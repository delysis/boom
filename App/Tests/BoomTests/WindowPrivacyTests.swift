import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class WindowPrivacyTests: XCTestCase {
  @MainActor func testWorkspaceReopensFromEncryptionWithSystemRestorationDisabled() async throws {
    let app = NSApplication.shared, previous = NSApplication.shared.activationPolicy()
    app.setActivationPolicy(.prohibited); defer { app.setActivationPolicy(previous) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-window-privacy-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let document = DocumentSnapshot(title: "Private window title 🦋", text: "Window privacy manuscript canary é.\n")
    let question = ChatMessage(role: .user, text: "Window privacy question canary.")
    let chat = ChatRecord(title: "Private conversation title", messages: [question], instructions: "Window privacy instruction canary.")
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.chats = [chat]; state.selectedDocument = document.id; state.selectedChat = chat.id
    state.showChat = true; state.showLibrary = false
    try await store.save(state, documents: [document])

    let fresh = try WorkspaceStore(rootOverride: root, testKey: key)
    let model = try await WorkspaceModel(storeOverride: fresh, loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
    window.isReleasedWhenClosed = false; defer { window.close() }
    window.title = model.layout.isAuthor ? model.selectedDocument?.title ?? "" : model.selectedChat?.title ?? ""
    let host = NSHostingView(rootView: WorkspaceView(model: model)); window.contentView = host
    host.layoutSubtreeIfNeeded()

    XCTAssertFalse(window.isRestorable, "A private workspace must not opt into AppKit state preservation.")
    XCTAssertNil(window.restorationClass)
    XCTAssertFalse(window.isVisible); XCTAssertEqual(app.activationPolicy(), .prohibited)
    XCTAssertTrue(window.canBecomeKey)
    XCTAssertEqual(model.selectedDocument, document)
    XCTAssertEqual(model.selectedChat, chat)
    XCTAssertEqual(model.state.selectedDocument, document.id)
    XCTAssertEqual(model.state.selectedChat, chat.id)
    XCTAssertFalse(model.state.showLibrary)
    XCTAssertEqual(window.title, model.layout.isAuthor ? document.title : chat.title)
    try await model.flush(); try await model.shutdown()

    let reopened = try WorkspaceStore(rootOverride: root, testKey: key)
    let loaded = try await reopened.load().get()
    XCTAssertEqual(loaded.1, [document]); XCTAssertEqual(loaded.0.chats, [chat])
    XCTAssertEqual(loaded.0.selectedDocument, document.id)
    XCTAssertEqual(loaded.0.selectedChat, chat.id)
    for file in try FileManager.default.contentsOfDirectory(at: reopened.vault.root, includingPropertiesForKeys: nil) {
      let bytes = try Data(contentsOf: file)
      for text in [document.title, document.text, chat.title, question.text, chat.instructions ?? ""] where !text.isEmpty {
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
          let needle = try XCTUnwrap(text.data(using: encoding))
          XCTAssertNil(bytes.range(of: needle), "A fixture canary appeared in its encrypted record.")
        }
      }
    }
  }
}
