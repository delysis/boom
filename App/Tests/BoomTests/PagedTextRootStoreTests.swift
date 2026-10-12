import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

final class PagedTextRootStoreTests: XCTestCase {
  private func workspace() throws -> (URL, Vault, SymmetricKey, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-paged-root-" + UUID().uuidString)
    let key = SymmetricKey(size: .bits256), owner = UUID()
    let vault = try Vault(root: root, testKey: key)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, vault, key, owner)
  }
  private func document(owner: UUID, title: String = "Public") -> PagedDocumentDescriptor {
    let id = UUID()
    return PagedDocumentDescriptor(id: id, title: title,
      revision: PagedTextRevision(schema: 1, ownerID: owner, documentID: id, root: nil))
  }
  private func interruptedJournal(_ journal: PagedTextPublishJournal, vault: Vault, root: URL) throws -> Data {
    let plaintext = try JSONEncoder().encode(journal)
    let binding = try PagedTextMetadataBinding(ownerID: journal.ownerID, role: .journal, plaintextBytes: plaintext.count)
    let ciphertext = try vault.sealPagedTextMetadata(plaintext, binding: binding)
    try ciphertext.write(to: root.appendingPathComponent("paged-text-v1/journal.sealed"), options: .atomic)
    return ciphertext
  }
  func testDurableJournalBeforeAndAfterCatalogRecoveryAndConflictRetention() async throws {
    let (root, vault, key, owner) = try workspace()
    let store = try PagedTextRootStore(vault: vault, ownerID: owner)
    _ = try store.initialize()
    let after = document(owner: owner, title: "Public Cafe\u{301}")
    let journal = PagedTextPublishJournal(ownerID: owner, generation: 0, before: nil, after: after)
    _ = try interruptedJournal(journal, vault: vault, root: root)
    let reopened = try PagedTextRootStore(vault: Vault(root: root, testKey: key), ownerID: owner)
    var validations = 0
    let restored = try reopened.load { revision in
      XCTAssertEqual(revision, after.revision); validations += 1
    }
    XCTAssertEqual(restored.generation, 1)
    XCTAssertEqual(restored.documents, [after])
    XCTAssertEqual(validations, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("paged-text-v1/journal.sealed").path))
    // Independently reconstruct the crash after catalog rename but before
    // journal deletion. Recovery must be idempotent rather than add a new root.
    _ = try interruptedJournal(journal, vault: vault, root: root)
    XCTAssertEqual(try reopened.load { _ in }, restored)
    let conflict = PagedTextPublishJournal(ownerID: owner, generation: 0, before: nil, after: document(owner: owner))
    let retained = try interruptedJournal(conflict, vault: vault, root: root)
    XCTAssertThrowsError(try reopened.load { _ in })
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("paged-text-v1/journal.sealed")), retained)
    XCTAssertThrowsError(try reopened.initialize())
  }
  func testUnavailableRootDoesNotAdvanceCatalogOrDiscardJournal() async throws {
    let (root, vault, _, owner) = try workspace()
    let store = try PagedTextRootStore(vault: vault, ownerID: owner)
    let initial = try store.initialize()
    let after = document(owner: owner)
    let retained = try interruptedJournal(PagedTextPublishJournal(ownerID: owner, generation: 0, before: nil, after: after), vault: vault, root: root)
    let catalogPath = root.appendingPathComponent("paged-text-v1/catalog.sealed")
    let before = try Data(contentsOf: catalogPath)
    XCTAssertThrowsError(try store.load { _ in throw BoomError.invalid("Public missing root fixture") })
    XCTAssertEqual(try Data(contentsOf: catalogPath), before)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("paged-text-v1/journal.sealed")), retained)
    let recovered = try store.load { _ in }
    XCTAssertEqual(initial.documents.count, 0)
    XCTAssertEqual(recovered.documents, [after])
  }
  func testAuthenticatedCatalogWrongOwnerTamperAndTitleBoundsFailClosed() async throws {
    let (root, vault, key, owner) = try workspace()
    let store = try PagedTextRootStore(vault: vault, ownerID: owner)
    _ = try store.initialize()
    var synced = false, validated = false
    let after = document(owner: owner)
    _ = try store.publish(after, expected: nil, synchronizePages: { synced = true }, validateRoot: { _ in validated = true })
    XCTAssertTrue(synced && validated)
    let foreign = try PagedTextRootStore(vault: Vault(root: root, testKey: key), ownerID: UUID())
    XCTAssertThrowsError(try foreign.load { _ in })
    XCTAssertThrowsError(try store.publish(document(owner: owner, title: String(repeating: "x", count: 1_025)),
      expected: nil, synchronizePages: {}, validateRoot: { _ in }))
    let path = root.appendingPathComponent("paged-text-v1/catalog.sealed")
    var ciphertext = try Data(contentsOf: path)
    ciphertext[ciphertext.count - 1] ^= 1
    try ciphertext.write(to: path)
    XCTAssertThrowsError(try store.load { _ in })
    XCTAssertThrowsError(try store.initialize())
    XCTAssertEqual(try Data(contentsOf: path), ciphertext)
  }
}
