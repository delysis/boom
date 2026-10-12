import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY: actual SQL outcomes and receiving joins are exercised by these
// authored controls. No runtime or durability qualification is implied.

private struct PagedNativeHistoryWorkerFixture: Sendable {
  let root: URL
  let owner: UUID
  let outputs: PagedNativeHistoryWorkerOutputs
  let vault: Vault
  let engine: PagedTextEngineAdapter
  let publisher: PagedWorkspacePublisher
  let snapshot: PagedWorkspaceSnapshot
}

/// A worker-control input owner. It uses the real bounded delta planner,
/// ciphertext, Rust engine and publisher. It deliberately does not stand in
/// for ordinary product provisional Undo/IME input acceptance.
@MainActor private final class PagedNativeHistoryWorkerDriver {
  let backend: PagedNativeStorageBackend
  var working: PagedWorkingWindow
  init(backend: PagedNativeStorageBackend, window: PagedTextWindow,
    record: PagedDocumentRootRecord) throws {
    self.backend = backend; working = try PagedWorkingWindow(window: window, rootRecord: record)
  }
  @discardableResult
  func replace(_ range: NSRange, with text: String, groupID: UUID = UUID(),
    beforeCaretUTF16: Int? = nil) async throws -> PagedNativeCommitAcknowledgement {
    let selection = try beforeCaretUTF16.map { try working.selection(NSRange(location: $0, length: 0)) }
    guard try working.replace(range, with: text, groupID: groupID, beforeSelection: selection) else {
      throw BoomError.invalid("The public worker control requires a genuinely accepted edit.")
    }
    return try await sealPending()
  }
  func sealPending() async throws -> PagedNativeCommitAcknowledgement {
    let batch = try XCTUnwrap(working.takeCommitBatch())
    let acknowledgement = try await backend.commit(batch)
    try working.acknowledge(acknowledgement)
    try await backend.finishCommitInstallation(acknowledgement)
    return acknowledgement
  }
  func command(_ groupID: UUID, direction: PagedNativeHistoryHandle.Direction = .undo) -> PagedNativeHistoryMoveCommand {
    PagedNativeHistoryMoveCommand(sessionID: working.sessionID, commandID: UUID(),
      sourceArenaID: working.arenaID, sourceWindowID: working.sealedWindow.windowID,
      expectedSequence: working.sealedGeneration, expectedRootRecord: working.sealedRootRecord,
      handle: PagedNativeHistoryHandle(documentID: working.sealedRootRecord.document.id,
        groupID: groupID, direction: direction))
  }
  /// Test-only adoption after the durable result. No provisional input or
  /// NSTextStorage installation is claimed by this worker control.
  func adopt(_ acknowledgement: PagedNativeHistoryAcknowledgement) throws {
    working = try PagedWorkingWindow(window: acknowledgement.sealedWindow,
      rootRecord: acknowledgement.sealedRootRecord, sessionID: acknowledgement.sessionID,
      generation: acknowledgement.admittedSequence)
  }
}

/// Strong receiving owner for real structured worker calls and scalar reads.
/// Registry snapshots provide diagnostic identity arguments only; actual Backend
/// detach still verifies its own lifetime/session/sequence/full-record custody.
@MainActor private final class PagedNativeHistoryWorkerOutputs {
  let engine: PagedTextEngineAdapter
  let identity: PagedSQLPublicControlIdentity
  private var reads: [PagedTextRootLease] = []
  private var controllers: [(backend: PagedNativeStorageBackend, id: UUID)] = []
  private var receiving: [PagedNativeRetainedHistoryIntent] = []
  private let maintenance: PagedSQLNativeFixtureMaintenance
  private(set) var expectedTerminalSnapshot: PagedTextSQLMaintenanceSnapshot?
  init(engine: PagedTextEngineAdapter, identity: PagedSQLPublicControlIdentity) {
    self.engine = engine; self.identity = identity; maintenance = PagedSQLNativeFixtureMaintenance(engine: engine)
  }
  func admitRead() throws { guard reads.count < 32 else { throw BoomError.budget("Actual history worker read custody exceeds its fixed bound.") } }
  func retain(_ lease: PagedTextRootLease) { reads.append(lease) }
  func makeBackend(_ publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord) async throws -> PagedNativeStorageBackend {
    guard controllers.count < 4 else { throw BoomError.budget("Actual history worker fixture has four owned controllers.") }
    let before = Set(engine.custodySnapshot.items.map(\.id))
    let backend = try await engine.makeNativeStorage(publisher, expected: expected)
    let added = engine.custodySnapshot.items.filter {
      if case .controller = $0.purpose { return !before.contains($0.id) }; return false
    }
    guard added.count == 1 else { throw BoomError.invalid("Actual serialized controller factory has an unresolved identity inventory.") }
    controllers.append((backend, added[0].id)); return backend
  }
  func retainIntent(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeRetainedHistoryIntent {
    guard receiving.count < 8 else { throw BoomError.budget("Actual receiving history intent budget is full.") }
    let receipt = try engine.retainNativeHistoryIntent(prepared)
    receiving.append(receipt); return receipt
  }
  func closeJoined() async throws {
    // Structured Backend calls in these worker bodies have returned; this
    // metadata read is not a substitute for a native/physical callback join.
    try await maintenance.drainAfterJoinedNativeCalls()
    guard engine.custodySnapshot.jobs == 0 else { throw BoomError.stale("Actual history source job remains entered.") }
    for owner in controllers {
      let items = engine.custodySnapshot.items.filter { $0.id == owner.id }
      guard items.count == 1, items[0].phase == .liveController, items[0].producerJoined,
        !items[0].bulkActive, items[0].pendingBatchID == nil else { throw BoomError.stale("Actual worker controller still owns an unjoined source/ACK.") }
      let records = items[0].claims.compactMap { claim -> PagedDocumentRootRecord? in
        if case .record(let record) = claim { return record }; return nil
      }
      guard records.count == 1 else { throw BoomError.stale("Actual joined worker controller has unresolved before/after custody.") }
      try await owner.backend.detachJoinedController(sessionID: items[0].controllerSessionID,
        sequence: items[0].controllerSequence, record: records[0])
    }
    for receipt in receiving { try engine.releaseRetainedHistoryIntent(receipt) }
    receiving.removeAll()
    for read in reads { try await engine.abandonJoinedRootOutput(read) }
    reads.removeAll()
    try await engine.close()
  }
  func retainExpectedConflict() async throws {
    try await maintenance.drainAfterJoinedNativeCalls()
    guard engine.custodySnapshot.jobs == 0 else { throw BoomError.stale("The terminal conflict still owns a real source job.") }
    expectedTerminalSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
    // Retain the admitted conflicting command, both real roots, source/output
    // claims and receipts until the exact nominated disposable process exits.
  }
}

@MainActor final class PagedNativeHistoryCommandTests: XCTestCase {
  private enum Refusal { case stale, invalid, commandConflict, authentication }
  private struct CipherWitness: Sendable {
    let fixture: PagedNativeHistoryWorkerFixture
    let value: PagedSQLPublicCiphertextWitness
    let mutation: PagedSQLPublicMutationReceipt
  }
  private static var retainedRoot: URL?
  private static var retainedOpening: PagedTextEngineAdapter?
  private static var retainedOutputs: PagedNativeHistoryWorkerOutputs?
  private static let retainedConflictCase = "testFullRecordCASRejectsSameSourceRootWithNewerHistoryEpochAndRetainsAcceptedCommand"
  private var observedRefusals: [Error] = []

  private func withFixture<T: Sendable>(_ texts: [String], initialCursor: PagedSealedCursor? = nil,
    retainedConflictCase: String? = nil,
    _ body: @MainActor (PagedNativeHistoryWorkerFixture) async throws -> T) async throws -> T {
    if let retainedConflictCase {
      guard retainedConflictCase == Self.retainedConflictCase,
        ProcessInfo.processInfo.environment["BLOOM_PAGED_HISTORY_ISOLATED_CASE"] == retainedConflictCase else {
        throw BoomError.denied("A retained admitted conflict requires its exact disposable process; no fixture entered.")
      }
    }
    guard Self.retainedRoot == nil, Self.retainedOpening == nil, Self.retainedOutputs == nil else {
      throw BoomError.denied("A previous actual failed history owner still owns this process.")
    }
    let initialFailures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-native-history-" + UUID().uuidString)
    Self.retainedRoot = root
    print("Public history-worker SQL fixture: \(root.path)")
    let opened = try await Task.detached {
      let owner = UUID(), storeID = UUID()
      let vault = try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x73, count: 32)))
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: .fresh(storeID: storeID))
      return (owner: owner, storeID: storeID, vault: vault, engine: engine)
    }.value
    Self.retainedOpening = opened.engine
    let identity = try await opened.engine._publicSQLControlIdentity(expectedVault: opened.vault, expectedStoreID: opened.storeID)
    let outputs = PagedNativeHistoryWorkerOutputs(engine: opened.engine, identity: identity)
    Self.retainedOutputs = outputs
    let prepared = try await Task.detached {
      let engine = opened.engine, publisher = try await engine.makeWorkspacePublisher()
      guard texts.count <= 2 else { throw BoomError.budget("Public history fixture admits two small source documents.") }
      var records: [PagedDocumentRootRecord] = []
      var producers: [(source: PagedTextRootLease, history: PagedTextRootLease)] = []
      for (index, text) in texts.enumerated() {
        let id = UUID(), input = root.appendingPathComponent("public-history-\(index).utf8")
        try Data(text.utf8).write(to: input, options: .withoutOverwriting)
        let file = try FileHandle(forReadingFrom: input)
        let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
        do { imported = try await engine.importUTF8Retaining(documentID: id, from: file) }
        catch {
          let original = error
          do { try file.close() } catch { XCTFail("Public history input close also failed: \(error)") }
          throw original
        }
        do { try file.close() } catch { throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
        let document = PagedDocumentDescriptor(id: id, title: "Public café \(index)", revision: imported.value.revision)
        let record: PagedTextCustodiedValue<PagedDocumentRootRecord>
        if index == 0, let initialCursor {
          let history = try PagedRootHistory(revision: imported.value.revision, cursor: initialCursor)
          record = try await engine._publicSQLControlWriteHistoryRetaining(identity: identity, history: history, document: document)
        } else { record = try await engine.initialNativeRecordRetaining(document) }
        records.append(record.value); producers.append((imported.lease, record.lease))
      }
      var state = WorkspaceState()
      state.documents = records.map { DocumentIndex(id: $0.document.id, title: $0.document.title) }
      state.selectedDocument = records.first?.document.id
      state.writingExampleIDs = records.reversed().map { $0.document.id }
      if let first = records.first {
        state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .document, id: first.document.id),
          text: "public retained unsent input", attachments: [], authoredRole: nil)]
      }
      let workspace = try await engine.initializeWorkspaceRetaining(publisher, state: state, documents: records)
      try await engine.finishWorkspacePublication(workspace, publisher: publisher)
      for (index, producer) in producers.enumerated() {
        try await engine.transferJoinedRootToHead(producer.source, publisher: publisher, expected: records[index])
        try await engine.transferJoinedRootToHead(producer.history, publisher: publisher, expected: records[index])
      }
      try await engine.abandonJoinedRootOutput(workspace.lease)
      return (publisher: publisher, snapshot: workspace.value)
    }.value
    let fixture = PagedNativeHistoryWorkerFixture(root: root, owner: opened.owner, outputs: outputs,
      vault: opened.vault, engine: opened.engine, publisher: prepared.publisher, snapshot: prepared.snapshot)
    do {
      let result = try await body(fixture)
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public SQL history assertions failed.") }
      if retainedConflictCase != nil {
        try await outputs.retainExpectedConflict()
        print("Retained actual full-record history conflict: \(root.path)")
        return result
      }
      try await outputs.closeJoined()
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public history actual joins recorded failed assertions.") }
      Self.retainedRoot = nil; Self.retainedOpening = nil; Self.retainedOutputs = nil
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      return result
    } catch {
      // Structured actual worker calls have returned; retain owners/claims and
      // original error. No storage/maintenance/close retry after this refusal.
      XCTFail("Public SQL history failure and exact source/output custody retained at \(root.path): \(error)")
      throw error
    }
  }
  private func driver(_ fixture: PagedNativeHistoryWorkerFixture, document: Int = 0,
    utf16Anchor: UInt64 = 0) async throws -> PagedNativeHistoryWorkerDriver {
    let record = fixture.snapshot.documents[document]
    let backend = try await fixture.outputs.makeBackend(fixture.publisher, expected: record)
    let window = try await backend.window(expected: record.document.revision,
      utf16Anchor: utf16Anchor, maximumBytes: PagedWorkingWindow.targetBytes)
    return try PagedNativeHistoryWorkerDriver(backend: backend, window: window, record: record)
  }
  private func admission(_ prepared: PagedNativePreparedHistoryMove,
    commandID: UUID? = nil, preparationID: UUID? = nil, sessionID: UUID? = nil,
    sourceArenaID: UUID? = nil, provisionalArenaID: UUID? = nil, preparedWindowID: UUID? = nil,
    admittedSequence: UInt64? = nil, expectedRootRecord: PagedDocumentRootRecord? = nil) throws -> PagedNativeHistoryAdmission {
    let command = prepared.command
    return PagedNativeHistoryAdmission(commandID: commandID ?? command.commandID,
      preparationID: preparationID ?? prepared.preparationID, sessionID: sessionID ?? command.sessionID,
      sourceArenaID: sourceArenaID ?? command.sourceArenaID, provisionalArenaID: provisionalArenaID ?? UUID(),
      sourceWindowID: command.sourceWindowID, preparedWindowID: preparedWindowID ?? prepared.window.windowID,
      expectedSequence: command.expectedSequence, admittedSequence: try (admittedSequence ?? command.nextSequence()),
      expectedRootRecord: expectedRootRecord ?? command.expectedRootRecord)
  }
  private func snapshot(_ fixture: PagedNativeHistoryWorkerFixture) async throws -> PagedWorkspaceSnapshot {
    try fixture.outputs.admitRead()
    let result = try await fixture.engine.loadWorkspaceRetaining(fixture.publisher)
    fixture.outputs.retain(result.lease); return result.value
  }
  private func readWorkspaceState(_ fixture: PagedNativeHistoryWorkerFixture) async throws -> WorkspaceState {
    try fixture.outputs.admitRead()
    let result = try await fixture.engine.loadWorkspaceCatalogRetaining(fixture.publisher)
    fixture.outputs.retain(result.lease); return result.value.state
  }
  private func history(_ fixture: PagedNativeHistoryWorkerFixture,
    record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    try fixture.outputs.admitRead()
    let result = try await fixture.engine._publicSQLControlHistoryRetaining(identity: fixture.outputs.identity, record: record)
    fixture.outputs.retain(result.lease); return result.value
  }
  private func sourceWindow(_ fixture: PagedNativeHistoryWorkerFixture, revision: PagedTextRevision,
    byteStart: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    try fixture.outputs.admitRead()
    let result = try await fixture.engine.windowRetaining(revision, byteStart: byteStart, maximumBytes: maximumBytes)
    fixture.outputs.retain(result.lease); return result.value
  }
  private func assertRefusal(_ expected: Refusal,
    _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("The exact native history boundary unexpectedly admitted this control.") }
    catch {
      guard observedRefusals.count < 32 else { XCTFail("Original public refusal evidence exceeds its fixed owner bound."); return }
      observedRefusals.append(error)
      let cause = pagedSQLUnderlyingRefusal(error)
      switch expected {
      case .stale: if case BoomError.stale = cause { break }; XCTFail("Expected stale identity refusal: \(error)")
      case .invalid: if case BoomError.invalid = cause { break }; XCTFail("Expected invalid source/cursor refusal: \(error)")
      case .commandConflict:
        XCTAssertTrue(cause is PagedNativeHistoryCommandConflict, "Expected retained command conflict: \(error)")
      case .authentication:
        if case CryptoKitError.authenticationFailure = cause { break }; XCTFail("Expected actual AEAD refusal: \(error)")
      }
    }
  }
  private func corruptCandidate(_ fixture: PagedNativeHistoryWorkerFixture,
    prepared: PagedNativePreparedHistoryMove) async throws -> CipherWitness {
    try fixture.outputs.admitRead()
    let witness = try await fixture.engine._publicSQLControlCiphertextWitnessRetaining(identity: fixture.outputs.identity,
      record: prepared.candidateRecord, target: .historyManifest)
    fixture.outputs.retain(witness.lease)
    try fixture.outputs.admitRead()
    let changed = try await fixture.engine._publicSQLControlCorruptRetaining(identity: fixture.outputs.identity, witness: witness.value)
    fixture.outputs.retain(changed.lease)
    return CipherWitness(fixture: fixture, value: witness.value, mutation: changed.value)
  }
  private func restore(_ witness: CipherWitness) async throws {
    try witness.fixture.outputs.admitRead()
    let result = try await witness.fixture.engine._publicSQLControlRestoreRetaining(identity: witness.fixture.outputs.identity, witness: witness.value)
    witness.fixture.outputs.retain(result.lease)
    guard case .restoration = result.value.mutation,
      result.value.witnessID == witness.value.id, result.value.record == witness.value.record else { throw BoomError.invalid("Actual SQL history witness restoration has another identity.") }
    // No independent failed native COMMIT/lease/fence is repaired by this helper.
  }

  func testWorkerUndoRedoUsesExactRetainedRootsAndPreservesUnrelatedHeadUpdate() async throws {
    try await withFixture(["a public café🙂\n", "u public unrelated\n"]) { fixture in
      let owner = try await driver(fixture), firstGroup = UUID(), secondGroup = UUID()
      let first = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: firstGroup)
      let second = try await owner.replace(NSRange(location: 0, length: 1), with: "c", groupID: secondGroup)
      let before = try await snapshot(fixture)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(secondGroup))
      let unchanged = try await snapshot(fixture)
      XCTAssertEqual(unchanged, before)
      XCTAssertEqual(prepared.candidateRecord.document.revision, first.sealedWindow.revision)
      XCTAssertEqual(prepared.candidateRecord.historyGeneration, second.historyGeneration + 1)
      let preparedHistory = try await history(fixture, record: prepared.candidateRecord)
      XCTAssertEqual(preparedHistory.undo.map(\.groupID), [firstGroup])
      XCTAssertEqual(preparedHistory.redo.map(\.groupID), [secondGroup])
      XCTAssertLessThanOrEqual(prepared.windowBytes, 16_384)
      let unrelated = try await driver(fixture, document: 1)
      let changedOther = try await unrelated.replace(NSRange(location: 0, length: 1), with: "U")
      let afterOther = try await snapshot(fixture)
      let admitted = try admission(prepared)
      let undo = try await owner.backend.commitPreparedHistory(prepared, admission: admitted)
      XCTAssertEqual(undo.admittedSequence, 3); XCTAssertEqual(undo.sealedRootRecord, prepared.candidateRecord)
      XCTAssertEqual(undo.sealedWindow.revision, first.sealedWindow.revision)
      let afterUndo = try await snapshot(fixture)
      XCTAssertEqual(afterUndo.documents[1], changedOther.sealedRootRecord)
      XCTAssertEqual(afterUndo.head.generation, afterOther.head.generation + 1)
      XCTAssertEqual(afterUndo.head.workspace, fixture.snapshot.head.workspace)
      try owner.adopt(undo)
      try await owner.backend.finishHistoryInstallation(prepared, admission: admitted)
      let redoPrepared = try await owner.backend.prepareHistoryMove(owner.command(secondGroup, direction: .redo))
      let redoAdmission = try admission(redoPrepared)
      let redo = try await owner.backend.commitPreparedHistory(redoPrepared, admission: redoAdmission)
      XCTAssertEqual(redo.admittedSequence, 4); XCTAssertEqual(redo.sealedWindow.revision, second.sealedWindow.revision)
      try owner.adopt(redo)
      try await owner.backend.finishHistoryInstallation(redoPrepared, admission: redoAdmission)
      let later = try await owner.replace(NSRange(location: 0, length: 1), with: "d")
      XCTAssertEqual(later.lastSequence, 5)
      let reopened = try await snapshot(fixture)
      let state = try await readWorkspaceState(fixture)
      XCTAssertEqual(state.writingExampleIDs, fixture.snapshot.documents.reversed().map { $0.document.id })
      XCTAssertEqual(state.composerDrafts?.first?.text, "public retained unsent input")
      XCTAssertEqual(reopened.documents[1], changedOther.sealedRootRecord)
    }
  }

  func testWorkerRejectsWrongTopGroupControllerSequenceRecordAndAdmissionWithoutPublication() async throws {
    try await withFixture(["a public"]) { fixture in
      let owner = try await driver(fixture), firstGroup = UUID(), lastGroup = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: firstGroup)
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "c", groupID: lastGroup)
      let command = owner.command(lastGroup), before = try await snapshot(fixture)
      await assertRefusal(.stale) { _ = try await owner.backend.prepareHistoryMove(owner.command(firstGroup)) }
      await assertRefusal(.stale) { _ = try await owner.backend.prepareHistoryMove(owner.command(lastGroup, direction: .redo)) }
      let staleRecord = PagedDocumentRootRecord(document: command.expectedRootRecord.document,
        historyPage: command.expectedRootRecord.historyPage, historyGeneration: command.expectedRootRecord.historyGeneration + 1)
      let nfdTitle = PagedDocumentDescriptor(id: command.handle.documentID, title: "Public cafe\u{301} 0",
        revision: command.expectedRootRecord.document.revision)
      let nfdRecord = PagedDocumentRootRecord(document: nfdTitle,
        historyPage: command.expectedRootRecord.historyPage, historyGeneration: command.expectedRootRecord.historyGeneration)
      let changedCommands = [
        PagedNativeHistoryMoveCommand(sessionID: UUID(), commandID: UUID(), sourceArenaID: command.sourceArenaID,
          sourceWindowID: command.sourceWindowID, expectedSequence: command.expectedSequence,
          expectedRootRecord: command.expectedRootRecord, handle: command.handle),
        PagedNativeHistoryMoveCommand(sessionID: command.sessionID, commandID: UUID(), sourceArenaID: command.sourceArenaID,
          sourceWindowID: command.sourceWindowID, expectedSequence: command.expectedSequence - 1,
          expectedRootRecord: command.expectedRootRecord, handle: command.handle),
        PagedNativeHistoryMoveCommand(sessionID: command.sessionID, commandID: UUID(), sourceArenaID: command.sourceArenaID,
          sourceWindowID: command.sourceWindowID, expectedSequence: command.expectedSequence,
          expectedRootRecord: staleRecord, handle: command.handle),
        PagedNativeHistoryMoveCommand(sessionID: command.sessionID, commandID: UUID(), sourceArenaID: command.sourceArenaID,
          sourceWindowID: command.sourceWindowID, expectedSequence: command.expectedSequence,
          expectedRootRecord: nfdRecord, handle: command.handle)
      ]
      for changed in changedCommands { await assertRefusal(.stale) { _ = try await owner.backend.prepareHistoryMove(changed) } }
      let prepared = try await owner.backend.prepareHistoryMove(command)
      await assertRefusal(.commandConflict) { _ = try await owner.backend.prepareHistoryMove(command) }
      let badAdmissions = try [admission(prepared, commandID: UUID()), admission(prepared, preparationID: UUID()),
        admission(prepared, sessionID: UUID()), admission(prepared, sourceArenaID: UUID()),
        admission(prepared, provisionalArenaID: command.sourceArenaID), admission(prepared, preparedWindowID: UUID()),
        admission(prepared, admittedSequence: command.expectedSequence + 2), admission(prepared, expectedRootRecord: staleRecord)]
      for bad in badAdmissions {
        await assertRefusal(.stale) { _ = try await owner.backend.commitPreparedHistory(prepared, admission: bad) }
      }
      let otherRoute = try await fixture.outputs.makeBackend(fixture.publisher, expected: command.expectedRootRecord)
      await assertRefusal(.stale) { _ = try await otherRoute.commitPreparedHistory(prepared, admission: admission(prepared)) }
      let unchanged = try await snapshot(fixture)
      XCTAssertEqual(unchanged, before)
      let reachability = await owner.backend.historyReachability()
      let pins = try XCTUnwrap(reachability)
      if case .prepared = pins.phase {} else { XCTFail("Invalid admissions changed command phase.") }
      let disposition = try await owner.backend.resolveUnadmittedHistory(prepared, disposition: .explicitlyAbandoned)
      XCTAssertEqual(disposition.prepared, prepared)
    }
  }

  func testInterveningAdmittedInputRetainsUndoIntentAndPinsWithoutRebase() async throws {
    try await withFixture(["a public"]) { fixture in
      let owner = try await driver(fixture), group = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: group)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group))
      XCTAssertTrue(try owner.working.replace(NSRange(location: 0, length: 1), with: "c", groupID: UUID()))
      let inputBytes = owner.working.bytes, inputGeneration = owner.working.generation
      let observation = PagedNativeHistoryInputObservation(sessionID: owner.working.sessionID,
        arenaID: owner.working.arenaID, generation: inputGeneration, compositionPinned: false)
      let conflict = try await owner.backend.noteHistoryInputConflict(prepared, observation: observation)
      XCTAssertEqual(conflict.prepared, prepared); XCTAssertEqual(conflict.observation, observation)
      await assertRefusal(.commandConflict) {
        _ = try await owner.backend.commitPreparedHistory(prepared, admission: admission(prepared))
      }
      let admitted = try await owner.sealPending()
      XCTAssertEqual(admitted.lastSequence, inputGeneration)
      XCTAssertEqual(owner.working.bytes, inputBytes)
      let reachability = await owner.backend.historyReachability()
      let retained = try XCTUnwrap(reachability)
      XCTAssertEqual(retained.before, prepared.command.expectedRootRecord); XCTAssertEqual(retained.candidate, prepared.candidateRecord)
      if case .inputConflict = retained.phase {} else { XCTFail("Admitted typing lost the pending Undo intent.") }
      // Explicit receiving-owner custody precedes backend release. This is
      // not a resolution of the product's still-unimplemented conflict policy.
      let recipient = try fixture.outputs.retainIntent(prepared)
      let transferID = recipient.receiptID, receivingLedger = [transferID: recipient.prepared]
      let receipt = try await owner.backend.resolveUnadmittedHistory(prepared,
        disposition: .transferredToRetainedOwner(receiptID: transferID))
      XCTAssertEqual(receivingLedger[transferID], receipt.prepared)
      let afterRelease = await owner.backend.historyReachability()
      XCTAssertNil(afterRelease)
      let unchangedCandidate = try await history(fixture, record: prepared.candidateRecord)
      XCTAssertEqual(unchangedCandidate.current, prepared.candidateRecord.document.revision)
      let current = try await snapshot(fixture)
      XCTAssertEqual(current.documents[0], admitted.sealedRootRecord)
    }
  }

  func testFullRecordCASRejectsSameSourceRootWithNewerHistoryEpochAndRetainsAcceptedCommand() async throws {
    try await withFixture(["a public"], retainedConflictCase: Self.retainedConflictCase) { fixture in
      let owner = try await driver(fixture), group = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: group)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group))
      let record = prepared.command.expectedRootRecord
      let otherRoute = try await fixture.outputs.makeBackend(fixture.publisher, expected: record)
      let island = try await otherRoute.window(expected: record.document.revision,
        utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
      let other = try PagedNativeHistoryWorkerDriver(backend: otherRoute, window: island, record: record)
      let transientGroup = UUID()
      XCTAssertTrue(try other.working.replace(NSRange(location: 0, length: 1), with: "c", groupID: transientGroup))
      XCTAssertTrue(try other.working.replace(NSRange(location: 0, length: 1), with: "b", groupID: transientGroup))
      let epoch = try await other.sealPending()
      XCTAssertEqual(epoch.sealedWindow.revision, record.document.revision)
      XCTAssertGreaterThan(epoch.historyGeneration, record.historyGeneration)
      await assertRefusal(.stale) {
        _ = try await owner.backend.commitPreparedHistory(prepared, admission: admission(prepared))
      }
      let recovery = try await owner.backend.inspectHistoryRecovery(prepared)
      if case .conflict(let actual) = recovery { XCTAssertEqual(actual, epoch.sealedRootRecord) }
      else { XCTFail("Same-source/new-history ABA was treated as publishable.") }
      let reachability = await owner.backend.historyReachability()
      let retained = try XCTUnwrap(reachability)
      if case .admitted = retained.phase {} else { XCTFail("Uncertain admitted command lost its pins.") }
      XCTAssertEqual(retained.before, record); XCTAssertEqual(retained.candidate, prepared.candidateRecord)
      let current = try await snapshot(fixture)
      XCTAssertEqual(current.documents[0], epoch.sealedRootRecord)
    }
  }

  func testMarkedInputDuringPreparationKeepsIntentAndCompositionWhileActualEditsSeal() async throws {
    try await withFixture(["a public"]) { fixture in
      let owner = try await driver(fixture), group = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: group)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group))
      owner.working.beginComposition()
      let pinned = PagedNativeHistoryInputObservation(sessionID: owner.working.sessionID,
        arenaID: owner.working.arenaID, generation: owner.working.generation, compositionPinned: true)
      _ = try await owner.backend.noteHistoryInputConflict(prepared, observation: pinned)
      XCTAssertTrue(owner.working.isPinned)
      XCTAssertTrue(try owner.working.replace(NSRange(location: 0, length: 1), with: "文", groupID: UUID()))
      XCTAssertNil(try owner.working.takeCommitBatch())
      await assertRefusal(.commandConflict) {
        _ = try await owner.backend.commitPreparedHistory(prepared, admission: admission(prepared))
      }
      XCTAssertTrue(owner.working.isPinned)
      owner.working.endComposition()
      let source = try await owner.sealPending()
      XCTAssertEqual(source.lastSequence, 2)
      XCTAssertEqual(source.sealedWindow.text, "文 public")
      let reachability = await owner.backend.historyReachability()
      let retained = try XCTUnwrap(reachability)
      if case .inputConflict = retained.phase {} else { XCTFail("IME source seal erased the pending Undo intent.") }
      // Fixture owner explicitly retains the unresolved intent before transfer.
      let recipient = try fixture.outputs.retainIntent(prepared)
      let transfer = recipient.receiptID, intentLedger = [transfer: recipient.prepared]
      let receipt = try await owner.backend.resolveUnadmittedHistory(prepared,
        disposition: .transferredToRetainedOwner(receiptID: transfer))
      XCTAssertEqual(intentLedger[transfer], receipt.prepared)
    }
  }

  func testCorruptUnpublishedHistoryRequiresAuthenticatedInspectionBeforeExplicitFinish() async throws {
    try await withFixture(["a public"]) { fixture in
      let owner = try await driver(fixture), group = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: group)
      let before = try await snapshot(fixture)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group)), admitted = try admission(prepared)
      let witness = try await corruptCandidate(fixture, prepared: prepared)
      await assertRefusal(.authentication) { _ = try await owner.backend.commitPreparedHistory(prepared, admission: admitted) }
      let unchanged = try await snapshot(fixture)
      XCTAssertEqual(unchanged, before)
      await assertRefusal(.commandConflict) { _ = try await owner.backend.window(expected: before.documents[0].document.revision,
        utf16Anchor: 0, maximumBytes: 16_384) }
      await assertRefusal(.commandConflict) { _ = try await owner.backend.completeVerifiedHistory(prepared, verificationID: UUID()) }
      await assertRefusal(.authentication) { _ = try await owner.backend.inspectHistoryRecovery(prepared) }
      let reachability = await owner.backend.historyReachability()
      let held = try XCTUnwrap(reachability)
      if case .admitted = held.phase {} else { XCTFail("Authentication failure dropped the admitted command.") }
      try await restore(witness)
      let recovery = try await owner.backend.inspectHistoryRecovery(prepared)
      guard case .verifiedNotPublished(let verification) = recovery else {
        throw BoomError.invalid("Actual before-record inspection did not issue a deliberate completion permit.")
      }
      let afterInspection = try await snapshot(fixture)
      XCTAssertEqual(afterInspection, before)
      await assertRefusal(.commandConflict) { _ = try await owner.backend.completeVerifiedHistory(prepared, verificationID: UUID()) }
      let completed = try await owner.backend.completeVerifiedHistory(prepared, verificationID: verification)
      XCTAssertEqual(completed.sealedRootRecord, prepared.candidateRecord)
      XCTAssertEqual(completed.admittedSequence, 2)
      let success = try await owner.backend.inspectHistoryRecovery(prepared)
      if case .published(let exact) = success { XCTAssertEqual(exact.sealedRootRecord, completed.sealedRootRecord) }
      else { XCTFail("The completed exact command was not durably classified.") }
      try await owner.backend.finishHistoryInstallation(prepared, admission: admitted)
      await assertRefusal(.stale) { _ = try await owner.backend.completeVerifiedHistory(prepared, verificationID: verification) }
    }
  }

  func testRetainedCursorIsValidatedAgainstActualScalarCoordinatesAndContextAnchorMayCrossSurrogate() async throws {
    try await withFixture(["🙂 public"]) { fixture in
      let record = fixture.snapshot.documents[0]
      for malformed in [PagedSealedCursor(byteOffset: 1, utf16Offset: 0), PagedSealedCursor(byteOffset: 1, utf16Offset: 1)] {
        let candidate = try PagedRootHistory(revision: record.document.revision, cursor: malformed)
        await assertRefusal(.invalid) {
          _ = try await fixture.engine._publicSQLControlWriteHistoryRetaining(identity: fixture.outputs.identity,
            history: candidate, document: record.document)
        }
        let after = try await snapshot(fixture)
        XCTAssertEqual(after, fixture.snapshot)
        XCTAssertEqual(fixture.engine.custodySnapshot.jobs, 0)
      }
    }
    let source = "🙂" + String(repeating: "a", count: 4_095) + " public tail"
    let cursor = PagedSealedCursor(byteOffset: 4_099, utf16Offset: 4_097)
    try await withFixture([source], initialCursor: cursor) { fixture in
      let owner = try await driver(fixture), group = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 2), with: "🙃", groupID: group,
        beforeCaretUTF16: 4_097)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group))
      XCTAssertEqual(prepared.cursor, cursor)
      XCTAssertEqual(prepared.window.byteStart, 4); XCTAssertEqual(prepared.window.utf16Start, 2)
      XCTAssertEqual(prepared.localCaretUTF16, 4_095)
      XCTAssertLessThanOrEqual(prepared.windowBytes, 16_384)
      let admitted = try admission(prepared)
      let result = try await owner.backend.commitPreparedHistory(prepared, admission: admitted)
      XCTAssertEqual(result.cursor, cursor); XCTAssertEqual(result.sealedWindow.revision, fixture.snapshot.documents[0].document.revision)
      try await owner.backend.finishHistoryInstallation(prepared, admission: admitted)
    }
  }

  func testHundredRealRootsKeepIdentityHistoryAndSourceNewerEpochAcrossUndoRedo() async throws {
    try await withFixture(["a public"]) { fixture in
      let owner = try await driver(fixture)
      var groups: [UUID] = []
      for index in 0..<100 {
        let group = UUID(); groups.append(group)
        _ = try await owner.replace(NSRange(location: 0, length: 1), with: index.isMultiple(of: 2) ? "b" : "a", groupID: group)
      }
      let before = owner.working.sealedRootRecord, retained = try await history(fixture, record: before)
      XCTAssertEqual(retained.undo.count, 100); XCTAssertTrue(retained.redo.isEmpty)
      XCTAssertEqual(retained.undo.map(\.groupID), groups)
      let top = try XCTUnwrap(retained.undo.last)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(top.groupID))
      let admitted = try admission(prepared)
      let result = try await owner.backend.commitPreparedHistory(prepared, admission: admitted)
      let undone = try await history(fixture, record: result.sealedRootRecord)
      XCTAssertEqual(undone.current, top.revision); XCTAssertEqual(undone.currentCursor, top.cursor)
      XCTAssertEqual(undone.undo, Array(retained.undo.dropLast())); XCTAssertEqual(undone.redo.count, 1)
      XCTAssertEqual(undone.generation, retained.generation + 1); XCTAssertNil(undone.activeGroup)
      XCTAssertEqual(result.admittedSequence, 101)
      try owner.adopt(result); try await owner.backend.finishHistoryInstallation(prepared, admission: admitted)
      let redoPrepared = try await owner.backend.prepareHistoryMove(owner.command(top.groupID, direction: .redo))
      let redoAdmission = try admission(redoPrepared)
      let redo = try await owner.backend.commitPreparedHistory(redoPrepared, admission: redoAdmission)
      let restored = try await history(fixture, record: redo.sealedRootRecord)
      XCTAssertEqual(restored.current, retained.current); XCTAssertEqual(restored.undo, retained.undo)
      XCTAssertTrue(restored.redo.isEmpty); XCTAssertEqual(restored.generation, retained.generation + 2)
      XCTAssertEqual(redo.admittedSequence, 102)
      try await owner.backend.finishHistoryInstallation(redoPrepared, admission: redoAdmission)
    }
  }

  func testRetainedCursorInLargeSingleLinePreparesOnlyFixedIslandAndContinuesExactLocalEditing() async throws {
    let source = String(repeating: "a", count: 65_536)
    let cursor = PagedSealedCursor(byteOffset: 50_000, utf16Offset: 50_000)
    try await withFixture([source], initialCursor: cursor) { fixture in
      let owner = try await driver(fixture, utf16Anchor: 50_000), group = UUID()
      _ = try await owner.replace(NSRange(location: 4_096, length: 1), with: "b", groupID: group)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group))
      XCTAssertEqual(prepared.candidateRecord.document.revision, fixture.snapshot.documents[0].document.revision)
      XCTAssertEqual(prepared.candidateRecord.document.revision.summary.bytes, 65_536)
      XCTAssertEqual(prepared.windowBytes, 16_384)
      XCTAssertEqual(prepared.window.byteStart, 45_904); XCTAssertEqual(prepared.window.utf16Start, 45_904)
      XCTAssertEqual(prepared.localCaretUTF16, 4_096)
      let admitted = try admission(prepared)
      let undo = try await owner.backend.commitPreparedHistory(prepared, admission: admitted)
      try owner.adopt(undo); try await owner.backend.finishHistoryInstallation(prepared, admission: admitted)
      let later = try await owner.replace(NSRange(location: 4_096, length: 1), with: "x")
      XCTAssertEqual(later.lastSequence, 3)
      let exact = try await sourceWindow(fixture, revision: later.sealedWindow.revision, byteStart: 49_999, maximumBytes: 3)
      XCTAssertEqual(exact.text, "axa"); XCTAssertEqual(exact.utf16Start, 49_999)
      let historyAfter = try await history(fixture, record: later.sealedRootRecord)
      XCTAssertEqual(historyAfter.currentCursor, PagedSealedCursor(byteOffset: 50_001, utf16Offset: 50_001))
      let statistics = try await fixture.engine.stats()
      XCTAssertLessThanOrEqual(statistics.chargedBytes, 8_388_608)
    }
  }

  func testRealEncryptedJournalRecoveryFinishesOnlyAfterEveryTargetComponentIsAdmitted() async throws {
    // The historical name is retained. SQLite now supplies the journal; this
    // control enters the actual published-before-receiving inspection path.
    try await withFixture(["a public"]) { fixture in
      let owner = try await driver(fixture), group = UUID()
      _ = try await owner.replace(NSRange(location: 0, length: 1), with: "b", groupID: group)
      let before = try await snapshot(fixture)
      let prepared = try await owner.backend.prepareHistoryMove(owner.command(group)), admitted = try admission(prepared)
      let original = try await owner.backend.commitPreparedHistory(prepared, admission: admitted)
      let after = try await snapshot(fixture)
      XCTAssertEqual(after.head.generation, before.head.generation + 1)
      XCTAssertEqual(after.documents[0], prepared.candidateRecord)
      XCTAssertEqual(after.head.workspace, before.head.workspace)
      let corrupt = try await corruptCandidate(fixture, prepared: prepared)
      let beforeInspection = fixture.engine.custodySnapshot
      await assertRefusal(.authentication) { _ = try await owner.backend.inspectHistoryRecovery(prepared) }
      let reachability = await owner.backend.historyReachability()
      let retained = try XCTUnwrap(reachability)
      XCTAssertEqual(retained.before, prepared.command.expectedRootRecord)
      XCTAssertEqual(retained.candidate, prepared.candidateRecord)
      guard case .published = retained.phase else { throw BoomError.invalid("Actual publication custody lost its installed-pending phase.") }
      XCTAssertEqual(fixture.engine.custodySnapshot.jobs, 0)
      XCTAssertEqual(fixture.engine.custodySnapshot.items.filter { $0.sqlOperationID == prepared.preparationID }.count,
        beforeInspection.items.filter { $0.sqlOperationID == prepared.preparationID }.count)
      try fixture.outputs.admitRead()
      let pointer = try await fixture.engine._publicSQLControlHeadPointerRetaining(identity: fixture.outputs.identity)
      fixture.outputs.retain(pointer.lease)
      XCTAssertEqual(pointer.value, after.head.headID)
      try await restore(corrupt)
      let inspected = try await owner.backend.inspectHistoryRecovery(prepared)
      guard case .published(let actual) = inspected else {
        throw BoomError.invalid("Authenticated SQL publication did not retain its actual history output.")
      }
      XCTAssertEqual(actual.sealedRootRecord, original.sealedRootRecord)
      XCTAssertEqual(actual.admittedSequence, original.admittedSequence)
      XCTAssertEqual(actual.sealedWindow.revision, original.sealedWindow.revision)
      XCTAssertTrue(actual.sealedWindow.text.utf8.elementsEqual(original.sealedWindow.text.utf8))
      let recovered = try await snapshot(fixture)
      XCTAssertEqual(recovered, after)
      try owner.adopt(actual)
      try await owner.backend.finishHistoryInstallation(prepared, admission: admitted)
      let joinedReachability = await owner.backend.historyReachability()
      XCTAssertNil(joinedReachability)
    }
  }
}

#endif
