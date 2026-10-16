import BoomCore
import AppKit
import SwiftUI
import XCTest
@testable import Boom

final class GeneratedTextTests: XCTestCase {
  @MainActor private final class WorkspaceCleanup {
    private var model: WorkspaceModel?
    private var shutdownAttempted = false
    private var shutdownFailure: Error?
    init(_ model: WorkspaceModel) { self.model = model }
    func close() async throws {
      guard !shutdownAttempted else {
        if let shutdownFailure { throw shutdownFailure }
        return
      }
      shutdownAttempted = true
      guard let model else { return }
      do { try await model.shutdown(); self.model = nil }
      catch { shutdownFailure = error; throw error }
    }
  }
  func testAuthoredPrefixUsesUnicodeCaretAndOmitsFollowingText() throws {
    let doc = DocumentSnapshot(title: "Draft", text: "é🦋 before|after")
    XCTAssertEqual(try ProductCore.authoredPrefix(doc, caret: 10), "é🦋 before")
    XCTAssertThrowsError(try ProductCore.authoredPrefix(doc, caret: 2))
  }
  @MainActor func testNativeWritingAvailabilityMatchesActualPrefixAcrossUnicodeCarets() {
    for source in ["", " \t\n\r\u{00a0}\u{202f}", "  a🙂 after", "e\u{301} after",
      "👩‍💻 after", "🇺🇸 after", "x\r\ny", "\u{200b} after"] {
      let document = DocumentSnapshot(title: "Public", text: source)
      for caret in [-1] + Array(0...source.utf16.count) + [Int.max] {
        let expected = (try? ProductCore.authoredPrefix(document, caret: caret))
          .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        XCTAssertEqual(MarkdownTextView.hasAuthoredPrefix(document, caret: caret), expected,
          "Source \(source.debugDescription), caret \(caret)")
      }
    }
  }
  @MainActor func testNativeWritingAvailabilityPreservesActualUTF8ManuscriptBudget() {
    for source in [String(repeating: "a", count: 2_097_152),
      String(repeating: "a", count: 2_097_153),
      String(repeating: "€", count: 699_050), String(repeating: "€", count: 699_051)] {
      let document = DocumentSnapshot(title: "Public", text: source)
      let expected = (try? ProductCore.authoredPrefix(document, caret: 1))
        .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
      XCTAssertEqual(MarkdownTextView.hasAuthoredPrefix(document, caret: 1), expected)
    }
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
    let store = try WorkspaceStore(rootOverride: root)
    let snapshot = DocumentSnapshot(title: "Draft", text: "Café 👩‍💻 waits UNSEEN")
    let example = DocumentSnapshot(title: "Example", text: "An earlier passage.")
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = snapshot.id
    state.documents = [snapshot, example].map { DocumentIndex(id: $0.id, title: $0.title) }
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [snapshot, example])
    let cleanup = WorkspaceCleanup(model)
    let app = NSApplication.shared
    let policy = app.activationPolicy()
    if policy != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
    defer { app.setActivationPolicy(policy) }
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
    window.center(); window.showAsInvisibleNativeTestWindow(); app.activate(ignoringOtherApps: true)
    let initialFailures = testRun?.failureCount ?? 0
    addTeardownBlock {
      try await cleanup.close()
      await MainActor.run { window.close() }
      if await MainActor.run(body: { self.testRun?.failureCount ?? 0 }) == initialFailures {
        try FileManager.default.removeItem(at: root)
      }
    }
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let editor = try XCTUnwrap(model.pagedInput?.activeView)
    guard window.makeFirstResponder(editor), window.isKeyWindow,
      window.firstResponder === editor else {
      throw XCTSkip("Captured branching requires the actual active native editor; app-run acceptance covers that route.")
    }
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
    try await NativeCheckEvidence.replacePublicDocument(model, text: "A live revision.", id: snapshot.id, caret: 0)
    try await NativeCheckEvidence.replacePublicDocument(model, text: "A changed example.", id: example.id, caret: 0)
    XCTAssertFalse(model.candidateIsCurrent)
    XCTAssertNoThrow(try ProductCore.validateWritingRecipe(recipe))
    model.branchCandidate(0)
    try await model.joinWorkspaceOperation()
    _ = try await NativeCheckEvidence.readPublicDocuments(model: model)
    let branch = try XCTUnwrap(model.selectedDocument)
    XCTAssertEqual(branch.text, "Café 👩‍💻 waits quietly. UNSEEN")
    XCTAssertEqual(model.documents.first { $0.id == snapshot.id }?.text, "A live revision.")
    let origin = try XCTUnwrap(model.state.manuscriptOrigins[branch.id])
    XCTAssertEqual(origin.documentID, snapshot.id); XCTAssertEqual(origin.revision, snapshot.revision)
    XCTAssertEqual(origin.bundleID, bundle.id); XCTAssertEqual(origin.candidateID, candidate.id)
    try await cleanup.close()
    let reloaded = (try await store.loadState(), try await NativeCheckEvidence.readPublicDocuments(store: store))
    XCTAssertEqual(reloaded.1.first { $0.id == branch.id }?.text, branch.text)
    XCTAssertEqual(reloaded.0.manuscriptOrigins[branch.id]?.candidateID, candidate.id)
    if (testRun?.failureCount ?? 0) == initialFailures { try FileManager.default.removeItem(at: root) }
  }
  @MainActor func testNativePartialAcceptanceUndoRestoresExactManuscript() async throws {
    try await verifyWordAcceptance(continuation: " quietly by the window.", accepted: " quietly ")
  }
  @MainActor func testNativeParagraphContinuationAcceptanceUndo() async throws {
    try await verifyWordAcceptance(continuation: "\n\n\tCafé 👩🏽‍💻 waits.", accepted: "\n\n\tCafé ")
  }
  @MainActor private func verifyWordAcceptance(continuation: String, accepted: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-writing-undo-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    let before = String(repeating: "A public passage before the caret.\n\n", count: 220) + "Café waits"
    let document = DocumentSnapshot(title: "Draft", text: before + " AFTER")
    let caret = before.utf16.count
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = document.id
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [document])
    let cleanup = WorkspaceCleanup(model)
    _ = NSApplication.shared
    guard model.layout.isAuthor else {
      try await cleanup.close()
      throw XCTSkip("The compiled chat edition has no manuscript editor.")
    }
    let app = NSApplication.shared
    let policy = app.activationPolicy()
    if policy != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
    defer { app.setActivationPolicy(policy) }
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
    let initialFailures = testRun?.failureCount ?? 0
    addTeardownBlock {
      try await cleanup.close()
      await MainActor.run { window.close() }
      if await MainActor.run(body: { self.testRun?.failureCount ?? 0 }) == initialFailures {
        try FileManager.default.removeItem(at: root)
      }
    }
    window.center(); window.showAsInvisibleNativeTestWindow(); app.activate(ignoringOtherApps: true)
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    guard window.makeFirstResponder(view), window.isKeyWindow,
      window.firstResponder === view else {
      throw XCTSkip("Native continuation acceptance requires the actual active editor; app-run acceptance covers that route.")
    }
    let manager = try XCTUnwrap(model.pagedCommands).manager
    view.setSelectedRange(NSRange(location: caret, length: 0)); model.movedCaret(caret, hasMarkedText: false)
    let compiled = try ProductCore.writingPrompt(document, caret: caret, examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: document, caretUTF16: caret, sources: [], prompt: compiled.prompt,
      promptDigest: compiled.digest, omittedPrefixCharacters: 0, model: "unit-test-model", profile: .standard,
      settings: try ProductCore.sampling(.standard), maxTokens: 64, generationPolicy: nil)
    // Authored fixture; no inference or writing-quality claim.
    let candidate = WritingCandidate(id: UUID(), seed: 42, text: continuation, state: .complete,
      promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: "unit-fixture")
    model.candidates = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [candidate], selected: 0)
    manager.groupsByEvent = false; manager.removeAllActions(); manager.beginUndoGrouping()
    model.acceptCandidateWord(0); manager.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.selectedDocument?.text, before + accepted + " AFTER")
    XCTAssertTrue(manager.canUndo); XCTAssertFalse(model.candidateIsCurrent)
    XCTAssertTrue(view.tryToPerform(NSSelectorFromString("undo:"), with: nil))
    XCTAssertEqual(view.string, document.text)
    XCTAssertEqual(model.selectedDocument?.text, document.text)
    try await cleanup.close()
    let loaded = try await NativeCheckEvidence.readPublicDocuments(store: store)
    XCTAssertEqual(loaded.first { $0.id == document.id }, document)
    if (testRun?.failureCount ?? 0) == initialFailures { try FileManager.default.removeItem(at: root) }
  }
}
