import MLX
import MLXLMCommon

/// The token IDs have already been admitted by Rust. Create this processor only
/// inside an owned generation; it neither changes prose nor advances RNG state.
struct CheckpointTokenMask: LogitProcessor {
  private let indices: MLXArray
  private let count: Int
  private let sampleObserver: (@Sendable (MLXArray) -> Void)?
  private let logitsObserver: (@Sendable (MLXArray) -> Void)?
  init(_ tokenIDs: [Int], didSample: (@Sendable (MLXArray) -> Void)? = nil,
    observeLogits: (@Sendable (MLXArray) -> Void)? = nil) {
    count = tokenIDs.count
    indices = MLXArray(tokenIDs.map(Int32.init))
    sampleObserver = didSample
    logitsObserver = observeLogits
  }
  mutating func prompt(_ prompt: MLXArray) {}
  mutating func didSample(token: MLXArray) { sampleObserver?(token) }
  func process(logits: MLXArray) -> MLXArray {
    logitsObserver?(logits)
    guard count > 0 else { return logits }
    let shape = Array(repeating: 1, count: logits.ndim - 1) + [count]
    return putAlong(logits, indices.reshaped(shape), values: MLXArray(-Float.infinity), axis: -1)
  }
}
