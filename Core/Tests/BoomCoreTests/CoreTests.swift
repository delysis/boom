import XCTest

@testable import BoomCore

final class CoreTests: XCTestCase {
  func testLibrarySelectionRangeToggleAndRename() {
    let rows = (0..<5).map { _ in UUID() }
    var selection = LibrarySelection(ids: [rows[1]])
    XCTAssertTrue(selection.click(rows[3], visible: rows, primary: rows[1], gesture: .range).open)
    XCTAssertEqual(selection.ids, Set(rows[1...3]))
    XCTAssertTrue(selection.click(rows[4], visible: rows, primary: rows[3], gesture: .additiveRange).open)
    XCTAssertEqual(selection.ids, Set(rows[1...4]))
    XCTAssertFalse(selection.click(rows[2], visible: rows, primary: rows[4], gesture: .toggle).open)
    XCTAssertFalse(selection.ids.contains(rows[2]))
    XCTAssertTrue(selection.click(rows[2], visible: rows, primary: rows[4], gesture: .plain).open)
    XCTAssertEqual(selection.ids, [rows[2]])
    XCTAssertTrue(selection.click(rows[2], visible: rows, primary: rows[2], gesture: .plain).rename)
  }
  func testLibrarySelectionFilteredAnchorFallsBackToClickedRow() {
    let rows = (0..<3).map { _ in UUID() }
    var selection = LibrarySelection(ids: [rows[0]], anchor: rows[0])
    XCTAssertTrue(selection.click(rows[2], visible: [rows[1], rows[2]],
      primary: rows[0], gesture: .range).open)
    XCTAssertEqual(selection.ids, [rows[2]])
    XCTAssertEqual(selection.anchor, rows[2])
  }
  func testSHA256Empty() {
    XCTAssertEqual(
      Digest.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }
  func testSHA256ABC() {
    XCTAssertEqual(
      Digest.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }
  func testSHA256Multiblock() {
    XCTAssertEqual(
      Digest.sha256(String(repeating: "a", count: 1000)),
      "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
  }
  func testCanonicalStable() throws {
    XCTAssertEqual(try Digest.identity(["b": 2, "a": 1]), try Digest.identity(["a": 1, "b": 2]))
  }
  func testUnicodeBoundary() throws {
    let s = "a😀e\u{301}z"
    XCTAssertEqual(try TextBoundary.split(s, atUTF16: 3).0, "a😀")
    XCTAssertThrowsError(try TextBoundary.index(2, in: s))
    XCTAssertThrowsError(try TextBoundary.index(4, in: s))
    XCTAssertThrowsError(try TextBoundary.index(-1, in: s))
    XCTAssertThrowsError(try TextBoundary.index(100, in: s))
  }
  func testGhostExactState() throws {
    let d = DocumentSnapshot(title: "A", text: "hi")
    let stamp = try GhostStamp(
      document: DocumentSnapshot(title: "x", text: ""), caretUTF16: 0, epoch: 2)
    XCTAssertFalse(stamp.accepts(document: d, caretUTF16: 0, epoch: 2, hasMarkedText: false))
    let own = try GhostStamp(document: d, caretUTF16: 2, epoch: 4)
    XCTAssertTrue(own.accepts(document: d, caretUTF16: 2, epoch: 4, hasMarkedText: false))
    XCTAssertFalse(own.accepts(document: d, caretUTF16: 2, epoch: 4, hasMarkedText: true))
    XCTAssertFalse(own.accepts(document: d, caretUTF16: 2, epoch: 5, hasMarkedText: false))
    XCTAssertFalse(own.accepts(document: d, caretUTF16: 1, epoch: 4, hasMarkedText: false))
    XCTAssertFalse(
      own.accepts(
        document: DocumentSnapshot(id: d.id, title: d.title, text: "hit"), caretUTF16: 2, epoch: 4,
        hasMarkedText: false))
  }
  func testWikiSkipsCodeAndEscapes() throws {
    let text = "[[Yes]] `[[No]]` \\[[No]]\n```swift\n[[No]]\n```\n    [[No]]\n[[Also]]"
    XCTAssertEqual(try ReferenceParser.wiki(text).map(\.title), ["Yes", "Also"])
  }
  func testUnclosedFenceSafe() throws {
    XCTAssertTrue(try ReferenceParser.wiki("```\n[[No]]").isEmpty)
  }
  func testStableWikiUUID() throws {
    let id = UUID()
    XCTAssertEqual(
      try ReferenceParser.wiki("[[T|\(id)]]"), [WikiReference(title: "T", documentID: id)])
  }
  func testInvalidWikiUUID() { XCTAssertThrowsError(try ReferenceParser.wiki("[[T|not-an-id]]")) }
  func testVoiceParsing() throws {
    XCTAssertEqual(
      try ReferenceParser.voices("@sage hi person@example.com `@code` @sage @critic"),
      ["sage", "critic"])
  }
  func testContextOrderAndRevalidation() throws {
    let c = DocumentSnapshot(title: "C", text: "facts")
    let b = DocumentSnapshot(title: "B", text: "[[C]]")
    let a = DocumentSnapshot(title: "A", text: "[[B]] [[C]]")
    let p = try ContextGraph.resolve(root: a, all: [a, b, c])
    XCTAssertEqual(p.documents.map(\.title), ["C", "B"])
    try p.revalidate(against: [a, b, c])
    XCTAssertThrowsError(try p.revalidate(against: [a, b]))
  }
  func testContextCycle() {
    let a = DocumentSnapshot(title: "A", text: "[[B]]")
    let b = DocumentSnapshot(title: "B", text: "[[A]]")
    XCTAssertThrowsError(try ContextGraph.resolve(root: a, all: [a, b]))
  }
  func testContextMissingAndAmbiguous() {
    let a = DocumentSnapshot(title: "A", text: "[[B]]")
    let b = DocumentSnapshot(title: "B", text: "")
    let b2 = DocumentSnapshot(title: "b", text: "")
    XCTAssertThrowsError(try ContextGraph.resolve(root: a, all: [a]))
    XCTAssertThrowsError(try ContextGraph.resolve(root: a, all: [a, b, b2]))
  }
  func testContextBudget() {
    let a = DocumentSnapshot(title: "A", text: "[[B]]")
    let b = DocumentSnapshot(title: "B", text: "too long")
    XCTAssertThrowsError(try ContextGraph.resolve(root: a, all: [a, b], limits: .init(bytes: 2)))
  }
  func testStableLinksSurviveRename() throws {
    let b = DocumentSnapshot(title: "Renamed", text: "x")
    let a = DocumentSnapshot(title: "A", text: "[[Old|\(b.id)]]")
    XCTAssertEqual(try ContextGraph.resolve(root: a, all: [a, b]).documents, [b])
  }
  func testChatReferencesRequireExplicitAttachmentOrLink() throws {
    let selected = DocumentSnapshot(title: "Selected elsewhere", text: "private")
    let linked = DocumentSnapshot(title: "Linked", text: "shared")
    XCTAssertTrue(
      try ContextGraph.resolveChat(request: "Hello", attachedDocumentID: nil,
        all: [selected, linked]).documents.isEmpty)
    XCTAssertEqual(
      try ContextGraph.resolveChat(request: "Read [[Linked]]", attachedDocumentID: nil,
        all: [selected, linked]).documents, [linked])
    XCTAssertEqual(
      try ContextGraph.resolveChat(request: "Hello", attachedDocumentID: selected.id,
        all: [selected, linked]).documents, [selected])
  }
  func testBranchPreservesAttachmentAndConversationBoundary() throws {
    let documentID = UUID()
    let user = ChatMessage(role: .user, text: "Original")
    let assistant = ChatMessage(role: .assistant, text: "Answer", feedback: .helpful)
    let later = ChatMessage(role: .user, text: "Later")
    let chat = ChatRecord(title: "Discussion", messages: [user, assistant, later],
      attachedDocumentID: documentID)
    let edited = try chat.branch(at: user.id, includeMessage: false)
    XCTAssertTrue(edited.messages.isEmpty)
    XCTAssertEqual(edited.attachedDocumentID, documentID)
    let continued = try chat.branch(at: assistant.id, includeMessage: true)
    XCTAssertEqual(continued.messages, [user, assistant])
    XCTAssertEqual(continued.messages[1].timestamp, assistant.timestamp)
    XCTAssertEqual(chat.messages.count, 3)
    XCTAssertThrowsError(try chat.branch(at: UUID(), includeMessage: true))
  }
  func testExistingChatsDecodeWithoutNewOptionalFields() throws {
    let legacyChat = """
      {"id":"00000000-0000-0000-0000-000000000001","title":"Old",
       "messages":[{"id":"00000000-0000-0000-0000-000000000002","role":"assistant",
       "text":"Hello","context":"","sources":[],"state":"complete"}]}
      """
    let chat = try JSONDecoder().decode(ChatRecord.self, from: Data(legacyChat.utf8))
    XCTAssertNil(chat.attachedDocumentID)
    XCTAssertNil(chat.messages[0].feedback)
    XCTAssertNil(chat.messages[0].timestamp, "Unknown historical times cannot be invented at decode.")
  }
  func testMessageTimestampSurvivesRecordRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message = ChatMessage(role: .assistant, text: "At the harbor.", timestamp: date)
    let decoded = try PropertyListDecoder().decode(ChatMessage.self, from: PropertyListEncoder().encode(message))
    XCTAssertEqual(decoded, message)
    XCTAssertEqual(decoded.timestamp, date)
  }
  func testFingerprintChanges() throws {
    let b = DocumentSnapshot(title: "B", text: "x")
    let a = DocumentSnapshot(title: "A", text: "[[B]]")
    let b2 = DocumentSnapshot(id: b.id, title: "B", text: "y")
    XCTAssertNotEqual(
      try ContextGraph.resolve(root: a, all: [a, b]).fingerprint,
      try ContextGraph.resolve(root: a, all: [a, b2]).fingerprint)
  }
  func testCompletionKeepsWhitespace() {
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("  next"))
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("<think>hmm"))
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("Here is the continuation:"))
  }
  func testCancellationSticky() {
    let c = CancellationFlag()
    XCTAssertFalse(c.isCancelled)
    c.cancel()
    XCTAssertThrowsError(try c.check())
    XCTAssertTrue(c.isCancelled)
  }
  func testDownloadPathSafety() throws {
    try DownloadPolicy.validateRelativePath("model.mlpackage/Data/weights.bin")
    for p in ["../escape", "/abs", "a//b", "a/./b", "a/../b", "a\\b", "a%2fb", "a:b", ""] {
      XCTAssertThrowsError(try DownloadPolicy.validateRelativePath(p))
    }
  }
  func testDownloadOrigins() {
    XCTAssertTrue(DownloadPolicy.permits(URL(string: "https://huggingface.co/a")!))
    XCTAssertTrue(DownloadPolicy.permits(URL(string: "https://cas-bridge.xethub.hf.co/a")!))
    XCTAssertTrue(DownloadPolicy.permits(URL(string: "https://us.aws.cdn.hf.co/a")!))
    for s in [
      "http://huggingface.co/a", "https://huggingface.co.evil/a", "https://x@huggingface.co/a",
      "https://127.0.0.1/a", "https://huggingface.co:444/a",
    ] { XCTAssertFalse(DownloadPolicy.permits(URL(string: s)!)) }
  }
}
