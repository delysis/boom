import BoomCore
import XCTest
@testable import Boom

final class RetainedInputTests: XCTestCase {
  private func store() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-retained-input-" + UUID().uuidString)
    let originalFailures = testRun?.failureCount ?? 0
    addTeardownBlock { [weak self] in
      guard self?.testRun?.failureCount == originalFailures else { return }
      try FileManager.default.removeItem(at: root)
    }
    return try WorkspaceStore(rootOverride: root)
  }

  @MainActor func testRestoredDraftNeverRetainsConsultationEditingAuthority() async throws {
    let ownerKinds = try ProductCore.layout().isAuthor ? [false, true] : [true]
    for chatOwner in ownerKinds {
      let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
      if chatOwner { try model.newChat(about: model.state.selectedDocument) }
      let first = try XCTUnwrap(chatOwner ? model.state.selectedChat : model.state.selectedDocument)
      let text = "An unsent request for its original owner."
      model.draft = text; model.mode = .edit
      if chatOwner { try model.newChat() }
      else { try model.newDocument(); try await model.joinWorkspaceOperation() }
      XCTAssertEqual(model.mode, .ask)
      if chatOwner { model.selectChat(first) }
      else { model.selectDocument(first); try await model.joinWorkspaceOperation() }
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
    try await model.joinWorkspaceOperation()
    let second = try XCTUnwrap(model.state.selectedDocument)
    XCTAssertEqual(model.draft, "")
    model.draft = "Question about the second manuscript."
    model.selectDocument(first)
    try await model.joinWorkspaceOperation()
    XCTAssertEqual(model.draft, "Question about the first manuscript.")
    model.selectDocument(second)
    try await model.joinWorkspaceOperation()
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
    if model.state.selectedDocument == nil {
      try model.newDocument(); try await model.joinWorkspaceOperation()
    }
    let manuscript = try XCTUnwrap(model.state.selectedDocument)
    try await model.addWritingExample(title: "Lantern", prose: "The lantern crosses the harbor.", manuscriptID: manuscript)
    try await model.addWritingExample(title: "Window", prose: "The window holds a pale reflection.", manuscriptID: manuscript)
    try await model.addWritingExample(title: "Letter", prose: "A folded letter waits on the table.", manuscriptID: manuscript)
    let ids = model.writingExampleIDs
    model.moveWritingExample(ids[1], by: -1)
    let ordered = [ids[1], ids[0], ids[2]]
    XCTAssertEqual(model.writingExampleIDs, ordered)
    try await model.shutdown()
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(reopened.writingExampleIDs, ordered)
    XCTAssertTrue(ordered.allSatisfy { id in reopened.documentIndices.contains { $0.id == id } })
    let expected = Dictionary(uniqueKeysWithValues: zip(ids, [
      "The lantern crosses the harbor.", "The window holds a pale reflection.", "A folded letter waits on the table."
    ]))
    for id in ordered {
      let source = try await reopened.previewDocument(id)
      XCTAssertEqual(source.documentID, id)
      XCTAssertEqual(Data(source.window.text.utf8), Data(try XCTUnwrap(expected[id]).utf8),
        "Each restored example must still resolve to its exact authored logical source, not only a catalog row.")
    }
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

  @MainActor func testFileBackupRestoresDraftAndOrderedExamples() async throws {
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.state.selectedDocument == nil {
      try model.newDocument(); try await model.joinWorkspaceOperation()
    }
    let manuscript = try XCTUnwrap(model.state.selectedDocument)
    try await model.addWritingExample(title: "Public prose", prose: "Rain follows the ferry upstream.", manuscriptID: manuscript)
    let examples = model.writingExampleIDs
    try model.newChat(); model.draft = "An unfinished question kept in the backup."
    try await model.shutdown()
    let backup = store.root.deletingLastPathComponent().appendingPathComponent("public-draft-backup-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: backup) }
    try await store.exportBackup(to: backup)
    let restoredStore = try self.store()
    _ = try await restoredStore.restoreBackup(from: backup)
    let reopened = try await WorkspaceModel(storeOverride: restoredStore, loadModels: false)
    XCTAssertEqual(reopened.draft, "An unfinished question kept in the backup.")
    XCTAssertEqual(reopened.writingExampleIDs, examples)
    XCTAssertTrue(reopened.selectedChat?.messages.isEmpty == true)
    XCTAssertFalse(reopened.isBusy)
    try await reopened.shutdown()
  }

  func testInconsistentRetainedOwnerCannotBeReassignedAndMetadataIsRetained() async throws {
    let store = try store()
    let chat = ChatRecord()
    var state = WorkspaceState(); state.chats = [chat]; state.selectedChat = chat.id
    state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .chat, id: UUID()),
      text: "This has a different owner.", attachments: [], authoredRole: nil)]
    try store.vault.encode(state, kind: .workspace, id: Vault.workspaceID)
    let file = store.vault.recordURL(.workspace, Vault.workspaceID), before = try Data(contentsOf: file)
    do { _ = try await store.loadState(); XCTFail("An absent owner was reassigned") }
    catch { XCTAssertTrue(error.localizedDescription.contains("ownership")) }
    XCTAssertEqual(try Data(contentsOf: file), before)
  }

}
