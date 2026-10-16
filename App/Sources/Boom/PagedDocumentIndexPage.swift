import BoomCore
import Foundation

/// Bounded library metadata. It deliberately has no manuscript
/// text, WorkspaceState, placeholder payload or native-installation authority.
struct PagedDocumentIndexPage: Sendable {
  static let maximumRecords = 7
  static let maximumPayloadBytes = 4_096 + maximumRecords * 16_384
  let head: PagedWorkspaceHead
  let records: [PagedDocumentRootRecord]
  let nextOrdinal: Int?
  let chargedBytes: Int
}
