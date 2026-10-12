import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY: real SQLite/executor/custody dependencies are not executed.

/// Scheduling only: every successful value comes from the actual encrypted
/// backend. Calls and timers are retained and joined, including failed calls.
private actor PagedCommandLaneControlledStorage: PagedNativeHistorySessionStorage, PagedNativeCommitInstallationStorage {
  struct JoinedPrefix: Sendable { let sessionID: UUID; let sequence: UInt64; let record: PagedDocumentRootRecord }
  enum Point: Hashable, Sendable {
    case commitBefore, commitAfter, prepareAfter, historyBefore, historyAfter, windowAfter, conflictAfter
  }
  struct Ticket: Sendable { let id: UUID }
  struct Snapshot: Sendable {
    let batches: [PagedNativeCommitBatch]
    let historyResults: [PagedNativeHistoryAcknowledgement]
    let activeCalls: Int
    let startedCalls: Int
    let finishedCalls: Int
    let injectedReplyLosses: Int
    let latestJoinedPrefix: JoinedPrefix?
  }
  private struct Hold {
    let point: Point
    var arrived = false
    var released = false
    var failure: Error?
    var observers: [CheckedContinuation<Void, Error>] = []
    var producer: CheckedContinuation<Void, Never>?
  }
  private let backend: PagedNativeStorageBackend
  private var pending: [Point: UUID] = [:]
  private var holds: [UUID: Hold] = [:]
  private var timers: [Task<Void, Never>] = []
  private var realJoins: [Task<Void, Never>] = []
  private var active = 0
  private var started = 0
  private var finished = 0
  private var closing = false
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var batches: [PagedNativeCommitBatch] = []
  private var historyResults: [PagedNativeHistoryAcknowledgement] = []
  private var loseHistoryReply = false
  private var injectedReplyLosses = 0
  private var latestJoinedPrefix: JoinedPrefix?

  init(_ backend: PagedNativeStorageBackend) { self.backend = backend }

  func holdNext(_ point: Point) throws -> Ticket {
    guard !closing, pending[point] == nil, holds.count < 16 else {
      throw BoomError.budget("The public control has another hold or exceeds its fixed hold budget.")
    }
    let id = UUID()
    pending[point] = id; holds[id] = Hold(point: point)
    timers.append(Task { [weak self] in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      await self?.expire(id)
    })
    return Ticket(id: id)
  }

  func awaitHeld(_ ticket: Ticket) async throws {
    guard let hold = holds[ticket.id] else { throw BoomError.invalid("Unknown public scheduling hold.") }
    if let failure = hold.failure { throw failure }
    if hold.arrived { return }
    try await withCheckedThrowingContinuation { holds[ticket.id]?.observers.append($0) }
  }

  func release(_ ticket: Ticket) throws {
    guard var hold = holds[ticket.id] else { throw BoomError.invalid("Unknown public scheduling release.") }
    hold.released = true
    let producer = hold.producer; hold.producer = nil
    holds[ticket.id] = hold
    producer?.resume()
  }

  private func expire(_ id: UUID) {
    guard var hold = holds[id], !hold.released else { return }
    hold.failure = BoomError.unavailable("The public scheduling control missed its ten-second deadline.")
    hold.released = true
    let observers = hold.observers, producer = hold.producer
    hold.observers.removeAll(); hold.producer = nil; holds[id] = hold
    for observer in observers { observer.resume(throwing: hold.failure!) }
    producer?.resume()
  }

  private func pass(_ point: Point?) async throws {
    guard let point, let id = pending.removeValue(forKey: point), var hold = holds[id] else { return }
    hold.arrived = true
    let observers = hold.observers; hold.observers.removeAll(); holds[id] = hold
    for observer in observers { observer.resume() }
    if !hold.released {
      await withCheckedContinuation { holds[id]?.producer = $0 }
    }
    if let failure = holds[id]?.failure { throw failure }
  }

  private func finishCall() {
    active -= 1; finished += 1
    if active == 0 {
      let waiters = idleWaiters; idleWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private func failHolds(_ points: [Point?], error: Error) {
    for point in points.compactMap({ $0 }) {
      guard let id = pending.removeValue(forKey: point), var hold = holds[id] else { continue }
      hold.failure = error; hold.released = true
      let observers = hold.observers; hold.observers.removeAll(); holds[id] = hold
      for observer in observers { observer.resume(throwing: error) }
    }
  }

  private func forward<T: Sendable>(before: Point? = nil, after: Point? = nil,
    _ call: @escaping @Sendable () async throws -> T) async throws -> T {
    guard !closing, active < 8, started < 512 else {
      throw BoomError.unavailable("The public control route is closing or exceeds its call budget.")
    }
    active += 1; started += 1
    defer { finishCall() }
    do {
      try await pass(before)
      let realCall = Task { try await call() }
      realJoins.append(Task { _ = try? await realCall.value })
      let result = try await realCall.value
      try await pass(after)
      return result
    } catch {
      failHolds([before, after], error: error)
      throw error
    }
  }

  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    batches.append(batch)
    let backend = backend
    let acknowledgement = try await forward(before: .commitBefore, after: .commitAfter) { try await backend.commit(batch) }
    latestJoinedPrefix = JoinedPrefix(sessionID: acknowledgement.sessionID,
      sequence: acknowledgement.lastSequence, record: acknowledgement.sealedRootRecord)
    return acknowledgement
  }
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    let backend = backend
    try await forward { try await backend.finishCommitInstallation(acknowledgement) }
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64,
    maximumBytes: Int) async throws -> PagedTextWindow {
    let backend = backend
    return try await forward(after: .windowAfter) {
      try await backend.window(expected: expected, utf16Anchor: utf16Anchor, maximumBytes: maximumBytes)
    }
  }
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove {
    let backend = backend
    return try await forward(after: .prepareAfter) { try await backend.prepareHistoryMove(command) }
  }
  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    let backend = backend
    let result = try await forward(before: .historyBefore, after: .historyAfter) {
      try await backend.commitPreparedHistory(prepared, admission: admission)
    }
    historyResults.append(result)
    latestJoinedPrefix = JoinedPrefix(sessionID: result.sessionID, sequence: result.admittedSequence, record: result.sealedRootRecord)
    if loseHistoryReply {
      loseHistoryReply = false; injectedReplyLosses += 1
      throw BoomError.unavailable("Public control deliberately lost the joined real history reply.")
    }
    return result
  }
  func noteHistoryInputConflict(_ prepared: PagedNativePreparedHistoryMove,
    observation: PagedNativeHistoryInputObservation) async throws -> PagedNativeHistoryInputConflictReceipt {
    let backend = backend
    return try await forward(after: .conflictAfter) {
      try await backend.noteHistoryInputConflict(prepared, observation: observation)
    }
  }
  func resolveUnadmittedHistory(_ prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) async throws -> PagedNativeHistoryIntentDispositionReceipt {
    let backend = backend
    return try await forward { try await backend.resolveUnadmittedHistory(prepared, disposition: disposition) }
  }
  func inspectHistoryRecovery(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    let backend = backend
    return try await forward { try await backend.inspectHistoryRecovery(prepared) }
  }
  func completeVerifiedHistory(_ prepared: PagedNativePreparedHistoryMove,
    verificationID: UUID) async throws -> PagedNativeHistoryAcknowledgement {
    let backend = backend
    return try await forward { try await backend.completeVerifiedHistory(prepared, verificationID: verificationID) }
  }
  func finishHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws {
    let backend = backend
    try await forward { try await backend.finishHistoryInstallation(prepared, admission: admission) }
  }
  func loseNextJoinedHistoryReply() { loseHistoryReply = true }
  var snapshot: Snapshot {
    Snapshot(batches: batches, historyResults: historyResults, activeCalls: active,
      startedCalls: started, finishedCalls: finished, injectedReplyLosses: injectedReplyLosses,
      latestJoinedPrefix: latestJoinedPrefix)
  }

  /// Refuse new forwarded work, release every existing hold and join every
  /// actual call before the engine can close. Timers also join on every path.
  func closeAndJoin() async {
    closing = true
    for id in Array(holds.keys) {
      guard var hold = holds[id] else { continue }
      hold.released = true
      let producer = hold.producer, observers = hold.observers
      hold.producer = nil; hold.observers.removeAll(); holds[id] = hold
      producer?.resume()
      for observer in observers { observer.resume(throwing: BoomError.unavailable("The public fixture is joining.")) }
    }
    for timer in timers { timer.cancel() }
    if active != 0 { await withCheckedContinuation { idleWaiters.append($0) } }
    for join in realJoins { await join.value }
    for timer in timers { await timer.value }
  }
}

private struct PagedCommandLaneSetup: Sendable {
  let root: URL
  let ownerID: UUID
  let storeID: UUID
  let sqlIdentity: PagedSQLPublicControlIdentity
  let vault: Vault
  let engine: PagedTextEngineAdapter
  let publisher: PagedWorkspacePublisher
  let record: PagedDocumentRootRecord
  let window: PagedTextWindow
  let backend: PagedNativeStorageBackend
}

@MainActor private final class PagedCommandLaneFixture {
  let setup: PagedCommandLaneSetup
  let route: PagedCommandLaneControlledStorage
  let session: PagedNativeSession
  let view: PagedNativeTextView
  private var observers: [Task<Void, Never>] = []
  private var additionalRoutes: [PagedCommandLaneControlledStorage] = []
  private var readOutputs: [PagedTextRootLease] = []
  private var receivingIntents: [PagedNativeRetainedHistoryIntent] = []
  private let maintenance: PagedSQLNativeFixtureMaintenance

  init(_ setup: PagedCommandLaneSetup) throws {
    let route = PagedCommandLaneControlledStorage(setup.backend)
    let session = try PagedNativeSession(window: setup.window, rootRecord: setup.record, storage: route)
    let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
    self.setup = setup; self.route = route; self.session = session; self.view = view
    maintenance = PagedSQLNativeFixtureMaintenance(engine: setup.engine)
  }
  func own<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
    let task = Task { try await body() }
    observers.append(Task { _ = try? await task.value })
    return task
  }
  func retainRoute(_ route: PagedCommandLaneControlledStorage) { additionalRoutes.append(route) }
  func replaceFirst(with text: String, separateGroup: Bool = true) throws {
    if separateGroup { view.boundedStorage.beginNativeGroup() }
    let previous = session.generation
    view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: text)
    if let error = view.boundedStorage.mutationFailure { throw error }
    guard session.generation == previous + 1 else { throw BoomError.invalid("Public native edit was not accepted exactly once.") }
  }
  func retainReadAdmission() throws {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public command-lane read custody exceeds its fixed bound.") }
  }
  func retainJoinedRead(_ lease: PagedTextRootLease) { readOutputs.append(lease) }
  func snapshot() async throws -> PagedWorkspaceSnapshot {
    try retainReadAdmission()
    let output = try await setup.engine.loadWorkspaceRetaining(setup.publisher)
    retainJoinedRead(output.lease); return output.value
  }
  func history(_ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    try retainReadAdmission()
    let output = try await setup.engine._publicSQLControlHistoryRetaining(identity: setup.sqlIdentity, record: record)
    retainJoinedRead(output.lease); return output.value
  }
  func source(_ revision: PagedTextRevision) async throws -> PagedTextWindow {
    try retainReadAdmission()
    let output = try await setup.engine.windowRetaining(revision, byteStart: 0, maximumBytes: 16_384)
    retainJoinedRead(output.lease); return output.value
  }
  func retainHistoryIntent(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeRetainedHistoryIntent {
    guard receivingIntents.count < 8 else { throw BoomError.budget("Actual command-lane receiving intents exceed their bounded owner.") }
    let receipt = try setup.engine.retainNativeHistoryIntent(prepared)
    receivingIntents.append(receipt)
    return receipt
  }
  func preparedUndo() async throws -> PagedNativePreparedHistoryMove {
    let snapshot = try await snapshot(), record = try XCTUnwrap(snapshot.documents.first)
    let retained = try await history(record), top = try XCTUnwrap(retained.undo.last)
    let prefix = try session.reservePrefix()
    return try await session.prepareHistoryMove(PagedNativeHistoryHandle(documentID: record.document.id,
      groupID: top.groupID, direction: .undo), prefix: prefix)
  }
  func joinCallsPreservingFailure() async {
    await route.closeAndJoin()
    for additional in additionalRoutes { await additional.closeAndJoin() }
    for observer in observers { await observer.value }
    await route.closeAndJoin()
  }
  func retainExpectedFailedInput() async throws {
    await joinCallsPreservingFailure()
    for joined in [route] + additionalRoutes {
      let status = await joined.snapshot
      guard status.activeCalls == 0, status.startedCalls == status.finishedCalls else {
        throw BoomError.invalid("The retained failed input left an actual producer unjoined.")
      }
    }
    let custody = setup.engine.custodySnapshot
    guard custody.jobs == 0, session.hasPendingHistoryCommand,
      session.persistenceFailure != nil, session.historyFailure != nil,
      custody.items.contains(where: { item in
        guard case .nativeBatch(let sessionID, _, _, _) = item.purpose else { return false }
        return sessionID == session.sessionID && item.phase == .unresolved
          && item.claims.contains(.record(setup.record))
      }) else {
      throw BoomError.stale("The original failed batch/input/intent or actual producer join was lost.")
    }
    // Retain this exact owner. A joined producer is not a native receive,
    // controller detach, WAL maintenance or successful SQL/Rust close.
  }
  func join() async throws {
    await joinCallsPreservingFailure()
    _ = try session.windowForNativeInstallation() // Actual joined source/notification/navigation admission, not a close proof.
    for joined in [route] + additionalRoutes {
      let status = await joined.snapshot
      guard status.activeCalls == 0, status.startedCalls == status.finishedCalls else {
        throw BoomError.invalid("The public native control left an actual call unjoined.")
      }
    }
    let status = await route.snapshot
    let prefix = status.latestJoinedPrefix
    let current = try await snapshot()
    let record = prefix?.record ?? setup.record
    guard current.documents.contains(record) else { throw BoomError.stale("Actual joined command prefix is no longer the full published record.") }
    try await setup.backend.detachJoinedController(sessionID: prefix?.sessionID,
      sequence: prefix?.sequence ?? 0, record: record)
    for intent in receivingIntents { try setup.engine.releaseRetainedHistoryIntent(intent) }
    receivingIntents.removeAll()
    for output in readOutputs { try await setup.engine.abandonJoinedRootOutput(output) }
    readOutputs.removeAll()
    try await maintenance.drainAfterJoinedNativeCalls()
    try await setup.engine.close()
  }
}

/// Authored real native/storage component controls only. The ordinary input
/// escrow and UndoManager timeline policy remain absent and unactivated.
@MainActor final class PagedNativeCommandLaneTests: XCTestCase {
  private struct CipherWitness: Sendable {
    let engine: PagedTextEngineAdapter
    let identity: PagedSQLPublicControlIdentity
    let value: PagedSQLPublicCiphertextWitness
    let mutation: PagedSQLPublicMutationReceipt
    let fixture: PagedCommandLaneFixture
  }
  private static var retainedRoot: URL?
  private static var retainedEngine: PagedTextEngineAdapter?
  private static var retainedSetup: PagedCommandLaneSetup?
  private static var terminalFixture: PagedCommandLaneFixture?

  private func withFixture(text: String = "a public🙂\n", preserveOnSuccess: Bool = false,
    _ body: @MainActor (PagedCommandLaneFixture) async throws -> Void) async throws {
    if preserveOnSuccess {
      guard ProcessInfo.processInfo.environment["BLOOM_PAGED_COMMAND_ISOLATED_CASE"]
        == "testRawIntentDispositionCannotDiscardAnActuallyFailedInputBatch" else {
        throw BoomError.denied("Retained failed input requires its exact disposable process; no fixture entered.")
      }
    }
    guard Self.retainedRoot == nil, Self.retainedEngine == nil, Self.retainedSetup == nil,
      Self.terminalFixture == nil else { throw BoomError.denied("A failed command-lane owner still owns this public process.") }
    _ = NSApplication.shared
    let initialFailures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-native-command-lane-" + UUID().uuidString)
    Self.retainedRoot = root
    print("Public command-lane SQL fixture: \(root.path)")
    let opened = try await Task.detached {
      let ownerID = UUID(), storeID = UUID()
      let vault = try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x73, count: 32)))
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: ownerID, sqliteOpening: .fresh(storeID: storeID))
      return (ownerID: ownerID, storeID: storeID, vault: vault, engine: engine)
    }.value
    Self.retainedEngine = opened.engine
    let identity = try await opened.engine._publicSQLControlIdentity(expectedVault: opened.vault, expectedStoreID: opened.storeID)
    let setup = try await Task.detached {
      let engine = opened.engine, input = root.appendingPathComponent("public-input.utf8")
      try Data(text.utf8).write(to: input, options: .withoutOverwriting)
      let file = try FileHandle(forReadingFrom: input)
      let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
      do { imported = try await engine.importUTF8Retaining(documentID: UUID(), from: file) }
      catch {
        let original = error
        do { try file.close() } catch { XCTFail("Public command input close also failed: \(error)") }
        throw original
      }
      do { try file.close() } catch { throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
      let document = PagedDocumentDescriptor(id: imported.value.revision.documentID, title: "Public café", revision: imported.value.revision)
      let initial = try await engine.initialNativeRecordRetaining(document), publisher = try await engine.makeWorkspacePublisher()
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
      state.selectedDocument = document.id
      let workspace = try await engine.initializeWorkspaceRetaining(publisher, state: state, documents: [initial.value])
      try await engine.finishWorkspacePublication(workspace, publisher: publisher)
      try await engine.transferJoinedRootToHead(imported.lease, publisher: publisher, expected: initial.value)
      try await engine.transferJoinedRootToHead(initial.lease, publisher: publisher, expected: initial.value)
      try await engine.abandonJoinedRootOutput(workspace.lease)
      let backend = try await engine.makeNativeStorage(publisher, expected: initial.value)
      let window = try await backend.window(expected: initial.value.document.revision, utf16Anchor: 0,
        maximumBytes: PagedWorkingWindow.targetBytes)
      return PagedCommandLaneSetup(root: root, ownerID: opened.ownerID, storeID: opened.storeID, sqlIdentity: identity,
        vault: opened.vault, engine: engine, publisher: publisher, record: initial.value, window: window, backend: backend)
    }.value
    Self.retainedSetup = setup
    let fixture = try PagedCommandLaneFixture(setup)
    Self.retainedRoot = nil; Self.retainedEngine = nil; Self.retainedSetup = nil
    do {
      try await body(fixture)
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public command-lane assertions failed.") }
      if preserveOnSuccess {
        Self.terminalFixture = fixture
        try await fixture.retainExpectedFailedInput()
        guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Retained failed-input producer joins recorded failed assertions.") }
        print("RETAINED_TERMINAL public SQL failed batch/input/intent; no controller detach, maintenance or joined close: \(root.path)")
        return
      }
      try await fixture.join()
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public command-lane join assertions failed.") }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
    } catch {
      let original = error
      Self.terminalFixture = fixture
      await fixture.joinCallsPreservingFailure()
      XCTFail("Public command-lane failure and exact native/SQL custody retained at \(root.path): \(original)")
      throw original
    }
  }

  private func assertStale(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try operation(); XCTFail("Expected exact native identity refusal.", file: file, line: line) }
    catch { if case BoomError.stale = error { return }; XCTFail("Expected stale refusal: \(error)", file: file, line: line) }
  }
  private func assertStaleAsync(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected exact native identity refusal.", file: file, line: line) }
    catch { if case BoomError.stale = error { return }; XCTFail("Expected stale refusal: \(error)", file: file, line: line) }
  }
  private func assertSource(_ fixture: PagedCommandLaneFixture, equals text: String) async throws {
    let snapshot = try await fixture.snapshot(), record = try XCTUnwrap(snapshot.documents.first)
    let actual = try await fixture.source(record.document.revision)
    XCTAssertEqual(Data(actual.text.utf8), Data(text.utf8))
    let retained = try await fixture.history(record)
    XCTAssertEqual(retained.current, record.document.revision)
  }

  func testHeldEarlierBatchReservedPrefixAndCompactedLaterNativeEditsStaySeparate() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitAfter)
      try fixture.replaceFirst(with: "b")
      try await fixture.route.awaitHeld(hold)
      try fixture.replaceFirst(with: "c")
      let prefix = try fixture.session.reservePrefix(), sourceArena = fixture.session.arenaID
      for index in 0..<97 { try fixture.replaceFirst(with: index.isMultiple(of: 2) ? "d" : "e") }
      let laterText = fixture.view.string, laterGeneration = fixture.session.generation
      XCTAssertEqual(prefix.generation, 2); XCTAssertEqual(laterGeneration, 99)
      try await fixture.route.release(hold)
      let captured = try await fixture.session.flush(prefix)
      XCTAssertEqual(captured.window.text, "c public🙂\n")
      XCTAssertEqual(captured.reservation, prefix); XCTAssertEqual(fixture.view.string, laterText)
      XCTAssertEqual(fixture.session.generation, laterGeneration); XCTAssertEqual(fixture.session.arenaID, sourceArena)
      let beforeRelease = await fixture.route.snapshot
      XCTAssertEqual(beforeRelease.batches.map(\.lastSequence), [1, 2])
      try await assertSource(fixture, equals: "c public🙂\n")
      try fixture.session.releasePrefix(prefix)
      _ = try await fixture.session.flush(through: laterGeneration)
      let joined = await fixture.route.snapshot, last = try XCTUnwrap(joined.batches.last)
      XCTAssertEqual(last.firstSequence, 3); XCTAssertEqual(last.lastSequence, 99)
      XCTAssertLessThanOrEqual(last.deltas.count, PagedWorkingWindow.maximumQueuedDeltas)
      XCTAssertEqual(last.expectedRootRecord, captured.rootRecord)
      try await assertSource(fixture, equals: laterText)
    }
  }

  func testMarkedInputAfterReservationCannotPinTheEarlierExactPrefix() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitAfter)
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      try fixture.replaceFirst(with: "c")
      let prefix = try fixture.session.reservePrefix()
      fixture.view.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 1))
      XCTAssertTrue(fixture.view.hasMarkedText()); XCTAssertTrue(fixture.session.isPinned)
      let marked = fixture.view.markedRange(), text = fixture.view.string, generation = fixture.session.generation
      try await fixture.route.release(hold)
      let captured = try await fixture.session.flush(prefix)
      XCTAssertEqual(captured.window.text, "c public🙂\n")
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(fixture.view.markedRange(), marked)
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertTrue(fixture.session.isPinned)
      try fixture.session.releasePrefix(prefix)
      fixture.view.unmarkText()
      XCTAssertFalse(fixture.session.isPinned); XCTAssertFalse(fixture.view.hasMarkedText())
      _ = try await fixture.session.flush(through: generation)
      try await assertSource(fixture, equals: text)
    }
  }

  func testProvisionalHistoryAndLaterNativeTypingSurviveTheRealHistoryAcknowledgement() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let before = fixture.session.sealedRevision, prepared = try await fixture.preparedUndo()
      let historyHold = try await fixture.route.holdNext(.historyBefore)
      let admission = try fixture.view.installPreparedHistory(prepared)
      try await fixture.route.awaitHeld(historyHold)
      XCTAssertEqual(fixture.session.generation, 2); XCTAssertEqual(fixture.session.sealedRevision, before)
      XCTAssertEqual(fixture.session.sourceBaseRevision, prepared.window.revision)
      fixture.view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
      fixture.view.insertText("y", replacementRange: NSRange(location: 1, length: 0))
      let text = fixture.view.string, generation = fixture.session.generation
      let laterHold = try await fixture.route.holdNext(.commitBefore)
      try await fixture.route.release(historyHold)
      let ack = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      try await fixture.route.awaitHeld(laterHold)
      XCTAssertEqual(ack.admittedSequence, 2); XCTAssertEqual(ack.sealedWindow.windowID, prepared.window.windowID)
      XCTAssertEqual(fixture.session.arenaID, admission.provisionalArenaID)
      XCTAssertEqual(fixture.session.sealedRevision, prepared.window.revision)
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(generation, 4)
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertFalse(fixture.session.isProvisionalHistory)
      let batches = await fixture.route.snapshot, later = try XCTUnwrap(batches.batches.last)
      XCTAssertEqual(later.firstSequence, 3); XCTAssertEqual(later.lastSequence, 4)
      XCTAssertEqual(later.expectedRootRecord, ack.sealedRootRecord)
      XCTAssertEqual(later.afterBytes, Data(text.utf8))
      try await fixture.route.release(laterHold)
      _ = try await fixture.session.flush(through: generation)
      try await assertSource(fixture, equals: "xya public🙂\n")
    }
  }

  func testMarkedInputInTheProvisionalArenaSurvivesAckAndSealsOnlyOnUnmark() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.preparedUndo(), hold = try await fixture.route.holdNext(.historyBefore)
      _ = try fixture.view.installPreparedHistory(prepared); try await fixture.route.awaitHeld(hold)
      fixture.view.setMarkedText("文🙂", selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
      let marked = fixture.view.markedRange(), text = fixture.view.string, generation = fixture.session.generation
      XCTAssertTrue(fixture.session.isPinned); XCTAssertTrue(fixture.view.hasMarkedText())
      try await fixture.route.release(hold)
      let ack = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      XCTAssertEqual(ack.admittedSequence, 2); XCTAssertEqual(fixture.view.string, text)
      XCTAssertEqual(fixture.view.markedRange(), marked); XCTAssertTrue(fixture.session.isPinned)
      XCTAssertEqual(fixture.session.generation, generation)
      let beforeUnmark = await fixture.route.snapshot
      XCTAssertEqual(beforeUnmark.batches.count, 1)
      fixture.view.unmarkText()
      _ = try await fixture.session.flush(through: generation)
      XCTAssertFalse(fixture.session.isPinned); XCTAssertFalse(fixture.view.hasMarkedText())
      let afterUnmark = await fixture.route.snapshot, later = try XCTUnwrap(afterUnmark.batches.last)
      XCTAssertEqual(later.firstSequence, 3); XCTAssertEqual(later.expectedRootRecord, ack.sealedRootRecord)
      try await assertSource(fixture, equals: text)
    }
  }

  func testWrongCommandControllerArenasWindowsAndFullRecordRefuseWithoutWorkingMutation() async throws {
    try await withFixture { fixture in
      var working = try PagedWorkingWindow(window: fixture.setup.window, rootRecord: fixture.setup.record)
      let group = UUID()
      XCTAssertTrue(try working.replace(NSRange(location: 0, length: 1), with: "b", groupID: group))
      let batch = try XCTUnwrap(working.takeCommitBatch()), ack = try await fixture.route.commit(batch)
      try working.acknowledge(ack)
      try await fixture.route.finishCommitInstallation(ack)
      let prefix = try working.reservePrefix()
      let command = PagedNativeHistoryMoveCommand(sessionID: working.sessionID, commandID: UUID(),
        sourceArenaID: working.arenaID, sourceWindowID: working.sealedWindow.windowID,
        expectedSequence: 1, expectedRootRecord: working.sealedRootRecord,
        handle: PagedNativeHistoryHandle(documentID: fixture.setup.record.document.id, groupID: group, direction: .undo))
      let prepared = try await fixture.route.prepareHistoryMove(command)
      func admission(commandID: UUID? = nil, preparationID: UUID? = nil, sessionID: UUID? = nil,
        sourceArenaID: UUID? = nil, provisionalArenaID: UUID? = nil, sourceWindowID: UUID? = nil,
        preparedWindowID: UUID? = nil, expectedSequence: UInt64 = 1, admittedSequence: UInt64 = 2,
        record: PagedDocumentRootRecord? = nil) -> PagedNativeHistoryAdmission {
        PagedNativeHistoryAdmission(commandID: commandID ?? command.commandID,
          preparationID: preparationID ?? prepared.preparationID, sessionID: sessionID ?? command.sessionID,
          sourceArenaID: sourceArenaID ?? command.sourceArenaID, provisionalArenaID: provisionalArenaID ?? UUID(),
          sourceWindowID: sourceWindowID ?? command.sourceWindowID, preparedWindowID: preparedWindowID ?? prepared.window.windowID,
          expectedSequence: expectedSequence, admittedSequence: admittedSequence, expectedRootRecord: record ?? command.expectedRootRecord)
      }
      let newerEpoch = PagedDocumentRootRecord(document: command.expectedRootRecord.document,
        historyPage: command.expectedRootRecord.historyPage, historyGeneration: command.expectedRootRecord.historyGeneration + 1)
      let variants = [admission(commandID: UUID()), admission(preparationID: UUID()), admission(sessionID: UUID()),
        admission(sourceArenaID: UUID()), admission(provisionalArenaID: command.sourceArenaID),
        admission(sourceWindowID: UUID()), admission(preparedWindowID: UUID()), admission(expectedSequence: 0),
        admission(admittedSequence: 3), admission(record: newerEpoch)]
      let bytes = working.bytes, arena = working.arenaID, record = working.sealedRootRecord
      for variant in variants {
        assertStale { try working.installProvisionalHistory(prepared, admission: variant) }
        XCTAssertEqual(working.bytes, bytes); XCTAssertEqual(working.arenaID, arena)
        XCTAssertEqual(working.generation, 1); XCTAssertEqual(working.sealedRootRecord, record)
        XCTAssertEqual(working.reservedPrefix, prefix); XCTAssertFalse(working.hasProvisionalHistory)
      }
      let actual = try await fixture.snapshot()
      XCTAssertEqual(actual.documents.first, record)
      _ = try await fixture.route.resolveUnadmittedHistory(prepared, disposition: .explicitlyAbandoned)
      try working.releasePrefix(prefix)
    }
  }

  func testForeignPreparationAndOldNSTextStorageCannotMutateTheNewArena() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let oldStorage = try PagedNativeTextStorage(session: fixture.session)
      let current = try await fixture.snapshot(), record = try XCTUnwrap(current.documents.first)
      let backend = try await fixture.setup.engine.makeNativeStorage(fixture.setup.publisher, expected: record)
      let foreignRoute = PagedCommandLaneControlledStorage(backend); fixture.retainRoute(foreignRoute)
      let foreignWindow = try await foreignRoute.window(expected: record.document.revision,
        utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
      let foreignSession = try PagedNativeSession(window: foreignWindow, rootRecord: record, storage: foreignRoute)
      let foreignView = try PagedNativeTextView(frame: .zero, session: foreignSession)
      let history = try await fixture.history(record), top = try XCTUnwrap(history.undo.last)
      let foreignPrefix = try foreignSession.reservePrefix()
      let foreign = try await foreignSession.prepareHistoryMove(PagedNativeHistoryHandle(documentID: record.document.id,
        groupID: top.groupID, direction: .undo), prefix: foreignPrefix)
      let prepared = try await fixture.preparedUndo(), before = fixture.view.string, arena = fixture.session.arenaID
      assertStale { _ = try fixture.view.installPreparedHistory(foreign) }
      XCTAssertEqual(fixture.view.string, before); XCTAssertEqual(fixture.session.arenaID, arena)
      XCTAssertEqual(fixture.session.generation, 1); XCTAssertFalse(fixture.session.isProvisionalHistory)
      _ = try await foreignSession.resolveUnadmittedHistory(.explicitlyAbandoned)
      XCTAssertEqual(foreignView.string, before)
      // Join this actual foreign command owner while its exact source record
      // is still published. After the primary Undo its old record cannot be
      // transferred to the newer head and must never be guessed/rebased.
      _ = try foreignSession.windowForNativeInstallation()
      await foreignRoute.closeAndJoin()
      try await backend.detachJoinedController(sessionID: foreignSession.sessionID,
        sequence: foreignSession.generation, record: record)
      let hold = try await fixture.route.holdNext(.historyBefore)
      _ = try fixture.view.installPreparedHistory(prepared); try await fixture.route.awaitHeld(hold)
      let installed = fixture.view.string, installedArena = fixture.session.arenaID
      oldStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
      XCTAssertNotNil(oldStorage.mutationFailure)
      XCTAssertEqual(oldStorage.string, before); XCTAssertEqual(fixture.view.string, installed)
      XCTAssertEqual(fixture.session.arenaID, installedArena); XCTAssertEqual(fixture.session.generation, 2)
      try await fixture.route.release(hold)
      _ = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      try await assertSource(fixture, equals: installed)
    }
  }

  func testPrefixReservationInvalidatesAnAlreadyLoadedRealNavigationWindow() async throws {
    try await withFixture(text: String(repeating: "a", count: 512)) { fixture in
      let hold = try await fixture.route.holdNext(.windowAfter)
      let navigation = fixture.own { try await fixture.session.navigate(toUTF16: 100) }
      try await fixture.route.awaitHeld(hold)
      let arena = fixture.session.arenaID, text = fixture.view.string
      let prefix = try fixture.session.reservePrefix()
      try await fixture.route.release(hold)
      await assertStaleAsync { _ = try await navigation.value }
      XCTAssertEqual(fixture.session.arenaID, arena); XCTAssertEqual(fixture.session.generation, 0)
      XCTAssertEqual(fixture.view.string, text)
      _ = try await fixture.session.flush(prefix); try fixture.session.releasePrefix(prefix)
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      try await assertSource(fixture, equals: "b" + String(repeating: "a", count: 511))
    }
  }

  func testLostRealPublishedReplyIsAuthenticatedThenConsumedWithoutReplacingLaterNativeInput() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.preparedUndo(), hold = try await fixture.route.holdNext(.historyAfter)
      await fixture.route.loseNextJoinedHistoryReply()
      _ = try fixture.view.installPreparedHistory(prepared); try await fixture.route.awaitHeld(hold)
      fixture.view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
      let text = fixture.view.string, generation = fixture.session.generation
      try await fixture.route.release(hold)
      do { _ = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID); XCTFail("Lost reply was treated as delivered.") }
      catch { if case BoomError.unavailable = error {} else { XCTFail("Unexpected reply-loss result: \(error)") } }
      XCTAssertTrue(fixture.session.isProvisionalHistory); XCTAssertNotNil(fixture.session.persistenceFailure)
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(fixture.session.generation, generation)
      let actual = try await fixture.snapshot()
      XCTAssertEqual(actual.documents.first, prepared.candidateRecord)
      let recovery = try await fixture.session.inspectHistoryRecovery()
      guard case .published(let recovered) = recovery else { throw BoomError.invalid("Real completed publication was not authenticated.") }
      let later = try await fixture.route.holdNext(.commitBefore)
      try fixture.session.acceptRecoveredHistory(recovered)
      _ = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      try await fixture.route.awaitHeld(later)
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(fixture.session.generation, generation)
      XCTAssertFalse(fixture.session.isProvisionalHistory); XCTAssertNil(fixture.session.persistenceFailure)
      let status = await fixture.route.snapshot
      XCTAssertEqual(status.injectedReplyLosses, 1); XCTAssertEqual(status.historyResults.count, 1)
      XCTAssertEqual(status.batches.last?.expectedRootRecord, recovered.sealedRootRecord)
      try await fixture.route.release(later)
      _ = try await fixture.session.flush(through: generation)
      try await assertSource(fixture, equals: text)
    }
  }

  private func corruptCandidate(_ fixture: PagedCommandLaneFixture,
    prepared: PagedNativePreparedHistoryMove) async throws -> CipherWitness {
    try await corruptHistoryRecord(fixture: fixture, record: prepared.candidateRecord)
  }
  private func corruptHistoryRecord(fixture: PagedCommandLaneFixture,
    record: PagedDocumentRootRecord) async throws -> CipherWitness {
    try fixture.retainReadAdmission()
    let output = try await fixture.setup.engine._publicSQLControlCiphertextWitnessRetaining(
      identity: fixture.setup.sqlIdentity, record: record, target: .historyManifest)
    fixture.retainJoinedRead(output.lease)
    try fixture.retainReadAdmission()
    let mutation = try await fixture.setup.engine._publicSQLControlCorruptRetaining(identity: fixture.setup.sqlIdentity, witness: output.value)
    fixture.retainJoinedRead(mutation.lease)
    return CipherWitness(engine: fixture.setup.engine, identity: fixture.setup.sqlIdentity,
      value: output.value, mutation: mutation.value, fixture: fixture)
  }
  private func restore(_ witness: CipherWitness) async throws {
    try witness.fixture.retainReadAdmission()
    let restored = try await witness.engine._publicSQLControlRestoreRetaining(identity: witness.identity, witness: witness.value)
    witness.fixture.retainJoinedRead(restored.lease)
    guard case .restoration = restored.value.mutation,
      restored.value.witnessID == witness.value.id, restored.value.record == witness.value.record else { throw BoomError.invalid("Actual SQL witness restoration returned another identity.") }
    // This only restores a known-successful guarded mutation. Any refused source
    // COMMIT keeps its independent Store fence; no verified-not-published permit
    // or lost native output is synthesized by this helper.
  }

  func testAuthenticatedBeforeRecordPermitCompletesExactlyOnceAndKeepsProvisionalTyping() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let before = try await fixture.snapshot(), prepared = try await fixture.preparedUndo()
      let hold = try await fixture.route.holdNext(.historyBefore)
      _ = try fixture.view.installPreparedHistory(prepared); try await fixture.route.awaitHeld(hold)
      fixture.view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
      let text = fixture.view.string, generation = fixture.session.generation
      let witness = try await corruptCandidate(fixture, prepared: prepared)
      try await fixture.route.release(hold)
      do { _ = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID); XCTFail("Corrupt candidate published.") }
      catch { if case CryptoKitError.authenticationFailure = pagedSQLUnderlyingRefusal(error) {} else { XCTFail("Expected actual AEAD refusal: \(error)") } }
      XCTAssertEqual(fixture.view.string, text); XCTAssertTrue(fixture.session.isProvisionalHistory)
      let unchanged = try await fixture.snapshot(); XCTAssertEqual(unchanged, before)
      do { _ = try await fixture.session.inspectHistoryRecovery(); XCTFail("Corrupt candidate permitted completion.") }
      catch { if case CryptoKitError.authenticationFailure = pagedSQLUnderlyingRefusal(error) {} else { XCTFail("Expected candidate AEAD refusal: \(error)") } }
      try await restore(witness)
      let recovery = try await fixture.session.inspectHistoryRecovery()
      guard case .verifiedNotPublished(let permit) = recovery else { throw BoomError.invalid("Exact authenticated before record yielded no completion permit.") }
      let later = try await fixture.route.holdNext(.commitBefore)
      try fixture.session.completeVerifiedHistory(permit)
      let ack = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      try await fixture.route.awaitHeld(later)
      XCTAssertEqual(ack.sealedRootRecord, prepared.candidateRecord)
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(fixture.session.generation, generation)
      assertStale { try fixture.session.completeVerifiedHistory(permit) }
      try await fixture.route.release(later)
      _ = try await fixture.session.flush(through: generation)
      try await assertSource(fixture, equals: text)
    }
  }

  func testOwnedBoundsAccountForTheHeldBatchCapturedPrefixAndLaterCompactedGroups() async throws {
    try await withFixture(text: String(repeating: "a", count: 16_000)) { fixture in
      var working = try PagedWorkingWindow(window: fixture.setup.window, rootRecord: fixture.setup.record)
      for index in 0..<100 {
        XCTAssertTrue(try working.replace(NSRange(location: 0, length: 1),
          with: index.isMultiple(of: 2) ? "b" : "a", groupID: UUID()))
      }
      let earlier = try XCTUnwrap(working.takeCommitBatch()), hold = try await fixture.route.holdNext(.commitAfter)
      let earlierCall = fixture.own { try await fixture.route.commit(earlier) }
      try await fixture.route.awaitHeld(hold)
      for index in 0..<100 {
        XCTAssertTrue(try working.replace(NSRange(location: 0, length: 1),
          with: index.isMultiple(of: 2) ? "b" : "a", groupID: UUID()))
      }
      let prefix = try working.reservePrefix()
      for index in 0..<117 {
        XCTAssertTrue(try working.replace(NSRange(location: 0, length: 1),
          with: index.isMultiple(of: 2) ? "b" : "a", groupID: UUID()))
        XCTAssertLessThanOrEqual(working.chargedOwnedGroupBytes, PagedWorkingWindow.maximumOwnedGroupBytes)
        XCTAssertLessThanOrEqual(working.chargedOwnedDeltaBytes, PagedWorkingWindow.maximumOwnedDeltaBytes)
        XCTAssertLessThanOrEqual(working.queuedDeltaCount, PagedWorkingWindow.maximumQueuedDeltas)
      }
      XCTAssertEqual(prefix.generation, 200); XCTAssertEqual(working.generation, 317)
      XCTAssertGreaterThan(working.chargedOwnedGroupBytes, PagedWorkingWindow.maximumResidentGroupBytes)
      XCTAssertGreaterThan(working.chargedOwnedDeltaBytes, working.chargedQueueBytes)
      let laterBytes = working.bytes
      try await fixture.route.release(hold)
      let earlierAck = try await earlierCall.value
      try working.acknowledge(earlierAck)
      try await fixture.route.finishCommitInstallation(earlierAck)
      let captured = try XCTUnwrap(working.takeCommitBatch())
      XCTAssertEqual(captured.firstSequence, 101); XCTAssertEqual(captured.lastSequence, 200)
      let capturedAck = try await fixture.route.commit(captured)
      try working.acknowledge(capturedAck)
      try await fixture.route.finishCommitInstallation(capturedAck)
      let sealed = try working.sealedPrefix(prefix)
      XCTAssertEqual(sealed.window.text, String(repeating: "a", count: 16_000))
      XCTAssertEqual(working.bytes, laterBytes)
      try working.releasePrefix(prefix)
      let later = try XCTUnwrap(working.takeCommitBatch())
      XCTAssertEqual(later.firstSequence, 201); XCTAssertEqual(later.lastSequence, 317)
      XCTAssertEqual(later.expectedRootRecord, capturedAck.sealedRootRecord)
      XCTAssertEqual(later.groupCheckpoints.count, PagedRootHistory.maximumEntries)
      XCTAssertNotNil(later.historyBaseline)
      let laterAck = try await fixture.route.commit(later)
      try working.acknowledge(laterAck)
      try await fixture.route.finishCommitInstallation(laterAck)
      XCTAssertEqual(working.sealedGeneration, 317); XCTAssertEqual(working.bytes, laterBytes)
      XCTAssertEqual(working.chargedOwnedDeltaBytes, 0); XCTAssertEqual(working.chargedOwnedGroupBytes, 0)
      let actual = try await fixture.snapshot()
      XCTAssertEqual(actual.documents.first, laterAck.sealedRootRecord)
      let retained = try await fixture.history(laterAck.sealedRootRecord)
      XCTAssertEqual(retained.undo.count, 100); XCTAssertTrue(retained.redo.isEmpty)
    }
  }

  func testRefusedWorkerPreparationKeepsRawIntentUntilExplicitJoinedDisposition() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prefix = try fixture.session.reservePrefix(), captured = try await fixture.session.flush(prefix)
      let requested = PagedNativeHistoryHandle(documentID: fixture.setup.record.document.id, groupID: UUID(), direction: .undo)
      await assertStaleAsync { _ = try await fixture.session.prepareHistoryMove(requested, prefix: prefix) }
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand); XCTAssertNotNil(fixture.session.historyFailure)
      XCTAssertEqual(fixture.view.string, "b public🙂\n"); XCTAssertEqual(fixture.session.generation, 1)
      assertStale { try fixture.session.releasePrefix(prefix) }
      let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
      do { _ = try fixture.session.resolveUnpreparedHistory(.transferredToRetainedOwner(receiptID: zero)); XCTFail("Empty raw-intent custody receipt admitted.") }
      catch { if case BoomError.invalid = error {} else { XCTFail("Unexpected raw-intent receipt refusal: \(error)") } }
      // The actual receiving test owner retains the original handle and exact
      // joined prefix before release. This is not a production collector ledger.
      let receivingID = UUID(), receiving = [receivingID: (requested, captured)]
      let disposition = try fixture.session.resolveUnpreparedHistory(.transferredToRetainedOwner(receiptID: receivingID))
      XCTAssertEqual(receiving[receivingID]?.0.groupID, disposition.handle.groupID)
      XCTAssertEqual(receiving[receivingID]?.1.rootRecord, disposition.prefix.rootRecord)
      XCTAssertEqual(disposition.prefix.reservation, prefix)
      XCTAssertFalse(fixture.session.hasPendingHistoryCommand); XCTAssertNil(fixture.session.historyFailure)
      try fixture.replaceFirst(with: "c"); _ = try await fixture.session.flush(through: 2)
      try await assertSource(fixture, equals: "c public🙂\n")
    }
  }

  func testConflictNotificationCannotRaceInstallationAfterANoEditCompositionEnds() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.preparedUndo(), hold = try await fixture.route.holdNext(.conflictAfter)
      // A no-edit native composition pin reproduces the await race without
      // disguising a generation change as the reason installation is refused.
      fixture.session.beginComposition()
      let conflict = fixture.own { try await fixture.session.retainHistoryInputConflict() }
      try await fixture.route.awaitHeld(hold)
      fixture.session.endComposition()
      XCTAssertFalse(fixture.session.isPinned); XCTAssertEqual(fixture.session.generation, prepared.command.expectedSequence)
      let text = fixture.view.string, arena = fixture.session.arenaID
      assertStale { _ = try fixture.view.installPreparedHistory(prepared) }
      await assertStaleAsync { _ = try await fixture.session.resolveUnadmittedHistory(.explicitlyAbandoned) }
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(fixture.session.arenaID, arena)
      XCTAssertFalse(fixture.session.isProvisionalHistory); XCTAssertNil(fixture.session.persistenceFailure)
      try await fixture.route.release(hold)
      let receipt = try await conflict.value
      XCTAssertEqual(receipt.prepared, prepared); XCTAssertTrue(receipt.observation.compositionPinned)
      let actualRecipient = try fixture.retainHistoryIntent(receipt.prepared)
      let receivingID = actualRecipient.receiptID, receiving = [receivingID: actualRecipient.prepared]
      let transfer = try await fixture.session.resolveUnadmittedHistory(.transferredToRetainedOwner(receiptID: receivingID))
      XCTAssertEqual(receiving[receivingID], transfer.prepared)
      XCTAssertEqual(fixture.view.string, text); XCTAssertFalse(fixture.session.hasPendingHistoryCommand)
      try fixture.replaceFirst(with: "c"); _ = try await fixture.session.flush(through: 2)
      try await assertSource(fixture, equals: "c public🙂\n")
    }
  }

  func testRawIntentDispositionCannotDiscardAnActuallyFailedInputBatch() async throws {
    try await withFixture(preserveOnSuccess: true) { fixture in
      let hold = try await fixture.route.holdNext(.commitBefore)
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      let prefix = try fixture.session.reservePrefix()
      let requested = PagedNativeHistoryHandle(documentID: fixture.setup.record.document.id, groupID: UUID(), direction: .undo)
      let prepare = fixture.own { try await fixture.session.prepareHistoryMove(requested, prefix: prefix) }
      let witness = try await corruptHistoryRecord(fixture: fixture, record: fixture.setup.record)
      try await fixture.route.release(hold)
      do { _ = try await prepare.value; XCTFail("Failed source input was treated as a joined prefix.") }
      catch { if case CryptoKitError.authenticationFailure = pagedSQLUnderlyingRefusal(error) {} else { XCTFail("Expected real input AEAD refusal: \(error)") } }
      assertStale { _ = try fixture.session.resolveUnpreparedHistory(.explicitlyAbandoned) }
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand)
      XCTAssertNotNil(fixture.session.persistenceFailure); XCTAssertNotNil(fixture.session.historyFailure)
      XCTAssertEqual(fixture.session.generation, 1); XCTAssertEqual(fixture.view.string, "b public🙂\n")
      try await restore(witness)
      let actual = try await fixture.snapshot()
      XCTAssertEqual(actual.documents.first, fixture.setup.record)
      // Preserve the exact public dirty input and before-record evidence at
      // the terminal refusal boundary, rather than deleting a successful test
      // fixture that intentionally has unresolved native custody.
      let root = fixture.setup.root, input = Data(fixture.view.string.utf8)
      let before = fixture.setup.record, captured = prefix
      try await Task.detached {
        try input.write(to: root.appendingPathComponent("retained-native-input.utf8"), options: .withoutOverwriting)
        try JSONEncoder().encode(before).write(to: root.appendingPathComponent("retained-before-record.json"), options: .withoutOverwriting)
        let receipt: [String: String] = ["schema": "1", "status": "expected-input-refusal-no-retry",
          "session": captured.sessionID.uuidString, "arena": captured.arenaID.uuidString,
          "reservation": captured.reservationID.uuidString, "generation": String(captured.generation)]
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("retained-refusal.json"), options: .withoutOverwriting)
      }.value
    }
  }

  func testUndoManagerInverseRegistrationIsSynchronousAndSeparateFromNativeActivation() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let before = try await fixture.snapshot(), record = try XCTUnwrap(before.documents.first)
      let retained = try await fixture.history(record), top = try XCTUnwrap(retained.undo.last)
      let handle = PagedNativeHistoryHandle(documentID: record.document.id, groupID: top.groupID, direction: .undo)
      let manager = UndoManager(); manager.groupsByEvent = false
      var deliveries: [(PagedNativeHistoryHandle, Bool, Bool)] = []
      let registration = PagedNativeUndoRegistration(manager: manager) {
        deliveries.append(($0, manager.isUndoing, manager.isRedoing))
      }
      manager.beginUndoGrouping(); registration.register(handle, actionName: "Public"); manager.endUndoGrouping()
      manager.undo()
      XCTAssertTrue(manager.canRedo); XCTAssertEqual(deliveries.count, 1)
      XCTAssertEqual(deliveries.first?.0.groupID, handle.groupID)
      XCTAssertEqual(deliveries.first?.0.direction, .undo); XCTAssertEqual(deliveries.first?.1, true)
      manager.redo()
      XCTAssertTrue(manager.canUndo); XCTAssertEqual(deliveries.count, 2)
      XCTAssertEqual(deliveries.last?.0.direction, .redo); XCTAssertEqual(deliveries.last?.2, true)
      XCTAssertFalse(fixture.view.allowsUndo); XCTAssertFalse(fixture.session.hasPendingHistoryCommand)
      XCTAssertEqual(fixture.session.generation, 1); XCTAssertEqual(fixture.view.string, "b public🙂\n")
      let after = try await fixture.snapshot(); XCTAssertEqual(after, before)
      manager.removeAllActions(withTarget: registration)
    }
  }
}

#endif
