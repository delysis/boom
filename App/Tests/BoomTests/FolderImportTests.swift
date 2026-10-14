import AppKit
import BoomCore
import XCTest
@testable import Boom

final class FolderImportTests: XCTestCase {
  @MainActor func testSelectedFileImportRetainsOriginalBytesThroughEditRelaunchAndBackupRestore() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-selected-import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("chosen-a/notes.md"), b = root.appendingPathComponent("chosen-b/notes.md")
    for file in [a, b] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
    let originals = [Data("\u{feff}# 章\r\nCafé 👩‍💻\nselected-import-canary".utf8), Data()]
    for (file, bytes) in zip([a, b], originals) { try bytes.write(to: file) }
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("workspace"))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try await model.importDocuments([a, b], flag: CancellationFlag())
    let sources = try await NativeCheckEvidence.readPublicDocuments(model: model)
    let paths = Set([a.path, b.path])
    let imported = sources.filter { paths.contains(model.state.importedFiles?[$0.id]?.path ?? "") }
    XCTAssertEqual(imported.count, 2)
    let first = try XCTUnwrap(imported.first { model.state.importedFiles?[$0.id]?.path == a.path })
    XCTAssertNil(model.state.importedFiles?[first.id]?.folderID)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 640, height: 480))
    window.isReleasedWhenClosed = false; window.contentView = try XCTUnwrap(model.pagedViewport)
    defer { window.close() }
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(model.pagedInput?.activeView)))
    try await NativeCheckEvidence.replacePublicDocument(model, text: "A changed manuscript. 🦋", id: first.id, caret: 0)
    for (file, bytes) in zip([a, b], originals) {
      let document = try XCTUnwrap(imported.first { model.state.importedFiles?[$0.id]?.path == file.path })
      let actualRead1 = try await NativeCheckEvidence.readPublicOriginal(model: model, documentID: document.id)
      XCTAssertEqual(actualRead1, bytes)
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    try await model.shutdown()
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let documents = try await NativeCheckEvidence.readPublicDocuments(model: reopened)
    XCTAssertEqual(documents.first { $0.id == first.id }?.text, "A changed manuscript. 🦋")
    XCTAssertEqual(reopened.state.importedFiles?[first.id]?.originalDigest, Digest.sha256(originals[0]))
    for (file, bytes) in zip([a, b], originals) {
      let document = try XCTUnwrap(imported.first { reopened.state.importedFiles?[$0.id]?.path == file.path })
      let actualRead2 = try await NativeCheckEvidence.readPublicOriginal(model: reopened, documentID: document.id)
      XCTAssertEqual(actualRead2, bytes)
    }
    try await reopened.shutdown()
    let backup = root.appendingPathComponent("explicit.bloombackup")
    try await store.exportBackup(to: backup)
    for file in [a, b] { try FileManager.default.removeItem(at: file) }
    let restoredStore = try WorkspaceStore(rootOverride: root.appendingPathComponent("restored"))
    try await restoredStore.restoreBackup(from: backup)
    let restored = try await WorkspaceModel(storeOverride: restoredStore, loadModels: false)
    let actualRead3 = try await NativeCheckEvidence.readPublicDocuments(model: restored)
    XCTAssertEqual(actualRead3, documents)
    for (file, bytes) in zip([a, b], originals) {
      let document = try XCTUnwrap(imported.first { restored.state.importedFiles?[$0.id]?.path == file.path })
      let actualRead4 = try await NativeCheckEvidence.readPublicOriginal(model: restored, documentID: document.id)
      XCTAssertEqual(actualRead4, bytes)
    }
    try await restored.shutdown()
  }

  @MainActor func testInvalidLaterImportKeepsEarlierPublishedSourceAndCancellationAddsNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-selected-invalid-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let good = root.appendingPathComponent("good.md"), bad = root.appendingPathComponent("bad.md")
    try Data("Keep this original.".utf8).write(to: good); try Data([0xff, 0xfe, 0xff]).write(to: bad)
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("workspace"))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    do { try await model.importDocuments([good, bad], flag: CancellationFlag()); XCTFail("Invalid UTF-8 was admitted") } catch {}
    let published = try await NativeCheckEvidence.readPublicDocuments(model: model)
    let retained = try XCTUnwrap(published.first { model.state.importedFiles?[$0.id]?.path == good.path })
    XCTAssertEqual(retained.text, "Keep this original.")
    XCTAssertFalse((model.state.importedFiles ?? [:]).values.contains { $0.path == bad.path })
    let before = model.documentIndices
    let cancelled = CancellationFlag(); cancelled.cancel()
    do { try await model.importDocuments([good], flag: cancelled); XCTFail("Cancelled import was admitted") } catch {}
    XCTAssertEqual(model.documentIndices, before)
    let actualRead5 = try await NativeCheckEvidence.readPublicOriginal(model: model, documentID: retained.id)
    XCTAssertEqual(actualRead5, Data(retained.text.utf8))
    try await model.shutdown()
    let actualRead6 = try await NativeCheckEvidence.readPublicDocuments(store: store)
    XCTAssertEqual(actualRead6, published)
  }

  func testFolderEnumerationKeepsUnicodeBytesSkipsOutsideLinksAndDoesNotWriteSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-folder-import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("chosen"), nested = source.appendingPathComponent("Drafts")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let bytes = Data("# 章\r\nCafé 👩‍💻\noriginal-import-canary".utf8), file = nested.appendingPathComponent("章.md")
    try bytes.write(to: file); try Data().write(to: source.appendingPathComponent("empty.txt"))
    let outside = root.appendingPathComponent("outside.md")
    try Data("outside-canary".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.md"), withDestinationURL: outside)
    let chosen = try FolderImport.chosenFiles(source, flag: CancellationFlag())
    XCTAssertEqual(chosen.map(\.path), ["Drafts/章.md", "empty.txt"])
    XCTAssertEqual(chosen.first?.url, file.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(chosen.first).url), bytes)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testPagedFolderEnumerationHasNoTextSizeLimitAndHonorsCancellation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-paged-folder-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let large = root.appendingPathComponent("large.md")
    XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
    let handle = try FileHandle(forWritingTo: large)
    // A sparse real file proves enumeration does not read, decode, or apply
    // the obsolete in-memory transport limit to paged source metadata.
    try handle.truncate(atOffset: 1_073_741_824); try handle.close()
    let chosen = try FolderImport.chosenFiles(root, flag: CancellationFlag())
    XCTAssertEqual(chosen.map(\.path), ["large.md"])
    XCTAssertEqual(try large.resourceValues(forKeys: [.fileSizeKey]).fileSize, 1_073_741_824)
    let cancelled = CancellationFlag(); cancelled.cancel()
    XCTAssertThrowsError(try FolderImport.chosenFiles(root, flag: cancelled))
    let linkedRoot = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
    XCTAssertThrowsError(try FolderImport.chosenFiles(linkedRoot, flag: CancellationFlag()))
  }
}
