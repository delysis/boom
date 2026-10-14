import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

final class ResidentPrefixAdversarialTests: XCTestCase {
  private func owner() -> PromptCacheOwner {
    PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
  }

  private func session(_ store: PromptPrefixCache, ids: [Int], owner: PromptCacheOwner,
    caches: () throws -> [KVCache]) throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(ids, [1, ids.count])),
      promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 4, chunking: .remainder),
      useActiveNative: true, makeCache: caches)
  }

  private func append(_ request: PromptPrefixCache.Session, ids: [Int], width: Int = 1, submitted: Bool = true) async {
    let keys = MLXArray(ids.map(Float.init), [width, 1, ids.count / width, 1])
    let values = MLXArray(ids.map { -Float($0) - 1 }, [width, 1, ids.count / width, 1])
    for cache in request.cache { _ = cache.update(keys: keys, values: values) }
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
      await append(request, ids: Array(ids[range]))
      request.prefill.progress?(range.upperBound, ids.count)
    }
  }

  private func expand(_ request: PromptPrefixCache.Session, width: Int) {
    for var cache in request.cache {
      cache.state = cache.state.map { broadcast($0, to: [width] + Array($0.shape.dropFirst())) }
    }
  }

  private func assertKV(_ cache: any KVCache, ids: [Int], file: StaticString = #filePath,
    line: UInt = #line) {
    XCTAssertEqual(cache.state[0].asArray(Float.self), ids.map(Float.init), file: file, line: line)
    XCTAssertEqual(cache.state[1].asArray(Float.self), ids.map { -Float($0) - 1 }, file: file, line: line)
  }

  func testActualHeterogeneousLayerBytesRejectTheWholeCohortAndPermitASmallControl() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let ids = Array(0..<4), scope = owner(), limit: UInt64 = 64
      let store = PromptPrefixCache(byteLimit: limit)
      let rejected = try session(store, ids: ids, owner: scope) { [0, 1].map { _ in let cache = KVCacheSimple(); cache.step = 4; return cache } }
      let smallKeys = MLXArray(ids.map(Float.init), [1, 1, ids.count, 1]).asType(.float16)
      let smallValues = MLXArray(ids.map { -Float($0) - 1 }, [1, 1, ids.count, 1]).asType(.float16)
      let largeKeys = MLXArray(Array(repeating: Float(123), count: 2 * ids.count * 4),
        [1, 2, ids.count, 4])
      let largeValues = MLXArray(Array(repeating: Float(-124), count: 2 * ids.count * 4),
        [1, 2, ids.count, 4])
      let firstLayerBytes = UInt64(smallKeys.nbytes + smallValues.nbytes)
      let actualBytes = firstLayerBytes + UInt64(largeKeys.nbytes + largeValues.nbytes)
      XCTAssertLessThanOrEqual(2 * firstLayerBytes, limit, "The initial homogeneous estimate must fit.")
      XCTAssertGreaterThan(actualBytes, limit, "The actual heterogeneous cohort must exceed the bound.")

      _ = rejected.cache[0].update(keys: smallKeys, values: smallValues)
      XCTAssertEqual(rejected.stagedBytesUpperBound, 0, "No incoming RAM page is archived before the completed raw handoff.")
      _ = rejected.cache[1].update(keys: largeKeys, values: largeValues)
      rejected.prefill.progress?(ids.count, ids.count)
      XCTAssertEqual(rejected.cache.map(\.offset), [ids.count, ids.count], "Capture refusal must not alter native execution.")
      XCTAssertEqual(rejected.stagedBytesUpperBound, 0, "A rejected cohort must release its already tapped layer.")
      asyncEval(rejected.cache.flatMap { $0.innerState() }); eval(rejected.cache)
      rejected.markCacheSubmitted(); await rejected.joinPendingSpill(cancelled: false)
      XCTAssertTrue(store.publish(rejected), "The actual complete native cache remains usable even when a large parent cannot spill.")
      XCTAssertEqual(rejected.retentionObservation?.refusalReason, "pool_limit")
      store.clear() // next factory has a different actual head/dtype layout

      XCTAssertEqual(store.retainedBytesUpperBound, 0)

      let accepted = try session(store, ids: ids, owner: scope) { [0, 1].map { _ in let cache = KVCacheSimple(); cache.step = 4; return cache } }
      let controlKeys = smallKeys.asType(.float32), controlValues = smallValues.asType(.float32)
      let controlBytes = firstLayerBytes + UInt64(controlKeys.nbytes + controlValues.nbytes)
      XCTAssertGreaterThan(controlBytes, 2 * firstLayerBytes, "The fitting control must also correct the initial estimate.")
      XCTAssertLessThanOrEqual(controlBytes, limit)
      _ = accepted.cache[0].update(keys: smallKeys, values: smallValues)
      _ = accepted.cache[1].update(keys: controlKeys, values: controlValues)
      accepted.prefill.progress?(ids.count, ids.count)
      asyncEval(accepted.cache.flatMap { $0.innerState() }); eval(accepted.cache)
      accepted.markCacheSubmitted(); await accepted.joinPendingSpill(cancelled: false)
      XCTAssertTrue(store.publish(accepted))
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertEqual(accepted.retentionObservation?.diskBytes, controlBytes)
      let reuse = try session(store, ids: ids + [99], owner: scope) { [0, 1].map { _ in let cache = KVCacheSimple(); cache.step = 4; return cache } }
      XCTAssertEqual(reuse.cachedTokenCount, ids.count)
      XCTAssertEqual(reuse.cache[0].state[0].dtype, .float16)
      XCTAssertEqual(reuse.cache[1].state[0].dtype, .float32)
      assertKV(reuse.cache[0], ids: ids); assertKV(reuse.cache[1], ids: ids)
    }
  }

  func testFinishedBatchRowSurvivesPeersAdvancingBeyondTwoWindowsWithoutInertTokens() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 4_096), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids: ids, owner: scope) {
        [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
      }
      try await prefill(request); expand(request, width: 3)
      for row in 0..<3 {
        XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 100], finished: false))
      }
      await append(request, ids: [901, 1001, 1101], width: 3)
      XCTAssertTrue(request.captureFinishedLane(row: 0, width: 3, emittedTokenIDs: [901, 902]))
      for row in 1..<3 {
        XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 100, 902 + row * 100], finished: false))
      }
      let additionalForwards = 12
      XCTAssertGreaterThan(additionalForwards, 2 * 4)
      for step in 1...additionalForwards {
        await append(request, ids: [-1, 1001 + step, 1101 + step], width: 3)
        for row in 1..<3 {
          let first = 901 + row * 100
          XCTAssertTrue(request.captureDecodeLane(row: row, width: 3,
            emittedTokenIDs: Array(first...(first + step + 1)), finished: step == additionalForwards))
        }
      }
      let completions: [PromptPrefixCache.Completion] = [
        .init(row: 0, emittedTokenIDs: [901, 902]),
        .init(row: 1, emittedTokenIDs: Array(1001...1014)),
        .init(row: 2, emittedTokenIDs: Array(1101...1114)),
      ]
      XCTAssertTrue(store.publish(request, completions: completions))
      let snapshots = store.retainedSnapshotObservations
      XCTAssertEqual(snapshots.count, 3)
      XCTAssertEqual(snapshots.first(where: { $0.row == 0 })?.tokenIDs, ids + [901])
      XCTAssertEqual(snapshots.first(where: { $0.row == 1 })?.tokenIDs, ids + Array(1001...1013))
      XCTAssertEqual(snapshots.first(where: { $0.row == 2 })?.tokenIDs, ids + Array(1101...1113))
      XCTAssertFalse(snapshots.contains { $0.tokenIDs.contains(-1) })
      XCTAssertFalse(snapshots.contains { $0.tokenIDs.contains(902) || $0.tokenIDs.contains(1014) || $0.tokenIDs.contains(1114) })

      // Account complete underlying K/V buffers, including the two sibling rows
      // behind a selected-row view. Global and late local pages are shared once.
      let pairBytesPerPosition = UInt64(2 * MemoryLayout<Float>.size)
      let globalBytes = UInt64(ids.count + 3 * (1 + additionalForwards)) * pairBytesPerPosition
      let frozenRowZeroBytes = UInt64(ids.count + 3) * pairBytesPerPosition
      let currentLocalBytes = UInt64(2 * 4 * 3) * pairBytesPerPosition
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, globalBytes)
      _ = (frozenRowZeroBytes, currentLocalBytes) // predecessor RAM archive geometry is preserved in the preimage
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 4_096)

      for row in 0..<3 {
        let nextIDs = ids + completions[row].emittedTokenIDs
        let next = try session(store, ids: nextIDs, owner: scope) {
          [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
        }
        let retainedIDs = row == 0 ? ids + [901] : ids + Array(completions[row].emittedTokenIDs.dropLast())
        XCTAssertEqual(next.cachedTokenCount, retainedIDs.count)
        XCTAssertEqual(next.observation.cachedOrigin, .batchDecode)
        XCTAssertEqual(next.observation.cachedBatchWidth, 3); XCTAssertEqual(next.observation.cachedRow, row)
        assertKV(next.cache[0], ids: retainedIDs)
        assertKV(next.cache[1], ids: Array(retainedIDs.suffix(4)))
        XCTAssertEqual(next.input.text.tokens.asArray(Int.self), [completions[row].emittedTokenIDs.last!])
      }
    }
  }

  func testImmediateEOSFreezesEnoughResidentCoverageForTheLastPromptTokenToBeRecomputed() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 4_096), scope = owner(), ids = Array(0..<9)
      let request = try session(store, ids: ids, owner: scope) {
        [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
      }
      try await prefill(request); expand(request, width: 3)
      XCTAssertTrue(request.captureDecodeLane(row: 0, width: 3, emittedTokenIDs: [],
        stopTokenID: 99, finished: true))
      XCTAssertTrue(request.captureDecodeLane(row: 1, width: 3, emittedTokenIDs: [1000], finished: false))
      XCTAssertTrue(request.captureDecodeLane(row: 2, width: 3, emittedTokenIDs: [2000], finished: false))
      let peerForwards = 12
      XCTAssertGreaterThan(peerForwards, 2 * 4)
      for step in 1...peerForwards {
        await append(request, ids: [99, 999 + step, 1999 + step], width: 3)
        XCTAssertTrue(request.captureDecodeLane(row: 1, width: 3,
          emittedTokenIDs: Array(1000...(1000 + step)), finished: step == peerForwards))
        XCTAssertTrue(request.captureDecodeLane(row: 2, width: 3,
          emittedTokenIDs: Array(2000...(2000 + step)), finished: step == peerForwards))
      }
      XCTAssertTrue(store.publish(request, completions: [
        .init(row: 0, emittedTokenIDs: [], stopTokenID: 99),
        .init(row: 1, emittedTokenIDs: Array(1000...1012)),
        .init(row: 2, emittedTokenIDs: Array(2000...2012)),
      ]))
      let snapshots = store.retainedSnapshotObservations
      XCTAssertEqual(snapshots.count, 3)
      XCTAssertEqual(snapshots.first(where: { $0.row == 0 })?.tokenIDs, ids)
      XCTAssertEqual(snapshots.first(where: { $0.row == 1 })?.tokenIDs, ids + Array(1000...1011))
      XCTAssertEqual(snapshots.first(where: { $0.row == 2 })?.tokenIDs, ids + Array(2000...2011))
      XCTAssertFalse(snapshots.contains { $0.tokenIDs.contains(99) })
      let pairBytesPerPosition = UInt64(2 * MemoryLayout<Float>.size)
      let globalBytes = UInt64(ids.count + 3 * peerForwards) * pairBytesPerPosition
      let frozenPromptLocalBytes = UInt64(ids.count) * pairBytesPerPosition
      let currentPeerLocalBytes = UInt64(2 * 4 * 3) * pairBytesPerPosition
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, globalBytes)
      _ = (frozenPromptLocalBytes, currentPeerLocalBytes)
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 4_096)

      let repeatRequest = try session(store, ids: ids, owner: scope) {
        [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
      }
      XCTAssertEqual(repeatRequest.cachedTokenCount, 8, "One prompt token must remain for logits after EOS.")
      XCTAssertEqual(repeatRequest.input.text.tokens.asArray(Int.self), [8])
      XCTAssertEqual(repeatRequest.observation.cachedBatchWidth, 3)
      assertKV(repeatRequest.cache[0], ids: Array(0..<8))
      assertKV(repeatRequest.cache[1], ids: Array(4..<8))
      // The repeat's first eight tokens are shared by all rows. Only the
      // frozen EOS row still covers the ninth prompt token after its peers roll.
      let continued = try session(store, ids: ids + [77], owner: scope) {
        [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
      }
      XCTAssertEqual(continued.cachedTokenCount, ids.count)
      XCTAssertEqual(continued.observation.cachedRow, 0)
      XCTAssertEqual(continued.observation.cachedBatchWidth, 3)
      XCTAssertEqual(continued.input.text.tokens.asArray(Int.self), [77])
      assertKV(continued.cache[0], ids: ids)
      assertKV(continued.cache[1], ids: Array(5..<9))
      let interior = try session(store, ids: Array(0..<5) + [77], owner: scope) {
        [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
      }
      XCTAssertEqual(interior.cachedTokenCount, 5)
      assertKV(interior.cache[0], ids: Array(0..<5))
      assertKV(interior.cache[1], ids: Array(1..<5))
    }
  }

  func testLongDecodeKeepsOnlyBoundedResidentWindowsAndHydratesARecentInteriorPrefix() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let window = 4, forwards = 1_024, ids = Array(0..<9), scope = owner()
      let store = PromptPrefixCache(byteLimit: 192)
      let request = try session(store, ids: ids, owner: scope) { [RotatingKVCache(maxSize: window, step: 2)] }
      try await prefill(request)
      let ledger = Array(2_000..<(2_000 + forwards))
      let initialRange = 4..<8
      let pairBytesPerPosition = UInt64(2 * MemoryLayout<Float>.size)
      let retainedBound = UInt64(initialRange.count + 2 * window) * pairBytesPerPosition
      for (position, token) in ledger.enumerated() {
        request.didSample?(MLXArray([token]))
        await append(request, ids: [token])
        if position >= 2 * window {
          XCTAssertLessThanOrEqual(request.stagedBytesUpperBound, retainedBound,
            "Only the initial reusable window and rolling tail may retain backing charges.")
        }
        if position % 32 == 0 { _ = request.cache[0].state[0].asArray(Float.self) }
      }
      XCTAssertTrue(store.publish(request, completions: [.init(emittedTokenIDs: ledger)]))
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 192)
      let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(store.retainedSnapshotObservations.count, 1)
      XCTAssertEqual(snapshot.tokenIDs, ids + ledger)
      XCTAssertEqual(snapshot.origin, .singleDecode)
      XCTAssertEqual(snapshot.residentLocalStarts, [0])
      XCTAssertEqual(snapshot.residentLocalCoverage, [.init(layer: 0, window: window, keep: 0,
        intervals: [.init(lowerBound: 0, upperBound: ids.count + forwards)])],
        "Ample disk quota preserves admitted middle intervals without a resident archive.")
      XCTAssertEqual(snapshot.forwardHistory.last?.endTokenCount, ids.count + forwards)

      let repeatPrompt = try session(store, ids: ids, owner: scope) {
        [RotatingKVCache(maxSize: window, step: 2)]
      }
      XCTAssertEqual(repeatPrompt.cachedTokenCount, initialRange.upperBound)
      XCTAssertEqual(repeatPrompt.input.text.tokens.asArray(Int.self), [8])
      assertKV(repeatPrompt.cache[0], ids: Array(initialRange))
      let gapIDs = ids + Array(ledger.prefix(forwards / 2)) + [93_000]
      let gap = try session(store, ids: gapIDs, owner: scope) {
        [RotatingKVCache(maxSize: window, step: 2)]
      }
      XCTAssertEqual(gap.cachedTokenCount, gapIDs.count - 1)
      XCTAssertEqual(gap.input.text.tokens.asArray(Int.self), [93_000])
      assertKV(gap.cache[0], ids: Array(gapIDs.dropLast().suffix(window)))
      let exact = try session(store, ids: ids + ledger + [90_000], owner: scope) {
        [RotatingKVCache(maxSize: window, step: 2)]
      }
      XCTAssertEqual(exact.cachedTokenCount, ids.count + forwards)
      assertKV(exact.cache[0], ids: Array(ledger.suffix(window)))
      let interiorIDs = ids + Array(ledger.dropLast(3))
      let interior = try session(store, ids: interiorIDs + [91_000], owner: scope) {
        [RotatingKVCache(maxSize: window, step: 2)]
      }
      XCTAssertEqual(interior.cachedTokenCount, interiorIDs.count)
      assertKV(interior.cache[0], ids: Array(interiorIDs.suffix(window)))
      let evicted = try session(store, ids: [0, 1, 92_000], owner: scope) {
        [RotatingKVCache(maxSize: window, step: 2)]
      }
      XCTAssertEqual(evicted.cachedTokenCount, 2)
      assertKV(evicted.cache[0], ids: [0, 1])
    }
  }
}
