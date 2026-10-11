import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

/// Scaled CPU cache semantics, not a model/numerical/RSS performance gate.
/// Five local owners and one global owner mirror the 12B 5:1 layer cadence.
/// Pair bytes 32/8, window 4, page 2 and pool 2048 preserve its pressure ratios.
final class PromptPrefixCachePressureTests: XCTestCase {
  private final class SoftPressure: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0
    func allow(_ bytes: UInt64) -> Bool {
      lock.lock(); defer { lock.unlock() }; calls += 1; return calls > 1
    }
  }
  private func owner() -> PromptCacheOwner {
    PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
  }
  private func request(_ store: PromptPrefixCache, _ ids: [Int], owner: PromptCacheOwner,
    allow: (@Sendable (UInt64) -> Bool)? = nil) throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(ids)),
      promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 2, chunking: .remainder),
      allowSnapshot: allow, makeCache: {
        var caches: [any KVCache] = (0..<5).map { _ in RotatingKVCache(maxSize: 4, step: 2) }
        let full = KVCacheSimple(); full.step = 2; caches.append(full)
        return caches
      })
  }
  private func append(_ request: PromptPrefixCache.Session, rows: [[Int]]) {
    precondition(!rows.isEmpty && rows.allSatisfy({ $0.count == rows[0].count }))
    for (layer, cache) in request.cache.enumerated() {
      let heads = layer < 5 ? 4 : 1
      let values = rows.flatMap { row in (0..<heads).flatMap { _ in row.map(Float.init) } }
      let array = MLXArray(values, [rows.count, heads, rows[0].count, 1])
      _ = cache.update(keys: array, values: array + 10000)
    }
  }
  private func prefill(_ request: PromptPrefixCache.Session) throws {
    let ids = request.input.text.tokens.asArray(Int.self)
    let completed = try request.prefill.forEachChunk(total: ids.count) { range in
      append(request, rows: [Array(ids[range])])
    }
    append(request, rows: [Array(ids[completed...])])
    request.prefill.progress?(ids.count, ids.count)
  }
  private func expand(_ request: PromptPrefixCache.Session) {
    for var cache in request.cache {
      cache.state = cache.state.map { broadcast($0, to: [3] + Array($0.shape.dropFirst())) }
    }
  }
  private func finish(_ request: PromptPrefixCache.Session, first: [Int], second: [Int]) {
    for row in 0..<3 {
      XCTAssertTrue(request.captureFinishedLane(row: row, width: 3,
        emittedTokenIDs: [first[row], second[row]]))
    }
  }
  private func completed(_ store: PromptPrefixCache, _ scope: PromptCacheOwner) throws {
    let ids = Array(0..<63), value = try request(store, ids, owner: scope)
    try prefill(value); expand(value)
    append(value, rows: [[901], [911], [921]])
    finish(value, first: [901, 911, 921], second: [902, 912, 922])
    XCTAssertTrue(store.publish(value, completions: [
      .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912]),
      .init(row: 2, emittedTokenIDs: [921, 922])]))
  }

  func testPressureCompletesScaledFullContextWithoutIncreasingPool() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner(), ids = Array(0..<63)
      let value = try request(store, ids, owner: scope); try prefill(value)
      XCTAssertTrue(value.retentionObservation?.compactLocalCoverage == true)
      XCTAssertEqual(value.retentionObservation?.lastCompleteTokenCount, 63)
      expand(value); append(value, rows: [[901], [911], [921]])
      finish(value, first: [901, 911, 921], second: [902, 912, 922])
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 2048)
      XCTAssertTrue(store.publish(value, completions: [
        .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912]),
        .init(row: 2, emittedTokenIDs: [921, 922])]))
      XCTAssertEqual(store.retainedSnapshotObservations.count, 3)
      XCTAssertTrue(store.retainedSnapshotObservations.allSatisfy({ $0.tokenIDs.count == 64 }))
      XCTAssertEqual(store.retainedBytesUpperBound, 1808, "All three rows share full backing charges once.")
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      let selected = try request(store, ids + [911, 912], owner: scope)
      XCTAssertEqual(selected.cachedTokenCount, 64)
      XCTAssertEqual(selected.cache[5].state[0].asArray(Float.self), (ids + [911]).map(Float.init))
    }
  }
  func testRetiredSelectedEntryStillChargesInheritedCroppedBackings() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner(), ids = Array(0..<63)
      try completed(store, scope)
      let next = try request(store, ids, owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 62)
      XCTAssertEqual(store.activeCaptureLeaseCount, 2, "Capture and hydrated cache have separate ownership.")
      try prefill(next); expand(next)
      append(next, rows: [[931], [941], [951]])
      XCTAssertFalse(store.hasAnchors, "LRU may retire the selected stored entry; the active lease remains.")
      XCTAssertEqual(store.activeCaptureLeaseCount, 2)
      XCTAssertEqual(store.retainedBytesUpperBound, 1808,
        "Inherited source pages keep full charges after stored entries retire; row cropping is no credit.")
      XCTAssertEqual(next.cache[5].state[0].dim(2), 64)
      finish(next, first: [931, 941, 951], second: [932, 942, 952])
      XCTAssertTrue(store.publish(next, completions: [
        .init(row: 0, emittedTokenIDs: [931, 932]), .init(row: 1, emittedTokenIDs: [941, 942]),
        .init(row: 2, emittedTokenIDs: [951, 952])]))
      XCTAssertEqual(store.retainedBytesUpperBound, 1808)
      XCTAssertEqual(store.activeCaptureLeaseCount, 1, "Working caches still own the hydration lease.")
    }
  }
  func testEarlyEOSRetainsPreviousPrefixAfterPeersAdvanceBeyondTwoWindows() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 8192), scope = owner(), ids = Array(0..<63), soft = SoftPressure()
      let value = try request(store, ids, owner: scope, allow: { soft.allow($0) })
      try prefill(value); expand(value)
      XCTAssertTrue(value.captureFinishedLane(row: 0, width: 3, emittedTokenIDs: [], stopTokenID: 999))
      var first: [Int] = [], second: [Int] = []
      for step in 0..<12 {
        first.append(901 + step); second.append(951 + step)
        XCTAssertTrue(value.captureDecodeLane(row: 1, width: 3, emittedTokenIDs: first, finished: false))
        XCTAssertTrue(value.captureDecodeLane(row: 2, width: 3, emittedTokenIDs: second, finished: false))
        append(value, rows: [[-1], [901 + step], [951 + step]])
      }
      first.append(913); second.append(963)
      XCTAssertTrue(value.captureFinishedLane(row: 1, width: 3, emittedTokenIDs: first))
      XCTAssertTrue(value.captureFinishedLane(row: 2, width: 3, emittedTokenIDs: second))
      XCTAssertTrue(store.publish(value, completions: [
        .init(row: 0, emittedTokenIDs: [], stopTokenID: 999), .init(row: 1, emittedTokenIDs: first),
        .init(row: 2, emittedTokenIDs: second)]))
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 8192)
      XCTAssertEqual(store.retainedSnapshotObservations.first(where: { $0.row == 0 })?.tokenIDs, ids)
      let identical = try request(store, ids, owner: scope)
      XCTAssertEqual(identical.cachedTokenCount, 62, "EOS requires coverage one boundary before the saved endpoint.")
      XCTAssertEqual(identical.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [58, 59, 60, 61].map(Float.init) })
    }
  }
  func testClearAndStalePublicationCannotEraseLiveLeaseCharges() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner()
      let value = try request(store, Array(0..<63), owner: scope); try prefill(value)
      let charged = store.retainedBytesUpperBound
      XCTAssertGreaterThan(charged, 0)
      store.clear(reason: "residency_evicted")
      XCTAssertFalse(store.hasAnchors); XCTAssertEqual(store.retainedBytesUpperBound, charged)
      XCTAssertFalse(store.publish(value))
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      let next = try request(store, Array(0..<63), owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 0); XCTAssertEqual(next.observation.missReason, "residency_evicted")
    }
  }
  func testMidCohortPoolRefusalCannotLeaveHalfLayerCoverageOrCharges() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 60), scope = owner()
      let value = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray([0, 1, 2])),
        promptTokenIDs: [0, 1, 2], prefill: PrefillParameters(stepSize: 2), makeCache: {
          [KVCacheSimple(), RotatingKVCache(maxSize: 4)]
        })
      let small = MLXArray([Float(0), 1], [1, 1, 2, 1])
      _ = value.cache[0].update(keys: small, values: small)
      XCTAssertEqual(store.retainedBytesUpperBound, 16)
      let large = MLXArray((0..<8).map(Float.init), [1, 4, 2, 1])
      _ = value.cache[1].update(keys: large, values: large)
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertEqual(value.retentionObservation?.refusalReason, "pool_limit")
      value.prefill.progress?(3, 3)
      XCTAssertFalse(store.publish(value)); XCTAssertFalse(store.hasAnchors)
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
    }
  }
  func testDiscardDropsOptimizationLeaseWithoutChangingWorkingKV() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner()
      let value = try request(store, Array(0..<63), owner: scope); try prefill(value)
      let before = value.cache[5].state[0].asArray(Float.self)
      XCTAssertGreaterThan(store.retainedBytesUpperBound, 0)
      value.discardStagedAnchors()
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertEqual(value.cache[5].state[0].asArray(Float.self), before)
      XCTAssertFalse(store.publish(value))
    }
  }

  func testHydratedOnePieceAliasAndCacheCopyKeepFullSourceCharge() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 256), scope = owner(), ids = [10, 11, 12, 13]
      let cold = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids)),
        promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 4), makeCache: { [KVCacheSimple()] })
      let array = MLXArray(ids.map(Float.init), [1, 1, 4, 1])
      _ = cold.cache[0].update(keys: array, values: array + 100)
      cold.prefill.progress?(4, 4)
      XCTAssertTrue(store.publish(cold)); XCTAssertEqual(store.retainedBytesUpperBound, 32)

      var warm: PromptPrefixCache.Session? = try store.makeSession(owner: scope,
        input: LMInput(tokens: MLXArray(ids)), promptTokenIDs: ids,
        prefill: PrefillParameters(stepSize: 4), makeCache: { [KVCacheSimple()] })
      XCTAssertEqual(warm?.cachedTokenCount, 3)
      var copy: (any KVCache)? = warm!.cache[0].copy()
      store.clear(); warm!.discardStagedAnchors(); warm = nil
      XCTAssertEqual(store.retainedBytesUpperBound, 32,
        "A three-position view still owns the original four-position backing.")
      XCTAssertEqual(store.activeCaptureLeaseCount, 1)
      XCTAssertEqual(copy!.state[0].asArray(Float.self), [10, 11, 12])
      XCTAssertEqual(store.retainedBytesUpperBound, 32,
        "Evaluation is no proof that a one-piece view stopped aliasing its source.")
      copy = nil
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
    }
  }

  func testHydrationReportsOnlyRequiredIDsWithFullBatchedBacking() throws {
    try Device.withDefaultDevice(.cpu) {
      let first = try PrefixKVSpan(offset: 0, layer: 0,
        keys: MLXArray((0..<12).map(Float.init), [3, 1, 4, 1]),
        values: MLXArray((100..<112).map(Float.init), [3, 1, 4, 1]))
      let future = try PrefixKVSpan(offset: 4, layer: 0,
        keys: MLXArray((12..<24).map(Float.init), [3, 1, 4, 1]),
        values: MLXArray((112..<124).map(Float.init), [3, 1, 4, 1]))
      var charges: [UUID: UInt64] = [:]
      let hydrated = try PrefixKVStorage.hydrate(layout: .simple(step: 4), spans: [first, future],
        prefix: 3, row: 2, batchWidth: 3, onSourceBacking: { charges[$0] = $1 })
      XCTAssertEqual(charges, [first.id: 96])
      XCTAssertEqual(hydrated.state[0].asArray(Float.self), [8, 9, 10])

      let pinned = try PrefixKVSpan(offset: 0, layer: 0,
        keys: MLXArray([Float(0)], [1, 1, 1, 1]), values: MLXArray([Float(100)], [1, 1, 1, 1]))
      let optional = try PrefixKVSpan(offset: 3, layer: 0,
        keys: MLXArray([Float(3), 4, 5], [1, 1, 3, 1]), values: MLXArray([Float(103), 104, 105], [1, 1, 3, 1]))
      let tail = try PrefixKVSpan(offset: 6, layer: 0,
        keys: MLXArray([Float(6), 7, 8], [1, 1, 3, 1]), values: MLXArray([Float(106), 107, 108], [1, 1, 3, 1]))
      let last = try PrefixKVSpan(offset: 9, layer: 0,
        keys: MLXArray([Float(9), 10, 11], [1, 1, 3, 1]), values: MLXArray([Float(109), 110, 111], [1, 1, 3, 1]))
      charges.removeAll()
      let local = try PrefixKVStorage.hydrate(
        layout: .rotating(window: 4, keep: 1, step: 4, capacityOrigin: "requested"),
        spans: [pinned, optional, tail, last], prefix: 10, row: 0,
        onSourceBacking: { charges[$0] = $1 })
      XCTAssertEqual(charges, [pinned.id: 8, tail.id: 24, last.id: 24])
      XCTAssertNil(charges[optional.id])
      XCTAssertEqual(local.state[0].asArray(Float.self), [0, 7, 8, 9])
    }
  }

  func testPressureCannotCreditSourceStillNeededByHydratedWorkingCache() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 56), scope = owner(), ids = Array(0..<6)
      let cold = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids)),
        promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 6),
        makeCache: { [RotatingKVCache(maxSize: 4)] })
      let source = MLXArray(ids.map(Float.init), [1, 1, 6, 1])
      _ = cold.cache[0].update(keys: source, values: source + 100)
      cold.prefill.progress?(6, 6); XCTAssertTrue(store.publish(cold))
      var warm: PromptPrefixCache.Session? = try store.makeSession(owner: scope,
        input: LMInput(tokens: MLXArray(ids)), promptTokenIDs: ids,
        prefill: PrefillParameters(stepSize: 6), makeCache: { [RotatingKVCache(maxSize: 4)] })
      XCTAssertEqual(warm?.cachedTokenCount, 5)
      let final = MLXArray([Float(5)], [1, 1, 1, 1])
      _ = warm!.cache[0].update(keys: final, values: final + 100)
      warm!.prefill.progress?(1, 1)
      let next = MLXArray([Float(901)], [1, 1, 1, 1])
      _ = warm!.cache[0].update(keys: next, values: next + 100)
      XCTAssertEqual(warm!.cache[0].offset, 7, "The valid model forward still proceeds.")
      XCTAssertEqual(warm!.retentionObservation?.lastCompleteTokenCount, 6)
      XCTAssertEqual(warm!.retentionObservation?.refusalReason, "pool_limit")
      XCTAssertTrue(warm!.retentionObservation?.compactLocalCoverage == true)
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 56)
      store.clear(); warm!.discardStagedAnchors()
      XCTAssertEqual(store.retainedBytesUpperBound, 48,
        "Optional descriptor release cannot erase the aliased full source backing.")
      warm = nil
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
    }
  }

  func testPageAlignedPromptKeepsInitialReusableWindowUnderPressure() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner(), ids = Array(0..<62)
      let value = try request(store, ids, owner: scope); try prefill(value); expand(value)
      append(value, rows: [[901], [911], [921]])
      finish(value, first: [901, 911, 921], second: [902, 912, 922])
      XCTAssertTrue(value.retentionObservation?.compactLocalCoverage == true)
      XCTAssertTrue(store.publish(value, completions: [
        .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912]),
        .init(row: 2, emittedTokenIDs: [921, 922])]))
      XCTAssertEqual(store.retainedBytesUpperBound, 1960)
      let identical = try request(store, ids, owner: scope)
      XCTAssertEqual(identical.cachedTokenCount, 61,
        "Pressure must preserve the initial window one token before the raw prompt endpoint.")
      XCTAssertEqual(identical.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [57, 58, 59, 60].map(Float.init) })
    }
  }

  private func completedGap(_ store: PromptPrefixCache, scope: PromptCacheOwner) throws {
    let ids = Array(0..<6), pressure = SoftPressure()
    let value = try request(store, ids, owner: scope, allow: { pressure.allow($0) })
    try prefill(value); expand(value)
    for step in 0..<11 {
      append(value, rows: [[901 + step], [951 + step], [1001 + step]])
    }
    let emitted = (0..<3).map { row in (0..<12).map { 901 + row * 50 + $0 } }
    for row in 0..<3 {
      XCTAssertTrue(value.captureFinishedLane(row: row, width: 3, emittedTokenIDs: emitted[row]))
    }
    XCTAssertTrue(store.publish(value, completions: (0..<3).map {
      .init(row: $0, emittedTokenIDs: emitted[$0])
    }))
  }

  func testLexicalMatchInCoverageGapFallsBackToGreatestValidPrefix() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 8192), scope = owner()
      try completedGap(store, scope: scope)
      let incoming = Array(0..<6) + [901, 902, 9999]
      let value = try request(store, incoming, owner: scope)
      XCTAssertEqual(value.cachedTokenCount, 5,
        "A lexical match through8 falls in the gap, but the protected prompt prefix through5 remains valid.")
      XCTAssertEqual(value.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [1, 2, 3, 4].map(Float.init) })
    }
  }

  func testCrossEntrySelectionUsesAdjustedValidCountsInsteadOfLexicalCounts() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 8192), scope = owner()
      let parentIDs = Array(0..<6) + [901, 902]
      let parent = try request(store, parentIDs, owner: scope); try prefill(parent)
      XCTAssertTrue(store.publish(parent))
      try completedGap(store, scope: scope)
      let incoming = Array(0..<6) + [901, 902, 903, 9999]
      let value = try request(store, incoming, owner: scope)
      XCTAssertEqual(value.cachedTokenCount, 8,
        "The parent lexical8/valid8 beats the child lexical9/valid5.")
      XCTAssertNil(value.observation.cachedRow)
      XCTAssertEqual(value.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [4, 5, 901, 902].map(Float.init) })
    }
  }
}
