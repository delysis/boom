import CryptoKit
import Darwin
import Foundation
import MLX
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Tokenizers

/// Developer-only text prefill comparison. No app request or model is changed.
enum InputPackagingProbe {
  private struct Fixture: Decodable, Sendable {
    let model: String
    let plan: Plan
    let outputs: [Output]
    struct Plan: Decodable, Sendable {
      let messages: [Message]
      struct Message: Decodable, Sendable { let role: String; let content: String }
    }
    struct Output: Decodable, Sendable { let prompt_digest: String; let prompt_tokens: Int }
  }
  private struct Trial: Encodable, Sendable {
    let trial: Int; let arm: String; let seconds: Double; let thread_qos: UInt32
    let token_shape: [Int]; let mask_shape: [Int]?
    let logits_shape: [Int]; let logits_bytes: Int; let logits_sha256: String; let logits_file: String
    let argmax: Int; let finite: Bool; let mlx_peak_bytes: Int
  }
  private struct Report: Encodable {
    let status: String; let model: String; let observations: [Trial]; let scope: String
  }
  static func run(_ args: [String]) async throws {
    guard args.count == 5, args[2...4].allSatisfy({ $0.hasPrefix("/") }) else {
      throw failure("Use --input-packaging-probe ABSOLUTE_PACK ABSOLUTE_FIXTURE NEW_OUTPUT.")
    }
    let pack = URL(fileURLWithPath: args[2]), fixtureURL = URL(fileURLWithPath: args[3])
    let output = URL(fileURLWithPath: args[4])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw failure("Refuse to replace evidence.") }
    let fixtureData = try Data(contentsOf: fixtureURL)
    guard fixtureData.count <= 1_048_576 else { throw failure("Oversized public fixture.") }
    let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)
    let manifest = try Data(contentsOf: pack.appendingPathComponent("bloom-model.json"))
    guard digest(manifest) == fixture.model, fixture.outputs.count == 1,
      fixture.outputs[0].prompt_tokens == 4096, !fixture.plan.messages.isEmpty else {
      throw failure("The captured model or 4K workload differs.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let order = ["native", "flat", "flat", "native"]
    try write(["status": "registered", "order": order, "model": fixture.model,
      "fixture_sha256": digest(fixtureData), "prompt_digest": fixture.outputs[0].prompt_digest,
      "input_tokens": 4096, "prefill_tokens": 512, "cache_bytes": 128 * 1_048_576,
      "scope": "one-model prefill component comparison; no sampling, application qualification or literary quality claim"],
      to: output.appendingPathComponent("registration.json"))
    Memory.memoryLimit = 24 * 1_073_741_824
    Memory.cacheLimit = 128 * 1_048_576
    do {
      let container = try await VLMModelFactory.shared.loadContainer(from: pack,
        using: #huggingFaceTokenizerLoader())
      let observations = try await container.perform { context in
        var observations: [Trial] = []
        // The fixture is an already captured Rust consultation plan. This is
        // native processor encoding, not a second request planner.
        let messages: [MLXLMCommon.Message] = fixture.plan.messages.map {
          ["role": $0.role, "content": $0.content]
        }
        let native = try await context.processor.prepare(input: UserInput(messages: messages,
          additionalContext: ["enable_thinking": false]))
        let ids = native.text.tokens.asArray(Int.self)
        let identity = digest(try JSONEncoder().encode(ids))
        guard ids.count == 4096, identity == fixture.outputs[0].prompt_digest,
          native.image == nil, native.video == nil, native.audio == nil,
          native.text.tokens.shape == [1, 4096], native.text.mask?.shape == [1, 4096] else {
          throw failure("Processor encoding or input shape differs from the app's retained fixture.")
        }
        try JSONEncoder().encode(ids).write(to: output.appendingPathComponent("input-token-ids.json"), options: .atomic)
        let parameters = GenerateParameters(maxTokens: 256,
          prefill: PrefillParameters(stepSize: 512, chunking: .balanced))
        func prefill(_ input: LMInput) throws -> MLXArray {
          let cache = try context.model.newCache(parameters: parameters)
          let result = try context.model.prepare(input, cache: cache, state: nil, prefill: parameters.prefill)
          guard case .logits(let prepared) = result else { throw failure("Expected Gemma text-only logits.") }
          let logits = prepared.logits[0..., -1, 0...]
          eval(logits); eval(cache); Stream.defaultStream.synchronize()
          return logits
        }
        _ = try prefill(LMInput(tokens: MLXArray(Array(ids.prefix(512)))))
        Memory.clearCache()
        for (index, arm) in order.enumerated() {
          try Task.checkCancellation()
          try autoreleasepool {
            let input = arm == "native" ? native : LMInput(tokens: MLXArray(ids))
            eval(input.text.tokens); Stream.defaultStream.synchronize()
            let clock = ContinuousClock(), started = clock.now
            let qos = qos_class_self().rawValue
            let logits = try prefill(input)
            let elapsed = started.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let values = logits.asType(.float32)
            let finite = all(isFinite(values)).item(Bool.self)
            let bytes = values.asArray(Float.self).withUnsafeBytes { Data($0) }
            let filename = "trial-\(index)-\(arm).f32le"
            try bytes.write(to: output.appendingPathComponent(filename), options: .atomic)
            observations.append(Trial(trial: index, arm: arm, seconds: seconds, thread_qos: qos,
              token_shape: input.text.tokens.shape, mask_shape: input.text.mask?.shape,
              logits_shape: values.shape, logits_bytes: bytes.count, logits_sha256: digest(bytes),
              logits_file: filename, argmax: argMax(values).item(Int.self), finite: finite,
              mlx_peak_bytes: Memory.peakMemory))
            try writeReport("pending", trials: observations, model: fixture.model, output: output)
            guard finite, values.shape == [1, 262144], seconds.isFinite, seconds > 0 else {
              throw failure("Invalid output or timing; evidence retained.")
            }
          }
          Memory.clearCache()
        }
        return observations
      }
      try writeReport("complete", trials: observations, model: fixture.model, output: output)
    } catch {
      try write(["status": "failed", "failure": error.localizedDescription,
        "partial_observations": "Retained unchanged in observations.json when present."],
        to: output.appendingPathComponent("failure.json"))
      throw error
    }
    print("Retained all four input-packaging trials and full-vocabulary logits.")
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func writeReport(_ status: String, trials: [Trial], model: String, output: URL) throws {
    let report = Report(status: status, model: model, observations: trials,
      scope: "prefill plus cache/logit settlement; no decode, pair residency, process-footprint or app timing qualification")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output.appendingPathComponent("observations.json"), options: .atomic)
  }
  private static func write(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
  }
  private static func failure(_ message: String) -> NSError {
    NSError(domain: "BloomInputPackagingProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
