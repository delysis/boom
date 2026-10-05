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
  private var waiting: [(CancellationFlag?, Bool, CheckedContinuation<Void, Never>)] = []
  var queuedOperations: Int { waiting.count }
  func enter(flag: CancellationFlag? = nil, background: Bool = false) async {
    if !occupied { occupied = true; activeFlag = flag; self.background = background; return }
    if !background, self.background { activeFlag?.cancel(); producer?.cancel() }
    await withCheckedContinuation { waiting.append((flag, background, $0)) }
  }
  func own(_ task: Task<Void, Never>) { producer = task }
  func leave() async {
    if let producer { await producer.value }
    producer = nil; activeFlag = nil
    if waiting.isEmpty { occupied = false; background = false }
    else {
      let index = waiting.firstIndex { !$0.1 } ?? 0
      let next = waiting.remove(at: index); activeFlag = next.0; background = next.1; next.2.resume()
    }
  }
}

/// Mutable model state is confined to this actor and ModelContainer.
actor MLXGemmaRunner {
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
  nonisolated let source: URL
  nonisolated let identity: String
  nonisolated let generationPolicy: ModelGenerationPolicy
  private let container: ModelContainer
  private let architectureContext: Int
  private let kvBytesPerToken: UInt64
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
  static func load(directory: URL, identity: String? = nil) async throws -> MLXGemmaRunner {
    await GenerationCoordinator.shared.enter()
    do {
      let config = try JSONDecoder().decode(Configuration.self,
        from: Data(contentsOf: directory.appendingPathComponent("config.json")))
      let text = config.text_config
      guard config.model_type == "gemma4_unified", text.max_position_embeddings > 0,
        text.num_hidden_layers > 0, text.num_key_value_heads > 0, text.head_dim > 0
      else { throw BoomError.invalid("This is not the supported Gemma 4 12B model.") }
      let tokenizerDescription = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
      let tokenizer = try JSONDecoder().decode(TokenizerFile.self, from: tokenizerDescription)
      let generationURL = directory.appendingPathComponent("generation_config.json")
      let generationDescription = try Data(contentsOf: generationURL)
      let model = try await VLMModelFactory.shared.loadContainer(
        from: directory, using: #huggingFaceTokenizerLoader())
      guard tokenizerDescription == (try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))),
        generationDescription == (try Data(contentsOf: generationURL)) else {
        throw BoomError.stale("The tokenizer or generation configuration changed while the model was loading.")
      }
      let tokenizerEnds = await model.perform { ($0.tokenizer.eosTokenId, $0.tokenizer.unknownTokenId) }
      let controls = tokenizer.added_tokens.filter(\.special).map(\.id) + (tokenizerEnds.1.map { [$0] } ?? [])
      let policy = try ProductCore.generationPolicy(vocabularySize: text.vocab_size,
        configuration: generationDescription, controls: controls, tokenizerEOS: tokenizerEnds.0)
      let runner = MLXGemmaRunner(source: directory, container: model,
        identity: try identity ?? ModelInstaller.hashFile(directory.appendingPathComponent(ModelPacks.manifestName), maxBytes: 4_194_304).sha256,
        architectureContext: text.max_position_embeddings,
        kvBytesPerToken: UInt64(text.num_hidden_layers) * UInt64(text.num_key_value_heads)
          * UInt64(text.head_dim) * 4,
        generationPolicy: policy, tokenizerDescription: tokenizerDescription)
      guard try runner.availableContext() >= 1024 else {
        throw BoomError.budget("The model leaves too little memory for a useful context.")
      }
      await GenerationCoordinator.shared.leave()
      return runner
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  private init(source: URL, container: ModelContainer, identity: String,
    architectureContext: Int, kvBytesPerToken: UInt64, generationPolicy: ModelGenerationPolicy, tokenizerDescription: Data) {
    self.source = source; self.identity = identity
    self.container = container; self.architectureContext = architectureContext
    self.kvBytesPerToken = kvBytesPerToken; self.generationPolicy = generationPolicy
    self.tokenizerDescription = tokenizerDescription
  }
  private nonisolated func availableContext() throws -> Int {
    min(16_384, architectureContext, Int(clamping: try ModelResidency.availableBytes() / kvBytesPerToken))
  }
  var contextLength: Int { (try? availableContext()) ?? 0 }
  func tokenCount(_ text: String) async -> Int {
    await container.perform { $0.tokenizer.encode(text: text, addSpecialTokens: false).count }
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
    examples: [String], profile: SamplingProfile, maxTokens: Int, flag: CancellationFlag
  ) async throws -> CompletionRecipe {
    let capacity = try availableContext() - maxTokens
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
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await generate(plan: nil, raw: rawPrompt, images: [], maxTokens: maxTokens,
      settings: settings ?? ProductCore.sampling(.standard), seed: seed, flag: flag, background: background,
      onCheckpoint: onCheckpoint, onText: onText)
  }
  private func generate(plan: ConsultationPlan?, raw: String?, images: [Data], maxTokens: Int,
    settings: SamplingSettings, seed: UInt64?, flag: CancellationFlag,
    background: Bool = false,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    await GenerationCoordinator.shared.enter(flag: flag, background: background)
    do {
      try flag.check()
      let capacity = try availableContext(), policy = generationPolicy
      let controls = Set(policy.controlTokenIDs), ends = Set(policy.eosTokenIDs)
      let result = try await container.perform { (context: ModelContext) async throws -> Output in
        let input: LMInput
        if let plan { input = try await Self.chatInput(plan, images: images, context: context) }
        else if let raw { input = LMInput(tokens: MLXArray(context.tokenizer.encode(text: raw, addSpecialTokens: false))) }
        else { throw BoomError.invalid("No compiled model input.") }
        let promptIDs = input.text.tokens.asArray(Int.self)
        guard promptIDs.count + maxTokens <= capacity else { throw BoomError.budget("The request exceeds available context.") }
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: settings.temperature,
          topP: settings.topP, topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, seed: seed)
        let preparedDigest = Digest.sha256(try JSONEncoder().encode(promptIDs))
        // TokenIterator performs prompt prefill during task construction.
        // Start before it so first-token and elapsed time include that work.
        let clock = ContinuousClock(), started = clock.now
        let components = GenerationComponents(logitProcessorFactory: { CheckpointTokenMask(policy.suppressedTokenIDs) })
        let (stream, task) = try generateTokensTask(input: input, parameters: parameters, context: context,
          includeStopToken: true, components: components)
        await GenerationCoordinator.shared.own(task)
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
      await GenerationCoordinator.shared.leave()
      return result
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  func join() async { await GenerationCoordinator.shared.enter(); await GenerationCoordinator.shared.leave() }
}

extension Duration {
  var timeInterval: Double {
    let value = components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
  }
}
