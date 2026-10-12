import BoomCore
import Foundation

/// Existing synchronous provider contract. The engine/executor supplies this
/// owner; no cache, queue, key or publish authority is created by a document.
protocol PagedTextDocumentPages: Sendable {
  var ownerID: UUID { get }
  var documentID: UUID { get }
  func writeNew(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    bytes: Data) throws -> PagedTextPageLocator
  func read(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    page: PagedTextPageRef, maximumPlaintextBytes: Int) throws -> Data
}

struct PagedSQLiteDocumentPages: PagedTextDocumentPages {
  let store: PagedSQLiteStore
  let ownerID: UUID
  let documentID: UUID
  func writeNew(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    bytes: Data) throws -> PagedTextPageLocator {
    try admit(ownerID, documentID)
    let id = UUID(), role: PagedSQLiteRole = kind == .text ? .text : .index
    try store.insert(bytes, objectID: id, documentID: documentID, role: role)
    return PagedTextPageLocator(storeID: store.storeID, recordID: id,
      ciphertextBytes: UInt32(bytes.count + 28))
  }
  func read(ownerID: UUID, documentID: UUID, kind: PagedTextPageKind,
    page: PagedTextPageRef, maximumPlaintextBytes: Int) throws -> Data {
    try admit(ownerID, documentID)
    guard maximumPlaintextBytes > 0, maximumPlaintextBytes <= kind.maximumBytes else {
      throw BoomError.budget("SQLite page read exceeds its exact kind bound.")
    }
    try page.validate(maximumPlaintextBytes: maximumPlaintextBytes)
    try page.locator.admit(storeID: store.storeID)
    let address = page.locator
    let bytes = try store.read(objectID: address.recordID, documentID: documentID,
      role: kind == .text ? .text : .index, maximumBytes: maximumPlaintextBytes)
    guard bytes.count + 28 == Int(address.ciphertextBytes), Digest.sha256(bytes) == page.digest else {
      throw BoomError.invalid("SQLite page differs from its authenticated immutable reference.")
    }
    return bytes
  }
  private func admit(_ owner: UUID, _ document: UUID) throws {
    try store.requireQueue()
    guard owner == ownerID, owner == store.ownerID, document == documentID else {
      throw BoomError.denied("SQLite provider has another admitted source.")
    }
  }
}
