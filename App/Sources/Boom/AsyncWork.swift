import Foundation

func detachedWork<T>(
  priority: TaskPriority = .utility, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let worker = Task.detached(priority: priority, operation: operation)
  return try await withTaskCancellationHandler(
    operation: { try await worker.value }, onCancel: { worker.cancel() })
}

/// Only a completed user export action supplies this destination. Serialize
/// captured content off the UI thread, then publish one complete file.
enum ExplicitFileExport {
  static func write(to url: URL, contents: @escaping @Sendable () throws -> Data) async throws {
    try await detachedWork {
      try Task.checkCancellation()
      let bytes = try contents()
      try Task.checkCancellation()
      try bytes.write(to: url, options: .atomic)
    }
  }
}
