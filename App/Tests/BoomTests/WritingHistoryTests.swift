import BoomCore
import XCTest
@testable import Boom

final class WritingHistoryTests: XCTestCase {
  @MainActor private final class WorkspaceCleanup {
    private var model: WorkspaceModel?
    private var attempted = false
    private var failure: Error?
    init(_ model: WorkspaceModel) { self.model = model }
    func close() async throws {
      guard !attempted else { if let failure { throw failure }; return }
      attempted = true
      guard let model else { return }
      do { try await model.shutdown(); self.model = nil }
      catch { failure = error; throw error }
    }
  }
  @MainActor private func track(_ model: WorkspaceModel, root: URL) {
    let cleanup = WorkspaceCleanup(model), failures = testRun?.failureCount ?? 0
    addTeardownBlock {
      try await cleanup.close()
      if await MainActor.run(body: { self.testRun?.failureCount ?? 0 }) == failures {
        try FileManager.default.removeItem(at: root)
      }
    }
  }
  func testCancelledHistoryDoesNotReadMissingCandidateRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-cancelled-history-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = UUID(), document = UUID()
    let request = Task.detached { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try await store.candidateHistory(for: document, ids: [missing])
        return false
      } catch { return error is CancellationError }
    }
    let cancelledBeforeRead = await request.value
    XCTAssertTrue(cancelledBeforeRead, "An obsolete request must stop before opening a missing candidate.")
    let history = try await store.candidateHistory(for: document, ids: [])
    XCTAssertTrue(history.explorations.isEmpty)
    XCTAssertNil(history.latest)
  }

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
    let store = try WorkspaceStore(rootOverride: root)
    let a = DocumentSnapshot(title: "A", text: "Café 👩🏽‍💻 waits."), b = DocumentSnapshot(title: "B", text: "Another manuscript.")
    let first = try bundle(a, prose: " First captured continuation."), second = try bundle(a, prose: " Second captured continuation.")
    for value in [first, second] { try store.vault.encode(value, kind: .candidate, id: value.id) }
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = a.id
    state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    state.candidateIDs = [first.id, second.id]
    try await PagedFileEngineControlOutputs.seed(store, documents: [a, b])
    try await store.saveState(state)
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
  @MainActor private func waitForSavedHistory(_ model: WorkspaceModel, count: Int) async throws {
    for _ in 0..<500 {
      if model.savedExplorations.count == count { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Saved continuation history did not load.")
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
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let cleanup = WorkspaceCleanup(model); track(model, root: root)
    try await waitForSavedHistory(model, count: 2)
    model.showContinuations(); try await finish(model)
    XCTAssertEqual(model.candidates?.id, second.id)
    model.dismissCandidates()
    XCTAssertNil(model.candidates); XCTAssertTrue(model.canShowContinuations)
    model.showContinuations(); try await finish(model)
    XCTAssertTrue(model.showingCandidates); XCTAssertEqual(model.candidates?.id, second.id)
    let liveText = a.text + " A subsequent human edit."
    try await NativeCheckEvidence.replacePublicDocument(model, text: liveText, id: a.id, caret: 5)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertEqual(model.pagedSelectedRecord?.document.id, a.id)
    XCTAssertEqual(model.pagedInput?.activeView?.string, liveText); XCTAssertEqual(model.caret, 5)
    XCTAssertEqual(model.candidates?.recipe.prompt, first.recipe.prompt)
    XCTAssertEqual(model.candidates?.recipe.document, a)
    XCTAssertEqual(model.candidates?.candidates.first?.seed, first.candidates.first?.seed)
    XCTAssertEqual(model.candidates?.candidates.first?.text, first.candidates.first?.text)
    XCTAssertFalse(model.candidateIsCurrent)
    XCTAssertEqual(model.savedExplorations.map(\.id), [second.id, first.id])
    try await cleanup.close()
  }
  @MainActor func testSwitchResetsCandidateSetAndCannotShowAnotherManuscriptsSet() async throws {
    let (root, store, a, b, first, _) = try await fixture()
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let cleanup = WorkspaceCleanup(model); track(model, root: root)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertEqual(model.candidates?.id, first.id)
    model.selectDocument(b.id)
    try await finish(model)
    XCTAssertNil(model.candidates); XCTAssertFalse(model.showingCandidates)
    XCTAssertEqual(model.pagedSelectedRecord?.document.id, b.id)
    XCTAssertEqual(model.pagedInput?.activeView?.string, b.text); XCTAssertEqual(model.caret, 0)
    model.selectDocument(a.id); try await finish(model)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertEqual(model.candidates?.id, first.id)
    XCTAssertEqual(model.pagedSelectedRecord?.document.id, a.id)
    XCTAssertEqual(model.pagedInput?.activeView?.string, a.text)
    try await cleanup.close()
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
    do { _ = try await store.loadState(); XCTFail("Four-row incompatible set was admitted") } catch {}
    XCTAssertEqual(try Data(contentsOf: url), before)
  }
  @MainActor func testCorruptRecordIsRejectedWithoutReplacingBytesOrVisibleSet() async throws {
    let (root, store, a, _, first, second) = try await fixture()
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let cleanup = WorkspaceCleanup(model); track(model, root: root)
    model.reviewContinuation(second.id); try await finish(model)
    XCTAssertEqual(model.candidates?.id, second.id)
    let url = store.vault.recordURL(.candidate, first.id)
    var damaged = try Data(contentsOf: url); damaged[damaged.count - 1] ^= 1
    try damaged.write(to: url, options: .atomic)
    model.reviewContinuation(first.id); try await finish(model)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.candidates?.id, second.id)
    XCTAssertEqual(model.pagedSelectedRecord?.document.id, a.id)
    XCTAssertEqual(model.pagedInput?.activeView?.string, a.text)
    XCTAssertEqual(try Data(contentsOf: url), damaged)
    try await cleanup.close()
    XCTAssertEqual(try Data(contentsOf: url), damaged)
  }
}
