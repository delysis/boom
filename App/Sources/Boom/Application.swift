import AppKit
import Combine
import Foundation
import BoomCore
import SwiftUI

@main @MainActor enum BoomMain {
  static func main() {
    #if BOOM_UI_TEST
    if CommandLine.arguments.contains("--attachment-route-smoke") {
      Task {
        do {
          try await AttachmentRouteSmoke.run()
          exit(0)
        } catch {
          fputs("Attachment routing failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      dispatchMain()
    }
    #endif
    if CommandLine.arguments.contains("--runtime-preflight") {
      print(AppleModel.availabilityMessage)
      exit(0)
    }
    if CommandLine.arguments.contains("--apple-smoke") {
      Task {
        do {
          try await AppleModel.smoke()
          exit(0)
        } catch {
          fputs("Apple smoke unavailable or failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      dispatchMain()
    }
    if CommandLine.arguments.contains("--speech-smoke") {
      Task {
        do {
          guard let index = CommandLine.arguments.firstIndex(of: "--audio-file"),
            index + 1 < CommandLine.arguments.count else {
            throw BoomError.invalid("Use --speech-smoke --audio-file ABSOLUTE_PATH.")
          }
          let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
          let result = try await VoiceInput().transcribeAttachment(
            url, flag: CancellationFlag()) { current, total in
              fputs("Local speech segment \(current)/\(total)\n", stderr)
            }
          print("Recognized \(result.text.count) characters; \(result.coverage)")
          exit(0)
        } catch {
          fputs("Local speech smoke failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      dispatchMain()
    }
    if CommandLine.arguments.contains("--install-default") {
      Task {
        do {
          guard let rootIndex = CommandLine.arguments.firstIndex(of: "--model-root"),
            rootIndex + 1 < CommandLine.arguments.count
          else { throw BoomError.invalid("Use --install-default --model-root ABSOLUTE_DIRECTORY.") }
          let rootPath = CommandLine.arguments[rootIndex + 1]
          guard rootPath.hasPrefix("/") else {
            throw BoomError.invalid("Model root must be absolute.")
          }
          let root = URL(fileURLWithPath: rootPath).standardizedFileURL
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          let installer = ModelInstaller()
          let installed = try await installer.download(to: root) { status in
            fputs(status + "\n", stderr)
          }
          print(installed.path)
          exit(0)
        } catch {
          fputs("Model install failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      dispatchMain()
    }
    if CommandLine.arguments.contains("--smoke") {
      Task {
        do {
          try await NativeSmoke.run(arguments: CommandLine.arguments)
          exit(0)
        } catch {
          fputs("Native smoke failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      dispatchMain()
    }
    if CommandLine.arguments.contains("--mlx-smoke") {
      Task {
        do {
          try await MLXNativeSmoke.run(arguments: CommandLine.arguments)
          exit(0)
        } catch {
          fputs("MLX smoke failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      dispatchMain()
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ApplicationDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate,
  NSMenuItemValidation, NSMenuDelegate
{
  private var model: WorkspaceModel?
  private var window: NSWindow?
  private var observer: AnyCancellable?
  private var buttons: [String: NSButton] = [:]
  private var terminating = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let model = try WorkspaceModel()
      self.model = model
      model.setTheme(model.state.theme)
      #if BOOM_UI_TEST
      let initialWidth: CGFloat = 340
      #else
      let initialWidth: CGFloat = 1190
      #endif
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 780),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      #if BOOM_UI_TEST
      window.contentMinSize = NSSize(width: 300, height: 440)
      #else
      window.contentMinSize = NSSize(width: 750, height: 440)
      #endif
      window.title = "Bloom"
      window.backgroundColor = BoomChrome.sidebarBackground
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unifiedCompact
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
      let toolbar = NSToolbar(identifier: "BoomComposerToolbar")
      toolbar.delegate = self
      toolbar.displayMode = .iconOnly
      toolbar.allowsUserCustomization = false
      window.toolbar = toolbar
      #if BOOM_UI_TEST
      window.minSize = NSSize(width: 310, height: 500)
      #else
      window.minSize = NSSize(width: 760, height: 500)
      #endif
      self.window = window
      NSApp.mainMenu = makeMenu()
      observer = model.objectWillChange.sink { [weak self] _ in
        DispatchQueue.main.async { self?.refreshToolbar() }
      }
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      refreshToolbar()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Bloom could not open its local workspace"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .critical
      alert.runModal()
      NSApp.terminate(nil)
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if terminating { return .terminateLater }
    terminating = true
    Task {
      do {
        try await model.shutdown()
        sender.reply(toApplicationShouldTerminate: true)
      } catch {
        terminating = false
        window?.makeKeyAndOrderFront(nil)
        model.report(error)
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .flexibleSpace, NSToolbarItem.Identifier("library"), NSToolbarItem.Identifier("document"),
      NSToolbarItem.Identifier("chat"),
    ]
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let definitions: [String: (String, String, Selector)] = [
      "library": ("sidebar.left", "Show or hide library (⌘1)", #selector(toggleLibrary)),
      "document": (
        "rectangle.center.inset.filled", "Show or hide document (⌘2)", #selector(toggleDocument)
      ),
      "chat": ("sidebar.right", "Show or hide chat (⌘3)", #selector(toggleChat)),
    ]
    guard let (symbol, label, action) = definitions[identifier.rawValue],
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    else { return nil }
    let button = NSButton(image: image, target: self, action: action)
    button.bezelStyle = .texturedRounded
    button.toolTip = label
    button.setAccessibilityLabel(label)
    if ["library", "document", "chat"].contains(identifier.rawValue) {
      button.setButtonType(.toggle)
    }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.view = button
    buttons[identifier.rawValue] = button
    return item
  }
  private func refreshToolbar() {
    guard let model else { return }
    buttons["library"]?.state = model.showsLibrary ? .on : .off
    buttons["document"]?.state = model.showsDocument ? .on : .off
    buttons["chat"]?.state = model.showsChat ? .on : .off
    window?.title = model.selectedDocument?.title ?? model.selectedChat?.title ?? "Bloom"
  }
  private func makeMenu() -> NSMenu {
    let bar = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let menu = NSMenu(title: title)
      item.submenu = menu
      bar.addItem(item)
      return menu
    }
    func item(
      _ title: String, _ action: Selector, _ key: String = "",
      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      return item
    }
    let app = submenu("Bloom")
    app.addItem(item("Local model…", #selector(models), ",", target: self))
    app.addItem(.separator())
    app.addItem(item("Hide Bloom", #selector(NSApplication.hide(_:)), "h", target: NSApp))
    app.addItem(
      item("Quit Bloom", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    let file = submenu("File")
    file.addItem(item("New Document", #selector(newDocument), "n", target: self))
    file.addItem(item("New Chat", #selector(newChat), "n", [.command, .shift], target: self))
    file.addItem(.separator())
    file.addItem(item("Import Markdown…", #selector(importDocument), "o", target: self))
    file.addItem(
      item("Export Markdown…", #selector(exportDocument), "s", [.command, .shift], target: self))
    file.addItem(item(
      "Attach Files to Document…", #selector(attachDocument), "a", [.command, .shift],
      target: self))
    file.addItem(item("Attach Files to Chat…", #selector(attachChat), target: self))
    let edit = submenu("Edit")
    if #available(macOS 15.2, *) { edit.automaticallyInsertsWritingToolsItems = false }
    edit.delegate = self
    edit.addItem(item("Undo", NSSelectorFromString("undo:"), "z"))
    edit.addItem(item("Redo", NSSelectorFromString("redo:"), "z", [.command, .shift]))
    edit.addItem(.separator())
    for (name, selector, key) in [
      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
      ("Select All", "selectAll:", "a"),
    ] { edit.addItem(item(name, NSSelectorFromString(selector), key)) }
    let find = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f")
    find.tag = 1
    edit.addItem(find)
    let format = NSMenu(title: "Format")
    let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
    formatItem.submenu = format
    edit.addItem(formatItem)
    format.addItem(item("Bold Markdown", #selector(MarkdownTextView.markdownBold(_:)), "b"))
    format.addItem(item("Italic Markdown", #selector(MarkdownTextView.markdownItalic(_:)), "i"))
    format.addItem(item("Link Markdown", #selector(MarkdownTextView.markdownLink(_:)), "k"))
    format.addItem(.separator())
    format.addItem(item("Heading", #selector(MarkdownTextView.markdownHeading(_:))))
    format.addItem(item("Bulleted List", #selector(MarkdownTextView.markdownList(_:))))
    format.addItem(item("Quote", #selector(MarkdownTextView.markdownQuote(_:))))
    format.addItem(item("Inline Code", #selector(MarkdownTextView.markdownCode(_:))))
    let view = submenu("View")
    view.addItem(item("Library", #selector(toggleLibrary), "1", target: self))
    view.addItem(item("Document", #selector(toggleDocument), "2", target: self))
    view.addItem(item("Chat", #selector(toggleChat), "3", target: self))
    view.addItem(.separator())
    view.addItem(item("Inline Completion", #selector(toggleCompletion), target: self))
    view.addItem(item("Clear Autocomplete Cache", #selector(clearFollowCache), target: self))
    let theme = NSMenu(title: "Appearance")
    let themeItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
    themeItem.submenu = theme
    view.addItem(themeItem)
    for value in ["system", "light", "dark"] {
      let entry = item(value.capitalized, #selector(changeTheme(_:)), target: self)
      entry.representedObject = value
      theme.addItem(entry)
    }
    let window = submenu("Window")
    window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
    NSApp.windowsMenu = window
    return bar
  }
  func menuWillOpen(_ menu: NSMenu) {
    guard menu.title == "Edit" else { return }
    for item in menu.items where ["Writing Tools", "AutoFill"].contains(item.title) {
      menu.removeItem(item)
    }
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let model else { return false }
    switch menuItem.action {
    case #selector(toggleLibrary): menuItem.state = model.showsLibrary ? .on : .off
    case #selector(toggleDocument): menuItem.state = model.showsDocument ? .on : .off
    case #selector(toggleChat): menuItem.state = model.showsChat ? .on : .off
    case #selector(toggleCompletion): menuItem.state = model.state.autocomplete ? .on : .off
    case #selector(changeTheme(_:)):
      menuItem.state = (menuItem.representedObject as? String) == model.state.theme ? .on : .off
    case #selector(attachDocument): return !model.isBusy && model.selectedDocument != nil
    case #selector(attachChat): return !model.isBusy
    case #selector(clearFollowCache): return !model.isBusy && model.modelReady
    default: break
    }
    return true
  }
  @objc private func toggleLibrary() { model?.toggle("library") }
  @objc private func toggleDocument() { model?.toggle("document") }
  @objc private func toggleChat() { model?.toggle("chat") }
  @objc private func newDocument() {
    do { try model?.newDocument() } catch { model?.report(error) }
  }
  @objc private func newChat() { do { try model?.newChat() } catch { model?.report(error) } }
  @objc private func importDocument() { model?.importDocument() }
  @objc private func exportDocument() { model?.exportDocument() }
  @objc private func attachDocument() { model?.chooseDocumentAttachmentFiles() }
  @objc private func attachChat() { model?.chooseChatAttachmentFiles() }
  @objc private func models() { model?.showingModels = true }
  @objc private func toggleCompletion() {
    guard let model else { return }
    model.state.autocomplete.toggle()
    model.invalidateGhost()
    model.scheduleSave()
  }
  @objc private func clearFollowCache() { model?.clearFollowCache() }
  @objc private func changeTheme(_ sender: NSMenuItem) {
    if let value = sender.representedObject as? String { model?.setTheme(value) }
  }
}
