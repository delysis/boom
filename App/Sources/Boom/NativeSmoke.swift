import CoreMLLLM
import CryptoKit
import Foundation
import BoomCore

/// Native real-weight acceptance executable. It is not a demo backend and cannot
/// create a passing receipt without loading and running the actual CoreML bundle.
enum NativeSmoke {
  static func run(arguments: [String]) async throws {
    func value(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1, let index = arguments.firstIndex(of: name),
        index + 1 < arguments.count
      else {
        throw BoomError.invalid(
          "Usage: Boom --smoke --model /absolute/verified/bundle --evidence /absolute/new/directory"
        )
      }
      let value = arguments[index + 1]
      guard value.hasPrefix("/") else { throw BoomError.invalid("Smoke paths must be absolute.") }
      return value
    }
    let modelURL = URL(fileURLWithPath: try value("--model"))
    let evidence = URL(fileURLWithPath: try value("--evidence"))
    guard !FileManager.default.fileExists(atPath: evidence.path) else {
      throw BoomError.denied("Evidence directory already exists; refusing to overwrite it.")
    }
    try FileManager.default.createDirectory(
      at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var passed: [String] = []
    var details: [String: Any] = [
      "schema": 1, "kind": "native-real-weight-smoke", "status": "running",
      "os": ProcessInfo.processInfo.operatingSystemVersionString, "keychain_tested": false,
      "ui_tested": false,
    ]
    func record(_ status: String, error: String? = nil) throws {
      details["status"] = status
      details["passed"] = passed
      details["error"] = error
      try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    func require(_ condition: Bool, _ test: String) throws {
      guard condition else { throw BoomError.invalid("Native acceptance failed: " + test) }
      passed.append(test)
      try record("running")
    }
    try record("running")
    do {
      let manifest = try ModelManifest.loadAndVerify(modelURL)
      details["model_manifest"] = manifest.identity
      var first: GemmaRunner? = try await GemmaRunner.load(
        directory: modelURL, manifestDigest: manifest.identity)
      guard let initial = first else { throw BoomError.unavailable("No loaded runtime.") }
      let messages = [
        ChatMessage(
          role: .user,
          text: "The harbor lighthouse is built from grey granite. Remember that detail."),
        ChatMessage(role: .assistant, text: "The harbor lighthouse is built from grey granite."),
      ]
      let prefix = try GemmaPrompt.prefix(messages)
      let prompt = GemmaPrompt.conversation(
        prefix: prefix, history: [],
        request: "What material is the harbor lighthouse built from? Answer briefly.")
      let cold = try await initial.run(
        prompt: prompt, maxTokens: 32, flag: CancellationFlag(), onText: { _ in })
      try require(!cold.tokenIDs.isEmpty, "real_weight_cold_generation_nonempty")
      let vault = try Vault(
        root: evidence.appendingPathComponent("sealed", isDirectory: true),
        testKey: SymmetricKey(size: .bits256))
      let persona = try await initial.makePersona(
        slug: "lighthouse", title: "Lighthouse", messages: messages, vault: vault,
        flag: CancellationFlag())
      try require(
        vault.exists(.personaCache, persona.cacheID), "actual_encrypted_kv_snapshot_written")
      let stored: StoredPersonaCache = try vault.decode(
        StoredPersonaCache.self, kind: .personaCache, id: persona.cacheID, limit: 1_100_000_000)
      let snapshot = try PropertyListDecoder().decode(BoomKVSnapshot.self, from: stored.payload)
      try require(
        snapshot.tensors.count == 8 && snapshot.tensors.allSatisfy { !$0.bytes.isEmpty },
        "eight_nonempty_native_kv_tensors")
      details["prefix_tokens"] = snapshot.position
      details["kv_bytes"] = snapshot.tensors.reduce(0) { $0 + $1.bytes.count }
      await initial.join()
      first = nil
      // A second independent loaded engine proves disk restore is not just
      // reuse of the first engine's live cache. Never used by the shipping UI.
      let second = try await GemmaRunner.load(
        directory: modelURL, manifestDigest: manifest.identity)
      let (restoredPrefix, restoredState) = try second.restorePersona(persona, vault: vault)
      try require(restoredPrefix == prefix, "disk_prefix_identity")
      let secondCold = try await second.run(
        prompt: prompt, maxTokens: 32, flag: CancellationFlag(), onText: { _ in })
      let warm = try await second.run(
        prompt: prompt, restore: restoredState, maxTokens: 32, flag: CancellationFlag(),
        onText: { _ in })
      try require(
        warm.cachedTokens == snapshot.position && warm.cachedTokens > 0,
        "native_kv_restore_was_used")
      details["cold_token_ids"] = cold.tokenIDs
      details["independent_cold_token_ids"] = secondCold.tokenIDs
      details["restored_token_ids"] = warm.tokenIDs
      details["cold_text"] = cold.text
      details["independent_cold_text"] = secondCold.text
      details["restored_text"] = warm.text
      let firstDifference = zip(cold.tokenIDs, warm.tokenIDs)
        .enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
      details["first_token_divergence"] = firstDifference.map { $0 as Any } ?? NSNull()
      try record("running")
      try require(cold.tokenIDs == warm.tokenIDs, "cold_equals_disk_restored_token_ids")
      let longContext = "BEGIN SOURCE " + String(repeating: "middle data ", count: 1_000)
        + " END SOURCE"
      let fitted = try await second.fitConversation(
        prefixes: [], history: [], instructions: "", context: longContext,
        request: "Continue briefly.", maxOutputTokens: 64, flag: CancellationFlag())
      let fittedPrompt = GemmaPrompt.conversation(
        history: fitted.history, request: fitted.context + "\n\nContinue briefly.")
      let fittedRun = try await second.run(
        prompt: fittedPrompt, maxTokens: 1, flag: CancellationFlag(), onText: { _ in })
      try require(
        fitted.omittedContextCharacters > 0 && fitted.context.contains("BEGIN SOURCE")
          && fitted.context.contains("END SOURCE") && !fittedRun.tokenIDs.isEmpty,
        "oversize_source_middle_excerpt_fits_real_model")
      details["omitted_context_characters"] = fitted.omittedContextCharacters
      let reference = DocumentSnapshot(
        title: "Voice", text: "Use plain, short sentences and concrete nouns.")
      let draft = DocumentSnapshot(title: "Draft", text: "[[Voice]]\nThe lighthouse is ")
      let context = try ContextGraph.resolve(root: draft, all: [draft, reference])
      let rawPrompt = try GemmaPrompt.completion(
        document: draft, caretUTF16: draft.text.utf16.count, context: context)
      try require(
        rawPrompt.hasPrefix("<bos>") && !rawPrompt.contains("<|turn>")
          && !rawPrompt.contains("<turn|>"), "document_completion_uses_raw_prefix")
      let followed = try await initial.complete(
        document: draft, caret: draft.text.utf16.count, context: context, vault: vault,
        flag: CancellationFlag(), onText: { _ in })
      try require(
        vault.exists(.followCache, Vault.followCacheID), "followed_document_native_kv_written")
      let followedColdDisk = try await second.complete(
        document: draft, caret: draft.text.utf16.count, context: context, vault: vault,
        flag: CancellationFlag(), onText: { _ in })
      try require(
        followedColdDisk.cachedTokens > 0, "followed_document_disk_kv_used_by_independent_runner")
      try require(
        followed.output.tokenIDs == followedColdDisk.output.tokenIDs,
        "followed_document_cold_disk_token_parity")
      details["followed_cached_tokens"] = followedColdDisk.cachedTokens
      details["followed_completion_text"] = followed.output.text
      let longReference = DocumentSnapshot(
        title: "Long", text: "BEGIN FOLLOWED "
          + String(repeating: "middle source data ", count: 1_000) + " END FOLLOWED")
      let longDraft = DocumentSnapshot(title: "Draft", text: "[[Long]]\nContinue this thought ")
      let longPlan = try ContextGraph.resolve(root: longDraft, all: [longDraft, longReference])
      let longCompletion = try await second.complete(
        document: longDraft, caret: longDraft.text.utf16.count, context: longPlan,
        vault: vault, flag: CancellationFlag(), onText: { _ in })
      let longCache: StoredFollowCache = try vault.decode(
        StoredFollowCache.self, kind: .followCache, id: Vault.followCacheID,
        limit: 1_100_000_000)
      try require(
        !longCompletion.output.tokenIDs.isEmpty
          && longCache.prefix.contains("BEGIN FOLLOWED")
          && longCache.prefix.contains("END FOLLOWED")
          && longCache.prefix.contains("source characters omitted from the middle"),
        "oversize_followed_document_middle_excerpt_fits_real_model")
      let unrelated = GemmaPrompt.conversation(
        history: [], request: "Name two kinds of trees. Answer briefly.")
      let unrelatedCold = try await second.run(
        prompt: unrelated, maxTokens: 32, flag: CancellationFlag(), onText: { _ in })
      let miss = try await second.run(
        prompt: unrelated, restore: restoredState, maxTokens: 32, flag: CancellationFlag(),
        onText: { _ in })
      try require(
        miss.cachedTokens == 0 && miss.tokenIDs == unrelatedCold.tokenIDs,
        "unrelated_prefix_never_receives_persona_kv")
      let back = try await second.run(
        prompt: prompt, restore: restoredState, maxTokens: 32, flag: CancellationFlag(),
        onText: { _ in })
      try require(back.tokenIDs == cold.tokenIDs, "a_b_a_session_isolation")
      let flag = CancellationFlag()
      do {
        _ = try await second.run(
          prompt: prompt, maxTokens: 256, flag: flag, onText: { _ in flag.cancel() })
        throw BoomError.invalid("Cancel did not interrupt generation.")
      } catch is CancellationError { passed.append("cancelled_decode_joined") }
      let afterCancel = try await second.run(
        prompt: prompt, restore: restoredState, maxTokens: 32, flag: CancellationFlag(),
        onText: { _ in })
      try require(afterCancel.tokenIDs == cold.tokenIDs, "cancel_then_restore_parity")
      do {
        _ = try await second.run(
          prompt: String(repeating: "Context overflow. ", count: 100_000), maxTokens: 512,
          flag: CancellationFlag(), onText: { _ in })
        throw BoomError.invalid("Context overflow was accepted.")
      } catch let e as BoomRuntimeError {
        passed.append("context_overflow_refused_before_decode")
        details["overflow_error"] = e.localizedDescription
      }
      let foreign = GemmaRunnerIdentityProbe.changedModel(second.identity)
      do {
        try stored.descriptor.validate(model: foreign, prefix: prefix, payload: stored.payload)
        throw BoomError.invalid("Foreign cache identity accepted.")
      } catch BoomError.stale { passed.append("foreign_model_cache_refused") }
      var corrupted = try Data(
        contentsOf: vault.root.appendingPathComponent(
          "personaCache-" + persona.cacheID.uuidString + ".sealed"))
      corrupted[corrupted.count - 1] ^= 1
      try corrupted.write(
        to: vault.root.appendingPathComponent(
          "personaCache-" + persona.cacheID.uuidString + ".sealed"), options: .atomic)
      var rejected = false
      do { _ = try second.restorePersona(persona, vault: vault) } catch { rejected = true }
      try require(rejected, "tampered_kv_ciphertext_refused_and_retained")
      let inspected = try AttachmentProcessor.inspect(
        name: "fixture.md", data: Data("# Native attachment\nA bounded fixture.".utf8))
      try require(!inspected.record.text.isEmpty, "real_rust_attachment_host_linked")
      let text = "A 😀 sentence."
      let document = DocumentSnapshot(title: "Unicode", text: text)
      let patch = DocumentPatch(
        documentID: document.id, revision: document.revision,
        replacements: [Replacement(old: "😀", new: "clear")])
      try require(
        try DocumentTools.apply(
          patch, grant: DocumentGrant(mode: .propose, snapshot: document), current: document
        ).text == "A clear sentence.", "unicode_document_transaction")
      await second.join()
      details["cold_token_ids"] = cold.tokenIDs
      details["restored_token_ids"] = warm.tokenIDs
      try record("passed")
      print("Native smoke passed: \(passed.count) checks. Receipt: \(evidence.path)/receipt.json")
    } catch {
      try? record("failed", error: error.localizedDescription)
      throw error
    }
  }
}
private enum GemmaRunnerIdentityProbe {
  static func changedModel(_ m: ModelIdentity) -> ModelIdentity {
    ModelIdentity(
      manifestDigest: m.manifestDigest + "-different", runtimeRevision: m.runtimeRevision,
      contextLength: m.contextLength)
  }
}
