import BoomCore
import Foundation

/// Explicit public-weight installation qualification. No workspace or Keychain.
enum ModelInstallSmoke {
  private final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    private let target: URL
    init(_ target: URL) { self.target = target }
    func stored(_ path: String, offset: UInt64) throws {
      lock.lock(); defer { lock.unlock() }
      rows.append(["path": path, "storedBytes": offset, "uptime": ProcessInfo.processInfo.systemUptime])
      try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: target, options: .atomic)
    }
  }
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --model-install-smoke --purpose consultation|writing --evidence NEW_ABSOLUTE_DIRECTORY [--interrupt-download].")
      }
      return arguments[index + 1]
    }
    guard let purpose = ModelPurpose(rawValue: try argument("--purpose")) else { throw BoomError.invalid("Unknown model purpose.") }
    let path = try argument("--evidence")
    guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { throw BoomError.invalid("Use a fresh absolute evidence directory.") }
    let evidence = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let checkpoint: PublishedCheckpoint
    if arguments.contains("--repository") {
      let repository = try argument("--repository")
      guard let selected = try ModelPacks.publishedCheckpoints(purpose).first(where: { $0.repository == repository }) else {
        throw BoomError.invalid("The requested public repository is not pinned in this bundle.")
      }
      checkpoint = selected
    } else { checkpoint = try ModelPacks.published(purpose) }
    let requirements = try ProductCore.checkpointRequirements(checkpoint)
    let cachedBefore = ModelPacks.cachedSnapshot(checkpoint, hubs: HuggingFaceCache.hubs)
    let interrupt = arguments.contains("--interrupt-download")
    let importSource: URL?
    if arguments.contains("--import-snapshot") {
      let path = try argument("--import-snapshot")
      guard path.hasPrefix("/"), !interrupt else { throw BoomError.invalid("Offline import needs an absolute model path and cannot be an interrupted download.") }
      importSource = URL(fileURLWithPath: path)
    } else { importSource = nil }
    let stage = ModelPacks.snapshot(repository: checkpoint.repository, revision: checkpoint.revision, hub: HuggingFaceCache.hub)
      .deletingLastPathComponent().appendingPathComponent(".bloom-download-" + checkpoint.revision)
    func observations() throws -> [[String: Any]] {
      try checkpoint.files.flatMap { file in
        try [file.path, file.path + ".partial"].compactMap { name -> [String: Any]? in
          let target = stage.appendingPathComponent(name)
          guard FileManager.default.fileExists(atPath: target.path) else { return nil }
          let value = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
          var row: [String: Any] = ["path": name, "bytes": value.fileSize ?? -1,
            "regular": value.isRegularFile == true, "symlink": value.isSymbolicLink == true]
          if name.hasSuffix(".partial"), (value.fileSize ?? Int.max) <= 134_217_728 {
            row["sha256"] = try ModelInstaller.hashFile(target, maxBytes: 134_217_728).sha256
          }
          return row
        }
      }
    }
    var receipt: [String: Any] = ["schema": 1, "status": "running", "checkpoint": try ProductCore.object(checkpoint),
      "identity": requirements.identity, "runtimeRevision": ModelPacks.runtimeRevision,
      "sourceInventorySHA256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "cacheRoots": HuggingFaceCache.hubs.map(\.path), "cachedBefore": cachedBefore?.path as Any? ?? NSNull(),
      "stagedBefore": try observations(), "interruptRequested": interrupt,
      "importSource": importSource?.path as Any? ?? NSNull(),
      "noWorkspaceOrKeychain": true]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    try persist()
    let flag = CancellationFlag(), ledger = Ledger(evidence.appendingPathComponent("ranges.json"))
    let started = ContinuousClock.now
    do {
      let directory: URL
      if let importSource {
        let result = try await detachedWork { try ModelPacks.importPack(importSource, flag: flag) }
        guard result.purpose == purpose else { throw BoomError.invalid("The imported model has the wrong purpose.") }
        directory = result.directory
      } else {
        directory = try await ModelPacks.installPublished(checkpoint, flag: flag, progress: { _ in }, onStoredRange: { file, offset in
          try ledger.stored(file, offset: offset)
          if interrupt, file.hasSuffix(".safetensors"), offset >= 67_108_864 { flag.cancel() }
        })
      }
      let admission = try await detachedWork { try ModelPacks.admission(directory, purpose: purpose) }
      receipt["status"] = "verified"; receipt["directory"] = directory.path
      receipt["admittedIdentity"] = admission.identity; receipt["weightBytes"] = admission.weightBytes
      receipt["weightKind"] = admission.kind.rawValue
      if interrupt, cachedBefore == nil { throw BoomError.invalid("The registered interruption did not occur.") }
    } catch is CancellationError where interrupt && flag.isCancelled {
      receipt["status"] = "interrupted"
    } catch {
      receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
      receipt["stagedAfter"] = try observations(); try persist(); throw error
    }
    receipt["stagedAfter"] = try observations()
    let duration = started.duration(to: .now).components
    receipt["elapsedSeconds"] = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let memory = ModelResidency.memoryAccounting()
    receipt["processCurrentBytes"] = memory.current; receipt["processPeakBytes"] = memory.peak
    try persist()
    print("Public model installation retained: \(receipt["status"] ?? "unknown")")
  }
}
