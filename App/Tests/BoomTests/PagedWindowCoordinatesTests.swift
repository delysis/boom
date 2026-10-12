import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

final class PagedWindowCoordinatesTests: XCTestCase {
  private func window(_ text: String, start: UInt64 = 0, total: UInt64? = nil) -> PagedTextWindow {
    let bytes = start + UInt64(text.utf8.count)
    let summary = PagedTextSummary(bytes: total ?? bytes, utf16: total ?? bytes, lfCount: total ?? bytes)
    let locator = PagedTextPageLocator(storeID: UUID(), recordID: UUID(), ciphertextBytes: 100)
    let root = PagedTextTreeRef(page: PagedTextPageRef(locator: locator, digest: String(repeating: "0", count: 64)),
      summary: summary, height: 0)
    return PagedTextWindow(revision: PagedTextRevision(schema: 1, ownerID: UUID(), documentID: UUID(), root: root),
      windowID: UUID(), byteStart: start, utf16Start: start, lfStart: 0, text: text)
  }
  func testUnicodeCoordinatesAndExactCanonicalEditAtLargeGlobalOffset() throws {
    let prefix = String(repeating: "Cafe\u{301} 👩🏽‍💻\r\n", count: 200)
    let text = prefix + "Café tail"
    let capture = window(text, start: 1_073_741_824, total: 8_589_934_592)
    let coordinates = try PagedWindowCoordinates(window: capture)
    // NSString's ordinary search also matches the earlier decomposed words.
    // The authored fixture position identifies the intended NFC bytes exactly.
    let local = NSRange(location: prefix.utf16.count, length: "Café".utf16.count)
    let absolute = try coordinates.absoluteByteRange(for: local)
    XCTAssertEqual(absolute.lowerBound, capture.byteStart + UInt64(prefix.utf8.count))
    XCTAssertEqual(absolute.count, "Café".utf8.count)
    XCTAssertEqual(try coordinates.localRange(forAbsoluteBytes: absolute), local)
    let edit = try coordinates.edit(in: local, replacement: "Cafe\u{301}")
    XCTAssertEqual(edit.oldBytes, Data("Café".utf8))
    XCTAssertEqual(edit.newBytes, Data("Cafe\u{301}".utf8))
    XCTAssertNotEqual(edit.oldBytes, edit.newBytes)
    XCTAssertEqual(edit.revision, capture.revision)
    XCTAssertEqual(edit.windowID, capture.windowID)
  }
  func testAllScalarBoundariesMatchSmallExhaustiveOracleAndRejectSplits() throws {
    let text = String(repeating: "aé界🙂\r\n", count: 300)
    let capture = window(text, start: 200)
    let coordinates = try PagedWindowCoordinates(window: capture)
    var byte = 0, utf16 = 0
    for scalar in text.unicodeScalars {
      let units = scalar.value > 0xffff ? 2 : 1
      let size = String(scalar).utf8.count
      let absolute = (capture.byteStart + UInt64(byte))..<(capture.byteStart + UInt64(byte + size))
      let native = NSRange(location: utf16, length: units)
      XCTAssertEqual(try coordinates.absoluteByteRange(for: native), absolute)
      XCTAssertEqual(try coordinates.localRange(forAbsoluteBytes: absolute), native)
      if units == 2 { XCTAssertThrowsError(try coordinates.absoluteByteRange(for: NSRange(location: utf16 + 1, length: 0))) }
      if size > 1 {
        let inside = capture.byteStart + UInt64(byte + 1)
        XCTAssertThrowsError(try coordinates.localRange(forAbsoluteBytes: inside..<inside))
      }
      byte += size; utf16 += units
    }
    XCTAssertEqual(try coordinates.absoluteByteRange(for: NSRange(location: utf16, length: 0)).lowerBound,
      capture.byteStart + UInt64(byte))
    XCTAssertThrowsError(try coordinates.absoluteByteRange(for: NSRange(location: NSNotFound, length: 1)))
  }
  func testNativeWindowLimitDoesNotBecomeWholeFileLimit() throws {
    let text = String(repeating: "a", count: PagedTextWindow.maximumBytes)
    let capture = window(text, start: 4_294_967_296, total: 16_179_869_184)
    let coordinates = try PagedWindowCoordinates(window: capture)
    XCTAssertEqual(coordinates.localByteCount, PagedTextWindow.maximumBytes)
    XCTAssertThrowsError(try coordinates.edit(in: NSRange(location: text.utf16.count, length: 0), replacement: "b"))
    XCTAssertThrowsError(try PagedWindowCoordinates(window: window(text + "b")))
    // Only arithmetic/metadata is synthetic; no multi-GB or TB fixture is allocated.
  }
}
