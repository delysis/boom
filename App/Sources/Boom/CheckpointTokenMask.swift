import MLX
import MLXLMCommon

/// The token IDs have already been admitted by Rust. Create this processor only
/// inside an owned generation; it neither changes prose nor advances RNG state.
struct CheckpointTokenMask: LogitProcessor {
  private let indices: MLXArray
  private let count: Int
  init(_ tokenIDs: [Int]) {
    count = tokenIDs.count
    indices = MLXArray(tokenIDs.map(Int32.init))
  }
  mutating func prompt(_ prompt: MLXArray) {}
  mutating func didSample(token: MLXArray) {}
  func process(logits: MLXArray) -> MLXArray {
    guard count > 0 else { return logits }
    let shape = Array(repeating: 1, count: logits.ndim - 1) + [count]
    return putAlong(logits, indices.reshaped(shape), values: MLXArray(-Float.infinity), axis: -1)
  }
}
