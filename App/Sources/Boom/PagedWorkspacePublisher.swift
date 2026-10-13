import BoomCore
import Foundation

/// Metadata uses the same ordinary workspace file as WorkspaceStore. Text and
/// history roots are published separately, so a keystroke never saves the catalog.
final class PagedWorkspacePublisher: @unchecked Sendable {
  let store: PagedTextFileStore
  var ownerID: UUID { store.ownerID }
  var storeID: UUID { store.storeID }
  var root: URL { store.root }
  private static let metadataLimit = 64 * 1_024 * 1_024

  init(store: PagedTextFileStore) { self.store = store }

  func currentRecord(id: UUID) throws -> PagedDocumentRootRecord? {
    try store.readDocument(id)
  }

  func admitCurrentRecord(_ expected: PagedDocumentRootRecord,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws {
    try expected.validate()
    guard try currentRecord(id: expected.document.id) == expected else {
      throw BoomError.stale("The document changed before this operation.")
    }
    try validateRecord(expected)
  }

  func publishInitialDocument(_ record: PagedDocumentRootRecord,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedDocumentRootRecord {
    try record.validate(); try validateRecord(record)
    return try store.publishDocument(record, expected: nil)
  }

  func publishDocument(_ after: PagedDocumentRootRecord, expected: PagedDocumentRootRecord,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceDocumentPublication {
    try expected.validate(); try after.validate()
    guard after.document.id == expected.document.id,
      after.historyGeneration > expected.historyGeneration else {
      throw BoomError.stale("The edit has another document or history revision.")
    }
    try validateRecord(after)
    return PagedWorkspaceDocumentPublication(record: try store.publishDocument(after, expected: expected))
  }

  func readHead() throws -> PagedWorkspaceHead { try readState().head }

  func documentIndexPage(afterOrdinal: Int, expectedHead: PagedWorkspaceHead?,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedDocumentIndexPage {
    guard afterOrdinal >= -1, afterOrdinal == -1 || expectedHead != nil else {
      throw BoomError.invalid("A continued library page requires its metadata revision.")
    }
    let capture = try readState()
    if let expectedHead, capture.head != expectedHead {
      throw BoomError.stale("The library changed while loading this page.")
    }
    let documents = capture.state.documents
    let start = afterOrdinal + 1
    guard start <= documents.count else { throw BoomError.invalid("Library page is outside the catalog.") }
    let end = min(documents.count, start + PagedDocumentIndexPage.maximumRecords)
    var records: [PagedDocumentRootRecord] = [], charged = 0
    for entry in documents[start..<end] {
      guard let record = try currentRecord(id: entry.id) else {
        throw BoomError.invalid("A library document has no saved root.")
      }
      try validateRecord(record)
      let size = try JSONEncoder().encode(record).count
      guard size <= PagedDocumentIndexPage.maximumPayloadBytes - charged else {
        throw BoomError.budget("Library root page exceeds its bound.")
      }
      records.append(record); charged += size
    }
    return PagedDocumentIndexPage(head: capture.head, records: records,
      nextOrdinal: end < documents.count ? end - 1 : nil, chargedBytes: charged)
  }

  func loadCatalogAndWorkspace(validateRecord: (PagedDocumentRootRecord) throws -> Void)
    throws -> PagedWorkspaceDocumentCatalog {
    let capture = try readState()
    var records: [PagedDocumentRootRecord] = []
    for index in capture.state.documents {
      guard let record = try currentRecord(id: index.id) else {
        throw BoomError.invalid("A library document has no saved root.")
      }
      try validateRecord(record); records.append(record)
    }
    return PagedWorkspaceDocumentCatalog(snapshot: PagedWorkspaceSnapshot(head: capture.head,
      documents: records), state: capture.state)
  }

  private func readState() throws -> (state: WorkspaceState, head: PagedWorkspaceHead) {
    let bytes: Data
    let state: WorkspaceState
    if let stored = try store.readMetadata(relativePath: "workspace.json", maximumBytes: Self.metadataLimit) {
      bytes = stored; state = try JSONDecoder().decode(WorkspaceState.self, from: stored)
    } else {
      state = WorkspaceState()
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      bytes = try encoder.encode(state)
    }
    guard state.schema == 1, Set(state.documents.map(\.id)).count == state.documents.count else {
      throw BoomError.invalid("Invalid document catalog.")
    }
    return (state, PagedWorkspaceHead(ownerID: ownerID, storeID: storeID,
      metadataDigest: Digest.sha256(bytes)))
  }
}
