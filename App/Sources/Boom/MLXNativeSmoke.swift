import Foundation
import BoomCore

/// Runs real first-party target and assistant weights. A receipt is written
/// before loading so failures are retained rather than silently retried.
enum MLXNativeSmoke {
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count
      else { throw BoomError.invalid("Use --mlx-smoke --size 12B --evidence ABSOLUTE_DIRECTORY.") }
      return arguments[index + 1]
    }
    guard let size = GemmaSize(rawValue: try argument("--size")) else {
      throw BoomError.invalid("Unknown Gemma size.")
    }
    let path = try argument("--evidence")
    let seed = try arguments.contains("--seed")
      ? UInt64(argument("--seed")) : UInt64(42)
    guard let seed else { throw BoomError.invalid("Invalid smoke seed.") }
    guard path.hasPrefix("/") else { throw BoomError.invalid("Evidence path must be absolute.") }
    let evidence = URL(fileURLWithPath: path).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: evidence.path) else {
      throw BoomError.denied("Evidence directory already exists.")
    }
    try FileManager.default.createDirectory(
      at: evidence, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var details: [String: Any] = [
      "schema": 1, "kind": "mlx-first-party-real-weight-smoke", "size": size.rawValue,
      "status": "running", "checks": [String](), "seed": seed,
    ]
    func record(_ status: String, error: String? = nil) throws {
      details["status"] = status
      details["error"] = error
      try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    func check(_ condition: Bool, _ name: String) throws {
      guard condition else { throw BoomError.invalid("MLX smoke failed: " + name) }
      var checks = details["checks"] as! [String]
      checks.append(name)
      details["checks"] = checks
      try record("running")
    }
    try record("running")
    do {
      let base = arguments.contains("--base-source") || arguments.contains("--base-converted")
      guard let source = base ? MLXModelStore.cachedBaseSource(for: size)
        : MLXModelStore.cachedSource(for: size) else {
        throw BoomError.unavailable("No complete first-party source is cached for \(size.rawValue).")
      }
      details["repository"] = source.repository
      details["revision"] = source.revision
      try record("running")
      let useSource = arguments.contains("--source-weights")
        || arguments.contains("--base-source")
      let directory: URL
      if useSource {
        directory = source.directory
        details["weight_format"] = "first-party-unquantized-source"
      } else {
        directory = try await MLXModelStore.prepare(source)
        try MLXModelStore.verify(directory, expected: source)
        try check(true, "converted_checkpoint_verified")
        details["weight_format"] = "q4_0-mlx"
      }
      let assistant = base ? nil : try await MLXModelStore.ensureAssistant(for: size)
      if let assistant { details["assistant_revision"] = assistant.lastPathComponent }
      try record("running")
      let runner = try await MLXGemmaRunner.load(
        directory: directory, assistantDirectory: assistant, size: size)
      let useDraft = !base && !arguments.contains("--autoregressive")
      details["draft_enabled"] = useDraft
      details["context_length"] = runner.contextLength
      try check(runner.contextLength > 2048, "context_exceeds_legacy_coreml_limit")
      if !base {
        let chat = try await runner.run(
          rawPrompt: MLXGemmaRunner.chatPrompt(history: [], request: "Reply with one word: ready."),
          maxTokens: 24, flag: CancellationFlag(), useDraft: useDraft, seed: seed,
          onText: { _ in })
        details["chat_text"] = chat.text
        details["chat_output_tokens"] = chat.outputTokens
        details["chat_proposed_draft_tokens"] = chat.proposedDraftTokens
        details["chat_accepted_draft_tokens"] = chat.acceptedDraftTokens
        try check(chat.outputTokens > 0 && chat.text.localizedCaseInsensitiveContains("ready")
            && !chat.text.contains("<|channel>") && !chat.text.contains("<channel|>"),
          "chat_generated_text")
        if useDraft {
          try check(chat.proposedDraftTokens > 0, "matching_mtp_assistant_proposed_tokens")
        }
        if arguments.contains("--image-file") {
          let image = try Data(contentsOf: URL(fileURLWithPath: try argument("--image-file")))
          let visual = try await runner.runChat(
            history: [], request: "Describe this image in one sentence.", images: [image],
            maxTokens: 128, flag: CancellationFlag(), onText: { _ in })
          details["image_text"] = visual.text
          details["image_prompt_tokens"] = visual.promptTokens
          try check(visual.text.filter(\.isLetter).count >= 12,
            "image_pixels_generated_response")
        }
        if arguments.contains("--edit-test") {
          let document = DocumentSnapshot(title: "Test", text:
            "The sky was blue. The sea was blue.")
          let instruction = "Make the second sentence more vivid."
          let plan = try ContextGraph.resolveChat(
            request: instruction, attachedDocumentID: nil,
            editingDocumentID: document.id, all: [document])
          let body = [DocumentTools.instructions, plan.text, instruction]
            .joined(separator: "\n\n")
          let output = try await runner.run(
            rawPrompt: MLXGemmaRunner.chatPrompt(history: [], request: body),
            maxTokens: 4_096, flag: CancellationFlag(), useDraft: useDraft,
            seed: seed, onText: { _ in })
          details["edit_text"] = output.text
          details["edit_output_tokens"] = output.outputTokens
          let envelope = try AssistantEnvelope.decode(output.text)
          guard let patch = envelope.edits.first else {
            throw BoomError.invalid("Real model returned no edit patch.")
          }
          let changed = try DocumentTools.apply(patch,
            grant: DocumentGrant(mode: .edit, snapshot: document), current: document)
          details["edited_document"] = changed.text
          try check(changed.text != document.text, "real_edit_applied")
        }
      }
      if base {
        let document = DocumentSnapshot(title: "Draft", text: "The harbor lighthouse was built from")
        let context = try ContextGraph.resolve(root: document, all: [document])
        let raw = try GemmaPrompt.completion(
          document: document, caretUTF16: document.text.utf16.count, context: context)
        try check(!raw.contains("<|turn>") && !raw.contains("<turn|>"),
          "document_prompt_has_no_chat_template")
        let completion = try await runner.complete(
          document: document, caret: document.text.utf16.count, context: context,
          flag: CancellationFlag(), useDraft: false, seed: seed, onText: { _ in })
        details["completion_text"] = completion.output.text
        details["completion_output_tokens"] = completion.output.outputTokens
        let story = try await runner.run(
          rawPrompt: "Once upon a time, in a small town by the sea, there lived",
          maxTokens: 32, flag: CancellationFlag(), useDraft: false, seed: seed,
          onText: { _ in })
        details["story_completion_text"] = story.text
        try check(story.text.filter(\.isLetter).count >= 20,
          "raw_story_continuation_generated")
        if completion.output.text.rangeOfCharacter(from: .letters) == nil {
          var probes: [String: String] = [:]
          for (name, prefix) in [
            ("plain", "The harbor lighthouse was built from"),
            ("story", "Once upon a time, in a small town by the sea, there lived"),
            ("markdown", "# The lighthouse\n\nThe harbor lighthouse was built from"),
          ] {
            let result = try await runner.run(rawPrompt: prefix, maxTokens: 32,
              flag: CancellationFlag(), useDraft: false, seed: seed, onText: { _ in })
            probes[name] = result.text
          }
          details["raw_probes"] = probes
          try record("running")
        }
        try check(completion.output.outputTokens > 0
            && completion.output.text.rangeOfCharacter(from: .letters) != nil,
          "raw_document_completion_generated")
      }
      await runner.join()
      try record("passed")
      print("MLX native smoke passed: \(evidence.path)/receipt.json")
    } catch {
      try? record("failed", error: error.localizedDescription)
      throw error
    }
  }
}
