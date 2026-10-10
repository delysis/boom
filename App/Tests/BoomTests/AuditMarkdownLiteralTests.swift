import AppKit
import BoomCore
import XCTest
@testable import Boom

final class AuditMarkdownLiteralTests: XCTestCase {
  @MainActor private func checkLiteral(_ source: String) throws {
    let view = NSTextView(); view.string = source
    view.setSelectedRange(NSRange(location: 0, length: 0))
    MarkdownStyle.apply(to: view, reading: true)
    let range = (source as NSString).range(of: "[[Literal|")
    let storage = try XCTUnwrap(view.textStorage)
    let font = try XCTUnwrap(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    XCTAssertGreaterThan(font.pointSize, 10, "Code content must remain legible rather than become a hidden reference")
    XCTAssertEqual(view.string, source)
    XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    XCTAssertTrue(try ReferenceParser.wiki(source).isEmpty, "The context resolver already treats this text as literal")
  }
  @MainActor func testStableReferenceInsideInlineCodeRemainsLegible() throws {
    try checkLiteral("`[[Literal|00000000-0000-0000-0000-000000000001]]`")
  }
  @MainActor func testStableReferenceInsideFencedCodeRemainsLegible() throws {
    try checkLiteral("```text\n[[Literal|00000000-0000-0000-0000-000000000001]]\n```")
  }
  @MainActor func testStableReferenceInsideIndentedCodeRemainsLegible() throws {
    try checkLiteral("    [[Literal|00000000-0000-0000-0000-000000000001]]\n")
  }
  @MainActor func testOrdinaryStableReferenceStillProjectsItsTitle() throws {
    let source = "[[Literal|00000000-0000-0000-0000-000000000001]]"
    let view = NSTextView(); view.string = source; MarkdownStyle.apply(to: view, reading: true)
    let storage = try XCTUnwrap(view.textStorage)
    XCTAssertLessThan(try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize, 1)
    XCTAssertGreaterThan(try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont).pointSize, 10)
    XCTAssertEqual(view.string, source)
  }
}
