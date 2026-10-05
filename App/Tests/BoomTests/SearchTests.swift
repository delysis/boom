import AppKit
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class SearchTests: XCTestCase {
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
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let first = DocumentSnapshot(title: "One", text: "👩‍💻 Café in the body."), second = DocumentSnapshot(title: "Two", text: "A different passage.")
    let chat = ChatRecord(title: "Conversation", messages: [ChatMessage(role: .user, text: "Café in a conversation.")])
    var state = WorkspaceState()
    state.documents = [first, second].map { DocumentIndex(id: $0.id, title: $0.title) }
    state.chats = [chat]; state.selectedDocument = first.id; state.selectedChat = chat.id
    try await store.save(state, documents: [first, second])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.draft = "Keep my unfinished question."
    model.librarySearch = "missing"; model.librarySearch = "CAFÉ"
    try await waitForSearch(model, query: "CAFÉ", document: first.id)
    XCTAssertTrue(model.documentMatchesSearch(first)); XCTAssertFalse(model.documentMatchesSearch(second))
    XCTAssertTrue(model.chatMatchesSearch(chat))
    XCTAssertEqual(model.documentSearch[first.id]?.matches.ranges.first?.native, NSRange(location: 6, length: 4))
    model.updateDocument("The match was removed.", id: first.id, caret: 0)
    try await model.flush()
    for _ in 0..<100 where model.documentSearch[first.id] != nil { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertNil(model.documentSearch[first.id])
    XCTAssertFalse(model.documentMatchesSearch(try XCTUnwrap(model.selectedDocument)))
    XCTAssertEqual(model.draft, "Keep my unfinished question.")
    model.librarySearch = ""
    XCTAssertTrue(model.documentMatchesSearch(second)); XCTAssertTrue(model.documentSearch.isEmpty)
    try await model.shutdown()
  }
  @MainActor private func waitForSearch(_ model: WorkspaceModel, query: String, document: UUID) async throws {
    for _ in 0..<100 {
      if model.documentSearch[document]?.query == query { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Live search did not publish its captured result.")
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
