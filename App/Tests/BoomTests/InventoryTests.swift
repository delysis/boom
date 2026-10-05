import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class InventoryTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, UUID, Data) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-inventory-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let id = UUID(), original = Data("Public original. Café 👩‍💻".utf8)
    var state = WorkspaceState()
    state.attachments = [AttachmentRecord(id: id, name: "Public.txt", rootDigest: Digest.sha256(original),
      text: "Public original. Café 👩‍💻", coverage: "complete")]
    try store.vault.put(original, kind: .attachment, id: id)
    try store.vault.put(Data("Public inspection receipt.".utf8), kind: .receipt, id: id)
    try await store.save(state, documents: [])
    return (store, id, original)
  }
  private func bytes(_ vault: Vault) throws -> [String: Data] {
    try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: vault.root, includingPropertiesForKeys: nil)
      .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
  }
  func testMissingAttachmentOriginalRejectsLoadAndCompleteBackupWithoutWrites() async throws {
    let (store, id, _) = try await fixture()
    try store.vault.remove(.attachment, id: id)
    let before = try bytes(store.vault), backup = store.root.appendingPathComponent("complete.bloombackup")
    do { _ = try await store.load().get(); XCTFail("Missing original was admitted") } catch {}
    do { try await store.exportBackup(passphrase: "public inventory passphrase", to: backup); XCTFail("Incomplete backup was exported") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    XCTAssertEqual(try bytes(store.vault), before)
    let retained = Data("Public existing export must remain unchanged.".utf8)
    try retained.write(to: backup)
    do { try await store.exportBackup(passphrase: "public inventory passphrase", to: backup); XCTFail("Incomplete export replaced a file") } catch {}
    XCTAssertEqual(try Data(contentsOf: backup), retained)
  }
  func testChangedCorruptAndUnreceiptedOriginalsRejectAdmissionWithoutChangingEvidence() async throws {
    for variant in ["changed", "corrupt", "receipt"] {
      let (store, id, _) = try await fixture()
      if variant == "changed" { try store.vault.put(Data("Other public bytes.".utf8), kind: .attachment, id: id) }
      if variant == "corrupt" {
        let file = store.vault.recordURL(.attachment, id)
        var value = try Data(contentsOf: file); value[value.count - 1] ^= 1; try value.write(to: file)
      }
      if variant == "receipt" { try store.vault.remove(.receipt, id: id) }
      let before = try bytes(store.vault), backup = store.root.appendingPathComponent("complete.bloombackup")
      do { _ = try await store.load().get(); XCTFail("Invalid original admitted: \(variant)") } catch {}
      do { try await store.exportBackup(passphrase: "public inventory passphrase", to: backup); XCTFail("Invalid backup exported: \(variant)") } catch {}
      XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
      XCTAssertEqual(try bytes(store.vault), before)
    }
  }
  func testUnknownPrivateFileCannotBecomeAnEmptyWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-unknown-inventory-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    try Data("Public retained evidence.".utf8).write(to: store.vault.root.appendingPathComponent("unknown-format"))
    let before = try bytes(store.vault)
    do { _ = try await store.load().get(); XCTFail("Unknown files became empty state") } catch {}
    XCTAssertEqual(try bytes(store.vault), before)
    XCTAssertFalse(store.vault.exists(.workspace, Vault.workspaceID))
  }
  func testCompleteBackupRewrapsOriginalReceiptAndUnindexedEvidence() async throws {
    let (store, id, original) = try await fixture()
    let orphan = UUID(), evidence = Data("Public interrupted import evidence.".utf8)
    try store.vault.put(evidence, kind: .attachment, id: orphan)
    let backup = store.root.appendingPathComponent("complete.bloombackup")
    try await store.exportBackup(passphrase: "public inventory passphrase", to: backup)
    let restored = try WorkspaceStore(rootOverride: store.root.appendingPathComponent("restored"), testKey: SymmetricKey(size: .bits256))
    _ = try await restored.restoreBackup(passphrase: "public inventory passphrase", from: backup)
    XCTAssertEqual(try restored.vault.get(.attachment, id: id), original)
    XCTAssertEqual(try restored.vault.get(.receipt, id: id), Data("Public inspection receipt.".utf8))
    XCTAssertEqual(try restored.vault.get(.attachment, id: orphan), evidence)
    XCTAssertNotEqual(try bytes(store.vault)[store.vault.recordURL(.attachment, id).lastPathComponent],
      try bytes(restored.vault)[restored.vault.recordURL(.attachment, id).lastPathComponent])
  }
  func testAuthenticatedIncompleteBackupIsRejectedBeforeReplacingTheTarget() async throws {
    let (source, id, _) = try await fixture()
    let passphrase = "public inventory passphrase", backup = source.root.appendingPathComponent("incomplete.bloombackup")
    try await source.exportBackup(passphrase: passphrase, to: backup)
    let exported = try Data(contentsOf: backup), headerCount = Data("BLOOM-BACKUP-1\n".utf8).count + 16
    let header = Data(exported.prefix(headerCount))
    let keyBytes: [UInt8] = try ProductCore.call(["op": "backup_key", "passphrase": passphrase, "salt": Array(header.suffix(16))])
    let key = SymmetricKey(data: Data(keyBytes))
    let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(exported.dropFirst(headerCount))), using: key, authenticating: header)
    let archive = try PropertyListDecoder().decode(BackupArchive.self, from: plain)
    let incomplete = BackupArchive(schema: archive.schema, records: archive.records.filter { !($0.kind == "attachment" && $0.id == id) })
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let forged = try XCTUnwrap(AES.GCM.seal(encoder.encode(incomplete), using: key, authenticating: header).combined)
    try (header + forged).write(to: backup)
    let originalBackup = try Data(contentsOf: backup)
    let target = try WorkspaceStore(rootOverride: source.root.appendingPathComponent("fresh-target"), testKey: SymmetricKey(size: .bits256))
    let stub = DocumentSnapshot(title: "Untitled", text: "")
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: stub.id, title: stub.title)]
    try await target.save(state, documents: [stub])
    let before = try bytes(target.vault)
    do { _ = try await target.restoreBackup(passphrase: passphrase, from: backup); XCTFail("Authenticated incomplete backup was admitted") } catch {}
    XCTAssertEqual(try bytes(target.vault), before)
    XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
    let loaded = try await target.load().get()
    XCTAssertEqual(loaded.1, [stub])
  }
}
