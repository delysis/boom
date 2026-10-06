import BoomCore
import CryptoKit
import Foundation

/// Explicit real-weight diagnostic; every attempt retains its own receipt.
enum MLXNativeSmoke {
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count
      else { throw BoomError.invalid("Use --mlx-smoke --pack ABSOLUTE_DIRECTORY --evidence NEW_DIRECTORY [--base] [--seed INTEGER] [--writing-fixtures ABSOLUTE_JSON] [--preempt].") }
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
    if arguments.contains("--memory-budget") {
      let cache: UInt64?
      if arguments.contains("--benchmark-cache-mib") {
        guard let mib = UInt64(try argument("--benchmark-cache-mib")), mib <= UInt64.max / 1_048_576 else {
          throw BoomError.invalid("Invalid allocator-cache probe.")
        }
        cache = mib * 1_048_576
      } else { cache = nil }
      try await ApplicationMemorySmoke.run(writingPack: directory, evidence: evidence, cacheProbe: cache)
      return
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
      try await BatchGenerationSmoke.run(directory: directory, evidence: evidence)
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
      let runner = try await MLXGemmaRunner.load(directory: directory)
      let output: MLXGemmaRunner.Output
      var editDocument: DocumentSnapshot?
      if arguments.contains("--edit-smoke") {
        let document = DocumentSnapshot(id: UUID(uuidString: "77D4A505-273A-487B-85AF-07EF1E524131")!,
          title: "Public edit fixture", text: "The harbor was quiet.")
        let graph = try ContextGraph.resolveChat(request: "", attachedDocumentID: document.id,
          editingDocumentID: document.id, all: [document])
        let authority = CapturedDocumentAuthority(mode: .edit, target: document)
        let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: graph.text,
          request: "In the document, replace quiet with bright. Keep every other character unchanged. Return the actual edit patch.",
          routing: [], authority: authority)
        receipt["plan"] = try ProductCore.object(plan)
        receipt["authority"] = try ProductCore.object(authority)
        try persist()
        output = try await runner.run(plan: plan, images: [], maxTokens: 1024,
          seed: seed, flag: CancellationFlag(), onText: { _ in })
        editDocument = document
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
      try persist() // Retain raw output even if tool decoding or the real commit fails.
      guard !output.text.isEmpty else { throw BoomError.invalid("The real model returned no text.") }
      await runner.join()
      if let document = editDocument {
        receipt["document_edit"] = try await checkDocumentEdit(output.text, document: document, evidence: evidence)
      }
      receipt["status"] = "passed"
      try persist()
      print("Real-weight diagnostic passed: \(evidence.path)")
    } catch {
      receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
      try persist(); throw error
    }
  }
  @MainActor private static func checkDocumentEdit(_ text: String, document: DocumentSnapshot, evidence: URL) async throws -> Any {
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
    let pending = ChatMessage(role: .assistant, text: "", state: .pending)
    guard let chatIndex = model.state.chats.firstIndex(where: { $0.id == chat.id }) else {
      throw BoomError.stale("Diagnostic chat is missing.")
    }
    model.state.chats[chatIndex].messages.append(pending)
    try await model.flush()
    _ = try await model.finishConsultationResponse(text, pending: pending, chatID: chat.id,
      authority: CapturedDocumentAuthority(mode: .edit, target: document), documentSources: [], attachments: [])
    let expected = "The harbor was bright."
    guard model.selectedDocument?.text == expected, model.state.proposals.last?.status == "applied" else {
      throw BoomError.invalid("Real model did not produce and commit the requested exact edit.")
    }
    try await model.flush()
    let persisted = try await store.load().get().1.first(where: { $0.id == document.id })
    guard persisted?.text == expected else { throw BoomError.invalid("Edited bytes did not persist.") }
    model.undoManager(document.id).undo()
    guard model.selectedDocument?.text == document.text else { throw BoomError.invalid("Native Undo did not restore the original bytes.") }
    try await model.shutdown()
    return ["expected_text": expected, "persisted_text": persisted?.text ?? "", "undone_text": document.text,
      "validated_and_committed": true, "native_undo_restored_original": true,
      "keychain_acceptance": false, "interactive_ui_acceptance": false] as [String: Any]
  }
}
