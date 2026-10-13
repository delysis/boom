import AppKit
import BoomCore
import SwiftUI
import XCTest
@testable import Boom

final class NativeReadingSourceVersionTests: XCTestCase {
  @MainActor private final class StorageEdits: NSObject, NSTextStorageDelegate {
    var characters = 0
    var attributes = 0
    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
      range: NSRange, changeInLength: Int) {
      if mask.contains(.editedCharacters) { characters += 1 }
      if mask.contains(.editedAttributes) { attributes += 1 }
    }
  }
  private func candidate(text: String = "", state: MessageState = .pending) -> WritingCandidate {
    // Authored fixture metadata, never represented as actual model generation.
    WritingCandidate(id: UUID(), seed: 42, text: text, state: state,
      promptTokens: 8, outputTokens: 2, tokenIDs: [5, 6], stopReason: "unit-fixture", stopTokenID: 7,
      batch: WritingBatchExecution(seeds: [42, 43, 44], lane: 0),
      executionOrigin: GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "unit-fixture",
        cachedPromptTokens: 0, cacheMissReason: "no_owner"))
  }

  func testCandidateCopyWritebackRecoveryAndCodecKeepSourceAndGenerationFields() throws {
    let original = candidate(text: "Café."), version = original.readingVersion
    let mutations: [(inout WritingCandidate) -> Void] = [
      { $0.text = "Cafe\u{301}." }, { $0.text.append(" A lantern.") },
      { $0.text.replaceSubrange($0.text.startIndex..<$0.text.index(after: $0.text.startIndex), with: "A") },
      { $0.state = .cancelled },
    ]
    for mutate in mutations {
      var first = original, second = original
      mutate(&first); mutate(&second)
      XCTAssertNotEqual(first.readingVersion, version)
      XCTAssertNotEqual(first.readingVersion, second.readingVersion)
      XCTAssertEqual(Data(original.text.utf8), Data("Café.".utf8))
    }
    var recovered = original
    let progress = GenerationProgress(text: "Cafe\u{301}. Recovered prose.", tokenIDs: [5, 6, 8],
      promptDigest: "unit-fixture", promptTokens: 8, firstTokenSeconds: nil, elapsedSeconds: 1,
      executionOrigin: original.executionOrigin)
    recovered.retain(progress)
    XCTAssertNotEqual(recovered.readingVersion, version)
    XCTAssertEqual(Data(recovered.text.utf8), Data(progress.text.utf8))
    XCTAssertEqual(recovered.tokenIDs, progress.tokenIDs)
    var metadata = original
    metadata.promptTokens = 9; metadata.outputTokens = 3; metadata.tokenIDs.append(8)
    metadata.stopReason = "changed"; metadata.stopTokenID = nil; metadata.batch = nil
    metadata.executionOrigin = nil
    XCTAssertEqual(metadata.readingVersion, version)

    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let bytes = try encoder.encode(original)
    var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set([
      "id", "seed", "text", "state", "promptTokens", "outputTokens", "tokenIDs", "stopReason",
      "stopTokenID", "batch", "executionOrigin"
    ]))
    fields["readingVersion"] = version.uuidString
    let restored = try JSONDecoder().decode(WritingCandidate.self,
      from: JSONSerialization.data(withJSONObject: fields))
    XCTAssertNotEqual(restored.readingVersion, version)
    XCTAssertEqual(try encoder.encode(restored), bytes)
    XCTAssertEqual(restored.executionOrigin, original.executionOrigin)
    XCTAssertEqual(restored.batch, original.batch)
    XCTAssertEqual(Data(restored.text.utf8), Data(original.text.utf8))
    fields.removeValue(forKey: "stopTokenID"); fields.removeValue(forKey: "batch")
    fields.removeValue(forKey: "executionOrigin")
    let legacy = try JSONDecoder().decode(WritingCandidate.self,
      from: JSONSerialization.data(withJSONObject: fields))
    XCTAssertNil(legacy.stopTokenID); XCTAssertNil(legacy.batch); XCTAssertNil(legacy.executionOrigin)
  }

  @MainActor func testDerivedEmptyStreamingAndRecoveredTextKeepExistingVisibleCopy() {
    _ = NSApplication.shared
    let reader = NativeReadingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
    var message = ChatMessage(role: .assistant, text: "", state: .pending, failure: "Retained failure.")
    reader.setSource(message); XCTAssertEqual(reader.string, "…")
    XCTAssertEqual(NativeText(message: message).text, reader.string)
    message.state = .failed
    reader.setSource(message); XCTAssertEqual(reader.string, "Retained failure.")
    message.failure = "A different failure."
    reader.setSource(message); XCTAssertEqual(reader.string, "A different failure.")
    message.failure = nil
    reader.setSource(message); XCTAssertEqual(reader.string, "")
    message.state = .pending; message.text = "Café 👩🏽‍💻."
    reader.setSource(message); XCTAssertEqual(Data(reader.string.utf8), Data(message.text.utf8))
    message.text = "Cafe\u{301} 👩🏽‍💻."
    reader.setSource(message); XCTAssertEqual(Data(reader.string.utf8), Data(message.text.utf8))
    XCTAssertEqual((reader.string as NSString).range(of: "👩🏽‍💻"), (message.text as NSString).range(of: "👩🏽‍💻"))
    message.state = .cancelled; message.failure = "This must not replace retained prose."
    reader.setSource(message); XCTAssertEqual(Data(reader.string.utf8), Data(message.text.utf8))
    let deliveredVersion = message.readingVersion
    let recovered = GenerationProgress(text: "Cafe\u{301}. Journal-recovered answer.", tokenIDs: [5, 6, 8],
      promptDigest: "unit-fixture", promptTokens: 8, firstTokenSeconds: nil, elapsedSeconds: 1)
    message.text = recovered.text
    XCTAssertNotEqual(message.readingVersion, deliveredVersion)
    reader.setSource(message); XCTAssertEqual(Data(reader.string.utf8), Data(recovered.text.utf8))

    var continuation = candidate()
    let emptyCases: [(MessageState, String)] = [
      (.pending, "Writing a continuation…"), (.cancelled, "Stopped before any prose was produced."),
      (.complete, "The model ended this continuation before producing prose."),
      (.failed, "The model ended this continuation before producing prose.")
    ]
    for (state, expected) in emptyCases {
      continuation.state = state
      reader.setSource(continuation); XCTAssertEqual(reader.string, expected)
      XCTAssertEqual(NativeText(candidate: continuation).text, expected)
    }
    continuation.state = .pending
    continuation.retain(GenerationProgress(text: "Cafe\u{301}. Recovered prose.", tokenIDs: [5, 6, 8],
      promptDigest: "unit-fixture", promptTokens: 8, firstTokenSeconds: nil, elapsedSeconds: 1))
    reader.setSource(continuation)
    XCTAssertEqual(Data(reader.string.utf8), Data(continuation.text.utf8))
  }

  @MainActor func testOwnedReaderSkipsNoOpEditsButPreservesStyleAndExternalMutationGuard() throws {
    _ = NSApplication.shared
    let reader = NativeReadingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
    let message = ChatMessage(role: .assistant, text: "Café **lantern**.")
    reader.setSource(message)
    let storage = try XCTUnwrap(reader.textStorage), observer = StorageEdits()
    storage.delegate = observer
    defer { storage.delegate = nil }
    let version = reader.sourceVersion
    for _ in 0..<5 { reader.setSource(message) }
    XCTAssertEqual(observer.characters, 0); XCTAssertEqual(observer.attributes, 0)
    XCTAssertEqual(reader.sourceVersion, version)
    reader.setSource(message, presentation: .literal, pointSize: 18)
    XCTAssertEqual(observer.characters, 0); XCTAssertGreaterThan(observer.attributes, 0)
    XCTAssertEqual(reader.sourceVersion, version)
    XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "External buffer change.")
    XCTAssertNotEqual(reader.sourceVersion, version)
    reader.setSource(message, presentation: .literal, pointSize: 18)
    XCTAssertEqual(Data(reader.string.utf8), Data(message.text.utf8))

    let layout = try XCTUnwrap(reader.layoutManager), rebound = NSTextStorage(string: "Different storage.")
    let beforeRebind = reader.sourceVersion
    layout.replaceTextStorage(rebound)
    XCTAssertNotEqual(reader.sourceVersion, beforeRebind)
    reader.setSource(message, presentation: .literal, pointSize: 18)
    XCTAssertEqual(Data(reader.string.utf8), Data(message.text.utf8))

    // Raw callers cannot borrow the previously acknowledged owner's identity.
    reader.setSource(message.text, presentation: .literal)
    reader.setSource("Cafe\u{301} **lantern**.", presentation: .literal)
    XCTAssertEqual(Data(reader.string.utf8), Data("Cafe\u{301} **lantern**.".utf8))
    reader.setSource(message, presentation: .literal)
    XCTAssertEqual(Data(reader.string.utf8), Data(message.text.utf8))
  }

  @MainActor private func readers(in view: NSView) -> [NativeReadingTextView] {
    if let reader = view as? NativeReadingTextView { return [reader] }
    return view.subviews.flatMap(readers)
  }
  @MainActor private func settle(_ host: NSView) async throws {
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
  }
  @MainActor func testActualChatAndCandidateRowsRetainSourceAcrossWorkspaceStatusAndSiblingUpdates() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-reading-version-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root)
    let document = DocumentSnapshot(title: "Public fixture", text: "Public manuscript.")
    let message = ChatMessage(role: .assistant, text: "A retained public chat answer.")
    let chat = ChatRecord(messages: [message], attachedDocumentID: document.id)
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.chats = [chat]; state.selectedChat = chat.id; state.selectedDocument = document.id
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [document])
    let messageVersion = try XCTUnwrap(model.selectedChat?.messages.first).readingVersion
    let first = candidate(text: "A retained public continuation.", state: .complete)
    let second = candidate(text: "A sibling continuation.")
    let recipe = CompletionRecipe(document: document, caretUTF16: document.text.utf16.count,
      sources: [], prompt: document.text, promptDigest: document.revision, omittedPrefixCharacters: 0,
      model: "unit-fixture", profile: .standard, settings: try ProductCore.sampling(.standard),
      maxTokens: 16, generationPolicy: nil)
    model.candidates = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [first, second], selected: 0)
    let host = NSHostingView(rootView: VStack { ChatPane(model: model); WritingAlternatives(model: model) })
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 800, height: 900))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await settle(host)
    let displayed = readers(in: host).filter { $0.string == message.text || $0.string == first.text }
    XCTAssertEqual(displayed.count, 2)
    let versions = displayed.map(\.sourceVersion)
    let observers = displayed.map { reader -> StorageEdits in
      let observer = StorageEdits(); reader.textStorage?.delegate = observer; return observer
    }
    defer { displayed.forEach { $0.textStorage?.delegate = nil } }
    for index in 0..<4 {
      model.status = "Public status \(index)"; model.ghostText = "Public ghost \(index)"
      model.candidates?.candidates[1].text.append(" Sibling update.")
      try await settle(host)
    }
    XCTAssertEqual(displayed.map(\.sourceVersion), versions)
    XCTAssertTrue(observers.allSatisfy { $0.characters == 0 && $0.attributes == 0 })
    XCTAssertEqual(model.selectedChat?.messages[0].readingVersion, messageVersion)
    XCTAssertEqual(model.candidates?.candidates[0].readingVersion, first.readingVersion)
    XCTAssertNotEqual(model.candidates?.candidates[1].readingVersion, second.readingVersion)
    try await model.shutdown()
  }
}
