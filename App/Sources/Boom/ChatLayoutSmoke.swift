import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// This process's own offscreen public fixture only. No user workspace, model,
/// network, Keychain, or foreground window is needed to qualify row reflow.
@MainActor enum ChatLayoutSmoke {
  static func run(arguments: [String]) async throws {
    guard let index = arguments.firstIndex(of: "--evidence"), index + 1 < arguments.count,
      arguments[index + 1].hasPrefix("/") else {
      throw BoomError.invalid("Chat layout qualification requires a fresh absolute evidence directory.")
    }
    let evidence = URL(fileURLWithPath: arguments[index + 1])
    guard !FileManager.default.fileExists(atPath: evidence.path) else { throw BoomError.invalid("Chat layout evidence already exists.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("public-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 73, count: 32)))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    let texts = [
      "It looks like you've entered \"stuff\" as a placeholder or a general query. Since there isn't a specific task or instruction provided, could you please clarify how you would like me to help?",
      "sure, proofread my memo and see if you can improve it.",
      "I can assist with analyzing the document, proofreading, drafting new content, or answering questions based on the text. Just let me know what you have in mind!",
      "# At the harbor\n\n- A long list with **bold** and *emphasized* words. " + String(repeating: "The river turns past the old house. ", count: 5),
      "Unicode: 👩🏽‍💻 café e\u{301} 日本語.\n\n" + String(repeating: "A paragraph that wraps at different pane widths. ", count: 5),
    ]
    for (index, text) in texts.enumerated() {
      model.authorChatMessage(index == 1 ? .user : .assistant); model.draft = text; model.send()
    }
    if let document = model.selectedDocument {
      model.state.autocomplete = false
      model.updateDocument("# Public manuscript\n\n" + String(repeating: "The river turns past the old house. 👩🏽‍💻 café 日本語. ", count: 25),
        id: document.id, caret: 0)
    }
    model.state.showLibrary = false; model.state.showChat = true
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 1800))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    var observations: [[String: Any]] = []
    func settle() async throws {
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    }
    func reading(_ view: NSView) -> [NativeReadingTextView] {
      if let text = view as? NativeReadingTextView { return [text] }
      return view.subviews.flatMap(reading)
    }
    func split(_ view: NSView) -> NSSplitView? {
      if let view = view as? NSSplitView { return view }
      return view.subviews.lazy.compactMap(split).first
    }
    func inspect(_ name: String, expected: Int) throws {
      let views = reading(host)
      guard views.count == expected else { throw BoomError.invalid("Chat layout fixture lost a message row.") }
      var rows: [[String: Any]] = []
      for view in views {
        guard let container = view.textContainer, let layout = view.layoutManager else { throw BoomError.invalid("A reading surface has no native layout.") }
        layout.ensureLayout(for: container)
        let glyphs = layout.usedRect(for: container)
        guard glyphs.maxY <= view.bounds.height + 1, glyphs.maxX <= view.bounds.width + 1 else {
          throw BoomError.invalid("Rendered glyphs exceeded their assigned message row during " + name)
        }
        rows.append(["sourceSHA256": Digest.sha256(view.string), "width": view.bounds.width,
          "height": view.bounds.height, "glyphWidth": glyphs.maxX, "glyphHeight": glyphs.maxY])
      }
      let rects = views.map { $0.convert($0.bounds, to: host) }.sorted { $0.minY < $1.minY }
      guard zip(rects, rects.dropFirst()).allSatisfy({ $0.maxY <= $1.minY + 1 }) else {
        throw BoomError.invalid("Chat rows overlapped during " + name)
      }
      var observation: [String: Any] = ["transition": name, "rows": rows]
      if let editor = model.editor, let container = editor.textContainer, let layout = editor.layoutManager {
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).maxY + editor.textContainerInset.height * 2
        guard height <= editor.bounds.height + 1 else { throw BoomError.invalid("The manuscript exceeded its assigned frame.") }
        observation["manuscript"] = ["width": editor.bounds.width, "height": editor.bounds.height, "glyphHeight": height]
      }
      observations.append(observation)
    }
    func image(_ name: String) throws {
      host.displayIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw BoomError.invalid("Native layout bitmap unavailable.") }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Native layout PNG unavailable.") }
      try png.write(to: evidence.appendingPathComponent(name + ".png"), options: .atomic)
    }
    do {
      for dark in [true, false] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for (index, width) in [620.0, 300.0, 470.0, 340.0, 620.0].enumerated() {
          let name = "\(dark ? "dark" : "light")-\(index)-\(Int(width))"
          if model.layout.isAuthor {
            try await settle()
            guard let split = split(host), split.subviews.count == 2 else { throw BoomError.invalid("The author fixture requires document and chat panes.") }
            split.setPosition(split.bounds.width - width, ofDividerAt: 0)
          } else { window.setContentSize(NSSize(width: width, height: 1800)) }
          try await settle(); try inspect(name, expected: texts.count)
          try image(name)
          if index == 1, let chat = model.state.chats.firstIndex(where: { $0.id == model.state.selectedChat }) {
            model.state.chats[chat].messages[2].state = .pending
            model.state.chats[chat].messages[2].text += "\n\n" + String(repeating: "An arriving paragraph at the narrow width. ", count: 3)
            try await settle(); try inspect(name + "-arriving", expected: texts.count)
            model.state.chats[chat].messages[2].state = .complete
            model.editingChatMessage = model.state.chats[chat].messages[1].id
            try await settle(); try inspect(name + "-editing", expected: texts.count - 1)
            try image(name + "-editing")
            model.editingChatMessage = nil
            try await settle(); try inspect(name + "-finished", expected: texts.count)
          }
        }
      }
      guard !window.isVisible else { throw BoomError.invalid("The background layout fixture became visible.") }
      try await model.shutdown()
      try write("passed", observations: observations, evidence: evidence)
    } catch {
      try write("failed", observations: observations, evidence: evidence, error: error.localizedDescription)
      throw error
    }
  }
  private static func write(_ status: String, observations: [[String: Any]], evidence: URL, error: String? = nil) throws {
    let receipt: [String: Any] = ["schema": 1, "status": status, "transitions": observations,
      "sourceInventorySHA256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "pid": ProcessInfo.processInfo.processIdentifier, "error": error as Any? ?? NSNull(),
      "publicFixtureOnly": true, "keychainLookups": VaultSession.shared.lookupCount]
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
  }
}
