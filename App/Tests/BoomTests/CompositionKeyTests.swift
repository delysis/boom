import AppKit
import BoomCore
import XCTest
@testable import Boom

final class CompositionKeyTests: XCTestCase {
  @MainActor private final class WorkspaceCleanup {
    private var model: WorkspaceModel?
    private var shutdownAttempted = false
    private var shutdownFailure: Error?
    init(_ model: WorkspaceModel) { self.model = model }
    func close() async throws {
      guard !shutdownAttempted else {
        if let shutdownFailure { throw shutdownFailure }
        return
      }
      shutdownAttempted = true
      guard let model else { return }
      do { try await model.shutdown(); self.model = nil }
      catch { shutdownFailure = error; throw error }
    }
  }
  @MainActor private final class Commands: NSObject, NSTextViewDelegate {
    var cancellations = 0
    var markedAtCancellation: [Bool] = []
    var selectors: [String] = []
    var markedStates: [Bool] = []
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      selectors.append(NSStringFromSelector(commandSelector)); markedStates.append(textView.hasMarkedText())
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        cancellations += 1; markedAtCancellation.append(textView.hasMarkedText())
      }
      return true
    }
  }

  @MainActor func testControlSpacePreservesNativeCommandDispatchInBothTextSurfaces() throws {
    _ = NSApplication.shared
    let policy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.prohibited)
    defer { NSApp.setActivationPolicy(policy) }
    for composing in [false, true] {
      let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
      let reference = NSTextView(frame: frame)
      var observed: [([String], [Bool])] = []
      for editor in [reference, MarkdownTextView(frame: frame), ChatTextView(frame: frame)] {
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
        let controlSpace = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "\u{0}", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        editor.keyDown(with: controlSpace)
        observed.append((commands.selectors, commands.markedStates))
        XCTAssertEqual(editor.string, before)
        XCTAssertFalse(window.isVisible)
      }
      XCTAssertFalse(observed[0].0.isEmpty, "The native reference must actually dispatch Control-Space.")
      for value in observed.dropFirst() {
        XCTAssertEqual(value.0, observed[0].0, "Both text surfaces must preserve the native command.")
        XCTAssertEqual(value.1, observed[0].1, "Native command handling must see the same marked state.")
      }
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
    let app = NSApplication.shared
    let policy = app.activationPolicy()
    if policy != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
    defer { app.setActivationPolicy(policy) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-composition-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    let document = DocumentSnapshot(title: "Public fixture", text: "Café waits.")
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [document])
    let editor = try XCTUnwrap(model.pagedInput?.activeView)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    window.isReleasedWhenClosed = false; window.contentView = try XCTUnwrap(model.pagedViewport)
    let cleanup = WorkspaceCleanup(model), initialFailures = testRun?.failureCount ?? 0
    addTeardownBlock {
      try await cleanup.close()
      await MainActor.run { window.close() }
      if await MainActor.run(body: { self.testRun?.failureCount ?? 0 }) == initialFailures {
        try FileManager.default.removeItem(at: root)
      }
    }
    window.center(); window.showAsInvisibleNativeTestWindow(); app.activate(ignoringOtherApps: true)
    guard window.makeFirstResponder(editor), window.isKeyWindow, app.isActive,
      window.firstResponder === editor else {
      throw XCTSkip("Escape routing requires an actual active key window; native acceptance is measured in the app run.")
    }
    editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
    model.movedCaret(document.text.utf16.count, hasMarkedText: false)
    // Explicitly authored test suggestion, not represented as model output.
    model.resumeGhost(" A public suggestion.", documentID: document.id, caret: document.text.utf16.count, sources: [])
    let stamp = try XCTUnwrap(model.ghostStamp)
    XCTAssertEqual(editor.completionClient?.ghostStamp, stamp)
    XCTAssertFalse(editor.hasMarkedText())
    let commands = Commands(); editor.delegate = commands
    let controlSpace = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
      characters: "\u{0}", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    editor.keyDown(with: controlSpace)
    XCTAssertEqual(model.ghostStamp, stamp, "A native input shortcut must not discard a captured continuation.")
    XCTAssertEqual(model.ghostText, " A public suggestion.")
    let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    editor.keyDown(with: escape)
    XCTAssertNil(model.ghostStamp); XCTAssertTrue(model.ghostText.isEmpty)
    XCTAssertEqual(commands.cancellations, 0)
    XCTAssertEqual(editor.string, document.text); XCTAssertEqual(model.selectedDocument, document)
    XCTAssertEqual(editor.selectedRange().location, stamp.caretUTF16)
    try await cleanup.close()
    let restored = try await NativeCheckEvidence.readPublicDocuments(store: store)
    XCTAssertEqual(restored, [document])
    if (testRun?.failureCount ?? 0) == initialFailures { try FileManager.default.removeItem(at: root) }
  }
}
