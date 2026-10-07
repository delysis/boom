import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class RecoveryTests: XCTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-recovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func testInterruptedBatchFinishesEveryDocumentBeforePublishingIndex() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let a = DocumentSnapshot(title: "A", text: "Before A"), b = DocumentSnapshot(title: "B", text: "Before B")
    var state = WorkspaceState(); state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    try await store.save(state, documents: [a, b])
    let afterA = DocumentSnapshot(id: a.id, title: a.title, text: "After A"), afterB = DocumentSnapshot(id: b.id, title: b.title, text: "After B")
    let journal = WorkspaceStore.SaveJournal(schema: 1, state: state, documents: [afterA, afterB], before: [a.id: a.revision, b.id: b.revision])
    try store.vault.encode(journal, kind: .saveJournal, id: Vault.workspaceID)
    try store.vault.put(Data(afterA.text.utf8), kind: .document, id: a.id)
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    let loaded = try await restarted.load().get()
    XCTAssertEqual(loaded.1, [afterA, afterB])
    XCTAssertFalse(restarted.vault.exists(.saveJournal, Vault.workspaceID))
    try await restarted.save(state, documents: [DocumentSnapshot(id: b.id, title: b.title, text: "Next B")])
  }
  func testConflictingCrashJournalRepairsNothingAndRetainsEvidence() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let a = DocumentSnapshot(title: "A", text: "Before A"), b = DocumentSnapshot(title: "B", text: "Before B")
    var state = WorkspaceState(); state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    try await store.save(state, documents: [a, b])
    let journal = WorkspaceStore.SaveJournal(schema: 1, state: state,
      documents: [DocumentSnapshot(id: a.id, title: a.title, text: "After A"), DocumentSnapshot(id: b.id, title: b.title, text: "After B")],
      before: [a.id: a.revision, b.id: b.revision])
    try store.vault.encode(journal, kind: .saveJournal, id: Vault.workspaceID)
    try store.vault.put(Data("Conflicting B".utf8), kind: .document, id: b.id)
    let retained = try Data(contentsOf: store.vault.recordURL(.saveJournal, Vault.workspaceID))
    switch await store.load() { case .success: XCTFail("Conflict was ignored"); case .failure: break }
    XCTAssertEqual(try store.vault.get(.document, id: a.id), Data(a.text.utf8))
    XCTAssertEqual(try Data(contentsOf: store.vault.recordURL(.saveJournal, Vault.workspaceID)), retained)
  }
  func testInterruptedRepliesKeepCapturedSpeakerAndPartialText() async throws {
    let store = try WorkspaceStore(rootOverride: root(), testKey: SymmetricKey(size: .bits256))
    let speaker = Speaker(name: "Original name", voiceID: UUID(), voiceRevision: "captured-revision")
    var chat = ChatRecord(title: "Consultation")
    chat.messages = [ChatMessage(role: .user, text: "Question"), ChatMessage(role: .assistant, text: "Partial answer", state: .pending, speaker: speaker)]
    var state = WorkspaceState(); state.chats = [chat]
    try await store.save(state, documents: [])
    let loaded = try await store.load().get().0.chats[0].messages[1]
    XCTAssertEqual(loaded.state, .cancelled); XCTAssertEqual(loaded.text, "Partial answer"); XCTAssertEqual(loaded.speaker, speaker)
  }
  func testProcessSessionSharesSuccessAndDenialWithoutRetry() async throws {
    let success = VaultSession(loader: { _ in SymmetricKey(data: Data(repeating: 7, count: 32)) })
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<16 { group.addTask { (try? success.unlock(existingRecords: true)) != nil } }
      for await result in group { XCTAssertTrue(result) }
    }
    XCTAssertEqual(success.lookupCount, 1)
    let denied = VaultSession(loader: { _ in throw BoomError.denied("Denied") })
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<16 { group.addTask { (try? denied.unlock(existingRecords: false)) == nil } }
      for await result in group { XCTAssertTrue(result) }
    }
    XCTAssertEqual(denied.lookupCount, 1)
  }
  func testInterruptedGenerationFinishesDurableReceiptsAndCandidates() async throws {
    let store = try WorkspaceStore(rootOverride: root(), testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Manuscript", text: "At the shore, ")
    let prompt = try ProductCore.writingPrompt(document, caret: document.text.utf16.count, examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: document, caretUTF16: document.text.utf16.count, sources: [],
      prompt: prompt.prompt, promptDigest: prompt.digest, omittedPrefixCharacters: 0, model: "captured-model",
      profile: .standard, settings: try ProductCore.sampling(.standard), maxTokens: 256, generationPolicy: nil)
    let bundle = CandidateBundle(id: UUID(), recipe: recipe, origin: nil,
      candidates: [WritingCandidate(id: UUID(), seed: 7, text: "a partial continuation", state: .pending,
        promptTokens: 9, outputTokens: 2, tokenIDs: [1, 2], stopReason: nil)], selected: 0)
    let message = ChatMessage(role: .assistant, text: "partial consultation", state: .pending)
    var chat = ChatRecord(); chat.messages = [message]
    let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: "", request: "Question", routing: [])
    let receipt = ConsultationReceipt(operationID: UUID(), seed: 9, state: .pending, failure: nil,
      model: "captured-model", voice: nil, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt),
      tokenIDs: [3], stopReason: "pending", firstTokenSeconds: 1, elapsedSeconds: 2, generationPolicy: nil)
    try store.vault.encode(bundle, kind: .candidate, id: bundle.id)
    try store.vault.encode(receipt, kind: .receipt, id: message.id)
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.chats = [chat]; state.candidateIDs = [bundle.id]
    try await store.save(state, documents: [document])
    _ = try await store.load().get()
    let recovered = try store.vault.decode(CandidateBundle.self, kind: .candidate, id: bundle.id)
    XCTAssertEqual(recovered.candidates[0].state, .cancelled)
    XCTAssertEqual(recovered.candidates[0].stopReason, "interrupted")
    XCTAssertEqual(recovered.candidates[0].text, bundle.candidates[0].text)
    XCTAssertEqual(recovered.candidates[0].tokenIDs, [1, 2]); XCTAssertEqual(recovered.candidates[0].seed, 7)
    let stopped = try store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id)
    XCTAssertEqual(stopped.state, .cancelled); XCTAssertEqual(stopped.tokenIDs, [3])
    XCTAssertEqual(stopped.stopReason, "interrupted")
  }
  func testInterruptedRetryKeepsFailedAttemptAndCancelsOnlyTheActiveAttempt() async throws {
    let store = try WorkspaceStore(rootOverride: root(), testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Public retry fixture", text: "Same.\nSame.")
    let message = ChatMessage(role: .assistant, text: "", state: .pending)
    var chat = ChatRecord(attachedDocumentID: document.id); chat.messages = [message]
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.chats = [chat]
    let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: document.text,
      request: "Change the second line.", routing: [], authority: CapturedDocumentAuthority(mode: .edit, target: document))
    let operation = UUID(), firstID = UUID(), activeID = UUID()
    var first = ConsultationReceipt(operationID: operation, seed: 7, state: .failed, failure: "Malformed fixture",
      model: "unit-test-model", voice: nil, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt),
      tokenIDs: [1], stopReason: "eos", firstTokenSeconds: 1, elapsedSeconds: 2, generationPolicy: nil)
    first.attemptID = firstID; first.responseID = message.id
    try store.vault.encode(first, kind: .receipt, id: firstID)
    let retainedFirst = try Data(contentsOf: store.vault.recordURL(.receipt, firstID))
    var active = ConsultationReceipt(operationID: operation, seed: 9, state: .pending, failure: nil,
      model: "unit-test-model", voice: nil, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt),
      tokenIDs: [], stopReason: "pending", firstTokenSeconds: nil, elapsedSeconds: 0, generationPolicy: nil)
    active.attemptID = activeID; active.previousAttemptID = firstID; active.responseID = message.id
    try store.vault.encode(active, kind: .receipt, id: activeID)
    try store.vault.encode(active, kind: .receipt, id: message.id)
    let identity = GenerationIdentity(kind: .documentResponse, operationID: operation, recordID: message.id,
      attemptID: activeID, model: active.model, seed: active.seed, requestDigest: Digest.sha256(plan.rawPrompt),
      maxTokens: 4096, generationPolicy: nil)
    try await store.checkpoint(GenerationProgress(text: "Incomplete public fixture", tokenIDs: [2, 3],
      promptDigest: Digest.sha256(plan.rawPrompt), promptTokens: 100, firstTokenSeconds: 1, elapsedSeconds: 2),
      identity: identity, stopReason: nil)
    try await store.save(state, documents: [document])
    let recovered = try await store.load().get()
    XCTAssertEqual(recovered.1[0].text, document.text)
    XCTAssertEqual(recovered.0.chats[0].messages[0].state, .cancelled)
    let stopped = try store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id)
    let archived = try store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: activeID)
    XCTAssertEqual(stopped.state, .cancelled); XCTAssertEqual(archived.state, .cancelled)
    XCTAssertEqual(stopped.previousAttemptID, firstID); XCTAssertEqual(stopped.tokenIDs, [2, 3])
    XCTAssertEqual(try Data(contentsOf: store.vault.recordURL(.receipt, firstID)), retainedFirst)
    let checkpoint = try await store.consultationCheckpoint(id: message.id, receipt: stopped)
    XCTAssertEqual(checkpoint?.identity.attemptID, activeID)
  }

  func testCorruptCapturedGenerationNeverBecomesEmptyState() async throws {
    let store = try WorkspaceStore(rootOverride: root(), testKey: SymmetricKey(size: .bits256))
    let id = UUID(); var state = WorkspaceState(); state.candidateIDs = [id]
    try store.vault.put(Data("incompatible candidate".utf8), kind: .candidate, id: id)
    try await store.save(state, documents: [])
    let before = try Data(contentsOf: store.vault.recordURL(.workspace, Vault.workspaceID))
    switch await store.load() { case .success: XCTFail("Invalid captured attempt was ignored"); case .failure: break }
    XCTAssertEqual(try Data(contentsOf: store.vault.recordURL(.workspace, Vault.workspaceID)), before)
    XCTAssertEqual(try store.vault.get(.candidate, id: id), Data("incompatible candidate".utf8))
  }
  func testCacheSearchKeepsDefaultWhenEnvironmentPointsElsewhere() {
    let roots = HuggingFaceCache.roots(environment: ["HF_HUB_CACHE": "/tmp/alternate-hub", "HF_HOME": "/tmp/alternate-home", "XDG_CACHE_HOME": "/tmp/xdg"], home: URL(fileURLWithPath: "/Users/example"))
    XCTAssertEqual(roots.map(\.path), ["/tmp/alternate-hub", "/tmp/alternate-home/hub", "/tmp/xdg/huggingface/hub", "/Users/example/.cache/huggingface/hub"])
  }
}
