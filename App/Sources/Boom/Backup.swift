import BoomCore
import Darwin
import Foundation

private struct WorkspaceBackupCleanupFailure: LocalizedError {
  let original: Error
  let cleanup: Error
  let path: URL
  var errorDescription: String? {
    "Backup failed: \(original.localizedDescription). Cleanup also failed: \(cleanup.localizedDescription). Copy retained at \(path.path)."
  }
}

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

/// Live export captures native file clones under the existing source writer
/// queue and category lock, then streams that immutable directory independently.
/// Restore requires a fresh destination. One 64 KiB buffer serves the byte copy.
enum WorkspaceBackup {
  /// Reports a completed bounded write to the unpublished copy. Nil leaves
  /// the ordinary export path without a progress observer.
  typealias CopyProgress = @Sendable (URL, URL, UInt64) throws -> Void

  /// An ordinary private directory owned by the existing export Task. Its
  /// identity prevents cleanup from removing a replacement at the same name.
  struct CapturedDirectory: Sendable {
    fileprivate let root: URL
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    fileprivate let owner: uid_t
    fileprivate let containerDevice: dev_t
    fileprivate let containerInode: ino_t
    fileprivate let containerOwner: uid_t
    fileprivate var container: URL { root.deletingLastPathComponent() }
  }

  static func export(root: URL, to target: URL) throws {
    _ = try copyWorkspace(from: root, to: target, restoring: false)
  }

  static func restore(from source: URL, into target: URL) throws {
    _ = try copyWorkspace(from: source, to: target, restoring: true)
  }

  /// Caller holds the existing Engine writer queue and Vault lock. Native
  /// clones are required: unsupported filesystems never fall back to a long
  /// byte copy while those source writers are excluded.
  static func captureForExport(root: URL, cancellation: CancellationFlag) throws -> CapturedDirectory {
    let source = try physicalDirectory(root)
    // Cocoa provides a temporary directory on this volume. Its existence is
    // not promised after app exit; no workspace sibling scavenger is needed.
    let directory = try FileManager.default.url(for: .itemReplacementDirectory,
      in: .userDomainMask, appropriateFor: source, create: true).standardizedFileURL
    var container = stat()
    guard lstat(directory.path, &container) == 0, container.st_mode & S_IFMT == S_IFDIR else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let target = directory.appendingPathComponent("Workspace", isDirectory: true)
      let info = try copyWorkspace(from: source, to: target, restoring: false, cloneOnly: true) {
        try Task.checkCancellation(); try cancellation.check()
      }
      return CapturedDirectory(root: target, device: info.st_dev, inode: info.st_ino, owner: info.st_uid,
        containerDevice: container.st_dev, containerInode: container.st_ino, containerOwner: container.st_uid)
    } catch {
      let original = error
      do {
        try admitDirectory(directory, device: container.st_dev, inode: container.st_ino, owner: container.st_uid)
        try FileManager.default.removeItem(at: directory)
      } catch { throw WorkspaceBackupCleanupFailure(original: original, cleanup: error, path: directory) }
      throw original
    }
  }

  /// Only the immutable clone is read during the potentially large export.
  /// Disposal is joined even on cancellation; a refusal retains both errors.
  static func export(_ captured: CapturedDirectory, to target: URL,
    cancellation: CancellationFlag, progress: CopyProgress? = nil) throws {
    var failure: Error?
    do {
      try admitCapture(captured)
      _ = try copyWorkspace(from: captured.root, to: target, restoring: false, progress: progress) {
        try Task.checkCancellation(); try cancellation.check()
      }
    } catch { failure = error }
    try discard(captured, preserving: failure)
  }

  /// The same operation also uses this if its source-read join refuses after
  /// the clone exists. A substituted path is retained, never removed.
  static func discard(_ captured: CapturedDirectory, preserving original: Error? = nil) throws {
    do {
      try admitCapture(captured)
      try FileManager.default.removeItem(at: captured.container)
    } catch {
      if let original { throw WorkspaceBackupCleanupFailure(original: original, cleanup: error, path: captured.container) }
      throw error
    }
    if let original { throw original }
  }

  private static func admitCapture(_ captured: CapturedDirectory) throws {
    try admitDirectory(captured.container, device: captured.containerDevice,
      inode: captured.containerInode, owner: captured.containerOwner)
    try admitDirectory(captured.root, device: captured.device, inode: captured.inode, owner: captured.owner)
  }

  private static func admitDirectory(_ directory: URL, device: dev_t, inode: ino_t, owner: uid_t) throws {
    var current = stat()
    guard lstat(directory.path, &current) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard current.st_mode & S_IFMT == S_IFDIR, current.st_dev == device,
      current.st_ino == inode, current.st_uid == owner else {
      throw BoomError.stale("The owned backup clone changed before export or disposal.")
    }
  }

  private static func copyWorkspace(from source: URL, to target: URL, restoring: Bool,
    cloneOnly: Bool = false, progress: CopyProgress? = nil,
    checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> stat {
    try checkCancellation()
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
    guard mkdir(stage.path, mode_t(0o700)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    do {
      var stageInfo = stat()
      guard lstat(stage.path, &stageInfo) == 0, stageInfo.st_mode & S_IFMT == S_IFDIR else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      var enumerationFailure: Error?
      guard let files = FileManager.default.enumerator(at: physicalSource,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        errorHandler: { _, error in enumerationFailure = error; return false }) else {
        throw BoomError.unavailable("Could not enumerate the workspace.")
      }
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while try autoreleasepool(invoking: { () throws -> Bool in
        guard let file = files.nextObject() as? URL else { return false }
        try checkCancellation()
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
          if cloneOnly { try cloneFile(file, to: destination) }
          else { try copyFile(file, to: destination, buffer: &buffer,
            checkCancellation: checkCancellation, progress: progress) }
        } else { throw BoomError.invalid("Backup refuses nonregular files.") }
        return true
      }) {}
      if let enumerationFailure { throw enumerationFailure }
      if !cloneOnly {
        // Files were synchronized individually. Sync nested directories before
        // the final root rename so their names belong to the published copy.
        enumerationFailure = nil
        guard let directories = FileManager.default.enumerator(at: stage,
          includingPropertiesForKeys: [.isDirectoryKey], options: [.includesDirectoriesPostOrder],
          errorHandler: { _, error in enumerationFailure = error; return false }) else {
          throw BoomError.unavailable("Could not enumerate backup directories.")
        }
        while try autoreleasepool(invoking: { () throws -> Bool in
          guard let directory = directories.nextObject() as? URL else { return false }
          try checkCancellation()
          if try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try synchronizeDirectory(directory)
          }
          return true
        }) {}
        if let enumerationFailure { throw enumerationFailure }
        try synchronizeDirectory(stage)
      }
      try checkCancellation()
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
        if !cloneOnly { try synchronizeDirectory(target.deletingLastPathComponent()) }
      }
      return stageInfo
    } catch {
      let original = error
      // The source is untouched. Discard only this operation's partial copy
      // (or the admitted empty shell after a completed directory exchange).
      if FileManager.default.fileExists(atPath: stage.path) {
        do { try FileManager.default.removeItem(at: stage) }
        catch { throw WorkspaceBackupCleanupFailure(original: original, cleanup: error, path: stage) }
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

  private static func copyFile(_ source: URL, to target: URL, buffer: inout [UInt8],
    checkCancellation: @Sendable () throws -> Void, progress: CopyProgress?) throws {
    let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var output: Int32 = -1
    var failure: Error?
    do {
      var before = stat()
      guard fstat(input, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw BoomError.invalid("Backup source is not a regular file.") }
      output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
      guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      var copied: Int64 = 0
      while true {
        try checkCancellation()
        let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
        if count < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 { break }
        let total = copied.addingReportingOverflow(Int64(count))
        guard !total.overflow else { throw BoomError.invalid("Backup source extent overflowed.") }
        copied = total.partialValue
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
        try progress?(source, target, UInt64(copied))
      }
      var after = stat()
      guard fstat(input, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard copied == before.st_size, sameVersion(before, after) else {
        throw BoomError.stale("Backup source changed during the copy.")
      }
      guard fsync(output) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch { failure = error }
    failure = closing(input, after: failure, at: source)
    if output >= 0 { failure = closing(output, after: failure, at: target) }
    if let failure { throw failure }
  }

  private static func cloneFile(_ source: URL, to target: URL) throws {
    let input = open(source.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var parent: Int32 = -1
    var failure: Error?
    do {
      var before = stat(), after = stat()
      guard fstat(input, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard before.st_mode & S_IFMT == S_IFREG else { throw BoomError.invalid("Backup clone requires a regular source file.") }
      parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
      guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard fclonefileat(input, parent, target.lastPathComponent,
        UInt32(CLONE_NOFOLLOW_ANY | CLONE_RESOLVE_BENEATH)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard fstat(input, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard sameVersion(before, after) else { throw BoomError.stale("The backup source changed during its native clone.") }
    } catch { failure = error }
    failure = closing(input, after: failure, at: source)
    if parent >= 0 { failure = closing(parent, after: failure, at: target.deletingLastPathComponent()) }
    if let failure { throw failure }
  }

  private static func sameVersion(_ before: stat, _ after: stat) -> Bool {
    before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_mode == after.st_mode &&
      before.st_uid == after.st_uid && before.st_size == after.st_size &&
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
  }

  private static func closing(_ descriptor: Int32, after original: Error?, at path: URL) -> Error? {
    guard Darwin.close(descriptor) != 0 else { return original }
    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    if let original { return WorkspaceBackupCleanupFailure(original: original, cleanup: error, path: path) }
    return error
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let synchronized = fsync(descriptor)
    let failure: Error? = synchronized == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    if let failure = closing(descriptor, after: failure, at: url) { throw failure }
  }
}
