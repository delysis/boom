import AppKit
import XCTest
@testable import Boom

final class WritingGuideTests: XCTestCase {
  @MainActor func testBundledGuideIsSelectableAndFitsBothWidths() async throws {
    _ = NSApplication.shared
    let lookups = VaultSession.shared.lookupCount
    let text = try await WritingGuide.load()
    XCTAssertTrue(text.contains("Writing → Variation → Default"))
    for width in [CGFloat(420), 640] {
      let window = WritingGuide.makeWindow(text: text,
        frame: NSRect(x: -10_000, y: -10_000, width: width, height: 560))
      defer { window.close() }
      let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
      let view = try XCTUnwrap(scroll.documentView as? NSTextView)
      scroll.layoutSubtreeIfNeeded()
      let container = try XCTUnwrap(view.textContainer), layout = try XCTUnwrap(view.layoutManager)
      layout.ensureLayout(for: container)
      XCTAssertFalse(window.isVisible)
      XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable)
      XCTAssertEqual(view.string, text)
      XCTAssertLessThanOrEqual(layout.usedRect(for: container).width, scroll.contentSize.width - 56 + 1)
      XCTAssertEqual(VaultSession.shared.lookupCount, lookups)
    }
  }
}
