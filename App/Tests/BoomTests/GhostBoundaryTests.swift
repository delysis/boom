import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class GhostBoundaryTests: XCTestCase {
  @MainActor private func key(_ code: UInt16, in editor: MarkdownTextView) throws {
    editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window?.windowNumber ?? 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
  }
  @MainActor private func fixture() async throws -> (WorkspaceModel, NSWindow, MarkdownTextView, DocumentSnapshot, DocumentSnapshot) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-word-boundary-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Public manuscript", text: "At the harbor.")
    let example = DocumentSnapshot(title: "Public example", text: "The lantern gleamed.")
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [document, example].map { DocumentIndex(id: $0.id, title: $0.title) }
    state.selectedDocument = document.id
    try await store.save(state, documents: [document, example])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw XCTSkip("The chat edition has no manuscript.") }
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1190, height: 800))
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: WorkspaceView(model: model)); window.contentView = host
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    let editor = try XCTUnwrap(model.editor)
    window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
    model.movedCaret(document.text.utf16.count, hasMarkedText: false)
    return (model, window, editor, document, example)
  }
  @MainActor func testRepeatedRightLeftPreservesRealSourcesRemainderAndExactManuscriptBytes() async throws {
    let (model, window, editor, original, example) = try await fixture()
    defer { window.close() }
    let sources = [original, example].map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }
    let words = [" Café ", "👩🏽‍💻 ", "waits.\n", "A ", "lantern ", "moved."]
    let continuation = words.joined()
    model.resumeGhost(continuation, documentID: original.id, caret: editor.selectedRange().location, sources: sources)
    for _ in 0..<3 {
      for i in words.indices {
        try key(124, in: editor)
        XCTAssertEqual(editor.string, original.text + words.prefix(i + 1).joined())
        XCTAssertEqual(model.selectedDocument?.text, editor.string)
        XCTAssertEqual(model.ghostText, words.dropFirst(i + 1).joined())
      }
      try key(124, in: editor) // At the end, an extra Right preserves reversibility.
      for i in words.indices.reversed() {
        try key(123, in: editor)
        XCTAssertEqual(editor.string, original.text + words.prefix(i).joined())
        XCTAssertEqual(model.ghostText, words.dropFirst(i).joined())
      }
      XCTAssertEqual(model.selectedDocument, original)
    }
    try key(124, in: editor)
    editor.insertText("Typed", replacementRange: editor.selectedRange())
    let edited = editor.string
    XCTAssertNil(model.ghostStamp)
    try key(123, in: editor)
    XCTAssertEqual(editor.string, edited, "An ordinary edit must terminate the completion boundary.")
    try await model.shutdown()
  }
  @MainActor func testChangingAnExampleEndsTheBoundaryWithoutDeletingAcceptedWords() async throws {
    let (model, window, editor, original, example) = try await fixture()
    defer { window.close() }
    let sources = [original, example].map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }
    model.resumeGhost(" One two three.", documentID: original.id, caret: editor.selectedRange().location, sources: sources)
    try key(124, in: editor)
    let accepted = editor.string
    model.updateDocument("Changed example.", id: example.id, caret: editor.selectedRange().location)
    try key(123, in: editor)
    XCTAssertEqual(editor.string, accepted)
    XCTAssertNil(model.ghostStamp)
    try await model.shutdown()
  }
}
