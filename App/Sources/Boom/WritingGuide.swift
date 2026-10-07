import AppKit
import BoomCore
import Foundation

/// A public bundled guide, separate from the manuscript and model context.
@MainActor enum WritingGuide {
  static func load() async throws -> String {
    guard let url = Bundle.module.url(forResource: "WritingGuide", withExtension: "md") else {
      throw BoomError.unavailable("The writing guide is missing from this build.")
    }
    return try await detachedWork { try String(contentsOf: url, encoding: .utf8) }
  }
  static func makeWindow(text: String, frame: NSRect = NSRect(x: 0, y: 0, width: 640, height: 560)) -> NSWindow {
    let window = ApplicationDelegate.workspaceWindow(frame: frame)
    window.title = "Writing with Bloom"
    window.minSize = NSSize(width: 420, height: 380)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
    scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
    let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
    view.isEditable = false; view.isSelectable = true; view.allowsUndo = false
    view.isRichText = true; view.importsGraphics = false; view.usesFindBar = true
    view.drawsBackground = false
    view.isHorizontallyResizable = false; view.isVerticallyResizable = true
    view.autoresizingMask = [.width]
    view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainerInset = NSSize(width: 28, height: 28)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width - 56, height: CGFloat.greatestFiniteMagnitude)
    view.string = text
    MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 17), reading: true)
    scroll.documentView = view
    window.contentView = scroll
    return window
  }
  /// Public bundled content only. Never orders a window or opens a workspace.
  static func capture(arguments: [String]) async throws {
    guard let index = arguments.firstIndex(of: "--evidence"), index+1 < arguments.count,
      arguments[index+1].hasPrefix("/"), arguments.filter({ $0 == "--evidence" }).count == 1 else {
      throw BoomError.invalid("Use --writing-guide-smoke --evidence NEW_ABSOLUTE_DIRECTORY.")
    }
    let root = URL(fileURLWithPath: arguments[index+1])
    guard !FileManager.default.fileExists(atPath: root.path) else { throw BoomError.invalid("Guide evidence already exists.") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let text = try await load()
    var frames: [[String: Any]] = []
    for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
      for width in [CGFloat(420),640] {
        let window = makeWindow(text: text,frame: NSRect(x: -10_000,y: -10_000,width: width,height: 560))
        window.appearance = NSAppearance(named: appearance)
        guard let view = window.contentView else { throw BoomError.invalid("Guide has no native view.") }
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let file = "guide-\(name)-\(Int(width)).png"
        var captured: Result<Data,Error>?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
          captured = Result {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BoomError.invalid("Guide bitmap allocation failed.") }
            view.cacheDisplay(in: view.bounds,to: bitmap)
            guard let bytes = bitmap.representation(using: .png,properties: [:]) else { throw BoomError.invalid("Guide PNG encoding failed.") }
            return bytes
          }
        }
        guard let captured else { throw BoomError.invalid("The guide drawing callback did not run.") }
        let bytes = try captured.get()
        try bytes.write(to: root.appendingPathComponent(file),options: .atomic)
        frames.append(["file":file,"sha256":Digest.sha256(bytes),"width":width,"appearance":name])
        guard !window.isVisible else { throw BoomError.invalid("A guide check showed a window.") }
        window.close()
      }
    }
    let report: [String: Any] = ["status":"complete","pid":ProcessInfo.processInfo.processIdentifier,
      "source_inventory_sha256":Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "guide_sha256":Digest.sha256(text),"frames":frames,"keychain_lookups":VaultSession.shared.lookupCount,
      "shown_window":false,"physical_input_qualified":false]
    try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
      .write(to: root.appendingPathComponent("receipt.json"),options: .atomic)
  }
}
