import BoomCore
import Darwin
import Foundation
import Metal
import MLX

enum ModelPurpose: String, Codable, CaseIterable, Sendable {
  case consultation, writing
  var title: String { rawValue.capitalized }
}
struct ModelPackManifest: Codable, Sendable {
  let schema: Int
  let purpose: ModelPurpose
  let upstreamRepository: String
  let upstreamRevision: String
  let upstreamFiles: [ModelFile]
  let runtimeRevision: String
  let bits: Int
  let groupSize: Int
  let calibration: String
  let files: [ModelFile]
  var weightBytes: UInt64 {
    UInt64(files.filter { $0.path.hasSuffix(".safetensors") }.reduce(Int64(0)) { $0 + $1.bytes })
  }
}
struct ModelCatalogEntry: Codable, Sendable {
  let purpose: ModelPurpose
  let repository: String
  let revision: String
  let manifestDigest: String
  let manifest: ModelPackManifest
  var bytes: Int64 { manifest.files.reduce(Int64(0)) { $0 + $1.bytes } }
}
private struct ModelCatalog: Codable { let entries: [ModelCatalogEntry] }

enum ModelResidency {
  static func memoryAccounting() -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))) : (0, 0)
  }
  static func footprint() -> UInt64 { memoryAccounting().current }
  static func limits() throws -> ResidencyLimits {
    guard let device = MTLCreateSystemDefaultDevice() else { throw BoomError.unavailable("Metal is unavailable.") }
    return try ProductCore.residencyLimits(physical: ProcessInfo.processInfo.physicalMemory,
      metal: device.recommendedMaxWorkingSetSize)
  }
  static func budget() throws -> UInt64 { try limits().applicationBytes }
  // MLX's allocator setting is a reclamation threshold, not an OS hard limit.
  // Admission and measured process footprint remain authoritative.
  static func configure() throws {
    let policy = try limits()
    Memory.memoryLimit = Int(clamping: policy.allocatorBytes)
    Memory.cacheLimit = Int(clamping: policy.cacheBytes)
    Memory.clearCache()
  }
  static func check() throws {
    let measured = footprint()
    guard measured > 0 else { throw BoomError.unavailable("Process memory accounting is unavailable.") }
    guard max(measured, UInt64(max(0, Memory.activeMemory + Memory.cacheMemory))) <= (try budget()) else {
      throw BoomError.budget("The operation exceeded Bloom's application memory budget. Its output was retained.")
    }
  }
  static func availableBytes() throws -> UInt64 {
    let used = max(footprint(), UInt64(max(0, Memory.activeMemory + Memory.cacheMemory)))
    let limit = try budget()
    return used < limit ? limit - used : 0
  }
  static func admit(weightBytes: UInt64) throws {
    try check()
    guard let device = MTLCreateSystemDefaultDevice() else { throw BoomError.unavailable("Metal is unavailable.") }
    let used = max(footprint(), UInt64(max(0, Memory.activeMemory + Memory.cacheMemory)))
    guard try ProductCore.admitModelLoad(physical: ProcessInfo.processInfo.physicalMemory,
      metal: device.recommendedMaxWorkingSetSize, resident: used, weights: weightBytes) else {
      throw BoomError.budget("This model does not fit alongside the resident model. Close the inactive model before loading it.")
    }
  }
}

enum ModelPacks {
  static let runtimeRevision = "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4"
  static let manifestName = "bloom-model.json"
  static func entries() throws -> [ModelCatalogEntry] {
    guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else {
      throw BoomError.unavailable("The signed model catalog is missing.")
    }
    return try JSONDecoder().decode(ModelCatalog.self, from: Data(contentsOf: url)).entries
  }
  static func entry(_ purpose: ModelPurpose) throws -> ModelCatalogEntry {
    guard let entry = try entries().first(where: { $0.purpose == purpose }) else {
      throw BoomError.unavailable("The qualified \(purpose.rawValue) model pack is not in this build's catalog.")
    }
    return entry
  }
  private static func publicSnapshot(_ specification: ModelPackManifest, hub: URL) -> URL {
    hub.appendingPathComponent("models--" + specification.upstreamRepository.replacingOccurrences(of: "/", with: "--"))
      .appendingPathComponent("snapshots/" + specification.upstreamRevision)
  }
  static func officialCached(_ purpose: ModelPurpose) -> URL? {
    guard let specification = try? entry(purpose).manifest else { return nil }
    return HuggingFaceCache.hubs.map { publicSnapshot(specification, hub: $0) }.first { snapshot in
      specification.upstreamFiles.allSatisfy {
        FileManager.default.fileExists(atPath: snapshot.appendingPathComponent($0.path).path)
      }
    }
  }
  private static func verifyPublicFiles(_ directory: URL, specification: ModelPackManifest) throws {
    let root = directory.resolvingSymlinksInPath()
    let blobs = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blobs").resolvingSymlinksInPath()
    for file in specification.upstreamFiles {
      try DownloadPolicy.validateRelativePath(file.path)
      let target = directory.appendingPathComponent(file.path).resolvingSymlinksInPath()
      guard target.path.hasPrefix(root.path + "/") || target.path.hasPrefix(blobs.path + "/") else {
        throw BoomError.invalid("Public checkpoint cache link escapes its snapshot and blob store.")
      }
      let value = try ModelInstaller.hashFile(target, maxBytes: file.bytes)
      guard value.bytes == file.bytes, value.sha256 == file.sha256 else { throw BoomError.invalid("Cached public checkpoint changed: " + file.path) }
    }
  }
  struct Admission: Sendable {
    let directory: URL
    let identity: String
    let weightBytes: UInt64
    let converted: Bool
  }
  static func admission(_ directory: URL) throws -> Admission {
    let manifest = directory.appendingPathComponent(manifestName)
    if FileManager.default.fileExists(atPath: manifest.path) {
      let digest = try ModelInstaller.hashFile(manifest, maxBytes: 4_194_304).sha256
      guard let purpose = try entries().first(where: { $0.manifestDigest == digest })?.purpose else {
        throw BoomError.invalid("This is not a catalog-qualified model pack.")
      }
      return try admission(directory, purpose: purpose)
    }
    guard let purpose = ModelPurpose.allCases.first(where: {
      officialCached($0)?.standardizedFileURL == directory.standardizedFileURL
    }) else { throw BoomError.invalid("This is not a pinned public Gemma checkpoint.") }
    return try admission(directory, purpose: purpose)
  }
  static func admission(_ directory: URL, purpose: ModelPurpose) throws -> Admission {
    let specification = try entry(purpose)
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifestName).path) {
      let manifest = try verify(directory, purpose: purpose)
      return Admission(directory: directory, identity: specification.manifestDigest, weightBytes: manifest.weightBytes, converted: true)
    }
    guard let official = officialCached(purpose), directory.standardizedFileURL == official.standardizedFileURL else {
      throw BoomError.invalid("This directory is not the pinned public Gemma checkpoint.")
    }
    try verifyPublicFiles(directory, specification: specification.manifest)
    let weights = specification.manifest.upstreamFiles.filter { $0.path.hasSuffix(".safetensors") }.reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
    return Admission(directory: directory, identity: specification.manifest.upstreamRepository + "@" + specification.manifest.upstreamRevision,
      weightBytes: weights, converted: false)
  }
  static func cached(_ purpose: ModelPurpose) -> URL? { installed(purpose) ?? officialCached(purpose) }
  static func installed(_ purpose: ModelPurpose) -> URL? {
    HuggingFaceCache.hubs.map { $0.appendingPathComponent("bloom/" + purpose.rawValue) }.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent(manifestName).path)
    }
  }
  static func verify(_ directory: URL, purpose: ModelPurpose) throws -> ModelPackManifest {
    let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard root.isDirectory == true, root.isSymbolicLink != true else { throw BoomError.invalid("Model pack is not a real directory.") }
    let entry = try entry(purpose)
    let manifestURL = directory.appendingPathComponent(manifestName)
    let digest = try ModelInstaller.hashFile(manifestURL, maxBytes: 4_194_304).sha256
    guard digest == entry.manifestDigest else { throw BoomError.invalid("Model pack manifest differs from the signed catalog.") }
    let manifest = try JSONDecoder().decode(ModelPackManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.schema == 1, manifest.purpose == purpose, manifest.runtimeRevision == runtimeRevision,
      manifest.bits == 4, manifest.groupSize == 32,
      !manifest.files.isEmpty, manifest.files.count <= 128,
      Set(manifest.files.map(\.path)).count == manifest.files.count,
      manifest.files.contains(where: { $0.path == "tokenizer.json" }),
      manifest.files.contains(where: { $0.path == "config.json" }) else { throw BoomError.invalid("Unsupported model pack manifest.") }
    let expected = Set(manifest.files.map(\.path) + [manifestName])
    let actual = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
    guard actual == expected else { throw BoomError.invalid("Model pack contains missing or unexpected files.") }
    for file in manifest.files {
      try DownloadPolicy.validateRelativePath(file.path)
      guard !file.path.contains("/"), file.bytes > 0, file.bytes <= 17_179_869_184 else { throw BoomError.invalid("Invalid model file bound.") }
      let value = try ModelInstaller.hashFile(directory.appendingPathComponent(file.path), maxBytes: file.bytes)
      guard value.bytes == file.bytes, value.sha256 == file.sha256 else { throw BoomError.invalid("Model file changed: \(file.path)") }
    }
    return manifest
  }
  static func importPack(_ source: URL, flag: CancellationFlag) throws -> ModelPackManifest {
    _ = try ModelInstaller.hashFile(source.appendingPathComponent(manifestName), maxBytes: 4_194_304)
    let data = try Data(contentsOf: source.appendingPathComponent(manifestName))
    let manifest = try JSONDecoder().decode(ModelPackManifest.self, from: data)
    _ = try verify(source, purpose: manifest.purpose)
    try flag.check()
    let root = HuggingFaceCache.bloomModels
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent(manifest.purpose.rawValue)
    guard !FileManager.default.fileExists(atPath: target.path) else { throw BoomError.stale("That model is already installed. Its files were retained.") }
    let stage = root.appendingPathComponent(".import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stage) }
    try FileManager.default.copyItem(at: source, to: stage)
    try flag.check(); _ = try verify(stage, purpose: manifest.purpose)
    try FileManager.default.moveItem(at: stage, to: target)
    return manifest
  }
  static func install(_ purpose: ModelPurpose, flag: CancellationFlag,
    progress: @escaping @Sendable (String) -> Void) async throws -> URL {
    if let cached = cached(purpose) {
      _ = try await detachedWork { try admission(cached, purpose: purpose) }
      return cached
    }
    let entry = try entry(purpose)
    let specification = entry.manifest
    let target = publicSnapshot(specification, hub: HuggingFaceCache.hub)
    let root = target.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw BoomError.invalid("The cached public snapshot is incomplete. Its files were retained.")
    }
    let stage = root.appendingPathComponent(".bloom-download-" + specification.upstreamRevision)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    let resources = try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeAvailableCapacityForImportantUsageKey])
    guard resources.isDirectory == true, resources.isSymbolicLink != true else { throw BoomError.invalid("Unsafe model download directory.") }
    let total = specification.upstreamFiles.reduce(Int64(0)) { $0 + $1.bytes }
    if let available = resources.volumeAvailableCapacityForImportantUsage, available < total + 1_073_741_824 {
      throw BoomError.budget("The public checkpoint needs " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) + " of free disk space.")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    for file in specification.upstreamFiles {
      try flag.check()
      try DownloadPolicy.validateRelativePath(file.path)
      let destination = stage.appendingPathComponent(file.path)
      if file.bytes > 0, FileManager.default.fileExists(atPath: destination.path),
        let hash = try? ModelInstaller.hashFile(destination, maxBytes: file.bytes),
        hash.bytes == file.bytes, hash.sha256 == file.sha256 { continue }
      guard let url = URL(string: "https://huggingface.co/\(specification.upstreamRepository)/resolve/\(specification.upstreamRevision)/\(file.path)") else { throw BoomError.invalid("Invalid catalog URL.") }
      let partial = stage.appendingPathComponent(file.path + ".partial")
      if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
      let partialInfo = try partial.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard partialInfo.isRegularFile == true, partialInfo.isSymbolicLink != true,
        (partialInfo.fileSize ?? Int.max) <= file.bytes else { throw BoomError.invalid("Unsafe partial model file.") }
      let handle = try FileHandle(forWritingTo: partial)
      do {
        var offset = Int64(try handle.seekToEnd())
        while offset < file.bytes {
          try flag.check()
          var request = URLRequest(url: url)
          let last = min(file.bytes - 1, offset + 33_554_431)
          request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
          progress("\(purpose.title) · \(ByteCountFormatter.string(fromByteCount: offset, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: max(0, file.bytes), countStyle: .file))")
          let (temporary, response) = try await session.download(for: request)
          defer { try? FileManager.default.removeItem(at: temporary) }
          guard let http = response as? HTTPURLResponse, [200,206].contains(http.statusCode),
            http.url.map(DownloadPolicy.permits) == true else { throw BoomError.unavailable("Model download failed.") }
          let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
          guard size > 0, size <= 33_554_432, Int64(size) == last - offset + 1, http.statusCode == 206 || offset == 0 else { throw BoomError.invalid("Server did not honor the bounded download range.") }
          if http.statusCode == 206 {
            guard http.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(last)/\(file.bytes)" else { throw BoomError.invalid("Model range is inconsistent.") }
          }
          try handle.write(contentsOf: Data(contentsOf: temporary)); try handle.synchronize()
          offset += Int64(size)
        }
        try handle.close()
      } catch { try? handle.close(); throw error }
      let result = try ModelInstaller.hashFile(partial, maxBytes: file.bytes)
      guard result.sha256 == file.sha256, result.bytes == file.bytes else { throw BoomError.invalid("Downloaded file failed verification; partial retained.") }
      try FileManager.default.moveItem(at: partial, to: destination)
    }
    _ = try await detachedWork { try verifyPublicFiles(stage, specification: specification) }
    try flag.check(); try FileManager.default.moveItem(at: stage, to: target)
    return target
  }
}
