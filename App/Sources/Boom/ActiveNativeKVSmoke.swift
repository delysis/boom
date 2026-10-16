import BoomCore
import Foundation
import Metal
import MLX

/// Public, explicitly selected headless diagnostics. Timing uses normal runner
/// APIs, numeric uses their owned bodies; no workspace, GUI or journal is opened.
enum ActiveNativeKVSmoke {
  enum CaseName: String, Codable, Sendable, CaseIterable {
    case writingWidth1 = "writing_width1", writingWidth3 = "writing_width3"
    case consultationWidth1 = "consultation_width1", selectedFinishedRow = "selected_finished_row"
    var width: Int { self == .writingWidth3 || self == .selectedFinishedRow ? 3 : 1 }
    var timingCalls: Int { self == .selectedFinishedRow ? 2 : 4 }
  }
  enum Phase: String, Codable, Sendable { case timing, numeric }
  struct Input: Codable, Sendable {
    let prompt: String?
    let plan: ConsultationPlan?
    let prepared_token_ids: [Int]
    let prompt_digest: String
    let exact_lcp_with_source: Int?
    func validate(count: Int, vocabulary: Int) throws {
      guard (prompt != nil) != (plan != nil), prepared_token_ids.count == count, count > 0,
        prepared_token_ids.allSatisfy({ $0 >= 0 && $0 < vocabulary && $0 <= Int(Int32.max) }),
        prompt_digest == Digest.sha256(try JSONEncoder().encode(prepared_token_ids)) else {
        throw BoomError.invalid("The public prepared token vector, digest or input shape is invalid.")
      }
    }
  }
  struct Purpose: Codable, Sendable {
    let model: String
    let generation_policy: ModelGenerationPolicy
    let source: Input
    let one_token_edit: Input?
    let maximal_content_edit: Input?
    let suffix_512_edit: Input
    let selected_row_source: Input?
    let invariant_generation_trailer_token_ids: [Int]?
    let maximal_content_lcp: Int?
  }
  struct Fixture: Codable, Sendable {
    let schema: Int
    let purpose: String
    let runtime_revision: String
    let context_length: Int
    let max_output_tokens: Int
    let writing: Purpose
    let consultation: Purpose
    static func decode(_ data: Data) throws -> Fixture {
      guard data.count <= 4_194_304 else { throw BoomError.invalid("Oversized public full-context fixture.") }
      let value = try JSONDecoder().decode(Fixture.self, from: data)
      guard value.schema == 1, value.purpose == "active_native_16k_public_v1",
        value.runtime_revision == ModelPacks.runtimeRevision, value.context_length == 16_384,
        value.max_output_tokens == 256 else { throw BoomError.invalid("Wrong public full-context declaration.") }
      for (entry, chat) in [(value.writing, false), (value.consultation, true)] {
        guard entry.generation_policy.prefill == PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512),
          !entry.model.isEmpty else { throw BoomError.invalid("The full-context fixture requires fixed512 and a bound model.") }
        try entry.source.validate(count: 16_128, vocabulary: entry.generation_policy.vocabularySize)
        try entry.suffix_512_edit.validate(count: 16_128, vocabulary: entry.generation_policy.vocabularySize)
        guard lcp(entry.source.prepared_token_ids, entry.suffix_512_edit.prepared_token_ids) == 15_616,
          entry.suffix_512_edit.exact_lcp_with_source == 15_616 else { throw BoomError.invalid("Material edit must have exact LCP15616.") }
        if chat {
          guard entry.source.plan != nil, let edit = entry.maximal_content_edit,
            let trailer = entry.invariant_generation_trailer_token_ids, !trailer.isEmpty,
            let bound = entry.maximal_content_lcp, bound == 16_128 - trailer.count - 1,
            bound > 15_616, bound < 16_127 else { throw BoomError.invalid("Require the actual immutable consultation trailer/content bound.") }
          try edit.validate(count: 16_128, vocabulary: entry.generation_policy.vocabularySize)
          guard edit.plan != nil, edit.exact_lcp_with_source == bound,
            lcp(entry.source.prepared_token_ids, edit.prepared_token_ids) == bound,
            [entry.source, edit, entry.suffix_512_edit].allSatisfy({ Array($0.prepared_token_ids.suffix(trailer.count)) == trailer }) else {
            throw BoomError.invalid("Consultation content edit changed its fixed generation trailer or LCP.")
          }
        } else {
          guard entry.source.prompt != nil, let edit = entry.one_token_edit, let row = entry.selected_row_source else {
            throw BoomError.invalid("Require raw authored writing inputs and selected-row source.") }
          try edit.validate(count: 16_128, vocabulary: entry.generation_policy.vocabularySize)
          try row.validate(count: 15_872, vocabulary: entry.generation_policy.vocabularySize)
          guard edit.prompt != nil, row.prompt != nil, edit.exact_lcp_with_source == 16_127,
            lcp(entry.source.prepared_token_ids, edit.prepared_token_ids) == 16_127 else {
            throw BoomError.invalid("Writing final-token edit must have exact LCP16127.")
          }
        }
      }
      return value
    }
  }
  struct PrefillEvent: Codable, Sendable { let processed: Int; let total: Int; let outer_seconds: Double }
  final class MatrixCollector: @unchecked Sendable {
    private let lock = NSLock(); private var events: [ActiveNativeKVProbeHooks.MatrixEvent] = []
    nonisolated init() {}
    nonisolated func append(_ event: ActiveNativeKVProbeHooks.MatrixEvent) { lock.lock(); events.append(event); lock.unlock() }
    nonisolated func snapshot() -> [ActiveNativeKVProbeHooks.MatrixEvent] { lock.lock(); defer { lock.unlock() }; return events }
  }
  final class ClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock(), started: ContinuousClock.Instant
    private var first: [Int: Double] = [:], token: [Int: Int] = [:]
    private var prefill: [PrefillEvent] = []
    private var checkpoints = 0
    nonisolated init(started: ContinuousClock.Instant) { self.started = started }
    nonisolated func firstDelivered(row: Int, tokenID: Int) {
      recordFirst(row: row, tokenID: tokenID, seconds: started.duration(to: clock.now).timeInterval)
    }
    nonisolated func recordFirst(row: Int, tokenID: Int, seconds: Double) {
      lock.lock(); defer { lock.unlock() }
      if first[row] == nil { first[row] = seconds; token[row] = tokenID }
    }
    nonisolated func submitted(_ value: MLXGemmaRunner.PrefillProgress) {
      let event = PrefillEvent(processed: value.processedPositions, total: value.totalPositions,
        outer_seconds: started.duration(to: clock.now).timeInterval)
      lock.lock(); prefill.append(event); lock.unlock()
    }
    nonisolated func checkpoint() { lock.lock(); checkpoints += 1; lock.unlock() }
    nonisolated func snapshot() -> (first: [Int: Double], tokens: [Int: Int], prefill: [PrefillEvent], checkpoints: Int) {
      lock.lock(); defer { lock.unlock() }; return (first, token, prefill, checkpoints)
    }
  }
  struct MemoryRecord: Codable, Sendable {
    let current_process_bytes: UInt64
    let lifetime_peak_process_bytes: UInt64
    let mlx_active_bytes: Int
    let mlx_cache_bytes: Int
    let mlx_peak_bytes: Int
  }
  struct Trial: Codable, Sendable {
    let operation_name: String
    let input: Input
    let prepared_token_ids: [Int]
    let policy: ModelGenerationPolicy
    let seeds: [UInt64]
    let output_limit: Int
    let minimum_accepted_output_tokens: Int
    let owner: PromptCacheOwner?
    let before: [PromptPrefixCache.SnapshotObservation]
    let independent_maximum_prefix: Int
    let memory_before: MemoryRecord
    var status = "running"
    var outputs: [MLXGemmaRunner.Output] = []
    var matrix_events: [ActiveNativeKVProbeHooks.MatrixEvent] = []
    var submitted_prefill: [PrefillEvent] = []
    var checkpoint_calls = 0
    var outer_first_delivered_token_seconds: [Int: Double] = [:]
    var first_delivered_token_ids: [Int: Int] = [:]
    var api_through_joined_seconds: Double? = nil
    var after: [PromptPrefixCache.SnapshotObservation] = []
    var memory_after: MemoryRecord? = nil
    var operation_joined = false
    var differences: [String] = []
    var error: String? = nil
  }
  struct NumericRequest: Sendable { let policy: ModelGenerationPolicy; let trials: [Trial]; let selectedRow: Int? }
  struct NumericSubcall: Encodable, Sendable {
    let name: String
    let source_history_matches_timing: Bool
    let outputs: [MLXGemmaRunner.Output]
    let matrix_events: [ActiveNativeKVProbeHooks.MatrixEvent]
    let comparison: ActiveNativeKVNumericalObserver.Result
  }
  struct NumericResult: Encodable, Sendable { let owned_subcalls: [NumericSubcall]; let exact: Bool }
  struct Receipt: Codable, Sendable {
    var schema = 1
    var `protocol` = "active_native_kv_public_v1"
    let case_name: CaseName
    let phase: Phase
    let source_inventory_sha256: String
    let fixture_sha256: String
    let runtime_revision: String
    let writing_model_identity: String
    let consultation_model_identity: String
    let application_byte_limit: UInt64
    let resident_staging_byte_limit: UInt64
    var status = "running"
    var operation_joined = false
    var normal_operation_count = 0
    var declared_numeric_operations = 0
    var numeric_owned_subcall_count: Int? = nil
    var fixture_loaded_token_vectors_exact = false
    var trials: [Trial] = []
    var selected_successor_input: Input? = nil
    var selected_row: Int? = nil
    var timing_receipt_sha256: String? = nil
    var same_history_numerical_exact: Bool? = nil
    var differences: [String] = []
    var error: String? = nil
    var release_qualified = false
    var replay_qualified = false
    var automatic_retries = false
    var profiler_used = false
    var mlx_runtime_env: [String: String] = [:]
    var backend_effective_buffer_limits_observed = false
    var per_position_discarded_prefill_logits_observed = false
    var cold_vs_cached_token_bits_equal: [Bool]? = nil
    var cold_vs_cached_equality_scope = "observational different forward histories; never a seeded Replay grant"
  }
  nonisolated static func lcp(_ a: [Int], _ b: [Int]) -> Int { zip(a,b).prefix { $0 == $1 }.count }
  nonisolated static func write<T: Encodable>(_ value: T, _ url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  static func memory() -> MemoryRecord {
    let value = ModelResidency.memoryAccounting()
    return MemoryRecord(current_process_bytes: value.current, lifetime_peak_process_bytes: value.peak,
      mlx_active_bytes: Memory.activeMemory, mlx_cache_bytes: Memory.cacheMemory, mlx_peak_bytes: Memory.peakMemory)
  }
  // Independent metadata-only coverage reducer; deliberately does not call the
  // cache's own maximumSupportedPrefix() or hydration implementation.
  nonisolated static func maximumPrefix(_ snapshots: [PromptPrefixCache.SnapshotObservation],
    ids: [Int], namespace: UUID?) -> Int {
    guard let namespace, ids.count > 1 else { return 0 }
    func covers(_ lower: Int, _ upper: Int, _ ranges: [PromptPrefixCache.ResidentInterval]) -> Bool {
      if lower >= upper { return true }
      var cursor = lower
      for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if range.upperBound <= cursor { continue }
        if range.lowerBound > cursor { return false }
        cursor = max(cursor, range.upperBound)
        if cursor >= upper { return true }
      }; return false
    }
    var best = 0
    for row in snapshots where row.namespace == namespace {
      guard let local = row.residentLocalCoverage, !local.isEmpty,
        let receipt = row.nativeRowReceipt, receipt.processedTokenCount >= row.tokenIDs.count,
        receipt.submittedTokenCount >= row.tokenIDs.count, receipt.completedTokenCount >= row.tokenIDs.count else { continue }
      let cap = min(lcp(ids, row.tokenIDs), ids.count - 1)
      let candidates = Set([cap] + local.flatMap { $0.intervals.map { min(cap, $0.upperBound) } })
      for count in candidates.sorted(by: >) where count > best {
        if local.allSatisfy({ entry in entry.keep >= 0 && entry.window > entry.keep
          && covers(0, min(entry.keep, count), entry.intervals)
          && covers(max(min(entry.keep, count), count - (entry.window - entry.keep)), count, entry.intervals) }) {
          best = count; break
        }
      }
    }; return best
  }
  nonisolated static func uniqueSelectedRow(_ snapshots: [PromptPrefixCache.SnapshotObservation],
    ids: [Int], namespace: UUID, originalPrompt: Int) -> (row: Int, prefix: Int)? {
    let maximum = maximumPrefix(snapshots, ids: ids, namespace: namespace)
    guard maximum > originalPrompt else { return nil }
    let matching = snapshots.filter { row in
      row.namespace == namespace && maximumPrefix([row], ids: ids, namespace: namespace) == maximum
    }
    let rows = Set(matching.compactMap(\.row))
    guard rows.count == 1, let row = rows.first else { return nil }
    return (row, maximum)
  }
  // Reservation and executed tokens are separate: ordinary EOS/control stops
  // may finish early. Missing/mismatched stop metadata cannot satisfy this gate.
  nonisolated static func stoppingGate(reservation: Int, minimum: Int,
    outputTokenCount: Int?, tokenIDCount: Int?, hasText: Bool?, reason: String?,
    endedByEOS: Bool?, stopTokenID: Int?, eosTokenIDs: [Int], controlTokenIDs: [Int]) -> Bool {
    guard reservation > 0, minimum > 0, minimum <= reservation,
      let count = outputTokenCount, count >= minimum, count <= reservation,
      tokenIDCount == count, hasText == true, let reason, let endedByEOS else { return false }
    switch reason {
    case "output_limit": return count == reservation && !endedByEOS && stopTokenID == nil
    case "eos":
      guard let stopTokenID else { return false }
      return endedByEOS && eosTokenIDs.contains(stopTokenID) && controlTokenIDs.contains(stopTokenID)
    case "model_control":
      guard let stopTokenID else { return false }
      return endedByEOS && controlTokenIDs.contains(stopTokenID) && !eosTokenIDs.contains(stopTokenID)
    default: return false
    }
  }
  static func runTrial(name: String, input: Input, seeds: [UInt64], output: Int,
    owner: PromptCacheOwner?, purpose: Purpose, runner: MLXGemmaRunner, directory: URL,
    minimumOutputTokens: Int = 16) async throws -> Trial {
    let before = await runner.diagnosticCacheSnapshots()
    let maximum = maximumPrefix(before, ids: input.prepared_token_ids, namespace: owner?.namespace)
    var trial = Trial(operation_name: name, input: input, prepared_token_ids: input.prepared_token_ids,
      policy: purpose.generation_policy, seeds: seeds, output_limit: output,
      minimum_accepted_output_tokens: minimumOutputTokens, owner: owner,
      before: before, independent_maximum_prefix: maximum, memory_before: memory())
    let url = directory.appendingPathComponent(name + ".json")
    try write(trial, url) // Disk is outside the declared outer request timer.
    let clock = ContinuousClock(), entered = clock.now
    let probe = ClockProbe(started: entered), matrices = MatrixCollector(), flag = CancellationFlag()
    let hooks = ActiveNativeKVProbeHooks(firstDelivered: { probe.firstDelivered(row: $0, tokenID: $1) },
      matrix: { matrices.append($0) })
    do {
      if let prompt = input.prompt {
        trial.outputs = try await runner.runBatch(rawPrompt: prompt, maxTokens: output,
          settings: ProductCore.sampling(.standard), seeds: seeds, flag: flag,
          cacheOwner: owner, executionPolicy: purpose.generation_policy, diagnostic: hooks,
          onPrefill: { probe.submitted($0) }, onCheckpoint: { _ in probe.checkpoint() })
      } else if let plan = input.plan, seeds.count == 1 {
        trial.outputs = [try await runner.run(plan: plan, images: [], maxTokens: output, seed: seeds[0],
          flag: flag, cacheOwner: owner, executionPolicy: purpose.generation_policy, diagnostic: hooks,
          onPrefill: { probe.submitted($0) }, onCheckpoint: { _, _, _ in probe.checkpoint() }, onText: { _ in })]
      } else { throw BoomError.invalid("Missing actual prepared input or declared row width.") }
      await runner.join(); trial.operation_joined = true
      trial.api_through_joined_seconds = entered.duration(to: clock.now).timeInterval
      let observed = probe.snapshot()
      trial.outer_first_delivered_token_seconds = observed.first
      trial.first_delivered_token_ids = observed.tokens; trial.submitted_prefill = observed.prefill
      trial.checkpoint_calls = observed.checkpoints; trial.matrix_events = matrices.snapshot()
      trial.after = await runner.diagnosticCacheSnapshots(); trial.memory_after = memory()
      if trial.outputs.count != seeds.count || observed.first.count != seeds.count { trial.differences.append("missing_actual_row_or_first_delivered_event") }
      for (row, result) in trial.outputs.enumerated() {
        if result.promptTokens != input.prepared_token_ids.count || result.promptDigest != input.prompt_digest { trial.differences.append("actual_prepared_vector_receipt") }
        if !stoppingGate(reservation: output, minimum: minimumOutputTokens,
          outputTokenCount: result.outputTokens, tokenIDCount: result.tokenIDs.count,
          hasText: !result.text.isEmpty, reason: result.stopReason, endedByEOS: result.endedByEOS,
          stopTokenID: result.stopTokenID, eosTokenIDs: purpose.generation_policy.eosTokenIDs,
          controlTokenIDs: purpose.generation_policy.controlTokenIDs) {
          trial.differences.append("meaningful_decoding_or_ordinary_stop_not_observed")
        }
        if observed.tokens[row] != result.tokenIDs.first { trial.differences.append("first_delivered_event_not_actual_output") }
        if let owner {
          guard let cache = result.prefillCacheMetrics else { trial.differences.append("missing_active_cache_metrics"); continue }
          if cache.algorithm != PromptPrefixCache.activeAlgorithm || cache.cachedPromptTokens != maximum
            || cache.cachedPromptTokens + cache.prefilledPromptTokens != input.prepared_token_ids.count { trial.differences.append("maximal_actual_active_native_prefix") }
          if cache.residentTensorByteLimit != 1 << 30 || (cache.residentTensorBytesAfter ?? UInt64.max) > 1 << 30
            || cache.nativeReadmission?.denied == true { trial.differences.append("native_or_staging_admission") }
          if name != "source", name != "selected_row_source", maximum == 0 { trial.differences.append("compatible_context_reuse_missing") }
          _ = owner
        } else if result.executionOrigin?.cachedPromptTokens != 0 { trial.differences.append("force_cold_was_not_cold") }
      }
      try ModelResidency.check()
      if let lexical = input.exact_lcp_with_source, owner != nil, maximum != lexical {
        trial.differences.append("declared_edit_prefix_not_fully_resident")
      }
      trial.status = trial.differences.isEmpty ? "passed" : "incomplete"
      try write(trial, url); return trial
    } catch {
      flag.cancel(); await runner.join(); trial.operation_joined = true
      trial.api_through_joined_seconds = entered.duration(to: clock.now).timeInterval
      let observed = probe.snapshot(); trial.outer_first_delivered_token_seconds = observed.first
      trial.first_delivered_token_ids = observed.tokens; trial.submitted_prefill = observed.prefill
      trial.matrix_events = matrices.snapshot(); trial.checkpoint_calls = observed.checkpoints
      trial.after = await runner.diagnosticCacheSnapshots(); trial.memory_after = memory()
      trial.status = "failed"; trial.error = String(describing: error); try write(trial, url); throw error
    }
  }
  static func verifyInputs(_ inputs: [Input], runner: MLXGemmaRunner) async throws {
    for input in inputs {
      let actual: [Int]
      if let text = input.prompt { actual = await runner.diagnosticTokenIDs(text) }
      else if let plan = input.plan { actual = try await runner.diagnosticTokenIDs(plan) }
      else { throw BoomError.invalid("Missing captured source.") }
      guard actual == input.prepared_token_ids else { throw BoomError.stale("Actual loaded tokenizer/template changed the complete public vector.") }
    }
  }
  nonisolated static func sameInput(_ a: Input, _ b: Input) -> Bool {
    guard a.prepared_token_ids == b.prepared_token_ids, a.prompt_digest == b.prompt_digest,
      a.prompt == b.prompt, a.exact_lcp_with_source == b.exact_lcp_with_source else { return false }
    if let x = a.plan, let y = b.plan {
      return x.rawPrompt == y.rawPrompt && x.messages.count == y.messages.count
        && zip(x.messages, y.messages).allSatisfy { $0.role == $1.role && $0.content == $1.content }
    }
    return a.plan == nil && b.plan == nil
  }
  nonisolated static func validateClosedHistory(_ history: Receipt, purpose: Purpose,
    sourceInput: Input) throws -> [Trial] {
    let selected = history.case_name == .selectedFinishedRow
    let names = selected ? ["selected_row_source", "selected_successor"]
      : ["source", "final_content_edit", "material_512_edit", "force_cold_material"]
    let seeds: [UInt64] = history.case_name.width == 3 ? [42,2026,8675309] : [42]
    guard history.trials.map(\.operation_name) == names, let namespace = history.trials.first?.owner?.namespace,
      sameInput(history.trials[0].input, sourceInput),
      history.trials.allSatisfy({ $0.operation_joined && $0.status == "passed"
        && $0.differences.isEmpty && $0.error == nil && $0.prepared_token_ids == $0.input.prepared_token_ids
        && $0.policy == purpose.generation_policy && !$0.outputs.isEmpty }) else {
      throw BoomError.stale("The immutable history lacks its exact declared order, source, policy or joined workload.")
    }
    for (index, trial) in history.trials.enumerated() {
      let successor = selected && index == 1
      guard trial.seeds == (successor ? [42] : seeds), trial.output_limit == (successor ? 16 : 256),
        trial.minimum_accepted_output_tokens == (selected ? 1 : 16),
        trial.outputs.count == trial.seeds.count,
        trial.outputs.allSatisfy({ stoppingGate(reservation: trial.output_limit,
          minimum: trial.minimum_accepted_output_tokens, outputTokenCount: $0.outputTokens,
          tokenIDCount: $0.tokenIDs.count, hasText: !$0.text.isEmpty, reason: $0.stopReason,
          endedByEOS: $0.endedByEOS, stopTokenID: $0.stopTokenID,
          eosTokenIDs: purpose.generation_policy.eosTokenIDs,
          controlTokenIDs: purpose.generation_policy.controlTokenIDs) }) else {
        throw BoomError.invalid("Timing row/seed/output reservation or ordinary stopping gate changed.") }

      if index == names.count - 1 && !selected {
        guard trial.owner == nil, sameInput(trial.input, purpose.suffix_512_edit) else { throw BoomError.stale("Force-cold timing query changed.") }
      } else {
        guard trial.owner?.namespace == namespace else { throw BoomError.stale("History crossed owner namespace.") }
      }
    }
    if selected {
      guard let row = history.selected_row, (0..<3).contains(row), let successor = history.selected_successor_input,
        sameInput(history.trials[1].input, successor),
        let prompt = sourceInput.prompt, successor.prompt == prompt + history.trials[0].outputs[row].text,
        successor.plan == nil, successor.prepared_token_ids.count <= 16_128,
        uniqueSelectedRow(history.trials[0].after, ids: successor.prepared_token_ids,
          namespace: namespace, originalPrompt: 15_872)?.row == row else {
        throw BoomError.stale("Selected successor is not the actual unique processed completion row.")
      }
      return history.trials
    }
    let small = history.case_name == .consultationWidth1 ? purpose.maximal_content_edit! : purpose.one_token_edit!
    guard sameInput(history.trials[1].input, small), sameInput(history.trials[2].input, purpose.suffix_512_edit) else {
      throw BoomError.stale("Immutable compatible edit inputs changed.")
    }
    return Array(history.trials.prefix(3))
  }
  static func run(writingPack: URL, consultationPack: URL, fixtureURL: URL,
    caseName: CaseName, phase: Phase, historyURL: URL?, historySHA: String?, evidence: URL) async throws {
    let bytes = try RegularFile(fixtureURL, limit: 4_194_304).data(), fixture = try Fixture.decode(bytes)
    let source = Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? ""
    guard source.count == 64 else { throw BoomError.invalid("The diagnostic requires the signed source inventory binding.") }
    var receipt = Receipt(case_name: caseName, phase: phase, source_inventory_sha256: source,
      fixture_sha256: Digest.sha256(bytes), runtime_revision: ModelPacks.runtimeRevision,
      writing_model_identity: fixture.writing.model, consultation_model_identity: fixture.consultation.model,
      application_byte_limit: 24 << 30, resident_staging_byte_limit: 1 << 30)
    let url = evidence.appendingPathComponent("receipt.json")
    let environment = ProcessInfo.processInfo.environment
    for name in ["MLX_MAX_OPS_PER_BUFFER", "MLX_MAX_MB_PER_BUFFER"] {
      receipt.mlx_runtime_env[name] = environment[name] ?? "unset"
    }
    try write(receipt, url)
    var retainedRunners: [MLXGemmaRunner] = []
    do {
      guard try ModelResidency.limits().applicationBytes == receipt.application_byte_limit else {
        throw BoomError.budget("This preregistered diagnostic requires the actual24GiB application limit.")
      }
      let writingAdmission = try ModelPacks.admission(writingPack, purpose: .writing)
      let consultationAdmission = try ModelPacks.admission(consultationPack, purpose: .consultation)
      guard writingAdmission.identity == fixture.writing.model, consultationAdmission.identity == fixture.consultation.model else {
        throw BoomError.stale("Registered paired model identities changed.") }
      for (name, admission, purpose) in [("writing", writingAdmission, ModelPurpose.writing),
        ("consultation", consultationAdmission, ModelPurpose.consultation)] {
        let manifest = try ModelPacks.evidenceManifest(admission, purpose: purpose)
        try manifest.write(to: evidence.appendingPathComponent(name + "-model-manifest.json"))
      }
      let writing = try await MLXGemmaRunner.load(admission: writingAdmission); retainedRunners.append(writing)
      try ModelResidency.admit(weightBytes: consultationAdmission.weightBytes, residentWeights: writingAdmission.weightBytes)
      let consultation = try await MLXGemmaRunner.load(admission: consultationAdmission); retainedRunners.append(consultation)
      let isChat = caseName == .consultationWidth1
      let purpose = isChat ? fixture.consultation : fixture.writing
      let runner = isChat ? consultation : writing
      let small = isChat ? purpose.maximal_content_edit! : purpose.one_token_edit!
      let sourceInput = caseName == .selectedFinishedRow ? purpose.selected_row_source! : purpose.source
      try await verifyInputs([fixture.writing.source, fixture.writing.one_token_edit!, fixture.writing.suffix_512_edit,
        fixture.writing.selected_row_source!], runner: writing)
      try await verifyInputs([fixture.consultation.source, fixture.consultation.maximal_content_edit!,
        fixture.consultation.suffix_512_edit], runner: consultation)
      receipt.fixture_loaded_token_vectors_exact = true
      if phase == .timing {
        guard historyURL == nil, historySHA == nil else { throw BoomError.invalid("Timing cannot consume a numerical history.") }
        let namespace = UUID(), owner = PromptCacheOwner(namespace: namespace, entity: UUID(), route: isChat ? .consultation : .writing)
        let seeds: [UInt64] = caseName.width == 3 ? [42,2026,8675309] : [42]
        let sourceTrial = try await runTrial(name: caseName == .selectedFinishedRow ? "selected_row_source" : "source",
          input: sourceInput, seeds: seeds, output: 256, owner: owner, purpose: purpose, runner: runner,
          directory: evidence, minimumOutputTokens: caseName == .selectedFinishedRow ? 1 : 16)
        receipt.trials.append(sourceTrial); receipt.normal_operation_count += 1; try write(receipt, url)
        if caseName == .selectedFinishedRow {
          guard let raw = sourceInput.prompt else { throw BoomError.invalid("Selected completion requires raw authored writing source.") }
          var selected: (Input, Int)?
          for (row, output) in sourceTrial.outputs.enumerated() {
            let prompt = raw + output.text, ids = await runner.diagnosticTokenIDs(prompt)
            if ids.count > 16_128 || ids.count <= sourceInput.prepared_token_ids.count { continue }
            if let match = uniqueSelectedRow(sourceTrial.after, ids: ids, namespace: namespace,
              originalPrompt: sourceInput.prepared_token_ids.count), match.row == row {
              let input = Input(prompt: prompt, plan: nil, prepared_token_ids: ids,
                prompt_digest: Digest.sha256(try JSONEncoder().encode(ids)), exact_lcp_with_source: nil)
              selected = (input, row); break
            }
          }
          guard let selected else {
            receipt.status = "incomplete"
            receipt.differences.append("selected_completion_has_no_unique_processed_resident_prefix")
            throw BoomError.unavailable("No actual selected completion has a unique processed resident prefix; no substitute.")
          }
          receipt.selected_successor_input = selected.0; receipt.selected_row = selected.1; try write(receipt, url)
          let next = try await runTrial(name: "selected_successor", input: selected.0, seeds: [42], output: 16,
            owner: owner, purpose: purpose, runner: runner, directory: evidence, minimumOutputTokens: 1)
          receipt.trials.append(next); receipt.normal_operation_count += 1
        } else {
          for (name, input, chosenOwner) in [("final_content_edit", small, Optional(owner)),
            ("material_512_edit", purpose.suffix_512_edit, Optional(owner)),
            ("force_cold_material", purpose.suffix_512_edit, nil)] {
            let trial = try await runTrial(name: name, input: input, seeds: seeds, output: 256,
              owner: chosenOwner, purpose: purpose, runner: runner, directory: evidence)
            receipt.trials.append(trial); receipt.normal_operation_count += 1; try write(receipt, url)
          }
        }
        if caseName != .selectedFinishedRow, receipt.trials.count == 4 {
          receipt.cold_vs_cached_token_bits_equal = zip(receipt.trials[2].outputs, receipt.trials[3].outputs).map {
            $0.tokenIDs == $1.tokenIDs && $0.stopTokenID == $1.stopTokenID && $0.stopReason == $1.stopReason
          }
        }
        receipt.differences = receipt.trials.flatMap(\.differences)
        receipt.status = receipt.trials.count == caseName.timingCalls && receipt.differences.isEmpty ? "passed" : "incomplete"
      } else {
        guard let historyURL, let historySHA, historySHA.count == 64 else { throw BoomError.invalid("Numeric requires exactly one immutable timing history binding.") }
        let data = try RegularFile(historyURL, limit: 16_777_216).data()
        guard Digest.sha256(data) == historySHA else { throw BoomError.stale("Timing receipt changed before numerical replay.") }
        let history = try JSONDecoder().decode(Receipt.self, from: data)
        guard history.schema == 1, history.protocol == receipt.protocol, history.phase == .timing,
          history.case_name == caseName, history.status == "passed", history.operation_joined,
          history.source_inventory_sha256 == source, history.fixture_sha256 == receipt.fixture_sha256,
          history.runtime_revision == receipt.runtime_revision, history.writing_model_identity == receipt.writing_model_identity,
          history.consultation_model_identity == receipt.consultation_model_identity,
          history.fixture_loaded_token_vectors_exact, history.normal_operation_count == caseName.timingCalls,
          history.trials.count == caseName.timingCalls, !history.release_qualified, !history.replay_qualified else {
          throw BoomError.stale("The complete declared timing history does not bind this exact source/models/fixture/case.") }
        let trials = try validateClosedHistory(history, purpose: purpose, sourceInput: sourceInput)
        try await verifyInputs(trials.map(\.input), runner: runner)
        receipt.timing_receipt_sha256 = historySHA; receipt.declared_numeric_operations = 1
        receipt.selected_row = history.selected_row; receipt.selected_successor_input = history.selected_successor_input
        try write(receipt, url)
        let result = try await runner.diagnosticActiveNativeKVParity(NumericRequest(policy: purpose.generation_policy,
          trials: trials, selectedRow: history.selected_row), evidence: evidence)
        await runner.join()
        receipt.numeric_owned_subcall_count = result.owned_subcalls.count
        receipt.same_history_numerical_exact = result.exact
        receipt.differences = result.owned_subcalls.flatMap { $0.comparison.differences }
        if !result.exact { receipt.differences.append("same_history_numerical_restoration") }
        try write(result, evidence.appendingPathComponent("numeric-result.json"))
        guard try RegularFile(historyURL, limit: 16_777_216).data() == data else { throw BoomError.stale("Timing history changed during numerical replay.") }
        receipt.status = result.exact ? "passed" : "failed"
      }
      for runner in retainedRunners { await runner.join() }
      try ModelResidency.check(); receipt.operation_joined = true
      try write(receipt, url)
      if receipt.status != "passed" { throw BoomError.unavailable("The declared full-context diagnostic remains incomplete or differs; receipts preserved.") }
    } catch {
      for runner in retainedRunners { await runner.join() }
      receipt.operation_joined = true
      if receipt.status == "running" { receipt.status = "failed" }
      receipt.error = String(describing: error); try write(receipt, url); throw error
    }
    withExtendedLifetime(retainedRunners) {}
  }
}
