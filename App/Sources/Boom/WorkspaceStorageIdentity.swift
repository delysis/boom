import BoomCore
import Foundation

/// Persisted identities are authenticated by the existing Vault record. They
/// select the SQL opening; the actual format row still authenticates admission.
struct WorkspaceStorageIdentity: Codable, Equatable, Sendable {
  let schema: UInt8
  let ownerID: UUID
  let storeID: UUID

  fileprivate static func fresh() -> Self { Self(schema: 1, ownerID: UUID(), storeID: UUID()) }
  func admit() throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard schema == 1, ownerID != zero, storeID != zero else {
      throw BoomError.denied("Workspace storage identity is invalid; records retained.")
    }
  }
}

struct WorkspaceStorageOpening: Sendable {
  let identity: WorkspaceStorageIdentity
  let sql: PagedSQLiteStore.Opening
}

extension WorkspaceStore {
  /// Only an empty new workspace or an authenticated SQL identity. Selected
  /// original attachments remain separate Vault records; opening does not scan
  /// that potentially large inventory. Legacy workspace authority cannot mix.
  func preparePagedStorageOpening() throws -> WorkspaceStorageOpening {
    let identityName = vault.recordURL(.workspaceIdentity, Vault.workspaceID).lastPathComponent
    let identity: WorkspaceStorageIdentity
    if vault.exists(.workspaceIdentity, Vault.workspaceID) {
      identity = try vault.decode(WorkspaceStorageIdentity.self, kind: .workspaceIdentity,
        id: Vault.workspaceID, limit: 512)
      try identity.admit()
      guard !vault.exists(.workspace, Vault.workspaceID), !vault.exists(.saveJournal, Vault.workspaceID) else {
        throw BoomError.denied("Workspace storage has another active authority; records retained.")
      }
    } else {
      _ = try Self.boundedStorageNames(vault.root, maximum: 0)
      identity = .fresh()
      let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
      try vault.createWorkspaceIdentity(encoder.encode(identity))
    }
    let directory = vault.root.appendingPathComponent("paged-sqlite-v3", isDirectory: true)
    if !FileManager.default.fileExists(atPath: directory.path) {
      guard try Self.boundedStorageNames(vault.root, maximum: 1) == [identityName] else {
        throw BoomError.denied("Prepared workspace contains data without a SQL store; records retained.")
      }
      try vault.synchronizeWorkspaceIdentity()
      return WorkspaceStorageOpening(identity: identity, sql: .fresh(storeID: identity.storeID))
    }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw BoomError.denied("Workspace SQL namespace is not a real directory; records retained.")
    }
    let sqlNames = try Self.boundedStorageNames(directory, maximum: 3)
    if sqlNames.isEmpty {
      guard try Self.boundedStorageNames(vault.root, maximum: 2) == [identityName, "paged-sqlite-v3"] else {
        throw BoomError.denied("Prepared workspace contains data without a SQL store; records retained.")
      }
      try vault.synchronizeWorkspaceIdentity()
      return WorkspaceStorageOpening(identity: identity, sql: .fresh(storeID: identity.storeID))
    }
    guard sqlNames.contains("store.sqlite"), sqlNames.isSubset(of: ["store.sqlite", "store.sqlite-wal", "store.sqlite-shm"]) else {
      throw BoomError.denied("Workspace SQL namespace is partial or unknown; records retained.")
    }
    return WorkspaceStorageOpening(identity: identity, sql: .existing(storeID: identity.storeID))
  }

  /// Stop after the fixed namespace bound; do not allocate a legacy inventory.
  private static func boundedStorageNames(_ root: URL, maximum: Int) throws -> Set<String> {
    var failure: Error?
    guard let enumerator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],
      errorHandler: { _, error in failure = error; return false }) else {
      throw BoomError.unavailable("Workspace storage namespace could not be read.")
    }
    var names: Set<String> = []
    while let file = enumerator.nextObject() as? URL {
      guard names.count < maximum else { throw BoomError.denied("Workspace storage has another format; records retained.") }
      names.insert(file.lastPathComponent)
    }
    if let failure { throw failure }
    return names
  }
}
