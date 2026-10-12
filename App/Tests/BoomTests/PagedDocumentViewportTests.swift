import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

@MainActor private final class PagedCharacterObserver: NSObject {
  var count = 0
  @objc func changed(_ notification: Notification) {
    if let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) { count += 1 }
  }
}

final class PagedDocumentViewportTests: XCTestCase {
  private func window(_ text: String, start: UInt64) -> PagedTextWindow {
    let total = start + UInt64(text.utf8.count)
    let summary = PagedTextSummary(bytes: total, utf16: total, lfCount: total)
    let locator = PagedTextPageLocator(storeID: UUID(), recordID: UUID(), ciphertextBytes: 100)
    let root = PagedTextTreeRef(page: PagedTextPageRef(locator: locator, digest: String(repeating: "0", count: 64)),
      summary: summary, height: 0)
    return PagedTextWindow(revision: PagedTextRevision(schema: 1, ownerID: UUID(), documentID: UUID(), root: root),
      windowID: UUID(), byteStart: start, utf16Start: start, lfStart: 0, text: text)
  }
  @MainActor func testNativeWindowBytesSelectionAndStatusRenders() throws {
    _ = NSApplication.shared
    let text = "Cafe\u{301} 👩🏽‍💻\r\npublic bounded prose"
    let capture = window(text, start: 1_073_741_824)
    let viewport = PagedDocumentViewport(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    try viewport.show(capture)
    XCTAssertEqual(Data(viewport.textView.string.utf8), Data(text.utf8))
    let observer = PagedCharacterObserver()
    NotificationCenter.default.addObserver(observer, selector: #selector(PagedCharacterObserver.changed(_:)),
      name: NSTextStorage.didProcessEditingNotification, object: viewport.textView.textStorage)
    defer { NotificationCenter.default.removeObserver(observer) }
    let selected = (text as NSString).range(of: "👩🏽‍💻")
    viewport.textView.setSelectedRange(selected)
    let expectedStart = capture.byteStart + UInt64("Cafe\u{301} ".utf8.count)
    let global = expectedStart..<(expectedStart + UInt64("👩🏽‍💻".utf8.count))
    XCTAssertEqual(try viewport.selectedGlobalBytes(), global)
    for _ in 0..<50 { try viewport.show(capture, selection: global) }
    XCTAssertEqual(observer.count, 0)
    XCTAssertEqual(viewport.textView.selectedRange(), selected)
    XCTAssertEqual(Data(viewport.textView.string.utf8), Data(text.utf8))
  }
  @MainActor func testImportPreviewAndOpenCharacterTransactionCannotAcquireEditCapture() throws {
    _ = NSApplication.shared
    let viewport = PagedDocumentViewport(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
    let preview = PagedTextImportPreview(ownerID: UUID(), documentID: UUID(), importID: UUID(), windowID: UUID(),
      expectedBytes: 1_073_741_824, validatedPrefixBytes: 65_536, text: "public first prefix")
    try viewport.showImport(preview)
    XCTAssertFalse(viewport.textView.isEditable)
    XCTAssertThrowsError(try viewport.captureEdit(in: NSRange(location: 0, length: 1), replacement: "x"))
    XCTAssertThrowsError(try viewport.selectedGlobalBytes())
    let capture = window("Café public", start: 200)
    try viewport.show(capture)
    let storage = try XCTUnwrap(viewport.textView.textStorage)
    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "Cafe\u{301}")
    XCTAssertThrowsError(try viewport.captureEdit(in: NSRange(location: 0, length: 1), replacement: "x"))
    XCTAssertThrowsError(try viewport.show(capture))
    storage.endEditing()
    XCTAssertThrowsError(try viewport.captureEdit(in: NSRange(location: 0, length: 1), replacement: "x"))
    try viewport.show(capture)
    XCTAssertEqual(Data(viewport.textView.string.utf8), Data(capture.text.utf8))
    let edit = try viewport.captureEdit(in: NSRange(location: 0, length: 4), replacement: "Cafe\u{301}")
    XCTAssertEqual(edit.oldBytes, Data("Café".utf8))
    XCTAssertEqual(edit.newBytes, Data("Cafe\u{301}".utf8))
  }
  func testPagedWireKeepsExplicitEmptyRootAndRejectsLegacyDigestShape() throws {
    let revision = PagedTextRevision(schema: 1, ownerID: UUID(), documentID: UUID(), root: nil)
    let data = try JSONEncoder().encode(revision)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(value["root"] is NSNull)
    XCTAssertNotNil(value["ownerId"])
    XCTAssertNotNil(value["documentId"])
    XCTAssertEqual(try JSONDecoder().decode(PagedTextRevision.self, from: data), revision)
    XCTAssertThrowsError(try JSONDecoder().decode(PagedTextRevision.self, from: Data("\"legacy-sha256\"".utf8)))
    var missing = value
    missing.removeValue(forKey: "root")
    XCTAssertThrowsError(try JSONDecoder().decode(PagedTextRevision.self,
      from: JSONSerialization.data(withJSONObject: missing)))
    XCTAssertThrowsError(try PagedTextSummary(bytes: 1, utf16: 0, lfCount: 0).validate())
    let locator = PagedTextPageLocator(storeID: UUID(), recordID: UUID(), ciphertextBytes: 100)
    let emptyRoot = PagedTextTreeRef(page: PagedTextPageRef(locator: locator, digest: String(repeating: "0", count: 64)),
      summary: PagedTextSummary(bytes: 0, utf16: 0, lfCount: 0), height: 0)
    XCTAssertThrowsError(try PagedTextRevision(schema: 1, ownerID: UUID(), documentID: UUID(), root: emptyRoot).validate())
  }
}
