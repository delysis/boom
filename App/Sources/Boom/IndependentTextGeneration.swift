import BoomCore
import Foundation
import MLX
import MLXLMCommon

extension MLXGemmaRunner {
  struct IndependentTextRequest: Sendable {
    enum Input: Sendable { case consultation(ConsultationPlan), raw(String) }
    let identity: GenerationIdentity
    let owner: PromptCacheOwner
    let input: Input
    let settings: SamplingSettings
    let flag: CancellationFlag
    let policy: ModelGenerationPolicy
    var joinedRetention: JoinedKVRetentionRequest? = nil
    var pairedAdmission: PairedContextAdmission? = nil
    var pairedAttempt: PairedAdmissionAttempt = .normal
    var beforeCachePublication: (@Sendable () async throws -> Void)? = nil
    var onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil
    var onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil
    var onText: @Sendable (String) -> Void
  }
  struct IndependentTextDecoded {
    let outputs: [Result<Output, Error>]
    let completions: [PromptPrefixCache.Completion]
    let acknowledged: [PromptPrefixCache.Completion?]
    let checkpointUncertain: [Bool]
    let cancelled: [Bool]
  }

  static func independentOrigins(requests: [IndependentTextRequest], preparedIDs: [[Int]],
    cohort: PromptPrefixCache.TextCohort, policy: ModelGenerationPolicy) throws -> [GenerationExecutionOrigin] {
    guard requests.count == preparedIDs.count, cohort.rows.count == requests.count else {
      throw BoomError.invalid("The actual cohort lost its prepared row inputs.")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let cohortID = UUID(), policyDigest = Digest.sha256(try encoder.encode(policy))
    let lineage = try requests.indices.map { row in
      IndependentTextCohortOrigin.Row(operationID: requests[row].identity.operationID,
        attemptID: requests[row].identity.attemptID, namespace: requests[row].owner.namespace,
        recordID: requests[row].identity.recordID, requestDigest: requests[row].identity.requestDigest,
        preparedTokenDigest: Digest.sha256(try encoder.encode(preparedIDs[row])),
        promptTokens: preparedIDs[row].count, cachedTokens: cohort.rows[row].cachedTokenCount,
        seed: requests[row].identity.seed, outputLimit: requests[row].identity.maxTokens,
        samplingDigest: Digest.sha256(try encoder.encode(requests[row].settings)),
        cacheParentID: cohort.parentIDs[row],
        cacheHistoryDigest: try PromptPrefixCache.operandHistoryDigest(cohort.rows[row].observation.cachedForwardHistory),
        cacheLengths: cohort.cacheLengths[row],
        cachePadding: zip(cohort.cacheWidths, cohort.cacheLengths[row]).map { $0 - $1 })
    }
    return requests.indices.map { row in
      GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "independent-text-cohort-v1",
        cachedPromptTokens: cohort.rows[row].cachedTokenCount,
        cacheMissReason: cohort.rows[row].observation.missReason,
        independentCohort: IndependentTextCohortOrigin(schema: 1, cohortID: cohortID,
          row: row, rows: lineage, policyDigest: policyDigest, promptWidth: cohort.input.text.tokens.dim(1),
          maskDigest: cohort.maskDigest, cacheWidths: cohort.cacheWidths,
          prefill: PromptCacheGeometry(promptTokens: cohort.input.text.tokens.dim(1), prefill: cohort.observedPrefill)))
    }
  }

  /// Common real model loop used by the owned runner and tiny CPU controls.
  /// No executor, model/cache owner, checkpoint writer or publication is made
  /// here. Its caller owns those lifetimes and performs their actual final join.
  static func decodeIndependentText(requests: [IndependentTextRequest],
    model: any LanguageModel, tokenizer: any MLXLMCommon.Tokenizer,
    cohort: PromptPrefixCache.TextCohort, origins: [GenerationExecutionOrigin],
    policy: ModelGenerationPolicy, flag: CancellationFlag,
    admitNext: () throws -> Void = {}) async throws -> IndependentTextDecoded {
    let width = requests.count
    guard (2...4).contains(width), cohort.rows.count == width, origins.count == width,
      origins.indices.allSatisfy({ origins[$0].independentCohort?.row == $0
        && origins[$0].isValid(promptTokens: cohort.rows[$0].fullPromptTokenCount) }) else {
      throw BoomError.invalid("Independent text rows changed before preparation.")
    }
    let clock = ContinuousClock(), started = clock.now
    let controls = Set(policy.controlTokenIDs), ends = Set(policy.eosTokenIDs)
    guard let inertToken = policy.eosTokenIDs.first else {
      throw BoomError.invalid("Independent text requires the actual loaded stop-token policy.")
    }
    let mask = CheckpointTokenMask(policy.suppressedTokenIDs)
    let samplers = requests.map { value in
      GenerateParameters(temperature: value.settings.temperature, topP: value.settings.topP,
        topK: value.settings.topK, minP: value.settings.minP,
        repetitionPenalty: nil, seed: value.identity.seed).sampler()
    }
    var tokens = Array(repeating: [Int](), count: width)
    var texts = Array(repeating: "", count: width)
    var first = Array<Double?>(repeating: nil, count: width)
    var reasons = Array<String?>(repeating: nil, count: width)
    var stops = Array<Int?>(repeating: nil, count: width)
    var failures = Array<Error?>(repeating: nil, count: width)
    var checkpointUncertain = Array(repeating: false, count: width)
    var cancelled = Array(repeating: false, count: width)
    var acknowledged = Array<PromptPrefixCache.Completion?>(repeating: nil, count: width)
    var elapsed = Array(repeating: 0.0, count: width)
    func progress(_ row: Int) -> GenerationProgress {
      GenerationProgress(text: texts[row], tokenIDs: tokens[row],
        promptDigest: origins[row].independentCohort!.rows[row].preparedTokenDigest,
        promptTokens: cohort.rows[row].fullPromptTokenCount, firstTokenSeconds: first[row],
        elapsedSeconds: elapsed[row], executionOrigin: origins[row])
    }
    func checkpoint(_ row: Int) async {
      do {
        try await requests[row].onCheckpoint?(progress(row), reasons[row], stops[row])
        if requests[row].joinedRetention?.checkpointIsDurable == true,
          requests[row].onCheckpoint != nil {
          acknowledged[row] = .init(row: row, emittedTokenIDs: tokens[row], stopTokenID: stops[row])
        }
        requests[row].onText(texts[row])
      } catch {
        // One refused durable callback is not another row's cancellation or ACK.
        failures[row] = error; checkpointUncertain[row] = true
        reasons[row] = "checkpoint_failed"
        requests[row].joinedRetention?.authorization.revoke()
        _ = cohort.captureLane(row, emitted: tokens[row], stop: stops[row], finished: true)
      }
    }
    var prefill = cohort.observedPrefill
    let originalProgress = prefill.progress
    prefill.progress = { processed, total in
      // Pinned Gemma text forEachChunk explicitly submits the complete cache
      // graph before intermediate progress. Terminal progress precedes its
      // final caller submission and must never serve as this witness.
      if processed > 0 && processed < total { cohort.markCacheSubmitted() }
      originalProgress?(processed, total)
      for row in requests.indices {
        let cached = cohort.rows[row].cachedTokenCount
        let full = cohort.rows[row].fullPromptTokenCount
        requests[row].onPrefill?(.init(operationID: requests[row].flag.operationID,
          processedPositions: cached + min(processed, full - cached), totalPositions: full))
      }
    }
    try flag.check(); try admitNext()
    let prepared = try model.prepare(cohort.input, cache: cohort.cache, state: nil, prefill: prefill)
    let initial: LMOutput
    switch prepared {
    case .logits(let result): initial = result
    case .tokens:
      throw BoomError.invalid("The actual independent Gemma prepare did not return per-row logits.")
    }
    guard initial.state == nil else { throw BoomError.invalid("Unexpected per-row model state.") }
    var logits = initial.logits[0..., -1, 0...]
    guard logits.ndim == 2, logits.dim(0) == width else {
      throw BoomError.invalid("The actual Gemma prepare lost independent rows.")
    }
    asyncEval([logits] + cohort.cache.flatMap { $0.innerState() })
    eval(logits); cohort.finishedPreparation(); cohort.markCacheSubmitted()
    while reasons.contains(nil) {
      for row in requests.indices where reasons[row] == nil && (requests[row].flag.isCancelled || flag.isCancelled || Task.isCancelled) {
        cancelled[row] = true; reasons[row] = "cancelled"; failures[row] = CancellationError()
        elapsed[row] = started.duration(to: clock.now).timeInterval
        texts[row] = tokenizer.decode(tokenIds: tokens[row])
        _ = cohort.captureLane(row, emitted: tokens[row], stop: nil, finished: true)
        await checkpoint(row)
      }
      guard reasons.contains(nil) else { break }
      let sampled: [Int] = autoreleasepool {
        let filtered = mask.process(logits: logits)
        let next = requests.indices.map { row in
          reasons[row] == nil
            ? samplers[row].sample(logits: filtered[row].expandedDimensions(axis: 0)).reshaped([1])
            : MLXArray([inertToken])
        }
        let joined = concatenated(next, axis: 0)
        eval(joined)
        return joined.asArray(Int.self)
      }
      for row in requests.indices where reasons[row] == nil {
        let token = sampled[row]
        guard !policy.suppressedTokenIDs.contains(token) else {
          throw BoomError.invalid("The actual row sampler emitted an excluded token.")
        }
        if controls.contains(token) {
          reasons[row] = ends.contains(token) ? "eos" : "model_control"; stops[row] = token
        } else {
          if first[row] == nil { first[row] = started.duration(to: clock.now).timeInterval }
          tokens[row].append(token)
          if tokens[row].count == requests[row].identity.maxTokens { reasons[row] = "output_limit" }
        }
        let decoded = tokenizer.decode(tokenIds: tokens[row])
        elapsed[row] = started.duration(to: clock.now).timeInterval
        _ = cohort.captureLane(row, emitted: tokens[row], stop: stops[row], finished: reasons[row] != nil)
        if reasons[row] != nil || (!decoded.hasSuffix("\u{FFFD}") && decoded != texts[row]) {
          texts[row] = decoded; await checkpoint(row)
        }
      }
      // Freeze completed rows' ACTUAL ready local ranges before inert peer
      // steps. A busy/unready disposable disk tier is a miss, never a wait.
      cohort.observeReadySpill()
      if reasons.contains(nil) {
        if flag.isCancelled || Task.isCancelled { continue }
        do { try admitNext() }
        catch is CancellationError where flag.isCancelled || Task.isCancelled {
          // Return through the real row checkpoint dispositions above. A
          // late cancellation cannot erase an earlier uncertain checkpoint.
          continue
        }
        logits = try autoreleasepool {
          cohort.observeDecodeOperands(sampled, active: reasons.map { $0 == nil })
          let output = model(LMInput.Text(tokens: MLXArray(sampled).reshaped([width, 1])),
            cache: cohort.cache, state: nil)
          guard output.state == nil else { throw BoomError.invalid("Unexpected independent decode state.") }
          let next = output.logits[0..., -1, 0...]
          guard next.ndim == 2, next.dim(0) == width else { throw BoomError.invalid("The model lost its independent decode rows.") }
          asyncEval([next] + cohort.cache.flatMap { $0.innerState() })
          eval(next); cohort.markCacheSubmitted()
          return next
        }
      }
    }
    let completions = requests.indices.map { PromptPrefixCache.Completion(row: $0,
      emittedTokenIDs: tokens[$0], stopTokenID: stops[$0]) }
    let outputs: [Result<Output, Error>] = requests.indices.map { row in
      if let failure = failures[row] { return .failure(failure) }
      return .success(Output(text: texts[row], tokenIDs: tokens[row],
        promptDigest: progress(row).promptDigest, promptTokens: cohort.rows[row].fullPromptTokenCount,
        outputTokens: tokens[row].count, endedByEOS: stops[row] != nil,
        stopReason: reasons[row]!, stopTokenID: stops[row], firstTokenSeconds: first[row],
        elapsedSeconds: elapsed[row], executionPriority: Task.currentPriority.rawValue,
        executionOrigin: origins[row]))
    }
    return IndependentTextDecoded(outputs: outputs, completions: completions,
      acknowledged: acknowledged, checkpointUncertain: checkpointUncertain, cancelled: cancelled)
  }
}
