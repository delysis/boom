import BoomCore
import Foundation
import MLX
import MLXLMCommon

struct PromptCacheOwner: Codable, Hashable, Sendable {
  enum Route: String, Codable, Sendable { case consultation, writing, inputCompletion }
  let namespace: UUID
  let entity: UUID
  let route: Route
}

struct PromptCacheGeometry: Codable, Equatable, Sendable {
  enum Chunking: String, Codable, Sendable { case balanced, remainder, unchunked }
  let chunking: Chunking
  let tokenCeiling: Int
  let chunkStride: Int?
  init(promptTokens: Int, prefill: PrefillParameters) {
    switch prefill.chunking {
    case .balanced: chunking = .balanced
    case .remainder: chunking = .remainder
    case .unchunked: chunking = .unchunked
    }
    tokenCeiling = prefill.resolvedStepSize()
    chunkStride = prefill.chunkLength(forChunking: max(0, promptTokens - 1))
  }
}

/// Transient, bounded KV. The runner binds model/processor identity; workspace
/// namespaces isolate content. Entity and route do not limit lookup. One native
/// cache stays hot; additional rotating history uses disposable bounded files.
/// A hit requires available coverage in every actual cache layer.
///
/// The lock protects index/publication metadata. Tensor access, hydration and
/// eviction remain on the inference executor under the exclusive model lease.
final class PromptPrefixCache: @unchecked Sendable {
  static let algorithm = "resident-hybrid-prefix-v6-joined"
  static let defaultByteLimit: UInt64 = 1 << 30
  static let activeAlgorithm = "one-active-native-prefix-v1-joined"

  enum Origin: String, Codable, Equatable, Sendable { case prefill, singleDecode, batchDecode }
  fileprivate enum ReservationDecision: String, Sendable {
    case admitted
    case poolLimit = "pool_limit"
    case residency = "residency_declined"
    case staleTicket = "stale_ticket"
  }
  struct RetentionObservation: Codable, Sendable {
    let compactLocalCoverage: Bool
    let lastCompleteTokenCount: Int
    let refusalReason: String?
    var diskReadyMisses: UInt64 = 0
    var diskBusyMisses: UInt64 = 0
    var diskWriteMisses: UInt64 = 0
    var diskAdmissionMisses: UInt64 = 0
    var diskQuotaMisses: UInt64 = 0
    var diskBytes: UInt64 = 0
    var diskSubmittedJobs: UInt64 = 0
    var diskCreatedFiles: UInt64 = 0
    var diskWriteCalls: UInt64 = 0
    var diskWrittenBytes: UInt64 = 0
    var diskDirectoryPath: String? = nil
  }
  struct ForwardSegment: Codable, Equatable, Sendable {
    let origin: Origin
    let startTokenCount: Int
    let endTokenCount: Int
    let batchWidth: Int
    let row: Int?
    let promptTokenCount: Int?
    let geometry: PromptCacheGeometry?
    // A prefix inside a forward still came from the complete original forward.
    var evaluatedEndTokenCount: Int? = nil
    var originalInput: OperandWitness? = nil
  }
  /// Immutable shared metadata; the existing backing lease charges its bounded
  /// host bytes until every entry, borrowed history and observation releases it.
  final class OperandWitness: Codable, Equatable, @unchecked Sendable {
    let binding: ForwardOperandBinding
    let identity: String
    private let lease: PrefixKVDependencyLease?
    init(_ binding: ForwardOperandBinding, lease: PrefixKVDependencyLease? = nil) {
      self.binding = binding; self.lease = lease
      identity = (try? Digest.identity(binding)) ?? ""
    }
    required init(from decoder: Decoder) throws {
      binding = try ForwardOperandBinding(from: decoder); lease = nil
      identity = (try? Digest.identity(binding)) ?? ""
    }
    func encode(to encoder: Encoder) throws { try binding.encode(to: encoder) }
    func committed() -> OperandWitness? {
      guard let value = binding.committed(allOwningLayersComplete: true, actuallySubmitted: true) else { return nil }
      return OperandWitness(value, lease: lease)
    }
    static func == (lhs: OperandWitness, rhs: OperandWitness) -> Bool { lhs.binding == rhs.binding }
  }
  /// One immutable host context per operation. Slices share the already-owned
  /// prepared token arrays; each forward retains only a bounded digest, never a
  /// repeated copy of the full prompt or any tensor/embedding contents.
  fileprivate final class OperandContext: @unchecked Sendable {
    let model: String
    let suffixes: [ArraySlice<Int>]
    let cached: [Int]
    let prefillMembers: [ForwardOperandBinding.Member]
    let decodeMembers: [ForwardOperandBinding.Member]
    private let lease: PrefixKVDependencyLease
    init?(model: String, tokenRows: [[Int]], cached: [Int], requests: [[String]],
      histories: [[ForwardSegment]], cacheLengths: [[Int]], cacheWidths: [Int],
      sharedDecodeRequests: [String]?, lease: PrefixKVDependencyLease) {
      guard ForwardOperandBinding.isDigest(model), (1...4).contains(tokenRows.count),
        cached.count == tokenRows.count, requests.count == tokenRows.count,
        histories.count == tokenRows.count, cacheLengths.count == tokenRows.count,
        !cacheWidths.isEmpty, cacheWidths.count <= 128,
        cacheWidths.allSatisfy({ (0...16_384).contains($0) }),
        cacheLengths.allSatisfy({ $0.count == cacheWidths.count
          && zip($0, cacheWidths).allSatisfy({ (0...$0.1).contains($0.0) }) }),
        tokenRows.indices.allSatisfy({ !tokenRows[$0].isEmpty && tokenRows[$0].count <= 16_384
          && (0..<tokenRows[$0].count).contains(cached[$0]) }) else { return nil }
      struct Padding: Encodable { let lengths: [Int]; let widths: [Int] }
      var members: [ForwardOperandBinding.Member] = []
      for row in tokenRows.indices {
        guard let full = ForwardOperandBinding.tokenDigest([tokenRows[row]]),
          let prefix = cached[row] == 0 ? Digest.sha256("Boom.empty-token-prefix.v1")
            : ForwardOperandBinding.tokenDigest([Array(tokenRows[row].prefix(cached[row]))]),
          let source = try? PromptPrefixCache.operandHistoryDigest(histories[row]),
          let padding = try? Digest.identity(Padding(lengths: cacheLengths[row], widths: cacheWidths)) else { return nil }
        members.append(.init(logicalRequests: requests[row], preparedTokenDigest: full,
          preparedTokenCount: tokenRows[row].count, cachedTokenCount: cached[row],
          cachedTokenDigest: prefix, cachedSourceDigest: source, cachePaddingDigest: padding))
      }
      self.model = model; self.cached = cached; self.lease = lease
      suffixes = tokenRows.indices.map { tokenRows[$0][cached[$0]...] }
      prefillMembers = members
      if let sharedDecodeRequests {
        guard tokenRows.count == 1, (1...4).contains(sharedDecodeRequests.count) else { return nil }
        let base = members[0]
        decodeMembers = sharedDecodeRequests.map {
          .init(logicalRequests: [$0], preparedTokenDigest: base.preparedTokenDigest,
            preparedTokenCount: base.preparedTokenCount, cachedTokenCount: base.cachedTokenCount,
            cachedTokenDigest: base.cachedTokenDigest, cachedSourceDigest: base.cachedSourceDigest,
            cachePaddingDigest: base.cachePaddingDigest)
        }
      } else { decodeMembers = members }
    }
    func prefill(_ range: Range<Int>, physicalWidth: Int, actualLengths: [Int]) -> ForwardOperandBinding? {
      guard physicalWidth == suffixes.count, actualLengths == suffixes.map(\.count),
        range.lowerBound >= 0, range.upperBound <= (actualLengths.max() ?? 0), !range.isEmpty else { return nil }
      let valid = suffixes.map { max(0, min(range.count, $0.count - range.lowerBound)) }
      let rows = suffixes.indices.map { row -> [Int] in
        let lower = min(range.lowerBound, suffixes[row].count)
        let begin = suffixes[row].index(suffixes[row].startIndex, offsetBy: lower)
        return Array(suffixes[row][begin..<suffixes[row].index(begin, offsetBy: valid[row])])
          + Array(repeating: 0, count: range.count - valid[row])
      }
      return ForwardOperandBinding.candidate(phase: .prefill, modelBinding: model, members: prefillMembers,
        inputRangeStart: range.lowerBound, tokenRows: rows,
        logicalStarts: suffixes.indices.map { cached[$0] + min(range.lowerBound, suffixes[$0].count) },
        validLengths: valid, generationActive: Array(repeating: true, count: physicalWidth))
    }
    func decode(_ sampled: [Int], logicalStarts: [Int], active: [Bool], step: Int) -> ForwardOperandBinding? {
      guard sampled.count == decodeMembers.count, logicalStarts.count == sampled.count,
        active.count == sampled.count else { return nil }
      // The real decode call has no prompt padding mask. Inert rows still are
      // actual physical operands; semantic activity is recorded separately.
      return ForwardOperandBinding.candidate(phase: .decode, modelBinding: model, members: decodeMembers,
        inputRangeStart: step, tokenRows: sampled.map { [$0] }, logicalStarts: logicalStarts,
        validLengths: Array(repeating: 1, count: sampled.count), generationActive: active)
    }
  }
  static func operandHistoryDigest(_ history: [ForwardSegment]) throws -> String {
    struct Segment: Encodable {
      let origin: Origin; let start: Int; let end: Int; let evaluatedEnd: Int?
      let width: Int; let row: Int?; let prompt: Int?; let geometry: PromptCacheGeometry?
      let operand: String?
    }
    guard history.count <= 16_384 else { throw BoomError.invalid("Unbounded forward metadata.") }
    // Linear metadata only: the original matrix digest/context is shared and
    // hashed once per actual forward, not serialized again per history prefix.
    return try Digest.identity(history.map { Segment(origin: $0.origin, start: $0.startTokenCount,
      end: $0.endTokenCount, evaluatedEnd: $0.evaluatedEndTokenCount, width: $0.batchWidth,
      row: $0.row, prompt: $0.promptTokenCount, geometry: $0.geometry, operand: $0.originalInput?.identity) })
  }
  struct Completion: Sendable {
    let row: Int
    let emittedTokenIDs: [Int]
    let stopTokenID: Int?
    init(row: Int = 0, emittedTokenIDs: [Int], stopTokenID: Int? = nil) {
      self.row = row; self.emittedTokenIDs = emittedTokenIDs; self.stopTokenID = stopTokenID
    }
    fileprivate var observedTokenIDs: [Int] { emittedTokenIDs + (stopTokenID.map { [$0] } ?? []) }
  }
  struct ResidentInterval: Codable, Equatable, Sendable {
    let lowerBound: Int
    let upperBound: Int
  }
  struct LocalCoverage: Codable, Equatable, Sendable {
    let layer: Int
    let window: Int
    let keep: Int
    let intervals: [ResidentInterval]
  }
  struct NativeRowReceipt: Codable, Sendable {
    let completedTokenCount: Int
    let submittedTokenCount: Int
    let processedTokenCount: Int
    let deliveredGeneratedTokenCount: Int
    let acknowledgedGeneratedTokenCount: Int
    let observedStopTokenID: Int?
  }
  struct SnapshotObservation: Codable, Sendable {
    let tokenIDs: [Int]
    let origin: Origin
    let batchWidth: Int
    let row: Int?
    let forwardHistory: [ForwardSegment]
    let geometry: PromptCacheGeometry
    var residentLocalStarts: [Int] = []
    var namespace: UUID? = nil
    // Missing in starts-only historical receipts; absence is not gap-free proof.
    var residentLocalCoverage: [LocalCoverage]? = nil
    var joinedRetentionProvenance: JoinedKVRetentionProvenance? = nil
    var nativePhysicalWidth: Int? = nil
    var nativeRowReceipt: NativeRowReceipt? = nil
  }
  struct Observation: Codable, Sendable {
    let algorithm: String
    let originalGeometry: PromptCacheGeometry
    let suffixGeometry: PromptCacheGeometry
    let fullPromptTokens: Int
    let cachedPromptTokens: Int
    let suffixPromptTokens: Int
    let missReason: String?
    let cachedOrigin: Origin?
    let cachedBatchWidth: Int?
    let cachedRow: Int?
    let cachedForwardHistory: [ForwardSegment]
    var retainedBytes: UInt64 = 0
    var byteLimit: UInt64 = 0
    var cachedJoinedRetentionProvenance: JoinedKVRetentionProvenance? = nil
    var nativeTensorBytes: UInt64? = nil
    var cachedNativePhysicalWidth: Int? = nil
    var unavailableDiskBackings: Int = 0
    var cachedCurrentHotPrefix: Bool = false
  }
  struct Session {
    let input: LMInput
    let cache: [KVCache]
    let prefill: PrefillParameters
    let cachedTokenCount: Int
    let fullPromptTokenCount: Int
    let preservesChunkBoundaries: Bool
    let observation: Observation
    fileprivate let owner: PromptCacheOwner?
    fileprivate let epoch: UUID
    fileprivate let joinedRetentionBinding: JoinedKVRetentionBinding?
    fileprivate let capture: Capture?
    fileprivate var nativeOwners: [PrefixKVNativeOwnership]? = nil
    var usesActiveNativeState: Bool { nativeOwners != nil }
    var stagedAnchorTokenCounts: [Int] {
      guard let count = capture?.coveredEnd, count > 0 else { return [] }
      return [count]
    }
    var stagedBytesUpperBound: UInt64 { capture?.stagedBytes ?? 0 }
    var submittedTokenCount: Int { capture?.submittedTokenCount ?? cachedTokenCount }
    /// Called only after a known pinned path actually submitted/evaluated this
    /// cache cohort. Terminal prefill progress is deliberately not such proof.
    func markCacheSubmitted() { capture?.markCacheSubmitted() }
    /// Producer-only checkpoint; no eval, GPU wait, data copy or file IO.
    func observeReadySpill() { capture?.observeReadySpill(cache.map { PrefixKVStorage.unwrap($0) }) }
    /// Existing producer join/fence must precede this optimization finalizer.
    func joinPendingSpill(cancelled: Bool) async {
      guard let capture else { return }
      if cancelled { capture.cancelSpill() }
      await capture.joinSpill()
      if !cancelled { await capture.drainReadySpills(cache.map { PrefixKVStorage.unwrap($0) }) }
    }
    /// Only the verified text route installs this observer. Its pinned prepare
    /// helper confirms the actual physical width/valid lengths at each call.
    func bindForwardOperands(model: String, requests: [String])
      -> (@Sendable (Range<Int>, Int, [Int]) -> Void)? {
      guard let capture, let lease = capture.makeContextLease(16_384),
        let context = OperandContext(model: model, tokenRows: [capture.tokens], cached: [cachedTokenCount],
          requests: [requests], histories: [observation.cachedForwardHistory],
          cacheLengths: [cache.map { $0.offset }], cacheWidths: cache.map { $0.offset },
          sharedDecodeRequests: requests, lease: lease) else { return nil }
      capture.installOperandContext(context)
      return { [weak capture] range, width, lengths in
        guard let capture else { return }
        capture.beginOperand(capture.prepareOperand(context.prefill(range, physicalWidth: width, actualLengths: lengths)))
      }
    }
    func observeDecodeOperands(_ sampled: [Int], active: [Bool]) { capture?.observeDecodeOperands(sampled, active: active) }
    var retentionObservation: RetentionObservation? { capture?.observation }
    var retentionDiagnosticForTesting: [String: Int]? { capture?.retentionDiagnostic }
    func discardStagedAnchors() { capture?.discard() }
    var didSample: (@Sendable (MLXArray) -> Void)? {
      guard let capture else { return nil }
      return { capture.observeSample($0) }
    }
    @discardableResult func captureDecodeLane(row: Int, width: Int, emittedTokenIDs: [Int],
      stopTokenID: Int? = nil, finished: Bool) -> Bool {
      capture?.observeLane(row: row, width: width,
        completion: Completion(row: row, emittedTokenIDs: emittedTokenIDs, stopTokenID: stopTokenID),
        finished: finished) ?? false
    }
    @discardableResult func captureFinishedLane(row: Int, width: Int, emittedTokenIDs: [Int],
      stopTokenID: Int? = nil) -> Bool {
      captureDecodeLane(row: row, width: width, emittedTokenIDs: emittedTokenIDs,
        stopTokenID: stopTokenID, finished: true)
    }
  }

  fileprivate struct Entry {
    let id: UUID
    let owner: PromptCacheOwner
    let tokens: [Int]
    let layouts: [PrefixKVStorage.Layout]
    var spans: [[PrefixKVSpan]]
    let geometry: PromptCacheGeometry
    let origin: Origin
    let batchWidth: Int
    let row: Int?
    let history: [ForwardSegment]
    var nativeGlobalPrefix: Int? = nil
    // Metadata witness only: no array/view is stored beside the one hot owner.
    // ActiveNativeRecord re-admits exact current offset/row/ring coverage.
    var nativeCurrentPrefix: Int? = nil
    var nativePhysicalWidth: Int? = nil
    var nativeProcessedTokenCount: Int? = nil
    // Physical row in the current native owner, independent of the original
    // batch row retained in forward provenance after scalar extraction.
    var nativeLedgerRow: Int? = nil
    var nativeRowReceipt: NativeRowReceipt? = nil
    var joinedAcknowledgedRow: Int? = nil
    var joinedRetentionProvenance: JoinedKVRetentionProvenance? = nil
    var observation: SnapshotObservation {
      SnapshotObservation(tokenIDs: tokens, origin: origin, batchWidth: batchWidth, row: row,
        forwardHistory: history, geometry: geometry,
        residentLocalStarts: zip(layouts, spans).compactMap { layout, values in
          if case .rotating = layout { return values.map(\.start).min() ?? tokens.count }
          return nil
        }, namespace: owner.namespace,
        residentLocalCoverage: layouts.enumerated().compactMap { layer, layout in
          guard case .rotating(let window, let keep, _, _) = layout else { return nil }
          return LocalCoverage(layer: layer, window: window, keep: keep,
            intervals: Self.contiguousIntervals(spans[layer], through: tokens.count))
        }, joinedRetentionProvenance: joinedRetentionProvenance,
        nativePhysicalWidth: nativePhysicalWidth, nativeRowReceipt: nativeRowReceipt)
    }
    static func contiguousIntervals(_ values: [PrefixKVSpan], through count: Int) -> [ResidentInterval] {
      var result: [ResidentInterval] = []
      for span in values where span.start < count {
        let upper = min(span.end, count)
        if let previous = result.last, span.start <= previous.upperBound {
          result[result.count - 1] = ResidentInterval(lowerBound: previous.lowerBound,
            upperBound: max(previous.upperBound, upper))
        } else { result.append(ResidentInterval(lowerBound: span.start, upperBound: upper)) }
      }
      return result
    }
    // Local prompt and endpoint windows may be disjoint. Every requested native
    // tail must be covered; holes outside that tail are not fabricated or filled.
    func supports(_ count: Int) -> Bool {
      guard count > 0, count <= tokens.count else { return false }
      return zip(layouts, spans).allSatisfy { layout, values in
        switch layout {
        case .simple: return nativeGlobalPrefix.map { count <= $0 } ?? Self.covers(0..<count, spans: values)
        case .rotating(let window, let keep, _, _):
          if nativeCurrentPrefix == count { return true }
          let prefix = min(keep, count)
          return Self.covers(0..<prefix, spans: values)
            && Self.covers(max(prefix, count - (window - keep))..<count, spans: values)
        }
      }
    }
    /// The lexical LCP may lie in a local-coverage gap. The greatest admissible
    /// count is either the cap or an endpoint of one layer's contiguous coverage.
    /// Try those metadata-only ceilings, never rewind a rotating native cache.
    func maximumSupportedPrefix(upTo lexicalCount: Int) -> Int? {
      let cap = min(lexicalCount, tokens.count)
      guard cap > 0 else { return nil }
      if supports(cap) { return cap }
      var ceilings: Set<Int> = []
      if let nativeCurrentPrefix, nativeCurrentPrefix <= cap { ceilings.insert(nativeCurrentPrefix) }
      for values in spans {
        var upper: Int?
        for span in values {
          if let prior = upper, span.start > prior { ceilings.insert(min(cap, prior)) }
          upper = max(upper ?? span.end, span.end)
        }
        if let upper { ceilings.insert(min(cap, upper)) }
      }
      return ceilings.filter { $0 > 0 && $0 < cap }.sorted(by: >).first(where: supports)
    }
    static func covers(_ range: Range<Int>, spans: [PrefixKVSpan]) -> Bool {
      guard !range.isEmpty else { return true }
      var end = range.lowerBound
      for span in spans where span.end > end {
        if span.start > end { return false }
        end = min(range.upperBound, span.end)
        if end == range.upperBound { return true }
      }
      return false
    }
  }

  /// Captures actual forward/token provenance before each native cache update.
  /// Completed rotating parents spill through the ready-only hook; no incoming
  /// local array/view is archived and no extra GPU fence is inserted.
  fileprivate final class Capture: @unchecked Sendable {
    private struct Forward {
      let start: Int
      let end: Int
      let width: Int
      var layers: Set<Int> = []
      var reservedBytes: UInt64
      var usedBytes: UInt64 = 0
    }
    /// Expiration releases descriptors from the front in amortized O(1).
    /// Pinned prefix and the initial reusable prompt window stay separate from
    /// the rolling tail. Expiration drops intervening history, even beyond W.
    private struct SpanBuffer {
      let keep: Int
      private var pinned: [PrefixKVSpan] = []
      private var initialWindow: [PrefixKVSpan] = []
      private var initialRange: Range<Int>?
      private var storage: [PrefixKVSpan?] = []
      private var head = 0
      init(keep: Int = 0) { self.keep = keep }
      mutating func append(_ span: PrefixKVSpan) -> [PrefixKVSpan] {
        var pieces: [PrefixKVSpan] = []
        func piece(_ range: Range<Int>) -> PrefixKVSpan? {
          guard !range.isEmpty else { return nil }
          return try? span.sliced(positions: (range.lowerBound - span.start)..<(range.upperBound - span.start))
        }
        if span.start < keep, let prefix = piece(span.start..<min(keep, span.end)) {
          pinned.append(prefix); pieces.append(prefix)
        }
        if span.end > keep, let tail = piece(max(keep, span.start)..<span.end) {
          storage.append(tail); pieces.append(tail)
        }
        return pieces
      }
      var values: [PrefixKVSpan] { pinned + initialWindow + storage[head...].compactMap { $0 } }
      mutating func expire(through boundary: Int, preserving required: Range<Int>) -> [PrefixKVSpan] {
        var removed: [PrefixKVSpan] = []
        if initialRange != required {
          var kept: [PrefixKVSpan] = []
          for span in initialWindow {
            if span.start < required.upperBound && span.end > required.lowerBound { kept.append(span) }
            else { removed.append(span) }
          }
          initialWindow = kept; initialRange = required
        }
        while head < storage.count, let span = storage[head], span.end <= boundary {
          if span.start < required.upperBound && span.end > required.lowerBound { initialWindow.append(span) }
          else { removed.append(span) }
          storage[head] = nil; head += 1
        }
        if head >= 128, head >= storage.count / 2 {
          storage.removeFirst(head); head = 0
        }
        return removed
      }
      mutating func removeIncomplete(start: Int) -> [PrefixKVSpan] {
        var removed: [PrefixKVSpan] = []
        if let last = storage.last ?? nil, last.start >= start {
          removed.append(last); storage.removeLast()
        }
        if let last = pinned.last, last.start >= start {
          removed.append(last); pinned.removeLast()
        }
        if let last = initialWindow.last, last.start >= start {
          removed.append(last); initialWindow.removeLast()
        }
        return removed
      }
    }
    private struct SpanCharge { let bytes: UInt64; let novel: Bool; var references: Int }
    private struct Lane {
      let width: Int
      var processed: Int
      var ledger: [Int]
      var finished: Bool
      var frozenLocal: [[PrefixKVSpan]]? = nil
    }
    let layouts: [PrefixKVStorage.Layout]
    let nativeGlobals: Bool
    let tokens: [Int]
    let cachedCount: Int
    let geometry: PromptCacheGeometry
    let suffixGeometry: PromptCacheGeometry
    let inheritedHistory: [ForwardSegment]
    private let reserve: @Sendable (UInt64, Bool) -> ReservationDecision
    private let retainBacking: @Sendable (UUID, UInt64) -> Void
    private let releaseBacking: @Sendable (UUID) -> Void
    private let closeLease: @Sendable () -> Void
    private let retainRawBacking: @Sendable (UUID, UUID, UInt64) -> Void
    private let releaseRawBacking: @Sendable (UUID, UUID) -> Void
    private let closeRawLease: @Sendable (UUID) -> Void
    private let disk: PrefixKVDiskStore
    private let spillIsLive: @Sendable () -> Bool
    private let reclaimDiskEntry: @Sendable () -> Bool
    private var spillThrough: [Int]
    private var nextSpillLayer = 0
    private var lastSpillEnd = 0
    private let spillStride: Int
    private var diskPromptBoundary = 0
    private let spillCancellation = CancellationFlag()
    private var diskReadyMisses: UInt64 = 0
    private var diskBusyMisses: UInt64 = 0
    private var diskWriteMisses: UInt64 = 0
    private var diskAdmissionMisses: UInt64 = 0
    private var lastSpillQuotaRefusal = false
    private let lock = NSLock()
    private var spans: [SpanBuffer]
    private var spanCharges: [UUID: SpanCharge] = [:]
    private var novelBytes: UInt64 = 0
    private var bytesPerPosition: [UInt64]
    private var pending: Forward?
    private var end: Int
    private var complete = false
    private var accepting = true
    private var discarded = false
    private var compactLocalCoverage = false
    private var lastCompleteTokenCount = 0
    private var refusalReason: ReservationDecision?
    private var history: [ForwardSegment] = []
    private var currentOperand: OperandWitness?
    private var operandCandidates: [Int: OperandWitness] = [:]
    private var scalarOperandMembers: [ForwardOperandBinding.Member] = []
    private var operandModelBinding: String?
    private let makeOperandWitness: @Sendable (ForwardOperandBinding) -> OperandWitness?
    let makeContextLease: @Sendable (UInt64) -> PrefixKVDependencyLease?
    private var operandContext: OperandContext?
    private var samples: [MLXArray] = []
    private var singleValid = true
    private var lanes: [Int: Lane] = [:]
    weak var primaryCache: PrefixKVCache?
    fileprivate let independentRow: Int?
    private let independentWidth: Int?

    init(layouts: [PrefixKVStorage.Layout], tokens: [Int], cachedCount: Int,
      geometry: PromptCacheGeometry, suffixGeometry: PromptCacheGeometry,
      inherited: Entry?, reserve: @escaping @Sendable (UInt64, Bool) -> ReservationDecision,
      retainBacking: @escaping @Sendable (UUID, UInt64) -> Void,
      releaseBacking: @escaping @Sendable (UUID) -> Void,
      closeLease: @escaping @Sendable () -> Void,
      retainRawBacking: @escaping @Sendable (UUID, UUID, UInt64) -> Void,
      releaseRawBacking: @escaping @Sendable (UUID, UUID) -> Void,
      closeRawLease: @escaping @Sendable (UUID) -> Void, disk: PrefixKVDiskStore,
      spillIsLive: @escaping @Sendable () -> Bool,
      reclaimDiskEntry: @escaping @Sendable () -> Bool, nativeGlobals: Bool = false,
      independentRow: Int? = nil, independentWidth: Int? = nil,
      makeOperandWitness: @escaping @Sendable (ForwardOperandBinding) -> OperandWitness? = { _ in nil },
      makeContextLease: @escaping @Sendable (UInt64) -> PrefixKVDependencyLease? = { _ in nil }) {
      self.makeOperandWitness = makeOperandWitness; self.makeContextLease = makeContextLease
      self.independentRow = independentRow; self.independentWidth = independentWidth
      self.layouts = layouts; self.nativeGlobals = nativeGlobals
      self.tokens = tokens; self.cachedCount = cachedCount
      self.geometry = geometry; self.suffixGeometry = suffixGeometry; self.reserve = reserve
      self.retainBacking = retainBacking; self.releaseBacking = releaseBacking; self.closeLease = closeLease
      self.retainRawBacking = retainRawBacking; self.closeRawLease = closeRawLease
      self.releaseRawBacking = releaseRawBacking
      self.disk = disk; self.spillIsLive = spillIsLive; self.reclaimDiskEntry = reclaimDiskEntry
      compactLocalCoverage = nativeGlobals
      spillStride = min(64, layouts.compactMap { layout -> Int? in
        if case .rotating(let window, let keep, _, _) = layout { return max(1, (window - keep) / 2) }
        return nil
      }.min() ?? 64)
      spillThrough = Array(repeating: 0, count: layouts.count)
      inheritedHistory = inherited.map { PromptPrefixCache.clippedHistory($0.history, through: cachedCount) } ?? []
      spans = layouts.map { layout in
        if case .rotating(_, let keep, _, _) = layout { return SpanBuffer(keep: keep) }
        return SpanBuffer()
      }
      end = cachedCount; lastCompleteTokenCount = cachedCount; submittedEnd = cachedCount
      bytesPerPosition = Array(repeating: 0, count: layouts.count)
      if let inherited {
        for layer in layouts.indices {
          for span in inherited.spans[layer] where span.start < cachedCount {
            let upper = min(span.end, cachedCount) - span.start
            let row = span.batchWidth == 1 ? 0 : inherited.row ?? 0
            if let cropped = try? span.sliced(positions: 0..<upper, row: row) {
              for piece in spans[layer].append(cropped) { retain(piece, novel: false) }
              spillThrough[layer] = max(spillThrough[layer], cropped.end)
            }
          }
        }
      }
      refreshDiskPromptBoundary()
    }
    // An inherited entry was already joined/fenced. New lazy descriptors alone
    // do not advance this witness; only actual pinned submission points do.
    private var submittedEnd: Int = 0
    private var workingGraphSubmitted = false
    var workingGraphWasSubmitted: Bool { lock.lock(); defer { lock.unlock() }; return workingGraphSubmitted }
    var submittedTokenCount: Int { lock.lock(); defer { lock.unlock() }; return submittedEnd }
    func markCacheSubmitted() {
      lock.lock(); defer { lock.unlock() }
      guard !discarded else { return }
      submittedEnd = max(submittedEnd, end); workingGraphSubmitted = true
      commitOperands(through: submittedEnd)
    }
    func installOperandContext(_ context: OperandContext) {
      lock.lock(); defer { lock.unlock() }
      operandContext = context; operandModelBinding = context.model; scalarOperandMembers = context.decodeMembers
    }
    func observeDecodeOperands(_ sampled: [Int], active: [Bool]) {
      lock.lock(); let context = operandContext; let start = end; lock.unlock()
      guard let context else { return }
      let step = max(0, start - tokens.count)
      beginOperand(prepareOperand(context.decode(sampled,
        logicalStarts: Array(repeating: start, count: sampled.count), active: active, step: step)))
    }
    func prepareOperand(_ candidate: ForwardOperandBinding?) -> OperandWitness? {
      candidate.flatMap(makeOperandWitness)
    }
    func beginOperand(_ candidate: OperandWitness?) {
      lock.lock(); defer { lock.unlock() }
      currentOperand = candidate
    }
    private func appendHistory(_ segment: ForwardSegment) {
      let index = history.count; history.append(segment)
      defer { currentOperand = nil }
      let row = independentRow ?? segment.row ?? 0
      if let value = currentOperand,
        value.binding.phase == (segment.origin == .prefill ? .prefill : .decode),
        value.binding.describes(start: segment.startTokenCount,
        end: segment.endTokenCount,
        evaluatedEnd: segment.evaluatedEndTokenCount ?? segment.endTokenCount,
        width: segment.batchWidth, row: segment.batchWidth > 1 ? row : nil) {
        operandCandidates[index] = value
      }
    }
    private func commitOperands(through submitted: Int) {
      for index in operandCandidates.keys.sorted() where history[index].endTokenCount <= submitted {
        // appendHistory runs only after every owning layer supplied the same
        // shape. The caller separately proves actual submission/join.
        history[index].originalInput = operandCandidates.removeValue(forKey: index)?.committed()
      }
    }
    private func bindJoinedScalarOperands(_ actual: [Int], through count: Int) {
      guard let model = operandModelBinding, scalarOperandMembers.count == 1 else { return }
      for index in history.indices {
        let segment = history[index]
        guard segment.originalInput == nil, segment.origin == .singleDecode, segment.batchWidth == 1,
          segment.endTokenCount == segment.startTokenCount + 1,
          segment.endTokenCount <= count, segment.startTokenCount >= tokens.count,
          actual.indices.contains(segment.startTokenCount - tokens.count) else { continue }
        let offset = segment.startTokenCount - tokens.count
        let candidate = ForwardOperandBinding.candidate(phase: .decode, modelBinding: model,
          members: scalarOperandMembers, inputRangeStart: offset,
          tokenRows: [[actual[offset]]], logicalStarts: [segment.startTokenCount],
          validLengths: [1], generationActive: [true])
        if let value = candidate?.committed(allOwningLayersComplete: true, actuallySubmitted: true) {
          history[index].originalInput = makeOperandWitness(value)
        }
      }
    }
    var coveredEnd: Int { lock.lock(); defer { lock.unlock() }; return end }
    var retentionDiagnostic: [String: Int] {
      lock.lock(); defer { lock.unlock() }
      return ["complete": complete ? 1 : 0, "coherent": nativeCoherent ? 1 : 0,
        "discarded": discarded ? 1 : 0, "submitted": submittedEnd, "end": end,
        "prompt": tokens.count, "cached": cachedCount, "pendingLayers": pending?.layers.count ?? -1,
        "pendingWidth": pending?.width ?? -1, "history": history.count, "lanes": lanes.count,
        "finishedLanes": lanes.values.filter { $0.finished }.count,
        "workingSubmitted": workingGraphSubmitted ? 1 : 0]
    }
    var stagedBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return novelBytes }
    var observation: RetentionObservation {
      lock.lock(); defer { lock.unlock() }
      let diskState = disk.observation
      return RetentionObservation(compactLocalCoverage: compactLocalCoverage,
        lastCompleteTokenCount: max(lastCompleteTokenCount, end), refusalReason: refusalReason?.rawValue,
        diskReadyMisses: diskReadyMisses, diskBusyMisses: diskBusyMisses,
        diskWriteMisses: diskWriteMisses, diskAdmissionMisses: diskAdmissionMisses,
        diskQuotaMisses: diskState.quotaMisses, diskBytes: diskState.bytes,
        diskSubmittedJobs: diskState.submittedJobs, diskCreatedFiles: diskState.createdFiles,
        diskWriteCalls: diskState.writeCalls, diskWrittenBytes: diskState.writtenBytes,
        diskDirectoryPath: diskState.directoryPath)
    }
    deinit {
      // No consumer remains; release descriptor ownership before its byte lease.
      spans.removeAll(); samples.removeAll(); lanes.removeAll(); spanCharges.removeAll()
      closeLease()
    }

    func update(layer: Int, offset: Int, keys: MLXArray, values: MLXArray) {
      let trace = PerformanceTrace.begin("Model.KVRetentionUpdate")
      defer { PerformanceTrace.end("Model.KVRetentionUpdate", trace) }
      lock.lock(); defer { lock.unlock() }
      if nativeGlobals { updateNative(layer: layer, offset: offset, keys: keys, values: values); return }
      guard accepting, !discarded, layouts.indices.contains(layer), keys.ndim == 4,
        values.ndim == 4, keys.dim(0) == values.dim(0), keys.dim(2) == values.dim(2),
        keys.dim(2) > 0 else { return }
      let length = keys.dim(2), width = keys.dim(0)
      if pending == nil {
        guard offset == end else { accepting = false; return }
        let firstPositionBytes = UInt64(max(0, keys.nbytes + values.nbytes)) / UInt64(length * max(1, width))
        let perPosition = bytesPerPosition.enumerated().reduce(UInt64(0)) { total, pair in
          PromptPrefixCache.adding(total, pair.element == 0 ? firstPositionBytes : pair.element)
        }
        let incoming = PromptPrefixCache.multiplying(perPosition, UInt64(length * width))
        guard admit(incoming: incoming, checkResidency: true) else { accepting = false; return }
        pending = Forward(start: offset, end: offset + length, width: width, reservedBytes: incoming)
      }
      guard var forward = pending, forward.start == offset, forward.end == offset + length,
        forward.width == width, !forward.layers.contains(layer),
        let span = try? PrefixKVSpan(offset: offset, layer: layer, keys: keys, values: values)
        else { accepting = false; removeIncomplete(); return }
      bytesPerPosition[layer] = UInt64(max(0, keys.nbytes + values.nbytes)) / UInt64(length * width)
      let actualBytes = Self.bytes(span)
      let actualCohort = PromptPrefixCache.adding(forward.usedBytes, actualBytes)
      if actualCohort > forward.reservedBytes {
        guard admit(incoming: actualBytes, checkResidency: false) else {
          accepting = false; removeIncomplete(); return
        }
        forward.reservedBytes = actualCohort
      }
      forward.usedBytes = actualCohort
      if case .simple = layouts[layer] {
        for piece in spans[layer].append(span) { retain(piece, novel: true) }
      }
      forward.layers.insert(layer); pending = forward
      if forward.layers.count == layouts.count {
        end = forward.end; lastCompleteTokenCount = end; pending = nil
        let origin: Origin = forward.start < tokens.count ? .prefill
          : forward.width == 1 ? .singleDecode : .batchDecode
        appendHistory(ForwardSegment(origin: origin, startTokenCount: forward.start,
          endTokenCount: forward.end, batchWidth: forward.width, row: nil,
          promptTokenCount: origin == .prefill ? tokens.count : nil,
          geometry: origin == .prefill ? suffixGeometry : nil,
          evaluatedEndTokenCount: forward.end))
        pruneLocalTail()
      }
    }
    /// Valid row tokens in one actual shared forward. The owning wrapper checks
    /// the full operand shape; padding and peers' inert decode inputs do not
    /// advance this row's semantic boundary or generated-token ledger.
    func updateCohort(layer: Int, count: Int, evaluatedCount: Int, width: Int, row: Int) {
      lock.lock(); defer { lock.unlock() }
      guard nativeGlobals, independentRow == row, independentWidth == width,
        !discarded, nativeCoherent, layouts.indices.contains(layer), count > 0,
        count <= evaluatedCount, evaluatedCount <= 16_384,
        count <= 16_384, end <= 16_384 - count else { return }
      if pending == nil {
        pending = Forward(start: end, end: end + count, width: width, reservedBytes: 0)
      }
      guard var forward = pending, forward.width == width, forward.end - forward.start == count,
        !forward.layers.contains(layer) else { nativeCoherent = false; return }
      forward.layers.insert(layer); pending = forward
      if forward.layers.count == layouts.count {
        end = forward.end; lastCompleteTokenCount = end; pending = nil
        let origin: Origin = forward.start < tokens.count ? .prefill : .batchDecode
        appendHistory(ForwardSegment(origin: origin, startTokenCount: forward.start,
          endTokenCount: forward.end, batchWidth: width, row: row,
          promptTokenCount: origin == .prefill ? tokens.count : nil,
          geometry: origin == .prefill ? suffixGeometry : nil,
          evaluatedEndTokenCount: forward.start + evaluatedCount))
        pruneLocalTail()
      }
    }
    func completedPreparation() {
      lock.lock(); defer { lock.unlock() }
      complete = nativeCoherent && pending == nil && end == tokens.count
    }
    var permitsJoinedHotState: Bool {
      lock.lock(); defer { lock.unlock() }
      return nativeCoherent && pending == nil && end == submittedEnd
    }
    func cohortSpillStart(layer: Int, actualPosition: Int, finalizing: Bool) -> Int? {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, !spillCancellation.isCancelled, pending == nil,
        layouts.indices.contains(layer), end > 0, actualPosition >= end, spillIsLive() else { return nil }
      let finishing = lanes.values.contains { $0.finished && $0.frozenLocal == nil && $0.processed > lastSpillEnd }
      guard finalizing || finishing || end - lastSpillEnd >= spillStride else { return nil }
      return spillThrough[layer]
    }
    func noteCohortSpill(accepted: Bool) {
      lock.lock(); defer { lock.unlock() }
      lastSpillEnd = end
      if !accepted { diskAdmissionMisses &+= 1 }
    }
    func acceptCohortSpill(_ values: [PrefixKVSpan]?) { acceptSpill(values) }

    /// Native globals are owned once; local archives contain only disk bytes.
    /// A declined optimization spill does not stop the all-layer
    /// completed/submitted witness or silently claim unsupported local coverage.
    private var nativeCoherent = true
    private func updateNative(layer: Int, offset: Int, keys: MLXArray, values: MLXArray) {
      guard !discarded, nativeCoherent, layouts.indices.contains(layer),
        (try? PrefixKVStorage.validatePair(keys, values)) != nil else { nativeCoherent = false; return }
      let length = keys.dim(2), width = keys.dim(0)
      let (upper, overflow) = offset.addingReportingOverflow(length)
      guard !overflow else { nativeCoherent = false; return }
      if pending == nil {
        guard offset == end else { nativeCoherent = false; return }
        pending = Forward(start: offset, end: upper, width: width, reservedBytes: 0)
      }
      guard var forward = pending, forward.start == offset, forward.end == upper,
        forward.width == width, !forward.layers.contains(layer) else { nativeCoherent = false; return }
      // Local retention happens only through completed raw ring data on disk.
      // Incoming keys/values remain owned solely by the actual active native KV.
      forward.layers.insert(layer); pending = forward
      if forward.layers.count == layouts.count {
        end = forward.end; lastCompleteTokenCount = end; pending = nil
        let origin: Origin = forward.start < tokens.count ? .prefill
          : forward.width == 1 ? .singleDecode : .batchDecode
        appendHistory(ForwardSegment(origin: origin, startTokenCount: forward.start,
          endTokenCount: forward.end, batchWidth: forward.width, row: nil,
          promptTokenCount: origin == .prefill ? tokens.count : nil,
          geometry: origin == .prefill ? suffixGeometry : nil, evaluatedEndTokenCount: forward.end))
        pruneLocalTail()
      }
    }
    /// The actual model owner calls before the next forward, while every cache
    /// still represents the same completed cohort. In-flight/partial graphs are
    /// never waited on. No lazy incoming array or row view becomes an archive.
    @discardableResult func observeReadySpill(_ caches: [any KVCache], finalizing: Bool = false) -> Bool {
      lock.lock(); defer { lock.unlock() }
      lastSpillQuotaRefusal = false
      guard !discarded, !spillCancellation.isCancelled, pending == nil, end > 0,
        caches.count == layouts.count, spillIsLive() else { return false }
      let finishingRow = lanes.values.contains { $0.finished && $0.frozenLocal == nil && $0.processed > lastSpillEnd }
      // Coalesce normal decode checkpoints, bounded by the actual local window.
      // Final joined state and an early-finished row may request a checkpoint
      // immediately. No wait/file IO is inserted into the model iteration.
      guard finalizing || finishingRow || end - lastSpillEnd >= spillStride else { return false }
      guard disk.canSubmit else { diskBusyMisses &+= 1; return false }
      lastSpillEnd = end // declined/unready checkpoints retry at the next interval or final join
      let rawLeaseID = UUID(), close = closeRawLease
      let rawLease = PrefixKVDependencyLease { close(rawLeaseID) }
      let admitParent: (Int) -> (@Sendable () -> Void)? = { [self] allocationBytes in
        let bytes = UInt64(allocationBytes)
        guard admit(incoming: bytes, checkResidency: true) else { return nil }
        let id = UUID(), release = releaseRawBacking
        retainRawBacking(rawLeaseID, id, bytes)
        return { release(rawLeaseID, id); withExtendedLifetime(rawLease) {} }
      }
      var ready: [PrefixKVDiskStore.ReadySpan] = []
      // A large real owner cohort may exceed the raw cap. Rotate through bounded
      // owner groups rather than pinning all parents or adding another job.
      for index in layouts.indices {
        let layer = (nextSpillLayer + index) % layouts.count
        let native = caches[layer]
        guard native.offset == end, PrefixKVStorage.layout(of: native) == layouts[layer] else {
          diskReadyMisses &+= 1; continue
        }
        let ranges: [(Int, Range<Int>)]
        switch layouts[layer] {
        case .simple:
          let start = min(end, spillThrough[layer])
          ranges = start < end ? [(start, start..<end)] : []
        case .rotating:
          guard let value = try? PrefixKVStorage.readyRingRanges(of: native,
            after: spillThrough[layer], needsPinned: !Entry.covers(0..<min(end, Self.keep(layouts[layer])),
              spans: spans[layer].values)) else { diskReadyMisses &+= 1; continue }
          ranges = value
        }
        guard !ranges.isEmpty else { continue }
        let arrays = native.innerState()
        guard arrays.count == 2, arrays[0].ndim == 4, arrays[1].ndim == 4,
          ranges.allSatisfy({ $0.1.upperBound <= arrays[0].dim(2) && $0.1.upperBound <= arrays[1].dim(2) }),
          let keys = arrays[0].readyBuffer(admitting: admitParent),
          let values = arrays[1].readyBuffer(admitting: admitParent) else {
          diskReadyMisses &+= 1
          if !ready.isEmpty { nextSpillLayer = layer; break }
          continue
        }
        var pieces: [PrefixKVDiskStore.ReadySpan] = []
        for (start, positions) in ranges {
          guard let value = try? PrefixKVDiskStore.ReadySpan(start: start, layer: layer,
            keys: keys, values: values, positions: positions) else { diskReadyMisses &+= 1; return false }
          pieces.append(value)
        }
        if !ready.isEmpty, !disk.fitsEmpty(ready + pieces) { nextSpillLayer = layer; break }
        ready.append(contentsOf: pieces)
      }
      guard !ready.isEmpty else { return false }
      if let last = ready.last { nextSpillLayer = (last.layer + 1) % layouts.count }
      let beforeQuotaMisses = disk.observation.quotaMisses
      let accepted = disk.submit(ready, isLive: { [weak self] in self?.spillStillLive() ?? false },
        completed: { [weak self] values in self?.acceptSpill(values) })
      if !accepted {
        diskAdmissionMisses &+= 1
        lastSpillQuotaRefusal = disk.observation.quotaMisses != beforeQuotaMisses && disk.fitsEmpty(ready)
      }
      return accepted
    }
    private var spillQuotaRefused: Bool { lock.lock(); defer { lock.unlock() }; return lastSpillQuotaRefusal }
    func drainReadySpills(_ caches: [any KVCache]) async {
      await disk.joinPending()
      // At most one admitted owner group per layer, after the actual producer
      // joined/fenced. No wait or write is added to an active decode iteration.
      var groups = 0, retirements = 0
      while groups < layouts.count {
        if observeReadySpill(caches, finalizing: true) {
          groups += 1; await disk.joinPending(); continue
        }
        guard spillQuotaRefused else { break }
        if retirements < 128, reclaimDiskEntry() { retirements += 1 }
        else if !shedOptionalDiskCoverage() { break }
        // Only remove an old index owner here, after the actual producer join.
        // Escaped hot/capture/lookup references still pin their files. Retry
        // observes the store's real quota only AFTER the utility unlink joins.
        await disk.joinPending()
      }
    }
    private static func keep(_ layout: PrefixKVStorage.Layout) -> Int {
      if case .rotating(_, let keep, _, _) = layout { return keep }; return 0
    }
    fileprivate func spillStillLive() -> Bool {
      return !spillCancellation.isCancelled && spillIsLive()
    }
    func cancelSpill() { spillCancellation.cancel() }
    func joinSpill() async { await disk.joinPending() }
    private func acceptSpill(_ values: [PrefixKVSpan]?) {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, !spillCancellation.isCancelled, spillIsLive() else { return }
      guard let values else { diskWriteMisses &+= 1; return }
      for span in values {
        for piece in spans[span.layer].append(span) { retain(piece, novel: true) }
        spillThrough[span.layer] = max(spillThrough[span.layer], span.end)
      }
      refreshDiskPromptBoundary()
      // A row may finish while this bounded write is pending. Freeze its real
      // immutable disk coverage before peers' later tail expiration.
      for row in Array(lanes.keys) {
        guard var lane = lanes[row], lane.finished, lane.frozenLocal == nil else { continue }
        lane.frozenLocal = freezeLocal(row: row, processed: lane.processed); lanes[row] = lane
      }
      pruneLocalTail()
    }
    private static func bytes(_ span: PrefixKVSpan) -> UInt64 {
      span.backingBytesUpperBound
    }
    private func removeIncomplete() {
      guard let pending else { return }
      for layer in spans.indices {
        for span in spans[layer].removeIncomplete(start: pending.start) { release(span) }
      }
      self.pending = nil
    }
    private func refreshDiskPromptBoundary() {
      guard nativeGlobals else { return }
      let cap = min(end, tokens.count)
      var candidates = Set(spans.flatMap { $0.values.map(\.end) }.filter { $0 > 0 && $0 <= cap })
      candidates.insert(cap)
      for count in candidates.sorted(by: >) where count > diskPromptBoundary {
        let supported = layouts.indices.allSatisfy { layer in
          let values = spans[layer].values
          switch layouts[layer] {
          case .simple: return Entry.covers(0..<count, spans: values)
          case .rotating(let window, let keep, _, _):
            let pinned = min(keep, count)
            return Entry.covers(0..<pinned, spans: values)
              && Entry.covers(max(pinned, count - (window - keep))..<count, spans: values)
          }
        }
        if supported { diskPromptBoundary = count; break }
      }
    }
    private func pruneLocalTail(forceDisk: Bool = false) {
      // Disk intervals stay eligible for earlier edits while quota admits them.
      // Only joined disk pressure sheds optional middle intervals. Required
      // current/initial/finished-row coverage keeps its actual file references.
      if nativeGlobals && !forceDisk { return }
      for layer in layouts.indices {
        guard case .rotating(let window, let keep, _, _) = layouts[layer] else { continue }
        // Pressure keeps both the initial reusable prompt boundary and current
        // endpoint/previous-boundary window. There is no archive between them.
        let first = localFloor(window: window, keep: keep, through: end)
        let initial = initialLocalRange(window: window, keep: keep, through: end)
        for span in spans[layer].expire(through: first, preserving: initial) { release(span) }
      }
    }
    private func localFloor(window: Int, keep: Int, through count: Int) -> Int {
      let (length, overflow) = compactLocalCoverage
        ? (window - keep).addingReportingOverflow(1) : window.multipliedReportingOverflow(by: 2)
      return overflow ? keep : max(keep, count - min(count, length))
    }
    private func initialLocalRange(window: Int, keep: Int, through count: Int) -> Range<Int> {
      let boundary = min(count, min(max(0, tokens.count - 1), nativeGlobals ? diskPromptBoundary : count))
      let pinned = min(keep, boundary)
      return max(pinned, boundary - (window - keep))..<boundary
    }
    /// Pressure reduces optional past coverage, never the required native tail.
    /// Whole incoming pages and all row views keep their immutable full charge.
    private func shedOptionalLocalCoverage(forceDisk: Bool = false) {
      compactLocalCoverage = true
      pruneLocalTail(forceDisk: forceDisk)
      if nativeGlobals && !forceDisk { return } // RAM pressure cannot reclaim disk-only bytes.
      for row in Array(lanes.keys) {
        guard var lane = lanes[row], var frozen = lane.frozenLocal else { continue }
        for layer in layouts.indices {
          guard case .rotating(let window, let keep, _, _) = layouts[layer] else { continue }
          let count = min(lane.processed, end)
          let first = localFloor(window: window, keep: keep, through: count)
          let initial = initialLocalRange(window: window, keep: keep, through: count)
          var kept: [PrefixKVSpan] = []
          for span in frozen[layer] {
            let neededInitially = span.start < initial.upperBound && span.end > initial.lowerBound
            if span.start >= keep, span.end <= first, !neededInitially { release(span) }
            else { kept.append(span) }
          }
          frozen[layer] = kept
        }
        lane.frozenLocal = frozen; lanes[row] = lane
      }
    }
    fileprivate func shedOptionalDiskCoverage() -> Bool {
      lock.lock(); defer { lock.unlock() }
      func files() -> Set<UUID> {
        let frozen = lanes.values.flatMap { $0.frozenLocal?.flatMap { $0 } ?? [] }
        return Set((spans.flatMap { $0.values } + frozen).compactMap(\.diskFileID))
      }
      let before = files()
      shedOptionalLocalCoverage(forceDisk: true)
      return !before.subtracting(files()).isEmpty
    }
    private func admit(incoming: UInt64, checkResidency: Bool) -> Bool {
      var decision = reserve(incoming, checkResidency)
      if decision == .admitted { return true }
      if decision == .poolLimit || decision == .residency {
        // Once compact, future cohorts keep that bounded target for this request.
        // The retry still uses actual OS/MLX accounting, without release credits.
        shedOptionalLocalCoverage()
        decision = reserve(incoming, checkResidency)
      }
      guard decision == .admitted else {
        refusalReason = decision
        return false
      }
      return true
    }
    private func retain(_ span: PrefixKVSpan, novel: Bool) {
      guard span.backingBytesUpperBound > 0 else { return }
      if var charge = spanCharges[span.id] { charge.references += 1; spanCharges[span.id] = charge }
      else {
        spanCharges[span.id] = SpanCharge(bytes: Self.bytes(span), novel: novel, references: 1)
        retainBacking(span.id, Self.bytes(span))
        if novel { novelBytes = PromptPrefixCache.adding(novelBytes, Self.bytes(span)) }
      }
    }
    private func release(_ span: PrefixKVSpan) {
      guard var charge = spanCharges[span.id] else { return }
      charge.references -= 1
      if charge.references == 0 {
        spanCharges.removeValue(forKey: span.id)
        releaseBacking(span.id)
        if charge.novel { novelBytes -= charge.bytes }
      } else { spanCharges[span.id] = charge }
    }
    private func freezeLocal(row: Int, processed: Int) -> [[PrefixKVSpan]]? {
      var frozen = Array(repeating: [PrefixKVSpan](), count: layouts.count)
      for layer in layouts.indices {
        guard case .rotating(let window, let keep, _, _) = layouts[layer] else { continue }
        let pinned = min(keep, processed)
        let required = pinned > 0 ? [0..<pinned, max(pinned, processed - (window - keep))..<processed]
          : [max(0, processed - window)..<processed]
        // Freeze the same bounded resident coverage, not just one endpoint.
        // A following query may end one token earlier or diverge inside it.
        for span in spans[layer].values where span.start < processed {
          let upper = min(span.end, processed), selected = span.batchWidth == 1 ? 0 : row
          guard selected < span.batchWidth,
            let view = try? span.sliced(positions: 0..<(upper - span.start), row: selected) else { return nil }
          frozen[layer].append(view)
        }
        guard required.allSatisfy({ Entry.covers($0, spans: frozen[layer]) }) else { return nil }
      }
      for span in frozen.flatMap({ $0 }) { retain(span, novel: spanCharges[span.id]?.novel ?? false) }
      return frozen
    }
    func progress(processed: Int, total: Int) {
      lock.lock(); defer { lock.unlock() }
      guard total == tokens.count - cachedCount, processed >= 0, processed <= total else { return }
      if processed == total { complete = true }
      else if processed > 0 {
        // Pinned Gemma4 text prepare's intermediate callback runs only AFTER
        // asyncEval(cache). Its terminal callback runs BEFORE final submission.
        let (full, overflow) = cachedCount.addingReportingOverflow(processed)
        if !overflow, full <= end {
          submittedEnd = max(submittedEnd, full); workingGraphSubmitted = true
          commitOperands(through: submittedEnd)
        }
      }
    }
    func observeSample(_ token: MLXArray) {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, singleValid, lanes.isEmpty, token.size == 1,
        samples.count < 16_384, primaryCache?.offset == tokens.count + samples.count else {
        singleValid = false; return
      }
      samples.append(token[.ellipsis])
    }
    func observeLane(row: Int, width: Int, completion: Completion, finished: Bool) -> Bool {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, samples.isEmpty, (1...4).contains(width), (0..<width).contains(row),
        completion.row == row, let processed = primaryCache?.offset ?? (independentRow == row ? end : nil),
        processed >= tokens.count, processed - tokens.count <= completion.observedTokenIDs.count else { return false }
      if let previous = lanes[row] {
        guard previous.width == width, !previous.finished, processed >= previous.processed,
          completion.observedTokenIDs.starts(with: previous.ledger) else { return false }
      }
      let frozen = finished ? freezeLocal(row: row, processed: min(processed, end)) : nil
      // Finishing is an actual decode ledger fact. Optional disk coverage can
      // still be in flight; final entry coverage checks remain strict.
      lanes[row] = Lane(width: width, processed: processed,
        ledger: completion.observedTokenIDs, finished: finished, frozenLocal: frozen)
      return true
    }
    func discard() {
      spillCancellation.cancel()
      lock.lock(); defer { lock.unlock() }
      discarded = true; accepting = false; spans.removeAll(); samples.removeAll(); lanes.removeAll()
      currentOperand = nil; operandCandidates.removeAll(); history.removeAll(); operandContext = nil
      spanCharges.removeAll(); novelBytes = 0; end = 0; pending = nil
      closeLease()
    }
    // Only after the producer joins and the existing fence. The authoritative
    // delivered ledger bounds publication, regardless of producer lookahead.
    func entries(owner: PromptCacheOwner, completions: [Completion]) -> [Entry] {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, complete, pending == nil, end > 0,
        Set(completions.map(\.row)).count == completions.count else { return [] }
      func entry(ledger: [Int], processed: Int, width: Int, row: Int?, frozenLocal: [[PrefixKVSpan]]? = nil) -> Entry? {
        let count = min(nativeGlobals ? submittedEnd : end, min(end, min(processed, tokens.count + ledger.count)))
        guard count > 0 else { return nil }
        let ids = Array(tokens.prefix(count)) + Array(ledger.prefix(max(0, count - tokens.count)))
        let selectedHistory = PromptPrefixCache.clippedHistory(inheritedHistory + history, through: count).map { segment in
          ForwardSegment(origin: segment.origin, startTokenCount: segment.startTokenCount,
            endTokenCount: segment.endTokenCount, batchWidth: segment.batchWidth,
            row: segment.row ?? (segment.origin == .batchDecode && segment.startTokenCount >= tokens.count ? row : nil),
            promptTokenCount: segment.promptTokenCount, geometry: segment.geometry,
            evaluatedEndTokenCount: segment.evaluatedEndTokenCount, originalInput: segment.originalInput)
        }
        let value = Entry(id: UUID(), owner: owner, tokens: ids, layouts: layouts,
          spans: layouts.indices.map { layer in
            if case .rotating = layouts[layer], let frozenLocal { return frozenLocal[layer] }
            return spans[layer].values.filter { $0.start < count }
          }, geometry: geometry,
          origin: selectedHistory.last?.origin ?? .prefill, batchWidth: width, row: row,
          history: selectedHistory, nativeGlobalPrefix: nativeGlobals ? count : nil,
          nativeCurrentPrefix: nativeGlobals && count == end ? count : nil)
        if nativeGlobals {
          guard let supported = value.maximumSupportedPrefix(upTo: count) else { return nil }
          let clipped = PromptPrefixCache.clippedHistory(selectedHistory, through: supported)
          let source = clipped.last
          return Entry(id: value.id, owner: owner, tokens: Array(ids.prefix(supported)), layouts: layouts,
            spans: value.spans.map { $0.filter { $0.start < supported } }, geometry: geometry,
            origin: source?.origin ?? .prefill, batchWidth: source?.batchWidth ?? width,
            row: independentRow ?? (source?.origin == .batchDecode ? source?.row ?? row : nil), history: clipped,
            nativeGlobalPrefix: supported,
            nativeCurrentPrefix: supported == end ? supported : nil,
            nativeProcessedTokenCount: row == nil ? end : processed,
            nativeLedgerRow: independentRow ?? row ?? 0)
        }
        return value.supports(count) ? value : nil
      }
      var result: [Entry] = []
      if !lanes.isEmpty {
        for row in lanes.keys.sorted() {
          guard let lane = lanes[row], lane.finished, let completion = completions.first(where: { $0.row == row }),
            completion.observedTokenIDs == lane.ledger else { continue }
          if let value = entry(ledger: lane.ledger, processed: lane.processed, width: lane.width,
            row: row, frozenLocal: lane.frozenLocal) { result.append(value) }
        }
      } else {
        var matching: [Int] = []
        if singleValid, let completion = completions.first(where: { $0.row == 0 }) {
          let observed = completion.observedTokenIDs
          let needed = min(samples.count, min(observed.count, max(0, end - tokens.count)))
          let actual = samples.prefix(needed).flatMap { $0.asArray(Int.self) }
          matching = Array(zip(actual, observed).prefix(while: { $0.0 == $0.1 }).map { $0.1 })
          bindJoinedScalarOperands(actual, through: min(submittedEnd, tokens.count + matching.count))
        }
        if let value = entry(ledger: matching, processed: tokens.count + matching.count, width: 1, row: nil) { result.append(value) }
      }
      samples.removeAll()
      return result
    }
    /// Alternate retention-only finalization. The runner supplies only callback-
    /// acknowledged ledgers and a joined/fenced/stateless proof. Successful/UI
    /// publication above keeps its original complete/finished guards unchanged.
    func joinedEntries(owner: PromptCacheOwner, acknowledged: [Completion]) -> [Entry] {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, end > 0, submittedEnd > 0,
        Set(acknowledged.map(\.row)).count == acknowledged.count else { return [] }
      // A cancelled forward may have updated only some layers. End/history are
      // advanced exclusively by the all-owning-layer cohort at update's end.
      // Removing that pending cohort never changes the native working cache.
      removeIncomplete()
      func entry(ledger: [Int], processed: Int, width: Int, row: Int?,
        frozenLocal: [[PrefixKVSpan]]? = nil) -> Entry? {
        let cap = min(submittedEnd, min(end, min(processed, tokens.count + ledger.count)))
        guard cap > 0 else { return nil }
        let ids = Array(tokens.prefix(cap)) + Array(ledger.prefix(max(0, cap - tokens.count)))
        let retained = layouts.indices.map { layer in
          if case .rotating = layouts[layer], let frozenLocal { return frozenLocal[layer] }
          return spans[layer].values.filter { $0.start < cap }
        }
        // A prompt fallback is truly width one. Never relabel a batch tensor.
        if width == 1, row == nil,
          retained.contains(where: { $0.contains(where: { $0.batchWidth != 1 }) }) { return nil }
        let candidate = Entry(id: UUID(), owner: owner, tokens: ids, layouts: layouts,
          spans: retained, geometry: geometry, origin: .prefill,
          batchWidth: width, row: row, history: [], nativeGlobalPrefix: nativeGlobals ? cap : nil,
          nativeCurrentPrefix: nativeGlobals && cap == end ? cap : nil)
        guard let count = candidate.maximumSupportedPrefix(upTo: cap) else { return nil }
        let selectedHistory = PromptPrefixCache.clippedHistory(inheritedHistory + history, through: count).map { segment in
          ForwardSegment(origin: segment.origin, startTokenCount: segment.startTokenCount,
            endTokenCount: segment.endTokenCount, batchWidth: segment.batchWidth,
            row: segment.row ?? (segment.origin == .batchDecode && segment.startTokenCount >= tokens.count ? row : nil),
            promptTokenCount: segment.promptTokenCount, geometry: segment.geometry,
            evaluatedEndTokenCount: segment.evaluatedEndTokenCount, originalInput: segment.originalInput)
        }
        let source = selectedHistory.last
        let sourceRow = independentRow ?? (source?.origin == .batchDecode ? source?.row ?? row : nil)
        return Entry(id: UUID(), owner: owner, tokens: Array(ids.prefix(count)), layouts: layouts,
          spans: retained.map { $0.filter { $0.start < count } }, geometry: geometry,
          origin: source?.origin ?? .prefill, batchWidth: source?.batchWidth ?? width, row: sourceRow,
          history: selectedHistory, nativeGlobalPrefix: nativeGlobals ? count : nil,
          nativeCurrentPrefix: nativeGlobals && count == end ? count : nil,
          nativeProcessedTokenCount: nativeGlobals ? (row == nil ? end : processed) : nil,
          nativeLedgerRow: independentRow ?? row ?? (nativeGlobals ? 0 : nil), joinedAcknowledgedRow: row)
      }
      var result: [Entry] = []
      if !lanes.isEmpty {
        for row in lanes.keys.sorted() {
          guard let lane = lanes[row], let ack = acknowledged.first(where: { $0.row == row }),
            lane.ledger.starts(with: ack.observedTokenIDs) else { continue }
          // Finished rows froze before inert padding. Active rows' known input
          // ledger can cover the final completed cohort after the last callback.
          let processed = lane.finished ? lane.processed : min(end, tokens.count + lane.ledger.count)
          if let value = entry(ledger: ack.observedTokenIDs, processed: processed,
            width: lane.width, row: row, frozenLocal: lane.frozenLocal) { result.append(value) }
        }
      } else if singleValid, let ack = acknowledged.first(where: { $0.row == 0 }) {
        let known = ack.observedTokenIDs
        let needed = min(samples.count, min(known.count, max(0, min(end, submittedEnd) - tokens.count)))
        // Same lazy sample validation as normal publication, after its fence.
        let actual = samples.prefix(needed).flatMap { $0.asArray(Int.self) }
        let matching = Array(zip(actual, known).prefix(while: { $0.0 == $0.1 }).map { $0.1 })
        bindJoinedScalarOperands(actual, through: min(submittedEnd, tokens.count + matching.count))
        if let value = entry(ledger: matching, processed: tokens.count + matching.count,
          width: 1, row: nil) { result.append(value) }
      }
      if result.isEmpty, let prompt = entry(ledger: [], processed: min(end, tokens.count),
        width: 1, row: nil) { result.append(prompt) }
      samples.removeAll()
      return result
    }
  }

  private final class ActiveNativeRecord {
    let owners: [PrefixKVNativeOwnership]
    let rows: [Entry]
    let localLease: PrefixKVDependencyLease
    init(owners: [PrefixKVNativeOwnership], rows: [Entry], localLease: PrefixKVDependencyLease) {
      self.owners = owners; self.rows = rows; self.localLease = localLease
    }
  }
  private var activeNative: ActiveNativeRecord?
  private var nativeCharges: [UUID: UInt64] = [:]
  private var storageEpoch = UUID()
  private struct Stored { let entry: Entry; let insertedAt: UInt64; var touched: UInt64 }
  private struct Backing { let bytes: UInt64; var references: Int }
  private let lock = NSLock()
  private let byteLimit: UInt64
  private let disk: PrefixKVDiskStore
  private var indices: [UUID: PrefixTokenIndex] = [:]
  private var entries: [UUID: Stored] = [:]
  private var backings: [UUID: Backing] = [:]
  // Entries, captures, temporary lookups and hydrated-cache ownership each hold
  // one reference per immutable backing. A lazy graph or evaluated view can
  // outlive its staging descriptor; capture pruning cannot release that lease.
  private var captureLeases: [UUID: Set<UUID>] = [:]
  private var bytes: UInt64 = 0
  private var clock: UInt64 = 0
  private var publicationTicket: UUID?
  private var pendingMissReason: String?
  init(byteLimit: UInt64 = PromptPrefixCache.defaultByteLimit,
    diskByteLimit: UInt64 = 4_294_967_296, temporaryParent: URL? = nil) {
    self.byteLimit = byteLimit; disk = PrefixKVDiskStore(byteLimit: diskByteLimit, temporaryParent: temporaryParent)
  }
  private func spillTicketIsLive(_ ticket: UUID) -> Bool {
    lock.lock(); defer { lock.unlock() }; return publicationTicket == ticket
  }
  func clear(reason: String? = nil) {
    var retiredEntries: [Stored] = []
    lock.lock()
    let retired = activeNative; activeNative = nil
    for id in Array(entries.keys) { remove(id, retiring: &retiredEntries) }
    indices.removeAll(); storageEpoch = UUID()
    // Live capture/lookup/hydration/native owners keep their true charges.
    publicationTicket = nil; pendingMissReason = reason
    lock.unlock(); withExtendedLifetime((retired, retiredEntries)) {}
  }
  /// Explicit close/eviction joins producers first, then clears and awaits the
  /// cleanup already queued by last file owners. Escaped spans remain owned.
  func joinPendingDiskCleanup() async { await disk.joinPending() }
  var retainedAnchorTokenCounts: [Int] {
    lock.lock(); defer { lock.unlock() }; return (entries.values.map { $0.entry.tokens.count } + (activeNative?.rows.map { $0.tokens.count } ?? [])).sorted(by: >)
  }
  var hasAnchors: Bool { lock.lock(); defer { lock.unlock() }; return !entries.isEmpty || activeNative != nil }
  var retainedSnapshotObservations: [SnapshotObservation] {
    lock.lock(); defer { lock.unlock() }
    if let activeNative {
      return activeNative.rows.map { row in
        var observation = row.observation
        observation.nativePhysicalWidth = row.nativePhysicalWidth
        return observation
      }
    }
    return entries.values.sorted { $0.touched > $1.touched }.map { $0.entry.observation }
  }
  /// Metadata for the same hot and published-disk candidate sources searched
  /// by activeChoice. This never hydrates, reads files or evaluates tensors.
  /// Hot-owner observations above keep their separate retention contract.
  var retainedLookupSnapshotObservations: [SnapshotObservation] {
    lock.lock(); defer { lock.unlock() }
    let hot: [SnapshotObservation] = activeNative?.rows.map { row in
      var observation = row.observation
      observation.nativePhysicalWidth = row.nativePhysicalWidth
      return observation
    } ?? []
    let published = entries.values.sorted { $0.touched > $1.touched }
      .filter { $0.entry.spans.flatMap { $0 }.allSatisfy { $0.diskFileID != nil } }
      .map { $0.entry.observation }
    return hot + published
  }
  /// All optimization backings in entries and live leases, including source
  /// buffers still reachable through hydrated working caches. Native working KV
  /// allocations and actual OS/MLX admission remain separately accounted.
  var retainedBytesUpperBound: UInt64 { lock.lock(); defer { lock.unlock() }; return bytes }
  /// Native ownership and parent aliases may exceed staging's 1 GiB quota.
  /// They remain charged until the last actual owner closes, even after clear.
  var retainedNativeBytesUpperBound: UInt64 {
    lock.lock(); defer { lock.unlock() }
    return nativeCharges.values.reduce(0, Self.adding)
  }
  var activeCaptureLeaseCount: Int { lock.lock(); defer { lock.unlock() }; return captureLeases.count }

  struct TextCohortInput {
    let owner: PromptCacheOwner
    let tokens: [Int]
    let joinedBinding: JoinedKVRetentionBinding?
  }
  struct TextCohortRetention {
    let completion: Completion
    let acknowledged: Completion?
    // Nil proof means a successful request. Failed/cancelled requests require
    // the existing joined proof and existing revocable owner authorization.
    let proof: JoinedKVRetentionProof?
    let authorization: JoinedKVRetentionAuthorization?
  }
  /// One existing operation ticket and one actual batch cache. MLX and mutable
  /// delivery metadata stay on its producer; only immutable ready bytes leave it.
  final class TextCohort: @unchecked Sendable {
    let input: LMInput
    private(set) var cache: [any KVCache] = []
    let rows: [Session]
    let parentIDs: [UUID?]
    let cacheLengths: [[Int]]
    let cacheWidths: [Int]
    let maskDigest: String
    let prefill: PrefillParameters
    private let preparedIDs: [[Int]]
    private var operandContext: OperandContext?
    private var decodeForwards = 0
    fileprivate let resources: [PrefixKVNativeOwnership]
    fileprivate let captures: [Capture]
    private var preparing = true
    private var processedByLayer: [Int]
    private var finalized: Set<Int> = []
    private var active: [Bool]
    fileprivate var nextSpillLayer = 0
    private let spill: (TextCohort, Bool) -> (accepted: Bool, quotaRefused: Bool)
    fileprivate init(input: LMInput, rows: [Session], parentIDs: [UUID?],
      cacheLengths: [[Int]], cacheWidths: [Int], maskDigest: String,
      prefill: PrefillParameters, preparedIDs: [[Int]], resources: [PrefixKVNativeOwnership], captures: [Capture],
      spill: @escaping (TextCohort, Bool) -> (accepted: Bool, quotaRefused: Bool)) {
      self.input = input; self.rows = rows; self.parentIDs = parentIDs
      self.cacheLengths = cacheLengths; self.cacheWidths = cacheWidths; self.maskDigest = maskDigest
      self.prefill = prefill; self.preparedIDs = preparedIDs
      self.resources = resources; self.captures = captures; self.spill = spill
      processedByLayer = Array(repeating: 0, count: resources.count)
      active = Array(repeating: true, count: rows.count)
    }
    func bindForwardOperands(model: String, requests: [String]) {
      guard requests.count == rows.count, let first = captures.first,
        let lease = first.makeContextLease(16_384),
        let context = OperandContext(model: model, tokenRows: preparedIDs,
          cached: rows.map(\.cachedTokenCount), requests: requests.map { [$0] },
          histories: rows.map { $0.observation.cachedForwardHistory },
          cacheLengths: cacheLengths, cacheWidths: cacheWidths,
          sharedDecodeRequests: nil, lease: lease) else { return }
      operandContext = context
      for capture in captures { capture.installOperandContext(context) }
    }
    var observedPrefill: PrefillParameters {
      var value = prefill
      guard let context = operandContext else { return value }
      value.observeTextForward = { [weak self] range, width, lengths in
        guard let self, let first = self.captures.first else { return }
        let witness = first.prepareOperand(context.prefill(range, physicalWidth: width, actualLengths: lengths))
        for capture in self.captures { capture.beginOperand(witness) }
      }
      return value
    }
    func observeDecodeOperands(_ sampled: [Int], active: [Bool]) {
      guard let context = operandContext, let first = captures.first else { return }
      let starts = rows.map { $0.fullPromptTokenCount + decodeForwards }
      let witness = first.prepareOperand(context.decode(sampled, logicalStarts: starts, active: active, step: decodeForwards))
      for capture in captures { capture.beginOperand(witness) }
      decodeForwards += 1
    }
    fileprivate func installObservers() {
      cache = resources.enumerated().map { layer, resource in
        PrefixBatchKVCache(layer: layer, ownership: resource, onUpdate: { [weak self] layer, keys, values in
          self?.update(layer: layer, keys: keys, values: values)
        }, onFinalize: { [weak self] layer in self?.didFinalize(layer) })
      }
    }
    private func update(layer: Int, keys: MLXArray, values: MLXArray) {
      precondition(keys.ndim == 4 && values.ndim == 4 && keys.dim(0) == rows.count
        && values.dim(0) == rows.count && keys.dim(2) == values.dim(2))
      if layer == 0 { observeReadySpill() } // previous completed immutable graph, before this update
      let length = keys.dim(2)
      for row in rows.indices {
        let count = preparing
          ? min(length, max(0, rows[row].fullPromptTokenCount - rows[row].cachedTokenCount - processedByLayer[layer]))
          : (active[row] ? length : 0)
        captures[row].updateCohort(layer: layer, count: count, evaluatedCount: length, width: rows.count, row: row)
      }
      if preparing { processedByLayer[layer] += length }
    }
    private func didFinalize(_ layer: Int) {
      finalized.insert(layer)
      if finalized.count == resources.count { preparing = false }
    }
    func finishedPreparation() {
      for capture in captures { capture.completedPreparation() }
      observeReadySpill(finalizing: true)
    }
    func markCacheSubmitted() { for capture in captures { capture.markCacheSubmitted() } }
    @discardableResult func captureLane(_ row: Int, emitted: [Int], stop: Int?, finished: Bool) -> Bool {
      if finished { active[row] = false }
      return captures[row].observeLane(row: row, width: rows.count,
        completion: Completion(row: row, emittedTokenIDs: emitted, stopTokenID: stop), finished: finished)
    }
    @discardableResult func observeReadySpill(finalizing: Bool = false) -> (accepted: Bool, quotaRefused: Bool) {
      spill(self, finalizing)
    }
    func discard() { for capture in captures { capture.discard() } }
  }

  /// Look up every row under the SAME untouched hot record, then consume that
  /// record once. No per-row makeSession may overwrite this operation's ticket.
  func makeTextCohort(_ inputs: [TextCohortInput], prefill: PrefillParameters,
    allowSnapshot: (@Sendable (UInt64) -> Bool)?,
    admit: ([Int]) throws -> Void,
    outputLimits: [Int], makeCache: () throws -> [any KVCache]) throws -> TextCohort {
    guard (2...4).contains(inputs.count), inputs.count == outputLimits.count,
      inputs.allSatisfy({ !$0.tokens.isEmpty && $0.tokens.count <= 16_384
        && ($0.joinedBinding == nil || $0.joinedBinding?.owner == $0.owner) }) else {
      throw BoomError.invalid("Invalid independent text cohort.")
    }
    var choices = inputs.map { activeChoice(owner: $0.owner, tokens: $0.tokens) }
    // This admission never clears the selected source. A ragged miss changes
    // padding, so it is readmitted before any new hydration/merge allocation.
    try admit(choices.map { $0?.2 ?? 0 })
    var selectedOwners: [[PrefixKVNativeOwnership]] = []
    var lengths: [[Int]] = []
    for row in inputs.indices {
      var owners: [PrefixKVNativeOwnership]?
      var excluded: Set<UUID> = [], unavailableFiles: Set<UUID> = []
      while let choice = choices[row] {
        do {
          owners = try choice.1.layouts.indices.map { layer in
            guard let record = choice.0 else {
              let restored = try PrefixKVStorage.hydrate(layout: choice.1.layouts[layer],
                spans: choice.1.spans[layer], prefix: choice.2,
                row: choice.1.nativeLedgerRow ?? choice.1.row ?? 0,
                batchWidth: choice.1.nativePhysicalWidth ?? choice.1.batchWidth)
              return self.makeNativeOwner(restored)
            }
            let source = record.owners[layer]
            switch choice.1.layouts[layer] {
            case .simple:
              return try ActiveNativeKVStorage.selectedGlobal(source, prefix: choice.2,
                row: choice.1.nativeLedgerRow ?? choice.1.row ?? 0, preservingSource: true,
                makeOwner: { self.makeNativeOwner($0, sources: $1, materialized: $2) })
            case .rotating:
              let selected = choice.1.nativeLedgerRow ?? choice.1.row ?? 0
              if PrefixKVStorage.currentRingSupports(source.native, prefix: choice.2, row: selected) {
                if let batch = source.native as? any BatchKVCacheProtocol {
                  return self.makeNativeOwner(try batch.extract(row: selected, through: choice.2),
                    sources: [source], materialized: true)
                }
                let views = try PrefixKVStorage.residentWindowSpans(of: source.native, layer: layer, through: choice.2)
                let restored = try PrefixKVStorage.hydrate(layout: choice.1.layouts[layer],
                  spans: views, prefix: choice.2, row: selected,
                  batchWidth: try ActiveNativeKVStorage.rowWidth([source]))
                return self.makeNativeOwner(restored, sources: [source])
              }
              let leaseID = UUID(), lease = PrefixKVDependencyLease { [weak self] in self?.releaseLease(leaseID) }
              let restored = try PrefixKVStorage.hydrate(layout: choice.1.layouts[layer],
                spans: choice.1.spans[layer], prefix: choice.2, row: choice.1.row ?? 0,
                batchWidth: choice.1.batchWidth,
                onSourceBacking: { [weak self] id, bytes in self?.retainLease(leaseID, id: id, bytes: bytes) })
              return self.makeNativeOwner(restored, dependencies: lease)
            }
          }
          break
        } catch {
          // Disposable optimization data may miss. The old record is untouched;
          // try the next actual supported row, then use the actual cold layout.
          owners = nil
          if let failure = error as? PrefixKVDiskUnavailable { unavailableFiles.insert(failure.fileID) }
          else { excluded.insert(choice.1.id) }
          choices[row] = activeChoice(owner: inputs[row].owner, tokens: inputs[row].tokens,
            excluding: excluded, excludingFiles: unavailableFiles)
          try admit(choices.map { $0?.2 ?? 0 })
        }
      }
      let values = try owners ?? makeCache().map { makeNativeOwner($0) }
      guard !values.isEmpty, values.allSatisfy({ PrefixKVStorage.layout(of: $0.native) != nil }) else {
        throw BoomError.invalid("Independent text requires concrete full-precision caches.")
      }
      selectedOwners.append(values)
      lengths.append(values.map { value in
        if case .rotating(let window, _, _, _) = PrefixKVStorage.layout(of: value.native) {
          return min(value.native.offset, window)
        }
        return value.native.offset
      })
    }
    let layerCount = selectedOwners[0].count
    guard layerCount <= 128, selectedOwners.allSatisfy({ $0.count == layerCount }) else {
      throw BoomError.invalid("Independent rows have incompatible cache layers.")
    }
    try admit(choices.map { $0?.2 ?? 0 })
    let resources = try (0..<layerCount).map { layer in
      let sources = selectedOwners.map { $0[layer] }
      let batch = try mergeBatchKVCache(sources.map(\.native))
      return makeNativeOwner(batch, sources: sources, materialized: true)
    }
    let layouts = resources.compactMap { PrefixKVStorage.layout(of: $0.native) }
    guard layouts.count == layerCount else { throw BoomError.invalid("Unknown independent batch layout.") }
    let ticket = UUID()
    lock.lock()
    for choice in choices.compactMap({ $0 }) {
      guard storageEpoch == choice.3,
        choice.0.map({ activeNative === $0 }) ?? (entries[choice.1.id] != nil) else {
        lock.unlock(); throw BoomError.stale("The actual cohort cache source changed before transfer.")
      }
    }
    let retired = activeNative; activeNative = nil
    // Existing disk-only history remains indexed under its own namespaces.
    publicationTicket = ticket
    lock.unlock()
    let counts = choices.map { $0?.2 ?? 0 }
    let suffixes = inputs.indices.map { Array(inputs[$0].tokens.dropFirst(counts[$0])) }
    let width = suffixes.map(\.count).max()!
    let masks = suffixes.flatMap { Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: width - $0.count) }
    let tokenIDs = suffixes.flatMap { $0.map(Int32.init) + Array(repeating: Int32(0), count: width - $0.count) }
    let input = LMInput(text: .init(tokens: MLXArray(tokenIDs).reshaped([inputs.count, width]),
      mask: MLXArray(masks).reshaped([inputs.count, width])))
    let commonGeometry = PromptCacheGeometry(promptTokens: width, prefill: prefill)
    var captures: [Capture] = [], sessions: [Session] = []
    for row in inputs.indices {
      let leaseID = UUID(), inherited = choices[row]?.1
      let capture = Capture(layouts: layouts, tokens: inputs[row].tokens, cachedCount: counts[row],
        geometry: PromptCacheGeometry(promptTokens: inputs[row].tokens.count, prefill: prefill),
        suffixGeometry: commonGeometry, inherited: inherited,
        reserve: { [weak self] bytes, check in self?.reserve(incoming: bytes, epoch: ticket,
          allow: check ? allowSnapshot : nil) ?? .staleTicket },
        retainBacking: { [weak self] id, bytes in self?.retainLease(leaseID, id: id, bytes: bytes) },
        releaseBacking: { [weak self] id in self?.releaseLeaseBacking(leaseID, id: id) },
        closeLease: { [weak self] in self?.releaseLease(leaseID) },
        retainRawBacking: { [weak self] lease, id, bytes in self?.retainLease(lease, id: id, bytes: bytes) },
        releaseRawBacking: { [self] lease, id in releaseLeaseBacking(lease, id: id) },
        closeRawLease: { [self] lease in releaseLease(lease) }, disk: disk,
        spillIsLive: { [weak self] in self?.spillTicketIsLive(ticket) ?? false },
        reclaimDiskEntry: { [weak self] in self?.retireOldestDiskEntry(epoch: ticket) ?? false },
        nativeGlobals: true,
        independentRow: row, independentWidth: inputs.count,
        makeOperandWitness: { [weak self] in self?.makeOperandWitness($0, epoch: ticket) },
        makeContextLease: { [weak self] in self?.makeMetadataLease($0, epoch: ticket) })
      let history = inherited.map { Self.clippedHistory($0.history, through: counts[row]) } ?? []
      let observation = Observation(algorithm: Self.activeAlgorithm, originalGeometry: capture.geometry,
        suffixGeometry: commonGeometry, fullPromptTokens: inputs[row].tokens.count,
        cachedPromptTokens: counts[row], suffixPromptTokens: suffixes[row].count,
        missReason: counts[row] > 0 ? nil : "no_active_supported_prefix",
        cachedOrigin: history.last?.origin, cachedBatchWidth: inherited?.batchWidth, cachedRow: inherited?.row,
        cachedForwardHistory: history, retainedBytes: retainedBytesUpperBound, byteLimit: byteLimit,
        cachedJoinedRetentionProvenance: inherited?.joinedRetentionProvenance,
        nativeTensorBytes: retainedNativeBytesUpperBound, cachedNativePhysicalWidth: inherited?.nativePhysicalWidth)
      sessions.append(Session(input: LMInput(tokens: MLXArray(suffixes[row])), cache: resources.map(\.native),
        prefill: prefill, cachedTokenCount: counts[row], fullPromptTokenCount: inputs[row].tokens.count,
        preservesChunkBoundaries: false, observation: observation, owner: inputs[row].owner, epoch: ticket,
        joinedRetentionBinding: inputs[row].joinedBinding, capture: capture, nativeOwners: resources))
      captures.append(capture)
    }
    let cohort = TextCohort(input: input, rows: sessions, parentIDs: choices.map { $0?.1.id },
      cacheLengths: lengths, cacheWidths: (0..<layerCount).map { layer in lengths.map { $0[layer] }.max()! },
      maskDigest: Digest.sha256(try JSONEncoder().encode(masks)), prefill: prefill, preparedIDs: inputs.map(\.tokens),
      resources: resources, captures: captures, spill: { [weak self] value, finalizing in
        self?.observeTextCohortSpill(value, ticket: ticket, allowSnapshot: allowSnapshot,
          finalizing: finalizing) ?? (false, false)
      })
    cohort.installObservers()
    lock.lock()
    if publicationTicket == ticket {
      for choice in choices.compactMap({ $0 }) where choice.0 == nil {
        if var stored = entries[choice.1.id] {
          clock &+= 1; stored.touched = clock; entries[choice.1.id] = stored
        }
      }
    }
    lock.unlock(); withExtendedLifetime(retired) {}
    return cohort
  }

  private func observeTextCohortSpill(_ cohort: TextCohort, ticket: UUID,
    allowSnapshot: (@Sendable (UInt64) -> Bool)?, finalizing: Bool
  ) -> (accepted: Bool, quotaRefused: Bool) {
    guard spillTicketIsLive(ticket), disk.canSubmit else { return (false, false) }
    // Acquire each full physical parent once, even when several rows/ring
    // pieces borrow it. Only ready immutable storage goes to the file worker.
    let leaseID = UUID()
    func admitParent(_ allocation: Int) -> (@Sendable () -> Void)? {
      let bytes = UInt64(allocation)
      guard reserve(incoming: bytes, epoch: ticket, allow: allowSnapshot) == .admitted else { return nil }
      let id = UUID(); retainLease(leaseID, id: id, bytes: bytes)
      return { [self] in releaseLeaseBacking(leaseID, id: id) }
    }
    var selected: [(PrefixKVDiskStore.ReadySpan, Int)] = []
    var attempted: Set<Int> = []
    for index in cohort.resources.indices {
      let layer = (cohort.nextSpillLayer + index) % cohort.resources.count
      let native = cohort.resources[layer].native
      guard let batch = native as? any BatchKVCacheProtocol,
        let metadata = PrefixKVStorage.readyBatchPositions(batch) else { continue }
      var wanted: [(Int, Int, Range<Int>)] = []
      for row in cohort.rows.indices {
        guard let after = cohort.captures[row].cohortSpillStart(layer: layer,
          actualPosition: metadata.positions[row], finalizing: finalizing) else { continue }
        let end = cohort.captures[row].coveredEnd
        attempted.insert(row)
        if let rotating = batch as? BatchRotatingKVCache {
          guard let ranges = try? rotating.residentRanges(position: metadata.positions[row],
            padding: metadata.padding[row], after: after, through: end) else { continue }
          wanted += ranges.map { (row, $0.0, $0.1) }
        } else if after < end {
          let padding = metadata.padding[row]
          guard padding >= 0 else { continue }
          wanted.append((row, after, (padding + after)..<(padding + end)))
        }
      }
      guard !wanted.isEmpty else { continue }
      let arrays = batch.innerState().filter { $0.ndim == 4 }
      guard arrays.count == 2,
        wanted.allSatisfy({ $0.2.upperBound <= arrays[0].dim(2) && $0.2.upperBound <= arrays[1].dim(2) }),
        let keys = arrays[0].readyBuffer(admitting: admitParent),
        let values = arrays[1].readyBuffer(admitting: admitParent) else {
        if !selected.isEmpty { cohort.nextSpillLayer = layer; break }
        continue
      }
      let pieces = wanted.compactMap { row, start, physical -> (PrefixKVDiskStore.ReadySpan, Int)? in
        (try? PrefixKVDiskStore.ReadySpan(start: start, layer: layer, keys: keys, values: values,
          positions: physical, rows: row..<(row + 1))).map { ($0, row) }
      }
      if !selected.isEmpty, !disk.fitsEmpty(selected.map { $0.0 } + pieces.map { $0.0 }) {
        cohort.nextSpillLayer = layer; break
      }
      selected += pieces
    }
    guard !selected.isEmpty else { return (false, false) }
    if let last = selected.last { cohort.nextSpillLayer = (last.0.layer + 1) % cohort.resources.count }
    // The existing store writes files in sorted layer order. Keep row/interval
    // correspondence explicit instead of zipping results to a rotated input.
    selected.sort { a, b in
      if a.0.layer != b.0.layer { return a.0.layer < b.0.layer }
      if a.1 != b.1 { return a.1 < b.1 }
      return a.0.start < b.0.start
    }
    let ready = selected.map { $0.0 }, rows = selected.map { $0.1 }, captures = cohort.captures
    let before = disk.observation.quotaMisses
    let accepted = disk.submit(ready, isLive: { [weak self] in
      self?.spillTicketIsLive(ticket) == true && captures.contains { $0.spillStillLive() }
    }, completed: { values in
      for row in captures.indices {
        let own = values.map { values in zip(rows, values).compactMap { $0.0 == row ? $0.1 : nil } }
        if own?.isEmpty == false { captures[row].acceptCohortSpill(own) }
      }
    })
    for row in attempted { captures[row].noteCohortSpill(accepted: accepted) }
    return (accepted, !accepted && disk.observation.quotaMisses != before && disk.fitsEmpty(ready))
  }
  func joinTextCohortSpill(_ cohort: TextCohort, cancelled: Bool) async {
    if cancelled { for capture in cohort.captures { capture.cancelSpill() } }
    await disk.joinPending()
    guard !cancelled, let ticket = cohort.rows.first?.epoch else { return }
    var groups = 0, retirements = 0
    while groups < cohort.resources.count {
      let result = cohort.observeReadySpill(finalizing: true)
      if result.accepted { groups += 1; await disk.joinPending(); continue }
      guard result.quotaRefused else { break }
      if retirements < 128, retireOldestDiskEntry(epoch: ticket) { retirements += 1 }
      else {
        var shed = false
        for capture in cohort.captures where capture.shedOptionalDiskCoverage() { shed = true }
        if !shed { break }
      }
      // Producer/fence has already joined. Only completed utility unlinks
      // credit disk quota; required/borrowed spans keep their actual ownership.
      await disk.joinPending()
    }
  }
  /// One final installation into the existing hot slot. A failed row may retain
  /// only its acknowledged joined prefix under its original owner permission;
  /// it cannot cancel, publish or mint another row's receiving result.
  @discardableResult func publishTextCohort(_ cohort: TextCohort,
    retention: [TextCohortRetention?]) -> Bool {
    var retiredEntries: [Stored] = []
    defer { withExtendedLifetime(retiredEntries) {} }
    guard retention.count == cohort.rows.count, let epoch = cohort.rows.first?.epoch else { return false }
    lock.lock(); let current = publicationTicket == epoch; lock.unlock()
    guard current else { return false }
    var candidates: [(Entry, TextCohortRetention, JoinedKVRetentionBinding?, Bool)] = []
    for row in cohort.rows.indices {
      guard let disposition = retention[row], let owner = cohort.rows[row].owner,
        disposition.completion.row == row, cohort.captures[row].workingGraphWasSubmitted else { continue }
      let capture = cohort.captures[row]
      let values: [Entry]
      if let proof = disposition.proof {
        guard proof.permitsRetention, let authorization = disposition.authorization,
          let binding = cohort.rows[row].joinedRetentionBinding, authorization.binding == binding,
          authorization.withAuthorization(binding: binding, { true }) == true else { continue }
        values = capture.joinedEntries(owner: owner, acknowledged: disposition.acknowledged.map { [$0] } ?? [])
      } else {
        values = capture.entries(owner: owner, completions: [disposition.completion])
      }
      for original in values {
        var value = original
        let actualRow = value.nativeLedgerRow ?? value.row ?? row
        guard actualRow == row else { continue }
        let hot = (disposition.proof?.termination != .constructorCancelled || capture.permitsJoinedHotState)
          && cohort.resources.indices.allSatisfy { layer in
            let native = cohort.resources[layer].native
            guard PrefixKVStorage.layout(of: native) == value.layouts[layer],
              let batch = native as? any BatchKVCacheProtocol,
              let positions = PrefixKVStorage.readyBatchPositions(batch),
              positions.positions[row] >= value.tokens.count else { return false }
            return true
          }
        // Physical forward width remains known when only its joined disk
        // coverage survives. It is independent of current-hot eligibility.
        value.nativePhysicalWidth = cohort.rows.count
        if hot, !Self.hasCurrentHot(value, owners: cohort.resources) { value.nativeCurrentPrefix = nil }
        value.nativeRowReceipt = NativeRowReceipt(completedTokenCount: capture.coveredEnd,
          submittedTokenCount: capture.submittedTokenCount,
          processedTokenCount: value.nativeProcessedTokenCount ?? value.tokens.count,
          deliveredGeneratedTokenCount: disposition.completion.emittedTokenIDs.count,
          acknowledgedGeneratedTokenCount: disposition.acknowledged?.observedTokenIDs.count ?? 0,
          observedStopTokenID: disposition.completion.stopTokenID)
        if let proof = disposition.proof, let binding = cohort.rows[row].joinedRetentionBinding {
          value.joinedRetentionProvenance = JoinedKVRetentionProvenance(binding: binding,
            termination: proof.termination, promptTokenCount: cohort.rows[row].fullPromptTokenCount,
            representedTokenCount: value.tokens.count, lastCompleteCohortTokenCount: capture.coveredEnd,
            lastSubmittedCohortTokenCount: capture.submittedTokenCount,
            acknowledgedGeneratedTokenCount: disposition.acknowledged?.observedTokenIDs.count ?? 0,
            representedGeneratedTokenCount: max(0, value.tokens.count - cohort.rows[row].fullPromptTokenCount))
        }
        candidates.append((value, disposition, cohort.rows[row].joinedRetentionBinding,
          hot && value.supports(value.tokens.count)))
      }
    }
    let leaseID = UUID(), localLease = PrefixKVDependencyLease { [weak self] in self?.releaseLease(leaseID) }
    for candidate in candidates where candidate.3 { for span in candidate.0.spans.flatMap({ $0 }) {
      retainLease(leaseID, id: span.id, bytes: span.backingBytesUpperBound)
    } }
    lock.lock()
    guard publicationTicket == epoch else { lock.unlock(); return false }
    var rows: [Entry] = [], diskAdded = false
    for (value, disposition, binding, hot) in candidates {
      let install = {
        diskAdded = self.retainDiskRows([value], retiring: &retiredEntries) || diskAdded // strips ALL native coverage witnesses
        if hot { rows.append(value) }
      }
      if let authorization = disposition.authorization, let binding {
        _ = authorization.withAuthorization(binding: binding, install)
      } else { install() }
    }
    let retired = activeNative
    activeNative = rows.isEmpty ? nil : ActiveNativeRecord(owners: cohort.resources, rows: rows, localLease: localLease)
    publicationTicket = nil
    lock.unlock(); withExtendedLifetime(retired) {}
    for cache in cohort.cache { (cache as? PrefixBatchKVCache)?.sealForJoinedTransfer() }
    // An unsafe/unsubmitted future stays owned until its real caller joins it;
    // disk-only disposition must never evaluate it to grant a native transfer.
    if !rows.isEmpty {
      for resource in cohort.resources { resource.releaseMaterializedSourcesAfterJoinedSubmission() }
    }
    return !rows.isEmpty || diskAdded
  }

  func makeSession(owner: PromptCacheOwner?, input: LMInput, promptTokenIDs: [Int],
    prefill: PrefillParameters, state: LMOutput.State? = nil,
    allowSnapshot: (@Sendable (UInt64) -> Bool)? = nil,
    joinedRetentionBinding: JoinedKVRetentionBinding? = nil,
    useActiveNative: Bool = false, outputTokens: Int = 1, batchWidth: Int = 1,
    admitNative: ((ActiveNativeKVAdmissionPlan?) throws -> Void)? = nil,
    makeCache: () throws -> [KVCache]) throws -> Session {
    guard joinedRetentionBinding == nil || joinedRetentionBinding?.owner == owner else {
      throw BoomError.invalid("Joined retention owner differs from the admitted request.")
    }
    guard input.text.tokens.size == promptTokenIDs.count, !promptTokenIDs.isEmpty else {
      throw BoomError.invalid("Prepared token count changed before prefix-cache admission.")
    }
    let geometry = PromptCacheGeometry(promptTokens: promptTokenIDs.count, prefill: prefill)
    let oneSequence = input.text.tokens.ndim == 1 || input.text.tokens.ndim == 2 && input.text.tokens.dim(0) == 1
    let textOnly = oneSequence && input.text.mask == nil && input.image == nil
      && input.video == nil && input.audio == nil && state == nil
    if useActiveNative, owner != nil, textOnly {
      return try makeNativeSession(owner: owner!, input: input, promptTokenIDs: promptTokenIDs,
        prefill: prefill, allowSnapshot: allowSnapshot, joinedRetentionBinding: joinedRetentionBinding,
        outputTokens: outputTokens, batchWidth: batchWidth, admitNative: admitNative, makeCache: makeCache)
    }
    // Non-stateless/masked/media or unowned input executes normally but cannot
    // acquire another reusable RAM archive. Only the admitted native text path
    // above owns hot state and disk-backed history.
    retireNativeOwned()
    let ticket = UUID()
    lock.lock(); publicationTicket = ticket
    let emptyReason = pendingMissReason; pendingMissReason = nil; lock.unlock()
    let cache = try makeCache()
    let reason = !textOnly ? "non_stateless_text" : owner == nil ? "owner_unavailable"
      : emptyReason ?? "native_cache_path_unverified"
    return Session(input: input, cache: cache, prefill: prefill, cachedTokenCount: 0,
      fullPromptTokenCount: promptTokenIDs.count, preservesChunkBoundaries: true,
      observation: Observation(algorithm: Self.activeAlgorithm, originalGeometry: geometry,
        suffixGeometry: geometry, fullPromptTokens: promptTokenIDs.count, cachedPromptTokens: 0,
        suffixPromptTokens: promptTokenIDs.count, missReason: reason, cachedOrigin: nil,
        cachedBatchWidth: nil, cachedRow: nil, cachedForwardHistory: [],
        retainedBytes: retainedBytesUpperBound, byteLimit: byteLimit),
      owner: owner, epoch: ticket, joinedRetentionBinding: joinedRetentionBinding, capture: nil)
  }
  private func makeNativeOwner(_ base: any KVCache,
    sources: [PrefixKVNativeOwnership] = [], materialized: Bool = false,
    dependencies: PrefixKVDependencyLease? = nil) -> PrefixKVNativeOwnership {
    PrefixKVNativeOwnership(native: base, dependencyLease: dependencies,
      sources: materialized ? [] : sources, materializedSources: materialized ? sources : [],
      changed: { [weak self] id, amount in
        guard let self else { return }; self.lock.lock(); self.nativeCharges[id] = amount; self.lock.unlock()
      }, closed: { [weak self] id in
        guard let self else { return }; self.lock.lock(); self.nativeCharges.removeValue(forKey: id); self.lock.unlock()
      })
  }
  private func activeChoice(owner: PromptCacheOwner, tokens: [Int], excluding: Set<UUID> = [],
    excludingFiles: Set<UUID> = [])
    -> (ActiveNativeRecord?, Entry, Int, UUID)? {
    lock.lock(); defer { lock.unlock() }
    let record = activeNative
    // The radix index already proves each disk candidate's exact prefix under
    // this same lock. Compare only the unindexed hot rows.
    var candidates: [(Entry, ActiveNativeRecord?, Int)] = []
    let limit = max(0, tokens.count - 1)
    if let record {
      for row in record.rows where row.owner.namespace == owner.namespace && !excluding.contains(row.id) {
        let bound = min(limit, row.tokens.count)
        var matched = 0
        while matched < bound, tokens[matched] == row.tokens[matched] { matched += 1 }
        candidates.append((row, record, matched))
      }
    }
    if let index = indices[owner.namespace] {
      for match in index.matches(tokens: tokens, maximumCount: tokens.count - 1) {
        if let entry = entries[match.id]?.entry,
          entry.spans.flatMap({ $0 }).allSatisfy({ $0.diskFileID != nil }) {
          candidates.append((entry, nil, match.tokenCount))
        }
      }
    }
    var selected: Entry?, selectedRecord: ActiveNativeRecord?, longest = 0
    for (original, source, cap) in candidates where original.owner.namespace == owner.namespace && !excluding.contains(original.id) {
      var row = original
      if source == nil || !Self.hasCurrentHot(row, owners: source!.owners) { row.nativeCurrentPrefix = nil }
      if !excludingFiles.isEmpty {
        row.spans = row.spans.map { $0.filter { span in
          span.diskFileID.map { !excludingFiles.contains($0) } ?? true
        } }
      }
      if let source, cap > 0 {
        // Probe the sole joined hot owner's actual coverage. No resident view
        // is archived; an earlier covered prefix is hydrated after admission.
        row.nativeCurrentPrefix = cap
        if !Self.hasCurrentHot(row, owners: source.owners) {
          // Across an overwritten-tail gap, only the pinned prefix can remain.
          let pinned = row.layouts.compactMap { layout -> Int? in
            if case .rotating(_, let keep, _, _) = layout { return keep }
            return nil
          }.min() ?? 0
          row.nativeCurrentPrefix = min(cap, pinned)
          if !Self.hasCurrentHot(row, owners: source.owners) { row.nativeCurrentPrefix = nil }
        }
      }
      guard let count = row.maximumSupportedPrefix(upTo: cap),
        count > longest else { continue }
      selected = row; selectedRecord = source; longest = count
    }
    guard let selected else { return nil }
    return (selectedRecord, selected, longest, storageEpoch)
  }
  private static func hasCurrentHot(_ row: Entry, owners: [PrefixKVNativeOwnership]) -> Bool {
    guard let prefix = row.nativeCurrentPrefix, prefix > 0, prefix <= row.tokens.count,
      owners.count == row.layouts.count, let width = try? ActiveNativeKVStorage.rowWidth(owners) else { return false }
    let selected = row.nativeLedgerRow ?? row.row ?? 0
    guard selected >= 0, selected < width else { return false }
    return owners.indices.allSatisfy { layer in
      let native = owners[layer].native
      if let batch = native as? any BatchKVCacheProtocol {
        guard let positions = PrefixKVStorage.readyBatchPositions(batch), selected < positions.positions.count,
          positions.positions[selected] >= prefix else { return false }
      } else if native.offset < prefix { return false }
      guard PrefixKVStorage.layout(of: native) == row.layouts[layer] else { return false }
      if case .rotating = row.layouts[layer] {
        return PrefixKVStorage.currentRingSupports(native, prefix: prefix, row: selected)
      }
      return true
    }
  }
  /// Read-only sizing for source/context preflight. It never consumes a slot,
  /// clears native ownership, or fabricates a prefix from missing local rows.
  func nativeAdmissionPlan(owner: PromptCacheOwner?, tokens: [Int], prefill: PrefillParameters,
    outputTokens: Int, batchWidth: Int) throws -> ActiveNativeKVAdmissionPlan? {
    guard let owner, let (record, row, count, _) = activeChoice(owner: owner, tokens: tokens) else { return nil }
    let suffix = Self.nativeSuffixPrefill(history: Self.clippedHistory(row.history, through: count),
      count: count, prompt: tokens.count, prefill: prefill)
    if let record {
      return try ActiveNativeKVStorage.plan(owners: record.owners, layouts: row.layouts,
        prefix: count, prompt: tokens.count, output: outputTokens, width: batchWidth,
        row: row.nativeLedgerRow ?? row.row, prefill: suffix)
    }
    return try ActiveNativeKVStorage.diskPlan(layouts: row.layouts, spans: row.spans,
      prefix: count, prompt: tokens.count, output: outputTokens, width: batchWidth, prefill: suffix)
  }
  /// This returns only after the retired record's real strong leases leave this
  /// scope. Any escaped working alias still owns/charges its source; admission
  /// rereads measured OS/MLX usage and never receives an estimated release credit.
  private func retireNativeOwned() {
    lock.lock(); let retired = activeNative; activeNative = nil; lock.unlock()
    withExtendedLifetime(retired) {}
  }
  private func makeNativeSession(owner: PromptCacheOwner, input: LMInput, promptTokenIDs: [Int],
    prefill: PrefillParameters, allowSnapshot: (@Sendable (UInt64) -> Bool)?,
    joinedRetentionBinding: JoinedKVRetentionBinding?, outputTokens: Int, batchWidth: Int,
    admitNative: ((ActiveNativeKVAdmissionPlan?) throws -> Void)?,
    makeCache: () throws -> [KVCache]) throws -> Session {
    var chosen = activeChoice(owner: owner, tokens: promptTokenIDs)
    var admissionRefused = false, diskUnavailable = false
    var excluded: Set<UUID> = [], unavailableFiles: Set<UUID> = []
    var preparedLocals: [Int: PrefixKVNativeOwnership] = [:]
    while let candidate = chosen {
      let suffix = Self.nativeSuffixPrefill(history: Self.clippedHistory(candidate.1.history, through: candidate.2),
        count: candidate.2, prompt: promptTokenIDs.count, prefill: prefill)
      let plan: ActiveNativeKVAdmissionPlan
      if let record = candidate.0 {
        plan = try ActiveNativeKVStorage.plan(owners: record.owners, layouts: candidate.1.layouts,
          prefix: candidate.2, prompt: promptTokenIDs.count, output: outputTokens,
          width: batchWidth, row: candidate.1.nativeLedgerRow ?? candidate.1.row, prefill: suffix)
      } else {
        plan = try ActiveNativeKVStorage.diskPlan(layouts: candidate.1.layouts, spans: candidate.1.spans,
          prefix: candidate.2, prompt: promptTokenIDs.count, output: outputTokens, width: batchWidth, prefill: suffix)
      }
      do { try admitNative?(plan) }
      catch BoomError.budget {
        chosen = nil; admissionRefused = true; break
      }
      // File reads/hydration happen on the existing inference executor BEFORE
      // decode or destructive source transfer. No read IO is added to a token.
      do {
        for layer in candidate.1.layouts.indices {
          guard let record = candidate.0 else {
            let restored = try PrefixKVStorage.hydrate(layout: candidate.1.layouts[layer],
              spans: candidate.1.spans[layer], prefix: candidate.2,
              row: candidate.1.nativeLedgerRow ?? candidate.1.row ?? 0,
              batchWidth: candidate.1.nativePhysicalWidth ?? candidate.1.batchWidth)
            preparedLocals[layer] = makeNativeOwner(restored)
            continue
          }
          guard case .rotating = candidate.1.layouts[layer] else { continue }
          let source = record.owners[layer], native = source.native
          let direct = native.innerState().allSatisfy { $0.dim(0) == 1 }
            && (native.offset == candidate.2 || native.isTrimmable && native.offset >= candidate.2)
          if direct { continue }
          if candidate.1.nativeCurrentPrefix == candidate.2 {
            let row = candidate.1.nativeLedgerRow ?? candidate.1.row ?? 0
            if let batch = native as? any BatchKVCacheProtocol {
              let restored = try batch.extract(row: row, through: candidate.2)
              preparedLocals[layer] = makeNativeOwner(restored, sources: [source], materialized: true)
              continue
            }
            // Borrow the current ring ONLY after warm admission, for this
            // selected lookup. No row view is retained in historical metadata.
            let borrowed = try PrefixKVStorage.residentWindowSpans(of: native, layer: layer, through: candidate.2)
            let restored = try PrefixKVStorage.hydrate(layout: candidate.1.layouts[layer],
              spans: borrowed, prefix: candidate.2, row: candidate.1.nativeLedgerRow ?? candidate.1.row ?? 0,
              batchWidth: candidate.1.nativePhysicalWidth ?? candidate.1.batchWidth, copyResidentPieces: true)
            preparedLocals[layer] = makeNativeOwner(restored, sources: [source], materialized: true)
            continue
          }
          let dependencyID = UUID()
          let lease = PrefixKVDependencyLease { [weak self] in self?.releaseLease(dependencyID) }
          let restored = try PrefixKVStorage.hydrate(layout: candidate.1.layouts[layer],
            spans: candidate.1.spans[layer], prefix: candidate.2,
            row: candidate.1.row ?? 0, batchWidth: candidate.1.batchWidth,
            onSourceBacking: { [weak self] id, bytes in self?.retainLease(dependencyID, id: id, bytes: bytes) })
          preparedLocals[layer] = makeNativeOwner(restored, dependencies: lease)
        }
        break
      } catch {
        // Keep the greatest feasible prefix from surviving files/actual rows.
        // No cache object has yet been trimmed, split or consumed.
        preparedLocals.removeAll(); diskUnavailable = true
        if let failed = error as? PrefixKVDiskUnavailable { unavailableFiles.insert(failed.fileID) }
        else { excluded.insert(candidate.1.id) }
        chosen = activeChoice(owner: owner, tokens: promptTokenIDs,
          excluding: excluded, excludingFiles: unavailableFiles)
      }
    }
    if chosen == nil {
      preparedLocals.removeAll(); retireNativeOwned()
      try admitNative?(nil) // actual OS/MLX remeasurement, never release credit
    }
    let ticket = UUID(), geometry = PromptCacheGeometry(promptTokens: promptTokenIDs.count, prefill: prefill)
    lock.lock()
    if let value = chosen {
      guard storageEpoch == value.3,
        value.0.map({ activeNative === $0 }) ?? (entries[value.1.id] != nil) else {
        lock.unlock(); throw BoomError.stale("The selected native/disk cache was invalidated during admission.")
      }
    }
    let retired = activeNative; activeNative = nil
    // Historical entries own only disk descriptors; the sole hot native owner
    // moves independently. Its unrelated namespaces never become query input.
    publicationTicket = ticket
    let emptyReason = pendingMissReason; pendingMissReason = nil
    lock.unlock()
    let selected = chosen?.1, count = chosen?.2 ?? 0
    let sourceOwners = chosen?.0?.owners ?? []
    var owners: [PrefixKVNativeOwnership] = []
    if let selected {
      let trace = PerformanceTrace.begin("Model.ActiveNativeKVTransfer")
      defer { PerformanceTrace.end("Model.ActiveNativeKVTransfer", trace) }
      for layer in selected.layouts.indices {
        if chosen?.0 == nil {
          guard let restored = preparedLocals.removeValue(forKey: layer) else {
            throw BoomError.invalid("Admitted disk KV disappeared before transfer.")
          }
          owners.append(restored); continue
        }
        let source = sourceOwners[layer]
        switch selected.layouts[layer] {
        case .simple:
          owners.append(try ActiveNativeKVStorage.selectedGlobal(source, prefix: count,
            row: selected.nativeLedgerRow ?? selected.row ?? 0,
            makeOwner: { self.makeNativeOwner($0, sources: $1, materialized: $2) }))
        case .rotating:
          let native = source.native
          let direct = native.innerState().allSatisfy { $0.dim(0) == 1 }
            && (native.offset == count || native.isTrimmable && native.offset >= count)
          if direct {
            _ = native.trim(native.offset - count)
            guard native.offset == count else { throw BoomError.invalid("Native local transfer changed its offset.") }
            owners.append(source)
          } else {
            guard let restored = preparedLocals.removeValue(forKey: layer) else {
              throw BoomError.invalid("Admitted local KV disappeared before transfer.")
            }
            owners.append(restored)
          }
        }
      }
    } else {
      let native = try makeCache()
      guard !native.isEmpty, native.allSatisfy({ PrefixKVStorage.layout(of: $0) != nil }) else {
        throw BoomError.invalid("The active native path requires known concrete full-precision caches.")
      }
      owners = native.map { makeNativeOwner($0) }
    }
    let layouts = try owners.map { owner -> PrefixKVStorage.Layout in
      guard let value = PrefixKVStorage.layout(of: owner.native) else { throw BoomError.invalid("Unsupported active native cache layout.") }
      return value
    }
    let narrowed: LMInput
    if count > 0 {
      let ids = input.text.tokens
      narrowed = LMInput(tokens: ids.ndim == 1 ? ids[count...] : ids[0..., count...])
    } else { narrowed = input }
    let history = selected.map { Self.clippedHistory($0.history, through: count) } ?? []
    let preserves = Self.preservesGeometry(history, count: count, prompt: promptTokenIDs.count, prefill: prefill)
    var suffix = Self.nativeSuffixPrefill(history: history, count: count, prompt: promptTokenIDs.count, prefill: prefill)
    let suffixGeometry = PromptCacheGeometry(promptTokens: promptTokenIDs.count - count, prefill: suffix)
    let capture = Capture(layouts: layouts, tokens: promptTokenIDs, cachedCount: count,
      geometry: geometry, suffixGeometry: suffixGeometry, inherited: selected,
      reserve: { [weak self] incoming, check in
        self?.reserve(incoming: incoming, epoch: ticket, allow: check ? allowSnapshot : nil) ?? .staleTicket
      }, retainBacking: { [weak self] id, bytes in self?.retainLease(ticket, id: id, bytes: bytes) },
      releaseBacking: { [weak self] id in self?.releaseLeaseBacking(ticket, id: id) },
      closeLease: { [weak self] in self?.releaseLease(ticket) },
      retainRawBacking: { [weak self] lease, id, bytes in self?.retainLease(lease, id: id, bytes: bytes) },
      releaseRawBacking: { [weak self] lease, id in self?.releaseLeaseBacking(lease, id: id) },
      closeRawLease: { [self] lease in releaseLease(lease) }, disk: disk,
      spillIsLive: { [weak self] in self?.spillTicketIsLive(ticket) ?? false },
      reclaimDiskEntry: { [weak self] in self?.retireOldestDiskEntry(epoch: ticket) ?? false }, nativeGlobals: true,
      makeOperandWitness: { [weak self] in self?.makeOperandWitness($0, epoch: ticket) },
        makeContextLease: { [weak self] in self?.makeMetadataLease($0, epoch: ticket) })
    let cache: [KVCache] = owners.enumerated().map { layer, resource in
      PrefixKVCache(layer: layer, ownership: resource) {
        if $0 == 0 { capture.observeReadySpill(owners.map { $0.native }) }
        capture.update(layer: $0, offset: $1, keys: $2, values: $3)
      }
    }
    capture.primaryCache = cache.first as? PrefixKVCache
    let sourceProgress = prefill.progress
    suffix.progress = { processed, total in
      capture.progress(processed: processed, total: total); sourceProgress?(count + processed, count + total)
    }
    let observation = Observation(algorithm: Self.activeAlgorithm, originalGeometry: geometry,
      suffixGeometry: suffixGeometry, fullPromptTokens: promptTokenIDs.count,
      cachedPromptTokens: count, suffixPromptTokens: promptTokenIDs.count - count,
      missReason: count > 0 ? nil : diskUnavailable ? "disk_span_unavailable"
        : admissionRefused ? "native_admission_refused" : emptyReason ?? "no_active_supported_prefix",
      cachedOrigin: history.last?.origin, cachedBatchWidth: selected?.batchWidth,
      cachedRow: selected?.row, cachedForwardHistory: history, retainedBytes: retainedBytesUpperBound,
      byteLimit: byteLimit, cachedJoinedRetentionProvenance: selected?.joinedRetentionProvenance,
      nativeTensorBytes: retainedNativeBytesUpperBound, cachedNativePhysicalWidth: selected?.nativePhysicalWidth,
      unavailableDiskBackings: unavailableFiles.count,
      cachedCurrentHotPrefix: selected?.nativeCurrentPrefix == count)
    if let chosen, chosen.0 == nil {
      lock.lock()
      if publicationTicket == ticket, var stored = entries[chosen.1.id] {
        clock &+= 1; stored.touched = clock; entries[chosen.1.id] = stored
      }
      lock.unlock()
    }
    // Capture now owns inherited pages; previous slot ownership leaves only
    // true working/materialization aliases. Its descriptors never become an archive.
    withExtendedLifetime(retired) {}
    return Session(input: narrowed, cache: cache, prefill: suffix, cachedTokenCount: count,
      fullPromptTokenCount: promptTokenIDs.count, preservesChunkBoundaries: preserves,
      observation: observation, owner: owner, epoch: ticket, joinedRetentionBinding: joinedRetentionBinding,
      capture: capture, nativeOwners: owners)
  }
  private func adoptNative(_ session: Session, values: [Entry], completions: [Completion],
    acknowledged: [Completion], authorization: JoinedKVRetentionAuthorization? = nil, binding: JoinedKVRetentionBinding? = nil) -> Bool {
    var retiredEntries: [Stored] = []
    defer { withExtendedLifetime(retiredEntries) {} }
    guard let capture = session.capture, let resources = session.nativeOwners, !values.isEmpty,
      resources.count == values[0].layouts.count else { return false }
    // Unsubmitted lazy suffixes cannot be adopted by offset trim: innerState()
    // could still execute their graph. Construction salvage must end at the
    // actual submitted all-layer boundary; partial/unknown future work refuses.
    let submitted = capture.submittedTokenCount
    // Inherited submittedEnd proves the old prefix, not this operation's lazy
    // row concat/zero or local hydration graph. Without a real current submit,
    // adoption could hide its unallocated H as an apparently ready width-one hit.
    guard capture.workingGraphWasSubmitted,
      resources.allSatisfy({ $0.native.offset <= submitted }),
      let physical = try? ActiveNativeKVStorage.rowWidth(resources) else { return false }
    let rows = values.filter { row in
      resources.indices.allSatisfy { layer in
        resources[layer].native.offset >= row.tokens.count
          && PrefixKVStorage.layout(of: resources[layer].native) == row.layouts[layer]
      }
    }.compactMap { original -> Entry? in
      var value = original; value.nativePhysicalWidth = physical
      if !Self.hasCurrentHot(value, owners: resources) { value.nativeCurrentPrefix = nil }
      guard value.supports(value.tokens.count) else { return nil }
      let row = value.nativeLedgerRow ?? value.joinedAcknowledgedRow ?? value.row ?? 0
      let delivered = completions.first { $0.row == row }, ack = acknowledged.first { $0.row == row }
      value.nativeRowReceipt = NativeRowReceipt(completedTokenCount: capture.coveredEnd,
        submittedTokenCount: submitted, processedTokenCount: value.nativeProcessedTokenCount ?? value.tokens.count,
        deliveredGeneratedTokenCount: delivered?.emittedTokenIDs.count ?? 0,
        acknowledgedGeneratedTokenCount: ack?.observedTokenIDs.count ?? 0,
        observedStopTokenID: delivered?.stopTokenID)
      return value
    }
    guard !rows.isEmpty else { return false }
    let leaseID = UUID()
    let localLease = PrefixKVDependencyLease { [weak self] in self?.releaseLease(leaseID) }
    // Exact full UUID charges survive both capture/index retirement and all
    // local hydration/row aliases. They are not active global archive pages.
    for span in rows.flatMap({ $0.spans.flatMap { $0 } }) {
      retainLease(leaseID, id: span.id, bytes: span.backingBytesUpperBound)
    }
    lock.lock()
    guard publicationTicket == session.epoch else { lock.unlock(); return false }
    let retired = activeNative
    let install = {
      self.retainDiskRows(rows, retiring: &retiredEntries)
      self.activeNative = ActiveNativeRecord(owners: resources, rows: rows, localLease: localLease)
      self.publicationTicket = nil
      return true
    }
    let accepted: Bool
    if let authorization, let binding { accepted = authorization.withAuthorization(binding: binding, install) ?? false }
    else { accepted = install() }
    lock.unlock(); withExtendedLifetime(retired) {}
    if accepted {
      // Sealed wrappers remain readable for final metrics, not mutable owners.
      // Existing finalization has joined/fenced. Two-piece row materialization
      // parents can close only after an actual submission in this operation.
      for cache in session.cache { _ = (cache as? PrefixKVCache)?.sealForJoinedTransfer() }
      if capture.workingGraphWasSubmitted {
        for resource in resources { resource.releaseMaterializedSourcesAfterJoinedSubmission() }
      }
    }
    return accepted
  }
  /// Called only in the existing authorized joined publication, with the index
  /// lock held. Metadata/files survive hot-cache switching; no native array,
  /// unverified global witness or second RAM archive enters this index.
  @discardableResult private func retainDiskRows(_ rows: [Entry], retiring retiredEntries: inout [Stored]) -> Bool {
    var added = false
    for original in rows {
      var available = original
      available.spans = original.spans.map { $0.filter { $0.diskFileID != nil } }
      available.nativeGlobalPrefix = nil; available.nativeCurrentPrefix = nil
      guard let count = available.maximumSupportedPrefix(upTo: original.tokens.count) else { continue }
      let history = Self.clippedHistory(original.history, through: count)
      let archived = Entry(id: UUID(), owner: original.owner,
        tokens: Array(original.tokens.prefix(count)), layouts: original.layouts,
        spans: available.spans.map { values in values.compactMap { span in
          guard span.start < count else { return nil }
          return try? span.sliced(positions: 0..<(min(count, span.end) - span.start))
        } }, geometry: original.geometry, origin: history.last?.origin ?? .prefill,
        batchWidth: original.batchWidth, row: original.nativeLedgerRow ?? original.row,
        history: history, nativePhysicalWidth: original.nativePhysicalWidth,
        nativeProcessedTokenCount: original.nativeProcessedTokenCount,
        nativeLedgerRow: original.nativeLedgerRow, nativeRowReceipt: original.nativeRowReceipt,
        joinedAcknowledgedRow: original.joinedAcknowledgedRow,
        joinedRetentionProvenance: original.joinedRetentionProvenance)
      for old in entries.values.filter({ $0.entry.owner.namespace == archived.owner.namespace
        && $0.entry.tokens == archived.tokens }).map({ $0.entry.id }) { remove(old, retiring: &retiredEntries) }
      insert(archived); added = true
    }
    while entries.count > 128 {
      guard let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
      remove(oldest, retiring: &retiredEntries) // final file owners unlink on the existing utility queue
    }
    return added
  }
  /// Caller retains the coordinator/executor lease across producer join, the
  /// existing fence, owner approval and this retention-only publication. This
  /// never reopens a journal, displays a result, or makes cancellation succeed.
  @discardableResult func publishJoinedValidPrefix(_ session: Session,
    proof: JoinedKVRetentionProof, authorization: JoinedKVRetentionAuthorization,
    acknowledged: [Completion] = []) -> Bool {
    var retiredEntries: [Stored] = []
    defer { withExtendedLifetime(retiredEntries) {} }
    let trace = PerformanceTrace.begin("Model.KVRetentionPublish")
    defer { PerformanceTrace.end("Model.KVRetentionPublish", trace) }
    guard proof.permitsRetention,
      proof.termination != .constructorCancelled || acknowledged.isEmpty else { return false }
    defer { session.capture?.discard() }
    guard let owner = session.owner, let binding = session.joinedRetentionBinding,
      binding.owner == owner, binding == authorization.binding, let capture = session.capture,
      capture.independentRow == nil else { return false }
    lock.lock(); let current = publicationTicket == session.epoch; lock.unlock()
    guard current,
      authorization.withAuthorization(binding: binding, { true }) == true else { return false }
    let values = capture.joinedEntries(owner: owner, acknowledged: acknowledged).map { original in
      var value = original
      value.joinedRetentionProvenance = JoinedKVRetentionProvenance(binding: binding,
        termination: proof.termination, promptTokenCount: session.fullPromptTokenCount,
        representedTokenCount: value.tokens.count,
        lastCompleteCohortTokenCount: capture.coveredEnd,
        lastSubmittedCohortTokenCount: capture.submittedTokenCount,
        acknowledgedGeneratedTokenCount: acknowledged.first(where: { $0.row == (value.joinedAcknowledgedRow ?? value.row ?? 0) })?.observedTokenIDs.count ?? 0,
        representedGeneratedTokenCount: max(0, value.tokens.count - session.fullPromptTokenCount))
      return value
    }
    if session.usesActiveNativeState {
      if adoptNative(session, values: values, completions: acknowledged,
        acknowledged: acknowledged, authorization: authorization, binding: binding) { return true }
      // A later half-layer/unsubmitted future cannot become the hot cache.
      // Earlier actual completed file bytes are independent of those owners.
      // Re-admit only disk-supported coverage under this SAME joined ticket;
      // never inspect/evaluate/trim a future native graph or change cancellation.
      guard capture.workingGraphWasSubmitted else { return false }
      lock.lock(); defer { lock.unlock() }
      guard publicationTicket == session.epoch else { return false }
      return authorization.withAuthorization(binding: binding) {
        let added = retainDiskRows(values, retiring: &retiredEntries) // clears every native coverage witness
        if added { publicationTicket = nil }
        return added
      } ?? false
    }
    lock.lock(); defer { lock.unlock() }
    guard publicationTicket == session.epoch else { return false }
    return authorization.withAuthorization(binding: binding) {
      publicationTicket = nil
      var added = false
      for value in values {
        for old in entries.values.filter({ $0.entry.owner.namespace == owner.namespace
          && $0.entry.tokens == value.tokens }).map({ $0.entry.id }) { remove(old, retiring: &retiredEntries) }
        insert(value); added = true
      }
      while bytes > byteLimit || entries.count > 128 {
        guard let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
        remove(oldest, retiring: &retiredEntries)
      }
      return added && values.contains { entries[$0.id] != nil }
    } ?? false
  }
  @discardableResult func publish(_ session: Session, completions: [Completion] = [],
    acknowledged: [Completion] = []) -> Bool {
    var retiredEntries: [Stored] = []
    defer { withExtendedLifetime(retiredEntries) {} }
    let trace = PerformanceTrace.begin("Model.KVRetentionPublish")
    defer { PerformanceTrace.end("Model.KVRetentionPublish", trace) }
    guard let owner = session.owner, session.capture?.independentRow == nil else { return false }
    lock.lock(); let current = publicationTicket == session.epoch; lock.unlock()
    guard current, let capture = session.capture else {
      session.capture?.discard(); return false
    }
    // Run after the manager lock releases; leases survive until descriptors leave.
    defer { capture.discard() }
    let values = capture.entries(owner: owner, completions: completions)
    if session.usesActiveNativeState { return adoptNative(session, values: values,
      completions: completions, acknowledged: acknowledged) }
    lock.lock(); defer { lock.unlock() }
    guard publicationTicket == session.epoch else { return false }
    publicationTicket = nil
    var added = false
    for value in values {
      // Replace only identical ledgers. Other resident branches remain eligible.
      for old in entries.values.filter({ $0.entry.owner.namespace == owner.namespace && $0.entry.tokens == value.tokens }).map({ $0.entry.id }) {
        remove(old, retiring: &retiredEntries)
      }
      insert(value); added = true
    }
    while bytes > byteLimit || entries.count > 128 {
      guard let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
      remove(oldest, retiring: &retiredEntries)
    }
    return added && values.contains { entries[$0.id] != nil }
  }
  /// Cold historical owners only. Strong span ownership protects borrowed and
  /// current rows; quota credit is exclusively the store's completed unlink.
  /// Called from the joined finalizer, never from an active decode update.
  private func retireOldestDiskEntry(epoch: UUID) -> Bool {
    var retiredEntries: [Stored] = []
    defer { withExtendedLifetime(retiredEntries) {} }
    lock.lock(); defer { lock.unlock() }
    guard publicationTicket == epoch else { return false }
    let historical = entries.filter { pair in
      !pair.value.entry.spans.isEmpty
        && pair.value.entry.spans.flatMap({ $0 }).allSatisfy { $0.diskFileID != nil }
    }
    guard let oldest = historical.min(by: { $0.value.touched < $1.value.touched })?.key else { return false }
    remove(oldest, retiring: &retiredEntries)
    return true
  }
  private func makeOperandWitness(_ binding: ForwardOperandBinding, epoch: UUID) -> OperandWitness? {
    guard binding.wellFormed,
      let lease = makeMetadataLease(ForwardOperandBinding.metadataBytesUpperBound, epoch: epoch) else { return nil }
    return OperandWitness(binding, lease: lease)
  }
  private func makeMetadataLease(_ amount: UInt64, epoch: UUID) -> PrefixKVDependencyLease? {
    guard amount > 0, amount <= 16_384 else { return nil }
    lock.lock()
    // Missing diagnostic metadata never evicts a useful KV row or changes its
    // automatic admission. Use the same existing pool, without eviction.
    guard publicationTicket == epoch, Self.adding(bytes, amount) <= byteLimit else {
      lock.unlock(); return nil
    }
    let leaseID = UUID(), backingID = UUID()
    retainLeaseLocked(leaseID, id: backingID, bytes: amount)
    lock.unlock()
    return PrefixKVDependencyLease { [weak self] in self?.releaseLease(leaseID) }
  }
  private func reserve(incoming: UInt64, epoch: UUID,
    allow: (@Sendable (UInt64) -> Bool)?) -> ReservationDecision {
    let trace = PerformanceTrace.begin("Model.KVRetentionReserve")
    defer { PerformanceTrace.end("Model.KVRetentionReserve", trace) }
    var retiredEntries: [Stored] = []
    lock.lock()
    guard publicationTicket == epoch else { lock.unlock(); return .staleTicket }
    while Self.adding(bytes, incoming) > byteLimit {
      let resident = entries.filter { $0.value.entry.spans.contains { values in
        values.contains { $0.backingBytesUpperBound > 0 }
      } }
      guard let oldest = resident.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
      // Disk-only metadata cannot free GPU/RAM bytes. Genuine escaped capture
      // and hydration leases keep resident backing charged after retirement.
      remove(oldest, retiring: &retiredEntries)
      lock.unlock()
      // Dispose the retired references before deciding whether another real
      // row must be evicted. Escaped observations keep their actual charges.
      retiredEntries.removeAll()
      lock.lock()
      guard publicationTicket == epoch else { lock.unlock(); return .staleTicket }
    }
    let withinPool = Self.adding(bytes, incoming) <= byteLimit
    lock.unlock()
    guard withinPool else { return .poolLimit }
    guard allow?(incoming) != false else { return .residency }
    lock.lock(); let current = publicationTicket == epoch; lock.unlock()
    return current ? .admitted : .staleTicket
  }
  private func borrow(id: UUID, lease: UUID, epoch: UUID) -> Entry? {
    lock.lock(); defer { lock.unlock() }
    guard publicationTicket == epoch, let value = entries[id]?.entry else { return nil }
    var seen: Set<UUID> = []
    for span in value.spans.flatMap({ $0 }) where seen.insert(span.id).inserted {
      retainLeaseLocked(lease, id: span.id, bytes: span.backingBytesUpperBound)
    }
    return value
  }
  private func retainLease(_ lease: UUID, id: UUID, bytes amount: UInt64) {
    lock.lock(); defer { lock.unlock() }; retainLeaseLocked(lease, id: id, bytes: amount)
  }
  private func retainLeaseLocked(_ lease: UUID, id: UUID, bytes amount: UInt64) {
    // Mutate the set in place; copying it per span would make decode quadratic.
    guard amount > 0, captureLeases[lease, default: []].insert(id).inserted else { return }
    if var backing = backings[id] {
      precondition(backing.bytes == amount, "Immutable backing charges must agree.")
      backing.references += 1; backings[id] = backing
    } else {
      let total = Self.adding(bytes, amount)
      precondition(total <= byteLimit, "An unreserved capture backing exceeded the pool.")
      backings[id] = Backing(bytes: amount, references: 1); bytes = total
    }
  }
  private func releaseLeaseBacking(_ lease: UUID, id: UUID) {
    lock.lock(); defer { lock.unlock() }
    guard captureLeases[lease]?.remove(id) != nil else { return }
    releaseBackingLocked(id)
    if captureLeases[lease]?.isEmpty == true { captureLeases.removeValue(forKey: lease) }
  }
  private func releaseLease(_ lease: UUID) {
    lock.lock(); defer { lock.unlock() }
    guard let ids = captureLeases.removeValue(forKey: lease) else { return }
    for id in ids { releaseBackingLocked(id) }
  }
  private func releaseBackingLocked(_ id: UUID) {
    guard var backing = backings[id] else { return }
    precondition(backing.references > 0)
    backing.references -= 1
    if backing.references == 0 { bytes -= backing.bytes; backings.removeValue(forKey: id) }
    else { backings[id] = backing }
  }
  private func insert(_ entry: Entry) {
    clock &+= 1; entries[entry.id] = Stored(entry: entry, insertedAt: clock, touched: clock)
    let index = indices[entry.owner.namespace] ?? PrefixTokenIndex()
    index.insert(tokens: entry.tokens, id: entry.id); indices[entry.owner.namespace] = index
    var seen: Set<UUID> = []
    for span in entry.spans.flatMap({ $0 }) where span.backingBytesUpperBound > 0 && seen.insert(span.id).inserted {
      if var backing = backings[span.id] { backing.references += 1; backings[span.id] = backing }
      else {
        let amount = span.backingBytesUpperBound
        backings[span.id] = Backing(bytes: amount, references: 1); bytes = Self.adding(bytes, amount)
      }
    }
  }
  private func remove(_ id: UUID, retiring: inout [Stored]) {
    guard let stored = entries.removeValue(forKey: id) else { return }
    indices[stored.entry.owner.namespace]?.remove(id: id)
    var seen: Set<UUID> = []
    for span in stored.entry.spans.flatMap({ $0 }) where span.backingBytesUpperBound > 0 && seen.insert(span.id).inserted {
      releaseBackingLocked(span.id)
    }
    retiring.append(stored)
  }
  fileprivate static func clippedHistory(_ history: [ForwardSegment], through count: Int) -> [ForwardSegment] {
    history.filter { $0.startTokenCount < count }.map { segment in
      ForwardSegment(origin: segment.origin, startTokenCount: segment.startTokenCount,
        endTokenCount: min(segment.endTokenCount, count), batchWidth: segment.batchWidth,
        row: segment.row, promptTokenCount: segment.promptTokenCount, geometry: segment.geometry,
        evaluatedEndTokenCount: segment.evaluatedEndTokenCount ?? segment.endTokenCount,
        originalInput: segment.originalInput)
    }
  }
  /// Admission and execution must use the identical selected stride. A preserved
  /// balanced parent can have a larger stride than freshly balancing its suffix.
  private static func nativeSuffixPrefill(history: [ForwardSegment], count: Int, prompt: Int,
    prefill: PrefillParameters) -> PrefillParameters {
    var result = prefill
    if count > 0, preservesGeometry(history, count: count, prompt: prompt, prefill: prefill),
      let stride = PromptCacheGeometry(promptTokens: prompt, prefill: prefill).chunkStride {
      result.chunking = .remainder; result.stepSize = stride
    }
    return result
  }
  private static func preservesGeometry(_ history: [ForwardSegment], count: Int, prompt: Int,
    prefill: PrefillParameters) -> Bool {
    guard count > 0 else { return true }
    guard history.allSatisfy({ $0.origin == .prefill && $0.batchWidth == 1 }) else { return false }
    var expected: [Range<Int>] = []
    var prepared = 0
    if let stride = prefill.chunkLength(forChunking: max(0, prompt - 1)) {
      while prompt - prepared > 1 {
        let length = min(stride, prompt - prepared - 1)
        expected.append(prepared..<(prepared + length)); prepared += length
      }
    }
    if prepared < prompt { expected.append(prepared..<prompt) }
    let actual = history.map { $0.startTokenCount..<($0.evaluatedEndTokenCount ?? $0.endTokenCount) }
    return Array(expected.prefix(actual.count)) == actual && actual.last?.upperBound == count
  }
  static func adding(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (value, overflow) = a.addingReportingOverflow(b); return overflow ? .max : value
  }
  static func multiplying(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b); return overflow ? .max : value
  }
}
