import BoomCore
import Foundation

/// Enumerates the chosen tree without materializing its documents.
enum FolderImport {
  struct ChosenFile: Sendable {
    let url: URL
    let path: String
  }
  /// Enumerate metadata only; the paged importer streams each chosen file.
  static func chosenFiles(_ root: URL, flag: CancellationFlag) throws -> [ChosenFile] {
    try flag.check()
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
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
    var files: [ChosenFile] = [], entries = 0
    for case let url as URL in iterator {
      try flag.check(); entries += 1
      guard entries <= 4096 else { throw BoomError.budget("Choose a smaller folder; this import exceeds 4096 entries.") }
      let values = try url.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
      let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
      guard resolved.pathComponents.starts(with: base.pathComponents) else {
        throw BoomError.invalid("A file is outside the chosen folder.")
      }
      let relative = resolved.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
      guard relative.split(separator: "/").count <= 16 else { throw BoomError.budget("The folder exceeds 16 levels.") }
      guard values.isRegularFile == true, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else { continue }
      guard files.count < 512 else { throw BoomError.budget("Import at most 512 text files at a time.") }
      files.append(ChosenFile(url: resolved, path: relative))
    }
    if let enumerationError { throw enumerationError }
    try flag.check()
    return files.sorted { $0.path < $1.path }
  }
}
