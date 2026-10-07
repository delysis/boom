import CryptoKit
import Foundation
import MLX

/// Developer-only arithmetic screen. No model, checkpoint or app policy is changed.
enum PrefillKernelProbe {
  struct Plan: Decodable {
    let shard: String
    let shardSHA256: String
    let packIdentity: String
    let output: String
    let operationBudgetBytes: Int
    let cases: [Case]
    struct Case: Decodable {
      let name: String
      let tensor: String
      let input: Int
      let output: Int
      let rows: Int
      let seed: UInt64
      let arms: [String]
      let bits: Int
      let groupSize: Int
    }
  }
  static func run(_ args: [String]) throws {
    guard args.count == 3, args[2].hasPrefix("/") else { throw failure("Choose an absolute probe plan.") }
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let directory = URL(fileURLWithPath: plan.output)
    guard plan.shard.hasPrefix("/"), plan.output.hasPrefix("/"), !plan.cases.isEmpty,
      plan.cases.count <= 12, [4, 8].map({ $0 * 1_073_741_824 }).contains(plan.operationBudgetBytes),
      !FileManager.default.fileExists(atPath: directory.path) else {
      throw failure("Require a bounded plan and a fresh output directory.")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    MLX.Memory.memoryLimit = plan.operationBudgetBytes
    MLX.Memory.cacheLimit = 128 * 1_048_576
    let arrays = try MLX.loadArrays(url: URL(fileURLWithPath: plan.shard))
    var observations: [[String: Any]] = []
    let clock = ContinuousClock()
    for item in plan.cases {
      guard [3840, 15360].contains(item.input), [3840, 4096, 15360].contains(item.output),
        [4, 8].contains(item.bits), [32, 64].contains(item.groupSize), [1, 64, 512].contains(item.rows),
        item.arms.count == 16, Set(item.arms) == ["fused", "dense-bf16", "dense-fp16", "cached-bf16"],
        let weight = arrays[item.tensor + ".weight"], let scales = arrays[item.tensor + ".scales"],
        let biases = arrays[item.tensor + ".biases"], weight.dtype == .uint32,
        scales.dtype == .bfloat16, biases.dtype == .bfloat16,
        weight.shape == [item.output, item.input / (32 / item.bits)],
        scales.shape == [item.output, item.input / item.groupSize],
        biases.shape == scales.shape else { throw failure("Probe tensor or shape changed.") }
      let input = MLXRandom.normal([item.rows, item.input], dtype: .bfloat16, key: MLXRandom.key(item.seed))
      eval(input, weight, scales, biases); Stream.defaultStream.synchronize()
      let conversionStart = clock.now
      let cached = dequantized(weight, scales: scales, biases: biases,
        groupSize: item.groupSize, bits: item.bits, dtype: .bfloat16)
      eval(cached); Stream.defaultStream.synchronize()
      let conversion = conversionStart.duration(to: clock.now).components
      let conversionSeconds = Double(conversion.seconds) + Double(conversion.attoseconds) / 1e18
      func operation(_ arm: String) -> MLXArray {
        if arm == "cached-bf16" { return matmul(input, cached.T) }
        if arm == "fused" {
          return quantizedMM(input, weight, scales: scales, biases: biases, transpose: true,
            groupSize: item.groupSize, bits: item.bits)
        }
        let dtype: DType = arm == "dense-fp16" ? .float16 : .bfloat16
        let dense = dequantized(weight, scales: scales, biases: biases,
          groupSize: item.groupSize, bits: item.bits, dtype: dtype)
        return matmul(input.asType(dtype), dense.T)
      }
      // Equal warmup count. Dense conversion stays inside every timed operation.
      for arm in ["fused", "dense-bf16", "dense-fp16", "cached-bf16"] {
        let output = operation(arm); eval(output); Stream.defaultStream.synchronize()
      }
      let reference = operation("fused").asType(.float32); eval(reference)
      var retained: [String: String] = [:]
      for (index, arm) in item.arms.enumerated() {
        try autoreleasepool {
          let started = clock.now
          let value = operation(arm); eval(value); Stream.defaultStream.synchronize()
          let elapsed = started.duration(to: clock.now).components
          let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
          let actual = value.asType(.float32), error = actual - reference
          let finite = all(isFinite(actual)).item(Bool.self)
          let maxError = abs(error).max().item(Float.self)
          let rmse = sqrt(mean(error * error)).item(Float.self)
          let rms = sqrt(mean(reference * reference)).item(Float.self)
          let bytes = actual.asArray(Float.self).withUnsafeBytes { Data($0) }
          let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
          if let prior = retained[arm], prior != digest { throw failure("A repeated kernel output changed; results retained.") }
          if retained[arm] == nil {
            try MLX.save(arrays: ["output": actual], url: directory.appendingPathComponent(item.name + "-" + arm + ".safetensors"))
            retained[arm] = digest
          }
          observations.append(["case": item.name, "arm": arm, "trial": index, "seconds": seconds,
            "rows": item.rows, "input": item.input, "output": item.output, "seed": item.seed,
            "bits": item.bits, "group_size": item.groupSize,
            "cached_conversion_seconds": conversionSeconds, "cached_weight_bytes": cached.nbytes,
            "output_sha256": digest, "finite": finite, "maximum_absolute_error": maxError,
            "relative_rmse": Double(rmse) / max(1e-12, Double(rms)),
            "mlx_peak_bytes": MLX.Memory.peakMemory])
          try write(["status": "pending", "observations": observations], to: directory.appendingPathComponent("observations.json"))
          guard finite, seconds.isFinite, seconds > 0 else { throw failure("Invalid kernel output or timing; results retained.") }
        }
      }
    }
    try write(["status": "complete", "pack_identity": plan.packIdentity, "shard_sha256": plan.shardSHA256,
      "operation_budget_bytes": plan.operationBudgetBytes, "scope": "isolated actual-weight arithmetic screen; no product performance or quality qualification",
      "observations": observations], to: directory.appendingPathComponent("observations.json"))
    print("Retained \(observations.count) kernel observations and every distinct output.")
  }
  private static func write(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
  }
  private static func failure(_ message: String) -> NSError {
    NSError(domain: "BloomKernelProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
