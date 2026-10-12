import BoomCore
import Foundation

enum PagedSQLiteRole: Int32, Sendable {
  case text = 1, index = 2, workspace = 3, documentRecord = 4, head = 5, format = 7
  case entity = 8, entityBody = 9
  var maximumBytes: Int { self == .index || self == .entity ? 16_384 : 65_536 }
}

/// Uses the existing Vault key. Database object UUIDs are immutable keys;
/// neither a SQL rowid nor a physical file offset enters this binding.
struct PagedSQLiteBinding: Sendable {
  let ownerID: UUID
  let storeID: UUID
  let documentID: UUID
  let objectID: UUID
  let role: PagedSQLiteRole
  let part: Int
  let plaintextBytes: Int
  init(ownerID: UUID, storeID: UUID, documentID: UUID, objectID: UUID,
    role: PagedSQLiteRole, part: Int, plaintextBytes: Int) throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard [ownerID, storeID, documentID, objectID].allSatisfy({ $0 != zero }),
      part >= 0, part < 2_048, (role != .entityBody || part < 64),
      (role == .workspace || role == .entityBody || part == 0),
      plaintextBytes >= 0, plaintextBytes <= role.maximumBytes else {
      throw BoomError.invalid("Invalid bounded SQLite object identity.")
    }
    self.ownerID = ownerID; self.storeID = storeID; self.documentID = documentID
    self.objectID = objectID; self.role = role; self.part = part; self.plaintextBytes = plaintextBytes
  }
  var authenticatedData: Data {
    var bytes = Data("bloom/paged-sqlite/object/v1\0".utf8)
    for id in [ownerID, storeID, documentID, objectID] {
      var value = id.uuid
      withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    }
    bytes.append(UInt8(role.rawValue))
    for value in [UInt64(part), UInt64(plaintextBytes)] {
      for shift in stride(from: 0, through: 56, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    return bytes
  }
}
