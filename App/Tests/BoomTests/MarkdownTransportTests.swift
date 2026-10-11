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
    }
  }
  @MainActor func testLiteralEligibilityKeepsLateUnicodeWikiAndAttachmentRendering() throws {
    let prefix = String(repeating: "Cafe\u{301} 👩🏽‍💻 public prose\n", count: 800)
    XCTAssertTrue(MarkdownStyle.wikiDisplays(in: prefix).isEmpty)
    let wiki = "[[Café|884646c1-14b4-490d-be8c-8953af793315]]"
    let attachment = "[Attachment: public.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)"
    let source = prefix + wiki + "\n" + attachment
    let display = try XCTUnwrap(MarkdownStyle.wikiDisplays(in: source).first)
    XCTAssertEqual(display.title, NSRange(location: prefix.utf16.count + 2, length: 4))
    let view = NSTextView(); view.string = source; MarkdownStyle.apply(to: view)
    let storage = try XCTUnwrap(view.textStorage)
    let name = (source as NSString).range(of: "public.png")
    XCTAssertEqual(storage.attribute(.underlineStyle, at: name.location, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
    XCTAssertEqual(Data(view.string.utf8), Data(source.utf8))
  }
}
