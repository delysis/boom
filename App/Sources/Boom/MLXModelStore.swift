import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import BoomCore

/// Model discovery is intentionally limited to Google's QAT safetensors in
/// the ordinary Hugging Face cache. Conversion publishes a complete, hashed
/// Boom variant alongside that cache; an interrupted stage is never loaded.
enum MLXModelStore {
  struct Source: Sendable {
    let size: GemmaSize
    let repository: String
    let revision: String
    let directory: URL
  }

  private struct Receipt: Codable {
    let schema: Int
    let repository: String
    let revision: String
    let size: String
    let runtimeRevision: String
    let files: [ModelFile]
  }

  static let runtimeRevision = "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4"
  private static let receiptName = "boom-mlx-model.json"

  private static func completeWeights(at directory: URL) -> Bool {
    let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
    if FileManager.default.fileExists(atPath: indexURL.path) {
      guard let data = try? Data(contentsOf: indexURL), data.count <= 4_194_304,
        let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let weights = index["weight_map"] as? [String: String], !weights.isEmpty
      else { return false }
      let names = Set(weights.values)
      guard names.count <= 128 else { return false }
      return names.allSatisfy { name in
        name.range(of: #"^model-[0-9]{5}-of-[0-9]{5}\.safetensors$"#,
          options: .regularExpression) != nil
          && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path)
      }
    }
    return FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("model.safetensors").path)
  }

  static func cachedSource(for size: GemmaSize) -> Source? {
    cachedSource(for: size, repository: size.qatSafetensorsRepository)
  }

  static func cachedBaseSource(for size: GemmaSize) -> Source? {
    cachedSource(for: size, repository: "google/gemma-4-\(size.rawValue)")
  }

  private static func cachedSource(for size: GemmaSize, repository: String) -> Source? {
    let directory = HuggingFaceCache.hub.appendingPathComponent(
      "models--" + repository.replacingOccurrences(of: "/", with: "--"))
      .appendingPathComponent("snapshots")
    let snapshots = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for snapshot in snapshots.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
      let revision = snapshot.lastPathComponent
      guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
        FileManager.default.fileExists(
          atPath: snapshot.appendingPathComponent("config.json").path),
        FileManager.default.fileExists(
          atPath: snapshot.appendingPathComponent("tokenizer.json").path),
        completeWeights(at: snapshot)
      else { continue }
      return Source(size: size, repository: repository, revision: revision, directory: snapshot)
    }
    return nil
  }

  static func cachedAssistant(for size: GemmaSize) -> URL? {
    let repository = size.qatAssistantRepository
    let snapshots = HuggingFaceCache.hub.appendingPathComponent(
      "models--" + repository.replacingOccurrences(of: "/", with: "--"))
      .appendingPathComponent("snapshots")
    let directories = (try? FileManager.default.contentsOfDirectory(
      at: snapshots, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    return directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
      .first { snapshot in
        snapshot.lastPathComponent.range(
          of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
          && FileManager.default.fileExists(
            atPath: snapshot.appendingPathComponent("config.json").path)
          && completeWeights(at: snapshot)
      }
  }

  static func ensureAssistant(for size: GemmaSize) async throws -> URL {
    if let cached = cachedAssistant(for: size) { return cached }
    let downloader: any Downloader = #hubDownloader(
      HubClient(cache: HubCache(cacheDirectory: HuggingFaceCache.hub)))
    let directory = try await downloader.download(
      id: size.qatAssistantRepository, revision: nil,
      matching: ["*.safetensors", "*.json"], useLatest: false,
      progressHandler: { _ in })
    guard FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("config.json").path),
      completeWeights(at: directory)
    else { throw BoomError.invalid("The matching Gemma assistant download is incomplete.") }
    return directory
  }

  static func bestCachedSource(physicalBytes: UInt64) -> Source? {
    guard let maximum = ModelMemoryPolicy.recommendedSize(physicalBytes: physicalBytes),
      let last = GemmaSize.allCases.firstIndex(of: maximum)
    else { return nil }
    return GemmaSize.allCases[...last].reversed().compactMap(cachedSource(for:)).first
  }

  static func ensureSource(
    for size: GemmaSize,
    progress: @Sendable @escaping (Progress) -> Void = { _ in }
  ) async throws -> Source {
    if let cached = cachedSource(for: size) { return cached }
    let downloader: any Downloader = #hubDownloader(
      HubClient(cache: HubCache(cacheDirectory: HuggingFaceCache.hub)))
    let directory = try await downloader.download(
      id: size.qatSafetensorsRepository, revision: nil,
      matching: ["*.safetensors", "*.json", "*.jinja"], useLatest: false,
      progressHandler: progress)
    guard let source = cachedSource(for: size),
      source.directory.standardizedFileURL == directory.standardizedFileURL
    else { throw BoomError.invalid("The first-party Gemma download is incomplete.") }
    return source
  }

  static func ensureBaseSource(for size: GemmaSize) async throws -> Source {
    if let cached = cachedBaseSource(for: size) { return cached }
    let repository = "google/gemma-4-\(size.rawValue)"
    let downloader: any Downloader = #hubDownloader(
      HubClient(cache: HubCache(cacheDirectory: HuggingFaceCache.hub)))
    let directory = try await downloader.download(
      id: repository, revision: nil,
      matching: ["*.safetensors", "*.json", "*.jinja"], useLatest: false,
      progressHandler: { _ in })
    guard let source = cachedBaseSource(for: size),
      source.directory.standardizedFileURL == directory.standardizedFileURL
    else { throw BoomError.invalid("The first-party base model download is incomplete.") }
    return source
  }

  static func convertedURL(for source: Source) -> URL {
    let family = source.repository == source.size.qatSafetensorsRepository
      ? "qat-q4_0" : "base-q4"
    return HuggingFaceCache.boomModels.appendingPathComponent(
      "gemma4-\(source.size.rawValue.lowercased())-\(family)-mlx-\(source.revision)")
  }

  static func verify(_ directory: URL, expected source: Source) throws {
    let receiptURL = directory.appendingPathComponent(receiptName)
    let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
    guard receipt.schema == 1, receipt.repository == source.repository,
      receipt.revision == source.revision, receipt.size == source.size.rawValue,
      receipt.runtimeRevision == runtimeRevision, !receipt.files.isEmpty,
      receipt.files.contains(where: { $0.path == "config.json" }),
      receipt.files.contains(where: { $0.path.hasSuffix(".safetensors") }),
      Set(receipt.files.map(\.path)).count == receipt.files.count
    else { throw BoomError.invalid("Converted Gemma model receipt is invalid.") }
    for file in receipt.files {
      try DownloadPolicy.validateRelativePath(file.path)
      let url = directory.appendingPathComponent(file.path)
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        Int64(values.fileSize ?? -1) == file.bytes,
        try ModelInstaller.hashFile(url, maxBytes: file.bytes).sha256 == file.sha256
      else { throw BoomError.invalid("Converted Gemma model file changed: \(file.path)") }
    }
  }

  static func prepare(_ source: Source) async throws -> URL {
    let destination = convertedURL(for: source)
    if FileManager.default.fileExists(atPath: destination.path) {
      try verify(destination, expected: source)
      return destination
    }
    try FileManager.default.createDirectory(
      at: HuggingFaceCache.boomModels, withIntermediateDirectories: true)
    let stage = HuggingFaceCache.boomModels.appendingPathComponent(
      ".converting-\(UUID().uuidString)")
    let inputs = HuggingFaceCache.boomModels.appendingPathComponent(
      ".inputs-\(UUID().uuidString)")
    defer {
      // This path was created for this invocation alone. A failed conversion
      // must not leave a partial checkpoint that a later scan could mistake
      // for a usable model.
      try? FileManager.default.removeItem(at: stage)
      try? FileManager.default.removeItem(at: inputs)
    }
    // Hugging Face snapshots are relative symlinks into ../../blobs. MLX's
    // converter copies those symlinks verbatim, which breaks them at the new
    // location and leaves config/tokenizer absent. Stage real sidecars and
    // hard links to the already cached weight blobs on this same volume.
    try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
    for item in try FileManager.default.contentsOfDirectory(
      at: source.directory, includingPropertiesForKeys: nil)
    where ["json", "jinja", "safetensors"].contains(item.pathExtension.lowercased()) {
      let resolved = item.resolvingSymlinksInPath()
      let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw BoomError.invalid("Cached Gemma source contains an unsafe file.")
      }
      let target = inputs.appendingPathComponent(item.lastPathComponent)
      if item.pathExtension == "safetensors" {
        try FileManager.default.linkItem(at: resolved, to: target)
      } else {
        try FileManager.default.copyItem(at: resolved, to: target)
      }
    }
    if source.repository == source.size.qatSafetensorsRepository {
      try await MLXGemmaRunner.convertQAT(source: inputs, destination: stage)
    } else if source.repository == "google/gemma-4-\(source.size.rawValue)" {
      try await MLXGemmaRunner.convertBase(source: inputs, destination: stage)
    } else {
      throw BoomError.invalid("Unsupported Gemma conversion source.")
    }
    let children = try FileManager.default.contentsOfDirectory(
      at: stage, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    let files = try children.compactMap { url -> ModelFile? in
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
        return nil
      }
      let digest = try ModelInstaller.hashFile(url, maxBytes: Int64(size)).sha256
      return ModelFile(path: url.lastPathComponent, bytes: Int64(size), sha256: digest)
    }.sorted { $0.path < $1.path }
    guard files.contains(where: { $0.path == "config.json" }),
      files.contains(where: { $0.path.hasSuffix(".safetensors") })
    else {
      throw BoomError.invalid(
        "MLX conversion produced no complete model (files: "
          + files.map(\.path).joined(separator: ", ") + ").")
    }
    let receipt = Receipt(
      schema: 1, repository: source.repository, revision: source.revision,
      size: source.size.rawValue, runtimeRevision: runtimeRevision, files: files)
    let data = try JSONEncoder().encode(receipt)
    try data.write(to: stage.appendingPathComponent(receiptName), options: .atomic)
    try verify(stage, expected: source)
    try FileManager.default.moveItem(at: stage, to: destination)
    return destination
  }
}
