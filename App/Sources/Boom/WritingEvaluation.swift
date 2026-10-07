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
  private struct Trial: Encodable, Sendable {
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
    var batch: WritingBatchExecution?
    var batchGroup: String?
  }
  private actor BatchTrials {
    let group: WritingEvaluationGroup
    let evidence: URL
    var trials: [Trial]
    var metrics: MLXGemmaRunner.BatchMetrics?
    var failure: String?
    init(group: WritingEvaluationGroup, evidence: URL) throws {
      self.group = group; self.evidence = evidence
      trials = try group.seeds.enumerated().map { lane, seed in
        var trial = Trial(fixture: group.fixture, seed: seed,
          replayOf: group.replayOf == nil ? nil : String(group.names[lane].dropLast("-replay".count)))
        trial.batchGroup = group.id
        if group.seeds.count > 1 {
          let execution = WritingBatchExecution(seeds: group.seeds, lane: lane)
          try ProductCore.validateWritingBatch(execution, seed: seed)
          trial.batch = execution
        }
        return trial
      }
    }
    func persist() throws {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      for (name, trial) in zip(group.names, trials) {
        try encoder.encode(trial).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
      }
      var summary: [String: Any] = ["group": try ProductCore.object(group),
        "metrics": try metrics.map { try ProductCore.object($0) } ?? NSNull(),
        "row_states": trials.map(\.state)]
      if let failure { summary["failure"] = failure }
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent(group.id + "-metrics.json"), options: .atomic)
    }
    func prepared(_ recipe: CompletionRecipe) throws {
      for lane in trials.indices { trials[lane].recipe = recipe }
      try persist()
    }
    func checkpoint(_ lane: Int, progress: GenerationProgress, stop: String?, token: Int?) throws {
      guard trials.indices.contains(lane) else { throw BoomError.invalid("Evaluation callback row is outside its captured batch.") }
      trials[lane].text = progress.text; trials[lane].tokenIDs = progress.tokenIDs
      trials[lane].promptDigest = progress.promptDigest; trials[lane].promptTokens = progress.promptTokens
      trials[lane].firstTokenSeconds = progress.firstTokenSeconds; trials[lane].elapsedSeconds = progress.elapsedSeconds
      trials[lane].stopReason = stop; trials[lane].stopTokenID = token
      if let stop {
        trials[lane].state = stop == "cancelled" ? "cancelled" : progress.text.isEmpty ? "ended_without_prose" : "generated"
      }
      try persist()
    }
    func measured(_ value: MLXGemmaRunner.BatchMetrics) { metrics = value }
    func finished(_ outputs: [MLXGemmaRunner.Output]) throws {
      guard outputs.count == trials.count else { throw BoomError.invalid("Evaluation lost a captured batch row.") }
      for (lane, output) in outputs.enumerated() {
        trials[lane].text = output.text; trials[lane].tokenIDs = output.tokenIDs
        trials[lane].promptDigest = output.promptDigest; trials[lane].promptTokens = output.promptTokens
        trials[lane].stopReason = output.stopReason; trials[lane].stopTokenID = output.stopTokenID
        trials[lane].firstTokenSeconds = output.firstTokenSeconds; trials[lane].elapsedSeconds = output.elapsedSeconds
        trials[lane].state = output.stopReason == "cancelled" ? "cancelled" : output.text.isEmpty ? "ended_without_prose" : "generated"
      }
      try persist()
    }
    func failed(_ reason: String) throws {
      failure = reason
      for lane in trials.indices where trials[lane].state == "pending" {
        trials[lane].state = "failed"; trials[lane].failure = reason
      }
      try persist()
    }
    func retained() -> [Trial] { trials }
  }
  static func run(fixtureURL: URL, directory: URL, evidence: URL, batched: Bool = false) async throws {
    let input = try ModelInstaller.hashFile(fixtureURL, maxBytes: 4_194_304)
    let bytes = try Data(contentsOf: fixtureURL)
    guard Digest.sha256(bytes) == input.sha256 else { throw BoomError.stale("Evaluation input changed during reading.") }
    let suite = try JSONDecoder().decode(Suite.self, from: bytes)
    let plan = try ProductCore.writingEvaluationPlan(fixtures: suite.fixtures.count, seeds: suite.seeds)
    try bytes.write(to: evidence.appendingPathComponent("fixtures.json"), options: .atomic)
    var receipt: [String: Any] = ["schema": 1, "status": "running", "fixture_sha256": input.sha256,
      "runtime_revision": ModelPacks.runtimeRevision, "quality_review": "pending",
      "execution": batched ? "shared_prefill_batches" : "scalar",
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
      let manifest = try ModelPacks.evidenceManifest(admission, purpose: .writing)
      try manifest.write(to: evidence.appendingPathComponent("model-manifest.json"), options: .atomic)
      receipt["weight_kind"] = admission.kind.rawValue
      receipt["weight_bytes"] = admission.weightBytes
      receipt["admitted_identity"] = admission.identity
      try persist()
      let runner = try await MLXGemmaRunner.load(admission: admission)
      receipt["model"] = runner.identity
      if batched {
        receipt = try await runBatched(suite, plan: plan, runner: runner, evidence: evidence, receipt: receipt)
        await runner.join()
        receipt["status"] = "execution_complete"
        try persist()
        print("Batched writing evaluation retained: \(evidence.path). Quality review remains separate.")
        return
      }
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
  private static func runBatched(_ suite: Suite, plan: [WritingEvaluationGroup], runner: MLXGemmaRunner,
    evidence: URL, receipt initial: [String: Any]) async throws -> [String: Any] {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(plan).write(to: evidence.appendingPathComponent("execution-plan.json"), options: .atomic)
    var receipt = initial, originals: [String: [Trial]] = [:]
    var attempts: [String] = [], failures = 0, empty = 0, replayMatches: [Bool] = []
    for group in plan {
      let recorder = try BatchTrials(group: group, evidence: evidence), fixture = suite.fixtures[group.fixture]
      try await recorder.persist()
      attempts.append(contentsOf: group.names)
      do {
        let sources = fixture.examples.map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "writing-example") }
        let recipe = try await runner.completionRecipe(document: fixture.document, caret: fixture.caretUTF16,
          sources: sources, examples: fixture.examples.map(\.text), profile: group.profile,
          maxTokens: 256, flag: CancellationFlag())
        try await recorder.prepared(recipe)
        let outputs = try await runner.runBatch(rawPrompt: recipe.prompt, maxTokens: recipe.maxTokens,
          settings: recipe.settings, seeds: group.seeds, flag: CancellationFlag(),
          onCheckpoint: { lane, progress, stop, token in
            try await recorder.checkpoint(lane, progress: progress, stop: stop, token: token)
          }, onMetrics: { metrics in await recorder.measured(metrics) })
        try await recorder.finished(outputs)
      } catch { try await recorder.failed(error.localizedDescription) }
      let trials = await recorder.retained()
      failures += trials.filter { $0.state == "failed" || $0.state == "cancelled" }.count
      empty += trials.filter { $0.state == "ended_without_prose" }.count
      if let original = group.replayOf {
        let previous = originals[original]
        replayMatches.append(previous?.count == trials.count && zip(previous ?? [], trials).allSatisfy { first, replay in
          first.state == "generated" || first.state == "ended_without_prose"
            ? first.recipe?.prompt == replay.recipe?.prompt && first.recipe?.settings == replay.recipe?.settings
              && first.batch == replay.batch && first.promptDigest == replay.promptDigest
              && first.tokenIDs == replay.tokenIDs && first.text == replay.text
              && first.stopReason == replay.stopReason && first.stopTokenID == replay.stopTokenID
            : false
        })
      } else { originals[group.id] = trials }
      receipt["attempts"] = attempts; receipt["failures"] = failures
      receipt["ended_without_prose"] = empty; receipt["replay_matches"] = replayMatches
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("evaluation.json"), options: .atomic)
      print("Retained \(group.id): \(trials.map(\.state)), \(trials.map { $0.tokenIDs.count }) tokens")
    }
    return receipt
  }
}
