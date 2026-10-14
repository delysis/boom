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

/// Transient, byte-bounded resident KV. The runner binds model/processor identity;
/// workspace namespaces isolate content. Entity and route do not limit lookup.
/// Native windows roll: overwritten local history is never archived to disk or
/// retained without a bound. A hit requires coverage in every actual cache layer.
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
    var retentionObservation: RetentionObservation? { capture?.observation }
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
    let spans: [[PrefixKVSpan]]
    let geometry: PromptCacheGeometry
    let origin: Origin
    let batchWidth: Int
    let row: Int?
    let history: [ForwardSegment]
    var nativeGlobalPrefix: Int? = nil
    var nativePhysicalWidth: Int? = nil
    var nativeProcessedTokenCount: Int? = nil
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

  /// Captures incoming global pages and only a rolling, bounded local tail.
  /// Every layer's inputs are tapped before its ring write. Descriptors are
  /// retained without copying full cache arrays or inserting a GPU fence.
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
          return try? PrefixKVSpan(id: span.id, offset: range.lowerBound, layer: span.layer,
            keys: span.keys[0..., 0..., (range.lowerBound - span.start)..<(range.upperBound - span.start), 0...],
            values: span.values[0..., 0..., (range.lowerBound - span.start)..<(range.upperBound - span.start), 0...],
            backingBytesUpperBound: span.backingBytesUpperBound)
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
    private var samples: [MLXArray] = []
    private var singleValid = true
    private var lanes: [Int: Lane] = [:]
    weak var primaryCache: PrefixKVCache?

    init(layouts: [PrefixKVStorage.Layout], tokens: [Int], cachedCount: Int,
      geometry: PromptCacheGeometry, suffixGeometry: PromptCacheGeometry,
      inherited: Entry?, reserve: @escaping @Sendable (UInt64, Bool) -> ReservationDecision,
      retainBacking: @escaping @Sendable (UUID, UInt64) -> Void,
      releaseBacking: @escaping @Sendable (UUID) -> Void,
      closeLease: @escaping @Sendable () -> Void, nativeGlobals: Bool = false) {
      self.layouts = layouts; self.nativeGlobals = nativeGlobals
      self.tokens = tokens; self.cachedCount = cachedCount
      self.geometry = geometry; self.suffixGeometry = suffixGeometry; self.reserve = reserve
      self.retainBacking = retainBacking; self.releaseBacking = releaseBacking; self.closeLease = closeLease
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
            if let cropped = try? PrefixKVSpan(id: span.id, offset: span.start, layer: span.layer,
              keys: span.keys[row..<(row + 1), 0..., ..<upper, 0...],
              values: span.values[row..<(row + 1), 0..., ..<upper, 0...],
              backingBytesUpperBound: span.backingBytesUpperBound) {
              for piece in spans[layer].append(cropped) {
                retain(piece, novel: false)
              }
            }
          }
        }
      }
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
    }
    var coveredEnd: Int { lock.lock(); defer { lock.unlock() }; return end }
    var stagedBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return novelBytes }
    var observation: RetentionObservation {
      lock.lock(); defer { lock.unlock() }
      return RetentionObservation(compactLocalCoverage: compactLocalCoverage,
        lastCompleteTokenCount: max(lastCompleteTokenCount, end), refusalReason: refusalReason?.rawValue)
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
      for piece in spans[layer].append(span) { retain(piece, novel: true) }
      forward.layers.insert(layer); pending = forward
      if forward.layers.count == layouts.count {
        end = forward.end; lastCompleteTokenCount = end; pending = nil
        let origin: Origin = forward.start < tokens.count ? .prefill
          : forward.width == 1 ? .singleDecode : .batchDecode
        history.append(ForwardSegment(origin: origin, startTokenCount: forward.start,
          endTokenCount: forward.end, batchWidth: forward.width, row: nil,
          promptTokenCount: origin == .prefill ? tokens.count : nil,
          geometry: origin == .prefill ? suffixGeometry : nil,
          evaluatedEndTokenCount: forward.end))
        pruneLocalTail()
      }
    }
    /// Native globals are owned once; only bounded local incoming pages enter
    /// the pool. A declined optimization page does not stop the all-layer
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
      if case .rotating = layouts[layer], accepting {
        let positionBytes = UInt64(max(0, keys.nbytes + values.nbytes)) / UInt64(length * width)
        bytesPerPosition[layer] = positionBytes
        if forward.reservedBytes == 0 {
          let localBytes = layouts.indices.reduce(UInt64(0)) { total, index in
            guard case .rotating = layouts[index] else { return total }
            return PromptPrefixCache.adding(total, bytesPerPosition[index] == 0 ? positionBytes : bytesPerPosition[index])
          }
          let incoming = PromptPrefixCache.multiplying(localBytes, UInt64(length * width))
          if admit(incoming: incoming, checkResidency: true) { forward.reservedBytes = incoming }
          else { accepting = false }
        }
        if accepting, let span = try? PrefixKVSpan(offset: offset, layer: layer, keys: keys, values: values) {
          let actual = PromptPrefixCache.adding(forward.usedBytes, Self.bytes(span))
          if actual > forward.reservedBytes, !admit(incoming: Self.bytes(span), checkResidency: false) {
            accepting = false
          } else {
            forward.reservedBytes = max(forward.reservedBytes, actual); forward.usedBytes = actual
            for piece in spans[layer].append(span) { retain(piece, novel: true) }
          }
        }
        if !accepting {
          // Discard incomplete descriptor cohorts, not the metadata witness.
          for index in spans.indices {
            for span in spans[index].removeIncomplete(start: offset) { release(span) }
          }
        }
      }
      forward.layers.insert(layer); pending = forward
      if forward.layers.count == layouts.count {
        end = forward.end; lastCompleteTokenCount = end; pending = nil
        let origin: Origin = forward.start < tokens.count ? .prefill
          : forward.width == 1 ? .singleDecode : .batchDecode
        history.append(ForwardSegment(origin: origin, startTokenCount: forward.start,
          endTokenCount: forward.end, batchWidth: forward.width, row: nil,
          promptTokenCount: origin == .prefill ? tokens.count : nil,
          geometry: origin == .prefill ? suffixGeometry : nil, evaluatedEndTokenCount: forward.end))
        pruneLocalTail()
      }
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
    private func pruneLocalTail() {
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
      let boundary = min(count, max(0, tokens.count - 1)), pinned = min(keep, boundary)
      return max(pinned, boundary - (window - keep))..<boundary
    }
    /// Pressure reduces optional past coverage, never the required native tail.
    /// Whole incoming pages and all row views keep their immutable full charge.
    private func shedOptionalLocalCoverage() {
      compactLocalCoverage = true
      pruneLocalTail()
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
          guard selected < span.batchWidth, let view = try? PrefixKVSpan(id: span.id,
            offset: span.start, layer: layer,
            keys: span.keys[selected..<(selected + 1), 0..., ..<(upper - span.start), 0...],
            values: span.values[selected..<(selected + 1), 0..., ..<(upper - span.start), 0...],
            backingBytesUpperBound: span.backingBytesUpperBound) else { return nil }
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
        if !overflow, full <= end { submittedEnd = max(submittedEnd, full); workingGraphSubmitted = true }
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
        completion.row == row, let processed = primaryCache?.offset,
        processed >= tokens.count, processed - tokens.count <= completion.observedTokenIDs.count else { return false }
      if let previous = lanes[row] {
        guard previous.width == width, !previous.finished, processed >= previous.processed,
          completion.observedTokenIDs.starts(with: previous.ledger) else { return false }
      }
      let frozen = finished ? freezeLocal(row: row, processed: min(processed, end)) : nil
      if finished, frozen == nil { return false }
      lanes[row] = Lane(width: width, processed: processed,
        ledger: completion.observedTokenIDs, finished: finished, frozenLocal: frozen)
      return true
    }
    func discard() {
      lock.lock(); defer { lock.unlock() }
      discarded = true; accepting = false; spans.removeAll(); samples.removeAll(); lanes.removeAll()
      spanCharges.removeAll(); novelBytes = 0; end = 0; pending = nil
      closeLease()
    }
    // Only after the producer joins and the existing fence. The authoritative
    // delivered ledger bounds publication, regardless of producer lookahead.
    func entries(owner: PromptCacheOwner, completions: [Completion]) -> [Entry] {
      lock.lock(); defer { lock.unlock() }
      guard !discarded, complete, pending == nil, end > 0,
        Set(completions.map(\.row)).count == completions.count else { return [] }
      let fullHistory = inheritedHistory + history
      func entry(ledger: [Int], processed: Int, width: Int, row: Int?, frozenLocal: [[PrefixKVSpan]]? = nil) -> Entry? {
        let count = min(nativeGlobals ? submittedEnd : end, min(end, min(processed, tokens.count + ledger.count)))
        guard count > 0 else { return nil }
        let ids = Array(tokens.prefix(count)) + Array(ledger.prefix(max(0, count - tokens.count)))
        let selectedHistory = PromptPrefixCache.clippedHistory(fullHistory, through: count).map { segment in
          ForwardSegment(origin: segment.origin, startTokenCount: segment.startTokenCount,
            endTokenCount: segment.endTokenCount, batchWidth: segment.batchWidth,
            row: segment.row ?? (segment.origin == .batchDecode && segment.startTokenCount >= tokens.count ? row : nil),
            promptTokenCount: segment.promptTokenCount, geometry: segment.geometry,
            evaluatedEndTokenCount: segment.evaluatedEndTokenCount)
        }
        let value = Entry(id: UUID(), owner: owner, tokens: ids, layouts: layouts,
          spans: layouts.indices.map { layer in
            if case .rotating = layouts[layer], let frozenLocal { return frozenLocal[layer] }
            return spans[layer].values.filter { $0.start < count }
          }, geometry: geometry,
          origin: selectedHistory.last?.origin ?? .prefill, batchWidth: width, row: row,
          history: selectedHistory, nativeGlobalPrefix: nativeGlobals ? count : nil)
        if nativeGlobals {
          guard let supported = value.maximumSupportedPrefix(upTo: count) else { return nil }
          let clipped = PromptPrefixCache.clippedHistory(selectedHistory, through: supported)
          let source = clipped.last
          return Entry(id: value.id, owner: owner, tokens: Array(ids.prefix(supported)), layouts: layouts,
            spans: value.spans.map { $0.filter { $0.start < supported } }, geometry: geometry,
            origin: source?.origin ?? .prefill, batchWidth: source?.batchWidth ?? width,
            row: source?.origin == .batchDecode ? source?.row ?? row : nil, history: clipped,
            nativeGlobalPrefix: supported, nativeProcessedTokenCount: row == nil ? end : processed,
            nativeLedgerRow: row)
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
      let fullHistory = inheritedHistory + history
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
          batchWidth: width, row: row, history: [], nativeGlobalPrefix: nativeGlobals ? cap : nil)
        guard let count = candidate.maximumSupportedPrefix(upTo: cap) else { return nil }
        let selectedHistory = PromptPrefixCache.clippedHistory(fullHistory, through: count).map { segment in
          ForwardSegment(origin: segment.origin, startTokenCount: segment.startTokenCount,
            endTokenCount: segment.endTokenCount, batchWidth: segment.batchWidth,
            row: segment.row ?? (segment.origin == .batchDecode && segment.startTokenCount >= tokens.count ? row : nil),
            promptTokenCount: segment.promptTokenCount, geometry: segment.geometry,
            evaluatedEndTokenCount: segment.evaluatedEndTokenCount)
        }
        let source = selectedHistory.last
        let sourceRow = source?.origin == .batchDecode ? source?.row ?? row : nil
        return Entry(id: UUID(), owner: owner, tokens: Array(ids.prefix(count)), layouts: layouts,
          spans: retained.map { $0.filter { $0.start < count } }, geometry: geometry,
          origin: source?.origin ?? .prefill, batchWidth: source?.batchWidth ?? width, row: sourceRow,
          history: selectedHistory, nativeGlobalPrefix: nativeGlobals ? count : nil,
          nativeProcessedTokenCount: nativeGlobals ? (row == nil ? end : processed) : nil,
          nativeLedgerRow: row, joinedAcknowledgedRow: row)
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
  init(byteLimit: UInt64 = PromptPrefixCache.defaultByteLimit) { self.byteLimit = byteLimit }
  func clear(reason: String? = nil) {
    lock.lock()
    let retired = activeNative; activeNative = nil
    for id in Array(entries.keys) { remove(id) }
    indices.removeAll(); storageEpoch = UUID()
    // Live capture/lookup/hydration/native owners keep their true charges.
    publicationTicket = nil; pendingMissReason = reason
    lock.unlock(); withExtendedLifetime(retired) {}
  }
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
    // A diagnostic/unsupported cold path cannot leave another global branch
    // indexed beside its own. True escaped owners/graph leases remain charged.
    retireNativeOwned()
    let ticket = UUID()
    lock.lock(); publicationTicket = ticket
    let emptyReason = pendingMissReason; pendingMissReason = nil
    var candidates: [(id: UUID, count: Int, insertedAt: UInt64)] = []
    var hasTokenMatch = false
    if let owner, textOnly, let index = indices[owner.namespace] {
      for match in index.matches(tokens: promptTokenIDs, maximumCount: promptTokenIDs.count - 1) {
        hasTokenMatch = true
        if let stored = entries[match.id],
          let supported = stored.entry.maximumSupportedPrefix(upTo: match.tokenCount) {
          candidates.append((stored.entry.id, supported, stored.insertedAt))
        }
      }
    }
    candidates.sort { $0.count == $1.count ? $0.insertedAt > $1.insertedAt : $0.count > $1.count }
    lock.unlock()
    var selected: Entry?, count = 0, working: [KVCache]?, selectedBorrow: UUID?
    var hydrationDependencies: PrefixKVDependencyLease?
    defer { if let selectedBorrow { releaseLease(selectedBorrow) } }
    for (id, matched, _) in candidates {
      let borrowed = UUID()
      guard let value = borrow(id: id, lease: borrowed, epoch: ticket) else { continue }
      let dependencyID = UUID()
      let dependencies = PrefixKVDependencyLease { [weak self] in
        self?.releaseLease(dependencyID)
      }
      let hydrated = try? {
        let trace = PerformanceTrace.begin("Model.PrefixCacheHydration")
        defer { PerformanceTrace.end("Model.PrefixCacheHydration", trace) }
        return try value.layouts.indices.map { layer in
          try PrefixKVStorage.hydrate(layout: value.layouts[layer], spans: value.spans[layer],
            prefix: matched, row: value.row ?? 0, batchWidth: value.batchWidth,
            onSourceBacking: { [weak self] id, bound in
              self?.retainLease(dependencyID, id: id, bytes: bound)
            })
        }
      }()
      if let hydrated {
        selected = value; count = matched; working = hydrated; selectedBorrow = borrowed
        hydrationDependencies = dependencies
        break
      }
      releaseLease(borrowed)
    }
    if let selected {
      lock.lock(); clock &+= 1
      if var stored = entries[selected.id] { stored.touched = clock; entries[selected.id] = stored }
      lock.unlock()
    }
    let native = try working ?? makeCache()
    let layouts = native.compactMap { PrefixKVStorage.layout(of: $0) }
    let canCapture = owner != nil && textOnly && !native.isEmpty && layouts.count == native.count
    let narrowed: LMInput
    if count > 0 {
      let ids = input.text.tokens
      narrowed = LMInput(tokens: ids.ndim == 1 ? ids[count...] : ids[0..., count...])
    } else { narrowed = input }
    var suffix = prefill
    let inheritedHistory = selected.map { Self.clippedHistory($0.history, through: count) } ?? []
    let preserves = Self.preservesGeometry(inheritedHistory, count: count, prompt: promptTokenIDs.count, prefill: prefill)
    if count > 0, preserves, let stride = geometry.chunkStride {
      suffix.chunking = .remainder; suffix.stepSize = stride
    }
    let suffixGeometry = PromptCacheGeometry(promptTokens: promptTokenIDs.count - count, prefill: suffix)
    let capture = canCapture ? Capture(layouts: layouts, tokens: promptTokenIDs, cachedCount: count,
      geometry: geometry, suffixGeometry: suffixGeometry, inherited: selected,
      reserve: { [weak self] incoming, checkResidency in
        self?.reserve(incoming: incoming, epoch: ticket,
          allow: checkResidency ? allowSnapshot : nil) ?? .staleTicket
      },
      retainBacking: { [weak self] id, bound in self?.retainLease(ticket, id: id, bytes: bound) },
      releaseBacking: { [weak self] id in self?.releaseLeaseBacking(ticket, id: id) },
      closeLease: { [weak self] in self?.releaseLease(ticket) }) : nil
    let cache: [KVCache] = native.enumerated().map { layer, base in
      if let capture {
        return PrefixKVCache(layer: layer, base: base, dependencyLease: hydrationDependencies) {
          capture.update(layer: $0, offset: $1, keys: $2, values: $3)
        }
      }
      if let hydrationDependencies {
        return PrefixKVCache(layer: layer, base: base, dependencyLease: hydrationDependencies) {
          _, _, _, _ in
        }
      }
      return base
    }
    capture?.primaryCache = cache.first as? PrefixKVCache
    let sourceProgress = prefill.progress
    let reusedTokenCount = count
    if let capture {
      suffix.progress = { processed, total in
        capture.progress(processed: processed, total: total)
        sourceProgress?(reusedTokenCount + processed, reusedTokenCount + total)
      }
    }
    let miss: String? = count > 0 ? nil : owner == nil ? "no_owner" : !textOnly ? "unsupported_input"
      : emptyReason ?? (candidates.isEmpty ? (hasTokenMatch ? "local_coverage_missing" : "no_resident_prefix") : "unsupported_cache")
    let observation = Observation(algorithm: Self.algorithm, originalGeometry: geometry,
      suffixGeometry: suffixGeometry, fullPromptTokens: promptTokenIDs.count,
      cachedPromptTokens: count, suffixPromptTokens: promptTokenIDs.count - count,
      missReason: miss, cachedOrigin: inheritedHistory.last?.origin, cachedBatchWidth: selected?.batchWidth,
      cachedRow: selected?.row, cachedForwardHistory: inheritedHistory,
      retainedBytes: retainedBytesUpperBound, byteLimit: byteLimit,
      cachedJoinedRetentionProvenance: selected?.joinedRetentionProvenance)
    return Session(input: narrowed, cache: cache, prefill: suffix, cachedTokenCount: count,
      fullPromptTokenCount: promptTokenIDs.count, preservesChunkBoundaries: preserves,
      observation: observation, owner: owner, epoch: ticket,
      joinedRetentionBinding: joinedRetentionBinding, capture: capture)
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
  private func activeChoice(owner: PromptCacheOwner, tokens: [Int]) -> (ActiveNativeRecord, Entry, Int, UUID)? {
    lock.lock(); defer { lock.unlock() }
    guard let record = activeNative else { return nil }
    var selected: Entry?, longest = 0
    for row in record.rows where row.owner.namespace == owner.namespace {
      let lexical = zip(tokens, row.tokens).prefix(while: { $0.0 == $0.1 }).count
      guard let count = row.maximumSupportedPrefix(upTo: min(lexical, tokens.count - 1)),
        count > longest else { continue }
      selected = row; longest = count
    }
    guard let selected else { return nil }
    return (record, selected, longest, storageEpoch)
  }
  /// Read-only sizing for source/context preflight. It never consumes a slot,
  /// clears native ownership, or fabricates a prefix from missing local rows.
  func nativeAdmissionPlan(owner: PromptCacheOwner?, tokens: [Int], prefill: PrefillParameters,
    outputTokens: Int, batchWidth: Int) throws -> ActiveNativeKVAdmissionPlan? {
    guard let owner, let (record, row, count, _) = activeChoice(owner: owner, tokens: tokens) else { return nil }
    let suffix = Self.nativeSuffixPrefill(history: Self.clippedHistory(row.history, through: count),
      count: count, prompt: tokens.count, prefill: prefill)
    return try ActiveNativeKVStorage.plan(owners: record.owners, layouts: row.layouts,
      prefix: count, prompt: tokens.count, output: outputTokens, width: batchWidth,
      row: row.row, prefill: suffix)
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
    var admissionRefused = false
    if chosen != nil {
      let plan = try { () -> ActiveNativeKVAdmissionPlan in
        let value = chosen!
        let suffix = Self.nativeSuffixPrefill(history: Self.clippedHistory(value.1.history, through: value.2),
          count: value.2, prompt: promptTokenIDs.count, prefill: prefill)
        return try ActiveNativeKVStorage.plan(owners: value.0.owners, layouts: value.1.layouts,
          prefix: value.2, prompt: promptTokenIDs.count, output: outputTokens,
          width: batchWidth, row: value.1.row, prefill: suffix)
      }()
      do { try admitNative?(plan) }
      catch BoomError.budget {
        // No tensor work or destructive native trim has happened. A real fit
        // failure may reclaim the slot and try ordinary *admission*, never retry
        // a model run or alter its prompt/width/policy.
        chosen = nil; admissionRefused = true
        retireNativeOwned()
        try admitNative?(nil)
      }
    } else {
      retireNativeOwned()
      try admitNative?(nil)
    }
    let ticket = UUID(), geometry = PromptCacheGeometry(promptTokens: promptTokenIDs.count, prefill: prefill)
    lock.lock()
    if let value = chosen, storageEpoch != value.3 || activeNative !== value.0 {
      lock.unlock(); throw BoomError.stale("The active native cache was invalidated during admission.")
    }
    let retired = activeNative; activeNative = nil
    // A native adoption/operation keeps no historical global KV branches.
    for id in Array(entries.keys) { remove(id) }; indices.removeAll()
    publicationTicket = ticket
    let emptyReason = pendingMissReason; pendingMissReason = nil
    lock.unlock()
    let selected = chosen?.1, count = chosen?.2 ?? 0
    let sourceOwners = chosen?.0.owners ?? []
    var owners: [PrefixKVNativeOwnership] = []
    if let selected {
      let trace = PerformanceTrace.begin("Model.ActiveNativeKVTransfer")
      defer { PerformanceTrace.end("Model.ActiveNativeKVTransfer", trace) }
      for layer in selected.layouts.indices {
        let source = sourceOwners[layer]
        switch selected.layouts[layer] {
        case .simple:
          owners.append(try ActiveNativeKVStorage.selectedGlobal(source, prefix: count,
            row: selected.row ?? 0, makeOwner: { self.makeNativeOwner($0, sources: $1, materialized: $2) }))
        case .rotating:
          let native = source.native
          let direct = native.innerState().allSatisfy { $0.dim(0) == 1 }
            && (native.offset == count || native.isTrimmable && native.offset >= count)
          if direct {
            _ = native.trim(native.offset - count)
            guard native.offset == count else { throw BoomError.invalid("Native local transfer changed its offset.") }
            owners.append(source)
          } else {
            let trace = PerformanceTrace.begin("Model.ActiveLocalKVHydration")
            defer { PerformanceTrace.end("Model.ActiveLocalKVHydration", trace) }
            let dependencyID = UUID()
            let lease = PrefixKVDependencyLease { [weak self] in self?.releaseLease(dependencyID) }
            let native = try PrefixKVStorage.hydrate(layout: selected.layouts[layer], spans: selected.spans[layer],
              prefix: count, row: selected.row ?? 0, batchWidth: selected.batchWidth,
              onSourceBacking: { [weak self] id, bytes in self?.retainLease(dependencyID, id: id, bytes: bytes) })
            owners.append(makeNativeOwner(native, dependencies: lease))
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
      closeLease: { [weak self] in self?.releaseLease(ticket) }, nativeGlobals: true)
    let cache: [KVCache] = owners.enumerated().map { layer, resource in
      PrefixKVCache(layer: layer, ownership: resource) { capture.update(layer: $0, offset: $1, keys: $2, values: $3) }
    }
    capture.primaryCache = cache.first as? PrefixKVCache
    let sourceProgress = prefill.progress
    suffix.progress = { processed, total in
      capture.progress(processed: processed, total: total); sourceProgress?(count + processed, count + total)
    }
    let observation = Observation(algorithm: Self.activeAlgorithm, originalGeometry: geometry,
      suffixGeometry: suffixGeometry, fullPromptTokens: promptTokenIDs.count,
      cachedPromptTokens: count, suffixPromptTokens: promptTokenIDs.count - count,
      missReason: count > 0 ? nil : admissionRefused ? "native_admission_refused" : emptyReason ?? "no_active_supported_prefix",
      cachedOrigin: history.last?.origin, cachedBatchWidth: selected?.batchWidth,
      cachedRow: selected?.row, cachedForwardHistory: history, retainedBytes: retainedBytesUpperBound,
      byteLimit: byteLimit, cachedJoinedRetentionProvenance: selected?.joinedRetentionProvenance,
      nativeTensorBytes: retainedNativeBytesUpperBound, cachedNativePhysicalWidth: selected?.nativePhysicalWidth)
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
    }.map { original -> Entry in
      var value = original; value.nativePhysicalWidth = physical
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
      for id in Array(self.entries.keys) { self.remove(id) }; self.indices.removeAll()
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
  /// Caller retains the coordinator/executor lease across producer join, the
  /// existing fence, owner approval and this retention-only publication. This
  /// never reopens a journal, displays a result, or makes cancellation succeed.
  @discardableResult func publishJoinedValidPrefix(_ session: Session,
    proof: JoinedKVRetentionProof, authorization: JoinedKVRetentionAuthorization,
    acknowledged: [Completion] = []) -> Bool {
    let trace = PerformanceTrace.begin("Model.KVRetentionPublish")
    defer { PerformanceTrace.end("Model.KVRetentionPublish", trace) }
    guard proof.permitsRetention,
      proof.termination != .constructorCancelled || acknowledged.isEmpty else { return false }
    defer { session.capture?.discard() }
    guard let owner = session.owner, let binding = session.joinedRetentionBinding,
      binding.owner == owner, binding == authorization.binding, let capture = session.capture else { return false }
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
      return adoptNative(session, values: values, completions: acknowledged,
        acknowledged: acknowledged, authorization: authorization, binding: binding)
    }
    lock.lock(); defer { lock.unlock() }
    guard publicationTicket == session.epoch else { return false }
    return authorization.withAuthorization(binding: binding) {
      publicationTicket = nil
      var added = false
      for value in values {
        for old in entries.values.filter({ $0.entry.owner.namespace == owner.namespace
          && $0.entry.tokens == value.tokens }).map({ $0.entry.id }) { remove(old) }
        insert(value); added = true
      }
      while bytes > byteLimit || entries.count > 128 {
        guard let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
        remove(oldest)
      }
      return added && values.contains { entries[$0.id] != nil }
    } ?? false
  }
  @discardableResult func publish(_ session: Session, completions: [Completion] = [],
    acknowledged: [Completion] = []) -> Bool {
    let trace = PerformanceTrace.begin("Model.KVRetentionPublish")
    defer { PerformanceTrace.end("Model.KVRetentionPublish", trace) }
    guard let owner = session.owner else { return false }
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
        remove(old)
      }
      insert(value); added = true
    }
    while bytes > byteLimit || entries.count > 128 {
      guard let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
      remove(oldest)
    }
    return added && values.contains { entries[$0.id] != nil }
  }
  private func reserve(incoming: UInt64, epoch: UUID,
    allow: (@Sendable (UInt64) -> Bool)?) -> ReservationDecision {
    let trace = PerformanceTrace.begin("Model.KVRetentionReserve")
    defer { PerformanceTrace.end("Model.KVRetentionReserve", trace) }
    lock.lock()
    guard publicationTicket == epoch else { lock.unlock(); return .staleTicket }
    var evicted = false
    while Self.adding(bytes, incoming) > byteLimit {
      guard let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
      // Capture and exact hydration leases protect source backings after entry
      // retirement; releasing optional descriptors does not credit lazy inputs.
      remove(oldest); evicted = true
    }
    let withinPool = Self.adding(bytes, incoming) <= byteLimit
    lock.unlock()
    if evicted { Memory.clearCache() }
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
    guard captureLeases[lease, default: []].insert(id).inserted else { return }
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
    for span in entry.spans.flatMap({ $0 }) where seen.insert(span.id).inserted {
      if var backing = backings[span.id] { backing.references += 1; backings[span.id] = backing }
      else {
        let amount = span.backingBytesUpperBound
        backings[span.id] = Backing(bytes: amount, references: 1); bytes = Self.adding(bytes, amount)
      }
    }
  }
  private func remove(_ id: UUID) {
    guard let stored = entries.removeValue(forKey: id) else { return }
    indices[stored.entry.owner.namespace]?.remove(id: id)
    var seen: Set<UUID> = []
    for span in stored.entry.spans.flatMap({ $0 }) where seen.insert(span.id).inserted {
      releaseBackingLocked(span.id)
    }
  }
  fileprivate static func clippedHistory(_ history: [ForwardSegment], through count: Int) -> [ForwardSegment] {
    history.filter { $0.startTokenCount < count }.map { segment in
      ForwardSegment(origin: segment.origin, startTokenCount: segment.startTokenCount,
        endTokenCount: min(segment.endTokenCount, count), batchWidth: segment.batchWidth,
        row: segment.row, promptTokenCount: segment.promptTokenCount, geometry: segment.geometry,
        evaluatedEndTokenCount: segment.evaluatedEndTokenCount ?? segment.endTokenCount)
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
