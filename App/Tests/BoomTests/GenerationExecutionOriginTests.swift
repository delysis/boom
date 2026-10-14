import AppKit
import BoomCore
import XCTest
@testable import Boom

final class GenerationExecutionOriginTests: XCTestCase {
  private func policy() throws -> ModelGenerationPolicy {
    try ProductCore.generationPolicy(vocabularySize: 16,
      configuration: Data(#"{"eos_token_id":1,"suppress_tokens":[14,15]}"#.utf8),
      controls: [0, 1, 3, 14, 15], tokenizerEOS: 1)
  }
  private func recipe(_ policy: ModelGenerationPolicy) throws -> CompletionRecipe {
    let document = DocumentSnapshot(title: "Public fixture", text: "At the harbor, ")
    let prompt = try ProductCore.writingPrompt(document, caret: document.text.utf16.count, examples: [], retaining: Int.max)
    return CompletionRecipe(document: document, caretUTF16: document.text.utf16.count, sources: [],
      prompt: prompt.prompt, promptDigest: prompt.digest, omittedPrefixCharacters: 0, model: "fixture-model",
      profile: .standard, settings: try ProductCore.sampling(.standard), maxTokens: 64, generationPolicy: policy)
  }
  private func origin(_ count: Int = 0, miss: String? = "no_owner") -> GenerationExecutionOrigin {
    GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "resident-hybrid-prefix-v3",
      cachedPromptTokens: count, cacheMissReason: miss)
  }
  private func candidate(_ origin: GenerationExecutionOrigin? = nil) -> WritingCandidate {
    WritingCandidate(id: UUID(), seed: .max, text: "Café 👩🏽‍💻", state: .complete,
      promptTokens: 12, outputTokens: 2, tokenIDs: [4, 5], stopReason: "output_limit", executionOrigin: origin)
  }
  func testColdMissesAndCacheHitsKeepDifferentObservedMeanings() {
    for miss in ["no_owner", "unsupported_input", "no_resident_prefix", "local_coverage_missing", "residency_evicted"] {
      XCTAssertTrue(origin(miss: miss).isConfirmedCold(promptTokens: 12), miss)
    }
    XCTAssertTrue(origin(11, miss: nil).isValid(promptTokens: 12))
    XCTAssertFalse(origin(11, miss: nil).isConfirmedCold(promptTokens: 12))
    XCTAssertFalse(origin(12, miss: nil).isValid(promptTokens: 12))
    XCTAssertFalse(origin(-1, miss: nil).isValid(promptTokens: 12))
    XCTAssertFalse(origin(0, miss: nil).isValid(promptTokens: 12))
    XCTAssertFalse(origin(1, miss: "no_owner").isValid(promptTokens: 12))
  }
  func testConfirmedColdHistoricalPolicyReplaysItsExactRecordedGeometryAndBatch() throws {
    let loaded = try policy(); var captured = loaded
    captured.prefill = PrefillGeometry(chunking: "balanced_v1", tokenCeiling: 512)
    let recipe = try recipe(captured)
    var row = candidate(origin())
    row.batch = WritingBatchExecution(seeds: [17, .max, 42], lane: 1)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let before = try encoder.encode(recipe)
    let effective = try row.coldReplayPolicy(recipe: recipe, loadedModel: recipe.model, loadedPolicy: loaded)
    XCTAssertEqual(effective, captured)
    XCTAssertEqual(effective.prefill?.chunking, "balanced_v1")
    XCTAssertEqual(try encoder.encode(recipe), before)
    XCTAssertEqual(row.batch?.seeds, [17, .max, 42]); XCTAssertEqual(row.batch?.lane, 1)
    XCTAssertEqual(try candidate(origin(miss: "unsupported_input")).coldReplayPolicy(
      recipe: recipe, loadedModel: recipe.model, loadedPolicy: loaded), captured)
  }
  func testHistoricalMissingOriginDecodesAsUnknownEvenWithSupportedBalancedPolicy() throws {
    let loaded = try policy(); var captured = loaded
    captured.prefill = PrefillGeometry(chunking: "balanced_v1", tokenCeiling: 512)
    let recipe = try recipe(captured), old = candidate()
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let data = try encoder.encode(old)
    let restored = try PropertyListDecoder().decode(WritingCandidate.self, from: data)
    XCTAssertNil(restored.executionOrigin)
    XCTAssertEqual(Data(restored.text.utf8), Data(old.text.utf8)); XCTAssertEqual(restored.seed, .max)
    XCTAssertThrowsError(try restored.coldReplayPolicy(recipe: recipe,
      loadedModel: recipe.model, loadedPolicy: loaded))
  }
  func testWarmUnknownMalformedAndWrongModelNeverAcquireColdReplayPermission() throws {
    let loaded = try policy(), recipe = try recipe(loaded)
    let cases: [GenerationExecutionOrigin?] = [nil, origin(8, miss: nil), origin(0, miss: nil),
      GenerationExecutionOrigin(schema: 2, cacheAlgorithm: "resident-hybrid-prefix-v3", cachedPromptTokens: 0,
        cacheMissReason: "no_owner")]
    for observation in cases {
      XCTAssertThrowsError(try candidate(observation).coldReplayPolicy(recipe: recipe,
        loadedModel: recipe.model, loadedPolicy: loaded))
    }
    XCTAssertThrowsError(try candidate(origin()).coldReplayPolicy(recipe: recipe,
      loadedModel: "other-model", loadedPolicy: loaded))
    var changed = loaded; changed.prefill = PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 1024)
    XCTAssertThrowsError(try candidate(origin()).coldReplayPolicy(recipe: recipe,
      loadedModel: recipe.model, loadedPolicy: changed))
  }
  func testWarmOriginSurvivesFileRecordRoundTripWithoutASeparateInventoryKind() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-origin-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try Vault(root: root)
    let recipe = try recipe(policy()), row = candidate(origin(8, miss: nil))
    let bundle = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [row], selected: 0)
    try vault.encode(bundle, kind: .candidate, id: bundle.id)
    let restored = try vault.decode(CandidateBundle.self, kind: .candidate, id: bundle.id)
    XCTAssertEqual(restored.candidates[0].executionOrigin, row.executionOrigin)
    XCTAssertEqual(restored.recipe.generationPolicy, recipe.generationPolicy)
  }
  @MainActor func testUnavailableModelDoesNotBeginAReplayOperation() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-replay-guard-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.state.autocomplete = false
    let recipe = try recipe(policy())
    model.appendDocument(recipe.document); model.state.selectedDocument = recipe.document.id
    // This fixture has no loaded or known writing model. Origin-specific
    // admission with a matching model/policy is checked separately above.
    for observation in [nil, origin(), origin(8, miss: nil)] as [GenerationExecutionOrigin?] {
      let bundle = CandidateBundle(id: UUID(), recipe: recipe, origin: nil,
        candidates: [candidate(observation)], selected: 0)
      model.candidates = bundle; model.showingCandidates = false
      XCTAssertFalse(model.canReplayCandidate(0))
      model.replayCandidate(0)
      XCTAssertFalse(model.isBusy); XCTAssertFalse(model.showingCandidates)
      XCTAssertEqual(model.candidates?.id, bundle.id)
      XCTAssertEqual(model.candidates?.candidates[0].executionOrigin, observation)
    }
    try await model.shutdown()
  }

  func testDecodedCorruptCohortRowIntExtremesRefuseBeforeSuffixArithmetic() throws {
    func row(_ prompt: Int, _ cached: Int, _ length: Int, _ padding: Int) -> [String: Any] {
      ["operationID": UUID().uuidString, "attemptID": UUID().uuidString,
        "namespace": UUID().uuidString, "recordID": UUID().uuidString,
        "requestDigest": String(repeating: "a", count: 64),
        "preparedTokenDigest": String(repeating: "b", count: 64),
        "promptTokens": prompt, "cachedTokens": cached, "seed": 17, "outputLimit": 4,
        "samplingDigest": String(repeating: "c", count: 64),
        "cacheHistoryDigest": String(repeating: "d", count: 64),
        "cacheLengths": [length], "cachePadding": [padding]]
    }
    let rows = [row(12, 0, 0, 4), row(10, 4, 4, 0)]
    let wire: [String: Any] = ["schema": 1, "cohortID": UUID().uuidString, "row": 0,
      "rows": rows, "policyDigest": String(repeating: "e", count: 64), "promptWidth": 12,
      "maskDigest": String(repeating: "f", count: 64), "cacheWidths": [4],
      "prefill": ["chunking": "remainder", "tokenCeiling": 512, "chunkStride": 11]]
    let decoder = JSONDecoder()
    let valid = try decoder.decode(IndependentTextCohortOrigin.self,
      from: JSONSerialization.data(withJSONObject: wire))
    XCTAssertTrue(valid.isValid(promptTokens: 12, cachedTokens: 0))
    // Corrupt the OTHER decoded row so the own-row initial guard still passes.
    // Both differences overflow Int unless bounded validation runs first.
    for (prompt, cached) in [(Int.min, Int.max), (Int.max, Int.min), (10, Int.min)] {
      var changed = wire, corrupted = rows
      corrupted[1]["promptTokens"] = prompt; corrupted[1]["cachedTokens"] = cached
      changed["rows"] = corrupted
      let decoded = try decoder.decode(IndependentTextCohortOrigin.self,
        from: JSONSerialization.data(withJSONObject: changed))
      XCTAssertFalse(decoded.isValid(promptTokens: 12, cachedTokens: 0))
    }
  }
}
