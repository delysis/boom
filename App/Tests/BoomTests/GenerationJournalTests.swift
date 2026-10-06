import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class GenerationJournalTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let key: SymmetricKey
    let store: WorkspaceStore
    let chat: ChatRecord
    let receipt: ConsultationReceipt
    let bundle: CandidateBundle
    let consultation: GenerationIdentity
    let writing: GenerationIdentity
    let document: DocumentSnapshot
  }
  private func fixture(_ policy: ModelGenerationPolicy? = nil) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-journal-" + UUID().uuidString)
    let key = SymmetricKey(size: .bits256), store = try WorkspaceStore(rootOverride: root, testKey: key)
    let document = DocumentSnapshot(title: "Manuscript", text: "At the shore, ")
    let prompt = try ProductCore.writingPrompt(document, caret: document.text.utf16.count, examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: document, caretUTF16: document.text.utf16.count, sources: [],
      prompt: prompt.prompt, promptDigest: prompt.digest, omittedPrefixCharacters: 0, model: "captured-model",
      profile: .standard, settings: try ProductCore.sampling(.standard), maxTokens: 256, generationPolicy: policy)
    let bundle = CandidateBundle(id: UUID(), recipe: recipe, origin: nil,
      candidates: [WritingCandidate(id: UUID(), seed: UInt64.max, text: "", state: .pending,
        promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: nil)], selected: 0)
    let speaker = Speaker(name: "Captured name", voiceID: UUID(), voiceRevision: "captured-revision")
    var chat = ChatRecord(); chat.messages = [ChatMessage(role: .assistant, text: "", state: .pending, speaker: speaker)]
    let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: "", request: "Question", routing: [])
    let operationID = UUID(), replyID = chat.messages[0].id
    let receipt = ConsultationReceipt(operationID: operationID, seed: 17, state: .pending, failure: nil,
      model: "captured-model", voice: nil, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt),
      tokenIDs: [], stopReason: "pending", firstTokenSeconds: nil, elapsedSeconds: 0, generationPolicy: policy)
    try store.vault.encode(bundle, kind: .candidate, id: bundle.id)
    try store.vault.encode(receipt, kind: .receipt, id: replyID)
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.chats = [chat]; state.candidateIDs = [bundle.id]
    try await store.save(state, documents: [document])
    return Fixture(root: root, key: key, store: store, chat: chat, receipt: receipt, bundle: bundle,
      consultation: GenerationIdentity(kind: .consultation, operationID: operationID, recordID: replyID,
        attemptID: replyID, model: receipt.model, seed: receipt.seed,
        requestDigest: Digest.sha256(plan.rawPrompt), maxTokens: 512, generationPolicy: policy),
      writing: GenerationIdentity(kind: .writing, operationID: UUID(), recordID: bundle.id,
        attemptID: bundle.candidates[0].id, model: recipe.model, seed: UInt64.max,
        requestDigest: recipe.promptDigest, maxTokens: 256, generationPolicy: policy), document: document)
  }
  private func progress(_ text: String = "A partial answer 👩🏽‍💻é", tokens: [Int] = [1, 2], elapsed: Double = 1) -> GenerationProgress {
    GenerationProgress(text: text, tokenIDs: tokens, promptDigest: Digest.sha256("prepared tokens"),
      promptTokens: 12, firstTokenSeconds: 0.2, elapsedSeconds: elapsed)
  }
  func testBatchRowsRecoverIndependentlyAndRejectChangedGeometryWithoutOverwriting() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    var bundle = f.bundle
    let seeds: [UInt64] = [.max, 17, 42]
    bundle.candidates = seeds.enumerated().map { lane, seed in
      WritingCandidate(id: UUID(), seed: seed, text: "", state: .pending,
        promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: nil,
        batch: WritingBatchExecution(seeds: seeds, lane: lane))
    }
    try f.store.vault.encode(bundle, kind: .candidate, id: bundle.id)
    for lane in seeds.indices {
      let identity = GenerationIdentity(kind: .writing, operationID: f.writing.operationID,
        recordID: bundle.id, attemptID: bundle.candidates[lane].id, model: bundle.recipe.model,
        seed: seeds[lane], requestDigest: bundle.recipe.promptDigest, maxTokens: 256,
        generationPolicy: nil, batch: bundle.candidates[lane].batch)
      try await f.store.checkpoint(progress("Row \(lane) 👩🏽‍💻é"), identity: identity,
        stopReason: lane == 0 ? "output_limit" : nil)
    }
    // Simulate death before the final bundle save: every stored row is pending,
    // but the first row has a durable terminal journal.
    let fresh = try WorkspaceStore(rootOverride: f.root, testKey: f.key)
    let (_, documents) = try await fresh.load().get()
    let recovered = try fresh.vault.decode(CandidateBundle.self, kind: .candidate, id: bundle.id)
    XCTAssertEqual(recovered.candidates.map(\.state), [.complete, .cancelled, .cancelled])
    XCTAssertEqual(recovered.candidates.map(\.text), ["Row 0 👩🏽‍💻é", "Row 1 👩🏽‍💻é", "Row 2 👩🏽‍💻é"])
    XCTAssertEqual(recovered.candidates.map(\.batch), bundle.candidates.map(\.batch))
    XCTAssertEqual(documents[0], f.document)
    var altered = recovered
    altered.candidates[1].batch = WritingBatchExecution(seeds: [.max, 17], lane: 1)
    try fresh.vault.encode(altered, kind: .candidate, id: altered.id)
    let candidateURL = fresh.vault.recordURL(.candidate, altered.id)
    let before = try Data(contentsOf: candidateURL)
    switch await fresh.load() { case .success: XCTFail("Changed batch shape was admitted"); case .failure: break }
    XCTAssertEqual(try Data(contentsOf: candidateURL), before)
  }
  func testFreshStoreRecoversOnlyDurableTokensAndKeepsManuscriptAndSpeaker() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let checkpoint = progress()
    try await f.store.checkpoint(checkpoint, identity: f.consultation, stopReason: nil)
    try await f.store.checkpoint(checkpoint, identity: f.writing, stopReason: nil)
    let fresh = try WorkspaceStore(rootOverride: f.root, testKey: f.key)
    let (state, documents) = try await fresh.load().get()
    XCTAssertEqual(state.chats[0].messages[0].text, checkpoint.text)
    XCTAssertEqual(state.chats[0].messages[0].state, .cancelled)
    XCTAssertEqual(state.chats[0].messages[0].speaker, f.chat.messages[0].speaker)
    XCTAssertEqual(documents[0].text, f.document.text)
    let bundle = try fresh.vault.decode(CandidateBundle.self, kind: .candidate, id: f.bundle.id)
    XCTAssertEqual(bundle.candidates[0].text, checkpoint.text)
    XCTAssertEqual(bundle.candidates[0].tokenIDs, checkpoint.tokenIDs)
    XCTAssertEqual(bundle.candidates[0].seed, UInt64.max)
    XCTAssertEqual(bundle.candidates[0].state, .cancelled)
    let receipt = try fresh.vault.decode(ConsultationReceipt.self, kind: .receipt, id: f.consultation.attemptID)
    XCTAssertEqual(receipt.tokenIDs, checkpoint.tokenIDs); XCTAssertEqual(receipt.state, .cancelled)
    let durable = try fresh.vault.decode(WorkspaceState.self, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit)
    XCTAssertEqual(durable.chats[0].messages[0].text, checkpoint.text)
    let second = try await fresh.load().get().0
    XCTAssertEqual(second.chats[0].messages[0].text, checkpoint.text)
    for file in try FileManager.default.contentsOfDirectory(at: fresh.vault.root, includingPropertiesForKeys: nil) {
      XCTAssertNil(try Data(contentsOf: file).range(of: Data(checkpoint.text.utf8)))
    }
  }
  func testStoppingIdentitySurvivesEncryptedInterruptionAndWrongTokenRetainsBytes() async throws {
    let policy = try ProductCore.generationPolicy(vocabularySize: 16,
      configuration: Data(#"{"eos_token_id":1,"suppress_tokens":[15,14]}"#.utf8),
      controls: [0, 1, 3, 14, 15], tokenizerEOS: 1)
    let f = try await fixture(policy); defer { try? FileManager.default.removeItem(at: f.root) }
    let value = progress(tokens: [4, 5])
    try await f.store.checkpoint(value, identity: f.writing, stopReason: nil)
    let url = f.store.vault.recordURL(.generationJournal, f.writing.attemptID)
    let before = try Data(contentsOf: url)
    do {
      try await f.store.checkpoint(value, identity: f.writing, stopReason: "model_control", stopTokenID: 14)
      XCTFail("Suppressed stopping token was admitted")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: url), before)
    try await f.store.checkpoint(value, identity: f.writing, stopReason: "eos", stopTokenID: 1)
    try await f.store.checkpoint(value, identity: f.consultation, stopReason: "eos", stopTokenID: 1)
    let fresh = try WorkspaceStore(rootOverride: f.root, testKey: f.key)
    _ = try await fresh.load().get()
    let bundle = try fresh.vault.decode(CandidateBundle.self, kind: .candidate, id: f.bundle.id)
    XCTAssertEqual(bundle.recipe.generationPolicy, policy)
    XCTAssertEqual(bundle.candidates[0].stopTokenID, 1)
    XCTAssertEqual(bundle.candidates[0].stopReason, "eos")
    XCTAssertEqual(bundle.candidates[0].state, .complete)
    let receipt = try fresh.vault.decode(ConsultationReceipt.self, kind: .receipt, id: f.consultation.attemptID)
    XCTAssertEqual(receipt.generationPolicy, policy); XCTAssertEqual(receipt.stopTokenID, 1)
    let journal = try await fresh.writingCheckpoint(bundle: bundle, candidate: bundle.candidates[0])
    XCTAssertEqual(journal?.stopTokenID, 1); XCTAssertEqual(journal?.stopReason, "eos")
    XCTAssertThrowsError(try ProductCore.admitGenerationPolicy(nil, loaded: policy))
  }
  func testStaleCheckpointAndCorruptionRetainExactSealedBytesAndIndex() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.checkpoint(progress(), identity: f.consultation, stopReason: "cancelled")
    let url = f.store.vault.recordURL(.generationJournal, f.consultation.attemptID)
    let before = try Data(contentsOf: url)
    do {
      try await f.store.checkpoint(progress(tokens: [1, 2, 3], elapsed: 2), identity: f.consultation, stopReason: nil)
      XCTFail("A late checkpoint reopened a cancelled producer")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: url), before)
    try await f.store.checkpoint(progress(), identity: f.writing, stopReason: nil)
    let corruptedURL = f.store.vault.recordURL(.generationJournal, f.writing.attemptID)
    var damaged = try Data(contentsOf: corruptedURL); damaged[damaged.count / 2] ^= 1
    try damaged.write(to: corruptedURL)
    let index = try Data(contentsOf: f.store.vault.recordURL(.workspace, Vault.workspaceID))
    let receipt = try Data(contentsOf: f.store.vault.recordURL(.receipt, f.consultation.attemptID))
    switch await f.store.load() { case .success: XCTFail("Corrupted checkpoint was admitted"); case .failure: break }
    XCTAssertEqual(try Data(contentsOf: corruptedURL), damaged)
    XCTAssertEqual(try Data(contentsOf: f.store.vault.recordURL(.workspace, Vault.workspaceID)), index)
    XCTAssertEqual(try Data(contentsOf: f.store.vault.recordURL(.receipt, f.consultation.attemptID)), receipt)
  }
  func testInterruptedStructuredResponseKeepsRawOutputWithoutEditingOrDisplayingAPartialPatch() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let generation = GenerationIdentity(kind: .documentResponse, operationID: f.consultation.operationID,
      recordID: f.consultation.recordID, attemptID: f.consultation.attemptID,
      model: f.consultation.model, seed: f.consultation.seed,
      requestDigest: f.consultation.requestDigest, maxTokens: 4096, generationPolicy: nil)
    let partial = progress("{\"reply\":\"Changed\",\"edits\":[")
    try await f.store.checkpoint(partial, identity: generation, stopReason: nil)
    let (state, documents) = try await f.store.load().get()
    XCTAssertEqual(state.chats[0].messages[0].text, "")
    XCTAssertEqual(state.chats[0].messages[0].state, .cancelled)
    XCTAssertTrue(state.proposals.isEmpty)
    XCTAssertEqual(documents[0].text, f.document.text)
    let retained = try f.store.vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: generation.attemptID)
    XCTAssertEqual(retained.progress.text, partial.text)
    let receipt = try f.store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: generation.attemptID)
    XCTAssertEqual(receipt.tokenIDs, partial.tokenIDs)
  }
  func testPassphraseBackupRetainsUnfinishedJournalsAndRestoresUnderAnotherVaultKey() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.checkpoint(progress(), identity: f.consultation, stopReason: nil)
    try await f.store.checkpoint(progress(), identity: f.writing, stopReason: nil)
    let backup = f.root.appendingPathComponent("explicit.bloombackup")
    try await f.store.exportBackup(passphrase: "public test passphrase", to: backup)
    let target = f.root.appendingPathComponent("restore")
    let restored = try WorkspaceStore(rootOverride: target, testKey: SymmetricKey(size: .bits256))
    try WorkspaceBackup.restore(from: backup, passphrase: "public test passphrase", into: restored.vault)
    let (state, _) = try await restored.load().get()
    XCTAssertEqual(state.chats[0].messages[0].text, progress().text)
    let restoredJournal = try restored.vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: f.writing.attemptID)
    XCTAssertEqual(restoredJournal.identity, f.writing)
    XCTAssertEqual(restoredJournal.progress.tokenIDs, progress().tokenIDs)
    XCTAssertNil(try Data(contentsOf: backup).range(of: Data(progress().text.utf8)))
    let wrong = try Vault(root: f.root.appendingPathComponent("wrong-passphrase"), testKey: SymmetricKey(size: .bits256))
    do {
      try WorkspaceBackup.restore(from: backup, passphrase: "wrong test passphrase", into: wrong)
      XCTFail("Wrong backup passphrase was admitted")
    } catch {}
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: wrong.root.path).isEmpty)
  }
}
