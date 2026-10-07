import AppKit
import Combine
import Foundation
import BoomCore
import SwiftUI

/// Accessibility input follows the same live action as typed search text.
@MainActor final class LibrarySearchField: NSSearchField {
  override func setAccessibilityValue(_ value: Any?) {
    guard let value = value as? String, value != stringValue else { return }
    stringValue = value
    if let action { sendAction(action, to: target) }
  }
}

@main @MainActor enum BoomMain {
  static func main() {
    if CommandLine.arguments.contains("--model-install-smoke") {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      Task {
        do { try await ModelInstallSmoke.run(arguments: CommandLine.arguments); exit(0) }
        catch { fputs("Public model installation failed: \(error.localizedDescription)\n", stderr); exit(1) }
      }
      app.run()
      return
    }
    if CommandLine.arguments.contains("--generation-recovery-smoke") || CommandLine.arguments.contains("--workspace-import-smoke") || CommandLine.arguments.contains("--writing-control-smoke") || CommandLine.arguments.contains("--writing-context-smoke") || CommandLine.arguments.contains("--consultation-control-smoke") || CommandLine.arguments.contains("--explicit-export-smoke") {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      Task {
        do {
          if CommandLine.arguments.contains("--explicit-export-smoke") {
            try await ExplicitExportSmoke.run(arguments: CommandLine.arguments)
          } else if CommandLine.arguments.contains("--consultation-control-smoke") {
            try await ConsultationControlSmoke.run(arguments: CommandLine.arguments)
          } else if CommandLine.arguments.contains("--writing-context-smoke") {
            try await WritingContextSmoke.run(arguments: CommandLine.arguments)
          } else if CommandLine.arguments.contains("--writing-control-smoke") {
            try await WritingControlSmoke.run(arguments: CommandLine.arguments)
          } else if CommandLine.arguments.contains("--workspace-import-smoke") {
            try await WorkspaceImportSmoke.run(arguments: CommandLine.arguments)
          } else { try await GenerationRecoverySmoke.run(arguments: CommandLine.arguments) }
          exit(0)
        } catch {
          fputs("Native diagnostic failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      app.run()
      return
    }
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
    if CommandLine.arguments.contains("--mlx-smoke") {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      Task {
        do {
          try await MLXNativeSmoke.run(arguments: CommandLine.arguments)
          exit(0)
        } catch {
          fputs("MLX smoke failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      app.run()
      return
    }
    let app = NSApplication.shared
    let background = CommandLine.arguments.contains("--native-check-workspace")
      && CommandLine.arguments.contains("--native-check-background")
    app.setActivationPolicy(background ? .accessory : .regular)
    let delegate = ApplicationDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate,
  NSMenuItemValidation, NSMenuDelegate, NSSearchFieldDelegate
{
  private var model: WorkspaceModel?
  private var window: NSWindow?
  private var observer: AnyCancellable?
  private var buttons: [String: NSButton] = [:]
  private var searchItem: NSSearchToolbarItem?
  private var searchField: NSSearchField?
  private var terminating = false
  private var isNativeCheck = false
  static func workspaceWindow(frame: NSRect) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    // Workspace restoration belongs to the encrypted store, not AppKit Resume.
    window.isRestorable = false
    window.disableSnapshotRestoration()
    return window
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await openWorkspace() }
  }
  private func openWorkspace() async {
    do {
      let arguments = CommandLine.arguments
      let override: WorkspaceStore?
      if let index = arguments.firstIndex(of: "--native-check-workspace") {
        guard arguments.filter({ $0 == "--native-check-workspace" }).count == 1,
          index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
          throw BoomError.invalid("Native checks require an explicit absolute encrypted workspace path.")
        }
        let root = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        override = try await detachedWork { try WorkspaceStore(rootOverride: root) }
        isNativeCheck = true
      } else { override = nil }
      let backgroundCheck = isNativeCheck && arguments.contains("--native-check-background")
      let noModels = isNativeCheck && arguments.contains("--native-check-no-models")
      let model = try await WorkspaceModel(storeOverride: override, loadModels: !noModels)
      self.model = model
      if isNativeCheck, let index = arguments.firstIndex(of: "--native-check-theme"), index + 1 < arguments.count {
        guard ["light", "dark"].contains(arguments[index + 1]) else { throw BoomError.invalid("Native appearance check requires light or dark.") }
        model.setTheme(arguments[index + 1])
      } else { model.setTheme(model.state.theme) }
      #if BOOM_UI_TEST
      let initialWidth: CGFloat = 340
      #else
      let initialWidth: CGFloat = model.layout.isAuthor ? 1190 : 1000
      #endif
      let frame = NSRect(x: 0, y: 0, width: initialWidth, height: 780)
      let window = Self.workspaceWindow(frame: frame)
      #if BOOM_UI_TEST
      window.contentMinSize = NSSize(width: 300, height: 440)
      #else
      window.contentMinSize = NSSize(width: model.layout.isAuthor ? 750 : 540, height: 440)
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
      window.minSize = NSSize(width: model.layout.isAuthor ? 760 : 550, height: 500)
      #endif
      self.window = window
      NSApp.mainMenu = makeMenu()
      observer = model.objectWillChange.sink { [weak self] _ in
        DispatchQueue.main.async { self?.refreshToolbar() }
      }
      if backgroundCheck {
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
      } else {
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      }
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
    let controls = (model?.layout.paneControls ?? []).map { NSToolbarItem.Identifier($0) }
    return [NSToolbarItem.Identifier.flexibleSpace] + controls + [NSToolbarItem.Identifier("search")]
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if identifier.rawValue == "search" {
      let item = NSSearchToolbarItem(itemIdentifier: identifier)
      let field = LibrarySearchField()
      field.placeholderString = "Search"
      field.setAccessibilityLabel("Search library")
      field.target = self; field.action = #selector(searchLibrary(_:)); field.delegate = self
      field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
      field.recentsAutosaveName = nil; field.maximumRecents = 0
      item.searchField = field
      item.preferredWidthForSearchField = 240
      field.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
      searchItem = item; searchField = field
      return item
    }
    guard model?.layout.paneControls.contains(identifier.rawValue) == true else { return nil }
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
    let title = model.layout.isAuthor ? model.selectedDocument?.title ?? "Bloom" : model.selectedChat?.title ?? "Bloom"
    window?.title = isNativeCheck ? "Native check · " + title : title
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
    if model?.layout.isAuthor == true {
    file.addItem(item("New Document", #selector(newDocument), "n", target: self))
    file.addItem(item("New Chat", #selector(newChat), "n", [.command, .shift], target: self))
    file.addItem(.separator())
    file.addItem(item("Import Markdown…", #selector(importDocument), "o", target: self))
    file.addItem(
      item("Export Markdown…", #selector(exportDocument), "s", [.command, .shift], target: self))
    file.addItem(item(
      "Attach Files to Document…", #selector(attachDocument), "a", [.command, .shift],
      target: self))
    file.addItem(item("Import Folder…", #selector(importFolder), target: self))
    } else {
      file.addItem(item("New Chat", #selector(newChat), "n", target: self))
    }
    file.addItem(item("Attach Files to Chat…", #selector(attachChat), target: self))
    file.addItem(.separator())
    file.addItem(item("Export Encrypted Backup…", #selector(exportBackup), target: self))
    file.addItem(item("Restore Encrypted Backup…", #selector(restoreBackup), target: self))
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
    if model?.layout.isAuthor == true {
    let writing = submenu("Writing")
    writing.addItem(item("Explore continuations", #selector(exploreWriting), "\r", target: self))
    writing.addItem(item("Writing examples…", #selector(writingExamples), target: self))
    writing.addItem(item("Show continuations", #selector(showContinuations), target: self))
    writing.addItem(.separator())
    writing.addItem(item("Inline suggestions", #selector(toggleCompletion), target: self))
    let variation = NSMenuItem(title: "Variation", action: nil, keyEquivalent: "")
    let variations = NSMenu(title: "Variation")
    for (label, profile) in [("Less", SamplingProfile.steady), ("Default", .standard), ("More (experimental)", .open)] {
      let option = item(label, #selector(changeVariation), target: self)
      option.representedObject = profile.rawValue
      variations.addItem(option)
    }
    variation.submenu = variations; writing.addItem(variation)
    }
    let chat = submenu("Chat")
    chat.addItem(item("Instructions…", #selector(chatInstructions), target: self))
    chat.addItem(item("Pin as voice", #selector(pinChat), target: self))
    chat.addItem(.separator())
    chat.addItem(item("Write a question", #selector(writeQuestion), target: self))
    chat.addItem(item("Write an answer", #selector(writeAnswer), target: self))
    chat.addItem(item("Import voice…", #selector(importVoice), target: self))
    let view = submenu("View")
    view.addItem(item("Library", #selector(toggleLibrary), "1", target: self))
    if model?.layout.paneControls.contains("chat") == true {
      view.addItem(item("Chat", #selector(toggleChat), "3", target: self))
    }
    view.addItem(item("Search Library…", #selector(focusSearch), "f", [.command, .shift], target: self))
    view.addItem(.separator())

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
    case #selector(chatInstructions), #selector(writeQuestion), #selector(writeAnswer): return model.showsChat && model.selectedChat != nil && !model.isBusy
    case #selector(pinChat):
      menuItem.title = model.selectedChat.flatMap { model.chatVoice($0.id) } == nil ? "Pin as voice" : "Unpin voice"
      return model.showsChat && model.selectedChat != nil && !model.isBusy
    case #selector(importVoice): return !model.isBusy
    case #selector(exportBackup), #selector(restoreBackup): return !model.isBusy
    case #selector(exportDocument): return model.selectedDocument != nil
    case #selector(toggleLibrary): menuItem.state = model.showsLibrary ? .on : .off
    case #selector(toggleDocument): menuItem.state = model.showsDocument ? .on : .off
    case #selector(toggleChat): menuItem.state = model.showsChat ? .on : .off
    case #selector(exploreWriting): return model.showsDocument && model.canExploreWriting
    case #selector(showContinuations): menuItem.title = model.showingCandidates ? "Hide continuations" : "Show continuations"; return model.showsDocument && model.canShowContinuations
    case #selector(writingExamples): return model.showsDocument && model.selectedDocument != nil && !model.isBusy
    case #selector(changeVariation): menuItem.state = (menuItem.representedObject as? String) == model.samplingProfile.rawValue ? .on : .off
    case #selector(toggleCompletion): menuItem.state = model.state.autocomplete ? .on : .off
    case #selector(changeTheme(_:)):
      menuItem.state = (menuItem.representedObject as? String) == model.state.theme ? .on : .off
    case #selector(attachDocument): return !model.isBusy && model.selectedDocument != nil
    case #selector(attachChat): return !model.isBusy
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
  @objc private func newChat() { do { try model?.newChat(about: model?.layout.isAuthor == true ? model?.state.selectedDocument : nil) } catch { model?.report(error) } }
  @objc private func chatInstructions() { if let id = model?.state.selectedChat { model?.openChatInstructions(id) } }
  @objc private func pinChat() {
    guard let model, let id = model.state.selectedChat else { return }
    if model.chatVoice(id) == nil { model.pinChat(id) } else { model.unpinChat(id) }
  }
  @objc private func writeQuestion() { model?.authorChatMessage(.user) }
  @objc private func writeAnswer() { model?.authorChatMessage(.assistant) }
  @objc private func importVoice() { model?.importVoice() }
  @objc private func searchLibrary(_ field: NSSearchField) {
    model?.librarySearch = field.stringValue
    if !field.stringValue.isEmpty, model?.showsLibrary == false { model?.toggle("library") }
  }
  @objc private func focusSearch() { searchItem?.beginSearchInteraction() }
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField, field === searchField else { return }
    searchLibrary(field)
  }
  @objc private func importFolder() { model?.importFolder() }
  @objc private func importDocument() { model?.importDocument() }
  @objc private func exportDocument() { model?.exportDocument() }
  @objc private func attachDocument() { model?.chooseDocumentAttachmentFiles() }
  @objc private func attachChat() { model?.chooseChatAttachmentFiles() }
  @objc private func exportBackup() { model?.backupWorkspace(restoring: false) }
  @objc private func restoreBackup() { model?.backupWorkspace(restoring: true) }
  @objc private func models() { model?.showingModels = true }
  @objc private func showContinuations() { model?.showContinuations() }
  @objc private func writingExamples() { model?.openWritingExamples() }
  @objc private func exploreWriting() { model?.exploreWriting() }
  @objc private func changeVariation(_ sender: NSMenuItem) {
    if let value = sender.representedObject as? String, let profile = SamplingProfile(rawValue: value) { model?.samplingProfile = profile }
  }
  @objc private func toggleCompletion() {
    guard let model else { return }
    model.setAutocomplete(!model.state.autocomplete)
  }
  @objc private func changeTheme(_ sender: NSMenuItem) {
    if let value = sender.representedObject as? String { model?.setTheme(value) }
  }
}
