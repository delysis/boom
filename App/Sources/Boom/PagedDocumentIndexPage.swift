import BoomCore
import Foundation

/// Bounded authenticated library metadata. It deliberately has no manuscript
/// text, WorkspaceState, placeholder payload or native-installation authority.
struct PagedDocumentIndexPage: Sendable {
  static let maximumRecords = 7
  static let maximumPayloadBytes = 4_096 + maximumRecords * 16_384
  let head: PagedWorkspaceHead
  let records: [PagedDocumentRootRecord]
  let nextOrdinal: Int?
  let chargedBytes: Int
  var documents: [WorkspaceDocumentDescriptor] { records.map(WorkspaceDocumentDescriptor.paged) }
}

extension WorkspaceStore {
  func loadPagedDocumentIndexPage(engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher, afterOrdinal: Int = -1,
    expectedHead: PagedWorkspaceHead? = nil)
    async throws -> PagedTextCustodiedValue<PagedDocumentIndexPage> {
    guard engine.belongs(to: vault), publisher.belongs(to: vault) else {
      throw BoomError.denied("The document-index page belongs to another Vault owner.")
    }
    return try await engine.loadDocumentIndexPageRetaining(publisher,
      afterOrdinal: afterOrdinal, expectedHead: expectedHead)
  }
}
