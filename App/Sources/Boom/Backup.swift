import BoomCore
import Darwin
import Foundation

/// Both directories keep a name while a fresh workspace is published.
enum AtomicDirectoryReplacement {
  static func exchange(_ first: URL, _ second: URL) throws {
    let parent = first.deletingLastPathComponent()
    guard first != second, parent == second.deletingLastPathComponent() else {
      throw BoomError.invalid("Workspace replacement requires distinct sibling directories.")
    }
    let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var failure: Error?
    do {
      for name in [first.lastPathComponent, second.lastPathComponent] {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw BoomError.invalid("Workspace replacement requires real directories.")
        }
      }
      guard renameatx_np(descriptor, first.lastPathComponent, descriptor, second.lastPathComponent,
        UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)) == 0,
        fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch { failure = error }
    let closed = close(descriptor), closeError = errno
    if let failure {
      guard closed == 0 else {
        throw BoomError.unavailable("Workspace replacement failed: \(failure.localizedDescription). Directory close also failed (\(closeError)).")
      }
      throw failure
    }
    guard closed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: closeError) ?? .EIO) }
  }
}

/// Directory backups preserve the complete quiesced workspace. The caller joins
/// all writers before export, and closes its engine/workspace lock before restore.
/// Every file is streamed through one 64 KiB buffer; no archive is materialized.
enum WorkspaceBackup {
  static func export(root: URL, to target: URL) throws {
    try copyWorkspace(from: root, to: target, restoring: false)
  }

  static func restore(from source: URL, into target: URL) throws {
    try copyWorkspace(from: source, to: target, restoring: true)
  }

  private static func copyWorkspace(from source: URL, to target: URL, restoring: Bool) throws {
    try Task.checkCancellation()
    guard source.isFileURL, target.isFileURL else {
      throw BoomError.invalid("Backup requires local directories.")
    }
    let source = source.standardizedFileURL
    var sourceInfo = stat()
    guard lstat(source.path, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFDIR else {
      throw BoomError.invalid("Backup source must be a real directory.")
    }
    let physicalSource = try physicalDirectory(source)
    let target = try physicalDirectory(target.deletingLastPathComponent().standardizedFileURL)
      .appendingPathComponent(target.lastPathComponent, isDirectory: true)
    guard target != physicalSource, !target.path.hasPrefix(physicalSource.path + "/"),
      !physicalSource.path.hasPrefix(target.path + "/") else {
      throw BoomError.invalid("Backup source and destination must be separate directories.")
    }
    var targetInfo = stat()
    let targetExists = lstat(target.path, &targetInfo) == 0
    if !targetExists && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    if targetExists {
      guard restoring, targetInfo.st_mode & S_IFMT == S_IFDIR else {
        throw BoomError.denied("Backup destination already exists.")
      }
      try requireFreshTarget(target)
    }
    let stage = target.deletingLastPathComponent().appendingPathComponent(".backup-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      var enumerationFailure: Error?
      guard let files = FileManager.default.enumerator(at: physicalSource,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        errorHandler: { _, error in enumerationFailure = error; return false }) else {
        throw BoomError.unavailable("Could not enumerate the workspace.")
      }
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while let file = files.nextObject() as? URL {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, file.path.hasPrefix(physicalSource.path + "/") else {
          throw BoomError.invalid("Backup refuses symbolic links.")
        }
        let relative = String(file.path.dropFirst(physicalSource.path.count + 1))
        let destination = stage.appendingPathComponent(relative)
        if values.isDirectory == true {
          try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        } else if values.isRegularFile == true {
          try copyFile(file, to: destination, buffer: &buffer)
        } else { throw BoomError.invalid("Backup refuses nonregular files.") }
      }
      if let enumerationFailure { throw enumerationFailure }
      // Files were synchronized individually. Sync nested directories before
      // the final root rename so their names belong to the published copy.
      enumerationFailure = nil
      guard let directories = FileManager.default.enumerator(at: stage,
        includingPropertiesForKeys: [.isDirectoryKey], options: [.includesDirectoriesPostOrder],
        errorHandler: { _, error in enumerationFailure = error; return false }) else {
        throw BoomError.unavailable("Could not enumerate backup directories.")
      }
      do {
        while let directory = directories.nextObject() as? URL {
          if try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try synchronizeDirectory(directory)
          }
        }
      }
      if let enumerationFailure { throw enumerationFailure }
      try synchronizeDirectory(stage)
      try Task.checkCancellation()
      if targetExists {
        try requireFreshTarget(target)
        var current = stat()
        guard lstat(target.path, &current) == 0, current.st_dev == targetInfo.st_dev,
          current.st_ino == targetInfo.st_ino else {
          throw BoomError.stale("Restore destination changed during the copy.")
        }
        try AtomicDirectoryReplacement.exchange(stage, target)
        try FileManager.default.removeItem(at: stage) // Only the admitted empty shell remains here.
      } else {
        var unexpected = stat()
        guard lstat(target.path, &unexpected) != 0, errno == ENOENT else {
          throw BoomError.stale("Backup destination appeared during the copy.")
        }
        guard renamex_np(stage.path, target.path, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(target.deletingLastPathComponent())
      }
    } catch {
      let original = error
      // The source is untouched. Discard only this operation's partial copy
      // (or the admitted empty shell after a completed directory exchange).
      if FileManager.default.fileExists(atPath: stage.path) {
        do { try FileManager.default.removeItem(at: stage) }
        catch { throw BoomError.unavailable("Backup failed: \(original.localizedDescription). Cleanup also failed: \(error.localizedDescription). Copy retained at \(stage.path).") }
      }
      throw original
    }
  }

  // Foundation may shorten /private/var to /var while its enumerator returns
  // /private/var children. Use the kernel spelling for ancestry and rename.
  private static func physicalDirectory(_ url: URL) throws -> URL {
    let (resolved, failure) = url.path.withCString { (realpath($0, nil), errno) }
    guard let resolved else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  /// A new WorkspaceStore may already have created its empty Objects directory
  /// and a released zero-length lock. No identity, metadata or authored file is erased.
  private static func requireFreshTarget(_ target: URL) throws {
    for file in try FileManager.default.contentsOfDirectory(at: target,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
      let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isSymbolicLink != true else { throw BoomError.denied("Restore requires a fresh workspace.") }
      if file.lastPathComponent == "Objects", values.isDirectory == true,
        try FileManager.default.contentsOfDirectory(atPath: file.path).isEmpty { continue }
      if file.lastPathComponent == ".workspace-lock", values.isRegularFile == true,
        values.fileSize == 0 { continue }
      throw BoomError.denied("Restore requires a fresh workspace.")
    }
  }

  private static func copyFile(_ source: URL, to target: URL, buffer: inout [UInt8]) throws {
    let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var before = stat()
    guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
      let original = errno; _ = close(input)
      throw POSIXError(POSIXErrorCode(rawValue: original) ?? .EIO)
    }
    let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard output >= 0 else {
      let original = errno; _ = close(input)
      throw POSIXError(POSIXErrorCode(rawValue: original) ?? .EIO)
    }
    var failure: Error?
    do {
      var copied: Int64 = 0
      while true {
        try Task.checkCancellation()
        let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
        if count < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 { break }
        copied += Int64(count)
        guard copied <= before.st_size else { throw BoomError.stale("Backup source grew during the copy.") }
        var offset = 0
        while offset < count {
          let written = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
          if written < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          guard written > 0 else { throw BoomError.unavailable("Backup write made no progress.") }
          offset += written
        }
      }
      var after = stat()
      guard fstat(input, &after) == 0, copied == before.st_size,
        before.st_dev == after.st_dev, before.st_ino == after.st_ino,
        before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
        throw BoomError.stale("Backup source changed during the copy.")
      }
      guard fsync(output) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch { failure = error }
    let inputClosed = close(input), inputError = errno
    let outputClosed = close(output), outputError = errno
    if let failure {
      guard inputClosed == 0, outputClosed == 0 else {
        throw BoomError.unavailable("Backup failed: \(failure.localizedDescription). File close also failed: input \(inputClosed)/\(inputError), output \(outputClosed)/\(outputError).")
      }
      throw failure
    }
    guard inputClosed == 0, outputClosed == 0 else {
      throw BoomError.unavailable("Backup file close failed: input \(inputClosed)/\(inputError), output \(outputClosed)/\(outputError).")
    }
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let synchronized = fsync(descriptor), syncError = errno
    let closed = close(descriptor), closeError = errno
    guard synchronized == 0, closed == 0 else {
      throw BoomError.unavailable("Backup directory close failed: sync \(synchronized)/\(syncError), close \(closed)/\(closeError).")
    }
  }
}
