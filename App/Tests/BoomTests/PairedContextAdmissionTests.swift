import BoomCore
import Foundation
import XCTest
@testable import Boom

/// Tensor-free retry/authority and coordinator identity checks only. These do
/// not qualify paired model residency, real memory peaks or packaged UI.
final class PairedContextAdmissionTests: XCTestCase {
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var owned = false
    func add(_ event: String) { lock.lock(); values.append(event); lock.unlock() }
    func enter() { lock.lock(); owned = true; values.append("enter"); lock.unlock() }
    func leave() { lock.lock(); owned = false; values.append("leave"); lock.unlock() }
    var leased: Bool { lock.lock(); defer { lock.unlock() }; return owned }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
  }
  private func request(_ flag: CancellationFlag) -> PreparedPairedAdmissionRequest {
    .init(operationID: flag.operationID, runnerEpoch: UUID(), modelIdentity: "public-model",
      processorIdentity: "public-processor", owner: .init(namespace: UUID(), entity: UUID(), route: .writing),
      tokenIDs: [11,12], outputTokens: 16, batchWidth: 3,
      policy: .init(schema: 1, vocabularySize: 32, eosTokenIDs: [0], suppressedTokenIDs: [],
        controlTokenIDs: [0], textDecoding: nil, prefill: .init(chunking: "fixed_v1", tokenCeiling: 512)))
  }
  private func changed(_ value: PreparedPairedAdmissionRequest, tokens: [Int]? = nil,
    operation: UUID? = nil, runner: UUID? = nil, model: String? = nil, processor: String? = nil,
    owner: PromptCacheOwner? = nil, output: Int? = nil, width: Int? = nil,
    policy: ModelGenerationPolicy? = nil) -> PreparedPairedAdmissionRequest {
    .init(operationID: operation ?? value.operationID, runnerEpoch: runner ?? value.runnerEpoch,
      modelIdentity: model ?? value.modelIdentity, processorIdentity: processor ?? value.processorIdentity,
      owner: owner ?? value.owner, tokenIDs: tokens ?? value.tokenIDs, outputTokens: output ?? value.outputTokens,
      batchWidth: width ?? value.batchWidth, policy: policy ?? value.policy)
  }
  func testSuccessfulPreparedNativeAdmissionLeavesBothRunnersAndNeverCallsPeerReclaimer() async throws {
    let flag = CancellationFlag(), state = State()
    let admission = PairedContextAdmission { _ in state.add("released-peer"); return true }
    let value = try await PairedContextAdmission.perform(using: admission, flag: flag) { attempt in
      state.enter(); defer { state.leave() }
      XCTAssertTrue(attempt.deferReclamation)
      // A prepared native plan fits even when the unrelated fresh estimate
      // would not. A successful result must escape without running callbacks.
      state.add("native-admitted-both-retained"); return 16_384
    }
    XCTAssertEqual(value, 16_384)
    XCTAssertEqual(state.events, ["enter", "native-admitted-both-retained", "leave"])
  }
  func testFailedPreparedFitExitsLeaseBeforePeerJoinThenRetriesExactCapture() async throws {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let admission = PairedContextAdmission { handoff in
      guard !state.leased else { throw BoomError.invalid("Peer join beneath the inference lease.") }
      XCTAssertEqual(handoff, binding); state.add("peer-joined-and-released"); return true
    }
    let value = try await PairedContextAdmission.perform(using: admission, flag: flag) { attempt in
      state.enter(); defer { state.leave() }
      if attempt.deferReclamation { state.add("prepared-fit-refused"); throw binding }
      try attempt.validate(binding); state.add("exact-source-measured-readmission"); return 16_384
    }
    XCTAssertEqual(value, 16_384)
    XCTAssertEqual(state.events, ["enter", "prepared-fit-refused", "leave", "peer-joined-and-released",
      "enter", "exact-source-measured-readmission", "leave"])
  }
  func testFalsePeerResultStillReadmitsWithoutAssumedReleasedBytes() async {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let admission = PairedContextAdmission { _ in state.add("no-peer-released"); return false }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { attempt -> Int in
        state.enter(); defer { state.leave() }
        if attempt.deferReclamation { throw binding }
        try attempt.validate(binding); state.add("measured-U-still-refuses")
        throw BoomError.budget("The freshly measured budget remains insufficient.")
      }
      XCTFail("A callback result is not memory admission.")
    } catch {
      state.add("caller-may-now-fit-history")
      XCTAssertEqual(state.events, ["enter", "leave", "no-peer-released", "enter",
        "measured-U-still-refuses", "leave", "caller-may-now-fit-history"])
    }
  }
  func testChangedExactTokenVectorRefusesBeforeTargetClearOrHistoryTrim() async {
    let flag = CancellationFlag(), binding = request(flag), replacement = changed(binding, tokens: [11,13]), state = State()
    let admission = PairedContextAdmission { _ in state.add("peer"); return true }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { attempt -> Int in
        if attempt.deferReclamation { throw binding }
        try attempt.validate(replacement); state.add("target-cleared-or-history-trimmed"); return 1
      }
      XCTFail("Changed prepared IDs were accepted.")
    } catch { XCTAssertEqual(state.events, ["peer"]) }
  }
  func testCaptureBindingIncludesOperationRunnerProcessorOwnerPolicyAndGeometry() throws {
    let flag = CancellationFlag(), value = request(flag)
    let attempt = PairedAdmissionAttempt(deferReclamation: false, expected: value)
    try attempt.validate(value)
    let differentPolicy = ModelGenerationPolicy(schema: 1, vocabularySize: 32, eosTokenIDs: [0],
      suppressedTokenIDs: [1], controlTokenIDs: [0], textDecoding: nil,
      prefill: .init(chunking: "balanced_v1", tokenCeiling: 512))
    for changed in [changed(value, operation: UUID()), changed(value, runner: UUID()),
      changed(value, model: "another-model"), changed(value, processor: "another-processor"),
      changed(value, owner: .init(namespace: UUID(), entity: UUID(), route: .consultation)),
      changed(value, output: 17), changed(value, width: 1), changed(value, policy: differentPolicy)] {
      XCTAssertThrowsError(try attempt.validate(changed))
    }
  }
  func testSourceAuthorityRefusalNeverReleasesPeerOrRetries() async {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let admission = PairedContextAdmission { _ in
      state.add("source-revalidation-refused")
      throw BoomError.stale("Captured source/workspace/model epoch changed.")
    }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { _ -> Int in
        state.add("first-attempt"); throw binding
      }
      XCTFail("Stale source granted reclamation.")
    } catch { XCTAssertEqual(state.events, ["first-attempt", "source-revalidation-refused"]) }
  }
  func testSourceCallbackBudgetErrorCannotMasqueradeAsPermissionToTrimHistory() async {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let admission = PairedContextAdmission { _ in
      state.add("source-budget-denied"); throw BoomError.budget("Captured source validation refused.")
    }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { _ -> Int in
        state.add("prepared-attempt"); throw binding
      }
      XCTFail("Source authority denial was swallowed.")
    } catch let error as BoomError {
      if case .budget = error { XCTFail("Source authority denial became a history-fitting budget error.") }
      XCTAssertEqual(state.events, ["prepared-attempt", "source-budget-denied"])
    } catch { XCTFail("Unexpected authority error: \(error)") }
  }
  func testCancelledOrMemoryDeniedRequestNeverInvokesReclaimer() async {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let admission = PairedContextAdmission { _ in state.add("peer"); return true }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { _ -> Int in
        state.add("memory-watch-denied"); flag.cancel(); throw binding
      }
      XCTFail("Cancelled memory denial was retried.")
    } catch { XCTAssertEqual(state.events, ["memory-watch-denied"]) }
  }
  func testCancellationDuringPeerJoinPreventsRetry() async {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let admission = PairedContextAdmission { _ in state.add("peer"); flag.cancel(); return true }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { _ -> Int in
        state.add("attempt"); throw binding
      }
      XCTFail("Cancelled source was retried.")
    } catch { XCTAssertEqual(state.events, ["attempt", "peer"]) }
  }
  func testUnclassifiedBudgetFailureDoesNotAuthorizePeerRelease() async {
    let flag = CancellationFlag(), state = State()
    let admission = PairedContextAdmission { _ in state.add("peer"); return true }
    do {
      _ = try await PairedContextAdmission.perform(using: admission, flag: flag) { _ -> Int in
        state.add("unclassified-failure"); throw BoomError.budget("Unknown/model/watch failure.")
      }
      XCTFail("The unknown failure was swallowed.")
    } catch { XCTAssertEqual(state.events, ["unclassified-failure"]) }
  }
  func testReboundSourceValidatorSharesOneFitAndGenerationOpportunity() async throws {
    let flag = CancellationFlag(), binding = request(flag), state = State()
    let fit = PairedContextAdmission { _ in state.add("fit-peer"); return true }
    _ = try await PairedContextAdmission.perform(using: fit, flag: flag) { attempt in
      if attempt.deferReclamation { throw binding }; try attempt.validate(binding); return 1
    }
    let generation = PairedContextAdmission(sharingAttempt: fit) { _ in state.add("second-peer"); return true }
    _ = try await PairedContextAdmission.perform(using: generation, flag: flag) { attempt in
      XCTAssertFalse(attempt.deferReclamation); state.add("normal-generation-readmission"); return 1
    }
    XCTAssertEqual(state.events, ["fit-peer", "normal-generation-readmission"])
  }
  func testExplicitNilDiagnosticNeverDefersOrCarriesExpectedWarmAuthority() async throws {
    let value = try await PairedContextAdmission.perform(using: nil, flag: CancellationFlag()) { attempt in
      XCTAssertFalse(attempt.deferReclamation); XCTAssertNil(attempt.expected); return 7
    }
    XCTAssertEqual(value, 7)
  }
  func testCoordinatorCancellationTargetsOnlyTheDeclaredRunnerEpoch() async {
    let coordinator = GenerationCoordinator(), active = CancellationFlag(), a = UUID(), b = UUID()
    await coordinator.enter(flag: active, runnerEpoch: a)
    await coordinator.cancel(runnerEpoch: b)
    XCTAssertFalse(active.isCancelled)
    await coordinator.cancel(runnerEpoch: a)
    XCTAssertTrue(active.isCancelled)
    await coordinator.leave()
  }
  func testQueuedPeerCancellationDoesNotCancelTheActiveTarget() async {
    let coordinator = GenerationCoordinator(), target = CancellationFlag(), peer = CancellationFlag()
    let targetEpoch = UUID(), peerEpoch = UUID()
    await coordinator.enter(flag: target, runnerEpoch: targetEpoch)
    let waiting = Task {
      await coordinator.enter(flag: peer, runnerEpoch: peerEpoch)
      let cancelled = peer.isCancelled; await coordinator.leave(); return cancelled
    }
    for _ in 0..<1_000 {
      if await coordinator.queuedOperations == 1 { break }
      await Task.yield()
    }
    let queued = await coordinator.queuedOperations
    XCTAssertEqual(queued, 1)
    await coordinator.cancel(runnerEpoch: peerEpoch)
    XCTAssertFalse(target.isCancelled); XCTAssertTrue(peer.isCancelled)
    await coordinator.leave()
    let cancelled = await waiting.value
    XCTAssertTrue(cancelled)
  }
  func testPeerReclamationBarrierDoesNotPreemptAnUnrelatedBackgroundTarget() async {
    let coordinator = GenerationCoordinator(), target = CancellationFlag(), epoch = UUID()
    await coordinator.enter(flag: target, background: true, runnerEpoch: epoch)
    let barrier = Task {
      await coordinator.enter(background: true)
      await coordinator.leave()
    }
    for _ in 0..<1_000 {
      if await coordinator.queuedOperations == 1 { break }
      await Task.yield()
    }
    let queued = await coordinator.queuedOperations
    XCTAssertEqual(queued, 1); XCTAssertFalse(target.isCancelled)
    await coordinator.leave(); await barrier.value
    XCTAssertFalse(target.isCancelled)
  }

}
