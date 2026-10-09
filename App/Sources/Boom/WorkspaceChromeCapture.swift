import AppKit
import BoomCore
import CryptoKit
import SwiftUI

/// Capture complete native chrome, not a hand-built imitation of the toolbar.
/// This public fixture stays offscreen and never opens a human vault.
@MainActor enum WorkspaceChromeCapture {
  static func run(evidence: URL) async throws {
    let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("chrome-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 37, count: 32)))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.state.autocomplete = false
    if let document = model.selectedDocument {
      model.renameDocument(document.id, to: "Harbor notes")
      model.updateDocument("# At the harbor\n\nThe boats were still tied up when Mara arrived.\n\nShe set the spool on the bench and opened her hand.",
        id: document.id, caret: 0)
    }
    if model.selectedChat == nil { try model.newChat(about: model.state.selectedDocument) }
    model.authorChatMessage(.user); model.draft = "Where could this scene go next?"; model.send()
    model.authorChatMessage(.assistant)
    model.draft = "Let the arrival change something small: a familiar boat is missing, or someone recognizes what Mara is carrying."
    model.send(); model.authoredChatRole = nil
    if let chat = model.selectedChat { model.renameChat(chat.id, to: "A scene at the harbor") }
    model.state.showLibrary = true; model.state.showDocument = true; model.state.showChat = true
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 780))
    let delegate = ApplicationDelegate()
    delegate.configureWorkspaceWindow(window, model: model)
    defer { window.close() }
    guard let host = window.contentView, let frame = host.superview else { throw BoomError.invalid("Native workspace chrome is missing.") }
    func inputs(_ view: NSView) -> [ChatTextView] {
      if let text = view as? ChatTextView { return [text] }
      return view.subviews.flatMap(inputs)
    }
    func settle() async throws {
      for _ in 0..<4 {
        frame.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
      }
    }
    func capture(_ name: String) throws {
      frame.displayIfNeeded()
      guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw BoomError.invalid("Native chrome bitmap unavailable.") }
      frame.cacheDisplay(in: frame.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Native chrome PNG unavailable.") }
      try png.write(to: evidence.appendingPathComponent(name + ".png"), options: .atomic)
    }
    var observations: [[String: Any]] = []
    do {
      for dark in [false, true] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let widths = model.layout.isAuthor ? [1190.0, 980, 750, 1190] : [1000.0, 540, 1000]
        for (index, width) in widths.enumerated() {
          window.setContentSize(NSSize(width: width, height: index == 1 ? 560 : 780))
          model.fitPanes(to: width)
          try await settle()
          guard let input = inputs(host).last else { throw BoomError.invalid("Workspace composer is missing.") }
          window.makeFirstResponder(input)
          input.setAccessibilityValue("")
          try await settle()
          let name = "workspace-\(dark ? "dark" : "light")-\(index)-\(Int(width))"
          try capture(name + "-empty")
          input.insertText("At the harbor,", replacementRange: input.selectedRange())
          try await settle(); try capture(name + "-typed")
          guard model.draft == "At the harbor," else { throw BoomError.invalid("Native composer did not publish typed text.") }
          observations.append(["name": name, "width": host.bounds.width, "height": host.bounds.height,
            "library": model.showsLibrary, "document": model.showsDocument, "chat": model.showsChat,
            "composerHeight": input.enclosingScrollView?.bounds.height ?? 0,
            "firstGlyph": input.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil).debugDescription])
        }
        if model.layout.isAuthor, let document = model.selectedDocument {
          let longText = document.text + "\n\n" + (1...40).map {
            "\($0). The tide carried the boats past the harbor wall. Mara watched until the last light disappeared."
          }.joined(separator: "\n\n")
          model.updateDocument(longText, id: document.id, caret: 0)
          try await settle(); try capture("workspace-\(dark ? "dark" : "light")-long-top")
          if let editor = model.editor {
            let end = NSRange(location: editor.string.utf16.count, length: 0)
            editor.setSelectedRange(end); editor.scrollRangeToVisible(end)
          }
          try await settle(); try capture("workspace-\(dark ? "dark" : "light")-long-end")
          model.updateDocument(document.text, id: document.id, caret: 0)
          try await settle()
        }
      }
      guard !window.isVisible else { throw BoomError.invalid("The background chrome fixture became visible.") }
      try await model.shutdown()
      try JSONSerialization.data(withJSONObject: ["status": "passed", "observations": observations,
        "sourceInventorySHA256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
        "pid": ProcessInfo.processInfo.processIdentifier, "keychainLookups": VaultSession.shared.lookupCount,
        "window": "unshown"], options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("chrome-receipt.json"), options: .atomic)
    } catch {
      try await model.shutdown()
      throw error
    }
  }
}
