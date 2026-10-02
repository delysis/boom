import CryptoKit
import Foundation
import BoomCore

struct ModelFile: Codable, Equatable {
  let path: String
  let bytes: Int64
  let sha256: String
}
struct ModelManifest: Codable {
  let schema: Int
  let repository: String
  let revision: String
  let files: [ModelFile]
  var identity: String { (try? Digest.identity(files.sorted { $0.path < $1.path })) ?? "invalid" }
  static let filename = "boom-model.json"
  static func loadAndVerify(_ root: URL) throws -> ModelManifest {
    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw BoomError.invalid("The model root is not a real directory.")
    }
    let manifestURL = root.appendingPathComponent(filename)
    let manifestValues = try manifestURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
      (manifestValues.fileSize ?? Int.max) <= 8_388_608
    else { throw BoomError.invalid("Unsafe model manifest file.") }
    let data = try Data(contentsOf: manifestURL)
    guard data.count <= 8_388_608 else { throw BoomError.budget("Model manifest too large.") }
    let manifest = try JSONDecoder().decode(Self.self, from: data)
    guard manifest.schema == 1, !manifest.files.isEmpty, manifest.files.count <= 10_000,
      Set(manifest.files.map(\.path)).count == manifest.files.count
    else { throw BoomError.invalid("Unsupported or duplicate model manifest entries.") }
    let fm = FileManager.default
    var total: Int64 = 0
    for file in manifest.files {
      try Task.checkCancellation()
      try DownloadPolicy.validateRelativePath(file.path)
      guard file.bytes > 0, file.bytes <= 4_294_967_296 else {
        throw BoomError.budget("Model object size is invalid.")
      }
      total += file.bytes
      guard total <= 17_179_869_184 else { throw BoomError.budget("Model exceeds 16 GiB.") }
      let url = root.appendingPathComponent(file.path)
      var cursor = root
      for part in file.path.split(separator: "/") {
        cursor.appendPathComponent(String(part))
        guard try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
          throw BoomError.invalid("Symlink in model bundle.")
        }
      }
      let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard v.isRegularFile == true, Int64(v.fileSize ?? -1) == file.bytes else {
        throw BoomError.invalid("Model object size changed: \(file.path)")
      }
      guard try ModelInstaller.hashFile(url, maxBytes: file.bytes).sha256 == file.sha256 else {
        throw BoomError.invalid("Model object hash changed: \(file.path)")
      }
    }
    // No unmanifested model data can influence automatic runtime asset discovery.
    guard
      let enumerator = fm.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
    else { throw BoomError.invalid("Cannot enumerate the installed model.") }
    let allowed = Set(manifest.files.map(\.path)).union([filename])
    while let url = enumerator.nextObject() as? URL {
      let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard v.isSymbolicLink != true else {
        throw BoomError.invalid("Unmanifested symlink in model bundle.")
      }
      if v.isRegularFile == true {
        let path = String(url.path.dropFirst(root.path.count + 1))
        guard allowed.contains(path) else {
          throw BoomError.invalid("Unmanifested model file: \(path)")
        }
      }
    }
    guard manifest.files.allSatisfy({ ModelInstaller.selected($0.path) }),
      manifest.files.contains(where: { $0.path == "model_config.json" }),
      manifest.files.contains(where: { $0.path == "hf_model/tokenizer.json" }),
      manifest.files.contains(where: { $0.path == "hf_model/tokenizer_config.json" }),
      (1...4).allSatisfy({ index in
        manifest.files.contains(where: {
          $0.path.hasPrefix("chunk\(index).mlmodelc/")
            || $0.path.hasPrefix("chunk\(index).mlpackage/")
        })
      })
    else {
      throw BoomError.invalid(
        "Choose the Gemma E2B chunk bundle, not an archive or a stateful experimental model.")
    }
    // A pinned publisher revision can contain several model experiments under
    // one commit. Content hashes alone do not prove the chosen compiled graphs
    // agree with the configuration. Check the decoder's actual MIL input shape
    // before admitting a downloaded bundle; the native loader checks again.
    if manifest.repository == DownloadPolicy.repositories[0] {
      let configData = try Data(contentsOf: root.appendingPathComponent("model_config.json"))
      guard configData.count <= 8192,
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
        let context = config["context_length"] as? Int, context > 0, context <= 32768
      else { throw BoomError.invalid("Pinned model context configuration is invalid.") }
      for index in 1...4 {
        let path = "chunk\(index).mlmodelc/model.mil"
        guard let file = manifest.files.first(where: { $0.path == path }), file.bytes <= 4_194_304
        else { throw BoomError.invalid("Pinned decoder graph is missing or too large: \(path)") }
        let graph = try String(
          contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        guard graph.contains("[1, 1, 1, \(context)]> causal_mask_full"),
          graph.contains("[1, 1, \(context), 1]> update_mask")
        else {
          throw BoomError.invalid(
            "Pinned decoder chunk \(index) has a different compiled context than model_config.json.")
        }
      }
    }
    return manifest
  }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var limit: Int64 = 0
  private var callback: (@Sendable (Int64) -> Void)?
  func begin(limit: Int64, callback: (@Sendable (Int64) -> Void)? = nil) {
    lock.lock()
    self.limit = limit
    self.callback = callback
    lock.unlock()
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    lock.lock()
    let bound = limit
    let cb = callback
    lock.unlock()
    if totalBytesWritten > bound || totalBytesExpectedToWrite > bound {
      downloadTask.cancel()
      return
    }
    cb?(totalBytesWritten)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, DownloadPolicy.permits(url) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

/// Match the Hugging Face Hub cache location without loading its Python client.
/// Boom keeps its flattened CoreML runtime under `hub/boom/`, and publishes
/// verified upstream objects in the normal repository `blobs/` directory.
enum HuggingFaceCache {
  static var hub: URL {
    let env = ProcessInfo.processInfo.environment
    if let path = env["HF_HUB_CACHE"], path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    if let path = env["HUGGINGFACE_HUB_CACHE"], path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    let home: URL
    if let path = env["HF_HOME"], path.hasPrefix("/") {
      home = URL(fileURLWithPath: path)
    } else if let path = env["XDG_CACHE_HOME"], path.hasPrefix("/") {
      home = URL(fileURLWithPath: path).appendingPathComponent("huggingface")
    } else {
      home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface")
    }
    return home.appendingPathComponent("hub").standardizedFileURL
  }
  static var boomModels: URL { hub.appendingPathComponent("boom", isDirectory: true) }
  static func repoBlobs(_ repository: String) -> URL {
    hub.appendingPathComponent(
      "models--" + repository.replacingOccurrences(of: "/", with: "--"), isDirectory: true
    ).appendingPathComponent("blobs", isDirectory: true)
  }
  static func candidateBlobs(for object: String, repository: String) throws -> [URL] {
    let preferred = repoBlobs(repository).appendingPathComponent(object)
    let names = (try? FileManager.default.contentsOfDirectory(
      at: hub, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
    let others = names.filter {
      $0.lastPathComponent.hasPrefix("models--") && $0 != repoBlobs(repository).deletingLastPathComponent()
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    return [preferred] + others.map {
      $0.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(object)
    }
  }
}

final class ModelInstaller: @unchecked Sendable {
  private let delegate = DownloadDelegate()
  private let session: URLSession
  init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.httpShouldSetCookies = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 90
    config.timeoutIntervalForResource = 7200
    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  private func request(_ url: URL, limit: Int64, progress: (@Sendable (Int64) -> Void)? = nil)
    async throws -> URL
  {
    guard DownloadPolicy.permits(url) else {
      throw BoomError.denied("The model downloader rejected this origin.")
    }
    try Task.checkCancellation()
    delegate.begin(limit: limit, callback: progress)
    var req = URLRequest(url: url)
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let (temporary, response) = try await session.download(for: req)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw BoomError.unavailable("Model download returned a non-success HTTP response.")
    }
    guard
      Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= limit
    else { throw BoomError.budget("Downloaded object exceeds its bound.") }
    return temporary
  }
  /// Download a bounded byte interval. A completed interval is appended to a
  /// stage file; an interrupted transfer never advances its length. This lets
  /// the next explicit attempt resume a multi-GiB object without trusting any
  /// unverified bytes as an installed model.
  private func requestRange(
    _ url: URL, start: Int64, end: Int64, total: Int64,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> URL {
    guard DownloadPolicy.permits(url), start >= 0, end >= start, end < total else {
      throw BoomError.denied("The model downloader rejected this asset range.")
    }
    try Task.checkCancellation()
    let length = end - start + 1
    delegate.begin(limit: length) { written in progress(start + written) }
    var req = URLRequest(url: url)
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    let (temporary, response) = try await session.download(for: req)
    guard let response = response as? HTTPURLResponse, response.statusCode == 206,
      response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(total)"
    else { throw BoomError.invalid("The model host did not honor the exact byte range.") }
    let received = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1)
    guard received == length else {
      throw BoomError.invalid("The model host returned an incomplete byte range.")
    }
    return temporary
  }
  struct Hashes {
    let sha256: String
    let gitSHA1: String
    let count: Int64
  }
  private static func currentFileSize(_ url: URL) throws -> Int64 {
    guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size]
      as? NSNumber
    else { throw BoomError.invalid("Cannot read model asset size.") }
    return size.int64Value
  }
  static func hashFile(_ url: URL, maxBytes: Int64) throws -> Hashes {
    let size = try currentFileSize(url)
    guard size >= 0, size <= maxBytes else { throw BoomError.budget("File exceeds declared size.") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var sha = SHA256()
    var git = Insecure.SHA1()
    var count: Int64 = 0
    git.update(data: Data("blob \(size)\0".utf8))
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      count += Int64(data.count)
      guard count <= maxBytes else { throw BoomError.budget("File grew while reading.") }
      sha.update(data: data)
      git.update(data: data)
    }
    guard count == size else { throw BoomError.stale("File changed while hashing.") }
    return Hashes(
      sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(),
      gitSHA1: git.finalize().map { String(format: "%02x", $0) }.joined(), count: count)
  }
  private static func verifiedCachedBlob(
    repository: String, size: Int64, sha256: String?, gitSHA1: String?
  ) throws -> URL? {
    guard let object = sha256 ?? gitSHA1,
      object.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil
    else { return nil }
    for url in try HuggingFaceCache.candidateBlobs(for: object, repository: repository) {
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        Int64(values.fileSize ?? -1) == size
      else { continue }
      let hash = try hashFile(url, maxBytes: size)
      if sha256.map({ $0 == hash.sha256 }) ?? (gitSHA1 == hash.gitSHA1) { return url }
    }
    return nil
  }
  private static func publishBlob(
    source: URL, repository: String, sha256: String?, gitSHA1: String?, size: Int64
  ) throws {
    guard let object = sha256 ?? gitSHA1 else { return }
    let directory = HuggingFaceCache.repoBlobs(repository)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(object)
    if FileManager.default.fileExists(atPath: destination.path) {
      let values = try destination.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      // The Hub cache is shared with other processes. Preserve an unsafe or
      // damaged entry as evidence; the verified Boom stage still stands alone.
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        Int64(values.fileSize ?? -1) == size
      else { return }
      let hash = try hashFile(destination, maxBytes: size)
      guard sha256.map({ $0 == hash.sha256 }) ?? (gitSHA1 == hash.gitSHA1) else { return }
      return
    }
    try FileManager.default.linkItem(at: source, to: destination)
  }
  private static func retainInterruptedPartial(
    _ partial: URL, root: URL, revision: String, path: String
  ) throws {
    guard FileManager.default.fileExists(atPath: partial.path) else { return }
    let values = try partial.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw BoomError.invalid("Interrupted model asset is unsafe: \(path)")
    }
    let evidence = root.appendingPathComponent(
      ".retained-partials-" + revision, isDirectory: true)
      .appendingPathComponent(path + "." + UUID().uuidString + ".partial")
    try FileManager.default.createDirectory(
      at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: partial, to: evidence)
  }
  static func selected(_ path: String) -> Bool {
    // Shipping text route + same-family media encoders; no code, archives,
    // experimental drafters, alternate model families or executable payloads.
    let first = path.split(separator: "/").first.map(String.init) ?? ""
    if ["LICENSE", "LICENSE.txt", "LICENSE.md", "NOTICE"].contains(path) { return true }
    if first == "hf_model" {
      let file = String(path.dropFirst("hf_model/".count))
      return [
        "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json",
        "config.json", "chat_template.jinja", "tokenizer.model",
      ].contains(file)
    }
    if first.range(
      of: #"^(chunk[1-4]|prefill_chunk[1-4]|vision|audio)\.(mlpackage|mlmodelc)$"#,
      options: .regularExpression) != nil
    {
      return true
    }
    return !path.contains("/")
      && ["bin", "npy", "json"].contains(URL(fileURLWithPath: path).pathExtension)
      && !first.hasPrefix("eagle") && !first.hasPrefix("mtp") && !first.hasPrefix("cross_vocab")
      && first != ModelManifest.filename
  }
  /// The pinned repository contains several incompatible research layouts.
  /// Flatten the pinned dependency's documented 2K shipping layout. The same
  /// repository revision also contains research 8K graphs that do not form a
  /// coherent bundle with its shipping positional sidecars.
  static func defaultAssetPath(_ remote: String) -> String? {
    if remote == "model_config.json" { return remote }
    if ["cos_full.npy", "sin_full.npy", "cos_sliding.npy", "sin_sliding.npy"].contains(remote) {
      return nil
    }
    if remote.hasPrefix("swa/") {
      let relative = String(remote.dropFirst("swa/".count))
      if ["cos_full.npy", "sin_full.npy", "cos_sliding.npy", "sin_sliding.npy"].contains(relative) {
        return relative
      }
      return relative.range(of: #"^chunk[1-4]\.mlmodelc/"#, options: .regularExpression) != nil
        ? relative : nil
    }
    if remote.hasPrefix("prefill/") {
      let relative = String(remote.dropFirst("prefill/".count))
      guard relative.range(of: #"^chunk[1-4]\.mlmodelc/"#, options: .regularExpression) != nil,
        !relative.hasSuffix("/weights/weight.bin")
      else { return nil }
      return "prefill_" + relative
    }
    // This revision ships both compiled and source vision models. The runtime
    // uses the compiled copy; retaining both doubles this encoder on disk.
    if remote.hasPrefix("vision.mlpackage/") { return nil }
    if remote.hasPrefix("chunk") || remote.hasPrefix("prefill") { return nil }
    return selected(remote) ? remote : nil
  }
  private static func stage(in root: URL) throws -> URL {
    let stage = root.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return stage
  }
  private static func downloadStage(in root: URL, revision: String) throws -> URL {
    // The same upstream revision includes incompatible decoder layouts. A
    // layout change gets a new stage so an older interrupted download stays
    // intact and cannot block the corrected asset selection.
    let stage = root.appendingPathComponent(
      ".install-gemma4-e2b-shipping-swa2k-" + revision, isDirectory: true)
    if FileManager.default.fileExists(atPath: stage.path) {
      let values = try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw BoomError.invalid("Existing model stage is not a real directory.")
      }
    } else {
      try FileManager.default.createDirectory(
        at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    return stage
  }
  private static func finish(
    stage: URL, root: URL, repository: String, revision: String, files: [ModelFile]
  ) throws -> URL {
    let manifest = ModelManifest(
      schema: 1, repository: repository, revision: revision,
      files: files.sorted { $0.path < $1.path })
    try Digest.canonical(manifest).write(
      to: stage.appendingPathComponent(ModelManifest.filename), options: .atomic)
    _ = try ModelManifest.loadAndVerify(stage)
    let final = root.appendingPathComponent(
      "gemma4-e2b-" + manifest.identity.prefix(20), isDirectory: true)
    if FileManager.default.fileExists(atPath: final.path) {
      _ = try ModelManifest.loadAndVerify(final)
      // The verified staging copy remains as explicit install evidence; no
      // user state or failed receipts are deleted to make an install pass.
      return final
    }
    try FileManager.default.moveItem(at: stage, to: final)
    return final
  }
  /// Called only by the explicit Download action. Resolves n1024 ONCE, then all
  /// requests use that immutable commit and validate upstream object hashes.
  func download(to root: URL, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
    let repo = DownloadPolicy.repositories[0]
    progress("Resolving the Gemma 4 E2B n1024 revision…")
    let infoURL = URL(
      string: "https://huggingface.co/api/models/\(repo)/revision/n1024?blobs=true")!
    let metadata = try await request(infoURL, limit: 8_388_608)
    let data = try Data(contentsOf: metadata)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let revision = object["sha"] as? String,
      revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
      let siblings = object["siblings"] as? [[String: Any]], siblings.count <= 20_000
    else {
      throw BoomError.invalid("Model repository did not supply a bounded immutable file inventory.")
    }
    let inventory = siblings.compactMap { sibling -> (String, String, [String: Any])? in
      guard let remote = sibling["rfilename"] as? String,
        let path = Self.defaultAssetPath(remote)
      else { return nil }
      return (remote, path, sibling)
    }
    let paths = Set(inventory.map { $0.1 })
    let required = [
      "model_config.json", "hf_model/tokenizer.json", "hf_model/tokenizer_config.json",
      "cos_full.npy", "sin_full.npy", "cos_sliding.npy", "sin_sliding.npy",
      "embed_tokens_q8.bin", "embed_tokens_per_layer_q8.bin", "per_layer_projection.bin",
    ]
      + (1...4).flatMap { index in
        ["chunk\(index).mlmodelc/coremldata.bin",
          "prefill_chunk\(index).mlmodelc/coremldata.bin"]
      }
    guard inventory.count == paths.count, required.allSatisfy(paths.contains) else {
      throw BoomError.invalid(
        "The pinned Gemma 4 E2B shipping decode/prefill inventory is incomplete or ambiguous. No model data was downloaded."
      )
    }
    // The documented shipping prefill graphs use byte-identical decode
    // weights. Check that promise against the immutable upstream inventory
    // before sharing the local objects; never infer it from matching sizes.
    var byRemote: [String: [String: Any]] = [:]
    for sibling in siblings {
      guard let name = sibling["rfilename"] as? String, byRemote[name] == nil else {
        throw BoomError.invalid("Publisher inventory contains an unnamed or duplicate asset.")
      }
      byRemote[name] = sibling
    }
    for index in 1...4 {
      let decode = byRemote["swa/chunk\(index).mlmodelc/weights/weight.bin"]?["lfs"]
        as? [String: Any]
      let prefill = byRemote["prefill/chunk\(index).mlmodelc/weights/weight.bin"]?["lfs"]
        as? [String: Any]
      guard let decode, let prefill,
        decode["sha256"] as? String == prefill["sha256"] as? String,
        decode["size"] as? NSNumber == prefill["size"] as? NSNumber
      else {
        throw BoomError.invalid("Publisher prefill weight differs from decoder chunk \(index).")
      }
    }
    let stage = try Self.downloadStage(in: root, revision: revision)
    var files: [ModelFile] = []
    var total: Int64 = 0
    for (remote, path, sibling) in inventory {
      try Task.checkCancellation()
      try DownloadPolicy.validateRelativePath(path)
      let lfs = sibling["lfs"] as? [String: Any]
      guard
        let size = (lfs?["size"] as? NSNumber)?.int64Value
          ?? (sibling["size"] as? NSNumber)?.int64Value, size > 0, size <= 4_294_967_296
      else { throw BoomError.invalid("No bounded size for model asset \(path).") }
      let expectedSHA = lfs?["sha256"] as? String
      let expectedGit = sibling["blobId"] as? String ?? sibling["blob_id"] as? String
      guard expectedSHA != nil || expectedGit != nil else {
        throw BoomError.invalid("No upstream content hash for \(path).")
      }
      total += size
      guard total <= 17_179_869_184, files.count < 10_000 else {
        throw BoomError.budget("Model install exceeds 16 GiB or 10,000 files.")
      }
      let destination = stage.appendingPathComponent(path)
      if FileManager.default.fileExists(atPath: destination.path) {
        let values = try destination.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          Int64(values.fileSize ?? -1) == size
        else { throw BoomError.invalid("Retained model asset is unsafe or changed: \(path)") }
        let hash = try Self.hashFile(destination, maxBytes: size)
        guard expectedSHA.map({ $0 == hash.sha256 }) ?? (expectedGit == hash.gitSHA1) else {
          throw BoomError.invalid("Retained model asset hash changed: \(path)")
        }
        try Self.publishBlob(
          source: destination, repository: repo, sha256: expectedSHA, gitSHA1: expectedGit,
          size: size)
        files.append(ModelFile(path: path, bytes: size, sha256: hash.sha256))
        progress("Reused verified \(path)")
        continue
      }
      if let cached = try Self.verifiedCachedBlob(
        repository: repo, size: size, sha256: expectedSHA, gitSHA1: expectedGit)
      {
        try Self.retainInterruptedPartial(
          destination.appendingPathExtension("partial"), root: root, revision: revision,
          path: path)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: cached, to: destination)
        let hash = try Self.hashFile(destination, maxBytes: size)
        try Self.publishBlob(
          source: destination, repository: repo, sha256: expectedSHA, gitSHA1: expectedGit,
          size: size)
        files.append(ModelFile(path: path, bytes: size, sha256: hash.sha256))
        progress("Reused Hugging Face cache · \(path)")
        continue
      }
      let base = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/")!
      let url = base.appendingPathComponent(remote)
      let partial = destination.appendingPathExtension("partial")
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: partial.path) {
        let values = try partial.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          Int64(values.fileSize ?? -1) >= 0, Int64(values.fileSize ?? -1) <= size
        else { throw BoomError.invalid("Retained partial asset is unsafe: \(path)") }
      } else {
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
          throw BoomError.unavailable("Cannot create the model asset stage.")
        }
      }
      let interval: Int64 = 32 * 1_048_576
      var received = try Self.currentFileSize(partial)
      // A short tail can only be the final interval. A torn file is retained
      // and refused rather than treated as a valid starting offset.
      guard received == size || received % interval == 0 else {
        throw BoomError.invalid("Retained partial range has an invalid length: \(path)")
      }
      while received < size {
        try Task.checkCancellation()
        let end = min(size - 1, received + interval - 1)
        progress("Downloading \(path) · \(received / 1_048_576) / \(size / 1_048_576) MiB")
        var segment: URL?
        for attempt in 1...3 {
          do {
            segment = try await requestRange(url, start: received, end: end, total: size) {
              written in
              progress("\(path) · \(written / 1_048_576) / \(size / 1_048_576) MiB")
            }
            break
          } catch {
            guard attempt < 3, !Task.isCancelled else {
              throw BoomError.unavailable(
                "Download failed for \(path): \(error.localizedDescription). Completed ranges retained at \(partial.path)")
            }
            progress("Network error for \(path); retry \(attempt + 1) of 3. Completed ranges retained.")
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
          }
        }
        guard let segment else { throw BoomError.unavailable("Model range did not return a file.") }
        let handle = try FileHandle(forWritingTo: partial)
        do {
          try handle.seekToEnd()
          let input = try FileHandle(forReadingFrom: segment)
          defer { try? input.close() }
          while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try handle.write(contentsOf: data)
          }
          try handle.synchronize()
          try handle.close()
        } catch {
          try? handle.close()
          throw error
        }
        received = try Self.currentFileSize(partial)
        guard received == end + 1 else {
          throw BoomError.invalid("Staged byte range changed while being written: \(path)")
        }
      }
      let hash = try Self.hashFile(partial, maxBytes: size)
      guard hash.count == size,
        expectedSHA.map({ $0 == hash.sha256 }) ?? (expectedGit == hash.gitSHA1)
      else {
        throw BoomError.invalid(
          "Upstream object verification failed: \(path). The staging directory was retained.")
      }
      try Self.publishBlob(
        source: partial, repository: repo, sha256: expectedSHA, gitSHA1: expectedGit, size: size)
      try FileManager.default.moveItem(at: partial, to: destination)
      files.append(ModelFile(path: path, bytes: size, sha256: hash.sha256))
    }
    for index in 1...4 {
      let decodePath = "chunk\(index).mlmodelc/weights/weight.bin"
      let prefillPath = "prefill_chunk\(index).mlmodelc/weights/weight.bin"
      guard let decoder = files.first(where: { $0.path == decodePath }) else {
        throw BoomError.invalid("Verified decoder weight is missing: \(decodePath)")
      }
      let destination = stage.appendingPathComponent(prefillPath)
      if FileManager.default.fileExists(atPath: destination.path) {
        let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          try Self.hashFile(destination, maxBytes: decoder.bytes).sha256 == decoder.sha256
        else { throw BoomError.invalid("Retained prefill weight changed: \(prefillPath)") }
      } else {
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(
          at: stage.appendingPathComponent(decodePath), to: destination)
      }
      files.append(ModelFile(path: prefillPath, bytes: decoder.bytes, sha256: decoder.sha256))
    }
    guard !files.isEmpty else { throw BoomError.invalid("No compatible model assets were found.") }
    progress("Verifying the complete installed bundle…")
    return try Self.finish(
      stage: stage, root: root, repository: repo, revision: revision, files: files)
  }
  static func importDirectory(
    _ source: URL, to root: URL, progress: @escaping @Sendable (String) -> Void
  ) throws -> URL {
    let stage = try stage(in: root)
    guard
      let items = FileManager.default.enumerator(
        at: source,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    else { throw BoomError.invalid("Cannot enumerate the granted model folder.") }
    var files: [ModelFile] = []
    var total: Int64 = 0
    while let url = items.nextObject() as? URL {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else {
        throw BoomError.invalid("Model imports cannot contain symlinks.")
      }
      guard values.isRegularFile == true else { continue }
      let path = String(url.path.dropFirst(source.path.count + 1))
      guard selected(path) else { continue }
      try DownloadPolicy.validateRelativePath(path)
      let size = Int64(values.fileSize ?? -1)
      guard size > 0, size <= 4_294_967_296 else {
        throw BoomError.budget("Invalid imported model object size.")
      }
      total += size
      guard total <= 17_179_869_184, files.count < 10_000 else {
        throw BoomError.budget("Imported model exceeds its bounds.")
      }
      progress("Copying and hashing \(path)…")
      let destination = stage.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: destination)
      let hash = try hashFile(destination, maxBytes: size)
      files.append(ModelFile(path: path, bytes: hash.count, sha256: hash.sha256))
    }
    return try finish(
      stage: stage, root: root, repository: "explicit-local-import", revision: "content-addressed",
      files: files)
  }
}
