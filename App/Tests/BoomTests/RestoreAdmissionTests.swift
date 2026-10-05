import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class RestoreAdmissionTests: XCTestCase {
  private func fixture() async throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-restore-admission-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let source = try WorkspaceStore(rootOverride: root.appendingPathComponent("source"), testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Backup", text: "Restore this manuscript. 👩‍💻")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
    try await source.save(state, documents: [document])
    let backup = root.appendingPathComponent("explicit.bloombackup")
    try await source.exportBackup(passphrase: "public restore test passphrase", to: backup)
    return (root, backup)
  }
  private func bytes(_ vault: Vault) throws -> [String: Data] {
    try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: vault.root, includingPropertiesForKeys: nil)
      .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
  }
  func testAtomicPublicationRetainsBothVaultsAndRelaunchFindsCompleteWorkspace() async throws {
    let (root, _) = try await fixture(), key = SymmetricKey(size: .bits256)
    let target = try WorkspaceStore(rootOverride: root.appendingPathComponent("atomic-target"), testKey: key)
    let stub = DocumentSnapshot(title: "Untitled", text: "")
    var original = WorkspaceState(); original.documents = [DocumentIndex(id: stub.id, title: stub.title)]
    try await target.save(original, documents: [stub])
    let stage = try target.vault.sibling(at: target.root.appendingPathComponent(".public-replacement"))
    let restored = DocumentSnapshot(title: "Restored", text: "Complete public manuscript. 👩‍💻")
    var replacement = WorkspaceState(); replacement.documents = [DocumentIndex(id: restored.id, title: restored.title)]
    try stage.put(Data(restored.text.utf8), kind: .document, id: restored.id)
    try stage.encode(replacement, kind: .workspace, id: Vault.workspaceID)
    let before = try bytes(target.vault), prepared = try bytes(stage)
    try AtomicDirectoryReplacement.exchange(stage.root, target.vault.root)
    XCTAssertEqual(try bytes(target.vault), prepared)
    XCTAssertEqual(try bytes(stage), before, "Publication must retain the previous encrypted directory.")
    let relaunched = try WorkspaceStore(rootOverride: target.root, testKey: key)
    let loaded = try await relaunched.load().get()
    XCTAssertEqual(loaded.1, [restored])
    try AtomicDirectoryReplacement.exchange(stage.root, target.vault.root)
    XCTAssertEqual(try bytes(target.vault), before)
    XCTAssertEqual(try bytes(stage), prepared)
    let rolledBack = try await target.load().get()
    XCTAssertEqual(rolledBack.1, [stub])
  }
  func testFailedDirectoryExchangeRetainsCanonicalVaultAndRefusesLinksAndFiles() async throws {
    let (root, _) = try await fixture()
    let target = try WorkspaceStore(rootOverride: root.appendingPathComponent("exchange-errors"), testKey: SymmetricKey(size: .bits256))
    try await target.save(WorkspaceState(), documents: [])
    let before = try bytes(target.vault), invalid = target.root.appendingPathComponent("invalid-replacement")
    XCTAssertThrowsError(try AtomicDirectoryReplacement.exchange(invalid, target.vault.root))
    XCTAssertEqual(try bytes(target.vault), before)
    try Data("Public unrelated file.".utf8).write(to: invalid)
    XCTAssertThrowsError(try AtomicDirectoryReplacement.exchange(invalid, target.vault.root))
    XCTAssertEqual(try bytes(target.vault), before)
    XCTAssertEqual(try Data(contentsOf: invalid), Data("Public unrelated file.".utf8))
    try FileManager.default.removeItem(at: invalid)
    try FileManager.default.createSymbolicLink(at: invalid, withDestinationURL: target.vault.root)
    XCTAssertThrowsError(try AtomicDirectoryReplacement.exchange(invalid, target.vault.root))
    XCTAssertEqual(try bytes(target.vault), before)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: invalid.path), target.vault.root.path)
    XCTAssertThrowsError(try AtomicDirectoryReplacement.exchange(target.vault.root, target.vault.root))
    XCTAssertThrowsError(try AtomicDirectoryReplacement.exchange(root, target.vault.root))
    XCTAssertEqual(try bytes(target.vault), before)
  }
  func testFailedRestoreRetainsOriginalBytesAndRevisionGuardForNextSave() async throws {
    let (root, _) = try await fixture()
    let source = try WorkspaceStore(rootOverride: root.appendingPathComponent("invalid-source"), testKey: SymmetricKey(size: .bits256))
    let target = try WorkspaceStore(rootOverride: root.appendingPathComponent("rollback-target"), testKey: SymmetricKey(size: .bits256))
    let stub = DocumentSnapshot(title: "Untitled", text: "")
    var original = WorkspaceState(); original.documents = [DocumentIndex(id: stub.id, title: stub.title)]
    try await target.save(original, documents: [stub])
    let before = try bytes(target.vault)
    let invalid = DocumentSnapshot(id: stub.id, title: "Restored", text: "A different captured revision.")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: invalid.id, title: invalid.title)]
    // Authenticated backup bytes alone do not establish complete workspace validity.
    let invalidCandidate = UUID()
    state.candidateIDs = [invalidCandidate]
    try source.vault.put(Data("Authenticated but incompatible candidate payload.".utf8), kind: .candidate, id: invalidCandidate)
    try await source.save(state, documents: [invalid])
    let backup = root.appendingPathComponent("invalid-candidate.bloombackup")
    try await source.exportBackup(passphrase: "public rollback test passphrase", to: backup)
    do { _ = try await target.restoreBackup(passphrase: "public rollback test passphrase", from: backup); XCTFail("Incomplete workspace admitted") } catch {}
    XCTAssertEqual(try bytes(target.vault), before)
    let next = DocumentSnapshot(id: stub.id, title: stub.title, text: "I can write after a failed restore. 👩‍💻")
    try await target.save(original, documents: [next])
    let loaded = try await target.load().get()
    XCTAssertEqual(loaded.1, [next])
  }
  func testUnindexedRecordsAndUnknownFilesPreventRestoreWithoutChangingAnyBytes() async throws {
    let (root, backup) = try await fixture()
    for kind in [Vault.Kind.attachment, .receipt, .candidate, .editJournal, .generationJournal] {
      let target = try WorkspaceStore(rootOverride: root.appendingPathComponent(kind.rawValue), testKey: SymmetricKey(size: .bits256))
      try await target.save(WorkspaceState(), documents: [])
      try target.vault.put(Data("Unindexed private record. 🦋".utf8), kind: kind, id: UUID())
      let before = try bytes(target.vault)
      do { _ = try await target.restoreBackup(passphrase: "public restore test passphrase", from: backup); XCTFail("Unindexed record was discarded") } catch {}
      XCTAssertEqual(try bytes(target.vault), before)
    }
    let target = try WorkspaceStore(rootOverride: root.appendingPathComponent("unknown-file"), testKey: SymmetricKey(size: .bits256))
    try Data("Explicitly retained file.".utf8).write(to: target.vault.root.appendingPathComponent(".retained"))
    let before = try bytes(target.vault)
    do { _ = try await target.restoreBackup(passphrase: "public restore test passphrase", from: backup); XCTFail("Unknown private file was discarded") } catch {}
    XCTAssertEqual(try bytes(target.vault), before)
  }
  func testRestoreRejectionDoesNotRunPendingSaveRecovery() async throws {
    let (root, backup) = try await fixture()
    let target = try WorkspaceStore(rootOverride: root.appendingPathComponent("pending-save"), testKey: SymmetricKey(size: .bits256))
    let stub = DocumentSnapshot(title: "Untitled", text: "")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: stub.id, title: stub.title)]
    try await target.save(state, documents: [stub])
    let pending = DocumentSnapshot(id: stub.id, title: stub.title, text: "Unfinished authored save.")
    try target.vault.encode(WorkspaceStore.SaveJournal(schema: 1, state: state, documents: [pending], before: [stub.id: stub.revision]),
      kind: .saveJournal, id: Vault.workspaceID)
    let before = try bytes(target.vault)
    do { _ = try await target.restoreBackup(passphrase: "public restore test passphrase", from: backup); XCTFail("Pending journal was discarded") } catch {}
    XCTAssertEqual(try bytes(target.vault), before, "Admission must precede any recovery writes.")
    let manuscript = try await target.readDocument(stub.id)
    XCTAssertEqual(manuscript, "")
  }
  func testHiddenChatHistoryAndBranchOriginsPreventReplacementWhileFreshStubAllowsIt() async throws {
    let (root, backup) = try await fixture()
    let hidden = try WorkspaceStore(rootOverride: root.appendingPathComponent("hidden-chat-history"), testKey: SymmetricKey(size: .bits256))
    var chat = ChatRecord(); chat.messageVersions = [ChatMessage(role: .assistant, text: "Earlier authored answer.")]
    var state = WorkspaceState(); state.chats = [chat]
    try await hidden.save(state, documents: [])
    let before = try bytes(hidden.vault)
    do { _ = try await hidden.restoreBackup(passphrase: "public restore test passphrase", from: backup); XCTFail("Hidden authored history was discarded") } catch {}
    XCTAssertEqual(try bytes(hidden.vault), before)
    state.chats = []; state.manuscriptOrigins[UUID()] = ManuscriptOrigin(documentID: UUID(), revision: "captured", bundleID: UUID(), candidateID: UUID())
    try await hidden.save(state, documents: [])
    let originBytes = try bytes(hidden.vault)
    do { _ = try await hidden.restoreBackup(passphrase: "public restore test passphrase", from: backup); XCTFail("Branch origin was discarded") } catch {}
    XCTAssertEqual(try bytes(hidden.vault), originBytes)
    let fresh = try WorkspaceStore(rootOverride: root.appendingPathComponent("fresh-stub"), testKey: SymmetricKey(size: .bits256))
    let stub = DocumentSnapshot(title: "Untitled", text: "")
    state = WorkspaceState(); state.documents = [DocumentIndex(id: stub.id, title: stub.title)]; state.chats = [ChatRecord()]
    try await fresh.save(state, documents: [stub])
    let freshBytes = try bytes(fresh.vault)
    do { _ = try await fresh.restoreBackup(passphrase: "wrong public test passphrase", from: backup); XCTFail("Wrong passphrase was admitted") } catch {}
    XCTAssertEqual(try bytes(fresh.vault), freshBytes)
    let (_, restored) = try await fresh.restoreBackup(passphrase: "public restore test passphrase", from: backup)
    XCTAssertEqual(restored.map(\.text), ["Restore this manuscript. 👩‍💻"])
    XCTAssertFalse(fresh.vault.exists(.document, stub.id))
  }
}
