import BoomCore
import Foundation

/// Stable identifiers for file locations and revision ownership, not encryption keys.
struct WorkspaceStorageIdentity: Codable, Equatable, Sendable {
  let schema: UInt8
  let ownerID: UUID
  let storeID: UUID

  func admit() throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard schema == 1, ownerID != zero, storeID != zero else {
      throw BoomError.invalid("Invalid workspace identity.")
    }
  }
}
