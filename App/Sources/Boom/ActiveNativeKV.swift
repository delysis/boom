import BoomCore
import Foundation
import MLX
import MLXLMCommon

/// The only sendability bridge is ownership/release of a native cache and its
/// sources. Access and mutation of `native` stay on the exclusive inference
/// executor/producer lease. The lock protects byte metadata only. Nothing assumes MLX donation.
final class PrefixKVNativeOwnership: @unchecked Sendable {
  let id = UUID()
  private var nativeStorage: (any KVCache)?
  var native: any KVCache { nativeStorage! }
  private var dependencyLease: PrefixKVDependencyLease?
  private var sources: [PrefixKVNativeOwnership]
  private var materializedSources: [PrefixKVNativeOwnership]
  private let lock = NSLock()
  private var byteBound: UInt64 = 0
  private let changed: @Sendable (UUID, UInt64) -> Void
  private let closed: @Sendable (UUID) -> Void

  init(native: any KVCache, dependencyLease: PrefixKVDependencyLease? = nil,
    sources: [PrefixKVNativeOwnership] = [], materializedSources: [PrefixKVNativeOwnership] = [],
    changed: @escaping @Sendable (UUID, UInt64) -> Void = { _, _ in },
    closed: @escaping @Sendable (UUID) -> Void = { _ in }) {
    self.nativeStorage = native; self.dependencyLease = dependencyLease; self.sources = sources; self.materializedSources = materializedSources
    self.changed = changed; self.closed = closed
    refreshCapacity()
  }
  var retainedBytesUpperBound: UInt64 {
    lock.lock(); defer { lock.unlock() }; return byteBound
  }
  /// Called after native metadata changes; reads shapes/bytes, never tensor data.
  func refreshCapacity() {
    let amount = native.innerState().reduce(UInt64(0)) {
      PromptPrefixCache.adding($0, UInt64(max(0, $1.nbytes)))
    }
    lock.lock()
    guard amount > byteBound else { lock.unlock(); return }
    byteBound = amount; lock.unlock()
    changed(id, amount)
  }
  /// Only two-nonempty-piece row concatenation sources may close here. The
  /// caller proves their native graph was submitted, then joined/fenced. Generic
  /// views/hydration aliases in `sources` and `dependencyLease` never use this.
  func releaseMaterializedSourcesAfterJoinedSubmission() { materializedSources.removeAll() }
  deinit {
    // Release the actual native cache/graphs before its source ownership and
    // accounting lease. No logical offset is treated as an alias-release proof.
    nativeStorage = nil
    dependencyLease = nil; sources.removeAll(); materializedSources.removeAll()
    closed(id)
  }
}

/// Joined-boundary admission describes *new allocations*, not released bytes.
/// Current OS/MLX accounting already includes all active parents and leases.
/// A submitted boundary already charges queued native buffers in measured U.
/// The runner readmits the next one/two forwards without assuming GPU completion.
/// Existing reserve, memory watch and joined final checks remain authoritative.
struct ActiveNativeKVAllocation: Codable, Sendable {
  let destinationBytes: UInt64
  let zeroExtensionBytes: UInt64
  let hydrationBytes: UInt64
  let sharedPrefillBytes: UInt64
  let grows: Bool
}
struct ActiveNativeKVAdmissionPlan: Codable, Sendable {
  let cachedTokenCount: Int
  let promptTokenCount: Int
  let reservedOutputTokenCount: Int
  let consumerWidth: Int
  let sourceWidth: Int
  let sourceRow: Int?
  let layers: [ActiveNativeKVAllocation]
  /// Reserve one next forward at an explicit throwing batch boundary, two
  /// forwards for pipelined decode or the final-chunk-plus-tail prefill edge.
  /// Source parents are already in measured U; initial hydration is additional.
  func transitionAllocations(width: Int, forwards: Int, hydration: Bool) throws -> [ActiveNativeKVAllocation] {
    guard (1...4).contains(width), (1...2).contains(forwards), consumerWidth > 0 else {
      throw BoomError.invalid("Invalid native KV allocation horizon.")
    }
    func scaled(_ value: UInt64) throws -> UInt64 {
      guard value % UInt64(consumerWidth) == 0 else { throw BoomError.invalid("Incoherent native allocation width.") }
      let (row, first) = (value / UInt64(consumerWidth)).multipliedReportingOverflow(by: UInt64(width))
      let (result, second) = row.multipliedReportingOverflow(by: UInt64(forwards))
      guard !first, !second else { throw BoomError.invalid("Native KV allocation horizon overflowed.") }
      return result
    }
    return try layers.map { layer in
      ActiveNativeKVAllocation(destinationBytes: try scaled(layer.destinationBytes),
        zeroExtensionBytes: try scaled(layer.zeroExtensionBytes),
        hydrationBytes: hydration ? layer.hydrationBytes : 0,
        // At readmission actual shared-prefill parents are already charged in U.
        sharedPrefillBytes: 0, grows: layer.grows)
    }
  }
}

struct ActiveNativeKVReadmissionObservation: Codable, Sendable {
  let checks: Int
  let denied: Bool
  let width: Int
  let pendingForwards: Int
}

/// Metadata-only cross-task bridge. Admission and MLX reads occur synchronously
/// on the current owned constructor/producer/batch executor. The lock protects
/// denial and metrics only; no cache or tensor is accessed under another task.
final class ActiveNativeKVReadmission: @unchecked Sendable {
  private let lock = NSLock()
  private var checks = 0, lastWidth = 1, lastForwards = 2
  private var refused = false, singleDecodeArmed = false
  private let flag: CancellationFlag
  private let authorization: JoinedKVRetentionAuthorization?
  private let admit: @Sendable (Int, Int) throws -> Void
  init(flag: CancellationFlag, authorization: JoinedKVRetentionAuthorization?,
    admit: @escaping @Sendable (Int, Int) throws -> Void) {
    self.flag = flag; self.authorization = authorization; self.admit = admit
  }
  var denied: Bool { lock.lock(); defer { lock.unlock() }; return refused }
  var observation: ActiveNativeKVReadmissionObservation {
    lock.lock(); defer { lock.unlock() }
    return .init(checks: checks, denied: refused, width: lastWidth, pendingForwards: lastForwards)
  }
  private func reserve(width: Int, forwards: Int) {
    if flag.isCancelled { return }
    lock.lock()
    if refused { lock.unlock(); return }
    checks += 1; lastWidth = width; lastForwards = forwards; lock.unlock()
    let trace = PerformanceTrace.begin("Model.ActiveKVAdmission")
    defer { PerformanceTrace.end("Model.ActiveKVAdmission", trace) }
    do { try admit(width, forwards) }
    catch {
      lock.lock(); refused = true; lock.unlock()
      authorization?.revoke()
      flag.cancel()
      // GenerationWorker preserves its Swift task on a serial executor. This
      // closes the producer-start/handler-install race without escaping a task.
      // The current lazy forward was admitted at the preceding boundary; only
      // further forwards stop. It still submits and joins through the old path.
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }
  func afterSubmittedPrefill(processed: Int, total: Int) {
    guard processed > 0, processed < total else { return }
    // There is no cancellation check between the last chunk callback and final
    // Gemma logits. The previous two-forward allowance covers that tail even
    // when this callback refuses. Terminal progress proves no submission.
    reserve(width: 1, forwards: 2)
  }
  func startSingleDecodeAfterConstructorSubmission() throws {
    reserve(width: 1, forwards: 1); try requireAdmitted()
    lock.lock(); singleDecodeArmed = true; lock.unlock()
  }
  func afterSingleSampleBeforeSubmission() {
    lock.lock(); let armed = singleDecodeArmed; lock.unlock()
    if armed { reserve(width: 1, forwards: 2) }
  }
  func beforeBatchForward(width: Int) throws {
    reserve(width: width, forwards: 1); try requireAdmitted()
  }
  func requireAdmitted() throws {
    if denied { throw BoomError.budget("The active native KV continuation exceeded its measured allocation allowance.") }
  }
}

enum ActiveNativeKVStorage {
  static func rowWidth(_ owners: [PrefixKVNativeOwnership]) throws -> Int {
    let widths = Set(owners.flatMap { $0.native.innerState().filter { $0.ndim == 4 }.map { $0.dim(0) } })
    guard widths.count == 1, let width = widths.first, (1...4).contains(width) else {
      throw BoomError.invalid("Active native KV has no coherent physical row width.")
    }
    return width
  }
  static func plan(owners: [PrefixKVNativeOwnership], layouts: [PrefixKVStorage.Layout],
    prefix: Int, prompt: Int, output: Int, width: Int, row: Int?, prefill: PrefillParameters
  ) throws -> ActiveNativeKVAdmissionPlan {
    guard owners.count == layouts.count, !owners.isEmpty, prefix > 0, prefix < prompt,
      output > 0, (1...4).contains(width) else { throw BoomError.invalid("Invalid active native KV admission coordinates.") }
    let sourceWidth = try rowWidth(owners)
    guard (0..<sourceWidth).contains(row ?? 0) else { throw BoomError.invalid("Invalid active native source row.") }
    let (target, overflow) = prompt.addingReportingOverflow(output)
    guard !overflow, target <= 16_384 else { throw BoomError.budget("The request exceeds the context ceiling.") }
    let suffix = prompt - prefix
    let stride = prefill.chunkLength(forChunking: max(0, suffix - 1))
    let chunk = stride.map { max(1, min($0, max(1, suffix - 1))) } ?? suffix
    let values = try owners.indices.map { layer -> ActiveNativeKVAllocation in
      let native = owners[layer].native, arrays = native.innerState().filter { $0.ndim == 4 }
      let actualOffset = try rowOffset(native, row: row ?? 0)
      guard arrays.count == 2, actualOffset >= prefix else { throw BoomError.invalid("Active native KV does not cover its authorized prefix.") }
      try PrefixKVStorage.validatePair(arrays[0], arrays[1])
      let keys = arrays[0], vals = arrays[1], capacity = keys.dim(2)
      let positionBytes = try sum(try product(UInt64(keys.dim(1)), UInt64(keys.dim(3)), UInt64(keys.dtype.size)),
        try product(UInt64(vals.dim(1)), UInt64(vals.dim(3)), UInt64(vals.dtype.size)))
      let finalCapacity: Int, hydrationPositions: Int, extensionPositions: Int, grows: Bool
      switch layouts[layer] {
      case .simple(let step):
        guard step > 0 else { throw BoomError.invalid("Invalid native full-attention step.") }
        let (rowCapacity, rowOverflow) = capacity.addingReportingOverflow(sourceWidth == 1 ? 0 : step)
        guard !rowOverflow else { throw BoomError.invalid("Native row capacity overflowed.") }
        if rowCapacity >= target {
          finalCapacity = rowCapacity; extensionPositions = 0; grows = false
        } else {
          let (padded, paddingOverflow) = target.addingReportingOverflow(step - 1)
          guard !paddingOverflow else { throw BoomError.invalid("Native capacity overflowed.") }
          finalCapacity = padded
          // Native Simple's zero-extension size is based on one actual forward,
          // not the full old prefix or the whole request's accumulated growth.
          let (ceilInput, ceilOverflow) = chunk.addingReportingOverflow(step - 1)
          guard !ceilOverflow else { throw BoomError.invalid("Native extension overflowed.") }
          let (extensionSize, extensionOverflow) = (ceilInput / step).multipliedReportingOverflow(by: step)
          guard !extensionOverflow else { throw BoomError.invalid("Native extension overflowed.") }
          extensionPositions = extensionSize; grows = true
        }
        if sourceWidth == 1 { hydrationPositions = 0 }
        else {
          // selectedGlobal constructs both zeros(step) and concat(capacity+step).
          // Neither the source parent nor the zero input is discounted before
          // actual allocation/submission; later growth G is a separate bound.
          let (positions, hydrationOverflow) = rowCapacity.addingReportingOverflow(step)
          guard !hydrationOverflow else { throw BoomError.invalid("Native row hydration overflowed.") }
          hydrationPositions = positions
        }
      case .rotating(let window, _, let step, _):
        guard step > 0 else { throw BoomError.invalid("Invalid native sliding step.") }
        let direct = sourceWidth == 1 && (native.offset == prefix || native.isTrimmable && native.offset >= prefix)
        let startingCapacity = direct ? capacity : min(prefix, window)
        let (temporary, tempOverflow) = window.addingReportingOverflow(chunk - 1)
        guard !tempOverflow else { throw BoomError.invalid("Native sliding capacity overflowed.") }
        finalCapacity = max(min(startingCapacity, window), min(target, temporary))
        extensionPositions = target > startingCapacity && startingCapacity < window
          ? min(step, window - startingCapacity) : 0
        // Multi-token concat, startup growth and oversized-ring compaction may
        // require concatenate output beside a non-donated write destination.
        grows = chunk > 1 || extensionPositions > 0 || direct && capacity > window
        hydrationPositions = direct ? 0 : min(prefix, window)
      }
      let destination = try product(positionBytes, UInt64(finalCapacity), UInt64(width))
      let extensionBytes = try product(positionBytes, UInt64(extensionPositions), UInt64(width))
      let hydration = try product(positionBytes, UInt64(hydrationPositions))
      // Shared width-one prepare can remain a parent of the batched destination.
      // This is an allocation reservation, not a second charge for held KV.
      let shared = width > 1 ? try product(positionBytes, UInt64(finalCapacity)) : 0
      return ActiveNativeKVAllocation(destinationBytes: destination,
        zeroExtensionBytes: extensionBytes, hydrationBytes: hydration,
        sharedPrefillBytes: shared, grows: grows)
    }
    return ActiveNativeKVAdmissionPlan(cachedTokenCount: prefix, promptTokenCount: prompt,
      reservedOutputTokenCount: output, consumerWidth: width, sourceWidth: sourceWidth,
      sourceRow: row, layers: values)
  }
  /// Historical candidates have file-owned metadata, not a pretend native
  /// cache. Reserve their real row read buffer and newly hydrated allocation
  /// before file IO; the unrelated current hot owner remains in measured U.
  static func diskPlan(layouts: [PrefixKVStorage.Layout], spans: [[PrefixKVSpan]],
    prefix: Int, prompt: Int, output: Int, width: Int, prefill: PrefillParameters
  ) throws -> ActiveNativeKVAdmissionPlan {
    guard !layouts.isEmpty, layouts.count == spans.count, prefix > 0, prefix < prompt,
      output > 0, (1...4).contains(width) else { throw BoomError.invalid("Invalid disk KV admission coordinates.") }
    let (target, overflow) = prompt.addingReportingOverflow(output)
    guard !overflow, target <= 16_384 else { throw BoomError.budget("The request exceeds the context ceiling.") }
    let suffix = prompt - prefix
    let stride = prefill.chunkLength(forChunking: max(0, suffix - 1))
    let chunk = stride.map { max(1, min($0, max(1, suffix - 1))) } ?? suffix
    let layers = try layouts.indices.map { layer -> ActiveNativeKVAllocation in
      guard let first = spans[layer].first, first.diskFileID != nil,
        spans[layer].allSatisfy({ $0.diskFileID != nil && $0.layer == layer
          && $0.keyShape[1] == first.keyShape[1] && $0.keyShape[3] == first.keyShape[3]
          && $0.valueShape[3] == first.valueShape[3]
          && $0.keyType == first.keyType && $0.valueType == first.valueType }) else {
        throw BoomError.invalid("Historical KV has no coherent disk-owned layer geometry.")
      }
      let position = try sum(try product(UInt64(first.keyShape[1]), UInt64(first.keyShape[3]), UInt64(first.keyType.size)),
        try product(UInt64(first.valueShape[1]), UInt64(first.valueShape[3]), UInt64(first.valueType.size)))
      let capacity: Int, extensionSize: Int, hydratedPositions: Int, grows: Bool
      switch layouts[layer] {
      case .simple(let step):
        guard step > 0 else { throw BoomError.invalid("Invalid historical full-attention step.") }
        let (padded, paddingOverflow) = target.addingReportingOverflow(step - 1)
        let (ceilInput, ceilOverflow) = chunk.addingReportingOverflow(step - 1)
        let (extensionValue, extensionOverflow) = (ceilInput / step).multipliedReportingOverflow(by: step)
        guard !paddingOverflow, !ceilOverflow, !extensionOverflow else { throw BoomError.invalid("Disk KV capacity overflowed.") }
        capacity = padded; extensionSize = extensionValue; hydratedPositions = prefix; grows = true
      case .rotating(let window, let keep, let step, _):
        guard window > keep, keep >= 0, step > 0 else { throw BoomError.invalid("Invalid historical sliding geometry.") }
        let (temporary, tempOverflow) = window.addingReportingOverflow(chunk - 1)
        guard !tempOverflow else { throw BoomError.invalid("Disk sliding capacity overflowed.") }
        let initial = min(prefix, window)
        capacity = max(initial, min(target, temporary))
        extensionSize = target > initial && initial < window ? min(step, window - initial) : 0
        hydratedPositions = initial; grows = chunk > 1 || extensionSize > 0
      }
      // Host pread bytes, immediate native raw-data copies and a possible
      // concatenate destination can coexist. Reserve all three, no release credit.
      let hydration = try product(position, UInt64(hydratedPositions), 3)
      return ActiveNativeKVAllocation(destinationBytes: try product(position, UInt64(capacity), UInt64(width)),
        zeroExtensionBytes: try product(position, UInt64(extensionSize), UInt64(width)),
        hydrationBytes: hydration,
        sharedPrefillBytes: width > 1 ? try product(position, UInt64(capacity)) : 0, grows: grows)
    }
    return ActiveNativeKVAdmissionPlan(cachedTokenCount: prefix, promptTokenCount: prompt,
      reservedOutputTokenCount: output, consumerWidth: width, sourceWidth: 1, sourceRow: nil, layers: layers)
  }
  static func rowOffset(_ cache: any KVCache, row: Int) throws -> Int {
    if let batch = PrefixKVStorage.unwrap(cache) as? any BatchKVCacheProtocol {
      return try batch.logicalOffset(row: row)
    }
    return cache.offset
  }
  static func selectedGlobal(_ source: PrefixKVNativeOwnership, prefix: Int, row: Int,
    preservingSource: Bool = false, makeOwner: (any KVCache, [PrefixKVNativeOwnership], Bool) -> PrefixKVNativeOwnership
  ) throws -> PrefixKVNativeOwnership {
    if let batch = source.native as? BatchKVCache {
      let extracted = try batch.extract(row: row, through: prefix)
      return makeOwner(extracted, [source], true)
    }
    guard let original = source.native as? KVCacheSimple, original.offset >= prefix,
      prefix > 0 else { throw BoomError.invalid("Invalid active full-attention prefix.") }
    let arrays = original.innerState()
    guard arrays.count == 2 else { throw BoomError.invalid("Active full-attention KV is empty.") }
    try PrefixKVStorage.validatePair(arrays[0], arrays[1])
    let width = arrays[0].dim(0)
    guard (0..<width).contains(row) else { throw BoomError.invalid("Invalid active full-attention row.") }
    if width == 1 {
      if preservingSource {
        let fork = original.copy()
        _ = fork.trim(fork.offset - prefix)
        guard fork.offset == prefix else { throw BoomError.invalid("Native prefix fork has another offset.") }
        return makeOwner(fork, [source], false)
      }
      guard original.trim(original.offset - prefix) >= 0, original.offset == prefix else {
        throw BoomError.invalid("Native full-attention offset transfer failed.")
      }
      return source
    }
    // A row view is not detached. Construct admitted width-one destination
    // arrays lazily and keep the *full* source ownership until this cache dies.
    // Existing prepare/evaluation submits this work; no extra eval or fence.
    var copied: [MLXArray] = []
    for array in arrays {
      let zeros = MLXArray.zeros([1, array.dim(1), original.step, array.dim(3)], dtype: array.dtype)
      // Full-slice assignment and copy() can alias in the pinned runtime. Two
      // nonempty concatenate inputs allocate a destination, also preserving a
      // real step of spare native capacity. Parent closure waits for submission.
      copied.append(concatenated([array[row..<(row + 1), 0..., 0..., 0...], zeros], axis: 2))
    }
    let native = KVCacheSimple(); native.step = original.step; native.state = copied
    _ = native.trim(native.offset - prefix)
    guard native.offset == prefix else { throw BoomError.invalid("Selected native row has the wrong logical offset.") }
    return makeOwner(native, [source], true)
  }
  private static func sum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (result, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw BoomError.invalid("Native allocation bytes overflowed.") }; return result
  }
  private static func product(_ values: UInt64...) throws -> UInt64 {
    try values.reduce(UInt64(1)) { previous, value in
      let (result, overflow) = previous.multipliedReportingOverflow(by: value)
      guard !overflow else { throw BoomError.invalid("Native allocation bytes overflowed.") }; return result
    }
  }
}
