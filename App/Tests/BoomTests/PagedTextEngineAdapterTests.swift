import BoomCore
import Foundation
import XCTest
@testable import Boom

@MainActor final class PagedFileEngineControlOutputs {
  private static var failedSeed: PagedFileEngineControlOutputs?
  let engine: PagedTextEngineAdapter
  let store: WorkspaceStore
  let root: URL
  private var leases: [PagedTextRootLease] = []
  private var closed = false
  init(engine: PagedTextEngineAdapter, store: WorkspaceStore) {
    self.engine = engine; self.store = store; root = store.root
  }
  func retain<T: Sendable>(_ output: PagedTextCustodiedValue<T>) -> T {
    leases.append(output.lease); return output.value
  }
  func imported(_ bytes: Data, documentID: UUID = UUID(),
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision> {
    let path = root.appendingPathComponent("public-input-" + UUID().uuidString)
    try bytes.write(to: path, options: .withoutOverwriting)
    let file = try FileHandle(forReadingFrom: path)
    let output: PagedTextCustodiedValue<PagedTextImportedRevision>
    do { output = try await engine.importUTF8Retaining(documentID: documentID, from: file, cancellation: cancellation) }
    catch {
      let original = error
      if let failed = error as? PagedTextCustodyFailure { leases.append(failed.lease) }
      do { try file.close() } catch { XCTFail("Input close also failed: \(error)") }
      throw original
    }
    _ = retain(output)
    XCTAssertEqual(try file.offset(), 0, "The engine must not move the caller's descriptor offset")
    try file.close()
    return output
  }
  func publish(_ output: PagedTextCustodiedValue<PagedTextImportedRevision>, title: String,
    publisher: PagedWorkspacePublisher) async throws -> PagedDocumentRootRecord {
    let initialized = try await engine.initialNativeRecordRetaining(PagedDocumentDescriptor(
      id: output.value.revision.documentID, title: title, revision: output.value.revision))
    _ = retain(initialized)
    let record = try await engine.publishInitialDocumentRetaining(publisher, imported: output, initialized: initialized)
    leases.removeAll { $0.id == output.lease.id || $0.id == initialized.lease.id }
    return record
  }
  func window(_ revision: PagedTextRevision, maximumBytes: Int = 65_536) async throws -> PagedTextWindow {
    retain(try await engine.windowRetaining(revision, byteStart: 0, maximumBytes: maximumBytes))
  }
  func close() async throws {
    guard !closed else { return }
    for lease in leases { try await engine.abandonJoinedRootOutput(lease) }
    leases.removeAll()
    try await engine.close()
    try await store.releaseExclusiveWorkspace()
    closed = true
  }
  static func seed(_ store: WorkspaceStore, documents: [DocumentSnapshot]) async throws {
    guard failedSeed == nil, documents.count <= 33,
      documents.allSatisfy({ $0.text.utf8.count <= PagedTextWindow.maximumBytes }) else {
      throw BoomError.budget("A public source fixture exceeds its explicit bound or retains an earlier failure.")
    }
    try await store.acquireExclusiveWorkspace()
    let identity = try await store.storageIdentity()
    let engine = try await PagedTextEngineAdapter.create(root: store.root, ownerID: identity.ownerID, storeID: identity.storeID)
    let output = PagedFileEngineControlOutputs(engine: engine, store: store)
    do {
      let publisher = try await engine.makeWorkspacePublisher()
      for document in documents {
        let imported = try await output.imported(Data(document.text.utf8), documentID: document.id)
        _ = try await output.publish(imported, title: document.title, publisher: publisher)
      }
      try await output.close()
    } catch { failedSeed = output; throw error }
  }
}

@MainActor final class PagedTextEngineAdapterTests: XCTestCase {
  private static var failedOutputs: PagedFileEngineControlOutputs?
  private func fixture(_ body: (PagedFileEngineControlOutputs) async throws -> Void) async throws {
    guard Self.failedOutputs == nil else { throw BoomError.denied("A failed public source fixture still owns this process.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-file-engine-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    try await store.acquireExclusiveWorkspace()
    let identity = try await store.storageIdentity()
    let engine = try await PagedTextEngineAdapter.create(root: store.root, ownerID: identity.ownerID, storeID: identity.storeID)
    let outputs = PagedFileEngineControlOutputs(engine: engine, store: store)
    let failures = testRun?.failureCount ?? 0
    do {
      try await body(outputs)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("File engine assertions failed.") }
      try await outputs.close()
      try FileManager.default.removeItem(at: store.root)
    } catch {
      if Self.failedOutputs == nil { Self.failedOutputs = outputs }
      print("Failed public file engine retained: \(store.root.path)")
      throw error
    }
  }

  func testStreamedUnicodeSpliceDurableReopenAndExactUndoRoot() async throws {
    try await fixture { outputs in
      let engine = outputs.engine, publisher = try await engine.makeWorkspacePublisher()
      let text = "Café 👩🏽‍💻\r\n" + String(repeating: "Cafe\u{301} public source\r\n", count: 8_000)
      let bytes = Data(text.utf8), imported = try await outputs.imported(bytes)
      XCTAssertEqual(imported.value.wholeTextSha256, Digest.sha256(bytes))
      let record = try await outputs.publish(imported, title: "Public", publisher: publisher)
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: record.document.id, title: record.document.title)]
      try await outputs.store.saveState(state)
      let window = try await outputs.window(record.document.revision)
      XCTAssertEqual(Data(window.text.utf8), Data(bytes.prefix(window.text.utf8.count)))
      XCTAssertLessThanOrEqual(window.text.utf8.count, 65_536)
      let edit = try PagedWindowCoordinates(window: window).edit(in: NSRange(location: 0, length: 4), replacement: "Cafe\u{301}")
      let changed = outputs.retain(try await engine.spliceRetaining(edit))
      let expected = Data(("Cafe\u{301}" + String(text.dropFirst(4))).utf8)
      let changedHash = try await engine.wholeTextSha256(changed)
      XCTAssertEqual(changedHash, Digest.sha256(expected))
      let undone = outputs.retain(try await engine.checkoutRetaining(changed, retained: record.document.revision))
      XCTAssertEqual(undone, record.document.revision)
      let originalHash = try await engine.wholeTextSha256(undone)
      XCTAssertEqual(originalHash, Digest.sha256(bytes))
      let identity = try await outputs.store.storageIdentity()
      try await outputs.close()
      try await outputs.store.acquireExclusiveWorkspace()
      let reopened = try await PagedTextEngineAdapter.create(root: outputs.root, ownerID: identity.ownerID, storeID: identity.storeID)
      let read = PagedFileEngineControlOutputs(engine: reopened, store: outputs.store)
      do {
        let opened = read.retain(try await reopened.openRetaining(changed))
        XCTAssertEqual(opened, changed)
        let target = outputs.root.appendingPathComponent("exported.utf8")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
        let file = try FileHandle(forWritingTo: target)
        do { try await reopened.export(opened, to: file) }
        catch { let original = error; do { try file.close() } catch { XCTFail("Output close also failed: \(error)") }; throw original }
        try file.close()
        XCTAssertEqual(try Data(contentsOf: target), expected)
        let nextPublisher = try await reopened.makeWorkspacePublisher()
        let saved = read.retain(try await reopened.currentDocumentRecordRetaining(nextPublisher, documentID: record.document.id))
        XCTAssertEqual(saved, record)
        try await read.close()
      } catch { Self.failedOutputs = read; throw error }
    }
  }

  func testDocumentRoutingSurvivesHandleEvictionAndForeignOwnerIsDenied() async throws {
    try await fixture { outputs in
      var revisions: [PagedTextRevision] = []
      for index in 0..<10 {
        revisions.append(try await outputs.imported(Data("public document \(index): Cafe\u{301} 🌿\r\n".utf8)).value.revision)
      }
      for (index, revision) in revisions.enumerated() {
        let window = try await outputs.window(revision)
        XCTAssertEqual(Data(window.text.utf8), Data("public document \(index): Cafe\u{301} 🌿\r\n".utf8))
      }
      let first = revisions[0], foreign = PagedTextRevision(schema: first.schema, ownerID: UUID(), documentID: first.documentID, root: first.root)
      do { _ = outputs.retain(try await outputs.engine.openRetaining(foreign)); XCTFail("Foreign owner was admitted") } catch {}
      do { _ = outputs.retain(try await outputs.engine.checkoutRetaining(first, retained: revisions[1])); XCTFail("Foreign document became Undo history") } catch {}
      let window = try await outputs.window(first)
      let wrong = PagedTextLocalEdit(revision: first, windowID: window.windowID, byteStart: 0, byteEnd: 6,
        oldBytes: Data("wrong!".utf8), newBytes: Data("x".utf8))
      do { _ = outputs.retain(try await outputs.engine.spliceRetaining(wrong)); XCTFail("Wrong captured bytes were admitted") } catch {}
      let actual = outputs.retain(try await outputs.engine.openRetaining(first))
      XCTAssertEqual(actual, first)
    }
  }

  func testCancelledAndMalformedImportsDoNotPublishAndCloseJoins() async throws {
    try await fixture { outputs in
      let cancelled = PagedTextCancellation(); cancelled.cancel()
      let cancelledID = UUID(), invalidID = UUID(), publisher = try await outputs.engine.makeWorkspacePublisher()
      do { _ = try await outputs.imported(Data("public input".utf8), documentID: cancelledID, cancellation: cancelled); XCTFail("Cancelled import was admitted") }
      catch { XCTAssertTrue(error is CancellationError) }
      do { _ = try await outputs.imported(Data(repeating: 0x61, count: 65_536) + Data([0xff]), documentID: invalidID); XCTFail("Invalid UTF8 was admitted") }
      catch { guard case BoomError.invalid = error else { throw error } }
      for id in [cancelledID, invalidID] {
        let root = outputs.root.appendingPathComponent("documents/" + id.uuidString.lowercased() + "/document-root.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        do { _ = outputs.retain(try await outputs.engine.currentDocumentRecordRetaining(publisher, documentID: id)); XCTFail("Unpublished document had a current root") }
        catch { guard case BoomError.stale = error else { throw error } }
      }
      XCTAssertEqual(outputs.engine.custodySnapshot.jobs, 0)
    }
  }
}
