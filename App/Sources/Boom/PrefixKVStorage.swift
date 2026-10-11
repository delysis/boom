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

/// Immutable descriptors of one chronological incoming span. IDs identify its
/// backing across row views and entry forks; constructing a descriptor never
/// evaluates, fences, decodes or reads tensor contents.
struct PrefixKVSpan {
  let id: UUID
  let start: Int
  let end: Int
  let batchWidth: Int
  let layer: Int
  let keys: MLXArray
  let values: MLXArray
  let backingBytesUpperBound: UInt64

  init(id: UUID = UUID(), offset: Int, layer: Int, keys: MLXArray, values: MLXArray,
    backingBytesUpperBound: UInt64? = nil) throws {
    guard offset >= 0, layer >= 0 else { throw BoomError.invalid("Invalid KV span coordinates.") }
    try PrefixKVStorage.validatePair(keys, values)
    let (end, overflow) = offset.addingReportingOverflow(keys.dim(2))
    guard !overflow else { throw BoomError.invalid("KV span coordinates overflowed.") }
    let bytes = try PrefixKVStorage.pairBytes(keys, values)
    guard backingBytesUpperBound.map({ $0 >= bytes }) ?? true else {
      throw BoomError.invalid("The KV backing bound is smaller than its declared view.")
    }
    self.id = id; start = offset; self.end = end; batchWidth = keys.dim(0); self.layer = layer
    self.keys = keys[.ellipsis]; self.values = values[.ellipsis]
    self.backingBytesUpperBound = backingBytesUpperBound ?? bytes
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
    while let observed = current as? PrefixKVCache { current = observed.base }
    return current
  }

  static func layout(of cache: any KVCache) -> Layout? {
    let native = unwrap(cache), type = ObjectIdentifier(type(of: native))
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

  /// Read at one admitted boundary. These are only current resident views,
  /// bounded by the native window; overwritten sliding history is unavailable.
  /// Wrapped buffers are described as separate chronological slices, never
  /// concatenated or cloned here. Every slice shares the snapshot's backing ID.
  static func residentWindowSpans(of cache: any KVCache, layer: Int) throws -> [PrefixKVSpan] {
    let native = unwrap(cache)
    guard let layout = layout(of: native),
      case let .rotating(window, keep, _, _) = layout else {
      throw BoomError.invalid("Resident-window reads require a known native rotating cache.")
    }
    let meta = native.metaState
    guard let offset = Int(meta[3]), let idx = Int(meta[4]), let wrapped = Bool(meta[6]), layer >= 0 else {
      throw BoomError.invalid("Invalid resident KV metadata.")
    }
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
    let retainedTail = min(tailCount, window - keep), wantedStart = offset - retainedTail
    let id = UUID(), backing = try pairBytes(keys, values)
    var result: [PrefixKVSpan] = []
    func view(_ physical: Range<Int>, absolute: Int) throws {
      guard !physical.isEmpty else { return }
      result.append(try PrefixKVSpan(id: id, offset: absolute, layer: layer,
        keys: keys[0..., 0..., physical, 0...], values: values[0..., 0..., physical, 0...],
        backingBytesUpperBound: backing))
    }
    try view(0..<pinned, absolute: 0)
    let physicalTail: [Range<Int>]
    if wrapped, idx < held { physicalTail = [idx..<held, pinned..<idx] }
    else { physicalTail = [pinned..<held] }
    var absolute = offset - tailCount
    for physical in physicalTail {
      let end = absolute + physical.count
      let start = max(absolute, wantedStart)
      if start < end {
        try view((physical.lowerBound + start - absolute)..<physical.upperBound, absolute: start)
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
    batchWidth: Int? = nil, onSourceBacking: ((UUID, UInt64) -> Void)? = nil) throws -> any KVCache {
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
        try validatePair(span.keys, span.values)
        guard span.layer == first.layer, span.start >= previousEnd, span.end > span.start,
          span.end - span.start == span.keys.dim(2), span.batchWidth == span.keys.dim(0),
          span.batchWidth == 1 || span.batchWidth == width,
          span.keys.dim(1) == first.keys.dim(1), span.keys.dim(3) == first.keys.dim(3),
          span.values.dim(3) == first.values.dim(3), span.keys.dtype == first.keys.dtype,
          span.values.dtype == first.values.dtype else {
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
        keyPieces.append(span.keys[selected..<(selected + 1), 0..., local, 0...])
        valuePieces.append(span.values[selected..<(selected + 1), 0..., local, 0...])
        position = end
        if position == range.upperBound { break }
      }
      guard position == range.upperBound else { throw BoomError.invalid("Required KV prefix coverage is unavailable.") }
    }
    guard !keyPieces.isEmpty, keyPieces.count == valuePieces.count else {
      throw BoomError.invalid("Required KV prefix has no retained tensors.")
    }
    let keys = keyPieces.count == 1 ? keyPieces[0] : concatenated(keyPieces, axis: 2)
    let values = valuePieces.count == 1 ? valuePieces[0] : concatenated(valuePieces, axis: 2)
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
