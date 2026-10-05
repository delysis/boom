import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class ChatVoiceTests: XCTestCase {
  private func store() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-chat-voice-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
  }
  @MainActor func testOrdinaryChatPinsAndEditsWithoutRewritingCapturedVersions() async throws {
    let store = try store(), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    let chatID = try XCTUnwrap(model.state.selectedChat)
    model.renameChat(chatID, to: "Quiet Perspective")
    try model.setChatInstructions("Notice the hesitation.", mention: nil, chatID: chatID)
    model.authorChatMessage(.user); model.draft = "I am rushing."; model.send()
    model.authorChatMessage(.assistant); model.draft = "Give yourself a moment."; model.send()
    model.pinChat(chatID)
    let captured = try XCTUnwrap(model.chatVoice(chatID))
    XCTAssertEqual(captured.id, chatID); XCTAssertEqual(captured.slug, "quiet-perspective")
    XCTAssertEqual(captured.instructions, "Notice the hesitation.")
    XCTAssertEqual(captured.examples, [VoiceExchange(user: "I am rushing.", assistant: "Give yourself a moment.")])
    let original = try XCTUnwrap(model.selectedChat?.messages.last)
    try model.replaceChatMessage("Pause and listen.", id: original.id, chatID: chatID)
    try model.setChatInstructions("Listen before responding.", mention: "quiet", chatID: chatID)
    let edited = try XCTUnwrap(model.chatVoice(chatID))
    XCTAssertEqual(edited.id, captured.id); XCTAssertEqual(edited.slug, "quiet")
    XCTAssertNotEqual(edited.revision, captured.revision)
    XCTAssertEqual(captured.examples[0].assistant, "Give yourself a moment.")
    XCTAssertTrue(model.state.voiceVersions.contains { $0.revision == captured.revision })
    XCTAssertEqual(model.selectedChat?.messageVersions, [original])
    XCTAssertEqual(model.selectedChat?.messages.last?.editedFrom, original.id)
    XCTAssertEqual(model.selectedChat?.messages.last?.authoredByUser, true)
    XCTAssertEqual(edited.examples[0].assistant, "Pause and listen.")
    try await model.shutdown()
    let loaded = try await store.load().get().0
    XCTAssertEqual(loaded.voices, [edited])
    XCTAssertEqual(loaded.chats.first { $0.id == chatID }?.messageVersions, [original])
    model.unpinChat(chatID)
    XCTAssertNil(model.chatVoice(chatID))
    XCTAssertEqual(model.selectedChat?.instructions, "Listen before responding.")
    XCTAssertEqual(model.selectedChat?.messages.last?.text, "Pause and listen.")
  }
  @MainActor func testEditingPreservesCapturedSpeakerAndSourceProvenance() async throws {
    let store = try store()
    var state = WorkspaceState()
    let voice = try ProductCore.voice(VoiceDraft(slug: "reader", name: "Reader", instructions: "Read attentively."))
    let source = SourceReference(id: UUID(), title: "Notes", digest: "captured", kind: "document")
    let original = ChatMessage(role: .assistant, text: "Original answer", context: "Captured context",
      sources: [source], provider: "Captured model", speaker: voice.speaker, authoredByUser: true)
    let chat = ChatRecord(title: "Consultation", messages: [original])
    state.chats = [chat]; state.selectedChat = chat.id
    try await store.save(state, documents: [])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try model.replaceChatMessage("My revision", id: original.id, chatID: chat.id)
    let edited = try XCTUnwrap(model.selectedChat?.messages.first)
    XCTAssertNotEqual(edited.id, original.id)
    XCTAssertEqual(edited.speaker, voice.speaker)
    XCTAssertEqual(edited.context, original.context); XCTAssertEqual(edited.sources, original.sources)
    XCTAssertEqual(edited.editedFrom, original.id); XCTAssertEqual(edited.authoredByUser, true)
    try await model.shutdown()
    let loaded = try await store.load().get().0
    XCTAssertEqual(loaded.chats[0].messages[0], edited)
    XCTAssertEqual(loaded.chats[0].messageVersions, [original])
  }
  @MainActor func testCompiledLayoutKeepsItsPrimaryPaneAndRestoresSecondaryPanesAfterNarrowing() async throws {
    let model = try await WorkspaceModel(storeOverride: store(), loadModels: false)
    model.state.showLibrary = false
    model.fitPanes(to: 760)
    if model.layout.isAuthor {
      let documentID = try XCTUnwrap(model.state.selectedDocument)
      try model.newChat(about: documentID)
      XCTAssertTrue(model.showsDocument); XCTAssertTrue(model.showsChat)
      model.selectDocument(documentID)
      XCTAssertTrue(model.showsChat)
      model.toggle("document")
      XCTAssertTrue(model.showsDocument)
      model.toggle("chat"); XCTAssertFalse(model.showsChat)
      model.toggle("chat"); XCTAssertTrue(model.showsChat)
    } else {
      XCTAssertTrue(model.showsChat); XCTAssertFalse(model.showsDocument)
      model.toggle("document"); model.toggle("chat")
      XCTAssertTrue(model.showsChat); XCTAssertFalse(model.showsDocument)
    }
    model.fitPanes(to: 1100)
    model.toggle("library"); XCTAssertTrue(model.showsLibrary)
    model.fitPanes(to: 540)
    XCTAssertTrue(model.showsChat || model.showsDocument)
    model.fitPanes(to: 1100)
    XCTAssertTrue(model.showsLibrary)
    XCTAssertEqual(model.showsDocument, model.layout.isAuthor)
    XCTAssertTrue(model.showsChat)
    try await model.shutdown()
  }
}
