import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY / UNPARSED / UNCOMPILED / UNRUN. Every case is nominated in a
// fresh process, with the real vendor admission unchanged. The final case is
// deliberately retained-terminal: its queued actual key and independent
// physical input refusal have no accepted receiving/close disposition.
private struct SQLDurabilityEvidenceFailure: Error {
  let original: Error
  let evidence: Error
}

@MainActor private final class SQLDurabilityFixture {
  let root: URL
  let vault: Vault
  let ownerID: UUID
  let storeID: UUID
  var engine: PagedTextEngineAdapter?
  var setupFailure: PagedTextSetupCustodyFailure?
  var identity: PagedSQLPublicControlIdentity?
  var publisher: PagedWorkspacePublisher?
  var backend: PagedNativeStorageBackend?
  var native: SQLDurabilityNative?
  var lostACKForwarder: SQLDurabilityLostACKForwarder?
  var file: FileHandle?
  var fileCloseAttempted = false
  var originalErrors: [Error] = []
  var closed = false
  init(root: URL, vault: Vault, ownerID: UUID, storeID: UUID) {
    self.root = root; self.vault = vault; self.ownerID = ownerID; self.storeID = storeID
  }
  func preserve(_ error: Error) throws {
    guard originalErrors.count < 8 else { throw BoomError.budget("Public original-error evidence exceeded 8 fixed entries.") }
    originalErrors.append(error)
  }
  func closeSource() async throws {
    guard file == nil else { throw BoomError.stale("Actual source descriptor remains owned.") }
    if let native { try await native.closeInput() }
    guard let engine else { throw BoomError.stale("Actual setup Engine is absent or unresolved.") }
    let maintenance = try await engine.joinScheduledWALMaintenance()
    if let error = maintenance.failure { throw error }
    try await engine.close(); closed = true
    native?.window.close()
  }
}

/// Drops only the actual first commit reply AFTER the real backend returned
/// its ACK. Every source/history/finish method still forwards to that SAME
/// encrypted backend; this never manufactures an output or durability result.
private actor SQLDurabilityLostACKForwarder: PagedNativeSQLDurabilityStorage {
  let actual: PagedNativeStorageBackend
  private var dropNext = true
  init(_ actual: PagedNativeStorageBackend) { self.actual = actual }
  func armNextActualReplyLoss() throws {
    guard !dropNext else { throw BoomError.stale("An actual public reply loss is already armed.") }
    dropNext = true
  }
  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    let acknowledgement = try await actual.commit(batch)
    if dropNext { dropNext = false; throw BoomError.unavailable("Actual commit ACK delivery deliberately lost after backend installation.") }
    return acknowledgement
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    try await actual.window(expected: expected, utf16Anchor: utf16Anchor, maximumBytes: maximumBytes)
  }
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    try await actual.finishCommitInstallation(acknowledgement)
  }
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove {
    try await actual.prepareHistoryMove(command)
  }
  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    try await actual.commitPreparedHistory(prepared, admission: admission)
  }
  func noteHistoryInputConflict(_ prepared: PagedNativePreparedHistoryMove, observation: PagedNativeHistoryInputObservation) async throws -> PagedNativeHistoryInputConflictReceipt {
    try await actual.noteHistoryInputConflict(prepared, observation: observation)
  }
  func resolveUnadmittedHistory(_ prepared: PagedNativePreparedHistoryMove, disposition: PagedNativeHistoryIntentDisposition) async throws -> PagedNativeHistoryIntentDispositionReceipt {
    try await actual.resolveUnadmittedHistory(prepared, disposition: disposition)
  }
  func inspectHistoryRecovery(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    try await actual.inspectHistoryRecovery(prepared)
  }
  func completeVerifiedHistory(_ prepared: PagedNativePreparedHistoryMove, verificationID: UUID) async throws -> PagedNativeHistoryAcknowledgement {
    try await actual.completeVerifiedHistory(prepared, verificationID: verificationID)
  }
  func finishHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission) async throws {
    try await actual.finishHistoryInstallation(prepared, admission: admission)
  }
  func repairHistoryDurability(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    try await actual.repairHistoryDurability(prepared)
  }
  func repairCommitDurability(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    let acknowledgement = try await actual.repairCommitDurability(batch)
    if dropNext { dropNext = false; throw BoomError.unavailable("Actual repaired ACK delivery deliberately lost after backend installation.") }
    return acknowledgement
  }
  func inspectCommitRecovery(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitRecovery {
    try await actual.inspectCommitRecovery(batch)
  }
  func retryVerifiedCommit(_ batch: PagedNativeCommitBatch, verificationID: UUID) async throws -> PagedNativeCommitAcknowledgement {
    try await actual.retryVerifiedCommit(batch, verificationID: verificationID)
  }
}

@MainActor private final class SQLDurabilityNative {
  let fixture: SQLDurabilityFixture
  let session: PagedNativeSession
  let input: PagedNativeInputOwner
  let commands: PagedNativeUndoOwner
  let window: NSWindow
  let scroll: NSScrollView
  var closed = false
  var view: PagedNativeTextView { input.activeView }
  init(fixture: SQLDurabilityFixture, backend: PagedNativeStorageBackend,
    opening: PagedNativeCanonicalOpening, storage: (any PagedNativeSessionStorage)? = nil) throws {
    self.fixture = fixture
    session = try PagedNativeSession(opening: opening, storage: storage ?? backend)
    input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
    commands = try PagedNativeUndoOwner(input: input)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320)); window.contentView = scroll
    fixture.native = self // retain actual graph before fallible focus/Cocoa
    commands.mountView = { [weak self] old, new in
      guard let self else { XCTFail("Actual public source/input owner was lost."); return }
      XCTAssertTrue(self.scroll.documentView === old)
      self.scroll.documentView = new
      XCTAssertTrue(self.window.makeFirstResponder(new))
    }
    scroll.documentView = view; window.makeKeyAndOrderFront(nil)
    guard window.makeFirstResponder(view), window.firstResponder === view else { throw BoomError.unavailable("Real public input did not acquire focus.") }
  }
  func replaceFirst(_ text: String) throws {
    let generation = session.generation
    view.setSelectedRange(NSRange(location: 0, length: 1))
    view.insertText(text, replacementRange: NSRange(location: 0, length: 1))
    guard session.generation == generation + 1, input.firstRefusal == nil,
      view.boundedStorage.mutationFailure == nil else { throw BoomError.stale("Actual public native primitive was refused.") }
  }
  func seal() async throws -> PagedDocumentRootRecord {
    _ = try await session.flush(through: session.generation)
    guard session.persistenceFailure == nil, session.pendingCommitInstallation == nil,
      let record = session.canonicalHistory?.record else { throw BoomError.unavailable("The actual native source/receiving task did not join.") }
    return record
  }
  func completeHistoryReceiving(_ acknowledgement: PagedNativeHistoryAcknowledgement) async throws {
    _ = try await session.joinHistoryPublication(commandID: acknowledgement.commandID)
    // This is the existing exact Root receiving disposition, after real Main
    // installation and same-controller finish. It does not replay the source.
    let ticket = try commands.prepareReceivingDisposition(.completeJoinedHistoryReceiving)
    let received = try await commands.applyReceivingDisposition(ticket)
    XCTAssertFalse(received.receivingOwnerRemainsBlocked)
    XCTAssertNil(commands.firstFailure)
    XCTAssertNil(commands.retainedPreparation); XCTAssertNil(commands.retainedPrefix)
  }
  func closeInput() async throws {
    guard !closed else { return }
    try await commands.joinPendingCommand()
    let record = try await seal()
    try commands.closeInput(); try commands.requireJoinedClose()
    _ = window.makeFirstResponder(nil); scroll.documentView = nil
    guard let backend = fixture.backend else { throw BoomError.stale("Actual native backend is absent.") }
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: session.generation, record: record)
    fixture.backend = nil; closed = true
  }
}

@MainActor final class PagedSQLiteDurabilityRepairTests: XCTestCase {
  private static var retained: SQLDurabilityFixture?
  private static var retainedRoot: URL?

  private func fixture(_ name: String, setupFailureExpected: Bool = false,
    retainedTerminal: Bool = false,
    _ body: @MainActor (SQLDurabilityFixture) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["BLOOM_PAGED_SQL_DURABILITY_PUBLIC_CASE"] == name else {
      throw BoomError.denied("Nominate exactly this real public durability case; zero skips, no implicit run.")
    }
    guard Self.retained == nil, Self.retainedRoot == nil else { throw BoomError.denied("An earlier actual public owner still owns this process.") }
    _ = NSApplication.shared
    let failureCount = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-sql-durability-" + UUID().uuidString)
    Self.retainedRoot = root
    print("Actual public SQL durability source: \(root.path)")
    let vault = try await Task.detached { try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x73, count: 32))) }.value
    let held = SQLDurabilityFixture(root: root, vault: vault, ownerID: UUID(), storeID: UUID())
    Self.retained = held
    do {
      do {
        let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: held.ownerID,
          sqliteOpening: .fresh(storeID: held.storeID))
        held.engine = engine // before any assertion/helper observation
        if setupFailureExpected { throw BoomError.invalid("The actual fresh-format name fault did not refuse opening.") }
        held.identity = try await engine._publicSQLControlIdentity(expectedVault: vault, expectedStoreID: held.storeID)
      } catch let failure as PagedTextSetupCustodyFailure {
        held.setupFailure = failure; held.engine = failure.engine
        try held.preserve(failure.original)
        guard setupFailureExpected else { throw failure }
      }
      try await body(held)
      guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual assertion failed; originals/owners/scratch retained.") }
      if retainedTerminal {
        guard name == "testNewActualRefusedInputSurvivesOlderCommitDurabilityRepair",
          held.native?.input.firstRefusal != nil, held.native?.commands.queuedRawKeyCount == 1,
          held.native?.commands.unretainedRawKeyCount == 0, held.closed == false else {
          throw BoomError.stale("The nominated retained-terminal case lost its actual original key or physical refusal.")
        }
        // Actual source tasks joined; the original intercepted NSEvent stays
        // in Root's real queue. The separate physical refusal has no release.
        // No cleanup, guessed close, product acceptance or historical ACK.
        print("RETAINED_TERMINAL original queued NSEvent and independent physical refusal; source tasks joined, no joined input/Engine close.")
        return
      }
      try await held.closeSource()
      guard held.closed, held.file == nil, held.backend == nil else { throw BoomError.stale("Actual owner/descriptor joins are incomplete.") }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      held.native = nil; Self.retained = nil; Self.retainedRoot = nil
    } catch {
      let preserved: Error
      do { try held.preserve(error); preserved = error }
      catch let evidence { preserved = SQLDurabilityEvidenceFailure(original: error, evidence: evidence) }
      XCTFail("Actual public durability failure preserved at \(root.path): \(preserved)")
      throw preserved
    }
  }
  private func requireActualRefusal(_ held: SQLDurabilityFixture, message: String,
    _ work: @MainActor () async throws -> Void) async throws {
    var refused = false
    do { try await work() }
    catch { refused = true; try held.preserve(error) }
    // Keep this outside catch: a control must never swallow its own failure
    // because the actual operation unexpectedly succeeded.
    guard refused else { throw BoomError.invalid(message) }
  }

  private func native(_ held: SQLDurabilityFixture, loseCommitReply: Bool = false) async throws -> SQLDurabilityNative {
    let engine = try XCTUnwrap(held.engine)
    let path = held.root.appendingPathComponent("public-source.utf8")
    let file = try await Task.detached {
      try Data("a public🙂\n".utf8).write(to: path, options: .withoutOverwriting)
      return try FileHandle(forReadingFrom: path)
    }.value
    held.file = file
    let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
    do { imported = try await engine.importUTF8Retaining(documentID: UUID(), from: file) }
    catch { try held.preserve(error); throw error }
    held.fileCloseAttempted = true
    do { try await Task.detached { try file.close() }.value; held.file = nil }
    catch { try held.preserve(error); throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
    let document = PagedDocumentDescriptor(id: imported.value.revision.documentID, title: "Public durability", revision: imported.value.revision)
    let initial = try await engine.initialNativeRecordRetaining(document)
    let publisher = try await engine.makeWorkspacePublisher(); held.publisher = publisher
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    let saved = try await engine.initializeWorkspaceRetaining(publisher, state: state, documents: [initial.value])
    try await engine.transferJoinedRootToHead(imported.lease, publisher: publisher, expected: initial.value)
    try await engine.transferJoinedRootToHead(initial.lease, publisher: publisher, expected: initial.value)
    try await engine.finishWorkspacePublication(saved, publisher: publisher)
    try await engine.abandonJoinedRootOutput(saved.lease)
    let backend = try await engine.makeNativeStorage(publisher, expected: initial.value); held.backend = backend
    let opening = try await backend.opening(sessionID: UUID())
    let storage: any PagedNativeSessionStorage
    if loseCommitReply {
      let forwarder = SQLDurabilityLostACKForwarder(backend)
      held.lostACKForwarder = forwarder; storage = forwarder
    } else { storage = backend }
    return try SQLDurabilityNative(fixture: held, backend: backend, opening: opening, storage: storage)
  }
  private func read(_ held: SQLDurabilityFixture, record: PagedDocumentRootRecord, text: String) async throws {
    let engine = try XCTUnwrap(held.engine)
    let window = try await engine.windowRetaining(record.document.revision,
      byteStart: 0, maximumBytes: PagedWorkingWindow.targetBytes)
    XCTAssertEqual(Data(window.value.text.utf8), Data(text.utf8))
    try await engine.abandonJoinedRootOutput(window.lease)
    let snapshot = try await engine.loadWorkspaceRetaining(try XCTUnwrap(held.publisher))
    XCTAssertEqual(snapshot.value.documents, [record])
    try await engine.abandonJoinedRootOutput(snapshot.lease)
  }
  private func failedUndo(_ held: SQLDurabilityFixture, fault: PagedSQLitePublicCommitFault)
    async throws -> (SQLDurabilityNative, PagedNativePreparedHistoryMove) {
    let native = try await native(held)
    try native.replaceFirst("b"); _ = try await native.seal()
    XCTAssertEqual(native.commands.manager.undoCount, 1)
    try await held.engine!._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: fault)
    native.commands.manager.undo() // actual Foundation admitted advancement/inverse
    try await requireActualRefusal(held, message: "The actual faulted Undo publication unexpectedly joined.") {
      try await native.commands.joinPendingCommand()
    }
    let prepared = try XCTUnwrap(native.commands.retainedPreparation)
    XCTAssertNotNil(native.session.historyFailure); XCTAssertNotNil(native.commands.firstFailure)
    XCTAssertTrue(native.session.hasPendingHistoryCommand)
    XCTAssertEqual(native.commands.manager.undoCount, 0); XCTAssertEqual(native.commands.manager.redoCount, 1)
    return (native, prepared)
  }

  func testActualEnteredCommitVetoRepairsBeforeThenExplicitHistoryCompletion() async throws {
    try await fixture("testActualEnteredCommitVetoRepairsBeforeThenExplicitHistoryCompletion") { held in
      let (native, prepared) = try await self.failedUndo(held, fault: .veto)
      let engine = try XCTUnwrap(held.engine)
      let fenced = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertEqual(fenced.storage.failedOperationID, prepared.preparationID)
      guard case .conflict = try await native.session.inspectHistoryRecovery() else { throw BoomError.invalid("Visible before alone improperly granted completion.") }
      guard case .verifiedNotPublished(let verification) = try await native.session.repairHistoryDurability() else {
        throw BoomError.invalid("Actual vetoed COMMIT did not settle the exact durable before state.")
      }
      let repairedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      let barrier = try XCTUnwrap(repairedSnapshot.storage.lastCheckpoint)
      XCTAssertEqual(barrier.code, 0); XCTAssertEqual(barrier.logFrames, 0); XCTAssertEqual(barrier.copiedFrames, 0); XCTAssertEqual(barrier.afterWALBytes, 0)
      XCTAssertNotNil(native.commands.firstFailure) // separate receiving owner still owns original intent
      try native.session.completeVerifiedHistory(verification)
      let acknowledgement = try await native.session.joinHistoryPublication(commandID: prepared.command.commandID)
      try await native.completeHistoryReceiving(acknowledgement)
      XCTAssertEqual(Data(native.view.string.utf8), Data("a public🙂\n".utf8))
      try await self.read(held, record: acknowledgement.sealedRootRecord, text: "a public🙂\n")
      native.commands.manager.redo(); try await native.commands.joinPendingCommand()
      let returned = try await native.seal()
      XCTAssertEqual(Data(native.view.string.utf8), Data("b public🙂\n".utf8))
      try await self.read(held, record: returned, text: "b public🙂\n")
    }
  }

  // Public protection admission fault; actual Apple live recovery remains unqualified.
  func testActualPostCommitProtectionFailureRequiresBarrierThenInstalledHistoryFinish() async throws {
    try await fixture("testActualPostCommitProtectionFailureRequiresBarrierThenInstalledHistoryFinish") { held in
      let (native, prepared) = try await self.failedUndo(held, fault: .changeProtection)
      let engine = try XCTUnwrap(held.engine), identity = try XCTUnwrap(held.identity)
      let writes = (try await engine.nativeSQLMaintenanceSnapshot()).storage.failedOperationID
      XCTAssertEqual(writes, prepared.preparationID)
      try await engine._publicSQLControlRestoreDatabaseProtection(identity: identity)
      guard case .conflict = try await native.session.inspectHistoryRecovery() else { throw BoomError.invalid("Authenticated visible after improperly granted durable native installation.") }
      guard case .published(let acknowledgement) = try await native.session.repairHistoryDurability() else {
        throw BoomError.invalid("Actual committed publication did not repair its same operation/full records.")
      }
      XCTAssertEqual(acknowledgement.expectedRootRecord, prepared.command.expectedRootRecord)
      XCTAssertEqual(acknowledgement.sealedRootRecord, prepared.candidateRecord)
      let pending = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertEqual(pending.storage.failedOperationID, prepared.preparationID) // receiving still outstanding
      try native.session.acceptRecoveredHistory(acknowledgement)
      try await native.completeHistoryReceiving(acknowledgement)
      let joinedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNil(joinedSnapshot.storage.failedOperationID)
      try await self.read(held, record: acknowledgement.sealedRootRecord, text: "a public🙂\n")
      // Exact still-current finish uses its real completion; no second command
      // or checkpoint. This is not a row-absence or historical ACK assertion.
      let joinedCheckpoint = (try await engine.nativeSQLMaintenanceSnapshot()).storage.lastCheckpoint?.operationID
      _ = try await native.session.joinHistoryPublication(commandID: acknowledgement.commandID)
      let retriedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertEqual(retriedSnapshot.storage.lastCheckpoint?.operationID, joinedCheckpoint)
    }
  }

  func testActualOrdinaryAfterRepairKeepsLaterAcceptedCharactersAndOrderedHistory() async throws {
    try await fixture("testActualOrdinaryAfterRepairKeepsLaterAcceptedCharactersAndOrderedHistory") { held in
      let native = try await self.native(held), engine = try XCTUnwrap(held.engine)
      try await engine._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: .changeProtection)
      try native.replaceFirst("b")
      try await self.requireActualRefusal(held, message: "The actual post-COMMIT ordinary fault unexpectedly joined.") {
        _ = try await native.seal()
      }
      XCTAssertNotNil(native.session.persistenceFailure)
      try native.replaceFirst("c") // actually accepted while the b prefix failed
      XCTAssertEqual(native.session.generation, 2)
      XCTAssertEqual(Data(native.view.string.utf8), Data("c public🙂\n".utf8))
      try await engine._publicSQLControlRestoreDatabaseProtection(identity: try XCTUnwrap(held.identity))
      let acknowledgement = try await native.session.repairCommitDurability()
      XCTAssertEqual(acknowledgement.lastSequence, 1)
      XCTAssertEqual(Data(acknowledgement.sealedWindow.text.utf8), Data("b public🙂\n".utf8))
      XCTAssertEqual(Data(native.view.string.utf8), Data("c public🙂\n".utf8))
      XCTAssertNotNil(native.session.lastDurabilityRepairOriginalFailure)
      let final = try await native.seal()
      XCTAssertEqual(final.document.revision, native.session.canonicalHistory?.record.document.revision)
      try await self.read(held, record: final, text: "c public🙂\n")
      XCTAssertEqual(native.commands.manager.undoCount, native.session.canonicalHistory?.undo.count)
      XCTAssertNil(native.input.firstRefusal); XCTAssertNil(native.commands.firstFailure)
    }
  }

  func testActualFreshFormatFailureRetainsSameOwnerUntilExplicitRepair() async throws {
    try await fixture("testActualFreshFormatFailureRetainsSameOwnerUntilExplicitRepair", setupFailureExpected: true) { held in
      let failure = try XCTUnwrap(held.setupFailure), originalEngine = failure.engine
      XCTAssertTrue(held.engine === originalEngine)
      XCTAssertEqual(originalEngine.custodySnapshot.items.count, 1)
      try await originalEngine._publicSQLControlRestoreFailedSetupProtection(failure)
      let result = try await originalEngine.repairFailedSetupOpening(failure)
      guard case .opened(let returned, _) = result else { throw BoomError.invalid("Actual visible committed format did not join opening.") }
      XCTAssertTrue(returned === originalEngine)
      XCTAssertTrue(returned.custodySnapshot.items.isEmpty)
      held.setupFailure = nil // original Error remains in bounded evidence array
      held.identity = try await returned._publicSQLControlIdentity(expectedVault: held.vault, expectedStoreID: held.storeID)
      let publisher = try await returned.makeWorkspacePublisher(); held.publisher = publisher
      let initial = try await returned.initializeWorkspaceRetaining(publisher, state: WorkspaceState(), documents: [])
      XCTAssertTrue(initial.value.documents.isEmpty); XCTAssertEqual(initial.value.head.generation, 0)
      try await returned.finishWorkspacePublication(initial, publisher: publisher)
      try await returned.abandonJoinedRootOutput(initial.lease)
      let loaded = try await returned.loadWorkspaceRetaining(publisher)
      XCTAssertEqual(loaded.value, initial.value)
      try await returned.abandonJoinedRootOutput(loaded.lease)
    }
  }


  func testActualLostCommitACKReturnsOriginalControllerOutputAndKeepsLaterTyping() async throws {
    try await fixture("testActualLostCommitACKReturnsOriginalControllerOutputAndKeepsLaterTyping") { held in
      let native = try await self.native(held, loseCommitReply: true), engine = try XCTUnwrap(held.engine)
      let before = try XCTUnwrap(native.session.canonicalHistory?.record)
      try native.replaceFirst("b")
      try await self.requireActualRefusal(held, message: "The actual forwarder did not lose its joined commit reply.") {
        _ = try await native.seal()
      }
      let pending = try XCTUnwrap(engine.custodySnapshot.items.first { $0.pendingBatchID != nil })
      let originalBatch = try XCTUnwrap(pending.pendingBatchID)
      XCTAssertEqual(pending.sqlOperationID, originalBatch)
      XCTAssertEqual(pending.controllerSequence, 1); XCTAssertEqual(pending.sqlReceivingJoined, false)
      XCTAssertEqual(native.session.canonicalHistory?.record, before)
      XCTAssertNil(native.session.pendingCommitInstallation) // Main has not received ACK
      let beforeRecovery = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNil(beforeRecovery.storage.failedOperationID) // real COMMIT already succeeded
      try native.replaceFirst("c")
      XCTAssertEqual(native.session.generation, 2)
      let acknowledgement = try await native.session.repairCommitDurability()
      XCTAssertEqual(acknowledgement.batchID, originalBatch); XCTAssertEqual(acknowledgement.lastSequence, 1)
      XCTAssertEqual(acknowledgement.expectedRootRecord, before)
      XCTAssertEqual(Data(acknowledgement.sealedWindow.text.utf8), Data("b public🙂\n".utf8))
      XCTAssertEqual(Data(native.view.string.utf8), Data("c public🙂\n".utf8))
      XCTAssertNotNil(native.session.lastDurabilityRepairOriginalFailure)
      let final = try await native.seal()
      try await self.read(held, record: final, text: "c public🙂\n")
      let afterRecovery = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertEqual(afterRecovery.storage.lastCheckpoint?.operationID, beforeRecovery.storage.lastCheckpoint?.operationID)
      XCTAssertFalse(engine.custodySnapshot.items.contains { $0.pendingBatchID == originalBatch })
      XCTAssertNil(native.session.persistenceFailure); XCTAssertNil(native.session.pendingCommitInstallation)
      XCTAssertNil(native.input.firstRefusal); XCTAssertNil(native.commands.firstFailure)
      // Repeat the delivery loss AFTER a real unknown COMMIT has been repaired
      // to AFTER. Its exact physical fence must survive the lost reply and be
      // read through the same outcome, then released only by actual finish.
      let forwarder = try XCTUnwrap(held.lostACKForwarder)
      try await forwarder.armNextActualReplyLoss()
      try await engine._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: .changeProtection)
      try native.replaceFirst("d")
      try await self.requireActualRefusal(held, message: "Actual post-COMMIT protection admission failure was not entered.") {
        _ = try await native.seal()
      }
      let originalFailure = try await engine.nativeSQLMaintenanceSnapshot()
      let failedOperation = try XCTUnwrap(originalFailure.storage.failedOperationID)
      try await engine._publicSQLControlRestoreDatabaseProtection(identity: try XCTUnwrap(held.identity))
      try await self.requireActualRefusal(held, message: "The real repaired ACK reply was not lost.") {
        _ = try await native.session.repairCommitDurability()
      }
      let retainedAfter = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertEqual(retainedAfter.storage.failedOperationID, failedOperation)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.pendingBatchID == failedOperation && $0.sqlReceivingJoined == false })
      XCTAssertNil(native.session.pendingCommitInstallation)
      XCTAssertEqual(native.session.canonicalHistory?.record, final)
      try native.replaceFirst("e")
      let repairedAck = try await native.session.repairCommitDurability()
      XCTAssertEqual(repairedAck.batchID, failedOperation); XCTAssertEqual(repairedAck.lastSequence, 3)
      XCTAssertEqual(repairedAck.expectedRootRecord, final)
      XCTAssertEqual(Data(repairedAck.sealedWindow.text.utf8), Data("d public🙂\n".utf8))
      XCTAssertEqual(Data(native.view.string.utf8), Data("e public🙂\n".utf8))
      let last = try await native.seal()
      try await self.read(held, record: last, text: "e public🙂\n")
      let joined = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNil(joined.storage.failedOperationID)
      XCTAssertEqual(joined.storage.lastCheckpoint?.operationID, retainedAfter.storage.lastCheckpoint?.operationID)
      XCTAssertNil(native.session.persistenceFailure); XCTAssertNil(native.session.pendingCommitInstallation)
    }
  }

  func testActualOrdinaryBeforeKeepsAcceptedPrefixAndLaterInputUntilExplicitSameBatchRetry() async throws {
    try await fixture("testActualOrdinaryBeforeKeepsAcceptedPrefixAndLaterInputUntilExplicitSameBatchRetry") { held in
      let native = try await self.native(held), engine = try XCTUnwrap(held.engine)
      let before = try XCTUnwrap(native.session.canonicalHistory?.record)
      try await engine._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: .veto)
      try native.replaceFirst("b")
      try await self.requireActualRefusal(held, message: "The actual ordinary veto unexpectedly published.") {
        _ = try await native.seal()
      }
      let failedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      let actualOperation = try XCTUnwrap(failedSnapshot.storage.failedOperationID)
      XCTAssertNotNil(native.session.persistenceFailure)
      try native.replaceFirst("c") // admitted G+1 stays in the same physical arena
      XCTAssertEqual(native.session.generation, 2)
      guard case .knownUnpublished(let verificationID) = try await native.session.inspectCommitRecovery() else {
        throw BoomError.invalid("The actual entered veto did not resolve exact unpublished input.")
      }
      XCTAssertEqual(native.session.canonicalHistory?.record, before)
      XCTAssertEqual(Data(native.view.string.utf8), Data("c public🙂\n".utf8))
      XCTAssertNotNil(native.session.persistenceFailure) // BEFORE is not receiving
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.sqlOperationID == actualOperation && $0.producerJoined })
      try await self.read(held, record: before, text: "a public🙂\n")
      let inspectedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      let checkpoint = try XCTUnwrap(inspectedSnapshot.storage.lastCheckpoint)
      XCTAssertEqual(checkpoint.operationID, actualOperation)
      XCTAssertEqual(checkpoint.code, 0); XCTAssertEqual(checkpoint.afterWALBytes, 0)
      let ack = try await native.session.completeVerifiedCommit(verificationID: verificationID)
      XCTAssertEqual(ack.batchID, actualOperation); XCTAssertEqual(ack.lastSequence, 1)
      XCTAssertEqual(ack.expectedRootRecord, before)
      XCTAssertEqual(Data(ack.sealedWindow.text.utf8), Data("b public🙂\n".utf8))
      XCTAssertEqual(Data(native.view.string.utf8), Data("c public🙂\n".utf8))
      XCTAssertNotNil(native.session.lastDurabilityRepairOriginalFailure)
      let final = try await native.seal()
      try await self.read(held, record: final, text: "c public🙂\n")
      XCTAssertEqual(native.commands.manager.undoCount, native.session.canonicalHistory?.undo.count)
      XCTAssertNil(native.session.pendingCommitInstallation); XCTAssertNil(native.session.persistenceFailure)
      let finishedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNil(finishedSnapshot.storage.failedOperationID)
    }
  }

  func testActualInitialWorkspaceBeforeRetriesSamePreparedPartsThenRealMetadataReceiving() async throws {
    try await fixture("testActualInitialWorkspaceBeforeRetriesSamePreparedPartsThenRealMetadataReceiving") { held in
      let engine = try XCTUnwrap(held.engine), publisher = try await engine.makeWorkspacePublisher()
      held.publisher = publisher
      try await engine._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: .veto)
      var original: PagedTextCustodyFailure?
      var unexpected: PagedTextCustodiedValue<PagedWorkspaceSnapshot>?
      do { unexpected = try await engine.initializeWorkspaceRetaining(publisher, state: WorkspaceState(), documents: []) }
      catch let failure as PagedTextCustodyFailure { original = failure; try held.preserve(failure.original) }
      guard unexpected == nil else { throw BoomError.invalid("Initial publication did not hit its actual COMMIT veto; actual output retained.") }
      let failed = try XCTUnwrap(original)
      // A visibility read cannot grant receiving or discard the original lease.
      let before = try await engine.resolveSQLiteOutputRetaining(failed.lease, publisher: publisher)
      guard case .before(let execution) = before.value else { throw BoomError.invalid("Initial metadata did not select its exact absent BEFORE authority.") }
      XCTAssertEqual(before.lease, failed.lease); XCTAssertTrue(execution.selectedBefore)
      XCTAssertNotNil(execution.original)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == failed.lease.id })
      let saved = try await engine.retryWorkspaceBeforeRetaining(failed.lease, publisher: publisher)
      XCTAssertEqual(saved.lease, failed.lease); XCTAssertTrue(saved.value.documents.isEmpty)
      XCTAssertEqual(saved.value.head.generation, 0)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == saved.lease.id && $0.sqlReceivingJoined == false })
      try await engine.finishWorkspacePublication(saved, publisher: publisher)
      // Same still-retained actual finish is idempotent, without a disk write.
      try await engine.finishWorkspacePublication(saved, publisher: publisher)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == saved.lease.id && $0.sqlReceivingJoined == true })
      try await engine.abandonJoinedRootOutput(saved.lease)
      let loaded = try await engine.loadWorkspaceRetaining(publisher)
      XCTAssertEqual(loaded.value, saved.value)
      try await engine.abandonJoinedRootOutput(loaded.lease)
      XCTAssertTrue(engine.custodySnapshot.items.isEmpty)
    }
  }

  func testActualWholeWorkspaceAfterUsesNormalMetadataReceivingAndPreservesNativeSource() async throws {
    try await fixture("testActualWholeWorkspaceAfterUsesNormalMetadataReceivingAndPreservesNativeSource") { held in
      let native = try await self.native(held), engine = try XCTUnwrap(held.engine)
      let publisher = try XCTUnwrap(held.publisher), record = try await native.seal()
      let before = try await engine.loadWorkspaceRetaining(publisher)
      let expectedHead = before.value.head
      try await engine.abandonJoinedRootOutput(before.lease)
      var state = WorkspaceState()
      state.documents = [DocumentIndex(id: record.document.id, title: record.document.title)]
      state.selectedDocument = nil // real metadata change, same immutable source
      try await engine._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: .changeProtection)
      var original: PagedTextCustodyFailure?
      var unexpected: PagedTextCustodiedValue<PagedWorkspaceSnapshot>?
      do { unexpected = try await engine.publishWorkspaceRetaining(publisher, state: state,
        documents: [record], expectedHead: expectedHead) }
      catch let failure as PagedTextCustodyFailure { original = failure; try held.preserve(failure.original) }
      guard unexpected == nil else { throw BoomError.invalid("Whole metadata missed the actual post-COMMIT protection admission failure; actual output retained.") }
      let failed = try XCTUnwrap(original)
      XCTAssertEqual(native.session.canonicalHistory?.record, record)
      try await engine._publicSQLControlRestoreDatabaseProtection(identity: try XCTUnwrap(held.identity))
      let resolved = try await engine.resolveSQLiteOutputRetaining(failed.lease, publisher: publisher)
      guard case .workspace(let snapshot) = resolved.value else { throw BoomError.invalid("Whole metadata did not return its actual normal AFTER snapshot.") }
      XCTAssertEqual(resolved.lease, failed.lease); XCTAssertEqual(snapshot.documents, [record])
      XCTAssertEqual(snapshot.head.generation, expectedHead.generation + 1)
      XCTAssertNotEqual(snapshot.head.workspace, expectedHead.workspace)
      let pendingSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNotNil(pendingSnapshot.storage.failedOperationID)
      let output = PagedTextCustodiedValue(value: snapshot, lease: resolved.lease)
      try await engine.finishWorkspacePublication(output, publisher: publisher)
      try await engine.abandonJoinedRootOutput(output.lease)
      let finishedSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNil(finishedSnapshot.storage.failedOperationID)
      let metadata = try await engine.loadWorkspaceCatalogRetaining(publisher)
      XCTAssertEqual(metadata.value.snapshot, snapshot); XCTAssertNil(metadata.value.state.selectedDocument)
      XCTAssertEqual(metadata.value.state.documents.map(\.id), [record.document.id])
      try await engine.abandonJoinedRootOutput(metadata.lease)
      // A later real native commit reuses this new immutable metadata reference.
      try native.replaceFirst("b"); let edited = try await native.seal()
      try await self.read(held, record: edited, text: "b public🙂\n")
      let finalMetadata = try await engine.loadWorkspaceCatalogRetaining(publisher)
      XCTAssertEqual(finalMetadata.value.snapshot.head.workspace, snapshot.head.workspace)
      XCTAssertNil(finalMetadata.value.state.selectedDocument)
      try await engine.abandonJoinedRootOutput(finalMetadata.lease)
    }
  }

  func testNewActualRefusedInputSurvivesOlderCommitDurabilityRepair() async throws {
    try await fixture("testNewActualRefusedInputSurvivesOlderCommitDurabilityRepair", retainedTerminal: true) { held in
      let native = try await self.native(held), engine = try XCTUnwrap(held.engine)
      try await engine._publicSQLControlArmCommitFault(identity: try XCTUnwrap(held.identity), fault: .moveDatabaseName)
      try native.replaceFirst("b")
      try await self.requireActualRefusal(held, message: "The actual original source fault unexpectedly joined.") {
        _ = try await native.seal()
      }
      let generation = native.session.generation
      // The actual requested Undo blocks at its prefix admission because the
      // original source seal failed. Do not fabricate a prefix that Session
      // refused to reserve. Root's queued command lane still owns the intent
      // and must retain the actual original intercepted event.
      native.commands.manager.undo()
      try await self.requireActualRefusal(held, message: "The original failed prefix unexpectedly admitted Undo.") {
        try await native.commands.joinPendingCommand()
      }
      let prefix = native.commands.retainedPrefix
      let identity = native.input.activeIdentity
      weak var originalEvent: NSEvent?
      try autoreleasepool {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: native.window.windowNumber,
          context: nil, characters: "Ω", charactersIgnoringModifiers: "Ω", isARepeat: false, keyCode: 6))
        originalEvent = event; native.view.keyDown(with: event)
      }
      XCTAssertNotNil(originalEvent); XCTAssertEqual(native.commands.queuedRawKeyCount, 1)
      XCTAssertEqual(native.commands.unretainedRawKeyCount, 0)
      // Actual bounded physical selection rejection, before any AppKit source
      // mutation. Its diagnostic is independent of the retained raw event.
      native.view.setSelectedRange(NSRange(location: Int.max, length: 1))
      XCTAssertEqual(native.session.generation, generation)
      XCTAssertNotNil(native.input.firstRefusal)
      XCTAssertEqual(Data(native.view.string.utf8), Data("b public🙂\n".utf8))
      try await engine._publicSQLControlRestoreDatabaseName(identity: try XCTUnwrap(held.identity))
      // If the actual client also advances Session's failure serial, the exact
      // older ticket correctly refuses. Otherwise it may repair only its own
      // source failure; the independent original input remains blocked.
      do { _ = try await native.session.repairCommitDurability() }
      catch { try held.preserve(error) }
      XCTAssertNotNil(native.input.firstRefusal)
      XCTAssertEqual(Data(native.view.string.utf8), Data("b public🙂\n".utf8))
      XCTAssertEqual(native.input.activeIdentity, identity)
      XCTAssertEqual(native.commands.retainedPrefix, prefix)
      XCTAssertEqual(native.commands.queuedRawKeyCount, 1); XCTAssertNotNil(originalEvent)
      var closeRefused = false
      do { try native.commands.closeInput() }
      catch { closeRefused = true; try held.preserve(error) }
      guard closeRefused else { throw BoomError.invalid("Independent refusal/original raw event was dropped by physical close.") }
      // No Engine.close: retained source/input owner remains truthful. The
      // nominated fresh process preserves diagnostics and has no passing close.
      XCTAssertFalse(held.closed); XCTAssertEqual(engine.custodySnapshot.jobs, 0)
    }
  }
}
#endif
