import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class VaultTests: XCTestCase {
  func testInjectedSessionIsSharedByStoresAndCannotSelectProductionNamespace() async throws {
    let id = UUID()
    XCTAssertEqual(VaultSession.qualificationService(id), "com.delysis.Bloom.qualification." + id.uuidString)
    let session = VaultSession(loader: { _ in SymmetricKey(size: .bits256) })
    let first = try WorkspaceStore(rootOverride: root(), session: session)
    let second = try WorkspaceStore(rootOverride: root(), session: session)
    let document = DocumentSnapshot(title: "Session fixture", text: "Public shared session")
    try first.vault.put(Data(document.text.utf8), kind: .document, id: document.id)
    let sibling = try first.vault.sibling(at: second.vault.root)
    try FileManager.default.copyItem(at: first.vault.recordURL(.document, document.id), to: sibling.recordURL(.document, document.id))
    XCTAssertEqual(try second.vault.get(.document, id: document.id), Data(document.text.utf8))
    XCTAssertEqual(session.lookupCount, 1)
  }
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func testPrivateDocumentsAndVoicesSurviveRelaunchWithoutPlaintext() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let document = DocumentSnapshot(title: "Confidential", text: "private-canary-é-🦋")
    let voice = try ProductCore.voice(VoiceDraft(slug: "sage", name: "Sage", instructions: "voice-canary", examples: [VoiceExchange(user: "Question", assistant: "Answer")]))
    var state = WorkspaceState()
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.voices = [voice]; state.voiceVersions = [voice]
    try await store.save(state, documents: [document])
    let relaunched = try WorkspaceStore(rootOverride: root, testKey: key)
    let restored = try await relaunched.load().get()
    XCTAssertEqual(restored.1, [document]); XCTAssertEqual(restored.0.voices, [voice])
    let files = try FileManager.default.contentsOfDirectory(at: store.vault.root, includingPropertiesForKeys: nil)
    for file in files {
      let bytes = try Data(contentsOf: file)
      XCTAssertNil(bytes.range(of: Data("private-canary".utf8)))
      XCTAssertNil(bytes.range(of: Data("voice-canary".utf8)))
    }
  }
  func testAuthenticatedIdentityWrongKeyAndCorruptionRetainRecords() throws {
    let root = try root(), id = UUID()
    let vault = try Vault(root: root, testKey: SymmetricKey(size: .bits256))
    try vault.put(Data("secret".utf8), kind: .attachment, id: id)
    let source = vault.recordURL(.attachment, id)
    try FileManager.default.copyItem(at: source, to: vault.recordURL(.receipt, id))
    XCTAssertThrowsError(try vault.get(.receipt, id: id))
    let wrong = try Vault(root: root, testKey: SymmetricKey(size: .bits256))
    XCTAssertThrowsError(try wrong.get(.attachment, id: id))
    var bytes = try Data(contentsOf: source); bytes[bytes.count - 1] ^= 1
    try bytes.write(to: source)
    XCTAssertThrowsError(try vault.get(.attachment, id: id))
    XCTAssertEqual(try Data(contentsOf: source), bytes)
  }
  func testCorruptIndexNeverBecomesEmptyWorkspace() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    try await store.save(WorkspaceState(), documents: [])
    let file = store.vault.recordURL(.workspace, Vault.workspaceID)
    var bytes = try Data(contentsOf: file); bytes[bytes.count - 1] ^= 1; try bytes.write(to: file)
    switch await store.load() {
    case .success: XCTFail("Corruption was replaced with empty state")
    case .failure: break
    }
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
  func testBackupRoundTripIncludesOriginalsAndReceiptsAndRejectsWrongPassphrase() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let doc = DocumentSnapshot(title: "Draft", text: "backup-canary")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: doc.id, title: doc.title)]
    try await store.save(state, documents: [doc])
    let original = UUID(), receipt = UUID()
    try store.vault.put(Data([0, 1, 2, 3]), kind: .attachment, id: original)
    try store.vault.put(Data("receipt-canary".utf8), kind: .receipt, id: receipt)
    let backup = root.appendingPathComponent("backup.bloombackup")
    try WorkspaceBackup.export(vault: store.vault, passphrase: "six violets by the sea", to: backup)
    XCTAssertNil(try Data(contentsOf: backup).range(of: Data("backup-canary".utf8)))
    let restored = try WorkspaceStore(rootOverride: root.appendingPathComponent("restored"), testKey: SymmetricKey(size: .bits256))
    XCTAssertThrowsError(try WorkspaceBackup.restore(from: backup, passphrase: "wrong-passphrase", into: restored.vault))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: restored.vault.root.path).isEmpty)
    try WorkspaceBackup.restore(from: backup, passphrase: "six violets by the sea", into: restored.vault)
    let loaded = try await restored.load().get()
    XCTAssertEqual(loaded.1, [doc])
    XCTAssertEqual(try restored.vault.get(.attachment, id: original), Data([0,1,2,3]))
    XCTAssertEqual(try restored.vault.get(.receipt, id: receipt), Data("receipt-canary".utf8))
    XCTAssertThrowsError(try WorkspaceBackup.restore(from: backup, passphrase: "six violets by the sea", into: restored.vault))
  }
  func testCompleteBackupRewrapsEveryRecordKindAndPreservesHistoryAndLineage() async throws {
    let root = try root(), store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let doc = DocumentSnapshot(title: "Original", text: "Confidential 🦋 manuscript.")
    let branch = DocumentSnapshot(title: "Branch", text: doc.text + " An authored test continuation.")
    let first = try ProductCore.voice(VoiceDraft(slug: "reader", name: "Reader", instructions: "Read attentively."))
    var edited = first.draft; edited.name = "Renamed reader"; edited.instructions = "Ask a question."
    let voice = try ProductCore.voice(edited)
    let answer = ChatMessage(role: .assistant, text: "An authored test answer.", speaker: first.speaker)
    var chat = ChatRecord(messages: [ChatMessage(role: .user, text: "A question."), answer], instructions: "Chat instructions.")
    chat.messageVersions = [ChatMessage(role: .assistant, text: "An earlier authored answer.", speaker: first.speaker)]
    let prompt = try ProductCore.writingPrompt(doc, caret: doc.text.utf16.count, examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: doc, caretUTF16: doc.text.utf16.count, sources: [],
      prompt: prompt.prompt, promptDigest: prompt.digest, omittedPrefixCharacters: 0, model: "unit-test-model",
      profile: .standard, settings: try ProductCore.sampling(.standard), maxTokens: 256, generationPolicy: nil)
    let candidate = WritingCandidate(id: UUID(), seed: 7, text: " An authored test continuation.", state: .complete,
      promptTokens: 4, outputTokens: 1, tokenIDs: [900], stopReason: "output_limit")
    let bundle = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [candidate], selected: 0)
    let plan = try ProductCore.prompt(voice: first, history: [], instructions: "", context: "", request: "A question.", routing: [])
    let receipt = ConsultationReceipt(operationID: UUID(), seed: 11, state: .complete, failure: nil,
      model: "unit-test-model", voice: first, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt),
      tokenIDs: [901], stopReason: "output_limit", firstTokenSeconds: nil, elapsedSeconds: 0, generationPolicy: nil)
    let original = Data("Confidential attachment original.\0".utf8), originalID = UUID(), proposalID = UUID()
    var state = WorkspaceState(); state.documents = [doc, branch].map { DocumentIndex(id: $0.id, title: $0.title) }
    state.chats = [chat]; state.voices = [voice]; state.voiceVersions = [first, voice]; state.candidateIDs = [bundle.id]
    state.manuscriptOrigins[branch.id] = ManuscriptOrigin(documentID: doc.id, revision: doc.revision,
      bundleID: bundle.id, candidateID: candidate.id)
    state.attachments = [AttachmentRecord(id: originalID, name: "Original.txt", rootDigest: Digest.sha256(original),
      text: "Confidential attachment original.", coverage: "complete")]
    try await store.save(state, documents: [doc, branch])
    try store.vault.put(original, kind: .attachment, id: originalID)
    try store.vault.put(Data("Public inspection receipt.".utf8), kind: .receipt, id: originalID)
    try store.vault.encode(bundle, kind: .candidate, id: bundle.id)
    try store.vault.encode(receipt, kind: .receipt, id: answer.id)
    try store.vault.encode(DocumentEditJournal(schema: 1, proposalID: proposalID, documentID: doc.id,
      beforeRevision: doc.revision, afterRevision: branch.revision, phase: "prepared"), kind: .editJournal, id: proposalID)
    try store.vault.encode(WorkspaceStore.SaveJournal(schema: 1, state: state, documents: [], before: [:]),
      kind: .saveJournal, id: Vault.workspaceID)
    let identities: [(Vault.Kind, UUID)] = [(.workspace, Vault.workspaceID), (.document, doc.id), (.document, branch.id),
      (.attachment, originalID), (.receipt, originalID), (.candidate, bundle.id), (.receipt, answer.id), (.editJournal, proposalID), (.saveJournal, Vault.workspaceID)]
    let backup = root.appendingPathComponent("complete.bloombackup")
    try WorkspaceBackup.export(vault: store.vault, passphrase: "six violets by the sea", to: backup)
    XCTAssertNil(try Data(contentsOf: backup).range(of: Data("Confidential".utf8)))
    let restored = try WorkspaceStore(rootOverride: root.appendingPathComponent("restored"), testKey: SymmetricKey(size: .bits256))
    try WorkspaceBackup.restore(from: backup, passphrase: "six violets by the sea", into: restored.vault)
    for (kind, id) in identities {
      XCTAssertEqual(try restored.vault.get(kind, id: id), try store.vault.get(kind, id: id))
      XCTAssertNotEqual(try Data(contentsOf: restored.vault.recordURL(kind, id)), try Data(contentsOf: store.vault.recordURL(kind, id)))
    }
    let loaded = try await restored.load().get()
    XCTAssertEqual(loaded.1, [doc, branch]); XCTAssertEqual(loaded.0.chats, [chat])
    XCTAssertEqual(loaded.0.voices, [voice]); XCTAssertEqual(loaded.0.voiceVersions, [first, voice])
    XCTAssertEqual(loaded.0.manuscriptOrigins[branch.id]?.candidateID, candidate.id)
    XCTAssertEqual(loaded.0.manuscriptOrigins[branch.id]?.revision, doc.revision)
  }
}
