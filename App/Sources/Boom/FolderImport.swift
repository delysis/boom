import BoomCore
import Foundation

/// Reads only the chosen tree. The resulting paths and text are validated in Rust.
enum FolderImport {
  struct File: Sendable {
    let id: UUID
    let path: String
    let original: Data
    let text: String
  }
  static func read(_ root: URL, flag: CancellationFlag) throws -> [File] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    let rootValues = try root.resourceValues(forKeys: keys)
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw BoomError.invalid("Choose a real folder to import.")
    }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    var enumerationError: Error?
    guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
        enumerationError = error; return false
      }) else { throw BoomError.invalid("The chosen folder could not be read.") }
    var files: [File] = []
    var entries = 0
    var bytes = 0
    for case let url as URL in iterator {
      try flag.check()
      entries += 1
      guard entries <= 4096 else { throw BoomError.budget("Choose a smaller folder; this import exceeds 4096 entries.") }
      let values = try url.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
      let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
      guard resolved.pathComponents.starts(with: base.pathComponents) else {
        throw BoomError.invalid("A file is outside the chosen folder.")
      }
      let relative = resolved.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
      if values.isDirectory == true {
        guard relative.split(separator: "/").count < 16 else { throw BoomError.budget("The folder exceeds 16 levels.") }
        continue
      }
      guard values.isRegularFile == true, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else { continue }
      guard let size = values.fileSize, size <= 2_097_152 else { throw BoomError.budget("A text file exceeds 2 MiB.") }
      let original = try AttachmentProcessor.readGranted(url, limit: 2_097_152, allowEmpty: true)
      bytes += original.count
      guard files.count < 512, bytes <= 8_388_608,
        let text = String(data: original, encoding: .utf8) else {
        throw BoomError.invalid("Import at most 512 UTF-8 files and 8 MiB of text at a time.")
      }
      files.append(File(id: UUID(), path: relative, original: original, text: text))
    }
    if let enumerationError { throw enumerationError }
    files.sort { $0.path < $1.path }
    _ = try ProductCore.importedTexts(files.map { ImportedText(path: $0.path, text: $0.text) })
    return files
  }
}
