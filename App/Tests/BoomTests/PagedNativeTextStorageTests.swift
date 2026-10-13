import AppKit
import BoomCore
import Foundation
import Synchronization
import XCTest
@testable import Boom

private actor PagedUnpublishedStorageControl: PagedNativeSessionStorage {
  private(set) var commits = 0
  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    commits += 1
    throw BoomError.unavailable("Public control has no durable publication owner.")
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    throw BoomError.unavailable("Public control has no navigation owner.")
  }
}

/// These controls use the actual NSTextStorage/NSTextView input primitives.
/// Their public roots are synthetic; they do not qualify durable publication.
@MainActor final class PagedNativeTextStorageTests: XCTestCase {
  private func fixture(_ text: String, prefix: String = "", suffix: String = "") throws -> (PagedNativeSession, PagedUnpublishedStorageControl) {
    let owner = UUID(), document = UUID()
    let page = PagedTextPageRef(locator: PagedTextPageLocator(storeID: UUID(), offset: 0,
      bytes: 128), digest: String(repeating: "a", count: 64))
    let revision = PagedTextRevision(schema: 1, ownerID: owner, documentID: document,
      root: text.isEmpty && prefix.isEmpty && suffix.isEmpty ? nil : PagedTextTreeRef(page: page,
        summary: PagedTextSummary(bytes: UInt64(prefix.utf8.count + text.utf8.count + suffix.utf8.count),
          utf16: UInt64(prefix.utf16.count + text.utf16.count + suffix.utf16.count),
          lfCount: UInt64((prefix + text + suffix).utf8.filter { $0 == 10 }.count)), height: 0))
    let window = PagedTextWindow(revision: revision, windowID: UUID(), byteStart: UInt64(prefix.utf8.count),
      utf16Start: UInt64(prefix.utf16.count), lfStart: UInt64(prefix.utf8.filter { $0 == 10 }.count), text: text)
    let record = PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: document, title: "Control", revision: revision),
      historyPage: page, historyGeneration: 0)
    let backend = PagedUnpublishedStorageControl()
    return (try PagedNativeSession(window: window, rootRecord: record, storage: backend), backend)
  }

  func testPartialMarkdownWindowKeepsLiteralSyntaxAndDoesNotActivateUncertainMedia() throws {
    let text = "**words** [[Link]]\n[Attachment: picture](boom-attachment:01234567-89AB-4CDE-8FAB-0123456789AB)"
    for context in [("```\n", "\n```"), ("", "\n[definition]: elsewhere")] {
      let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240),
        session: fixture(text, prefix: context.0, suffix: context.1).0)
      XCTAssertFalse(view.hasCompleteMarkupContext)
      XCTAssertTrue(view.markupProjection.markdown.isEmpty)
      XCTAssertTrue(view.inlineMedia.spans.isEmpty)
      XCTAssertFalse(view.markupProjection.hasWikiMarker)
      XCTAssertFalse(view.markupProjection.hasAttachmentMarker)
      XCTAssertEqual(view.string, text)
      XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, MarkdownStyle.body)
    }
    let complete = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240),
      session: fixture(text).0)
    XCTAssertTrue(complete.hasCompleteMarkupContext)
    XCTAssertFalse(complete.markupProjection.markdown.isEmpty)
    XCTAssertEqual(complete.inlineMedia.spans.count, 1)
    XCTAssertTrue(complete.markupProjection.hasWikiMarker)
    XCTAssertEqual(complete.string, text)
  }

  func testLineFormattingCannotPrefixTheMiddleOfAnUnseenLogicalLine() throws {
    let text = "continuation\nnext line"
    let (session, _) = try fixture(text, prefix: "earlier part ")
    let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240), session: session)
    var refusal: Error?
    view.didRejectInput = { refusal = $0 }
    view.setSelectedRange(NSRange(location: 3, length: 0))
    view.prefixLines("## ")
    XCTAssertNotNil(refusal)
    XCTAssertEqual(view.string, text)
    XCTAssertEqual(session.generation, 0)
  }

  func testAcceptedPrimitiveRecordsExactCharactersBeforeStorageObservers() async throws {
    let (session, backend) = try fixture("e\u{301} 👩‍💻 tail")
    let storage = try PagedNativeTextStorage(session: session)
    session.beginComposition()
    let generationAtNotification = Mutex<UInt64?>(nil)
    let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
      object: storage, queue: .main) { _ in
        MainActor.assumeIsolated { generationAtNotification.withLock { $0 = session.generation } }
      }
    defer { NotificationCenter.default.removeObserver(token) }
    storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
    XCTAssertEqual(Data(storage.string.utf8), Data("é 👩‍💻 tail".utf8))
    XCTAssertEqual(session.generation, 1)
    XCTAssertEqual(generationAtNotification.withLock { $0 }, 1)
    XCTAssertNil(storage.mutationFailure)
    let commitCount = await backend.commits
    XCTAssertEqual(commitCount, 0)
    XCTAssertThrowsError(try session.windowForNativeInstallation())
  }

  func testAttributeTransactionsDoNotCreateSourceEditsOrPublication() async throws {
    let (session, backend) = try fixture("source")
    let storage = try PagedNativeTextStorage(session: session)
    storage.beginEditing()
    storage.setAttributes([.foregroundColor: NSColor.red], range: NSRange(location: 0, length: 6))
    storage.endEditing()
    XCTAssertEqual(session.generation, 0)
    XCTAssertEqual(storage.string, "source")
    let commitCount = await backend.commits
    XCTAssertEqual(commitCount, 0)
    XCTAssertNoThrow(try session.windowForNativeInstallation())
  }

  func testRejectedScalarAndReserveMutationsPreserveNativeCharacters() throws {
    let (session, _) = try fixture("🙂")
    let storage = try PagedNativeTextStorage(session: session)
    session.beginComposition()
    storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "x")
    XCTAssertEqual(storage.string, "🙂"); XCTAssertEqual(session.generation, 0)
    XCTAssertNil(storage.mutationFailure)
    storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x")
    XCTAssertEqual(storage.string, "🙂x"); XCTAssertEqual(session.generation, 1)
    XCTAssertNil(storage.mutationFailure)
    let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240),
      session: fixture(String(repeating: "a", count: 16_384)).0)
    let before = view.string
    XCTAssertFalse(view.shouldChangeText(in: NSRange(location: 16_384, length: 0),
      replacementString: String(repeating: "b", count: 8_193)))
    XCTAssertEqual(view.string, before)
    XCTAssertEqual(view.session.generation, 0)
    XCTAssertNil(view.boundedStorage.mutationFailure)
    view.session.beginComposition() // This local fixture has no publication owner.
    view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "c")
    XCTAssertEqual(view.string, "c" + String(repeating: "a", count: 16_383))
    XCTAssertEqual(view.session.generation, 1)
    XCTAssertNil(view.boundedStorage.mutationFailure)
  }

  func testNativeMarkedTextPinsItsIslandAndRecordsTheAcceptedReplacement() throws {
    let (session, _) = try fixture("hello ")
    let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240), session: session)
    view.setSelectedRange(NSRange(location: 6, length: 0))
    view.setMarkedText("e\u{301}", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 6, length: 0))
    XCTAssertTrue(view.hasMarkedText()); XCTAssertTrue(session.isPinned)
    XCTAssertEqual(Data(view.string.utf8), Data("hello e\u{301}".utf8))
    XCTAssertEqual(session.generation, 1)
    XCTAssertFalse(view.allowsUndo)
    XCTAssertThrowsError(try session.windowForNativeInstallation())
    // This mechanical input control stays pinned; it deliberately has no
    // Saved acknowledgement or ordinary packaged editor authority.
  }
}
