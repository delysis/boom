import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

// SOURCE ONLY: this SQL fixture port and its exact composed dependencies are
// unparsed, uncompiled and unrun. Guard omission supplies no qualification.

/// Scheduling only: every successful value comes from the actual encrypted
/// backend. Calls and timers are retained and joined, including failed calls.
// Shared only by the authored staged/managed XCTest controls in this module.
// Scheduling gates always forward the actual encrypted backend.
actor PagedStagedControlledStorage: PagedNativeHistorySessionStorage, PagedNativeCommitInstallationStorage, PagedNativeDocumentNavigationStorage {
  enum Point: Hashable, Sendable {
    case commitBefore, commitAfter, commitInstallationBefore, commitInstallationAfter,
      prepareAfter, historyBefore, historyAfter, historyInstallationBefore, windowAfter, conflictAfter
  }
  struct Ticket: Sendable { let id: UUID }
  struct Snapshot: Sendable {
    let batches: [PagedNativeCommitBatch]
    let historyResults: [PagedNativeHistoryAcknowledgement]
    let preparations: [PagedNativePreparedHistoryMove]
    let activeCalls: Int
    let startedCalls: Int
    let finishedCalls: Int
    let injectedReplyLosses: Int
    let commitInstallations: [PagedNativeCommitAcknowledgement]
    let injectedCommitInstallationLosses: Int
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
  private var preparations: [PagedNativePreparedHistoryMove] = []
  private var loseHistoryReply = false
  private var injectedReplyLosses = 0
  private var commitInstallations: [PagedNativeCommitAcknowledgement] = []
  private var loseCommitInstallationReply = false
  private var injectedCommitInstallationLosses = 0

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
    guard !closing, active < 8, started < 128 else {
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
    guard !closing, batches.count < 128 else { throw BoomError.budget("Public staged batch evidence exceeds its fixed bound.") }
    batches.append(batch)
    let backend = backend
    return try await forward(before: .commitBefore, after: .commitAfter) { try await backend.commit(batch) }
  }
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    let backend = backend
    try await forward(before: .commitInstallationBefore, after: .commitInstallationAfter) {
      try await backend.finishCommitInstallation(acknowledgement)
    }
    guard commitInstallations.count < 16 else { throw BoomError.budget("Public staged installation evidence exceeds its fixed bound.") }
    commitInstallations.append(acknowledgement)
    if loseCommitInstallationReply {
      loseCommitInstallationReply = false; injectedCommitInstallationLosses += 1
      throw BoomError.unavailable("Public control deliberately lost the joined real ACK custody completion reply.")
    }
  }
  func documentPosition(expected: PagedTextRevision, utf16Offset: UInt64,
    forward: Bool) async throws -> PagedTextSummary {
    let backend = backend
    return try await self.forward {
      try await backend.documentPosition(expected: expected, utf16Offset: utf16Offset, forward: forward)
    }
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64,
    maximumBytes: Int) async throws -> PagedTextWindow {
    let backend = backend
    return try await forward(after: .windowAfter) {
      try await backend.window(expected: expected, utf16Anchor: utf16Anchor, maximumBytes: maximumBytes)
    }
  }
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove {
    guard !closing, preparations.count < 16 else { throw BoomError.budget("Public staged preparation evidence exceeds its fixed bound.") }
    let backend = backend
    let result = try await forward(after: .prepareAfter) { try await backend.prepareHistoryMove(command) }
    guard preparations.count < 16 else { throw BoomError.budget("Public staged preparation evidence exceeds its fixed bound.") }
    preparations.append(result)
    return result
  }
  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    let backend = backend
    let result = try await forward(before: .historyBefore, after: .historyAfter) {
      try await backend.commitPreparedHistory(prepared, admission: admission)
    }
    guard historyResults.count < 16 else { throw BoomError.budget("Public staged history evidence exceeds its fixed bound.") }
    historyResults.append(result)
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
    try await forward(before: .historyInstallationBefore) { try await backend.finishHistoryInstallation(prepared, admission: admission) }
  }
  func loseNextJoinedHistoryReply() { loseHistoryReply = true }
  func loseNextJoinedCommitInstallationReply() { loseCommitInstallationReply = true }
  var snapshot: Snapshot {
    Snapshot(batches: batches, historyResults: historyResults, preparations: preparations, activeCalls: active,
      startedCalls: started, finishedCalls: finished, injectedReplyLosses: injectedReplyLosses,
      commitInstallations: commitInstallations, injectedCommitInstallationLosses: injectedCommitInstallationLosses)
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

struct PagedStagedSetup: Sendable {
  let root: URL
  let ownerID: UUID
  let vault: Vault
  let engine: PagedTextEngineAdapter
  let publisher: PagedWorkspacePublisher
  let record: PagedDocumentRootRecord
  let window: PagedTextWindow
  let backend: PagedNativeStorageBackend
}

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL

/// This fixture joins every known component call before its explicit exact
/// root transfer. It does not claim a physical input-method callback drain or
/// activate the ordinary product route.
@MainActor private final class PagedStagedFixture {
  let setup: PagedStagedSetup
  private let sqlIdentity: PagedSQLPublicControlIdentity
  let route: PagedStagedControlledStorage
  let session: PagedNativeSession
  let inputOwner: PagedNativeInputOwner?
  private let prototypeView: PagedNativeTextView?
  var view: PagedNativeTextView { inputOwner?.activeView ?? prototypeView! }
  private var observers: [Task<Void, Never>] = []
  private var notificationTokens: [NSObjectProtocol] = []
  private var admittedCommands: [UUID] = []
  private var readOutputs: [PagedTextRootLease] = []
  private var joinedWAL: PagedTextSQLMaintenanceSnapshot?
  private(set) var historyJoinFailures: [UUID: Error] = [:]
  private var preparationSelection: PagedNativeSelectionObservation?
  private(set) var preparationPrefix: PagedNativePrefixReservation?
  private(set) var closures: [PagedNativeGroupClosureReceipt] = []
  var afterClosure: ((PagedNativeGroupClosureReceipt) -> Void)?

  init(_ setup: PagedStagedSetup, managed: Bool, sqlIdentity: PagedSQLPublicControlIdentity) throws {
    let route = PagedStagedControlledStorage(setup.backend)
    let session = try PagedNativeSession(window: setup.window, rootRecord: setup.record, storage: route)
    self.setup = setup; self.sqlIdentity = sqlIdentity; self.route = route; self.session = session
    if managed {
      inputOwner = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
      prototypeView = nil
    } else {
      inputOwner = nil
      prototypeView = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
    }
    session.didCloseNativeGroup = { [weak self] receipt in
      guard let self else { return }
      precondition(closures.count < 128, "Public staged group evidence exceeds its fixed bound.")
      closures.append(receipt)
      afterClosure?(receipt)
    }
  }
  func own<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
    precondition(observers.count < 32, "Public staged waiter evidence exceeds its fixed bound.")
    let task = Task { try await body() }
    observers.append(Task { _ = try? await task.value })
    return task
  }
  func retainNotification(_ token: NSObjectProtocol) {
    precondition(notificationTokens.count < 8)
    notificationTokens.append(token)
  }
  func recordAdmission(_ ticket: PagedNativeHistoryInstallationTicket) {
    recordPublicationCommand(ticket.commandID)
  }
  func recordPublicationCommand(_ commandID: UUID) {
    precondition(admittedCommands.count < 16)
    admittedCommands.append(commandID)
  }
  func replaceFirst(with text: String) throws {
    let generation = session.generation
    if inputOwner == nil { view.boundedStorage.beginNativeGroup() }
    view.insertText(text, replacementRange: NSRange(location: 0, length: 1))
    if let error = view.boundedStorage.mutationFailure { throw error }
    if let error = inputOwner?.firstRefusal { throw error }
    guard session.generation == generation + 1 else { throw BoomError.invalid("The public native primitive was not accepted once.") }
  }
  func snapshot() async throws -> PagedWorkspaceSnapshot {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public staged read-output custody exceeds its bound.") }
    let result = try await setup.engine.loadWorkspaceRetaining(setup.publisher)
    readOutputs.append(result.lease)
    return result.value
  }
  func sourceWindow(_ record: PagedDocumentRootRecord) async throws -> PagedTextWindow {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public staged read-output custody exceeds its bound.") }
    let result = try await setup.engine.windowRetaining(record.document.revision, byteStart: 0, maximumBytes: 16_384)
    readOutputs.append(result.lease)
    return result.value
  }
  func history(_ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public staged SQL history custody exceeds its fixed bound.") }
    let result = try await setup.engine._publicSQLControlHistoryRetaining(identity: sqlIdentity, record: record)
    readOutputs.append(result.lease)
    return result.value
  }
  func prepared(_ direction: PagedNativeHistoryHandle.Direction = .undo) async throws -> PagedNativePreparedHistoryMove {
    let snapshot = try await snapshot(), record = try XCTUnwrap(snapshot.documents.first)
    let retained = try await history(record)
    let top = try XCTUnwrap(direction == .undo ? retained.undo.last : retained.redo.last)
    preparationSelection = try inputOwner?.observeSelection()
    let prefix = try session.reservePrefix()
    preparationPrefix = prefix
    return try await session.prepareHistoryMove(PagedNativeHistoryHandle(documentID: record.document.id,
      groupID: top.groupID, direction: direction), prefix: prefix)
  }
  func stage(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeHistoryInstallationTicket {
    let owner = try XCTUnwrap(inputOwner), selection = try XCTUnwrap(preparationSelection)
    return try owner.stage(prepared, observedSelection: selection)
  }
  @discardableResult
  func adopt(_ ticket: PagedNativeHistoryInstallationTicket) throws -> PagedNativeHistoryAdmission {
    let owner = try XCTUnwrap(inputOwner)
    let admission = try owner.withStagedInstallation(ticket,
      advancingFoundation: { consume in consume() }, mounted: { _, _ in })
    recordAdmission(ticket)
    return admission
  }
  /// Failure cleanup only joins the actual forwarded calls/waiters/timers.
  /// It cannot retry SQL maintenance, release roots, detach or close the engine.
  func joinCallsPreservingFailure() async {
    afterClosure = nil
    session.didFail = nil
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    notificationTokens.removeAll()
    await route.closeAndJoin()
    for commandID in admittedCommands {
      do { _ = try await session.joinHistoryPublication(commandID: commandID) }
      catch {
        if historyJoinFailures[commandID] == nil {
          precondition(historyJoinFailures.count < 16, "Public staged history failure evidence exceeds its command bound.")
          historyJoinFailures[commandID] = error
        }
      }
    }
    for observer in observers { await observer.value }
    await route.closeAndJoin()
  }
  /// true means source workers joined but a deliberately newer persistence
  /// failure remains owned. The isolated process retains that exact fixture.
  func join(expectPersistenceRefusal: Bool = false) async throws -> Bool {
    await joinCallsPreservingFailure()
    let joined = await route.snapshot
    guard joined.activeCalls == 0, joined.startedCalls == joined.finishedCalls else {
      throw BoomError.invalid("Public staged control left a real component call unjoined.")
    }
    guard session.historyFailure == nil,
      !session.hasPendingHistoryCommand, !(inputOwner?.hasStagedClient ?? false),
      view.inputCommandIsClosed, !view.hasMarkedText() else {
      throw BoomError.stale("Public staged control retained failed or unresolved input/history custody.")
    }
    if expectPersistenceRefusal {
      guard inputOwner == nil, session.pendingCommitInstallation == nil,
        let failure = session.persistenceFailure, case BoomError.invalid = failure else {
        throw BoomError.invalid("The public newer-failure control lost its exact terminal refusal.")
      }
      return true
    }
    guard session.persistenceFailure == nil else {
      throw BoomError.stale("Public staged control retained a failed source persistence owner.")
    }
    // Successful physical retirement uses actual quiescent source admission;
    // framework-retained inert clients are ordinary reference lifetime, not
    // an invented callback drain or an eight-installation terminal boundary.
    if let inputOwner {
      try inputOwner.retireInputForClose()
      try inputOwner.requireJoinedClose()
      guard inputOwner.retainedClientCount == 0 else {
        throw BoomError.invalid("The public managed owner kept its active/staged graph after retirement.")
      }
    }
    let final = try await snapshot(), record = try XCTUnwrap(final.documents.first)
    for lease in readOutputs { try await setup.engine.abandonJoinedRootOutput(lease) }
    readOutputs.removeAll()
    // Every case has sealed at least one native edit, so the actual backend's
    // controller is this exact session. Refusal keeps its files and custody.
    try await setup.backend.detachJoinedController(sessionID: session.sessionID,
      sequence: session.generation, record: record)
    try await joinWALAfterSource()
    try await setup.engine.close()
    return false
  }
  /// Explicit bounded maintenance AFTER the real native/source/receiving joins.
  /// A failed operation keeps its original Store fence and whole fixture; this
  /// never repairs an uncertain COMMIT or repeats source publication.
  private func joinWALAfterSource() async throws {
    let joined = try await setup.engine.joinScheduledWALMaintenance()
    joinedWAL = joined
    if let failure = joined.failure { throw failure }
    guard joined.storage.failedOperationID == nil,
      joined.storage.observedWALBytes <= PagedSQLiteStore.walAdmissionBytes,
      setup.engine.custodySnapshot.jobs == 0 else {
      throw BoomError.stale("Actual WAL/source work remains owned; fixture close refused.")
    }
  }
}

/// Actual Foundation notifications and synchronous inverse registration. The
/// eventual sole chronological ordinary manager owner remains a separate gate.
@MainActor private final class PagedStagedUndoTarget {
  let manager: UndoManager
  var handler: ((PagedNativeHistoryHandle) -> Void)?
  init(_ manager: UndoManager) { self.manager = manager }
  func register(_ handle: PagedNativeHistoryHandle) {
    manager.registerUndo(withTarget: self) { owner in
      owner.handler?(handle)
      owner.register(handle.inverse)
    }
  }
}

@MainActor private final class PagedStagedNotificationState {
  var adoption: (() -> Void)?
  var deliveries = 0
  var will = 0
  var did = 0
}

@MainActor private final class PagedStagedCaptureState {
  private var entered = false
  private var observer: CheckedContinuation<Void, Never>?
  var completed = false
  func enter() {
    entered = true
    observer?.resume(); observer = nil
  }
  func awaitEntry() async {
    guard !entered else { return }
    await withCheckedContinuation { observer = $0 }
  }
}

/// Source-bound real-backend/native component controls, authored only. No
/// successful ACK is synthesized; all storage values come from the encrypted
/// engine, publisher, backend and their actual retained/joined calls.
@MainActor final class PagedNativeStagedInstallationTests: XCTestCase {
  /// Successful managed physical clients retire through the actual owner API.
  /// Each intentionally retained source failure requires one exact separately
  /// owned disposable test process. Missing nomination refuses before entry.
  private static var retainedSetupRoot: URL?
  private static var retainedSetupEngine: PagedTextEngineAdapter?
  private static var retainedSetup: PagedStagedSetup?
  private static var terminalFixture: PagedStagedFixture?
  private func withFixture(managed: Bool = false, expectPersistenceRefusal: Bool = false,
    isolatedCase: String? = nil, preserveOnSuccess: Bool = false,
    _ body: @MainActor (PagedStagedFixture) async throws -> Void) async throws {
    if expectPersistenceRefusal {
      guard let isolatedCase,
        ProcessInfo.processInfo.environment["BLOOM_PAGED_STAGED_ISOLATED_CASE"] == isolatedCase else {
        throw BoomError.denied("Terminal staged SQL control requires its exact separately owned disposable process; no fixture entered.")
      }
    }
    guard Self.retainedSetupRoot == nil, Self.retainedSetupEngine == nil,
      Self.retainedSetup == nil, Self.terminalFixture == nil else {
      throw BoomError.denied("A prior failed/terminal fixture still owns this process.")
    }
    _ = NSApplication.shared
    let initialFailures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-native-staged-" + UUID().uuidString)
    Self.retainedSetupRoot = root
    print("Public staged SQL setup: \(root.path)")
    let created = try await Task.detached {
      let ownerID = UUID(), storeID = UUID(), vault = try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x73, count: 32)))
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: ownerID, sqliteOpening: .fresh(storeID: storeID))
      return (ownerID: ownerID, storeID: storeID, vault: vault, engine: engine)
    }.value
    Self.retainedSetupEngine = created.engine // Identity/receiving refusal preserves the actual joined opening.
    let identity = try await created.engine._publicSQLControlIdentity(expectedVault: created.vault, expectedStoreID: created.storeID)
    let setup = try await Task.detached {
      let engine = created.engine
      let source = root.appendingPathComponent("public-input.utf8")
      try Data("a public🙂\n".utf8).write(to: source, options: .withoutOverwriting)
      let file = try FileHandle(forReadingFrom: source)
      let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
      do { imported = try await engine.importUTF8Retaining(documentID: UUID(), from: file) }
      catch {
        let original = error
        do { try file.close() }
        catch { XCTFail("Public staged input close also failed; original import failure preserved: \(error)") }
        throw original
      }
      do { try file.close() }
      catch { throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
      let document = PagedDocumentDescriptor(id: imported.value.revision.documentID, title: "Public café", revision: imported.value.revision)
      let rootOutput = try await engine.initialNativeRecordRetaining(document)
      let record = rootOutput.value
      let publisher = try await engine.makeWorkspacePublisher()
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]
      state.selectedDocument = document.id
      let workspace = try await engine.initializeWorkspaceRetaining(publisher, state: state, documents: [record])
      try await engine.finishWorkspacePublication(workspace, publisher: publisher)
      // Actual strict head admission transfers the real joined import/history
      // outputs. A constructor or metadata callback cannot substitute for it.
      try await engine.transferJoinedRootToHead(imported.lease, publisher: publisher, expected: record)
      try await engine.transferJoinedRootToHead(rootOutput.lease, publisher: publisher, expected: record)
      try await engine.abandonJoinedRootOutput(workspace.lease)
      let backend = try await engine.makeNativeStorage(publisher, expected: record)
      let window = try await backend.window(expected: record.document.revision, utf16Anchor: 0,
        maximumBytes: PagedWorkingWindow.targetBytes)
      return PagedStagedSetup(root: root, ownerID: created.ownerID, vault: created.vault, engine: engine,
        publisher: publisher, record: record, window: window, backend: backend)
    }.value
    Self.retainedSetup = setup
    let fixture: PagedStagedFixture
    do { fixture = try PagedStagedFixture(setup, managed: managed, sqlIdentity: identity) }
    catch {
      XCTFail("Public staged constructor refused; actual setup and encrypted evidence retained at \(root.path): \(error)")
      throw error
    }
    Self.retainedSetup = nil; Self.retainedSetupEngine = nil; Self.retainedSetupRoot = nil
    do {
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public staged construction recorded failed assertions.") }
      try await body(fixture)
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public staged body recorded failed assertions.") }
      let retained = try await fixture.join(expectPersistenceRefusal: expectPersistenceRefusal)
      guard (testRun?.failureCount ?? 0) == initialFailures else { throw BoomError.invalid("Public staged actual join recorded failed assertions.") }
      if retained {
        Self.terminalFixture = fixture
        let status = await fixture.route.snapshot
        let sql = try await setup.engine.nativeSQLMaintenanceSnapshot() // Read-only; terminal receipt retirement stays owned.
        let custody = setup.engine.custodySnapshot
        guard status.activeCalls == 0, status.startedCalls == status.finishedCalls, custody.jobs == 0 else {
          throw BoomError.stale("Public terminal receipt preceded real staged source joins.")
        }
        let receipt: [String: String] = ["schema": "1",
          "status": "source-workers-joined-newer-persistence-refusal-retained",
          "case": isolatedCase!, "registered-client-count": String(fixture.inputOwner?.retainedClientCount ?? 0),
          "started-component-calls": String(status.startedCalls), "finished-component-calls": String(status.finishedCalls),
          "active-component-calls": String(status.activeCalls), "history-join-failures": String(fixture.historyJoinFailures.count),
          "live-root-custody-entries": String(custody.items.count),
          "sqlite-wal-bytes": String(sql.storage.observedWALBytes),
          "sqlite-failed-operation": sql.storage.failedOperationID?.uuidString ?? "none",
          "sqlite-maintenance": "retained-no-terminal-checkpoint",
          "engine": "retained-no-detach-no-close-no-delete"]
        try await Task.detached {
          let bytes = try JSONEncoder().encode(receipt)
          guard bytes.count <= 16_384 else { throw BoomError.budget("Public staged terminal receipt exceeds its fixed evidence cap.") }
          try bytes.write(to: root.appendingPathComponent("retained-component-boundary.json"), options: .withoutOverwriting)
        }.value
        print("Public retained staged SQL refusal evidence: \(root.path)")
        return
      }
      if preserveOnSuccess {
        print("Public preserved staged SQL finish-refusal/recovery evidence: \(root.path)")
        return
      }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
    } catch {
      let original = error
      Self.terminalFixture = fixture
      await fixture.joinCallsPreservingFailure() // No repeated retirement, source write, detach or engine close.
      XCTFail("Public staged control failed; actual source/input owners and encrypted evidence retained at \(root.path): \(original)")
      throw original
    }
  }
  private func assertStale(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try body(); XCTFail("Expected exact source-owner refusal.", file: file, line: line) }
    catch { if case BoomError.stale = error { return }; XCTFail("Expected stale refusal: \(error)", file: file, line: line) }
  }
  private func assertStaleAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("Expected exact source-owner refusal.", file: file, line: line) }
    catch { if case BoomError.stale = error { return }; XCTFail("Expected stale refusal: \(error)", file: file, line: line) }
  }
  private func assertSource(_ fixture: PagedStagedFixture, equals text: String) async throws {
    let snapshot = try await fixture.snapshot(), record = try XCTUnwrap(snapshot.documents.first)
    let actual = try await fixture.sourceWindow(record)
    XCTAssertEqual(Data(actual.text.utf8), Data(text.utf8))
    let history = try await fixture.history(record)
    XCTAssertEqual(history.current, record.document.revision)
  }

  func testCancelPreservesRealPreparedCustodyAndRestagingConsumesOnlyTheFreshTicket() async throws {
    try await withFixture(managed: true) { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let before = try await fixture.snapshot(), record = try XCTUnwrap(before.documents.first)
      let foreign = try PagedNativeSession(window: fixture.session.windowForNativeInstallation(),
        rootRecord: record, storage: fixture.route)
      let prepared = try await fixture.prepared(), owner = try XCTUnwrap(fixture.inputOwner)
      let oldArena = fixture.session.arenaID, ticket = try fixture.stage(prepared)
      XCTAssertEqual(ticket.window.windowID, prepared.window.windowID)
      XCTAssertEqual(ticket.window.revision, prepared.window.revision)
      XCTAssertEqual(ticket.localCaretUTF16, prepared.localCaretUTF16)
      XCTAssertEqual(fixture.session.generation, 1); XCTAssertEqual(fixture.session.arenaID, oldArena)
      XCTAssertFalse(fixture.session.isProvisionalHistory)
      let capturedPins = await fixture.setup.backend.historyReachability()
      let pinned = try XCTUnwrap(capturedPins)
      XCTAssertEqual(pinned.commandID, ticket.commandID); XCTAssertEqual(pinned.preparationID, ticket.preparationID)
      XCTAssertEqual(pinned.before, prepared.command.expectedRootRecord); XCTAssertEqual(pinned.candidate, prepared.candidateRecord)
      if case .prepared = pinned.phase {} else { XCTFail("Staging advanced the real backend preparation.") }
      assertStale { _ = try foreign.windowForStagedNativeInstallation(ticket) }
      assertStale { try foreign.cancelStagedHistoryInstallation(ticket) }
      var foreignEntered = false
      assertStale { _ = try foreign.withStagedHistoryInstallation(ticket) { _ in foreignEntered = true } }
      XCTAssertFalse(foreignEntered)
      try owner.cancelStage(ticket)
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand); XCTAssertFalse(owner.hasStagedClient)
      XCTAssertEqual(owner.retainedClientCount, 1)
      assertStale { _ = try fixture.session.windowForStagedNativeInstallation(ticket) }
      assertStale { try fixture.session.cancelStagedHistoryInstallation(ticket) }
      var cancelledEntered = false
      assertStale { _ = try fixture.session.withStagedHistoryInstallation(ticket) { _ in cancelledEntered = true } }
      XCTAssertFalse(cancelledEntered)
      let retainedPins = await fixture.setup.backend.historyReachability()
      let stillPinned = try XCTUnwrap(retainedPins)
      XCTAssertEqual(stillPinned.before, pinned.before); XCTAssertEqual(stillPinned.candidate, pinned.candidate)
      XCTAssertEqual(stillPinned.preparationID, pinned.preparationID)
      let fresh = try fixture.stage(prepared)
      XCTAssertNotEqual(fresh.provisionalArenaID, ticket.provisionalArenaID)
      let admission = try fixture.adopt(fresh)
      XCTAssertEqual(admission, fresh.admission); XCTAssertEqual(fixture.session.generation, 2)
      let ack = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      XCTAssertEqual(ack.preparationID, prepared.preparationID); XCTAssertEqual(ack.sealedRootRecord, prepared.candidateRecord)
      XCTAssertEqual(fixture.view.string, "a public🙂\n")
      assertStale { _ = try fixture.session.windowForStagedNativeInstallation(fresh) }
      var repeatedEntered = false
      assertStale { _ = try fixture.session.withStagedHistoryInstallation(fresh) { _ in repeatedEntered = true } }
      XCTAssertFalse(repeatedEntered)
      let joinedPins = await fixture.setup.backend.historyReachability()
      XCTAssertNil(joinedPins)
      try await assertSource(fixture, equals: "a public🙂\n")
    }
  }

  func testEverySourceTransitionRefusesWhileStagedWithoutPoisoningOrReleasingTheIntent() async throws {
    try await withFixture(managed: true) { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let undo = try await fixture.prepared(), first = try fixture.stage(undo)
      _ = try fixture.adopt(first)
      let actualUndoAck = try await fixture.session.joinHistoryPublication(commandID: undo.command.commandID)
      let redo = try await fixture.prepared(.redo)
      assertStale { _ = try fixture.session.stageHistoryInstallation(undo) }
      let ticket = try fixture.stage(redo)
      let prefix = try XCTUnwrap(fixture.preparationPrefix), owner = try XCTUnwrap(fixture.inputOwner)
      let oldView = fixture.view, oldArena = fixture.session.arenaID, generation = fixture.session.generation
      let started = await fixture.route.snapshot
      XCTAssertFalse(fixture.session.beginComposition()); XCTAssertFalse(fixture.session.endComposition())
      XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
      assertStale { try fixture.session.nativeCharacterTransactionWillBegin() }
      assertStale { try fixture.session.canReplace(NSRange(location: 0, length: 1), with: "x") }
      assertStale { _ = try fixture.session.replace(NSRange(location: 0, length: 1), with: "x", groupID: UUID()) }
      assertStale { _ = try fixture.session.closeNativeGroup() }
      assertStale { _ = try fixture.session.reservePrefix() }
      assertStale { try fixture.session.releasePrefix(prefix) }
      assertStale { _ = try fixture.session.windowForNativeInstallation() }
      assertStale { _ = try fixture.session.stageHistoryInstallation(redo) }
      assertStale { _ = try fixture.session.installPreparedHistory(redo) { _, _, _ in XCTFail("Fenced prototype installed.") } }
      assertStale { _ = try fixture.session.resolveUnpreparedHistory(.explicitlyAbandoned) }
      assertStale { try fixture.session.completeVerifiedHistory(UUID()) }
      assertStale { try fixture.session.acceptRecoveredHistory(actualUndoAck) }
      await assertStaleAsync { _ = try await fixture.session.completePendingCommitInstallation() }
      await assertStaleAsync { _ = try await fixture.session.flush(prefix) }
      await assertStaleAsync { _ = try await fixture.session.flush(through: generation) }
      await assertStaleAsync { _ = try await fixture.session.navigate(toUTF16: 0) }
      await assertStaleAsync { _ = try await fixture.session.prepareHistoryMove(redo.command.handle, prefix: prefix) }
      await assertStaleAsync { _ = try await fixture.session.retainHistoryInputConflict() }
      await assertStaleAsync { _ = try await fixture.session.resolveUnadmittedHistory(.explicitlyAbandoned) }
      await assertStaleAsync { _ = try await fixture.session.inspectHistoryRecovery() }
      fixture.session.requestCommit()
      let after = await fixture.route.snapshot
      XCTAssertEqual(after.startedCalls, started.startedCalls); XCTAssertEqual(after.finishedCalls, started.finishedCalls)
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertEqual(fixture.session.arenaID, oldArena)
      XCTAssertTrue(fixture.view === oldView); XCTAssertEqual(fixture.view.string, "a public🙂\n")
      XCTAssertFalse(fixture.session.isPinned); XCTAssertNil(fixture.session.compositionGroupID)
      XCTAssertNil(fixture.session.persistenceFailure); XCTAssertNil(fixture.session.historyFailure)
      XCTAssertEqual(try fixture.session.windowForStagedNativeInstallation(ticket).windowID, redo.window.windowID)
      let capturedReachability = await fixture.setup.backend.historyReachability()
      let reachability = try XCTUnwrap(capturedReachability)
      XCTAssertEqual(reachability.preparationID, redo.preparationID)
      try owner.cancelStage(ticket)
      _ = try await fixture.session.resolveUnadmittedHistory(.explicitlyAbandoned)
      XCTAssertFalse(fixture.session.hasPendingHistoryCommand)
      try await assertSource(fixture, equals: "a public🙂\n")
    }
  }

  func testFoundationNotificationsCannotInvalidateTheSynchronousConsumerOrItsInverse() async throws {
    try await withFixture(managed: true) { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.prepared(), ticket = try fixture.stage(prepared)
      let owner = try XCTUnwrap(fixture.inputOwner), oldView = fixture.view, oldArena = fixture.session.arenaID
      let manager = UndoManager(); manager.groupsByEvent = false
      let target = PagedStagedUndoTarget(manager)
      let notifications = PagedStagedNotificationState()
      target.handler = { handle in
        XCTAssertTrue(manager.isUndoing); XCTAssertEqual(handle.groupID, prepared.command.handle.groupID)
        notifications.deliveries += 1; notifications.adoption!()
        XCTAssertEqual(fixture.session.arenaID, ticket.provisionalArenaID)
        XCTAssertFalse(fixture.session.beginComposition())
        XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
        self.assertStale { try fixture.session.cancelStagedHistoryInstallation(ticket) }
      }
      let willToken = NotificationCenter.default.addObserver(forName: .NSUndoManagerWillUndoChange,
        object: manager, queue: .main) { _ in
          MainActor.assumeIsolated {
            notifications.will += 1
            XCTAssertEqual(fixture.session.arenaID, oldArena); XCTAssertEqual(fixture.session.generation, 1)
            XCTAssertFalse(fixture.session.beginComposition()); XCTAssertFalse(fixture.session.endComposition())
            self.assertStale { try fixture.session.cancelStagedHistoryInstallation(ticket) }
            self.assertStale { try fixture.session.nativeCharacterTransactionWillBegin() }
            fixture.session.requestCommit()
          }
        }
      fixture.retainNotification(willToken)
      let didToken = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidUndoChange,
        object: manager, queue: .main) { _ in
          MainActor.assumeIsolated {
            notifications.did += 1
            XCTAssertEqual(fixture.session.arenaID, ticket.provisionalArenaID); XCTAssertEqual(fixture.session.generation, 2)
            XCTAssertTrue(manager.canRedo); XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
            self.assertStale { try fixture.session.cancelStagedHistoryInstallation(ticket) }
            self.assertStale { _ = try fixture.session.reservePrefix() }
          }
        }
      fixture.retainNotification(didToken)
      manager.beginUndoGrouping(); target.register(prepared.command.handle); manager.endUndoGrouping()
      XCTAssertTrue(manager.canUndo); XCTAssertFalse(manager.canRedo)
      _ = try owner.withStagedInstallation(ticket, advancingFoundation: { consume in
        withoutActuallyEscaping(consume) { synchronous in
          notifications.adoption = synchronous
          defer { notifications.adoption = nil }
          manager.undo()
        }
      }, mounted: { old, new in
        XCTAssertTrue(old === oldView); XCTAssertFalse(new === oldView)
        XCTAssertEqual(new.string, "a public🙂\n"); XCTAssertEqual(old.string, "b public🙂\n")
      })
      fixture.recordAdmission(ticket)
      XCTAssertEqual(notifications.deliveries, 1); XCTAssertEqual(notifications.will, 1); XCTAssertEqual(notifications.did, 1)
      XCTAssertTrue(manager.canRedo); XCTAssertNil(fixture.session.persistenceFailure)
      XCTAssertFalse(oldView === fixture.view); XCTAssertEqual(oldView.string, "b public🙂\n")
      let actual = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      XCTAssertEqual(actual.admittedSequence, ticket.admission.admittedSequence)
      manager.removeAllActions(withTarget: target)
      try await assertSource(fixture, equals: "a public🙂\n")
    }
  }

  func testPrebuiltNewViewKeepsLaterNativeTypingAcrossTheRealHistoryAckAndNextBatch() async throws {
    try await withFixture(managed: true) { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.prepared(), oldView = fixture.view
      let oldIdentity = try XCTUnwrap(fixture.inputOwner?.activeIdentity)
      let ticket = try fixture.stage(prepared), hold = try await fixture.route.holdNext(.historyBefore)
      let oldRevision = fixture.session.sealedRevision
      _ = try fixture.adopt(ticket)
      try await fixture.route.awaitHeld(hold)
      let newIdentity = try XCTUnwrap(fixture.inputOwner?.activeIdentity)
      XCTAssertNotEqual(newIdentity.clientID, oldIdentity.clientID)
      XCTAssertEqual(oldIdentity.arenaID, oldView.inputBinding?.identity.arenaID)
      XCTAssertEqual(newIdentity.arenaID, ticket.provisionalArenaID)
      XCTAssertEqual(fixture.session.generation, 2); XCTAssertEqual(fixture.session.sealedRevision, oldRevision)
      XCTAssertEqual(fixture.view.string, "a public🙂\n"); XCTAssertEqual(oldView.string, "b public🙂\n")
      fixture.view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
      fixture.view.insertText("y", replacementRange: NSRange(location: 1, length: 0))
      let text = fixture.view.string, laterGeneration = fixture.session.generation
      XCTAssertEqual(laterGeneration, 4); XCTAssertEqual(text, "xya public🙂\n")
      XCTAssertNil(fixture.inputOwner?.firstRefusal)
      let commitHold = try await fixture.route.holdNext(.commitBefore)
      try await fixture.route.release(hold)
      let ack = try await fixture.session.joinHistoryPublication(commandID: ticket.commandID)
      try await fixture.route.awaitHeld(commitHold)
      XCTAssertEqual(ack.preparedWindowID, prepared.window.windowID); XCTAssertEqual(ack.admittedSequence, 2)
      XCTAssertEqual(fixture.session.arenaID, newIdentity.arenaID); XCTAssertEqual(fixture.session.generation, laterGeneration)
      XCTAssertEqual(fixture.view.string, text); XCTAssertEqual(oldView.string, "b public🙂\n")
      let status = await fixture.route.snapshot, batch = try XCTUnwrap(status.batches.last)
      XCTAssertEqual(batch.firstSequence, 3); XCTAssertEqual(batch.lastSequence, 4)
      XCTAssertEqual(batch.expectedRootRecord, ack.sealedRootRecord); XCTAssertEqual(batch.afterBytes, Data(text.utf8))
      let laterClosures = fixture.closures.filter { $0.arenaID == newIdentity.arenaID }
      XCTAssertEqual(laterClosures.map(\.lastSequence), [3, 4])
      XCTAssertEqual(batch.groupCheckpoints.map(\.groupID), laterClosures.map(\.effectiveGroupID))
      try await fixture.route.release(commitHold)
      _ = try await fixture.session.flush(through: laterGeneration)
      try await assertSource(fixture, equals: text)
    }
  }

  func testEffectiveMarkedGroupStaysPinnedInTheNewViewThroughAckAndClosesOnlyAtUnmark() async throws {
    try await withFixture(managed: true) { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.prepared(), oldView = fixture.view
      let ticket = try fixture.stage(prepared), hold = try await fixture.route.holdNext(.historyBefore)
      _ = try fixture.adopt(ticket); try await fixture.route.awaitHeld(hold)
      fixture.view.setMarkedText("文🙂", selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
      let effectiveGroup = try XCTUnwrap(fixture.session.compositionGroupID)
      let marked = fixture.view.markedRange(), text = fixture.view.string, generation = fixture.session.generation
      XCTAssertTrue(fixture.view.hasMarkedText()); XCTAssertTrue(fixture.session.isPinned)
      XCTAssertFalse(fixture.closures.contains { $0.effectiveGroupID == effectiveGroup })
      try await fixture.route.release(hold)
      let ack = try await fixture.session.joinHistoryPublication(commandID: ticket.commandID)
      XCTAssertEqual(ack.admittedSequence, 2); XCTAssertEqual(fixture.view.string, text)
      XCTAssertEqual(fixture.view.markedRange(), marked); XCTAssertTrue(fixture.session.isPinned)
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertEqual(fixture.session.compositionGroupID, effectiveGroup)
      XCTAssertEqual(oldView.string, "b public🙂\n")
      let beforeUnmark = await fixture.route.snapshot
      XCTAssertEqual(beforeUnmark.batches.count, 1)
      let commitHold = try await fixture.route.holdNext(.commitBefore)
      fixture.view.unmarkText()
      XCTAssertFalse(fixture.session.isPinned); XCTAssertFalse(fixture.view.hasMarkedText())
      let closures = fixture.closures.filter { $0.effectiveGroupID == effectiveGroup }
      XCTAssertEqual(closures.count, 1)
      XCTAssertEqual(closures.first?.arenaID, ticket.provisionalArenaID)
      XCTAssertEqual(closures.first?.firstSequence, 3); XCTAssertEqual(closures.first?.lastSequence, generation)
      XCTAssertEqual(closures.first?.localCaretUTF16, 3); XCTAssertEqual(closures.first?.hasEffectiveSourceChange, true)
      try await fixture.route.awaitHeld(commitHold)
      let captured = await fixture.route.snapshot, batch = try XCTUnwrap(captured.batches.last)
      XCTAssertEqual(batch.firstSequence, 3); XCTAssertEqual(batch.expectedRootRecord, ack.sealedRootRecord)
      XCTAssertEqual(batch.groupCheckpoints.map(\.groupID), [effectiveGroup])
      try await fixture.route.release(commitHold)
      _ = try await fixture.session.flush(through: generation)
      try await assertSource(fixture, equals: text)
    }
  }

  func testInterveningActualOldArenaInputRefusesStagingBeforeManagerAdvancementAndIsSealedAfterDisposition() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.prepared(), oldArena = fixture.session.arenaID
      let manager = UndoManager(); manager.groupsByEvent = false
      let target = PagedStagedUndoTarget(manager)
      var deliveries = 0
      target.handler = { _ in deliveries += 1 }
      manager.beginUndoGrouping(); target.register(prepared.command.handle); manager.endUndoGrouping()
      try fixture.replaceFirst(with: "c")
      assertStale { _ = try fixture.session.stageHistoryInstallation(prepared) }
      XCTAssertEqual(deliveries, 0); XCTAssertTrue(manager.canUndo); XCTAssertFalse(manager.canRedo)
      XCTAssertEqual(fixture.session.arenaID, oldArena); XCTAssertEqual(fixture.session.generation, 2)
      XCTAssertEqual(fixture.view.string, "c public🙂\n"); XCTAssertTrue(fixture.session.hasPendingHistoryCommand)
      let conflict = try await fixture.session.retainHistoryInputConflict()
      XCTAssertEqual(conflict.prepared, prepared); XCTAssertEqual(conflict.observation.generation, 2)
      XCTAssertEqual(conflict.observation.arenaID, oldArena)
      _ = try await fixture.session.resolveUnadmittedHistory(.explicitlyAbandoned)
      _ = try await fixture.session.flush(through: 2)
      XCTAssertEqual(fixture.view.string, "c public🙂\n"); XCTAssertEqual(deliveries, 0)
      manager.removeAllActions(withTarget: target)
      try await assertSource(fixture, equals: "c public🙂\n")
    }
  }

  func testStagedTicketRetainsItsExactWindowWhenAnEarlierRealNavigationResultArrives() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let oldArena = fixture.session.arenaID, hold = try await fixture.route.holdNext(.windowAfter)
      let navigation = fixture.own { try await fixture.session.navigate(toUTF16: 0) }
      try await fixture.route.awaitHeld(hold)
      let prepared = try await fixture.prepared()
      // Invalidation preserves this exact retained intent but is not a join
      // of the old actual window producer. Stage refuses before consumption.
      assertStale { _ = try fixture.session.stageHistoryInstallation(prepared) }
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand)
      try await fixture.route.release(hold)
      await assertStaleAsync { _ = try await navigation.value }
      let ticket = try fixture.session.stageHistoryInstallation(prepared)
      XCTAssertEqual(fixture.session.arenaID, oldArena); XCTAssertEqual(fixture.session.generation, 1)
      XCTAssertEqual(try fixture.session.windowForStagedNativeInstallation(ticket).windowID, prepared.window.windowID)
      XCTAssertEqual(fixture.view.string, "b public🙂\n")
      try fixture.session.cancelStagedHistoryInstallation(ticket)
      _ = try await fixture.session.resolveUnadmittedHistory(.explicitlyAbandoned)
      try await assertSource(fixture, equals: "b public🙂\n")
    }
  }

  func testActualSourceNeutralOuterGroupReportsSequencesAndCaretBeforeStorageWithoutCreatingUndo() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitBefore)
      var callbackCount = 0
      fixture.afterClosure = { receipt in
        callbackCount += 1
        XCTAssertEqual(receipt.sessionID, fixture.session.sessionID); XCTAssertEqual(receipt.arenaID, fixture.session.arenaID)
        XCTAssertEqual(receipt.firstSequence, 1); XCTAssertEqual(receipt.lastSequence, 2)
        XCTAssertEqual(receipt.localCaretUTF16, 1); XCTAssertFalse(receipt.hasEffectiveSourceChange)
        XCTAssertFalse(fixture.session.beginComposition()); XCTAssertFalse(fixture.session.endComposition())
        XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
        self.assertStale { try fixture.session.nativeCharacterTransactionWillBegin() }
        self.assertStale { _ = try fixture.session.reservePrefix() }
        self.assertStale { _ = try fixture.session.closeNativeGroup() }
        fixture.session.requestCommit()
      }
      let storage = fixture.view.boundedStorage
      storage.beginEditing()
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "a")
      storage.endEditing()
      XCTAssertEqual(callbackCount, 1); XCTAssertEqual(fixture.closures.count, 1)
      XCTAssertEqual(fixture.session.generation, 2); XCTAssertNil(fixture.session.persistenceFailure)
      try await fixture.route.awaitHeld(hold)
      let status = await fixture.route.snapshot, batch = try XCTUnwrap(status.batches.first)
      XCTAssertEqual(batch.firstSequence, 1); XCTAssertEqual(batch.lastSequence, 2)
      XCTAssertTrue(batch.groupCheckpoints.isEmpty); XCTAssertEqual(batch.finalCaretUTF16, 1)
      try await fixture.route.release(hold)
      _ = try await fixture.session.flush(through: 2)
      let snapshot = try await fixture.snapshot(), record = try XCTUnwrap(snapshot.documents.first)
      let retained = try await fixture.history(record)
      XCTAssertTrue(retained.undo.isEmpty); XCTAssertTrue(retained.redo.isEmpty)
      XCTAssertEqual(record.document.revision, fixture.setup.record.document.revision)
      XCTAssertGreaterThan(record.historyGeneration, fixture.setup.record.historyGeneration)
      try await assertSource(fixture, equals: "a public🙂\n")
    }
  }

  func testUnchangedAndRefusedPrimitivesDoNotInventClosuresAndUuidSwitchUsesActualEarlierCaret() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitBefore), storage = fixture.view.boundedStorage
      storage.beginEditing()
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
      XCTAssertTrue(fixture.closures.isEmpty)
      storage.beginNativeGroup()
      // The changed supplied UUID on an unchanged primitive must not close
      // the actual previous group or advance its sequence/caret.
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
      XCTAssertTrue(fixture.closures.isEmpty); XCTAssertEqual(fixture.session.generation, 1)
      XCTAssertThrowsError(try fixture.session.replace(NSRange(location: 4, length: 1),
        with: String(repeating: "x", count: PagedWorkingWindow.hardBytes), groupID: UUID()))
      XCTAssertTrue(fixture.closures.isEmpty); XCTAssertEqual(fixture.session.generation, 1)
      storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "xy")
      XCTAssertEqual(fixture.closures.count, 1)
      XCTAssertEqual(fixture.closures.first?.firstSequence, 1); XCTAssertEqual(fixture.closures.first?.lastSequence, 1)
      XCTAssertEqual(fixture.closures.first?.localCaretUTF16, 1)
      storage.endEditing()
      XCTAssertEqual(fixture.closures.count, 2)
      XCTAssertEqual(fixture.closures.last?.firstSequence, 2); XCTAssertEqual(fixture.closures.last?.localCaretUTF16, 3)
      try await fixture.route.awaitHeld(hold)
      let status = await fixture.route.snapshot, batch = try XCTUnwrap(status.batches.first)
      XCTAssertEqual(batch.groupCheckpoints.map(\.groupID), fixture.closures.map(\.effectiveGroupID))
      XCTAssertEqual(batch.groupCheckpoints.map(\.caretUTF16), [1, 3])
      try await fixture.route.release(hold)
      _ = try await fixture.session.flush(through: 2)
      let snapshot = try await fixture.snapshot(), record = try XCTUnwrap(snapshot.documents.first)
      let retained = try await fixture.history(record)
      XCTAssertEqual(retained.undo.map(\.groupID), fixture.closures.map(\.effectiveGroupID))
      try await assertSource(fixture, equals: "bxy public🙂\n")
    }
  }

  func testActualImeGroupClosesAtUnmarkBeforeTheWorkerAndIgnoresOrdinarySuppliedUuid() async throws {
    try await withFixture { fixture in
      fixture.view.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 1))
      let group = try XCTUnwrap(fixture.session.compositionGroupID)
      XCTAssertTrue(fixture.session.isPinned); XCTAssertTrue(fixture.view.hasMarkedText())
      XCTAssertTrue(fixture.closures.isEmpty)
      fixture.session.requestCommit()
      let before = await fixture.route.snapshot
      XCTAssertTrue(before.batches.isEmpty)
      let hold = try await fixture.route.holdNext(.commitBefore)
      fixture.view.boundedStorage.beginNativeGroup()
      fixture.view.unmarkText()
      XCTAssertEqual(fixture.closures.count, 1); XCTAssertEqual(fixture.closures.first?.effectiveGroupID, group)
      XCTAssertEqual(fixture.closures.first?.lastSequence, fixture.session.generation)
      XCTAssertEqual(fixture.closures.first?.localCaretUTF16, 1)
      XCTAssertFalse(fixture.session.isPinned); XCTAssertFalse(fixture.view.hasMarkedText())
      try await fixture.route.awaitHeld(hold)
      let status = await fixture.route.snapshot, batch = try XCTUnwrap(status.batches.first)
      XCTAssertEqual(batch.groupCheckpoints.map(\.groupID), [group])
      try await fixture.route.release(hold)
      _ = try await fixture.session.flush(through: fixture.session.generation)
      let snapshot = try await fixture.snapshot(), record = try XCTUnwrap(snapshot.documents.first)
      let retained = try await fixture.history(record)
      XCTAssertEqual(retained.undo.last?.groupID, group)
      try await assertSource(fixture, equals: "文 public🙂\n")
    }
  }

  func testMainConsumedAckRetainsBothRealRootsAndLaterInputUntilItsExplicitCustodyJoin() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitInstallationBefore)
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      let pending = try XCTUnwrap(fixture.session.pendingCommitInstallation)
      XCTAssertEqual(pending.lastSequence, 1); XCTAssertEqual(fixture.session.sealedRevision, pending.sealedWindow.revision)
      let custody = fixture.setup.engine.custodySnapshot
      let controller = try XCTUnwrap(custody.items.first { if case .controller = $0.purpose { return true }; return false })
      XCTAssertEqual(controller.pendingBatchID, pending.batchID)
      XCTAssertTrue(controller.claims.contains(.record(pending.expectedRootRecord)))
      XCTAssertTrue(controller.claims.contains(.record(pending.sealedRootRecord)))
      let captureState = PagedStagedCaptureState()
      let capture = fixture.own {
        captureState.enter()
        let revision = try await fixture.session.flush(through: 1)
        captureState.completed = true
        return revision
      }
      await captureState.awaitEntry()
      XCTAssertFalse(captureState.completed)
      try fixture.replaceFirst(with: "c")
      let before = await fixture.route.snapshot
      XCTAssertEqual(before.batches.count, 1); XCTAssertEqual(fixture.session.generation, 2)
      XCTAssertEqual(fixture.view.string, "c public🙂\n")
      XCTAssertEqual(fixture.session.pendingCommitInstallation?.batchID, pending.batchID)
      let nextHold = try await fixture.route.holdNext(.commitBefore)
      try await fixture.route.release(hold)
      try await fixture.route.awaitHeld(nextHold)
      let capturedRevision = try await capture.value
      XCTAssertEqual(capturedRevision, pending.sealedWindow.revision)
      XCTAssertNil(fixture.session.pendingCommitInstallation)
      let released = fixture.setup.engine.custodySnapshot
      let joinedController = try XCTUnwrap(released.items.first { if case .controller = $0.purpose { return true }; return false })
      XCTAssertNil(joinedController.pendingBatchID)
      XCTAssertEqual(joinedController.claims, [.record(pending.sealedRootRecord)])
      let after = await fixture.route.snapshot, batch = try XCTUnwrap(after.batches.last)
      XCTAssertEqual(batch.firstSequence, 2); XCTAssertEqual(batch.expectedRootRecord, pending.sealedRootRecord)
      XCTAssertEqual(batch.afterBytes, Data(fixture.view.string.utf8))
      try await fixture.route.release(nextHold)
      _ = try await fixture.session.flush(through: 2)
      XCTAssertNil(fixture.session.pendingCommitInstallation)
      try await assertSource(fixture, equals: "c public🙂\n")
      let beforeStaleFinish = try await fixture.snapshot()
      await assertStaleAsync { try await fixture.route.finishCommitInstallation(pending) }
      let afterStaleFinish = try await fixture.snapshot()
      XCTAssertEqual(afterStaleFinish, beforeStaleFinish)
    }
  }

  func testAlreadyConsumedReservedPrefixStillJoinsCustodyAndExcludesLaterInput() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitInstallationBefore)
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      let pending = try XCTUnwrap(fixture.session.pendingCommitInstallation), prefix = try fixture.session.reservePrefix()
      let captureState = PagedStagedCaptureState()
      let capture = fixture.own {
        captureState.enter()
        let value = try await fixture.session.flush(prefix)
        captureState.completed = true
        return value
      }
      await captureState.awaitEntry(); XCTAssertFalse(captureState.completed)
      try fixture.replaceFirst(with: "c")
      try await fixture.route.release(hold)
      let exact = try await capture.value
      XCTAssertEqual(exact.window.windowID, pending.sealedWindow.windowID)
      XCTAssertEqual(exact.rootRecord, pending.sealedRootRecord); XCTAssertEqual(exact.reservation.generation, 1)
      XCTAssertEqual(exact.window.text, "b public🙂\n"); XCTAssertEqual(fixture.view.string, "c public🙂\n")
      XCTAssertEqual(fixture.session.generation, 2)
      let beforeRelease = await fixture.route.snapshot
      XCTAssertEqual(beforeRelease.batches.count, 1)
      try fixture.session.releasePrefix(prefix)
      _ = try await fixture.session.flush(through: 2)
      try await assertSource(fixture, equals: "c public🙂\n")
    }
  }

  func testRefusedPrefixPreparationRetainsItsIntentAndAckUntilExplicitCustodyCompletion() async throws {
    try await withFixture(preserveOnSuccess: true) { fixture in
      let hold = try await fixture.route.holdNext(.commitInstallationAfter)
      await fixture.route.loseNextJoinedCommitInstallationReply()
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      let pending = try XCTUnwrap(fixture.session.pendingCommitInstallation)
      let snapshot = try await fixture.snapshot(), record = try XCTUnwrap(snapshot.documents.first)
      let retained = try await fixture.history(record), group = try XCTUnwrap(retained.undo.last)
      let handle = PagedNativeHistoryHandle(documentID: record.document.id, groupID: group.groupID, direction: .undo)
      let prefix = try fixture.session.reservePrefix(), captureState = PagedStagedCaptureState()
      let preparation = fixture.own {
        captureState.enter()
        return try await fixture.session.prepareHistoryMove(handle, prefix: prefix)
      }
      await captureState.awaitEntry()
      try fixture.replaceFirst(with: "c")
      try await fixture.route.release(hold)
      var originalFailure = ""
      do { _ = try await preparation.value; XCTFail("The lost prefix completion admitted a history preparation.") }
      catch {
        originalFailure = error.localizedDescription
        if case BoomError.unavailable = error {} else { XCTFail("Expected the original joined completion refusal: \(error)") }
      }
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand)
      XCTAssertNotNil(fixture.session.historyFailure)
      XCTAssertEqual(fixture.session.pendingCommitInstallation?.batchID, pending.batchID)
      do { _ = try await fixture.session.flush(prefix); XCTFail("A Main-consumed but unjoined ACK became a captured prefix.") }
      catch { if case BoomError.unavailable = error {} else { XCTFail("Expected the preserved original prefix refusal: \(error)") } }
      assertStale { try fixture.session.releasePrefix(prefix) }
      assertStale { _ = try fixture.session.resolveUnpreparedHistory(.explicitlyAbandoned) }
      assertStale { _ = try fixture.session.windowForNativeInstallation() }
      let beforeCompletion = await fixture.route.snapshot
      XCTAssertEqual(beforeCompletion.batches.count, 1); XCTAssertTrue(beforeCompletion.historyResults.isEmpty)
      let root = fixture.setup.root
      let refusal: [String: String] = ["schema": "1", "status": "raw-history-intent-prefix-and-ack-retained-after-real-finish-reply-loss",
        "error": originalFailure, "session": pending.sessionID.uuidString, "batch": pending.batchID.uuidString,
        "prefix": prefix.reservationID.uuidString, "sequence": String(prefix.generation)]
      try await Task.detached {
        try JSONEncoder().encode(refusal).write(to: root.appendingPathComponent("original-prefix-finish-refusal.json"), options: .withoutOverwriting)
      }.value
      let completed = try await fixture.session.completePendingCommitInstallation()
      XCTAssertEqual(completed.batchID, pending.batchID); XCTAssertNil(fixture.session.pendingCommitInstallation)
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand); XCTAssertNotNil(fixture.session.historyFailure)
      let exact = try await fixture.session.flush(prefix)
      XCTAssertEqual(exact.rootRecord, pending.sealedRootRecord); XCTAssertEqual(exact.window.text, "b public🙂\n")
      XCTAssertEqual(fixture.session.generation, 2); XCTAssertEqual(fixture.view.string, "c public🙂\n")
      let afterCompletion = await fixture.route.snapshot
      XCTAssertEqual(afterCompletion.batches.count, 1)
      XCTAssertEqual(afterCompletion.commitInstallations.map(\.batchID), [pending.batchID, pending.batchID])
      let disposition = try fixture.session.resolveUnpreparedHistory(.explicitlyAbandoned)
      XCTAssertEqual(disposition.prefix.reservation, prefix); XCTAssertEqual(disposition.prefix.rootRecord, pending.sealedRootRecord)
      XCTAssertEqual(disposition.handle.groupID, handle.groupID)
      XCTAssertFalse(fixture.session.hasPendingHistoryCommand); XCTAssertNil(fixture.session.historyFailure)
      _ = try await fixture.session.flush(through: 2)
      try await assertSource(fixture, equals: "c public🙂\n")
    }
  }

  func testLostRealCustodyCompletionKeepsTheConsumedAckUntilExplicitIdempotentFinishWithoutRepublishing() async throws {
    try await withFixture(preserveOnSuccess: true) { fixture in
      let hold = try await fixture.route.holdNext(.commitInstallationAfter)
      await fixture.route.loseNextJoinedCommitInstallationReply()
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      let pending = try XCTUnwrap(fixture.session.pendingCommitInstallation)
      // The actual backend has already completed, but its reply has not been
      // delivered to Main. Later accepted native input keeps its own queue.
      try fixture.replaceFirst(with: "c")
      let failedCapture = fixture.own { try await fixture.session.flush(through: 2) }
      try await fixture.route.release(hold)
      var originalFailure = ""
      do { _ = try await failedCapture.value; XCTFail("The deliberately lost real finish reply became a success.") }
      catch {
        originalFailure = error.localizedDescription
        if case BoomError.unavailable = error {} else { XCTFail("Expected joined finish-reply loss: \(error)") }
      }
      XCTAssertNotNil(fixture.session.persistenceFailure)
      XCTAssertEqual(fixture.session.pendingCommitInstallation?.batchID, pending.batchID)
      XCTAssertEqual(fixture.session.sealedRevision, pending.sealedWindow.revision)
      XCTAssertEqual(fixture.session.generation, 2); XCTAssertEqual(fixture.view.string, "c public🙂\n")
      let failed = await fixture.route.snapshot
      XCTAssertEqual(failed.batches.count, 1); XCTAssertEqual(failed.injectedCommitInstallationLosses, 1)
      XCTAssertEqual(failed.commitInstallations.map(\.batchID), [pending.batchID])
      let root = fixture.setup.root
      let refusal: [String: String] = ["schema": "1", "status": "original-joined-finish-reply-refusal-before-explicit-completion",
        "error": originalFailure, "session": pending.sessionID.uuidString, "batch": pending.batchID.uuidString,
        "sequence": String(pending.lastSequence), "injected-loss-count": String(failed.injectedCommitInstallationLosses)]
      try await Task.detached {
        try JSONEncoder().encode(refusal).write(to: root.appendingPathComponent("original-finish-refusal.json"), options: .withoutOverwriting)
      }.value
      let nextHold = try await fixture.route.holdNext(.commitBefore)
      let completed = try await fixture.session.completePendingCommitInstallation()
      XCTAssertEqual(completed.batchID, pending.batchID)
      XCTAssertNil(fixture.session.pendingCommitInstallation); XCTAssertNil(fixture.session.persistenceFailure)
      try await fixture.route.awaitHeld(nextHold)
      let explicit = await fixture.route.snapshot
      XCTAssertEqual(explicit.commitInstallations.map(\.batchID), [pending.batchID, pending.batchID])
      XCTAssertEqual(explicit.batches.count, 2)
      XCTAssertEqual(explicit.batches.last?.firstSequence, 2)
      XCTAssertEqual(explicit.batches.last?.expectedRootRecord, pending.sealedRootRecord)
      try await fixture.route.release(nextHold)
      _ = try await fixture.session.flush(through: 2)
      try await assertSource(fixture, equals: "c public🙂\n")
    }
  }

  func testExplicitFinishCannotClearANewerNativePersistenceFailureOrDiscardItsLaterInput() async throws {
    try await withFixture(expectPersistenceRefusal: true,
      isolatedCase: "testExplicitFinishCannotClearANewerNativePersistenceFailureOrDiscardItsLaterInput") { fixture in
      let firstHold = try await fixture.route.holdNext(.commitInstallationAfter)
      await fixture.route.loseNextJoinedCommitInstallationReply()
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(firstHold)
      let pending = try XCTUnwrap(fixture.session.pendingCommitInstallation)
      try fixture.replaceFirst(with: "c")
      let capture = fixture.own { try await fixture.session.flush(through: 2) }
      try await fixture.route.release(firstHold)
      var originalFailure = ""
      do { _ = try await capture.value; XCTFail("The original finish reply loss was discarded.") }
      catch {
        originalFailure = error.localizedDescription
        if case BoomError.unavailable = error {} else { XCTFail("Expected original reply loss: \(error)") }
      }
      let secondHold = try await fixture.route.holdNext(.commitInstallationAfter)
      let completion = fixture.own { try await fixture.session.completePendingCommitInstallation() }
      try await fixture.route.awaitHeld(secondHold)
      // A genuinely unmatched public primitive records a newer independent
      // failure while the exact idempotent metadata completion is in flight.
      XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
      let newer = try XCTUnwrap(fixture.session.persistenceFailure)
      if case BoomError.invalid = newer {} else { XCTFail("Expected the actual newer unmatched-close refusal.") }
      try await fixture.route.release(secondHold)
      let joined = try await completion.value
      XCTAssertEqual(joined.batchID, pending.batchID); XCTAssertNil(fixture.session.pendingCommitInstallation)
      let remaining = try XCTUnwrap(fixture.session.persistenceFailure)
      if case BoomError.invalid = remaining {} else { XCTFail("Explicit completion cleared or replaced the newer refusal.") }
      XCTAssertEqual(fixture.session.generation, 2); XCTAssertEqual(fixture.view.string, "c public🙂\n")
      let calls = await fixture.route.snapshot
      XCTAssertEqual(calls.batches.count, 1); XCTAssertEqual(calls.commitInstallations.map(\.batchID), [pending.batchID, pending.batchID])
      let root = fixture.setup.root, source = Data(fixture.view.string.utf8)
      let receipt: [String: String] = ["schema": "1", "status": "exact-ack-completed-newer-unmatched-close-refusal-and-later-input-retained",
        "original-error": originalFailure, "newer-error": remaining.localizedDescription,
        "session": pending.sessionID.uuidString, "batch": pending.batchID.uuidString, "later-generation": "2"]
      try await Task.detached {
        try source.write(to: root.appendingPathComponent("retained-public-native-input.utf8"), options: .withoutOverwriting)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("retained-newer-refusal.json"), options: .withoutOverwriting)
      }.value
    }
  }

  func testHistoryFinishKeepsANewerNativePersistenceRefusalAndItsLaterActualInput() async throws {
    try await withFixture(expectPersistenceRefusal: true,
      isolatedCase: "testHistoryFinishKeepsANewerNativePersistenceRefusalAndItsLaterActualInput") { fixture in
      try fixture.replaceFirst(with: "b"); _ = try await fixture.session.flush(through: 1)
      let prepared = try await fixture.prepared(), hold = try await fixture.route.holdNext(.historyInstallationBefore)
      _ = try fixture.view.installPreparedHistory(prepared)
      fixture.recordPublicationCommand(prepared.command.commandID)
      try await fixture.route.awaitHeld(hold)
      XCTAssertEqual(fixture.session.sealedRevision, prepared.window.revision)
      try fixture.replaceFirst(with: "c")
      XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
      let refusal = try XCTUnwrap(fixture.session.persistenceFailure)
      if case BoomError.invalid = refusal {} else { XCTFail("Expected actual unmatched-close refusal during history finish.") }
      try await fixture.route.release(hold)
      let ack = try await fixture.session.joinHistoryPublication(commandID: prepared.command.commandID)
      XCTAssertEqual(ack.admittedSequence, 2); XCTAssertEqual(fixture.session.generation, 3)
      XCTAssertEqual(fixture.view.string, "c public🙂\n"); XCTAssertFalse(fixture.session.hasPendingHistoryCommand)
      let retained = try XCTUnwrap(fixture.session.persistenceFailure)
      if case BoomError.invalid = retained {} else { XCTFail("History finish discarded the newer native failure.") }
      let status = await fixture.route.snapshot
      XCTAssertEqual(status.batches.count, 1); XCTAssertEqual(status.historyResults.count, 1)
      let root = fixture.setup.root, source = Data(fixture.view.string.utf8)
      let receipt: [String: String] = ["schema": "1", "status": "history-base-finished-newer-native-refusal-and-later-input-retained",
        "error": retained.localizedDescription, "command": prepared.command.commandID.uuidString,
        "preparation": prepared.preparationID.uuidString, "admitted-sequence": "2", "later-generation": "3"]
      try await Task.detached {
        try source.write(to: root.appendingPathComponent("retained-public-native-input.utf8"), options: .withoutOverwriting)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("retained-history-finish-refusal.json"), options: .withoutOverwriting)
      }.value
    }
  }

  func testExplicitFinishPreservesANativeFailureAlreadyPresentBeforeItsCall() async throws {
    try await withFixture(expectPersistenceRefusal: true,
      isolatedCase: "testExplicitFinishPreservesANativeFailureAlreadyPresentBeforeItsCall") { fixture in
      let hold = try await fixture.route.holdNext(.commitInstallationAfter)
      await fixture.route.loseNextJoinedCommitInstallationReply()
      var injectedNewerFailure = false
      fixture.session.didFail = { error in
        if case BoomError.unavailable = error, !injectedNewerFailure {
          injectedNewerFailure = true
          // The failure observer reenters after the original error was
          // recorded. Its newer error must not acquire the original finish
          // failure's serial merely because the callback returned later.
          XCTAssertFalse(fixture.session.nativeCharacterTransactionDidClose())
        }
      }
      try fixture.replaceFirst(with: "b"); try await fixture.route.awaitHeld(hold)
      let pending = try XCTUnwrap(fixture.session.pendingCommitInstallation)
      try fixture.replaceFirst(with: "c")
      let capture = fixture.own { try await fixture.session.flush(through: 2) }
      try await fixture.route.release(hold)
      do { _ = try await capture.value; XCTFail("The actual finish reply loss was discarded.") }
      catch { if case BoomError.invalid = error {} else { XCTFail("Expected the retained newer failure from the original refusal callback: \(error)") } }
      let original = try XCTUnwrap(fixture.session.lastCommitInstallationFailure)
      if case BoomError.unavailable = original {} else { XCTFail("The original completion phase refusal was not retained.") }
      XCTAssertTrue(injectedNewerFailure)
      let newer = try XCTUnwrap(fixture.session.persistenceFailure)
      if case BoomError.invalid = newer {} else { XCTFail("Expected the newer native close refusal before explicit finish.") }
      let completed = try await fixture.session.completePendingCommitInstallation()
      XCTAssertEqual(completed.batchID, pending.batchID); XCTAssertNil(fixture.session.pendingCommitInstallation)
      let remaining = try XCTUnwrap(fixture.session.persistenceFailure)
      if case BoomError.invalid = remaining {} else { XCTFail("Explicit finish cleared the unrelated already-present refusal.") }
      XCTAssertEqual(fixture.view.string, "c public🙂\n"); XCTAssertEqual(fixture.session.generation, 2)
      let status = await fixture.route.snapshot
      XCTAssertEqual(status.batches.count, 1); XCTAssertEqual(status.commitInstallations.map(\.batchID), [pending.batchID, pending.batchID])
      let root = fixture.setup.root, source = Data(fixture.view.string.utf8)
      let receipt: [String: String] = ["schema": "1", "status": "exact-ack-completed-already-present-unrelated-failure-retained",
        "original-error": original.localizedDescription, "newer-error": remaining.localizedDescription,
        "session": pending.sessionID.uuidString, "batch": pending.batchID.uuidString]
      try await Task.detached {
        try source.write(to: root.appendingPathComponent("retained-public-native-input.utf8"), options: .withoutOverwriting)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("retained-before-call-refusal.json"), options: .withoutOverwriting)
      }.value
    }
  }
}

#endif
