import BoomCore
import Foundation

/// The metadata revision is distinct from a document's immutable source revision.
struct PagedWorkspaceHead: Equatable, Sendable {
  let ownerID: UUID
  let storeID: UUID
  let metadataDigest: String
}

struct PagedWorkspaceSnapshot: Sendable {
  let head: PagedWorkspaceHead
  let documents: [PagedDocumentRootRecord]
}

struct PagedWorkspaceDocumentCatalog: Sendable {
  let snapshot: PagedWorkspaceSnapshot
  let state: WorkspaceState
}

struct PagedWorkspaceDocumentPublication: Sendable {
  let record: PagedDocumentRootRecord
}
