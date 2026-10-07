import CryptoKit
import Darwin
import Dispatch
import Foundation
import MLX
import MLXNN
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Tokenizers
import Metal

/// Owned, developer-only instrumentation. Synchronization perturbs scheduling;
/// these are settled operation groups, never production kernel timings.
enum PrefillProfile {
  /// The same native queue configuration as Bloom's InferenceExecutor.
  /// This developer copy isolates scheduling without linking the application.
  private actor EntryExecutor {
    static let shared = EntryExecutor()
    private nonisolated let queue = DispatchSerialQueue(label: "com.delysis.Bloom.inference")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    func perform(_ action: sending (isolated EntryExecutor) throws -> Void) rethrows { try action(self) }
  }
  private struct Plan: Decodable {
    let pack: String; let fixture: String; let fixtureSHA256: String
    let model: String; let output: String
    let mode: String; let seed: UInt64; let sampling: Sampling
    let suppressedTokenIDs: [Int]
    struct Sampling: Decodable {
      let temperature: Float; let topP: Float; let topK: Int; let minP: Float
    }
  }
  private struct Fixture: Decodable {
    let model: String; let plan: Request; let outputs: [Output]
    struct Request: Decodable {
      let messages: [Message]
      struct Message: Decodable { let role: String; let content: String }
    }
    struct Output: Decodable { let prompt_digest: String; let prompt_tokens: Int }
  }
  private struct Observation: Encodable {
    let module: String; let input_shape: [Int]; let output_shape: [Int]
    let quantization_bits: Int?; let quantization_group_size: Int?
    let input_settlement_seconds: Double; let projection_seconds: Double
  }
  private final class Recorder {
    var enabled = false
    var observations: [Observation] = []
  }
  private final class MeasuredLinear: Linear {
    let original: Linear
    let name: String
    let recorder: Recorder
    init(_ original: Linear, name: String, recorder: Recorder) {
      self.original = original; self.name = name; self.recorder = recorder
      super.init(weight: original.weight, bias: original.bias)
    }
    override var shape: (Int, Int) { original.shape }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
      guard recorder.enabled else { return original(x) }
      let clock = ContinuousClock(), before = clock.now
      // Settle upstream work first. In particular o_proj's input settlement
      // includes attention/rotary/cache work, not the output projection itself.
      eval(x); Stream.defaultStream.synchronize()
      let start = clock.now
      let result = original(x)
      eval(result); Stream.defaultStream.synchronize()
      let quantized = original as? QuantizedLinear
      recorder.observations.append(Observation(module: name, input_shape: x.shape,
        output_shape: result.shape, quantization_bits: quantized?.bits,
        quantization_group_size: quantized?.groupSize,
        input_settlement_seconds: seconds(before.duration(to: start)),
        projection_seconds: seconds(start.duration(to: clock.now))))
      return result
    }
  }
  private struct Trial: Encodable {
    let trial: Int; let arm: String; let seconds: Double
    let logits_shape: [Int]; let logits_sha256: String; let logits_file: String
    let finite: Bool; let mlx_peak_bytes: Int; let observations: [Observation]
    var constructor_seconds: Double? = nil
    var selected_token_id: Int? = nil
    var thread_qos: UInt32? = nil
  }
  private struct Report: Encodable {
    let status: String; let model: String; let prompt_digest: String
    let input_tokens: Int; let prefill_tokens: Int; let modules: [String]
    let trials: [Trial]; let scope: String
    var backend = Backend()
  }
  private struct Backend: Encodable {
    let device_name: String
    let architecture: String
    let max_ops_override: String?
    let max_mb_override: String?
    init() {
      let device = MTLCreateSystemDefaultDevice()
      device_name = device?.name ?? "unavailable"
      architecture = device?.architecture.name ?? "unavailable"
      let environment = ProcessInfo.processInfo.environment
      max_ops_override = environment["MLX_MAX_OPS_PER_BUFFER"]
      max_mb_override = environment["MLX_MAX_MB_PER_BUFFER"]
    }
  }
  static func run(_ args: [String]) async throws {
    guard args.count == 3, args[2].hasPrefix("/") else { throw failure("Use --prefill-profile ABSOLUTE_PLAN.") }
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let output = URL(fileURLWithPath: plan.output)
    guard [plan.pack, plan.fixture, plan.output].allSatisfy({ $0.hasPrefix("/") }),
      ["profile", "entry", "priority", "executor"].contains(plan.mode),
      !FileManager.default.fileExists(atPath: output.path) else { throw failure("Require absolute paths and fresh output.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: plan.fixture))
    guard data.count <= 1_048_576, digest(data) == plan.fixtureSHA256 else { throw failure("Fixture binding differs.") }
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    guard fixture.model == plan.model, fixture.outputs.count == 1,
      fixture.outputs[0].prompt_tokens == 4096 else { throw failure("Require captured 4K consultation.") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    Memory.memoryLimit = 24 * 1_073_741_824
    Memory.cacheLimit = 128 * 1_048_576
    let container = try await VLMModelFactory.shared.loadContainer(from: URL(fileURLWithPath: plan.pack),
      using: #huggingFaceTokenizerLoader())
    try await container.perform { context in
      let messages: [MLXLMCommon.Message] = fixture.plan.messages.map {
        ["role": $0.role, "content": $0.content]
      }
      let input = try await context.processor.prepare(input: UserInput(messages: messages,
        additionalContext: ["enable_thinking": false]))
      let ids = input.text.tokens.asArray(Int.self)
      guard ids.count == 4096, digest(try JSONEncoder().encode(ids)) == fixture.outputs[0].prompt_digest,
        input.image == nil, input.video == nil, input.audio == nil else { throw failure("Captured input differs.") }
      try JSONEncoder().encode(ids).write(to: output.appendingPathComponent("input-token-ids.json"), options: .atomic)
      if plan.mode != "profile" {
        if plan.mode == "entry" {
          try compareEntries(plan: plan, fixture: fixture, input: input, context: context, output: output)
        } else {
          let task = Task.detached(priority: .userInitiated) {
            if plan.mode == "executor" {
              try await EntryExecutor.shared.perform { _ in
                try compareEntries(plan: plan, fixture: fixture, input: input, context: context, output: output)
              }
            } else {
              try compareEntries(plan: plan, fixture: fixture, input: input, context: context, output: output)
            }
          }
          try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        return
      }
      let model: Module = context.model
      let recorder = Recorder()
      let originals = model.leafModules().flattened().compactMap { name, module -> (String, Linear)? in
        guard let linear = module as? Linear, name.hasPrefix("language_model.") else { return nil }
        return (name, linear)
      }.sorted { $0.0 < $1.0 }
      guard !originals.isEmpty else { throw failure("No text projection modules found.") }
      let replacements: [(String, Module)] = originals.map {
        ($0.0, MeasuredLinear($0.1, name: $0.0, recorder: recorder))
      }
      try model.update(modules: ModuleChildren.unflattened(replacements), verify: .none)
      defer { model.update(modules: ModuleChildren.unflattened(originals.map { ($0.0, $0.1 as Module) })) }
      let parameters = GenerateParameters(maxTokens: 256,
        prefill: PrefillParameters(stepSize: 512, chunking: .balanced))
      func prefill(_ input: LMInput) throws -> MLXArray {
        let cache = try context.model.newCache(parameters: parameters)
        let prepared = try context.model.prepare(input, cache: cache, state: nil, prefill: parameters.prefill)
        guard case .logits(let result) = prepared else { throw failure("Expected text logits.") }
        let logits = result.logits[0..., -1, 0...]
        eval(logits); eval(cache); Stream.defaultStream.synchronize()
        return logits
      }
      _ = try prefill(LMInput(tokens: MLXArray(Array(ids.prefix(512)))))
      Memory.clearCache()
      var trials: [Trial] = []
      let names = originals.map(\.0)
      for (index, arm) in ["baseline", "profile", "profile", "baseline"].enumerated() {
        recorder.observations.removeAll(keepingCapacity: true)
        recorder.enabled = arm == "profile"
        try autoreleasepool {
          let clock = ContinuousClock(), start = clock.now
          let logits = try prefill(input)
          let elapsed = seconds(start.duration(to: clock.now))
          let values = logits.asType(.float32), finite = all(isFinite(values)).item(Bool.self)
          let bytes = values.asArray(Float.self).withUnsafeBytes { Data($0) }
          let filename = "trial-\(index)-\(arm).f32le"
          try bytes.write(to: output.appendingPathComponent(filename), options: .atomic)
          trials.append(Trial(trial: index, arm: arm, seconds: elapsed, logits_shape: values.shape,
            logits_sha256: digest(bytes), logits_file: filename, finite: finite,
            mlx_peak_bytes: Memory.peakMemory, observations: recorder.observations))
          try write(Report(status: "pending", model: plan.model, prompt_digest: fixture.outputs[0].prompt_digest,
            input_tokens: 4096, prefill_tokens: 512, modules: names, trials: trials, scope: scope), output: output)
          guard finite, values.shape == [1, 262144] else { throw failure("Invalid retained logits.") }
        }
        Memory.clearCache()
      }
      try write(Report(status: "complete", model: plan.model, prompt_digest: fixture.outputs[0].prompt_digest,
        input_tokens: 4096, prefill_tokens: 512, modules: names, trials: trials, scope: scope), output: output)
    }
  }
  private final class FirstLogits {
    var logits: MLXArray?
    var sample: MLXArray?
    var calls = 0
  }
  /// Observes the first logits before the checkpoint-authored control mask.
  /// Sampling and masking use the admitted Rust plan and native MLX arithmetic.
  private struct CaptureProcessor: LogitProcessor {
    let capture: FirstLogits
    let indices: MLXArray
    let count: Int
    init(capture: FirstLogits, suppressed: [Int]) {
      self.capture = capture; count = suppressed.count
      indices = MLXArray(suppressed.map(Int32.init))
    }
    mutating func prompt(_ prompt: MLXArray) {}
    mutating func didSample(token: MLXArray) { if capture.sample == nil { capture.sample = token } }
    func process(logits: MLXArray) -> MLXArray {
      capture.calls += 1
      if capture.logits == nil { capture.logits = logits }
      guard count > 0 else { return logits }
      let shape = Array(repeating: 1, count: logits.ndim - 1) + [count]
      return putAlong(logits, indices.reshaped(shape), values: MLXArray(-Float.infinity), axis: -1)
    }
  }
  private static func compareEntries(plan: Plan, fixture: Fixture, input: LMInput,
    context: ModelContext, output: URL) throws {
    let parameters = GenerateParameters(maxTokens: 1, temperature: plan.sampling.temperature,
      topP: plan.sampling.topP, topK: plan.sampling.topK, minP: plan.sampling.minP,
      repetitionPenalty: nil, prefill: PrefillParameters(stepSize: 512, chunking: .balanced), seed: plan.seed)
    let ids = input.text.tokens.asArray(Int.self)
    try autoreleasepool {
      let warmCache = try context.model.newCache(parameters: parameters)
      let prepared = try context.model.prepare(LMInput(tokens: MLXArray(Array(ids.prefix(512)))),
        cache: warmCache, state: nil, prefill: parameters.prefill)
      guard case .logits(let result) = prepared else { throw failure("Expected warmup logits.") }
      eval(result.logits); eval(warmCache); Stream.defaultStream.synchronize()
    }
    Memory.clearCache()
    let scope = "matched direct preparation and production TokenIterator initialization/first-sample settlement; execution variant \(plan.mode); no app lifecycle, delivery, throughput or performance gate"
    var trials: [Trial] = []
    for (index, arm) in ["direct", "iterator", "iterator", "direct"].enumerated() {
      try autoreleasepool {
        let capture = FirstLogits()
        var processor = CaptureProcessor(capture: capture, suppressed: plan.suppressedTokenIDs)
        let cache = try context.model.newCache(parameters: parameters)
        let clock = ContinuousClock(), start = clock.now, qos = qos_class_self().rawValue
        if arm == "iterator" {
          // This is the initializer used inside generateTokensTask. Observe its
          // already-primed sample without next(), which pipelines another decode.
          let iteratorProcessor = processor
          let iterator = try TokenIterator(input: input, model: context.model, cache: cache,
            parameters: parameters, components: GenerationComponents(logitProcessorFactory: { iteratorProcessor }))
          withExtendedLifetime(iterator) {}
        } else {
          processor.prompt(input.text.tokens)
          let result = try context.model.prepare(input, cache: cache, state: nil, prefill: parameters.prefill)
          guard case .logits(let prepared) = result else { throw failure("Expected raw text logits.") }
          let logits = prepared.logits[0..., -1, 0...]
          let selected = parameters.sampler().sample(logits: processor.process(logits: logits))
          processor.didSample(token: selected)
          asyncEval(selected)
        }
        let constructor = seconds(start.duration(to: clock.now))
        guard capture.calls == 1, let logits = capture.logits, let sample = capture.sample else {
          throw failure("Expected exactly one captured first-sample evaluation.")
        }
        eval(sample); eval(cache); Stream.defaultStream.synchronize()
        let elapsed = seconds(start.duration(to: clock.now)), token = sample.item(Int.self)
        let values = logits.asType(.float32), finite = all(isFinite(values)).item(Bool.self)
        let bytes = values.asArray(Float.self).withUnsafeBytes { Data($0) }
        let filename = "trial-\(index)-\(arm).f32le"
        try bytes.write(to: output.appendingPathComponent(filename), options: .atomic)
        trials.append(Trial(trial: index, arm: arm, seconds: elapsed, logits_shape: values.shape,
          logits_sha256: digest(bytes), logits_file: filename, finite: finite,
          mlx_peak_bytes: Memory.peakMemory, observations: [], constructor_seconds: constructor,
          selected_token_id: token, thread_qos: qos))
        try write(Report(status: "pending", model: plan.model, prompt_digest: fixture.outputs[0].prompt_digest,
          input_tokens: 4096, prefill_tokens: 512, modules: [], trials: trials, scope: scope), output: output)
        guard finite, values.shape == [1, 262144] else { throw failure("Invalid retained first logits.") }
      }
      Memory.clearCache()
    }
    try write(Report(status: "complete", model: plan.model, prompt_digest: fixture.outputs[0].prompt_digest,
      input_tokens: 4096, prefill_tokens: 512, modules: [], trials: trials, scope: scope), output: output)
  }
  private static let scope = "synchronized text projection and preceding-work attribution; instrumentation perturbs scheduling; no kernel, application latency, residency or quality qualification"
  private static func seconds(_ duration: Duration) -> Double {
    let d = duration.components; return Double(d.seconds) + Double(d.attoseconds) / 1e18
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func write(_ report: Report, output: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output.appendingPathComponent("observations.json"), options: .atomic)
  }
  private static func failure(_ message: String) -> NSError {
    NSError(domain: "BloomPrefillProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
