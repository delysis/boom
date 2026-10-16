import BoomCore
import Foundation

/// The existing serialized engine supplies this source provider.
protocol PagedTextDocumentPages: Sendable {
  var ownerID: UUID { get }
  var documentID: UUID { get }
  func writeNew(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    bytes: Data) throws -> PagedTextPageLocator
  func read(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    page: PagedTextPageRef, maximumPlaintextBytes: Int) throws -> Data
}
struct PagedFileDocumentPages: PagedTextDocumentPages {
  let store: PagedTextFileStore
  let ownerID: UUID
  let documentID: UUID
  func writeNew(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    bytes: Data) throws -> PagedTextPageLocator {
    try admit(ownerID, documentID)
    return try store.appendPage(documentID: documentID, kind: kind, bytes: bytes)
  }
  func read(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    page: PagedTextPageRef, maximumPlaintextBytes: Int) throws -> Data {
    try admit(ownerID, documentID)
    return try store.readPage(documentID: documentID, kind: kind, page: page, maximumBytes: maximumPlaintextBytes)
  }
  private func admit(_ owner: UUID, _ document: UUID) throws {
    try store.requireQueue()
    guard owner == ownerID, owner == store.ownerID, document == documentID else {
      throw BoomError.denied("Page provider has another captured source.")
    }
  }
}
