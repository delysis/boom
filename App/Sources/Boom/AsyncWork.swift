import Foundation

func detachedWork<T>(
  priority: TaskPriority = .utility, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let worker = Task.detached(priority: priority, operation: operation)
  return try await withTaskCancellationHandler(
    operation: { try await worker.value }, onCancel: { worker.cancel() })
}
