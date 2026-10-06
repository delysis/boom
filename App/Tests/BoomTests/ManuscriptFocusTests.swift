import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class ManuscriptFocusTests: XCTestCase {
  @MainActor func testProductionWindowAndRenderedPageAcceptFocusAndTypingWhileBusy() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-caret-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Caret fixture", text: "The harbor was quiet.")
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw XCTSkip("The chat edition has no manuscript pane.") }
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: WorkspaceView(model: model)); window.contentView = host
    for _ in 0..<10 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(25))
    }
    let editor = try XCTUnwrap(model.editor)
    // An unshown window cannot be main, but must allow keyboard focus.
    XCTAssertTrue(window.canBecomeKey, "The production window must allow keyboard focus.")
    XCTAssertTrue(editor.acceptsFirstMouse(for: nil)); XCTAssertTrue(editor.isEditable); XCTAssertTrue(editor.isSelectable)
    // The empty portion of a manuscript page must also be an editor hit area.
    let local = NSPoint(x: editor.bounds.midX, y: min(editor.bounds.maxY - 8, 300))
    let inHostParent = editor.convert(local, to: host.superview)
    let hit = host.hitTest(inHostParent)
    XCTAssertTrue(hit === editor, "Editor \(editor.frame) bounds \(editor.bounds), host \(host.frame), point \(inHostParent), hit \(String(describing: hit))")
    model.isBusy = true; host.layoutSubtreeIfNeeded()
    XCTAssertTrue(editor.isEditable)
    XCTAssertTrue(window.makeFirstResponder(editor)); XCTAssertTrue(window.firstResponder === editor)
    editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
    editor.insertText(" A lantern moved.", replacementRange: editor.selectedRange())
    XCTAssertEqual(editor.selectedRange().length, 0)
    XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
    XCTAssertEqual(model.selectedDocument?.text, document.text + " A lantern moved.")
    model.isBusy = false
    try await model.flush()
    let reopened = try await store.load().get().1.first(where: { $0.id == document.id })
    XCTAssertEqual(reopened?.text, editor.string)
    try await model.shutdown()
  }
}
