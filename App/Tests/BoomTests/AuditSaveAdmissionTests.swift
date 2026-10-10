import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class AuditSaveAdmissionTests: XCTestCase {
  private func fixture() throws -> (URL, SymmetricKey, WorkspaceStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-audit-save-" + UUID().uuidString)
    let key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, key, store)
  }
  func testRejectedOversizedEditCannotChangeTheNextLaunch() async throws {
    let (root, key, store) = try fixture()
    let before = DocumentSnapshot(title: "Public admission fixture", text: "Keep this authored text.")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: before.id, title: before.title)]
    try await store.save(state, documents: [before])
    let indexBytes = try Data(contentsOf: store.vault.recordURL(.workspace, Vault.workspaceID))
    let documentBytes = try Data(contentsOf: store.documentURL(before.id))
    let rejected = DocumentSnapshot(id: before.id, title: before.title,
      text: String(repeating: "x", count: 2_097_153))
    do { try await store.save(state, documents: [rejected]); XCTFail("Oversized save was admitted") }
    catch { XCTAssertTrue(error.localizedDescription.contains("2 MiB")) }
    XCTAssertFalse(store.vault.exists(.saveJournal, Vault.workspaceID), "Rejected work must not become recoverable work")
    XCTAssertEqual(try Data(contentsOf: store.documentURL(before.id)), documentBytes)
    XCTAssertEqual(try Data(contentsOf: store.vault.recordURL(.workspace, Vault.workspaceID)), indexBytes)
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    switch await restarted.load() {
    case .success(let loaded): XCTAssertEqual(loaded.1.map(\.revision), [before.revision])
    case .failure(let error): XCTFail("Rejected edit poisoned reopening: \(error.localizedDescription)")
    }
    XCTAssertEqual(try Data(contentsOf: store.documentURL(before.id)), documentBytes,
      "Reopening must not overwrite the last admitted document")
  }
  func testEntireBatchIsAdmittedBeforeAnyDocumentChanges() async throws {
    let (root, key, store) = try fixture()
    let a = DocumentSnapshot(title: "A", text: "Original A")
    let b = DocumentSnapshot(title: "B", text: "Original B")
    var state = WorkspaceState(); state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    try await store.save(state, documents: [a, b])
    let nextA = DocumentSnapshot(id: a.id, title: a.title, text: "Changed A")
    let invalidB = DocumentSnapshot(id: b.id, title: b.title, text: String(repeating: "é", count: 1_048_577))
    do { try await store.save(state, documents: [nextA, invalidB]); XCTFail("Invalid batch admitted") }
    catch { XCTAssertTrue(error.localizedDescription.contains("2 MiB")) }
    XCTAssertEqual(try store.vault.get(.document, id: a.id), Data(a.text.utf8), "A rejected batch must leave every document intact")
    XCTAssertFalse(store.vault.exists(.saveJournal, Vault.workspaceID))
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    switch await restarted.load() {
    case .success(let loaded): XCTAssertEqual(loaded.1.map(\.revision), [a.revision, b.revision])
    case .failure(let error): XCTFail("Rejected batch poisoned reopening: \(error.localizedDescription)")
    }
  }
  func testExactTwoMiBUTF8BoundaryStillSavesAndReopens() async throws {
    let (root, key, store) = try fixture()
    let document = DocumentSnapshot(title: "Boundary", text: String(repeating: "é", count: 1_048_576))
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
    try await store.save(state, documents: [document])
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    let loaded = try await restarted.load().get()
    XCTAssertEqual(loaded.1.map(\.revision), [document.revision])
  }
  func testRejectedLargerEditCannotMakeTheWorkspaceUnreadable() async throws {
    let (root, key, store) = try fixture()
    let before = DocumentSnapshot(title: "Public rejection fixture", text: "Last admitted version")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: before.id, title: before.title)]
    try await store.save(state, documents: [before])
    let invalid = DocumentSnapshot(id: before.id, title: before.title, text: String(repeating: "x", count: 2_097_217))
    do { try await store.save(state, documents: [invalid]); XCTFail("Oversized save admitted") } catch {}
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    switch await restarted.load() {
    case .success(let loaded): XCTAssertEqual(loaded.1.map(\.revision), [before.revision])
    case .failure(let error): XCTFail("Rejected edit prevented reopening: \(error.localizedDescription)")
    }
  }
  func testRecoveryRejectsAnOldInvalidJournalBeforeAnyRepairAndRetainsEvidence() async throws {
    let (root, key, store) = try fixture()
    let a = DocumentSnapshot(title: "A", text: "Last admitted A")
    let b = DocumentSnapshot(title: "B", text: "Last admitted B")
    var state = WorkspaceState(); state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    try await store.save(state, documents: [a, b])
    let aBytes = try Data(contentsOf: store.documentURL(a.id))
    let bBytes = try Data(contentsOf: store.documentURL(b.id))
    let invalid = WorkspaceStore.SaveJournal(schema: 1, state: state, documents: [
      DocumentSnapshot(id: a.id, title: a.title, text: "Not yet admitted A"),
      DocumentSnapshot(id: b.id, title: b.title, text: String(repeating: "x", count: 2_097_153))
    ], before: [a.id: a.revision, b.id: b.revision])
    try store.vault.encode(invalid, kind: .saveJournal, id: Vault.workspaceID)
    let journalURL = store.vault.recordURL(.saveJournal, Vault.workspaceID)
    let journalBytes = try Data(contentsOf: journalURL)
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    switch await restarted.load() {
    case .success: XCTFail("Recovery admitted an invalid historical journal")
    case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("2 MiB"))
    }
    XCTAssertEqual(try Data(contentsOf: store.documentURL(a.id)), aBytes)
    XCTAssertEqual(try Data(contentsOf: store.documentURL(b.id)), bBytes)
    XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
  }
  func testPlaintextReadLimitIsExactEvenWithinEncryptedEnvelopeSlack() throws {
    let (_, _, store) = try fixture()
    let id = UUID()
    try store.vault.put(Data(repeating: 42, count: 65), kind: .document, id: id)
    XCTAssertThrowsError(try store.vault.get(.document, id: id, limit: 64))
    XCTAssertEqual(try store.vault.get(.document, id: id, limit: 65), Data(repeating: 42, count: 65))
  }
  func testAggregateJournalCannotPoisonAnOtherwiseAdmittedWorkspace() async throws {
    let (root, key, store) = try fixture()
    let before = DocumentSnapshot(title: "Admitted", text: "Keep the last admitted version.")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: before.id, title: before.title)]
    try await store.save(state, documents: [before])
    let indexURL = store.vault.recordURL(.workspace, Vault.workspaceID)
    let indexBytes = try Data(contentsOf: indexURL), documentBytes = try Data(contentsOf: store.documentURL(before.id))
    let batch = (0..<65).map { index -> DocumentSnapshot in
      let prefix = "\(index):"
      return DocumentSnapshot(title: "Public aggregate \(index)", text: prefix + String(repeating: "x", count: 2_097_152 - prefix.utf8.count))
    }
    state.documents += batch.map { DocumentIndex(id: $0.id, title: $0.title) }
    do { try await store.save(state, documents: batch); XCTFail("Aggregate journal was admitted") }
    catch { XCTAssertTrue(error.localizedDescription.contains("128 MiB")) }
    XCTAssertFalse(store.vault.exists(.saveJournal, Vault.workspaceID))
    XCTAssertEqual(try Data(contentsOf: indexURL), indexBytes)
    XCTAssertEqual(try Data(contentsOf: store.documentURL(before.id)), documentBytes)
    for document in batch { XCTAssertFalse(store.vault.exists(.document, document.id)) }
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    let loaded = try await restarted.load().get()
    XCTAssertEqual(loaded.1, [before])
  }
  func testInterruptedAdmittedSaveRollsForwardEveryDocumentAndTheIndex() async throws {
    let (root, key, store) = try fixture()
    let a = DocumentSnapshot(title: "A", text: "Original A"), b = DocumentSnapshot(title: "B", text: "Original B")
    var state = WorkspaceState(); state.documents = [a, b].map { DocumentIndex(id: $0.id, title: $0.title) }
    try await store.save(state, documents: [a, b])
    let nextA = DocumentSnapshot(id: a.id, title: "Updated A", text: "New A 🦋")
    let nextB = DocumentSnapshot(id: b.id, title: "Updated B", text: "New B é")
    state.documents = [nextA, nextB].map { DocumentIndex(id: $0.id, title: $0.title) }
    let journal = WorkspaceStore.SaveJournal(schema: 1, state: state, documents: [nextA, nextB], before: [a.id: a.revision, b.id: b.revision])
    try store.vault.encode(journal, kind: .saveJournal, id: Vault.workspaceID)
    try store.vault.put(Data(nextA.text.utf8), kind: .document, id: a.id)
    // This retained on-disk state represents interruption after one document, before index publication.
    let restarted = try WorkspaceStore(rootOverride: root, testKey: key)
    let loaded = try await restarted.load().get()
    XCTAssertEqual(loaded.1, [nextA, nextB])
    XCTAssertEqual(loaded.0.documents.map(\.title), [nextA.title, nextB.title])
    XCTAssertFalse(store.vault.exists(.saveJournal, Vault.workspaceID))
    XCTAssertEqual(try store.vault.get(.document, id: b.id), Data(nextB.text.utf8))
  }
}
