import BoomCore
import XCTest
@testable import Boom

final class GenerationJournalTests: XCTestCase {
  private struct Fixture {
    let root: URL
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
    let store = try WorkspaceStore(rootOverride: root)
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
    try await PagedFileEngineControlOutputs.seed(store, documents: [document])
    try await store.saveState(state)
    return Fixture(root: root, store: store, chat: chat, receipt: receipt, bundle: bundle,
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
  func testLiveInterruptionPreservesDurableCompletionAndPartialRows() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.checkpoint(progress("Finished 👩🏽‍💻"), identity: f.writing, stopReason: "output_limit")
    let journal = try await f.store.writingCheckpoint(bundle: f.bundle, candidate: f.bundle.candidates[0])
    var candidate = f.bundle.candidates[0]
    candidate.finishInterrupted(journal, reason: "cancelled")
    XCTAssertEqual(candidate.state, .complete); XCTAssertEqual(candidate.stopReason, "output_limit")
    XCTAssertEqual(candidate.text, "Finished 👩🏽‍💻"); XCTAssertEqual(candidate.tokenIDs, [1, 2])
    let finished = candidate
    candidate.finishInterrupted(nil, failed: true, reason: "failed")
    XCTAssertEqual(candidate.state, finished.state); XCTAssertEqual(candidate.text, finished.text)
    XCTAssertEqual(candidate.tokenIDs, finished.tokenIDs); XCTAssertEqual(candidate.stopReason, finished.stopReason)
    var partial = f.bundle.candidates[0]
    let checkpoint = GenerationCheckpoint(schema: 1, identity: f.writing, progress: progress(), stopReason: nil)
    partial.finishInterrupted(checkpoint, reason: "cancelled")
    XCTAssertEqual(partial.state, .cancelled); XCTAssertEqual(partial.text, checkpoint.progress.text)
    XCTAssertEqual(partial.tokenIDs, checkpoint.progress.tokenIDs)
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
    let fresh = try WorkspaceStore(rootOverride: f.root)
    _ = try await fresh.loadState()
    let documents = try await NativeCheckEvidence.readPublicDocuments(store: fresh)
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
    do { _ = try await fresh.loadState(); XCTFail("Changed batch shape was admitted") } catch {}
    XCTAssertEqual(try Data(contentsOf: candidateURL), before)
  }
  func testFreshStoreRecoversOnlyDurableTokensAndKeepsManuscriptAndSpeaker() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let checkpoint = progress()
    try await f.store.checkpoint(checkpoint, identity: f.consultation, stopReason: nil)
    try await f.store.checkpoint(checkpoint, identity: f.writing, stopReason: nil)
    let fresh = try WorkspaceStore(rootOverride: f.root)
    let state = try await fresh.loadState()
    let documents = try await NativeCheckEvidence.readPublicDocuments(store: fresh)
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
    let second = try await fresh.loadState()
    XCTAssertEqual(second.chats[0].messages[0].text, checkpoint.text)
  }
  func testStoppingIdentitySurvivesFileInterruptionAndWrongTokenRetainsBytes() async throws {
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
    let fresh = try WorkspaceStore(rootOverride: f.root)
    _ = try await fresh.loadState()
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
  func testPrefillGeometrySurvivesEncryptedRecoveryAndCannotBeChanged() async throws {
    let small = try ProductCore.generationPolicy(vocabularySize: 16,
      configuration: Data(#"{"eos_token_id":1,"suppress_tokens":[15,14]}"#.utf8),
      controls: [0, 1, 3, 14, 15], tokenizerEOS: 1)
    XCTAssertEqual(small.prefill, PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512))
    for ceiling in [UInt32(256), UInt32(1024)] {
      let alternate = try ProductCore.generationPolicy(vocabularySize: 16,
        configuration: Data(#"{"eos_token_id":1,"suppress_tokens":[15,14]}"#.utf8),
        controls: [0, 1, 3, 14, 15], tokenizerEOS: 1, prefillTokens: ceiling)
      let f = try await fixture(alternate); defer { try? FileManager.default.removeItem(at: f.root) }
      try await f.store.checkpoint(progress(tokens: [4, 5]), identity: f.writing, stopReason: "cancelled")
      let url = f.store.vault.recordURL(.generationJournal, f.writing.attemptID)
      let before = try Data(contentsOf: url)
      let fresh = try WorkspaceStore(rootOverride: f.root)
      _ = try await fresh.loadState()
      let recovered = try await fresh.generationCheckpoint(identity: f.writing)
      let journal = try XCTUnwrap(recovered)
      XCTAssertEqual(journal.identity.generationPolicy?.prefill,
        PrefillGeometry(chunking: "fixed_v1", tokenCeiling: Int(ceiling)))
      try ProductCore.admitGenerationPolicy(alternate, loaded: alternate)
      XCTAssertThrowsError(try ProductCore.admitGenerationPolicy(alternate, loaded: small))
      var unrecorded = small; unrecorded.prefill = nil
      XCTAssertThrowsError(try ProductCore.admitGenerationPolicy(unrecorded, loaded: small))
      let changed = GenerationIdentity(kind: f.writing.kind, operationID: f.writing.operationID,
        recordID: f.writing.recordID, attemptID: f.writing.attemptID, model: f.writing.model,
        seed: f.writing.seed, requestDigest: f.writing.requestDigest, maxTokens: f.writing.maxTokens,
        generationPolicy: small)
      do { _ = try await fresh.generationCheckpoint(identity: changed); XCTFail("Changed prefill geometry was accepted") }
      catch {}
      XCTAssertEqual(try Data(contentsOf: url), before)
    }
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
    do { _ = try await f.store.loadState(); XCTFail("Corrupted checkpoint was admitted") } catch {}
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
    let state = try await f.store.loadState()
    let documents = try await NativeCheckEvidence.readPublicDocuments(store: f.store)
    XCTAssertEqual(state.chats[0].messages[0].text, "")
    XCTAssertEqual(state.chats[0].messages[0].state, .cancelled)
    XCTAssertTrue(state.proposals.isEmpty)
    XCTAssertEqual(documents[0].text, f.document.text)
    let retained = try f.store.vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: generation.attemptID)
    XCTAssertEqual(retained.progress.text, partial.text)
    let receipt = try f.store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: generation.attemptID)
    XCTAssertEqual(receipt.tokenIDs, partial.tokenIDs)
  }
  func testDirectoryBackupRetainsExactUnfinishedJournals() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.checkpoint(progress(), identity: f.consultation, stopReason: nil)
    try await f.store.checkpoint(progress(), identity: f.writing, stopReason: nil)
    let backup = f.root.deletingLastPathComponent().appendingPathComponent("public-journal-backup-" + UUID().uuidString)
    let target = f.root.deletingLastPathComponent().appendingPathComponent("public-journal-restore-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: target) }
    let before = try Data(contentsOf: f.store.vault.recordURL(.generationJournal, f.writing.attemptID))
    try await f.store.exportBackup(to: backup)
    let restored = try WorkspaceStore(rootOverride: target)
    try await restored.restoreBackup(from: backup)
    XCTAssertEqual(try Data(contentsOf: restored.vault.recordURL(.generationJournal, f.writing.attemptID)), before)
    let state = try await restored.loadState()
    XCTAssertEqual(state.chats[0].messages[0].text, progress().text)
    let journal = try restored.vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: f.writing.attemptID)
    XCTAssertEqual(journal.identity, f.writing); XCTAssertEqual(journal.progress.tokenIDs, progress().tokenIDs)
  }
  func testColdAndWarmOriginsRecoverFromTerminalCheckpointsBeforeFinalRecordSave() async throws {
    for cached in [0, 7] {
      let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
      let origin = GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "resident-hybrid-prefix-v3",
        cachedPromptTokens: cached, cacheMissReason: cached == 0 ? "no_owner" : nil)
      var observed = progress("Complete Cafe\u{301} 👩🏽‍💻")
      observed.executionOrigin = origin
      try await f.store.checkpoint(observed, identity: f.writing, stopReason: "output_limit")
      try await f.store.checkpoint(observed, identity: f.consultation, stopReason: nil)
      let fresh = try WorkspaceStore(rootOverride: f.root)
      _ = try await fresh.loadState()
      let bundle = try fresh.vault.decode(CandidateBundle.self, kind: .candidate, id: f.bundle.id)
      let receipt = try fresh.vault.decode(ConsultationReceipt.self, kind: .receipt, id: f.consultation.recordID)
      XCTAssertEqual(bundle.candidates[0].state, .complete)
      XCTAssertEqual(bundle.candidates[0].executionOrigin, origin)
      XCTAssertEqual(receipt.executionOrigin, origin)
      XCTAssertEqual(Data(bundle.candidates[0].text.utf8), Data(observed.text.utf8))
      XCTAssertEqual(bundle.candidates[0].executionOrigin?.isConfirmedCold(promptTokens: 12), cached == 0)
    }
  }
  func testOriginCannotBeRewrittenDowngradedOrInventedWithoutRetainingTheEncryptedJournal() async throws {
    for initial in [nil, GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "resident-hybrid-prefix-v3",
      cachedPromptTokens: 7, cacheMissReason: nil)] as [GenerationExecutionOrigin?] {
      let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
      var before = progress(); before.executionOrigin = initial
      try await f.store.checkpoint(before, identity: f.writing, stopReason: nil)
      let path = f.store.vault.recordURL(.generationJournal, f.writing.attemptID)
      let ciphertext = try Data(contentsOf: path)
      var after = progress("Continues", tokens: [1, 2, 3], elapsed: 2)
      after.executionOrigin = GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "resident-hybrid-prefix-v3",
        cachedPromptTokens: 0, cacheMissReason: "no_owner")
      do { try await f.store.checkpoint(after, identity: f.writing, stopReason: nil)
        XCTFail("Invented or rewritten origin was admitted") } catch {}
      XCTAssertEqual(try Data(contentsOf: path), ciphertext)
      if initial != nil {
        after.executionOrigin = nil
        do { try await f.store.checkpoint(after, identity: f.writing, stopReason: nil)
          XCTFail("Origin downgrade was admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), ciphertext)
      }
    }
  }
  func testFinalCandidateOriginMustAgreeWithItsAdmittedCheckpoint() async throws {
    let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    var observed = progress()
    observed.executionOrigin = GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "resident-hybrid-prefix-v3",
      cachedPromptTokens: 7, cacheMissReason: nil)
    try await f.store.checkpoint(observed, identity: f.writing, stopReason: "output_limit")
    var forged = f.bundle
    forged.candidates[0].state = .complete
    forged.candidates[0].retain(observed)
    forged.candidates[0].executionOrigin = GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "resident-hybrid-prefix-v3",
      cachedPromptTokens: 0, cacheMissReason: "no_owner")
    try f.store.vault.encode(forged, kind: .candidate, id: forged.id)
    let path = f.store.vault.recordURL(.candidate, forged.id), ciphertext = try Data(contentsOf: path)
    do { _ = try await f.store.loadState(); XCTFail("Contradictory origin was admitted") } catch {}
    XCTAssertEqual(try Data(contentsOf: path), ciphertext)
  }

}
