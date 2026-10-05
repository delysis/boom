import AppKit
import SwiftUI
import XCTest
import BoomCore
import CryptoKit
@testable import Boom

final class ChatEditorTests: XCTestCase {
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
