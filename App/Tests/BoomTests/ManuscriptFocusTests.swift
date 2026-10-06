import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class ManuscriptFocusTests: XCTestCase {
  @MainActor private func click(_ point: NSPoint, in editor: MarkdownTextView) throws {
    let result = try NativeCaretProbe.click(point, in: editor)
    XCTAssertTrue(result.acquiredEditorFocus); XCTAssertTrue(result.windowStayedUnshown)
  }

  @MainActor func testRenderedManuscriptClickPlacesCaretWithoutPreassigningEditorFocus() async throws {
    _ = NSApplication.shared
    let previousPolicy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.prohibited)
    defer { NSApp.setActivationPolicy(previousPolicy) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-native-caret-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Mouse fixture", text: "Café 👩🏽‍🚀 waits.\nThe lantern moved.")
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw XCTSkip("The chat edition has no manuscript pane.") }
    for width in [1440, 760] {
      for dark in [true, false] {
        model.fitPanes(to: CGFloat(width))
        let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: width, height: 846))
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: WorkspaceView(model: model).environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        for _ in 0..<10 {
          host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try XCTUnwrap(model.editor)
        model.isBusy = true; host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(nil)); XCTAssertFalse(window.firstResponder === editor)
        let blank = NSPoint(x: editor.bounds.midX, y: min(editor.bounds.maxY - 8, 300))
        try click(blank, in: editor)
        XCTAssertTrue(window.firstResponder === editor, "A click must acquire text focus without test assistance.")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: document.text.utf16.count, length: 0))
        // Authored fixture, not a model output. An unchanged click must preserve a
        // valid continuation; moving the caret must still invalidate it.
        model.resumeGhost(" A public suggestion.", documentID: document.id,
          caret: document.text.utf16.count, sources: [])
        let capturedStamp = try XCTUnwrap(model.ghostStamp)
        try click(blank, in: editor)
        try click(NativeCaretProbe.point(at: document.text.utf16.count, in: editor), in: editor)
        XCTAssertEqual(model.ghostStamp, capturedStamp, "Refocusing at the same caret must not invalidate the captured request.")
        XCTAssertEqual(model.ghostText, " A public suggestion.")
        XCTAssertTrue(editor.acceptNextGhostWord())
        XCTAssertNotEqual(model.selectedDocument?.text, document.text)
        try click(NativeCaretProbe.point(at: editor.selectedRange().location, in: editor), in: editor)
        let reverseWord = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        editor.keyDown(with: reverseWord)
        XCTAssertEqual(model.selectedDocument, document, "Refocusing an unchanged caret must preserve Option-Left reversal of a word acceptance.")
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let firstGlyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let first = NSPoint(x: editor.textContainerOrigin.x + firstGlyph.minX + 0.1,
          y: editor.textContainerOrigin.y + firstGlyph.midY)
        try click(first, in: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0), "The text click must move the caret to the clicked glyph.")
        XCTAssertNil(model.ghostStamp); XCTAssertEqual(model.ghostText, "")
        XCTAssertEqual(model.selectedDocument, document)
        XCTAssertTrue(editor.isEditable)
      }
    }
    model.isBusy = false
    try await model.shutdown()
  }

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
