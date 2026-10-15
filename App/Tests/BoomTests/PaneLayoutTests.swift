import AppKit
import SwiftUI
import XCTest
@testable import Boom

@MainActor private final class PaneFocusTextView: NSTextView {
  var windowDepartures = 0
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window != nil, newWindow == nil { windowDepartures += 1 }
    super.viewWillMove(toWindow: newWindow)
  }
}

@MainActor private struct PaneFocusEditor: NSViewRepresentable {
  let editor: PaneFocusTextView
  func makeNSView(context: Context) -> PaneFocusTextView { editor }
  func updateNSView(_ view: PaneFocusTextView, context: Context) {}
}

@MainActor final class PaneLayoutTests: XCTestCase {
  func testChangingSiblingPanesRetainsMountedEditorResponderAndActualUndo() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let split = PaneLayout.ShadeSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    split.isVertical = true
    let coordinator = PaneLayout.Coordinator()
    split.delegate = coordinator
    window.contentView = split
    let editor = PaneFocusTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
    editor.isRichText = false; editor.allowsUndo = true; editor.string = "author"
    func pane(_ id: String) -> PaneLayout.Pane {
      let content = id == "document" ? AnyView(PaneFocusEditor(editor: editor)) : AnyView(Color.clear)
      return .init(id: id, content: content, minimum: 100, preferred: 250,
        maximum: id == "document" ? .infinity : 300)
    }
    coordinator.update([pane("document"), pane("chat")], in: split)
    split.layoutSubtreeIfNeeded()
    XCTAssertTrue(editor.window === window)
    XCTAssertTrue(window.makeFirstResponder(editor))
    let manager = try XCTUnwrap(editor.undoManager)
    manager.groupsByEvent = false
    manager.beginUndoGrouping()
    editor.insertText("!", replacementRange: NSRange(location: 6, length: 0))
    editor.breakUndoCoalescing()
    manager.endUndoGrouping()
    XCTAssertEqual(editor.string, "author!"); XCTAssertTrue(manager.canUndo)
    let documentHost = try XCTUnwrap(coordinator.hosts["document"])
    let departures = editor.windowDepartures

    for ids in [["library", "document", "chat"], ["library", "document"],
      ["document", "library"], ["document", "chat"]] {
      coordinator.update(ids.map(pane), in: split)
      split.layoutSubtreeIfNeeded()
      XCTAssertTrue(coordinator.hosts["document"] === documentHost)
      XCTAssertTrue(documentHost.superview === split)
      XCTAssertTrue(editor.window === window)
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertTrue(editor.undoManager === manager)
      XCTAssertEqual(editor.windowDepartures, departures)
      XCTAssertEqual(split.subviews.count, ids.count)
      for (index, id) in ids.enumerated() {
        XCTAssertTrue(split.subviews[index] === coordinator.hosts[id])
      }
      XCTAssertEqual(editor.string, "author!"); XCTAssertTrue(manager.canUndo)
    }
    manager.undo(); XCTAssertEqual(editor.string, "author")
    manager.redo(); XCTAssertEqual(editor.string, "author!")
  }
}
