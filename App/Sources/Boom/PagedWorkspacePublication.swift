import BoomCore
import CryptoKit
import Foundation

struct PagedWorkspaceObjectReference: Codable, Equatable, Sendable {
  enum Layout: String, Codable, Sendable { case workspaceState, settings }
  var layout: Layout = .workspaceState
  let objectID: UUID
  let plaintextBytes: Int
  let digest: String
  let documentProjectionDigest: String
  var partCount: Int { plaintextBytes / 65_536 + (plaintextBytes % 65_536 == 0 ? 0 : 1) }
  func validate(ownerID: UUID) throws {
    let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard ownerID != empty, objectID != empty, plaintextBytes > 0, plaintextBytes <= Vault.workspaceLimit,
      Self.isDigest(digest), Self.isDigest(documentProjectionDigest), partCount > 0, partCount <= 2_048 else {
      throw BoomError.invalid("Invalid bounded SQLite workspace reference.")
    }
    if layout == .settings, plaintextBytes > WorkspaceSettings.maximumEncodedBytes || partCount != 1 {
      throw BoomError.budget("Fresh ordinary settings must be one bounded16 KiB record.")
    }
  }
  func hasSameSettingsPayload(as other: Self) -> Bool {
    layout == .settings && other.layout == .settings && objectID == other.objectID
      && plaintextBytes == other.plaintextBytes && digest == other.digest
  }
  static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
struct PagedWorkspaceSettingsObject: Codable, Sendable {
  let schema: UInt8
  let purpose: String
  let ownerID: UUID
  let objectID: UUID
  let settings: WorkspaceSettings
  init(ownerID: UUID, objectID: UUID, settings: WorkspaceSettings) {
    schema = 1; purpose = "bloom/paged-workspace/settings/v1"
    self.ownerID = ownerID; self.objectID = objectID; self.settings = settings
  }
}
/// Explicit SQL format; it never decodes the old append-file v2 head as SQL.
/// Document records are independently scoped immutable encrypted objects.
/// The cold loader verifies their exact id/title projection against workspace.
struct PagedWorkspaceHead: Codable, Equatable, Sendable {
  let schema: UInt8
  let purpose: String
  let ownerID: UUID
  let storeID: UUID
  let headID: UUID
  let generation: UInt64
  let workspace: PagedWorkspaceObjectReference
  init(ownerID: UUID, storeID: UUID, generation: UInt64, workspace: PagedWorkspaceObjectReference) {
    schema = 3; purpose = "bloom/paged-workspace/sqlite-head/v1"
    self.ownerID = ownerID; self.storeID = storeID; headID = UUID(); self.generation = generation; self.workspace = workspace
  }
  func validate(ownerID: UUID) throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard schema == 3, purpose == "bloom/paged-workspace/sqlite-head/v1", self.ownerID == ownerID,
      storeID != zero, headID != zero else { throw BoomError.invalid("Invalid SQLite workspace head identity.") }
    try workspace.validate(ownerID: ownerID)
  }
}
struct PagedWorkspaceSnapshot: Equatable, Sendable {
  let head: PagedWorkspaceHead
  let documents: [PagedDocumentRootRecord]
}
/// A target-only publication is not a complete workspace snapshot.
struct PagedWorkspaceDocumentPublication: Equatable, Sendable {
  let head: PagedWorkspaceHead
  let record: PagedDocumentRootRecord
  let operationID: UUID
  let publication: PagedSQLitePublication
}
struct PagedWorkspacePayloadObject: Codable, Sendable {
  let schema: UInt8
  let purpose: String
  let ownerID: UUID
  let objectID: UUID
  let state: WorkspaceState
  init(ownerID: UUID, objectID: UUID, state: WorkspaceState) {
    schema = 3; purpose = "bloom/paged-workspace/sqlite-payload/v1"
    self.ownerID = ownerID; self.objectID = objectID; self.state = state
  }
  func validate(ownerID: UUID, reference: PagedWorkspaceObjectReference) throws {
    guard schema == 3, purpose == "bloom/paged-workspace/sqlite-payload/v1", self.ownerID == ownerID,
      objectID == reference.objectID else { throw BoomError.invalid("SQLite workspace payload identity changed.") }
    try PagedWorkspaceProjection.validate(state)
    guard try PagedWorkspaceProjection.digest(state.documents) == reference.documentProjectionDigest else {
      throw BoomError.invalid("SQLite workspace payload document projection changed.")
    }
  }
}
enum PagedWorkspaceProjection {
  static let maximumDocuments = 1_024
  static func digest(_ documents: [DocumentIndex]) throws -> String {
    try digest(count: documents.count) { documents[$0] }
  }
  /// The same canonical sorted-key JSON array, hashed one bounded index at a
  /// time. Library mutations never assemble a whole workspace/catalog payload.
  static func digest(count: Int, documentAt: (Int) throws -> DocumentIndex) throws -> String {
    guard count >= 0, count <= maximumDocuments else { throw BoomError.budget("Document projection exceeds its existing catalog bound.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var seen = Set<UUID>(), hash = SHA256(); hash.update(data: Data([0x5b]))
    for index in 0..<count {
      let document = try documentAt(index)
      guard document.id != WorkspaceEntityHeader.zero, document.title.utf8.count <= 1_024,
        seen.insert(document.id).inserted else { throw BoomError.invalid("Duplicate or oversized document projection.") }
      if index != 0 { hash.update(data: Data([0x2c])) }
      let encoded = try encoder.encode(document)
      guard encoded.count <= 8_192 else { throw BoomError.budget("One canonical document index exceeds its bounded encoding.") }
      hash.update(data: encoded)
    }
    hash.update(data: Data([0x5d])); return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func validate(_ state: WorkspaceState) throws {
    // StoredProposal's legacy DocumentSnapshot embeds whole source. Preserve
    // that production format, but never smuggle it into paged metadata or drop
    // its evidence. The host must migrate proposals to typed paged captures
    // before this new workspace format can activate for such a workspace.
    guard state.proposals.isEmpty else {
      throw BoomError.unavailable("Legacy source proposals require paged capture migration; existing records retained.")
    }
    guard state.schema == 1, Set(state.chats.map(\.id)).count == state.chats.count,
      Set(state.voices.map(\.id)).count == state.voices.count,
      Set(state.voices.map(\.slug)).count == state.voices.count else {
      throw BoomError.invalid("Invalid retained workspace metadata; records retained.")
    }
    _ = try digest(state.documents)
    try state.validateRetainedInput()
  }
}

