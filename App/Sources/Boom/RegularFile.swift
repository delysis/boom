import BoomCore
import Darwin
import Foundation

/// The type, bound and bytes belong to one opened file, not a preceding path lookup.
final class RegularFile {
  private let handle: FileHandle
  private let admitted: stat
  private let limit: Int64

  init(_ url: URL, limit: Int64, allowEmpty: Bool = true) throws {
    guard url.isFileURL, limit >= 0, limit < Int64.max else { throw BoomError.invalid("Invalid file read bound.") }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw BoomError.invalid("The file could not be opened safely.") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, info.st_size <= limit, allowEmpty || info.st_size > 0 else {
      close(descriptor)
      throw BoomError.invalid("Choose a regular file within its read bound; symlinks and directories are refused.")
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    admitted = info
    self.limit = limit
  }

  /// Opened-object metadata only; no content is read by admission planning.
  var byteCount: Int64 { admitted.st_size }

  func chunks(_ consume: (Data) throws -> Void) throws -> Int64 {
    var total: Int64 = 0
    while try autoreleasepool(invoking: { () throws -> Bool in
      // One extra byte detects growth without admitting an unbounded allocation.
      let count = Int(min(1_048_576, limit - total + 1))
      guard let bytes = try handle.read(upToCount: count), !bytes.isEmpty else { return false }
      total += Int64(bytes.count)
      guard total <= limit else { throw BoomError.budget("The file grew beyond its read bound.") }
      try consume(bytes)
      return true
    }) {}
    var final = stat()
    guard fstat(handle.fileDescriptor, &final) == 0, total == admitted.st_size,
      final.st_size == admitted.st_size,
      final.st_mtimespec.tv_sec == admitted.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == admitted.st_mtimespec.tv_nsec else {
      throw BoomError.stale("The opened file changed during reading; no content was admitted.")
    }
    return total
  }

  func data() throws -> Data {
    var result = Data()
    _ = try chunks { result.append($0) }
    return result
  }
}
