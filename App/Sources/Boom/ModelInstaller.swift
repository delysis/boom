import BoomCore
import CryptoKit
import Darwin
import Foundation

struct ModelFile: Codable, Equatable, Sendable {
  let path: String
  let bytes: Int64
  let sha256: String
}
/// A kernel-owned lock protects resumable files across Author and Chat builds.
/// A leftover lock file has no authority after its owning descriptor closes.
final class ModelInstallLease {
  private var descriptor: Int32
  init(root: URL, identity: String) throws {
    let path = root.appendingPathComponent(".bloom-install-" + identity + ".lock")
    let descriptor = open(path.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw BoomError.invalid("The model installation lock could not be opened safely.") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(descriptor); throw BoomError.invalid("The model installation lock is not a regular file.")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw BoomError.unavailable("Another Bloom process is installing this model. Its download was retained.")
    }
    self.descriptor = descriptor
  }
  func release() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
  deinit { release() }
}
enum HuggingFaceCache {
  static func roots(environment: [String: String], home: URL) -> [URL] {
    var paths: [URL] = []
    func add(_ path: String?, suffix: String = "") {
      guard let path, path.hasPrefix("/") else { return }
      let url = URL(fileURLWithPath: path).appendingPathComponent(suffix).standardizedFileURL
      if !paths.contains(url) { paths.append(url) }
    }
    add(environment["HF_HUB_CACHE"])
    add(environment["HF_HOME"], suffix: "hub")
    add(environment["XDG_CACHE_HOME"], suffix: "huggingface/hub")
    add(home.appendingPathComponent(".cache/huggingface/hub").path)
    return paths
  }
  static var hubs: [URL] {
    roots(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  static var hub: URL { hubs[0] }

  static var bloomModels: URL { hub.appendingPathComponent("bloom", isDirectory: true) }
}
enum LocalModelDirectories {
  static func roots(home: URL) -> [URL] {
    [home.appendingPathComponent(".lmstudio/models"), home.appendingPathComponent(".cache/lm-studio/models")]
  }
  static var roots: [URL] { roots(home: FileManager.default.homeDirectoryForCurrentUser) }
  static func cached(_ checkpoint: PublishedCheckpoint, roots: [URL]) -> URL? {
    roots.map { $0.appendingPathComponent(checkpoint.repository) }.first { directory in
      checkpoint.files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path) }
    }
  }
}
enum ModelInstaller {
  static func hashFile(_ url: URL, maxBytes: Int64) throws -> (sha256: String, bytes: Int64) {
    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard info.isRegularFile == true, info.isSymbolicLink != true,
      let size = info.fileSize, Int64(size) <= maxBytes else { throw BoomError.invalid("Unsafe model file.") }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256(), total: Int64 = 0
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let chunk = try handle.read(upToCount: 4_194_304), !chunk.isEmpty else { return false }
      total += Int64(chunk.count)
      guard total <= maxBytes else { throw BoomError.budget("Model file grew during verification.") }
      hash.update(data: chunk)
      return true
    }) {
    }
    return (hash.finalize().map { String(format: "%02x", $0) }.joined(), total)
  }
}
