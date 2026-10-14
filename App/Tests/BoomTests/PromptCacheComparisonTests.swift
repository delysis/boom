import MLXLMCommon
import XCTest
@testable import Boom

final class PromptCacheComparisonTests: XCTestCase {
  private typealias Forward = PromptCacheReuseSmoke.ComparisonForward
  private typealias Evidence = PromptCacheReuseSmoke.OutputHistoryEvidence
  private func evidence(_ forwards: [Forward], prompt: Int = 8, width: Int = 1,
    binding: String = String(repeating: "a", count: 64), blockers: [String] = []) -> Evidence {
    .init(requestBinding: binding, promptTokens: prompt, decodeWidth: width, decodeRow: 0,
      preparePath: width == 1 ? "token-iterator-constructor" : "shared-prefill-model-prepare",
      forwards: forwards, blockers: blockers)
  }
  private func prefill(_ start: Int, _ end: Int, evaluated: Int? = nil) -> Forward {
    .init(origin: .prefill, start: start, end: end, evaluatedEnd: evaluated ?? end, width: 1, row: nil)
  }

  func testExactOriginalPartitionsAreAdmittedWithoutNormalizingAdjacentCalls() {
    let a = evidence([prefill(0, 4), prefill(4, 7), prefill(7, 8)])
    let exact = PromptCacheReuseSmoke.classifyOutputHistories([a], [a])
    XCTAssertEqual(exact.relation, .sameObservedPartitions)
    XCTAssertTrue(exact.requiresExactOutput)
    let combined = evidence([prefill(0, 4), prefill(4, 8)])
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([a], [combined]).relation,
      .differentObservedPartitions, "Seven plus final one is not an eight-token original forward.")
  }

  func testInteriorCropPreservesOriginalEvaluatedExtentAndCannotInventItsMissingInputs() {
    let retained = evidence([prefill(0, 4), prefill(4, 7, evaluated: 8)], prompt: 7)
    let cold = evidence([prefill(0, 4), prefill(4, 7, evaluated: 7)], prompt: 7)
    let changed = PromptCacheReuseSmoke.classifyOutputHistories([retained], [cold])
    XCTAssertEqual(changed.relation, .differentObservedPartitions)
    XCTAssertTrue(changed.differences.contains(where: { $0.contains("beyond_prefix_unrecorded") }))
    let sameShape = PromptCacheReuseSmoke.classifyOutputHistories([retained], [retained])
    XCTAssertEqual(sameShape.relation, .unknown,
      "Equal scalar descriptors cannot recover the original inputs beyond the admitted prefix.")
    XCTAssertFalse(sameShape.requiresExactOutput)
  }

  func testBatchWidthAndNumericalParentRowStayDistinctFromAuthoredTokenIdentity() {
    func history(width: Int, row: Int?) -> Evidence {
      evidence([prefill(0, 4)] + (4..<8).map { position in
        .init(origin: width > 1 ? .batchDecode : .singleDecode, start: position, end: position + 1,
          evaluatedEnd: position + 1, width: width, row: row)
      })
    }
    let row0 = history(width: 3, row: 0), row2 = history(width: 3, row: 2)
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([row0], [row2]).relation,
      .differentObservedPartitions)
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([row0], [history(width: 1, row: nil)]).relation,
      .differentObservedPartitions)
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([row2], [row2]).relation, .unknown,
      "The complete original batch operand matrix is not present in selected-row metadata.")
  }

  func testMissingEvaluatedEndAndHistoryHoleRemainUnknown() {
    let missing = evidence([.init(origin: .prefill, start: 0, end: 8,
      evaluatedEnd: nil, width: 1, row: nil)])
    let hole = evidence([prefill(0, 4), prefill(5, 8)])
    for value in [missing, hole, evidence([], blockers: ["execution_origin_missing_or_invalid"])] {
      let result = PromptCacheReuseSmoke.classifyOutputHistories([value], [value])
      XCTAssertEqual(result.relation, .unknown)
      XCTAssertFalse(result.requiredComparisonAdmitted)
    }
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([], []).relation, .unknown)
    let complete = evidence([prefill(0, 8)])
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([hole], [complete]).relation, .unknown,
      "A different shape cannot hide a missing interval.")
  }

  func testLiveAdapterUsesShiftedCallbacksAndRequiresExplicitOrigin() {
    func output(cached: Int = 0, originPresent: Bool = true,
      algorithm: String = PromptPrefixCache.activeAlgorithm) -> MLXGemmaRunner.Output {
      var value = MLXGemmaRunner.Output(text: "Public", tokenIDs: [10], promptDigest: String(repeating: "c", count: 64),
        promptTokens: 8, outputTokens: 1, endedByEOS: false, stopReason: "output_limit", stopTokenID: nil,
        firstTokenSeconds: 1, elapsedSeconds: 1)
      value.setupMetrics = .init(path: "token-iterator-constructor", returnedSeconds: 0,
        threadQoSBefore: 0, threadQoSAfter: 0, firstDeliveryThreadQoS: 0, tokenShape: [8 - cached], maskShape: nil)
      if originPresent {
        value.executionOrigin = .init(schema: 1, cacheAlgorithm: algorithm,
          cachedPromptTokens: cached, cacheMissReason: cached == 0 ? "owner_disabled" : nil)
      }
      if cached > 0 {
        let geometry = PromptCacheGeometry(promptTokens: 8, prefill: PrefillParameters(stepSize: 4, chunking: .remainder))
        let suffix = PromptCacheGeometry(promptTokens: 8 - cached, prefill: PrefillParameters(stepSize: 4, chunking: .remainder))
        value.prefillCacheMetrics = .init(algorithm: algorithm, cachedPromptTokens: cached,
          prefilledPromptTokens: 8 - cached, fullPromptTokens: 8, preservesChunkBoundaries: true,
          originalGeometry: geometry, suffixGeometry: suffix, missReason: nil, contextReclamation: nil,
          cachedOrigin: .prefill, cachedBatchWidth: 1, cachedRow: nil,
          cachedForwardHistory: [.init(origin: .prefill, startTokenCount: 0, endTokenCount: cached,
            batchWidth: 1, row: nil, promptTokenCount: 8, geometry: geometry, evaluatedEndTokenCount: cached)])
      }
      return value
    }
    func history(_ value: MLXGemmaRunner.Output, _ callbacks: [Int]) -> [Evidence] {
      PromptCacheReuseSmoke.comparisonHistories(outputs: [value], callbackPositions: callbacks,
        batch: nil, requestBinding: String(repeating: "a", count: 64))
    }
    let cold = history(output(), [4, 7, 8])
    let warm = history(output(cached: 4), [7, 8])
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories(cold, warm).relation, .sameObservedPartitions)
    XCTAssertEqual(warm[0].forwards, cold[0].forwards)
    let obsolete = history(output(algorithm: PromptPrefixCache.algorithm), [4, 7, 8])
    XCTAssertTrue(obsolete[0].blockers.contains("cache_algorithm_not_current"))
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories(obsolete, cold).relation, .unknown)
    let missingOrigin = history(output(originPresent: false), [4, 7, 8])
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories(missingOrigin, cold).relation, .unknown)
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories(history(output(cached: 4), [3, 7, 8]), cold).relation, .unknown)
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories(history(output(cached: 4), [7]), cold).relation, .unknown)
  }

  func testPolicySeedInputAndLaneBindingsCannotBecomeNumericalHistoryObservations() {
    let a = evidence([prefill(0, 8)])
    let wrongBinding = evidence([prefill(0, 8)], binding: String(repeating: "b", count: 64))
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([a], [wrongBinding]).relation,
      .incompatibleRequest)
    let wrongLane = Evidence(requestBinding: a.requestBinding, promptTokens: 8,
      decodeWidth: 1, decodeRow: 1, preparePath: a.preparePath, forwards: a.forwards, blockers: [])
    XCTAssertEqual(PromptCacheReuseSmoke.classifyOutputHistories([a], [wrongLane]).relation,
      .incompatibleRequest)
  }

  func testCrossHistoryEqualityAndMismatchBothRemainUnqualifiedAndVisible() {
    for equal in [true, false] {
      var controls = PromptCacheReuseSmoke.ControlResults()
      controls.record("input", category: .provenance, passed: true)
      controls.record("resident_prefix", category: .cacheSemantics, passed: true)
      controls.record("cold_reconstruction", category: .exactOutput, passed: true)
      controls.record("cross_history", category: .crossHistoryObservation, passed: equal,
        differences: equal ? [] : ["lane_0.token_ids", "lane_0.text"])
      XCTAssertTrue(controls.requiredControlsPassed)
      XCTAssertFalse(controls.qualified, "Text equality cannot qualify independent native restoration.")
      XCTAssertEqual(controls.checks.last?.passed, equal)
      XCTAssertEqual(controls.checks.last?.differences, equal ? [] : ["lane_0.token_ids", "lane_0.text"])
    }
  }

  func testSameHistoryExactMismatchAndUnknownEvidenceBlockRequiredControls() {
    for category in [PromptCacheReuseSmoke.ControlResults.Category.exactOutput, .historyClassification] {
      var controls = PromptCacheReuseSmoke.ControlResults()
      controls.record("semantics", category: .cacheSemantics, passed: true)
      controls.record("required", category: category, passed: false, differences: ["preserved_failure"])
      XCTAssertFalse(controls.requiredControlsPassed)
      XCTAssertFalse(controls.qualified)
      XCTAssertEqual(controls.checks.last?.differences, ["preserved_failure"])
    }
  }

  func testGeneratedCrossHistoryEqualityAndDifferenceStayOpenInTheSummary() {
    let full = evidence([prefill(0, 4), prefill(4, 8)])
    let split = evidence([prefill(0, 4), prefill(4, 7), prefill(7, 8)])
    let same = PromptCacheReuseSmoke.classifyOutputHistories([full], [full])
    let changed = PromptCacheReuseSmoke.classifyOutputHistories([full], [split])
    let exact = PromptCacheReuseSmoke.OutputComparisonOutcome(history: same, exactObserved: true)
    for equal in [true, false] {
      let observed = PromptCacheReuseSmoke.OutputComparisonOutcome(history: changed, exactObserved: equal)
      XCTAssertEqual(observed.exactObserved, equal)
      XCTAssertTrue(observed.requiredComparisonPassed)
      XCTAssertFalse(observed.numericalComparisonQualified)
      let status = PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: true,
        inputExact: true, comparisons: [exact, observed, exact])
      XCTAssertEqual(status, .qualificationOpen)
    }
  }

  func testGeneratedSameHistoryMismatchRemainsARequiredFailure() {
    let value = evidence([prefill(0, 8)])
    let history = PromptCacheReuseSmoke.classifyOutputHistories([value], [value])
    let exact = PromptCacheReuseSmoke.OutputComparisonOutcome(history: history, exactObserved: true)
    let mismatch = PromptCacheReuseSmoke.OutputComparisonOutcome(history: history, exactObserved: false)
    XCTAssertEqual(PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: true,
      inputExact: true, comparisons: [exact, mismatch, exact]), .failed)
    XCTAssertEqual(PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: true,
      inputExact: true, comparisons: [exact, exact, exact]), .passed)
  }

  func testGeneratedMissingUnknownAndIncompatibleComparisonCannotBecomeOpen() {
    let value = evidence([prefill(0, 8)])
    let exact = PromptCacheReuseSmoke.OutputComparisonOutcome(
      history: PromptCacheReuseSmoke.classifyOutputHistories([value], [value]), exactObserved: true)
    for bad in [PromptCacheReuseSmoke.classifyOutputHistories([], []),
      PromptCacheReuseSmoke.classifyOutputHistories([value], [evidence([prefill(0, 8)],
        binding: String(repeating: "b", count: 64))])] {
      let unresolved = PromptCacheReuseSmoke.OutputComparisonOutcome(history: bad, exactObserved: true)
      XCTAssertEqual(PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: true,
        inputExact: true, comparisons: [exact, unresolved, exact]), .failed)
    }
    XCTAssertEqual(PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: true,
      inputExact: true, comparisons: [exact, nil, exact]), .failed)
    XCTAssertEqual(PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: true,
      inputExact: true, comparisons: [exact, exact]), .failed)
  }

  func testGeneratedSemanticsAndInputFailuresAreNotNumericalObservations() {
    let a = evidence([prefill(0, 8)]), b = evidence([prefill(0, 7), prefill(7, 8)])
    let observation = PromptCacheReuseSmoke.OutputComparisonOutcome(
      history: PromptCacheReuseSmoke.classifyOutputHistories([a], [b]), exactObserved: false)
    for flags in [(false, true), (true, false)] {
      XCTAssertEqual(PromptCacheReuseSmoke.generatedControlDisposition(semanticPassed: flags.0,
        inputExact: flags.1, comparisons: [observation, observation, observation]), .failed)
    }
  }
}
