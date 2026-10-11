import BoomCore
import Foundation
import Metal
import MLX
import MLXLMCommon

/// Explicit public native-value diagnostic. It never runs ordinary UI or replay.
enum NeuralPrefixParitySmoke {
  enum Kind: String, Codable, Hashable, Sendable { case consultationInterior, writingLateDivergence }
  struct Reference: Codable, Sendable { let path: String; let sha256: String }
  struct Declaration: Codable, Sendable {
    let kind: Kind
    let namespace: UUID
    let sharedSource: Reference
    let anchorSource: Reference?
    let currentQuery: Reference
    let sharedProcessedDecodeTokens: Int
    let sharedDeliveredLedgerTokens: Int
    let sharedWidth: Int
    let anchorCachedPrefix: Int?
    let sourceNativeBoundary: Int
    let cachedPrefix: Int
    let coldNativeBoundary: Int
    let warmSuffixPartitions: [Int]
    let decodeControlTokens: Int
    let seed: UInt64
  }
  struct Fixture: Codable, Sendable {
    let schema: Int
    let scope: String
    let runtimeRevision: String
    let originatingSourceInventory: String
    let declarations: [Declaration]
  }
  struct CapturedOutput: Codable, Sendable {
    let token_ids: [Int]
    let stop_reason: String
    let stop_token_id: Int?
    let prompt_digest: String
    let prompt_tokens: Int
  }
  struct CapturedInput: Codable, Sendable {
    let name: String
    let model: String
    let prompt: String?
    let plan: ConsultationPlan?
    let prepared_token_ids: [Int]
    let generation_policy: ModelGenerationPolicy
    let settings: SamplingSettings
    let outputs: [CapturedOutput]
    let status: String
  }
  struct Request: Sendable {
    let declaration: Declaration
    let shared: CapturedInput
    let anchor: CapturedInput?
    let query: CapturedInput
    var inputs: [CapturedInput] { [shared] + (anchor.map { [$0] } ?? []) + [query] }
    var name: String { declaration.kind.rawValue }
  }
  struct Samples: Codable, Sendable {
    let sampledTokenIDs: [Int]
    let emittedTokenIDs: [Int]
    let stopReason: String
    let stopTokenID: Int?
    let processedDecodeTokens: Int
  }
  struct PairSummary: Codable, Sendable {
    let name: String
    let initialState: NativePrefixParityProbe.StateComparison
    let allLogitBitsEqual: Bool
    let sampledReferenceTokenIDs: [Int]
    let sampledCandidateTokenIDs: [Int]
    let firstSampleDifferenceZeroBased: Int?
    let eitherBranchStoppedByControl: Bool
    let method: String
    var allSamplesEqual: Bool { sampledReferenceTokenIDs == sampledCandidateTokenIDs }
  }
  struct CaseSummary: Codable, Sendable {
    let name: String
    let modelIdentity: String
    let sourceBoundary: Int
    let coldBoundary: Int
    let prefix: Int
    let actualWarmObservation: PromptPrefixCache.Observation
    let restoration: PairSummary
    let coldVsRetained: PairSummary
    let naturalFullQueryColdSamples: Samples
    let fullQueryColdPromptHistory: [NativePrefixParityProbe.TokenRange]
    let releaseQualified: Bool
    var sameHistoryRestorationExact: Bool {
      restoration.initialState.allKVBitsEqual && restoration.initialState.allMasksEqual
        && restoration.allLogitBitsEqual && restoration.allSamplesEqual
    }
    var coldHistoryEquivalenceObserved: Bool {
      coldVsRetained.initialState.allKVBitsEqual && coldVsRetained.initialState.allMasksEqual
        && coldVsRetained.allLogitBitsEqual && coldVsRetained.allSamplesEqual
    }
  }

  static func decodeFixture(_ data: Data) throws -> Fixture {
    guard data.count <= 1_048_576 else { throw BoomError.invalid("Oversized parity manifest.") }
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    guard fixture.schema == 1, fixture.scope == "public_completed_trial_inputs_v1",
      fixture.runtimeRevision == ModelPacks.runtimeRevision,
      fixture.originatingSourceInventory.count == 64, fixture.declarations.count == 2,
      Set(fixture.declarations.map(\.kind)) == [.consultationInterior, .writingLateDivergence] else {
      throw BoomError.invalid("Require the two registered public parity controls and exact runtime.")
    }
    for d in fixture.declarations {
      guard d.seed == 42, d.decodeControlTokens == 16,
        d.sharedSource.path.hasPrefix("/"), d.currentQuery.path.hasPrefix("/"),
        d.sharedSource.sha256.count == 64, d.currentQuery.sha256.count == 64 else {
        throw BoomError.invalid("Require bounded seeded controls and source-bound public receipts.")
      }
      switch d.kind {
      case .consultationInterior:
        guard d.anchorSource == nil, d.anchorCachedPrefix == nil, d.sharedWidth == 1,
          d.sharedProcessedDecodeTokens == 16, d.sharedDeliveredLedgerTokens == 16,
          d.sourceNativeBoundary == 4095, d.cachedPrefix == 4092, d.coldNativeBoundary == 4096,
          d.warmSuffixPartitions == [36, 1] else {
          throw BoomError.invalid("Changed consultation parity scope.")
        }
      case .writingLateDivergence:
        guard let anchor = d.anchorSource, anchor.path.hasPrefix("/"), anchor.sha256.count == 64,
          d.sharedWidth == 3, d.sharedProcessedDecodeTokens == 85, d.sharedDeliveredLedgerTokens == 86,
          d.anchorCachedPrefix == 4181, d.sourceNativeBoundary == 4352,
          d.cachedPrefix == 4349, d.coldNativeBoundary == 4352, d.warmSuffixPartitions == [3, 1] else {
          throw BoomError.invalid("Changed mixed writing parity scope.")
        }
      }
    }
    return fixture
  }

  static func captured(_ reference: Reference) throws -> CapturedInput {
    let bytes = try RegularFile(URL(fileURLWithPath: reference.path), limit: 4_194_304).data()
    guard Digest.sha256(bytes) == reference.sha256 else { throw BoomError.stale("A declared public receipt changed.") }
    let input = try JSONDecoder().decode(CapturedInput.self, from: bytes)
    let promptDigest = Digest.sha256(try JSONEncoder().encode(input.prepared_token_ids))
    guard input.status == "passed", !input.prepared_token_ids.isEmpty,
      input.prepared_token_ids.count <= 4_353, !input.outputs.isEmpty,
      input.generation_policy.prefill == PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512),
      input.outputs.allSatisfy({ $0.prompt_tokens == input.prepared_token_ids.count
        && $0.prompt_digest == promptDigest }) else {
      throw BoomError.invalid("Require complete public inputs with their exact prompt and fixed policy.")
    }
    return input
  }

  static func request(_ declaration: Declaration) throws -> Request {
    let shared = try captured(declaration.sharedSource)
    let anchor = try declaration.anchorSource.map(captured)
    let query = try captured(declaration.currentQuery)
    let request = Request(declaration: declaration, shared: shared, anchor: anchor, query: query)
    guard shared.prepared_token_ids.count == 4096, shared.outputs.count == declaration.sharedWidth,
      query.outputs.count == 1, query.outputs[0].token_ids.count == 16,
      request.inputs.allSatisfy({ $0.model == shared.model && $0.settings == query.settings
        && $0.generation_policy == query.generation_policy }),
      shared.outputs.allSatisfy({ $0.token_ids.count >= declaration.sharedDeliveredLedgerTokens }) else {
      throw BoomError.invalid("Public source, rows, policies or sampling settings changed.")
    }
    switch declaration.kind {
    case .consultationInterior:
      guard query.prepared_token_ids.count == 4129,
        request.inputs.allSatisfy({ $0.prompt == nil && $0.plan != nil }),
        query.prepared_token_ids.prefix(4092).elementsEqual(shared.prepared_token_ids.prefix(4092)) else {
        throw BoomError.invalid("The public next-turn integer prefix is not the declared consultation.")
      }
    case .writingLateDivergence:
      guard let anchor, anchor.prepared_token_ids.count == 4353, anchor.outputs.count == 1,
        anchor.outputs[0].token_ids.count == 16, query.prepared_token_ids.count == 4353,
        request.inputs.allSatisfy({ $0.prompt != nil && $0.plan == nil }),
        anchor.prepared_token_ids.prefix(4181).elementsEqual(shared.prepared_token_ids
          + Array(shared.outputs[2].token_ids.prefix(85))),
        query.prepared_token_ids.prefix(4349).elementsEqual(anchor.prepared_token_ids.prefix(4349)) else {
        throw BoomError.invalid("The public width-three row/late-anchor integer prefixes changed.")
      }
    }
    return request
  }

  private static func write<T: Encodable>(_ value: T, _ name: String, _ evidence: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: evidence.appendingPathComponent(name), options: .atomic)
  }
  private static func object(_ value: [String: Any], _ name: String, _ evidence: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent(name), options: .atomic)
  }
  static func nativeBases(_ caches: [any KVCache]) -> [any KVCache] {
    // Transparent adapter access only. The independent oracle does not use the
    // storage helper's layout, resident ranges, spans or hydration implementation.
    caches.map(PrefixKVStorage.unwrap)
  }
  private struct Prepared {
    let session: PromptPrefixCache.Session
    let logits: MLXArray
    let snapshot: NativePrefixParityProbe.Snapshot?
    let ranges: [NativePrefixParityProbe.TokenRange]
  }

  // Mirrors pinned Gemma text-only prepare, in this explicit diagnostic only.
  // Capture may occur before a later prefill chunk, not only at its final extent.
  private static func prepare(model: any LanguageModel, session: PromptPrefixCache.Session,
    captureAt: Int?, label: String, flag: CancellationFlag, evidence: URL) throws -> Prepared {
    let ids = session.input.text.tokens.asArray(Int.self)
    let y = MLXArray(ids.map(Int32.init)).expandedDimensions(axis: 0)
    var snapshot: NativePrefixParityProbe.Snapshot?, ranges: [NativePrefixParityProbe.TokenRange] = []
    var failure: Error?
    let done = try session.prefill.forEachChunk(total: ids.count) { range in
      guard failure == nil else { return }
      do {
        try flag.check(); try ModelResidency.check()
        let result = model(LMInput.Text(tokens: y[0..., range]), cache: session.cache, state: nil)
        guard result.state == nil else { throw BoomError.invalid("Unsupported public model state.") }
        asyncEval(session.cache)
        let absolute = session.cachedTokenCount + range.upperBound
        ranges.append(NativePrefixParityProbe.TokenRange(
          session.cachedTokenCount + range.lowerBound ..< absolute))
        if captureAt == absolute {
          let captured = try NativePrefixParityProbe.captureNative(nativeBases(session.cache),
            evaluatedPrefix: absolute, selectedRow: 0)
          snapshot = captured
          try write(captured.source, label + "-native-source.json", evidence)
        }
        try write(ranges, label + "-prefill-ranges.json", evidence)
      } catch { failure = error }
    }
    if let failure { throw failure }
    if done > 0 { eval(session.cache) }
    try flag.check(); try ModelResidency.check()
    let final = model(LMInput.Text(tokens: y[0..., done...]), cache: session.cache, state: nil)
    guard final.state == nil, final.logits.ndim == 3, final.logits.dim(0) == 1 else {
      throw BoomError.invalid("Unsupported final public model output.")
    }
    ranges.append(NativePrefixParityProbe.TokenRange(session.cachedTokenCount + done ..< session.fullPromptTokenCount))
    session.prefill.progress?(ids.count, ids.count)
    eval([final.logits] + session.cache.flatMap { $0.innerState() })
    try flag.check(); try ModelResidency.check()
    try write(ranges, label + "-prefill-ranges.json", evidence)
    if captureAt != nil, snapshot == nil {
      throw BoomError.invalid("The declared native boundary was not part of the actual source partitions.")
    }
    return Prepared(session: session, logits: final.logits[0..., -1, 0...], snapshot: snapshot, ranges: ranges)
  }

  private static func produce(_ input: CapturedInput, model: any LanguageModel,
    manager: PromptPrefixCache, owner: PromptCacheOwner, prefill: PrefillParameters,
    policy: ModelGenerationPolicy, expectedCached: Int, width: Int, processed: Int, delivered: Int,
    captureAt: Int?, label: String, flag: CancellationFlag,
    allowSnapshot: @escaping @Sendable (UInt64) -> Bool, fence: () -> Void, evidence: URL) throws -> Prepared {
    let parameters = GenerateParameters(maxTokens: 16, temperature: input.settings.temperature,
      topP: input.settings.topP, topK: input.settings.topK, minP: input.settings.minP,
      repetitionPenalty: nil, prefill: prefill, seed: 42)
    let session = try manager.makeSession(owner: owner,
      input: LMInput(tokens: MLXArray(input.prepared_token_ids.map(Int32.init))),
      promptTokenIDs: input.prepared_token_ids, prefill: prefill, allowSnapshot: allowSnapshot,
      makeCache: { try model.newCache(parameters: parameters) })
    try write(session.observation, label + "-lookup.json", evidence)
    guard session.cachedTokenCount == expectedCached else {
      throw BoomError.invalid("The declared source's actual manager selection changed.")
    }
    let prepared = try prepare(model: model, session: session, captureAt: captureAt,
      label: label, flag: flag, evidence: evidence)
    let ledgers = input.outputs.map { Array($0.token_ids.prefix(delivered)) }
    guard ledgers.count == width, processed <= delivered, width == 1 || processed < delivered,
      ledgers.allSatisfy({ $0.count == delivered && $0.allSatisfy { !policy.controlTokenIDs.contains($0)
        && $0 >= 0 && $0 < policy.vocabularySize } }) else {
      throw BoomError.invalid("Invalid public teacher-forced ledger bounds.")
    }
    if width > 1 {
      for var entry in session.cache {
        let state = entry.state
        guard state.count == 2, state.allSatisfy({ $0.ndim == 4 && $0.dim(0) == 1 }) else {
          throw BoomError.invalid("Unsupported real batch cache expansion.")
        }
        entry.state = state.map { broadcast($0, to: [width] + Array($0.shape.dropFirst())) }
      }
      eval(session.cache)
    }
    var processedMatrices: [[Int]] = []
    for position in 0 ..< processed {
      try flag.check(); try ModelResidency.check()
      let column = ledgers.map { $0[position] }
      if width == 1 { session.didSample?(MLXArray(Int32(column[0]))) }
      else {
        for row in 0 ..< width {
          guard session.captureDecodeLane(row: row, width: width,
            emittedTokenIDs: Array(ledgers[row].prefix(position + 1)), finished: false) else {
            throw BoomError.invalid("The actual manager refused a declared batch ledger boundary.")
          }
        }
      }
      let output = model(LMInput.Text(tokens: MLXArray(column.map(Int32.init)).reshaped([width, 1])),
        cache: session.cache, state: nil)
      guard output.state == nil else { throw BoomError.invalid("Unexpected teacher-forced model state.") }
      eval([output.logits] + session.cache.flatMap { $0.innerState() })
      processedMatrices.append(column)
    }
    if width > 1 {
      for row in 0 ..< width {
        guard session.captureFinishedLane(row: row, width: width, emittedTokenIDs: ledgers[row]) else {
          throw BoomError.invalid("The actual manager refused the public finished-row checkpoint.")
        }
      }
    }
    fence(); try flag.check(); try ModelResidency.check()
    let published = manager.publish(session, completions: ledgers.indices.map {
      PromptPrefixCache.Completion(row: $0, emittedTokenIDs: ledgers[$0])
    })
    try object(["method": "teacher_force_exact_public_receipt_ledger",
      "original_receipt_emitted_counts": input.outputs.map { $0.token_ids.count },
      "declared_supplied_ledger_counts": ledgers.map(\.count),
      "processed_decode_positions": processed, "processed_row_matrix": processedMatrices,
      "unprocessed_supplied_ledger_suffixes": ledgers.map { Array($0.dropFirst(processed)) },
      "inert_positions": [], "actual_native_offsets": session.cache.map { $0.offset },
      "actual_native_batch_dimensions": session.cache.flatMap { $0.state.map { $0.dim(0) } },
      "published": published, "retained_byte_bound": manager.retainedBytesUpperBound,
      "source_is_autonomous_generation": false], label + "-producer.json", evidence)
    try write(manager.retainedSnapshotObservations, label + "-manager-snapshots.json", evidence)
    guard published else { throw BoomError.invalid("The bounded normal manager did not retain the declared source.") }
    return prepared
  }

  private static func naturalSamples(model: any LanguageModel, cache: [any KVCache], logits initial: MLXArray,
    settings: SamplingSettings, policy: ModelGenerationPolicy, flag: CancellationFlag) throws -> Samples {
    let sampler = GenerateParameters(temperature: settings.temperature, topP: settings.topP,
      topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, seed: 42).sampler()
    let mask = CheckpointTokenMask(policy.suppressedTokenIDs)
    var logits = initial, sampled: [Int] = [], emitted: [Int] = [], processed = 0
    var reason = "output_limit", stop: Int?
    for step in 0 ..< 16 {
      try flag.check(); try ModelResidency.check()
      let next = sampler.sample(logits: mask.process(logits: logits)).reshaped([1])
      eval(next)
      let id = next.item(Int.self); sampled.append(id)
      guard !policy.suppressedTokenIDs.contains(id), id >= 0, id < policy.vocabularySize else {
        throw BoomError.invalid("The normal sampler returned a forbidden token.")
      }
      if policy.controlTokenIDs.contains(id) {
        stop = id; reason = policy.eosTokenIDs.contains(id) ? "eos" : "model_control"; break
      }
      emitted.append(id)
      if step == 15 { break }
      let output = model(LMInput.Text(tokens: next.reshaped([1, 1])), cache: cache, state: nil)
      guard output.state == nil else { throw BoomError.invalid("Unexpected natural-cold inference state.") }
      logits = output.logits[0..., -1, 0...]; eval([logits] + cache.flatMap { $0.innerState() })
      processed += 1
    }
    return Samples(sampledTokenIDs: sampled, emittedTokenIDs: emitted, stopReason: reason,
      stopTokenID: stop, processedDecodeTokens: processed)
  }

  private static func pair(name: String, model: any LanguageModel, reference: [any KVCache],
    candidate: [any KVCache], query: [Int], prefix: Int, partitions: [Int], windows: [Int?],
    settings: SamplingSettings, policy: ModelGenerationPolicy, flag: CancellationFlag,
    evidence: URL) throws -> PairSummary {
    let initial = try NativePrefixParityProbe.compareState(oracle: reference, hydrated: candidate,
      suffixLength: partitions[0], maskWindows: windows)
    try write(initial, name + "-initial-state.json", evidence)
    let makeSampler = { GenerateParameters(temperature: settings.temperature, topP: settings.topP,
      topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, seed: 42).sampler() }
    let aSampler = makeSampler(), bSampler = makeSampler(), mask = CheckpointTokenMask(policy.suppressedTokenIDs)
    var aIDs: [Int] = [], bIDs: [Int] = [], control = false, equalLogits = true
    let sample: (MLXArray, MLXArray, Int) throws -> [NativePrefixParityProbe.SampleComparison] = { a, b, _ in
      let at = aSampler.sample(logits: mask.process(logits: a)).reshaped([1])
      let bt = bSampler.sample(logits: mask.process(logits: b)).reshaped([1])
      eval([at, bt]); let ai = at.item(Int.self), bi = bt.item(Int.self)
      guard [ai, bi].allSatisfy({ $0 >= 0 && $0 < policy.vocabularySize
        && !policy.suppressedTokenIDs.contains($0) }) else {
        throw BoomError.invalid("A paired normal sampler returned a forbidden token.")
      }
      aIDs.append(ai); bIDs.append(bi)
      control = policy.controlTokenIDs.contains(ai) || policy.controlTokenIDs.contains(bi)
      return [.init(seed: 42, referenceTokenID: ai, candidateTokenID: bi)]
    }
    var cursor = prefix
    for (index, count) in partitions.enumerated() {
      try flag.check(); try ModelResidency.check()
      let ids = Array(query[cursor ..< cursor + count]); cursor += count
      let result = try NativePrefixParityProbe.forwardSameInputs(model: model, oracle: reference,
        hydrated: candidate, tokenBlocks: [ids], maskWindows: windows, vocabularySize: policy.vocabularySize,
        sample: index == partitions.count - 1 ? sample : nil,
        didRecordBlock: { try write($0, name + "-suffix-\(index).json", evidence) })
      equalLogits = equalLogits && result.allSatisfy { $0.logits.bitwiseEqual == true }
    }
    // Continue both histories with the same reference token after every draw.
    // Each sampler has its own RNG state. Stop at either actual control token.
    for step in 1 ..< 16 {
      if control { break }
      try flag.check(); try ModelResidency.check()
      guard let previous = aIDs.last else { throw BoomError.invalid("The paired sampler did not produce its declared checkpoint.") }
      let result = try NativePrefixParityProbe.forwardSameInputs(model: model, oracle: reference,
        hydrated: candidate, tokenBlocks: [[previous]], maskWindows: windows, vocabularySize: policy.vocabularySize,
        sample: sample, didRecordBlock: { try write($0, name + "-decode-\(step).json", evidence) })
      equalLogits = equalLogits && result.allSatisfy { $0.logits.bitwiseEqual == true }
    }
    let first = aIDs.indices.first { aIDs[$0] != bIDs[$0] }
    let summary = PairSummary(name: name, initialState: initial, allLogitBitsEqual: equalLogits,
      sampledReferenceTokenIDs: aIDs, sampledCandidateTokenIDs: bIDs,
      firstSampleDifferenceZeroBased: first, eitherBranchStoppedByControl: control,
      method: "identical_suffix_partitions_then_reference_teacher_forced_tokens; independent_normal_samplers; candidate_after_divergence_is_not_autonomous")
    try write(summary, name + "-summary.json", evidence)
    return summary
  }

  // Runs synchronously only on the owned inference executor. Default inference
  // gains no eval, snapshot, matrix, reduction or diagnostic callback.
  static func execute(_ request: Request, model: any LanguageModel, manager: PromptPrefixCache,
    prefill: PrefillParameters, policy: ModelGenerationPolicy, layerWindows: [Int?],
    flag: CancellationFlag, allowSnapshot: @escaping @Sendable (UInt64) -> Bool, fence: () -> Void,
    evidence: URL) throws -> CaseSummary {
    let d = request.declaration
    let owner = PromptCacheOwner(namespace: d.namespace, entity: d.namespace,
      route: d.kind == .consultationInterior ? .consultation : .writing)
    let shared = try produce(request.shared, model: model, manager: manager, owner: owner,
      prefill: prefill, policy: policy, expectedCached: 0, width: d.sharedWidth,
      processed: d.sharedProcessedDecodeTokens, delivered: d.sharedDeliveredLedgerTokens,
      captureAt: d.kind == .consultationInterior ? d.sourceNativeBoundary : nil,
      label: "shared-source", flag: flag, allowSnapshot: allowSnapshot, fence: fence, evidence: evidence)
    let anchor: Prepared?
    if let input = request.anchor {
      guard let cached = d.anchorCachedPrefix else { throw BoomError.invalid("Missing declared anchor admission.") }
      anchor = try produce(input, model: model, manager: manager, owner: owner, prefill: prefill,
        policy: policy, expectedCached: cached, width: 1, processed: 16, delivered: 16,
        captureAt: d.sourceNativeBoundary, label: "late-anchor", flag: flag,
        allowSnapshot: allowSnapshot, fence: fence, evidence: evidence)
    } else { anchor = nil }
    guard let sourceSnapshot = (anchor ?? shared).snapshot else { throw BoomError.invalid("Original native source was not captured.") }
    // Hold both original producer sessions, source tensors and model lease until
    // after all comparisons; snapshots are bounded to these declared cases.
    defer { withExtendedLifetime((shared, anchor)) {} }

    let parameters = GenerateParameters(maxTokens: 16, temperature: request.query.settings.temperature,
      topP: request.query.settings.topP, topK: request.query.settings.topK, minP: request.query.settings.minP,
      repetitionPenalty: nil, prefill: prefill, seed: 42)
    let cold = try manager.makeSession(owner: nil,
      input: LMInput(tokens: MLXArray(request.query.prepared_token_ids.map(Int32.init))),
      promptTokenIDs: request.query.prepared_token_ids, prefill: prefill,
      makeCache: { try model.newCache(parameters: parameters) })
    let coldPrepared = try prepare(model: model, session: cold, captureAt: d.coldNativeBoundary,
      label: "natural-full-query-cold", flag: flag, evidence: evidence)
    guard let coldSnapshot = coldPrepared.snapshot else { throw BoomError.invalid("Full-query cold native boundary was not captured.") }
    let coldSamples = try naturalSamples(model: model, cache: cold.cache, logits: coldPrepared.logits,
      settings: request.query.settings, policy: policy, flag: flag)
    try write(coldSamples, "natural-full-query-cold-samples.json", evidence)
    try object(["method": "natural_full_current_query_cold; no shortened_C_token_prefill",
      "prepared_tokens": request.query.prepared_token_ids.count,
      "native_capture_boundary": d.coldNativeBoundary,
      "natural_samples_match_historical_public_query": coldSamples.emittedTokenIDs == request.query.outputs[0].token_ids,
      "final_native_offsets": cold.cache.map(\.offset)], "natural-full-query-cold-scope.json", evidence)
    fence(); try flag.check(); try ModelResidency.check()

    let warm = try manager.makeSession(owner: owner,
      input: LMInput(tokens: MLXArray(request.query.prepared_token_ids.map(Int32.init))),
      promptTokenIDs: request.query.prepared_token_ids, prefill: prefill, allowSnapshot: allowSnapshot,
      makeCache: { try model.newCache(parameters: parameters) })
    defer { withExtendedLifetime((warm, coldPrepared)) {} }
    try write(warm.observation, "actual-warm-lookup.json", evidence)
    guard warm.cachedTokenCount == d.cachedPrefix,
      warm.fullPromptTokenCount - warm.cachedTokenCount == d.warmSuffixPartitions.reduce(0, +) else {
      throw BoomError.invalid("The actual bounded manager did not select the declared parity prefix.")
    }
    let bases = nativeBases(warm.cache)
    guard !bases.isEmpty, bases.count <= layerWindows.count else { throw BoomError.invalid("Actual owning cache layers exceed declared architecture.") }
    let windows = Array(layerWindows.prefix(bases.count))
    var ranges: [Int] = []
    let tailCount = warm.input.text.tokens.size
    _ = try warm.prefill.forEachChunk(total: tailCount) { ranges.append($0.count) }
    ranges.append(tailCount - ranges.reduce(0, +))
    guard ranges == d.warmSuffixPartitions else { throw BoomError.invalid("The actual warm suffix partitions changed.") }
    try object(["comparison_A": "same_original_evaluated_native_history_vs_actual_normal_manager_hydration",
      "comparison_B": "retained_original_native_history_vs_independently_cold_full_current_query_native_history",
      "warm_suffix_partitions": ranges, "source_native_boundary": d.sourceNativeBoundary,
      "cold_native_boundary": d.coldNativeBoundary, "prefix": d.cachedPrefix,
      "same_integer_prefix_proved": true, "unavailable_oracle_fallback": false,
      "full_query_cold_history_is_primary": true, "historical_native_tensors_recreated_from_receipts": false],
      "comparison-scope.json", evidence)

    let a = try pair(name: "A-same-history-restoration", model: model,
      reference: sourceSnapshot.oracle(prefix: d.cachedPrefix), candidate: bases,
      query: request.query.prepared_token_ids, prefix: d.cachedPrefix, partitions: ranges, windows: windows,
      settings: request.query.settings, policy: policy, flag: flag, evidence: evidence)
    // A's working caches were advanced; B starts from fresh independent native
    // snapshot crops, never from A's advanced hydration or oracle-derived spans.
    let b = try pair(name: "B-full-query-cold-vs-retained-history", model: model,
      reference: sourceSnapshot.oracle(prefix: d.cachedPrefix), candidate: coldSnapshot.oracle(prefix: d.cachedPrefix),
      query: request.query.prepared_token_ids, prefix: d.cachedPrefix, partitions: ranges, windows: windows,
      settings: request.query.settings, policy: policy, flag: flag, evidence: evidence)
    fence(); try flag.check(); try ModelResidency.check()
    let result = CaseSummary(name: request.name, modelIdentity: request.query.model,
      sourceBoundary: d.sourceNativeBoundary, coldBoundary: d.coldNativeBoundary,
      prefix: d.cachedPrefix, actualWarmObservation: warm.observation,
      restoration: a, coldVsRetained: b, naturalFullQueryColdSamples: coldSamples,
      fullQueryColdPromptHistory: coldPrepared.ranges, releaseQualified: false)
    try write(result, "case-result.json", evidence)
    try object(["status": "execution_complete", "source_bound": true,
      "same_history_restoration_exact": result.sameHistoryRestorationExact,
      "cold_history_equivalence_observed": result.coldHistoryEquivalenceObserved,
      "natural_full_query_cold_samples": try ProductCore.object(coldSamples),
      "no_hidden_retry": true, "release_qualified": false], "terminal.json", evidence)
    return result
  }

  private final class MemoryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var samples = 0
    private var peakFootprint: UInt64 = 0
    private var peakAllocator: UInt64 = 0
    init() {
      timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now(), repeating: .milliseconds(20))
      timer.setEventHandler { [weak self] in self?.sample() }; timer.resume()
    }
    func sample() {
      let account = ModelResidency.memoryAccounting()
      let allocated = UInt64(max(0, Memory.activeMemory + Memory.cacheMemory))
      lock.lock(); defer { lock.unlock() }
      samples += 1; peakFootprint = max(peakFootprint, max(account.current, account.peak))
      peakAllocator = max(peakAllocator, allocated)
    }
    func snapshot() -> [String: Any] {
      sample(); lock.lock(); defer { lock.unlock() }
      return ["sample_interval_ms": 20, "sample_count": samples,
        "peak_process_footprint_bytes": peakFootprint, "peak_allocator_active_plus_cache_bytes": peakAllocator,
        "mlx_peak_memory_bytes": Memory.peakMemory]
    }
    func check(_ limit: UInt64) throws {
      sample(); lock.lock(); let used = max(peakFootprint, peakAllocator); lock.unlock()
      guard used > 0, used <= limit else { throw BoomError.budget("The parity diagnostic exceeded 24 GiB.") }
    }
    func stop() { timer.cancel() }
    deinit { timer.cancel() }
  }

  static func run(writingPack: URL, consultationPack: URL, fixtureURL: URL, evidence: URL) async throws {
    var receipt: [String: Any] = ["schema": 1, "status": "running",
      "scope": "two declared public native-KV/logit comparisons; teacher_forcing_explicit",
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "runtime_revision": ModelPacks.runtimeRevision, "automatic_retries": false,
      "diagnostic_only_evaluations": true, "release_qualified": false,
      "main_4k_256_gate_replaced": false, "full_context_16k": "not_run", "interactive_ui_qualified": false]
    func persist() throws { try object(receipt, "receipt.json", evidence) }
    try persist()
    let observation = MemoryObservation(); defer { observation.stop() }
    do {
      let bytes = try RegularFile(fixtureURL, limit: 1_048_576).data()
      let fixture = try decodeFixture(bytes), requests = try fixture.declarations.map(request)
      receipt["fixture_sha256"] = Digest.sha256(bytes)
      receipt["originating_source_inventory"] = fixture.originatingSourceInventory
      let budget = min(try ModelResidency.budget(), UInt64(24) << 30)
      let wa = try ModelPacks.admission(writingPack, purpose: .writing)
      let ca = try ModelPacks.admission(consultationPack, purpose: .consultation)
      for (name, admission, purpose) in [("writing", wa, ModelPurpose.writing),
        ("consultation", ca, ModelPurpose.consultation)] {
        let manifest = try ModelPacks.evidenceManifest(admission, purpose: purpose)
        try manifest.write(to: evidence.appendingPathComponent(name + "-model-manifest.json"))
        receipt[name + "_model_manifest_sha256"] = Digest.sha256(manifest)
      }
      let writing = try await MLXGemmaRunner.load(admission: wa)
      try ModelResidency.admit(weightBytes: ca.weightBytes, residentWeights: wa.weightBytes)
      let consultation = try await MLXGemmaRunner.load(admission: ca)
      defer { withExtendedLifetime((writing, consultation)) {} }
      receipt["both_models_retained"] = true; receipt["budget_bytes"] = budget
      receipt["metal_device"] = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
      receipt["cases"] = [String: Any](); try persist()
      var statuses: [String: Any] = [:], results: [CaseSummary] = [], failed = false
      for item in requests {
        let directory = evidence.appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        try object(["status": "running", "declared_public_control": item.name,
          "automatic_retries": false, "release_qualified": false], "terminal.json", directory)
        do {
          try observation.check(budget)
          let runner = item.declaration.kind == .writingLateDivergence ? writing : consultation
          let result = try await runner.diagnosticPrefixParity(item, evidence: directory)
          results.append(result)
          statuses[item.name] = ["status": "execution_complete",
            "same_history_restoration_exact": result.sameHistoryRestorationExact,
            "cold_history_equivalence_observed": result.coldHistoryEquivalenceObserved]
          failed = failed || !result.sameHistoryRestorationExact || !result.coldHistoryEquivalenceObserved
        } catch {
          failed = true
          let status: [String: Any] = ["status": "failed_or_unavailable", "error": String(describing: error),
            "joined": true, "automatic_retries": false, "release_qualified": false]
          statuses[item.name] = status; try object(status, "terminal.json", directory)
        }
        receipt["cases"] = statuses; receipt["memory"] = observation.snapshot(); try persist()
      }
      try observation.check(budget)
      receipt["status"] = failed ? "differences_or_unavailable_controls" : "execution_complete"
      receipt["joined"] = true; receipt["cases_completed"] = results.count
      receipt["memory"] = observation.snapshot(); try persist()
      if failed { throw BoomError.invalid("Native parity differences or unavailable controls were preserved in the receipts.") }
    } catch {
      if receipt["joined"] == nil { receipt["status"] = "failed" }
      receipt["error"] = String(describing: error); receipt["joined"] = true
      receipt["memory"] = observation.snapshot(); try persist(); throw error
    }
  }
}
