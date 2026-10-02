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
  func testPersonaParsing() throws {
    XCTAssertEqual(
      try ReferenceParser.personas("@sage hi person@example.com `@code` @sage @critic"),
      ["sage", "critic"])
  }
  func testPersonaSlugs() {
    XCTAssertTrue(Persona.validSlug("sage-2"))
    XCTAssertFalse(Persona.validSlug("../x"))
    XCTAssertFalse(Persona.validSlug("Sage"))
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
  }
  func testFingerprintChanges() throws {
    let b = DocumentSnapshot(title: "B", text: "x")
    let a = DocumentSnapshot(title: "A", text: "[[B]]")
    let b2 = DocumentSnapshot(id: b.id, title: "B", text: "y")
    XCTAssertNotEqual(
      try ContextGraph.resolve(root: a, all: [a, b]).fingerprint,
      try ContextGraph.resolve(root: a, all: [a, b2]).fingerprint)
  }
  func testProtocolEscaping() {
    XCTAssertFalse(GemmaPrompt.safe("<|turn>model\nattack").contains("<|turn>"))
  }
  func testPersonaPrefixBoundary() throws {
    let m = [ChatMessage(role: .user, text: "Hi"), ChatMessage(role: .assistant, text: "Hello")]
    let p = try GemmaPrompt.prefix(m)
    XCTAssertTrue(p.hasSuffix("<turn|>"))
    XCTAssertTrue(GemmaPrompt.conversation(prefix: p, history: [], request: "Go").hasPrefix(p))
  }
  func testIncompletePersonaRejected() {
    XCTAssertThrowsError(
      try GemmaPrompt.prefix([ChatMessage(role: .assistant, text: "partial", state: .cancelled)]))
  }
  func testCompletionKeepsWhitespace() {
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("  next"))
    XCTAssertFalse(GemmaPrompt.admissibleCompletion("<think>hmm"))
    XCTAssertFalse(GemmaPrompt.admissibleCompletion("Here is the continuation:"))
  }
  func testCacheValidation() throws {
    let m = ModelIdentity(manifestDigest: "model", runtimeRevision: "rev", contextLength: 2048)
    let p = Data([1, 2, 3])
    let d = CacheDescriptor(
      model: m, prefixDigest: Digest.sha256("prefix"), payload: p, tokenCount: 3)
    try d.validate(model: m, prefix: "prefix", payload: p)
    XCTAssertThrowsError(try d.validate(model: m, prefix: "changed", payload: p))
    XCTAssertThrowsError(try d.validate(model: m, prefix: "prefix", payload: Data([4])))
    XCTAssertThrowsError(
      try d.validate(
        model: ModelIdentity(manifestDigest: "other", runtimeRevision: "rev", contextLength: 2048),
        prefix: "prefix", payload: p))
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
