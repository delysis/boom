import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class WritingHistoryTests: XCTestCase {
  private func bundle(_ document: DocumentSnapshot, prose: String, budget: Int = 256) throws -> CandidateBundle {
    let compiled = try ProductCore.writingPrompt(document, caret: document.text.utf16.count,
      examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: document, caretUTF16: document.text.utf16.count,
      sources: [], prompt: compiled.prompt, promptDigest: compiled.digest, omittedPrefixCharacters: 0,
      model: "authored-unit-fixture", profile: .standard, settings: try ProductCore.sampling(.standard),
      maxTokens: budget, generationPolicy: nil)
    // Authored fixtures test ownership and persistence, never model quality.
    let candidate = WritingCandidate(id: UUID(), seed: 42, text: prose, state: .complete,
      promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: "unit-fixture")
    return CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [candidate], selected: 0)
  }
  private func fixture() async throws -> (URL, WorkspaceStore, DocumentSnapshot, DocumentSnapshot, CandidateBundle, CandidateBundle) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-history-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let a = DocumentSnapshot(title: "A", text: "Café 👩🏽‍💻 waits."), b = DocumentSnapshot(title: "B", text: "Another manuscript.")
    let first = try bundle(a, prose: " First captured continuation."), second = try bundle(a, prose: " Second captured continuation.")
    for value in [first, second] { try store.vault.encode(value, kind: .candidate, id: value.id) }
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = a.id
    state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    state.candidateIDs = [first.id, second.id]
    try await store.save(state, documents: [a, b])
    return (root, store, a, b, first, second)
  }
  @MainActor private func finish(_ model: WorkspaceModel) async throws {
    for _ in 0..<500 {
      if !model.isBusy { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Opening a saved set did not finish within five seconds")
    throw CancellationError()
  }
  func testLatestExplicitSetSurvivesMoreRecentAutomaticSuggestion() async throws {
    let (root, store, a, b, first, second) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let automatic = try bundle(a, prose: " A later automatic suggestion.", budget: 64)
    let foreign = try bundle(b, prose: " Another document's result.")
    for value in [automatic, foreign] { try store.vault.encode(value, kind: .candidate, id: value.id) }
    let ids = [first.id, second.id, automatic.id, foreign.id]
    let history = try await store.candidateHistory(for: a.id, ids: ids)
    XCTAssertEqual(history.explorations.map(\.id), [second.id, first.id])
    XCTAssertEqual(history.latest, second.id)
    let latest = try await store.latestCandidate(for: a.id, ids: ids)
    XCTAssertEqual(latest?.id, second.id)
    let other = try await store.candidateHistory(for: b.id, ids: ids)
    XCTAssertEqual(other.explorations.map(\.id), [foreign.id])
  }
  @MainActor func testDismissReopenAndOlderSetPreserveLiveTextCaretAndCapturedRecipe() async throws {
    let (root, store, a, _, first, second) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(model.candidates?.id, second.id)
    model.dismissCandidates()
    XCTAssertNil(model.candidates); XCTAssertTrue(model.canShowContinuations)
    model.showContinuations(); try await finish(model)
    XCTAssertTrue(model.showingCandidates); XCTAssertEqual(model.candidates?.id, second.id)
    let liveText = a.text + " A subsequent human edit."
    model.updateDocument(liveText, id: a.id, caret: 7)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertEqual(model.selectedDocument?.text, liveText); XCTAssertEqual(model.caret, 7)
    XCTAssertEqual(model.candidates?.recipe.prompt, first.recipe.prompt)
    XCTAssertEqual(model.candidates?.recipe.document, a)
    XCTAssertEqual(model.candidates?.candidates.first?.seed, first.candidates.first?.seed)
    XCTAssertEqual(model.candidates?.candidates.first?.text, first.candidates.first?.text)
    XCTAssertFalse(model.candidateIsCurrent)
    XCTAssertEqual(model.savedExplorations.map(\.id), [second.id, first.id])
    try await model.shutdown()
  }
  @MainActor func testSwitchDuringOpenCannotPublishAnotherManuscriptsSet() async throws {
    let (root, store, a, b, first, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.dismissCandidates(); model.reviewContinuation(first.id)
    model.selectDocument(b.id)
    try await finish(model)
    XCTAssertNil(model.candidates); XCTAssertFalse(model.showingCandidates)
    XCTAssertEqual(model.selectedDocument, b); XCTAssertEqual(model.caret, 0)
    model.selectDocument(a.id)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertEqual(model.candidates?.id, first.id); XCTAssertEqual(model.selectedDocument, a)
    try await model.shutdown()
  }
  func testIncompatibleSetIsRejectedBeforeRecoveryCanRewriteIt() async throws {
    let (root, store, _, _, first, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var incompatible = first
    incompatible.candidates = (0..<4).map { _ in
      WritingCandidate(id: UUID(), seed: 42, text: "", state: .pending,
        promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: nil)
    }
    try store.vault.encode(incompatible, kind: .candidate, id: first.id)
    let url = store.vault.recordURL(.candidate, first.id), before = try Data(contentsOf: url)
    switch await store.load() { case .success: XCTFail("Four-row incompatible set was admitted"); case .failure: break }
    XCTAssertEqual(try Data(contentsOf: url), before)
  }
  @MainActor func testCorruptRecordIsRejectedWithoutReplacingBytesOrVisibleSet() async throws {
    let (root, store, a, _, first, second) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let url = store.vault.recordURL(.candidate, first.id)
    var damaged = try Data(contentsOf: url); damaged[damaged.count - 1] ^= 1
    try damaged.write(to: url, options: .atomic)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.candidates?.id, second.id); XCTAssertEqual(model.selectedDocument, a)
    XCTAssertEqual(try Data(contentsOf: url), damaged)
    try await model.shutdown()
    XCTAssertEqual(try Data(contentsOf: url), damaged)
  }
}
