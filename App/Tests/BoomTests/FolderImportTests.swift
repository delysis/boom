import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class FolderImportTests: XCTestCase {
  @MainActor func testSelectedFileImportRetainsOriginalBytesThroughEditRelaunchAndBackupRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-selected-import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("chosen-a/notes.md"), b = root.appendingPathComponent("chosen-b/notes.md")
    for file in [a, b] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
    let originals = [Data("\u{feff}# 章\r\nCafé 👩‍💻\nselected-import-canary".utf8), Data()]
    for (file, bytes) in zip([a, b], originals) { try bytes.write(to: file) }
    let key = SymmetricKey(size: .bits256)
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted"), testKey: key)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try await model.importDocuments([a, b], flag: CancellationFlag())
    let imported = model.documents.filter { model.state.importedFiles?[$0.id] != nil }
    XCTAssertEqual(imported.count, 2)
    let first = try XCTUnwrap(imported.first)
    XCTAssertEqual(model.state.importedFiles?[first.id]?.path, "notes.md")
    XCTAssertNil(model.state.importedFiles?[first.id]?.folderID, "Selected files remain in the ordinary document list.")
    model.updateDocument("A changed manuscript. 🦋", id: first.id, caret: 0)
    try await model.shutdown()
    let relaunched = try WorkspaceStore(rootOverride: store.root, testKey: key)
    let (state, documents) = try await relaunched.load().get()
    XCTAssertEqual(documents.first { $0.id == first.id }?.text, "A changed manuscript. 🦋")
    XCTAssertEqual(state.importedFiles?[first.id]?.originalDigest, Digest.sha256(originals[0]))
    for (document, bytes) in zip(imported, originals) {
      XCTAssertEqual(try relaunched.vault.get(.attachment, id: document.id), bytes)
    }
    for (file, bytes) in zip([a, b], originals) { XCTAssertEqual(try Data(contentsOf: file), bytes) }
    for record in try FileManager.default.contentsOfDirectory(at: store.vault.root, includingPropertiesForKeys: nil) {
      XCTAssertNil(try Data(contentsOf: record).range(of: Data("selected-import-canary".utf8)))
    }
    let backup = root.appendingPathComponent("explicit.bloombackup")
    try await relaunched.exportBackup(passphrase: "public selected import test", to: backup)
    for file in [a, b] { try FileManager.default.removeItem(at: file) }
    let restored = try WorkspaceStore(rootOverride: root.appendingPathComponent("restored"), testKey: SymmetricKey(size: .bits256))
    let (_, restoredDocuments) = try await restored.restoreBackup(passphrase: "public selected import test", from: backup)
    XCTAssertEqual(restoredDocuments, documents)
    for (document, bytes) in zip(imported, originals) {
      XCTAssertEqual(try restored.vault.get(.attachment, id: document.id), bytes)
    }
  }
  @MainActor func testInvalidLaterImportAndCancellationAdmitNoEarlierFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-selected-invalid-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let good = root.appendingPathComponent("good.md"), bad = root.appendingPathComponent("bad.md")
    try Data("Keep this original.".utf8).write(to: good); try Data([0xff, 0xfe, 0xff]).write(to: bad)
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted"), testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try await model.flush()
    let before = try FileManager.default.contentsOfDirectory(atPath: store.vault.root.path).sorted()
    let documents = model.documents
    do { try await model.importDocuments([good, bad], flag: CancellationFlag()); XCTFail("Invalid later file was admitted") } catch {}
    let cancelled = CancellationFlag(); cancelled.cancel()
    do { try await model.importDocuments([good], flag: cancelled); XCTFail("Cancelled import was admitted") } catch {}
    XCTAssertEqual(model.documents, documents)
    XCTAssertTrue((model.state.importedFiles ?? [:]).isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.vault.root.path).sorted(), before)
    try await model.shutdown()
  }
  func testOriginalCollisionRetainsEveryExistingCiphertext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-original-collision-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let existing = UUID(), new = UUID()
    try store.vault.put(Data("Existing original.".utf8), kind: .attachment, id: existing)
    let before = try Data(contentsOf: store.vault.recordURL(.attachment, existing))
    let files = [new, existing].map { FolderImport.File(id: $0, path: "notes.md", original: Data("Replacement".utf8), text: "Replacement") }
    do { try await store.retainImportedOriginals(files, flag: CancellationFlag()); XCTFail("Colliding original was replaced") } catch {}
    XCTAssertEqual(try Data(contentsOf: store.vault.recordURL(.attachment, existing)), before)
    XCTAssertFalse(store.vault.exists(.attachment, new))
  }
  func testMissingImportedOriginalAndDuplicateFolderIdentityRejectLoadingWithoutReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-import-integrity-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let document = DocumentSnapshot(title: "Imported", text: "Private original.")
    let folder = ImportedFolder(id: UUID(), name: "Chosen folder")
    var state = WorkspaceState()
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.importedFolders = [folder]
    state.importedFiles = [document.id: ImportedFile(folderID: folder.id, path: "Imported.md", originalDigest: document.revision)]
    try await store.save(state, documents: [document])
    let indexURL = store.vault.recordURL(.workspace, Vault.workspaceID)
    let before = try Data(contentsOf: indexURL)
    do { _ = try await store.load().get(); XCTFail("Missing originals must stop loading.") } catch {}
    XCTAssertEqual(try Data(contentsOf: indexURL), before)
    try store.vault.put(Data(document.text.utf8), kind: .attachment, id: document.id)
    _ = try await store.load().get()
    state.importedFolders = [folder, folder]
    try await store.save(state, documents: [])
    let duplicate = try Data(contentsOf: indexURL)
    do { _ = try await store.load().get(); XCTFail("Duplicate folder identities must stop loading.") } catch {}
    XCTAssertEqual(try Data(contentsOf: indexURL), duplicate)
    XCTAssertEqual(try store.vault.get(.attachment, id: document.id), Data(document.text.utf8))
  }
  func testImportCapturesUnicodeOriginalsSkipsOutsideLinksAndNeverWritesSourceFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-folder-import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("chosen")
    let nested = source.appendingPathComponent("Drafts")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let bytes = Data("# 章\r\nCafé 👩‍💻\noriginal-import-canary".utf8)
    let file = nested.appendingPathComponent("章.md")
    try bytes.write(to: file)
    try Data().write(to: source.appendingPathComponent("empty.txt"))
    let outside = root.appendingPathComponent("outside.md")
    try Data("outside-canary".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.md"), withDestinationURL: outside)
    let imported = try FolderImport.read(source, flag: CancellationFlag())
    XCTAssertEqual(imported.map(\.path), ["Drafts/章.md", "empty.txt"])
    let original = try XCTUnwrap(imported.first)
    XCTAssertEqual(original.original, bytes)
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted"), testKey: SymmetricKey(size: .bits256))
    let folder = ImportedFolder(id: UUID(), name: "chosen")
    var state = WorkspaceState()
    state.importedFolders = [folder]
    state.importedFiles = [original.id: ImportedFile(folderID: folder.id, path: original.path,
      originalDigest: Digest.sha256(bytes))]
    let document = DocumentSnapshot(id: original.id, title: "章", text: original.text + "\nEdited inside Bloom.")
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    try store.vault.put(bytes, kind: .attachment, id: original.id)
    try await store.save(state, documents: [document])
    let loaded = try await store.load().get()
    XCTAssertEqual(loaded.1, [document])
    XCTAssertEqual(loaded.0.importedFiles?[original.id]?.path, original.path)
    XCTAssertEqual(try store.vault.get(.attachment, id: original.id), bytes)
    XCTAssertEqual(try Data(contentsOf: file), bytes, "Editing the imported document cannot mutate its source.")
    for record in try FileManager.default.contentsOfDirectory(at: store.vault.root, includingPropertiesForKeys: nil) {
      XCTAssertNil(try Data(contentsOf: record).range(of: Data("original-import-canary".utf8)))
    }
  }
}
