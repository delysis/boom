import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// Real public-model residency transitions through the production controller.
/// Capacity checks do not qualify generation at the full context ceiling.
@MainActor enum ModelResidencySmoke {
  static func run(writingPack: URL, consultationPack: URL, fixtureURL: URL, evidence: URL) async throws {
    var receipt: [String: Any] = ["status": "running", "schema": 1,
      "source_inventory_sha256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "application_budget_bytes": try ModelResidency.budget(),
      "scope": "public fixtures, real model eviction/reload, focused automatic suggestions, stale editing, consultation preemption and Explore; full-context generation, physical input and Keychain remain unqualified",
      "full_context_generation_qualified": false, "keychain_dialogs_qualified": false,
      "physical_input_qualified": false, "window_shown": false]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    try persist()
    let probe = try ApplicationMemorySmoke.Probe(evidence.appendingPathComponent("memory-samples.jsonl"))
    var model: WorkspaceModel?
    var window: NSWindow?
    func finish(_ workspace: WorkspaceModel) async throws {
      let deadline = ContinuousClock().now.advanced(by: .seconds(180))
      while workspace.isBusy {
        guard ContinuousClock().now < deadline else { workspace.cancel(); throw BoomError.unavailable("Residency transition timed out.") }
        try await Task.sleep(for: .milliseconds(25))
      }
      try await workspace.flush()
    }
    do {
      let bytes = try AttachmentProcessor.readGranted(fixtureURL)
      let fixture = try JSONDecoder().decode(WritingEvaluation.Fixture.self, from: bytes)
      receipt["fixture_sha256"] = Digest.sha256(bytes)
      try bytes.write(to: evidence.appendingPathComponent("fixture.json"), options: .atomic)
      for (purpose, directory) in [(ModelPurpose.consultation, consultationPack), (.writing, writingPack)] {
        let admission = try await detachedWork { try ModelPacks.admission(directory, purpose: purpose) }
        receipt[purpose.rawValue + "_model"] = admission.identity
        try ModelPacks.evidenceManifest(admission, purpose: purpose)
          .write(to: evidence.appendingPathComponent(purpose.rawValue + "-manifest.json"), options: .atomic)
        try persist()
      }
      let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"),
        testKey: SymmetricKey(data: Data(repeating: 0x6b, count: 32)))
      var state = WorkspaceState(); state.autocomplete = false
      let documents = [fixture.document] + fixture.examples
      state.documents = documents.map { DocumentIndex(id: $0.id, title: $0.title) }
      state.selectedDocument = fixture.document.id
      try await store.save(state, documents: documents)
      let workspace = try await WorkspaceModel(storeOverride: store, loadModels: false); model = workspace
      guard workspace.layout.isAuthor else { throw BoomError.invalid("Use the author edition.") }
      let host = NSHostingView(rootView: WorkspaceView(model: workspace))
      let testWindow = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1440, height: 900))
      window = testWindow; testWindow.isReleasedWhenClosed = false; testWindow.contentView = host
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      guard let editor = workspace.editor, testWindow.makeFirstResponder(editor), editor.isEditable else {
        throw BoomError.invalid("Mounted manuscript did not accept an insertion point.")
      }
      for example in fixture.examples { workspace.toggleWritingExample(example.id) }
      probe.mark("open-consultation")
      _ = try await workspace.openModel(consultationPack, purpose: .consultation, flag: CancellationFlag())
      guard await workspace.selectedMLXRunner?.contextLength == 16_384 else {
        throw BoomError.budget("Consultation alone does not admit the context ceiling.")
      }
      probe.mark("open-writing-and-release-inactive")
      _ = try await workspace.openModel(writingPack, purpose: .writing, flag: CancellationFlag())
      guard workspace.selectedMLXRunner == nil, workspace.canInfer, workspace.baseReady,
        try await workspace.completionRunner?.contextLength(batchWidth: 3) == 16_384 else {
        throw BoomError.invalid("The public pair failed to release inactive weights while preserving consultation availability.")
      }
      receipt["writing_capacity_after_inactive_release"] = 16_384
      receipt["consultation_released_without_disabling_send"] = true; try persist()
      try workspace.newChat()
      let question = "Reply with one word: ready."
      workspace.draft = question
      probe.mark("send-reloads-consultation")
      workspace.send(); try await finish(workspace)
      guard workspace.draft.isEmpty, workspace.selectedMLXRunner != nil,
        workspace.completionRunner == nil, workspace.baseReady,
        let chat = workspace.selectedChat, chat.messages.count == 2,
        chat.messages[0].text == question, chat.messages[1].state == .complete,
        chat.messages[1].provider == receipt["consultation_model"] as? String,
        !chat.messages[1].text.isEmpty else {
        throw BoomError.invalid("Send failed to reload consultation or lost its captured question/reply.")
      }
      receipt["consultation_capacity_after_reload"] = await workspace.selectedMLXRunner?.contextLength
      receipt["consultation_reply"] = try ProductCore.object(chat)
      receipt["send_reloaded_same_snapshot"] = true; try persist()
      host.layoutSubtreeIfNeeded()
      editor.setSelectedRange(NSRange(location: fixture.caretUTF16, length: 0))
      workspace.movedCaret(fixture.caretUTF16, hasMarkedText: false)
      func suggestion(_ ready: (CandidateBundle) -> Bool) async throws -> CandidateBundle {
        let deadline = ContinuousClock().now.advanced(by: .seconds(180))
        while ContinuousClock().now < deadline {
          if let candidate = workspace.candidates, ready(candidate) { return candidate }
          try await Task.sleep(for: .milliseconds(25))
        }
        workspace.cancel()
        throw BoomError.unavailable("Automatic suggestion did not reach its registered state: " + workspace.status)
      }
      func composer(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text !== editor, text.isEditable { return text }
        for child in view.subviews { if let text = composer(child) { return text } }
        return nil
      }
      guard let chatComposer = composer(host), testWindow.makeFirstResponder(chatComposer) else {
        throw BoomError.invalid("The mounted chat composer did not accept input focus.")
      }
      probe.mark("chat-focus-does-not-reload-writing")
      workspace.setAutocomplete(true)
      try await Task.sleep(for: .milliseconds(800))
      guard workspace.completionRunner == nil, workspace.candidates == nil else {
        throw BoomError.invalid("Chat focus started an unsolicited writing-model reload.")
      }
      receipt["chat_focus_did_not_reload_writing"] = true; try persist()
      probe.mark("typing-reloads-writing-for-short-suggestion")
      guard testWindow.makeFirstResponder(editor) else { throw BoomError.invalid("Manuscript focus was lost.") }
      editor.insertText("x", replacementRange: NSRange(location: fixture.caretUTF16, length: 0))
      editor.insertText("", replacementRange: NSRange(location: fixture.caretUTF16, length: 1))
      let automatic = try await suggestion { $0.candidates.count == 1 && $0.candidates[0].state == .complete }
      guard automatic.recipe.maxTokens == 64, automatic.recipe.model == receipt["writing_model"] as? String,
        automatic.candidates[0].outputTokens <= 64, !automatic.candidates[0].text.isEmpty,
        !workspace.showingCandidates, !workspace.ghostText.isEmpty,
        workspace.selectedDocument == fixture.document, editor.string == fixture.document.text,
        editor.isEditable, workspace.selectedMLXRunner == nil else {
        throw BoomError.invalid("Typing failed to resume a short suggestion after writing-model eviction.")
      }
      receipt["automatic_suggestion"] = try ProductCore.object(automatic)
      receipt["typing_reloaded_same_snapshot"] = true; try persist()
      workspace.setAutocomplete(true)
      let interruptedByEdit = try await suggestion { $0.id != automatic.id && $0.candidates.count == 1
        && $0.candidates[0].state == .pending && $0.candidates[0].outputTokens > 0 }
      probe.mark("native-edit-invalidates-short-suggestion")
      editor.breakUndoCoalescing()
      editor.insertText("x", replacementRange: NSRange(location: fixture.caretUTF16, length: 0))
      workspace.setAutocomplete(false)
      editor.undoManager?.undo()
      let cancelledByEdit = try await suggestion { $0.id == interruptedByEdit.id && $0.candidates[0].state == .cancelled }
      guard editor.string == fixture.document.text, workspace.selectedDocument == fixture.document,
        workspace.ghostText.isEmpty else { throw BoomError.invalid("Obsolete automatic text survived native editing/Undo.") }
      receipt["cancelled_by_edit"] = try ProductCore.object(cancelledByEdit); try persist()
      workspace.setAutocomplete(true)
      let interruptedByConsultation = try await suggestion { $0.id != cancelledByEdit.id && $0.candidates.count == 1
        && $0.candidates[0].state == .pending && $0.candidates[0].outputTokens > 0 }
      probe.mark("consultation-preempts-automatic-suggestion")
      guard testWindow.makeFirstResponder(chatComposer) else { throw BoomError.invalid("Chat focus was lost.") }
      workspace.draft = question; workspace.send(); try await finish(workspace)
      guard let cancelledByConsultation = workspace.candidates,
        cancelledByConsultation.id == interruptedByConsultation.id,
        cancelledByConsultation.candidates[0].state == .cancelled,
        workspace.selectedChat?.messages.count == 4,
        workspace.selectedChat?.messages.last?.state == .complete,
        workspace.selectedMLXRunner != nil, workspace.completionRunner == nil,
        workspace.ghostText.isEmpty, editor.string == fixture.document.text else {
        throw BoomError.invalid("Foreground consultation failed to join/preempt the automatic suggestion.")
      }
      receipt["cancelled_by_consultation"] = try ProductCore.object(cancelledByConsultation)
      receipt["consultation_preempted_automatic_suggestion"] = true; try persist()
      workspace.setAutocomplete(false); workspace.dismissCandidates()
      guard testWindow.makeFirstResponder(editor) else { throw BoomError.invalid("Manuscript focus was lost after consultation.") }
      editor.setSelectedRange(NSRange(location: fixture.caretUTF16, length: 0))
      workspace.movedCaret(fixture.caretUTF16, hasMarkedText: false)
      guard workspace.canExploreWriting else { throw BoomError.invalid("Released writing model disabled Explore.") }
      probe.mark("explore-reloads-writing")
      workspace.exploreWriting(); try await finish(workspace)
      guard workspace.selectedMLXRunner == nil, workspace.canInfer,
        let bundle = workspace.candidates, bundle.candidates.count == 3,
        bundle.candidates.allSatisfy({ $0.state == .complete && !$0.text.isEmpty }),
        bundle.recipe.model == receipt["writing_model"] as? String,
        workspace.selectedDocument == fixture.document, editor.string == fixture.document.text,
        editor.isEditable, !testWindow.isVisible else {
        throw BoomError.invalid("Explore failed to reload writing, lost candidates or altered the manuscript.")
      }
      receipt["alternatives"] = try ProductCore.object(bundle)
      receipt["explore_reloaded_same_snapshot"] = true
      receipt["manuscript_and_native_editor_unchanged"] = true
      try await workspace.shutdown()
      let disk = try await store.load().get()
      guard disk.1.first(where: { $0.id == fixture.document.id }) == fixture.document else {
        throw BoomError.invalid("Encrypted manuscript differs after model transitions.")
      }
      testWindow.close(); window = nil
      let measured = try probe.finish()
      receipt["memory_samples"] = measured.1; receipt["peak_process_footprint_bytes"] = measured.0
      guard measured.0 <= (try ModelResidency.budget()) else {
        throw BoomError.budget("Residency transitions exceeded the application budget.")
      }
      receipt["status"] = "passed"; try persist()
    } catch {
      model?.cancel(); if let model { try await model.shutdown() }; window?.close()
      let measured = try probe.finish()
      receipt["memory_samples"] = measured.1; receipt["peak_process_footprint_bytes"] = measured.0
      receipt["status"] = "failed"; receipt["error"] = String(describing: error)
      try persist(); throw error
    }
  }
}
