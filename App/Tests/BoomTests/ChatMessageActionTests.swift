import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class ChatMessageActionTests: XCTestCase {
  @MainActor private func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    window.contentView?.layoutSubtreeIfNeeded()
  }
  @MainActor private func rails(_ view: NSView) -> [ChatMessageActionView] {
    if let rail = view as? ChatMessageActionView { return [rail] }
    return view.subviews.flatMap(rails)
  }
  @MainActor private func editor(_ view: NSView) -> ChatInputView? {
    if let input = view as? ChatInputView, input.saveButton != nil { return input }
    return view.subviews.lazy.compactMap(editor).first
  }
  @MainActor func testHoverEditActionsReachBothRolesAndPreserveOriginalsAndTimes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-message-actions-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    model.authorChatMessage(.user); model.draft = "A question."; model.send()
    model.authorChatMessage(.assistant); model.draft = "An answer."; model.send()
    let chatID = try XCTUnwrap(model.state.selectedChat), originals = try XCTUnwrap(model.selectedChat?.messages)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 340, height: 680))
    window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: ChatPane(model: model))
    defer { window.close() }
    for original in originals {
      settle(window)
      let content = try XCTUnwrap(window.contentView)
      let rail = try XCTUnwrap(rails(content).first { $0.commands.message.id == original.id })
      rail.setHovered(true); content.layoutSubtreeIfNeeded()
      let point = rail.editButton.convert(NSPoint(x: 12, y: 12), to: content.superview)
      XCTAssertTrue(content.hitTest(point) === rail.editButton, "The visible pencil must receive the click.")
      rail.editButton.performClick(nil); settle(window)
      let input = try XCTUnwrap(editor(content)), text = try XCTUnwrap(input.scroll.documentView as? ChatTextView)
      text.setAccessibilityValue("Revised " + original.text)
      try XCTUnwrap(input.saveButton).performClick(nil); settle(window)
      XCTAssertNil(editor(content)); XCTAssertNil(model.editingChatMessage)
      let replacement = try XCTUnwrap(model.selectedChat?.messages.first { $0.editedFrom == original.id })
      XCTAssertEqual(replacement.text, "Revised " + original.text)
      XCTAssertEqual(replacement.timestamp, original.timestamp)
      XCTAssertEqual(replacement.role, original.role)
      XCTAssertTrue(model.selectedChat?.messageVersions?.contains(original) == true)
    }
    try await model.shutdown()
    let saved = try await store.load().get().0.chats.first { $0.id == chatID }
    XCTAssertEqual(saved?.messages, model.selectedChat?.messages)
    XCTAssertEqual(saved?.messageVersions, originals)
  }
  @MainActor func testNativeRailCopyFeedbackBranchAndKeyboardReveal() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-message-rail-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    model.authorChatMessage(.user); model.draft = "A question."; model.send()
    model.authorChatMessage(.assistant); model.draft = "An answer."; model.send()
    let chatID = try XCTUnwrap(model.state.selectedChat), reply = try XCTUnwrap(model.selectedChat?.messages.last)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let rail = ChatMessageActionView(commands: ChatMessageCommands(model: model, chatID: chatID, message: reply, pasteboard: pasteboard))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 300, height: 24))
    window.isReleasedWhenClosed = false; window.contentView = rail
    defer { window.close() }
    settle(window)
    let frame = rail.frame
    XCTAssertFalse(rail.revealed)
    rail.setHovered(true); settle(window)
    XCTAssertTrue(rail.revealed); XCTAssertEqual(rail.frame, frame)
    for button in [rail.copyButton, rail.editButton, rail.branchButton, try XCTUnwrap(rail.feedbackButton)] {
      let rect = button.convert(button.bounds, to: rail)
      XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.maxX, rail.bounds.width)
    }
    rail.copyButton.performClick(nil)
    XCTAssertEqual(pasteboard.string(forType: .string), reply.text)
    let helpful = try XCTUnwrap(rail.feedbackMenu().items.first)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(helpful.action), to: helpful.target, from: helpful))
    XCTAssertEqual(model.selectedChat?.messages.last?.feedback, .helpful)
    rail.update(commands: ChatMessageCommands(model: model, chatID: chatID,
      message: try XCTUnwrap(model.selectedChat?.messages.last), pasteboard: pasteboard))
    XCTAssertEqual(rail.feedbackMenu().items.first?.state, .on)
    let remove = try XCTUnwrap(rail.feedbackMenu().items.first)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
    XCTAssertNil(model.selectedChat?.messages.last?.feedback)
    rail.update(commands: ChatMessageCommands(model: model, chatID: chatID,
      message: try XCTUnwrap(model.selectedChat?.messages.last), pasteboard: pasteboard))
    let restore = try XCTUnwrap(rail.feedbackMenu().items.first)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(restore.action), to: restore.target, from: restore))
    XCTAssertEqual(model.selectedChat?.messages.last?.feedback, .helpful)
    rail.setHovered(false)
    XCTAssertTrue(window.makeFirstResponder(rail.editButton)); settle(window)
    XCTAssertTrue(rail.revealed, "Keyboard focus must reveal otherwise hidden actions.")
    rail.branchButton.performClick(nil)
    XCTAssertNotEqual(model.state.selectedChat, chatID)
    XCTAssertEqual(model.selectedChat?.messages.last?.id, reply.id)
    XCTAssertEqual(model.selectedChat?.messages.last?.timestamp, reply.timestamp)
    XCTAssertEqual(model.selectedChat?.messages.last?.feedback, .helpful)
    XCTAssertEqual(model.state.chats.first { $0.id == chatID }?.messages.count, 2)
    try await model.shutdown()
  }
  @MainActor func testCompletedReplyKeepsPendingTimestampAndUnknownDatesStayUnknown() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-message-time-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256)), loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    let chatID = try XCTUnwrap(model.state.selectedChat), index = try XCTUnwrap(model.state.chats.firstIndex { $0.id == chatID })
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let pending = ChatMessage(role: .assistant, text: "", state: .pending, timestamp: date)
    model.state.chats[index].messages.append(pending)
    let recaptured = ChatMessage(id: pending.id, role: .assistant, text: "", state: .pending)
    let completed = try await model.finishConsultationResponse("A completed answer.", pending: recaptured, chatID: chatID,
      authority: CapturedDocumentAuthority(mode: .ask, target: nil), documentSources: [], attachments: [])
    XCTAssertEqual(completed.timestamp, date, "Retry/completion cannot replace the original response time.")
    let unknown = ChatMessage(role: .user, text: "Older text.", timestamp: nil)
    let rail = ChatMessageActionView(commands: ChatMessageCommands(model: model, chatID: chatID, message: unknown))
    XCTAssertTrue(rail.timestamp.isHidden); XCTAssertEqual(rail.timestamp.stringValue, "")
    let waiting = ChatMessageActionView(commands: ChatMessageCommands(model: model, chatID: chatID, message: pending))
    XCTAssertFalse(waiting.editButton.isEnabled); XCTAssertFalse(waiting.branchButton.isEnabled)
    XCTAssertFalse(try XCTUnwrap(waiting.feedbackButton).isEnabled)
    try await model.shutdown()
  }
}
