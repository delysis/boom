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
  @MainActor func testAttachmentSourceInsideCodeRemainsLegibleWithoutChangingSelection() throws {
    let attachment = "[Attachment: Photo.png](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)"
    for source in ["`\(attachment)`", "```text\n\(attachment)\n```\n", "    \(attachment)\n"] {
      let view = MarkdownTextView(frame: .zero); view.string = source
      let projection = view.markupProjection
      XCTAssertTrue(projection.hasAttachmentMarker, "Exact marker detection intentionally includes code bytes.")
      XCTAssertTrue(projection.media.isEmpty, "The actual parser excludes code from media activation.")
      let range = (source as NSString).range(of: attachment)
      view.setSelectedRange(NSRange(location: range.location + 1, length: 0))
      MarkdownStyle.apply(to: view, reading: true)
      let storage = try XCTUnwrap(view.textStorage)
      storage.enumerateAttribute(.font, in: range) { value, _, _ in
        XCTAssertGreaterThan((value as? NSFont)?.pointSize ?? 0, 10,
          "Attachment punctuation and identity are literal code, not hidden media chrome.")
      }
      XCTAssertEqual(view.string, source)
      XCTAssertEqual(view.selectedRange(), NSRange(location: range.location + 1, length: 0))
      XCTAssertTrue(view.subviews.compactMap { $0 as? InlineMediaHost }.isEmpty)
    }
  }
  @MainActor func testOrdinaryStableReferenceStillProjectsItsTitle() throws {
    let source = "[[Literal|00000000-0000-0000-0000-000000000001]]"
    let view = NSTextView(); view.string = source; MarkdownStyle.apply(to: view, reading: true)
    let storage = try XCTUnwrap(view.textStorage)
    XCTAssertLessThan(try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize, 1)
    XCTAssertGreaterThan(try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont).pointSize, 10)
    XCTAssertEqual(view.string, source)
  }

  @MainActor private func mediaActionFixture() throws -> (NativeMediaTextView, InlineMediaHost, NSEvent) {
    _ = NSApplication.shared
    let id = UUID(), marker = "[Attachment: public](boom-attachment:\(id.uuidString))"
    let view = NativeMediaTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.isEditable = true; view.isSelectable = true; view.isRichText = false
    view.string = marker; view.inlineMedia.refresh()
    let record = AttachmentRecord(id: id, name: "public", rootDigest: Digest.sha256("public"),
      text: "", coverage: "", transform: nil, presentation: .unavailable)
    let item = InlineMediaItem(record), host = InlineMediaHost(item: item, owner: view)
    let range = try XCTUnwrap(view.inlineMedia.spans.first(where: { $0.id == id })?.range)
    let storage = try XCTUnwrap(view.textStorage)
    storage.addAttribute(NSAttributedString.Key("BloomInlineMedia"), value: item, range: range)
    host.sourceRange = range; view.addSubview(host); view.setSelectedRange(range)
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1))
    return (view, host, event)
  }
  @MainActor func testRetainedMediaMenuDoesNotCutReboundStorageButFreshMenuStillCuts() throws {
    let (view, host, event) = try mediaActionFixture()
    let menu = try XCTUnwrap(host.menu(for: event)), cut = try XCTUnwrap(menu.items.first(where: { $0.title == "Cut" }))
    let marker = view.string, manager = try XCTUnwrap(view.layoutManager)
    let originalStorage = try XCTUnwrap(view.textStorage), originalVersion = view.sourceVersion
    // The exact native view and even the media host survive; its occurrence
    // moves in a genuinely replaced TextKit source, as on logical adoption.
    let next = NSTextStorage(string: "NEW\n" + marker)
    manager.replaceTextStorage(next); view.inlineMedia.refresh()
    let range = try XCTUnwrap(view.inlineMedia.spans.first(where: { $0.id == host.item.record.id })?.range)
    next.addAttribute(NSAttributedString.Key("BloomInlineMedia"), value: host.item, range: range)
    host.sourceRange = range; view.setSelectedRange(range)
    XCTAssertTrue(host.superview === view); XCTAssertTrue(manager.textStorage === next)
    XCTAssertTrue(originalStorage.layoutManagers.isEmpty); XCTAssertNotEqual(view.sourceVersion, originalVersion)
    let selection = view.selectedRange(), source = view.string
    XCTAssertTrue(host.tryToPerform(try XCTUnwrap(cut.action), with: cut))
    XCTAssertEqual(view.string, source); XCTAssertEqual(view.selectedRange(), selection)
    // A new menu owns this actual source/range; stable view identity itself
    // does not make current actions stale or disable normal native Cut.
    let fresh = try XCTUnwrap(host.menu(for: event))
    let currentCut = try XCTUnwrap(fresh.items.first(where: { $0.title == "Cut" }))
    XCTAssertTrue(host.tryToPerform(try XCTUnwrap(currentCut.action), with: currentCut))
    XCTAssertEqual(view.string, "NEW\n")
  }
  @MainActor func testRemovedMediaHostCannotSelectOrCutTheStableCurrentView() throws {
    let (view, host, event) = try mediaActionFixture()
    let menu = try XCTUnwrap(host.menu(for: event)), cut = try XCTUnwrap(menu.items.first(where: { $0.title == "Cut" }))
    host.removeFromSuperview()
    try XCTUnwrap(view.layoutManager).replaceTextStorage(NSTextStorage(string: "current"))
    view.setSelectedRange(NSRange(location: 2, length: 1))
    let selection = view.selectedRange(), source = view.string
    host.mouseDown(with: event)
    XCTAssertEqual(view.selectedRange(), selection)
    XCTAssertTrue(host.tryToPerform(try XCTUnwrap(cut.action), with: cut))
    XCTAssertEqual(view.string, source); XCTAssertEqual(view.selectedRange(), selection)
    XCTAssertNil(host.menu(for: event))
  }
}
