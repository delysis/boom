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
      allowSnapshot: allow, useActiveNative: true, makeCache: {
        var caches: [any KVCache] = (0..<5).map { _ in RotatingKVCache(maxSize: 4, step: 2) }
        let full = KVCacheSimple(); full.step = 2; caches.append(full)
        return caches
      })
  }
  private func append(_ request: PromptPrefixCache.Session, rows: [[Int]], submitted: Bool = true) async {
    precondition(!rows.isEmpty && rows.allSatisfy({ $0.count == rows[0].count }))
    for (layer, cache) in request.cache.enumerated() {
      let heads = layer < 5 ? 4 : 1
      let values = rows.flatMap { row in (0..<heads).flatMap { _ in row.map(Float.init) } }
      let array = MLXArray(values, [rows.count, heads, rows[0].count, 1])
      _ = cache.update(keys: array, values: array + 10000)
    }
      if submitted {
      asyncEval(request.cache.flatMap { $0.innerState() })
      eval(request.cache); request.markCacheSubmitted()
      request.observeReadySpill(); await request.joinPendingSpill(cancelled: false)
    }
  }
  private func prefill(_ request: PromptPrefixCache.Session) async throws {
    let ids = request.input.text.tokens.asArray(Int.self)
    var partition = request.prefill; partition.progress = nil
    var ranges: [Range<Int>] = []
    let done = try partition.forEachChunk(total: ids.count) { ranges.append($0) }
    if done < ids.count { ranges.append(done..<ids.count) }
    for range in ranges {
      await append(request, rows: [Array(ids[range])])
      request.prefill.progress?(range.upperBound, ids.count)
    }
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
  private func completed(_ store: PromptPrefixCache, _ scope: PromptCacheOwner) async throws {
    let ids = Array(0..<63), value = try request(store, ids, owner: scope)
    try await prefill(value); expand(value)
    await append(value, rows: [[901], [911], [921]])
    finish(value, first: [901, 911, 921], second: [902, 912, 922])
    XCTAssertTrue(store.publish(value, completions: [
      .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912]),
      .init(row: 2, emittedTokenIDs: [921, 922])]))
  }

  func testPressureCompletesScaledFullContextWithoutIncreasingPool() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner(), ids = Array(0..<63)
      let value = try request(store, ids, owner: scope); try await prefill(value)
      XCTAssertTrue(value.retentionObservation?.compactLocalCoverage == true)
      XCTAssertEqual(value.retentionObservation?.lastCompleteTokenCount, 63)
      expand(value); await append(value, rows: [[901], [911], [921]])
      finish(value, first: [901, 911, 921], second: [902, 912, 922])
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 2048)
      XCTAssertTrue(store.publish(value, completions: [
        .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912]),
        .init(row: 2, emittedTokenIDs: [921, 922])]))
      XCTAssertEqual(store.retainedSnapshotObservations.count, 3)
      XCTAssertTrue(store.retainedSnapshotObservations.allSatisfy({ $0.tokenIDs.count == 64 }))
      XCTAssertEqual(store.retainedBytesUpperBound, 0, "Joined raw pins leave only disk history and the actual hot KV.")
      XCTAssertGreaterThan(store.retainedNativeBytesUpperBound, 0)
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      let selected = try request(store, ids + [911, 912], owner: scope)
      XCTAssertEqual(selected.cachedTokenCount, 64)
      XCTAssertEqual(selected.cache[5].state[0].asArray(Float.self), (ids + [911]).map(Float.init))
    }
  }
  func testRetiredSelectedEntryStillChargesInheritedCroppedBackings() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner(), ids = Array(0..<63)
      try await completed(store, scope)
      let next = try request(store, ids, owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 62)
      XCTAssertEqual(store.activeCaptureLeaseCount, 0, "Disk descriptors carry no resident lease.")
      try await prefill(next); expand(next)
      await append(next, rows: [[931], [941], [951]])
      XCTAssertTrue(store.hasAnchors, "Zero-RAM disk history survives raw pressure.")
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertGreaterThan(store.retainedNativeBytesUpperBound, 0,
        "Actual source aliases remain in native ownership; cropping is no release credit.")
      XCTAssertEqual(next.cache[5].state[0].dim(2), 64)
      finish(next, first: [931, 941, 951], second: [932, 942, 952])
      XCTAssertTrue(store.publish(next, completions: [
        .init(row: 0, emittedTokenIDs: [931, 932]), .init(row: 1, emittedTokenIDs: [941, 942]),
        .init(row: 2, emittedTokenIDs: [951, 952])]))
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertGreaterThan(store.retainedNativeBytesUpperBound, 0)
    }
  }
  func testEarlyEOSRetainsPreviousPrefixAfterPeersAdvanceBeyondTwoWindows() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 8192), scope = owner(), ids = Array(0..<63), soft = SoftPressure()
      let value = try request(store, ids, owner: scope, allow: { soft.allow($0) })
      try await prefill(value); expand(value)
      XCTAssertTrue(value.captureFinishedLane(row: 0, width: 3, emittedTokenIDs: [], stopTokenID: 999))
      var first: [Int] = [], second: [Int] = []
      for step in 0..<12 {
        first.append(901 + step); second.append(951 + step)
        XCTAssertTrue(value.captureDecodeLane(row: 1, width: 3, emittedTokenIDs: first, finished: false))
        XCTAssertTrue(value.captureDecodeLane(row: 2, width: 3, emittedTokenIDs: second, finished: false))
        await append(value, rows: [[-1], [901 + step], [951 + step]])
      }
      first.append(913); second.append(963)
      XCTAssertTrue(value.captureFinishedLane(row: 1, width: 3, emittedTokenIDs: first))
      XCTAssertTrue(value.captureFinishedLane(row: 2, width: 3, emittedTokenIDs: second))
      XCTAssertTrue(store.publish(value, completions: [
        .init(row: 0, emittedTokenIDs: [], stopTokenID: 999), .init(row: 1, emittedTokenIDs: first),
        .init(row: 2, emittedTokenIDs: second)]))
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 8192)
      // A prompt-only EOS keeps prefill provenance (row == nil). Identify
      // its actual stopped lane by the receipt rather than a decode-origin row.
      let earlyEOS = store.retainedSnapshotObservations.first {
        $0.nativeRowReceipt?.observedStopTokenID == 999
      }
      XCTAssertEqual(earlyEOS?.tokenIDs, ids)
      XCTAssertEqual(earlyEOS?.origin, .prefill)
      XCTAssertNil(earlyEOS?.row)
      XCTAssertEqual(earlyEOS?.nativeRowReceipt?.deliveredGeneratedTokenCount, 0)
      let identical = try request(store, ids, owner: scope)
      XCTAssertEqual(identical.cachedTokenCount, 62, "EOS requires coverage one boundary before the saved endpoint.")
      XCTAssertEqual(identical.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [58, 59, 60, 61].map(Float.init) })
    }
  }
  func testClearAndStalePublicationCannotEraseLiveLeaseCharges() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner()
      let value = try request(store, Array(0..<63), owner: scope); try await prefill(value)
      let charged = store.retainedNativeBytesUpperBound
      XCTAssertGreaterThan(charged, 0)
      store.clear(reason: "residency_evicted")
      XCTAssertFalse(store.hasAnchors); XCTAssertEqual(store.retainedNativeBytesUpperBound, charged)
      XCTAssertFalse(store.publish(value))
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      let next = try request(store, Array(0..<63), owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 0); XCTAssertEqual(next.observation.missReason, "residency_evicted")
    }
  }
  func testMidCohortPoolRefusalCannotLeaveHalfLayerCoverageOrCharges() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 60), scope = owner()
      let value = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray([0, 1, 2])),
        promptTokenIDs: [0, 1, 2], prefill: PrefillParameters(stepSize: 2), useActiveNative: true, makeCache: {
          [KVCacheSimple(), RotatingKVCache(maxSize: 4)]
        })
      let small = MLXArray([Float(0), 1], [1, 1, 2, 1])
      _ = value.cache[0].update(keys: small, values: small)
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      let large = MLXArray((0..<8).map(Float.init), [1, 4, 2, 1])
      _ = value.cache[1].update(keys: large, values: large)
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      eval(value.cache) // actual bytes are completed, deliberately no submitted-prefix proof
      value.observeReadySpill(); await value.joinPendingSpill(cancelled: false)
      XCTAssertEqual(value.retentionObservation?.refusalReason, "pool_limit")
      value.prefill.progress?(3, 3)
      XCTAssertFalse(store.publish(value)); XCTAssertFalse(store.hasAnchors)
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
    }
  }
  func testDiscardDropsOptimizationLeaseWithoutChangingWorkingKV() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner()
      let value = try request(store, Array(0..<63), owner: scope); try await prefill(value)
      let before = value.cache[5].state[0].asArray(Float.self)
      XCTAssertGreaterThan(store.retainedNativeBytesUpperBound, 0)
      value.discardStagedAnchors()
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertEqual(value.cache[5].state[0].asArray(Float.self), before)
      XCTAssertFalse(store.publish(value))
    }
  }

  func testHydratedOnePieceAliasAndCacheCopyKeepFullSourceCharge() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 256), scope = owner(), ids = [10, 11, 12, 13]
      var cold: PromptPrefixCache.Session? = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids)),
        promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 4), useActiveNative: true,
        makeCache: { let cache = KVCacheSimple(); cache.step = 4; return [cache] })
      let array = MLXArray(ids.map(Float.init), [1, 1, 4, 1])
      _ = cold!.cache[0].update(keys: array, values: array + 100)
      cold!.prefill.progress?(4, 4)
      asyncEval(cold!.cache.flatMap { $0.innerState() }); eval(cold!.cache); cold!.markCacheSubmitted()
      await cold!.joinPendingSpill(cancelled: false)
      XCTAssertTrue(store.publish(cold!)); cold = nil
      XCTAssertEqual(store.retainedBytesUpperBound, 0)

      var warm: PromptPrefixCache.Session? = try store.makeSession(owner: scope,
        input: LMInput(tokens: MLXArray(ids)), promptTokenIDs: ids,
        prefill: PrefillParameters(stepSize: 4), useActiveNative: true, makeCache: { let cache = KVCacheSimple(); cache.step = 4; return [cache] })
      XCTAssertEqual(warm?.cachedTokenCount, 3)
      var copy: (any KVCache)? = warm!.cache[0].copy()
      store.clear(); warm!.discardStagedAnchors(); warm = nil
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, 32,
        "A three-position view still owns the original four-position backing.")
      XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertEqual(copy!.state[0].asArray(Float.self), [10, 11, 12])
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, 32,
        "Evaluation is no proof that a one-piece view stopped aliasing its source.")
      copy = nil
      XCTAssertEqual(store.retainedNativeBytesUpperBound, 0); XCTAssertEqual(store.retainedBytesUpperBound, 0)
    }
  }

  func testHydrationReportsOnlyRequiredIDsWithFullBatchedBacking() async throws {
    try await Device.withDefaultDevice(.cpu) {
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

  /// Test-side ready observation only. The scoped C pins close on return;
  /// neither this helper nor the production hook evaluates an unready graph.
  private func readyParentBytes(_ arrays: [MLXArray], phase: String) throws -> UInt64 {
    let pair = try XCTUnwrap(arrays.count == 2 ? arrays : nil)
    let keys = try XCTUnwrap(pair[0].readyBuffer(), "Missing completed K parent at \(phase).")
    let values = try XCTUnwrap(pair[1].readyBuffer(), "Missing completed V parent at \(phase).")
    XCTAssertGreaterThanOrEqual(keys.allocationBytes, pair[0].nbytes)
    XCTAssertGreaterThanOrEqual(values.allocationBytes, pair[1].nbytes)
    let keyBytes = try XCTUnwrap(UInt64(exactly: keys.allocationBytes))
    let valueBytes = try XCTUnwrap(UInt64(exactly: values.allocationBytes))
    let (sum, overflow) = keyBytes.addingReportingOverflow(valueBytes)
    let total = try XCTUnwrap(overflow ? nil : sum, "Physical parent byte sum overflowed.")
    print("KVPressureReady phase=\(phase) keyParent=\(keyBytes) valueParent=\(valueBytes) keyLogical=\(pair[0].nbytes) valueLogical=\(pair[1].nbytes) total=\(total)")
    return total
  }

  func testReadyParentBudgetOneByteShortRefusesSpillWithoutChangingNativeKV() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let scope = owner(), ids = Array(0..<6)
      let keys = MLXArray(ids.map(Float.init), [1, 1, 6, 1]), values = keys + 100
      asyncEval([keys, values]); eval([keys, values])
      let required = try readyParentBytes([keys, values], phase: "under-budget-source")
      let (limit, overflow) = required.subtractingReportingOverflow(1)
      let rawLimit = try XCTUnwrap(overflow ? nil : limit)
      let store = PromptPrefixCache(byteLimit: rawLimit)
      let cold = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids)),
        promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 6),
        useActiveNative: true, makeCache: { [RotatingKVCache(maxSize: 4)] })
      _ = cold.cache[0].update(keys: keys, values: values)
      cold.prefill.progress?(6, 6)
      asyncEval(cold.cache.flatMap { $0.innerState() }); eval(cold.cache); cold.markCacheSubmitted()
      XCTAssertEqual(try readyParentBytes(cold.cache[0].innerState(), phase: "under-budget-native"), required)
      await cold.joinPendingSpill(cancelled: false)
      XCTAssertEqual(cold.retentionObservation?.refusalReason, "pool_limit")
      XCTAssertEqual(cold.retentionObservation?.diskSubmittedJobs, 0)
      XCTAssertEqual(cold.retentionObservation?.diskBytes, 0)
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertEqual(cold.cache[0].offset, 6)
      XCTAssertEqual(cold.cache[0].state[0].asArray(Float.self), ids.map(Float.init))
      XCTAssertEqual(cold.cache[0].state[1].asArray(Float.self), ids.map { Float($0 + 100) })
      XCTAssertTrue(store.publish(cold), "A real joined hot cache remains valid even when its disk spill cannot fit.")
      let next = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids)),
        promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 6),
        useActiveNative: true, makeCache: { [RotatingKVCache(maxSize: 4)] })
      XCTAssertEqual(next.cachedTokenCount, 5,
        "The sole hot ring still physically covers this prefix even though its disk spill was refused.")
      XCTAssertEqual(next.cache[0].offset, 5)
      XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), [1, 2, 3, 4])
      XCTAssertEqual(next.cache[0].state[1].asArray(Float.self), [101, 102, 103, 104])
      XCTAssertEqual(cold.cache[0].offset, 6)
      XCTAssertEqual(cold.cache[0].state[0].asArray(Float.self), ids.map(Float.init))
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, 48)
      store.clear(); next.discardStagedAnchors(); cold.discardStagedAnchors()
      XCTAssertEqual(store.retainedBytesUpperBound, 0); XCTAssertEqual(store.activeCaptureLeaseCount, 0)
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, 48,
        "A declined raw pin cannot credit the explicitly held native source.")
    }
  }

  func testPressureCannotCreditSourceStillNeededByHydratedWorkingCache() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let scope = owner(), ids = Array(0..<6)
      let source = MLXArray(ids.map(Float.init), [1, 1, 6, 1]), values = source + 100
      asyncEval([source, values]); eval([source, values])
      let parents = try readyParentBytes([source, values], phase: "positive-source")
      // The pinned allocator declines cache rentals >=2x the requested extent.
      // Derive fixture headroom from ACTUAL parents, not the former56-byte
      // logical archive. The later four-position ring is measured again below.
      let (doubled, overflow) = parents.multipliedReportingOverflow(by: 2)
      let rawLimit = try XCTUnwrap(overflow ? nil : doubled)
      XCTAssertLessThanOrEqual(rawLimit, PromptPrefixCache.defaultByteLimit)
      print("KVPressureQuota rawLimit=\(rawLimit) measuredParents=\(parents)")
      let store = PromptPrefixCache(byteLimit: rawLimit)
      let cold = try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids)),
        promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 6),
        useActiveNative: true, makeCache: { [RotatingKVCache(maxSize: 4)] })
      _ = cold.cache[0].update(keys: source, values: values)
      cold.prefill.progress?(6, 6)
      asyncEval(cold.cache.flatMap { $0.innerState() }); eval(cold.cache); cold.markCacheSubmitted()
      XCTAssertEqual(try readyParentBytes(cold.cache[0].innerState(), phase: "positive-cold"), parents)
      await cold.joinPendingSpill(cancelled: false)
      XCTAssertGreaterThan(cold.retentionObservation?.diskSubmittedJobs ?? 0, 0)
      XCTAssertTrue(store.publish(cold))
      var warm: PromptPrefixCache.Session? = try store.makeSession(owner: scope,
        input: LMInput(tokens: MLXArray(ids)), promptTokenIDs: ids,
        prefill: PrefillParameters(stepSize: 6), useActiveNative: true, makeCache: { [RotatingKVCache(maxSize: 4)] })
      XCTAssertEqual(warm?.cachedTokenCount, 5)
      do {
        let working = try XCTUnwrap(warm).cache[0]
        asyncEval(working.innerState()); eval(working.innerState())
        XCTAssertLessThanOrEqual(try readyParentBytes(working.innerState(), phase: "positive-hydrated"), rawLimit)
        XCTAssertEqual(working.state[0].asArray(Float.self), [1, 2, 3, 4])
        XCTAssertEqual(working.state[1].asArray(Float.self), [101, 102, 103, 104])
      }
      let final = MLXArray([Float(5)], [1, 1, 1, 1])
      _ = warm!.cache[0].update(keys: final, values: final + 100)
      warm!.prefill.progress?(1, 1)
      let next = MLXArray([Float(901)], [1, 1, 1, 1])
      _ = warm!.cache[0].update(keys: next, values: next + 100)
      XCTAssertEqual(warm!.cache[0].offset, 7, "The valid model forward still proceeds.")
      asyncEval(warm!.cache.flatMap { $0.innerState() }); eval(warm!.cache); warm!.markCacheSubmitted()
      XCTAssertLessThanOrEqual(try readyParentBytes(warm!.cache[0].innerState(), phase: "positive-advanced"), rawLimit)
      XCTAssertEqual(warm!.cache[0].state[0].asArray(Float.self), [5, 901, 3, 4])
      XCTAssertEqual(warm!.cache[0].state[1].asArray(Float.self), [105, 1001, 103, 104])
      await warm!.joinPendingSpill(cancelled: false)
      XCTAssertEqual(warm!.retentionObservation?.lastCompleteTokenCount, 7)
      XCTAssertNil(warm!.retentionObservation?.refusalReason,
        "No extra immutable RAM archive is retained; every actual ready parent still fits the measured raw quota.")
      XCTAssertTrue(warm!.retentionObservation?.compactLocalCoverage == true)
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, rawLimit)
      store.clear(); warm!.discardStagedAnchors()
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, 48,
        "Optional descriptor release cannot erase the aliased full source backing.")
      XCTAssertEqual(cold.cache[0].offset, 6)
      XCTAssertEqual(cold.cache[0].state[0].asArray(Float.self), ids.map(Float.init))
      XCTAssertEqual(cold.cache[0].state[1].asArray(Float.self), ids.map { Float($0 + 100) })
      warm = nil
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertGreaterThan(store.retainedNativeBytesUpperBound, 0, "The explicitly held cold session still owns its real native cache.")
    }
  }

  func testPageAlignedPromptKeepsInitialReusableWindowUnderPressure() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 2048), scope = owner(), ids = Array(0..<62)
      let value = try request(store, ids, owner: scope); try await prefill(value); expand(value)
      await append(value, rows: [[901], [911], [921]])
      finish(value, first: [901, 911, 921], second: [902, 912, 922])
      XCTAssertTrue(value.retentionObservation?.compactLocalCoverage == true)
      XCTAssertTrue(store.publish(value, completions: [
        .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912]),
        .init(row: 2, emittedTokenIDs: [921, 922])]))
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      let identical = try request(store, ids, owner: scope)
      XCTAssertEqual(identical.cachedTokenCount, 61,
        "Pressure must preserve the initial window one token before the raw prompt endpoint.")
      XCTAssertEqual(identical.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [57, 58, 59, 60].map(Float.init) })
    }
  }

  private func completedGap(_ store: PromptPrefixCache, scope: PromptCacheOwner) async throws {
    let ids = Array(0..<6), pressure = SoftPressure()
    let value = try request(store, ids, owner: scope, allow: { pressure.allow($0) })
    try await prefill(value); expand(value)
    for step in 0..<11 {
      await append(value, rows: [[901 + step], [951 + step], [1001 + step]])
    }
    let emitted = (0..<3).map { row in (0..<12).map { 901 + row * 50 + $0 } }
    for row in 0..<3 {
      XCTAssertTrue(value.captureFinishedLane(row: row, width: 3, emittedTokenIDs: emitted[row]))
    }
    XCTAssertTrue(store.publish(value, completions: (0..<3).map {
      .init(row: $0, emittedTokenIDs: emitted[$0])
    }))
  }

  func testLexicalMatchInCoverageGapFallsBackToGreatestValidPrefix() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 8192), scope = owner()
      try await completedGap(store, scope: scope)
      let incoming = Array(0..<6) + [901, 902, 9999]
      let value = try request(store, incoming, owner: scope)
      XCTAssertEqual(value.cachedTokenCount, 8,
        "Admitted zero-RAM disk middle intervals retain the full lexical prefix.")
      XCTAssertEqual(value.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [4, 5, 901, 902].map(Float.init) })
    }
  }

  func testCrossEntrySelectionUsesAdjustedValidCountsInsteadOfLexicalCounts() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 8192), scope = owner()
      let parentIDs = Array(0..<6) + [901, 902]
      let parent = try request(store, parentIDs, owner: scope); try await prefill(parent)
      XCTAssertTrue(store.publish(parent))
      try await completedGap(store, scope: scope)
      let incoming = Array(0..<6) + [901, 902, 903, 9999]
      let value = try request(store, incoming, owner: scope)
      XCTAssertEqual(value.cachedTokenCount, 9,
        "The child now has actual disk coverage through its lexical9, so it beats parent8.")
      XCTAssertEqual(value.observation.cachedRow, 0)
      XCTAssertEqual(value.cache[0].state[0].asArray(Float.self),
        (0..<4).flatMap { _ in [5, 901, 902, 903].map(Float.init) })
    }
  }
}
