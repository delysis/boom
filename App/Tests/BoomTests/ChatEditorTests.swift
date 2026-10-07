import AppKit
import SwiftUI
import XCTest
import BoomCore
import CryptoKit
@testable import Boom

final class ChatEditorTests: XCTestCase {
  @MainActor func testUnsentDocumentComposerDoesNotCreateChatAndFirstSendCapturesDocument() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-lazy-chat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw XCTSkip("The chat edition creates its initial chat at startup.") }
    let document = try XCTUnwrap(model.selectedDocument)
    let host = NSHostingView(rootView: ChatPane(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 480, height: 640))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(nativeEditor(in: host))
    input.setAccessibilityValue("Tell me about this document.")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(model.draft, "Tell me about this document.")
    XCTAssertTrue(model.state.chats.isEmpty)
    model.send()
    XCTAssertEqual(model.state.chats.count, 1)
    XCTAssertEqual(model.selectedChat?.attachedDocumentID, document.id)
    XCTAssertTrue(model.selectedChat?.messages.isEmpty == true)
    XCTAssertEqual(model.draft, "Tell me about this document.", "Model setup must retain the unsent question.")
    model.send()
    XCTAssertEqual(model.state.chats.count, 1)
    try await model.shutdown()
  }
  @MainActor func testPopulatedChatReflowsWithoutOverdrawWhenResized() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-chat-resize-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    let messages = [
      "It looks like you've entered \"stuff\" as a placeholder or a general query. Since there isn't a specific task or instruction provided, could you please clarify how you would like me to help?",
      "sure, proofread my memo and see if you can improve it.",
      "I can assist with analyzing the document, proofreading, drafting new content, or answering questions based on the text. Just let me know what you have in mind!",
      "# A taller heading\n\n- A long list entry with **bold** and *emphasized* words. " + String(repeating: "The river turns past the old house. ", count: 5),
      "Unicode: 👩🏽‍💻 café e\u{301} 日本語.\n\n" + String(repeating: "A paragraph that wraps at different pane widths. ", count: 8),
    ]
    for (index, text) in messages.enumerated() {
      model.authorChatMessage(index == 1 ? .user : .assistant); model.draft = text; model.send()
    }
    let host = NSHostingView(rootView: ChatPane(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 740, height: 2400))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    func readingViews(_ view: NSView) -> [NSTextView] {
      if let text = view as? NSTextView, !text.isEditable { return [text] }
      return view.subviews.flatMap(readingViews)
    }
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
      window.appearance = NSAppearance(named: appearance)
      for width in [740.0, 300.0, 510.0, 340.0, 740.0] {
        window.setContentSize(NSSize(width: width, height: 2400)); settle(window)
        if width == 300, let chatIndex = model.state.chats.firstIndex(where: { $0.id == model.state.selectedChat }) {
          model.state.chats[chatIndex].messages[2].state = .pending
          model.state.chats[chatIndex].messages[2].text += "\n\n" + String(repeating: "An arriving paragraph wraps while the pane is narrow. ", count: 4)
          settle(window)
        }
        let views = readingViews(host)
        XCTAssertEqual(views.count, messages.count)
        for view in views {
          let container = try XCTUnwrap(view.textContainer), layout = try XCTUnwrap(view.layoutManager)
          layout.ensureLayout(for: container)
          let glyphs = layout.usedRect(for: container)
          XCTAssertLessThanOrEqual(glyphs.maxY, view.bounds.height + 1,
            "Rendered text exceeds its assigned row at width \(width): frame=\(view.frame) container=\(container.size) measured=\((view as? NativeReadingTextView)?.contentHeight(at: view.bounds.width) ?? -1) \(view.string.prefix(30))")
          XCTAssertLessThanOrEqual(glyphs.maxX, view.bounds.width + 1)
        }
        let rects = views.map { $0.convert($0.bounds, to: host) }.sorted { $0.minY < $1.minY }
        for (first, second) in zip(rects, rects.dropFirst()) {
          XCTAssertLessThanOrEqual(first.maxY, second.minY + 1, "Message rows overlap at width \(width)")
        }
      }
    }
    try await model.shutdown()
  }
  @MainActor func testSpeculativeTextMeasurementDoesNotChangeDisplayedGeometry() throws {
    let view = NativeReadingTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
    view.setSource("# A heading\n\n" + String(repeating: "Native text stays in its assigned container. 👩🏽‍💻 ", count: 8))
    view.setFrameSize(NSSize(width: 340, height: 400))
    let container = try XCTUnwrap(view.textContainer), layout = try XCTUnwrap(view.layoutManager)
    layout.ensureLayout(for: container)
    let size = container.size, frame = view.frame, before = layout.usedRect(for: container)
    XCTAssertGreaterThan(view.contentHeight(at: 180), view.contentHeight(at: 740))
    XCTAssertEqual(container.size, size); XCTAssertEqual(view.frame, frame)
    layout.ensureLayout(for: container)
    XCTAssertEqual(layout.usedRect(for: container), before)
    view.setSource("A short replacement.")
    XCTAssertLessThan(view.contentHeight(at: 340), before.height)
    for presentation in [NativeText.Presentation.markdown, .literal, .removed, .added] {
      view.setSource("# A heading\n\n" + String(repeating: "Literal or styled prose 👩🏽‍💻. ", count: 12),
        presentation: presentation, pointSize: 12)
      let height = view.contentHeight(at: 220)
      view.setFrameSize(NSSize(width: 220, height: height)); layout.ensureLayout(for: container)
      XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxY, height + 1)
      XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxX, 221)
    }
  }
  @MainActor func testManuscriptReflowsAndProbesPreserveSelectionUndoAndLiveLayout() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-document-resize-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor, let document = model.selectedDocument else { throw XCTSkip("No manuscript in the chat edition.") }
    model.state.autocomplete = false
    model.updateDocument("# At the harbor\n\n" + String(repeating: "The river turns past the old house. 👩🏽‍💻 café e\u{301} 日本語. ", count: 100), id: document.id, caret: 0)
    let host = NSHostingView(rootView: ManuscriptPane(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 840, height: 640))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    settle(window)
    let view = try XCTUnwrap(model.editor), container = try XCTUnwrap(view.textContainer), layout = try XCTUnwrap(view.layoutManager)
    view.setSelectedRange(NSRange(location: 20, length: 3))
    let selection = view.selectedRange(), source = view.string, canUndo = view.undoManager?.canUndo
    for width in [840.0, 330.0, 600.0, 380.0, 840.0] {
      window.setContentSize(NSSize(width: width, height: 640)); settle(window)
      layout.ensureLayout(for: container)
      XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxY + view.textContainerInset.height * 2, view.bounds.height + 1)
      let size = container.size, frame = view.frame, displayed = layout.usedRect(for: container)
      _ = view.manuscriptSize(width: 240, minimumHeight: 180)
      _ = view.manuscriptSize(width: 760, minimumHeight: 180)
      layout.ensureLayout(for: container)
      XCTAssertEqual(container.size, size); XCTAssertEqual(view.frame, frame)
      XCTAssertEqual(layout.usedRect(for: container), displayed)
      XCTAssertEqual(view.selectedRange(), selection); XCTAssertEqual(view.string, source)
      XCTAssertEqual(view.undoManager?.canUndo, canUndo)
    }
    try await model.shutdown()
  }
  @MainActor private func nativeEditor(in view: NSView) -> ChatTextView? {
    if let text = view as? ChatTextView { return text }
    return view.subviews.lazy.compactMap { self.nativeEditor(in: $0) }.first
  }
  @MainActor private func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    window.contentView?.layoutSubtreeIfNeeded()
  }
  @MainActor private func editingInput(in view: NSView) -> ChatInputView? {
    if let input = view as? ChatInputView, input.saveButton != nil { return input }
    return view.subviews.lazy.compactMap { self.editingInput(in: $0) }.first
  }
  @MainActor func testInstructionIconsSaveAndDiscardThroughTheRenderedChat() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-native-edit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    let id = try XCTUnwrap(model.state.selectedChat)
    model.openChatInstructions(id)
    var changes = 0
    let observer = model.objectWillChange.sink { changes += 1 }
    defer { observer.cancel() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ChatPane(model: model))
    settle(window)
    let input = try XCTUnwrap(editingInput(in: XCTUnwrap(window.contentView)))
    let text = try XCTUnwrap(input.scroll.documentView as? ChatTextView)
    text.setAccessibilityValue("Listen before responding.")
    settle(window)
    let save = try XCTUnwrap(input.saveButton)
    let content = try XCTUnwrap(window.contentView)
    // NSView.hitTest receives a point in its superview's coordinate system.
    let point = save.convert(NSPoint(x: save.bounds.midX, y: save.bounds.midY), to: content.superview)
    XCTAssertTrue(content.hitTest(point) === save, "The save icon must receive clicks at its visible position.")
    save.performClick(nil)
    XCTAssertGreaterThan(changes, 0, "The rendered chat must receive model changes.")
    XCTAssertNil(model.showingChatInstructions)
    XCTAssertEqual(model.selectedChat?.instructions, "Listen before responding.")
    settle(window)
    XCTAssertNil(editingInput(in: content), "Saving must remove the editor from the visible chat.")
    model.openChatInstructions(id)
    settle(window)
    let reopened = try XCTUnwrap(editingInput(in: XCTUnwrap(window.contentView)))
    let edit = try XCTUnwrap(reopened.scroll.documentView as? ChatTextView)
    edit.insertText("Discard this change.", replacementRange: NSRange(location: 0, length: (edit.string as NSString).length))
    try XCTUnwrap(reopened.cancelButton).performClick(nil)
    XCTAssertNil(model.showingChatInstructions)
    XCTAssertEqual(model.selectedChat?.instructions, "Listen before responding.")
    settle(window)
    XCTAssertNil(editingInput(in: content), "Discard must remove the editor from the visible chat.")
    try await model.shutdown()
    let persisted = try await store.load().get().0
    XCTAssertEqual(persisted.chats.first { $0.id == id }?.instructions, "Listen before responding.")
  }
  @MainActor func testInlineEditorFitsTextAndPreservesNativeUndo() throws {
    _ = NSApplication.shared
    var saved: String?
    let original = "A short answer.\nA second line."
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ChatTextEditor(label: "Edit message", text: original,
      save: { saved = $0 }, cancel: {}))
    settle(window)
    let view = try XCTUnwrap(nativeEditor(in: XCTUnwrap(window.contentView)))
    let scroll = try XCTUnwrap(view.enclosingScrollView)
    XCTAssertLessThan(scroll.frame.height, 80, "A short edit must not reserve a large blank editor.")
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    view.insertText("\nA third line.", replacementRange: view.selectedRange())
    XCTAssertEqual(view.string, original + "\nA third line.")
    view.undoManager?.undo()
    XCTAssertEqual(view.string, original)
    view.insertText(" Revised.", replacementRange: view.selectedRange())
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    XCTAssertTrue(window.makeFirstResponder(view))
    XCTAssertTrue(window.performKeyEquivalent(with: event), "The active editor must handle Command-Return before menu commands.")
    XCTAssertEqual(saved, original + " Revised.")
  }
  @MainActor func testMessageDiscardClosesAndSavePreservesOriginal() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-message-edit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    model.authorChatMessage(.user); model.draft = "A question."; model.send()
    model.authorChatMessage(.assistant); model.draft = "An answer."; model.send()
    let original = try XCTUnwrap(model.selectedChat?.messages.last)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ChatPane(model: model))
    model.editingChatMessage = original.id
    settle(window)
    let content = try XCTUnwrap(window.contentView)
    let input = try XCTUnwrap(editingInput(in: content))
    (input.scroll.documentView as? ChatTextView)?.setAccessibilityValue("Discard this draft.")
    try XCTUnwrap(input.cancelButton).performClick(nil)
    settle(window)
    XCTAssertNil(editingInput(in: content)); XCTAssertNil(model.editingChatMessage)
    XCTAssertEqual(model.selectedChat?.messages.last, original)
    model.editingChatMessage = original.id
    settle(window)
    let reopened = try XCTUnwrap(editingInput(in: content))
    (reopened.scroll.documentView as? ChatTextView)?.setAccessibilityValue("My revised answer.")
    try XCTUnwrap(reopened.saveButton).performClick(nil)
    settle(window)
    XCTAssertNil(editingInput(in: content)); XCTAssertNil(model.editingChatMessage)
    XCTAssertEqual(model.selectedChat?.messages.last?.text, "My revised answer.")
    XCTAssertEqual(model.selectedChat?.messageVersions, [original])
    try await model.shutdown()
  }
  @MainActor func testInstructionsRemainReachableAfterSwitchingFromLongChat() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-chat-switch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    let first = try XCTUnwrap(model.state.selectedChat)
    try model.setChatInstructions("First voice instructions.", mention: nil, chatID: first)
    model.authorChatMessage(.user); model.draft = "A question."; model.send()
    model.authorChatMessage(.assistant); model.draft = "An answer."; model.send()
    model.pinChat(first)
    try model.newChat()
    let second = try XCTUnwrap(model.state.selectedChat)
    try model.setChatInstructions("Different chat instructions.", mention: nil, chatID: second)
    for index in 0..<40 {
      model.authorChatMessage(index.isMultiple(of: 2) ? .user : .assistant)
      model.draft = "Exchange \(index). " + String(repeating: "A paragraph that fills the conversation viewport. ", count: 8)
      model.send()
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ChatPane(model: model))
    settle(window)
    model.selectChat(first)
    model.openChatInstructions(first)
    settle(window)
    let content = try XCTUnwrap(window.contentView)
    let input = try XCTUnwrap(editingInput(in: content), "Opening another chat's instructions must mount its editor.")
    let text = try XCTUnwrap(input.scroll.documentView as? ChatTextView)
    XCTAssertEqual(text.string, "First voice instructions.")
    let save = try XCTUnwrap(input.saveButton)
    let point = save.convert(NSPoint(x: save.bounds.midX, y: save.bounds.midY), to: content.superview)
    XCTAssertTrue(content.hitTest(point) === save, "The instruction editor must be reachable inside the viewport.")
    text.setAccessibilityValue("Updated first voice."); save.performClick(nil)
    settle(window)
    XCTAssertEqual(model.selectedChat?.instructions, "Updated first voice.")
    model.selectChat(second); model.openChatInstructions(second)
    settle(window)
    let other = try XCTUnwrap(editingInput(in: content))
    XCTAssertEqual((other.scroll.documentView as? ChatTextView)?.string, "Different chat instructions.",
      "An editor cannot retain the previous chat's draft.")
    try await model.shutdown()
  }
}
