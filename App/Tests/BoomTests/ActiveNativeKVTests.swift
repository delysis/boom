import BoomCore
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest
@testable import Boom

/// Tiny CPU tensors test native ownership, actual rows/rings and allocation
/// boundaries. They do not qualify GPU peaks, model numerics or warm Replay.
final class ActiveNativeKVTests: XCTestCase {
  private let namespace = UUID()
  private func owner() -> PromptCacheOwner { .init(namespace: namespace, entity: UUID(), route: .writing) }
  private func binding(_ owner: PromptCacheOwner) -> JoinedKVRetentionBinding {
    .init(owner: owner, workspaceEpoch: UUID(), runnerEpoch: UUID(), modelIdentity: "cpu-model",
      processorIdentity: "cpu-processor", policyDigest: String(repeating: "a", count: 64), operationID: UUID())
  }
  private func session(_ store: PromptPrefixCache, _ ids: [Int], _ owner: PromptCacheOwner,
    step: Int = 2, window: Int = 4, globals: Int = 1, batchWidth: Int = 1,
    binding: JoinedKVRetentionBinding? = nil,
    admit: ((ActiveNativeKVAdmissionPlan?) throws -> Void)? = nil) throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(ids, [1, ids.count])),
      promptTokenIDs: ids, prefill: .init(stepSize: step, chunking: .remainder),
      joinedRetentionBinding: binding, useActiveNative: true, outputTokens: 2, batchWidth: batchWidth,
      admitNative: admit, makeCache: {
        let full: [KVCache] = (0..<globals).map { _ in let c = KVCacheSimple(); c.step = 4; return c }
        return full + [RotatingKVCache(maxSize: window, step: 2)]
      })
  }
  private func append(_ s: PromptPrefixCache.Session, _ ids: [Int], width: Int = 1, submitted: Bool = true) async {
    let k = MLXArray(ids.map(Float.init), [width, 1, ids.count / width, 1])
    for c in s.cache { _ = c.update(keys: k, values: k + 100) }
      if submitted {
      asyncEval(s.cache.flatMap { $0.innerState() })
      eval(s.cache); s.markCacheSubmitted()
      s.observeReadySpill(); await s.joinPendingSpill(cancelled: false)
    }
  }
  private func prefill(_ s: PromptPrefixCache.Session) async throws {
    let ids = s.input.text.tokens.asArray(Int.self)
    var partition = s.prefill; partition.progress = nil
    var ranges: [Range<Int>] = []
    let done = try partition.forEachChunk(total: ids.count) { ranges.append($0) }
    if done < ids.count { ranges.append(done..<ids.count) }
    for range in ranges {
      await append(s, Array(ids[range]))
      s.prefill.progress?(range.upperBound, ids.count)
    }
  }
  private func seed(_ store: PromptPrefixCache, _ ids: [Int], _ owner: PromptCacheOwner,
    globals: Int = 1) async throws {
    let s = try session(store, ids, owner, globals: globals); try await prefill(s)
    XCTAssertTrue(store.publish(s))
  }
  private func expand(_ s: PromptPrefixCache.Session, width: Int) {
    for var c in s.cache {
      let state = c.innerState(), offset = c.offset, meta = c.metaState
      c.state = state.map { broadcast($0, to: [width] + Array($0.shape.dropFirst())) }
      if case .simple = PrefixKVStorage.layout(of: c) { _ = c.trim(c.offset - offset) }
      else { c.metaState = meta }
    }
    eval(s.cache)
  }
  private func approved(_ b: JoinedKVRetentionBinding) -> JoinedKVRetentionAuthorization {
    let a = JoinedKVRetentionAuthorization(binding: b); XCTAssertTrue(a.approve(binding: b)); return a
  }
  private let constructorProof = JoinedKVRetentionProof(termination: .constructorCancelled,
    producerJoined: true, existingFenceCompleted: true, checkpointUncertain: false,
    memoryLimitExceeded: false, statelessTextKVVerified: true)

  func testSameWidthGlobalTransfersActualObjectAndSpareCapacity() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let s = try session(store, ids, scope); try await prefill(s)
      let native = PrefixKVStorage.unwrap(s.cache[0]), id = ObjectIdentifier(native as AnyObject)
      XCTAssertEqual(native.innerState()[0].dim(2), 12)
      XCTAssertTrue(store.publish(s))
      let next = try session(store, ids, scope)
      XCTAssertEqual(next.cachedTokenCount, 8)
      XCTAssertEqual(ObjectIdentifier(PrefixKVStorage.unwrap(next.cache[0]) as AnyObject), id)
      XCTAssertEqual(next.cache[0].innerState()[0].dim(2), 12)
      XCTAssertEqual(next.cache[0].offset, 8)
      XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), Array(0..<8).map(Float.init))
    }
  }
  func testWarmFourRowAdmissionAndEveryGeneratedRowRestore() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let ids = Array(0..<9), first = [901, 911, 921, 931], last = [902, 912, 922, 932]
      try ProductCore.admitWritingBatch(width: 4, prompt: ids.count, output: 2, capacity: 16_384)
      // Each selection needs its own real lifetime: native lookup transfers the
      // sole active cache rather than copying a snapshot for four later queries.
      for selectedRow in 0..<4 {
        let store = PromptPrefixCache(byteLimit: 4_096), scope = owner()
        try await seed(store, ids, scope)
        var admitted: ActiveNativeKVAdmissionPlan?
        let warm = try session(store, ids, scope, batchWidth: 4, admit: { plan in
          admitted = try XCTUnwrap(plan, "This must use warm admission, not a cold four-row control.")
        })
        let plan = try XCTUnwrap(admitted)
        XCTAssertEqual(warm.cachedTokenCount, 8)
        XCTAssertEqual(plan.cachedTokenCount, 8)
        XCTAssertEqual(plan.sourceWidth, 1); XCTAssertEqual(plan.consumerWidth, 4)
        let one = try plan.transitionAllocations(width: 1, forwards: 1, hydration: false)
        let four = try plan.transitionAllocations(width: 4, forwards: 1, hydration: false)
        for (single, batch) in zip(one, four) {
          XCTAssertEqual(batch.destinationBytes, 4 * single.destinationBytes)
          XCTAssertEqual(batch.zeroExtensionBytes, 4 * single.zeroExtensionBytes)
          XCTAssertEqual(batch.hydrationBytes, 0); XCTAssertEqual(batch.sharedPrefillBytes, 0)
        }
        let flag = CancellationFlag()
        let readmission = ActiveNativeKVReadmission(flag: flag, authorization: nil) { width, forwards in
          _ = try plan.transitionAllocations(width: width, forwards: forwards, hydration: false)
        }
        try readmission.beforeBatchForward(width: 4)
        XCTAssertEqual(readmission.observation.width, 4)
        XCTAssertEqual(readmission.observation.checks, 1)
        XCTAssertFalse(flag.isCancelled)

        try await prefill(warm); expand(warm, width: 4)
        for row in 0..<4 {
          XCTAssertTrue(warm.captureDecodeLane(row: row, width: 4,
            emittedTokenIDs: [first[row]], finished: false))
        }
        await append(warm, first, width: 4); eval(warm.cache); warm.markCacheSubmitted()
        for row in 0..<4 {
          XCTAssertTrue(warm.captureFinishedLane(row: row, width: 4,
            emittedTokenIDs: [first[row], last[row]]))
        }
        XCTAssertTrue(store.publish(warm, completions: (0..<4).map {
          .init(row: $0, emittedTokenIDs: [first[$0], last[$0]])
        }))
        let rows = store.retainedSnapshotObservations.sorted { ($0.row ?? -1) < ($1.row ?? -1) }
        XCTAssertEqual(rows.count, 4)
        for row in 0..<4 {
          let value = try XCTUnwrap(rows.first { $0.row == row })
          XCTAssertEqual(value.nativePhysicalWidth, 4)
          XCTAssertEqual(value.tokenIDs, ids + [first[row]])
          XCTAssertFalse(value.tokenIDs.contains(last[row]), "The delivered last token has not entered KV.")
        }
        XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 4_096)
        let parentBytes = store.retainedNativeBytesUpperBound

        let query = ids + [first[selectedRow], last[selectedRow]]
        let selectedPlan = try XCTUnwrap(store.nativeAdmissionPlan(owner: scope, tokens: query,
          prefill: .init(stepSize: 2, chunking: .remainder), outputTokens: 2, batchWidth: 4))
        XCTAssertEqual(selectedPlan.sourceWidth, 4); XCTAssertEqual(selectedPlan.consumerWidth, 4)
        XCTAssertEqual(selectedPlan.sourceRow, selectedRow)
        let restored = try session(store, query, scope, batchWidth: 4)
        XCTAssertEqual(restored.cachedTokenCount, 10)
        XCTAssertEqual(restored.observation.cachedRow, selectedRow)
        XCTAssertEqual(restored.observation.cachedNativePhysicalWidth, 4)
        XCTAssertEqual(restored.input.text.tokens.asArray(Int.self), [last[selectedRow]])
        XCTAssertEqual(restored.cache[0].state[0].asArray(Float.self), (ids + [first[selectedRow]]).map(Float.init))
        XCTAssertEqual(restored.cache[1].state[0].asArray(Float.self), [6, 7, 8, first[selectedRow]].map(Float.init))
        XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, parentBytes,
          "A selected-row view must retain the complete four-row parent until its real joined transfer.")
        try await prefill(restored); expand(restored, width: 4)
        XCTAssertTrue(restored.cache.allSatisfy { $0.innerState().allSatisfy { $0.dim(0) == 4 } })
        XCTAssertEqual(restored.cache[0].state[0].asArray(Float.self),
          Array(repeating: query.map(Float.init), count: 4).flatMap { $0 })
        XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 4_096)
        XCTAssertThrowsError(try selectedPlan.transitionAllocations(width: 5, forwards: 1, hydration: false))
      }
    }
  }

  func testFullAttentionIncomingPagesAreNotHistoricalStaging() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let scope = owner(), ids = Array(0..<62), one = PromptPrefixCache(), five = PromptPrefixCache()
      try await seed(one, ids, scope, globals: 1); try await seed(five, ids, scope, globals: 5)
      XCTAssertEqual(one.retainedBytesUpperBound, five.retainedBytesUpperBound)
      XCTAssertGreaterThan(five.retainedNativeBytesUpperBound, one.retainedNativeBytesUpperBound)
      XCTAssertLessThanOrEqual(one.retainedBytesUpperBound, 1 << 30)
    }
  }

  func testInterruptedScalarExtractionRetainsPhysicalRowZeroAndBatchProvenance() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let ids = Array(0..<9), first = [901, 911], last = [902, 912]
      let store = PromptPrefixCache(byteLimit: 4_096), scope = owner()
      let batched = try session(store, ids, scope, batchWidth: 2)
      try await prefill(batched); expand(batched, width: 2)
      for row in 0..<2 {
        XCTAssertTrue(batched.captureDecodeLane(row: row, width: 2,
          emittedTokenIDs: [first[row]], finished: false))
      }
      await append(batched, first, width: 2)
      for row in 0..<2 {
        XCTAssertTrue(batched.captureFinishedLane(row: row, width: 2,
          emittedTokenIDs: [first[row], last[row]]))
      }
      XCTAssertTrue(store.publish(batched, completions: (0..<2).map {
        .init(row: $0, emittedTokenIDs: [first[$0], last[$0]])
      }))
      let query = ids + [first[1], last[1]], retention = binding(scope)
      let scalar = try session(store, query, scope, binding: retention)
      XCTAssertEqual(scalar.observation.cachedRow, 1)
      XCTAssertEqual(scalar.cachedTokenCount, 10)
      // The extracted width-one cache really submits, but construction stops
      // before a suffix forward. Its inherited history still ends in batch row 1.
      eval(scalar.cache); scalar.markCacheSubmitted()
      XCTAssertTrue(store.publishJoinedValidPrefix(scalar, proof: constructorProof,
        authorization: approved(retention)))
      let plan = try XCTUnwrap(store.nativeAdmissionPlan(owner: scope, tokens: query,
        prefill: .init(stepSize: 2, chunking: .remainder), outputTokens: 2, batchWidth: 1))
      XCTAssertEqual(plan.sourceWidth, 1)
      XCTAssertEqual(plan.sourceRow, 0)
      let resumed = try session(store, query, scope)
      XCTAssertEqual(resumed.cachedTokenCount, 10)
      XCTAssertEqual(resumed.observation.cachedRow, 1, "Keep original forward provenance separate from physical row identity.")
      XCTAssertEqual(resumed.cache[0].state[0].asArray(Float.self), (ids + [first[1]]).map(Float.init))
      XCTAssertEqual(resumed.cache[1].state[0].asArray(Float.self), [6, 7, 8, first[1]].map(Float.init))
    }
  }
  func testGeneratedPrefixKeepsDeliveredLedgerAndExcludesLookahead() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let s = try session(store, ids, scope); try await prefill(s)
      s.didSample?(MLXArray([901])); await append(s, [901]); s.didSample?(MLXArray([902]))
      await append(s, [902]); s.didSample?(MLXArray([903])); await append(s, [903]); s.didSample?(MLXArray([904]))
      eval(s.cache); s.markCacheSubmitted()
      XCTAssertTrue(store.publish(s, completions: [.init(emittedTokenIDs: [901, 902])],
        acknowledged: [.init(emittedTokenIDs: [901])]))
      let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(snapshot.tokenIDs, ids + [901, 902])
      XCTAssertEqual(snapshot.nativeRowReceipt?.completedTokenCount, 12)
      XCTAssertEqual(snapshot.nativeRowReceipt?.submittedTokenCount, 12)
      XCTAssertEqual(snapshot.nativeRowReceipt?.deliveredGeneratedTokenCount, 2)
      XCTAssertEqual(snapshot.nativeRowReceipt?.acknowledgedGeneratedTokenCount, 1)
      let next = try session(store, ids + [901, 902, 999], scope)
      XCTAssertEqual(next.cachedTokenCount, 11)
      XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), (ids + [901, 902]).map(Float.init))
    }
  }
  func testWrappedLocalRewindUsesExactWindowAndMaskOffset() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      try await seed(store, ids, scope)
      let next = try session(store, ids, scope)
      XCTAssertEqual(next.cachedTokenCount, 8)
      let local = next.cache[1]
      XCTAssertEqual(local.offset, 8)
      XCTAssertEqual(local.state[0].asArray(Float.self), [4, 5, 6, 7])
      XCTAssertEqual(local.state[1].asArray(Float.self), [104, 105, 106, 107])
      let ref = RotatingKVCache(maxSize: 4, step: 2)
      ref.state = [MLXArray([Float(4), 5, 6, 7], [1, 1, 4, 1]), MLXArray([Float(104), 105, 106, 107], [1, 1, 4, 1])]
      ref.metaState = ["0", "4", "2", "8", "4", "modelNative", "false"]
      XCTAssertEqual(local.metaState, ref.metaState)
      guard case .array(let actualMask) = local.makeMask(n: 2, windowSize: 4, returnArray: true),
        case .array(let referenceMask) = ref.makeMask(n: 2, windowSize: 4, returnArray: true) else {
        return XCTFail("Expected array masks for the exact local history.")
      }
      XCTAssertEqual(actualMask.shape, referenceMask.shape)
      XCTAssertEqual(actualMask.asArray(Bool.self), referenceMask.asArray(Bool.self))
      let input = MLXArray([Float(1), 2], [1, 1, 1, 2])
      XCTAssertEqual(RoPE(dimensions: 2, traditional: true)(input, offset: local.offset).asArray(Float.self),
        RoPE(dimensions: 2, traditional: true)(input, offset: ref.offset).asArray(Float.self))
    }
  }
  func testScaledLongPromptTrailingEditUsesBoundedLocalCoverage() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<62)
      try await seed(store, ids, scope)
      let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
      let ranges = try XCTUnwrap(snapshot.residentLocalCoverage?.first?.intervals)
      XCTAssertEqual(ranges, [.init(lowerBound: 0, upperBound: 62)], "Optional disk history remains available until real quota pressure.")
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      let next = try session(store, Array(0..<60) + [999, 1000], scope)
      XCTAssertEqual(next.cachedTokenCount, 60)
      XCTAssertEqual(next.cache[1].state[0].asArray(Float.self), [56, 57, 58, 59])
      XCTAssertEqual(next.cache[0].innerState()[0].dim(2), 64)
    }
  }
  func testMissingOldLocalCoverageNeverFabricatesGlobalOnlyHit() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(diskByteLimit: 1), scope = owner(); try await seed(store, Array(0..<62), scope)
      let next = try session(store, Array(0..<8) + [999], scope)
      XCTAssertEqual(next.cachedTokenCount, 0)
    }
  }
  func testEarlyFinishedBatchRowKeepsExactWindowAndParentCharge() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      let s = try session(store, ids, scope); try await prefill(s); expand(s, width: 3)
      for row in 0..<3 { XCTAssertTrue(s.captureDecodeLane(row: row, width: 3, emittedTokenIDs: [901 + row * 10], finished: false)) }
      await append(s, [901, 911, 921], width: 3); eval(s.cache); s.markCacheSubmitted()
      XCTAssertTrue(s.captureFinishedLane(row: 0, width: 3, emittedTokenIDs: [901, 902]))
      var lane1 = [911], lane2 = [921]
      for n in 1...12 {
        lane1.append(911 + n); lane2.append(921 + n)
        XCTAssertTrue(s.captureDecodeLane(row: 1, width: 3, emittedTokenIDs: lane1, finished: false))
        XCTAssertTrue(s.captureDecodeLane(row: 2, width: 3, emittedTokenIDs: lane2, finished: false))
        await append(s, [-1, 911 + n, 921 + n], width: 3)
      }
      eval(s.cache); s.markCacheSubmitted()
      XCTAssertTrue(store.publish(s, completions: [.init(row: 0, emittedTokenIDs: [901, 902]),
        .init(row: 1, emittedTokenIDs: lane1), .init(row: 2, emittedTokenIDs: lane2)]))
      let frozen = try XCTUnwrap(store.retainedSnapshotObservations.first { $0.row == 0 })
      XCTAssertEqual(frozen.tokenIDs, ids + [901]); XCTAssertEqual(frozen.nativePhysicalWidth, 3)
      let parentBytes = store.retainedNativeBytesUpperBound
      let next = try session(store, ids + [901, 999], scope)
      XCTAssertEqual(next.cachedTokenCount, 10)
      XCTAssertEqual(next.observation.cachedRow, 0)
      XCTAssertEqual(next.cache[1].state[0].asArray(Float.self), [6, 7, 8, 901])
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, parentBytes,
        "Unevaluated global row materialization retains the full old parent.")
      XCTAssertEqual(next.cache[0].state[0].asArray(Float.self), (ids + [901]).map(Float.init))
    }
  }
  func testClearDoesNotDiscountStillOwnedNativeAliases() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner()
      var s: PromptPrefixCache.Session? = try session(store, Array(0..<9), scope)
      try await prefill(s!); XCTAssertTrue(store.publish(s!))
      let held = store.retainedNativeBytesUpperBound; XCTAssertGreaterThan(held, 0)
      store.clear(reason: "workspace_closed")
      XCTAssertFalse(store.hasAnchors); XCTAssertEqual(store.retainedNativeBytesUpperBound, held)
      s = nil; XCTAssertEqual(store.retainedNativeBytesUpperBound, 0)
    }
  }
  func testWarmAdmissionRefusalOccursBeforeTransferAndColdRemeasures() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(); try await seed(store, Array(0..<9), scope)
      var sawWarm = false, sawCold = false
      let next = try session(store, Array(0..<9), scope, admit: { plan in
        if plan != nil { sawWarm = true; XCTAssertTrue(store.hasAnchors); throw BoomError.budget("test refusal") }
        sawCold = true; XCTAssertTrue(store.hasAnchors, "Disk history is not retired to claim a native release credit."); XCTAssertEqual(store.retainedNativeBytesUpperBound, 0)
      })
      XCTAssertTrue(sawWarm); XCTAssertTrue(sawCold); XCTAssertEqual(next.cachedTokenCount, 0)
      XCTAssertEqual(next.observation.missReason, "native_admission_refused")
    }
  }
  func testOneActiveBranchAndNamespaceAuthorityRemainExact() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      try await seed(store, ids, scope)
      let privateOwner = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
      XCTAssertNil(try store.nativeAdmissionPlan(owner: privateOwner, tokens: ids,
        prefill: .init(stepSize: 2), outputTokens: 2, batchWidth: 1))
      XCTAssertNil(try store.nativeAdmissionPlan(owner: nil, tokens: ids,
        prefill: .init(stepSize: 2), outputTokens: 2, batchWidth: 1))
      XCTAssertTrue(store.hasAnchors)
      let changed = try session(store, [0, 1, 900, 901, 902], scope); try await prefill(changed)
      XCTAssertTrue(store.publish(changed))
      XCTAssertEqual(try session(store, ids, scope).cachedTokenCount, 8,
        "The historical branch is disk-backed while only one native branch stays hot.")
    }
  }
  func testSelectedBatchRowWithoutAnyCurrentSubmissionCannotAdoptLazyHydration() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<9)
      var source: PromptPrefixCache.Session? = try session(store, ids, scope)
      try await prefill(source!); expand(source!, width: 3)
      for row in 0..<3 {
        XCTAssertTrue(source!.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10], finished: false))
      }
      await append(source!, [901, 911, 921], width: 3); eval(source!.cache); source!.markCacheSubmitted()
      for row in 0..<3 {
        XCTAssertTrue(source!.captureFinishedLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10]))
      }
      XCTAssertTrue(store.publish(source!, completions: (0..<3).map {
        .init(row: $0, emittedTokenIDs: [901 + $0 * 10, 902 + $0 * 10])
      }))
      weak var parent = PrefixKVStorage.unwrap(source!.cache[0]) as? KVCacheSimple
      let parentBytes = UInt64(parent!.innerState().reduce(0) { $0 + $1.nbytes })
      source = nil
      let b = binding(scope), auth = approved(b)
      var selected: PromptPrefixCache.Session? = try session(store, ids + [911, 999], scope, binding: b)
      XCTAssertEqual(selected!.cachedTokenCount, 10)
      XCTAssertEqual(selected!.observation.cachedRow, 1)
      XCTAssertEqual(selected!.cache[0].innerState()[0].dim(0), 1)
      XCTAssertEqual(selected!.submittedTokenCount, 10, "Inherited prefix count is not a current graph submission.")
      // No forward, progress, tensor read, eval or markCacheSubmitted on selected.
      XCTAssertFalse(store.publishJoinedValidPrefix(selected!, proof: constructorProof, authorization: auth))
      XCTAssertTrue(store.hasAnchors); XCTAssertEqual(store.retainedSnapshotObservations.count, 3,
        "Refused current hydration cannot erase previously joined disk history.")
      XCTAssertNotNil(parent)
      XCTAssertGreaterThanOrEqual(store.retainedNativeBytesUpperBound, parentBytes,
        "Refused lazy hydration still holds the complete width-three parent.")
      selected = nil
      XCTAssertNil(parent); XCTAssertEqual(store.retainedNativeBytesUpperBound, 0)
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
    }
  }
  func testSelectedRowHydrationReservesZeroStepEvenWithoutLaterGrowth() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let native = KVCacheSimple(); native.step = 4
      native.state = [MLXArray.zeros([3, 2, 8, 3], dtype: .float32),
        MLXArray.zeros([3, 2, 8, 3], dtype: .float32)]
      let plan = try ActiveNativeKVStorage.plan(owners: [.init(native: native)], layouts: [.simple(step: 4)],
        prefix: 7, prompt: 8, output: 1, width: 1, row: 1, prefill: .init(stepSize: 2, chunking: .remainder))
      let perPosition = UInt64(2 * 3 * 4 * 2)
      XCTAssertFalse(plan.layers[0].grows); XCTAssertEqual(plan.layers[0].zeroExtensionBytes, 0)
      XCTAssertEqual(plan.layers[0].destinationBytes, perPosition * 12)
      XCTAssertEqual(plan.layers[0].hydrationBytes, perPosition * (12 + 4),
        "Initial H includes concat(capacity+step) and its zeros(step) input.")
      let initial = try plan.transitionAllocations(width: 1, forwards: 2, hydration: true)
      XCTAssertEqual(initial[0].hydrationBytes, perPosition * 16)
      XCTAssertEqual(initial[0].destinationBytes + initial[0].hydrationBytes, perPosition * (2 * 12 + 16))
      let submitted = try plan.transitionAllocations(width: 1, forwards: 2, hydration: false)
      XCTAssertEqual(submitted[0].hydrationBytes, 0,
        "After actual submission its buffers stay in measured U, not a release credit.")
    }
  }
  func testSlidingAdmissionCoversActualGrowthStepsAndDiscardedSpareCapacity() async throws {
    try await Device.withDefaultDevice(.cpu) {
      for prefix in [20, 255, 256, 1_023, 1_025] {
        for suffix in [1, 8, 129] {
          let native = RotatingKVCache(maxSize: 1_024, step: 256)
          func update(_ count: Int) {
            let keys = MLXArray.zeros([1, 2, count, 3], dtype: .float32)
            _ = native.update(keys: keys, values: keys)
            eval(native)
          }
          update(prefix)
          // A preceding decode leaves unused step capacity. The next prefill
          // discards it, then the tail/decode allocates another complete step.
          update(1)
          let retained = prefix + 1, output = 64
          let plan = try ActiveNativeKVStorage.plan(owners: [.init(native: native)],
            layouts: [try XCTUnwrap(PrefixKVStorage.layout(of: native))], prefix: retained,
            prompt: retained + suffix, output: output, width: 1, row: nil,
            prefill: .init(stepSize: 256, chunking: .remainder))
          let admission = try ProductCore.incrementalKVAdmission(application: 24 << 30,
            used: 0, reserve: 2 << 30, layers: plan.layers)
          XCTAssertTrue(admission.admitted)
          func checkCapacity() {
            let actual = UInt64(native.innerState().reduce(0) { $0 + $1.nbytes })
            XCTAssertLessThanOrEqual(actual, plan.layers[0].destinationBytes,
              "Actual native capacity exceeds the reservation for prefix \(retained), suffix \(suffix).")
          }
          if suffix > 1 { update(suffix - 1); checkCapacity() }
          for _ in 0...output { update(1); checkCapacity() }
        }
      }
    }
  }

  func testConstructorUsesSubmittedCohortAndRejectsUnsubmittedFinalGraph() async throws {
    try await Device.withDefaultDevice(.cpu) {
      for finalGraph in [false, true] {
        let store = PromptPrefixCache(), scope = owner(), b = binding(scope), auth = approved(b)
        let s = try session(store, Array(0..<9), scope, binding: b)
        await append(s, Array(0..<8)); asyncEval(s.cache); s.prefill.progress?(8, 9)
        if finalGraph { await append(s, [8], submitted: false); s.prefill.progress?(9, 9) }
        XCTAssertEqual(s.submittedTokenCount, 8)
        XCTAssertTrue(store.publishJoinedValidPrefix(s, proof: constructorProof, authorization: auth))
        let next = try session(store, Array(0..<8) + [999], scope)
        XCTAssertEqual(next.cachedTokenCount, 8)
        XCTAssertEqual(next.observation.cachedCurrentHotPrefix, !finalGraph)
        if finalGraph {
          XCTAssertEqual(s.cache[0].offset, 9, "Only independent disk bytes retained the submitted8; future native9 was not adopted.")
        }
      }
    }
  }
  func testRevokedGrantAndClearEpochCannotAdoptNativeState() async throws {
    try await Device.withDefaultDevice(.cpu) {
      for clear in [false, true] {
        let store = PromptPrefixCache(), scope = owner(), b = binding(scope), auth = approved(b)
        let s = try session(store, Array(0..<9), scope, binding: b)
        await append(s, Array(0..<8)); asyncEval(s.cache); s.prefill.progress?(8, 9)
        if clear { store.clear(reason: "model_replaced") } else { auth.revoke() }
        XCTAssertFalse(store.publishJoinedValidPrefix(s, proof: constructorProof, authorization: auth))
      }
    }
  }
  func testAdmissionMatchesPreservedBalancedSuffixStride() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), ids = Array(0..<14)
      func balanced(_ values: [Int]) throws -> PromptPrefixCache.Session {
        try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(values, [1, values.count])),
          promptTokenIDs: values, prefill: .init(stepSize: 6, chunking: .balanced),
          useActiveNative: true, outputTokens: 2, batchWidth: 1,
          makeCache: { let c = KVCacheSimple(); c.step = 4; return [c, RotatingKVCache(maxSize: 8, step: 2)] })
      }
      let original = try balanced(ids); try await prefill(original); XCTAssertTrue(store.publish(original))
      let current = Array(0..<5) + Array(100..<109)
      let plan = try XCTUnwrap(store.nativeAdmissionPlan(owner: scope, tokens: current,
        prefill: .init(stepSize: 6, chunking: .balanced), outputTokens: 2, batchWidth: 1))
      // Cold suffix8 balances to4; retained original13 balanced to5. Native
      // local concat can hold W+5-1=12, so11 would under-reserve the real call.
      XCTAssertEqual(plan.cachedTokenCount, 5)
      XCTAssertEqual(plan.layers[1].destinationBytes, 12 * 8)
      let next = try balanced(current)
      XCTAssertTrue(next.preservesChunkBoundaries)
      XCTAssertEqual(next.prefill.chunkLength(forChunking: 8), 5)
    }
  }
  func testAdmissionUsesActualCapacityWidthHeadsAndDtypeWithTwoForwardHorizon() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let native = KVCacheSimple(); native.step = 4
      native.state = [MLXArray.zeros([1, 2, 8, 3], dtype: .float32), MLXArray.zeros([1, 2, 8, 3], dtype: .float32)]
      let plan = try ActiveNativeKVStorage.plan(owners: [.init(native: native)], layouts: [.simple(step: 4)],
        prefix: 7, prompt: 8, output: 1, width: 3, row: nil, prefill: .init(stepSize: 2, chunking: .remainder))
      XCTAssertEqual(plan.layers[0].destinationBytes, 3 * 12 * 2 * 3 * 4 * 2)
      XCTAssertEqual(plan.layers[0].zeroExtensionBytes, 3 * 4 * 2 * 3 * 4 * 2)
      let two = try plan.transitionAllocations(width: 1, forwards: 2, hydration: false)
      XCTAssertEqual(two[0].destinationBytes, 2 * 12 * 2 * 3 * 4 * 2)
      XCTAssertEqual(two[0].zeroExtensionBytes, 2 * 4 * 2 * 3 * 4 * 2)
      XCTAssertEqual(two[0].hydrationBytes, 0); XCTAssertEqual(two[0].sharedPrefillBytes, 0)
      XCTAssertThrowsError(try plan.transitionAllocations(width: 1, forwards: 3, hydration: false))
    }
  }
  func testFinalChunkRefusalStillAllowsPreviouslyReservedTailAndDeniesPublication() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), auth = approved(b), flag = CancellationFlag()
      let request = try session(store, [0, 1, 2], scope, binding: b)
      let watch = ActiveNativeKVReadmission(flag: flag, authorization: auth) { _, _ in
        throw BoomError.budget("test callback refusal")
      }
      var progress = request.prefill
      let recorded = progress.progress
      progress.progress = { processed, total in
        recorded?(processed, total); watch.afterSubmittedPrefill(processed: processed, total: total)
      }
      var partition = progress; partition.progress = nil
      var ranges: [Range<Int>] = []
      let done = try partition.forEachChunk(total: 3) { ranges.append($0) }
      for range in ranges {
        await append(request, Array([0, 1, 2][range]))
        progress.progress?(range.upperBound, 3)
      }
      // Actual driver returned after its last nonterminal callback; no new
      // cancellation check exists before the Gemma final-tail graph.
      XCTAssertEqual(done, 2); XCTAssertTrue(watch.denied)
      await append(request, [2]); progress.progress?(3, 3); eval(request.cache); request.markCacheSubmitted()
      XCTAssertEqual(request.submittedTokenCount, 3)
      let denied = JoinedKVRetentionProof(termination: .constructorCancelled, producerJoined: true,
        existingFenceCompleted: true, checkpointUncertain: false, memoryLimitExceeded: watch.denied,
        statelessTextKVVerified: true)
      XCTAssertFalse(store.publishJoinedValidPrefix(request, proof: denied, authorization: auth))
    }
  }
  func testLastChunkRefusalRevokesAndTerminalProgressCannotArmDecode() async throws {
    let flag = CancellationFlag(), scope = owner(), b = binding(scope), auth = approved(b)
    let watch = ActiveNativeKVReadmission(flag: flag, authorization: auth) { width, forwards in
      XCTAssertEqual(width, 1); XCTAssertEqual(forwards, 2)
      throw BoomError.budget("test final chunk refusal")
    }
    let cancellation = flag.onCancel { XCTAssertTrue(watch.observation.denied) }
    defer { flag.removeCancellationHandler(cancellation) }
    watch.afterSubmittedPrefill(processed: 9, total: 9)
    XCTAssertEqual(watch.observation.checks, 0); XCTAssertFalse(flag.isCancelled)
    watch.afterSingleSampleBeforeSubmission()
    XCTAssertEqual(watch.observation.checks, 0, "Constructor sampling is not an armed decode boundary.")
    watch.afterSubmittedPrefill(processed: 8, total: 9)
    XCTAssertTrue(flag.isCancelled); XCTAssertTrue(watch.denied)
    XCTAssertFalse(auth.approve(binding: b)); XCTAssertThrowsError(try watch.requireAdmitted())
  }
}
