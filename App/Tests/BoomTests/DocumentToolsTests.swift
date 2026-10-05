import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class DocumentToolsTests: XCTestCase {
  @MainActor func testResponseCompletesOnlyAfterAValidatedEditAndPreservesUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-edit-response-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedDocument == nil { try model.newDocument() }
    let document = try XCTUnwrap(model.selectedDocument)
    model.updateDocument("A quiet beginning.", id: document.id, caret: 0)
    try model.newChat(about: document.id)
    let captured = try XCTUnwrap(model.selectedDocument), chatID = try XCTUnwrap(model.state.selectedChat)
    let pending = ChatMessage(role: .assistant, text: "", state: .pending)
    let chatIndex = try XCTUnwrap(model.state.chats.firstIndex { $0.id == chatID })
    model.state.chats[chatIndex].messages.append(pending)
    let authority = CapturedDocumentAuthority(mode: .edit, target: captured)
    let bad = AssistantEnvelope(reply: "Claimed edit.", edits: [patch(captured, [Replacement(old: "missing", new: "Wrong.")])])
    do {
      _ = try await model.finishConsultationResponse(String(decoding: JSONEncoder().encode(bad), as: UTF8.self),
        pending: pending, chatID: chatID, authority: authority, documentSources: [], attachments: [])
      XCTFail("Invalid edits must fail.")
    } catch {}
    XCTAssertEqual(model.selectedDocument?.text, captured.text)
    XCTAssertEqual(model.selectedChat?.messages.last?.state, .pending)
    XCTAssertTrue(model.state.proposals.isEmpty)
    let envelope = AssistantEnvelope(reply: "Here is the new beginning.", edits: [patch(captured, [Replacement(old: captured.text, new: "A brighter beginning.")])])
    let result = try await model.finishConsultationResponse(String(decoding: JSONEncoder().encode(envelope), as: UTF8.self),
      pending: pending, chatID: chatID, authority: authority, documentSources: [], attachments: [])
    XCTAssertEqual(result.state, .complete)
    XCTAssertEqual(model.selectedDocument?.text, "A brighter beginning.")
    XCTAssertEqual(model.state.proposals.last?.status, "applied")
    let persisted = try await store.load().get()
    XCTAssertEqual(persisted.1.first { $0.id == captured.id }?.text, "A brighter beginning.")
    model.undoManager(captured.id).undo()
    XCTAssertEqual(model.selectedDocument?.text, captured.text)
    try await model.shutdown()
  }
  func testActualCompiledPromptCarriesReadOnlyOrCapturedToolPermission() throws {
    let document = DocumentSnapshot(title: "Chapter", text: "Original.")
    let ask = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: "",
      request: "Edit my document.", routing: [])
    XCTAssertTrue(ask.rawPrompt.contains("Ask (read only)")); XCTAssertTrue(ask.rawPrompt.contains("Never claim"))
    let edit = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: document.text,
      request: "Edit my document.", routing: [], authority: CapturedDocumentAuthority(mode: .edit, target: document))
    XCTAssertTrue(edit.rawPrompt.contains(document.id.uuidString.lowercased()))
    XCTAssertTrue(edit.rawPrompt.contains(document.revision)); XCTAssertTrue(edit.rawPrompt.contains("actual replacement text"))
  }
  private func patch(_ d: DocumentSnapshot, _ rs: [Replacement]) -> DocumentPatch {
    DocumentPatch(documentID: d.id, revision: d.revision, replacements: rs)
  }
  func testAtomicReplacements() throws {
    let d = DocumentSnapshot(title: "T", text: "one two three")
    let g = DocumentGrant(mode: .propose, snapshot: DocumentSnapshot(title: "wrong", text: ""))
    XCTAssertThrowsError(
      try DocumentTools.apply(patch(d, [Replacement(old: "one", new: "1")]), grant: g, current: d))
    let p = patch(d, [Replacement(old: "one", new: "1"), Replacement(old: "three", new: "3")])
    XCTAssertEqual(
      try DocumentTools.apply(p, grant: DocumentGrant(mode: .edit, snapshot: d), current: d).text,
      "1 two 3")
  }
  func testStaleRejected() {
    let d = DocumentSnapshot(title: "T", text: "old")
    let changed = DocumentSnapshot(id: d.id, title: "T", text: "old ")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "old", new: "new")]),
        grant: DocumentGrant(mode: .edit, snapshot: d), current: changed))
  }
  func testAskCannotEdit() {
    let d = DocumentSnapshot(title: "T", text: "old")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "old", new: "new")]),
        grant: DocumentGrant(mode: .ask, snapshot: d), current: d))
  }
  func testAmbiguousRejected() {
    let d = DocumentSnapshot(title: "T", text: "aa aa")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "aa", new: "b")]),
        grant: DocumentGrant(mode: .edit, snapshot: d), current: d))
  }
  func testOverlappingOccurrencesRejected() {
    let d = DocumentSnapshot(title: "T", text: "aaa")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "aa", new: "b")]),
        grant: DocumentGrant(mode: .edit, snapshot: d), current: d))
  }
  func testOverlappingEditsRejected() {
    let d = DocumentSnapshot(title: "T", text: "abcdef")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "abc", new: "x"), Replacement(old: "cde", new: "y")]),
        grant: DocumentGrant(mode: .edit, snapshot: d), current: d))
  }
  func testEmptyDocumentInsertion() throws {
    let d = DocumentSnapshot(title: "T", text: "")
    XCTAssertEqual(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "", new: "hello")]),
        grant: DocumentGrant(mode: .propose, snapshot: d), current: d
      ).text, "hello")
  }
  func testEmptyAnchorForbidden() {
    let d = DocumentSnapshot(title: "T", text: "a")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "", new: "x")]), grant: DocumentGrant(mode: .edit, snapshot: d),
        current: d))
  }
  func testEditCannotSplitGrapheme() {
    let d = DocumentSnapshot(title: "T", text: "e\u{301}")
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch(d, [Replacement(old: "e", new: "x")]), grant: DocumentGrant(mode: .edit, snapshot: d),
        current: d))
  }
  func testStrictEnvelope() throws {
    XCTAssertEqual(try AssistantEnvelope.decode("{\"reply\":\"hi\",\"edits\":[]}").reply, "hi")
    XCTAssertThrowsError(
      try AssistantEnvelope.decode("```json\n{\"reply\":\"hi\",\"edits\":[]}\n```"))
    XCTAssertThrowsError(
      try AssistantEnvelope.decode("{\"reply\":\"hi\",\"edits\":[],\"shell\":\"ls\"}"))
  }
  func testMalformedEditNeverPartiallyApplies() {
    let original = DocumentSnapshot(title: "Text", text: "alpha beta")
    let patch = DocumentPatch(
      documentID: original.id, revision: original.revision,
      replacements: [Replacement(old: "alpha", new: "A"), Replacement(old: "missing", new: "B")])
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch, grant: DocumentGrant(mode: .edit, snapshot: original), current: original))
    XCTAssertEqual(original.text, "alpha beta")
  }
  func testLiteralHTMLCanBeAnExactEditAnchor() throws {
    let original = DocumentSnapshot(title: "Text", text: "<aside>Old</aside>")
    let patch = DocumentPatch(
      documentID: original.id, revision: original.revision,
      replacements: [Replacement(old: "<aside>Old</aside>", new: "<aside>New</aside>")])
    XCTAssertEqual(
      try DocumentTools.apply(
        patch, grant: DocumentGrant(mode: .edit, snapshot: original), current: original
      ).text, "<aside>New</aside>")
  }
}
