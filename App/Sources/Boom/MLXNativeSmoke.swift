import BoomCore
import AppKit
import CryptoKit
import Foundation
import Metal
import MLX
import SwiftUI

/// Explicit real-weight diagnostic; every attempt retains its own receipt.
enum MLXNativeSmoke {
  struct ConsultationFixture: Decodable {
    let model: String
    let plan: ConsultationPlan
    let generation_policy: ModelGenerationPolicy
    let seeds: [UInt64]
    let max_tokens_per_row: Int
    let outputs: [Expected]
    struct Expected: Decodable { let prompt_digest: String; let prompt_tokens: Int }
    static func decode(_ data: Data, model: String, seed: UInt64,
      promptTokens: Int, outputTokens: Int) throws -> Self {
      guard data.count <= 1_048_576 else { throw BoomError.invalid("Oversized consultation fixture.") }
      let fixture = try JSONDecoder().decode(Self.self, from: data)
      guard fixture.model == model, fixture.seeds == [seed], fixture.outputs.count == 1,
        fixture.max_tokens_per_row == outputTokens, fixture.outputs[0].prompt_tokens == promptTokens else {
        throw BoomError.invalid("Require the captured model, seed and complete consultation workload.")
      }
      return fixture
    }
  }
  static func validateConsultationArguments(_ arguments: [String]) throws {
    let captured = arguments.contains("--consultation-fixture")
    guard captured == arguments.contains("--consultation-warmup") else {
      throw BoomError.invalid("Supply both the captured consultation and its captured warmup.")
    }
    let otherModes = ["--base", "--edit-smoke", "--propose-smoke", "--unchanged-smoke",
      "--memory-budget", "--residency-fallback", "--preempt", "--writing-fixtures", "--batch"]
    guard !captured || !otherModes.contains(where: arguments.contains) else {
      throw BoomError.invalid("Choose only the captured consultation diagnostic.")
    }
  }
  static func run(arguments: [String]) async throws {
    try validateConsultationArguments(arguments)
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count
      else { throw BoomError.invalid("Use --mlx-smoke --pack ABSOLUTE_DIRECTORY --evidence NEW_DIRECTORY [--base] [--seed INTEGER] [--writing-fixtures ABSOLUTE_JSON] [--preempt] [--consultation-fixture ABSOLUTE_JSON --consultation-warmup ABSOLUTE_JSON].") }
      return arguments[index + 1]
    }
    let directory = URL(fileURLWithPath: try argument("--pack"))
    let evidence = URL(fileURLWithPath: try argument("--evidence"))
    let seed: UInt64
    if arguments.contains("--seed") {
      guard let value = UInt64(try argument("--seed")) else { throw BoomError.invalid("Invalid seed.") }
      seed = value
    } else { seed = 42 }
    guard directory.path.hasPrefix("/"), evidence.path.hasPrefix("/"),
      !FileManager.default.fileExists(atPath: evidence.path)
    else { throw BoomError.invalid("Use absolute paths and a fresh evidence directory.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    if arguments.contains("--residency-fallback") {
      let consultation = try argument("--consultation-pack"), fixture = try argument("--fixture")
      guard consultation.hasPrefix("/"), fixture.hasPrefix("/") else {
        throw BoomError.invalid("Use absolute consultation and fixture paths.")
      }
      try await ModelResidencySmoke.run(writingPack: directory,
        consultationPack: URL(fileURLWithPath: consultation),
        fixtureURL: URL(fileURLWithPath: fixture), evidence: evidence)
      return
    }
    if arguments.contains("--memory-budget") {
      let prefill: UInt32?
      if arguments.contains("--benchmark-prefill-tokens") {
        guard let value = UInt32(try argument("--benchmark-prefill-tokens")) else {
          throw BoomError.invalid("Invalid prefill-token probe.")
        }
        prefill = value
      } else { prefill = nil }
      let cache: UInt64?
      if arguments.contains("--benchmark-cache-mib") {
        guard let mib = UInt64(try argument("--benchmark-cache-mib")), mib <= UInt64.max / 1_048_576 else {
          throw BoomError.invalid("Invalid allocator-cache probe.")
        }
        cache = mib * 1_048_576
      } else { cache = nil }
      let consultationPack: URL?
      if arguments.contains("--consultation-pack") {
        let path = try argument("--consultation-pack")
        guard path.hasPrefix("/") else { throw BoomError.invalid("Use an absolute consultation model path.") }
        consultationPack = URL(fileURLWithPath: path)
      } else { consultationPack = nil }
      try await ApplicationMemorySmoke.run(writingPack: directory, evidence: evidence, consultationPackOverride: consultationPack, cacheProbe: cache,
        prefillTokens: prefill)
      return
    }
    guard !arguments.contains("--benchmark-prefill-tokens") else {
      throw BoomError.invalid("Prefill probes require the explicit memory-budget diagnostic.")
    }
    if arguments.contains("--preempt") {
      try await GenerationPreemptionSmoke.run(writingPack: directory, evidence: evidence, batch: arguments.contains("--batch"))
      return
    }
    if arguments.contains("--writing-fixtures") {
      let path = try argument("--writing-fixtures")
      guard path.hasPrefix("/") else { throw BoomError.invalid("Use an absolute evaluation fixture path.") }
      try await WritingEvaluation.run(fixtureURL: URL(fileURLWithPath: path), directory: directory,
        evidence: evidence, batched: arguments.contains("--batch"))
      return
    }
    if arguments.contains("--batch") {
      try await BatchGenerationSmoke.run(directory: directory, evidence: evidence,
        sharedInstructionModel: arguments.contains("--shared-model"))
      return
    }
    var receipt: [String: Any] = ["schema": 1, "status": "running", "seed": seed,
      "model_directory": directory.path, "runtime_revision": ModelPacks.runtimeRevision]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    try persist()
    do {
      let admission = try await detachedWork { try ModelPacks.admission(directory) }
      receipt["admitted_identity"] = admission.identity
      receipt["weight_bytes"] = admission.weightBytes
      receipt["weight_kind"] = admission.kind.rawValue
      try persist()
      let runner = try await MLXGemmaRunner.load(admission: admission)
      let output: MLXGemmaRunner.Output
      var editDocument: (DocumentSnapshot, InteractionMode, Bool)?
      let documentCases = ["--edit-smoke", "--propose-smoke", "--unchanged-smoke"].filter { arguments.contains($0) }
      guard documentCases.count <= 1 else { throw BoomError.invalid("Choose one document response diagnostic.") }
      if !documentCases.isEmpty {
        let document = DocumentSnapshot(id: UUID(uuidString: "77D4A505-273A-487B-85AF-07EF1E524131")!,
          title: "Public edit fixture", text: "The harbor was quiet.")
        let graph = try ContextGraph.resolveChat(request: "", attachedDocumentID: document.id,
          editingDocumentID: document.id, all: [document])
        let mode: InteractionMode = arguments.contains("--edit-smoke") ? .edit : .propose
        let expectsEdit = !arguments.contains("--unchanged-smoke")
        let authority = CapturedDocumentAuthority(mode: mode, target: document)
        let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "",
          context: DocumentTools.context(graph.documents, authority: authority),
          request: expectsEdit
            ? "In the document, replace quiet with bright. Keep every other character unchanged. Return the actual edit patch."
            : "Explain the sentence briefly. Do not change any document text. Reply normally without an edit patch.",
          routing: [], authority: authority)
        receipt["plan"] = try ProductCore.object(plan)
        receipt["authority"] = try ProductCore.object(authority)
        try persist()
        output = try await runner.run(plan: plan, images: [], maxTokens: 1024,
          seed: seed, flag: CancellationFlag(), onText: { _ in })
        editDocument = (document, mode, expectsEdit)
      } else if arguments.contains("--consultation-fixture") {
        func captured(_ name: String, seed: UInt64, promptTokens: Int, outputTokens: Int) throws -> (ConsultationFixture, String) {
          let path = try argument(name)
          guard path.hasPrefix("/") else { throw BoomError.invalid("Use an absolute consultation fixture path.") }
          let url = URL(fileURLWithPath: path)
          let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
          guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= 1_048_576 else { throw BoomError.invalid("Unsafe consultation fixture type or size.") }
          let data = try Data(contentsOf: url)
          let fixture = try ConsultationFixture.decode(data, model: runner.identity, seed: seed,
            promptTokens: promptTokens, outputTokens: outputTokens)
          try ProductCore.admitGenerationPolicy(fixture.generation_policy, loaded: runner.generationPolicy)
          return (fixture, Digest.sha256(data))
        }
        let (fixture, fixtureHash) = try captured("--consultation-fixture", seed: seed, promptTokens: 4096, outputTokens: 256)
        let (warmFixture, warmHash) = try captured("--consultation-warmup", seed: 99, promptTokens: 512, outputTokens: 16)
        receipt["fixture_sha256"] = fixtureHash
        receipt["warmup_fixture_sha256"] = warmHash
        receipt["plan"] = try ProductCore.object(fixture.plan)
        receipt["generation_policy"] = try ProductCore.object(runner.generationPolicy)
        let device = MTLCreateSystemDefaultDevice()
        receipt["backend"] = ["device_name": device?.name ?? "unavailable",
          "architecture": device?.architecture.name ?? "unavailable",
          "max_ops_override": ProcessInfo.processInfo.environment["MLX_MAX_OPS_PER_BUFFER"] ?? "unset",
          "max_mb_override": ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"] ?? "unset",
          "cache_limit_bytes": Memory.cacheLimit, "memory_limit_bytes": Memory.memoryLimit] as [String: Any]
        receipt["scope"] = "application runner, GPU lease, preflight, executor, production token stream and completed response; no UI or encrypted checkpoint workload"
        try persist()
        let warmup = try await runner.run(plan: warmFixture.plan, images: [], maxTokens: 16, seed: 99,
          flag: CancellationFlag(), onText: { _ in })
        receipt["warmup"] = ["prompt_tokens": warmup.promptTokens, "prompt_digest": warmup.promptDigest,
          "text": warmup.text, "token_ids": warmup.tokenIDs, "elapsed_seconds": warmup.elapsedSeconds] as [String: Any]
        try persist()
        guard warmup.promptDigest == warmFixture.outputs[0].prompt_digest,
          warmup.promptTokens == warmFixture.outputs[0].prompt_tokens else {
          throw BoomError.invalid("The application runner supplied a different captured warmup.")
        }
        output = try await runner.run(plan: fixture.plan, images: [], maxTokens: fixture.max_tokens_per_row,
          seed: seed, flag: CancellationFlag(), onText: { _ in })
        receipt["captured_prompt_matches"] = output.promptDigest == fixture.outputs[0].prompt_digest
          && output.promptTokens == fixture.outputs[0].prompt_tokens
      } else if arguments.contains("--base") {
        let text = "The harbor lighthouse was built from"
        output = try await runner.run(rawPrompt: "<bos>" + text, maxTokens: 64,
          seed: seed, flag: CancellationFlag(), onText: { _ in })
        receipt["authored_prefix"] = text
      } else {
        let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "",
          context: "", request: "Reply with one word: ready.", routing: [])
        output = try await runner.run(plan: plan, images: [], maxTokens: 64,
          seed: seed, flag: CancellationFlag(), onText: { _ in })
        receipt["plan"] = try ProductCore.object(plan)
      }
      receipt["text"] = output.text
      receipt["token_ids"] = output.tokenIDs
      receipt["prompt_digest"] = output.promptDigest
      receipt["prompt_tokens"] = output.promptTokens
      receipt["stop_reason"] = output.stopReason
      receipt["stop_token_id"] = output.stopTokenID
      receipt["first_token_seconds"] = output.firstTokenSeconds
      receipt["elapsed_seconds"] = output.elapsedSeconds
      receipt["native_setup_metrics"] = try output.setupMetrics.map { try ProductCore.object($0) } ?? NSNull()
      receipt["execution_task_priority"] = output.executionPriority
      try persist() // Retain raw output even if tool decoding or the real commit fails.
      if arguments.contains("--consultation-fixture"), receipt["captured_prompt_matches"] as? Bool != true {
        throw BoomError.invalid("The application runner supplied a different captured prompt.")
      }
      guard !output.text.isEmpty else { throw BoomError.invalid("The real model returned no text.") }
      await runner.join()
      if let (document, mode, expectsEdit) = editDocument {
        receipt["document_edit"] = try await checkDocumentEdit(output.text, document: document,
          mode: mode, expectsEdit: expectsEdit, evidence: evidence)
      }
      receipt["status"] = "passed"
      try persist()
      print("Real-weight diagnostic passed: \(evidence.path)")
    } catch {
      receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
      try persist(); throw error
    }
  }
  @MainActor private static func checkDocumentEdit(_ text: String, document: DocumentSnapshot,
    mode: InteractionMode, expectsEdit: Bool, evidence: URL) async throws -> Any {
    // This explicit public diagnostic exercises encrypted admission and Undo,
    // using an ephemeral key. It does not qualify real Keychain authorization.
    let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"),
      testKey: SymmetricKey(size: .bits256))
    var state = WorkspaceState()
    let chat = ChatRecord(title: "Public edit diagnostic", attachedDocumentID: document.id)
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.chats = [chat]; state.selectedDocument = document.id; state.selectedChat = chat.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    var mountedWindow: NSWindow?
    if model.layout.isAuthor {
      model.state.showChat = false
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 900))
      window.isReleasedWhenClosed = false; window.contentView = host
      mountedWindow = window; host.layoutSubtreeIfNeeded()
      let deadline = ContinuousClock.now + .seconds(2)
      while model.editor == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      guard let editor = model.editor, editor.documentID == document.id, editor.string == document.text,
        !window.isVisible, window.makeFirstResponder(editor) else {
        throw BoomError.invalid("The public document diagnostic could not mount its actual native editor.")
      }
    }
    defer { mountedWindow?.close() }
    let pending = ChatMessage(role: .assistant, text: "", state: .pending)
    guard let chatIndex = model.state.chats.firstIndex(where: { $0.id == chat.id }) else {
      throw BoomError.stale("Diagnostic chat is missing.")
    }
    model.state.chats[chatIndex].messages.append(pending)
    try await model.flush()
    let sources = try ContextGraph.resolveChat(request: "", attachedDocumentID: document.id,
      editingDocumentID: document.id, all: [document]).sources
    let message = try await model.finishConsultationResponse(text, pending: pending, chatID: chat.id,
      authority: CapturedDocumentAuthority(mode: mode, target: document), documentSources: sources, attachments: [])
    if !expectsEdit {
      guard message.state == .complete, model.selectedDocument == document,
        model.editor.map({ $0.string == document.text }) ?? true,
        model.state.proposals.isEmpty, !model.undoManager(document.id).canUndo,
        model.status == "No document changes" else {
        throw BoomError.invalid("The no-change response changed document state or reported a proposal.")
      }
      try await model.flush()
      let persisted = try await store.load().get().1.first { $0.id == document.id }
      guard persisted == document else { throw BoomError.invalid("The no-change response altered persisted bytes.") }
      try await model.shutdown()
      return ["mode": mode.rawValue, "status": "No document changes", "expected_text": document.text,
        "persisted_text": persisted?.text ?? "", "no_changes": true, "no_proposal": true,
        "no_undo_action": true, "mounted_editor": mountedWindow != nil,
        "keychain_acceptance": false, "interactive_ui_acceptance": false] as [String: Any]
    }
    if mode == .propose {
      guard model.selectedDocument == document, let proposal = model.state.proposals.last,
        proposal.status == "pending", model.status == "Proposal ready for review",
        !model.undoManager(document.id).canUndo else {
        throw BoomError.invalid("The model proposal was missing or applied without acceptance.")
      }
      let preview = try await store.load().get().1.first { $0.id == document.id }
      guard preview == document else { throw BoomError.invalid("An unaccepted proposal changed persisted bytes.") }
      model.accept(proposal.id)
      let deadline = ContinuousClock.now + .seconds(3)
      while model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      guard !model.isBusy, model.errorMessage == nil else { throw BoomError.invalid("Proposal acceptance did not finish.") }
    }
    let expected = "The harbor was bright."
    guard model.selectedDocument?.text == expected, model.state.proposals.last?.status == "applied",
      model.editor.map({ $0.string == expected && $0.isEditable }) ?? true,
      model.status == "Document edited" else {
      throw BoomError.invalid("Real model did not produce and commit the requested exact edit.")
    }
    try await model.flush()
    let persisted = try await store.load().get().1.first(where: { $0.id == document.id })
    guard persisted?.text == expected else { throw BoomError.invalid("Edited bytes did not persist.") }
    model.undoManager(document.id).undo()
    guard model.selectedDocument?.text == document.text,
      model.editor.map({ $0.string == document.text }) ?? true else { throw BoomError.invalid("Native Undo did not restore the original bytes.") }
    try await model.flush()
    let undone = try await store.load().get().1.first { $0.id == document.id }
    guard undone == document else { throw BoomError.invalid("Native Undo did not restore persisted document bytes.") }
    try await model.shutdown()
    return ["mode": mode.rawValue, "status": "Document edited", "proposal_required_acceptance": mode == .propose,
      "expected_text": expected, "persisted_text": persisted?.text ?? "", "undone_text": document.text,
      "validated_and_committed": true, "native_undo_restored_original": true,
      "mounted_editor": mountedWindow != nil, "native_undo_persisted_original": true,
      "keychain_acceptance": false, "interactive_ui_acceptance": false] as [String: Any]
  }
}
