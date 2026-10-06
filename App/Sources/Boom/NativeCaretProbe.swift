import AppKit
import BoomCore

/// Explicit public-fixture checks only. No WindowServer input or activation.
@MainActor enum NativeCaretProbe {
  struct Observation: Codable {
    let documentID: UUID
    let beforeLocation: Int
    let beforeLength: Int
    let afterLocation: Int
    let afterLength: Int
    let acquiredEditorFocus: Bool
    let windowStayedUnshown: Bool
  }
  static func point(at caret: Int, in editor: MarkdownTextView) throws -> NSPoint {
    guard caret >= 0, caret <= editor.string.utf16.count, let window = editor.window,
      let layout = editor.layoutManager, let container = editor.textContainer else {
      throw BoomError.invalid("The public caret fixture has no native layout.")
    }
    editor.scrollRangeToVisible(NSRange(location: caret, length: 0))
    layout.ensureLayout(for: container)
    let screen = editor.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
    let local = editor.convert(window.convertFromScreen(screen), from: nil)
    guard local.minX.isFinite, local.midY.isFinite, local.height > 0 else {
      throw BoomError.invalid("The public caret fixture has no insertion rectangle.")
    }
    return NSPoint(x: local.minX + 0.1, y: local.midY)
  }
  static func click(_ point: NSPoint, in editor: MarkdownTextView) throws -> Observation {
    guard NSApp.activationPolicy() == .prohibited, let window = editor.window,
      !window.isVisible, let content = window.contentView else {
      throw BoomError.invalid("Native caret checks require an unshown public-fixture window and prohibited activation.")
    }
    let before = editor.selectedRange()
    let hitPoint = editor.convert(point, to: content.superview)
    guard let receiver = content.hitTest(hitPoint), receiver === editor else {
      throw BoomError.invalid("The rendered public manuscript did not receive its caret click.")
    }
    let location = editor.convert(point, to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
      modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location,
        modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else {
      throw BoomError.invalid("The public caret mouse events could not be constructed.")
    }
    // NSTextView tracks in this application's event queue. This is not a
    // globally posted mouse event and cannot target another app's window.
    NSApp.postEvent(up, atStart: true)
    receiver.mouseDown(with: down)
    let after = editor.selectedRange()
    let observation = Observation(documentID: editor.documentID,
      beforeLocation: before.location, beforeLength: before.length,
      afterLocation: after.location, afterLength: after.length,
      acquiredEditorFocus: window.firstResponder === editor, windowStayedUnshown: !window.isVisible)
    guard observation.acquiredEditorFocus, observation.windowStayedUnshown else {
      throw BoomError.invalid("The public caret click lost editor focus or showed its window.")
    }
    return observation
  }
}
