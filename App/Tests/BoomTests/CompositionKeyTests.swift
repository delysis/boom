import AppKit
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class CompositionKeyTests: XCTestCase {
  @MainActor private final class Commands: NSObject, NSTextViewDelegate {
    var cancellations = 0
    var markedAtCancellation: [Bool] = []
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      cancellations += 1; markedAtCancellation.append(textView.hasMarkedText())
      return true
    }
  }

  @MainActor func testEscapeReachesNativeCommandHandlingWithAndWithoutComposition() throws {
    _ = NSApplication.shared
    let policy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.prohibited)
    defer { NSApp.setActivationPolicy(policy) }
    for composing in [false, true] {
      let reference = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
      let manuscript = MarkdownTextView(frame: reference.frame)
      var observed: [(Int, [Bool])] = []
      for editor in [reference, manuscript] {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 300),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let commands = Commands(); editor.delegate = commands
        editor.isRichText = false; editor.string = "Café waits."
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        if composing {
          editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
          XCTAssertTrue(editor.hasMarkedText())
        }
        let before = editor.string
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        editor.keyDown(with: escape)
        observed.append((commands.cancellations, commands.markedAtCancellation))
        XCTAssertEqual(editor.string, before)
        XCTAssertFalse(window.isVisible)
      }
      XCTAssertEqual(observed[0].0, 1, "The native reference must actually receive Escape.")
      XCTAssertEqual(observed[1].0, observed[0].0, "The manuscript must preserve native command dispatch.")
      XCTAssertEqual(observed[1].1, observed[0].1, "The input method must receive the same composition state.")
    }
  }

  @MainActor func testEscapeDismissesCapturedContinuationWithoutChangingManuscript() async throws {
    _ = NSApplication.shared
    let policy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.prohibited)
    defer { NSApp.setActivationPolicy(policy) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-composition-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Public fixture", text: "Café waits.")
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    editor.owner = model; editor.documentID = document.id; editor.string = document.text
    editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
    model.editor = editor; model.movedCaret(document.text.utf16.count, hasMarkedText: false)
    // Explicitly authored test suggestion, not represented as model output.
    model.resumeGhost(" A public suggestion.", documentID: document.id, caret: document.text.utf16.count, sources: [])
    let stamp = try XCTUnwrap(model.ghostStamp)
    let commands = Commands(); editor.delegate = commands
    let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    editor.keyDown(with: escape)
    XCTAssertNil(model.ghostStamp); XCTAssertTrue(model.ghostText.isEmpty)
    XCTAssertEqual(commands.cancellations, 0)
    XCTAssertEqual(editor.string, document.text); XCTAssertEqual(model.selectedDocument, document)
    XCTAssertEqual(editor.selectedRange().location, stamp.caretUTF16)
    try await model.shutdown()
    let restored = try await store.load().get().1
    XCTAssertEqual(restored, [document])
  }
}
