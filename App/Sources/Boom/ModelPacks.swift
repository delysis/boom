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
struct PublishedCheckpoint: Codable, Sendable {
  let purpose: ModelPurpose
  let repository: String
  let revision: String
  let files: [ModelFile]
}
struct CheckpointRequirements: Decodable, Sendable {
  let identity: String
  let weightBytes: UInt64
  let downloadBytes: UInt64
  let diskBytes: UInt64
}
struct CheckpointRange: Decodable, Sendable {
  let first: UInt64
  let last: UInt64
  let bytes: UInt64
  let contentRange: String
}
private struct ModelCatalog: Codable {
  let entries: [ModelCatalogEntry]
  let publishedCheckpoints: [PublishedCheckpoint]
}

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
  static func admit(weightBytes: UInt64, residentWeights: UInt64 = 0) throws {
    try check()
    guard try ProductCore.admitModelWeights(physical: ProcessInfo.processInfo.physicalMemory,
      resident: residentWeights, weights: weightBytes) else {
      throw BoomError.budget("Model weights would use more than half this Mac's memory.")
    }
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
  private static func catalog() throws -> ModelCatalog {
    guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else {
      throw BoomError.unavailable("The signed model catalog is missing.")
    }
    return try JSONDecoder().decode(ModelCatalog.self, from: Data(contentsOf: url))
  }
  static func entries() throws -> [ModelCatalogEntry] { try catalog().entries }
  static func publishedCheckpoints(_ purpose: ModelPurpose) throws -> [PublishedCheckpoint] {
    try catalog().publishedCheckpoints.filter { $0.purpose == purpose }
  }
  static func setupChoices(writing: Bool) throws -> [ModelSetupChoice] {
    var choices: [ModelSetupChoice] = []
    for purpose in writing ? ModelPurpose.allCases : [.consultation] {
      if let directory = installed(purpose) {
        let entry = try entry(purpose)
        choices.append(ModelSetupChoice(candidate: ModelSetupCandidate(identity: entry.manifestDigest,
          purpose: purpose, weightBytes: entry.manifest.weightBytes, diskBytes: 0, cached: true, rank: 0),
          directory: directory, checkpoint: nil))
      }
      for (index, checkpoint) in try publishedCheckpoints(purpose).enumerated() {
        let requirements = try ProductCore.checkpointRequirements(checkpoint)
        let directory = cachedSnapshot(checkpoint, hubs: HuggingFaceCache.hubs)
        choices.append(ModelSetupChoice(candidate: ModelSetupCandidate(identity: requirements.identity,
          purpose: purpose, weightBytes: requirements.weightBytes, diskBytes: directory == nil ? requirements.diskBytes : 0,
          cached: directory != nil, rank: index + 1), directory: directory, checkpoint: checkpoint))
      }
    }
    return choices
  }
  static func published(_ purpose: ModelPurpose) throws -> PublishedCheckpoint {
    guard let checkpoint = try catalog().publishedCheckpoints.first(where: { $0.purpose == purpose }) else {
      throw BoomError.unavailable("The public \(purpose.rawValue) model is missing from this build's catalog.")
    }
    _ = try ProductCore.checkpointRequirements(checkpoint)
    return checkpoint
  }
  static func entry(_ purpose: ModelPurpose) throws -> ModelCatalogEntry {
    guard let entry = try entries().first(where: { $0.purpose == purpose }) else {
      throw BoomError.unavailable("The qualified \(purpose.rawValue) model pack is not in this build's catalog.")
    }
    return entry
  }
  static func snapshot(repository: String, revision: String, hub: URL) -> URL {
    hub.appendingPathComponent("models--" + repository.replacingOccurrences(of: "/", with: "--"))
      .appendingPathComponent("snapshots/" + revision)
  }
  static func cachedSnapshot(_ checkpoint: PublishedCheckpoint, hubs: [URL]) -> URL? {
    guard (try? ProductCore.checkpointRequirements(checkpoint)) != nil else { return nil }
    return hubs.map { snapshot(repository: checkpoint.repository, revision: checkpoint.revision, hub: $0) }.first { snapshot in
      checkpoint.files.allSatisfy { FileManager.default.fileExists(atPath: snapshot.appendingPathComponent($0.path).path) }
    }
  }
  static func publishedCached(_ purpose: ModelPurpose) -> URL? {
    guard let checkpoint = try? published(purpose) else { return nil }
    return cachedSnapshot(checkpoint, hubs: HuggingFaceCache.hubs)
  }
  static func officialCached(_ purpose: ModelPurpose) -> URL? {
    guard let specification = try? entry(purpose).manifest else { return nil }
    return HuggingFaceCache.hubs.map { snapshot(repository: specification.upstreamRepository, revision: specification.upstreamRevision, hub: $0) }.first { snapshot in
      specification.upstreamFiles.allSatisfy {
        FileManager.default.fileExists(atPath: snapshot.appendingPathComponent($0.path).path)
      }
    }
  }
  private static func verifyPublicFiles(_ directory: URL, files: [ModelFile]) throws {
    let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard info.isDirectory == true, info.isSymbolicLink != true else { throw BoomError.invalid("The model snapshot is not a real directory.") }
    let root = directory.resolvingSymlinksInPath()
    let blobs = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blobs").resolvingSymlinksInPath()
    for file in files {
      try DownloadPolicy.validateRelativePath(file.path)
      let target = directory.appendingPathComponent(file.path).resolvingSymlinksInPath()
      guard target.path.hasPrefix(root.path + "/") || target.path.hasPrefix(blobs.path + "/") else {
        throw BoomError.invalid("Public checkpoint cache link escapes its snapshot and blob store.")
      }
      let value = try ModelInstaller.hashFile(target, maxBytes: file.bytes)
      guard value.bytes == file.bytes, value.sha256 == file.sha256 else { throw BoomError.invalid("Cached public checkpoint changed: " + file.path) }
    }
  }
  static func verifyPublished(_ directory: URL, checkpoint: PublishedCheckpoint) throws -> CheckpointRequirements {
    let requirements = try ProductCore.checkpointRequirements(checkpoint)
    try verifyPublicFiles(directory, files: checkpoint.files)
    return requirements
  }
  struct Admission: Sendable {
    enum Kind: String, Sendable { case convertedPack = "converted_pack", officialCheckpoint = "official_checkpoint", publishedCheckpoint = "published_checkpoint" }
    let directory: URL
    let purpose: ModelPurpose
    let identity: String
    let weightBytes: UInt64
    let kind: Kind
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
    let config = try ModelInstaller.hashFile(directory.appendingPathComponent("config.json"), maxBytes: 4_194_304)
    if let purpose = try catalog().publishedCheckpoints.first(where: {
      $0.files.contains(where: { $0.path == "config.json" && $0.sha256 == config.sha256 })
    })?.purpose { return try admission(directory, purpose: purpose) }
    for purpose in ModelPurpose.allCases {
      let specification = try entry(purpose).manifest
      if HuggingFaceCache.hubs.contains(where: {
        snapshot(repository: specification.upstreamRepository, revision: specification.upstreamRevision, hub: $0).standardizedFileURL.path == directory.standardizedFileURL.path
      }) { return try admission(directory, purpose: purpose) }
    }
    throw BoomError.invalid("This is not a pinned public Gemma checkpoint.")
  }
  static func admission(_ directory: URL, purpose: ModelPurpose) throws -> Admission {
    let specification = try entry(purpose)
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifestName).path) {
      let manifest = try verify(directory, purpose: purpose)
      return Admission(directory: directory, purpose: purpose, identity: specification.manifestDigest, weightBytes: manifest.weightBytes, kind: .convertedPack)
    }
    let config = try ModelInstaller.hashFile(directory.appendingPathComponent("config.json"), maxBytes: 4_194_304)
    if let checkpoint = try publishedCheckpoints(purpose).first(where: {
      $0.files.contains(where: { $0.path == "config.json" && $0.sha256 == config.sha256 })
    }) {
      let requirements = try verifyPublished(directory, checkpoint: checkpoint)
      return Admission(directory: directory, purpose: purpose, identity: requirements.identity, weightBytes: requirements.weightBytes, kind: .publishedCheckpoint)
    }
    guard HuggingFaceCache.hubs.contains(where: {
      snapshot(repository: specification.manifest.upstreamRepository, revision: specification.manifest.upstreamRevision, hub: $0).standardizedFileURL.path == directory.standardizedFileURL.path
    }) else {
      throw BoomError.invalid("This directory is not the pinned public Gemma checkpoint.")
    }
    try verifyPublicFiles(directory, files: specification.manifest.upstreamFiles)
    let weights = specification.manifest.upstreamFiles.filter { $0.path.hasSuffix(".safetensors") }.reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
    return Admission(directory: directory, purpose: purpose, identity: specification.manifest.upstreamRepository + "@" + specification.manifest.upstreamRevision,
      weightBytes: weights, kind: .officialCheckpoint)
  }
  static func cached(_ purpose: ModelPurpose) -> URL? { installed(purpose) ?? publishedCached(purpose) }
  static func evidenceManifest(_ admission: Admission, purpose: ModelPurpose) throws -> Data {
    if admission.kind == .convertedPack {
      return try Data(contentsOf: admission.directory.appendingPathComponent(manifestName))
    }
    let repository: String, revision: String, files: [ModelFile]
    if admission.kind == .publishedCheckpoint {
      guard let checkpoint = try catalog().publishedCheckpoints.first(where: {
        $0.repository + "@" + $0.revision == admission.identity
      }) else { throw BoomError.invalid("The admitted checkpoint is absent from the catalog.") }
      repository = checkpoint.repository; revision = checkpoint.revision; files = checkpoint.files
    } else {
      let checkpoint = try entry(purpose).manifest
      repository = checkpoint.upstreamRepository; revision = checkpoint.upstreamRevision; files = checkpoint.upstreamFiles
    }
    guard admission.identity == repository + "@" + revision else { throw BoomError.stale("The admitted model identity differs from its catalog.") }
    let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: admission.directory.appendingPathComponent("config.json"))) as? [String: Any]
    return try JSONSerialization.data(withJSONObject: ["schema": 1, "purpose": purpose.rawValue,
      "identity": admission.identity, "repository": repository, "revision": revision,
      "runtimeRevision": runtimeRevision, "weightKind": admission.kind.rawValue,
      "quantization": configuration?["quantization"] ?? NSNull(), "files": ProductCore.object(files),
      "conversionProvenance": admission.kind == .publishedCheckpoint
        ? "Published artifact; exact upstream conversion lineage is not independently established." : "Official checkpoint; no application conversion."],
      options: [.prettyPrinted, .sortedKeys])
  }
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
  struct ImportedModel: Sendable { let purpose: ModelPurpose; let directory: URL }
  static func importPack(_ source: URL, flag: CancellationFlag) throws -> ImportedModel {
    if !FileManager.default.fileExists(atPath: source.appendingPathComponent(manifestName).path) {
      let admission = try admission(source)
      guard admission.kind == .publishedCheckpoint,
        let checkpoint = try catalog().publishedCheckpoints.first(where: {
          $0.repository + "@" + $0.revision == admission.identity
        }) else { throw BoomError.invalid("Choose a pinned public model snapshot or a Bloom model pack.") }
      let purpose = checkpoint.purpose
      let target = snapshot(repository: checkpoint.repository, revision: checkpoint.revision, hub: HuggingFaceCache.hub)
      let root = target.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let lease = try ModelInstallLease(root: root, identity: checkpoint.revision)
      defer { lease.release() }
      guard !FileManager.default.fileExists(atPath: target.path) else {
        throw BoomError.stale("That model snapshot is already installed. Its files were retained.")
      }
      let stage = root.appendingPathComponent(".import-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: stage) }
      let requirements = try ProductCore.checkpointRequirements(checkpoint)
      let space = try stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
      if let space, UInt64(max(0, space)) < requirements.diskBytes {
        throw BoomError.budget("There is not enough free space to import this model.")
      }
      for file in checkpoint.files {
        try flag.check()
        let input = try FileHandle(forReadingFrom: source.appendingPathComponent(file.path).resolvingSymlinksInPath())
        let destination = stage.appendingPathComponent(file.path)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
          var copied: Int64 = 0
          while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try input.read(upToCount: 4_194_304), !data.isEmpty else { return false }
            try flag.check(); copied += Int64(data.count)
            guard copied <= file.bytes else { throw BoomError.stale("The model file grew during import.") }
            try output.write(contentsOf: data)
            return true
          }) {}
          try input.close(); try output.synchronize(); try output.close()
        } catch { try? input.close(); try? output.close(); throw error }
      }
      _ = try verifyPublished(stage, checkpoint: checkpoint)
      try flag.check(); try FileManager.default.moveItem(at: stage, to: target)
      return ImportedModel(purpose: purpose, directory: target)
    }
    _ = try ModelInstaller.hashFile(source.appendingPathComponent(manifestName), maxBytes: 4_194_304)
    let data = try Data(contentsOf: source.appendingPathComponent(manifestName))
    let manifest = try JSONDecoder().decode(ModelPackManifest.self, from: data)
    _ = try verify(source, purpose: manifest.purpose)
    try flag.check()
    let root = HuggingFaceCache.bloomModels
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent(manifest.purpose.rawValue)
    let lease = try ModelInstallLease(root: root, identity: manifest.purpose.rawValue)
    defer { lease.release() }
    guard !FileManager.default.fileExists(atPath: target.path) else { throw BoomError.stale("That model is already installed. Its files were retained.") }
    let stage = root.appendingPathComponent(".import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stage) }
    try FileManager.default.copyItem(at: source, to: stage)
    try flag.check(); _ = try verify(stage, purpose: manifest.purpose)
    try FileManager.default.moveItem(at: stage, to: target)
    return ImportedModel(purpose: manifest.purpose, directory: target)
  }
  static func install(_ purpose: ModelPurpose, flag: CancellationFlag,
    progress: @escaping @Sendable (String) -> Void) async throws -> URL {
    if let cached = cached(purpose) {
      _ = try await detachedWork { try admission(cached, purpose: purpose) }
      return cached
    }
    return try await installPublished(purpose, flag: flag, progress: progress)
  }
  static func installPublished(_ purpose: ModelPurpose, flag: CancellationFlag,
    progress: @escaping @Sendable (String) -> Void,
    onStoredRange: @escaping @Sendable (String, UInt64) throws -> Void = { _, _ in }) async throws -> URL {
    try await installPublished(published(purpose), flag: flag, progress: progress, onStoredRange: onStoredRange)
  }
  static func installPublished(_ specification: PublishedCheckpoint, flag: CancellationFlag,
    progress: @escaping @Sendable (String) -> Void,
    onStoredRange: @escaping @Sendable (String, UInt64) throws -> Void = { _, _ in }) async throws -> URL {
    let purpose = specification.purpose
    if let cached = cachedSnapshot(specification, hubs: HuggingFaceCache.hubs) {
      _ = try await detachedWork { try verifyPublished(cached, checkpoint: specification) }
      return cached
    }
    let requirements = try ProductCore.checkpointRequirements(specification)
    let target = snapshot(repository: specification.repository, revision: specification.revision, hub: HuggingFaceCache.hub)
    let root = target.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lease = try ModelInstallLease(root: root, identity: specification.revision)
    defer { lease.release() }
    if FileManager.default.fileExists(atPath: target.path) {
      _ = try await detachedWork { try verifyPublished(target, checkpoint: specification) }
      return target
    }
    let stage = root.appendingPathComponent(".bloom-download-" + specification.revision)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    let resources = try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeAvailableCapacityForImportantUsageKey])
    guard resources.isDirectory == true, resources.isSymbolicLink != true else { throw BoomError.invalid("Unsafe model download directory.") }
    var stagedBytes: UInt64 = 0
    for file in specification.files {
      guard !(FileManager.default.fileExists(atPath: stage.appendingPathComponent(file.path).path)
        && FileManager.default.fileExists(atPath: stage.appendingPathComponent(file.path + ".partial").path)) else {
        throw BoomError.invalid("The model has conflicting staged files. They were retained.")
      }
      for name in [file.path, file.path + ".partial"] where FileManager.default.fileExists(atPath: stage.appendingPathComponent(name).path) {
        let info = try stage.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
          Int64(size) <= file.bytes else { throw BoomError.invalid("Unsafe staged model file.") }
        stagedBytes += UInt64(size)
      }
    }
    let needed = requirements.diskBytes - min(stagedBytes, requirements.downloadBytes)
    var downloadedBytes = stagedBytes
    if let available = resources.volumeAvailableCapacityForImportantUsage, UInt64(max(0, available)) < needed {
      throw BoomError.budget("The model needs " + ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file) + " of free disk space.")
    }
    for file in specification.files {
      try flag.check()
      let destination = stage.appendingPathComponent(file.path)
      if FileManager.default.fileExists(atPath: destination.path) {
        let hash = try ModelInstaller.hashFile(destination, maxBytes: file.bytes)
        guard hash.bytes == file.bytes, hash.sha256 == file.sha256 else {
          throw BoomError.invalid("A staged model file changed. Its bytes were retained.")
        }
        continue
      }
      guard let url = URL(string: "https://huggingface.co/\(specification.repository)/resolve/\(specification.revision)/\(file.path)") else { throw BoomError.invalid("Invalid catalog URL.") }
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
          progress("\(purpose.title) · \(ByteCountFormatter.string(fromByteCount: Int64(downloadedBytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(requirements.downloadBytes), countStyle: .file))")
          try flag.check()
          let bytes = try await ModelTransfer.fetch(url, fileBytes: UInt64(file.bytes), offset: UInt64(offset))
          try flag.check()
          try handle.write(contentsOf: bytes); try handle.synchronize()
          offset += Int64(bytes.count)
          downloadedBytes += UInt64(bytes.count)
          try onStoredRange(file.path, UInt64(offset))
        }
        try handle.close()
      } catch { try? handle.close(); throw error }
      let result = try ModelInstaller.hashFile(partial, maxBytes: file.bytes)
      guard result.sha256 == file.sha256, result.bytes == file.bytes else { throw BoomError.invalid("Downloaded file failed verification; partial retained.") }
      try FileManager.default.moveItem(at: partial, to: destination)
    }
    _ = try await detachedWork { try verifyPublished(stage, checkpoint: specification) }
    try flag.check(); try FileManager.default.moveItem(at: stage, to: target)
    return target
  }
}
