import BoomCore
import Foundation
import MLXLMCommon
import XCTest
@testable import Boom

final class JoinedPrefixCancellationSmokeTests: XCTestCase {
  private var valid: [String] {
    ["--mlx-smoke", "--joined-prefix-cancellation-smoke", "--pack", "/public/writing",
      "--joined-cancellation-fixture", "/public/frozen.json", "--evidence", "/public/new", "--seed", "42"]
  }
  func testModeAndDedicatedFixtureCannotShadowOtherWorkloads() throws {
    try MLXNativeSmoke.validateJoinedCancellationArguments(valid)
    XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(["--joined-cancellation-fixture", "/public/frozen.json"]))
    for option in ["--prompt-cache-smoke", "--neural-prefix-parity-smoke", "--consultation-fixture",
      "--consultation-warmup", "--cache-consultation-fixture", "--memory-budget", "--batch", "--preempt",
      "--writing-fixtures", "--base", "--unknown"] {
      XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(valid + [option]), option)
    }
    XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(valid + ["--joined-prefix-cancellation-smoke"]))
  }
  func testRequiredPathsAndSeedRejectDuplicatesMissingValuesAndRelativeInputs() throws {
    for name in ["--pack", "--joined-cancellation-fixture", "--evidence"] {
      let index = try XCTUnwrap(valid.firstIndex(of: name))
      var missing = valid; missing.remove(at: index + 1)
      XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(missing))
      var relative = valid; relative[index + 1] = "public/relative"
      XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(relative))
      var absent = valid; absent.removeSubrange(index...(index + 1))
      XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(absent))
      XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(valid + [name, "/public/other"]))
    }
    var wrongSeed = valid; wrongSeed[wrongSeed.count - 1] = "43"
    XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(wrongSeed))
    XCTAssertThrowsError(try MLXNativeSmoke.validateJoinedCancellationArguments(valid + ["--seed", "42"]))
  }
  func testOnlyTheActualFirstNonterminal512CallbackCanQualifyConstructorCancellation() {
    for pair in [(512, 4096), (511, 4096), (4096, 4096), (512, 4104)] {
      let flag = CancellationFlag(), probe = JoinedPrefixCancellationSmoke.Probe()
      probe.prefilling(.init(operationID: flag.operationID, processedPositions: pair.0, totalPositions: pair.1),
        cancelConstructor: true, flag: flag)
      XCTAssertTrue(flag.isCancelled, "Unexpected first callbacks must stop the bounded owned attempt.")
      XCTAssertEqual(probe.observation().exactConstructorTriggerObserved, pair.0 == 512 && pair.1 == 4096)
      XCTAssertEqual(probe.observation().unexpectedTrigger, !(pair.0 == 512 && pair.1 == 4096))
      probe.prefilling(.init(operationID: flag.operationID, processedPositions: 512, totalPositions: 4096),
        cancelConstructor: true, flag: flag)
      XCTAssertTrue(probe.observation().unexpectedTrigger, "A later callback cannot retarget the case.")
    }
  }
  private func binding() -> JoinedKVRetentionBinding {
    .init(owner: .init(namespace: UUID(), entity: UUID(), route: .writing), workspaceEpoch: UUID(),
      runnerEpoch: UUID(), modelIdentity: "public-model", processorIdentity: "public-processor",
      policyDigest: String(repeating: "a", count: 64), operationID: UUID())
  }
  private func snapshot(_ b: JoinedKVRetentionBinding, submitted: Int = 512,
    intervals: [PromptPrefixCache.ResidentInterval] = [.init(lowerBound: 0, upperBound: 512)])
    -> PromptPrefixCache.SnapshotObservation {
    let geometry = PromptCacheGeometry(promptTokens: 4096, prefill: .init(stepSize: 512, chunking: .remainder))
    return .init(tokenIDs: Array(0..<512), origin: .prefill, batchWidth: 1, row: nil,
      forwardHistory: [.init(origin: .prefill, startTokenCount: 0, endTokenCount: 512,
        batchWidth: 1, row: nil, promptTokenCount: 4096, geometry: geometry, evaluatedEndTokenCount: 512)],
      geometry: geometry, namespace: b.owner.namespace,
      residentLocalCoverage: [.init(layer: 0, window: 1024, keep: 0, intervals: intervals)],
      joinedRetentionProvenance: .init(binding: b, termination: .constructorCancelled,
        promptTokenCount: 4096, representedTokenCount: 512, lastCompleteCohortTokenCount: 512,
        lastSubmittedCohortTokenCount: submitted, acknowledgedGeneratedTokenCount: 0, representedGeneratedTokenCount: 0))
  }
  func testCompleteGraphMetadataDoesNotReplaceActualSubmissionOrCoverage() {
    let b = binding(), ids = Array(0..<4096)
    func differences(_ value: PromptPrefixCache.SnapshotObservation) -> [String] {
      JoinedPrefixCancellationSmoke.retainedDifferences(value, binding: b, sourceIDs: ids, localLayers: [0], window: 1024)
    }
    XCTAssertTrue(differences(snapshot(b)).isEmpty)
    XCTAssertTrue(differences(snapshot(b, submitted: 0)).contains("joined_submitted_cohort_provenance"))
    XCTAssertTrue(differences(snapshot(b, intervals: [.init(lowerBound: 0, upperBound: 255),
      .init(lowerBound: 256, upperBound: 512)])).contains("owning_local_layer_interval_coverage"))
    var wrongOwner = snapshot(b); wrongOwner.namespace = UUID()
    XCTAssertTrue(differences(wrongOwner).contains("cancelled_source_integer_prefix_or_namespace"))
    var missing = snapshot(b); missing.joinedRetentionProvenance = nil
    XCTAssertTrue(differences(missing).contains("joined_retention_provenance_missing"))
  }
  func testRealGrantRevocationCannotBeReapprovedAndStaleCallbacksStillFail() {
    let b = binding(), flag = CancellationFlag(), probe = JoinedPrefixCancellationSmoke.Probe()
    let authorization = JoinedKVRetentionAuthorization(binding: b)
    probe.prefilling(.init(operationID: flag.operationID, processedPositions: 512, totalPositions: 4096),
      cancelConstructor: true, flag: flag)
    XCTAssertFalse(probe.authorize(authorization, binding: b, deny: true))
    XCTAssertFalse(authorization.approve(binding: b))
    XCTAssertTrue(JoinedPrefixCancellationSmoke.constructorDifferences(probe.observation(),
      cancellationError: true, flagCancelled: true, denied: true).isEmpty)
    probe.display()
    XCTAssertTrue(JoinedPrefixCancellationSmoke.constructorDifferences(probe.observation(),
      cancellationError: true, flagCancelled: true, denied: true).contains("stale_success_callback"))
  }
  func testRevokedNamespaceCannotPublishButDoesNotInvalidateAnExistingOtherNamespace() {
    let allowed = binding(), denied = binding()
    XCTAssertTrue(JoinedPrefixCancellationSmoke.revokedNamespaceDifferences([snapshot(allowed)],
      owner: denied.owner).isEmpty)
    XCTAssertEqual(JoinedPrefixCancellationSmoke.revokedNamespaceDifferences([snapshot(allowed), snapshot(denied)],
      owner: denied.owner), ["revoked_source_published"])
  }
}
