import BoomCore
import AppKit
import SwiftUI
import XCTest
@testable import Boom

final class DocumentToolsTests: XCTestCase {
  @MainActor func testSuccessiveNativeEditsHaveSeparateUndoAndPreserveCaret() throws {
    _ = NSApplication.shared
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    let manager = UndoManager(); manager.groupsByEvent = false
    view.documentUndo = manager; view.allowsUndo = true
    let original = "The harbor was quiet. Human addition."
    view.string = original; view.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
    let base = DocumentSnapshot(title: "Public fixture", text: original)
    let first = try DocumentTools.plan(patch(base, [Replacement(old: "quiet", new: "bright")]),
      grant: DocumentGrant(mode: .edit, snapshot: base), current: base)
    view.replaceDocument(first.0.text, action: "First edit", edits: first.1)
    XCTAssertEqual(view.selectedRange().location, first.0.text.utf16.count)
    let second = try DocumentTools.plan(patch(first.0, [Replacement(old: "bright", new: "hushed")]),
      grant: DocumentGrant(mode: .edit, snapshot: first.0), current: first.0)
    view.replaceDocument(second.0.text, action: "Second edit", edits: second.1)
    XCTAssertEqual(view.string, second.0.text)
    manager.undo(); XCTAssertEqual(view.string, first.0.text)
    manager.undo(); XCTAssertEqual(view.string, original)
    manager.redo(); XCTAssertEqual(view.string, first.0.text)
  }
  @MainActor func testMountedEditorAppliesResponseAndUndoPreservesModelAndDisk() async throws {
    try await PagedNativeFixtureApplication.requireNativeKeyWindow()
    let (model, store, root, document, chatID, pending) = try await responseFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    guard model.layout.isAuthor else {
      try await model.shutdown()
      throw XCTSkip("The chat edition has no manuscript editor.")
    }
    let editor = try XCTUnwrap(model.pagedInput?.activeView)
    try await PagedNativeFixtureApplication.focus(editor, in: try XCTUnwrap(editor.window))
    XCTAssertEqual(editor.session.sourceBaseRevision.documentID, document.id); XCTAssertEqual(editor.string, document.text)
    let response = AssistantEnvelope(reply: "The replacement is included.",
      edits: [patch(document, [Replacement(old: "quiet", new: "bright")])])
    _ = try await model.finishConsultationResponse(
      String(decoding: JSONEncoder().encode(response), as: UTF8.self), pending: pending, chatID: chatID,
      authority: CapturedDocumentAuthority(mode: .edit, target: document, capture: try await model.captureDocument(document.id)), documentSources: [], attachments: [])
    let expected = document.text.replacingOccurrences(of: "quiet", with: "bright")
    XCTAssertEqual(editor.string, expected); XCTAssertEqual(model.selectedDocument?.text, expected)
    XCTAssertTrue(editor.isEditable)
    try await model.flush()
    let persisted = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
    XCTAssertEqual(persisted?.text, expected)
    XCTAssertTrue(editor.undoManager?.canUndo == true)
    editor.undoManager?.undo()
    try await model.pagedCommands?.joinPendingCommand()
    XCTAssertEqual(editor.string, document.text)
    try await model.flush()
    let undone = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
    XCTAssertEqual(undone, document)
    try await model.shutdown()
  }
  @MainActor func testEmptyEditResponsePreservesBytesAndReportsNoChanges() async throws {
    for mode in [InteractionMode.propose, .edit] {
      let (model, store, root, document, chatID, pending) = try await responseFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let response = AssistantEnvelope(reply: "The harbor is quiet.", edits: [])
      let answer = try await model.finishConsultationResponse(
        String(decoding: JSONEncoder().encode(response), as: UTF8.self), pending: pending, chatID: chatID,
        authority: CapturedDocumentAuthority(mode: mode, target: document, capture: try await model.captureDocument(document.id)), documentSources: [], attachments: [])
      XCTAssertEqual(answer.state, .complete)
      XCTAssertEqual(model.status, "No document changes")
      XCTAssertEqual(model.selectedDocument, document)
      XCTAssertTrue(model.state.proposals.isEmpty)
      XCTAssertFalse(try XCTUnwrap(model.pagedCommands).manager.canUndo)
      try await model.flush()
      let persisted = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
      XCTAssertEqual(persisted, document)
      try await model.shutdown()
    }
  }
  @MainActor func testProposalRequiresAcceptanceAndRetainsNativeHistory() async throws {
    let (model, store, root, document, chatID, pending) = try await responseFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = AssistantEnvelope(reply: "Here is a brighter harbor.",
      edits: [patch(document, [Replacement(old: "quiet", new: "bright")])])
    _ = try await model.finishConsultationResponse(
      String(decoding: JSONEncoder().encode(response), as: UTF8.self), pending: pending, chatID: chatID,
      authority: CapturedDocumentAuthority(mode: .propose, target: document, capture: try await model.captureDocument(document.id)), documentSources: [], attachments: [])
    let proposal = try XCTUnwrap(model.state.proposals.last)
    XCTAssertEqual(proposal.status, "pending")
    XCTAssertEqual(model.status, "Proposal ready for review")
    let persisted = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
    XCTAssertEqual(persisted, document)
    XCTAssertFalse(try XCTUnwrap(model.pagedCommands).manager.canUndo)
    model.accept(proposal.id)
    try await waitForResponse(model)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.status, "Document edited")
    let applied = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
    XCTAssertEqual(applied?.text, document.text.replacingOccurrences(of: "quiet", with: "bright"))
    XCTAssertEqual(model.state.proposals.last?.status, "applied")
    XCTAssertTrue(try XCTUnwrap(model.pagedCommands).manager.canUndo)
    try await model.shutdown()
  }
  @MainActor func testProposalMergesLaterAuthoredTextWithoutOverwritingIt() async throws {
    let (model, store, root, document, chatID, pending) = try await responseFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = AssistantEnvelope(reply: "A suggested change.",
      edits: [patch(document, [Replacement(old: "quiet", new: "bright")])])
    _ = try await model.finishConsultationResponse(
      String(decoding: JSONEncoder().encode(response), as: UTF8.self), pending: pending, chatID: chatID,
      authority: CapturedDocumentAuthority(mode: .propose, target: document, capture: try await model.captureDocument(document.id)), documentSources: [], attachments: [])
    let proposal = try XCTUnwrap(model.state.proposals.last)
    let authored = document.text + "\n\nLater text by the author."
    try await NativeCheckEvidence.replacePublicDocument(model, text: authored, id: document.id, caret: 0)
    try await model.flush()
    model.accept(proposal.id)
    try await waitForResponse(model)
    XCTAssertNil(model.errorMessage)
    let applied = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
    XCTAssertEqual(applied?.text, authored.replacingOccurrences(of: "quiet", with: "bright"))
    XCTAssertEqual(model.state.proposals.last?.status, "applied")
    let persisted = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == document.id }
    XCTAssertEqual(persisted?.text, authored.replacingOccurrences(of: "quiet", with: "bright"))
    try await model.shutdown()
  }
  @MainActor private func responseFixture() async throws
    -> (WorkspaceModel, WorkspaceStore, URL, DocumentSnapshot, UUID, ChatMessage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-response-outcome-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    let document = DocumentSnapshot(title: "Public response", text: "Café 👩🏽‍💻 waited.\n\nThe harbor was quiet.\n\nA final line.")
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [document])
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 640, height: 480))
    window.isReleasedWhenClosed = false; window.contentView = try XCTUnwrap(model.pagedViewport)
    window.showAsInvisibleNativeTestWindow(); XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(model.pagedInput?.activeView)))
    addTeardownBlock { await MainActor.run { window.close() } }
    try model.newChat(about: document.id)
    let chatID = try XCTUnwrap(model.state.selectedChat)
    let pending = ChatMessage(role: .assistant, text: "", state: .pending)
    let index = try XCTUnwrap(model.state.chats.firstIndex { $0.id == chatID })
    model.state.chats[index].messages.append(pending)
    try await model.flush()
    try XCTUnwrap(model.pagedCommands).manager.removeAllActions()
    return (model, store, root, document, chatID, pending)
  }
  @MainActor private func waitForResponse(_ model: WorkspaceModel) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.isBusy)
  }
  @MainActor func testResponseCompletesOnlyAfterAValidatedEditAndPreservesUndo() async throws {
    try await PagedNativeFixtureApplication.requireNativeKeyWindow()
    let (model, store, root, captured, chatID, firstPending) = try await responseFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatIndex = try XCTUnwrap(model.state.chats.firstIndex { $0.id == chatID })
    let authority = CapturedDocumentAuthority(mode: .edit, target: captured, capture: try await model.captureDocument(captured.id))
    let bad = AssistantEnvelope(reply: "Claimed edit.", edits: [patch(captured, [Replacement(old: "missing", new: "Wrong.")])])
    let rawBad = String(decoding: try JSONEncoder().encode(bad), as: UTF8.self)
    let failed = try await model.finishConsultationResponse(rawBad,
      pending: firstPending, chatID: chatID, authority: authority, documentSources: [], attachments: [])
    XCTAssertEqual(failed.state, .failed)
    XCTAssertEqual(failed.text, rawBad)
    XCTAssertNotNil(failed.failure)
    let unchanged = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == captured.id }
    XCTAssertEqual(unchanged?.text, captured.text)
    XCTAssertEqual(model.selectedChat?.messages.last?.state, .failed)
    XCTAssertTrue(model.state.proposals.isEmpty)
    let pending = ChatMessage(role: .assistant, text: "", state: .pending)
    model.state.chats[chatIndex].messages.append(pending)
    let envelope = AssistantEnvelope(reply: "Here is the new beginning.", edits: [patch(captured, [Replacement(old: captured.text, new: "A brighter beginning.")])])
    let result = try await model.finishConsultationResponse(String(decoding: JSONEncoder().encode(envelope), as: UTF8.self),
      pending: pending, chatID: chatID, authority: authority, documentSources: [], attachments: [])
    XCTAssertEqual(result.state, .complete)
    let applied = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == captured.id }
    XCTAssertEqual(applied?.text, "A brighter beginning.")
    XCTAssertEqual(model.state.proposals.last?.status, "applied")
    let persisted = (try await store.loadState(), try await NativeCheckEvidence.readPublicDocuments(model: model))
    XCTAssertEqual(persisted.1.first { $0.id == captured.id }?.text, "A brighter beginning.")
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    try await PagedNativeFixtureApplication.focus(view, in: try XCTUnwrap(view.window))
    try XCTUnwrap(model.pagedCommands).manager.undo()
    try await model.pagedCommands?.joinPendingCommand()
    try await model.flush()
    let undone = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == captured.id }
    XCTAssertEqual(undone?.text, captured.text)
    try await model.shutdown()
  }
  @MainActor func testMalformedResponseRetainsRawTextWithoutProposalUndoOrAlert() async throws {
    let (model, store, root, document, chatID, pending) = try await responseFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = "{\"reply\":\"Suggested changes\",\"edits\":["
    let response = try await model.finishConsultationResponse(raw, pending: pending, chatID: chatID,
      authority: CapturedDocumentAuthority(mode: .propose, target: document, capture: try await model.captureDocument(document.id)), documentSources: [], attachments: [])
    XCTAssertEqual(response.text, raw)
    XCTAssertEqual(response.state, .failed)
    XCTAssertEqual(model.selectedDocument?.text, document.text)
    XCTAssertTrue(model.state.proposals.isEmpty)
    XCTAssertFalse(try XCTUnwrap(model.pagedCommands).manager.canUndo)
    XCTAssertNil(model.errorMessage)
    try await model.flush()
    let persisted = (try await store.loadState(), try await NativeCheckEvidence.readPublicDocuments(model: model))
    XCTAssertEqual(persisted.0.chats.first { $0.id == chatID }?.messages.last?.text, raw)
    try await model.shutdown()
  }

  @MainActor private func mergedInterveningEdit() async throws
    -> (WorkspaceModel, URL, DocumentSnapshot, String, StoredProposal) {
    let (model, store, root, base, chatID, pending) = try await responseFixture()
    let currentText = base.text + " Human addition."
    try await NativeCheckEvidence.replacePublicDocument(model, text: currentText, id: base.id, caret: currentText.utf16.count)
    try await model.flush()
    let envelope = AssistantEnvelope(reply: "A brighter harbor.", edits: [patch(base,
      [Replacement(old: "The harbor was quiet.", new: "The harbor was bright.")])])
    let response = try await model.finishConsultationResponse(String(decoding: JSONEncoder().encode(envelope), as: UTF8.self),
      pending: pending, chatID: chatID, authority: CapturedDocumentAuthority(mode: .edit, target: base, capture: try await model.captureDocument(base.id)),
      documentSources: [SourceReference(id: base.id, title: base.title, digest: base.revision, kind: "document")], attachments: [])
    XCTAssertEqual(response.state, .complete)
    let expected = currentText.replacingOccurrences(of: "quiet", with: "bright")
    let appliedCapture = try await model.captureDocument(base.id)
    XCTAssertEqual(model.state.proposals.last?.appliedRevision, appliedCapture.revisionDigest)
    let persisted = (try await store.loadState(), try await NativeCheckEvidence.readPublicDocuments(model: model))
    XCTAssertEqual(persisted.1.first { $0.id == base.id }?.text, expected)
    let proposal = try XCTUnwrap(model.state.proposals.last)
    return (model, root, base, currentText, proposal)
  }

  @MainActor func testEditMergesInterveningTypingAndPersists() async throws {
    let (model, root, _, _, _) = try await mergedInterveningEdit()
    defer { try? FileManager.default.removeItem(at: root) }
    try await model.shutdown()
  }

  @MainActor func testMergedEditNativeUndoPreservesInterveningTyping() async throws {
    try await PagedNativeFixtureApplication.requireNativeKeyWindow()
    let (model, root, base, currentText, proposal) = try await mergedInterveningEdit()
    defer { try? FileManager.default.removeItem(at: root) }
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    try await PagedNativeFixtureApplication.focus(view, in: try XCTUnwrap(view.window))
    XCTAssertTrue(model.canUndo(proposal))
    model.undoProposal(proposal)
    try await waitForResponse(model)
    XCTAssertNil(model.errorMessage)
    let undone = try await NativeCheckEvidence.readPublicDocuments(model: model).first { $0.id == base.id }
    XCTAssertEqual(undone?.text, currentText)
    XCTAssertEqual(model.state.proposals.first(where: { $0.id == proposal.id })?.status, "undone")
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
    XCTAssertTrue(edit.rawPrompt.contains(document.revision)); XCTAssertTrue(edit.rawPrompt.contains("PUT N.=M:"))
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
  func testConflictingInterveningEditIsRejected() {
    let d = DocumentSnapshot(title: "T", text: "old")
    let changed = DocumentSnapshot(id: d.id, title: "T", text: "Human replacement")
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
  func testAutomaticReferenceWindowKeepsOriginalSourceAndPlanProvenance() throws {
    let original = String(String(repeating: "Public harbor line.\n", count: 5_000).prefix(82_600))
    let document = DocumentSnapshot(title: "Public 82K", text: original)
    let captured = try DocumentTools.renderedContext([document], attachments: [], authority: .readOnly,
      preferredDocumentID: document.id, omittedSources: 7)
    let windowed = try DocumentTools.windowedContext(captured, authority: .readOnly,
      capturedSources: captured.bindings.map(\.source), bodyBytes: 4_096, maximumSources: 1)
    let binding = try XCTUnwrap(windowed.bindings.first)
    let window = try XCTUnwrap(binding.window)
    XCTAssertEqual(binding.source.id, document.id)
    XCTAssertEqual(binding.source.digest, document.revision)
    XCTAssertEqual(window.digest, document.revision)
    XCTAssertEqual(window.bytes, 82_600)
    XCTAssertLessThanOrEqual(window.ranges.reduce(0) { $0 + $1.end - $1.start }, 4_096)
    XCTAssertEqual(windowed.omittedSources, 7)
    XCTAssertNotNil(binding.originalUTF8Hex)
    let question = String(repeating: "Earlier question e\u{301}👩‍💻 ", count: 2_000) + "Which line mentions the harbor?"
    let plan = try ProductCore.prompt(voice: nil, history: [],
      instructions: String(repeating: "Authored guidance. ", count: 2_000), context: windowed.prompt,
      request: question, routing: [], promptContract: .referenceBindingsV3,
      renderedContext: windowed, capturedSources: windowed.bindings.map(\.source), workingTextBytes: 96, workingRequestBytes: 96)
    let requestWindow = try XCTUnwrap(plan.workingWindow?.request)
    XCTAssertEqual(requestWindow.digest, Digest.sha256(question))
    XCTAssertEqual(requestWindow.bytes, question.utf8.count)
    XCTAssertEqual(requestWindow.ranges.last?.end, question.utf8.count)
    XCTAssertTrue(plan.rawPrompt.contains("Which line mentions the harbor?"))
    XCTAssertTrue(plan.rawPrompt.contains("Document permission: Ask (read only)"))
    XCTAssertFalse(plan.rawPrompt.contains(question))
    let reopened = try JSONDecoder().decode(ConsultationPlan.self, from: JSONEncoder().encode(plan))
    XCTAssertEqual(reopened.workingWindow?.request?.digest, requestWindow.digest)
    XCTAssertEqual(reopened.rawPrompt, plan.rawPrompt)
    XCTAssertEqual(document.text, original)
    XCTAssertEqual(original.utf8.count, 82_600)
  }

  func testFittedTargetScopeSurvivesProposalCodingAndApplication() throws {
    let empty = DocumentSnapshot(title: "Empty", text: "")
    let emptyAuthority = CapturedDocumentAuthority(mode: .edit, target: empty)
    let renderedEmpty = try DocumentTools.renderedContext([empty], attachments: [], authority: emptyAuthority)
    XCTAssertNil(try XCTUnwrap(renderedEmpty.bindings.first).window)
    let tag = try XCTUnwrap(renderedEmpty.target?.tag)
    let append = try DocumentTools.response("```hashline\n\(tag)\nPUT >$:\n+First line\n```", authority: emptyAuthority)
    XCTAssertNil(append.issue)
    let appendPatch = try XCTUnwrap(append.edits.first)
    XCTAssertEqual(try DocumentTools.apply(appendPatch,
      grant: DocumentGrant(mode: .edit, snapshot: empty), current: empty).text, "First line")

    let text = (1...10).map { String(format: "Line%02d ", $0) + String(repeating: "x", count: 44) + "\n" }.joined()
    let document = DocumentSnapshot(title: "Windowed target", text: text)
    var authority = CapturedDocumentAuthority(mode: .propose, target: document)
    let captured = try DocumentTools.renderedContext([document], attachments: [], authority: authority)
    let rendered = try DocumentTools.windowedContext(captured, authority: authority,
      capturedSources: captured.bindings.map(\.source), bodyBytes: 160, maximumSources: 1)
    let scope = try XCTUnwrap(rendered.bindings.first?.window)
    authority.targetWindow = scope
    let currentTag = try XCTUnwrap(rendered.target?.tag)
    let response = try DocumentTools.response("```hashline\n\(currentTag)\nCUT 5\n```", authority: authority)
    XCTAssertNotNil(response.issue)
    XCTAssertTrue(response.edits.isEmpty)
    let forbidden = patch(document, [Replacement(old: "Line05", new: "Hidden edit")])
    let proposal = StoredProposal(id: UUID(), chatID: UUID(), messageID: UUID(), patch: forbidden,
      document: document, documents: [], attachments: [], status: "pending", targetWindow: scope)
    let restored = try JSONDecoder().decode(StoredProposal.self, from: JSONEncoder().encode(proposal))
    XCTAssertEqual(restored.targetWindow?.digest, document.revision)
    XCTAssertThrowsError(try DocumentTools.plan(restored.patch,
      grant: DocumentGrant(mode: .propose, snapshot: document), current: document,
      targetWindow: restored.targetWindow))
    let visible = patch(document, [Replacement(old: "Line01", new: "Visible edit")])
    let changed = try DocumentTools.apply(visible, grant: DocumentGrant(mode: .edit, snapshot: document),
      current: document, targetWindow: scope)
    XCTAssertTrue(changed.text.hasPrefix("Visible edit "))
    XCTAssertTrue(changed.text.contains("Line05"))
    XCTAssertEqual(document.text, text)
  }

  func testCurrentQuestionPrecedesOptionalReferenceAndInstructionProse() throws {
    let document = DocumentSnapshot(title: "Optional reference", text: String(repeating: "Older source text. ", count: 2_000))
    let captured = try DocumentTools.renderedContext([document], attachments: [], authority: .readOnly,
      preferredDocumentID: document.id)
    let omitted = try DocumentTools.windowedContext(captured, authority: .readOnly,
      capturedSources: captured.bindings.map(\.source), bodyBytes: 0, maximumSources: 0)
    let question = "Keep this complete e\u{301}👩‍💻 current question about the harbor."
    let full = try ProductCore.prompt(voice: nil, history: [],
      instructions: String(repeating: "Optional instructions. ", count: 2_000), context: omitted.prompt,
      request: question, routing: [], promptContract: .referenceBindingsV3,
      renderedContext: omitted, capturedSources: [], workingTextBytes: 0)
    XCTAssertTrue(omitted.bindings.isEmpty)
    XCTAssertTrue(full.rawPrompt.contains(question))
    XCTAssertNil(full.workingWindow?.request)
    XCTAssertNotNil(full.workingWindow?.instructions)
    let clipped = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: omitted.prompt,
      request: question, routing: [], promptContract: .referenceBindingsV3,
      renderedContext: omitted, capturedSources: [], workingTextBytes: 0, workingRequestBytes: 24)
    let scope = try XCTUnwrap(clipped.workingWindow?.request)
    XCTAssertEqual(scope.digest, Digest.sha256(question))
    XCTAssertEqual(scope.ranges.last?.end, question.utf8.count)
    XCTAssertFalse(clipped.rawPrompt.contains(question))
    XCTAssertTrue(clipped.rawPrompt.contains("about the harbor."))
  }

}
