import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY. Real SQL fixture dependencies and isolated nominations must be
// frozen and qualified; omission of the guard is not case acceptance.

/// Only small, public component fixtures. This file proposes controls; neither
/// authored source nor a skipped isolated case is a lifecycle qualification.
/// The route shared with staged controls forwards the actual encrypted backend.
private struct PagedManagedOpen: Sendable {
  let root: URL
  let ownerID: UUID
  let storeID: UUID
  let vault: Vault
  let engine: PagedTextEngineAdapter
}

@MainActor private final class PagedManagedNotificationState {
  var willUndo = 0
  var didUndo = 0
  var willRedo = 0
  var didRedo = 0
  var injectedUndo = false
  var injectedRedo = false
}

/// Retain the actual context and its actual immutable client, never a view or
/// TextKit storage. ARC/reference ownership is separate from worker/root joins.
@MainActor private final class PagedManagedRetiredClient {
  let context: NSTextInputContext
  let client: PagedNativeTextInputClient
  let identity: PagedNativeInputIdentity
  weak var view: PagedNativeTextView?
  weak var storage: PagedNativeTextStorage?

  init(_ view: PagedNativeTextView) throws {
    context = try XCTUnwrap(view.inputContext)
    client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
    identity = client.identity
    self.view = view; storage = view.boundedStorage
  }

  func deliverOldCallbacks() {
    client.insertText("OLD", replacementRange: NSRange(location: 0, length: 1))
    client.setMarkedText("旧", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 1))
    client.unmarkText()
    client.doCommand(by: NSSelectorFromString("undo:"))
    client.doCommand(by: NSSelectorFromString("redo:"))
  }
}

@MainActor private final class PagedManagedFixture {
  let setup: PagedStagedSetup
  private let sqlIdentity: PagedSQLPublicControlIdentity
  private let maintenance: PagedSQLNativeFixtureMaintenance
  private(set) var failedCommandJoin: Error?
  var backend: PagedNativeStorageBackend
  var route: PagedStagedControlledStorage
  var session: PagedNativeSession
  var input: PagedNativeInputOwner
  var commands: PagedNativeUndoOwner
  let window: NSWindow
  let scroll: NSScrollView
  private var readOutputs: [PagedTextRootLease] = []
  private var notificationTokens: [NSObjectProtocol] = []
  private(set) var mountedIdentities: [PagedNativeInputIdentity] = []
  private(set) var retiredRoutes = 0

  var view: PagedNativeTextView { input.activeView }

  init(_ setup: PagedStagedSetup, sqlIdentity: PagedSQLPublicControlIdentity) throws {
    self.setup = setup; self.sqlIdentity = sqlIdentity
    maintenance = PagedSQLNativeFixtureMaintenance(engine: setup.engine); backend = setup.backend
    route = PagedStagedControlledStorage(setup.backend)
    session = try PagedNativeSession(window: setup.window, rootRecord: setup.record, storage: route)
    input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
    commands = try PagedNativeUndoOwner(input: input)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Public"
    scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
    window.contentView = scroll
    wireMount()
    scroll.documentView = view
    window.makeKeyAndOrderFront(nil)
    // Keep the fully constructed owner graph available for failed diagnostics
    // even if AppKit refuses focus. Actual preparation still requires focus.
    XCTAssertTrue(window.makeFirstResponder(view))
    XCTAssertTrue(window.firstResponder === view)
    mountedIdentities = [try XCTUnwrap(input.activeIdentity)]
  }

  private func wireMount() {
    commands.mountView = { [weak self] old, new in
      guard let self else {
        XCTFail("The real managed mount lost its public window owner.")
        throw BoomError.unavailable("Actual managed physical mount owner is absent.")
      }
      XCTAssertTrue(self.scroll.documentView === old)
      XCTAssertTrue(self.input.activeView === new)
      self.scroll.documentView = new
      XCTAssertTrue(self.window.makeFirstResponder(new))
      XCTAssertTrue(self.window.firstResponder === new)
      guard self.mountedIdentities.count < 16, let identity = self.input.activeIdentity else {
        XCTFail("Public managed mount evidence exceeded its fixed bound or lost the physical identity.")
        throw BoomError.budget("Actual public physical mount evidence is full or unbound.")
      }
      self.mountedIdentities.append(identity)
    }
  }

  func observe(_ name: Notification.Name, _ body: @escaping @MainActor () -> Void) throws {
    guard notificationTokens.count < 8 else { throw BoomError.budget("Public notification evidence exceeds its bound.") }
    let token = NotificationCenter.default.addObserver(forName: name,
      object: commands.manager, queue: .main) { _ in MainActor.assumeIsolated { body() } }
    notificationTokens.append(token)
  }

  func removeObservers() {
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    notificationTokens.removeAll()
  }

  func replaceFirst(_ text: String) throws {
    let before = session.generation
    view.insertText(text, replacementRange: NSRange(location: 0, length: 1))
    guard input.firstRefusal == nil, view.boundedStorage.mutationFailure == nil,
      session.generation == before + 1 else {
      throw BoomError.invalid("The actual public native edit was refused or did not enter one source primitive.")
    }
  }

  /// This joins tasks the Root owner actually entered. A known notification
  /// control can enqueue exactly two operations: joining the first may refuse
  /// quiescence because its defer started the second. No time-based polling.
  func joinCommands(maximumEntered: Int = 1) async throws {
    guard maximumEntered > 0, maximumEntered <= 2 else { throw BoomError.invalid("Public command join bound changed.") }
    for index in 0..<maximumEntered {
      do { try await commands.joinPendingCommand(); return }
      catch {
        guard case BoomError.stale = error, index + 1 < maximumEntered,
          commands.hasPendingCommand, commands.firstFailure == nil,
          session.historyFailure == nil, session.persistenceFailure == nil else { throw error }
      }
    }
    throw BoomError.stale("The actual public command tasks did not reach quiescence within their admitted count.")
  }

  func sealCurrent() async throws -> PagedTextRevision {
    try await session.flush(through: session.generation)
  }

  func snapshot() async throws -> PagedWorkspaceSnapshot {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public read-output custody exceeds its fixed bound.") }
    let result = try await setup.engine.loadWorkspaceRetaining(setup.publisher)
    readOutputs.append(result.lease)
    return result.value
  }

  func record() async throws -> PagedDocumentRootRecord {
    let loaded = try await snapshot()
    guard loaded.documents.count == 1 else { throw BoomError.invalid("Public fixture acquired another document.") }
    return loaded.documents[0]
  }

  func source(_ record: PagedDocumentRootRecord) async throws -> PagedTextWindow {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public read-output custody exceeds its fixed bound.") }
    let result = try await setup.engine.windowRetaining(record.document.revision,
      byteStart: 0, maximumBytes: PagedWorkingWindow.targetBytes)
    readOutputs.append(result.lease)
    return result.value
  }

  /// Actual same-executor retained authentication; no file reader or second key.
  func history(_ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    guard readOutputs.count < 32 else { throw BoomError.budget("Public SQL history custody exceeds its fixed read bound.") }
    let result = try await setup.engine._publicSQLControlHistoryRetaining(identity: sqlIdentity, record: record)
    readOutputs.append(result.lease)
    return result.value
  }

  /// The loop explicitly ends only its already-consumed scalar/read witnesses.
  /// Earlier receiving owners remain retained; no source writer is abandoned.
  func consumedReadCheckpoint() -> Int { readOutputs.count }
  func finishConsumedReadScope(after checkpoint: Int) async throws {
    guard checkpoint >= 0, checkpoint <= readOutputs.count else { throw BoomError.invalid("Public read scope has another retained prefix.") }
    for output in readOutputs[checkpoint...] { try await setup.engine.abandonJoinedRootOutput(output) }
    readOutputs.removeLast(readOutputs.count - checkpoint)
  }

  /// A new command/input owner begins only after the old owner's physical and
  /// exact controller custody joins. Restart timeline hydration remains open;
  /// this control makes no claim that the new Foundation manager has old entries.
  func replaceJoinedOwner() async throws {
    guard retiredRoutes == 0 else { throw BoomError.budget("Public replacement owner control allows one replacement.") }
    try commands.requireJoinedClose()
    let current = try await record()
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: session.generation, record: current)
    await route.closeAndJoin()
    let old = await route.snapshot
    guard old.activeCalls == 0, old.startedCalls == old.finishedCalls else {
      throw BoomError.invalid("The actual retired public route still owns a worker.")
    }
    retiredRoutes += 1
    let replacement = try await setup.engine.makeNativeStorage(setup.publisher, expected: current)
    let island = try await replacement.window(expected: current.document.revision,
      utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
    let nextRoute = PagedStagedControlledStorage(replacement)
    let nextSession = try PagedNativeSession(window: island, rootRecord: current, storage: nextRoute)
    let nextInput = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: nextSession)
    let nextCommands = try PagedNativeUndoOwner(input: nextInput)
    backend = replacement; route = nextRoute; session = nextSession; input = nextInput; commands = nextCommands
    wireMount()
    scroll.documentView = view
    guard window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.unavailable("The new public owner did not acquire the actual text responder.")
    }
    guard mountedIdentities.count < 16 else { throw BoomError.budget("Public mount identity evidence exceeds its bound.") }
    mountedIdentities.append(try XCTUnwrap(input.activeIdentity))
  }

  func joinAndClose() async throws {
    removeObservers()
    try await joinCommands()
    _ = try await sealCurrent()
    let current = try await record()
    try commands.closeInput()
    try commands.requireJoinedClose()
    XCTAssertEqual(input.retainedClientCount, 0)
    XCTAssertNil(input.commandOwner)
    _ = window.makeFirstResponder(nil)
    scroll.documentView = nil
    await route.closeAndJoin()
    let joined = await route.snapshot
    guard joined.activeCalls == 0, joined.startedCalls == joined.finishedCalls,
      session.persistenceFailure == nil, session.historyFailure == nil,
      session.pendingCommitInstallation == nil, !session.hasPendingHistoryCommand else {
      throw BoomError.stale("The public fixture still owns unresolved input/source publication.")
    }
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: session.generation, record: current)
    // All read consumers above are finished; only now release their real output
    // leases. Detach authenticated the actual complete final head first.
    for output in readOutputs { try await setup.engine.abandonJoinedRootOutput(output) }
    readOutputs.removeAll()
    try await maintenance.drainAfterJoinedNativeCalls()
    try await setup.engine.close()
    window.close()
  }

  /// Failure path joins calls/timers that exist, retains the source/command
  /// owners and evidence, and does not pretend a refused close was successful.
  func joinFailedCalls() async {
    removeObservers()
    await route.closeAndJoin()
    do { try await commands.joinPendingCommand() }
    catch { if failedCommandJoin == nil { failedCommandJoin = error } }
    let joined = await route.snapshot
    XCTAssertEqual(joined.activeCalls, 0)
    XCTAssertEqual(joined.startedCalls, joined.finishedCalls)
  }
}

@MainActor final class PagedNativeManagedRetirementTests: XCTestCase {
  private static var terminalFixture: PagedManagedFixture?
  private static var retainedSetup: PagedManagedOpen?
  private static var retainedSetupRoot: URL?
  private static let refusedCase = "testActualRefusedPrimitiveRetainsAcceptedSourceAndRefusesPhysicalClose"

  private func makeFixture() async throws -> PagedManagedFixture {
    guard Self.terminalFixture == nil, Self.retainedSetup == nil, Self.retainedSetupRoot == nil else {
      throw BoomError.denied("A prior retained public owner still owns this disposable process.")
    }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-managed-retirement-" + UUID().uuidString)
    Self.retainedSetupRoot = root
    print("Public managed SQL fixture: \(root.path)")
    let opened = try await Task.detached {
      let ownerID = UUID(), storeID = UUID()
      let vault = try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x73, count: 32)))
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: ownerID, sqliteOpening: .fresh(storeID: storeID))
      return PagedManagedOpen(root: root, ownerID: ownerID, storeID: storeID, vault: vault, engine: engine)
    }.value
    Self.retainedSetup = opened
    do {
      let identity = try await opened.engine._publicSQLControlIdentity(expectedVault: opened.vault, expectedStoreID: opened.storeID)
      let setup = try await Task.detached {
        let source = root.appendingPathComponent("public-input.utf8")
        try Data("a public🙂\n".utf8).write(to: source, options: .withoutOverwriting)
        let file = try FileHandle(forReadingFrom: source)
        let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
        do { imported = try await opened.engine.importUTF8Retaining(documentID: UUID(), from: file) }
        catch {
          let original = error
          do { try file.close() } catch { XCTFail("Public input close also failed: \(error)") }
          throw original
        }
        do { try file.close() } catch { throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
        let document = PagedDocumentDescriptor(id: imported.value.revision.documentID,
          title: "Public café", revision: imported.value.revision)
        let initial = try await opened.engine.initialNativeRecordRetaining(document)
        let publisher = try await opened.engine.makeWorkspacePublisher()
        var state = WorkspaceState()
        state.documents = [DocumentIndex(id: document.id, title: document.title)]
        state.selectedDocument = document.id
        let workspace = try await opened.engine.initializeWorkspaceRetaining(publisher,
          state: state, documents: [initial.value])
        try await opened.engine.finishWorkspacePublication(workspace, publisher: publisher)
        try await opened.engine.transferJoinedRootToHead(imported.lease,
          publisher: publisher, expected: initial.value)
        try await opened.engine.transferJoinedRootToHead(initial.lease,
          publisher: publisher, expected: initial.value)
        try await opened.engine.abandonJoinedRootOutput(workspace.lease)
        let backend = try await opened.engine.makeNativeStorage(publisher, expected: initial.value)
        let island = try await backend.window(expected: document.revision,
          utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
        return PagedStagedSetup(root: root, ownerID: opened.ownerID, vault: opened.vault,
          engine: opened.engine, publisher: publisher, record: initial.value, window: island, backend: backend)
      }.value
      let fixture = try PagedManagedFixture(setup, sqlIdentity: identity)
      Self.retainedSetup = nil; Self.retainedSetupRoot = nil
      return fixture
    } catch {
      // A failed setup keeps the actual opening, key, files and output claims.
      // Do not attempt close/maintenance to erase the original refused admission.
      XCTFail("Public managed SQL setup failed and remains owned at \(root.path): \(error)")
      throw error
    }
  }

  private func withFixture(_ body: @MainActor (PagedManagedFixture) async throws -> Void) async throws {
    let failures = testRun?.failureCount ?? 0
    let fixture = try await makeFixture()
    do {
      try await body(fixture)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("The public managed control recorded a failed assertion.")
      }
      try await fixture.joinAndClose()
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("The public managed shutdown recorded a failed assertion.")
      }
    } catch {
      Self.terminalFixture = fixture
      await fixture.joinFailedCalls()
      XCTFail("Public managed control failed; input/source owners and diagnostics retained at \(fixture.setup.root.path): \(error)")
      throw error
    }
    // Destructive scratch cleanup follows the actual task/controller/engine
    // joins; failed fixtures and failed evidence are retained instead.
    let root = fixture.setup.root
    try await Task.detached { try FileManager.default.removeItem(at: root) }.value
  }

  private func requireRefusal(_ body: () throws -> Void,
    file: StaticString = #filePath, line: UInt = #line) {
    do { try body(); XCTFail("Expected the actual joined-owner preflight to refuse.", file: file, line: line) }
    catch {
      guard case BoomError.stale = error else {
        XCTFail("Expected exact stale preflight refusal: \(error)", file: file, line: line); return
      }
    }
  }

  private func assertSource(_ fixture: PagedManagedFixture, _ expected: String,
    revision: PagedTextRevision? = nil) async throws -> PagedDocumentRootRecord {
    let record = try await fixture.record()
    if let revision { XCTAssertEqual(record.document.revision, revision) }
    let source = try await fixture.source(record)
    XCTAssertEqual(Data(source.text.utf8), Data(expected.utf8))
    XCTAssertEqual(fixture.view.string, expected)
    let history = try await fixture.history(record)
    XCTAssertEqual(history.current, record.document.revision)
    XCTAssertEqual(history.generation, record.historyGeneration)
    return record
  }

  func testRealFoundationInverseIsVisibleAtDidNotificationsAndPreservesEncryptedRoots() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst("b")
      _ = try await fixture.sealCurrent()
      let edited = try await self.assertSource(fixture, "b public🙂\n")
      let firstHistory = try await fixture.history(edited)
      let group = try XCTUnwrap(firstHistory.undo.last?.groupID)
      let state = PagedManagedNotificationState()
      try fixture.observe(.NSUndoManagerDidUndoChange) {
        state.didUndo += 1
        XCTAssertTrue(fixture.commands.manager.canRedo)
        XCTAssertEqual(fixture.session.generation, 2)
        XCTAssertEqual(fixture.view.string, "a public🙂\n")
        self.requireRefusal { try fixture.commands.closeInput() }
      }
      try fixture.observe(.NSUndoManagerDidRedoChange) {
        state.didRedo += 1
        XCTAssertTrue(fixture.commands.manager.canUndo)
        XCTAssertEqual(fixture.session.generation, 3)
        XCTAssertEqual(fixture.view.string, "b public🙂\n")
        self.requireRefusal { try fixture.commands.closeInput() }
      }
      XCTAssertTrue(fixture.commands.manager.canUndo)
      fixture.commands.manager.undo()
      XCTAssertNotNil(fixture.commands.retainedPrefix)
      try await fixture.joinCommands()
      let undone = try await self.assertSource(fixture, "a public🙂\n", revision: fixture.setup.record.document.revision)
      let undoHistory = try await fixture.history(undone)
      XCTAssertEqual(undoHistory.redo.map(\.groupID), [group])
      XCTAssertEqual(undone.historyGeneration, edited.historyGeneration + 1)
      fixture.commands.manager.redo()
      try await fixture.joinCommands()
      let redone = try await self.assertSource(fixture, "b public🙂\n", revision: edited.document.revision)
      XCTAssertEqual(redone.historyGeneration, undone.historyGeneration + 1)
      XCTAssertEqual(state.didUndo, 1); XCTAssertEqual(state.didRedo, 1)
      XCTAssertNil(fixture.commands.retainedPrefix)
      XCTAssertNil(fixture.commands.firstFailure)
      let actual = await fixture.route.snapshot
      XCTAssertEqual(actual.historyResults.map(\.sealedRootRecord), [undone, redone])
    }
  }

  func testWillUndoAndWillRedoNestedPublicRequestsQueueTwoRealOrderedCommands() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst("b"); _ = try await fixture.sealCurrent()
      try fixture.replaceFirst("c"); _ = try await fixture.sealCurrent()
      let edited = try await fixture.record()
      let history = try await fixture.history(edited)
      XCTAssertEqual(history.undo.count, 2)
      let state = PagedManagedNotificationState()
      try fixture.observe(.NSUndoManagerWillUndoChange) {
        state.willUndo += 1
        guard !state.injectedUndo else { return }
        state.injectedUndo = true
        let generation = fixture.session.generation
        let arena = fixture.session.arenaID
        fixture.commands.manager.undoNestedGroup()
        // This callback must queue; a direct second Foundation pop would
        // consume the same staged owner and violate these synchronous checks.
        XCTAssertEqual(fixture.session.generation, generation)
        XCTAssertEqual(fixture.session.arenaID, arena)
        XCTAssertEqual(state.didUndo, 0)
        XCTAssertNotNil(fixture.commands.retainedPrefix)
      }
      try fixture.observe(.NSUndoManagerDidUndoChange) { state.didUndo += 1 }
      try fixture.observe(.NSUndoManagerWillRedoChange) {
        state.willRedo += 1
        guard !state.injectedRedo else { return }
        state.injectedRedo = true
        let generation = fixture.session.generation
        fixture.commands.manager.undoNestedGroup()
        XCTAssertEqual(fixture.session.generation, generation)
        XCTAssertEqual(state.didRedo, 0)
      }
      try fixture.observe(.NSUndoManagerDidRedoChange) { state.didRedo += 1 }
      fixture.commands.manager.undo()
      try await fixture.joinCommands(maximumEntered: 2)
      let undone = try await self.assertSource(fixture, "a public🙂\n", revision: fixture.setup.record.document.revision)
      XCTAssertEqual(fixture.session.generation, 4)
      XCTAssertEqual(state.didUndo, 2)
      let undoHistory = try await fixture.history(undone)
      XCTAssertEqual(undoHistory.undo.count, 0); XCTAssertEqual(undoHistory.redo.count, 2)
      fixture.commands.manager.redo()
      try await fixture.joinCommands(maximumEntered: 2)
      let afterRedoUndo = try await self.assertSource(fixture, "a public🙂\n", revision: undone.document.revision)
      XCTAssertEqual(fixture.session.generation, 6)
      XCTAssertEqual(afterRedoUndo.historyGeneration, undone.historyGeneration + 2)
      XCTAssertEqual(state.didRedo, 1); XCTAssertEqual(state.didUndo, 3)
      XCTAssertFalse(fixture.commands.manager.canUndo); XCTAssertTrue(fixture.commands.manager.canRedo)
      let actual = await fixture.route.snapshot
      XCTAssertEqual(actual.historyResults.count, 4)
      XCTAssertEqual(actual.preparations.map { $0.command.handle.direction }, [.undo, .undo, .redo, .undo])
      XCTAssertEqual(actual.preparations.map { $0.command.expectedSequence }, [2, 3, 4, 5])
      XCTAssertEqual(Set(actual.historyResults.map { $0.commandID }).count, 4)
      XCTAssertNil(fixture.commands.firstFailure)
    }
  }

  func testJoinedCloseMakesRetainedManagerAndContextInertBesideANewRealOwner() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst("b"); _ = try await fixture.sealCurrent()
      let original = try await fixture.record()
      let oldInput = fixture.input, oldCommands = fixture.commands, manager = oldCommands.manager
      let retired = try PagedManagedRetiredClient(fixture.view)
      try oldCommands.closeInput(); try oldCommands.requireJoinedClose()
      XCTAssertTrue(retired.client.isRetired)
      XCTAssertEqual(oldInput.retainedClientCount, 0)
      _ = fixture.window.makeFirstResponder(nil); fixture.scroll.documentView = nil
      XCTAssertNil(retired.view); XCTAssertNil(retired.storage)
      manager.undo(); manager.redo(); manager.undoNestedGroup()
      oldCommands.request(.undo); oldCommands.inputCommandDidClose()
      retired.deliverOldCallbacks()
      try await oldCommands.joinPendingCommand()
      XCTAssertFalse(manager.canUndo); XCTAssertFalse(manager.canRedo)
      try await fixture.replaceJoinedOwner()
      XCTAssertFalse(fixture.commands.manager.canUndo) // restart hydration is not implemented
      try fixture.replaceFirst("c"); _ = try await fixture.sealCurrent()
      let live = try await self.assertSource(fixture, "c public🙂\n")
      let generation = fixture.session.generation, arena = fixture.session.arenaID
      manager.undoNestedGroup(); oldCommands.request(.redo); retired.deliverOldCallbacks()
      try await oldCommands.joinPendingCommand()
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertEqual(fixture.session.arenaID, arena)
      let headAfterOldCallbacks = try await fixture.record()
      XCTAssertEqual(headAfterOldCallbacks, live)
      XCTAssertEqual(original.document.revision.ownerID, live.document.revision.ownerID)
      XCTAssertNil(fixture.input.firstRefusal); XCTAssertFalse(fixture.commands.hasPendingCommand)
      XCTAssertEqual(retired.client.selectedRange().location, NSNotFound)
      XCTAssertFalse(retired.client.hasMarkedText())
      try oldCommands.requireJoinedClose()
    }
  }

  func testPendingCommitAndMarkedQueuedUndoRefuseCloseUntilActualTaskJoins() async throws {
    try await withFixture { fixture in
      let hold = try await fixture.route.holdNext(.commitBefore)
      try fixture.replaceFirst("b")
      try await fixture.route.awaitHeld(hold)
      self.requireRefusal { try fixture.commands.closeInput() }
      XCTAssertEqual(fixture.input.retainedClientCount, 1)
      XCTAssertEqual(fixture.session.generation, 1)
      XCTAssertEqual(fixture.view.string, "b public🙂\n")
      XCTAssertNotNil(fixture.view.inputContext)
      try await fixture.route.release(hold)
      _ = try await fixture.sealCurrent()
      let beforeMark = try await fixture.record()
      fixture.view.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 1))
      XCTAssertTrue(fixture.view.hasMarkedText()); XCTAssertTrue(fixture.session.isPinned)
      XCTAssertEqual(fixture.session.generation, 2)
      self.requireRefusal { try fixture.commands.closeInput() }
      fixture.commands.manager.undo()
      do { try await fixture.commands.joinPendingCommand(); XCTFail("Queued Undo cannot join before its actual IME unmark.") }
      catch { guard case BoomError.stale = error else { throw error } }
      XCTAssertTrue(fixture.commands.hasPendingCommand)
      XCTAssertNil(fixture.commands.retainedPrefix)
      XCTAssertNil(fixture.commands.firstFailure)
      self.requireRefusal { try fixture.commands.closeInput() }
      fixture.view.unmarkText()
      XCTAssertFalse(fixture.session.isPinned)
      try await fixture.joinCommands()
      let after = try await self.assertSource(fixture, "b public🙂\n", revision: beforeMark.document.revision)
      XCTAssertEqual(fixture.session.generation, 3)
      let retained = try await fixture.history(after)
      XCTAssertEqual(retained.redo.count, 1)
      let actual = await fixture.route.snapshot
      XCTAssertEqual(actual.historyResults.count, 1)
      XCTAssertEqual(actual.preparations.first?.command.expectedSequence, 2)
      XCTAssertNil(fixture.commands.firstFailure); XCTAssertNil(fixture.input.firstRefusal)
    }
  }

  func testTwelveRealManagedInstallationsReleaseOldViewsButRetainOnlyInertClients() async throws {
    try await withFixture { fixture in
      try fixture.replaceFirst("b"); _ = try await fixture.sealCurrent()
      let edited = try await fixture.record()
      var retained: [PagedManagedRetiredClient] = []
      retained.reserveCapacity(12)
      for index in 0..<12 {
        let readPrefix = fixture.consumedReadCheckpoint()
        retained.append(try PagedManagedRetiredClient(fixture.view))
        let previous = try XCTUnwrap(fixture.input.activeIdentity)
        if index.isMultiple(of: 2) { fixture.commands.manager.undo() }
        else { fixture.commands.manager.redo() }
        try await fixture.joinCommands()
        let current = try XCTUnwrap(fixture.input.activeIdentity)
        XCTAssertNotEqual(previous.clientID, current.clientID)
        XCTAssertNotEqual(previous.arenaID, current.arenaID)
        XCTAssertEqual(fixture.input.retainedClientCount, 1)
        XCTAssertFalse(fixture.input.hasStagedClient)
        XCTAssertEqual(fixture.session.generation, UInt64(index + 2))
        let expected = index.isMultiple(of: 2) ? "a public🙂\n" : "b public🙂\n"
        let revision = index.isMultiple(of: 2) ? fixture.setup.record.document.revision : edited.document.revision
        let live = try await self.assertSource(fixture, expected, revision: revision)
        for old in retained {
          XCTAssertTrue(old.client.isRetired)
          // The public owner has no retired-pair array. These actual weak
          // witnesses must disappear after the actual command task joins.
          XCTAssertNil(old.view); XCTAssertNil(old.storage)
          let generation = fixture.session.generation
          old.deliverOldCallbacks()
          XCTAssertEqual(fixture.session.generation, generation)
          XCTAssertEqual(fixture.view.string, expected)
          XCTAssertNil(fixture.input.firstRefusal)
        }
        XCTAssertEqual(live.historyGeneration, UInt64(index + 2))
        try await fixture.finishConsumedReadScope(after: readPrefix)
      }
      XCTAssertEqual(retained.count, 12)
      XCTAssertEqual(fixture.mountedIdentities.count, 13)
      XCTAssertEqual(Set(fixture.mountedIdentities.map(\.clientID)).count, 13)
      let actual = await fixture.route.snapshot
      XCTAssertEqual(actual.historyResults.count, 12)
      XCTAssertEqual(Set(actual.historyResults.map(\.commandID)).count, 12)
      XCTAssertFalse(fixture.commands.hasPendingCommand)
    }
  }

  /// Known terminal product gap: the active binding retains the refusal/Error,
  /// but does NOT own the rejected payload or a receiving disposition. Preserve
  /// the accepted source, actual controller and public files in one disposable
  /// process; do not invent a fake lossless payload holder or successful close.
  func testActualRefusedPrimitiveRetainsAcceptedSourceAndRefusesPhysicalClose() async throws {
    guard ProcessInfo.processInfo.environment["BLOOM_PAGED_MANAGED_ISOLATED_CASE"] == Self.refusedCase else {
      throw BoomError.denied("Active refused-input custody requires its exact separately owned disposable test process; no fixture entered.")
    }
    let failures = testRun?.failureCount ?? 0
    let fixture = try await makeFixture()
    Self.terminalFixture = fixture
    do {
      try fixture.replaceFirst("b"); _ = try await fixture.sealCurrent()
      let before = try await fixture.record()
      let controllerBefore = try XCTUnwrap(fixture.setup.engine.custodySnapshot.items.first {
        if case .controller = $0.purpose { return true }; return false
      })
      // Emoji occupies UTF16 units 8 and 9: an insertion between its surrogate
      // halves must be refused before either source or Cocoa character mutation.
      fixture.view.insertText("x", replacementRange: NSRange(location: 9, length: 0))
      XCTAssertNotNil(fixture.input.firstRefusal)
      XCTAssertNotNil(fixture.view.inputBinding?.firstRefusal)
      XCTAssertEqual(fixture.input.refusedClientIDs, [try XCTUnwrap(fixture.input.activeIdentity?.clientID)])
      XCTAssertEqual(fixture.session.generation, 1)
      XCTAssertEqual(fixture.view.string, "b public🙂\n")
      requireRefusal { try fixture.commands.closeInput() }
      requireRefusal { _ = try fixture.input.prepareInputRetirement(commandOwner: fixture.commands) }
      fixture.commands.manager.undo()
      do { try await fixture.commands.joinPendingCommand(); XCTFail("Refused active input cannot consume queued Undo.") }
      catch { guard case BoomError.stale = error else { throw error } }
      XCTAssertTrue(fixture.commands.hasPendingCommand)
      XCTAssertNil(fixture.commands.retainedPreparation)
      let headAfterRefusal = try await fixture.record()
      XCTAssertEqual(headAfterRefusal, before)
      let controllerAfter = try XCTUnwrap(fixture.setup.engine.custodySnapshot.items.first {
        if case .controller = $0.purpose { return true }; return false
      })
      XCTAssertEqual(controllerAfter.id, controllerBefore.id)
      XCTAssertEqual(controllerAfter.claims, [.record(before)])
      await fixture.joinFailedCalls()
      XCTAssertEqual(fixture.input.retainedClientCount, 1)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("The isolated active-refusal control recorded a failed assertion.")
      }
      let status = await fixture.route.snapshot
      let receipt: [String: String] = ["schema": "1", "case": Self.refusedCase,
        "status": "actual-workers-joined-accepted-root-and-active-refusal-retained",
        "started-component-calls": String(status.startedCalls),
        "finished-component-calls": String(status.finishedCalls),
        "active-component-calls": String(status.activeCalls),
        "receiving-payload-custody": "ABSENT-unresolved-product-gap",
        "engine": "retained-no-controller-detach-no-close-no-delete"]
      let root = fixture.setup.root
      try await Task.detached {
        let encoded = try JSONEncoder().encode(receipt)
        guard encoded.count <= 16_384 else { throw BoomError.budget("Public managed receipt exceeds its fixed evidence bound.") }
        try encoded.write(to: root.appendingPathComponent("retained-input-boundary.json"), options: .withoutOverwriting)
      }.value
      print("Public active-input refusal evidence: \(root.path)")
    } catch {
      await fixture.joinFailedCalls()
      XCTFail("Active input/source custody and failed evidence retained at \(fixture.setup.root.path): \(error)")
      throw error
    }
  }
}

#endif
