import Darwin
import Foundation
import BoomCore
import XCTest
@testable import Boom

final class VaultTests: XCTestCase {
  private func fixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-files-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }

  func testMetadataAndCategoryFilesReopenWithoutKeys() async throws {
    let parent = try fixtureRoot(), root = parent.appendingPathComponent("workspace")
    let store = try WorkspaceStore(rootOverride: root)
    let live = DocumentIndex(id: UUID(), title: "Café"), archived = DocumentIndex(id: UUID(), title: "Earlier draft")
    var state = WorkspaceState()
    state.documents = [live]; state.archivedDocuments = [archived]
    state.selectedDocument = live.id
    state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .document, id: archived.id),
      text: "Retained unsent text", attachments: [], authoredRole: nil)]
    try await store.saveState(state)
    let id = UUID(), bytes = Data("Public original é 🦋".utf8)
    try store.vault.put(bytes, kind: .attachment, id: id)
    let firstIdentity = try await store.storageIdentity()
    let reopened = try WorkspaceStore(rootOverride: root)
    let loaded = try await reopened.loadState(), secondIdentity = try await reopened.storageIdentity()
    XCTAssertEqual(loaded.documents, [live]); XCTAssertEqual(loaded.archivedDocuments, [archived])
    XCTAssertEqual(loaded.composerDrafts?.first?.text, "Retained unsent text")
    XCTAssertEqual(firstIdentity.ownerID, secondIdentity.ownerID)
    XCTAssertEqual(firstIdentity.storeID, secondIdentity.storeID)
    XCTAssertEqual(try reopened.vault.get(.attachment, id: id), bytes)
    XCTAssertEqual(try Data(contentsOf: store.vault.recordURL(.attachment, id)), bytes)
    XCTAssertEqual(store.vault.recordURL(.workspace, Vault.workspaceID), store.root.appendingPathComponent("workspace.json"))
    XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: store.root.appendingPathComponent("workspace.json"))) as? [String: Any])
    for (url, expected) in [(store.root, 0o700), (store.vault.root, 0o700),
      (store.vault.recordURL(.attachment, id), 0o600), (store.root.appendingPathComponent("workspace.json"), 0o600)] {
      let actual = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
      XCTAssertEqual(actual?.intValue, expected)
    }
  }

  func testMalformedMetadataIsRetainedAndCannotBecomeAnEmptyWorkspace() async throws {
    let store = try WorkspaceStore(rootOverride: fixtureRoot())
    try await store.saveState(WorkspaceState())
    let file = store.root.appendingPathComponent("workspace.json"), invalid = Data("{invalid metadata".utf8)
    try invalid.write(to: file)
    do { _ = try await store.loadState(); XCTFail("Malformed metadata was admitted") }
    catch { XCTAssertEqual(try Data(contentsOf: file), invalid) }
  }

  func testBoundedRecordsAndSymbolicLinksAreRefused() throws {
    let root = try fixtureRoot(), objects = root.appendingPathComponent("Objects")
    let vault = try Vault(root: objects), id = UUID(), bytes = Data(repeating: 0x5a, count: 65_537)
    try vault.put(bytes, kind: .attachment, id: id)
    XCTAssertThrowsError(try vault.get(.attachment, id: id, limit: 65_536))
    let foreign = root.appendingPathComponent("foreign"), foreignBytes = Data("Retained foreign bytes".utf8)
    try foreignBytes.write(to: foreign)
    let linkID = UUID()
    try FileManager.default.createSymbolicLink(at: vault.recordURL(.receipt, linkID), withDestinationURL: foreign)
    XCTAssertThrowsError(try vault.get(.receipt, id: linkID))
    XCTAssertThrowsError(try vault.put(Data(), kind: .receipt, id: linkID))
    XCTAssertEqual(try Data(contentsOf: foreign), foreignBytes)
    let rootLink = root.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: objects)
    XCTAssertThrowsError(try Vault(root: rootLink))
  }

  func testWorkspaceLockRefusesASecondOpeningUntilRelease() async throws {
    let root = try fixtureRoot(), first = try WorkspaceStore(rootOverride: root), second = try WorkspaceStore(rootOverride: root)
    try await first.acquireExclusiveWorkspace()
    do { try await second.acquireExclusiveWorkspace(); XCTFail("A second workspace writer was admitted") }
    catch {}
    try await first.releaseExclusiveWorkspace()
    try await second.acquireExclusiveWorkspace()
    try await second.releaseExclusiveWorkspace()
  }

  func testDirectoryBackupPreservesMetadataPagesAndUnindexedFiles() async throws {
    let parent = try fixtureRoot(), store = try WorkspaceStore(rootOverride: parent.appendingPathComponent("workspace"))
    let document = DocumentIndex(id: UUID(), title: "Public source")
    var state = WorkspaceState(); state.documents = [document]
    try await store.saveState(state)
    let identity = try await store.storageIdentity()
    let attachment = UUID(), original = Data(repeating: 0x71, count: 196_619)
    try store.vault.put(original, kind: .attachment, id: attachment)
    let pages = store.root.appendingPathComponent("Documents/" + document.id.uuidString)
    try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
    let pageBytes = Data(repeating: 0x44, count: 131_075)
    try pageBytes.write(to: pages.appendingPathComponent("pages"))
    let interrupted = Data("Public retained operation evidence".utf8)
    try interrupted.write(to: store.root.appendingPathComponent(".interrupted"))
    let backup = parent.appendingPathComponent("backup")
    try await store.exportBackup(to: backup)
    let restored = try WorkspaceStore(rootOverride: parent.appendingPathComponent("restored"))
    try await restored.restoreBackup(from: backup)
    let loaded = try await restored.loadState(), restoredIdentity = try await restored.storageIdentity()
    XCTAssertEqual(loaded.documents, [document])
    XCTAssertEqual(restoredIdentity.ownerID, identity.ownerID)
    XCTAssertEqual(restoredIdentity.storeID, identity.storeID)
    XCTAssertEqual(try restored.vault.get(.attachment, id: attachment), original)
    XCTAssertEqual(try Data(contentsOf: restored.root.appendingPathComponent("Documents/" + document.id.uuidString + "/pages")), pageBytes)
    XCTAssertEqual(try Data(contentsOf: restored.root.appendingPathComponent(".interrupted")), interrupted)
    let before = try Data(contentsOf: restored.root.appendingPathComponent("workspace.json"))
    do { try await restored.restoreBackup(from: backup); XCTFail("An authored workspace was replaced") }
    catch { XCTAssertEqual(try Data(contentsOf: restored.root.appendingPathComponent("workspace.json")), before) }
  }

  func testBackupDoesNotReplaceExistingOutputOrFollowLinks() throws {
    let parent = try fixtureRoot(), source = parent.appendingPathComponent("source"), destination = parent.appendingPathComponent("backup")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let retained = Data("Existing backup".utf8)
    try retained.write(to: destination.appendingPathComponent("retained"))
    XCTAssertThrowsError(try WorkspaceBackup.export(root: source, to: destination))
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("retained")), retained)
    let foreign = parent.appendingPathComponent("foreign")
    try retained.write(to: foreign)
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: foreign)
    let refused = parent.appendingPathComponent("refused")
    XCTAssertThrowsError(try WorkspaceBackup.export(root: source, to: refused))
    XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    XCTAssertEqual(try Data(contentsOf: foreign), retained)
  }
  func testFailedAtomicReplacementRemovesOnlyItsTemporaryRecord() throws {
    let root = try fixtureRoot(), vault = try Vault(root: root.appendingPathComponent("Objects"))
    let id = UUID(), before = Data("Retained category bytes".utf8), after = Data("Replacement bytes".utf8)
    try vault.put(before, kind: .receipt, id: id)
    let target = vault.recordURL(.receipt, id)
    let descriptor = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
    var admitted = stat()
    guard fstat(descriptor, &admitted) == 0, admitted.st_mode & S_IFMT == S_IFREG,
      admitted.st_uid == getuid(), admitted.st_nlink == 1 else {
      throw BoomError.invalid("The owned category fixture is not a regular file.")
    }
    guard fchflags(descriptor, admitted.st_flags | UInt32(UF_IMMUTABLE)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { XCTAssertEqual(fchflags(descriptor, admitted.st_flags), 0, "Restore exact flags on the same opened inode") }
    do {
      try vault.put(after, kind: .receipt, id: id)
      XCTFail("An immutable destination allowed atomic replacement")
    } catch {
      let actual = error as NSError
      XCTAssertEqual(actual.domain, NSPOSIXErrorDomain)
      XCTAssertEqual(actual.code, Int(EPERM), "The real rename failure must remain the primary error")
    }
    XCTAssertEqual(try vault.get(.receipt, id: id), before)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: vault.root.path)
      .allSatisfy { !$0.hasPrefix(".record-") }, "Failed publication must not leave its disposable stage")
    guard fchflags(descriptor, admitted.st_flags) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try vault.put(after, kind: .receipt, id: id)
    XCTAssertEqual(try vault.get(.receipt, id: id), after)
  }

}
