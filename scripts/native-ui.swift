#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

// Developer native acceptance driver. Explicit PID and bounded AX traversal.
struct Failure: Error { let message: String }
func attribute(_ element: AXUIElement, _ name: String) -> Any? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
  let result = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  if result.isEmpty, attribute(element, kAXRoleAttribute) as? String == kAXApplicationRole,
    let focused = attribute(element, kAXFocusedWindowAttribute) { return [focused as! AXUIElement] }
  return result
}
func describe(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
  var result: [String: Any] = [:]
  for key in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute] {
    if let value = attribute(element, key) as? String { result[key] = String(value.prefix(1024)) }
    else if let value = attribute(element, key) as? NSNumber { result[key] = value }
  }
  if depth < 14 { result["children"] = children(element).prefix(200).map { describe($0, depth: depth + 1) } }
  return result
}
func find(_ element: AXUIElement, label: String, role: String?, depth: Int = 0) -> AXUIElement? {
  guard depth < 18 else { return nil }
  let actualRole = attribute(element, kAXRoleAttribute) as? String
  let matches = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute].contains {
    (attribute(element, $0) as? String) == label
  }
  if matches, role == nil || actualRole == role { return element }
  for child in children(element) { if let found = find(child, label: label, role: role, depth: depth + 1) { return found } }
  return nil
}
func control(_ application: AXUIElement, label: String, role: String?) -> AXUIElement? {
  // A window's Save button must not resolve to a menu-bar command with the
  // same title. Search visible windows before considering menu controls.
  var windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
  if windows.isEmpty, let focused = attribute(application, kAXFocusedWindowAttribute) {
    windows = [focused as! AXUIElement]
  }
  for window in windows { if let result = find(window, label: label, role: role) { return result } }
  return find(application, label: label, role: role)
}
func run(_ args: [String] = CommandLine.arguments) throws {
  guard args.count >= 3, let pid = Int32(args[1]), AXIsProcessTrusted() else { throw Failure(message: "Use a live PID and grant Accessibility to the driver.") }
  let application = AXUIElementCreateApplication(pid)
  switch args[2] {
  case "sequence":
    guard args.count == 4 else { throw Failure(message: "Missing action sequence.") }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    guard bytes.count <= 65_536 else { throw Failure(message: "Action sequence exceeds 64 KiB.") }
    let actions = try JSONDecoder().decode([[String]].self, from: bytes)
    guard actions.count <= 128, actions.allSatisfy({ !$0.isEmpty && $0[0] != "sequence" }) else { throw Failure(message: "Invalid action sequence.") }
    for action in actions {
      try run([args[0], args[1]] + action)
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
  case "tree":
    var windows = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if windows.isEmpty, let focused = attribute(application, kAXFocusedWindowAttribute) { windows = [focused as! AXUIElement] }
    let bytes = try JSONSerialization.data(withJSONObject: ["windows": windows.map { describe($0) }], options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
  case "click":
    guard CGPreflightPostEventAccess(), args.count >= 4, let element = control(application, label: args[3], role: nil),
      let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { throw Failure(message: "Control geometry not found.") }
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure(message: "Activate the target window before clicking.") }
    let point = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
      guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw Failure(message: "Cannot click control.") }
      event.post(tap: .cghidEventTap)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  case "press", "set", "focus":
    guard args.count >= 4, let element = control(application, label: args[3], role: args.count > 5 ? args[5] : nil) else { throw Failure(message: "Control not found.") }
    let status: AXError
    if args[2] == "press" { status = AXUIElementPerformAction(element, kAXPressAction as CFString) }
    else if args[2] == "focus" { status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    else {
      guard args.count >= 5 else { throw Failure(message: "Missing field value.") }
      status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[4] as CFString)
    }
    guard status == .success else { throw Failure(message: "Accessibility action failed: \(status.rawValue)") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    if args[2] == "focus" {
      guard let focused = attribute(application, kAXFocusedUIElementAttribute),
        CFEqual(focused as AnyObject, element) else { throw Failure(message: "Requested control did not receive focus.") }
    }
  case "range":
    guard args.count == 6, let start = Int(args[4]), let length = Int(args[5]), start >= 0, length >= 0,
      let element = find(application, label: args[3], role: "AXTextArea") else { throw Failure(message: "Invalid text range." ) }
    var range = CFRange(location: start, length: length)
    guard let value = AXValueCreate(.cfRange, &range),
      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { throw Failure(message: "Range change failed." ) }
  case "read-value":
    guard args.count >= 4, let element = find(application, label: args[3], role: args.count > 4 ? args[4] : nil),
      let value = attribute(element, kAXValueAttribute) as? String else { throw Failure(message: "No text value for this control.") }
    print(value, terminator: "")
  case "type-file":
    guard CGPreflightPostEventAccess(), args.count == 4 else { throw Failure(message: "Missing text fixture path or event-post permission.") }
    let url = URL(fileURLWithPath: args[3])
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_097_152 else { throw Failure(message: "Fixture exceeds 2 MiB.") }
    let string = try String(contentsOf: url, encoding: .utf8)
    var start = string.startIndex
    while start < string.endIndex {
      let end = string.index(start, offsetBy: 8, limitedBy: string.endIndex) ?? string.endIndex
      let units = Array(string[start..<end].utf16)
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { throw Failure(message: "Cannot type fixture.") }
      event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure(message: "Activate the target before typing.") }
      event.post(tap: .cghidEventTap)
      start = end
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  case "key":
    guard CGPreflightPostEventAccess(), args.count >= 4, let code = UInt16(args[3]) else { throw Failure(message: "Missing key code or event-post permission.") }
    var flags: CGEventFlags = []
    if args.count > 4 {
      if args[4].contains("command") { flags.insert(.maskCommand) }
      if args[4].contains("option") { flags.insert(.maskAlternate) }
      if args[4].contains("shift") { flags.insert(.maskShift) }
      if args[4].contains("control") { flags.insert(.maskControl) }
    }
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw Failure(message: "Could not create key event.") }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure(message: "Activate the target before typing.") }
      event.flags = flags; event.post(tap: .cghidEventTap)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  case "size":
    guard args.count == 5, let width = Double(args[3]), let height = Double(args[4]),
      let window = attribute(application, kAXWindowsAttribute) as? [AXUIElement], let first = window.first else { throw Failure(message: "Missing window dimensions.") }
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size),
      AXUIElementSetAttributeValue(first, kAXSizeAttribute as CFString, value) == .success else { throw Failure(message: "Resize failed.") }
  case "activate":
    guard let running = NSRunningApplication(processIdentifier: pid) else { throw Failure(message: "Process is no longer running.") }
    running.unhide()
    guard running.activate(options: [.activateAllWindows]) else { throw Failure(message: "The target could not activate.") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
  case "frontmost":
    if let running = NSWorkspace.shared.frontmostApplication { print("\(running.processIdentifier) \(running.localizedName ?? "")") }
  case "window-id":
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }) else { throw Failure(message: "No visible native window.") }
    print(window[kCGWindowNumber as String]!)
  default: throw Failure(message: "Unknown action.")
  }
}
do { try run() } catch { fputs("Native UI driver failed: \(error)\n", stderr); exit(1) }
