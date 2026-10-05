import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class FolderImportTests: XCTestCase {
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
