import BoomCore
import Foundation

/// Explicit developer evaluation. Inputs and every attempt are exported only to
/// the requested fresh directory; normal workspace operation never uses it.
enum WritingEvaluation {
  struct Fixture: Codable {
    let document: DocumentSnapshot
    let caretUTF16: Int
    let examples: [DocumentSnapshot]
  }
  struct Suite: Codable {
    let fixtures: [Fixture]
    let seeds: [UInt64]
  }
  private struct Trial: Encodable {
    let fixture: Int
    let seed: UInt64
    let replayOf: String?
    var state = "pending"
    var recipe: CompletionRecipe?
    var failure: String?
    var text = ""
    var tokenIDs: [Int] = []
    var promptDigest: String?
    var promptTokens: Int?
    var stopReason: String?
    var stopTokenID: Int?
    var firstTokenSeconds: Double?
    var elapsedSeconds: Double?
  }
  static func run(fixtureURL: URL, directory: URL, evidence: URL) async throws {
    let input = try ModelInstaller.hashFile(fixtureURL, maxBytes: 4_194_304)
    let bytes = try Data(contentsOf: fixtureURL)
    guard Digest.sha256(bytes) == input.sha256 else { throw BoomError.stale("Evaluation input changed during reading.") }
    let suite = try JSONDecoder().decode(Suite.self, from: bytes)
    guard !suite.fixtures.isEmpty, suite.fixtures.count <= 16,
      !suite.seeds.isEmpty, suite.seeds.count <= 16,
      Set(suite.seeds).count == suite.seeds.count
    else { throw BoomError.invalid("Use one to sixteen fixtures and distinct seeds.") }
    try bytes.write(to: evidence.appendingPathComponent("fixtures.json"), options: .atomic)
    var receipt: [String: Any] = ["schema": 1, "status": "running", "fixture_sha256": input.sha256,
      "runtime_revision": ModelPacks.runtimeRevision, "quality_review": "pending",
      "hardware_bytes": ProcessInfo.processInfo.physicalMemory,
      "source_inventory_sha256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable"]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("evaluation.json"), options: .atomic)
    }
    func persist(_ trial: Trial, name: String) throws {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(trial).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
    }
    try persist()
    do {
      // Use the same pinned, hash-checked cache admission as the product. A
      // reference run loads official weights directly; it never converts them.
      let admission = try ModelPacks.admission(directory, purpose: .writing)
      try ModelResidency.admit(weightBytes: admission.weightBytes)
      let manifest: Data
      if admission.converted {
        manifest = try Data(contentsOf: directory.appendingPathComponent(ModelPacks.manifestName))
      } else {
        let source = try ModelPacks.entry(.writing).manifest
        // The catalog also describes the converted pack. Export only the
        // admitted official files here, never its 4-bit output metadata.
        manifest = try JSONSerialization.data(withJSONObject: ["schema": 1,
          "purpose": "writing", "identity": admission.identity,
          "upstreamRepository": source.upstreamRepository, "upstreamRevision": source.upstreamRevision,
          "runtimeRevision": source.runtimeRevision, "weightKind": "official_checkpoint",
          "quantization": NSNull(), "files": ProductCore.object(source.upstreamFiles)],
          options: [.prettyPrinted, .sortedKeys])
      }
      try manifest.write(to: evidence.appendingPathComponent("model-manifest.json"), options: .atomic)
      receipt["weight_kind"] = admission.converted ? "converted_pack" : "official_checkpoint"
      receipt["weight_bytes"] = admission.weightBytes
      receipt["admitted_identity"] = admission.identity
      try persist()
      let runner = try await MLXGemmaRunner.load(directory: directory, identity: admission.identity)
      receipt["model"] = runner.identity
      var attempts: [String] = [], failures = 0, empty = 0, replayMatches: [Bool] = []
      for (index, fixture) in suite.fixtures.enumerated() {
        let sources = fixture.examples.map {
          SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "writing-example")
        }
        for profile in SamplingProfile.allCases {
          var first: (String, Trial)?
          // Replay the first seed after the other seeds, without reloading the
          // model. This checks state isolation as well as repeatability.
          for position in 0...suite.seeds.count {
            let replay = position == suite.seeds.count
            let seed = suite.seeds[replay ? 0 : position]
            let name = "fixture-\(index)-\(profile.rawValue)-\(seed)" + (replay ? "-replay" : "")
            var trial = Trial(fixture: index, seed: seed, replayOf: replay ? first?.0 : nil)
            try persist(trial, name: name)
            attempts.append(name)
            do {
              let recipe = try await runner.completionRecipe(document: fixture.document,
                caret: fixture.caretUTF16, sources: sources, examples: fixture.examples.map(\.text),
                profile: profile, maxTokens: 256, flag: CancellationFlag())
              trial.recipe = recipe
              try persist(trial, name: name)
              let output = try await runner.run(rawPrompt: recipe.prompt, maxTokens: recipe.maxTokens,
                settings: recipe.settings, seed: seed, flag: CancellationFlag(), onText: { _ in })
              trial.text = output.text; trial.tokenIDs = output.tokenIDs
              trial.promptDigest = output.promptDigest; trial.promptTokens = output.promptTokens
              trial.stopReason = output.stopReason; trial.stopTokenID = output.stopTokenID
              trial.firstTokenSeconds = output.firstTokenSeconds; trial.elapsedSeconds = output.elapsedSeconds
              trial.state = output.text.isEmpty ? "ended_without_prose" : "generated"
              if output.text.isEmpty { empty += 1 }
              if position == 0 { first = (name, trial) }
              if replay {
                replayMatches.append(first?.1.recipe?.prompt == recipe.prompt
                  && first?.1.promptDigest == output.promptDigest
                  && first?.1.tokenIDs == output.tokenIDs && first?.1.text == output.text)
              }
            } catch {
              trial.state = "failed"; trial.failure = error.localizedDescription; failures += 1
            }
            try persist(trial, name: name)
            receipt["attempts"] = attempts; receipt["failures"] = failures
            receipt["ended_without_prose"] = empty; receipt["replay_matches"] = replayMatches
            try persist()
            print("Retained \(name): \(trial.state), \(trial.tokenIDs.count) tokens")
          }
        }
      }
      await runner.join()
      receipt["status"] = "execution_complete"
      try persist()
      print("Writing evaluation retained: \(evidence.path). Quality review remains separate.")
    } catch {
      receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
      try persist(); throw error
    }
  }
}
