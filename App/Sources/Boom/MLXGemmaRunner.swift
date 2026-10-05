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
  private let container: ModelContainer
  private let architectureContext: Int
  private let kvBytesPerToken: UInt64
  private let controlTokens: Set<Int>
  private struct Configuration: Decodable {
    let model_type: String
    let text_config: Text
    struct Text: Decodable {
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
      let tokenizer = try JSONDecoder().decode(TokenizerFile.self,
        from: Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
      let model = try await VLMModelFactory.shared.loadContainer(
        from: directory, using: #huggingFaceTokenizerLoader())
      let runner = MLXGemmaRunner(source: directory, container: model,
        identity: try identity ?? ModelInstaller.hashFile(directory.appendingPathComponent(ModelPacks.manifestName), maxBytes: 4_194_304).sha256,
        architectureContext: text.max_position_embeddings,
        kvBytesPerToken: UInt64(text.num_hidden_layers) * UInt64(text.num_key_value_heads)
          * UInt64(text.head_dim) * 4,
        controlTokens: Set(tokenizer.added_tokens.filter(\.special).map(\.id)))
      guard try runner.availableContext() >= 1024 else {
        throw BoomError.budget("The model leaves too little memory for a useful context.")
      }
      await GenerationCoordinator.shared.leave()
      return runner
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  private init(source: URL, container: ModelContainer, identity: String,
    architectureContext: Int, kvBytesPerToken: UInt64, controlTokens: Set<Int>) {
    self.source = source; self.identity = identity
    self.container = container; self.architectureContext = architectureContext
    self.kvBytesPerToken = kvBytesPerToken; self.controlTokens = controlTokens
  }
  private nonisolated func availableContext() throws -> Int {
    min(16_384, architectureContext, Int(clamping: try ModelResidency.availableBytes() / kvBytesPerToken))
  }
  var contextLength: Int { (try? availableContext()) ?? 0 }
  func tokenCount(_ text: String) async -> Int {
    await container.perform { $0.tokenizer.encode(text: text, addSpecialTokens: false).count }
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
    let full = try ProductCore.writingPrompt(document, caret: caret, examples: examples, retaining: Int.max)
    guard full.totalCharacters > 0 else { throw BoomError.unavailable("Write some text before requesting a continuation.") }
    let capacity = try availableContext() - maxTokens
    let empty = try ProductCore.writingPrompt(document, caret: caret, examples: examples, retaining: 0)
    guard capacity > 0, await tokenCount(empty.prompt) < capacity else { throw BoomError.budget("The examples leave no room for the manuscript.") }
    var selected = full
    if await tokenCount(full.prompt) > capacity {
      var low = 1, high = full.totalCharacters
      while low < high {
        try flag.check()
        let middle = low + (high - low + 1) / 2
        let candidate = try ProductCore.writingPrompt(document, caret: caret, examples: examples, retaining: middle)
        if await tokenCount(candidate.prompt) <= capacity { low = middle } else { high = middle - 1 }
      }
      selected = try ProductCore.writingPrompt(document, caret: caret, examples: examples, retaining: low)
    }
    guard await tokenCount(selected.prompt) <= capacity else { throw BoomError.budget("The text at the caret does not fit.") }
    return CompletionRecipe(document: document, caretUTF16: caret, sources: sources,
      prompt: selected.prompt, promptDigest: selected.digest, omittedPrefixCharacters: selected.omittedCharacters,
      model: identity, profile: profile, settings: try ProductCore.sampling(profile), maxTokens: maxTokens)
  }
  func run(plan: ConsultationPlan, images: [Data], maxTokens: Int, seed: UInt64? = nil,
    flag: CancellationFlag,
    onCheckpoint: (@Sendable (GenerationProgress, String?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await generate(plan: plan, raw: nil, images: images, maxTokens: maxTokens,
      settings: ProductCore.sampling(.standard), seed: seed, flag: flag, onCheckpoint: onCheckpoint, onText: onText)
  }
  func run(rawPrompt: String, maxTokens: Int, settings: SamplingSettings? = nil, seed: UInt64? = nil,
    flag: CancellationFlag, background: Bool = false,
    onCheckpoint: (@Sendable (GenerationProgress, String?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await generate(plan: nil, raw: rawPrompt, images: [], maxTokens: maxTokens,
      settings: settings ?? ProductCore.sampling(.standard), seed: seed, flag: flag, background: background,
      onCheckpoint: onCheckpoint, onText: onText)
  }
  private func generate(plan: ConsultationPlan?, raw: String?, images: [Data], maxTokens: Int,
    settings: SamplingSettings, seed: UInt64?, flag: CancellationFlag,
    background: Bool = false,
    onCheckpoint: (@Sendable (GenerationProgress, String?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    await GenerationCoordinator.shared.enter(flag: flag, background: background)
    do {
      try flag.check()
      let capacity = try availableContext(), controls = controlTokens
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
        let (stream, task) = try generateTokensTask(input: input, parameters: parameters, context: context)
        await GenerationCoordinator.shared.own(task)
        var tokens: [Int] = [], text = "", ended = false, reason = "output_limit"
        let clock = ContinuousClock(), started = clock.now
        var first: Double?; var stopToken: Int?
        do {
          for await event in stream {
            if flag.isCancelled || Task.isCancelled { task.cancel(); break }
            switch event {
            case .token(let token):
              if controls.contains(token) { stopToken = token; reason = "model_control"; ended = true; task.cancel(); break }
              if first == nil { first = started.duration(to: clock.now).timeInterval }
              tokens.append(token)
              let decoded = context.tokenizer.decode(tokenIds: tokens)
              if !decoded.hasSuffix("\u{FFFD}"), decoded != text {
                // Every displayed update is durable before it reaches a view.
                // Awaiting the store also bounds the checkpoint producer.
                try await onCheckpoint?(GenerationProgress(text: decoded,
                  tokenIDs: tokens, promptDigest: preparedDigest, promptTokens: promptIDs.count,
                  firstTokenSeconds: first, elapsedSeconds: started.duration(to: clock.now).timeInterval), nil)
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
          elapsedSeconds: elapsed), reason)
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

private extension Duration {
  var timeInterval: Double {
    let value = components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
  }
}
