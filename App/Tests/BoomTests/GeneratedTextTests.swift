import BoomCore
import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class GeneratedTextTests: XCTestCase {
  func testAuthoredPrefixUsesUnicodeCaretAndOmitsFollowingText() throws {
    let doc = DocumentSnapshot(title: "Draft", text: "é🦋 before|after")
    XCTAssertEqual(try ProductCore.authoredPrefix(doc, caret: 10), "é🦋 before")
    XCTAssertThrowsError(try ProductCore.authoredPrefix(doc, caret: 2))
  }
  func testCapturedVoiceRevisionAndSpeakerAttribution() throws {
    let first = try ProductCore.voice(VoiceDraft(slug: "sage", name: "Sage", instructions: "First approach"))
    var edited = first.draft; edited.instructions = "A new approach"; edited.name = "Renamed"
    let second = try ProductCore.voice(edited)
    XCTAssertNotEqual(first.revision, second.revision)
    let message = ChatMessage(role: .assistant, text: "Original answer", speaker: first.speaker)
    let plan = try ProductCore.prompt(voice: second, history: [message], instructions: "", context: "", request: "Another question", routing: [])
    XCTAssertTrue(plan.rawPrompt.contains("Sage")); XCTAssertTrue(plan.rawPrompt.contains("Original answer"))
    XCTAssertFalse(plan.messages.filter { $0.role == "assistant" }.contains { $0.content == "Original answer" })
    XCTAssertEqual(message.speaker?.voiceRevision, first.revision)
  }
  func testLexicalOpeningsRemainAvailable() {
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("Here is the continuation:"))
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("<3 forever"))
  }
  @MainActor func testCapturedBranchSurvivesLiveManuscriptAndExampleEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-writing-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let snapshot = DocumentSnapshot(title: "Draft", text: "Café 👩‍💻 waits UNSEEN")
    let example = DocumentSnapshot(title: "Example", text: "An earlier passage.")
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = snapshot.id
    state.documents = [snapshot, example].map { DocumentIndex(id: $0.id, title: $0.title) }
    try await store.save(state, documents: [snapshot, example])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let caret = "Café 👩‍💻 waits".utf16.count
    let compiled = try ProductCore.writingPrompt(snapshot, caret: caret, examples: [example.text], retaining: Int.max)
    let recipe = CompletionRecipe(document: snapshot, caretUTF16: caret,
      sources: [SourceReference(id: example.id, title: example.title, digest: example.revision, kind: "document")],
      prompt: compiled.prompt, promptDigest: compiled.digest, omittedPrefixCharacters: 0,
      model: "unit-test-model", profile: .standard, settings: try ProductCore.sampling(.standard), maxTokens: 256, generationPolicy: nil)
    // Authored unit fixture, never represented as an actual model output.
    let candidate = WritingCandidate(id: UUID(), seed: 42, text: " quietly.", state: .complete,
      promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: "unit-fixture")
    let bundle = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [candidate], selected: 0)
    model.candidates = bundle
    model.updateDocument("A live revision.", id: snapshot.id, caret: 0)
    model.updateDocument("A changed example.", id: example.id, caret: 0)
    XCTAssertFalse(model.candidateIsCurrent)
    XCTAssertNoThrow(try ProductCore.validateWritingRecipe(recipe))
    model.branchCandidate(0)
    let branch = try XCTUnwrap(model.selectedDocument)
    XCTAssertEqual(branch.text, "Café 👩‍💻 waits quietly. UNSEEN")
    XCTAssertEqual(model.documents.first { $0.id == snapshot.id }?.text, "A live revision.")
    let origin = try XCTUnwrap(model.state.manuscriptOrigins[branch.id])
    XCTAssertEqual(origin.documentID, snapshot.id); XCTAssertEqual(origin.revision, snapshot.revision)
    XCTAssertEqual(origin.bundleID, bundle.id); XCTAssertEqual(origin.candidateID, candidate.id)
    try await model.shutdown()
    let reloaded = try await store.load().get()
    XCTAssertEqual(reloaded.1.first { $0.id == branch.id }?.text, branch.text)
    XCTAssertEqual(reloaded.0.manuscriptOrigins[branch.id]?.candidateID, candidate.id)
  }
  @MainActor func testNativePartialAcceptanceUndoRestoresExactManuscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-writing-undo-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let before = String(repeating: "A public passage before the caret.\n\n", count: 220) + "Café waits"
    let document = DocumentSnapshot(title: "Draft", text: before + " AFTER")
    let caret = before.utf16.count
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = document.id
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    _ = NSApplication.shared
    guard model.layout.isAuthor else {
      try await model.shutdown()
      throw XCTSkip("The compiled chat edition has no manuscript editor.")
    }
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1440, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let view = try XCTUnwrap(model.editor)
    let manager = model.undoManager(document.id)
    view.setSelectedRange(NSRange(location: caret, length: 0)); model.movedCaret(caret, hasMarkedText: false)
    let compiled = try ProductCore.writingPrompt(document, caret: caret, examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: document, caretUTF16: caret, sources: [], prompt: compiled.prompt,
      promptDigest: compiled.digest, omittedPrefixCharacters: 0, model: "unit-test-model", profile: .standard,
      settings: try ProductCore.sampling(.standard), maxTokens: 64, generationPolicy: nil)
    // Authored fixture; no inference or writing-quality claim.
    let candidate = WritingCandidate(id: UUID(), seed: 42, text: " quietly by the window.", state: .complete,
      promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: "unit-fixture")
    model.candidates = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [candidate], selected: 0)
    manager.groupsByEvent = false; manager.removeAllActions(); manager.beginUndoGrouping()
    model.acceptCandidateWord(0); manager.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.selectedDocument?.text, before + " quietly  AFTER")
    XCTAssertTrue(manager.canUndo); XCTAssertFalse(model.candidateIsCurrent)
    XCTAssertTrue(view.tryToPerform(NSSelectorFromString("undo:"), with: nil))
    XCTAssertEqual(view.string, document.text)
    XCTAssertEqual(model.selectedDocument?.text, document.text)
    try await model.shutdown()
    let loaded = try await store.load().get()
    XCTAssertEqual(loaded.1.first { $0.id == document.id }, document)
  }
}
