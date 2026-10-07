import AppKit
import BoomCore
import CryptoKit
import Darwin
import Foundation
import Metal
import MLX
import SwiftUI
import Synchronization

/// Explicit public fixtures, actual paired MLX allocations and production
/// encrypted checkpoints. No shown window, user workspace, Keychain or network.
@MainActor enum ApplicationMemorySmoke {
  private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.delysis.Bloom.memory-sampler", qos: .utility)
    private let source: DispatchSourceTimer
    private let handle: FileHandle
    private let started = ContinuousClock().now
    private let suspendingStarted = SuspendingClock().now
    private var phase = "startup"
    private var failure: String?
    private var peak: UInt64 = 0
    private var samples = 0
    private var finished = false
    init(_ url: URL) throws {
      source = DispatchSource.makeTimerSource(queue: queue)
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw BoomError.unavailable("Memory sample ledger could not be created.")
      }
      handle = try FileHandle(forWritingTo: url)
      source.schedule(deadline: .now(), repeating: .milliseconds(20))
      source.setEventHandler { [weak self] in self?.sample() }
      source.resume()
    }
    func mark(_ value: String) {
      lock.lock(); phase = value; lock.unlock()
      queue.async { [weak self] in self?.sample() }
    }
    func currentPhase() -> String { lock.lock(); defer { lock.unlock() }; return phase }
    func elapsedSeconds() -> Double { started.duration(to: ContinuousClock().now).timeInterval }
    private func sample() {
      guard !finished else { return }
      let sampledPhase = currentPhase(), seconds = elapsedSeconds()
      let suspendingSeconds = suspendingStarted.duration(to: SuspendingClock().now).timeInterval
      let accounting = ModelResidency.memoryAccounting(), footprint = accounting.current
      peak = max(peak, footprint, accounting.peak); samples += 1
      do {
        var bytes = try JSONSerialization.data(withJSONObject: [
          "seconds": seconds, "suspending_seconds": suspendingSeconds,
          "phase": sampledPhase, "process_footprint_bytes": footprint,
          "kernel_process_peak_footprint_bytes": accounting.peak,
          "mlx_active_bytes": Memory.activeMemory, "mlx_cache_bytes": Memory.cacheMemory,
          "mlx_peak_active_bytes": Memory.peakMemory], options: [.sortedKeys])
        bytes.append(0x0a); try handle.write(contentsOf: bytes)
      } catch { failure = error.localizedDescription }
    }
    func finish() throws -> (UInt64, Int) {
      source.cancel()
      return try queue.sync {
        sample(); finished = true
        try handle.synchronize()
        if let failure { throw BoomError.unavailable(failure) }
        return (peak, samples)
      }
    }
    deinit { source.cancel(); try? handle.close() }
  }
  private actor TrialTrace {
    private var cancelledAt: ContinuousClock.Instant?
    private(set) var metrics: MLXGemmaRunner.BatchMetrics?
    func cancel(_ flag: CancellationFlag) {
      if cancelledAt == nil { cancelledAt = ContinuousClock().now; flag.cancel() }
    }
    func measured(_ value: MLXGemmaRunner.BatchMetrics) { metrics = value }
    func cancellationSeconds() -> Double? {
      cancelledAt.map { $0.duration(to: ContinuousClock().now).timeInterval }
    }
  }
  /// Callbacks mark submitted chunks, not completed GPU execution. Capturing
  /// the calling thread here preserves its QoS instead of an actor-hop value.
  private final class PrefillTrace: Sendable {
    struct Observation: Codable, Sendable {
      let operationID: UUID
      let processedPositions: Int
      let totalPositions: Int
      let requestElapsedSeconds: Double
      let threadQoS: UInt32
    }
    private let started = ContinuousClock().now
    private let observations = Mutex<[Observation]>([])
    func record(_ progress: MLXGemmaRunner.PrefillProgress) {
      let value = Observation(operationID: progress.operationID,
        processedPositions: progress.processedPositions, totalPositions: progress.totalPositions,
        requestElapsedSeconds: started.duration(to: ContinuousClock().now).timeInterval,
        threadQoS: qos_class_self().rawValue)
      observations.withLock { $0.append(value) }
    }
    func captured() -> [Observation] { observations.withLock { $0 } }
  }
  private static func write(_ value: [String: Any], _ name: String, evidence: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent(name), options: .atomic)
  }
  private static func swap() -> [String: Any] {
    var value = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    let status = sysctlbyname("vm.swapusage", &value, &size, nil, 0)
    return ["available": status == 0, "used_bytes": value.xsu_used,
      "total_bytes": value.xsu_total, "scope": "host-wide; other applications can contribute"]
  }
  private static func overlapProbe(_ admission: ModelPacks.Admission, prefillTokens: UInt32?) async throws -> [String: Any] {
    guard let device = MTLCreateSystemDefaultDevice() else { throw BoomError.unavailable("Metal is unavailable.") }
    let usedBefore = max(ModelResidency.footprint(), UInt64(max(0, Memory.activeMemory + Memory.cacheMemory)))
    let preview = try ProductCore.admitModelLoad(physical: ProcessInfo.processInfo.physicalMemory,
      metal: device.recommendedMaxWorkingSetSize, resident: usedBefore, weights: admission.weightBytes)
    let coordinator = GenerationCoordinator.shared
    await coordinator.enter()
    let queued = Task { try await MLXGemmaRunner.load(admission: admission, prefillTokens: prefillTokens) }
    var released = false
    do {
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      while await coordinator.queuedOperations != 1 {
        try Task.checkCancellation()
        guard ContinuousClock().now < deadline else { throw BoomError.unavailable("The overlap load did not queue.") }
        await Task.yield()
      }
      // Public process memory changes after the load queues. Allocate off the
      // UI thread and keep it alive until the waiting loader has finished.
      let reservation = try await detachedWork { Data(repeating: 0xa5, count: 1_073_741_824) }
      let before = ModelResidency.memoryAccounting()
      let usedWhileQueued = max(before.current, UInt64(max(0, Memory.activeMemory + Memory.cacheMemory)))
      await coordinator.leave(); released = true
      let outcome = await queued.result
      let after = withExtendedLifetime(reservation) { ModelResidency.memoryAccounting() }
      switch outcome {
      case .success: throw BoomError.invalid("The queued model ignored the changed resident allocations.")
      case .failure(let error):
        guard let failure = error as? BoomError, case .budget(let message) = failure,
          message == "This model does not fit alongside the resident model. Close the inactive model before loading it." else {
          throw BoomError.invalid("The queued model failed after admission rather than before weight loading: " + String(describing: error))
        }
      }
      let growth = after.peak > before.peak ? after.peak - before.peak : 0
      guard growth <= 67_108_864 else { throw BoomError.invalid("The rejected load exceeded its 64 MiB metadata allowance.") }
      return ["preview_admitted_before_queue": preview, "rejected_before_weight_loading": true,
        "attempted_model": admission.identity, "attempted_weight_bytes": admission.weightBytes,
        "fixture_resident_bytes": reservation.count, "resident_accounted_before_queue_bytes": usedBefore,
        "resident_accounted_while_queued_bytes": usedWhileQueued,
        "before_current_bytes": before.current, "before_peak_bytes": before.peak,
        "after_current_bytes": after.current, "after_peak_bytes": after.peak,
        "kernel_peak_growth_bytes": growth]
    } catch {
      queued.cancel()
      if !released { await coordinator.leave() }
      _ = await queued.result
      throw error
    }
  }
  static func run(writingPack: URL, evidence: URL, consultationPackOverride: URL? = nil, cacheProbe: UInt64? = nil,
    prefillTokens: UInt32? = nil) async throws {
    let limits = try ModelResidency.limits()
    let metal = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0
    if let cacheProbe {
      try ProductCore.admitCacheProbe(physical: ProcessInfo.processInfo.physicalMemory,
        metal: metal, cache: cacheProbe)
    }
    var receipt: [String: Any] = ["schema": 1, "status": "running",
      "gate": "24 GiB application budget on the development Mac; full admitted context",
      "source_inventory_sha256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
      "metal_recommended_working_set_bytes": MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0,
      "limits": try ProductCore.object(limits), "runtime_revision": ModelPacks.runtimeRevision,
      "actual_32gb_hardware_required": false, "os_physical_footprint_hard_limit": false,
      "network_permission": "outbound denied by the invoking OS sandbox",
      "keychain_dialogs_qualified": false, "physical_keyboard_or_ime_qualified": false,
      "swap_before": swap(), "sample_interval_ms": 20,
      "durable_encrypted_checkpoint_overhead_included": true,
      "producer_priority_scope": "explicit operations request user-initiated task priority; autocomplete requests background priority; receipts record effective task priority, not OS thread QoS",
      "inference_activity_scope": "GPU lease through producer joining; explicit operations request user-initiated activity while allowing idle system sleep; autocomplete requests background activity",
      "clock_scope": "ContinuousClock includes system sleep; SuspendingClock excludes system sleep; recorded wall-clock gates are unchanged"]
    receipt["requested_cache_probe_bytes"] = cacheProbe as Any? ?? NSNull()
    receipt["requested_prefill_token_ceiling"] = prefillTokens as Any? ?? NSNull()
    try write(receipt, "receipt.json", evidence: evidence)
    let probe = try Probe(evidence.appendingPathComponent("memory-samples.jsonl"))
    var typing: Task<[Double], Error>?
    var model: WorkspaceModel?
    var window: NSWindow?
    do {
      guard let consultationPack = consultationPackOverride ?? ModelPacks.cached(.consultation) else {
        throw BoomError.unavailable("Both cached model packs are required.")
      }
      let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"),
        testKey: SymmetricKey(data: Data(repeating: 0x6a, count: 32)))
      let clock = ContinuousClock()
      var writingAdmission: ModelPacks.Admission?
      func load(_ directory: URL, _ purpose: ModelPurpose) async throws -> MLXGemmaRunner {
        probe.mark("verify-" + purpose.rawValue)
        let admission = try await detachedWork { try ModelPacks.admission(directory, purpose: purpose) }
        if purpose == .writing { writingAdmission = admission }
        try ModelResidency.admit(weightBytes: admission.weightBytes)
        probe.mark("load-" + purpose.rawValue)
        let started = clock.now
        let runner = try await MLXGemmaRunner.load(admission: admission, prefillTokens: prefillTokens)
        receipt[purpose.rawValue + "_generation_policy"] = try ProductCore.object(runner.generationPolicy)
        receipt[purpose.rawValue + "_load_seconds"] = started.duration(to: clock.now).timeInterval
        receipt[purpose.rawValue + "_model"] = admission.identity
        receipt[purpose.rawValue + "_loaded_footprint_bytes"] = ModelResidency.footprint()
        try ModelPacks.evidenceManifest(admission, purpose: purpose)
          .write(to: evidence.appendingPathComponent(purpose.rawValue + "-manifest.json"))
        try write(receipt, "receipt.json", evidence: evidence)
        return runner
      }
      // A fresh process does not guarantee a cold OS filesystem cache.
      receipt["loading_scope"] = "fresh process; OS filesystem cache was not flushed"
      let consultation = try await load(consultationPack, .consultation)
      let writing = try await load(writingPack, .writing)
      probe.mark("reject-resident-overlap")
      guard let duplicate = writingAdmission else { throw BoomError.invalid("The writing admission was not captured.") }
      receipt["overlap_load_admission_probe"] = try await overlapProbe(duplicate, prefillTokens: prefillTokens)
      try write(receipt, "receipt.json", evidence: evidence)
      if let cacheProbe { Memory.cacheLimit = Int(clamping: cacheProbe); Memory.clearCache() }
      receipt["effective_allocator_cache_limit_bytes"] = Memory.cacheLimit
      probe.mark("pair-resident")
      let writingCapacity = try await writing.contextLength(batchWidth: 3)
      let consultationCapacity = await consultation.contextLength
      receipt["writing_three_row_context_capacity_after_pair_load"] = writingCapacity
      receipt["consultation_context_capacity_after_pair_load"] = consultationCapacity
      guard writingCapacity >= 4096 + 256, consultationCapacity >= 4096 + 256 else {
        throw BoomError.budget("The pair leaves insufficient context for the registered 4K trial.")
      }
      let short = try await writing.diagnosticPrefix(tokens: 512)
      let document = DocumentSnapshot(title: "Public memory and typing fixture", text:
        try await writing.diagnosticPrefix(tokens: 16_128))
      var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
      state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
      try await store.save(state, documents: [document])
      let workspace = try await WorkspaceModel(storeOverride: store, loadModels: false); model = workspace
      guard workspace.layout.isAuthor else { throw BoomError.unavailable("Use the author edition for this diagnostic.") }
      let host = NSHostingView(rootView: WorkspaceView(model: workspace))
      let testWindow = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      window = testWindow; testWindow.isReleasedWhenClosed = false; testWindow.contentView = host
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      guard let editor = workspace.editor, testWindow.makeFirstResponder(editor), editor.isEditable else {
        throw BoomError.invalid("The production offscreen editor did not accept keyboard focus.")
      }
      workspace.isBusy = true
      var typingObservations: [[String: Any]] = []
      typing = Task { @MainActor in
        var delays: [Double] = []
        while !Task.isCancelled {
          let expected = clock.now.advanced(by: .milliseconds(100))
          let expectedSuspending = SuspendingClock().now.advanced(by: .milliseconds(100))
          do { try await Task.sleep(until: expected, clock: clock) } catch { break }
          let started = clock.now
          let suspendingWake = SuspendingClock().now
          let phase = probe.currentPhase()
          editor.setSelectedRange(NSRange(location: 0, length: 0))
          editor.insertText("x", replacementRange: editor.selectedRange())
          let inserted = clock.now
          editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
          let deleted = clock.now
          host.layoutSubtreeIfNeeded()
          let ended = clock.now
          delays.append(max(0, expected.duration(to: ended).timeInterval))
          typingObservations.append(["phase": phase,
            "observation_seconds": probe.elapsedSeconds(),
            "scheduled_delay_seconds": max(0, expected.duration(to: started).timeInterval),
            "scheduled_delay_excluding_system_sleep_seconds": max(0, expectedSuspending.duration(to: suspendingWake).timeInterval),
            "insertion_seconds": started.duration(to: inserted).timeInterval,
            "deletion_seconds": inserted.duration(to: deleted).timeInterval,
            "layout_seconds": deleted.duration(to: ended).timeInterval,
            "combined_seconds": delays.last!])
          guard editor.string == document.text, editor.isEditable,
            testWindow.firstResponder === editor else { throw BoomError.invalid("Native typing changed fixture bytes or lost focus.") }
          if started.duration(to: clock.now) > .seconds(2) { throw BoomError.unavailable("Native typing stalled.") }
        }
        return delays
      }
      func consultationPlan(tokens: Int) async throws -> ConsultationPlan {
        var length = tokens - 64
        for _ in 0..<8 {
          let prefix = try await consultation.diagnosticPrefix(tokens: length)
          let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "",
            context: prefix, request: "Write a detailed continuation of the harbor scene. Introduce a person whose arrival changes what the keeper intends. Use at least three paragraphs.", routing: [])
          let actual = try await consultation.tokenCount(plan)
          if actual == tokens { return plan }
          length += tokens - actual
        }
        throw BoomError.invalid("Chat fixture did not reach its exact registered token count.")
      }
      func trial(_ name: String, runner: MLXGemmaRunner, prompt: String?, plan: ConsultationPlan?,
        seeds: [UInt64], maxTokens: Int, cancellation: Bool = false) async throws -> [String: Any] {
        probe.mark(name)
        let flag = CancellationFlag(), trace = TrialTrace(), prefillTrace = PrefillTrace()
        let batch = seeds.count > 1
        let identities = seeds.enumerated().map { lane, seed in
          GenerationIdentity(kind: plan == nil ? .writing : .consultation, operationID: flag.operationID,
            recordID: UUID(), attemptID: UUID(), model: runner.identity, seed: seed,
            requestDigest: Digest.sha256(prompt ?? plan!.rawPrompt), maxTokens: maxTokens,
            generationPolicy: runner.generationPolicy,
            batch: batch ? WritingBatchExecution(algorithm: "shared-prefill-fixed-batch-v1", seeds: seeds, lane: lane) : nil)
        }
        var record: [String: Any] = ["status": "pending", "model": runner.identity,
          "generation_policy": try ProductCore.object(runner.generationPolicy),
          "seeds": seeds, "max_tokens_per_row": maxTokens, "batch_width": seeds.count,
          "prompt": prompt as Any? ?? NSNull(), "plan": try plan.map { try ProductCore.object($0) } ?? NSNull()]
        try write(record, name + ".json", evidence: evidence)
        let started = clock.now
        do {
          let outputs: [MLXGemmaRunner.Output]
          if let prompt {
            outputs = try await runner.runBatch(rawPrompt: prompt, maxTokens: maxTokens,
              settings: ProductCore.sampling(.standard), seeds: seeds, flag: flag,
              onPrefill: { prefillTrace.record($0) },
              onCheckpoint: { lane, progress, stop, token in
                try await store.checkpoint(progress, identity: identities[lane], stopReason: stop, stopTokenID: token)
                if cancellation, lane == 0, progress.tokenIDs.count >= 8 { await trace.cancel(flag) }
              }, onMetrics: { await trace.measured($0) })
          } else {
            guard let plan, seeds.count == 1 else { throw BoomError.invalid("Missing diagnostic input.") }
            outputs = [try await runner.run(plan: plan, images: [], maxTokens: maxTokens,
              seed: seeds[0], flag: flag,
              onPrefill: { prefillTrace.record($0) },
              onCheckpoint: { progress, stop, token in
                try await store.checkpoint(progress, identity: identities[0], stopReason: stop, stopTokenID: token)
                if cancellation, progress.tokenIDs.count >= 8 { await trace.cancel(flag) }
              }, onText: { _ in })]
          }
          record["elapsed_including_checkpoint_seconds"] = started.duration(to: clock.now).timeInterval
          record["cancellation_join_seconds"] = await trace.cancellationSeconds() as Any? ?? NSNull()
          record["batch_metrics"] = try await trace.metrics.map { try ProductCore.object($0) } ?? NSNull()
          record["prefill_submissions"] = try ProductCore.object(prefillTrace.captured())
          record["prefill_observation_scope"] = "CPU chunk submission callbacks, request-relative wall clock and calling-thread QoS; no per-chunk GPU completion timing"
          record["outputs"] = try outputs.map { value -> [String: Any] in
            ["text": value.text, "token_ids": value.tokenIDs, "prompt_digest": value.promptDigest,
              "prompt_tokens": value.promptTokens, "output_tokens": value.outputTokens,
              "stop_reason": value.stopReason, "stop_token_id": value.stopTokenID as Any? ?? NSNull(),
              "first_token_seconds": value.firstTokenSeconds as Any? ?? NSNull(),
              "elapsed_seconds": value.elapsedSeconds,
              "execution_task_priority": value.executionPriority as Any? ?? NSNull(),
              "native_setup_metrics": try value.setupMetrics.map { try ProductCore.object($0) } ?? NSNull(),
              "sustained_decode_tokens_per_second": value.firstTokenSeconds.map {
                Double(max(0, value.outputTokens - 1)) / max(0.000001, value.elapsedSeconds - $0)
              } as Any? ?? NSNull()]
          }
          record["journal_ids"] = identities.map { $0.attemptID.uuidString }
          for (identity, output) in zip(identities, outputs) {
            guard let checkpoint = try await store.generationCheckpoint(identity: identity),
              checkpoint.progress.tokenIDs == output.tokenIDs, checkpoint.progress.text == output.text,
              checkpoint.stopReason == output.stopReason else { throw BoomError.invalid("Durable final journal differs from its output.") }
          }
          record["status"] = "complete"; try write(record, name + ".json", evidence: evidence)
          print("\(name): \(outputs.map(\.promptTokens)) input, \(outputs.map(\.outputTokens)) output tokens")
          return record
        } catch {
          record["prefill_submissions"] = try ProductCore.object(prefillTrace.captured())
          record["status"] = "failed"; record["error"] = String(describing: error)
          try write(record, name + ".json", evidence: evidence); throw error
        }
      }
      _ = try await trial("warmup-writing", runner: writing, prompt: short, plan: nil, seeds: [99], maxTokens: 16)
      _ = try await trial("warmup-consultation", runner: consultation, prompt: nil,
        plan: consultationPlan(tokens: 512), seeds: [99], maxTokens: 16)
      let warmWriting = try await trial("warm-writing-4k", runner: writing,
        prompt: writing.diagnosticPrefix(tokens: 4096), plan: nil, seeds: [42], maxTokens: 256)
      let warmConsultation = try await trial("warm-consultation-4k", runner: consultation,
        prompt: nil, plan: consultationPlan(tokens: 4096), seeds: [42], maxTokens: 256)
      // Recompute admission after warming both models and exercising the UI.
      let fullWritingCapacity = try await writing.contextLength(batchWidth: 3)
      let fullConsultationCapacity = await consultation.contextLength
      receipt["full_writing_admitted_context"] = fullWritingCapacity
      receipt["full_consultation_admitted_context"] = fullConsultationCapacity
      try write(receipt, "receipt.json", evidence: evidence)
      let fullContext = try ProductCore.qualificationContext(writing: fullWritingCapacity, consultation: fullConsultationCapacity)
      receipt["registered_full_context_workload"] = try ProductCore.object(fullContext)
      _ = try await trial("full-context-writing-three", runner: writing,
        prompt: writing.diagnosticPrefix(tokens: fullContext.inputTokens[0]), plan: nil,
        seeds: [42, 2026, 8675309], maxTokens: fullContext.outputTokens)
      _ = try await trial("full-context-consultation", runner: consultation,
        prompt: nil, plan: consultationPlan(tokens: fullContext.inputTokens[1]), seeds: [42], maxTokens: fullContext.outputTokens)
      let cancelled = try await trial("decode-cancellation-three", runner: writing,
        prompt: short, plan: nil, seeds: [17, 42, 314], maxTokens: 256, cancellation: true)
      _ = try await trial("after-cancellation", runner: writing, prompt: short, plan: nil, seeds: [17], maxTokens: 16)
      await writing.join(); await consultation.join()
      typing?.cancel()
      let typingDelays = try await typing!.value; typing = nil
      workspace.isBusy = false; try await workspace.shutdown()
      testWindow.close(); window = nil; model = nil
      let measured = try probe.finish()
      receipt["peak_sampled_process_footprint_bytes"] = measured.0; receipt["memory_samples"] = measured.1
      receipt["typing_samples_seconds"] = typingDelays
      receipt["typing_observations"] = typingObservations
      receipt["typing_scope"] = "offscreen production editor insertion, deletion, model update and layout plus main-actor scheduling; not physical keystrokes"
      receipt["maximum_typing_latency_seconds"] = typingDelays.max() ?? 0
      receipt["swap_after"] = swap()
      let warmRows = [warmWriting, warmConsultation].flatMap { $0["outputs"] as? [[String: Any]] ?? [] }
      receipt["application_budget_passed"] = measured.0 > 0 && measured.0 <= limits.applicationBytes
      receipt["warm_4k_first_response_passed"] = warmRows.count == 2 && warmRows.allSatisfy {
        ($0["first_token_seconds"] as? Double ?? .infinity) <= 8
      }
      receipt["sustained_decode_passed"] = warmRows.count == 2 && warmRows.allSatisfy {
        ($0["output_tokens"] as? Int ?? 0) >= 64
          && ($0["sustained_decode_tokens_per_second"] as? Double ?? 0) >= 10
      }
      receipt["sustained_decode_minimum_sample_tokens"] = 64
      receipt["decode_cancellation_passed"] = (cancelled["cancellation_join_seconds"] as? Double ?? .infinity) <= 2
      receipt["offscreen_typing_passed"] = !typingDelays.isEmpty && typingDelays.allSatisfy { $0 <= 0.1 }
      receipt["status"] = "execution_complete"
      try write(receipt, "receipt.json", evidence: evidence)
    } catch {
      typing?.cancel(); if let typing { _ = await typing.result }
      if let model { model.isBusy = false; try await model.shutdown() }; window?.close()
      let measured = try probe.finish()
      receipt["peak_sampled_process_footprint_bytes"] = measured.0; receipt["memory_samples"] = measured.1
      receipt["status"] = "failed"; receipt["error"] = String(describing: error); receipt["swap_after"] = swap()
      try write(receipt, "receipt.json", evidence: evidence); throw error
    }
  }
}
