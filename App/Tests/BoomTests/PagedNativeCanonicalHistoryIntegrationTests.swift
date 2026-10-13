import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

// SOURCE ONLY: unparsed, uncompiled and unrun. This file requires the reviewed
// composed file retirement, guarded seam and real receiving successor.
// It never constructs a source ACK or interprets visibility as durability.
// Terminal receiving cases require one exact separately owned test process.
private enum CanonicalPublicFault: Error, Sendable, Equatable {
  case refusedHistoryFinishBeforeCall
  case lostJoinedHistoryFinishReply
}

/// Decorates the existing public scheduling route, which forwards the real
/// file backend. Only failure delivery/evidence is added; no engine,
/// executor, history, timer, root pin, guardian or successful value is invented.
private actor CanonicalPublicRoute: PagedNativeHistorySessionStorage, PagedNativeCommitInstallationStorage {
  nonisolated let gate: PagedStagedControlledStorage
  struct Snapshot: Sendable {
    let acknowledgements: [PagedNativeCommitAcknowledgement]
    let admissions: [PagedNativeHistoryAdmission]
    let beforeFinishRefusals: Int
    let joinedHistoryFinishReturns: Int
    let lostFinishReplies: Int
  }
  private var acknowledgements: [PagedNativeCommitAcknowledgement] = []
  private var admissions: [PagedNativeHistoryAdmission] = []
  private var refuseBeforeFinish = false
  private var loseAfterFinish = false
  private var beforeFinishRefusals = 0
  private var joinedHistoryFinishReturns = 0
  private var lostFinishReplies = 0

  init(_ backend: PagedNativeStorageBackend) { gate = PagedStagedControlledStorage(backend) }
  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    guard acknowledgements.count < 16 else { throw BoomError.budget("Public canonical ACK evidence exceeds its bound.") }
    let result = try await gate.commit(batch)
    guard acknowledgements.count < 16 else { throw BoomError.budget("Public canonical ACK evidence exceeds its bound.") }
    acknowledgements.append(result)
    return result
  }
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    try await gate.finishCommitInstallation(acknowledgement)
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    try await gate.window(expected: expected, utf16Anchor: utf16Anchor, maximumBytes: maximumBytes)
  }
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove {
    try await gate.prepareHistoryMove(command)
  }
  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    guard admissions.count < 16 else { throw BoomError.budget("Public canonical command evidence exceeds its bound.") }
    admissions.append(admission)
    return try await gate.commitPreparedHistory(prepared, admission: admission)
  }
  func noteHistoryInputConflict(_ prepared: PagedNativePreparedHistoryMove,
    observation: PagedNativeHistoryInputObservation) async throws -> PagedNativeHistoryInputConflictReceipt {
    try await gate.noteHistoryInputConflict(prepared, observation: observation)
  }
  func resolveUnadmittedHistory(_ prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) async throws -> PagedNativeHistoryIntentDispositionReceipt {
    try await gate.resolveUnadmittedHistory(prepared, disposition: disposition)
  }
  func inspectHistoryRecovery(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    try await gate.inspectHistoryRecovery(prepared)
  }
  func completeVerifiedHistory(_ prepared: PagedNativePreparedHistoryMove,
    verificationID: UUID) async throws -> PagedNativeHistoryAcknowledgement {
    try await gate.completeVerifiedHistory(prepared, verificationID: verificationID)
  }
  func finishHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws {
    if refuseBeforeFinish {
      refuseBeforeFinish = false; beforeFinishRefusals += 1
      throw CanonicalPublicFault.refusedHistoryFinishBeforeCall
    }
    try await gate.finishHistoryInstallation(prepared, admission: admission)
    joinedHistoryFinishReturns += 1
    if loseAfterFinish {
      loseAfterFinish = false; lostFinishReplies += 1
      throw CanonicalPublicFault.lostJoinedHistoryFinishReply
    }
  }
  func refuseNextHistoryFinishBeforeCall() { refuseBeforeFinish = true }
  func loseNextJoinedHistoryFinishReply() { loseAfterFinish = true }
  var snapshot: Snapshot {
    Snapshot(acknowledgements: acknowledgements, admissions: admissions,
      beforeFinishRefusals: beforeFinishRefusals, joinedHistoryFinishReturns: joinedHistoryFinishReturns,
      lostFinishReplies: lostFinishReplies)
  }
}

private struct CanonicalPublicOpen: Sendable {
  let root: URL
  let ownerID: UUID
  let storeID: UUID
  let store: WorkspaceStore
  let engine: PagedTextEngineAdapter
}
private struct CanonicalPublicReady: Sendable {
  let opened: CanonicalPublicOpen
  let publisher: PagedWorkspacePublisher
  let record: PagedDocumentRootRecord
  let backend: PagedNativeStorageBackend
  let opening: PagedNativeCanonicalOpening
}

@MainActor private final class CanonicalPublicNotifications {
  var willUndo = 0
  var willRedo = 0
}

@MainActor private final class CanonicalPublicFixture {
  private static let key = UndoManager.UserInfoKey(rawValue: "bloom.paged.native-entry.v1")
  var opened: CanonicalPublicOpen
  var publisher: PagedWorkspacePublisher
  var backend: PagedNativeStorageBackend
  var route: CanonicalPublicRoute
  var session: PagedNativeSession
  var input: PagedNativeInputOwner
  var commands: PagedNativeUndoOwner
  let initialRecord: PagedDocumentRootRecord
  let window: NSWindow
  let scroll: NSScrollView
  private var readOutputs: [PagedTextRootLease] = []
  private var retainedReopeningEngine: PagedTextEngineAdapter?
  private(set) var joinedCommandFailure: Error?
  private var notificationTokens: [NSObjectProtocol] = []
  var view: PagedNativeTextView { input.activeView! }

  init(_ ready: CanonicalPublicReady) throws {
    // Use local graph owners while XCTest autoclosures run; do not capture
    // the partially initialized fixture self before every stored field exists.
    let initialRoute = CanonicalPublicRoute(ready.backend)
    let initialSession = try PagedNativeSession(opening: ready.opening, storage: initialRoute)
    let initialInput = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: initialSession)
    XCTAssertTrue(initialInput.canonicalActivationPending)
    XCTAssertEqual(initialInput.activeView.inputBinding?.state, .staged)
    let initialCommands = try PagedNativeUndoOwner(input: initialInput)
    XCTAssertFalse(initialInput.canonicalActivationPending)
    XCTAssertNil(initialSession.canonicalOpening)
    opened = ready.opened; publisher = ready.publisher; backend = ready.backend
    initialRecord = ready.record; route = initialRoute; session = initialSession
    input = initialInput; commands = initialCommands
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "Public"
    scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
    window.contentView = scroll
    wireMount()
    scroll.documentView = view
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(view))
    XCTAssertTrue(window.firstResponder === view)
  }
  private func wireMount() {
    commands.mountView = { [weak self] old, new in
      guard let self else {
        XCTFail("The actual public canonical mount lost its window.")
        throw BoomError.unavailable("Actual canonical physical mount owner is absent.")
      }
      XCTAssertTrue(self.scroll.documentView === old)
      XCTAssertTrue(self.input.activeView === new)
      self.scroll.documentView = new
      XCTAssertTrue(self.window.makeFirstResponder(new))
      XCTAssertTrue(self.window.firstResponder === new)
    }
  }
  func top(_ direction: PagedNativeHistoryHandle.Direction) throws -> NSObject {
    let value = direction == .undo ? commands.manager.undoActionUserInfoValue(forKey: Self.key)
      : commands.manager.redoActionUserInfoValue(forKey: Self.key)
    return try XCTUnwrap(value as? NSObject)
  }
  func observeHistoryNotifications(_ state: CanonicalPublicNotifications) {
    precondition(notificationTokens.isEmpty)
    for (name, undo) in [(Notification.Name.NSUndoManagerWillUndoChange, true),
      (Notification.Name.NSUndoManagerWillRedoChange, false)] {
      notificationTokens.append(NotificationCenter.default.addObserver(forName: name,
        object: commands.manager, queue: .main) { _ in MainActor.assumeIsolated {
          if undo { state.willUndo += 1 } else { state.willRedo += 1 }
        } })
    }
  }
  func removeObservers() {
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    notificationTokens.removeAll()
  }
  func replaceFirst(_ text: String) throws {
    let before = session.generation
    view.insertText(text, replacementRange: NSRange(location: 0, length: 1))
    guard session.generation == before + 1, input.firstRefusal == nil,
      view.boundedStorage.mutationFailure == nil else {
      throw BoomError.invalid("The real native input primitive was refused.")
    }
  }
  /// Calls the actual NSTextStorage primitive inside its real binding command.
  /// Keeping the storage's existing UUID permits two real closed chunks to
  /// model one continuing native group; no group receipt or ACK is fabricated.
  func continuingPrimitive(_ replacements: [String], oneTransaction: Bool) throws {
    guard !replacements.isEmpty, replacements.count <= 2 else { throw BoomError.budget("Public primitive fixture exceeds its bound.") }
    let binding = try XCTUnwrap(view.inputBinding)
    try binding.beginCommand(in: session)
    defer { binding.endCommand(); commands.inputCommandDidClose() }
    if oneTransaction { view.boundedStorage.beginEditing() }
    defer { if oneTransaction { view.boundedStorage.endEditing() } }
    for text in replacements {
      view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: text)
      guard input.firstRefusal == nil, view.boundedStorage.mutationFailure == nil else {
        throw BoomError.invalid("Actual storage refused the admitted public primitive.")
      }
    }
  }
  func key(_ text: String = "z") throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
      charactersIgnoringModifiers: text, isARepeat: false, keyCode: 6))
  }
  func record() async throws -> PagedDocumentRootRecord {
    guard readOutputs.count < 48 else { throw BoomError.budget("Public retained read evidence exceeds its fixed bound.") }
    let result = try await opened.engine.currentDocumentRecordRetaining(publisher, documentID: initialRecord.document.id)
    readOutputs.append(result.lease)
    return result.value
  }
  func source(_ record: PagedDocumentRootRecord) async throws -> PagedTextWindow {
    guard readOutputs.count < 48 else { throw BoomError.budget("Public retained read evidence exceeds its fixed bound.") }
    let result = try await opened.engine.windowRetaining(record.document.revision,
      byteStart: 0, maximumBytes: PagedWorkingWindow.targetBytes)
    readOutputs.append(result.lease)
    return result.value
  }
  /// Independent read-only authentication through the SAME owner/file provider.
  /// The full record is still held by the real controller/read output above.
  func history(_ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    guard readOutputs.count < 48 else { throw BoomError.budget("Public retained file history evidence exceeds its fixed bound.") }
    let result = try await opened.engine.rootHistoryRetaining(publisher, expected: record)
    readOutputs.append(result.lease)
    return result.value
  }
  func seal() async throws { _ = try await session.flush(through: session.generation) }
  func historyCommand(_ direction: PagedNativeHistoryHandle.Direction) async throws {
    if direction == .undo { commands.manager.undo() } else { commands.manager.redo() }
    try await commands.joinPendingCommand()
  }
  func assertSource(_ text: String, revision: PagedTextRevision? = nil) async throws -> PagedDocumentRootRecord {
    let current = try await record(), island = try await source(current)
    XCTAssertEqual(Data(island.text.utf8), Data(text.utf8))
    XCTAssertEqual(Data(view.string.utf8), Data(text.utf8))
    if let revision { XCTAssertEqual(current.document.revision, revision) }
    let actual = try await history(current)
    XCTAssertEqual(actual.current, current.document.revision)
    XCTAssertEqual(actual.generation, current.historyGeneration)
    XCTAssertEqual(session.canonicalHistory?.record, current)
    return current
  }
  func retainInspection(_ output: PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection>) throws {
    guard readOutputs.count < 48 else { throw BoomError.budget("Public inspection output exceeds its fixed bound.") }
    readOutputs.append(output.lease)
  }
  func closeOwnerAndEngine() async throws -> PagedDocumentRootRecord {
    removeObservers()
    try await commands.joinPendingCommand(); try await seal()
    let current = try await record()
    try commands.closeInput(); try commands.requireJoinedClose()
    _ = window.makeFirstResponder(nil); scroll.documentView = nil
    await route.gate.closeAndJoin()
    let joined = await route.gate.snapshot
    guard joined.activeCalls == 0, joined.startedCalls == joined.finishedCalls,
      session.pendingCommitInstallation == nil, !session.hasPendingHistoryCommand,
      session.persistenceFailure == nil, session.historyFailure == nil else {
      throw BoomError.stale("Actual public source workers/ACK custody did not join.")
    }
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: session.generation, record: current)
    for output in readOutputs { try await opened.engine.abandonJoinedRootOutput(output) }
    readOutputs.removeAll()
    try await opened.engine.close()
    try await opened.store.releaseExclusiveWorkspace()
    return current
  }
  func reopenJoined() async throws {
    guard retainedReopeningEngine == nil else { throw BoomError.denied("An earlier public file reopening remains owned.") }
    let expected = try await closeOwnerAndEngine()
    let root = opened.root, ownerID = opened.ownerID, storeID = opened.storeID, store = opened.store
    try await store.acquireExclusiveWorkspace()
    let nextEngine = try await PagedTextEngineAdapter.create(root: root, ownerID: ownerID, storeID: storeID)
    retainedReopeningEngine = nextEngine // Retain a joined real opening even if identity admission refuses.
    opened = CanonicalPublicOpen(root: root, ownerID: ownerID, storeID: storeID, store: store, engine: nextEngine)
    retainedReopeningEngine = nil
    publisher = try await nextEngine.makeWorkspacePublisher()
    let loaded = try await nextEngine.currentDocumentRecordRetaining(publisher, documentID: expected.document.id)
    readOutputs.append(loaded.lease)
    guard loaded.value == expected else { throw BoomError.stale("File reopen changed the complete head.") }
    backend = try await nextEngine.makeNativeStorage(publisher, expected: expected)
    let opening = try await backend.opening(sessionID: UUID())
    route = CanonicalPublicRoute(backend)
    session = try PagedNativeSession(opening: opening, storage: route)
    input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
    XCTAssertTrue(input.canonicalActivationPending)
    commands = try PagedNativeUndoOwner(input: input)
    XCTAssertNil(session.canonicalOpening); XCTAssertFalse(input.canonicalActivationPending)
    wireMount(); scroll.documentView = view
    window.makeKeyAndOrderFront(nil)
    guard window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.unavailable("Reopened actual native owner did not acquire focus.")
    }
  }
  func joinFailedCalls() async {
    removeObservers()
    await route.gate.closeAndJoin()
    do { try await commands.joinPendingCommand() }
    catch {
      if joinedCommandFailure == nil { joinedCommandFailure = error }
      print("Actual canonical command join ended with retained failure at \(opened.root.path): \(error)")
    }
    let joined = await route.gate.snapshot
    XCTAssertEqual(joined.activeCalls, 0)
    XCTAssertEqual(joined.startedCalls, joined.finishedCalls)
  }
}

@MainActor final class PagedNativeCanonicalHistoryIntegrationTests: XCTestCase {
  private static var retainedSetupRoot: URL?
  private static var retainedSetupEngine: PagedTextEngineAdapter?
  private static var retainedOpen: CanonicalPublicOpen?
  private static var retainedReady: CanonicalPublicReady?
  private static var terminalFixture: CanonicalPublicFixture?

  private func makeFixture() async throws -> CanonicalPublicFixture {
    guard Self.retainedSetupRoot == nil, Self.retainedSetupEngine == nil,
      Self.retainedOpen == nil, Self.retainedReady == nil, Self.terminalFixture == nil else {
      throw BoomError.denied("A prior retained public fixture still owns this process.")
    }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-canonical-history-" + UUID().uuidString)
    Self.retainedSetupRoot = root // Failed opening keeps its public files; no teardown deletes them.
    print("Public canonical setup: \(root.path)")
    let store = try WorkspaceStore(rootOverride: root)
    try await store.acquireExclusiveWorkspace()
    let identity = try await store.storageIdentity()
    let engine = try await PagedTextEngineAdapter.create(root: store.root, ownerID: identity.ownerID, storeID: identity.storeID)
    Self.retainedSetupEngine = engine
    let opened = CanonicalPublicOpen(root: store.root, ownerID: identity.ownerID, storeID: identity.storeID,
      store: store, engine: engine)
    Self.retainedOpen = opened
    Self.retainedSetupEngine = nil; Self.retainedSetupRoot = nil
    let importOwner = opened
    let imported = try await Task.detached {
      let source = root.appendingPathComponent("public-input.utf8")
      try Data("a public🙂\n".utf8).write(to: source, options: .withoutOverwriting)
      let file = try FileHandle(forReadingFrom: source)
      let result: PagedTextCustodiedValue<PagedTextImportedRevision>
      do { result = try await importOwner.engine.importUTF8Retaining(documentID: UUID(), from: file) }
      catch {
        let original = error
        do { try file.close() }
        catch { XCTFail("Public input close also failed; original import failure preserved: \(error)") }
        throw original
      }
      do { try file.close() }
      catch { throw PagedTextCustodyFailure(original: error, lease: result.lease) }
      return result
    }.value
    let document = PagedDocumentDescriptor(id: imported.value.revision.documentID,
      title: "Public café", revision: imported.value.revision)
    let initial = try await opened.engine.initialNativeRecordRetaining(document)
    let publisher = try await opened.engine.makeWorkspacePublisher()
    let record = try await opened.engine.publishInitialDocumentRetaining(publisher, imported: imported, initialized: initial)
    var state = WorkspaceState()
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await opened.store.saveState(state)
    let backend = try await opened.engine.makeNativeStorage(publisher, expected: record)
    let opening = try await backend.opening(sessionID: UUID())
    let ready = CanonicalPublicReady(opened: opened, publisher: publisher,
      record: record, backend: backend, opening: opening)
    Self.retainedReady = ready
    let fixture = try CanonicalPublicFixture(ready)
    Self.retainedOpen = nil; Self.retainedReady = nil
    return fixture
  }
  private func withFixture(isolatedCase: String? = nil,
    _ body: @MainActor (CanonicalPublicFixture) async throws -> Void) async throws {
    if let isolatedCase,
      ProcessInfo.processInfo.environment["BLOOM_PAGED_CANONICAL_ISOLATED_CASE"] != isolatedCase {
      throw BoomError.denied("Retained receiving-boundary control requires its exact separately owned disposable test process; no fixture entered.")
    }
    let failures = testRun?.failureCount ?? 0
    let fixture = try await makeFixture()
    do {
      try await body(fixture)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("The actual canonical control recorded failed assertions.") }
      if let isolatedCase {
        Self.terminalFixture = fixture
        await fixture.joinFailedCalls()
        guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("The actual terminal workers did not join.") }
        let gate = await fixture.route.gate.snapshot
        let owner = fixture.opened, sourceGeneration = fixture.session.generation
        let custody = owner.engine.custodySnapshot
        guard gate.activeCalls == 0, gate.startedCalls == gate.finishedCalls, custody.jobs == 0 else {
          throw BoomError.stale("Terminal evidence cannot precede actual public worker joins.")
        }
        let receipt: [String: String] = ["case": isolatedCase,
          "status": "actual-component-workers-joined-receiving-intent-and-input-retained",
          "source-generation": String(sourceGeneration),
          "queued-raw-input": String(fixture.commands.queuedRawKeyCount),
          "retained-prefix": String(fixture.commands.retainedPrefix != nil),
          "actual-started-calls": String(gate.startedCalls), "actual-finished-calls": String(gate.finishedCalls),
          "actual-active-calls": String(gate.activeCalls), "live-root-custody-entries": String(custody.items.count),
          "engine": "retained-no-detach-no-close-no-delete",
          "receiving-disposition": "OPEN-not-qualified-or-silently-applied"]
        try await Task.detached {
          let bytes = try JSONEncoder().encode(receipt)
          guard bytes.count <= 16_384 else { throw BoomError.budget("Public terminal file receipt exceeds its fixed evidence cap.") }
          try bytes.write(to: owner.root.appendingPathComponent("retained-canonical-boundary.json"), options: .withoutOverwriting)
        }.value
        print("Public canonical retained boundary: \(owner.root.path)")
        return
      }
      _ = try await fixture.closeOwnerAndEngine(); fixture.window.close()
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual canonical shutdown recorded a failed assertion.") }
    } catch {
      Self.terminalFixture = fixture
      await fixture.joinFailedCalls()
      XCTFail("Actual input/source owners and failed diagnostics retained at \(fixture.opened.root.path): \(error)")
      throw error
    }
    let root = fixture.opened.root
    // Only successful joined owners permit destructive scratch cleanup.
    try await Task.detached { try FileManager.default.removeItem(at: root) }.value
  }
  private func requireRefusal(_ body: () throws -> Void) {
    do { try body(); XCTFail("Actual unresolved input/source close must refuse.") }
    catch {
      guard case BoomError.stale = error else {
        XCTFail("Expected the actual stale close refusal, received: \(error)"); return
      }
    }
  }

  // The first control uses a synchronous XCTest entry around its async body.
  // The actual async body is unchanged; its Task result is joined before the
  // public expectation completes. Timeout retains the tasks and failed source.
  private static var synchronousControlTask: Task<Void, Error>?
  private static var synchronousControlJoin: Task<Void, Never>?

  func testFileReopenHydratesBothFoundationDirectionsAndExactCursors() {
    guard Self.synchronousControlTask == nil, Self.synchronousControlJoin == nil else {
      XCTFail("An earlier canonical control still owns its actual async tasks."); return
    }
    let joined = expectation(description: "Actual canonical history body joined")
    let work = Task { @MainActor in try await self.fileReopenHydratesBothDirectionsBody() }
    Self.synchronousControlTask = work
    Self.synchronousControlJoin = Task { @MainActor in
      let result = await work.result
      if case .failure(let error) = result {
        XCTFail("Joined actual canonical history control failed: \(error)")
      }
      joined.fulfill()
    }
    let completion = XCTWaiter.wait(for: [joined], timeout: 120)
    guard completion == .completed else {
      work.cancel()
      XCTFail("Canonical history control timed out; actual tasks and partial source retained.")
      return
    }
    Self.synchronousControlTask = nil; Self.synchronousControlJoin = nil
  }

  private func fileReopenHydratesBothDirectionsBody() async throws {
    try await withFixture { f in
      let base = f.initialRecord.document.revision
      try f.replaceFirst("b"); try await f.seal(); let b = try await f.assertSource("b public🙂\n")
      try f.replaceFirst("c"); try await f.seal(); let c = try await f.assertSource("c public🙂\n")
      try f.replaceFirst("d"); try await f.seal(); let d = try await f.assertSource("d public🙂\n")
      try await f.historyCommand(.undo); _ = try await f.assertSource("c public🙂\n", revision: c.document.revision)
      try await f.historyCommand(.undo); let before = try await f.assertSource("b public🙂\n", revision: b.document.revision)
      let actualBefore = try await f.history(before)
      XCTAssertEqual(actualBefore.undo.map(\.revision), [base])
      XCTAssertEqual(actualBefore.redo.map(\.revision), [d.document.revision, c.document.revision])
      try await f.reopenJoined()
      XCTAssertEqual(f.session.generation, 0)
      XCTAssertEqual(f.session.canonicalHistory?.record, before)
      XCTAssertEqual(f.commands.manager.undoCount, 1); XCTAssertEqual(f.commands.manager.redoCount, 2)
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 1, length: 0))
      XCTAssertEqual(f.session.canonicalHistory?.currentCursor, actualBefore.currentCursor)
      for (direction, revision, text, cursor) in [
        (PagedNativeHistoryHandle.Direction.redo, c.document.revision, "c public🙂\n", 1),
        (.redo, d.document.revision, "d public🙂\n", 1),
        (.undo, c.document.revision, "c public🙂\n", 1),
        (.undo, b.document.revision, "b public🙂\n", 1),
        (.undo, base, "a public🙂\n", 0)] {
        try await f.historyCommand(direction)
        let current = try await f.assertSource(text, revision: revision)
        let history = try await f.history(current)
        XCTAssertEqual(history.currentCursor, PagedSealedCursor(byteOffset: UInt64(cursor), utf16Offset: UInt64(cursor)))
        XCTAssertEqual(f.view.selectedRange(), NSRange(location: cursor, length: 0))
      }
      XCTAssertEqual(f.commands.manager.undoCount, 0); XCTAssertEqual(f.commands.manager.redoCount, 3)
    }
  }

  func testMovedCaretAndBackwardDeleteRestoreObservedStartAcrossFileReopen() async throws {
    try await withFixture { f in
      try f.replaceFirst("b"); try await f.seal()
      f.view.setSelectedRange(NSRange(location: 2, length: 0))
      f.view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await f.seal()
      let typed = try await f.assertSource("b zpublic🙂\n")
      let typedHistory = try await f.history(typed)
      XCTAssertEqual(typedHistory.undo.last?.cursor, PagedSealedCursor(byteOffset: 2, utf16Offset: 2))
      try await f.historyCommand(.undo)
      _ = try await f.assertSource("b public🙂\n")
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 2, length: 0))
      try await f.historyCommand(.redo)
      _ = try await f.assertSource("b zpublic🙂\n", revision: typed.document.revision)
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 3, length: 0))

      // The physical cursor is after the deleted character; using the affected
      // range's start would reproduce a second, independent Undo cursor error.
      f.view.setSelectedRange(NSRange(location: 9, length: 0))
      f.view.doCommand(by: NSSelectorFromString("deleteBackward:"))
      try await f.seal()
      let deleted = try await f.assertSource("b zpubli🙂\n")
      let deletedHistory = try await f.history(deleted)
      XCTAssertEqual(deletedHistory.undo.last?.cursor, PagedSealedCursor(byteOffset: 9, utf16Offset: 9))
      try await f.reopenJoined()
      try await f.historyCommand(.undo)
      _ = try await f.assertSource("b zpublic🙂\n", revision: typed.document.revision)
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 9, length: 0))
      try await f.historyCommand(.redo)
      _ = try await f.assertSource("b zpubli🙂\n", revision: deleted.document.revision)
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 8, length: 0))
    }
  }

  func testFirstNativeMarkedCompositionRetainsMovedStartCursorAcrossAccentedUndoRedo() async throws {
    try await withFixture { f in
      try f.replaceFirst("é"); try await f.seal()
      let before = try await f.assertSource("é public🙂\n")
      let beforeHistory = try await f.history(before)
      XCTAssertEqual(beforeHistory.currentCursor, PagedSealedCursor(byteOffset: 2, utf16Offset: 1))
      f.view.setSelectedRange(NSRange(location: 4, length: 0))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 4, length: 0))
      let startByte = try await f.opened.engine.byteAtUTF16(before.document.revision, offset: 4)
      XCTAssertEqual(startByte, 5)
      let precedingSequence = f.session.generation

      // Call the actual view's marked-text commands. AppKit changes the live
      // caret during updates; the group's first physical start must survive.
      f.view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      if let error = f.view.boundedStorage.mutationFailure { throw error }
      if let error = f.input.firstRefusal { throw error }
      let composition = try XCTUnwrap(f.session.compositionGroupID)
      XCTAssertTrue(f.view.hasMarkedText()); XCTAssertTrue(f.session.isPinned)
      XCTAssertGreaterThan(f.session.generation, precedingSequence)
      XCTAssertEqual(f.view.markedRange(), NSRange(location: 4, length: 1))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 5, length: 0))
      XCTAssertEqual(Data(f.view.string.utf8), Data("é puxblic🙂\n".utf8))

      f.view.setMarkedText("e\u{301}", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      if let error = f.view.boundedStorage.mutationFailure { throw error }
      if let error = f.input.firstRefusal { throw error }
      XCTAssertEqual(f.session.compositionGroupID, composition)
      XCTAssertTrue(f.view.hasMarkedText()); XCTAssertTrue(f.session.isPinned)
      XCTAssertEqual(f.view.markedRange(), NSRange(location: 4, length: 2))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 6, length: 0))
      XCTAssertEqual(Data(f.view.string.utf8), Data("é pue\u{301}blic🙂\n".utf8))

      f.view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
      if let error = f.view.boundedStorage.mutationFailure { throw error }
      if let error = f.input.firstRefusal { throw error }
      f.view.unmarkText()
      if let error = f.view.boundedStorage.mutationFailure { throw error }
      if let error = f.input.firstRefusal { throw error }
      guard !f.view.hasMarkedText(), !f.session.isPinned, f.view.inputCommandIsClosed else {
        throw BoomError.invalid("The actual final marked-text command did not close its native source gate.")
      }
      let completedSequence = f.session.generation
      try await f.seal()
      let composed = try await f.assertSource("é puéblic🙂\n")
      let composedHistory = try await f.history(composed)
      XCTAssertEqual(composedHistory.undo.count, beforeHistory.undo.count + 1)
      XCTAssertEqual(composedHistory.undo.last?.revision, before.document.revision)
      XCTAssertEqual(composedHistory.undo.last?.groupID, composition)
      XCTAssertEqual(composedHistory.undo.last?.cursor, PagedSealedCursor(byteOffset: 5, utf16Offset: 4))
      XCTAssertEqual(composedHistory.activeGroup, composition)
      XCTAssertEqual(composedHistory.currentCursor, PagedSealedCursor(byteOffset: 7, utf16Offset: 5))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 5, length: 0))
      let endpointByte = try await f.opened.engine.byteAtUTF16(composed.document.revision, offset: 5)
      XCTAssertEqual(endpointByte, 7)
      let sealed = await f.route.snapshot
      XCTAssertEqual(sealed.acknowledgements.last?.lastSequence, completedSequence)
      XCTAssertEqual(sealed.acknowledgements.last?.canonicalHistory?.activeGroup, composition)

      try await f.reopenJoined()
      try await f.historyCommand(.undo)
      let undone = try await f.assertSource("é public🙂\n", revision: before.document.revision)
      let undoneHistory = try await f.history(undone)
      XCTAssertEqual(undoneHistory.currentCursor, PagedSealedCursor(byteOffset: 5, utf16Offset: 4))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 4, length: 0))
      try await f.historyCommand(.redo)
      let redone = try await f.assertSource("é puéblic🙂\n", revision: composed.document.revision)
      let redoneHistory = try await f.history(redone)
      XCTAssertEqual(redoneHistory.currentCursor, PagedSealedCursor(byteOffset: 7, utf16Offset: 5))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 5, length: 0))
    }
  }

  func testSeparatelySealedProgrammaticNativeChunksRetainFirstObservedCursor() async throws {
    try await withFixture { f in
      let base = f.initialRecord.document.revision
      _ = try await f.assertSource("a public🙂\n", revision: base)
      f.view.setSelectedRange(NSRange(location: 4, length: 0))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 4, length: 0))
      let precedingSequence = f.session.generation

      // This existing helper admits the real binding and storage primitive,
      // deliberately retaining its native UUID; it is a programmed continuation.
      try f.continuingPrimitive(["é"], oneTransaction: false)
      let firstSequence = f.session.generation
      XCTAssertEqual(firstSequence, precedingSequence + 1)
      try await f.seal()
      let first = try await f.assertSource("é public🙂\n")
      let firstHistory = try await f.history(first)
      let firstEntry = try XCTUnwrap(firstHistory.undo.last)
      let originalGroup = try XCTUnwrap(firstHistory.activeGroup)
      XCTAssertEqual(firstHistory.undo.count, 1)
      XCTAssertEqual(firstEntry.revision, base); XCTAssertEqual(firstEntry.groupID, originalGroup)
      XCTAssertEqual(firstEntry.cursor, PagedSealedCursor(byteOffset: 4, utf16Offset: 4))
      XCTAssertEqual(firstHistory.currentCursor, PagedSealedCursor(byteOffset: 2, utf16Offset: 1))
      XCTAssertEqual(f.commands.manager.undoCount, 1)

      f.view.setSelectedRange(NSRange(location: 6, length: 0))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 6, length: 0))
      let movedByte = try await f.opened.engine.byteAtUTF16(first.document.revision, offset: 6)
      XCTAssertEqual(movedByte, 7)
      try f.continuingPrimitive(["ñ"], oneTransaction: false)
      let secondSequence = f.session.generation
      XCTAssertEqual(secondSequence, firstSequence + 1)
      try await f.seal()
      let second = try await f.assertSource("ñ public🙂\n")
      let secondHistory = try await f.history(second)
      XCTAssertEqual(secondHistory.undo, firstHistory.undo)
      XCTAssertEqual(secondHistory.undo.count, 1)
      XCTAssertEqual(secondHistory.activeGroup, originalGroup)
      XCTAssertEqual(secondHistory.currentCursor, PagedSealedCursor(byteOffset: 2, utf16Offset: 1))
      XCTAssertEqual(f.commands.manager.undoCount, 1)
      let sealed = await f.route.snapshot
      XCTAssertEqual(sealed.acknowledgements.count, 2)
      let firstAck = try XCTUnwrap(sealed.acknowledgements.first)
      let secondAck = try XCTUnwrap(sealed.acknowledgements.last)
      XCTAssertNotEqual(firstAck.batchID, secondAck.batchID)
      XCTAssertEqual(firstAck.lastSequence, firstSequence)
      XCTAssertEqual(secondAck.lastSequence, secondSequence)
      XCTAssertEqual(firstAck.canonicalHistory?.undo, firstHistory.undo)
      XCTAssertEqual(secondAck.canonicalHistory?.undo, firstHistory.undo)

      try await f.historyCommand(.undo)
      let undone = try await f.assertSource("a public🙂\n", revision: base)
      let undoneHistory = try await f.history(undone)
      XCTAssertEqual(undoneHistory.currentCursor, PagedSealedCursor(byteOffset: 4, utf16Offset: 4))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 4, length: 0))
      XCTAssertEqual(f.commands.manager.undoCount, 0); XCTAssertEqual(f.commands.manager.redoCount, 1)
      try await f.historyCommand(.redo)
      let redone = try await f.assertSource("ñ public🙂\n", revision: second.document.revision)
      let redoneHistory = try await f.history(redone)
      XCTAssertEqual(redoneHistory.currentCursor, PagedSealedCursor(byteOffset: 2, utf16Offset: 1))
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: 1, length: 0))
      XCTAssertEqual(f.commands.manager.undoCount, 1); XCTAssertEqual(f.commands.manager.redoCount, 0)
    }
  }

  func testActualHeldSealPreservesSourceNewerFoundationTargetWithoutSyntheticUndo() async throws {
    try await withFixture { f in
      let notifications = CanonicalPublicNotifications(); f.observeHistoryNotifications(notifications)
      let first = try await f.route.gate.holdNext(.commitAfter)
      try f.replaceFirst("b"); try await f.route.gate.awaitHeld(first)
      let second = try await f.route.gate.holdNext(.commitBefore)
      try f.replaceFirst("c"); let later = try f.top(.undo)
      XCTAssertEqual(f.session.generation, 2); XCTAssertEqual(f.commands.manager.undoCount, 2)
      try await f.route.gate.release(first); try await f.route.gate.awaitHeld(second)
      XCTAssertEqual(f.session.canonicalHistory?.scope.coveredSequence, 1)
      XCTAssertTrue(try f.top(.undo) === later)
      XCTAssertEqual(f.view.string, "c public🙂\n")
      XCTAssertEqual(notifications.willUndo, 0); XCTAssertEqual(notifications.willRedo, 0)
      try await f.route.gate.release(second); try await f.seal()
      let final = try await f.assertSource("c public🙂\n")
      let history = try await f.history(final)
      XCTAssertEqual(history.undo.count, 2)
      XCTAssertTrue(try f.top(.undo) === later)
      XCTAssertEqual(notifications.willUndo, 0); XCTAssertEqual(notifications.willRedo, 0)
      let actual = await f.route.snapshot
      XCTAssertEqual(actual.acknowledgements.map(\.lastSequence), [1, 2])
      XCTAssertEqual(actual.acknowledgements.last?.sealedRootRecord, final)
    }
  }

  func testPostPrefixCoalescenceSelectsExactCanonicalSlotAndReplaysOnlyOriginalRawInput() async throws {
    try await withFixture { f in
      let notifications = CanonicalPublicNotifications(); f.observeHistoryNotifications(notifications)
      let held = try await f.route.gate.holdNext(.commitBefore)
      try f.continuingPrimitive(["b"], oneTransaction: false)
      try f.continuingPrimitive(["c"], oneTransaction: false)
      XCTAssertEqual(f.commands.manager.undoCount, 2)
      let originalTarget = try f.top(.undo)
      f.commands.manager.undo()
      let prefix = try XCTUnwrap(f.commands.retainedPrefix)
      XCTAssertEqual(prefix.generation, 2)
      let originalInputLease = try f.input.inputLease(for: f.view)
      weak var retainedOriginalEvent: NSEvent?
      try autoreleasepool {
        let event = try f.key(); retainedOriginalEvent = event
        f.view.keyDown(with: event)
      }
      XCTAssertNotNil(retainedOriginalEvent) // Root must own the actual original intercepted event
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1)
      XCTAssertEqual(f.session.generation, 2)
      try await f.route.gate.awaitHeld(held)
      try await f.route.gate.release(held)
      try await f.commands.joinPendingCommand(); try await f.seal()
      let actual = await f.route.gate.snapshot
      let prepared = try XCTUnwrap(actual.preparations.first)
      let selected = try XCTUnwrap(prepared.command.canonicalSelection)
      let sealed = await f.route.snapshot
      XCTAssertEqual(sealed.acknowledgements.count, 3) // two prefix chunks, then actual replay
      XCTAssertEqual(sealed.acknowledgements[0].canonicalHistory?.undo.count, 1)
      XCTAssertEqual(sealed.acknowledgements[1].canonicalHistory?.undo.count, 1)
      XCTAssertEqual(selected.record, sealed.acknowledgements[1].sealedRootRecord)
      XCTAssertEqual(selected.coveredSequence, prefix.generation)
      XCTAssertEqual(selected.direction, .undo); XCTAssertEqual(selected.index, 0)
      XCTAssertEqual(selected.entry.revision, f.initialRecord.document.revision)
      XCTAssertEqual(selected.entry.groupID, prepared.command.handle.groupID)
      XCTAssertEqual(actual.historyResults.first?.sealedRootRecord.document.revision, f.initialRecord.document.revision)
      XCTAssertEqual(notifications.willUndo, 1); XCTAssertEqual(notifications.willRedo, 0)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 0)
      XCTAssertNotEqual(try f.input.inputLease(for: f.view).identity, originalInputLease.identity)
      XCTAssertNil(f.commands.retainedPrefix); XCTAssertNil(f.commands.firstFailure)
      XCTAssertFalse(try f.top(.undo) === originalTarget)
      _ = try await f.assertSource("za public🙂\n")
      XCTAssertEqual(f.session.generation, 4)
    }
  }

  func testGenuineNetZeroEpochPreservesRealRedoAndUnchangedPrimitiveAddsNoSeal() async throws {
    try await withFixture { f in
      try f.replaceFirst("b"); try await f.seal(); let b = try await f.record()
      try f.replaceFirst("c"); try await f.seal(); let c = try await f.record()
      try await f.historyCommand(.undo)
      let before = try await f.record(), old = try await f.history(before)
      let undoTarget = try f.top(.undo), redoTarget = try f.top(.redo)
      XCTAssertEqual(before.document.revision, b.document.revision)
      let notifications = CanonicalPublicNotifications(); f.observeHistoryNotifications(notifications)
      let generation = f.session.generation
      try f.continuingPrimitive(["d", "b"], oneTransaction: true)
      XCTAssertEqual(f.session.generation, generation + 2)
      try await f.seal()
      let current = try await f.assertSource("b public🙂\n", revision: b.document.revision)
      let next = try await f.history(current)
      XCTAssertGreaterThan(current.historyGeneration, before.historyGeneration)
      XCTAssertEqual(next.undo, old.undo); XCTAssertEqual(next.redo, old.redo)
      XCTAssertEqual(next.activeGroup, old.activeGroup)
      XCTAssertTrue(try f.top(.undo) === undoTarget); XCTAssertTrue(try f.top(.redo) === redoTarget)
      XCTAssertEqual(notifications.willUndo, 0); XCTAssertEqual(notifications.willRedo, 0)
      let count = (await f.route.snapshot).acknowledgements.count, accepted = f.session.generation
      f.view.insertText("b", replacementRange: NSRange(location: 0, length: 1))
      try await f.seal()
      XCTAssertEqual(f.session.generation, accepted)
      let unchangedSnapshot = await f.route.snapshot, unchangedRecord = try await f.record()
      XCTAssertEqual(unchangedSnapshot.acknowledgements.count, count)
      XCTAssertEqual(unchangedRecord, current)
      try await f.historyCommand(.redo)
      _ = try await f.assertSource("c public🙂\n", revision: c.document.revision)
      XCTAssertEqual(notifications.willRedo, 1)
    }
  }

  func testActualNewProducerInspectionAndLostJoinedFinishRejoinKeepReceivingFailureAndRawInput() async throws {
    let name = "testActualNewProducerInspectionAndLostJoinedFinishRejoinKeepReceivingFailureAndRawInput"
    try await withFixture(isolatedCase: name) { f in
      try f.replaceFirst("b"); try await f.seal()
      let notifications = CanonicalPublicNotifications(); f.observeHistoryNotifications(notifications)
      await f.route.refuseNextHistoryFinishBeforeCall()
      f.commands.manager.undo()
      do { try await f.commands.joinPendingCommand(); XCTFail("The deliberately refused real finish must remain unresolved.") }
      catch { guard (error as? CanonicalPublicFault) == .refusedHistoryFinishBeforeCall else { throw error } }
      let prepared = try XCTUnwrap(f.commands.retainedPreparation)
      let firstSnapshot = await f.route.snapshot
      let admission = try XCTUnwrap(firstSnapshot.admissions.first)
      let original = try XCTUnwrap(f.session.canonicalHistory)
      let target = try f.top(.redo), prefix = try XCTUnwrap(f.commands.retainedPrefix)
      let before = try await f.record()
      XCTAssertEqual(before, prepared.candidateRecord)
      let pendingReachability = await f.backend.historyReachability()
      XCTAssertNotNil(pendingReachability)
      let originalInputLease = try f.input.inputLease(for: f.view)
      weak var retainedOriginalEvent: NSEvent?
      try autoreleasepool {
        let event = try f.key(); retainedOriginalEvent = event
        f.view.keyDown(with: event)
      }
      XCTAssertNotNil(retainedOriginalEvent) // Root must own the actual original intercepted event
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1)
      // This is the ACTUAL new worker inspection, before any finish retires
      // pending custody. The output is retained separately; no decorator
      // substitutes it for Backend.inspectHistoryRecovery or creates an ACK.
      let inspected = try await f.opened.engine.inspectNativeHistoryPublicationRetaining(prepared,
        admission: admission, publisher: f.publisher)
      try f.retainInspection(inspected)
      guard case .published(let newACK) = inspected.value else { throw BoomError.stale("Actual file inspection did not prove the published record.") }
      let newMetadata = try XCTUnwrap(newACK.canonicalHistory)
      XCTAssertEqual(newMetadata.producer.id, inspected.lease.id)
      let producer = try XCTUnwrap(f.opened.engine.custodySnapshot.items.first { $0.id == inspected.lease.id })
      XCTAssertTrue(producer.producerJoined)
      XCTAssertGreaterThan(producer.outputInFlightWitness ?? 0, 0)
      XCTAssertTrue(producer.claims.contains(.record(prepared.command.expectedRootRecord)))
      XCTAssertTrue(producer.claims.contains(.record(prepared.candidateRecord)))
      XCTAssertNotEqual(newMetadata.producer.id, original.producer.id)
      XCTAssertTrue(newMetadata.hasSamePublishedMetadata(as: original))
      await f.route.loseNextJoinedHistoryFinishReply()
      try f.session.acceptRecoveredHistory(newACK)
      do { _ = try await f.session.joinHistoryPublication(commandID: admission.commandID); XCTFail("The actual joined finish reply was deliberately lost.") }
      catch { guard (error as? CanonicalPublicFault) == .lostJoinedHistoryFinishReply else { throw error } }
      XCTAssertEqual(f.session.canonicalHistory?.producer.id, newMetadata.producer.id)
      XCTAssertTrue(try f.top(.redo) === target)
      let finishedReachability = await f.backend.historyReachability()
      XCTAssertNil(finishedReachability)
      let recovery = try await f.session.inspectHistoryRecovery()
      guard case .published(let joinedACK) = recovery else { throw BoomError.stale("The exact actual joined finish receipt did not rejoin.") }
      // The Backend receipt is the old actual publication ACK, not a claim
      // that another job just inspected the source. Its exact same metadata
      // can complete the pending Session join idempotently.
      XCTAssertEqual(joinedACK.preparationID, prepared.preparationID)
      XCTAssertTrue(try XCTUnwrap(joinedACK.canonicalHistory).hasSamePublishedMetadata(as: newMetadata))
      try f.session.acceptRecoveredHistory(joinedACK)
      let completed = try await f.session.joinHistoryPublication(commandID: admission.commandID)
      XCTAssertEqual(completed.sealedRootRecord, before)
      XCTAssertFalse(f.session.hasPendingHistoryCommand)
      XCTAssertNil(f.session.persistenceFailure); XCTAssertNil(f.session.historyFailure)
      XCTAssertTrue(try f.top(.redo) === target)
      XCTAssertEqual(notifications.willUndo, 1); XCTAssertEqual(notifications.willRedo, 0)
      let route = await f.route.snapshot
      XCTAssertEqual(route.beforeFinishRefusals, 1); XCTAssertEqual(route.lostFinishReplies, 1)
      XCTAssertEqual(route.joinedHistoryFinishReturns, 2) // actual finish, then its exact joined receipt
      let gateSnapshot = await f.route.gate.snapshot, after = try await f.record()
      XCTAssertEqual(gateSnapshot.historyResults.count, 1)
      XCTAssertEqual(after, before)
      XCTAssertEqual(f.commands.retainedPrefix, prefix)
      XCTAssertEqual(f.commands.retainedPreparation, prepared)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1)
      guard (f.commands.firstFailure as? CanonicalPublicFault) == .refusedHistoryFinishBeforeCall else {
        throw BoomError.invalid("Session rejoin cleared or replaced the independent receiving-owner failure.")
      }
      requireRefusal { try f.commands.closeInput() }
      // A separate actual receiving discrepancy must not be cleared with the
      // older joined-finish error. This is real SDK disposal, not a fake hook.
      // The next real native ACK reaches Root's owned throwing metadata hook
      // and is refused BEFORE any canonical reconciliation mutation.
      f.commands.manager.removeAllActions()
      let admitted = f.session.generation
      f.view.insertText("q", replacementRange: NSRange(location: 0, length: 0))
      XCTAssertEqual(f.session.generation, admitted + 1)
      XCTAssertEqual(f.view.string, "qa public🙂\n")
      do { try await f.seal(); XCTFail("The actual canonical receiving discrepancy must retain the new ACK.") }
      catch { guard case BoomError.stale = error else { throw error } }
      let pendingACK = try XCTUnwrap(f.session.pendingCommitInstallation)
      let newHead = try await f.record(), source = try await f.source(newHead)
      XCTAssertEqual(pendingACK.expectedRootRecord, before)
      XCTAssertEqual(pendingACK.sealedRootRecord, newHead)
      XCTAssertEqual(Data(source.text.utf8), Data("qa public🙂\n".utf8))
      XCTAssertEqual(f.view.string, "qa public🙂\n")
      XCTAssertNotNil(f.session.persistenceFailure)
      XCTAssertNotNil(f.commands.unregisteredGroup)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1)
      XCTAssertNotNil(retainedOriginalEvent)
      XCTAssertEqual(try f.input.inputLease(for: f.view), originalInputLease)
      XCTAssertEqual(f.commands.retainedPrefix, prefix)
      XCTAssertTrue(f.opened.engine.custodySnapshot.items.contains { item in
        if case .controller = item.purpose {
          return item.pendingBatchID == pendingACK.batchID
            && item.claims.contains(.record(before)) && item.claims.contains(.record(newHead))
        }; return false
      })
      guard (f.commands.firstFailure as? CanonicalPublicFault) == .refusedHistoryFinishBeforeCall else {
        throw BoomError.invalid("The newer canonical receiving failure replaced the original retained failure.")
      }
      requireRefusal { try f.commands.closeInput() }
      // Worker/source history rejoin passed; original receiving intent/raw
      // input plus a NEW independent ordinary ACK/refused group remain OPEN.
      // No fixture restores hidden SDK targets or fabricates a joined close.
    }
  }

  /// ACTUAL lost receiving reply, then ACTUAL same-current Session finish. The
  /// source-newer group enters while the real finish is held, not after Root
  /// becomes blocked. No ACK or projection is constructed by this helper.
  private func actualJoinedReceivingFailureWithSourceNewerGroup(_ f: CanonicalPublicFixture)
    async throws -> (prepared: PagedNativePreparedHistoryMove,
      prefix: PagedNativePrefixReservation, current: PagedDocumentRootRecord) {
    try f.replaceFirst("b"); try await f.seal()
    let held = try await f.route.gate.holdNext(.historyInstallationBefore)
    await f.route.loseNextJoinedHistoryFinishReply()
    f.commands.manager.undo()
    try await f.route.gate.awaitHeld(held)
    XCTAssertEqual(f.view.string, "a public🙂\n")
    try f.replaceFirst("c")
    try await f.route.gate.release(held)
    do { try await f.commands.joinPendingCommand(); XCTFail("The real joined finish reply must be lost before receiving disposition.") }
    catch { guard (error as? CanonicalPublicFault) == .lostJoinedHistoryFinishReply else { throw error } }
    let prepared = try XCTUnwrap(f.commands.retainedPreparation)
    let prefix = try XCTUnwrap(f.commands.retainedPrefix)
    let recovery = try await f.session.inspectHistoryRecovery()
    guard case .published(let acknowledgement) = recovery else {
      throw BoomError.stale("Actual joined history custody was not recoverable.")
    }
    try f.session.acceptRecoveredHistory(acknowledgement)
    let actual = try await f.session.joinHistoryPublication(commandID: prepared.command.commandID)
    XCTAssertEqual(actual.sealedRootRecord, prepared.candidateRecord)
    try await f.seal() // the actual G+1 native producer/finish also joins
    XCTAssertFalse(f.session.hasPendingHistoryCommand)
    XCTAssertNil(f.session.pendingCommitInstallation)
    XCTAssertNil(f.session.persistenceFailure); XCTAssertNil(f.session.historyFailure)
    guard (f.commands.firstFailure as? CanonicalPublicFault) == .lostJoinedHistoryFinishReply else {
      throw BoomError.invalid("Actual Session completion silently cleared the independent receiving failure.")
    }
    return (prepared, prefix, try await f.record())
  }

  func testExplicitExpiredIntentCancellationKeepsActualLaterTextAndOriginalEventsBeforeNormalReplay() async throws {
    try await withFixture { f in
      let notifications = CanonicalPublicNotifications(); f.observeHistoryNotifications(notifications)
      let first = try await f.route.gate.holdNext(.commitAfter)
      try f.replaceFirst("b"); try await f.route.gate.awaitHeld(first)
      for index in 0..<105 { try f.replaceFirst(index.isMultiple(of: 2) ? "c" : "d") }
      let second = try await f.route.gate.holdNext(.commitAfter)
      try await f.route.gate.release(first); try await f.route.gate.awaitHeld(second)
      f.commands.manager.undo()
      let prefix = try XCTUnwrap(f.commands.retainedPrefix)
      XCTAssertEqual(prefix.generation, 106)
      for index in 0..<105 { try f.replaceFirst(index.isMultiple(of: 2) ? "d" : "c") }
      let lease = try f.input.inputLease(for: f.view)
      weak var original: NSEvent?
      try autoreleasepool { let event = try f.key(); original = event; f.view.keyDown(with: event) }
      try await f.route.gate.release(second)
      do { try await f.commands.joinPendingCommand(); XCTFail("The actually expired selected target must remain unconsumed.") }
      catch { guard case BoomError.stale = error else { throw error } }
      XCTAssertEqual(f.session.generation, 211); XCTAssertEqual(f.view.string, "d public🙂\n")
      let before = try await f.record(), top = try f.top(.undo)
      let ticket = try f.commands.prepareReceivingDisposition(.cancelUnpreparedHistoryKeepingInput)
      // A later actual event invalidates the observation, without a new error
      // or loss. Explicitly disposing this token only drops metadata.
      weak var later: NSEvent?
      try autoreleasepool { let event = try f.key(); later = event; f.view.keyDown(with: event) }
      do { _ = try await f.commands.applyReceivingDisposition(ticket); XCTFail("The older exact queue observation must refuse.") }
      catch { guard case BoomError.stale = error else { throw error } }
      XCTAssertNotNil(original); XCTAssertNotNil(later)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 2); XCTAssertEqual(f.commands.retainedPrefix, prefix)
      XCTAssertEqual(try f.input.inputLease(for: f.view), lease)
      XCTAssertEqual(f.view.string, "d public🙂\n"); XCTAssertTrue(try f.top(.undo) === top)
      try f.commands.discardReceivingDispositionTicket(ticket)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 2); XCTAssertNotNil(f.commands.firstFailure)
      let current = try f.commands.prepareReceivingDisposition(.cancelUnpreparedHistoryKeepingInput)
      let normalSeal = try await f.route.gate.holdNext(.commitBefore)
      let receipt = try await f.commands.applyReceivingDisposition(current)
      XCTAssertEqual(receipt.choice, .cancelUnpreparedHistoryKeepingInput)
      XCTAssertEqual(receipt.checkpoint.record, before)
      XCTAssertEqual(receipt.checkpoint.generation, 211); XCTAssertEqual(receipt.checkpoint.sealedGeneration, 106)
      XCTAssertEqual(receipt.prefix, prefix); XCTAssertEqual(receipt.queuedRawKeyCount, 2)
      XCTAssertFalse(receipt.receivingOwnerRemainsBlocked)
      XCTAssertEqual(f.commands.lastReceivingDisposition?.ticketID, receipt.ticketID)
      XCTAssertNil(f.commands.retainedPrefix); XCTAssertNil(f.commands.retainedPreparation)
      XCTAssertNil(f.commands.firstFailure); XCTAssertNil(f.commands.independentReceivingFailure)
      XCTAssertNotNil(original); XCTAssertNotNil(later)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 2); XCTAssertEqual(f.session.generation, 211)
      XCTAssertEqual(f.view.string, "d public🙂\n"); XCTAssertTrue(try f.top(.undo) === top)
      XCTAssertEqual(notifications.willUndo, 0); XCTAssertEqual(notifications.willRedo, 0)
      requireRefusal { try f.commands.closeInput() }
      // The explicit receiving receipt did NOT interpret or drop the events.
      // Resume the existing native lane, then join real source producers.
      f.commands.inputCommandDidClose()
      XCTAssertEqual(f.commands.queuedRawKeyCount, 0)
      XCTAssertEqual(f.session.generation, 213); XCTAssertEqual(f.view.string, "dzz public🙂\n")
      try await f.route.gate.awaitHeld(normalSeal); try await f.route.gate.release(normalSeal)
      try await f.seal()
      _ = try await f.assertSource("dzz public🙂\n")
      let actual = await f.route.gate.snapshot
      XCTAssertTrue(actual.historyResults.isEmpty)
      XCTAssertEqual(actual.batches.last?.lastSequence, 213)
      do { _ = try await f.commands.applyReceivingDisposition(current); XCTFail("An actually consumed cancellation ticket cannot apply twice.") }
      catch { guard case BoomError.stale = error else { throw error } }
      _ = try await f.assertSource("dzz public🙂\n")
    }
  }

  func testReceivingOnlyCompletionFollowsActualJoinedHistoryAndLaterNativeSealWithoutSDKOrRawReplay() async throws {
    try await withFixture { f in
      let notifications = CanonicalPublicNotifications(); f.observeHistoryNotifications(notifications)
      let joined = try await self.actualJoinedReceivingFailureWithSourceNewerGroup(f)
      let laterTarget = try f.top(.undo), lease = try f.input.inputLease(for: f.view)
      let actual = try await f.history(joined.current)
      XCTAssertEqual(f.view.string, "c public🙂\n"); XCTAssertEqual(f.session.generation, 3)
      XCTAssertNotEqual(joined.current, joined.prepared.candidateRecord)
      XCTAssertTrue(actual.redo.isEmpty)
      weak var original: NSEvent?
      try autoreleasepool { let event = try f.key(); original = event; f.view.keyDown(with: event) }
      let ticket = try f.commands.prepareReceivingDisposition(.completeJoinedHistoryReceiving)
      let futureReplaySeal = try await f.route.gate.holdNext(.commitBefore)
      let receipt = try await f.commands.applyReceivingDisposition(ticket)
      XCTAssertEqual(receipt.choice, .completeJoinedHistoryReceiving)
      XCTAssertEqual(receipt.checkpoint.record, joined.current)
      XCTAssertEqual(receipt.checkpoint.completedHistory?.preparationID, joined.prepared.preparationID)
      XCTAssertEqual(receipt.checkpoint.completedHistory?.afterRecord, joined.prepared.candidateRecord)
      XCTAssertEqual(receipt.checkpoint.generation, 3); XCTAssertEqual(receipt.checkpoint.sealedGeneration, 3)
      XCTAssertEqual(receipt.prefix, joined.prefix); XCTAssertEqual(receipt.queuedRawKeyCount, 1)
      XCTAssertFalse(receipt.receivingOwnerRemainsBlocked)
      XCTAssertNil(f.commands.retainedPrefix); XCTAssertNil(f.commands.retainedPreparation)
      XCTAssertNil(f.commands.firstFailure); XCTAssertNil(f.commands.independentReceivingFailure)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1); XCTAssertNotNil(original)
      XCTAssertEqual(try f.input.inputLease(for: f.view), lease)
      XCTAssertEqual(f.view.string, "c public🙂\n"); XCTAssertEqual(f.session.generation, 3)
      XCTAssertTrue(try f.top(.undo) === laterTarget)
      XCTAssertEqual(notifications.willUndo, 1); XCTAssertEqual(notifications.willRedo, 0)
      let beforeReplay = try await f.record()
      XCTAssertEqual(beforeReplay, joined.current)
      requireRefusal { try f.commands.closeInput() }
      do { _ = try await f.commands.applyReceivingDisposition(ticket); XCTFail("An actually joined receiving ticket cannot complete twice.") }
      catch { guard case BoomError.stale = error else { throw error } }
      f.commands.inputCommandDidClose()
      XCTAssertEqual(f.commands.queuedRawKeyCount, 0); XCTAssertEqual(f.session.generation, 4)
      XCTAssertEqual(f.view.string, "cz public🙂\n")
      try await f.route.gate.awaitHeld(futureReplaySeal); try await f.route.gate.release(futureReplaySeal)
      try await f.seal()
      _ = try await f.assertSource("cz public🙂\n")
      try await f.historyCommand(.undo)
      _ = try await f.assertSource("c public🙂\n", revision: joined.current.document.revision)
      try await f.historyCommand(.undo)
      _ = try await f.assertSource("a public🙂\n", revision: f.initialRecord.document.revision)
    }
  }

  func testOldReceivingTicketRefusesActualNewSDKAndPendingACKFailureKeepingBothSourcesAndOriginalInput() async throws {
    let name = "testOldReceivingTicketRefusesActualNewSDKAndPendingACKFailureKeepingBothSourcesAndOriginalInput"
    try await withFixture(isolatedCase: name) { f in
      let joined = try await self.actualJoinedReceivingFailureWithSourceNewerGroup(f)
      let lease = try f.input.inputLease(for: f.view)
      weak var original: NSEvent?
      try autoreleasepool { let event = try f.key(); original = event; f.view.keyDown(with: event) }
      let ticket = try f.commands.prepareReceivingDisposition(.completeJoinedHistoryReceiving)
      f.commands.manager.removeAllActions() // actual SDK projection discrepancy
      f.view.insertText("q", replacementRange: NSRange(location: 0, length: 0))
      XCTAssertEqual(f.session.generation, 4); XCTAssertEqual(f.view.string, "qc public🙂\n")
      do { try await f.seal(); XCTFail("The new actual canonical hook refusal must retain its ordinary ACK.") }
      catch { guard case BoomError.stale = error else { throw error } }
      let pending = try XCTUnwrap(f.session.pendingCommitInstallation)
      let current = try await f.record(), source = try await f.source(current)
      XCTAssertEqual(pending.expectedRootRecord, joined.current)
      XCTAssertEqual(pending.sealedRootRecord, current)
      XCTAssertEqual(Data(source.text.utf8), Data("qc public🙂\n".utf8))
      XCTAssertNotNil(f.session.persistenceFailure)
      XCTAssertNotNil(f.commands.unregisteredGroup)
      XCTAssertNotNil(f.commands.independentReceivingFailure)
      do { _ = try await f.commands.applyReceivingDisposition(ticket); XCTFail("A new real receiving/source failure must supersede the older ticket.") }
      catch { guard case BoomError.stale = error else { throw error } }
      XCTAssertNil(f.commands.lastReceivingDisposition)
      XCTAssertEqual(f.commands.retainedPrefix, joined.prefix)
      XCTAssertEqual(f.commands.retainedPreparation, joined.prepared)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1); XCTAssertNotNil(original)
      XCTAssertEqual(try f.input.inputLease(for: f.view), lease)
      XCTAssertEqual(f.view.string, "qc public🙂\n"); XCTAssertEqual(f.session.generation, 4)
      guard (f.commands.firstFailure as? CanonicalPublicFault) == .lostJoinedHistoryFinishReply else {
        throw BoomError.invalid("The old receiving ticket cleared or replaced the original actual finish failure.")
      }
      XCTAssertTrue(f.opened.engine.custodySnapshot.items.contains { item in
        if case .controller = item.purpose {
          return item.pendingBatchID == pending.batchID && item.claims.contains(.record(joined.current))
            && item.claims.contains(.record(current))
        }; return false
      })
      try f.commands.discardReceivingDispositionTicket(ticket)
      requireRefusal { _ = try f.commands.prepareReceivingDisposition(.completeJoinedHistoryReceiving) }
      XCTAssertEqual(f.commands.retainedPrefix, joined.prefix)
      XCTAssertEqual(f.commands.retainedPreparation, joined.prepared)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1); XCTAssertNotNil(original)
      XCTAssertNotNil(f.commands.firstFailure); XCTAssertNotNil(f.commands.independentReceivingFailure)
      XCTAssertNotNil(f.session.pendingCommitInstallation); XCTAssertNotNil(f.session.persistenceFailure)
      requireRefusal { try f.commands.closeInput() }
      // This new negative receiving case has an actual pending ordinary ACK,
      // SDK discrepancy and refused group. No receiving disposition repairs
      // or drops them; component calls join, and all owners remain retained.
    }
  }

  func testActualCanonicalACKRefusalPropagatesThroughReservedUndoWithoutInventingIndependentFailure() async throws {
    let name = "testActualCanonicalACKRefusalPropagatesThroughReservedUndoWithoutInventingIndependentFailure"
    try await withFixture(isolatedCase: name) { f in
      let held = try await f.route.gate.holdNext(.commitAfter)
      try f.replaceFirst("b"); try await f.route.gate.awaitHeld(held)
      f.commands.manager.undo()
      let prefix = try XCTUnwrap(f.commands.retainedPrefix)
      let lease = try f.input.inputLease(for: f.view)
      weak var original: NSEvent?
      try autoreleasepool { let event = try f.key(); original = event; f.view.keyDown(with: event) }
      f.commands.manager.removeAllActions()
      try await f.route.gate.release(held)
      do { try await f.commands.joinPendingCommand(); XCTFail("The actual ACK metadata refusal must propagate through the prefix join.") }
      catch { guard case BoomError.stale = error else { throw error } }
      let pending = try XCTUnwrap(f.session.pendingCommitInstallation)
      let current = try await f.record(), source = try await f.source(current)
      XCTAssertEqual(pending.expectedRootRecord, f.initialRecord)
      XCTAssertEqual(pending.sealedRootRecord, current)
      XCTAssertEqual(Data(source.text.utf8), Data("b public🙂\n".utf8))
      XCTAssertEqual(f.view.string, "b public🙂\n"); XCTAssertEqual(f.session.generation, 1)
      XCTAssertNotNil(f.commands.firstFailure)
      XCTAssertNil(f.commands.independentReceivingFailure) // propagation of the SAME real owned-hook refusal
      XCTAssertNil(f.commands.unregisteredGroup)
      XCTAssertEqual(f.commands.retainedPrefix, prefix); XCTAssertNil(f.commands.retainedPreparation)
      XCTAssertEqual(f.commands.queuedRawKeyCount, 1); XCTAssertNotNil(original)
      XCTAssertEqual(try f.input.inputLease(for: f.view), lease)
      XCTAssertNotNil(f.session.persistenceFailure)
      requireRefusal { _ = try f.commands.prepareReceivingDisposition(.cancelUnpreparedHistoryKeepingInput) }
      XCTAssertEqual(f.session.pendingCommitInstallation?.batchID, pending.batchID)
      XCTAssertTrue(f.opened.engine.custodySnapshot.items.contains { item in
        if case .controller = item.purpose {
          return item.pendingBatchID == pending.batchID && item.claims.contains(.record(f.initialRecord))
            && item.claims.contains(.record(current))
        }; return false
      })
      requireRefusal { try f.commands.closeInput() }
      // No target or metadata restoration is invented to make this negative
      // pass. The real SDK discrepancy and ordinary ACK remain unresolved.
    }
  }
}
