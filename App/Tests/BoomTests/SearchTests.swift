import AppKit
import BoomCore
import XCTest
@testable import Boom

final class SearchTests: XCTestCase {
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
  @MainActor func testToolbarSearchOpensFromIconAndCollapsesOnBlurOrEscape() throws {
    _ = NSApplication.shared
    let delegate = ApplicationDelegate()
    let toolbar = NSToolbar(identifier: "Public search fixture")
    toolbar.delegate = delegate
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 760, height: 500))
    window.isReleasedWhenClosed = false; window.toolbar = toolbar
    defer { window.close() }
    let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "search" })
    let icon = try XCTUnwrap(item.view as? NSButton)
    icon.performClick(nil)
    let field = try XCTUnwrap(item.view as? NSSearchField)
    field.stringValue = "café"
    delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    delegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    XCTAssertTrue(item.view === icon)
    icon.performClick(nil)
    XCTAssertTrue(item.view === field)
    XCTAssertEqual(field.stringValue, "café")
    XCTAssertTrue(delegate.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertTrue(item.view === icon)
    XCTAssertEqual(field.stringValue, "")
  }
  @MainActor private final class SearchReceiver: NSObject {
    var query = ""
    @objc func changed(_ sender: NSSearchField) { query = sender.stringValue }
  }
  @MainActor func testAccessibleSearchControlPublishesLiveInputAndClearingWithoutSubmission() {
    _ = NSApplication.shared
    let field = LibrarySearchField(), receiver = SearchReceiver()
    field.target = receiver; field.action = #selector(SearchReceiver.changed(_:))
    field.setAccessibilityValue("café")
    XCTAssertEqual(receiver.query, "café")
    field.setAccessibilityValue("")
    XCTAssertEqual(receiver.query, "")
  }
  @MainActor func testLiveSearchFindsBodiesAndReplacesStaleResultsWithoutConsumingTheDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-search-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    let first = DocumentSnapshot(title: "One", text: "👩‍💻 Café in the body."), second = DocumentSnapshot(title: "Two", text: "A different passage.")
    let chat = ChatRecord(title: "Conversation", messages: [ChatMessage(role: .user, text: "Café in a conversation.")])
    var state = WorkspaceState()
    state.documents = [first, second].map { DocumentIndex(id: $0.id, title: $0.title) }
    state.chats = [chat]; state.selectedDocument = first.id; state.selectedChat = chat.id
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [first, second])
    let cleanup = WorkspaceCleanup(model), initialFailures = testRun?.failureCount ?? 0
    addTeardownBlock {
      try await cleanup.close()
      if await MainActor.run(body: { self.testRun?.failureCount ?? 0 }) == initialFailures {
        try FileManager.default.removeItem(at: root)
      }
    }
    model.draft = "Keep my unfinished question."
    model.librarySearch = "missing"; model.librarySearch = "CAFÉ"
    try await waitForSearch(model, query: "CAFÉ", document: first.id)
    try await waitForAbsentSearchResult(model, document: second)
    XCTAssertTrue(model.documentMatchesSearch(first)); XCTAssertFalse(model.documentMatchesSearch(second))
    XCTAssertTrue(model.chatMatchesSearch(chat))
    XCTAssertEqual(model.documentSearch[first.id]?.matches.ranges.first?.native, NSRange(location: 6, length: 4))
    try await NativeCheckEvidence.replacePublicDocument(model, text: "The match was removed.", id: first.id, caret: 0)
    try await model.flush()
    try await waitForAbsentSearchResult(model, document: first)
    XCTAssertNil(model.documentSearch[first.id])
    XCTAssertFalse(model.documentMatchesSearch(try XCTUnwrap(model.selectedDocument)))
    XCTAssertEqual(model.draft, "Keep my unfinished question.")
    model.librarySearch = ""
    XCTAssertTrue(model.documentMatchesSearch(second)); XCTAssertTrue(model.documentSearch.isEmpty)
    try await cleanup.close()
  }
  @MainActor private func waitForSearch(_ model: WorkspaceModel, query: String, document: UUID) async throws {
    for _ in 0..<100 {
      if model.documentSearch[document]?.query == query,
        model.documentSearch[document]?.matches.hasMatches == true { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Live search did not publish query=\(query), searchIssue=\(model.searchIssue ?? "none"), documentIDs=\(model.matchingDocumentIDs), results=\(model.documentSearch.keys), expected=\(document).")
  }
  @MainActor private func waitForAbsentSearchResult(_ model: WorkspaceModel, document: DocumentSnapshot) async throws {
    for _ in 0..<100 {
      if !model.documentMatchesSearch(document) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Search did not settle without a match for \(document.id).")
  }
  @MainActor func testHighlightsUseOriginalUnicodeRangesAndLeaveTextAndNativeUndoIntact() throws {
    _ = NSApplication.shared
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    let undo = UndoManager(); view.documentUndo = undo; view.allowsUndo = true
    let original = "👩‍💻 Café and CAFÉ."
    view.string = original
    let ranges = try ProductCore.search(original, query: "café").ranges.map(\.native)
    view.highlightSearch(ranges, identity: "fixture/café")
    XCTAssertEqual(view.string, original); XCTAssertFalse(undo.canUndo)
    XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 6, effectiveRange: nil))
    XCTAssertNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
    view.highlightSearch([], identity: nil)
    XCTAssertNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 6, effectiveRange: nil))
    XCTAssertEqual(view.string, original); XCTAssertFalse(undo.canUndo)
    view.setAccessibilityValue(original + " Added.")
    XCTAssertEqual(view.string, original + " Added.")
    view.highlightSearch(ranges, identity: "fixture/café")
    undo.undo()
    XCTAssertEqual(view.string, original)
  }
}
