import AppKit
import SwiftUI

@MainActor enum BlessengerApplication {
  private static var delegate: Delegate?
  static func run() {
    let app = NSApplication.shared
    // LaunchServices normally performs this admission. Direct executable starts
    // must also focus the existing product before any credential/store access.
    if let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty,
      let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
      existing.activate(options: [.activateAllWindows]); return
    }
    app.setActivationPolicy(.regular)
    let owner = Delegate(); delegate = owner; app.delegate = owner
    owner.installMenu()
    app.run()
    delegate = nil
  }
  final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: BlessengerModel?
    private var startup: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var pendingSettings = false
    func applicationDidFinishLaunching(_ notification: Notification) {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = "Blessenger"; window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true; window.minSize = NSSize(width: 640, height: 480)
      window.isRestorable = false; window.disableSnapshotRestoration(); window.delegate = self
      window.isReleasedWhenClosed = false; window.center()
      window.contentView = NSHostingView(rootView: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity))
      self.window = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      startup = Task {
        do {
          let opened = try await BlessengerModel.open()
          self.model = opened; opened.settingsOpen = self.pendingSettings; self.pendingSettings = false
          window.contentView = NSHostingView(rootView: BlessengerView(model: opened))
        } catch {
          window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text("Blessenger could not open its private workspace.").font(.headline)
            Text(error.localizedDescription).textSelection(.enabled)
            Button("Quit") { NSApp.terminate(nil) }
          }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        self.startup = nil
      }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      if shutdown != nil { return .terminateLater }
      guard model != nil || startup != nil else { return .terminateNow }
      shutdown = Task {
        if let startup { await startup.value }
        do {
          try await model?.shutdown()
          NSApp.reply(toApplicationShouldTerminate: true)
        } catch {
          model?.report(error); window?.makeKeyAndOrderFront(nil)
          shutdown = nil; NSApp.reply(toApplicationShouldTerminate: false)
        }
      }
      return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
      window?.makeKeyAndOrderFront(nil); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func installMenu() {
      let bar = NSMenu(), application = NSMenu(), file = NSMenu(), edit = NSMenu(), window = NSMenu()
      func root(_ title: String, _ menu: NSMenu) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = menu; bar.addItem(item) }
      func action(_ title: String, _ selector: Selector, _ key: String = "", menu: NSMenu, target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = target; menu.addItem(item)
      }
      root("Blessenger", application); root("File", file); root("Edit", edit); root("Window", window)
      action("About Blessenger", #selector(about), menu: application, target: self)
      application.addItem(.separator()); action("Settings…", #selector(settings), ",", menu: application, target: self)
      application.addItem(.separator()); action("Hide Blessenger", #selector(NSApplication.hide(_:)), "h", menu: application, target: NSApp)
      application.addItem(.separator()); action("Quit Blessenger", #selector(NSApplication.terminate(_:)), "q", menu: application, target: NSApp)
      action("New Message", #selector(newMessage), "n", menu: file, target: self)
      action("Add Attachment…", #selector(attach), menu: file, target: self)
      action("Export Conversation…", #selector(exportChat), menu: file, target: self)
      action("Stop", #selector(stop), ".", menu: file, target: self)
      action("Close", #selector(NSWindow.performClose(_:)), "w", menu: file)
      action("Undo", Selector(("undo:")), "z", menu: edit)
      let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
      edit.addItem(.separator())
      action("Cut", #selector(NSText.cut(_:)), "x", menu: edit)
      action("Copy", #selector(NSText.copy(_:)), "c", menu: edit)
      action("Paste", #selector(NSText.paste(_:)), "v", menu: edit)
      action("Select All", #selector(NSText.selectAll(_:)), "a", menu: edit)
      action("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", menu: window)
      action("Zoom", #selector(NSWindow.performZoom(_:)), menu: window)
      NSApp.mainMenu = bar; NSApp.windowsMenu = window
    }
    @objc private func about() {
      NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Blessenger",
        .applicationVersion: "Development", .credits: NSAttributedString(string: "Private, on-device conversations with imagined AI consultants. A messaging parody; the named people do not participate in or endorse these generated consultations.")])
    }
    @objc private func settings() { if let model { model.settingsOpen = true } else { pendingSettings = true } }
    @objc private func newMessage() { if let model { Task { await model.select(nil) } } }
    @objc private func attach() { model?.pickAttachments() }
    @objc private func exportChat() { model?.exportConversation() }
    @objc private func stop() { model?.stop() }
  }
}
