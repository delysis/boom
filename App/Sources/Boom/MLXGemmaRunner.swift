import BoomCore
import Foundation
import Metal
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers

actor GenerationCoordinator {
  static let shared = GenerationCoordinator()
  private var occupied = false
  private var activeFlag: CancellationFlag?
  private var background = false
  private var producer: Task<Void, Never>?
  private var cancelProducer: (@Sendable () -> Void)?
  private var activity: NSObjectProtocol?
  private var waiting: [(CancellationFlag?, Bool, CheckedContinuation<Void, Never>)] = []
  var queuedOperations: Int { waiting.count }
  private func admitOwner(flag: CancellationFlag?, background: Bool) {
    occupied = true; activeFlag = flag; self.background = background
    activity = ProcessInfo.processInfo.beginActivity(
      options: background ? .background : .userInitiatedAllowingIdleSystemSleep,
      reason: "On-device model operation")
  }
  func enter(flag: CancellationFlag? = nil, background: Bool = false) async {
    if !occupied { admitOwner(flag: flag, background: background); return }
    if !background, self.background { activeFlag?.cancel(); cancelProducer?() }
    await withCheckedContinuation { waiting.append((flag, background, $0)) }
  }
  func own<R: Sendable, E: Error>(_ task: Task<R, E>) {
    cancelProducer = { task.cancel() }
    producer = Task { _ = try? await task.value }
    // A foreground request can arrive between lease acquisition and task
    // registration. The new owner must observe that earlier cancellation.
    if activeFlag?.isCancelled == true { task.cancel() }
  }
  func leave() async {
    if let producer { await producer.value }
    producer = nil; cancelProducer = nil; activeFlag = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    if waiting.isEmpty { occupied = false; background = false }
    else {
      let index = waiting.firstIndex { !$0.1 } ?? 0
      let next = waiting.remove(at: index)
      admitOwner(flag: next.0, background: next.1); next.2.resume()
    }
  }
}

/// Mutable model state is confined to this actor and ModelContainer.
actor MLXGemmaRunner {
  struct PrefillProgress: Sendable {
    let operationID: UUID
    let processedPositions: Int
    let totalPositions: Int
  }
  struct Output: Sendable {
    let text: String
    let tokenIDs: [Int]
    let promptDigest: String
    let promptTokens: Int
    let outputTokens: Int
    let endedByEOS: Bool
    let stopReason: String
    let stopTokenID: Int?
    let firstTokenSeconds: Double?
    let elapsedSeconds: Double
  }
  struct BatchMetrics: Codable, Sendable {
    let width: Int
    let sharedPromptPrefills: Int
    let decodeForwardPasses: Int
    let cacheBatchDimensions: [Int]
  }
  nonisolated let source: URL
  nonisolated let identity: String
  nonisolated let generationPolicy: ModelGenerationPolicy
  private let container: ModelContainer
  private let cacheConfiguration: Data
  private let tokenizerDescription: Data
  private var contextVocabulary: ContextVocabulary?
  private struct Configuration: Decodable {
    let model_type: String
    let text_config: Text
    struct Text: Decodable {
      let vocab_size: Int
      let max_position_embeddings: Int
      let num_hidden_layers: Int
      let num_key_value_heads: Int
      let head_dim: Int
    }
  }
  private struct TokenizerFile: Decodable {
    let added_tokens: [Added]
    struct Added: Decodable { let id: Int; let special: Bool }
  }
  static func load(directory: URL, identity: String? = nil, prefillTokens: UInt32? = nil) async throws -> MLXGemmaRunner {
    await GenerationCoordinator.shared.enter()
    do {
      try ModelResidency.configure()
      try ModelResidency.check()
      let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
      let config = try JSONDecoder().decode(Configuration.self,
        from: configuration)
      let text = config.text_config
      guard config.model_type == "gemma4_unified", text.max_position_embeddings > 0,
        text.num_hidden_layers > 0, text.num_key_value_heads > 0, text.head_dim > 0
      else { throw BoomError.invalid("This is not the supported Gemma 4 12B model.") }
      let tokenizerDescription = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
      let tokenizer = try JSONDecoder().decode(TokenizerFile.self, from: tokenizerDescription)
      let generationURL = directory.appendingPathComponent("generation_config.json")
      let generationDescription = try Data(contentsOf: generationURL)
      let tokenizerConfigurationURL = directory.appendingPathComponent("tokenizer_config.json")
      let tokenizerConfiguration = try Data(contentsOf: tokenizerConfigurationURL)
      let model = try await VLMModelFactory.shared.loadContainer(
        from: directory, using: CheckpointTokenizerLoader())
      guard tokenizerDescription == (try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))),
        tokenizerConfiguration == (try Data(contentsOf: tokenizerConfigurationURL)),
        generationDescription == (try Data(contentsOf: generationURL)) else {
        throw BoomError.stale("The tokenizer or generation configuration changed while the model was loading.")
      }
      let tokenizerEnds = await model.perform { ($0.tokenizer.eosTokenId, $0.tokenizer.unknownTokenId) }
      let controls = tokenizer.added_tokens.filter(\.special).map(\.id) + (tokenizerEnds.1.map { [$0] } ?? [])
      let policy = try ProductCore.generationPolicy(vocabularySize: text.vocab_size,
        configuration: generationDescription, controls: controls, tokenizerEOS: tokenizerEnds.0,
        prefillTokens: prefillTokens)
      guard let object = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        let cacheConfiguration = object["text_config"] as? [String: Any] else {
        throw BoomError.invalid("Missing model cache configuration.")
      }
      let runner = MLXGemmaRunner(source: directory, container: model,
        identity: try identity ?? ModelInstaller.hashFile(directory.appendingPathComponent(ModelPacks.manifestName), maxBytes: 4_194_304).sha256,
        cacheConfiguration: try JSONSerialization.data(withJSONObject: cacheConfiguration),
        generationPolicy: policy, tokenizerDescription: tokenizerDescription)
      try ModelResidency.check()
      guard try runner.availableContext() >= 1024 else {
        throw BoomError.budget("The model leaves too little memory for a useful context.")
      }
      await GenerationCoordinator.shared.leave()
      return runner
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  private init(source: URL, container: ModelContainer, identity: String,
    cacheConfiguration: Data, generationPolicy: ModelGenerationPolicy, tokenizerDescription: Data) {
    self.source = source; self.identity = identity
    self.container = container; self.cacheConfiguration = cacheConfiguration
    self.generationPolicy = generationPolicy
    self.tokenizerDescription = tokenizerDescription
  }
  private nonisolated func availableContext(batchWidth: Int = 1) throws -> Int {
    guard let prefill = generationPolicy.prefill else { throw BoomError.invalid("The loaded model has no prefill geometry.") }
    return try ProductCore.contextCapacity(configuration: cacheConfiguration,
      available: ModelResidency.availableBytes(), width: batchWidth, prefill: prefill)
  }
  private nonisolated func prefillParameters(_ callback: (@Sendable (PrefillProgress) -> Void)?,
    operationID: UUID) throws -> PrefillParameters {
    guard let geometry = generationPolicy.prefill else { throw BoomError.invalid("The loaded model has no prefill geometry.") }
    return PrefillParameters(stepSize: geometry.tokenCeiling, chunking: .balanced,
      progress: { processed, total in
        callback?(PrefillProgress(operationID: operationID, processedPositions: processed, totalPositions: total))
      })
  }
  var contextLength: Int { (try? availableContext()) ?? 0 }
  func contextLength(batchWidth: Int) throws -> Int { try availableContext(batchWidth: batchWidth) }
  func tokenCount(_ text: String) async -> Int {
    await container.perform { $0.tokenizer.encode(text: text, addSpecialTokens: false).count }
  }
  /// Public diagnostic fixture construction using this exact loaded tokenizer.
  func diagnosticPrefix(tokens: Int) async throws -> String {
    guard (1...16_384).contains(tokens) else { throw BoomError.invalid("Invalid public fixture token bound.") }
    return try await container.perform { context in
      let authored = "<bos>" + String(repeating:
        "The harbor was quiet. A light moved across the water, and the keeper watched from the window.\n", count: 1024)
      let ids = context.tokenizer.encode(text: authored, addSpecialTokens: false)
      let text = context.tokenizer.decode(tokenIds: Array(ids.prefix(tokens)))
      guard context.tokenizer.encode(text: text, addSpecialTokens: false).count == tokens else {
        throw BoomError.invalid("Public fixture did not round-trip to the requested exact token count.")
      }
      return text
    }
  }
  func tokenCount(_ plan: ConsultationPlan) async throws -> Int {
    await GenerationCoordinator.shared.enter()
    do {
      let count = try await container.perform { context in
        try await Self.chatInput(plan, images: [], context: context).text.tokens.size
      }
      await GenerationCoordinator.shared.leave(); return count
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  private func writingVocabulary(tokenizer: any MLXLMCommon.Tokenizer, flag: CancellationFlag) throws -> ContextVocabulary {
    if let contextVocabulary { return contextVocabulary }
    guard let description = try JSONSerialization.jsonObject(with: tokenizerDescription) as? [String: Any],
      var model = description["model"] as? [String: Any], let vocabulary = model["vocab"] as? NSDictionary,
      let added = description["added_tokens"] as? [[String: Any]],
      let normalizer = description["normalizer"], let preTokenizer = description["pre_tokenizer"] else {
      throw BoomError.invalid("Invalid writing tokenizer description.")
    }
    // Use the loaded tokenizer's exact strings. A Swift dictionary keyed by
    // String would collapse canonically equivalent vocabulary entries.
    let ids = vocabulary.allValues.compactMap { ($0 as? NSNumber)?.intValue }
      + added.compactMap { ($0["id"] as? NSNumber)?.intValue }
    var words: [String] = []; words.reserveCapacity(ids.count)
    for id in Set(ids) {
      try flag.check()
      guard let word = tokenizer.convertIdToToken(id) else { throw BoomError.invalid("The loaded tokenizer has an incomplete vocabulary.") }
      words.append(word)
    }
    model.removeValue(forKey: "vocab"); model.removeValue(forKey: "merges")
    let dictionary = try ProductCore.contextVocabulary(["vocabulary": words, "normalizer": normalizer,
      "preTokenizer": preTokenizer, "model": model, "addedTokens": added])
    contextVocabulary = dictionary
    return dictionary
  }
  func writingContext(document: DocumentSnapshot, caret: Int, examples: [String], capacity: Int,
    flag: CancellationFlag) async throws -> (WritingPrompt, Int) {
    try flag.check()
    let tokenizer = await container.perform { $0.tokenizer }
    let dictionary = try writingVocabulary(tokenizer: tokenizer, flag: flag)
    var step = try ProductCore.writingContext(document, caret: caret, examples: examples,
      capacity: capacity, dictionary: dictionary)
    defer { ProductCore.releaseContext(step.id) }
    while step.status == "candidate", let prompt = step.candidate {
      try flag.check()
      let count = tokenizer.encode(text: prompt.prompt, addSpecialTokens: false).count
      try flag.check()
      step = try ProductCore.countedContext(step, prompt: prompt, count: count)
      await Task.yield()
    }
    try flag.check()
    guard step.status == "selected", let prompt = step.candidate else {
      throw BoomError.budget("The examples leave no room for text at the caret.")
    }
    return (prompt, step.testedCandidates)
  }
  private static func chatInput(_ plan: ConsultationPlan, images: [Data], context: ModelContext) async throws -> LMInput {
    let media = try images.map { UserInput.Image.ciImage(try LocalImage.decode($0)) }
    let messages = plan.messages.enumerated().map { index, m -> Chat.Message in
      switch m.role {
      case "system": return .system(m.content)
      case "assistant": return .assistant(m.content)
      default: return .user(m.content, images: index == plan.messages.count - 1 ? media : [])
      }
    }
    guard !messages.isEmpty else { throw BoomError.invalid("Conversation plan is empty.") }
    return try await context.processor.prepare(input: UserInput(chat: messages,
      additionalContext: ["enable_thinking": false]))
  }
  func preflight(_ plan: ConsultationPlan, images: [Data], maxTokens: Int, flag: CancellationFlag) async throws -> Int {
    // Preparing media creates MLX arrays too. It shares the same GPU lease as
    // loading and decoding, and must preempt background autocomplete.
    await GenerationCoordinator.shared.enter(flag: flag)
    do {
      try flag.check()
      let count = try await container.perform { context in
        let input = try await Self.chatInput(plan, images: images, context: context)
        return input.text.tokens.size
      }
      guard count + maxTokens <= (try availableContext()) else {
        throw BoomError.budget("The voice, question and sources do not fit. Nothing was sent.")
      }
      try flag.check()
      await GenerationCoordinator.shared.leave()
      return count
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  func fittedRound(voices: [Voice?], history: [ChatMessage], instructions: String, context: String,
    request: String, routing: [String], images: [Data], reserves: [Int], flag: CancellationFlag,
    authority: CapturedDocumentAuthority = .readOnly
  ) async throws -> (plans: [ConsultationPlan], history: [ChatMessage], omittedHistory: Int) {
    guard voices.count == reserves.count else { throw BoomError.invalid("Every participant needs an output reservation.") }
    var retained = history.filter { $0.state == .complete }
    let originalCount = retained.count
    while true {
      try flag.check()
      let plans = try ProductCore.consultationRound(voices: voices, history: retained,
        instructions: instructions, context: context, request: request, routing: routing, authority: authority)
      do {
        for (plan, reserve) in zip(plans, reserves) {
          _ = try await preflight(plan, images: images, maxTokens: reserve, flag: flag)
        }
        // Every participant receives this exact captured history suffix.
        return (plans, retained, originalCount - retained.count)
      } catch BoomError.budget {
        guard !retained.isEmpty else { throw BoomError.budget("The current question, voice and explicit sources exceed available context. Nothing was sent.") }
        retained.removeFirst()
      }
    }
  }
  func completionRecipe(document: DocumentSnapshot, caret: Int, sources: [SourceReference],
    examples: [String], profile: SamplingProfile, maxTokens: Int, flag: CancellationFlag, batchWidth: Int = 1
  ) async throws -> CompletionRecipe {
    let capacity = try availableContext(batchWidth: batchWidth) - maxTokens
    let (selected, _) = try await writingContext(document: document, caret: caret, examples: examples,
      capacity: capacity, flag: flag)
    return CompletionRecipe(document: document, caretUTF16: caret, sources: sources,
      prompt: selected.prompt, promptDigest: selected.digest, omittedPrefixCharacters: selected.omittedCharacters,
      model: identity, profile: profile, settings: try ProductCore.sampling(profile), maxTokens: maxTokens,
      generationPolicy: generationPolicy)
  }
  func run(plan: ConsultationPlan, images: [Data], maxTokens: Int, seed: UInt64? = nil,
    flag: CancellationFlag,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await generate(plan: plan, raw: nil, images: images, maxTokens: maxTokens,
      settings: ProductCore.sampling(.standard), seed: seed, flag: flag, onCheckpoint: onCheckpoint, onText: onText)
  }
  func run(rawPrompt: String, maxTokens: Int, settings: SamplingSettings? = nil, seed: UInt64? = nil,
    flag: CancellationFlag, background: Bool = false,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await generate(plan: nil, raw: rawPrompt, images: [], maxTokens: maxTokens,
      settings: settings ?? ProductCore.sampling(.standard), seed: seed, flag: flag, background: background, onPrefill: onPrefill,
      onCheckpoint: onCheckpoint, onText: onText)
  }
  private func generate(plan: ConsultationPlan?, raw: String?, images: [Data], maxTokens: Int,
    settings: SamplingSettings, seed: UInt64?, flag: CancellationFlag,
    background: Bool = false,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await ownedOperation(flag: flag, background: background) {
      try await self.generateOwned(plan: plan, raw: raw, images: images, maxTokens: maxTokens,
        settings: settings, seed: seed, flag: flag, onPrefill: onPrefill,
        onCheckpoint: onCheckpoint, onText: onText)
    }
  }
  private func ownedOperation<R: Sendable>(flag: CancellationFlag, background: Bool,
    operation: @escaping @Sendable () async throws -> R) async throws -> R {
    await GenerationCoordinator.shared.enter(flag: flag, background: background)
    let watch: OperationMemoryWatch
    do { watch = try OperationMemoryWatch(flag: flag) }
    catch { await GenerationCoordinator.shared.leave(); throw error }
    defer { watch.stop() }
    // Own the whole task before preparing input or constructing the iterator.
    // MLX checks Task cancellation between prefill chunks, before a stream
    // producer exists. Every exit fences submitted GPU work before handoff.
    let work = Task { try await operation() }
    let registration = flag.onCancel { work.cancel() }
    defer { flag.removeCancellationHandler(registration) }
    await GenerationCoordinator.shared.own(work)
    do {
      let result = try await withTaskCancellationHandler {
        try await work.value
      } onCancel: { flag.cancel(); work.cancel() }
      watch.stop()
      try ModelResidency.check()
      if watch.exceeded { throw BoomError.budget("The operation reached Bloom's application memory budget.") }
      await GenerationCoordinator.shared.leave()
      return result
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  /// One producer, one prompt prefill, and one weight-reading forward pass per
  /// decoding step. Rows never compact: their shape is part of seeded replay.
  func runBatch(rawPrompt: String, maxTokens: Int, settings: SamplingSettings, seeds: [UInt64],
    flag: CancellationFlag, background: Bool = false,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable (Int, GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onMetrics: (@Sendable (BatchMetrics) async -> Void)? = nil
  ) async throws -> [Output] {
    try ProductCore.admitWritingBatch(width: seeds.count, prompt: 1, output: maxTokens, capacity: 16_384)
    if seeds.count == 1 {
      return [try await run(rawPrompt: rawPrompt, maxTokens: maxTokens, settings: settings,
        seed: seeds[0], flag: flag, background: background, onPrefill: onPrefill,
        onCheckpoint: { progress, stop, token in try await onCheckpoint?(0, progress, stop, token) },
        onText: { _ in })]
    }
    return try await ownedOperation(flag: flag, background: background) {
      try await self.generateBatchOwned(raw: rawPrompt, maxTokens: maxTokens, settings: settings,
        seeds: seeds, flag: flag, onPrefill: onPrefill, onCheckpoint: onCheckpoint, onMetrics: onMetrics)
    }
  }
  private func generateBatchOwned(raw: String, maxTokens: Int, settings: SamplingSettings,
    seeds: [UInt64], flag: CancellationFlag,
    onPrefill: (@Sendable (PrefillProgress) -> Void)?,
    onCheckpoint: (@Sendable (Int, GenerationProgress, String?, Int?) async throws -> Void)?,
    onMetrics: (@Sendable (BatchMetrics) async -> Void)?
  ) async throws -> [Output] {
    try flag.check()
    let capacity = try availableContext(batchWidth: seeds.count), policy = generationPolicy
    let prefill = try prefillParameters(onPrefill, operationID: flag.operationID)
    let controls = Set(policy.controlTokenIDs), ends = Set(policy.eosTokenIDs)
    return try await container.perform { (context: ModelContext) async throws -> [Output] in
      try await InferenceExecutor.shared.perform { _ in
        defer { Stream.defaultStream.synchronize() }
        let promptIDs = context.tokenizer.encode(text: raw, addSpecialTokens: false)
        try ProductCore.admitWritingBatch(width: seeds.count, prompt: promptIDs.count,
          output: maxTokens, capacity: capacity)
        let digest = Digest.sha256(try JSONEncoder().encode(promptIDs))
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: settings.temperature,
          topP: settings.topP, topK: settings.topK, minP: settings.minP, repetitionPenalty: nil,
          prefill: prefill)
        let cache = try context.model.newCache(parameters: parameters)
        let clock = ContinuousClock(), started = clock.now
        let prepared = try context.model.prepare(LMInput(tokens: MLXArray(promptIDs)),
          cache: cache, state: nil, prefill: parameters.prefill)
        let initial: LMOutput
        switch prepared {
        case .logits(let output): initial = output
        case .tokens(let tail):
          initial = context.model(LMInput.Text(tokens: tail.tokens.expandedDimensions(axis: 0)), cache: cache, state: nil)
        }
        guard initial.state == nil else { throw BoomError.invalid("This checkpoint needs unsupported per-row inference state.") }
        var logits = initial.logits[0..., -1, 0...]
        eval(logits); eval(cache)
        try flag.check()
        // Preserve each existing cache object's offsets and rotating-window
        // metadata. Only its leading tensor dimension changes.
        for var entry in cache {
          let state = entry.state
          if state.isEmpty { continue } // Gemma's shared-KV layers have no own tensors.
          guard (entry is KVCacheSimple || entry is RotatingKVCache), state.count == 2,
            state.allSatisfy({ $0.ndim == 4 && $0.dim(0) == 1 }) else {
            throw BoomError.invalid("Unsupported cache layout for batched writing.")
          }
          entry.state = state.map { broadcast($0, to: [seeds.count] + Array($0.shape.dropFirst())) }
        }
        eval(cache)
        logits = broadcast(logits, to: [seeds.count, logits.dim(1)])
        let mask = CheckpointTokenMask(policy.suppressedTokenIDs)
        let samplers = seeds.map { seed in
          GenerateParameters(temperature: settings.temperature, topP: settings.topP,
            topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, seed: seed).sampler()
        }
        var tokens = Array(repeating: [Int](), count: seeds.count)
        var texts = Array(repeating: "", count: seeds.count)
        var first = Array<Double?>(repeating: nil, count: seeds.count)
        var reasons = Array<String?>(repeating: nil, count: seeds.count)
        var stops = Array<Int?>(repeating: nil, count: seeds.count)
        var elapsed = Array(repeating: 0.0, count: seeds.count)
        var decodePasses = 0
        // Finished rows remain inert occupants of the original shape. They never
        // sample again or emit another checkpoint, and cannot affect other rows.
        let inertToken = policy.eosTokenIDs[0]
        while reasons.contains(nil), !flag.isCancelled, !Task.isCancelled {
          let sampled: [Int] = autoreleasepool {
            let filtered = mask.process(logits: logits)
            let next = samplers.indices.map { lane in
              reasons[lane] == nil
                ? samplers[lane].sample(logits: filtered[lane].expandedDimensions(axis: 0)).reshaped([1])
                : MLXArray([inertToken])
            }
            let joined = concatenated(next, axis: 0)
            eval(joined)
            return joined.asArray(Int.self)
          }
          for lane in seeds.indices where reasons[lane] == nil {
            let token = sampled[lane]
            guard !policy.suppressedTokenIDs.contains(token) else {
              throw BoomError.invalid("A batch row emitted an excluded checkpoint token.")
            }
            if controls.contains(token) {
              reasons[lane] = ends.contains(token) ? "eos" : "model_control"; stops[lane] = token
            } else {
              if first[lane] == nil { first[lane] = started.duration(to: clock.now).timeInterval }
              tokens[lane].append(token)
              if tokens[lane].count == maxTokens { reasons[lane] = "output_limit" }
            }
            let decoded = context.tokenizer.decode(tokenIds: tokens[lane])
            elapsed[lane] = started.duration(to: clock.now).timeInterval
            if reasons[lane] != nil || (!decoded.hasSuffix("\u{FFFD}") && decoded != texts[lane]) {
              try await onCheckpoint?(lane, GenerationProgress(text: decoded, tokenIDs: tokens[lane],
                promptDigest: digest, promptTokens: promptIDs.count, firstTokenSeconds: first[lane],
                elapsedSeconds: elapsed[lane]), reasons[lane], stops[lane])
              texts[lane] = decoded
            }
          }
          if reasons.contains(nil), !flag.isCancelled, !Task.isCancelled {
            logits = try autoreleasepool {
              let output = context.model(LMInput.Text(tokens: MLXArray(sampled).reshaped([seeds.count, 1])),
                cache: cache, state: nil)
              guard output.state == nil else { throw BoomError.invalid("Unexpected batch inference state.") }
              let next = output.logits[0..., -1, 0...]
              guard next.ndim == 2, next.dim(0) == seeds.count else { throw BoomError.invalid("The model lost its batch rows.") }
              eval(next); eval(cache)
              return next
            }
            decodePasses += 1
          }
        }
        for lane in seeds.indices where reasons[lane] == nil {
          reasons[lane] = "cancelled"
          elapsed[lane] = started.duration(to: clock.now).timeInterval
          texts[lane] = context.tokenizer.decode(tokenIds: tokens[lane])
          try await onCheckpoint?(lane, GenerationProgress(text: texts[lane], tokenIDs: tokens[lane],
            promptDigest: digest, promptTokens: promptIDs.count, firstTokenSeconds: first[lane],
            elapsedSeconds: elapsed[lane]), reasons[lane], nil)
        }
        await onMetrics?(BatchMetrics(width: seeds.count, sharedPromptPrefills: 1,
          decodeForwardPasses: decodePasses,
          cacheBatchDimensions: cache.flatMap { $0.state.map { $0.dim(0) } }))
        return seeds.indices.map { lane in
          Output(text: texts[lane], tokenIDs: tokens[lane], promptDigest: digest, promptTokens: promptIDs.count,
            outputTokens: tokens[lane].count, endedByEOS: stops[lane] != nil, stopReason: reasons[lane] ?? "cancelled",
            stopTokenID: stops[lane], firstTokenSeconds: first[lane], elapsedSeconds: elapsed[lane])
        }
      }
    }
  }
  private func generateOwned(plan: ConsultationPlan?, raw: String?, images: [Data], maxTokens: Int,
    settings: SamplingSettings, seed: UInt64?, flag: CancellationFlag,
    onPrefill: (@Sendable (PrefillProgress) -> Void)?,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)?,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try flag.check()
    let capacity = try availableContext(), policy = generationPolicy
    let prefill = try prefillParameters(onPrefill, operationID: flag.operationID)
    let controls = Set(policy.controlTokenIDs), ends = Set(policy.eosTokenIDs)
    return try await container.perform { (context: ModelContext) async throws -> Output in
      try await InferenceExecutor.shared.perform { _ in
        defer { Stream.defaultStream.synchronize() }
        let input: LMInput
        if let plan { input = try await Self.chatInput(plan, images: images, context: context) }
        else if let raw { input = LMInput(tokens: MLXArray(context.tokenizer.encode(text: raw, addSpecialTokens: false))) }
        else { throw BoomError.invalid("No compiled model input.") }
        let promptIDs = input.text.tokens.asArray(Int.self)
        guard promptIDs.count + maxTokens <= capacity else { throw BoomError.budget("The request exceeds available context.") }
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: settings.temperature,
          topP: settings.topP, topK: settings.topK, minP: settings.minP, repetitionPenalty: nil,
          prefill: prefill, seed: seed)
        let preparedDigest = Digest.sha256(try JSONEncoder().encode(promptIDs))
        // TokenIterator performs prompt prefill during task construction.
        // Start before it so first-token and elapsed time include that work.
        let clock = ContinuousClock(), started = clock.now
        let components = GenerationComponents(logitProcessorFactory: { CheckpointTokenMask(policy.suppressedTokenIDs) })
        let (stream, task) = try generateTokensTask(input: input, parameters: parameters, context: context,
          includeStopToken: true, components: components)
        var tokens: [Int] = [], text = "", ended = false, reason = "output_limit"
        var first: Double?; var stopToken: Int?
        do {
          for await event in stream {
            if flag.isCancelled || Task.isCancelled { task.cancel(); break }
            switch event {
            case .token(let token):
              guard !policy.suppressedTokenIDs.contains(token) else {
                throw BoomError.invalid("The model emitted a token excluded by its checkpoint policy.")
              }
              if controls.contains(token) {
                stopToken = token; reason = ends.contains(token) ? "eos" : "model_control"
                ended = true; task.cancel(); break
              }
              if first == nil { first = started.duration(to: clock.now).timeInterval }
              tokens.append(token)
              let decoded = context.tokenizer.decode(tokenIds: tokens)
              if !decoded.hasSuffix("\u{FFFD}"), decoded != text {
                // Every displayed update is durable before it reaches a view.
                // Awaiting the store also bounds the checkpoint producer.
                try await onCheckpoint?(GenerationProgress(text: decoded,
                  tokenIDs: tokens, promptDigest: preparedDigest, promptTokens: promptIDs.count,
                  firstTokenSeconds: first, elapsedSeconds: started.duration(to: clock.now).timeInterval), nil, nil)
                text = decoded; onText(text)
              }
            case .info(let info):
              switch info.stopReason {
              case .stop: ended = true; reason = "eos"
              case .length: reason = "output_limit"
              case .cancelled: reason = "cancelled"
              }
            }
            if ended { break }
          }
        } catch {
          task.cancel()
          await task.value
          throw error
        }
        if flag.isCancelled || Task.isCancelled { task.cancel() }
        await task.value
        // Joining must retain the producer's emitted tokens even on cancellation.
        // Callers persist this receipt before propagating their cancelled operation.
        if flag.isCancelled || Task.isCancelled { reason = "cancelled" }
        let final = context.tokenizer.decode(tokenIds: tokens)
        let elapsed = started.duration(to: clock.now).timeInterval
        try await onCheckpoint?(GenerationProgress(text: final, tokenIDs: tokens,
          promptDigest: preparedDigest, promptTokens: promptIDs.count, firstTokenSeconds: first,
          elapsedSeconds: elapsed), reason, stopToken)
        if final != text, reason != "cancelled" { onText(final) }
        return Output(text: final, tokenIDs: tokens, promptDigest: preparedDigest,
          promptTokens: promptIDs.count, outputTokens: tokens.count, endedByEOS: ended, stopReason: reason, stopTokenID: stopToken,
          firstTokenSeconds: first, elapsedSeconds: elapsed)
      }
    }
  }
  func join() async { await GenerationCoordinator.shared.enter(); await GenerationCoordinator.shared.leave() }
}

extension Duration {
  var timeInterval: Double {
    let value = components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
  }
}
