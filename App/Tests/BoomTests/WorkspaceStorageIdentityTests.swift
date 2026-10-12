import CryptoKit
import Foundation
import XCTest
@testable import Boom

final class WorkspaceStorageIdentityTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-storage-identity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let failures = testRun?.failureCount ?? 0
    addTeardownBlock { [weak self] in
      guard let self, self.testRun?.failureCount == failures else {
        print("Failed public storage identity fixture retained: \(root.path)")
        return
      }
      try FileManager.default.removeItem(at: root)
    }
    return root
  }

  func testColdBootstrapRestoresIdentitiesWithoutCallerUUIDsOrReplacement() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let first = try await store.preparePagedStorageOpening()
    if case .fresh(let id) = first.sql { XCTAssertEqual(id, first.identity.storeID) }
    else { XCTFail("Empty storage did not select a fresh SQL opening") }
    let path = store.vault.recordURL(.workspaceIdentity, Vault.workspaceID)
    let original = try Data(contentsOf: path)
    XCTAssertNil(original.range(of: Data(first.identity.ownerID.uuidString.utf8)))
    XCTAssertNil(original.range(of: Data(first.identity.storeID.uuidString.utf8)))
    let reopened = try WorkspaceStore(rootOverride: root, testKey: key)
    let second = try await reopened.preparePagedStorageOpening()
    XCTAssertEqual(second.identity, first.identity)
    XCTAssertEqual(try Data(contentsOf: path), original)
    let replacement = PropertyListEncoder()
    let bytes = try replacement.encode(first.identity)
    do { try await Task.detached { try reopened.vault.createWorkspaceIdentity(bytes) }.value; XCTFail("Existing identity was replaced") }
    catch { XCTAssertEqual(try Data(contentsOf: path), original) }
  }

  func testWrongKeyOrCorruptBootstrapCannotCreateAnotherIdentity() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    _ = try await store.preparePagedStorageOpening()
    let path = store.vault.recordURL(.workspaceIdentity, Vault.workspaceID)
    var original = try Data(contentsOf: path)
    let wrong = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    do { _ = try await wrong.preparePagedStorageOpening(); XCTFail("Wrong key created a fresh identity") }
    catch { XCTAssertEqual(try Data(contentsOf: path), original) }
    original[original.count - 1] ^= 1
    try original.write(to: path)
    do { _ = try await store.preparePagedStorageOpening(); XCTFail("Corrupt bootstrap created a fresh identity") }
    catch { XCTAssertEqual(try Data(contentsOf: path), original) }
  }

  func testLegacyAndPartialSQLNamespacesRemainIntact() async throws {
    let root = try root(), store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let legacy = store.vault.recordURL(.workspace, Vault.workspaceID)
    let bytes = Data("public existing-format fixture".utf8)
    try bytes.write(to: legacy)
    do { _ = try await store.preparePagedStorageOpening(); XCTFail("Legacy storage was silently converted") }
    catch { XCTAssertEqual(try Data(contentsOf: legacy), bytes) }
    XCTAssertFalse(store.vault.exists(.workspaceIdentity, Vault.workspaceID))
    try FileManager.default.removeItem(at: legacy)
    let first = try await store.preparePagedStorageOpening()
    let directory = store.vault.root.appendingPathComponent("paged-sqlite-v3", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let partial = directory.appendingPathComponent("store.sqlite-wal")
    try bytes.write(to: partial)
    do { _ = try await store.preparePagedStorageOpening(); XCTFail("Orphan WAL became a fresh SQL store") }
    catch { XCTAssertEqual(try Data(contentsOf: partial), bytes) }
    let restored = try store.vault.decode(WorkspaceStorageIdentity.self, kind: .workspaceIdentity, id: Vault.workspaceID, limit: 512)
    XCTAssertEqual(restored, first.identity)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("store.sqlite").path))
  }
}
