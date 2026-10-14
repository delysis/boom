import BoomCore
import Foundation
import Metal
import MLX

/// Public real-weight cache controls. No workspace, Keychain or native window.
enum PromptCacheReuseSmoke {
  private struct PrefillEvent: Codable, Sendable {
    let operationID: UUID
    let processedPositions: Int
    let totalPositions: Int
    let seconds: Double
  }
  private struct CheckpointEvent: Codable, Sendable {
    let progress: GenerationProgress
    let stopReason: String?
    let stopTokenID: Int?
    let seconds: Double
  }
  private final class TrialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var events: [PrefillEvent] = []
    private var batch: MLXGemmaRunner.BatchMetrics?
    private var checkpoints: [CheckpointEvent] = []
    private var cancelledAt: ContinuousClock.Instant?
    init(started: ContinuousClock.Instant) { self.started = started }
    func prefilling(_ progress: MLXGemmaRunner.PrefillProgress) {
      let event = PrefillEvent(operationID: progress.operationID,
        processedPositions: progress.processedPositions, totalPositions: progress.totalPositions,
        seconds: started.duration(to: clock.now).timeInterval)
      lock.lock(); defer { lock.unlock() }; events.append(event)
    }
    func measured(_ value: MLXGemmaRunner.BatchMetrics) {
      lock.lock(); defer { lock.unlock() }; batch = value
    }
    func checkpoint(_ progress: GenerationProgress, stop: String?, token: Int?, flag: CancellationFlag) {
      let now = clock.now
      lock.lock()
      checkpoints.append(CheckpointEvent(progress: progress, stopReason: stop, stopTokenID: token,
        seconds: started.duration(to: now).timeInterval))
      let cancel = cancelledAt == nil && stop == nil && !progress.tokenIDs.isEmpty
      if cancel { cancelledAt = now }
      lock.unlock()
      if cancel { flag.cancel() }
    }
    func observation() -> ([PrefillEvent], MLXGemmaRunner.BatchMetrics?) {
      lock.lock(); defer { lock.unlock() }; return (events, batch)
    }
    func checkpointObservation() -> ([CheckpointEvent], Double?) {
      lock.lock(); defer { lock.unlock() }
      return (checkpoints, cancelledAt.map { $0.duration(to: clock.now).timeInterval })
    }
  }
  private final class MemoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let source: DispatchSourceTimer
    private var stopped = false
    private var samples = 0
    private var sampledFootprint: UInt64 = 0
    private var lifetimeFootprint: UInt64 = 0
    private var sampledAllocator = 0
    init() {
      source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      source.schedule(deadline: .now(), repeating: .milliseconds(20))
      source.setEventHandler { [weak self] in self?.sample() }
      source.resume()
    }
    func sample() {
      let process = ModelResidency.memoryAccounting()
      let allocator = max(0, Memory.activeMemory + Memory.cacheMemory)
      lock.lock(); defer { lock.unlock() }
      guard !stopped else { return }
      samples += 1; sampledFootprint = max(sampledFootprint, process.current)
      lifetimeFootprint = max(lifetimeFootprint, process.peak)
      sampledAllocator = max(sampledAllocator, allocator)
    }
    func observation() -> [String: Any] {
      sample()
      lock.lock(); defer { lock.unlock() }
      return ["sample_interval_ms": 20, "samples": samples,
        "sampled_peak_footprint_bytes": sampledFootprint,
        "process_lifetime_peak_footprint_bytes": lifetimeFootprint,
        "sampled_peak_allocator_active_plus_cache_bytes": sampledAllocator,
        "mlx_peak_memory_bytes": Memory.peakMemory]
    }
    func check(budget: UInt64) throws {
      sample()
      lock.lock()
      let used = max(max(sampledFootprint, lifetimeFootprint), UInt64(sampledAllocator))
      lock.unlock()
      guard used > 0, used <= budget else {
        throw BoomError.budget("The cache diagnostic exceeded the unchanged application memory budget.")
      }
      try ModelResidency.check()
    }
    func stop() {
      sample()
      lock.lock(); stopped = true; lock.unlock(); source.cancel()
    }
    deinit { source.cancel() }
  }
  private struct Trial {
    let outputs: [MLXGemmaRunner.Output]
    let events: [PrefillEvent]
    let batch: MLXGemmaRunner.BatchMetrics?
    var expectedResidentCachedTokens: Int? = nil
    var outputHistories: [OutputHistoryEvidence] = []
  }
  struct ControlResults {
    enum Category: String, Codable, Sendable {
      case cacheSemantics, provenance, exactOutput, historyClassification, crossHistoryObservation
    }
    struct Check: Codable, Sendable {
      let name: String
      let category: Category
      let passed: Bool
      let differences: [String]
    }
    private(set) var checks: [Check] = []
    mutating func record(_ name: String, category: Category, passed: Bool, differences: [String] = []) {
      checks.append(Check(name: name, category: category, passed: passed, differences: differences))
    }
    func passed(_ category: Category) -> Bool {
      let selected = checks.filter { $0.category == category }
      return !selected.isEmpty && selected.allSatisfy(\.passed)
    }
    var requiredControlsPassed: Bool {
      let required = checks.filter { $0.category != .crossHistoryObservation }
      return !required.isEmpty && required.allSatisfy(\.passed)
    }
    var hasUnqualifiedNumericalComparisons: Bool {
      checks.contains { $0.category == .crossHistoryObservation || $0.category == .historyClassification }
    }
    // Cross-history text equality does not supply an independent KV oracle.
    // Missing history cannot be promoted by coincidentally identical text.
    var qualified: Bool { requiredControlsPassed && !hasUnqualifiedNumericalComparisons }
  }
  static func exactOutputs(_ lhs: [MLXGemmaRunner.Output], _ rhs: [MLXGemmaRunner.Output]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { first, second in
      first.promptDigest == second.promptDigest && first.promptTokens == second.promptTokens
        && first.tokenIDs == second.tokenIDs && first.text.utf8.elementsEqual(second.text.utf8)
        && first.outputTokens == second.outputTokens && first.stopReason == second.stopReason
        && first.stopTokenID == second.stopTokenID && first.endedByEOS == second.endedByEOS
    }
  }
  struct ContinuationAnalysis: Codable, Sendable {
    let oldPromptTokens: Int
    let deliveredTokens: Int
    let currentPromptTokens: Int
    let commonLeadingTokens: Int
    let currentContainsDeliveredTokenLedger: Bool
  }
  static func continuationAnalysis(sourcePrompt: [Int], delivered: [Int], current: [Int]) -> ContinuationAnalysis {
    let ledger = sourcePrompt + delivered
    let common = zip(ledger, current).prefix(while: { first, second in first == second }).count
    return ContinuationAnalysis(oldPromptTokens: sourcePrompt.count, deliveredTokens: delivered.count,
      currentPromptTokens: current.count, commonLeadingTokens: common,
      currentContainsDeliveredTokenLedger: current.starts(with: ledger))
  }
  /// Select inside a retained sequence when the current prepared input diverges
  /// or ends sooner. The entire snapshot must still belong to the observed row's
  /// ledger; a speculative/undelivered tail cannot authorize even a partial hit.
  static func generatedPrefixEligible(retained: [Int], sourcePrompt: [Int], delivered: [Int],
    stopToken: Int?, current: [Int]) -> Bool {
    let ledger = sourcePrompt + delivered + (stopToken.map { [$0] } ?? [])
    let count = commonPrefixCount(retained, current, maximumCount: max(0, current.count - 1))
    return count > sourcePrompt.count && ledger.starts(with: retained)
  }
  /// Namespace hit controls need an eligible resident fixture, not merely a
  /// lexical ancestor that the bounded local windows no longer cover.
  static func snapshotCacheDifferences(expected: Int?, cached: [Int?], requireHit: Bool) -> [String] {
    guard let expected, expected >= 0 else { return ["resident_snapshot_missing"] }
    var differences: [String] = []
    if requireHit && expected == 0 { differences.append("no_eligible_resident_prefix_setup") }
    if cached.isEmpty || cached.contains(where: { $0 == nil }) { differences.append("cache_metrics_missing") }
    if requireHit && (cached.isEmpty || cached.contains(where: { ($0 ?? 0) <= 0 })) {
      differences.append("required_hit_missing")
    }
    if cached.contains(where: { $0 != expected }) { differences.append("resident_lcp") }
    return differences
  }
  /// Authored selection binds the input token prefix. A resident parent can be
  /// another source row after identical processed ledgers are deduplicated.
  static func selectedGeneratedPrefixMatches(retained: [Int], cachedTokenCount: Int,
    sourcePrompt: [Int], delivered: [Int], stopToken: Int?, current: [Int]) -> Bool {
    let ledger = sourcePrompt + delivered + (stopToken.map { [$0] } ?? [])
    guard cachedTokenCount > sourcePrompt.count, cachedTokenCount < current.count,
      cachedTokenCount <= retained.count, cachedTokenCount <= ledger.count else { return false }
    return retained.prefix(cachedTokenCount).elementsEqual(ledger.prefix(cachedTokenCount))
      && retained.prefix(cachedTokenCount).elementsEqual(current.prefix(cachedTokenCount))
  }
  static func generatedParentMatchesSelected(_ snapshot: PromptPrefixCache.SnapshotObservation,
    sourcePrompt: [Int], delivered: [Int], stopToken: Int?, current: [Int],
    metrics: MLXGemmaRunner.PrefillCacheMetrics) -> Bool {
    snapshotMatches(snapshot, current: current, metrics: metrics)
      && selectedGeneratedPrefixMatches(retained: snapshot.tokenIDs,
        cachedTokenCount: metrics.cachedPromptTokens, sourcePrompt: sourcePrompt,
        delivered: delivered, stopToken: stopToken, current: current)
  }
  static func commonPrefixCount(_ first: [Int], _ second: [Int], maximumCount: Int) -> Int {
    let bound = max(0, min(min(first.count, second.count), maximumCount))
    var count = 0
    while count < bound, first[count] == second[count] { count += 1 }
    return count
  }
  /// Historical starts-only evidence assumes a dense local suffix. It cannot
  /// prove coverage for current disjoint ranges; live checks use exact intervals.
  static func residentPrefixCount(retained: [Int], residentLocalStarts: [Int], current: [Int],
    window: Int, localLayerCount: Int) -> Int {
    guard window > 0, localLayerCount >= 0, residentLocalStarts.count == localLayerCount else { return 0 }
    let count = commonPrefixCount(retained, current, maximumCount: max(0, current.count - 1))
    guard count > 0, residentLocalStarts.allSatisfy({
      $0 >= 0 && $0 <= retained.count && $0 <= max(0, count - window)
    }) else { return 0 }
    return count
  }
  static func expectedResidentPrefix(snapshots: [PromptPrefixCache.SnapshotObservation], current: [Int],
    namespace: UUID, window: Int, localLayerCount: Int) -> Int {
    guard window > 0 else { return 0 }
    return snapshots.filter { $0.namespace == namespace }.map {
      residentPrefixCount(snapshot: $0, current: current, localLayerCount: localLayerCount)
    }.max() ?? 0
  }
  static func historyMatchesPrefix(_ observed: [PromptPrefixCache.ForwardSegment],
    retained: [PromptPrefixCache.ForwardSegment], tokenCount: Int) -> Bool {
    let prefix = retained.filter { $0.startTokenCount < tokenCount }
    return tokenCount > 0 && !prefix.isEmpty && observed.count == prefix.count
      && observed.first?.startTokenCount == 0 && observed.last?.endTokenCount == tokenCount
      && zip(observed, prefix).allSatisfy { actual, source in
        actual.origin == source.origin && actual.startTokenCount == source.startTokenCount
          && actual.endTokenCount == min(source.endTokenCount, tokenCount)
          && actual.batchWidth == source.batchWidth && actual.row == source.row
          && actual.promptTokenCount == source.promptTokenCount && actual.geometry == source.geometry
          && (actual.evaluatedEndTokenCount ?? actual.endTokenCount)
            == (source.evaluatedEndTokenCount ?? source.endTokenCount)
      }
  }
  private static func snapshotMatches(_ snapshot: PromptPrefixCache.SnapshotObservation,
    current: [Int], metrics: MLXGemmaRunner.PrefillCacheMetrics) -> Bool {
    let count = metrics.cachedPromptTokens
    return count > 0 && count < current.count && count <= snapshot.tokenIDs.count
      && commonPrefixCount(snapshot.tokenIDs, current, maximumCount: count) == count
      && snapshot.batchWidth == metrics.cachedBatchWidth && snapshot.row == metrics.cachedRow
      && metrics.cachedOrigin == metrics.cachedForwardHistory.last?.origin
      && historyMatchesPrefix(metrics.cachedForwardHistory, retained: snapshot.forwardHistory, tokenCount: count)
  }
  static func replayDifferences(_ lhs: [MLXGemmaRunner.Output], _ rhs: [MLXGemmaRunner.Output]) -> [String] {
    var differences: [String] = lhs.count == rhs.count ? [] : ["lane_count"]
    for lane in 0..<min(lhs.count, rhs.count) {
      let a = lhs[lane], b = rhs[lane]
      let fields: [(String, Bool)] = [("prompt_digest", a.promptDigest == b.promptDigest),
        ("prompt_tokens", a.promptTokens == b.promptTokens), ("token_ids", a.tokenIDs == b.tokenIDs),
        ("text", a.text.utf8.elementsEqual(b.text.utf8)), ("output_tokens", a.outputTokens == b.outputTokens),
        ("stop_reason", a.stopReason == b.stopReason), ("stop_token_id", a.stopTokenID == b.stopTokenID),
        ("ended_by_eos", a.endedByEOS == b.endedByEOS)]
      differences += fields.filter { !$0.1 }.map { "lane_\(lane)." + $0.0 }
    }
    return differences
  }
  static func nextConsultationPlan(_ source: ConsultationPlan, completion: String,
    question: String) throws -> ConsultationPlan {
    // Preserve the captured planning representation from consultation.rs. The
    // actual model input still comes from chatInput's loaded chat template.
    let reply = "<|turn>model\n<|channel>thought\n<channel|>"
    guard source.messages.last?.role == "user", source.rawPrompt.hasSuffix(reply) else {
      throw BoomError.invalid("The captured public plan is missing its recorded reply boundary.")
    }
    let messages = source.messages + [.init(role: "assistant", content: completion),
      .init(role: "user", content: question)]
    let raw = String(source.rawPrompt.dropLast(reply.count))
      + "<|turn>model\n" + completion + "<turn|>\n<|turn>user\n" + question + "<turn|>\n" + reply
    return ConsultationPlan(messages: messages, rawPrompt: raw)
  }
  private static func snapshotObject(_ snapshot: PromptPrefixCache.SnapshotObservation) throws -> [String: Any] {
    ["token_ids": snapshot.tokenIDs, "origin": snapshot.origin.rawValue,
      "batch_width": snapshot.batchWidth, "row": snapshot.row as Any? ?? NSNull(),
      "forward_history": try ProductCore.object(snapshot.forwardHistory),
      "geometry": try ProductCore.object(snapshot.geometry),
      "namespace": snapshot.namespace?.uuidString as Any? ?? NSNull(),
      "resident_local_starts": snapshot.residentLocalStarts,
      "resident_local_coverage": try snapshot.residentLocalCoverage.map { try ProductCore.object($0) } ?? NSNull(),
      "resident_coverage_evidence": snapshot.residentLocalCoverage == nil
        ? "historical_starts_only" : "exact_intervals"]
  }
  static func outputObject(_ output: MLXGemmaRunner.Output) throws -> [String: Any] {
    ["text": output.text, "token_ids": output.tokenIDs, "prompt_digest": output.promptDigest,
      "prompt_tokens": output.promptTokens, "output_tokens": output.outputTokens,
      "stop_reason": output.stopReason, "stop_token_id": output.stopTokenID as Any? ?? NSNull(),
      "ended_by_eos": output.endedByEOS,
      "first_token_seconds": output.firstTokenSeconds as Any? ?? NSNull(),
      "elapsed_seconds": output.elapsedSeconds,
      "execution_task_priority": output.executionPriority as Any? ?? NSNull(),
      "execution_origin": try output.executionOrigin.map { try ProductCore.object($0) } ?? NSNull(),
      "native_setup_metrics": try output.setupMetrics.map { try ProductCore.object($0) } ?? NSNull(),
      "prefill_cache_metrics": try output.prefillCacheMetrics.map { try ProductCore.object($0) } ?? NSNull()]
  }
  private static func ownerObject(_ owner: PromptCacheOwner?) -> Any {
    guard let owner else { return NSNull() }
    return ["namespace": owner.namespace.uuidString, "entity": owner.entity.uuidString,
      "route": owner.route.rawValue]
  }
  private static func verify(_ trial: Trial, tokens: Int, width: Int, maxTokens: Int,
    operationID: UUID, owner: PromptCacheOwner?,
    cancelled: Bool = false) -> [String] {
    var differences: [String] = []
    if !(trial.outputs.count == width && width > 0 && trial.outputs.allSatisfy({ $0.promptTokens == tokens
      && !$0.tokenIDs.isEmpty && $0.outputTokens == $0.tokenIDs.count && $0.outputTokens <= maxTokens
      && (cancelled ? $0.stopReason == "cancelled"
        : !["cancelled", "failed"].contains($0.stopReason)) })
      && trial.events.last?.processedPositions == tokens) {
      differences.append("registered_workload")
    }
    var previous = 0
    for event in trial.events {
      if !(event.operationID == operationID && event.totalPositions == tokens
        && event.processedPositions >= previous && event.processedPositions <= tokens) {
        differences.append("prefill_callback_identity_or_position")
      }
      previous = event.processedPositions
    }
    if owner != nil {
      for output in trial.outputs {
        guard let metrics = output.prefillCacheMetrics else {
          differences.append("cache_metrics_missing"); continue
        }
        if !(metrics.algorithm == PromptPrefixCache.activeAlgorithm && metrics.fullPromptTokens == tokens
          && metrics.cachedPromptTokens >= 0 && metrics.cachedPromptTokens < tokens
          && metrics.prefilledPromptTokens == tokens - metrics.cachedPromptTokens
          && trial.events.allSatisfy({ $0.processedPositions > metrics.cachedPromptTokens })) {
          differences.append("cache_metrics_or_shifted_prefill_positions")
        }
      }
    }
    if trial.outputs.count == 3 {
      if let metrics = trial.batch {
        if !(metrics.width == 3 && metrics.sharedPromptPrefills == 1 && metrics.decodeForwardPasses > 0
          && !metrics.cacheBatchDimensions.isEmpty && metrics.cacheBatchDimensions.allSatisfy({ $0 == 3 })) {
          differences.append("shared_prefill_or_fixed_batch_width")
        }
      } else {
        differences.append("batch_metrics_missing")
      }
    }
    return differences
  }
  private static func cacheObserved(_ trial: Trial, reused: Bool) -> Bool {
    !trial.outputs.isEmpty && trial.outputs.allSatisfy({ output in
      guard let metrics = output.prefillCacheMetrics else { return false }
      return reused ? metrics.cachedPromptTokens > 0 : metrics.cachedPromptTokens == 0
    })
  }
  private static func changedWord(_ prompt: String, late: Bool) throws -> String {
    let options: String.CompareOptions = late ? .backwards : []
    guard let range = prompt.range(of: "harbor", options: options) else {
      throw BoomError.invalid("The public mutation fixture is missing its authored word.")
    }
    var changed = prompt; changed.replaceSubrange(range, with: "garden"); return changed
  }
  private struct ResidentShape {
    let window: Int
    let localLayers: Int
  }
  private static func residentShape(_ pack: URL) throws -> ResidentShape {
    let data = try RegularFile(pack.appendingPathComponent("config.json"), limit: 1_048_576).data()
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = object["text_config"] as? [String: Any],
      let window = text["sliding_window"] as? Int, window > 0,
      let layers = text["layer_types"] as? [String],
      let count = text["num_hidden_layers"] as? Int, count > 0 else {
      throw BoomError.invalid("The public cache control has no captured native window geometry.")
    }
    let shared = text["num_kv_shared_layers"] as? Int ?? 0
    guard shared >= 0, shared < count, layers.count == count,
      layers.allSatisfy({ ["full_attention", "sliding_attention"].contains($0) }) else {
      throw BoomError.invalid("The public cache control's owning layer geometry is invalid.")
    }
    return ResidentShape(window: window,
      localLayers: layers.prefix(count - shared).filter { $0 == "sliding_attention" }.count)
  }
  static func run(writingPack: URL, consultationPack: URL, consultationFixture: URL?, evidence: URL) async throws {
    var receipt: [String: Any] = ["schema": 3, "status": "running",
      "numerical_contract": "observed-forward-partitions-v1",
      "independent_cross_history_cache_correctness_qualified": false,
      "independent_native_parity_performed_by_this_smoke": false,
      "scope": "headless public runner cache controls; no workspace UI, Keychain or encrypted checkpoint workload",
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "runtime_revision": ModelPacks.runtimeRevision, "automatic_retries": false,
      "main_prompt_tokens": 4096, "main_max_tokens_per_row": 256, "seed": 42,
      "batch_seeds": [42, 43, 44], "mutation_control_max_tokens": 16,
      "cold_4k_and_full_context_gate_replaced": false,
      "cancellation_immediate_successor": "not_run", "full_context_16k": "not_run",
      "cancellation_join_threshold_seconds": 2,
      "generated_continuation_controls": "not_run", "replay_history_contract_qualified": false,
      "timing_scope": "outer request runs from runner entry through returned output and joining; it includes input preparation, hashing, cache lookup, prefill and decoding, excludes receipt I/O and separately recorded model loading",
      "performance_thresholds_qualified": false, "interactive_ui_qualified": false]
    var controls = ControlResults()
    var comparisonOutcomes: [String: OutputComparisonOutcome] = [:]
    func write(_ value: [String: Any], _ name: String) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent(name), options: .atomic)
    }
    func persist() throws { try write(receipt, "receipt.json") }
    func check(_ name: String, category: ControlResults.Category, passed: Bool,
      differences: [String] = []) throws {
      controls.record(name, category: category, passed: passed, differences: differences)
      receipt["control_checks"] = try ProductCore.object(controls.checks)
      receipt["cache_semantic_controls_passed"] = controls.passed(.cacheSemantics)
      receipt["provenance_controls_passed"] = controls.passed(.provenance)
      receipt["same_observed_history_output_exactness_passed"] = controls.passed(.exactOutput)
      receipt["cold_output_exactness_passed"] = controls.passed(.exactOutput)
        && !controls.hasUnqualifiedNumericalComparisons
      receipt["required_controls_passed"] = controls.requiredControlsPassed
      receipt["cross_history_equivalence_status"] = controls.hasUnqualifiedNumericalComparisons ? "open" : "not_compared"
      receipt["all_strict_checks_passed"] = controls.qualified
      receipt["release_qualified"] = false
      try persist()
    }
    func compare(_ name: String, _ first: Trial, _ second: Trial) throws -> Bool {
      let differences = replayDifferences(first.outputs, second.outputs)
      let exactObserved = exactOutputs(first.outputs, second.outputs)
      let history = classifyOutputHistories(first.outputHistories, second.outputHistories)
      let bindingMatches = comparisonBindingsMatch(first.outputHistories, second.outputHistories)
      let outcome = OutputComparisonOutcome(history: history, exactObserved: exactObserved)
      let requiredPassed = outcome.requiredComparisonPassed
      comparisonOutcomes[name] = outcome
      let status: String
      switch history.relation {
      case .sameObservedPartitions: status = exactObserved ? "passed" : "failed"
      case .differentObservedPartitions, .differentObservedInputs:
        status = exactObserved ? "equality_observed_unqualified" : "difference_observed_unqualified"
      case .unknown: status = "history_unknown"
      case .incompatibleRequest: status = "failed"
      }
      try write(["name": name, "status": status, "category": history.requiresExactOutput
          ? "same_observed_history_exact_output" : "cross_history_or_unknown_observation",
        "output_exact_observed": exactObserved, "differences": differences,
        "history_classification": try ProductCore.object(history),
        "requires_exact_output": history.requiresExactOutput,
        "required_comparison_admitted": history.requiredComparisonAdmitted,
        "required_comparison_passed": requiredPassed,
        "independent_native_restoration_qualified": false,
        "cold_equivalence_qualified": false, "warm_replay_qualified": false,
        "first_histories": try ProductCore.object(first.outputHistories),
        "second_histories": try ProductCore.object(second.outputHistories),
        "first_outputs": try first.outputs.map(outputObject),
        "second_outputs": try second.outputs.map(outputObject)], name + "-comparison.json")
      try check(name + ".request_binding", category: .provenance,
        passed: bindingMatches, differences: bindingMatches ? [] : ["request_binding"])
      if history.requiresExactOutput {
        try check(name, category: .exactOutput, passed: exactObserved, differences: differences)
      } else {
        if !history.requiredComparisonAdmitted {
          try check(name + ".history_classification", category: .historyClassification,
            passed: false, differences: history.differences)
        }
        // False equality observations remain false in the ledger. This category
        // can never qualify cache correctness, including when all text matches.
        try check(name, category: .crossHistoryObservation, passed: exactObserved, differences: differences)
      }
      return exactObserved
    }
    func requireCache(_ name: String, _ result: Trial, reused: Bool) throws {
      try check(name, category: .cacheSemantics, passed: cacheObserved(result, reused: reused),
        differences: cacheObserved(result, reused: reused) ? [] : [reused ? "required_hit_missing" : "required_cold_missing"])
    }
    func requireSnapshotCache(_ name: String, _ result: Trial, hitRequired: Bool) throws {
      let differences = snapshotCacheDifferences(expected: result.expectedResidentCachedTokens,
        cached: result.outputs.map { $0.prefillCacheMetrics?.cachedPromptTokens }, requireHit: hitRequired)
      try check(name, category: .cacheSemantics, passed: differences.isEmpty, differences: differences)
    }
    try persist()
    let memory = MemoryProbe(); defer { memory.stop() }
    var writingRunner: MLXGemmaRunner?, consultationRunner: MLXGemmaRunner?
    do {
      let limits = try ModelResidency.limits(), budget = min(limits.applicationBytes, UInt64(24) << 30)
      receipt["limits"] = try ProductCore.object(limits)
      receipt["physical_memory_bytes"] = ProcessInfo.processInfo.physicalMemory
      receipt["metal_device"] = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
      let writingAdmission = try ModelPacks.admission(writingPack, purpose: .writing)
      let consultationAdmission = try ModelPacks.admission(consultationPack, purpose: .consultation)
      let writingShape = try residentShape(writingPack), consultationShape = try residentShape(consultationPack)
      receipt["writing_resident_window"] = writingShape.window
      receipt["writing_local_owning_layers"] = writingShape.localLayers
      receipt["consultation_resident_window"] = consultationShape.window
      receipt["consultation_local_owning_layers"] = consultationShape.localLayers
      for (name, admission, purpose) in [("writing", writingAdmission, ModelPurpose.writing),
        ("consultation", consultationAdmission, ModelPurpose.consultation)] {
        let manifest = try ModelPacks.evidenceManifest(admission, purpose: purpose)
        try manifest.write(to: evidence.appendingPathComponent(name + "-model-manifest.json"))
        receipt[name + "_model_manifest_sha256"] = Digest.sha256(manifest)
      }
      try persist()
      let loadClock = ContinuousClock(), writingLoadStarted = loadClock.now
      let writing = try await MLXGemmaRunner.load(admission: writingAdmission)
      receipt["writing_model_load_seconds"] = writingLoadStarted.duration(to: loadClock.now).timeInterval
      writingRunner = writing
      try ModelResidency.admit(weightBytes: consultationAdmission.weightBytes,
        residentWeights: writingAdmission.weightBytes)
      let consultationLoadStarted = loadClock.now
      let consultation = try await MLXGemmaRunner.load(admission: consultationAdmission)
      receipt["consultation_model_load_seconds"] = consultationLoadStarted.duration(to: loadClock.now).timeInterval
      consultationRunner = consultation
      defer { withExtendedLifetime((writing, consultation)) {} }
      guard writing.generationPolicy.prefill == PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512),
        consultation.generationPolicy.prefill == PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512) else {
        throw BoomError.invalid("The public cache diagnostic requires the versioned future fixed 512-token policy.")
      }
      receipt["writing_identity"] = writing.identity; receipt["consultation_identity"] = consultation.identity
      receipt["writing_generation_policy"] = try ProductCore.object(writing.generationPolicy)
      receipt["consultation_generation_policy"] = try ProductCore.object(consultation.generationPolicy)
      receipt["both_models_retained"] = true; receipt["effective_cache_limit_bytes"] = Memory.cacheLimit
      receipt["writing_three_lane_context_capacity"] = try await writing.contextLength(batchWidth: 3)
      receipt["consultation_context_capacity"] = await consultation.contextLength
      try memory.check(budget: budget); try persist()
      let prompt = try await writing.diagnosticPrefix(tokens: 4096)
      let append4097 = try await writing.diagnosticPrefix(tokens: 4097)
      let append4098 = try await writing.diagnosticPrefix(tokens: 4098)
      let lateAnchor = try await writing.diagnosticPrefix(tokens: 4353)
      let late = try changedWord(lateAnchor, late: true), early = try changedWord(lateAnchor, late: false)
      let lateTokens = await writing.tokenCount(late), earlyTokens = await writing.tokenCount(early)
      let plan: ConsultationPlan
      var capturedDigest: String?
      if let consultationFixture {
        let data = try RegularFile(consultationFixture, limit: 1_048_576).data()
        let fixture = try MLXNativeSmoke.ConsultationFixture.decode(data, model: consultation.identity,
          seed: 42, promptTokens: 4096, outputTokens: 256)
        _ = try ProductCore.resolvedGenerationPolicy(fixture.generation_policy, loaded: consultation.generationPolicy)
        plan = fixture.plan; capturedDigest = fixture.outputs[0].prompt_digest
        receipt["cache_consultation_fixture_sha256"] = Digest.sha256(data)
        receipt["fixture_recorded_generation_policy"] = try ProductCore.object(fixture.generation_policy)
        receipt["fixture_scope"] = "exact captured public input; fresh fixed_v1 cache-control executions, not a historical output replay"
      } else {
        var length = 4032, prepared: ConsultationPlan?
        for _ in 0..<8 {
          let prefix = try await consultation.diagnosticPrefix(tokens: length)
          let candidate = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: prefix,
            request: "Write a detailed continuation of the harbor scene. Introduce a person whose arrival changes what the keeper intends. Use at least three paragraphs.", routing: [])
          let actual = try await consultation.tokenCount(candidate)
          if actual == 4096 { prepared = candidate; break }
          length += 4096 - actual
        }
        guard let prepared else { throw BoomError.invalid("Public consultation input did not reach exactly 4096 prepared tokens.") }
        plan = prepared
      }
      guard try await consultation.tokenCount(plan) == 4096 else {
        throw BoomError.invalid("The cache consultation plan changed its registered token count.")
      }
      receipt["consultation_plan"] = try ProductCore.object(plan)
      receipt["fixture_construction_scope"] = "bounded tokenizer-only count calibration; no model-generation retries"
      try persist()
      let namespace = UUID()
      let ownerA = PromptCacheOwner(namespace: namespace, entity: UUID(), route: .writing)
      let ownerB = PromptCacheOwner(namespace: namespace, entity: UUID(), route: .writing)
      let routeOwner = PromptCacheOwner(namespace: namespace, entity: UUID(), route: .inputCompletion)
      let privateOwner = PromptCacheOwner(namespace: UUID(), entity: ownerA.entity, route: .writing)
      let chatOwner = PromptCacheOwner(namespace: namespace, entity: UUID(), route: .consultation)
      receipt["writing_owner"] = ownerObject(ownerA); receipt["switched_writing_owner"] = ownerObject(ownerB)
      receipt["consultation_owner"] = ownerObject(chatOwner)
      receipt["same_namespace_route_owner"] = ownerObject(routeOwner)
      receipt["new_namespace_owner"] = ownerObject(privateOwner)
      let settings = try ProductCore.sampling(.standard)
      var legacyPolicy = writing.generationPolicy
      legacyPolicy.prefill = PrefillGeometry(chunking: "balanced_v1", tokenCeiling: 512)
      legacyPolicy = try ProductCore.resolvedGenerationPolicy(legacyPolicy, loaded: writing.generationPolicy)
      var attempts: [String] = []
      func trial(_ name: String, runner: MLXGemmaRunner, raw: String?, chat: ConsultationPlan?,
        tokens: Int, owner: PromptCacheOwner?, seeds: [UInt64] = [42], maxTokens: Int = 256,
        executionPolicy: ModelGenerationPolicy? = nil, cancelAfterFirstCheckpoint: Bool = false,
        allowsGeneratedHistory: Bool = false,
        scope: String = "4096/256 main cache control") async throws -> Trial {
        let flag = CancellationFlag()
        let policy = try ProductCore.resolvedGenerationPolicy(executionPolicy ?? runner.generationPolicy,
          loaded: runner.generationPolicy)
        let preparedIDs: [Int]
        if let raw { preparedIDs = await runner.diagnosticTokenIDs(raw) }
        else if let chat { preparedIDs = try await runner.diagnosticTokenIDs(chat) }
        else { throw BoomError.invalid("Invalid public cache diagnostic input.") }
        let preparedDigest = Digest.sha256(try JSONEncoder().encode(preparedIDs))
        let requestBinding = Digest.sha256(try JSONSerialization.data(withJSONObject: [
          "model": runner.identity, "generation_policy": try ProductCore.object(policy),
          "settings": try ProductCore.object(settings), "seeds": seeds,
          "max_tokens_per_row": maxTokens, "prepared_token_digest": preparedDigest,
          "runtime_revision": ModelPacks.runtimeRevision], options: [.sortedKeys]))
        let shape = runner === writing ? writingShape : consultationShape
        let allSnapshots = await runner.diagnosticCacheSnapshots()
        let before = owner.map { owner in allSnapshots.filter { $0.namespace == owner.namespace } } ?? []
        let expected = owner.map { expectedResidentPrefix(snapshots: before, current: preparedIDs,
          namespace: $0.namespace, window: shape.window, localLayerCount: shape.localLayers) } ?? 0
        attempts.append(name); receipt["attempts"] = attempts; try persist()
        var record: [String: Any] = ["name": name, "status": "running", "scope": scope,
          "model": runner.identity, "generation_policy": try ProductCore.object(policy),
          "operation_id": flag.operationID.uuidString, "cache_owner": ownerObject(owner), "seeds": seeds,
          "expected_full_prompt_tokens": tokens, "max_tokens_per_row": maxTokens,
          "cancel_after_first_delivered_checkpoint": cancelAfterFirstCheckpoint,
          "generated_forward_history_observation_scope": allowsGeneratedHistory,
          "prepared_token_ids": preparedIDs, "resident_snapshots_before": try before.map(snapshotObject),
          "expected_cached_tokens_at_snapshot": expected, "resident_window": shape.window,
          "local_owning_layers": shape.localLayers,
          "settings": try ProductCore.object(settings), "prompt": raw as Any? ?? NSNull(),
          "plan": try chat.map { try ProductCore.object($0) } ?? NSNull()]
        try write(record, name + ".json")
        let clock = ContinuousClock(), started = clock.now, probe = TrialProbe(started: started)
        let checkpointCallback: @Sendable (GenerationProgress, String?, Int?) async throws -> Void = { progress, stop, token in
          probe.checkpoint(progress, stop: stop, token: token, flag: flag)
        }
        let checkpoint = cancelAfterFirstCheckpoint ? checkpointCallback : nil
        do {
          let outputs: [MLXGemmaRunner.Output]
          if let raw {
            if seeds.count == 1 {
              outputs = [try await runner.run(rawPrompt: raw, maxTokens: maxTokens, settings: settings,
                seed: seeds[0], flag: flag, cacheOwner: owner, executionPolicy: policy,
                onPrefill: { probe.prefilling($0) }, onCheckpoint: checkpoint, onText: { _ in })]
            } else {
              outputs = try await runner.runBatch(rawPrompt: raw, maxTokens: maxTokens, settings: settings,
                seeds: seeds, flag: flag, cacheOwner: owner, executionPolicy: policy,
                onPrefill: { probe.prefilling($0) }, onMetrics: { probe.measured($0) })
            }
          } else if let chat, seeds.count == 1 {
            outputs = [try await runner.run(plan: chat, images: [], maxTokens: maxTokens, seed: seeds[0],
              flag: flag, cacheOwner: owner, executionPolicy: policy,
              onPrefill: { probe.prefilling($0) }, onCheckpoint: checkpoint, onText: { _ in })]
          } else { throw BoomError.invalid("Invalid public cache diagnostic route.") }
          record["outer_request_elapsed_seconds"] = started.duration(to: clock.now).timeInterval
          if cancelAfterFirstCheckpoint { await runner.join(); record["joined"] = true }
          let (events, batch) = probe.observation()
          let (checkpoints, cancellationSeconds) = probe.checkpointObservation()
          let histories = comparisonHistories(outputs: outputs,
            callbackPositions: events.map(\.processedPositions), batch: batch, requestBinding: requestBinding)
          let result = Trial(outputs: outputs, events: events, batch: batch,
            expectedResidentCachedTokens: expected, outputHistories: histories)
          record["output_history_evidence"] = try ProductCore.object(histories)
          record["outputs"] = try outputs.map(outputObject)
          record["prefill_callbacks"] = try ProductCore.object(events)
          record["prefill_callback_count"] = events.count
          record["batch_metrics"] = try batch.map { try ProductCore.object($0) } ?? NSNull()
          record["checkpoints"] = try ProductCore.object(checkpoints)
          record["flag_is_cancelled"] = flag.isCancelled
          record["cancellation_join_seconds"] = cancellationSeconds as Any? ?? NSNull()
          record["memory"] = memory.observation(); record["status"] = "execution_complete"
          try write(record, name + ".json")
          var differences = verify(result, tokens: tokens, width: seeds.count, maxTokens: maxTokens,
            operationID: flag.operationID, owner: owner, cancelled: cancelAfterFirstCheckpoint)
          if preparedIDs.count != tokens { differences.append("prepared_token_count") }
          let expectedDigest = preparedDigest
          if outputs.contains(where: { $0.promptDigest != expectedDigest }) { differences.append("prepared_input_digest") }
          var cacheDifferences: [String] = []
          var observations: [[String: Any]] = []
          for (row, output) in outputs.enumerated() {
            if let metrics = output.prefillCacheMetrics {
              let count = metrics.cachedPromptTokens
              let reclaimed = metrics.contextReclamation?.reason == "residency_evicted"
                && count == 0 && metrics.missReason == "residency_evicted"
              if count != expected && !reclaimed { cacheDifferences.append("lane_\(row).resident_lcp") }
              let identities = before.filter { snapshotMatches($0, current: preparedIDs, metrics: metrics) }
              if count > 0 && identities.isEmpty { differences.append("lane_\(row).cached_prefix_history") }
              if let bytes = metrics.residentTensorBytes, let limit = metrics.residentTensorByteLimit,
                bytes > limit || limit == 0 { cacheDifferences.append("lane_\(row).resident_byte_limit") }
              let prefix = count >= 0 && count <= preparedIDs.count ? Array(preparedIDs.prefix(count)) : []
              observations.append(["row": row, "cached_tokens": count, "cached_prefix_token_ids": prefix,
                "cached_prefix_digest": Digest.sha256(try JSONEncoder().encode(prefix)),
                "resident_tensor_bytes": metrics.residentTensorBytes as Any? ?? NSNull(),
                "resident_tensor_byte_limit": metrics.residentTensorByteLimit as Any? ?? NSNull(),
                "snapshot_evicted_before_lookup": reclaimed,
                "miss_reason": metrics.missReason as Any? ?? NSNull(),
                "matched_snapshot_histories": try identities.map(snapshotObject)])
            } else if owner != nil { cacheDifferences.append("lane_\(row).cache_metrics_missing") }
          }
          if cancelAfterFirstCheckpoint {
            var cancellationPassed = false
            if let final = checkpoints.last, let output = outputs.first,
              let cancellationSeconds {
              cancellationPassed = flag.isCancelled && checkpoints.count >= 2 && checkpoints.first?.stopReason == nil
                && final.stopReason == "cancelled" && final.progress.tokenIDs == output.tokenIDs
                && final.progress.text.utf8.elementsEqual(output.text.utf8)
                && final.progress.promptDigest == output.promptDigest
                && final.progress.promptTokens == output.promptTokens && cancellationSeconds <= 2
            }
            if !cancellationPassed { differences.append("cancellation_checkpoint_or_join_bound") }
          }
          try memory.check(budget: budget)
          record["cache_observations"] = observations
          record["provenance_differences"] = differences
          record["cache_semantic_differences"] = cacheDifferences
          record["status"] = differences.isEmpty && cacheDifferences.isEmpty ? "passed" : "failed"
          try write(record, name + ".json")
          try check(name + ".provenance", category: .provenance, passed: differences.isEmpty, differences: differences)
          try check(name + ".resident_cache", category: .cacheSemantics,
            passed: cacheDifferences.isEmpty, differences: cacheDifferences)
          return result
        } catch {
          await runner.join()
          let (events, batch) = probe.observation()
          let (checkpoints, cancellationSeconds) = probe.checkpointObservation()
          record["prefill_callbacks"] = try ProductCore.object(events)
          record["prefill_callback_count"] = events.count
          record["batch_metrics"] = try batch.map { try ProductCore.object($0) } ?? NSNull()
          if record["outer_request_elapsed_seconds"] == nil {
            record["outer_request_elapsed_seconds"] = started.duration(to: clock.now).timeInterval
          }
          record["checkpoints"] = try ProductCore.object(checkpoints)
          record["flag_is_cancelled"] = flag.isCancelled; record["joined"] = true
          if record["cancellation_join_seconds"] == nil {
            record["cancellation_join_seconds"] = cancellationSeconds as Any? ?? NSNull()
          }
          record["memory"] = memory.observation(); record["status"] = "failed"
          record["error"] = error.localizedDescription
          try write(record, name + ".json"); throw error
        }
      }
      // Nil-owner historical/cold oracles explicitly reclaim optional KV. All
      // cold comparisons precede the owned controls so they cannot disturb them.
      let oracle3 = try await trial("writing-cold-oracle-three", runner: writing, raw: prompt,
        chat: nil, tokens: 4096, owner: nil, seeds: [42, 43, 44])
      let base16 = try await trial("writing-cold-oracle-owner-switch", runner: writing, raw: prompt,
        chat: nil, tokens: 4096, owner: nil, maxTokens: 16, scope: "mutation control only; not the 256-output gate")
      let oracle4097 = try await trial("writing-cold-oracle-4097", runner: writing, raw: append4097,
        chat: nil, tokens: 4097, owner: nil, maxTokens: 16, scope: "append control only; not the 256-output gate")
      let oracle4098 = try await trial("writing-cold-oracle-4098", runner: writing, raw: append4098,
        chat: nil, tokens: 4098, owner: nil, maxTokens: 16, scope: "append control only; not the 256-output gate")
      let lateOracle = try await trial("writing-cold-oracle-late", runner: writing, raw: late,
        chat: nil, tokens: lateTokens, owner: nil, maxTokens: 16, scope: "divergence control only; not the 256-output gate")
      let earlyOracle = try await trial("writing-cold-oracle-early", runner: writing, raw: early,
        chat: nil, tokens: earlyTokens, owner: nil, maxTokens: 16, scope: "divergence control only; not the 256-output gate")
      let legacyOracle = try await trial("writing-cold-oracle-legacy-4098", runner: writing, raw: append4098,
        chat: nil, tokens: 4098, owner: nil, maxTokens: 16, executionPolicy: legacyPolicy,
        scope: "historical balanced geometry control only; not the 256-output gate")
      let cold = try await trial("writing-cold-owner", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: ownerA)
      try requireCache("writing_initial_cold", cold, reused: false)
      let identical = try await trial("writing-identical-reuse", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: ownerA)
      try requireCache("writing_identical_hit", identical, reused: true)
      receipt["identical_writing_exact"] = try compare("writing-identical", cold, identical); try persist()
      let batch = try await trial("writing-three-reuse", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: ownerA, seeds: [42, 43, 44])
      try requireCache("writing_three_hit", batch, reused: true)
      let repeatedBatch = try await trial("writing-three-repeat", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: ownerA, seeds: [42, 43, 44])
      try requireCache("writing_three_repeat_hit", repeatedBatch, reused: true)
      let threeColdExact = try compare("writing-three-cold", oracle3, batch)
      let threeRepeatExact = try compare("writing-three-repeat", batch, repeatedBatch)
      receipt["three_lane_cold_and_repeated_replay_exact"] = threeColdExact && threeRepeatExact
      receipt["three_lane_exact_by_seed"] = zip([42, 43, 44], 0..<3).map { seed, lane in
        ["seed": seed,
          "cold_exact": oracle3.outputs.indices.contains(lane) && batch.outputs.indices.contains(lane)
            && exactOutputs([oracle3.outputs[lane]], [batch.outputs[lane]]),
          "repeat_exact": batch.outputs.indices.contains(lane) && repeatedBatch.outputs.indices.contains(lane)
            && exactOutputs([batch.outputs[lane]], [repeatedBatch.outputs[lane]])] as [String: Any]
      }
      try persist()
      let appended1 = try await trial("writing-append-4097", runner: writing, raw: append4097,
        chat: nil, tokens: 4097, owner: ownerA, maxTokens: 16, scope: "append control only; not the 256-output gate")
      try requireCache("writing_append_4097_hit", appended1, reused: true)
      let appended2 = try await trial("writing-append-4098", runner: writing, raw: append4098,
        chat: nil, tokens: 4098, owner: ownerA, maxTokens: 16, scope: "append control only; not the 256-output gate")
      try requireCache("writing_append_4098_hit", appended2, reused: true)
      let append1Exact = try compare("writing-append-4097", oracle4097, appended1)
      let append2Exact = try compare("writing-append-4098", oracle4098, appended2)
      receipt["append_cold_output_exact"] = append1Exact && append2Exact
      let appendGeometry1 = appended1.outputs.first?.prefillCacheMetrics?.originalGeometry
      let appendGeometry2 = appended2.outputs.first?.prefillCacheMetrics?.originalGeometry
      let fixedGeometry = appendGeometry1 != nil && appendGeometry1 == appendGeometry2
        && appendGeometry1?.chunking == .remainder && appendGeometry1?.tokenCeiling == 512
        && appendGeometry1?.chunkStride == 512
      try check("fixed_4097_4098_registered_policy", category: .provenance, passed: fixedGeometry)
      receipt["fixed_4097_4098_geometry_equal"] = fixedGeometry
      _ = try await trial("writing-late-anchor", runner: writing, raw: lateAnchor, chat: nil,
        tokens: 4353, owner: ownerA, maxTokens: 16, scope: "public late-divergence setup; not the 256-output gate")
      let lateTrial = try await trial("writing-late-divergence", runner: writing, raw: late, chat: nil,
        tokens: lateTokens, owner: ownerA, maxTokens: 16, scope: "divergence control only; not the 256-output gate")
      let earlyTrial = try await trial("writing-early-divergence", runner: writing, raw: early, chat: nil,
        tokens: earlyTokens, owner: ownerA, maxTokens: 16, scope: "divergence control only; not the 256-output gate")
      // Both divergences are checked against their actual resident windows by
      // trial(); an early edit can hit or miss without a fixture-specific rule.
      // Isolate ownership from the preceding edits and bounded branch eviction.
      // This is one declared setup, not a retry of a failed ownership request.
      await writing.clearPromptCache()
      let namespaceAnchor = try await trial("writing-namespace-control-anchor", runner: writing,
        raw: prompt, chat: nil, tokens: 4096, owner: ownerA, maxTokens: 16,
        scope: "cold original-prefix setup for namespace controls only; not the 256-output gate")
      try requireCache("namespace_control_anchor_cold", namespaceAnchor, reused: false)
      let namespaceAnchorExact = try compare("writing-namespace-control-anchor", base16, namespaceAnchor)
      receipt["namespace_control_anchor_cold_output_exact"] = namespaceAnchorExact
      try persist()
      let switched = try await trial("writing-owner-switch", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: ownerB, maxTokens: 16, scope: "owner control only; not the 256-output gate")
      try requireSnapshotCache("same_namespace_entity_hit", switched, hitRequired: true)
      let routed = try await trial("writing-same-namespace-route", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: routeOwner, maxTokens: 16, scope: "namespace-pool route control only; not the 256-output gate")
      try requireSnapshotCache("same_namespace_route_hit", routed, hitRequired: true)
      let isolated = try await trial("writing-new-namespace-cold", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: privateOwner, maxTokens: 16, scope: "new namespace privacy control only; not the 256-output gate")
      try requireCache("new_namespace_privacy_cold", isolated, reused: false)
      let returned = try await trial("writing-return-to-namespace", runner: writing, raw: prompt, chat: nil,
        tokens: 4096, owner: ownerB, maxTokens: 16, scope: "return to resident namespace control only; not the 256-output gate")
      // The private namespace may have evicted the old resident pages. Returning
      // obeys the current resident oracle; the two isolated hit controls above
      // still require a positive, exact longest resident match.
      try requireSnapshotCache("return_to_namespace_residency", returned, hitRequired: false)
      let lateExact = try compare("writing-late-divergence", lateOracle, lateTrial)
      let earlyExact = try compare("writing-early-divergence", earlyOracle, earlyTrial)
      let switchExact = try compare("writing-owner-switch", base16, switched)
      let routeExact = try compare("writing-same-namespace-route", base16, routed)
      let privacyExact = try compare("writing-new-namespace", base16, isolated)
      let returnedExact = try compare("writing-return-to-namespace", base16, returned)
      receipt["append_divergence_owner_controls_exact"] = lateExact && earlyExact && switchExact
        && routeExact && privacyExact && returnedExact; try persist()
      receipt["cancellation_immediate_successor"] = "running"; try persist()
      let cancelled = try await trial("writing-cancel-after-checkpoint", runner: writing, raw: prompt,
        chat: nil, tokens: 4096, owner: ownerB, maxTokens: 16, cancelAfterFirstCheckpoint: true,
        scope: "first delivered checkpoint cancellation control only; not the 256-output gate")
      try requireCache("cancelled_request_hit", cancelled, reused: true)
      let successor = try await trial("writing-immediate-successor", runner: writing, raw: prompt,
        chat: nil, tokens: 4096, owner: ownerB, maxTokens: 16,
        scope: "immediate same-owner cancellation successor control only; not the 256-output gate")
      try requireCache("immediate_successor_hit", successor, reused: true)
      let successorExact = try compare("writing-immediate-successor", base16, successor)
      receipt["cancellation_immediate_successor"] = successorExact ? "passed" : "failed"; try persist()
      let legacyAnchor = try await trial("writing-legacy-4097", runner: writing, raw: append4097,
        chat: nil, tokens: 4097, owner: ownerB, maxTokens: 16, executionPolicy: legacyPolicy,
        scope: "historical balanced geometry setup only; not the 256-output gate")
      let legacy = try await trial("writing-legacy-4098-normal-cache", runner: writing, raw: append4098,
        chat: nil, tokens: 4098, owner: ownerB, maxTokens: 16, executionPolicy: legacyPolicy,
        scope: "normal resident reuse under captured balanced policy; history may differ from cold geometry")
      try requireCache("balanced_normal_resident_hit", legacy, reused: true)
      receipt["balanced_normal_history_changed"] = !(legacy.outputs.first?.prefillCacheMetrics?.preservesChunkBoundaries ?? true)
      let legacyGeometry = legacyAnchor.outputs.first?.prefillCacheMetrics?.originalGeometry
      receipt["balanced_anchor_original_geometry"] = try legacyGeometry.map { try ProductCore.object($0) } ?? NSNull()
      _ = try compare("writing-balanced-normal-cold-output", legacyOracle, legacy)
      let legacyReplay = try await trial("writing-legacy-4098-cold", runner: writing, raw: append4098,
        chat: nil, tokens: 4098, owner: nil, maxTokens: 16, executionPolicy: legacyPolicy,
        scope: "explicit nil-owner historical balanced cold replay oracle; no cache lineage substituted")
      receipt["historical_balanced_stride_change_cold_exact"] = try compare("writing-balanced-historical-replay", legacyOracle, legacyReplay)
      try persist()
      let chatCold = try await trial("consultation-cold-owner", runner: consultation, raw: nil, chat: plan,
        tokens: 4096, owner: chatOwner)
      try requireCache("consultation_initial_cold", chatCold, reused: false)
      if let capturedDigest {
        try check("consultation_fixture_input_digest", category: .provenance,
          passed: chatCold.outputs.first?.promptDigest == capturedDigest)
      }
      let chatReuse = try await trial("consultation-identical-reuse", runner: consultation, raw: nil, chat: plan,
        tokens: 4096, owner: chatOwner)
      try requireCache("consultation_identical_hit", chatReuse, reused: true)
      receipt["consultation_exact"] = try compare("consultation-identical", chatCold, chatReuse)
      receipt["main_prompt_only_controls_passed"] = controls.qualified
      receipt["generated_continuation_controls"] = "running"; try persist()
      var generatedSummaries: [[String: Any]] = [], generatedFailures: [String] = []
      var generatedUnqualified: [String] = []
      func generatedControl(_ name: String, runner: MLXGemmaRunner, sourceRaw: String?,
        sourceChat: ConsultationPlan?, sourceCold: Trial, sourceSeeds: [UInt64], selectedRow: Int,
        sourceColdFile: String) async throws {
        guard sourceCold.outputs.count == sourceSeeds.count, sourceSeeds.indices.contains(selectedRow) else {
          generatedFailures.append(name)
          generatedSummaries.append(["name": name, "status": "failed", "selected_row": selectedRow,
            "error": "The generated continuation source lost its captured candidate rows."])
          try check(name + ".source_rows", category: .provenance, passed: false, differences: ["source_rows"])
          receipt["generated_continuation_results"] = generatedSummaries
          receipt["generated_continuation_failures"] = generatedFailures
          try persist(); return
        }
        let selected = sourceCold.outputs[selectedRow]
        let currentRaw: String?, currentChat: ConsultationPlan?, sourceIDs: [Int], currentIDs: [Int]
        if let sourceRaw {
          let accepted = sourceRaw + selected.text
          currentRaw = accepted; currentChat = nil
          sourceIDs = await runner.diagnosticTokenIDs(sourceRaw)
          currentIDs = await runner.diagnosticTokenIDs(accepted)
        } else if let sourceChat {
          currentRaw = nil
          let nextPlan = try nextConsultationPlan(sourceChat, completion: selected.text,
            question: "What does the keeper do next?")
          currentChat = nextPlan
          sourceIDs = try await runner.diagnosticTokenIDs(sourceChat)
          currentIDs = try await runner.diagnosticTokenIDs(nextPlan)
        } else { throw BoomError.invalid("The generated continuation has no captured public input.") }
        let analysis = continuationAnalysis(sourcePrompt: sourceIDs, delivered: selected.tokenIDs, current: currentIDs)
        let sourceDigest = Digest.sha256(try JSONEncoder().encode(sourceIDs))
        let currentDigest = Digest.sha256(try JSONEncoder().encode(currentIDs))
        let shape = runner === writing ? writingShape : consultationShape
        let owner = PromptCacheOwner(namespace: namespace, entity: UUID(),
          route: sourceRaw == nil ? .consultation : .writing)
        var record: [String: Any] = ["name": name, "status": "running",
          "scope": "accepted generated completion, 16-token public cache control; not the 256-output gate",
          "source_cold_trial": sourceColdFile, "source_seed_rows": sourceSeeds, "selected_row": selectedRow,
          "next_seed": sourceSeeds[selectedRow], "cache_owner": ownerObject(owner),
          "generation_policy": try ProductCore.object(runner.generationPolicy),
          "source_prepared_token_ids": sourceIDs, "current_prepared_token_ids": currentIDs,
          "current_prompt_digest": currentDigest, "retokenization": try ProductCore.object(analysis),
          "current_raw_prompt": currentRaw as Any? ?? NSNull(),
          "current_plan": try currentChat.map { try ProductCore.object($0) } ?? NSNull(),
          "replay_history_contract_qualified": false, "automatic_retries": false]
        try write(record, name + ".json")
        do {
          // The nil-owner oracle clears old state. Reconstruct the declared source
          // exactly once afterward, as an explicit control, to publish its history.
          let oracle = try await trial(name + "-cold-successor", runner: runner, raw: currentRaw,
            chat: currentChat, tokens: currentIDs.count, owner: nil, seeds: [sourceSeeds[selectedRow]],
            maxTokens: 16, scope: "generated continuation cold oracle only; not the 256-output gate")
          let published = try await trial(name + "-source-owned", runner: runner, raw: sourceRaw,
            chat: sourceChat, tokens: sourceIDs.count, owner: owner, seeds: sourceSeeds,
            maxTokens: 16, scope: "declared source reconstruction and completed-KV publication; not a retry or the 256-output gate")
          try requireCache(name + ".reconstructed_source_cold", published, reused: false)
          let allSnapshots = await runner.diagnosticCacheSnapshots()
          let snapshots = allSnapshots.filter { $0.namespace == owner.namespace }
          let decoded = snapshots.filter { $0.origin != .prefill }
          let selectedDecodeRetained = decoded.contains { ($0.row ?? 0) == selectedRow }
          let validLedgers = decoded.allSatisfy { snapshot in
            let row = snapshot.row ?? 0
            guard published.outputs.indices.contains(row), snapshot.batchWidth == sourceSeeds.count else { return false }
            let output = published.outputs[row]
            let ledger = sourceIDs + output.tokenIDs + (output.stopTokenID.map { [$0] } ?? [])
            return ledger.starts(with: snapshot.tokenIDs) && snapshot.tokenIDs.count > sourceIDs.count
          }
          let eligible = decoded.filter { snapshot in
            let row = snapshot.row ?? 0
            guard published.outputs.indices.contains(row) else { return false }
            let output = published.outputs[row]
            return generatedPrefixEligible(retained: snapshot.tokenIDs, sourcePrompt: sourceIDs,
              delivered: output.tokenIDs, stopToken: output.stopTokenID, current: currentIDs)
              && residentPrefixCount(snapshot: snapshot, current: currentIDs,
                localLayerCount: shape.localLayers) > sourceIDs.count
          }
          let selectedEligible = eligible.filter { ($0.row ?? 0) == selectedRow }
          let selectedTokenEligible = eligible.filter { snapshot in
            let count = residentPrefixCount(snapshot: snapshot, current: currentIDs,
              localLayerCount: shape.localLayers)
            return selectedGeneratedPrefixMatches(retained: snapshot.tokenIDs, cachedTokenCount: count,
              sourcePrompt: sourceIDs, delivered: selected.tokenIDs, stopToken: selected.stopTokenID,
              current: currentIDs)
          }
          record["retained_snapshots"] = try snapshots.map(snapshotObject)
          record["selected_row_decode_snapshot_retained"] = selectedDecodeRetained
          record["retained_decode_ledgers_valid"] = validLedgers
          record["eligible_generated_snapshots"] = try eligible.map(snapshotObject)
          record["selected_row_generated_prefix_eligible"] = !selectedEligible.isEmpty
          record["selected_authored_token_prefix_eligible"] = !selectedTokenEligible.isEmpty
          record["decoded_source_snapshot_retained"] = !decoded.isEmpty
          record["eligible_row_ids"] = eligible.map { $0.row ?? 0 }
          try write(record, name + ".json")
          let resumed = try await trial(name + "-accepted-cache", runner: runner, raw: currentRaw,
            chat: currentChat, tokens: currentIDs.count, owner: owner, seeds: [sourceSeeds[selectedRow]],
            maxTokens: 16, allowsGeneratedHistory: true,
            scope: "actual generated-forward history observation; not cold-replay qualification or the 256-output gate")
          let allRepeatSnapshots = await runner.diagnosticCacheSnapshots()
          let repeatSnapshots = allRepeatSnapshots.filter { $0.namespace == owner.namespace }
          let repeated = try await trial(name + "-same-history-repeat", runner: runner, raw: currentRaw,
            chat: currentChat, tokens: currentIDs.count, owner: owner, seeds: [sourceSeeds[selectedRow]],
            maxTokens: 16, allowsGeneratedHistory: true,
            scope: "same-owner completed-cache repeat observation; not arbitrary replay or the 256-output gate")
          let metrics = resumed.outputs.first?.prefillCacheMetrics
          let cachedCount = metrics?.cachedPromptTokens ?? 0
          let matched = eligible.filter { snapshot in
            metrics.map { snapshotMatches(snapshot, current: currentIDs, metrics: $0) } ?? false
          }
          let generatedRequired = !eligible.isEmpty
          let generatedHit = cachedCount > sourceIDs.count
          let identityValid = !generatedHit || !matched.isEmpty
          let generatedHitRequiredPassed = !generatedRequired || (generatedHit && identityValid)
          let selectedMatched = matched.filter { snapshot in
            metrics.map { generatedParentMatchesSelected(snapshot, sourcePrompt: sourceIDs,
              delivered: selected.tokenIDs, stopToken: selected.stopTokenID, current: currentIDs,
              metrics: $0) } ?? false
          }
          let selectedPrefixValid = !generatedHit || !selectedMatched.isEmpty
          let sourceRowsAuthorizingPrefix = published.outputs.indices.filter { row in
            let output = published.outputs[row]
            return matched.contains { snapshot in
              selectedGeneratedPrefixMatches(retained: snapshot.tokenIDs, cachedTokenCount: cachedCount,
                sourcePrompt: sourceIDs, delivered: output.tokenIDs, stopToken: output.stopTokenID,
                current: currentIDs)
            }
          }
          let repeatMetrics = repeated.outputs.first?.prefillCacheMetrics
          let repeatMatchesSnapshot = repeatSnapshots.contains { snapshot in
            repeatMetrics.map { snapshotMatches(snapshot, current: currentIDs, metrics: $0) } ?? false
          }
          let repeatCachePassed = !generatedRequired || ((repeatMetrics?.cachedPromptTokens ?? 0) > sourceIDs.count
            && repeatMatchesSnapshot)
          let sourceExact = try compare(name + "-source-reconstruction", sourceCold, published)
          let coldExact = try compare(name + "-cold-output", oracle, resumed)
          let repeatExact = try compare(name + "-repeat-output", resumed, repeated)
          let inputExact = sourceCold.outputs.allSatisfy { $0.promptDigest == sourceDigest }
            && published.outputs.allSatisfy { $0.promptDigest == sourceDigest }
            && (oracle.outputs + resumed.outputs + repeated.outputs).allSatisfy { $0.promptDigest == currentDigest }
          // Snapshot row IDs describe the actual numerical parent. They need
          // not equal the authored selected row when exact token prefixes match.
          let semanticChecks: [(String, Bool)] = [
            ("decoded_source_snapshot_missing", !decoded.isEmpty),
            ("retained_decode_ledger", validLedgers),
            ("required_generated_hit", generatedHitRequiredPassed),
            ("cached_parent_history", identityValid),
            ("selected_authored_token_prefix", selectedPrefixValid),
            ("same_history_repeat_cache", repeatCachePassed)]
          let semanticDifferences = semanticChecks.filter { !$0.1 }.map { $0.0 }
          let semanticPassed = semanticDifferences.isEmpty
          let comparisonNames = [name + "-source-reconstruction", name + "-cold-output", name + "-repeat-output"]
          let disposition = generatedControlDisposition(semanticPassed: semanticPassed,
            inputExact: inputExact, comparisons: comparisonNames.map { comparisonOutcomes[$0] })
          let requiredPassed = disposition != .failed
          try check(name + ".cache_semantics", category: .cacheSemantics, passed: semanticPassed,
            differences: semanticDifferences)
          try check(name + ".input_binding", category: .provenance, passed: inputExact)
          record["source_reconstruction_exact"] = sourceExact
          record["source_reconstruction_differences"] = replayDifferences(sourceCold.outputs, published.outputs)
          record["input_binding_exact"] = inputExact
          record["generated_hit_required"] = generatedRequired
          record["cached_prompt_tokens"] = cachedCount
          let matchedPrefix = cachedCount > 0 && cachedCount < currentIDs.count
            ? Array(currentIDs.prefix(cachedCount)) : []
          record["cached_prefix_token_ids"] = matchedPrefix
          record["cached_prefix_digest"] = Digest.sha256(try JSONEncoder().encode(matchedPrefix))
          record["generated_tokens_reused"] = max(0, cachedCount - sourceIDs.count)
          record["generated_snapshot_identity_valid"] = identityValid
          record["selected_authored_token_prefix_valid"] = selectedPrefixValid
          record["cached_parent_row"] = metrics?.cachedRow as Any? ?? NSNull()
          record["cached_parent_batch_width"] = metrics?.cachedBatchWidth as Any? ?? NSNull()
          record["cached_parent_rows_authorizing_selected_prefix"] = selectedMatched.map { $0.row as Any? ?? NSNull() }
          record["source_rows_authorizing_actual_cached_prefix"] = sourceRowsAuthorizingPrefix
          record["cache_semantic_differences"] = semanticDifferences
          record["matched_generated_snapshots"] = try matched.map(snapshotObject)
          record["same_history_repeat_snapshots"] = try repeatSnapshots.map(snapshotObject)
          record["same_history_repeat_cache_passed"] = repeatCachePassed
          record["cold_output_exact_observed"] = coldExact
          record["cold_output_differences"] = replayDifferences(oracle.outputs, resumed.outputs)
          record["cold_mismatch_attribution"] = coldExact ? "not_observed"
            : "unattributed; actual forward history is retained, numerical causes are not profiled here"
          record["same_history_repeat_exact_observed"] = repeatExact
          record["same_history_repeat_differences"] = replayDifferences(resumed.outputs, repeated.outputs)
          record["cold_chunk_geometry_preserved"] = metrics?.preservesChunkBoundaries ?? false
          record["cache_semantic_controls_passed"] = semanticPassed
          record["required_comparison_controls_passed"] = requiredPassed
          record["numerical_comparisons_qualified"] = disposition == .passed
          record["independent_cross_history_cache_correctness_qualified"] = false
          record["cold_output_exactness_observed"] = sourceExact && coldExact && repeatExact
          record["cold_output_exactness_passed"] = sourceExact && coldExact && repeatExact
            && !controls.hasUnqualifiedNumericalComparisons
          record["resident_tensor_bytes"] = metrics?.residentTensorBytes as Any? ?? NSNull()
          record["resident_tensor_byte_limit"] = metrics?.residentTensorByteLimit as Any? ?? NSNull()
          record["status"] = disposition.rawValue
          try write(record, name + ".json")
          generatedSummaries.append(["name": name, "status": disposition.rawValue,
            "required_comparison_controls_passed": requiredPassed,
            "numerical_comparisons_qualified": disposition == .passed,
            "selected_row": selectedRow, "generated_prefix_eligible": generatedRequired,
            "generated_tokens_reused": max(0, cachedCount - sourceIDs.count),
            "cache_semantic_controls_passed": semanticPassed,
            "cold_output_exact_observed": coldExact, "same_history_repeat_exact_observed": repeatExact,
            "replay_history_contract_qualified": false])
          if disposition == .failed { generatedFailures.append(name) }
          if disposition == .qualificationOpen { generatedUnqualified.append(name) }
          receipt["generated_continuation_unqualified"] = generatedUnqualified
          receipt["generated_continuation_results"] = generatedSummaries
          receipt["generated_continuation_failures"] = generatedFailures
          try persist()
        } catch {
          await runner.join()
          record["status"] = "failed"; record["error"] = error.localizedDescription
          record["joined"] = true
          try write(record, name + ".json")
          generatedFailures.append(name)
          generatedSummaries.append(["name": name, "status": "failed", "selected_row": selectedRow,
            "error": error.localizedDescription, "joined": true])
          receipt["generated_continuation_results"] = generatedSummaries
          receipt["generated_continuation_failures"] = generatedFailures
          try check(name + ".execution", category: .provenance, passed: false,
            differences: [error.localizedDescription])
          if let boom = error as? BoomError, case .budget(_) = boom { throw error }
        }
      }
      try await generatedControl("writing-generated-single", runner: writing, sourceRaw: prompt,
        sourceChat: nil, sourceCold: base16, sourceSeeds: [42], selectedRow: 0,
        sourceColdFile: "writing-cold-oracle-owner-switch.json")
      let generatedBatchSource = try await trial("writing-generated-batch-source-cold", runner: writing,
        raw: prompt, chat: nil, tokens: 4096, owner: nil, seeds: [42, 43, 44], maxTokens: 16,
        scope: "three-row generated source control only; not the 256-output gate")
      for row in 0..<3 {
        try await generatedControl("writing-generated-selected-row-\(row)", runner: writing, sourceRaw: prompt,
          sourceChat: nil, sourceCold: generatedBatchSource, sourceSeeds: [42, 43, 44], selectedRow: row,
          sourceColdFile: "writing-generated-batch-source-cold.json")
      }
      let generatedChatSource = try await trial("consultation-generated-source-cold", runner: consultation,
        raw: nil, chat: plan, tokens: 4096, owner: nil, maxTokens: 16,
        scope: "consultation next-turn source control only; not the 256-output gate")
      try await generatedControl("consultation-generated-next-turn", runner: consultation, sourceRaw: nil,
        sourceChat: plan, sourceCold: generatedChatSource, sourceSeeds: [42], selectedRow: 0,
        sourceColdFile: "consultation-generated-source-cold.json")
      receipt["generated_continuation_controls"] = generatedFailures.isEmpty
        ? (generatedUnqualified.isEmpty ? "passed" : "qualification_open") : "failed"
      receipt["writing_generated_hit_observed"] = generatedSummaries.contains {
        ($0["name"] as? String)?.hasPrefix("writing-") == true
          && ($0["generated_tokens_reused"] as? Int ?? 0) > 0
      }
      receipt["consultation_generated_hit_observed"] = generatedSummaries.contains {
        ($0["name"] as? String)?.hasPrefix("consultation-") == true
          && ($0["generated_tokens_reused"] as? Int ?? 0) > 0
      }
      try persist()
      await writing.join(); await consultation.join()
      try memory.check(budget: budget)
      receipt["both_models_retained_through_all_controls"] = true
      receipt["memory"] = memory.observation(); receipt["memory_budget_passed"] = true
      receipt["joined"] = true; try persist()
      guard generatedFailures.isEmpty, controls.qualified else {
        receipt["status"] = controls.requiredControlsPassed && controls.hasUnqualifiedNumericalComparisons
          ? "qualification_open" : "failed"
        try persist()
        throw BoomError.invalid("Cache diagnostic remains unqualified; required failures and cross-history numerical observations are preserved. Independent native restoration and cold equivalence remain separate gates.")
      }
      receipt["joined"] = true; receipt["status"] = "passed"; try persist()
    } catch {
      await writingRunner?.join(); await consultationRunner?.join()
      receipt["memory"] = memory.observation(); receipt["joined"] = true
      if receipt["generated_continuation_controls"] as? String == "running" {
        receipt["generated_continuation_controls"] = "failed"
      }
      if receipt["status"] as? String != "qualification_open" { receipt["status"] = "failed" }
      receipt["error"] = error.localizedDescription
      try persist(); throw error
    }
  }
}

extension PromptCacheReuseSmoke {
  static func residentPrefixCount(snapshot: PromptPrefixCache.SnapshotObservation,
    current: [Int], localLayerCount: Int) -> Int {
    guard let coverage = snapshot.residentLocalCoverage,
      localLayerCount >= 0, coverage.count == localLayerCount,
      Set(coverage.map(\.layer)).count == localLayerCount else { return 0 }
    let lexical = commonPrefixCount(snapshot.tokenIDs, current,
      maximumCount: max(0, current.count - 1))
    guard lexical > 0 else { return 0 }
    var supported: [ClosedRange<Int>] = [1...lexical]
    for local in coverage {
      guard local.layer >= 0, local.window > 0, local.keep >= 0, local.keep < local.window else { return 0 }
      var spans: [ClosedRange<Int>] = []
      for interval in local.intervals {
        guard interval.lowerBound >= 0, interval.lowerBound < interval.upperBound,
          interval.upperBound <= snapshot.tokenIDs.count else { return 0 }
        if let previous = spans.last {
          guard interval.lowerBound >= previous.lowerBound else { return 0 }
          // Coalesce overlap/adjacency independently of the production helper.
          if interval.lowerBound <= previous.upperBound + 1 {
            spans[spans.count - 1] = previous.lowerBound...max(previous.upperBound, interval.upperBound - 1)
            continue
          }
        }
        spans.append(interval.lowerBound...(interval.upperBound - 1))
      }
      // These are inclusive *token-count* intervals, distinct from row ranges.
      var legal: [ClosedRange<Int>] = []
      let leadingEnd = spans.first.flatMap { $0.lowerBound == 0 ? $0.upperBound + 1 : nil } ?? 0
      let startupEnd = min(lexical, min(local.keep, leadingEnd))
      if startupEnd > 0 { legal.append(1...startupEnd) }
      if leadingEnd >= local.keep {
        for span in spans where span.upperBound + 1 > local.keep {
          let start = max(local.keep, span.lowerBound)
          let minimum: Int
          if start == local.keep { minimum = local.keep + 1 }
          else {
            let (bound, overflow) = start.addingReportingOverflow(local.window - local.keep)
            if overflow { continue }
            minimum = bound
          }
          let maximum = min(lexical, span.upperBound + 1)
          if minimum <= maximum { legal.append(minimum...maximum) }
        }
      }
      var intersection: [ClosedRange<Int>] = []
      for prior in supported {
        for range in legal {
          let lower = max(prior.lowerBound, range.lowerBound)
          let upper = min(prior.upperBound, range.upperBound)
          if lower <= upper { intersection.append(lower...upper) }
        }
      }
      supported = intersection
      if supported.isEmpty { return 0 }
    }
    return supported.map(\.upperBound).max() ?? 0
  }
}
