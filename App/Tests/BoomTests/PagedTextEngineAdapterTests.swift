import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY: actual fresh/existing system-SQLite/native worker controls.
// No execution or encrypted component qualification is implied by source ports.

@MainActor private final class PagedSQLEngineControlOutputs {
  let engine: PagedTextEngineAdapter
  let identity: PagedSQLPublicControlIdentity
  private var leases: [PagedTextRootLease] = []
  private var source: FileHandle?
  private var destination: FileHandle?
  private var destinationCloseAttempted = false
  private var originalRefusals: [Error] = []
  private let maintenance: PagedSQLNativeFixtureMaintenance
  private(set) var inputOffset: UInt64?
  init(engine: PagedTextEngineAdapter, identity: PagedSQLPublicControlIdentity) {
    self.engine = engine; self.identity = identity
    maintenance = PagedSQLNativeFixtureMaintenance(engine: engine)
  }
  func admitOutput() throws {
    guard leases.count < 32 else { throw BoomError.budget("Public engine output custody exceeds32 real leases.") }
  }
  func retain<T: Sendable>(_ value: PagedTextCustodiedValue<T>) -> T {
    leases.append(value.lease); return value.value
  }
  func transfer(_ lease: PagedTextRootLease, publisher: PagedWorkspacePublisher,
    expected: PagedDocumentRootRecord) async throws {
    guard leases.contains(where: { $0.id == lease.id }) else { throw BoomError.denied("Actual public producer is not in this receiving owner.") }
    try await engine.transferJoinedRootToHead(lease, publisher: publisher, expected: expected)
    leases.removeAll { $0.id == lease.id }
  }
  func release(_ lease: PagedTextRootLease) async throws {
    guard leases.contains(where: { $0.id == lease.id }) else { throw BoomError.denied("Actual public read is not in this receiving owner.") }
    try await engine.abandonJoinedRootOutput(lease)
    leases.removeAll { $0.id == lease.id }
  }
  func observeRefusal(_ error: Error) throws {
    guard originalRefusals.count < 8 else { throw BoomError.budget("Actual original public refusal evidence exceeds8 records.") }
    originalRefusals.append(error)
  }
  func importBytes(_ bytes: Data, documentID: UUID, root: URL,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision> {
    guard source == nil else { throw BoomError.stale("A public source descriptor is already retained after refusal.") }
    try admitOutput()
    let file = try await Task.detached {
      let path = root.appendingPathComponent("public-input-" + UUID().uuidString)
      try bytes.write(to: path, options: .withoutOverwriting)
      return try FileHandle(forReadingFrom: path)
    }.value
    source = file
    let output: PagedTextCustodiedValue<PagedTextImportedRevision>
    do { output = try await engine.importUTF8Retaining(documentID: documentID, from: file, cancellation: cancellation) }
    catch {
      let original = error
      do { try await Task.detached { try file.close() }.value; source = nil }
      catch { try observeRefusal(error) } // Exact descriptor retained; no retry.
      throw original
    }
    _ = retain(output) // Root output is received BEFORE descriptor observation/close.
    inputOffset = try await Task.detached { try file.offset() }.value
    do { try await Task.detached { try file.close() }.value; source = nil }
    catch { throw PagedTextCustodyFailure(original: error, lease: output.lease) }
    return output
  }
  func window(_ revision: PagedTextRevision, byteStart: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    try admitOutput()
    return retain(try await engine.windowRetaining(revision, byteStart: byteStart, maximumBytes: maximumBytes))
  }
  func snapshot(_ publisher: PagedWorkspacePublisher) async throws -> PagedWorkspaceSnapshot {
    try admitOutput(); return retain(try await engine.loadWorkspaceRetaining(publisher))
  }
  func ownDestination(_ file: FileHandle) throws {
    guard destination == nil, !destinationCloseAttempted else { throw BoomError.stale("Actual public export descriptor already entered this receiving scope.") }
    destination = file
  }
  func finishDestination() async throws {
    guard let file = destination, !destinationCloseAttempted else { throw BoomError.stale("Public export close is absent or already attempted.") }
    destinationCloseAttempted = true
    try await Task.detached { try file.close() }.value
    destination = nil // Only after the actual descriptor close returns.
  }
  func closeAfterRealProducers() async throws {
    guard source == nil, destination == nil else { throw BoomError.stale("Actual source descriptor still owns this fixture.") }
    try await maintenance.drainAfterJoinedNativeCalls()
    guard engine.custodySnapshot.jobs == 0 else { throw BoomError.stale("Actual source/maintenance producer still owns this fixture.") }
    for lease in leases { try await engine.abandonJoinedRootOutput(lease) }
    leases.removeAll()
    try await engine.close()
  }
}

@MainActor final class PagedTextEngineAdapterTests: XCTestCase {
  private static var retainedRoot: URL?
  private static var retainedOpening: PagedTextEngineAdapter?
  private static var retainedOutputs: PagedSQLEngineControlOutputs?
  private static var originalFailure: Error?
  private static var retainedUnexpectedOpening: PagedTextEngineAdapter?
  private func workspace() async throws -> (URL, Vault, SymmetricKey, UUID, UUID) {
    guard Self.retainedRoot == nil, Self.retainedOpening == nil,
      Self.retainedOutputs == nil, Self.originalFailure == nil, Self.retainedUnexpectedOpening == nil else { throw BoomError.denied("An earlier failed public engine still owns this process.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-paged-engine-" + UUID().uuidString)
    Self.retainedRoot = root
    print("Public SQL engine fixture: \(root.path)")
    let key = SymmetricKey(data: Data(repeating: 0x53, count: 32)), owner = UUID(), storeID = UUID()
    let vault = try await Task.detached { try Vault(root: root, testKey: key) }.value
    return (root, vault, key, owner, storeID)
  }
  private func withEngine(root: URL, vault: Vault, owner: UUID, storeID: UUID, opening: PagedSQLiteStore.Opening,
    _ body: @MainActor (PagedSQLEngineControlOutputs) async throws -> Void) async throws {
    guard Self.retainedOpening == nil, Self.retainedOutputs == nil, Self.originalFailure == nil,
      Self.retainedUnexpectedOpening == nil else { throw BoomError.denied("An actual earlier opening remains retained.") }
    Self.retainedRoot = root
    let failures = testRun?.failureCount ?? 0
    do {
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: opening)
      Self.retainedOpening = engine
      let identity = try await engine._publicSQLControlIdentity(expectedVault: vault, expectedStoreID: storeID)
      let outputs = PagedSQLEngineControlOutputs(engine: engine, identity: identity)
      Self.retainedOutputs = outputs
      try await body(outputs)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual public engine assertions failed; evidence retained.") }
      try await outputs.closeAfterRealProducers()
      Self.retainedOutputs = nil; Self.retainedOpening = nil; Self.retainedRoot = nil
    } catch {
      if Self.originalFailure == nil { Self.originalFailure = error }
      // No new publication, failed output disposition, maintenance or close
      // retry. Original structured calls returned; exact failures stay owned.
      XCTFail("Public actual SQL engine failure retained at \(root.path): \(error)")
      throw error
    }
  }

  func testStreamedUnicodeSpliceDurableReopenAndExactUndoRoot() async throws {
    let (root, vault, key, owner, storeID) = try await workspace(), document = UUID()
    let text = "Café 👩🏽‍💻\r\n" + String(repeating: "Cafe\u{301} public source\r\n", count: 8_000)
    let bytes = Data(text.utf8)
    var saved: PagedTextRevision?
    try await withEngine(root: root, vault: vault, owner: owner, storeID: storeID, opening: .fresh(storeID: storeID)) { outputs in
      let engine = outputs.engine, publisher = try await engine.makeWorkspacePublisher()
      try outputs.admitOutput()
      let empty = try await engine.initializeWorkspaceRetaining(publisher, state: WorkspaceState(), documents: [])
      let initial = outputs.retain(empty)
      try await engine.finishWorkspacePublication(empty, publisher: publisher)
      XCTAssertTrue(initial.documents.isEmpty)
      let importedOutput = try await outputs.importBytes(bytes, documentID: document, root: root), imported = importedOutput.value
      XCTAssertEqual(imported.wholeTextSha256, Digest.sha256(bytes))
      XCTAssertEqual(outputs.inputOffset, 0, "Import must not move the caller's FileHandle offset")
      try outputs.admitOutput()
      let recordOutput = try await engine.initialNativeRecordRetaining(PagedDocumentDescriptor(id: document, title: "Public", revision: imported.revision))
      let record = outputs.retain(recordOutput)
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: document, title: "Public")]; state.selectedDocument = document
      try outputs.admitOutput()
      let firstOutput = try await engine.publishWorkspaceRetaining(publisher, state: state, documents: [record], expectedHead: initial.head)
      let first = outputs.retain(firstOutput)
      try await engine.finishWorkspacePublication(firstOutput, publisher: publisher)
      XCTAssertEqual(first.head.generation, 1)
      try await outputs.transfer(importedOutput.lease, publisher: publisher, expected: record)
      try await outputs.transfer(recordOutput.lease, publisher: publisher, expected: record)
      let window = try await outputs.window(imported.revision, byteStart: 0, maximumBytes: 65_536)
      XCTAssertEqual(Data(window.text.utf8), Data(bytes.prefix(window.text.utf8.count)))
      XCTAssertLessThanOrEqual(window.text.utf8.count, 65_536)
      let edit = try PagedWindowCoordinates(window: window).edit(in: NSRange(location: 0, length: 4), replacement: "Cafe\u{301}")
      try outputs.admitOutput()
      let changedOutput = try await engine.spliceRetaining(edit), changed = outputs.retain(changedOutput)
      let expected = Data(("Cafe\u{301}" + String(text.dropFirst(4))).utf8)
      let changedHash = try await engine.wholeTextSha256(changed)
      XCTAssertEqual(changedHash, Digest.sha256(expected))
      try outputs.admitOutput()
      let history = try await engine._publicSQLControlHistoryRetaining(identity: outputs.identity, record: record)
      var changedHistory = outputs.retain(history)
      try changedHistory.record(changed, cursor: PagedSealedCursor(byteOffset: 0, utf16Offset: 0), beforeCursor: changedHistory.currentCursor, groupID: UUID())
      try outputs.admitOutput()
      let changedRecordOutput = try await engine._publicSQLControlWriteHistoryRetaining(identity: outputs.identity,
        history: changedHistory, document: PagedDocumentDescriptor(id: document, title: "Public", revision: changed))
      let changedRecord = outputs.retain(changedRecordOutput)
      try outputs.admitOutput()
      let changedHeadOutput = try await engine.publishWorkspaceRetaining(publisher, state: state,
        documents: [changedRecord], expectedHead: first.head)
      let changedHead = outputs.retain(changedHeadOutput)
      try await engine.finishWorkspacePublication(changedHeadOutput, publisher: publisher)
      try await outputs.transfer(changedOutput.lease, publisher: publisher, expected: changedRecord)
      try await outputs.transfer(changedRecordOutput.lease, publisher: publisher, expected: changedRecord)
      // Generic component full-record CAS: accepted native failure custody is
      // covered separately by the retained-terminal real Backend case.
      do {
        let unexpected = try await engine._publicSQLControlPublishDocumentRetaining(identity: outputs.identity,
          publisher: publisher, after: changedRecord, expected: record)
        _ = outputs.retain(unexpected); XCTFail("A stale current-root CAS was admitted")
      } catch {
        try outputs.observeRefusal(error)
        guard case BoomError.stale = pagedSQLUnderlyingRefusal(error) else { throw error }
      }
      let unchanged = try await outputs.snapshot(publisher); XCTAssertEqual(unchanged, changedHead)
      // The real retained-root checkout returns its actual output directly.
      try outputs.admitOutput()
      let checkoutOutput = try await engine.checkoutRetaining(changed, retained: imported.revision)
      let undo = outputs.retain(checkoutOutput), checkoutLease = checkoutOutput.lease
      _ = try changedHistory.stepUndo(expected: changed)
      XCTAssertEqual(changedHistory.current, undo)
      try outputs.admitOutput()
      let undoRecordOutput = try await engine._publicSQLControlWriteHistoryRetaining(identity: outputs.identity,
        history: changedHistory, document: PagedDocumentDescriptor(id: document, title: "Public", revision: undo))
      let undoRecord = outputs.retain(undoRecordOutput)
      try outputs.admitOutput()
      let undoHeadOutput = try await engine.publishWorkspaceRetaining(publisher, state: state,
        documents: [undoRecord], expectedHead: changedHead.head)
      _ = outputs.retain(undoHeadOutput)
      try await engine.finishWorkspacePublication(undoHeadOutput, publisher: publisher)
      try await outputs.transfer(checkoutLease, publisher: publisher, expected: undoRecord)
      try await outputs.transfer(undoRecordOutput.lease, publisher: publisher, expected: undoRecord)
      saved = undo
      let stats = try await engine.stats()
      XCTAssertLessThanOrEqual(stats.chargedBytes, 8_388_608)
      XCTAssertLessThanOrEqual(stats.entries, 512)
      XCTAssertGreaterThan(stats.pageWrites, 0)
    }
    let revision = try XCTUnwrap(saved)
    let reopenedVault = try await Task.detached { try Vault(root: root, testKey: key) }.value
    try await withEngine(root: root, vault: reopenedVault, owner: owner, storeID: storeID, opening: .existing(storeID: storeID)) { outputs in
      let engine = outputs.engine, publisher = try await engine.makeWorkspacePublisher()
      let catalog = try await outputs.snapshot(publisher)
      XCTAssertEqual(catalog.documents.first?.document.revision, revision)
      let outputURL = root.appendingPathComponent("explicit-public-export")
      let output = try await Task.detached {
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw BoomError.invalid("Public export target already exists.") }
        return try FileHandle(forWritingTo: outputURL)
      }.value
      try outputs.ownDestination(output)
      do { try await engine.export(revision, to: output) }
      catch {
        let original = error
        do { try await outputs.finishDestination() } catch { try outputs.observeRefusal(error) }
        throw original
      }
      try await outputs.finishDestination()
      let exported = try await Task.detached { try Data(contentsOf: outputURL) }.value
      XCTAssertEqual(exported, bytes)
      let restoredHash = try await engine.wholeTextSha256(revision)
      XCTAssertEqual(restoredHash, Digest.sha256(bytes))
    }
    try await Task.detached { try FileManager.default.removeItem(at: root) }.value
  }

  func testDocumentRoutingSurvivesHandleEvictionAndForeignOwnerIsDenied() async throws {
    let (root, vault, _, owner, storeID) = try await workspace()
    try await withEngine(root: root, vault: vault, owner: owner, storeID: storeID, opening: .fresh(storeID: storeID)) { outputs in
      let engine = outputs.engine
      var revisions: [PagedTextRevision] = []
      for index in 0..<10 {
        let bytes = Data("public document \(index): Cafe\u{301} 🌿\r\n".utf8)
        let result = try await outputs.importBytes(bytes, documentID: UUID(), root: root)
        revisions.append(result.value.revision)
      }
      for (index, revision) in revisions.enumerated() {
        let window = try await outputs.window(revision, byteStart: 0, maximumBytes: PagedTextWindow.maximumBytes)
        XCTAssertEqual(Data(window.text.utf8), Data("public document \(index): Cafe\u{301} 🌿\r\n".utf8))
      }
      let first = revisions[0]
      let foreign = PagedTextRevision(schema: 1, ownerID: UUID(), documentID: first.documentID, root: first.root)
      try outputs.admitOutput()
      do { _ = outputs.retain(try await engine.openRetaining(foreign)); XCTFail("Another private owner was admitted") }
      catch { try outputs.observeRefusal(error); guard case BoomError.denied = pagedSQLUnderlyingRefusal(error) else { throw error } }
      do { try outputs.admitOutput(); _ = outputs.retain(try await engine.checkoutRetaining(first, retained: revisions[1])); XCTFail("Another document became Undo history") }
      catch { try outputs.observeRefusal(error); guard case BoomError.denied = pagedSQLUnderlyingRefusal(error) else { throw error } }
      let window = try await outputs.window(first, byteStart: 0, maximumBytes: PagedTextWindow.maximumBytes)
      let wrong = PagedTextLocalEdit(revision: first, windowID: window.windowID,
        byteStart: 0, byteEnd: 6, oldBytes: Data("wrong!".utf8), newBytes: Data("x".utf8))
      try outputs.admitOutput()
      do { _ = outputs.retain(try await engine.spliceRetaining(wrong)); XCTFail("Wrong captured old bytes were admitted") }
      catch { try outputs.observeRefusal(error); guard case BoomError.stale = pagedSQLUnderlyingRefusal(error) else { throw error } }
      try outputs.admitOutput()
      let opened = outputs.retain(try await engine.openRetaining(first))
      XCTAssertEqual(opened, first)
    }
    try await Task.detached { try FileManager.default.removeItem(at: root) }.value
  }

  func testCancelledAndMalformedImportsDoNotPublishAndCloseJoins() async throws {
    let (root, vault, key, owner, storeID) = try await workspace()
    var actuallyReturnedEngine: PagedTextEngineAdapter?
    try await withEngine(root: root, vault: vault, owner: owner, storeID: storeID, opening: .fresh(storeID: storeID)) { outputs in
      let engine = outputs.engine, publisher = try await engine.makeWorkspacePublisher()
      actuallyReturnedEngine = engine
      try outputs.admitOutput()
      let initialized = try await engine.initializeWorkspaceRetaining(publisher, state: WorkspaceState(), documents: [])
      _ = outputs.retain(initialized)
      try await engine.finishWorkspacePublication(initialized, publisher: publisher)
      let cancellation = PagedTextCancellation(); cancellation.cancel()
      do { _ = try await outputs.importBytes(Data("public input".utf8), documentID: UUID(), root: root, cancellation: cancellation); XCTFail("Cancelled import was admitted") }
      catch {
        try outputs.observeRefusal(error)
        guard pagedSQLUnderlyingRefusal(error) is CancellationError else { throw error }
      }
      let invalid = Data(repeating: 0x61, count: 65_536) + Data([0xff])
      do { _ = try await outputs.importBytes(invalid, documentID: UUID(), root: root); XCTFail("Invalid UTF8 sealed a revision") }
      catch {
        try outputs.observeRefusal(error)
        guard case BoomError.invalid = pagedSQLUnderlyingRefusal(error) else { throw error }
        if let actual = error as? PagedTextCustodyFailure {
          _ = try await engine.repairFailedSQLiteProducer(actual.lease, publisher: publisher)
        }
      }
      // Actual aborted C/cache/SQL work must join before the original nonpublication
      // and cold-opening oracles. Successful rollback is not a native ACK.
      let retainedCatalog = try await outputs.snapshot(publisher)
      XCTAssertTrue(retainedCatalog.documents.isEmpty)
      do {
        let unexpected = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner,
          sqliteOpening: .existing(storeID: storeID))
        Self.retainedUnexpectedOpening = unexpected // Preserve a genuine unexpected owner before failing.
        XCTFail("A second process cache was created")
        throw BoomError.invalid("Actual singleton admission unexpectedly returned another owner.")
      } catch {
        try outputs.observeRefusal(error)
        if Self.retainedUnexpectedOpening != nil { throw error }
      }
    }
    // Reached only after the actual generic failure disposition and close join.
    let closed = try XCTUnwrap(actuallyReturnedEngine)
    do { _ = try await closed.stats(); XCTFail("A closed callback context was used") }
    catch { /* The actual post-close refusal remains a separate oracle. */ }
    let reopenedVault = try await Task.detached { try Vault(root: root, testKey: key) }.value
    try await withEngine(root: root, vault: reopenedVault, owner: owner, storeID: storeID, opening: .existing(storeID: storeID)) { outputs in
      let stats = try await outputs.engine.stats(); XCTAssertEqual(stats.chargedBytes, 0)
    }
    try await Task.detached { try FileManager.default.removeItem(at: root) }.value
  }
}
#endif
