import AppKit

@MainActor extension NSWindow {
  /// Keep a real attached AppKit window for responder and layout tests without
  /// exposing the test fixture over the user's desktop. Some window managers
  /// still surface transparent key windows, so keep the fixture off-screen too.
  func showAsInvisibleNativeTestWindow() {
    alphaValue = 0
    setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    makeKeyAndOrderFront(nil)
  }
}
