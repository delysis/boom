import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class NativeSourceIdentityTests: XCTestCase {
  @MainActor private final class CharacterEdits: NSObject, NSTextStorageDelegate {
    var count = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int) {
      if editedMask.contains(.editedCharacters) { count += 1 }
    }
  }

  @MainActor func testNativeEditAndUndoSurviveRepeatedStatusUpdatesWithoutSourceReplacement() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-status-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DocumentSnapshot(title: "Public source", text: "Café 👩🏽‍💻 waits.")
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [.init(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw XCTSkip("The Chat edition has no manuscript pane.") }
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    let editor = try XCTUnwrap(model.editor), storage = try XCTUnwrap(editor.textStorage)
    let edits = CharacterEdits(); storage.delegate = edits
    defer { storage.delegate = nil }
    model.isBusy = true
    XCTAssertTrue(window.makeFirstResponder(editor))
    let suffix = " A lantern."
    editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
    editor.insertText(suffix, replacementRange: editor.selectedRange())
    let editCount = edits.count
    XCTAssertGreaterThan(editCount, 0)
    for index in 0..<12 {
      model.status = "Public status \(index)"; model.streamingText = "Public progress \(index)"
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(edits.count, editCount, "Status rendering must not replace the native source.")
    XCTAssertEqual(Data(editor.string.utf8), Data((document.text + suffix).utf8))
    XCTAssertEqual(editor.selectedRange(), NSRange(location: (document.text + suffix).utf16.count, length: 0))
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertTrue(editor.documentUndo?.canUndo == true)
    editor.documentUndo?.undo()
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(Data(editor.string.utf8), Data(document.text.utf8))
    XCTAssertEqual(Data(try XCTUnwrap(model.selectedDocument).text.utf8), Data(document.text.utf8))
    try await model.shutdown()
  }

  @MainActor func testExternalCanonicalFormChangeReachesEditorAndSearchAtExactOffsets() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-source-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DocumentSnapshot(title: "Public source", text: "Café\nA lantern.")
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [.init(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw XCTSkip("The Chat edition has no manuscript pane.") }
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    let editor = try XCTUnwrap(model.editor)
    model.isBusy = true
    let replacement = "Cafe\u{301}\nA lantern."
    XCTAssertEqual(document.text, replacement, "This fixture must be canonically equivalent.")
    XCTAssertNotEqual(Data(document.text.utf8), Data(replacement.utf8))
    model.updateDocument(replacement, id: document.id, caret: 0)
    model.librarySearch = "lantern"
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if model.documentSearch[document.id]?.revision == model.selectedDocument?.revision { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(Data(editor.string.utf8), Data(replacement.utf8), "The rendered source must retain the model's exact canonical form.")
    let match = (replacement as NSString).range(of: "lantern")
    var highlighted = NSRange(location: NSNotFound, length: 0)
    let color = editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: match.location,
      effectiveRange: &highlighted)
    XCTAssertNotNil(color); XCTAssertEqual(highlighted, match)
    if color != nil, highlighted.location != NSNotFound, NSMaxRange(highlighted) <= editor.string.utf16.count {
      XCTAssertEqual((editor.string as NSString).substring(with: highlighted), "lantern")
    }
    model.librarySearch = ""
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: match.location,
      effectiveRange: nil))
    try await model.flush()
    let restored = try await store.load().get().1
    let saved = try XCTUnwrap(restored.first { $0.id == document.id })
    XCTAssertEqual(Data(saved.text.utf8), Data(replacement.utf8))
    try await model.shutdown()
  }

  @MainActor func testMediaRangeRefreshesWhenCanonicalFormChangesBeforeReference() throws {
    _ = NSApplication.shared
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let reference = "[Attachment: public.png](boom-attachment:D5739A90-5E3D-4B91-A5B9-92DE213C9FD2)"
    let original = "Café\n" + reference
    let replacement = "Cafe\u{301}\n" + reference
    XCTAssertEqual(original, replacement)
    view.string = original; view.setMedia(model: nil)
    let first = try XCTUnwrap(view.inlineMedia.spans.first)
    XCTAssertEqual(first.range, (original as NSString).range(of: reference))
    view.string = replacement; view.setMedia(model: nil)
    let updated = try XCTUnwrap(view.inlineMedia.spans.first)
    XCTAssertEqual(updated.range, (replacement as NSString).range(of: reference),
      "Media spans must follow the exact UTF16 source, even when display text is canonically equivalent.")
    XCTAssertEqual(updated.location, first.location + 1)
    XCTAssertEqual(Data(view.string.utf8), Data(replacement.utf8))
  }

  @MainActor func testAccessibleCanonicalFormReplacementPreservesBytesAndNativeUndo() throws {
    _ = NSApplication.shared
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let undo = UndoManager(); view.documentUndo = undo; view.allowsUndo = true
    let original = "Café", replacement = "Cafe\u{301}"
    view.string = original; undo.removeAllActions()
    view.setAccessibilityValue(replacement)
    XCTAssertEqual(Data(view.string.utf8), Data(replacement.utf8))
    XCTAssertTrue(undo.canUndo)
    undo.undo()
    XCTAssertEqual(Data(view.string.utf8), Data(original.utf8))
  }
}
