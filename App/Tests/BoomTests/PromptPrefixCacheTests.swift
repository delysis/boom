import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

final class PromptPrefixCacheTests: XCTestCase {
  private let namespace = UUID()
  private func owner(namespace: UUID? = nil, route: PromptCacheOwner.Route = .writing) -> PromptCacheOwner {
    PromptCacheOwner(namespace: namespace ?? self.namespace, entity: UUID(), route: route)
  }
  private func session(_ store: PromptPrefixCache, _ ids: [Int], owner: PromptCacheOwner?,
    step: Int = 4, chunking: PrefillParameters.Chunking = .remainder,
    allow: (@Sendable (UInt64) -> Bool)? = nil, window: Int = 4) throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(ids, [1, ids.count])),
      promptTokenIDs: ids, prefill: PrefillParameters(stepSize: step, chunking: chunking),
      allowSnapshot: allow, useActiveNative: true, makeCache: { let global = KVCacheSimple(); global.step = 4; return [global, RotatingKVCache(maxSize: window, step: 2)] })
  }
  private func append(_ request: PromptPrefixCache.Session, values: [Float], width: Int = 1, submitted: Bool = true) async {
    let array = MLXArray(values, [width, 1, values.count / width, 1])
    for cache in request.cache { _ = cache.update(keys: array, values: array) }
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
      await append(request, values: ids[range].map(Float.init))
      request.prefill.progress?(range.upperBound, ids.count)
    }
  }
  private func publishPrompt(_ store: PromptPrefixCache, _ ids: [Int], owner: PromptCacheOwner) async throws {
    let request = try session(store, ids, owner: owner)
    try await prefill(request)
    XCTAssertTrue(store.publish(request))
  }
  private func expand(_ request: PromptPrefixCache.Session, width: Int) {
    for var cache in request.cache {
      cache.state = cache.state.map { broadcast($0, to: [width] + Array($0.shape.dropFirst())) }
    }
  }
  func testLongestPrefixInsideAForwardAndReturningEntityAreAutomatic() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), ids = Array(0..<9), firstOwner = owner()
      try await publishPrompt(store, ids, owner: firstOwner)
      let changed = try session(store, [0, 1, 2, 90, 91], owner: owner(route: .consultation))
      XCTAssertEqual(changed.cachedTokenCount, 3)
      XCTAssertEqual(changed.input.text.tokens.asArray(Int.self), [90, 91])
      XCTAssertEqual(changed.cache[0].state[0].asArray(Float.self), [0, 1, 2])
      XCTAssertFalse(changed.preservesChunkBoundaries)
      try await prefill(changed); XCTAssertTrue(store.publish(changed))
      let returning = try session(store, ids, owner: firstOwner)
      XCTAssertEqual(returning.cachedTokenCount, 8)
      XCTAssertEqual(returning.cache[0].state[0].asArray(Float.self), Array(0..<8).map(Float.init))
      XCTAssertTrue(returning.preservesChunkBoundaries)
      let privateOther = try session(store, ids, owner: owner(namespace: UUID()))
      XCTAssertEqual(privateOther.cachedTokenCount, 0)
    }
  }
  func testGeneratedKVIsReusedAndUnobservedLookaheadIsExcluded() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids, owner: scope); try await prefill(request)
      request.didSample?(MLXArray([901]))
      await append(request, values: [901]); request.didSample?(MLXArray([902]))
      await append(request, values: [902]); request.didSample?(MLXArray([903]))
      await append(request, values: [903]); request.didSample?(MLXArray([904]))
      XCTAssertTrue(store.publish(request, completions: [.init(emittedTokenIDs: [901, 902])]))
      XCTAssertEqual(store.retainedSnapshotObservations[0].tokenIDs, ids + [901, 902])
      let next = try session(store, ids + [901, 902, 999], owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 11)
      XCTAssertEqual(next.observation.cachedOrigin, .singleDecode)
      XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), (ids + [901, 902]).map(Float.init))
      XCTAssertFalse(store.retainedSnapshotObservations.contains { $0.tokenIDs.contains(903) })
    }
  }
  func testIncorrectSampleLedgerCannotPublishGeneratedKV() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids, owner: scope); try await prefill(request)
      request.didSample?(MLXArray([901])); await append(request, values: [901])
      request.didSample?(MLXArray([902]))
      XCTAssertTrue(store.publish(request, completions: [.init(emittedTokenIDs: [777])]))
      XCTAssertEqual(store.retainedSnapshotObservations[0].tokenIDs, ids)
    }
  }
  func testEachBatchRowRetainsOnlyProcessedDeliveredTokensAndSharesBacking() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids, owner: scope); try await prefill(request); expand(request, width: 3)
      for row in 0..<3 {
        XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10], finished: false))
      }
      await append(request, values: [901, 911, 921], width: 3)
      XCTAssertTrue(request.captureDecodeLane(row: 0, width: 3, emittedTokenIDs: [901, 902], finished: true))
      for row in 1..<3 {
        XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10], finished: false))
      }
      await append(request, values: [-1, 912, 922], width: 3)
      XCTAssertTrue(request.captureDecodeLane(row: 1, width: 3, emittedTokenIDs: [911, 912, 913], finished: true))
      XCTAssertTrue(request.captureDecodeLane(row: 2, width: 3, emittedTokenIDs: [921, 922, 923], finished: true))
      let stagedBeforePublication = request.stagedBytesUpperBound
      XCTAssertTrue(store.publish(request, completions: [
        .init(row: 0, emittedTokenIDs: [901, 902]), .init(row: 1, emittedTokenIDs: [911, 912, 913]),
        .init(row: 2, emittedTokenIDs: [921, 922, 923])]))
      let snapshots = store.retainedSnapshotObservations
      XCTAssertEqual(snapshots.count, 3)
      XCTAssertEqual(snapshots.first(where: { $0.row == 0 })?.tokenIDs, ids + [901])
      XCTAssertEqual(snapshots.first(where: { $0.row == 1 })?.tokenIDs, ids + [911, 912])
      XCTAssertEqual(snapshots.first(where: { $0.row == 2 })?.tokenIDs, ids + [921, 922])
      XCTAssertEqual(stagedBeforePublication, 0)
      XCTAssertEqual(store.retainedBytesUpperBound, 0, "Only disk descriptors remain; raw parents are separately joined.")
      for row in 0..<3 {
        let delivered = row == 0 ? [901, 902] : [901 + row * 10, 902 + row * 10, 903 + row * 10]
        let next = try session(store, ids + delivered, owner: scope)
        let processed = row == 0 ? 10 : 11
        XCTAssertEqual(next.cachedTokenCount, processed)
        XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), (ids + Array(delivered.prefix(processed - ids.count))).map(Float.init))
        try await prefill(next); XCTAssertTrue(store.publish(next))
        let repeatRequest = try session(store, ids + delivered + [999], owner: scope)
        XCTAssertEqual(repeatRequest.cachedTokenCount, ids.count + delivered.count)
      }
    }
  }
  func testResidentWindowsRollAndDoNotArchiveAnEntireLongPrompt() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<40)
      try await publishPrompt(store, ids, owner: scope)
      let observation = store.retainedSnapshotObservations[0]
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertEqual(observation.residentLocalStarts[0], 0, "Admitted optional disk intervals preserve earlier edits.")
      let repeatRequest = try session(store, ids, owner: scope)
      XCTAssertEqual(repeatRequest.cachedTokenCount, 39)
      XCTAssertEqual(repeatRequest.cache[1].state[0].asArray(Float.self), [35, 36, 37, 38])
      let oldEdit = try session(store, Array(0..<10) + [999], owner: scope)
      XCTAssertEqual(oldEdit.cachedTokenCount, 10)
      XCTAssertEqual(oldEdit.cache[1].state[0].asArray(Float.self), [6, 7, 8, 9])
    }
  }
  func testOlderResidentBranchRemainsUsableWhenNewestWindowCannotCoverQuery() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner()
      try await publishPrompt(store, Array(0..<9), owner: scope)
      try await publishPrompt(store, Array(0..<40), owner: scope)
      let request = try session(store, [0, 1, 2, 3, 4, 99], owner: scope)
      XCTAssertEqual(request.cachedTokenCount, 5)
    }
  }
  func testLookupInventoryKeepsPublishedDiskNamespaceBesideDifferentHotOwner() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), first = owner(), second = owner(namespace: UUID())
      let original = Array(0..<9), other = Array(40..<49)
      try await publishPrompt(store, original, owner: first)
      try await publishPrompt(store, other, owner: second)
      XCTAssertTrue(store.retainedSnapshotObservations.allSatisfy { $0.namespace == second.namespace })
      let beforeRaw = store.retainedBytesUpperBound, beforeNative = store.retainedNativeBytesUpperBound
      let beforeAnchors = store.retainedAnchorTokenCounts, beforeLeases = store.activeCaptureLeaseCount
      let observations = store.retainedLookupSnapshotObservations
      XCTAssertEqual(store.retainedBytesUpperBound, beforeRaw)
      XCTAssertEqual(store.retainedNativeBytesUpperBound, beforeNative)
      XCTAssertEqual(store.retainedAnchorTokenCounts, beforeAnchors)
      XCTAssertEqual(store.activeCaptureLeaseCount, beforeLeases)
      let previous = try XCTUnwrap(observations.first {
        $0.namespace == first.namespace && $0.tokenIDs == original
      })
      XCTAssertEqual(previous.origin, .prefill); XCTAssertEqual(previous.batchWidth, 1)
      XCTAssertNil(previous.row); XCTAssertEqual(previous.nativePhysicalWidth, 1)
      XCTAssertEqual(previous.forwardHistory.last?.endTokenCount, original.count)
      XCTAssertEqual(previous.nativeRowReceipt?.processedTokenCount, original.count)
      let coverage = try XCTUnwrap(previous.residentLocalCoverage)
      XCTAssertEqual(coverage.count, 1); XCTAssertEqual(coverage[0].layer, 1)
      XCTAssertEqual(coverage[0].window, 4); XCTAssertEqual(coverage[0].keep, 0)
      XCTAssertTrue(observations.contains { $0.namespace == second.namespace && $0.tokenIDs == other })
      let query = original + [999]
      let expected = observations.filter { $0.namespace == first.namespace }.map {
        PromptCacheReuseSmoke.residentPrefixCount(snapshot: $0, current: query, localLayerCount: 1)
      }.max() ?? 0
      XCTAssertEqual(expected, original.count)
      let returning = try session(store, query, owner: first)
      XCTAssertEqual(returning.cachedTokenCount, expected)
      XCTAssertEqual(returning.observation.cachedNativePhysicalWidth, previous.nativePhysicalWidth)
      XCTAssertEqual(returning.cache[0].state[0].asArray(Float.self), original.map(Float.init))
      XCTAssertEqual(returning.cache[1].state[0].asArray(Float.self), [5, 6, 7, 8])
    }
  }
  func testChangingForwardGeometryDoesNotPreventValidResidentReuse() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      try await publishPrompt(store, ids, owner: scope)
      let request = try session(store, ids + [99], owner: scope, step: 3, chunking: .balanced)
      XCTAssertEqual(request.cachedTokenCount, 9)
      XCTAssertFalse(request.preservesChunkBoundaries)
      XCTAssertEqual(request.observation.originalGeometry.chunking, .balanced)
    }
  }
  func testBudgetDeclineRetainsEarlierCompleteForwardWithoutAFalseGap() async throws {
    final class Guard: @unchecked Sendable {
      private let lock = NSLock(); private var calls = 0
      func allow(_ bytes: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; calls += 1; return calls <= 4
      }
    }
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), guardState = Guard()
      let request = try session(store, Array(0..<9), owner: scope, allow: { guardState.allow($0) })
      try await prefill(request); XCTAssertTrue(store.publish(request))
      let hot = try session(store, Array(0..<9) + [90], owner: scope)
      XCTAssertEqual(hot.cachedTokenCount, 9, "Raw archive refusal cannot invalidate the actual joined hot cache.")
      hot.discardStagedAnchors(); await hot.joinPendingSpill(cancelled: true)
      _ = try session(store, [100, 101, 102], owner: owner(namespace: UUID()))
      let next = try session(store, Array(0..<9), owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 4, "Only the first complete admitted disk checkpoint survives.")
    }
  }
  func testStaleTicketAndDiscardCannotPublish() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let stale = try session(store, ids, owner: scope); try await prefill(stale)
      let current = try session(store, ids, owner: scope)
      XCTAssertFalse(store.publish(stale))
      try await prefill(current); current.discardStagedAnchors()
      XCTAssertFalse(store.publish(current))
      XCTAssertFalse(store.hasAnchors)
      let cleared = try session(store, ids, owner: scope); try await prefill(cleared)
      store.clear(reason: "residency_evicted")
      XCTAssertFalse(store.publish(cleared))
      XCTAssertEqual(try session(store, ids, owner: scope).observation.missReason, "residency_evicted")
    }
  }
  func testUnfinishedLayerCohortCannotBePublished() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), request = try session(store, Array(0..<9), owner: owner())
      let values = MLXArray([Float(0), 1, 2, 3], [1, 1, 4, 1])
      _ = request.cache[0].update(keys: values, values: values)
      request.prefill.progress?(9, 9)
      XCTAssertFalse(store.publish(request))
      XCTAssertFalse(store.hasAnchors)
    }
  }
  func testPoolEvictsInactiveEntriesAndCountsEachBackingOnce() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 180, diskByteLimit: 180), scope = owner()
      try await publishPrompt(store, Array(0..<9), owner: scope)
      try await publishPrompt(store, Array(100..<109), owner: scope)
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 180)
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertEqual(try session(store, Array(100..<109), owner: scope).cachedTokenCount, 8)
      XCTAssertEqual(try session(store, Array(0..<9), owner: scope).cachedTokenCount, 0)
    }
  }
}
