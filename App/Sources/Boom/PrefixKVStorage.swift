import BoomCore
import Foundation
import MLX
import MLXLMCommon

/// Metadata-only ownership for source buffers reachable from hydrated cache
/// arrays. Evaluation may detach graphs, but slices may still alias their input
/// backing. Release follows cache ownership, never a guessed token boundary.
final class PrefixKVDependencyLease: Sendable {
  private let onRelease: @Sendable () -> Void
  init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
  deinit { onRelease() }
}

/// Transparent observation of the app's full-precision, non-speculative caches.
/// The tap is synchronous and confined to the owner's inference executor. This
/// adapter has no retention policy and does not observe independently copied KV.
final class PrefixKVCache: KVCache {
  typealias UpdateTap = (Int, Int, MLXArray, MLXArray) -> Void
  private var ownership: PrefixKVNativeOwnership?
  fileprivate var base: any KVCache { ownership!.native }
  private var sealed = false
  private let layer: Int
  private let onUpdate: UpdateTap

  init(layer: Int, base: any KVCache, dependencyLease: PrefixKVDependencyLease? = nil,
    onUpdate: @escaping UpdateTap) {
    self.layer = layer
    self.ownership = PrefixKVNativeOwnership(native: base, dependencyLease: dependencyLease)
    self.onUpdate = onUpdate
  }
  init(layer: Int, ownership: PrefixKVNativeOwnership, onUpdate: @escaping UpdateTap) {
    self.layer = layer; self.ownership = ownership; self.onUpdate = onUpdate
  }
  /// Existing producer join/fence is a caller precondition. The old wrapper is
  /// read-only for final metrics; the same native owner/lease moves to the slot.
  func sealForJoinedTransfer() -> PrefixKVNativeOwnership {
    sealed = true; return ownership!
  }
  deinit {
    // Normal runner teardown occurs after its producer join and existing fence.
    // Drop this native cache's array ownership before its source-buffer lease.
    ownership = nil
  }
  var offset: Int { base.offset }
  var ropeOffset: RoPEOffset { base.ropeOffset }
  var maxSize: Int? { base.maxSize }
  var state: [MLXArray] {
    get { base.state }
    set {
      // KVCache is not class constrained. Supported native caches are reference
      // types; copying the existential preserves the object being restored.
      precondition(!sealed, "A transferred native wrapper is read-only.")
      var target = base; target.state = newValue; ownership?.refreshCapacity()
    }
  }
  var metaState: [String] {
    get { base.metaState }
    set { precondition(!sealed); var target = base; target.metaState = newValue; ownership?.refreshCapacity() }
  }
  var isTrimmable: Bool { base.isTrimmable }
  func isTrimmable(after positions: Int) -> Bool { base.isTrimmable(after: positions) }
  @discardableResult func trim(_ n: Int) -> Int { precondition(!sealed); return base.trim(n) }
  func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
    base.makeMask(n: n, windowSize: windowSize, returnArray: returnArray)
  }
  func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
    precondition(!sealed, "A transferred native wrapper cannot update.")
    onUpdate(layer, base.offset, keys, values)
    let value = base.update(keys: keys, values: values)
    ownership?.refreshCapacity(); return value
  }
  func prepare(lengths: [Int]?) { precondition(!sealed); base.prepare(lengths: lengths) }
  func prepare(lengths: MLXArray?) { precondition(!sealed); base.prepare(lengths: lengths) }
  func finalize() { precondition(!sealed); base.finalize() }
  func innerState() -> [MLXArray] { base.innerState() }
  func copy() -> any KVCache {
    let independent = base.copy()
    guard let ownership else { return independent }
    // A native descriptor copy may alias its whole source. Preserve the source
    // owner and every hydration lease rather than claiming detachment.
    return PrefixKVCache(layer: layer, ownership: PrefixKVNativeOwnership(native: independent,
      sources: [ownership])) { _, _, _, _ in }
  }
}

/// The same observation wrapper for a genuine independent-row cache. A scalar
/// wrapper never conforms to the batch protocol, so ordinary prepare stays scalar.
final class PrefixBatchKVCache: BatchKVCacheProtocol {
  private var ownership: PrefixKVNativeOwnership?
  fileprivate var base: any BatchKVCacheProtocol { ownership!.native as! any BatchKVCacheProtocol }
  private let layer: Int
  private let onUpdate: (Int, MLXArray, MLXArray) -> Void
  private let onFinalize: (Int) -> Void
  private var sealed = false
  init(layer: Int, ownership: PrefixKVNativeOwnership,
    onUpdate: @escaping (Int, MLXArray, MLXArray) -> Void,
    onFinalize: @escaping (Int) -> Void) {
    self.layer = layer; self.ownership = ownership
    self.onUpdate = onUpdate; self.onFinalize = onFinalize
  }
  deinit { ownership = nil }
  var offset: Int { base.offset }
  var batchSize: Int { base.batchSize }
  var batchOffset: MLXArray { base.batchOffset }
  var rowPositionState: [MLXArray] { base.rowPositionState }
  var ropeOffset: RoPEOffset { base.ropeOffset }
  var maxSize: Int? { base.maxSize }
  var state: [MLXArray] {
    get { base.state }
    set { precondition(!sealed); var target = base; target.state = newValue; ownership?.refreshCapacity() }
  }
  var metaState: [String] {
    get { base.metaState }
    set { precondition(!sealed); var target = base; target.metaState = newValue }
  }
  var isTrimmable: Bool { base.isTrimmable }
  func isTrimmable(after positions: Int) -> Bool { base.isTrimmable(after: positions) }
  func trim(_ n: Int) -> Int { precondition(!sealed); return base.trim(n) }
  func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
    base.makeMask(n: n, windowSize: windowSize, returnArray: returnArray)
  }
  func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
    precondition(!sealed); onUpdate(layer, keys, values)
    let value = base.update(keys: keys, values: values)
    ownership?.refreshCapacity(); return value
  }
  func prepare(lengths: [Int]?) { precondition(!sealed); base.prepare(lengths: lengths) }
  func prepare(lengths: MLXArray?) { precondition(!sealed); base.prepare(lengths: lengths) }
  func finalize() { precondition(!sealed); base.finalize(); onFinalize(layer) }
  func innerState() -> [MLXArray] { base.innerState() }
  func logicalOffset(row: Int) throws -> Int { try base.logicalOffset(row: row) }
  func extract(row: Int) throws -> any KVCache { try base.extract(row: row) }
  func extract(row: Int, through position: Int) throws -> any KVCache {
    try base.extract(row: row, through: position)
  }
  func copy() -> any KVCache {
    guard let ownership else { return base.copy() }
    return PrefixBatchKVCache(layer: layer,
      ownership: PrefixKVNativeOwnership(native: base.copy(), sources: [ownership]),
      onUpdate: { _, _, _ in }, onFinalize: { _ in })
  }
  func sealForJoinedTransfer() { sealed = true }
}

/// Immutable descriptors of one chronological incoming span. IDs identify its
/// backing across row views and entry forks; constructing a descriptor never
/// evaluates, fences, decodes or reads tensor contents.
struct PrefixKVSpan {
  private enum Storage {
    case resident(MLXArray, MLXArray)
    case disk(PrefixKVDiskFile, keysOffset: UInt64, valuesOffset: UInt64)
  }
  let id: UUID
  let start: Int
  let end: Int
  let batchWidth: Int
  let layer: Int
  let keyShape: [Int]
  let valueShape: [Int]
  let keyType: DType
  let valueType: DType
  /// RAM bound; immutable disk spans charge zero resident bytes. The store
  /// separately charges disk bytes, while ready in-flight parents stay charged.
  let backingBytesUpperBound: UInt64
  private let storage: Storage
  private let sourcePositions: Range<Int>
  private let sourceRows: Range<Int>

  init(id: UUID = UUID(), offset: Int, layer: Int, keys: MLXArray, values: MLXArray,
    backingBytesUpperBound: UInt64? = nil) throws {
    try PrefixKVStorage.validatePair(keys, values)
    let bytes = try PrefixKVStorage.pairBytes(keys, values)
    guard backingBytesUpperBound.map({ $0 >= bytes }) ?? true else {
      throw BoomError.invalid("The KV backing bound is smaller than its declared view.")
    }
    try self.init(id: id, offset: offset, layer: layer,
      keyShape: keys.shape, valueShape: values.shape, keyType: keys.dtype, valueType: values.dtype,
      storage: .resident(Self.detachedDescriptor(keys), Self.detachedDescriptor(values)),
      rows: 0..<keys.dim(0), positions: 0..<keys.dim(2),
      bound: backingBytesUpperBound ?? bytes)
  }
  /// Own an independent array context while sharing its existing backing.
  /// Updating the caller's Swift wrapper must not change this immutable span.
  /// MLX context assignment adds no primitive, evaluation or tensor copy.
  private static func detachedDescriptor(_ array: MLXArray) -> MLXArray {
    let snapshot = MLXArray.mlxNone
    snapshot._updateInternal(array)
    return snapshot
  }
  init(disk: PrefixKVDiskFile, offset: Int, layer: Int, keyShape: [Int], valueShape: [Int],
    keyType: DType, valueType: DType, keysOffset: UInt64, valuesOffset: UInt64) throws {
    guard keyShape.count == 4, valueShape.count == 4 else {
      throw BoomError.invalid("Invalid disk KV dimensions.")
    }
    try self.init(id: UUID(), offset: offset, layer: layer,
      keyShape: keyShape, valueShape: valueShape, keyType: keyType, valueType: valueType,
      storage: .disk(disk, keysOffset: keysOffset, valuesOffset: valuesOffset),
      rows: 0..<keyShape[0], positions: 0..<keyShape[2], bound: 0)
  }
  private init(id: UUID, offset: Int, layer: Int, keyShape: [Int], valueShape: [Int],
    keyType: DType, valueType: DType, storage: Storage, rows: Range<Int>,
    positions: Range<Int>, bound: UInt64) throws {
    let floating: [DType] = [.float16, .bfloat16, .float32]
    guard offset >= 0, layer >= 0, keyShape.count == 4, valueShape.count == 4,
      keyShape.allSatisfy({ $0 > 0 }), valueShape.allSatisfy({ $0 > 0 }),
      keyShape[0...2] == valueShape[0...2], floating.contains(keyType), floating.contains(valueType),
      !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= keyShape[0],
      !positions.isEmpty, positions.lowerBound >= 0, positions.upperBound <= keyShape[2] else {
      throw BoomError.invalid("Invalid native KV span metadata.")
    }
    let (upper, overflow) = offset.addingReportingOverflow(positions.count)
    guard !overflow else { throw BoomError.invalid("KV span coordinates overflowed.") }
    self.id = id; start = offset; end = upper; self.layer = layer; batchWidth = rows.count
    self.keyShape = keyShape; self.valueShape = valueShape; self.keyType = keyType; self.valueType = valueType
    self.storage = storage; sourceRows = rows; sourcePositions = positions; backingBytesUpperBound = bound
  }
  /// Relative logical slicing never builds/evaluates another MLX graph or reads disk.
  func sliced(positions: Range<Int>, row: Int? = nil) throws -> PrefixKVSpan {
    guard positions.lowerBound >= 0, !positions.isEmpty, positions.upperBound <= end - start,
      row.map({ $0 >= 0 && $0 < batchWidth }) ?? true else {
      throw BoomError.invalid("Invalid KV span slice.")
    }
    let rows = row.map { (sourceRows.lowerBound + $0)..<(sourceRows.lowerBound + $0 + 1) } ?? sourceRows
    return try PrefixKVSpan(id: id, offset: start + positions.lowerBound, layer: layer,
      keyShape: keyShape, valueShape: valueShape, keyType: keyType, valueType: valueType,
      storage: storage, rows: rows,
      positions: (sourcePositions.lowerBound + positions.lowerBound)..<(sourcePositions.lowerBound + positions.upperBound),
      bound: backingBytesUpperBound)
  }
  var diskFileID: UUID? {
    if case .disk(let file, _, _) = storage { return file.id }; return nil
  }
  func materialize(row: Int, positions: Range<Int>) throws -> (MLXArray, MLXArray) {
    let view = try sliced(positions: positions, row: row)
    let selected = view.sourceRows.lowerBound, local = view.sourcePositions
    switch storage {
    case .resident(let keys, let values):
      return (keys[selected..<(selected + 1), 0..., local, 0...],
        values[selected..<(selected + 1), 0..., local, 0...])
    case .disk(let file, let keysOffset, let valuesOffset):
      do {
        return (try file.read(offset: keysOffset, shape: keyShape, dtype: keyType, row: selected, positions: local),
          try file.read(offset: valuesOffset, shape: valueShape, dtype: valueType, row: selected, positions: local))
      } catch { throw PrefixKVDiskUnavailable(fileID: file.id, original: error) }
    }
  }
}

enum PrefixKVStorage {
  /// Architecture metadata comes from the actual native prototypes, including
  /// their number of layers. Mutable offset/ring position is not layout identity.
  enum Layout: Hashable, Sendable {
    case simple(step: Int)
    case rotating(window: Int, keep: Int, step: Int, capacityOrigin: String)
  }

  static func unwrap(_ cache: any KVCache) -> any KVCache {
    // Borrow for metadata inspection within the owner's cache lifetime. An
    // unwrapped native cache or state array must not escape that owned scope.
    var current = cache
    while true {
      if let observed = current as? PrefixKVCache { current = observed.base }
      else if let observed = current as? PrefixBatchKVCache { current = observed.base }
      else { return current }
    }
  }

  static func layout(of cache: any KVCache) -> Layout? {
    let native = unwrap(cache), type = ObjectIdentifier(type(of: native))
    if native is BatchKVCache { return .simple(step: 256) }
    if let batch = native as? BatchRotatingKVCache {
      let meta = batch.metaState
      guard meta.count == 5, let window = Int(meta[0]), window > 0,
        ["modelNative", "requested"].contains(meta[4]) else { return nil }
      return .rotating(window: window, keep: 0, step: 256, capacityOrigin: meta[4])
    }
    if type == ObjectIdentifier(KVCacheSimple.self), let simple = native as? KVCacheSimple {
      return simple.step > 0 ? .simple(step: simple.step) : nil
    }
    guard type == ObjectIdentifier(RotatingKVCache.self) else { return nil }
    let meta = native.metaState
    guard meta.count == 7, let keep = Int(meta[0]), let window = Int(meta[1]),
      let step = Int(meta[2]), let offset = Int(meta[3]), let idx = Int(meta[4]),
      Bool(meta[6]) != nil, window > 0, keep >= 0, keep < window, step > 0,
      offset >= 0, idx >= 0, ["modelNative", "requested"].contains(meta[5]) else { return nil }
    return .rotating(window: window, keep: keep, step: step, capacityOrigin: meta[5])
  }

  static func validatePair(_ keys: MLXArray, _ values: MLXArray) throws {
    let floating: [DType] = [.float16, .bfloat16, .float32]
    guard keys.ndim == 4, values.ndim == 4,
      keys.shape.allSatisfy({ $0 > 0 }), values.shape.allSatisfy({ $0 > 0 }),
      keys.dim(0) == values.dim(0), keys.dim(1) == values.dim(1), keys.dim(2) == values.dim(2),
      floating.contains(keys.dtype), floating.contains(values.dtype) else {
      throw BoomError.invalid("Require full-precision four-dimensional KV spans with matching rows, heads and positions.")
    }
  }

  static func pairBytes(_ keys: MLXArray, _ values: MLXArray) throws -> UInt64 {
    guard keys.nbytes >= 0, values.nbytes >= 0 else { throw BoomError.invalid("Invalid KV byte count.") }
    let (bytes, overflow) = UInt64(keys.nbytes).addingReportingOverflow(UInt64(values.nbytes))
    guard !overflow else { throw BoomError.invalid("KV byte accounting overflowed.") }
    return bytes
  }

  /// Concrete physical ring chronology without creating an MLX view. A
  /// temporal prefill buffer can hold additional valid rows beyond W; retaining
  /// them on disk preserves feasible earlier prefixes. Only real held rows are
  /// admitted. The caller retains the original completed raw parent.
  static func readyRingRanges(of cache: any KVCache, after: Int,
    needsPinned: Bool) throws -> [(Int, Range<Int>)] {
    let native = unwrap(cache)
    guard let layout = layout(of: native), case let .rotating(window, keep, _, _) = layout, after >= 0 else {
      throw BoomError.invalid("Require an admitted native rotating ring.")
    }
    let meta = native.metaState, arrays = native.innerState()
    guard arrays.count == 2, let offset = Int(meta[3]), let idx = Int(meta[4]),
      let wrapped = Bool(meta[6]) else { throw BoomError.invalid("Invalid ready ring metadata.") }
    try validatePair(arrays[0], arrays[1])
    let capacity = arrays[0].dim(2), held = wrapped ? capacity : idx
    let pinned = min(keep, offset), tailCount = held - pinned
    guard idx <= capacity, held <= offset, held >= pinned,
      !wrapped || (capacity == window && idx >= keep) else {
      throw BoomError.invalid("Invalid ready ring extent.")
    }
    var result: [(Int, Range<Int>)] = []
    if needsPinned, pinned > 0 { result.append((0, 0..<pinned)) }
    let physical = wrapped && idx < held ? [idx..<held, pinned..<idx] : [pinned..<held]
    var absolute = offset - tailCount
    for range in physical {
      let end = absolute + range.count, start = max(absolute, after, pinned)
      if start < end { result.append((start, (range.lowerBound + start - absolute)..<range.upperBound)) }
      absolute = end
    }
    return result
  }

  /// Actual completed position vectors. Never calls eval/asArray or changes a
  /// producer event. An unready vector is an optimization miss on this producer.
  static func readyBatchPositions(_ cache: any BatchKVCacheProtocol) -> (positions: [Int], padding: [Int])? {
    let values = cache.rowPositionState
    guard values.count == 2 else { return nil }
    func integers(_ value: MLXArray) -> [Int]? {
      guard let buffer = value.readyBuffer(), buffer.dtype == .int32,
        buffer.shape == [cache.batchSize], buffer.strides.count == 1 else { return nil }
      return buffer.withUnsafeBytes { bytes in
        (0..<cache.batchSize).map { row in
          Int(bytes.loadUnaligned(fromByteOffset: buffer.byteOffset + row * buffer.strides[0] * 4, as: Int32.self))
        }
      }
    }
    guard let positions = integers(values[0]), let padding = integers(values[1]) else { return nil }
    return (positions, padding)
  }

  /// Current-hot eligibility is metadata only. The actual joined native owner
  /// must still hold every required interval for this authorized prefix/row.
  /// Earlier resident prefixes are hydrated; an overwritten tail is a miss.
  static func currentRingSupports(_ cache: any KVCache, prefix: Int, row: Int) -> Bool {
    let native = unwrap(cache)
    if let batch = native as? BatchRotatingKVCache {
      guard prefix > 0, (0..<batch.batchSize).contains(row),
        let metadata = readyBatchPositions(batch), metadata.positions[row] >= prefix,
        let window = batch.maxSize,
        let ranges = try? batch.residentRanges(position: metadata.positions[row],
          padding: metadata.padding[row], after: max(0, prefix - window)) else { return false }
      var end = max(0, prefix - window)
      for (start, physical) in ranges where start + physical.count > end {
        guard start <= end else { return false }
        end = min(prefix, start + physical.count)
        if end == prefix { return true }
      }
      return false
    }
    guard prefix > 0, native.offset >= prefix,
      let layout = layout(of: native), case let .rotating(window, keep, _, _) = layout,
      let ranges = try? readyRingRanges(of: native, after: 0, needsPinned: true) else { return false }
    let arrays = native.innerState()
    guard arrays.count == 2, row >= 0, row < arrays[0].dim(0) else { return false }
    let pinned = min(keep, prefix)
    let required = pinned > 0 ? [0..<pinned, max(pinned, prefix - (window - keep))..<prefix]
      : [max(0, prefix - window)..<prefix]
    return required.allSatisfy { wanted in
      var end = wanted.lowerBound
      for (start, range) in ranges where start + range.count > end {
        guard start <= end else { return false }
        end = min(wanted.upperBound, start + range.count)
        if end == wanted.upperBound { return true }
      }
      return wanted.isEmpty
    }
  }

  /// Read at one admitted boundary. These are only current resident views,
  /// bounded by the native window; overwritten sliding history is unavailable.
  /// Wrapped buffers are described as separate chronological slices, never
  /// concatenated or cloned here. Every slice shares the snapshot's backing ID.
  static func residentWindowSpans(of cache: any KVCache, layer: Int, through prefix: Int? = nil) throws -> [PrefixKVSpan] {
    let native = unwrap(cache)
    guard let layout = layout(of: native),
      case let .rotating(window, keep, _, _) = layout else {
      throw BoomError.invalid("Resident-window reads require a known native rotating cache.")
    }
    let meta = native.metaState
    guard let offset = Int(meta[3]), let idx = Int(meta[4]), let wrapped = Bool(meta[6]), layer >= 0 else {
      throw BoomError.invalid("Invalid resident KV metadata.")
    }
    let target = prefix ?? offset
    guard target >= 0, target <= offset else { throw BoomError.invalid("Resident KV prefix exceeds its source.") }
    let arrays = native.innerState()
    if arrays.isEmpty {
      guard offset == 0, idx == 0, !wrapped else { throw BoomError.invalid("Resident KV metadata has no tensor state.") }
      return []
    }
    guard arrays.count == 2 else { throw BoomError.invalid("Invalid resident KV array count.") }
    let keys = arrays[0], values = arrays[1]
    try validatePair(keys, values)
    let capacity = keys.dim(2)
    let held = wrapped ? capacity : idx
    guard idx <= capacity, held <= offset, held >= min(keep, offset),
      !wrapped || (capacity == window && idx >= keep) else {
      throw BoomError.invalid("Resident KV counters do not describe a valid native ring.")
    }
    guard held > 0 else { return [] }
    let pinned = min(keep, held), tailCount = held - pinned
    // Restrict temporary views to the QUERY's required window. Prefill can
    // physically retain more than W positions, including an earlier endpoint.
    let wantedStart = max(pinned, target - (window - keep))
    let id = UUID(), backing = try pairBytes(keys, values)
    var result: [PrefixKVSpan] = []
    func view(_ physical: Range<Int>, absolute: Int) throws {
      guard !physical.isEmpty else { return }
      result.append(try PrefixKVSpan(id: id, offset: absolute, layer: layer,
        keys: keys[0..., 0..., physical, 0...], values: values[0..., 0..., physical, 0...],
        backingBytesUpperBound: backing))
    }
    try view(0..<min(pinned, target), absolute: 0)
    let physicalTail: [Range<Int>]
    if wrapped, idx < held { physicalTail = [idx..<held, pinned..<idx] }
    else { physicalTail = [pinned..<held] }
    var absolute = offset - tailCount
    for physical in physicalTail {
      let end = absolute + physical.count
      let start = max(absolute, wantedStart), upper = min(end, target)
      if start < upper {
        try view((physical.lowerBound + start - absolute)..<(physical.lowerBound + upper - absolute), absolute: start)
      }
      absolute = end
    }
    return result
  }

  /// Full attention needs every prefix row. Sliding attention needs the pinned
  /// prefix and trailing native window only. Gaps outside those retained ranges
  /// remain absent; a hole within any required range refuses hydration.
  /// `batchWidth` is the source entry's width, not the new consumer's width.
  /// Width-one spans are shared prefill or already selected inherited row views.
  static func hydrate(layout: Layout, spans: [PrefixKVSpan], prefix: Int, row: Int,
    batchWidth: Int? = nil, copyResidentPieces: Bool = false,
    onSourceBacking: ((UUID, UInt64) -> Void)? = nil) throws -> any KVCache {
    let width = batchWidth ?? spans.map(\.batchWidth).max() ?? 1
    guard prefix >= 0, width > 0, row >= 0, row < width else {
      throw BoomError.invalid("Invalid requested KV prefix or source row.")
    }
    let native: any KVCache, ranges: [Range<Int>]
    switch layout {
    case .simple(let step):
      guard step > 0 else { throw BoomError.invalid("Invalid native full-attention step.") }
      let fresh = KVCacheSimple(); fresh.step = step; native = fresh
      ranges = prefix > 0 ? [0..<prefix] : []
    case .rotating(let window, let keep, let step, let origin):
      guard window > 0, keep >= 0, keep < window, step > 0,
        ["modelNative", "requested"].contains(origin) else {
        throw BoomError.invalid("Invalid native sliding-window layout.")
      }
      var fresh: any KVCache = RotatingKVCache(maxSize: window, keep: keep, step: step)
      fresh.metaState = [String(keep), String(window), String(step), "0", "0", origin, "false"]
      native = fresh
      if prefix <= window { ranges = prefix > 0 ? [0..<prefix] : [] }
      else {
        let tail = (prefix - (window - keep))..<prefix
        ranges = keep > 0 ? [0..<keep, tail] : [tail]
      }
    }
    let sorted = spans.sorted { $0.start < $1.start }
    if let first = sorted.first {
      var previousEnd = 0
      for span in sorted {
        guard span.layer == first.layer, span.start >= previousEnd, span.end > span.start,
          span.batchWidth > 0,
          span.batchWidth == 1 || span.batchWidth == width,
          span.keyShape[1] == first.keyShape[1], span.keyShape[3] == first.keyShape[3],
          span.valueShape[3] == first.valueShape[3], span.keyType == first.keyType,
          span.valueType == first.valueType else {
          throw BoomError.invalid("KV spans overlap or change their native layer, width or dimensions.")
        }
        previousEnd = span.end
      }
    }
    guard prefix > 0 else { return native }
    var keyPieces: [MLXArray] = [], valuePieces: [MLXArray] = []
    for range in ranges {
      var position = range.lowerBound
      for span in sorted where span.end > position && span.start < range.upperBound {
        guard span.start <= position else { throw BoomError.invalid("Required KV prefix coverage has a hole.") }
        let end = min(span.end, range.upperBound), selected = span.batchWidth == 1 ? 0 : row
        let local = (position - span.start)..<(end - span.start)
        // The consumer depends on the full original backing even for one row,
        // one position, or a single-piece alias. Duplicate IDs are deduplicated
        // by the owning lease; unused optional local/future pages are excluded.
        onSourceBacking?(span.id, span.backingBytesUpperBound)
        let arrays = try span.materialize(row: selected, positions: local)
        keyPieces.append(arrays.0); valuePieces.append(arrays.1)
        position = end
        if position == range.upperBound { break }
      }
      guard position == range.upperBound else { throw BoomError.invalid("Required KV prefix coverage is unavailable.") }
    }
    guard !keyPieces.isEmpty, keyPieces.count == valuePieces.count else {
      throw BoomError.invalid("Required KV prefix has no retained tensors.")
    }
    // Two nonempty pieces already allocate one compact destination. A lone
    // hot-row slice needs Gather's raw copy; no arithmetic or whole-parent copy.
    func combine(_ pieces: [MLXArray]) -> MLXArray {
      if pieces.count > 1 { return concatenated(pieces, axis: 2) }
      let piece = pieces[0]
      if copyResidentPieces {
        return take(piece, MLXArray([Int32(0)]), axis: 0)
      }
      return piece
    }
    let keys = combine(keyPieces), values = combine(valuePieces)
    var restored = native
    restored.state = [keys, values]
    if case let .rotating(window, keep, step, origin) = layout {
      restored.metaState = [String(keep), String(window), String(step), String(prefix),
        String(keys.dim(2)), origin, "false"]
    }
    guard restored.offset == prefix, restored.state.count == 2,
      restored.state.allSatisfy({ $0.ndim == 4 && $0.dim(0) == 1 }) else {
      throw BoomError.invalid("Restored native KV geometry differs from the requested prefix.")
    }
    return restored
  }
}
