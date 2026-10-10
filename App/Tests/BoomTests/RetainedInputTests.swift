import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class RetainedInputTests: XCTestCase {
  private func store() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-retained-input-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
  }

  @MainActor func testRestoredDraftNeverRetainsConsultationEditingAuthority() async throws {
    let ownerKinds = try ProductCore.layout().isAuthor ? [false, true] : [true]
    for chatOwner in ownerKinds {
      let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
      if chatOwner { try model.newChat(about: model.state.selectedDocument) }
      let first = try XCTUnwrap(chatOwner ? model.state.selectedChat : model.state.selectedDocument)
      let text = "An unsent request for its original owner."
      model.draft = text; model.mode = .edit
      if chatOwner { try model.newChat() } else { try model.newDocument() }
      XCTAssertEqual(model.mode, .ask)
      if chatOwner { model.selectChat(first) } else { model.selectDocument(first) }
      XCTAssertEqual(model.draft, text)
      XCTAssertEqual(model.mode, .ask, "Switching restores input, not an earlier editing grant")
      model.mode = .edit
      try await model.shutdown()
      let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
      XCTAssertEqual(reopened.draft, text)
      XCTAssertEqual(reopened.mode, .ask, "Restart requires a fresh editing-mode selection")
      XCTAssertTrue(reopened.state.chats.allSatisfy { $0.messages.isEmpty })
      XCTAssertFalse(reopened.isBusy)
      try await reopened.shutdown()
    }
  }

  @MainActor func testChatDraftsKeepTheirOwnerAcrossSwitchAndRestart() async throws {
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try model.newChat()
    let first = try XCTUnwrap(model.state.selectedChat)
    let text = "Café 👩🏽‍🚀 — unfinished question\n<3 forever"
    model.draft = text; model.mode = .propose
    try model.newChat()
    let second = try XCTUnwrap(model.state.selectedChat)
    XCTAssertEqual(model.draft, "")
    model.draft = "Another conversation's unfinished question."
    model.selectChat(first)
    XCTAssertEqual(model.draft, text)
    XCTAssertEqual(model.mode, .ask)
    model.selectChat(second)
    XCTAssertEqual(model.draft, "Another conversation's unfinished question.")
    model.selectChat(first)
    model.mode = .propose
    try await model.shutdown()
    let sealed = try Data(contentsOf: store.vault.recordURL(.workspace, Vault.workspaceID))
    XCTAssertNil(sealed.range(of: Data(text.utf8)))
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(reopened.draft, text)
    XCTAssertEqual(reopened.mode, .ask)
    XCTAssertTrue(reopened.state.chats.allSatisfy { $0.messages.isEmpty })
    XCTAssertFalse(reopened.isBusy); XCTAssertFalse(reopened.modelReady)
    try await reopened.shutdown()
  }

  @MainActor func testUnsentDocumentDraftDoesNotMoveToAnotherManuscript() async throws {
    guard try ProductCore.layout().isAuthor else { throw XCTSkip("The chat edition has no manuscript composer.") }
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let first = try XCTUnwrap(model.state.selectedDocument)
    model.draft = "Question about the first manuscript."
    try model.newDocument()
    let second = try XCTUnwrap(model.state.selectedDocument)
    XCTAssertEqual(model.draft, "")
    model.draft = "Question about the second manuscript."
    model.selectDocument(first)
    XCTAssertEqual(model.draft, "Question about the first manuscript.")
    model.selectDocument(second)
    XCTAssertEqual(model.draft, "Question about the second manuscript.")
    try await model.shutdown()
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(reopened.state.selectedChat, nil)
    XCTAssertEqual(reopened.draft, "Question about the second manuscript.")
    XCTAssertTrue(reopened.state.chats.isEmpty)
    try await reopened.shutdown()
  }

  @MainActor func testWritingExampleOrderSurvivesRestartWithoutStartingGeneration() async throws {
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.state.selectedDocument == nil { try model.newDocument() }
    let manuscript = try XCTUnwrap(model.state.selectedDocument)
    try model.addWritingExample(title: "Lantern", prose: "The lantern crosses the harbor.", manuscriptID: manuscript)
    try model.addWritingExample(title: "Window", prose: "The window holds a pale reflection.", manuscriptID: manuscript)
    try model.addWritingExample(title: "Letter", prose: "A folded letter waits on the table.", manuscriptID: manuscript)
    let ids = model.writingExampleIDs
    model.moveWritingExample(ids[1], by: -1)
    let ordered = [ids[1], ids[0], ids[2]]
    XCTAssertEqual(model.writingExampleIDs, ordered)
    try await model.shutdown()
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(reopened.writingExampleIDs, ordered)
    XCTAssertTrue(ordered.allSatisfy { id in reopened.documents.contains { $0.id == id } })
    XCTAssertNil(reopened.candidates); XCTAssertFalse(reopened.isBusy)
    XCTAssertFalse(reopened.showingCandidates)
    try await reopened.shutdown()
  }

  @MainActor func testIntentionalAuthoredSendClearsOnlyThatDraft() async throws {
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try model.newChat()
    let other = try XCTUnwrap(model.state.selectedChat)
    model.draft = "Keep this other draft."
    try model.newChat()
    let sent = try XCTUnwrap(model.state.selectedChat)
    model.authorChatMessage(.user); model.draft = "An intentionally authored message."; model.send()
    XCTAssertEqual(model.draft, "")
    XCTAssertEqual(model.selectedChat?.messages.map(\.text), ["An intentionally authored message."])
    try await model.shutdown()
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(reopened.state.selectedChat, sent); XCTAssertEqual(reopened.draft, "")
    reopened.selectChat(other)
    XCTAssertEqual(reopened.draft, "Keep this other draft.")
    XCTAssertTrue(reopened.selectedChat?.messages.isEmpty == true)
    try await reopened.shutdown()
  }

  @MainActor func testEncryptedBackupRestoresDraftAndOrderedExamples() async throws {
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.state.selectedDocument == nil { try model.newDocument() }
    let manuscript = try XCTUnwrap(model.state.selectedDocument)
    try model.addWritingExample(title: "Public prose", prose: "Rain follows the ferry upstream.", manuscriptID: manuscript)
    let examples = model.writingExampleIDs
    try model.newChat(); model.draft = "An unfinished question kept in the backup."
    try await model.shutdown()
    let backup = store.root.appendingPathComponent("Public.bloombackup")
    try await store.exportBackup(passphrase: "Public fixture passphrase.", to: backup)
    let restoredStore = try self.store()
    _ = try await restoredStore.restoreBackup(passphrase: "Public fixture passphrase.", from: backup)
    let reopened = try await WorkspaceModel(storeOverride: restoredStore, loadModels: false)
    XCTAssertEqual(reopened.draft, "An unfinished question kept in the backup.")
    XCTAssertEqual(reopened.writingExampleIDs, examples)
    XCTAssertTrue(reopened.selectedChat?.messages.isEmpty == true)
    XCTAssertFalse(reopened.isBusy)
    try await reopened.shutdown()
  }

  @MainActor func testLegacyWorkspaceWithNoRetentionFieldsOpensWithoutImplicitActions() async throws {
    let store = try store()
    let document = DocumentSnapshot(title: "Legacy manuscript", text: "Previously saved authored prose.")
    var state = WorkspaceState()
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let bytes = try store.vault.get(.workspace, id: Vault.workspaceID)
    let legacy = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
    XCTAssertNil(legacy["composerDrafts"]); XCTAssertNil(legacy["writingExampleIDs"])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(model.selectedDocument, document); XCTAssertEqual(model.draft, "")
    XCTAssertTrue(model.writingExampleIDs.isEmpty)
    XCTAssertEqual(model.state.chats.count, model.layout.isAuthor ? 0 : 1)
    XCTAssertTrue(model.state.chats.allSatisfy { $0.messages.isEmpty })
    XCTAssertFalse(model.isBusy)
    try await model.shutdown()
  }

  func testInconsistentRetainedOwnerCannotBeReassignedAndCiphertextIsRetained() async throws {
    let store = try store()
    let chat = ChatRecord()
    var state = WorkspaceState(); state.chats = [chat]; state.selectedChat = chat.id
    state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .chat, id: UUID()),
      text: "This has a different owner.", attachments: [], authoredRole: nil)]
    try store.vault.encode(state, kind: .workspace, id: Vault.workspaceID)
    let file = store.vault.recordURL(.workspace, Vault.workspaceID), before = try Data(contentsOf: file)
    switch await store.load() {
    case .success: XCTFail("An absent owner was reassigned")
    case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("ownership"))
    }
    XCTAssertEqual(try Data(contentsOf: file), before)
  }

  func testInvalidRetainedStateRejectsRecoveryBeforeAnyDocumentRepair() async throws {
    let store = try store(), document = DocumentSnapshot(title: "Preserved", text: "Last admitted text.")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
    try await store.save(state, documents: [document])
    let file = store.documentURL(document.id), before = try Data(contentsOf: file)
    state.writingExampleIDs = [document.id, document.id]
    let replacement = DocumentSnapshot(id: document.id, title: document.title, text: "Not yet admitted.")
    try store.vault.encode(WorkspaceStore.SaveJournal(schema: 1, state: state, documents: [replacement],
      before: [document.id: document.revision]), kind: .saveJournal, id: Vault.workspaceID)
    let journal = store.vault.recordURL(.saveJournal, Vault.workspaceID), evidence = try Data(contentsOf: journal)
    switch await store.load() {
    case .success: XCTFail("Inconsistent selection admitted during recovery")
    case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("selection"))
    }
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(try Data(contentsOf: journal), evidence)
  }
}
