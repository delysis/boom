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

  static func loadOrCreate(at url: URL) throws -> Self {
    if FileManager.default.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size > 0, size <= 512 else {
        throw BoomError.invalid("Invalid workspace identity file.")
      }
      let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
      try value.admit(); return value
    }
    let value = Self(schema: 1, ownerID: UUID(), storeID: UUID())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return value
  }
}
