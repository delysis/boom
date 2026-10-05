import BoomCore
import Foundation

/// Real MLX prefill interruption and foreground handoff, public fixtures only.
/// No window, workspace, Keychain, or target-machine qualification.
enum GenerationPreemptionSmoke {
  private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let started = ContinuousClock().now
    private var chunks: [[String: Any]] = []
    private var updates = 0
    func prefill(_ progress: MLXGemmaRunner.PrefillProgress) {
      lock.lock(); defer { lock.unlock() }
      chunks.append(["operation_id": progress.operationID.uuidString,
        "processed": progress.processedPositions, "total": progress.totalPositions,
        "seconds": started.duration(to: clock.now).timeInterval])
    }
    func text() { lock.lock(); updates += 1; lock.unlock() }
    func snapshot() -> (chunks: [[String: Any]], updates: Int) {
      lock.lock(); defer { lock.unlock() }; return (chunks, updates)
    }
  }
  static func run(writingPack: URL, evidence: URL) async throws {
    var receipt: [String: Any] = ["status": "running", "schema": 1,
      "scope": "public real-model prefill preemption; no window or workspace",
      "source_inventory_sha256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "runtime_revision": ModelPacks.runtimeRevision,
      "hardware_bytes": ProcessInfo.processInfo.physicalMemory,
      "target_32gb_qualified": false, "interactive_native_qualified": false]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    try persist()
    let backgroundFlag = CancellationFlag(), foregroundFlag = CancellationFlag()
    var backgroundTask: Task<MLXGemmaRunner.Output, Error>?
    var foregroundTask: Task<(Int, MLXGemmaRunner.Output), Error>?
    do {
      guard let consultationPack = ModelPacks.cached(.consultation) else {
        throw BoomError.unavailable("This diagnostic requires the cached consultation model as well.")
      }
      let writingAdmission = try ModelPacks.admission(writingPack, purpose: .writing)
      try ModelResidency.admit(weightBytes: writingAdmission.weightBytes)
      let writing = try await MLXGemmaRunner.load(directory: writingPack, identity: writingAdmission.identity)
      let consultationAdmission = try ModelPacks.admission(consultationPack, purpose: .consultation)
      try ModelResidency.admit(weightBytes: consultationAdmission.weightBytes)
      let consultation = try await MLXGemmaRunner.load(directory: consultationPack, identity: consultationAdmission.identity)
      receipt["writing_model"] = writing.identity; receipt["consultation_model"] = consultation.identity
      // Recompute after both loads. The diagnostic cannot bypass residency.
      let capacity = await writing.contextLength
      let prompt = "<bos>" + String(repeating: "The harbor was quiet. A light moved across the water, and the keeper watched from the window.\n", count: 512)
      let count = await writing.tokenCount(prompt)
      guard count >= 4096, count + 64 <= capacity else {
        throw BoomError.budget("The paired models leave insufficient context for this long-prefill diagnostic.")
      }
      try Data(prompt.utf8).write(to: evidence.appendingPathComponent("public-prefix.txt"), options: .atomic)
      receipt["prompt_sha256"] = Digest.sha256(Data(prompt.utf8)); receipt["prompt_tokens"] = count
      receipt["context_capacity_after_pair_loading"] = capacity
      try persist()
      let trace = Trace()
      let events = AsyncStream<MLXGemmaRunner.PrefillProgress>.makeStream()
      let background = Task {
        defer { events.continuation.finish() }
        return try await writing.run(rawPrompt: prompt, maxTokens: 64, seed: 42,
          flag: backgroundFlag, background: true, onPrefill: { progress in
            trace.prefill(progress); events.continuation.yield(progress)
          }, onText: { _ in trace.text() })
      }
      backgroundTask = background
      let watchdog = DispatchSource.makeTimerSource(queue: .global())
      watchdog.schedule(deadline: .now() + .seconds(120))
      watchdog.setEventHandler { backgroundFlag.cancel(); foregroundFlag.cancel() }
      watchdog.resume(); defer { watchdog.cancel() }
      var reachedChunk = false
      for await progress in events.stream {
        guard progress.operationID == backgroundFlag.operationID else {
          backgroundFlag.cancel(); _ = await background.result
          throw BoomError.stale("Prefill callback belongs to another operation.")
        }
        if progress.processedPositions > 0, progress.processedPositions < progress.totalPositions {
          reachedChunk = true; break
        }
      }
      guard reachedChunk else {
        backgroundFlag.cancel(); _ = await background.result
        throw BoomError.invalid("The background generation did not expose an intermediate prefill chunk.")
      }
      let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "",
        context: "", request: "Reply with one word: ready.", routing: [])
      receipt["foreground_plan"] = try ProductCore.object(plan)
      receipt["background_operation_id"] = backgroundFlag.operationID.uuidString
      try persist()
      let clock = ContinuousClock(), requested = clock.now
      let foreground: Task<(Int, MLXGemmaRunner.Output), Error> = Task {
        // Acquisition cancels the background owner. Do not cancel it from this
        // diagnostic: exercise the actual coordinator's foreground preemption.
        let tokens = try await consultation.preflight(plan, images: [], maxTokens: 64, flag: foregroundFlag)
        let output = try await consultation.run(plan: plan, images: [], maxTokens: 64, seed: 42,
          flag: foregroundFlag, onText: { _ in })
        return (tokens, output)
      }
      foregroundTask = foreground
      let backgroundResult = await background.result
      receipt["background_join_after_foreground_request_seconds"] = requested.duration(to: clock.now).timeInterval
      let snapshot = trace.snapshot()
      receipt["prefill_chunks"] = snapshot.chunks; receipt["background_text_updates"] = snapshot.updates
      receipt["background_flag_cancelled"] = backgroundFlag.isCancelled
      switch backgroundResult {
      case .failure(let error):
        receipt["background_error"] = String(describing: error)
        receipt["prefill_interrupted"] = error is CancellationError
      case .success(let output):
        receipt["background_output"] = output.text; receipt["background_token_ids"] = output.tokenIDs
        receipt["background_stop"] = output.stopReason; receipt["prefill_interrupted"] = false
      }
      try persist()
      let result: (Int, MLXGemmaRunner.Output)
      do { result = try await foreground.value }
      catch { receipt["foreground_error"] = String(describing: error); try persist(); throw error }
      receipt["foreground_operation_id"] = foregroundFlag.operationID.uuidString
      receipt["foreground_preflight_tokens"] = result.0
      receipt["foreground_text"] = result.1.text; receipt["foreground_token_ids"] = result.1.tokenIDs
      receipt["foreground_prompt_digest"] = result.1.promptDigest
      receipt["foreground_stop_reason"] = result.1.stopReason; receipt["foreground_stop_token_id"] = result.1.stopTokenID
      receipt["foreground_first_token_seconds"] = result.1.firstTokenSeconds
      try persist()
      guard receipt["prefill_interrupted"] as? Bool == true, backgroundFlag.isCancelled,
        snapshot.updates == 0, snapshot.chunks.allSatisfy({ ($0["processed"] as? Int ?? count) < count }),
        !result.1.text.isEmpty else {
        throw BoomError.invalid("The diagnostic did not prove interruption before the first token and successful foreground generation.")
      }
      // The same writing runner must remain usable and deterministic after
      // interruption; no stale KV from the cancelled request may leak into it.
      let short = "<bos>The harbor lighthouse was built from"
      let fresh = try await writing.run(rawPrompt: short, maxTokens: 32, seed: 2026,
        flag: CancellationFlag(), onText: { _ in })
      receipt["fresh_writing_text"] = fresh.text; receipt["fresh_writing_token_ids"] = fresh.tokenIDs
      receipt["fresh_writing_prompt_digest"] = fresh.promptDigest
      receipt["fresh_writing_stop_reason"] = fresh.stopReason; receipt["fresh_writing_stop_token_id"] = fresh.stopTokenID
      try persist()
      let replay = try await writing.run(rawPrompt: short, maxTokens: 32, seed: 2026,
        flag: CancellationFlag(), onText: { _ in })
      receipt["replayed_writing_text"] = replay.text; receipt["replayed_writing_token_ids"] = replay.tokenIDs
      receipt["fresh_seeded_replay_matches"] = fresh.text == replay.text && fresh.tokenIDs == replay.tokenIDs
        && fresh.promptDigest == replay.promptDigest
      guard !fresh.text.isEmpty, receipt["fresh_seeded_replay_matches"] as? Bool == true else {
        throw BoomError.invalid("Writing did not recover deterministically after prefill interruption.")
      }
      await writing.join(); await consultation.join()
      receipt["status"] = "passed"; try persist()
    } catch {
      backgroundFlag.cancel(); foregroundFlag.cancel()
      if let backgroundTask { _ = await backgroundTask.result }
      if let foregroundTask { _ = await foregroundTask.result }
      receipt["status"] = "failed"; receipt["error"] = String(describing: error)
      try persist(); throw error
    }
  }
}
