import BoomCore
import Darwin
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

  /// The producer owns its bounded stream until it returns. Apple supplies the
  /// replacement directory on the destination volume and publishes the file;
  /// no whole-file buffer or workspace/storage authority is introduced here.
  static func write(to url: URL,
    checkCancellation: @escaping @Sendable () throws -> Void = {},
    stream: @escaping @Sendable (FileHandle) async throws -> Void) async throws -> URL {
    try await detachedWork {
      try Task.checkCancellation()
      try checkCancellation()
      let target = url.standardizedFileURL
      guard target.isFileURL, target != target.deletingLastPathComponent() else {
        throw BoomError.invalid("Export requires a selected file destination.")
      }
      let manager = FileManager.default
      let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
        appropriateFor: target, create: true)
      var file: FileHandle?
      var closeAttempted = false
      var publicationEntered = false
      var published: URL?
      do {
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let staged = directory.appendingPathComponent("Export")
        let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        file = handle
        try await stream(handle)
        try Task.checkCancellation()
        try checkCancellation()
        try handle.synchronize()
        closeAttempted = true
        try handle.close()

        var coordinationError: NSError?
        var publicationError: Error?
        // Only cancel() crosses threads; Apple explicitly permits that call.
        nonisolated(unsafe) let coordinator = NSFileCoordinator(filePresenter: nil)
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          coordinator.coordinate(writingItemAt: target, options: .forReplacing,
            error: &coordinationError) { destination in
            do {
              try Task.checkCancellation()
              try checkCancellation()
              guard destination.standardizedFileURL == target else {
                throw BoomError.stale("The selected export destination changed during coordination.")
              }
              var existing = stat()
              let exists = lstat(destination.path, &existing) == 0
              guard exists || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
              guard !exists || existing.st_mode & S_IFMT == S_IFREG else {
                throw BoomError.denied("Export cannot replace a symlink, directory or device.")
              }
              publicationEntered = true
              if exists {
                published = try manager.replaceItemAt(destination, withItemAt: staged,
                  options: .usingNewMetadataOnly) ?? destination
              } else {
                try manager.moveItem(at: staged, to: destination)
                published = destination
              }
            } catch { publicationError = error }
          }
        } onCancel: { coordinator.cancel() }
        if let publicationError { throw publicationError }
        if let coordinationError { throw coordinationError }
        guard let published else { throw BoomError.unavailable("The export destination was not published.") }
        try manager.removeItem(at: directory)
        return published
      } catch {
        let original = error
        var cleanup: Error?
        if let file, !closeAttempted {
          closeAttempted = true
          do { try file.close() } catch { cleanup = error }
        }
        // A failed system replacement can relocate the ORIGINAL into this
        // directory. Keep it, including Apple's original-location NSError;
        // never treat a publication failure as disposable partial output.
        if publicationEntered {
          throw ExplicitStreamExportFailure(original: original, cleanup: cleanup,
            retainedDirectory: directory, publishedURL: published)
        }
        do { try manager.removeItem(at: directory) }
        catch { cleanup = cleanup ?? error }
        if let cleanup {
          throw ExplicitStreamExportFailure(original: original, cleanup: cleanup,
            retainedDirectory: manager.fileExists(atPath: directory.path) ? directory : nil,
            publishedURL: nil)
        }
        throw original
      }
    }
  }
}

struct ExplicitStreamExportFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error?
  let retainedDirectory: URL?
  let publishedURL: URL?
  var errorDescription: String? {
    var description = original.localizedDescription
    if let publishedURL { description += " Export was published at \(publishedURL.path)." }
    if let retainedDirectory { description += " Export files were retained at \(retainedDirectory.path)." }
    if let cleanup { description += " Cleanup also failed: \(cleanup.localizedDescription)" }
    return description
  }
}
