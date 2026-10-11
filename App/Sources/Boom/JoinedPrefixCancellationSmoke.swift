import BoomCore
import Foundation
import MLX

/// Explicit public four-operation constructor diagnostic. No tensor snapshots,
/// model-history replay, UI, workspace, Keychain or additional decode case.
enum JoinedPrefixCancellationSmoke {
  static let fixtureSHA256 = "73fadfb71de757289837582ed16349aef2c591219b978ad7d5928396e76aff9b"
  static let applicationBudget: UInt64 = 24 << 30
  static let retainedBudget: UInt64 = 1 << 30
  struct Fixture: Decodable, Sendable {
    struct Input: Codable, Sendable {
      let prompt: String
      let prepared_token_ids: [Int]
      let prompt_digest: String
    }
    let schema: Int
    let purpose: String
    let model: String
    let generation_policy: ModelGenerationPolicy
    let seed: UInt64
    let source: Input
    let successor: Input
    let exact_prepared_lcp: Int
    let successor_max_tokens: Int
    static func decode(_ data: Data) throws -> Fixture {
      guard data.count <= 1_048_576, Digest.sha256(data) == fixtureSHA256 else {
        throw BoomError.invalid("Require the independently reviewed public cancellation fixture.")
      }
      let result = try JSONDecoder().decode(Self.self, from: data)
      guard result.schema == 1, result.purpose == "joined_prefix_cancellation_public_v1",
        result.seed == 42, result.successor_max_tokens == 16,
        result.source.prepared_token_ids.count == 4096, result.successor.prepared_token_ids.count == 4104,
        result.generation_policy.prefill == PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512),
        result.exact_prepared_lcp == 512,
        commonPrefix(result.source.prepared_token_ids, result.successor.prepared_token_ids) == 512,
        Digest.sha256(try JSONEncoder().encode(result.source.prepared_token_ids)) == result.source.prompt_digest,
        Digest.sha256(try JSONEncoder().encode(result.successor.prepared_token_ids)) == result.successor.prompt_digest else {
        throw BoomError.invalid("The bounded public prepared input or policy changed.")
      }
      return result
    }
  }
  struct PrefillEvent: Codable, Sendable {
    let operationID: UUID
    let processed: Int
    let total: Int
    let seconds: Double
  }
  struct ProbeObservation: Codable, Sendable {
    let prefill: [PrefillEvent]
    let exactConstructorTriggerObserved: Bool
    let unexpectedTrigger: Bool
    let checkpointCallbacks: Int
    let displayedUpdates: Int
    let strictSuccessPublicationCallbacks: Int
    let afterJoinGrantCallbacks: Int
    let grantApproved: [Bool]
    let grantRevoked: Bool
    let elapsedSeconds: Double
    let cancelToJoinedSeconds: Double?
  }
  final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var events: [PrefillEvent] = []
    private var exactTrigger = false, unexpected = false, revoked = false
    private var checkpoints = 0, displayed = 0, strict = 0, grants = 0
    private var approved: [Bool] = []
    private var cancelledAt: ContinuousClock.Instant?
    init() { started = ContinuousClock().now }
    func prefilling(_ value: MLXGemmaRunner.PrefillProgress, cancelConstructor: Bool,
      flag: CancellationFlag) {
      lock.lock()
      events.append(.init(operationID: value.operationID, processed: value.processedPositions,
        total: value.totalPositions, seconds: started.duration(to: clock.now).timeInterval))
      let first = events.count == 1
      if cancelConstructor {
        if first {
          exactTrigger = value.operationID == flag.operationID
            && value.processedPositions == 512 && value.totalPositions == 4096
          unexpected = !exactTrigger; cancelledAt = clock.now
        } else { unexpected = true }
      }
      lock.unlock()
      // An unexpected first callback shuts the owned request down and fails the
      // declared case. It never becomes a retargeted qualifying trigger.
      if cancelConstructor && first { flag.cancel() }
    }
    func checkpoint() { lock.lock(); checkpoints += 1; lock.unlock() }
    func display() { lock.lock(); displayed += 1; lock.unlock() }
    func strictPublication() { lock.lock(); strict += 1; lock.unlock() }
    func authorize(_ authorization: JoinedKVRetentionAuthorization,
      binding: JoinedKVRetentionBinding, deny: Bool) -> Bool {
      if deny { authorization.revoke() }
      let permitted = authorization.approve(binding: binding)
      lock.lock(); grants += 1; approved.append(permitted); revoked = revoked || deny; lock.unlock()
      return permitted
    }
    func observation() -> ProbeObservation {
      lock.lock(); defer { lock.unlock() }
      let now = clock.now
      return .init(prefill: events, exactConstructorTriggerObserved: exactTrigger,
        unexpectedTrigger: unexpected, checkpointCallbacks: checkpoints, displayedUpdates: displayed,
        strictSuccessPublicationCallbacks: strict, afterJoinGrantCallbacks: grants,
        grantApproved: approved, grantRevoked: revoked,
        elapsedSeconds: started.duration(to: now).timeInterval,
        cancelToJoinedSeconds: cancelledAt.map { $0.duration(to: now).timeInterval })
    }
  }
  static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
    zip(a, b).prefix { $0 == $1 }.count
  }
  static func constructorDifferences(_ probe: ProbeObservation, cancellationError: Bool,
    flagCancelled: Bool, denied: Bool) -> [String] {
    var result: [String] = []
    if !cancellationError || !flagCancelled { result.append("constructor_not_cancelled") }
    if !probe.exactConstructorTriggerObserved || probe.unexpectedTrigger || probe.prefill.count != 1 {
      result.append("actual_nonterminal_512_trigger")
    }
    if probe.checkpointCallbacks != 0 || probe.displayedUpdates != 0
      || probe.strictSuccessPublicationCallbacks != 0 { result.append("stale_success_callback") }
    if probe.afterJoinGrantCallbacks != 1 || probe.grantApproved != [!denied]
      || probe.grantRevoked != denied { result.append("joined_owner_authorization") }
    return result
  }
  static func retainedDifferences(_ snapshot: PromptPrefixCache.SnapshotObservation,
    binding: JoinedKVRetentionBinding, sourceIDs: [Int], localLayers: [Int], window: Int) -> [String] {
    var result: [String] = []
    if snapshot.namespace != binding.owner.namespace || snapshot.tokenIDs != Array(sourceIDs.prefix(512)) {
      result.append("cancelled_source_integer_prefix_or_namespace")
    }
    if snapshot.origin != .prefill || snapshot.batchWidth != 1 || snapshot.row != nil {
      result.append("cancelled_source_width_row_origin")
    }
    if snapshot.geometry.chunking != .remainder || snapshot.geometry.tokenCeiling != 512 {
      result.append("cancelled_source_geometry")
    }
    let h = snapshot.forwardHistory
    if h.count != 1 || h.first?.origin != .prefill || h.first?.startTokenCount != 0
      || h.first?.endTokenCount != 512 || h.first?.evaluatedEndTokenCount != 512
      || h.first?.batchWidth != 1 || h.first?.row != nil
      || h.first?.promptTokenCount != 4096 || h.first?.geometry != snapshot.geometry {
      result.append("actual_submitted_forward_history")
    }
    if let p = snapshot.joinedRetentionProvenance {
      if p.binding != binding || p.termination != .constructorCancelled || p.promptTokenCount != 4096
        || p.representedTokenCount != 512 || p.lastCompleteCohortTokenCount != 512
        || p.lastSubmittedCohortTokenCount != 512 || p.acknowledgedGeneratedTokenCount != 0
        || p.representedGeneratedTokenCount != 0 { result.append("joined_submitted_cohort_provenance") }
    } else { result.append("joined_retention_provenance_missing") }
    if let coverage = snapshot.residentLocalCoverage {
      if coverage.map(\.layer).sorted() != localLayers.sorted() || coverage.count != localLayers.count
        || coverage.contains(where: { $0.window != window || $0.keep != 0
          || $0.intervals != [.init(lowerBound: 0, upperBound: 512)] }) {
        result.append("owning_local_layer_interval_coverage")
      }
    } else { result.append("local_interval_coverage_missing") }
    return result
  }
  static func revokedNamespaceDifferences(_ snapshots: [PromptPrefixCache.SnapshotObservation],
    owner: PromptCacheOwner) -> [String] {
    snapshots.contains(where: { $0.namespace == owner.namespace }) ? ["revoked_source_published"] : []
  }
  private static func memory() -> [String: Any] {
    let process = ModelResidency.memoryAccounting()
    return ["application_byte_limit": applicationBudget, "current_footprint_bytes": process.current,
      "process_lifetime_peak_footprint_bytes": process.peak,
      "allocator_active_plus_cache_bytes": max(0, Memory.activeMemory + Memory.cacheMemory),
      "mlx_peak_bytes": Memory.peakMemory,
      "operation_watch": "existing authoritative runner watch; no new polling/fence/eval"]
  }
  private static func checkMemory() throws {
    try ModelResidency.check()
    guard try ModelResidency.budget() == applicationBudget else {
      throw BoomError.budget("The declared application memory bound changed.")
    }
    let process = ModelResidency.memoryAccounting()
    let allocator = max(0, Memory.activeMemory + Memory.cacheMemory)
    guard process.current > 0, max(max(process.current, process.peak), UInt64(allocator)) <= applicationBudget else {
      throw BoomError.budget("The interrupted-prefix control exceeded the existing memory bound.")
    }
  }
  static func run(pack: URL, fixtureURL: URL, evidence: URL) async throws {
    var receipt: [String: Any] = ["schema": 1, "status": "running",
      "protocol": "joined_prefix_constructor_public_v1", "scope": "exactly four public constructor operations",
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "runtime_revision": ModelPacks.runtimeRevision, "cache_algorithm": PromptPrefixCache.algorithm,
      "fixture_sha256": fixtureSHA256, "application_byte_limit": applicationBudget,
      "retained_byte_limit": retainedBudget,
      "automatic_retries": false, "fifth_decode_case": "not_run",
      "native_tensor_restoration_observed": false, "logit_or_cold_output_equivalence_qualified": false,
      "native_tensor_oracle_blocker": "Normal runner exposes retained/hydrated metadata, not the original cancelled live K/V tensors. No copies or archives added.",
      "full_attention_coverage_scope": "Complete/submitted cohort provenance is source-bound helper proof; full-attention per-layer tensors/ranges are not independently exported.",
      "finalizer_fence_scope": "Existing runner fence/join permits publication; no separate diagnostic GPU fence measurement.",
      "stale_UI_release_qualified": false, "cold_4k_256_and_full_context_gates_replaced": false,
      "performance_qualified": false, "replay_qualified": false, "cases_completed": 0]
    receipt["full_context_16k"] = "not_run"
    func write(_ value: [String: Any], _ name: String) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent(name), options: .atomic)
    }
    func persist() throws { try write(receipt, "receipt.json") }
    func require(_ differences: [String]) throws {
      if !differences.isEmpty { throw BoomError.invalid("Interrupted-prefix diagnostic failed: " + differences.joined(separator: ", ")) }
    }
    try persist()
    var loaded: MLXGemmaRunner?
    do {
      guard PromptPrefixCache.defaultByteLimit == retainedBudget else {
        throw BoomError.budget("The declared one-GiB resident prefix bound changed.")
      }
      let bytes = try RegularFile(fixtureURL, limit: 1_048_576).data()
      let fixture = try Fixture.decode(bytes)
      try bytes.write(to: evidence.appendingPathComponent("fixture.json"), options: [.withoutOverwriting])
      let admission = try await detachedWork { try ModelPacks.admission(pack) }
      guard admission.purpose == .writing, admission.identity == fixture.model else {
        throw BoomError.invalid("The public writing model binding changed.")
      }
      let runner = try await MLXGemmaRunner.load(admission: admission); loaded = runner
      let policy = try ProductCore.resolvedGenerationPolicy(fixture.generation_policy, loaded: runner.generationPolicy)
      let sourceIDs = await runner.diagnosticTokenIDs(fixture.source.prompt)
      let successorIDs = await runner.diagnosticTokenIDs(fixture.successor.prompt)
      guard sourceIDs == fixture.source.prepared_token_ids, successorIDs == fixture.successor.prepared_token_ids,
        commonPrefix(sourceIDs, successorIDs) == 512 else {
        throw BoomError.stale("The exact loaded writing tokenizer changed the frozen public input.")
      }
      let configuration = try RegularFile(pack.appendingPathComponent("config.json"), limit: 1_048_576).data()
      guard let raw = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        let text = raw["text_config"] as? [String: Any], let types = text["layer_types"] as? [String],
        let layerCount = text["num_hidden_layers"] as? Int, let window = text["sliding_window"] as? Int,
        let shared = text["num_kv_shared_layers"] as? Int,
        let localKVHeads = text["num_key_value_heads"] as? Int,
        let globalKVHeads = text["num_global_key_value_heads"] as? Int,
        let localHeadDimension = text["head_dim"] as? Int,
        let globalHeadDimension = text["global_head_dim"] as? Int,
        let attentionKEqualsV = text["attention_k_eq_v"] as? Bool,
        types.count == layerCount, window >= 512 else { throw BoomError.invalid("Missing actual owning layer geometry.") }
      guard (0..<layerCount).contains(shared),
        localKVHeads > 0, globalKVHeads > 0, localHeadDimension > 0, globalHeadDimension > 0,
        types.allSatisfy({ ["full_attention", "sliding_attention"].contains($0) }) else {
        throw BoomError.invalid("Unsupported owning/cache layer geometry.")
      }
      let localLayers = types.prefix(layerCount - shared).enumerated().compactMap { $0.element == "sliding_attention" ? $0.offset : nil }
      let settings = try ProductCore.sampling(.standard)
      receipt["model"] = runner.identity; receipt["processor_identity"] = runner.processorIdentity
      receipt["generation_policy"] = try ProductCore.object(policy); receipt["settings"] = try ProductCore.object(settings)
      receipt["fixture_loaded_token_vectors_exact"] = true; receipt["source_prepared_tokens"] = sourceIDs.count
      receipt["successor_prepared_tokens"] = successorIDs.count; receipt["actual_prepared_lcp"] = 512
      receipt["owning_local_layer_indices"] = localLayers; receipt["native_window"] = window
      receipt["actual_model_geometry"] = ["num_hidden_layers": layerCount,
        "num_kv_shared_layers": shared, "sliding_window": window,
        "num_key_value_heads": localKVHeads, "num_global_key_value_heads": globalKVHeads,
        "head_dim": localHeadDimension, "global_head_dim": globalHeadDimension,
        "attention_k_eq_v": attentionKEqualsV]
      receipt["model_configuration_sha256"] = Digest.sha256(configuration); receipt["memory_before"] = memory()
      guard await runner.diagnosticCacheSnapshots().isEmpty else { throw BoomError.invalid("The fresh diagnostic runner already has cache state.") }
      try persist(); try checkMemory()

      func interrupted(_ name: String, owner: PromptCacheOwner, epoch: UUID, denied: Bool) async throws
        -> (JoinedKVRetentionBinding, [PromptPrefixCache.SnapshotObservation]) {
        let flag = CancellationFlag(), probe = Probe()
        guard let binding = try runner.joinedRetentionBinding(owner: owner, workspaceEpoch: epoch,
          operationID: flag.operationID, policy: policy) else {
          throw BoomError.unavailable("The loaded model did not verify the stateless text KV contract.")
        }
        let authorization = JoinedKVRetentionAuthorization(binding: binding)
        let request = JoinedKVRetentionRequest(authorization: authorization, checkpointIsDurable: false,
          authorizeAfterJoin: { probe.authorize(authorization, binding: binding, deny: denied) })
        try write(["name": name, "status": "running", "binding": try ProductCore.object(binding),
          "expected_nonterminal_cancel_positions": 512, "expected_full_prompt_positions": 4096,
          "source_prompt_digest": fixture.source.prompt_digest], name + ".json")
        var returned: MLXGemmaRunner.Output?, caught: Error?
        do {
          returned = try await runner.run(rawPrompt: fixture.source.prompt, maxTokens: 16, settings: settings,
            seed: fixture.seed, flag: flag, cacheOwner: owner, executionPolicy: policy, joinedRetention: request,
            beforeCachePublication: { probe.strictPublication(); try flag.check() },
            onPrefill: { probe.prefilling($0, cancelConstructor: true, flag: flag) },
            onCheckpoint: { _, _, _ in probe.checkpoint() }, onText: { _ in probe.display() })
        } catch { caught = error }
        await runner.join()
        let observation = probe.observation()
        let snapshots = await runner.diagnosticCacheSnapshots()
        let cancellationError = caught.map { $0 is CancellationError } ?? false
        var differences = constructorDifferences(observation, cancellationError: cancellationError,
          flagCancelled: flag.isCancelled, denied: denied)
        if denied {
          // A different, valid namespace may still be retained. The revoked
          // namespace must publish nothing; the later clear covers all scopes.
          differences += revokedNamespaceDifferences(snapshots, owner: owner)
        } else {
          if snapshots.count != 1 { differences.append("cancelled_source_snapshot_count") }
          for snapshot in snapshots {
            differences += retainedDifferences(snapshot, binding: binding, sourceIDs: sourceIDs,
              localLayers: localLayers, window: window)
          }
        }
        var record: [String: Any] = ["name": name, "status": "joined_validation_pending",
          "binding": try ProductCore.object(binding), "owner_joined": true, "flag_cancelled": flag.isCancelled,
          "error_type": caught.map { String(reflecting: type(of: $0)) } as Any? ?? NSNull(),
          "error": caught?.localizedDescription as Any? ?? NSNull(),
          "returned_output": try returned.map { try ProductCore.object($0) } ?? NSNull(),
          "probe": try ProductCore.object(observation), "snapshots": try ProductCore.object(snapshots),
          "snapshots_in_requested_namespace": snapshots.filter { $0.namespace == owner.namespace }.count,
          "differences": differences, "memory_after_join": memory(),
          "native_tensor_restoration_observed": false, "stopped_request_remains_cancelled": returned == nil && cancellationError]
        record["memory_gate"] = "not_checked"
        try write(record, name + ".json")
        if denied {
          // The authorization callback holds the executor/coordinator lease.
          // Clearing here, only after run+join, avoids re-entering that lease.
          await runner.clearPromptCache()
          let afterClear = await runner.diagnosticCacheSnapshots()
          record["clear_invoked_after_owned_join"] = true; record["snapshots_after_clear"] = try ProductCore.object(afterClear)
          if !afterClear.isEmpty { differences.append("post_join_barrier_clear") }
          record["differences"] = differences
        }
        do {
          try checkMemory(); record["memory_gate"] = "passed"
          try require(differences)
          record["status"] = "passed_metadata_controls"
          try write(record, name + ".json")
        } catch {
          record["status"] = "failed"; record["validation_error"] = error.localizedDescription
          try write(record, name + ".json"); throw error
        }
        return (binding, snapshots)
      }
      func successor(_ name: String, owner: PromptCacheOwner,
        sourceSnapshot: PromptPrefixCache.SnapshotObservation?) async throws {
        let flag = CancellationFlag(), probe = Probe()
        try write(["name": name, "status": "running", "owner": try ProductCore.object(owner),
          "operation_id": flag.operationID.uuidString, "successor_prompt_digest": fixture.successor.prompt_digest,
          "expected_cached_prompt_tokens": sourceSnapshot == nil ? 0 : 512], name + ".json")
        var returned: MLXGemmaRunner.Output?, caught: Error?
        do {
          returned = try await runner.run(rawPrompt: fixture.successor.prompt, maxTokens: fixture.successor_max_tokens,
            settings: settings, seed: fixture.seed, flag: flag, cacheOwner: owner, executionPolicy: policy,
            beforeCachePublication: { probe.strictPublication(); try flag.check() },
            onPrefill: { probe.prefilling($0, cancelConstructor: false, flag: flag) },
            onCheckpoint: { _, _, _ in probe.checkpoint() }, onText: { _ in probe.display() })
        } catch { caught = error }
        await runner.join()
        var differences: [String] = []
        if let output = returned, let metrics = output.prefillCacheMetrics {
          let expected = sourceSnapshot == nil ? 0 : 512
          if output.promptDigest != fixture.successor.prompt_digest || output.promptTokens != successorIDs.count
            || output.outputTokens != output.tokenIDs.count || output.outputTokens > 16
            || !["eos", "model_control", "output_limit"].contains(output.stopReason) || flag.isCancelled {
            differences.append("successor_input_output_status")
          }
          if let origin = output.executionOrigin {
            if !origin.isValid(promptTokens: output.promptTokens) || origin.cacheAlgorithm != PromptPrefixCache.algorithm
              || origin.cachedPromptTokens != expected || origin.cacheMissReason != metrics.missReason {
              differences.append("actual_execution_origin")
            }
          } else { differences.append("execution_origin_missing") }
          if metrics.algorithm != PromptPrefixCache.algorithm || metrics.cachedPromptTokens != expected
            || metrics.fullPromptTokens != successorIDs.count || metrics.prefilledPromptTokens != successorIDs.count - expected {
            differences.append("actual_hydrated_prefix_and_suffix_counts")
          }
          if !metrics.preservesChunkBoundaries || metrics.originalGeometry.chunking != .remainder
            || metrics.originalGeometry.tokenCeiling != 512 || metrics.originalGeometry.chunkStride != 512
            || metrics.suffixGeometry != metrics.originalGeometry {
            differences.append("actual_fixed_512_chunk_boundaries")
          }
          if metrics.residentTensorByteLimit != retainedBudget
            || metrics.residentTensorBytes == nil || metrics.residentTensorBytesAfter == nil
            || (metrics.residentTensorBytes ?? UInt64.max) > retainedBudget
            || (metrics.residentTensorBytesAfter ?? UInt64.max) > retainedBudget {
            differences.append("actual_resident_backing_budget")
          }
          if let original = sourceSnapshot {
            if metrics.cachedOrigin != original.origin || metrics.cachedBatchWidth != original.batchWidth
              || metrics.cachedRow != original.row || metrics.cachedForwardHistory != original.forwardHistory {
              differences.append("actual_cached_source_history_identity")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if try encoder.encode(metrics.cachedJoinedRetentionProvenance) != encoder.encode(original.joinedRetentionProvenance) {
              differences.append("actual_cached_cancelled_cohort_provenance")
            }
          } else if metrics.cachedJoinedRetentionProvenance != nil || !metrics.cachedForwardHistory.isEmpty
            || metrics.cachedOrigin != nil || metrics.cachedBatchWidth != nil || metrics.cachedRow != nil
            || metrics.missReason == nil {
            differences.append("denied_source_history_carryover")
          }
        } else { differences.append("successor_missing_output_or_cache_metrics") }
        if caught != nil { differences.append("successor_execution_error") }
        var record: [String: Any] = ["name": name, "status": "joined_validation_pending",
          "owner": try ProductCore.object(owner), "owner_joined": true,
          "output": try returned.map { try ProductCore.object($0) } ?? NSNull(),
          "error": caught?.localizedDescription as Any? ?? NSNull(), "probe": try ProductCore.object(probe.observation()),
          "declared_suffix_prepared_token_ids": Array(successorIDs.dropFirst(sourceSnapshot == nil ? 0 : 512)),
          "suffix_scope": "Derived from exact full input; live session metrics bind counts/history. Raw suffix tensor is not independently exported.",
          "differences": differences, "memory_after_join": memory(),
          "native_tensor_restoration_observed": false, "output_maximum": 16,
          "cold_output_exactness_compared": false, "memory_gate": "not_checked"]
        try write(record, name + ".json")
        do {
          try checkMemory(); record["memory_gate"] = "passed"
          try require(differences)
          record["status"] = "passed_metadata_controls"
          try write(record, name + ".json")
        } catch {
          record["status"] = "failed"; record["validation_error"] = error.localizedDescription
          try write(record, name + ".json"); throw error
        }
      }
      let allowed = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
      let (_, retained) = try await interrupted("01-constructor-authorized-cancel", owner: allowed, epoch: UUID(), denied: false)
      receipt["cases_completed"] = 1; try persist()
      try await successor("02-changed-tail-successor", owner: allowed, sourceSnapshot: retained.first)
      receipt["cases_completed"] = 2; try persist()
      let denied = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
      _ = try await interrupted("03-constructor-revoked-cancel", owner: denied, epoch: UUID(), denied: true)
      receipt["cases_completed"] = 3; try persist()
      try await successor("04-denied-owner-successor", owner: denied, sourceSnapshot: nil)
      receipt["cases_completed"] = 4
      await runner.join()
      guard Digest.sha256(try RegularFile(fixtureURL, limit: 1_048_576).data()) == fixtureSHA256 else {
        throw BoomError.stale("The public fixture changed during the owned diagnostic.")
      }
      receipt["memory_after_all_joins"] = memory(); receipt["joined"] = true
      try checkMemory()
      receipt["status"] = "passed_metadata_controls"; receipt["release_qualified"] = false
      try persist()
    } catch {
      await loaded?.join()
      receipt["joined"] = true; receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
      receipt["release_qualified"] = false
      try persist(); throw error
    }
  }
}
