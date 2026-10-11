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
      allowSnapshot: allow, makeCache: { [KVCacheSimple(), RotatingKVCache(maxSize: window)] })
  }
  private func append(_ request: PromptPrefixCache.Session, values: [Float], width: Int = 1) {
    let array = MLXArray(values, [width, 1, values.count / width, 1])
    for cache in request.cache { _ = cache.update(keys: array, values: array) }
  }
  private func prefill(_ request: PromptPrefixCache.Session) throws {
    let suffix = request.input.text.tokens.asArray(Int.self)
    let count = try request.prefill.forEachChunk(total: suffix.count) { range in
      append(request, values: suffix[range].map(Float.init))
    }
    append(request, values: suffix[count...].map(Float.init))
    request.prefill.progress?(suffix.count, suffix.count)
  }
  private func publishPrompt(_ store: PromptPrefixCache, _ ids: [Int], owner: PromptCacheOwner) throws {
    let request = try session(store, ids, owner: owner)
    try prefill(request)
    XCTAssertTrue(store.publish(request))
  }
  private func expand(_ request: PromptPrefixCache.Session, width: Int) {
    for var cache in request.cache {
      cache.state = cache.state.map { broadcast($0, to: [width] + Array($0.shape.dropFirst())) }
    }
  }
  func testLongestPrefixInsideAForwardAndReturningEntityAreAutomatic() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), ids = Array(0..<9), firstOwner = owner()
      try publishPrompt(store, ids, owner: firstOwner)
      let changed = try session(store, [0, 1, 2, 90, 91], owner: owner(route: .consultation))
      XCTAssertEqual(changed.cachedTokenCount, 3)
      XCTAssertEqual(changed.input.text.tokens.asArray(Int.self), [90, 91])
      XCTAssertEqual(changed.cache[0].state[0].asArray(Float.self), [0, 1, 2])
      XCTAssertFalse(changed.preservesChunkBoundaries)
      try prefill(changed); XCTAssertTrue(store.publish(changed))
      let returning = try session(store, ids, owner: firstOwner)
      XCTAssertEqual(returning.cachedTokenCount, 8)
      XCTAssertEqual(returning.cache[0].state[0].asArray(Float.self), Array(0..<8).map(Float.init))
      XCTAssertTrue(returning.preservesChunkBoundaries)
      let privateOther = try session(store, ids, owner: owner(namespace: UUID()))
      XCTAssertEqual(privateOther.cachedTokenCount, 0)
    }
  }
  func testGeneratedKVIsReusedAndUnobservedLookaheadIsExcluded() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids, owner: scope); try prefill(request)
      request.didSample?(MLXArray([901]))
      append(request, values: [901]); request.didSample?(MLXArray([902]))
      append(request, values: [902]); request.didSample?(MLXArray([903]))
      append(request, values: [903]); request.didSample?(MLXArray([904]))
      XCTAssertTrue(store.publish(request, completions: [.init(emittedTokenIDs: [901, 902])]))
      XCTAssertEqual(store.retainedSnapshotObservations[0].tokenIDs, ids + [901, 902])
      let next = try session(store, ids + [901, 902, 999], owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 11)
      XCTAssertEqual(next.observation.cachedOrigin, .singleDecode)
      XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), (ids + [901, 902]).map(Float.init))
      XCTAssertFalse(store.retainedSnapshotObservations.contains { $0.tokenIDs.contains(903) })
    }
  }
  func testIncorrectSampleLedgerCannotPublishGeneratedKV() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids, owner: scope); try prefill(request)
      request.didSample?(MLXArray([901])); append(request, values: [901])
      request.didSample?(MLXArray([902]))
      XCTAssertTrue(store.publish(request, completions: [.init(emittedTokenIDs: [777])]))
      XCTAssertEqual(store.retainedSnapshotObservations[0].tokenIDs, ids)
    }
  }
  func testEachBatchRowRetainsOnlyProcessedDeliveredTokensAndSharesBacking() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids, owner: scope); try prefill(request); expand(request, width: 3)
      for row in 0..<3 {
        XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10], finished: false))
      }
      append(request, values: [901, 911, 921], width: 3)
      XCTAssertTrue(request.captureDecodeLane(row: 0, width: 3, emittedTokenIDs: [901, 902], finished: true))
      for row in 1..<3 {
        XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10], finished: false))
      }
      append(request, values: [-1, 912, 922], width: 3)
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
      XCTAssertLessThan(store.retainedBytesUpperBound, 3 * stagedBeforePublication)
      for row in 0..<3 {
        let delivered = row == 0 ? [901, 902] : [901 + row * 10, 902 + row * 10, 903 + row * 10]
        let next = try session(store, ids + delivered, owner: scope)
        let processed = row == 0 ? 10 : 11
        XCTAssertEqual(next.cachedTokenCount, processed)
        XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), (ids + Array(delivered.prefix(processed - ids.count))).map(Float.init))
        try prefill(next); XCTAssertTrue(store.publish(next))
        let repeatRequest = try session(store, ids + delivered + [999], owner: scope)
        XCTAssertEqual(repeatRequest.cachedTokenCount, ids.count + delivered.count)
      }
    }
  }
  func testResidentWindowsRollAndDoNotArchiveAnEntireLongPrompt() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<40)
      try publishPrompt(store, ids, owner: scope)
      let observation = store.retainedSnapshotObservations[0]
      XCTAssertGreaterThanOrEqual(observation.residentLocalStarts[0], 40 - 2 * 4 - 4)
      let repeatRequest = try session(store, ids, owner: scope)
      XCTAssertEqual(repeatRequest.cachedTokenCount, 39)
      XCTAssertEqual(repeatRequest.cache[1].state[0].asArray(Float.self), [35, 36, 37, 38])
      let oldEdit = try session(store, Array(0..<10) + [999], owner: scope)
      XCTAssertEqual(oldEdit.cachedTokenCount, 0, "An evicted local window must not be fabricated from the global cache.")
      XCTAssertEqual(oldEdit.observation.missReason, "local_coverage_missing")
    }
  }
  func testOlderResidentBranchRemainsUsableWhenNewestWindowCannotCoverQuery() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner()
      try publishPrompt(store, Array(0..<9), owner: scope)
      try publishPrompt(store, Array(0..<40), owner: scope)
      let request = try session(store, [0, 1, 2, 3, 4, 99], owner: scope)
      XCTAssertEqual(request.cachedTokenCount, 5)
    }
  }
  func testChangingForwardGeometryDoesNotPreventValidResidentReuse() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      try publishPrompt(store, ids, owner: scope)
      let request = try session(store, ids + [99], owner: scope, step: 3, chunking: .balanced)
      XCTAssertEqual(request.cachedTokenCount, 9)
      XCTAssertFalse(request.preservesChunkBoundaries)
      XCTAssertEqual(request.observation.originalGeometry.chunking, .balanced)
    }
  }
  func testBudgetDeclineRetainsEarlierCompleteForwardWithoutAFalseGap() throws {
    final class Guard: @unchecked Sendable {
      private let lock = NSLock(); private var calls = 0
      func allow(_ bytes: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; calls += 1; return calls == 1
      }
    }
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), guardState = Guard()
      let request = try session(store, Array(0..<9), owner: scope, allow: { guardState.allow($0) })
      try prefill(request); XCTAssertTrue(store.publish(request))
      XCTAssertEqual(store.retainedAnchorTokenCounts, [4])
      let next = try session(store, Array(0..<9), owner: scope)
      XCTAssertEqual(next.cachedTokenCount, 4)
    }
  }
  func testStaleTicketAndDiscardCannotPublish() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let stale = try session(store, ids, owner: scope); try prefill(stale)
      let current = try session(store, ids, owner: scope)
      XCTAssertFalse(store.publish(stale))
      try prefill(current); current.discardStagedAnchors()
      XCTAssertFalse(store.publish(current))
      XCTAssertFalse(store.hasAnchors)
      let cleared = try session(store, ids, owner: scope); try prefill(cleared)
      store.clear(reason: "residency_evicted")
      XCTAssertFalse(store.publish(cleared))
      XCTAssertEqual(try session(store, ids, owner: scope).observation.missReason, "residency_evicted")
    }
  }
  func testUnfinishedLayerCohortCannotBePublished() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), request = try session(store, Array(0..<9), owner: owner())
      let values = MLXArray([Float(0), 1, 2, 3], [1, 1, 4, 1])
      _ = request.cache[0].update(keys: values, values: values)
      request.prefill.progress?(9, 9)
      XCTAssertFalse(store.publish(request))
      XCTAssertFalse(store.hasAnchors)
    }
  }
  func testPoolEvictsInactiveEntriesAndCountsEachBackingOnce() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 180), scope = owner()
      try publishPrompt(store, Array(0..<9), owner: scope)
      try publishPrompt(store, Array(100..<109), owner: scope)
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 180)
      XCTAssertLessThan(store.retainedAnchorTokenCounts.count, 2)
      XCTAssertEqual(try session(store, Array(100..<109), owner: scope).cachedTokenCount, 8)
      XCTAssertEqual(try session(store, Array(0..<9), owner: scope).cachedTokenCount, 0)
    }
  }
}
