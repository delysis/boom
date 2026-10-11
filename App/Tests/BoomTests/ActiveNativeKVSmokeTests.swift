import BoomCore
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

/// Argument, scalar-bound, independent coverage and tiny CPU value checks only.
/// These checks do not qualify a real model, packaged application or replay.
final class ActiveNativeKVSmokeTests: XCTestCase {
  private var valid: [String] {
    ["--mlx-smoke", "--active-native-kv-smoke", "--pack", "/public/writing",
      "--consultation-pack", "/public/chat", "--active-native-fixture", "/public/fixture.json",
      "--active-native-case", "writing_width3", "--active-native-phase", "timing",
      "--evidence", "/public/new", "--seed", "42"]
  }
  func testExplicitCasePhaseRejectsMixingAndUnknownOrDuplicateArguments() throws {
    try MLXNativeSmoke.validateActiveNativeArguments(valid)
    for flag in ["--neural-prefix-parity-smoke", "--prompt-cache-smoke", "--joined-prefix-cancellation-smoke",
      "--consultation-fixture", "--batch", "--memory-budget", "--unknown", "--active-native-kv-smoke"] {
      XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(valid + [flag]), flag)
    }
    XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(valid + ["stray"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(["--active-native-fixture", "/public/fixture.json"]))
    for (key, replacement) in [("--active-native-case", "width2"), ("--active-native-phase", "both"), ("--seed", "43")] {
      var value = valid; value[try XCTUnwrap(value.firstIndex(of: key)) + 1] = replacement
      XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(value))
    }
  }
  func testNumericHistoryIsOneExplicitAbsoluteSHAInputAndNeverATimingInput() throws {
    let history = ["--active-native-history", "/public/timing.json", "--active-native-history-sha256", String(repeating: "a", count: 64)]
    XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(valid + history))
    var numeric = valid; numeric[try XCTUnwrap(numeric.firstIndex(of: "--active-native-phase")) + 1] = "numeric"
    XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(numeric))
    try MLXNativeSmoke.validateActiveNativeArguments(numeric + history)
    for index in [1,3] {
      var wrong = history; wrong[index] = index == 1 ? "relative" : "unbound"
      XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(numeric + wrong))
    }
    XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(numeric + history + history))
  }
  func testEveryRequiredPathRejectsMissingRelativeAndRepeatedValues() throws {
    for key in ["--pack", "--consultation-pack", "--active-native-fixture", "--evidence"] {
      let index = try XCTUnwrap(valid.firstIndex(of: key))
      var missing = valid; missing.remove(at: index + 1)
      XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(missing))
      var relative = valid; relative[index + 1] = "public/relative"
      XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(relative))
      XCTAssertThrowsError(try MLXNativeSmoke.validateActiveNativeArguments(valid + [key, "/public/other"]))
    }
  }
  func testActualFirstDeliveredMarkerUsesOuterClockAndNeverDecodedCheckpointTime() {
    let clock = ContinuousClock(), probe = ActiveNativeKVSmoke.ClockProbe(started: clock.now)
    probe.checkpoint()
    XCTAssertTrue(probe.snapshot().first.isEmpty)
    probe.recordFirst(row: 0, tokenID: 10, seconds: 1.25)
    probe.recordFirst(row: 0, tokenID: 11, seconds: 2.75)
    probe.recordFirst(row: 2, tokenID: 12, seconds: 1.5)
    XCTAssertEqual(probe.snapshot().first[0], 1.25)
    XCTAssertEqual(probe.snapshot().tokens[0], 10)
    XCTAssertEqual(probe.snapshot().first[2], 1.5)
    XCTAssertEqual(probe.snapshot().checkpoints, 1)
  }
  func testCheckedAllocationScalarsRefuseOverflowAndMatrixRowsStayExplicit() throws {
    XCTAssertEqual(try ActiveNativeKVNumericalObserver.checkedScale(128, by: 32), 4096)
    XCTAssertThrowsError(try ActiveNativeKVNumericalObserver.checkedScale(UInt64.max, by: 2))
    XCTAssertEqual(try ActiveNativeKVNumericalObserver.validateMatrix([[1],[2],[3]], width: 3, vocabulary: 8), [1,2,3])
    XCTAssertThrowsError(try ActiveNativeKVNumericalObserver.validateMatrix([[1],[2,3],[4]], width: 3, vocabulary: 8))
    XCTAssertThrowsError(try ActiveNativeKVNumericalObserver.validateMatrix([[1],[2],[3]], width: 1, vocabulary: 8))
    XCTAssertThrowsError(try ActiveNativeKVNumericalObserver.validateMatrix([[8]], width: 1, vocabulary: 8))
    XCTAssertThrowsError(try ActiveNativeKVNumericalObserver.validateMatrix([[-1]], width: 1, vocabulary: 8))
  }
  func testOutputReservationAcceptsMeaningfulEarlyEOSAndRejectsMissingOrWrongStoppingShape() {
    func gate(_ count: Int? = 16, ids: Int? = 16, text: Bool? = true, reason: String? = "eos",
      ended: Bool? = true, stop: Int? = 2, reservation: Int = 256, minimum: Int = 16) -> Bool {
      ActiveNativeKVSmoke.stoppingGate(reservation: reservation, minimum: minimum,
        outputTokenCount: count, tokenIDCount: ids, hasText: text, reason: reason,
        endedByEOS: ended, stopTokenID: stop, eosTokenIDs: [2], controlTokenIDs: [2,3])
    }
    XCTAssertTrue(gate()) // Reserve256, accept16 actual tokens plus a valid natural EOS.
    XCTAssertTrue(gate(reason: "model_control", stop: 3))
    XCTAssertTrue(gate(256, ids: 256, reason: "output_limit", ended: false, stop: nil))
    XCTAssertTrue(gate(1, ids: 1, reservation: 16, minimum: 1)) // Bounded selected successor.
    XCTAssertFalse(gate(15, ids: 15))
    XCTAssertFalse(gate(reason: "output_limit", ended: false, stop: nil))
    XCTAssertFalse(gate(257, ids: 257))
    XCTAssertFalse(gate(ids: 15))
    XCTAssertFalse(gate(nil)); XCTAssertFalse(gate(ids: nil)); XCTAssertFalse(gate(text: nil))
    XCTAssertFalse(gate(reason: nil)); XCTAssertFalse(gate(ended: nil)); XCTAssertFalse(gate(stop: nil))
    XCTAssertFalse(gate(reason: "cancelled")); XCTAssertFalse(gate(reason: "eos", stop: 3))
    XCTAssertFalse(gate(reason: "model_control", stop: 2)); XCTAssertFalse(gate(text: false))
  }
  func testSubmittedBoundaryNeverPromotesTerminalGraphConstruction() {
    XCTAssertEqual(ActiveNativeKVNumericalObserver.submittedBoundary(processed: 512, total: 4096, cached: 128), 640)
    XCTAssertNil(ActiveNativeKVNumericalObserver.submittedBoundary(processed: 4096, total: 4096, cached: 0))
    XCTAssertNil(ActiveNativeKVNumericalObserver.submittedBoundary(processed: 0, total: 4096, cached: 0))
    XCTAssertNil(ActiveNativeKVNumericalObserver.submittedBoundary(processed: 1, total: 2, cached: Int.max))
  }
  private func snapshot(_ namespace: UUID, ids: [Int], row: Int, ranges: [Range<Int>], submitted: Int? = nil,
    layers: [PromptPrefixCache.LocalCoverage]? = nil) -> PromptPrefixCache.SnapshotObservation {
    let geometry = PromptCacheGeometry(promptTokens: 16, prefill: .init(stepSize: 4, chunking: .remainder))
    return .init(tokenIDs: ids, origin: .batchDecode, batchWidth: 3, row: row, forwardHistory: [],
      geometry: geometry, namespace: namespace,
      residentLocalCoverage: layers ?? [.init(layer: 0, window: 4, keep: 0,
        intervals: ranges.map { .init(lowerBound: $0.lowerBound, upperBound: $0.upperBound) })],
      nativePhysicalWidth: 3,
      nativeRowReceipt: .init(completedTokenCount: ids.count, submittedTokenCount: submitted ?? ids.count,
        processedTokenCount: ids.count, deliveredGeneratedTokenCount: max(0, ids.count - 8),
        acknowledgedGeneratedTokenCount: 0, observedStopTokenID: nil))
  }
  func testIndependentReducerSelectsSupportedInteriorInsteadOfLexicalGap() {
    let namespace = UUID(), ids = Array(0..<16)
    let row = snapshot(namespace, ids: ids, row: 1, ranges: [0..<8,12..<16])
    XCTAssertEqual(ActiveNativeKVSmoke.maximumPrefix([row], ids: Array(ids.prefix(10)) + [99], namespace: namespace), 8)
    XCTAssertEqual(ActiveNativeKVSmoke.maximumPrefix([row], ids: ids + [99], namespace: namespace), 16)
    XCTAssertEqual(ActiveNativeKVSmoke.maximumPrefix([row], ids: ids, namespace: UUID()), 0)
  }
  func testLayerIntersectionAndSubmittedLedgerRefuseInventedCoverage() {
    let namespace = UUID(), ids = Array(0..<16)
    let local: [PromptPrefixCache.LocalCoverage] = [
      .init(layer: 0, window: 4, keep: 0, intervals: [.init(lowerBound: 0, upperBound: 16)]),
      .init(layer: 1, window: 4, keep: 0, intervals: [.init(lowerBound: 0, upperBound: 8), .init(lowerBound: 12, upperBound: 16)])]
    let good = snapshot(namespace, ids: ids, row: 0, ranges: [], layers: local)
    XCTAssertEqual(ActiveNativeKVSmoke.maximumPrefix([good], ids: Array(ids.prefix(10)) + [99], namespace: namespace), 8)
    let unsubmitted = snapshot(namespace, ids: ids, row: 0, ranges: [0..<16], submitted: 15)
    XCTAssertEqual(ActiveNativeKVSmoke.maximumPrefix([unsubmitted], ids: ids + [99], namespace: namespace), 0)
  }
  func testSelectedCompletionRequiresUniqueActualRowAndNonemptyUnprocessedSuffix() {
    let namespace = UUID(), ids = Array(0..<12), query = ids + [99]
    let one = snapshot(namespace, ids: ids, row: 1, ranges: [0..<12])
    let two = snapshot(namespace, ids: ids, row: 2, ranges: [0..<12])
    XCTAssertEqual(ActiveNativeKVSmoke.uniqueSelectedRow([one], ids: query, namespace: namespace, originalPrompt: 8)?.row, 1)
    XCTAssertNil(ActiveNativeKVSmoke.uniqueSelectedRow([one,two], ids: query, namespace: namespace, originalPrompt: 8))
    XCTAssertEqual(ActiveNativeKVSmoke.maximumPrefix([one], ids: ids, namespace: namespace), 11)
    XCTAssertNil(ActiveNativeKVSmoke.uniqueSelectedRow([one], ids: query, namespace: namespace, originalPrompt: 12))
  }
  private func fixture(trailerChanged: Bool = false, materialChanged: Bool = false) throws -> Data {
    let policy = ModelGenerationPolicy(schema: 1, vocabularySize: 32_768, eosTokenIDs: [0],
      suppressedTokenIDs: [], controlTokenIDs: [0], textDecoding: nil,
      prefill: .init(chunking: "fixed_v1", tokenCeiling: 512))
    func input(_ ids: [Int], lcp: Int? = nil, chat: Bool = false) throws -> ActiveNativeKVSmoke.Input {
      .init(prompt: chat ? nil : "public", plan: chat ? .init(messages: [.init(role: "user", content: "public")], rawPrompt: "public") : nil,
        prepared_token_ids: ids, prompt_digest: Digest.sha256(try JSONEncoder().encode(ids)), exact_lcp_with_source: lcp)
    }
    let original = Array(0..<16_128), trailer = Array(1..<10)
    var one = original; one[16_127] = 32_766
    var material = original; material[materialChanged ? 15_615 : 15_616] = 32_765
    var chat = original; chat.replaceSubrange(16_119..<16_128, with: trailer)
    var last = chat; last[16_118] = 32_766
    if trailerChanged { last[16_127] = 32_764 }
    var chatMaterial = chat; chatMaterial[15_616] = 32_765
    let writing = ActiveNativeKVSmoke.Purpose(model: "writing", generation_policy: policy,
      source: try input(original), one_token_edit: try input(one, lcp: 16_127), maximal_content_edit: nil,
      suffix_512_edit: try input(material, lcp: 15_616), selected_row_source: try input(Array(0..<15_872)),
      invariant_generation_trailer_token_ids: nil, maximal_content_lcp: nil)
    let consultation = ActiveNativeKVSmoke.Purpose(model: "chat", generation_policy: policy,
      source: try input(chat, chat: true), one_token_edit: nil, maximal_content_edit: try input(last, lcp: 16_118, chat: true),
      suffix_512_edit: try input(chatMaterial, lcp: 15_616, chat: true), selected_row_source: nil,
      invariant_generation_trailer_token_ids: trailer, maximal_content_lcp: 16_118)
    return try JSONEncoder().encode(ActiveNativeKVSmoke.Fixture(schema: 1, purpose: "active_native_16k_public_v1",
      runtime_revision: ModelPacks.runtimeRevision, context_length: 16_384, max_output_tokens: 256,
      writing: writing, consultation: consultation))
  }
  func testFullVectorsAndActualImmutableChatTrailerBindContentGeometry() throws {
    let value = try ActiveNativeKVSmoke.Fixture.decode(fixture())
    XCTAssertEqual(value.writing.one_token_edit?.exact_lcp_with_source, 16_127)
    XCTAssertEqual(value.consultation.maximal_content_edit?.exact_lcp_with_source, 16_118)
    XCTAssertThrowsError(try ActiveNativeKVSmoke.Fixture.decode(fixture(trailerChanged: true)))
    XCTAssertThrowsError(try ActiveNativeKVSmoke.Fixture.decode(fixture(materialChanged: true)))
  }
  func testAllThreeRealTensorRowsParticipateInExactValueReduction() throws {
    try Device.withDefaultDevice(.cpu) {
      let reference = MLXArray((0..<12).map(Float.init), [3,1,4,1])
      let same = MLXArray((0..<12).map(Float.init), [3,1,4,1])
      var changed = MLXArray((0..<12).map(Float.init), [3,1,4,1])
      changed[2,0,1,0] = MLXArray(Float(999))
      func compare(_ array: MLXArray) throws -> NativePrefixParityProbe.TensorComparison {
        let rows = try (0..<3).map { row in try NativePrefixParityProbe.compareTensor(
          reference[row..<row + 1,0...,0...,0...], array[row..<row + 1,0...,0...,0...]) }
        return ActiveNativeKVNumericalObserver.mergeRows(rows, reference: reference, candidate: array)
      }
      XCTAssertEqual(try compare(same).bitwiseEqual, true)
      let difference = try compare(changed)
      XCTAssertEqual(difference.reference.shape, [3,1,4,1])
      XCTAssertEqual(difference.bitwiseEqual, false)
      XCTAssertEqual(difference.differingElementCount, 1)
      XCTAssertEqual(difference.firstDifferingAxis2Index, 1)
    }
  }
}
