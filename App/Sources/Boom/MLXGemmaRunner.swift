import Foundation
import Metal
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
import BoomCore

enum GemmaGeneratedText {
  // Multimodal and turn delimiters are model control tokens, never manuscript.
  private static let delimiters = ["<image|>", "<audio|>", "<video|>", "<|", "<channel|>"]

  static func visiblePrefix(_ raw: String, final: Bool) -> String {
    if let first = delimiters.compactMap({ raw.range(of: $0)?.lowerBound }).min() {
      return String(raw[..<first])
    }
    guard !final else { return raw }
    for length in stride(from: delimiters.map(\.count).max()! - 1, through: 1, by: -1) {
      if delimiters.contains(where: { marker in
        marker.count > length && raw.hasSuffix(marker.prefix(length))
      }) {
        return String(raw.dropLast(length))
      }
    }
    return raw
  }
}

/// Native Swift/GPU inference for first-party Gemma 4 safetensors. This backend
/// never interprets a document as a chat turn: the caller supplies exact token
/// text, and tokenization adds no second template or hidden instruction.
final class MLXGemmaRunner: @unchecked Sendable {
  /// Google's Gemma 4 template opens the final channel explicitly when
  /// thinking is disabled. The older CoreML bundle stops at `model\n`.
  static func chatPrompt(history: [ChatMessage], request: String) -> String {
    GemmaPrompt.conversation(history: history, request: request)
      + "<|channel>thought\n<channel|>"
  }
  struct Output: Sendable {
    let text: String
    let promptTokens: Int
    let outputTokens: Int
    let endedByEOS: Bool
    let proposedDraftTokens: Int
    let acceptedDraftTokens: Int
  }

  let size: GemmaSize
  let contextLength: Int
  let source: URL
  private let container: ModelContainer
  private let drafter: Gemma4AssistantDraftModel?
  private let gate = Gate()

  private actor Gate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
      if !occupied { occupied = true; return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func leave() {
      if waiters.isEmpty { occupied = false }
      else { waiters.removeFirst().resume() }
    }
    func join() async {
      await enter()
      leave()
    }
  }

  private struct Configuration: Decodable {
    let modelType: String
    let text: Text
    struct Text: Decodable {
      let maxPositionEmbeddings: Int
      let numHiddenLayers: Int
      let numKeyValueHeads: Int
      let headDim: Int
      let hiddenSize: Int
      let vocabularySize: Int
      enum CodingKeys: String, CodingKey {
        case maxPositionEmbeddings = "max_position_embeddings"
        case numHiddenLayers = "num_hidden_layers"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case hiddenSize = "hidden_size"
        case vocabularySize = "vocab_size"
      }
    }
    enum CodingKeys: String, CodingKey {
      case modelType = "model_type"
      case text = "text_config"
    }
  }

  static func load(
    directory: URL, assistantDirectory: URL? = nil, size: GemmaSize
  ) async throws -> MLXGemmaRunner {
    let config = try JSONDecoder().decode(
      Configuration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
    guard config.modelType == "gemma4" || config.modelType == "gemma4_unified",
      config.text.maxPositionEmbeddings > 0,
      config.text.numHiddenLayers > 0,
      config.text.numKeyValueHeads > 0,
      config.text.headDim > 0, config.text.hiddenSize > 0,
      config.text.vocabularySize > 0
    else { throw BoomError.invalid("This folder is not a supported Gemma 4 checkpoint.") }
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw BoomError.unavailable("This Mac has no Metal inference device.")
    }
    let model = try await VLMModelFactory.shared.loadContainer(
      from: directory, using: #huggingFaceTokenizerLoader())
    let drafter: Gemma4AssistantDraftModel?
    if let assistantDirectory {
      let assistantConfiguration = try JSONDecoder().decode(
        Gemma4AssistantConfiguration.self,
        from: Data(contentsOf: assistantDirectory.appendingPathComponent("config.json")))
      guard assistantConfiguration.modelType == "gemma4_assistant"
          || assistantConfiguration.modelType == "gemma4_unified_assistant",
        assistantConfiguration.backboneHiddenSize == config.text.hiddenSize,
        assistantConfiguration.textConfiguration.vocabularySize == config.text.vocabularySize
      else { throw BoomError.invalid("The Gemma assistant does not match the target model.") }
      let loaded = Gemma4AssistantDraftModel(assistantConfiguration)
      try await loadWeights(modelDirectory: assistantDirectory, model: loaded)
      drafter = loaded
    } else {
      drafter = nil
    }
    // A full-length, fp16 K/V estimate is conservative for Gemma's sliding
    // layers. The live Metal working-set allowance determines the actual cap.
    let kvBytesPerToken = UInt64(config.text.numHiddenLayers)
      * UInt64(config.text.numKeyValueHeads) * UInt64(config.text.headDim) * 4
    let context = ModelMemoryPolicy.maximumContext(
      architectureLimit: config.text.maxPositionEmbeddings,
      workingSetBytes: device.recommendedMaxWorkingSetSize,
      residentBytes: UInt64(max(0, Memory.activeMemory)),
      kvBytesPerToken: kvBytesPerToken)
    guard context >= 1024 else {
      throw BoomError.budget("The loaded model leaves too little GPU memory for a useful context.")
    }
    return MLXGemmaRunner(
      size: size, contextLength: context, source: directory,
      container: model, drafter: drafter)
  }

  private init(
    size: GemmaSize, contextLength: Int, source: URL,
    container: ModelContainer, drafter: Gemma4AssistantDraftModel?
  ) {
    self.size = size
    self.contextLength = contextLength
    self.source = source
    self.container = container
    self.drafter = drafter
  }

  func tokenCount(_ text: String) async -> Int {
    await container.perform { context in
      context.tokenizer.encode(text: text, addSpecialTokens: false).count
    }
  }

  func fitConversation(
    history: [ChatMessage], instructions: String, context: String,
    request: String, maxOutputTokens: Int, flag: CancellationFlag
  ) async throws -> FittedConversation {
    let capacity = contextLength - maxOutputTokens
    guard capacity > 0 else { throw BoomError.budget("The model has no room for a reply.") }
    func fits(_ kept: [ChatMessage], _ excerpt: String) async -> Bool {
      let body = [instructions, excerpt, request].filter { !$0.isEmpty }
        .joined(separator: "\n\n")
      let prompt = GemmaPrompt.conversation(history: kept, request: body)
      return await tokenCount(prompt) <= capacity
    }
    for dropped in 0...history.count {
      try flag.check()
      let kept = Array(history.dropFirst(dropped))
      if await fits(kept, context) {
        return FittedConversation(
          history: kept, context: context, omittedHistoryCount: dropped,
          omittedContextCharacters: 0)
      }
      guard !context.isEmpty, await fits(kept, ContextExcerpt.middle(context, keeping: 0))
      else { continue }
      var low = 0
      var high = context.count
      while low < high {
        try flag.check()
        let middle = low + (high - low + 1) / 2
        if await fits(kept, ContextExcerpt.middle(context, keeping: middle)) { low = middle }
        else { high = middle - 1 }
      }
      return FittedConversation(
        history: kept, context: ContextExcerpt.middle(context, keeping: low),
        omittedHistoryCount: dropped, omittedContextCharacters: context.count - low)
    }
    throw BoomError.budget("The current request exceeds available model context.")
  }

  struct Completion: Sendable {
    let output: Output
    let window: CompletionWindow
  }

  func complete(
    document: DocumentSnapshot, caret: Int, context: ContextPlan,
    flag: CancellationFlag, useDraft: Bool = true, seed: UInt64? = nil,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> Completion {
    var before = 2048
    let after = 512
    let sourceLength = context.documents.reduce(0) { $0 + $1.text.count }
    var sourceCharacters: Int? = context.documents.isEmpty ? nil : sourceLength
    func prompt(_ characters: Int, _ sources: Int?) throws -> String {
      try GemmaPrompt.completion(
        document: document, caretUTF16: caret, context: context,
        prefixCharacters: characters, suffixCharacters: after,
        sourceBodyCharacters: sources)
    }
    func fits(_ value: String) async -> Bool {
      await tokenCount(value) + 64 <= contextLength
    }
    var value = try prompt(before, sourceCharacters)
    if !(await fits(value)), sourceLength > 0 {
      var low = 0
      var high = sourceLength
      while low < high {
        try flag.check()
        let middle = low + (high - low + 1) / 2
        if await fits(try prompt(before, middle)) { low = middle }
        else { high = middle - 1 }
      }
      sourceCharacters = low
      value = try prompt(before, sourceCharacters)
    }
    while !(await fits(value)) {
      try flag.check()
      guard before > 1 else {
        throw BoomError.budget("The text at the caret exceeds available model context.")
      }
      before = max(1, before / 2)
      value = try prompt(before, sourceCharacters)
    }
    let window = try CompletionWindow(
      document: document, caretUTF16: caret, prefixCharacters: before,
      suffixCharacters: after)
    let output = try await run(rawPrompt: value, maxTokens: 64, flag: flag,
      useDraft: useDraft, seed: seed, onText: onText)
    return Completion(output: output, window: window)
  }

  func run(
    rawPrompt: String, maxTokens: Int, flag: CancellationFlag,
    useDraft: Bool = true, seed: UInt64? = nil,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> Output {
    try await run(input: .raw(rawPrompt), maxTokens: maxTokens, flag: flag,
      useDraft: useDraft, seed: seed, onText: onText)
  }

  func runChat(
    history: [ChatMessage], request: String, images: [Data],
    maxTokens: Int, flag: CancellationFlag,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> Output {
    try await run(input: .chat(history: history, request: request, images: images),
      maxTokens: maxTokens, flag: flag, useDraft: false, onText: onText)
  }

  private enum PromptInput: Sendable {
    case raw(String)
    case chat(history: [ChatMessage], request: String, images: [Data])
  }

  private static func validatedImage(_ data: Data) throws -> UserInput.Image {
    .ciImage(try LocalImage.decode(data))
  }

  private func run(
    input prompt: PromptInput, maxTokens: Int, flag: CancellationFlag,
    useDraft: Bool, seed: UInt64? = nil,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> Output {
    await gate.enter()
    do {
      let result = try await container.perform { context -> Output in
        try flag.check()
        let input: LMInput
        let promptTokens: Int
        switch prompt {
        case .raw(let rawPrompt):
          let ids = context.tokenizer.encode(text: rawPrompt, addSpecialTokens: false)
          input = LMInput(tokens: MLXArray(ids))
          promptTokens = ids.count
        case .chat(let history, let request, let images):
          let media = try images.map(Self.validatedImage)
          let messages: [Chat.Message] = history.filter { $0.state == .complete }.map {
            $0.role == .user ? .user($0.text) : .assistant($0.text)
          } + [.user(request, images: media)]
          input = try await context.processor.prepare(input: UserInput(chat: messages))
          promptTokens = input.text.tokens.shape.last ?? 0
        }
        guard promptTokens + maxTokens <= self.contextLength else {
          throw BoomError.budget("The request exceeds available model context.")
        }
        let parameters = GenerateParameters(
          maxTokens: maxTokens, temperature: 0.7, topP: 0.95,
          repetitionPenalty: 1.1, repetitionContextSize: 64, seed: seed)
        let (stream, task): (AsyncStream<Generation>, Task<Void, Never>)
        if useDraft {
          guard let drafter = self.drafter else {
            throw BoomError.unavailable("This model has no matching draft assistant.")
          }
          let iterator = try MTPSpeculativeTokenIterator(
            input: input, mainModel: context.model, drafter: drafter,
            parameters: parameters, blockSize: 4)
          (stream, task) = generateTask(
            promptTokenCount: promptTokens, modelConfiguration: context.configuration,
            tokenizer: context.tokenizer, iterator: iterator)
        } else {
          let iterator = try TokenIterator(
            input: input, model: context.model, parameters: parameters)
          (stream, task) = generateTask(
            promptTokenCount: promptTokens, modelConfiguration: context.configuration,
            tokenizer: context.tokenizer, iterator: iterator)
        }
        var rawText = ""
        var text = ""
        var outputTokens = 0
        var endedByEOS = false
        var proposed = 0
        var accepted = 0
        for await event in stream {
          if flag.isCancelled {
            task.cancel()
            break
          }
          switch event {
          case .chunk(let chunk):
            rawText += chunk
            let visible = GemmaGeneratedText.visiblePrefix(rawText, final: false)
            if visible != text {
              text = visible
              onText(text)
            }
          case .info(let info):
            outputTokens = info.generationTokenCount
            if case .stop = info.stopReason { endedByEOS = true }
            proposed = info.proposedDraftTokens ?? 0
            accepted = info.acceptedDraftTokens ?? 0
          case .toolCall, .rejectedToolCall:
            break
          }
        }
        await task.value
        try flag.check()
        let finalText = GemmaGeneratedText.visiblePrefix(rawText, final: true)
        if finalText != text {
          text = finalText
          onText(text)
        }
        return Output(
          text: text, promptTokens: promptTokens, outputTokens: outputTokens,
          endedByEOS: endedByEOS, proposedDraftTokens: proposed,
          acceptedDraftTokens: accepted)
      }
      await gate.leave()
      return result
    } catch {
      await gate.leave()
      throw error
    }
  }

  func join() async { await gate.join() }

  /// QAT unquantized safetensors are Google's own trained weights. Reproduce
  /// their Q4_0 calibration rather than applying a fresh unrelated 4-bit grid.
  static func convertQAT(source: URL, destination: URL) async throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw BoomError.invalid("A converted model already exists at this location.")
    }
    let data = try Data(contentsOf: source.appendingPathComponent("config.json"))
    let type = try JSONDecoder().decode(Configuration.self, from: data).modelType
    let model: any BaseLanguageModel
    switch type {
    case "gemma4_unified": model = Gemma4Unified(try JSONDecoder().decode(
      Gemma4UnifiedConfiguration.self, from: data))
    case "gemma4": model = Gemma4(try JSONDecoder().decode(
      MLXVLM.Gemma4Configuration.self, from: data))
    default: throw BoomError.invalid("This is not a first-party Gemma 4 checkpoint.")
    }
    let options = ModelConversionOptions(bits: 4, groupSize: 32, calibration: .q4Zero)
    _ = try MLXLMCommon.convert(
      modelDirectory: source, model: model, to: destination, options: options)
  }

  /// A separate first-party base checkpoint supplies literal manuscript
  /// continuation. It has no chat template and no QAT-specific calibration.
  static func convertBase(source: URL, destination: URL) async throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw BoomError.invalid("A converted model already exists at this location.")
    }
    let data = try Data(contentsOf: source.appendingPathComponent("config.json"))
    let type = try JSONDecoder().decode(Configuration.self, from: data).modelType
    let model: any BaseLanguageModel
    switch type {
    case "gemma4_unified": model = Gemma4Unified(try JSONDecoder().decode(
      Gemma4UnifiedConfiguration.self, from: data))
    case "gemma4": model = Gemma4(try JSONDecoder().decode(
      MLXVLM.Gemma4Configuration.self, from: data))
    default: throw BoomError.invalid("This is not a first-party Gemma 4 checkpoint.")
    }
    let options = ModelConversionOptions(bits: 4, groupSize: 32)
    _ = try MLXLMCommon.convert(
      modelDirectory: source, model: model, to: destination, options: options)
  }
}
