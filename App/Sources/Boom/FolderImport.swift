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
  struct File: Sendable {
    let id: UUID
    let path: String
    let original: Data
    let text: String
  }
  static func read(_ root: URL, flag: CancellationFlag) throws -> [File] {
    var files: [File] = []
    var bytes = 0
    for chosen in try chosenFiles(root, flag: flag) {
      try flag.check()
      let original = try AttachmentProcessor.readGranted(chosen.url, limit: 2_097_152, allowEmpty: true)
      bytes += original.count
      guard files.count < 512, bytes <= 8_388_608,
        let text = String(data: original, encoding: .utf8) else {
        throw BoomError.invalid("Import at most 512 UTF-8 files and 8 MiB of text at a time.")
      }
      files.append(File(id: UUID(), path: chosen.path, original: original, text: text))
    }
    try ProductCore.admitImportedTexts(files.map { ImportedText(path: $0.path, text: $0.text) })
    return files
  }
}

enum DocumentImport {
  static func read(_ urls: [URL], flag: CancellationFlag) throws -> [FolderImport.File] {
    try flag.check()
    try ProductCore.admitImportedTexts(urls.map { ImportedText(path: $0.lastPathComponent, text: "") }, documents: true)
    var files: [FolderImport.File] = [], totalBytes = 0
    for url in urls {
      try flag.check()
      let scope = url.startAccessingSecurityScopedResource()
      defer { if scope { url.stopAccessingSecurityScopedResource() } }
      let original = try AttachmentProcessor.readGranted(url, limit: 2_097_152, allowEmpty: true)
      totalBytes += original.count
      try ProductCore.importBudget(files: urls.count, bytes: totalBytes)
      guard let text = String(data: original, encoding: .utf8) else {
        throw BoomError.invalid("Document import requires UTF-8 text.")
      }
      files.append(FolderImport.File(id: UUID(), path: url.lastPathComponent, original: original, text: text))
    }
    try ProductCore.admitImportedTexts(files.map { ImportedText(path: $0.path, text: $0.text) }, documents: true)
    return files
  }
}
