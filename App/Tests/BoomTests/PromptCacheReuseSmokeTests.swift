import Foundation
import MLXLMCommon
import XCTest
@testable import Boom

final class PromptCacheReuseSmokeTests: XCTestCase {
  private func output(text: String = "Public text", tokens: [Int] = [7, 8],
    digest: String = String(repeating: "a", count: 64), promptTokens: Int = 4096,
    outputTokens: Int = 2, ended: Bool = false, stop: String = "output_limit",
    stopToken: Int? = nil, seconds: Double = 1) -> MLXGemmaRunner.Output {
    MLXGemmaRunner.Output(text: text, tokenIDs: tokens, promptDigest: digest,
      promptTokens: promptTokens, outputTokens: outputTokens, endedByEOS: ended,
      stopReason: stop, stopTokenID: stopToken, firstTokenSeconds: seconds,
      elapsedSeconds: seconds)
  }

  func testTimingDifferencesCannotReplaceFullOutputEquivalence() {
    XCTAssertTrue(PromptCacheReuseSmoke.exactOutputs([output()], [output(seconds: 9)]))
    let changes = [output(text: "Changed"), output(tokens: [7, 9]),
      output(digest: String(repeating: "b", count: 64)), output(promptTokens: 4095),
      output(outputTokens: 1), output(ended: true), output(stop: "eos"), output(stopToken: 1)]
    for changed in changes {
      XCTAssertFalse(PromptCacheReuseSmoke.exactOutputs([output()], [changed]))
    }
  }

  func testEverySeededLaneAndItsOrderMustMatch() {
    let lanes = [output(tokens: [7, 8]), output(tokens: [9, 10]), output(tokens: [11, 12])]
    XCTAssertTrue(PromptCacheReuseSmoke.exactOutputs(lanes, lanes))
    XCTAssertFalse(PromptCacheReuseSmoke.exactOutputs(lanes, Array(lanes.prefix(2))))
    XCTAssertFalse(PromptCacheReuseSmoke.exactOutputs(lanes, [lanes[0], lanes[2], lanes[1]]))
    for lane in lanes.indices {
      var changed = lanes; changed[lane] = output(tokens: [99, 100])
      XCTAssertFalse(PromptCacheReuseSmoke.exactOutputs(lanes, changed))
    }
  }

  func testCanonicalEquivalentDecodedTextIsNotAnExactOutputLedger() {
    let nfc = "\u{e9}", nfd = "e\u{301}"
    XCTAssertEqual(nfc, nfd)
    XCTAssertFalse(PromptCacheReuseSmoke.exactOutputs([output(text: nfc)], [output(text: nfd)]))
    XCTAssertEqual(PromptCacheReuseSmoke.replayDifferences([output(text: nfc)], [output(text: nfd)]),
      ["lane_0.text"])
  }

  func testAcceptedTextMustMatchPreparedTokensAcrossTheBPESeam() {
    let source = [1, 2], delivered = [3, 4]
    let stable = PromptCacheReuseSmoke.continuationAnalysis(sourcePrompt: source,
      delivered: delivered, current: [1, 2, 3, 4, 5])
    XCTAssertEqual(stable.commonLeadingTokens, 4)
    XCTAssertTrue(stable.currentContainsDeliveredTokenLedger)
    let retokenized = PromptCacheReuseSmoke.continuationAnalysis(sourcePrompt: source,
      delivered: delivered, current: [1, 99, 3, 4, 5])
    XCTAssertEqual(retokenized.commonLeadingTokens, 1)
    XCTAssertFalse(retokenized.currentContainsDeliveredTokenLedger)
    XCTAssertFalse(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3],
      sourcePrompt: source, delivered: delivered, stopToken: nil, current: [1, 99, 3, 4, 5]))
  }

  func testGeneratedEligibilityUsesActualPartialPrefixAndExcludesUndeliveredState() {
    let source = [1, 2], delivered = [3, 4]
    XCTAssertTrue(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3],
      sourcePrompt: source, delivered: delivered, stopToken: nil, current: [1, 2, 3, 4]))
    XCTAssertTrue(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3, 4],
      sourcePrompt: source, delivered: delivered, stopToken: nil, current: [1, 2, 3, 4]))
    XCTAssertTrue(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3, 4],
      sourcePrompt: source, delivered: delivered, stopToken: nil, current: [1, 2, 3, 99, 5]))
    XCTAssertFalse(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3, 4, 9],
      sourcePrompt: source, delivered: delivered, stopToken: nil, current: [1, 2, 3, 4, 9, 10]))
    XCTAssertTrue(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3, 4, 9],
      sourcePrompt: source, delivered: delivered, stopToken: 9, current: [1, 2, 3, 4, 9, 10]))
  }

  func testSiblingPaddingCannotBecomeSelectedCandidatePrefix() {
    let source = [1, 2]
    XCTAssertFalse(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 7],
      sourcePrompt: source, delivered: [3, 4], stopToken: nil, current: [1, 2, 3, 4, 5]))
    XCTAssertFalse(PromptCacheReuseSmoke.generatedPrefixEligible(retained: [1, 2, 3, 4, 0],
      sourcePrompt: source, delivered: [3, 4], stopToken: nil, current: [1, 2, 3, 4, 0, 5]))
  }

  func testReplayMismatchRemainsExplicitEvenWhenVisibleTextMatches() {
    XCTAssertEqual(PromptCacheReuseSmoke.replayDifferences([output()], [output(tokens: [7, 9])]),
      ["lane_0.token_ids"])
    XCTAssertEqual(PromptCacheReuseSmoke.replayDifferences([output()], [output(seconds: 9)]), [])
    XCTAssertEqual(PromptCacheReuseSmoke.replayDifferences([output()], []), ["lane_count"])
  }

  func testResidentPrefixUsesEveryLocalLayerAndLeavesOneInputToken() {
    let retained = Array(0..<4112), current = Array(0..<4096)
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(retained: retained,
      residentLocalStarts: [2048, 3000], current: current, window: 1024, localLayerCount: 2), 4095)
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(retained: retained,
      residentLocalStarts: [2048, 3072], current: current, window: 1024, localLayerCount: 2), 0,
      "One missing row in one local layer must refuse the hit.")
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(retained: retained,
      residentLocalStarts: [2048], current: current, window: 1024, localLayerCount: 2), 0,
      "Missing diagnostic layer coverage cannot stand in for full coverage.")
    var changed = current; changed[3500] = -1
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(retained: retained,
      residentLocalStarts: [2048, 2048], current: changed, window: 1024, localLayerCount: 2), 3500)
    changed[2048] = -2
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(retained: retained,
      residentLocalStarts: [2048, 2048], current: changed, window: 1024, localLayerCount: 2), 0)
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(retained: retained,
      residentLocalStarts: [0, 0], current: changed, window: 1024, localLayerCount: 2), 2048,
      "An earlier edit can hit when its complete local window is actually resident.")
  }

  func testNamespaceAndOlderResidentEntryDetermineExpectedHit() {
    let geometry = PromptCacheGeometry(promptTokens: 4096,
      prefill: PrefillParameters(stepSize: 512, chunking: .remainder))
    let scope = UUID(), other = UUID(), current = Array(0..<4096)
    func snapshot(_ starts: [Int], _ namespace: UUID) -> PromptPrefixCache.SnapshotObservation {
      .init(tokenIDs: current, origin: .singleDecode, batchWidth: 1, row: nil,
        forwardHistory: [], geometry: geometry, residentLocalStarts: starts, namespace: namespace,
        residentLocalCoverage: starts.enumerated().map { layer, start in
          .init(layer: layer, window: 1024, keep: 0,
            intervals: [.init(lowerBound: start, upperBound: current.count)])
        })
    }
    let snapshots = [snapshot([3072], scope), snapshot([0], other), snapshot([2048], scope)]
    XCTAssertEqual(PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: snapshots, current: current,
      namespace: scope, window: 1024, localLayerCount: 1), 4095)
    XCTAssertEqual(PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: Array(snapshots.prefix(2)),
      current: current, namespace: scope, window: 1024, localLayerCount: 1), 0,
      "The other namespace's otherwise eligible entry is private.")
    XCTAssertEqual(PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: snapshots, current: current,
      namespace: UUID(), window: 1024, localLayerCount: 1), 0)
  }

  func testClippedPrefixHistoryKeepsActualForwardEndAndBatchRow() {
    let geometry = PromptCacheGeometry(promptTokens: 8,
      prefill: PrefillParameters(stepSize: 4, chunking: .remainder))
    let prefill = PromptPrefixCache.ForwardSegment(origin: .prefill, startTokenCount: 0,
      endTokenCount: 8, batchWidth: 1, row: nil, promptTokenCount: 8, geometry: geometry)
    let decoded = PromptPrefixCache.ForwardSegment(origin: .batchDecode, startTokenCount: 8,
      endTokenCount: 12, batchWidth: 3, row: 1, promptTokenCount: nil, geometry: nil)
    let clippedPrefill = PromptPrefixCache.ForwardSegment(origin: .prefill, startTokenCount: 0,
      endTokenCount: 8, batchWidth: 1, row: nil, promptTokenCount: 8, geometry: geometry,
      evaluatedEndTokenCount: 8)
    let clippedDecode = PromptPrefixCache.ForwardSegment(origin: .batchDecode, startTokenCount: 8,
      endTokenCount: 11, batchWidth: 3, row: 1, promptTokenCount: nil, geometry: nil,
      evaluatedEndTokenCount: 12)
    XCTAssertTrue(PromptCacheReuseSmoke.historyMatchesPrefix([clippedPrefill, clippedDecode],
      retained: [prefill, decoded], tokenCount: 11))
    XCTAssertFalse(PromptCacheReuseSmoke.historyMatchesPrefix([prefill, decoded],
      retained: [prefill, decoded], tokenCount: 13), "History must reach the claimed cached boundary.")
    let wrongRow = PromptPrefixCache.ForwardSegment(origin: .batchDecode, startTokenCount: 8,
      endTokenCount: 11, batchWidth: 3, row: 2, promptTokenCount: nil, geometry: nil,
      evaluatedEndTokenCount: 12)
    XCTAssertFalse(PromptCacheReuseSmoke.historyMatchesPrefix([clippedPrefill, wrongRow],
      retained: [prefill, decoded], tokenCount: 11))
    let fabricatedEnd = PromptPrefixCache.ForwardSegment(origin: .batchDecode, startTokenCount: 8,
      endTokenCount: 11, batchWidth: 3, row: 1, promptTokenCount: nil, geometry: nil,
      evaluatedEndTokenCount: 11)
    XCTAssertFalse(PromptCacheReuseSmoke.historyMatchesPrefix([clippedPrefill, fabricatedEnd],
      retained: [prefill, decoded], tokenCount: 11))
  }

  func testAllMismatchesRemainRecordedAndExactnessIsNotReplacedBySemantics() {
    var controls = PromptCacheReuseSmoke.ControlResults()
    XCTAssertFalse(controls.qualified)
    controls.record("resident_prefix", category: .cacheSemantics, passed: true)
    controls.record("first_cold_seed", category: .exactOutput, passed: false, differences: ["lane_0.token_ids"])
    controls.record("history", category: .provenance, passed: false, differences: ["evaluated_end"])
    controls.record("remaining_seed", category: .exactOutput, passed: true)
    XCTAssertEqual(controls.checks.count, 4)
    XCTAssertEqual(controls.checks.filter { !$0.passed }.count, 2)
    XCTAssertTrue(controls.passed(.cacheSemantics))
    XCTAssertFalse(controls.passed(.exactOutput))
    XCTAssertFalse(controls.passed(.provenance))
    XCTAssertFalse(controls.qualified)
    XCTAssertEqual(controls.checks[1].differences, ["lane_0.token_ids"])
  }

  func testNextConsultationTurnRetainsCapturedRolesAndAssistantCompletion() throws {
    let reply = "<|turn>model\n<|channel>thought\n<channel|>"
    let source = ConsultationPlan(messages: [.init(role: "system", content: "Public instruction"),
      .init(role: "user", content: "Public scene")], rawPrompt: "<bos>captured turns\n" + reply)
    let next = try PromptCacheReuseSmoke.nextConsultationPlan(source,
      completion: "The keeper opened the gate.", question: "What next?")
    XCTAssertEqual(next.messages.map(\.role), ["system", "user", "assistant", "user"])
    XCTAssertEqual(next.messages[0].content, source.messages[0].content)
    XCTAssertEqual(next.messages[1].content, source.messages[1].content)
    XCTAssertEqual(next.messages[2].content, "The keeper opened the gate.")
    XCTAssertEqual(next.messages[3].content, "What next?")
    XCTAssertEqual(source.messages.count, 2)
    XCTAssertTrue(next.rawPrompt.hasPrefix("<bos>captured turns\n"))
    XCTAssertTrue(next.rawPrompt.hasSuffix(reply))
    XCTAssertThrowsError(try PromptCacheReuseSmoke.nextConsultationPlan(
      ConsultationPlan(messages: source.messages, rawPrompt: "unrecorded template"),
      completion: "Public", question: "Next?"))
  }
  func testReceiptUsesAdmittedExecutionOriginAndNeverInventsItFromOptionalMetrics() throws {
    var admitted = output()
    admitted.executionOrigin = GenerationExecutionOrigin(schema: 1,
      cacheAlgorithm: "resident-hybrid-prefix-v3", cachedPromptTokens: 3, cacheMissReason: nil)
    let receipt = try PromptCacheReuseSmoke.outputObject(admitted)
    let origin = try XCTUnwrap(receipt["execution_origin"] as? [String: Any])
    XCTAssertEqual(origin["cachedPromptTokens"] as? Int, 3)
    XCTAssertEqual(origin["cacheAlgorithm"] as? String, "resident-hybrid-prefix-v3")
    XCTAssertTrue(receipt["prefill_cache_metrics"] is NSNull,
      "Admitted origin is durable even without optional diagnostic metrics.")
    let geometry = PromptCacheGeometry(promptTokens: 4096,
      prefill: PrefillParameters(stepSize: 512, chunking: .remainder))
    var unknown = output()
    unknown.prefillCacheMetrics = .init(algorithm: "resident-hybrid-prefix-v3", cachedPromptTokens: 3,
      prefilledPromptTokens: 4093, fullPromptTokens: 4096, preservesChunkBoundaries: false,
      originalGeometry: geometry, suffixGeometry: geometry, missReason: nil, contextReclamation: nil,
      cachedOrigin: .batchDecode, cachedBatchWidth: 3, cachedRow: 2, cachedForwardHistory: [])
    XCTAssertTrue(try PromptCacheReuseSmoke.outputObject(unknown)["execution_origin"] is NSNull,
      "Unknown admitted origin stays unknown even when diagnostics report a hit.")
    admitted.executionOrigin = GenerationExecutionOrigin(schema: 1,
      cacheAlgorithm: "resident-hybrid-prefix-v3", cachedPromptTokens: 0, cacheMissReason: "unsupported_input")
    let cold = try XCTUnwrap(try PromptCacheReuseSmoke.outputObject(admitted)["execution_origin"] as? [String: Any])
    XCTAssertEqual(cold["cachedPromptTokens"] as? Int, 0)
    XCTAssertEqual(cold["cacheMissReason"] as? String, "unsupported_input")
  }

  func testIdenticalProcessedPrefixMayUseAnotherSourceRowWithoutClaimingItsLastSampledToken() {
    let source = [1, 2], retained = [1, 2, 3]
    for delivered in [[3, 4], [3, 9], [3, 8]] {
      XCTAssertTrue(PromptCacheReuseSmoke.selectedGeneratedPrefixMatches(retained: retained,
        cachedTokenCount: 3, sourcePrompt: source, delivered: delivered, stopToken: nil,
        current: source + delivered))
    }
    XCTAssertFalse(PromptCacheReuseSmoke.selectedGeneratedPrefixMatches(retained: retained,
      cachedTokenCount: 4, sourcePrompt: source, delivered: [3, 4], stopToken: nil,
      current: [1, 2, 3, 4, 5]), "A sampled but unprocessed final token has no resident KV.")
    XCTAssertFalse(PromptCacheReuseSmoke.selectedGeneratedPrefixMatches(retained: [1, 2, 7],
      cachedTokenCount: 3, sourcePrompt: source, delivered: [3, 4], stopToken: nil,
      current: [1, 2, 3, 4]))
    XCTAssertFalse(PromptCacheReuseSmoke.selectedGeneratedPrefixMatches(retained: retained,
      cachedTokenCount: 3, sourcePrompt: source, delivered: [7, 4], stopToken: nil,
      current: [1, 2, 3, 4]), "Current input alone cannot replace the captured authored ledger.")
    XCTAssertFalse(PromptCacheReuseSmoke.selectedGeneratedPrefixMatches(retained: retained,
      cachedTokenCount: 3, sourcePrompt: source, delivered: [3, 4], stopToken: nil,
      current: [1, 2, 7, 4]))
  }

  func testDeduplicatedRowKeepsItsActualParentHistoryAndRejectsFabricatedSelectedRowHistory() {
    let source = [1, 2], delivered = [3, 4], current = source + delivered
    let geometry = PromptCacheGeometry(promptTokens: 2,
      prefill: PrefillParameters(stepSize: 2, chunking: .remainder))
    let prefill = PromptPrefixCache.ForwardSegment(origin: .prefill, startTokenCount: 0,
      endTokenCount: 2, batchWidth: 1, row: nil, promptTokenCount: 2, geometry: geometry,
      evaluatedEndTokenCount: 2)
    func decode(row: Int, end: Int = 3) -> PromptPrefixCache.ForwardSegment {
      .init(origin: .batchDecode, startTokenCount: 2, endTokenCount: 3, batchWidth: 3,
        row: row, promptTokenCount: nil, geometry: nil, evaluatedEndTokenCount: end)
    }
    let snapshot = PromptPrefixCache.SnapshotObservation(tokenIDs: [1, 2, 3], origin: .batchDecode,
      batchWidth: 3, row: 2, forwardHistory: [prefill, decode(row: 2)], geometry: geometry,
      residentLocalStarts: [0], namespace: UUID())
    func metrics(row: Int = 2, historyRow: Int = 2, end: Int = 3) -> MLXGemmaRunner.PrefillCacheMetrics {
      .init(algorithm: "resident-hybrid-prefix-v3", cachedPromptTokens: 3,
        prefilledPromptTokens: 1, fullPromptTokens: 4, preservesChunkBoundaries: false,
        originalGeometry: geometry, suffixGeometry: geometry, missReason: nil,
        contextReclamation: nil, cachedOrigin: .batchDecode, cachedBatchWidth: 3,
        cachedRow: row, cachedForwardHistory: [prefill, decode(row: historyRow, end: end)])
    }
    func matches(_ metrics: MLXGemmaRunner.PrefillCacheMetrics) -> Bool {
      PromptCacheReuseSmoke.generatedParentMatchesSelected(snapshot, sourcePrompt: source,
        delivered: delivered, stopToken: nil, current: current, metrics: metrics)
    }
    XCTAssertTrue(matches(metrics()), "Authored row 0 may use an exact resident row 2 prefix.")
    XCTAssertFalse(matches(metrics(row: 0)), "Actual parent row must still match the recorded snapshot.")
    XCTAssertFalse(matches(metrics(historyRow: 0)), "Do not rewrite actual numerical history as authored selection.")
    XCTAssertFalse(matches(metrics(end: 4)), "Evaluated boundaries remain exact even for identical tokens.")
    XCTAssertFalse(PromptCacheReuseSmoke.exactOutputs([output(text: "Selected", tokens: [3, 4])],
      [output(text: "Sibling", tokens: [3, 4])]), "Prefix sharing cannot excuse changed authored text.")
  }

  func testNamespaceHitNeedsFreshResidentOriginalAfterEarlyEdit() {
    let namespace = UUID(), original = Array(0..<4096)
    let geometry = PromptCacheGeometry(promptTokens: 4096,
      prefill: PrefillParameters(stepSize: 512, chunking: .remainder))
    func snapshot(_ tokens: [Int]) -> PromptPrefixCache.SnapshotObservation {
      .init(tokenIDs: tokens, origin: .singleDecode, batchWidth: 1, row: nil,
        forwardHistory: [], geometry: geometry, residentLocalStarts: Array(repeating: 2048, count: 40),
        namespace: namespace, residentLocalCoverage: (0..<40).map { layer in
          .init(layer: layer, window: 1024, keep: 0,
            intervals: [.init(lowerBound: 2048, upperBound: tokens.count)])
        })
    }
    var early = Array(0..<4369); early[2] = -1
    let unavailable = PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: [snapshot(early)],
      current: original, namespace: namespace, window: 1024, localLayerCount: 40)
    XCTAssertEqual(unavailable, 0)
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: unavailable, cached: [0], requireHit: false), [])
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: unavailable, cached: [0], requireHit: true),
      ["no_eligible_resident_prefix_setup", "required_hit_missing"])
    let anchored = PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: [snapshot(Array(0..<4112))],
      current: original, namespace: namespace, window: 1024, localLayerCount: 40)
    XCTAssertEqual(anchored, 4095)
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: anchored, cached: [4095], requireHit: true), [])
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: anchored, cached: [4094], requireHit: true),
      ["resident_lcp"], "A hit below the longest valid resident prefix still fails.")
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: anchored, cached: [0], requireHit: true),
      ["required_hit_missing", "resident_lcp"], "An immediately resident fixture keeps ownership hits mandatory.")
  }
  func testNamespaceReturnCannotAssumePagesSurviveTheOtherNamespacesColdPrefill() {
    let namespace = UUID(), privateNamespace = UUID(), original = Array(0..<4096)
    let geometry = PromptCacheGeometry(promptTokens: 4096,
      prefill: PrefillParameters(stepSize: 512, chunking: .remainder))
    let privateSnapshot = PromptPrefixCache.SnapshotObservation(tokenIDs: Array(0..<4112), origin: .singleDecode,
      batchWidth: 1, row: nil, forwardHistory: [], geometry: geometry,
      residentLocalStarts: Array(repeating: 2048, count: 40), namespace: privateNamespace)
    let expected = PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: [privateSnapshot], current: original,
      namespace: namespace, window: 1024, localLayerCount: 40)
    XCTAssertEqual(expected, 0)
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: expected, cached: [0], requireHit: false), [])
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: expected, cached: [4095], requireHit: false),
      ["resident_lcp"], "The other namespace's identical tokens cannot authorize reuse.")
    XCTAssertEqual(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: nil, cached: [0], requireHit: false),
      ["resident_snapshot_missing"])
    XCTAssertTrue(PromptCacheReuseSmoke.snapshotCacheDifferences(expected: 4095, cached: [nil], requireHit: true)
      .contains("cache_metrics_missing"))
  }

  private func coverageSnapshot(_ tokens: [Int], namespace: UUID = UUID(),
    coverage: [PromptPrefixCache.LocalCoverage]?) -> PromptPrefixCache.SnapshotObservation {
    .init(tokenIDs: tokens, origin: .singleDecode, batchWidth: 1, row: nil,
      forwardHistory: [], geometry: PromptCacheGeometry(promptTokens: tokens.count,
        prefill: PrefillParameters(stepSize: 2, chunking: .remainder)), namespace: namespace,
      residentLocalCoverage: coverage)
  }
  func testIntervalOracleFindsGapFallbackAndHeterogeneousLayerIntersection() {
    let tokens = Array(0..<17), current = Array(0..<8) + [-1]
    let first = PromptPrefixCache.LocalCoverage(layer: 0, window: 4, keep: 0,
      intervals: [.init(lowerBound: 0, upperBound: 5), .init(lowerBound: 12, upperBound: 17)])
    let second = PromptPrefixCache.LocalCoverage(layer: 1, window: 2, keep: 0,
      intervals: [.init(lowerBound: 0, upperBound: 4), .init(lowerBound: 14, upperBound: 17)])
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(
      snapshot: coverageSnapshot(tokens, coverage: [first]), current: current, localLayerCount: 1), 5)
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(
      snapshot: coverageSnapshot(tokens, coverage: [first, second]), current: current, localLayerCount: 2), 4)
  }
  func testIntervalOracleHonorsPinnedPrefixAndMissingPin() {
    let tokens = Array(0..<10), current = Array(0..<9) + [-1]
    let local = PromptPrefixCache.LocalCoverage(layer: 2, window: 4, keep: 1,
      intervals: [.init(lowerBound: 0, upperBound: 1), .init(lowerBound: 7, upperBound: 10)])
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(snapshot: coverageSnapshot(tokens, coverage: [local]),
      current: current, localLayerCount: 1), 1)
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(snapshot: coverageSnapshot(tokens, coverage: [local]),
      current: tokens + [-1], localLayerCount: 1), 10)
    let missingPin = PromptPrefixCache.LocalCoverage(layer: 2, window: 4, keep: 1,
      intervals: [.init(lowerBound: 7, upperBound: 10)])
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(
      snapshot: coverageSnapshot(tokens, coverage: [missingPin]), current: tokens + [-1], localLayerCount: 1), 0)
  }
  func testStartsOnlyHistoricalSnapshotCannotProveDisjointCoverage() {
    let tokens = Array(0..<8), current = tokens + [-1]
    var historical = coverageSnapshot(tokens, coverage: nil)
    historical.residentLocalStarts = [0]
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(snapshot: historical,
      current: current, localLayerCount: 1), 0, "Starts-only receipts are explicitly limited historical evidence.")
    let pastLedger = PromptPrefixCache.LocalCoverage(layer: 0, window: 4, keep: 0,
      intervals: [.init(lowerBound: 0, upperBound: 9)])
    XCTAssertEqual(PromptCacheReuseSmoke.residentPrefixCount(snapshot: coverageSnapshot(tokens, coverage: [pastLedger]),
      current: current, localLayerCount: 1), 0, "Future/unobserved rows are outside the authoritative token ledger.")
  }
  func testIntervalOracleChoosesShorterLexicalParentWithGreaterValidCount() {
    let scope = UUID(), current = Array(0..<9) + [-1]
    let parent = coverageSnapshot(Array(0..<8), namespace: scope, coverage: [
      .init(layer: 0, window: 4, keep: 0, intervals: [.init(lowerBound: 0, upperBound: 8)])])
    let child = coverageSnapshot(Array(0..<17), namespace: scope, coverage: [
      .init(layer: 0, window: 4, keep: 0,
        intervals: [.init(lowerBound: 0, upperBound: 5), .init(lowerBound: 12, upperBound: 17)])])
    XCTAssertEqual(PromptCacheReuseSmoke.expectedResidentPrefix(snapshots: [child, parent], current: current,
      namespace: scope, window: 4, localLayerCount: 1), 8)
  }
}
