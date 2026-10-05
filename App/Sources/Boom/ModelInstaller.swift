import BoomCore
import CryptoKit
import Foundation

struct ModelFile: Codable, Equatable, Sendable {
  let path: String
  let bytes: Int64
  let sha256: String
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
enum ModelInstaller {
  static func hashFile(_ url: URL, maxBytes: Int64) throws -> (sha256: String, bytes: Int64) {
    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard info.isRegularFile == true, info.isSymbolicLink != true,
      let size = info.fileSize, Int64(size) <= maxBytes else { throw BoomError.invalid("Unsafe model file.") }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256(), total: Int64 = 0
    while let chunk = try handle.read(upToCount: 4_194_304), !chunk.isEmpty {
      total += Int64(chunk.count)
      guard total <= maxBytes else { throw BoomError.budget("Model file grew during verification.") }
      hash.update(data: chunk)
    }
    return (hash.finalize().map { String(format: "%02x", $0) }.joined(), total)
  }
}
