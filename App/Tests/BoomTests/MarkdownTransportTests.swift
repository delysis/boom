import AppKit
import XCTest
@testable import Boom

final class MarkdownTransportTests: XCTestCase {
  private struct Span: Decodable, Equatable {
    let kind: String
    let location: Int
    let length: Int
    let level: Int
  }
  func testNativeBorrowedUTF8KeepsExactParserOutputForForeignAndAuthoredStrings() throws {
    let reference = "[Attachment: café\\]🙂.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)"
    let foreign = NSMutableString(string: "Cafe\u{301} 👩🏽‍💻\n")
    foreign.append("**bold *italic***\n" + reference + "\n`" + reference + "`\n\0\"\\")
    for text in ["", "plain prose", "Café 👩🏽‍💻", foreign as String] {
      let expected: [Span] = try ProductCore.call(["op": "markdown_spans", "text": text])
      let actual: [Span] = try ProductCore.markdownSpans(text)
      XCTAssertEqual(actual, expected)
      let expectedMedia: [InlineMediaSpan] = try ProductCore.call(["op": "media_spans", "text": text])
      let actualMedia = try ProductCore.markdownMediaSpans(text)
      XCTAssertEqual(actualMedia.map(\.id), expectedMedia.map(\.id))
      XCTAssertEqual(actualMedia.map(\.range), expectedMedia.map(\.range))
      let projection = ProductCore.markupProjection(text)
      XCTAssertEqual(projection.markdown.map {
        Span(kind: $0.kind, location: $0.location, length: $0.length, level: $0.level)
      }, expected)
      XCTAssertEqual(projection.media.map(\.id), expectedMedia.map(\.id))
      XCTAssertEqual(projection.media.map(\.range), expectedMedia.map(\.range))
    }
  }
  @MainActor func testSharedProjectionFollowsNativeCharacterEditsAndPreservesAttributeOnlyVersion() throws {
    _ = NSApplication.shared
    let reference = "[Attachment: public.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)"
    let original = "Café **bold**\n" + reference
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    view.string = original
    let storage = try XCTUnwrap(view.textStorage)
    let first = try XCTUnwrap(view.markupProjection.media.first)
    let version = view.sourceVersion
    storage.addAttribute(NSAttributedString.Key("public-projection-fixture"), value: true,
      range: NSRange(location: 0, length: storage.length))
    MarkdownStyle.apply(to: view)
    XCTAssertEqual(view.sourceVersion, version)
    XCTAssertEqual(view.markupProjection.media.first?.range, first.range)
    XCTAssertEqual(Data(view.string.utf8), Data(original.utf8))
    let replacement = "Cafe\u{301} **bold**\n" + reference
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: replacement)
    XCTAssertNotEqual(view.sourceVersion, version)
    MarkdownStyle.apply(to: view)
    let updated = try XCTUnwrap(view.markupProjection.media.first)
    XCTAssertEqual(updated.location, first.location + 1)
    XCTAssertEqual(updated.range, (replacement as NSString).range(of: reference))
    XCTAssertEqual(view.inlineMedia.spans.first?.range, updated.range)
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "👩🏽‍💻 plain")
    MarkdownStyle.apply(to: view)
    XCTAssertTrue(view.markupProjection.markdown.isEmpty)
    XCTAssertTrue(view.markupProjection.media.isEmpty)
    XCTAssertTrue(view.inlineMedia.spans.isEmpty)
  }
  @MainActor func testProjectionCannotReuseCharactersInsideAnUnprocessedStorageTransaction() throws {
    _ = NSApplication.shared
    let reference = "[Attachment: public.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)"
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    view.string = reference
    let storage = try XCTUnwrap(view.textStorage)
    let original = try XCTUnwrap(view.markupProjection.media.first)
    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "🙂")
    let first = view.markupProjection.media.first?.range
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Cafe\u{301}\n")
    view.inlineMedia.refresh()
    let second = view.inlineMedia.spans.first?.range
    storage.endEditing()
    XCTAssertEqual(first, NSRange(location: original.location + 2, length: original.length))
    XCTAssertEqual(second, (view.string as NSString).range(of: reference))
    XCTAssertEqual(view.markupProjection.media.first?.range, second)
  }
  @MainActor func testLiteralEligibilityKeepsLateUnicodeWikiAndAttachmentRendering() throws {
    let prefix = String(repeating: "Cafe\u{301} 👩🏽‍💻 public prose\n", count: 800)
    XCTAssertTrue(MarkdownStyle.wikiDisplays(in: prefix).isEmpty)
    let wiki = "[[Café|884646c1-14b4-490d-be8c-8953af793315]]"
    let attachment = "[Attachment: public.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)"
    let source = prefix + wiki + "\n" + attachment
    let display = try XCTUnwrap(MarkdownStyle.wikiDisplays(in: source).first)
    XCTAssertEqual(display.title, NSRange(location: prefix.utf16.count + 2, length: 4))
    let view = MarkdownTextView(frame: .zero); view.string = source; MarkdownStyle.apply(to: view)
    let storage = try XCTUnwrap(view.textStorage)
    let name = (source as NSString).range(of: "public.png")
    XCTAssertEqual(storage.attribute(.underlineStyle, at: name.location, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
    XCTAssertEqual(Data(view.string.utf8), Data(source.utf8))
  }
  func testSharedByteMarkersRequireExactASCIIAndFindLateForeignSource() {
    let prefix = String(repeating: "Cafe\u{301} 👩🏽‍💻 public prose\n", count: 800)
    for source in ["", prefix, "[", "［[", "[Attachment:", "[attachment: ", "[Attachment: "] {
      let projection = ProductCore.markupProjection(source)
      XCTAssertFalse(projection.hasWikiMarker)
      XCTAssertFalse(projection.hasAttachmentMarker)
    }
    let foreign = NSMutableString(string: prefix)
    foreign.append("[[Café]]\n[Attachment: public.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)")
    let projection = ProductCore.markupProjection(foreign as String)
    XCTAssertTrue(projection.hasWikiMarker)
    XCTAssertTrue(projection.hasAttachmentMarker)
  }
}
