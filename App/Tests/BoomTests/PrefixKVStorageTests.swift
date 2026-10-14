import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

final class PrefixKVStorageTests: XCTestCase {
  private func tensor(_ positions: Range<Int>, rows: [Int] = [0], heads: Int = 1,
    dimension: Int = 1, values: Bool = false) -> MLXArray {
    var data: [Float] = []
    for row in rows {
      for head in 0..<heads {
        for position in positions {
          for component in 0..<dimension {
            let number = Float(row * 10_000 + head * 1_000 + position * 10 + component)
            data.append(values ? -number - 1 : number)
          }
        }
      }
    }
    return MLXArray(data, [rows.count, heads, positions.count, dimension])
  }

  private func span(_ positions: Range<Int>, rows: [Int] = [0], layer: Int = 0,
    heads: Int = 1, dimension: Int = 1) throws -> PrefixKVSpan {
    try PrefixKVSpan(offset: positions.lowerBound, layer: layer,
      keys: tensor(positions, rows: rows, heads: heads, dimension: dimension),
      values: tensor(positions, rows: rows, heads: heads, dimension: dimension, values: true))
  }

  private func append(_ cache: any KVCache, _ positions: Range<Int>, rows: [Int] = [0]) -> (MLXArray, MLXArray) {
    cache.update(keys: tensor(positions, rows: rows), values: tensor(positions, rows: rows, values: true))
  }

  private final class ForwardingCache: KVCache {
    let native = KVCacheSimple()
    var preparedArrays = 0, finalized = 0
    var preparedLengths: [Int]?, queriedPositions: [Int] = []
    var step: Int { get { native.step } set { native.step = newValue } }
    var offset: Int { native.offset }
    var maxSize: Int? { 17 }
    var ropeOffset: RoPEOffset { .scalar(offset + 100) }
    var state: [MLXArray] { get { native.state } set { native.state = newValue } }
    var metaState: [String] { get { native.metaState } set { native.metaState = newValue } }
    var isTrimmable: Bool { native.isTrimmable }
    func innerState() -> [MLXArray] { native.innerState() }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) { native.update(keys: keys, values: values) }
    @discardableResult func trim(_ n: Int) -> Int { native.trim(n) }
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
      native.makeMask(n: n, windowSize: windowSize, returnArray: returnArray)
    }
    func copy() -> any KVCache { native.copy() }
    func prepare(lengths: [Int]?) { preparedLengths = lengths; native.prepare(lengths: lengths) }
    func prepare(lengths: MLXArray?) { preparedArrays += 1; native.prepare(lengths: lengths) }
    func finalize() { finalized += 1; native.finalize() }
    func isTrimmable(after positions: Int) -> Bool {
      queriedPositions.append(positions); return positions < 3
    }
  }

  func testTapRunsBeforeNativeUpdateAndCopyNeverObserves() throws {
    try Device.withDefaultDevice(.cpu) {
      let base = ForwardingCache(); base.step = 3
      let reference = KVCacheSimple(); reference.step = 3
      var spans: [PrefixKVSpan] = [], errors: [Error] = []
      let tapped = PrefixKVCache(layer: 2, base: base) { layer, offset, keys, values in
        XCTAssertEqual(base.offset, offset)
        do { spans.append(try PrefixKVSpan(offset: offset, layer: layer, keys: keys, values: values)) }
        catch { errors.append(error) }
      }
      for positions in [0..<3, 3..<5] {
        let observed = append(tapped, positions), expected = append(reference, positions)
        XCTAssertEqual(observed.0.asArray(Float.self), expected.0.asArray(Float.self))
        XCTAssertEqual(observed.1.asArray(Float.self), expected.1.asArray(Float.self))
      }
      XCTAssertTrue(errors.isEmpty)
      XCTAssertEqual(spans.map(\.start), [0, 3]); XCTAssertEqual(spans.map(\.end), [3, 5])
      XCTAssertEqual(spans.map(\.layer), [2, 2]); XCTAssertNotEqual(spans[0].id, spans[1].id)
      XCTAssertEqual(tapped.offset, base.offset); XCTAssertEqual(tapped.maxSize, 17)
      if case let .scalar(offset) = tapped.ropeOffset { XCTAssertEqual(offset, 105) }
      else { XCTFail("The native rotary offset was replaced") }
      XCTAssertEqual(tapped.innerState().map(\.shape), base.innerState().map(\.shape))
      XCTAssertEqual(tapped.makeMask(n: 2, windowSize: nil, returnArray: true).mask?.asArray(Bool.self),
        base.makeMask(n: 2, windowSize: nil, returnArray: true).mask?.asArray(Bool.self))
      tapped.prepare(lengths: [2, 4]); tapped.prepare(lengths: MLXArray([2, 4])); tapped.finalize()
      XCTAssertEqual(base.preparedLengths, [2, 4]); XCTAssertEqual(base.preparedArrays, 1)
      XCTAssertEqual(base.finalized, 1); XCTAssertFalse(tapped.isTrimmable(after: 3))
      XCTAssertEqual(base.queriedPositions, [3]); XCTAssertTrue(tapped.isTrimmable)
      let copy = tapped.copy()
      XCTAssertEqual(copy.state[0].asArray(Float.self), tapped.state[0].asArray(Float.self))
      XCTAssertEqual(copy.state[1].asArray(Float.self), tapped.state[1].asArray(Float.self))
      _ = append(copy, 5..<6)
      XCTAssertEqual(spans.count, 2); XCTAssertEqual(base.offset, 5); XCTAssertEqual(copy.offset, 6)
      XCTAssertEqual(tapped.trim(2), 2); XCTAssertEqual(base.offset, 3)
      tapped.state = [tensor(0..<2), tensor(0..<2, values: true)]
      tapped.metaState = [""]
      XCTAssertEqual(base.offset, 2); XCTAssertEqual(tapped.state[0].asArray(Float.self), [0, 10])
      XCTAssertNil(PrefixKVStorage.layout(of: base), "A custom adapter is not an admitted native layout.")
    }
  }

  func testIndependentCopyKeepsSourceLeaseUntilItsLastOwnerEnds() throws {
    try Device.withDefaultDevice(.cpu) {
      var lease: PrefixKVDependencyLease? = PrefixKVDependencyLease(onRelease: {})
      weak var retainedLease = lease
      var observations = 0
      var original: PrefixKVCache? = PrefixKVCache(layer: 0, base: KVCacheSimple(),
        dependencyLease: lease) { _, _, _, _ in observations += 1 }
      var copy: (any KVCache)? = original!.copy()
      lease = nil; original = nil
      XCTAssertNotNil(retainedLease)
      _ = append(copy!, 0..<2)
      XCTAssertEqual(copy?.offset, 2)
      XCTAssertEqual(observations, 0)
      copy = nil
      XCTAssertNil(retainedLease)
    }
  }

  func testSpanDescriptorsDetachFromCallerUpdatesAndShareBackingIdentityAcrossViews() throws {
    try Device.withDefaultDevice(.cpu) {
      let keys = tensor(0..<4), values = tensor(0..<4, values: true)
      let original = try PrefixKVSpan(offset: 0, layer: 0, keys: keys, values: values)
      let view = try original.sliced(positions: 1..<3)
      keys[.ellipsis] = tensor(10..<14); values[.ellipsis] = tensor(10..<14, values: true)
      let originalArrays = try original.materialize(row: 0, positions: 0..<4)
      let viewArrays = try view.materialize(row: 0, positions: 0..<2)
      XCTAssertEqual(originalArrays.0.asArray(Float.self), [0, 10, 20, 30])
      XCTAssertEqual(viewArrays.0.asArray(Float.self), [10, 20])
      XCTAssertEqual(view.id, original.id); XCTAssertEqual(view.backingBytesUpperBound, original.backingBytesUpperBound)
    }
  }

  func testFullAttentionHydratesAnArbitraryOffsetInsideImmutablePages() throws {
    try Device.withDefaultDevice(.cpu) {
      let prototype = KVCacheSimple(); prototype.step = 3
      let layout = try XCTUnwrap(PrefixKVStorage.layout(of: prototype))
      let pages = try [span(0..<4), span(4..<9), span(9..<15)]
      let restored = try PrefixKVStorage.hydrate(layout: layout, spans: pages, prefix: 7, row: 0)
      XCTAssertEqual((restored as? KVCacheSimple)?.step, 3)
      XCTAssertEqual(restored.offset, 7)
      XCTAssertEqual(restored.state[0].asArray(Float.self), tensor(0..<7).asArray(Float.self))
      XCTAssertEqual(restored.state[1].asArray(Float.self), tensor(0..<7, values: true).asArray(Float.self))
      let updated = append(restored, 7..<9)
      XCTAssertEqual(updated.0.asArray(Float.self), tensor(0..<9).asArray(Float.self))
      XCTAssertEqual(try pages[1].materialize(row: 0, positions: 0..<5).0.asArray(Float.self),
        tensor(4..<9).asArray(Float.self))
      let empty = try PrefixKVStorage.hydrate(layout: layout, spans: [], prefix: 0, row: 0)
      XCTAssertEqual(empty.offset, 0); XCTAssertTrue(empty.state.isEmpty)
    }
  }

  func testSelectedRowCombinesSharedPrefillWithItsOwnBatchSpans() throws {
    try Device.withDefaultDevice(.cpu) {
      let pages = try [span(0..<5), span(5..<9, rows: [0, 1, 2])]
      let rowTwo = try PrefixKVStorage.hydrate(layout: .simple(step: 4), spans: pages,
        prefix: 8, row: 2, batchWidth: 3)
      let expected = tensor(0..<5).asArray(Float.self) + tensor(5..<8, rows: [2]).asArray(Float.self)
      XCTAssertEqual(rowTwo.state[0].asArray(Float.self), expected)
      _ = append(rowTwo, 8..<9, rows: [2])
      let rowOne = try PrefixKVStorage.hydrate(layout: .simple(step: 4), spans: pages,
        prefix: 8, row: 1, batchWidth: 3)
      XCTAssertEqual(rowOne.state[0].asArray(Float.self),
        tensor(0..<5).asArray(Float.self) + tensor(5..<8, rows: [1]).asArray(Float.self))
      let shared = try PrefixKVStorage.hydrate(layout: .simple(step: 4), spans: [pages[0]],
        prefix: 3, row: 2, batchWidth: 3)
      XCTAssertEqual(shared.state[0].asArray(Float.self), tensor(0..<3).asArray(Float.self))
      XCTAssertThrowsError(try PrefixKVStorage.hydrate(layout: .simple(step: 4), spans: pages,
        prefix: 8, row: 3, batchWidth: 3))
    }
  }

  func testWrappedResidentWindowHydratesNativeSingleAndMultiTokenContinuation() throws {
    try Device.withDefaultDevice(.cpu) {
      let live = RotatingKVCache(maxSize: 4, keep: 1, step: 2)
      for position in 0..<12 { _ = append(live, position..<(position + 1)) }
      let before = live.state.map { $0.asArray(Float.self) }, metadata = live.metaState
      let views = try PrefixKVStorage.residentWindowSpans(of: live, layer: 1)
      XCTAssertEqual(Set(views.map(\.id)).count, 1)
      XCTAssertEqual(views.reduce(0) { $0 + $1.end - $1.start }, 4)
      XCTAssertEqual(views.first?.start, 0); XCTAssertEqual(views.last?.end, 12)
      XCTAssertEqual(live.metaState, metadata); XCTAssertEqual(live.state.map { $0.asArray(Float.self) }, before)
      let layout = try XCTUnwrap(PrefixKVStorage.layout(of: live))
      let restored = try PrefixKVStorage.hydrate(layout: layout, spans: views, prefix: 12, row: 0)
      XCTAssertEqual(restored.metaState, ["1", "4", "2", "12", "4", "modelNative", "false"])
      XCTAssertEqual(restored.state[0].asArray(Float.self), [0, 90, 100, 110])
      let observedSingle = append(restored, 12..<13), referenceSingle = append(live, 12..<13)
      XCTAssertEqual(observedSingle.0.asArray(Float.self).sorted(), [0, 100, 110, 120])
      XCTAssertEqual(observedSingle.0.asArray(Float.self).sorted(), referenceSingle.0.asArray(Float.self).sorted())
      XCTAssertEqual(observedSingle.1.asArray(Float.self).sorted(), referenceSingle.1.asArray(Float.self).sorted())
      XCTAssertEqual(restored.makeMask(n: 3, windowSize: 4, returnArray: true).mask?.asArray(Bool.self),
        live.makeMask(n: 3, windowSize: 4, returnArray: true).mask?.asArray(Bool.self))
      let observedMulti = append(restored, 13..<16), referenceMulti = append(live, 13..<16)
      XCTAssertEqual(observedMulti.0.asArray(Float.self), [0, 110, 120, 130, 140, 150])
      XCTAssertEqual(observedMulti.0.asArray(Float.self), referenceMulti.0.asArray(Float.self))
      XCTAssertEqual(observedMulti.1.asArray(Float.self), referenceMulti.1.asArray(Float.self))
      XCTAssertEqual(restored.offset, 16); XCTAssertEqual(live.offset, 16)
    }
  }

  func testOnlyTwoBoundedWindowsCanCoverAnIntermediateAbsolutePrefix() throws {
    try Device.withDefaultDevice(.cpu) {
      let live = RotatingKVCache(maxSize: 4, step: 2)
      for position in 0..<12 { _ = append(live, position..<(position + 1)) }
      let older = try PrefixKVStorage.residentWindowSpans(of: live, layer: 0)
      for position in 12..<15 { _ = append(live, position..<(position + 1)) }
      let newer = try PrefixKVStorage.residentWindowSpans(of: live, layer: 0)
      let layout = try XCTUnwrap(PrefixKVStorage.layout(of: live))
      XCTAssertThrowsError(try PrefixKVStorage.hydrate(layout: layout, spans: newer, prefix: 13, row: 0))
      let first = try XCTUnwrap(older.first)
      XCTAssertEqual(first.start, 8)
      let disjointOld = try first.sliced(positions: 0..<3)
      let restored = try PrefixKVStorage.hydrate(layout: layout, spans: [disjointOld] + newer, prefix: 13, row: 0)
      XCTAssertEqual(restored.offset, 13); XCTAssertEqual(restored.state[0].asArray(Float.self), [90, 100, 110, 120])
      XCTAssertLessThanOrEqual(older.reduce(0) { $0 + $1.end - $1.start }, 4)
      XCTAssertLessThanOrEqual(newer.reduce(0) { $0 + $1.end - $1.start }, 4)
      XCTAssertThrowsError(try PrefixKVStorage.hydrate(layout: layout, spans: older, prefix: 7, row: 0))
    }
  }

  func testOversizedPrefillViewsRemainBoundedAndRetainCapacityAccounting() throws {
    try Device.withDefaultDevice(.cpu) {
      let live = RotatingKVCache(maxSize: 4, step: 2)
      _ = append(live, 0..<11)
      let capacityBytes = live.innerState().reduce(UInt64(0)) { $0 + UInt64($1.nbytes) }
      let views = try PrefixKVStorage.residentWindowSpans(of: live, layer: 0)
      XCTAssertEqual(views.map(\.start), [7]); XCTAssertEqual(views.map(\.end), [11])
      XCTAssertEqual(views[0].backingBytesUpperBound, capacityBytes)
      let viewArrays = try views[0].materialize(row: 0, positions: 0..<4)
      XCTAssertGreaterThan(capacityBytes, UInt64(viewArrays.0.nbytes + viewArrays.1.nbytes))
      let restored = try PrefixKVStorage.hydrate(layout: try XCTUnwrap(PrefixKVStorage.layout(of: live)),
        spans: views, prefix: 11, row: 0)
      XCTAssertEqual(restored.state[0].asArray(Float.self), [70, 80, 90, 100])
    }
  }

  func testMetadataOriginAndDynamicPrototypeCountSurviveHydration() throws {
    try Device.withDefaultDevice(.cpu) {
      let ring = RotatingKVCache(maxSize: 5, keep: 1, step: 3)
      var metadata = ring.metaState; metadata[5] = "requested"; ring.metaState = metadata
      let prototypes: [any KVCache] = [KVCacheSimple(), ring, KVCacheSimple()]
      let layouts = try prototypes.map { try XCTUnwrap(PrefixKVStorage.layout(of: $0)) }
      XCTAssertEqual(layouts.count, prototypes.count)
      let zero = try PrefixKVStorage.hydrate(layout: layouts[1], spans: [], prefix: 0, row: 0)
      XCTAssertEqual(zero.metaState, ["1", "5", "3", "0", "0", "requested", "false"])
      let restored = try PrefixKVStorage.hydrate(layout: layouts[1], spans: [span(0..<3)], prefix: 3, row: 0)
      XCTAssertEqual(restored.metaState, ["1", "5", "3", "3", "3", "requested", "false"])
      XCTAssertNil(PrefixKVStorage.layout(of: ForwardingCache()))
    }
  }

  func testMissingCoverageOverlapWidthsAndShapesAreRefused() throws {
    try Device.withDefaultDevice(.cpu) {
      let layout = PrefixKVStorage.Layout.simple(step: 4)
      for pages in [try [span(0..<3), span(4..<7)], try [span(0..<4), span(3..<7)],
        try [span(0..<4), span(4..<7, dimension: 2)], try [span(0..<4), span(4..<7, layer: 1)],
        try [span(0..<4), span(4..<7, rows: [0, 1])]] {
        XCTAssertThrowsError(try PrefixKVStorage.hydrate(layout: layout, spans: pages, prefix: 6, row: 0, batchWidth: 3))
      }
      XCTAssertThrowsError(try PrefixKVSpan(offset: 0, layer: 0, keys: MLXArray([1.0, 2.0]), values: tensor(0..<2)))
      XCTAssertThrowsError(try PrefixKVSpan(offset: -1, layer: 0, keys: tensor(0..<1), values: tensor(0..<1)))
      XCTAssertThrowsError(try PrefixKVSpan(offset: Int.max, layer: 0, keys: tensor(0..<1), values: tensor(0..<1)))
      XCTAssertThrowsError(try PrefixKVStorage.hydrate(layout: layout, spans: [span(0..<3)], prefix: 3, row: -1))
      XCTAssertThrowsError(try PrefixKVStorage.residentWindowSpans(of: KVCacheSimple(), layer: 0))
    }
  }
}
