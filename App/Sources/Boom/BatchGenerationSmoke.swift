import BoomCore
import Foundation
import MLX

/// Public prose only; no workspace, Keychain, UI, or network authority.
enum BatchGenerationSmoke {
  private actor Probe {
    var progress: [Int: GenerationProgress] = [:]
    var stops: [Int: String] = [:]
    var metrics: MLXGemmaRunner.BatchMetrics?
    var cancelledAt: ContinuousClock.Instant?
    var peakFootprint = ModelResidency.footprint()
    func checkpoint(_ lane: Int, _ value: GenerationProgress, _ stop: String?) {
      progress[lane] = value
      if let stop { stops[lane] = stop }
      peakFootprint = max(peakFootprint, ModelResidency.footprint())
    }
    func measured(_ value: MLXGemmaRunner.BatchMetrics) { metrics = value }
    func cancelling() { if cancelledAt == nil { cancelledAt = ContinuousClock().now } }
    func object() throws -> [String: Any] {
      ["last_progress": try ProductCore.object(progress), "stops": try ProductCore.object(stops),
        "batch_metrics": try metrics.map { try ProductCore.object($0) } ?? NSNull(),
        "sampled_peak_footprint_bytes": peakFootprint,
        "cancellation_join_seconds": cancelledAt.map { $0.duration(to: ContinuousClock().now).timeInterval } as Any? ?? NSNull()]
    }
  }
  static func run(directory: URL, evidence: URL, sharedInstructionModel: Bool = false) async throws {
    let prompt = "<bos>At dusk, Mara reached the harbor with the spool hidden under her coat. "
      + "The old man waited beside the warehouse.\n\n“You are early,” he said.\n\n"
      + "“I was told to come before the boats.”\n\nHe set the spool on the bench. "
      + "Beyond them, a single lantern moved across the water.\n\n“And what were you told to bring?”\n\nMara opened her hand."
    var receipt: [String: Any] = ["schema": 1, "status": "running", "prompt": prompt,
      "runtime_revision": ModelPacks.runtimeRevision, "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "host_performance_qualified_for_32gb": false, "durable_workspace_checkpoint_overhead_included": false]
    func write(_ value: [String: Any], _ name: String) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent(name), options: .atomic)
    }
    try write(receipt, "receipt.json")
    do {
      let admission = try sharedInstructionModel ? ModelPacks.admission(directory, purpose: .consultation) : ModelPacks.admission(directory, purpose: .writing)
      let manifest = try ModelPacks.evidenceManifest(admission, purpose: sharedInstructionModel ? .consultation : .writing)
      receipt["shared_instruction_model_raw_writing"] = sharedInstructionModel
      try manifest.write(to: evidence.appendingPathComponent("model-manifest.json"))
      receipt["model_manifest_sha256"] = Digest.sha256(manifest)
      receipt["model_identity"] = admission.identity
      receipt["weight_kind"] = admission.kind.rawValue
      try write(receipt, "receipt.json")
      try ModelResidency.admit(weightBytes: admission.weightBytes)
      let runner = try await MLXGemmaRunner.load(admission: admission)
      let settings = try ProductCore.sampling(.standard)
      receipt["settings"] = try ProductCore.object(settings)
      receipt["model_identity"] = runner.identity
      receipt["loaded_footprint_bytes"] = ModelResidency.footprint()
      try write(receipt, "receipt.json")
      _ = try await runner.run(rawPrompt: prompt, maxTokens: 16, settings: settings,
        seed: 99, flag: CancellationFlag(), onText: { _ in })
      func trial(_ name: String, seeds: [UInt64], serial: Bool = false, cancel: Bool = false) async throws -> [MLXGemmaRunner.Output] {
        let probe = Probe(), flag = CancellationFlag()
        var record: [String: Any] = ["name": name, "seeds": seeds, "serial": serial,
          "max_tokens_per_lane": 128, "status": "running"]
        try write(record, name + ".json")
        let clock = ContinuousClock(), start = clock.now
        do {
          let outputs: [MLXGemmaRunner.Output]
          if serial {
            var values: [MLXGemmaRunner.Output] = []
            for (lane, seed) in seeds.enumerated() {
              values.append(try await runner.run(rawPrompt: prompt, maxTokens: 128,
                settings: settings, seed: seed, flag: flag,
                onCheckpoint: { progress, stop, _ in await probe.checkpoint(lane, progress, stop) },
                onText: { _ in }))
            }
            outputs = values
          } else {
            outputs = try await runner.runBatch(rawPrompt: prompt, maxTokens: 128,
              settings: settings, seeds: seeds, flag: flag,
              onCheckpoint: { lane, progress, stop, _ in
                await probe.checkpoint(lane, progress, stop)
                if cancel, lane == 0, progress.tokenIDs.count >= 8 {
                  await probe.cancelling(); flag.cancel()
                }
              }, onMetrics: { await probe.measured($0) })
          }
          let elapsed = start.duration(to: clock.now).timeInterval
          record.merge(try await probe.object()) { _, new in new }
          record["elapsed_seconds"] = elapsed
          record["aggregate_tokens_per_second"] = Double(outputs.reduce(0) { $0 + $1.outputTokens }) / elapsed
          record["mlx_peak_memory_bytes"] = Memory.peakMemory
          record["outputs"] = outputs.map { output -> [String: Any] in
            ["text": output.text, "token_ids": output.tokenIDs, "prompt_digest": output.promptDigest,
              "prompt_tokens": output.promptTokens, "output_tokens": output.outputTokens,
              "stop_reason": output.stopReason, "stop_token_id": output.stopTokenID as Any? ?? NSNull(),
              "first_token_seconds": output.firstTokenSeconds as Any? ?? NSNull(), "elapsed_seconds": output.elapsedSeconds]
          }
          record["status"] = "passed"
          try write(record, name + ".json")
          print("\(name): \(outputs.map(\.outputTokens)) tokens in \(elapsed) seconds")
          return outputs
        } catch {
          record.merge(try await probe.object()) { _, new in new }
          record["status"] = "failed"; record["error"] = error.localizedDescription
          try write(record, name + ".json"); throw error
        }
      }
      let seeds: [UInt64] = [17, 42, 314]
      _ = try await trial("serial-three", seeds: seeds, serial: true)
      _ = try await trial("batch-two", seeds: Array(seeds.prefix(2)))
      let batch = try await trial("batch-three", seeds: seeds)
      _ = try await trial("batch-four", seeds: seeds + [2718])
      let replay = try await trial("batch-three-replay", seeds: seeds)
      guard zip(batch, replay).allSatisfy({ $0.tokenIDs == $1.tokenIDs && $0.text == $1.text && $0.stopReason == $1.stopReason }) else {
        throw BoomError.invalid("Fixed batch seed replay changed output; every output retained.")
      }
      let cancelled = try await trial("batch-three-cancelled", seeds: seeds, cancel: true)
      guard cancelled.count == batch.count, cancelled.contains(where: { $0.stopReason == "cancelled" }),
        zip(cancelled, batch).allSatisfy({ partial, full in
          if partial.stopReason == "cancelled" {
            return !partial.tokenIDs.isEmpty && full.tokenIDs.starts(with: partial.tokenIDs)
          }
          return partial.tokenIDs == full.tokenIDs && partial.text == full.text
            && partial.stopReason == full.stopReason && partial.stopTokenID == full.stopTokenID
        }) else {
        throw BoomError.invalid("Batch cancellation lost partial output or changed a completed row.")
      }
      // A subsequent lease must work after cancellation and producer joining.
      _ = try await runner.run(rawPrompt: prompt, maxTokens: 8, settings: settings,
        seed: 42, flag: CancellationFlag(), onText: { _ in })
      receipt["status"] = "passed"; receipt["fixed_batch_replay_exact"] = true
      receipt["cancelled_rows_retained_and_next_operation_passed"] = true
      receipt["final_footprint_bytes"] = ModelResidency.footprint()
      try write(receipt, "receipt.json")
    } catch {
      receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
      try write(receipt, "receipt.json"); throw error
    }
  }
}
