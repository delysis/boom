import CryptoKit
import Darwin
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Developer precision screen. It does not alter application admission or weights.
enum BaseFidelityProbe {
  private struct Plan: Decodable, Sendable {
    let pack: String
    let model: String
    let fixture: String
    let fixtureSHA256: String
    let output: String
  }
  private struct Fixture: Decodable, Sendable {
    let recipe: Recipe
    let promptDigest: String
    let promptTokens: Int
    let tokenIDs: [Int]
    struct Recipe: Decodable, Sendable { let prompt: String }
  }
  private struct Observation: Encodable, Sendable {
    struct Token: Encodable, Sendable { let id: Int; let logit: Float; let text: String }
    let name: String
    let input_tokens: Int
    let shape: [Int]
    let logits_sha256: String
    let top: [Token]
    let memory: [String: UInt64]
  }
  private static let budget = UInt64(24) * 1_073_741_824
  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func failure(_ text: String) -> NSError {
    NSError(domain: "BloomBaseFidelity", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
  private static func memory() throws -> [String: UInt64] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { throw failure("Kernel process accounting failed.") }
    return ["current_footprint_bytes": info.phys_footprint,
      "kernel_peak_footprint_bytes": UInt64(max(0, info.ledger_phys_footprint_peak)),
      "mlx_peak_bytes": UInt64(max(0, Memory.peakMemory))]
  }
  static func run(_ arguments: [String]) async throws {
    guard arguments.count == 3, arguments[2].hasPrefix("/") else { throw failure("Use --base-fidelity ABSOLUTE_PLAN.") }
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    guard [plan.pack, plan.fixture, plan.output].allSatisfy({ $0.hasPrefix("/") }),
      !FileManager.default.fileExists(atPath: plan.output) else { throw failure("Use absolute inputs and fresh output.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: plan.fixture))
    guard data.count <= 1_048_576, hash(data) == plan.fixtureSHA256 else { throw failure("Captured fixture changed.") }
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    guard fixture.promptTokens == 659, fixture.tokenIDs == [236913, 3771, 625, 5889, 236789] else {
      throw failure("Require the captured broken-contraction case.")
    }
    let output = URL(fileURLWithPath: plan.output)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    var report: [String: Any] = ["status": "running", "model": plan.model,
      "fixture_sha256": plan.fixtureSHA256, "process_budget_bytes": budget,
      "scope": "same Swift architecture, public quantized versus official BF16 weights; teacher forcing, no independent architecture or product admission qualification"]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("report.json"), options: .atomic)
    }
    try persist()
    do {
      Memory.memoryLimit = Int(budget)
      Memory.cacheLimit = 128 * 1_048_576
      let container = try await VLMModelFactory.shared.loadContainer(from: URL(fileURLWithPath: plan.pack),
        using: #huggingFaceTokenizerLoader())
      let loadedMemory = try memory()
      report["after_load"] = loadedMemory; try persist()
      guard max(loadedMemory["current_footprint_bytes"] ?? 0,
        loadedMemory["kernel_peak_footprint_bytes"] ?? 0) <= budget else {
        throw failure("Model loading exceeded the precision screen's process bound.")
      }
      let observations = try await container.perform { context in
        let ids = context.tokenizer.encode(text: fixture.recipe.prompt, addSpecialTokens: false)
        guard ids.count == fixture.promptTokens, hash(try JSONEncoder().encode(ids)) == fixture.promptDigest else {
          throw failure("Native captured prompt tokenization changed.")
        }
        try JSONEncoder().encode(ids).write(to: output.appendingPathComponent("prompt-token-ids.json"), options: .atomic)
        let parameters = GenerateParameters(maxTokens: 1,
          prefill: PrefillParameters(stepSize: 512, chunking: .balanced))
        let cache = try context.model.newCache(parameters: parameters)
        let prepared = try context.model.prepare(LMInput(tokens: MLXArray(ids)), cache: cache, state: nil, prefill: parameters.prefill)
        guard case .logits(let first) = prepared else { throw failure("Expected raw text logits.") }
        var logits = first.logits[0..., -1, 0...]
        var observations: [Observation] = []
        func save(_ name: String, tokenCount: Int) throws {
          eval(logits); eval(cache); Stream.defaultStream.synchronize()
          let values = logits.asType(.float32).asArray(Float.self)
          guard values.count == 262144, values.allSatisfy(\.isFinite) else { throw failure("Invalid full-vocabulary logits.") }
          let bytes = values.withUnsafeBytes { Data($0) }
          try bytes.write(to: output.appendingPathComponent(name + ".f32"), options: .atomic)
          let sampledMemory = try memory()
          let top = values.indices.sorted { values[$0] > values[$1] }.prefix(16).map { index in
            Observation.Token(id: index, logit: values[index], text: context.tokenizer.decode(tokenIds: [index]))
          }
          let observation = Observation(name: name, input_tokens: tokenCount, shape: logits.shape,
            logits_sha256: hash(bytes), top: top, memory: sampledMemory)
          observations.append(observation)
          try JSONEncoder().encode(observation).write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
          guard max(sampledMemory["current_footprint_bytes"] ?? 0,
            sampledMemory["kernel_peak_footprint_bytes"] ?? 0) <= budget else {
            throw failure("The precision screen exceeded its 24 GiB process bound.")
          }
        }
        try save("prefix", tokenCount: ids.count)
        for token in fixture.tokenIDs {
          logits = context.model(LMInput.Text(tokens: MLXArray([token]).reshaped([1, 1])), cache: cache, state: nil)
            .logits[0..., -1, 0...]
          eval(logits); Stream.defaultStream.synchronize()
        }
        try save("after-apostrophe", tokenCount: ids.count + fixture.tokenIDs.count)
        return observations
      }
      report["observations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observations))
      report["status"] = "complete"; try persist()
    } catch {
      report["status"] = "failed"; report["error"] = error.localizedDescription
      try persist(); throw error
    }
  }
}
