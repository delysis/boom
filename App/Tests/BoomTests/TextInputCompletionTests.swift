import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class TextInputCompletionTests: XCTestCase {
  @MainActor private func input(_ view: NSView) -> ChatTextView? {
    if let text = view as? ChatTextView { return text }
    return view.subviews.lazy.compactMap(input).first
  }
  @MainActor private func model() async throws -> WorkspaceModel {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-input-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256)), loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    model.authorChatMessage(.user); model.draft = "A question."; model.send()
    model.authorChatMessage(.assistant); model.draft = "An answer."; model.send()
    model.state.autocomplete = false
    return model
  }
  @MainActor private func key(_ code: UInt16, _ text: ChatTextView) throws {
    text.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: text.window?.windowNumber ?? 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
  }
  @MainActor func testComposerAndBothMessageEditorsShareReversibleWordsWithoutSavingGhosts() async throws {
    let model = try await model()
    let chat = try XCTUnwrap(model.selectedChat), originals = chat.messages
    for message in [nil] + originals.map(Optional.some) {
      let target = TextInputTarget(chatID: chat.id, documentID: nil, messageID: message?.id)
      let original = message?.text ?? "My draft."
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 340, height: 400))
      window.isReleasedWhenClosed = false
      let host: NSView
      if let message {
        host = NSHostingView(rootView: ChatTextEditor(label: "Edit message", text: message.text,
          completionModel: model, completionTarget: target, save: { _ in }, cancel: {}))
      } else {
        model.draft = original
        host = NSHostingView(rootView: ChatComposer(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
          focusRequest: 0, onSend: {}, onCancel: {}, completionModel: model, completionTarget: target))
      }
      window.contentView = host
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      let text = try XCTUnwrap(input(host)), completion = try XCTUnwrap(text.completionClient as? TextInputCompletion)
      window.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
      let words = [" Café ", "👩🏽‍💻 ", "waits.\n", "One ", "more."]
      completion.resumeGhost(words.joined(), documentID: text.documentID, caret: text.selectedRange().location, sources: [])
      for _ in 0..<3 {
        for index in words.indices {
          try key(124, text)
          XCTAssertEqual(text.string, original + words.prefix(index + 1).joined())
          XCTAssertEqual(completion.ghostText, words.dropFirst(index + 1).joined())
        }
        try key(124, text)
        for index in words.indices.reversed() {
          try key(123, text)
          XCTAssertEqual(text.string, original + words.prefix(index).joined())
          XCTAssertEqual(completion.ghostText, words.dropFirst(index).joined())
        }
      }
      try key(124, text)
      let accepted = text.string
      let copyShortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
      text.keyDown(with: copyShortcut)
      XCTAssertEqual(text.string, accepted)
      try key(123, text)
      XCTAssertEqual(text.string, original, "Copying is not an edit and must preserve word reversal.")
      try key(124, text)
      text.insertText("typed", replacementRange: text.selectedRange())
      let typed = text.string
      try key(123, text)
      XCTAssertEqual(text.string, typed)
      XCTAssertNil(completion.ghostStamp)
      completion.resumeGhost(" private suggestion", documentID: text.documentID, caret: text.selectedRange().location, sources: [])
      text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(text.hasMarkedText()); XCTAssertNil(completion.ghostStamp)
      text.unmarkText()
      XCTAssertEqual(model.selectedChat?.messages, originals, "Inline completion cannot save an exchange implicitly.")
    }
    try await model.shutdown()
  }
  @MainActor func testCapturedContextPreservesSpeakersAndExcludesLaterTurnsAndTextAfterCaret() async throws {
    let model = try await model(), chat = try XCTUnwrap(model.selectedChat)
    let target = TextInputTarget(chatID: chat.id, documentID: nil, messageID: chat.messages[1].id)
    let compiled = try model.inputContext(target, text: "A new answer. AFTER", caret: "A new answer.".utf16.count)
    XCTAssertEqual(compiled, "You: A question.\n\nBloom: A new answer.")
    XCTAssertFalse(compiled.contains("AFTER")); XCTAssertFalse(compiled.contains("An answer."))
    let old = try model.inputContextDigest(target)
    model.authorChatMessage(.user); model.draft = "A later turn."; model.send()
    XCTAssertNotEqual(try model.inputContextDigest(target), old)
    XCTAssertEqual(try model.inputContext(target, text: "Prefix", caret: 6), "You: A question.\n\nBloom: Prefix")
    try await model.shutdown()
  }
}
