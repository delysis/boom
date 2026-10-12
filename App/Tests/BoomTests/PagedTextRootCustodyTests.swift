import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY: actual SQL/custody controls remain unparsed/uncompiled/unrun.

private struct PagedRootCustodyFixture: Sendable {
  let root: URL
  let vault: Vault
  let engine: PagedTextEngineAdapter
  let ownerID: UUID
  let storeID: UUID
  let sqlIdentity: PagedSQLPublicControlIdentity
  let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
  let publisher: PagedWorkspacePublisher?
  let snapshot: PagedWorkspaceSnapshot?
}

/// Component controls only. Every source, history and acknowledgement comes
/// from the actual Rust engine, routed AEAD provider and coherent publisher.
/// The scheduling gate never supplies text or a durable acknowledgement.
@MainActor final class PagedTextRootCustodyTests: XCTestCase {
  private enum ControlError: Error { case expectedRefusal, schedulingDeadline }
  private struct CipherWitness: Sendable {
    let fixture: PagedRootCustodyFixture
    let value: PagedSQLPublicCiphertextWitness
    let lease: PagedTextRootLease
    let mutation: PagedSQLPublicMutationReceipt
    let mutationLease: PagedTextRootLease
  }
  /// Exact public opening and original errors remain strongly owned after any
  /// refused setup/body. No cleanup retry, alternate connection or fake finish.
  private static var retainedRoot: URL?
  private static var retainedOpening: PagedTextEngineAdapter?
  private static var retainedFixture: PagedRootCustodyFixture?
  private static var retainedSuccessor: PagedTextEngineAdapter?
  private static var originalFailure: Error?
  private static var actuallyClosedCurrent: PagedTextEngineAdapter?
  private static var retainedCiphertext: PagedTextCustodiedValue<PagedSQLPublicCiphertextWitness>?

  private struct PublicFileFailure: Error {
    let original: Error
    let closeError: Error
    let handle: FileHandle
  }

  private func withFixture(native: Bool = false,
    _ body: @MainActor (PagedRootCustodyFixture) async throws -> Void) async throws {
    guard Self.retainedRoot == nil, Self.retainedOpening == nil,
      Self.retainedFixture == nil, Self.retainedSuccessor == nil,
      Self.originalFailure == nil, Self.actuallyClosedCurrent == nil, Self.retainedCiphertext == nil else {
      throw BoomError.denied("An earlier failed actual SQL custody owner still owns this process.")
    }
    let initialFailures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-paged-custody-" + UUID().uuidString)
    Self.retainedRoot = root
    print("Public SQL custody fixture: \(root.path)")
    do {
      let opened = try await Task.detached {
        let owner = UUID(), storeID = UUID()
        let vault = try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x3c, count: 32)))
        let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner,
          sqliteOpening: .fresh(storeID: storeID))
        return (owner: owner, storeID: storeID, vault: vault, engine: engine)
      }.value
      Self.retainedOpening = opened.engine
      let identity = try await opened.engine._publicSQLControlIdentity(expectedVault: opened.vault, expectedStoreID: opened.storeID)
      let fixture = try await Task.detached {
        let engine = opened.engine, input = root.appendingPathComponent("public-input.utf8")
        guard FileManager.default.createFile(atPath: input.path, contents: nil) else {
          throw BoomError.invalid("Could not create the owned public custody input.")
        }
        let writer = try FileHandle(forWritingTo: input)
        var writerCloseAttempted = false
        do {
          if native { try writer.write(contentsOf: Data("banana café\npublic source\n".utf8)) }
          else {
            let block = Data(repeating: 0x61, count: 65_536)
            for _ in 0..<4 { try writer.write(contentsOf: block) }
          }
          try writer.synchronize(); writerCloseAttempted = true
          do { try writer.close() }
          catch { throw PublicFileFailure(original: error, closeError: error, handle: writer) }
        } catch {
          let original = error
          if !writerCloseAttempted {
            writerCloseAttempted = true
            do { try writer.close() }
            catch { throw PublicFileFailure(original: original, closeError: error, handle: writer) }
          }
          throw original
        }
        let reader = try FileHandle(forReadingFrom: input)
        let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
        do { imported = try await engine.importUTF8Retaining(documentID: UUID(), from: reader) }
        catch {
          let original = error
          do { try reader.close() }
          catch { throw PublicFileFailure(original: original, closeError: error, handle: reader) }
          throw original
        }
        do { try reader.close() }
        catch { throw PagedTextCustodyFailure(original: PublicFileFailure(original: error, closeError: error, handle: reader), lease: imported.lease) }
        guard native else {
          return PagedRootCustodyFixture(root: root, vault: opened.vault, engine: engine, ownerID: opened.owner,
            storeID: opened.storeID, sqlIdentity: identity, imported: imported, publisher: nil, snapshot: nil)
        }
        let publisher = try await engine.makeWorkspacePublisher()
        let document = PagedDocumentDescriptor(id: imported.value.revision.documentID,
          title: "Public café", revision: imported.value.revision)
        let record = try await engine.initialNativeRecordRetaining(document)
        var state = WorkspaceState()
        state.documents = [DocumentIndex(id: document.id, title: document.title)]
        state.selectedDocument = document.id; state.writingExampleIDs = [document.id]
        state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .document, id: document.id),
          text: "public unsent input", attachments: [], authoredRole: nil)]
        let workspace = try await engine.initializeWorkspaceRetaining(publisher, state: state, documents: [record.value])
        try await engine.finishWorkspacePublication(workspace, publisher: publisher)
        try await engine.transferJoinedRootToHead(imported.lease, publisher: publisher, expected: record.value)
        try await engine.transferJoinedRootToHead(record.lease, publisher: publisher, expected: record.value)
        try await engine.abandonJoinedRootOutput(workspace.lease)
        return PagedRootCustodyFixture(root: root, vault: opened.vault, engine: engine, ownerID: opened.owner,
          storeID: opened.storeID, sqlIdentity: identity, imported: imported, publisher: publisher, snapshot: workspace.value)
      }.value
      Self.retainedFixture = fixture
      try await body(fixture)
      guard (testRun?.failureCount ?? 0) == initialFailures else {
        throw BoomError.invalid("Public custody assertions failed; exact files/owners retained.")
      }
      if Self.actuallyClosedCurrent !== fixture.engine {
        // The known import read/writer is explicitly done after this body. A
        // native fixture already transferred it to the real authenticated head.
        if fixture.engine.custodySnapshot.items.contains(where: { $0.id == fixture.imported.lease.id }) {
          try await fixture.engine.abandonJoinedRootOutput(fixture.imported.lease)
        }
        let maintenance = PagedSQLNativeFixtureMaintenance(engine: fixture.engine)
        try await maintenance.drainAfterJoinedNativeCalls()
        try await fixture.engine.close()
        Self.actuallyClosedCurrent = fixture.engine // Only after its actual awaited successful close.
      }
      let root = fixture.root
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      Self.retainedFixture = nil; Self.retainedOpening = nil; Self.retainedRoot = nil
      Self.actuallyClosedCurrent = nil
    } catch {
      if Self.originalFailure == nil { Self.originalFailure = error }
      // Body-owned scheduling tasks join in their existing catch scopes. No
      // publication, maintenance, descriptor close, detach or Engine retry here.
      XCTFail("Public SQL custody failure and actual opening/error retained at \(root.path): \(error)")
      throw error
    }
  }

  private func refusal(_ action: () async throws -> Void) async throws -> Error {
    do { try await action() }
    catch { return error }
    XCTFail("The real root-custody boundary unexpectedly admitted the control.")
    throw ControlError.expectedRefusal
  }
  private func native(_ fixture: PagedRootCustodyFixture) async throws
    -> (PagedNativeStorageBackend, PagedWorkingWindow, PagedWorkspaceSnapshot) {
    let publisher = try XCTUnwrap(fixture.publisher), snapshot = try XCTUnwrap(fixture.snapshot)
    let record = try XCTUnwrap(snapshot.documents.first)
    let backend = try await fixture.engine.makeNativeStorage(publisher, expected: record)
    let window = try await backend.window(expected: record.document.revision, utf16Anchor: 0,
      maximumBytes: PagedWorkingWindow.targetBytes)
    return (backend, try PagedWorkingWindow(window: window, rootRecord: record), snapshot)
  }
  private func edit(_ backend: PagedNativeStorageBackend, working: inout PagedWorkingWindow,
    engine: PagedTextEngineAdapter, groupID: UUID, replacement: String = "B") async throws -> PagedNativeCommitAcknowledgement {
    guard try working.replace(NSRange(location: 0, length: 1), with: replacement, groupID: groupID) else {
      throw BoomError.invalid("The public custody edit must change actual native bytes.")
    }
    let batch = try XCTUnwrap(working.takeCommitBatch())
    let route: any PagedNativeCommitInstallationStorage = backend
    let acknowledgement = try await route.commit(batch)
    // The controller must retain its before-source until this actual consumer
    // acknowledges. No actor callback is a substitute for native installation.
    let pending = try XCTUnwrap(engine.custodySnapshot.items.first { $0.phase == .liveController })
    XCTAssertEqual(pending.pendingBatchID, batch.batchID)
    XCTAssertTrue(pending.claims.contains(.record(batch.expectedRootRecord)))
    XCTAssertTrue(pending.claims.contains(.record(acknowledgement.sealedRootRecord)))
    XCTAssertTrue(pending.claims.contains(.writerDocument(batch.expected.revision.documentID)))
    XCTAssertTrue(pending.claims.contains(.workspace))
    let earlyDetach = try await refusal {
      try await backend.detachJoinedController(sessionID: acknowledgement.sessionID,
        sequence: acknowledgement.lastSequence, record: acknowledgement.sealedRootRecord)
    }
    guard case BoomError.stale = earlyDetach else { throw earlyDetach }
    XCTAssertEqual(engine.custodySnapshot.items.first { $0.phase == .liveController }?.pendingBatchID, batch.batchID)
    let beforeFinish = try await engine.stats()
    try working.acknowledge(acknowledgement)
    try await route.finishCommitInstallation(acknowledgement)
    // An explicit lost-reply completion joins only this same current ACK.
    try await route.finishCommitInstallation(acknowledgement)
    let afterFinish = try await engine.stats()
    XCTAssertEqual(afterFinish.pageWrites, beforeFinish.pageWrites)
    XCTAssertEqual(afterFinish.pageReads, beforeFinish.pageReads)
    XCTAssertNil(engine.custodySnapshot.items.first { $0.phase == .liveController }?.pendingBatchID)
    return acknowledgement
  }
  private func command(working: PagedWorkingWindow, groupID: UUID) -> PagedNativeHistoryMoveCommand {
    PagedNativeHistoryMoveCommand(sessionID: working.sessionID, commandID: UUID(),
      sourceArenaID: working.arenaID, sourceWindowID: working.sealedWindow.windowID,
      expectedSequence: working.sealedGeneration, expectedRootRecord: working.sealedRootRecord,
      handle: PagedNativeHistoryHandle(documentID: working.sealedRootRecord.document.id,
        groupID: groupID, direction: .undo))
  }
  private func admission(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeHistoryAdmission {
    let command = prepared.command
    return PagedNativeHistoryAdmission(commandID: command.commandID, preparationID: prepared.preparationID,
      sessionID: command.sessionID, sourceArenaID: command.sourceArenaID, provisionalArenaID: UUID(),
      sourceWindowID: command.sourceWindowID, preparedWindowID: prepared.window.windowID,
      expectedSequence: command.expectedSequence, admittedSequence: try command.nextSequence(),
      expectedRootRecord: command.expectedRootRecord)
  }
  private func corrupt(_ fixture: PagedRootCustodyFixture,
    prepared: PagedNativePreparedHistoryMove) async throws -> CipherWitness {
    guard Self.retainedCiphertext == nil else { throw BoomError.stale("An earlier actual ciphertext witness still owns its producing lease.") }
    let witness = try await fixture.engine._publicSQLControlCiphertextWitnessRetaining(identity: fixture.sqlIdentity,
      record: prepared.candidateRecord, target: .historyManifest)
    Self.retainedCiphertext = witness // BEFORE mutation: keep the real producer through refusal/restoration.
    let changed = try await fixture.engine._publicSQLControlCorruptRetaining(identity: fixture.sqlIdentity, witness: witness.value)
    // The SAME live known-success corruption Entry supplies restoration
    // provenance. It remains pinned together with the original ciphertext;
    // no durable receipt survives an early producer release.
    return CipherWitness(fixture: fixture, value: witness.value, lease: witness.lease,
      mutation: changed.value, mutationLease: changed.lease)
  }
  private func restore(_ witness: CipherWitness) async throws {
    guard let held = Self.retainedCiphertext, held.value === witness.value, held.lease == witness.lease else {
      throw BoomError.stale("Restoration lost the exact actual ciphertext receiving owner.")
    }
    let restored = try await witness.fixture.engine._publicSQLControlRestoreRetaining(identity: witness.fixture.sqlIdentity,
      witness: witness.value)
    guard case .restoration = restored.value.mutation,
      restored.value.witnessID == witness.value.id, restored.value.record == witness.value.record else {
      throw BoomError.invalid("Actual SQL custody restoration has another witnessed record.")
    }
    try await witness.fixture.engine.abandonJoinedRootOutput(restored.lease)
    try await witness.fixture.engine.abandonJoinedRootOutput(witness.mutationLease)
    try await witness.fixture.engine.abandonJoinedRootOutput(witness.lease)
    Self.retainedCiphertext = nil // Only after actual restoration and both explicit releases return.
    // Known-success public mutation restoration never clears an independently
    // failed source-COMMIT fence or manufactures a verified-not-published permit.
  }

  func testQueuedInputPinsBeforeActualReadAndOutputPrecedesProducerAccounting() async throws {
    try await withFixture { fixture in
      let engine = fixture.engine, revision = fixture.imported.value.revision
      let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
      let gate = Task.detached { try await engine._rootCustodyControlBarrier(entered: entered, release: release) }
      var read: Task<PagedTextCustodiedValue<PagedTextWindow>, Error>?
      var delivered: PagedTextCustodiedValue<PagedTextWindow>?
      do {
        try await Task.detached {
          guard entered.wait(timeout: .now() + .seconds(1)) == .success else { throw ControlError.schedulingDeadline }
        }.value
        read = Task { try await engine.windowRetaining(revision, byteStart: 0, maximumBytes: 64) }
        let deadline = ContinuousClock.now + .seconds(1)
        var observed = false
        while ContinuousClock.now < deadline {
          if engine.custodySnapshot.items.contains(where: {
            $0.phase == .admitted && $0.claims == [.source(revision)] && !$0.producerJoined
          }) { observed = true; break }
          await Task.yield()
        }
        XCTAssertTrue(observed, "Actual queued input must be pinned before its real Rust read can start.")
        release.signal()
        delivered = try await XCTUnwrap(read).value
        try await gate.value
        let output = try XCTUnwrap(delivered)
        let pin = try XCTUnwrap(engine.custodySnapshot.items.first { $0.id == output.lease.id })
        XCTAssertTrue(pin.producerJoined); XCTAssertEqual(pin.phase, .output)
        XCTAssertEqual(pin.claims, [.source(revision)])
        XCTAssertGreaterThan(try XCTUnwrap(pin.outputInFlightWitness), 0)
        XCTAssertEqual(output.value.text, String(repeating: "a", count: 64))
        try await engine.abandonJoinedRootOutput(output.lease); delivered = nil
      } catch {
        let original = error; release.signal()
        if let read, delivered == nil {
          do { delivered = try await read.value } catch { /* real failed prefix remains in ledger/receipt */ }
        }
        do { try await gate.value } catch { XCTFail("Public scheduling owner joined with failure: \(error)") }
        if let delivered { try await engine.abandonJoinedRootOutput(delivered.lease) }
        throw original
      }
    }
  }

  func testUnclaimedImportPreventsCloseAndOldLeaseCannotCrossEngineIncarnation() async throws {
    try await withFixture { fixture in
      let old = fixture.imported.lease
      let item = try XCTUnwrap(fixture.engine.custodySnapshot.items.first { $0.id == old.id })
      XCTAssertTrue(item.producerJoined); XCTAssertGreaterThan(try XCTUnwrap(item.outputInFlightWitness), 0)
      XCTAssertTrue(item.claims.contains(.source(fixture.imported.value.revision)))
      _ = try await self.refusal { try await fixture.engine.close() }
      XCTAssertTrue(fixture.engine.custodySnapshot.closing)
      XCTAssertTrue(fixture.engine.custodySnapshot.items.contains { $0.id == old.id })
      try await fixture.engine.abandonJoinedRootOutput(old)
      try await fixture.engine.close()
      Self.actuallyClosedCurrent = fixture.engine // Actual returned close, never inferred from a closing Boolean.
      let successor = try await PagedTextEngineAdapter.create(vault: fixture.vault, ownerID: fixture.ownerID,
        sqliteOpening: .existing(storeID: fixture.storeID))
      Self.retainedSuccessor = successor
      do {
        XCTAssertNotEqual(successor.custodyIncarnation, old.engineIncarnation)
        let error = try await self.refusal { try await successor.abandonJoinedRootOutput(old) }
        guard case BoomError.denied = error else { throw error }
        XCTAssertTrue(successor.custodySnapshot.items.isEmpty)
        try await successor.close()
        Self.retainedSuccessor = nil
      } catch {
        // The exact successor remains held; failed close is not retried.
        throw error
      }
    }
  }

  func testForeignOwnerAndSelfTransferFailWithoutReadingOrDroppingActualRoot() async throws {
    try await withFixture { fixture in
      let revision = fixture.imported.value.revision, before = try await fixture.engine.stats()
      let foreign = PagedTextRevision(schema: revision.schema, ownerID: UUID(), documentID: revision.documentID, root: revision.root)
      let foreignError = try await self.refusal { _ = try await fixture.engine.windowRetaining(foreign, byteStart: 0, maximumBytes: 64) }
      guard case BoomError.denied = foreignError else { throw foreignError }
      let after = try await fixture.engine.stats()
      XCTAssertEqual(after.pageReads, before.pageReads); XCTAssertEqual(after.pageWrites, before.pageWrites)
      _ = try await self.refusal { try fixture.engine.absorbJoinedCustody(fixture.imported.lease, into: fixture.imported.lease) }
      XCTAssertTrue(fixture.engine.custodySnapshot.items.contains { $0.id == fixture.imported.lease.id })
    }
  }

  func testEntryBoundRefusesSpliceBeforeAnyEncryptedPageMutation() async throws {
    try await withFixture { fixture in
      var outputs: [PagedTextRootLease] = []
      var firstWindowID: UUID?
      for _ in 1..<PagedTextRootCustody.maximumEntries {
        let output = try await fixture.engine.windowRetaining(fixture.imported.value.revision, byteStart: 0, maximumBytes: 1)
        outputs.append(output.lease)
        if firstWindowID == nil { firstWindowID = output.value.windowID }
      }
      XCTAssertEqual(fixture.engine.custodySnapshot.items.count, PagedTextRootCustody.maximumEntries)
      let before = try await fixture.engine.stats()
      let edit = PagedTextLocalEdit(revision: fixture.imported.value.revision,
        windowID: try XCTUnwrap(firstWindowID), byteStart: 0, byteEnd: 1,
        oldBytes: Data([0x61]), newBytes: Data([0x62]))
      let error = try await self.refusal { _ = try await fixture.engine.spliceRetaining(edit) }
      guard case BoomError.budget = error else { throw error }
      let after = try await fixture.engine.stats()
      XCTAssertEqual(after.pageWrites, before.pageWrites); XCTAssertEqual(after.pageReads, before.pageReads)
      for lease in outputs { try await fixture.engine.abandonJoinedRootOutput(lease) }
      outputs.removeAll()
      let actual = try await fixture.engine.windowRetaining(fixture.imported.value.revision, byteStart: 0, maximumBytes: 1)
      XCTAssertEqual(actual.value.text, "a")
      try await fixture.engine.abandonJoinedRootOutput(actual.lease)
    }
  }

  func testPayloadBoundRefusesAnotherWindowBeforeActualRead() async throws {
    try await withFixture { fixture in
      var outputs: [PagedTextRootLease] = []
      for _ in 0..<(PagedTextRootCustody.maximumPayloadBytes / PagedTextWindow.maximumBytes) {
        let output = try await fixture.engine.windowRetaining(fixture.imported.value.revision,
          byteStart: 0, maximumBytes: PagedTextWindow.maximumBytes)
        outputs.append(output.lease)
      }
      XCTAssertEqual(fixture.engine.custodySnapshot.reservedPayloadBytes, PagedTextRootCustody.maximumPayloadBytes)
      let before = try await fixture.engine.stats()
      let error = try await self.refusal {
        _ = try await fixture.engine.windowRetaining(fixture.imported.value.revision, byteStart: 0, maximumBytes: 1)
      }
      guard case BoomError.budget = error else { throw error }
      let after = try await fixture.engine.stats()
      XCTAssertEqual(after.pageReads, before.pageReads)
      for lease in outputs { try await fixture.engine.abandonJoinedRootOutput(lease) }
    }
  }

  func testRealNativeCommitTransfersOnlyToExactControllerAndRetainsWorkspacePayload() async throws {
    try await withFixture(native: true) { fixture in
      let (backend, initial, snapshot) = try await self.native(fixture)
      var working = initial
      let registered = try XCTUnwrap(fixture.engine.custodySnapshot.items.first)
      XCTAssertEqual(registered.phase, .liveController)
      XCTAssertGreaterThan(try XCTUnwrap(registered.outputInFlightWitness), 0)
      let acknowledgement = try await self.edit(backend, working: &working, engine: fixture.engine, groupID: UUID())
      let items = fixture.engine.custodySnapshot.items
      XCTAssertEqual(items.count, 1)
      XCTAssertEqual(items.first?.claims, [.record(acknowledgement.sealedRootRecord)])
      XCTAssertEqual(items.first?.controllerSessionID, working.sessionID)
      XCTAssertEqual(items.first?.controllerSequence, acknowledgement.lastSequence)
      let actual = try await fixture.engine.loadWorkspaceRetaining(try XCTUnwrap(fixture.publisher))
      XCTAssertEqual(actual.value.head.workspace, snapshot.head.workspace)
      XCTAssertEqual(actual.value.documents.first, acknowledgement.sealedRootRecord)
      try await fixture.engine.abandonJoinedRootOutput(actual.lease)
      let successor = try await self.edit(backend, working: &working, engine: fixture.engine,
        groupID: UUID(), replacement: "C")
      let stale = try await self.refusal { try await backend.finishCommitInstallation(acknowledgement) }
      guard case BoomError.stale = stale else { throw stale }
      XCTAssertEqual(fixture.engine.custodySnapshot.items.first?.claims, [.record(successor.sealedRootRecord)])
      try await backend.detachJoinedController(sessionID: working.sessionID, sequence: working.sealedGeneration,
        record: working.sealedRootRecord)
      XCTAssertTrue(fixture.engine.custodySnapshot.items.isEmpty)
    }
  }

  func testControllerBoundRefusesFreshOwnerBeforeStorageAdmission() async throws {
    try await withFixture(native: true) { fixture in
      let publisher = try XCTUnwrap(fixture.publisher)
      let record = try XCTUnwrap(fixture.snapshot?.documents.first)
      var owners: [PagedNativeStorageBackend] = []
      for _ in 0..<PagedTextRootCustody.maximumControllers {
        owners.append(try await fixture.engine.makeNativeStorage(publisher, expected: record))
      }
      let before = try await fixture.engine.stats()
      let refusal = try await self.refusal { _ = try await fixture.engine.makeNativeStorage(publisher, expected: record) }
      guard case BoomError.unavailable = refusal else { throw refusal }
      let after = try await fixture.engine.stats()
      XCTAssertEqual(after.pageReads, before.pageReads); XCTAssertEqual(after.pageWrites, before.pageWrites)
      XCTAssertEqual(fixture.engine.custodySnapshot.items.count, PagedTextRootCustody.maximumControllers)
      for owner in owners {
        try await owner.detachJoinedController(sessionID: nil, sequence: 0, record: record)
      }
      XCTAssertTrue(fixture.engine.custodySnapshot.items.isEmpty)
    }
  }

  func testPreparedHistoryTransferRequiresActualReceivingIntentBeforeSenderRelease() async throws {
    try await withFixture(native: true) { fixture in
      let (backend, initial, _) = try await self.native(fixture)
      var working = initial; let groupID = UUID()
      _ = try await self.edit(backend, working: &working, engine: fixture.engine, groupID: groupID)
      let prepared = try await backend.prepareHistoryMove(self.command(working: working, groupID: groupID))
      let before = fixture.engine.custodySnapshot
      XCTAssertEqual(before.items.count, 2)
      let sender = try XCTUnwrap(before.items.first { $0.phase == .preparedHistory })
      XCTAssertTrue(sender.claims.contains(.record(prepared.command.expectedRootRecord)))
      XCTAssertTrue(sender.claims.contains(.record(prepared.candidateRecord)))
      XCTAssertGreaterThan(try XCTUnwrap(sender.outputInFlightWitness), 0)
      let error = try await self.refusal {
        _ = try await backend.resolveUnadmittedHistory(prepared, disposition: .transferredToRetainedOwner(receiptID: UUID()))
      }
      guard case BoomError.denied = error else { throw error }
      let stillPending = await backend.historyReachability()
      XCTAssertNotNil(stillPending)
      // The receiver's admission must fail BEFORE the sender can be removed.
      // Fill remaining entries with real one-byte engine window outputs.
      var heldReads: [PagedTextRootLease] = []
      for _ in before.items.count..<PagedTextRootCustody.maximumEntries {
        let read = try await fixture.engine.windowRetaining(working.sealedRootRecord.document.revision,
          byteStart: 0, maximumBytes: 1)
        heldReads.append(read.lease)
      }
      let full = try await self.refusal { _ = try fixture.engine.retainNativeHistoryIntent(prepared) }
      guard case BoomError.budget = full else { throw full }
      XCTAssertTrue(fixture.engine.custodySnapshot.items.contains { $0.id == sender.id })
      for lease in heldReads { try await fixture.engine.abandonJoinedRootOutput(lease) }
      let receiver = try fixture.engine.retainNativeHistoryIntent(prepared)
      XCTAssertEqual(fixture.engine.custodySnapshot.items.count, 3)
      _ = try await backend.resolveUnadmittedHistory(prepared,
        disposition: .transferredToRetainedOwner(receiptID: receiver.receiptID))
      let resolved = await backend.historyReachability()
      XCTAssertNil(resolved)
      XCTAssertFalse(fixture.engine.custodySnapshot.items.contains { $0.id == sender.id })
      let held = try XCTUnwrap(fixture.engine.custodySnapshot.items.first { $0.id == receiver.lease.id })
      XCTAssertEqual(held.phase, .retainedHistory)
      XCTAssertTrue(held.claims.contains(.record(prepared.candidateRecord)))
      try fixture.engine.releaseRetainedHistoryIntent(receiver)
      try await backend.detachJoinedController(sessionID: working.sessionID, sequence: working.sealedGeneration,
        record: working.sealedRootRecord)
    }
  }

  func testFailedAdmittedEncryptedHistoryStaysPinnedThroughRealInspectionAndInstallation() async throws {
    try await withFixture(native: true) { fixture in
      let (backend, initial, _) = try await self.native(fixture)
      var working = initial; let groupID = UUID()
      _ = try await self.edit(backend, working: &working, engine: fixture.engine, groupID: groupID)
      let prepared = try await backend.prepareHistoryMove(self.command(working: working, groupID: groupID))
      let admission = try self.admission(prepared)
      let witness = try await self.corrupt(fixture, prepared: prepared)
      let error = try await self.refusal { _ = try await backend.commitPreparedHistory(prepared, admission: admission) }
      let failure = try XCTUnwrap(error as? PagedTextCustodyFailure)
      guard case CryptoKitError.authenticationFailure = pagedSQLUnderlyingRefusal(failure.original) else { throw failure.original }
      let unresolved = try XCTUnwrap(fixture.engine.custodySnapshot.items.first { $0.phase == .unresolved })
      let heldWitness = try XCTUnwrap(fixture.engine.custodySnapshot.items.first { $0.id == witness.lease.id })
      XCTAssertEqual(heldWitness.phase, .output); XCTAssertTrue(heldWitness.producerJoined)
      XCTAssertEqual(heldWitness.claims, [.record(prepared.candidateRecord)])
      let mutationOwner = try XCTUnwrap(fixture.engine.custodySnapshot.items.first { $0.id == witness.mutationLease.id })
      XCTAssertEqual(mutationOwner.sqlOperationID, witness.mutation.operationID)
      XCTAssertTrue(mutationOwner.producerJoined); XCTAssertEqual(mutationOwner.phase, .output)
      XCTAssertEqual(fixture.engine.custodySnapshot.items.count, 4) // Controller/intent PLUS actual witness/corruption producers.
      XCTAssertTrue(unresolved.claims.contains(.record(prepared.command.expectedRootRecord)))
      XCTAssertTrue(unresolved.claims.contains(.record(prepared.candidateRecord)))
      XCTAssertTrue(unresolved.publicationAttempted); XCTAssertTrue(unresolved.producerJoined)
      let capability = try fixture.engine.adoptUnclaimedRootOutput(unresolved.id)
      _ = try await self.refusal { try await fixture.engine.abandonJoinedRootOutput(capability) }
      let stillAdmitted = await backend.historyReachability()
      if case .admitted? = stillAdmitted?.phase {} else { XCTFail("The admitted failing history intent was not retained.") }
      try await self.restore(witness)
      let inspection = try await backend.inspectHistoryRecovery(prepared)
      guard case .verifiedNotPublished(let verificationID) = inspection else {
        throw BoomError.invalid("Restored real head must prove the exact before-record, not guess success.")
      }
      let acknowledgement = try await backend.completeVerifiedHistory(prepared, verificationID: verificationID)
      // The worker control consumes its actual durable bounded result; it does
      // not claim native provisional TextStorage/IME product acceptance.
      working = try PagedWorkingWindow(window: acknowledgement.sealedWindow,
        rootRecord: acknowledgement.sealedRootRecord, sessionID: acknowledgement.sessionID,
        generation: acknowledgement.admittedSequence)
      XCTAssertEqual(working.bytes, initial.bytes)
      XCTAssertEqual(fixture.engine.custodySnapshot.items.count, 2)
      try await backend.finishHistoryInstallation(prepared, admission: admission)
      let installed = fixture.engine.custodySnapshot.items
      XCTAssertEqual(installed.count, 1)
      XCTAssertEqual(installed.first?.claims, [.record(working.sealedRootRecord)])
      XCTAssertEqual(installed.first?.controllerSequence, working.sealedGeneration)
      try await backend.detachJoinedController(sessionID: working.sessionID, sequence: working.sealedGeneration,
        record: working.sealedRootRecord)
    }
  }
}

#endif
