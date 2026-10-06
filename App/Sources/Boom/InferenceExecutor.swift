import Dispatch

/// MLX prefill and batch evaluation block their thread. Keep that work off
/// Swift's cooperative pool so timer continuations and UI tasks can progress.
/// ModelContainer retains its exclusive access while this callback runs; the
/// generation coordinator still owns the GPU lease and joins the whole task.
actor InferenceExecutor {
  static let shared = InferenceExecutor()
  private nonisolated let queue = DispatchSerialQueue(label: "com.delysis.Bloom.inference")
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

  func perform<R: Sendable>(
    _ action: sending (isolated InferenceExecutor) async throws -> R
  ) async rethrows -> R {
    try await action(self)
  }
}
