import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

// SOURCE ONLY: these controls require exactly one nominated public case per
// process. Every successful root/window/ACK is from the actual current encrypted
// backend; the shared route changes scheduling only and joins its real calls.
@MainActor private final class ManagedViewportFixture {
  let root: URL
  let ownerID = UUID()
  let storeID = UUID()
  let originalText: String
  var vault: Vault?
  var engine: PagedTextEngineAdapter?
  var publisher: PagedWorkspacePublisher?
  var backend: PagedNativeStorageBackend?
  var route: PagedStagedControlledStorage?
  var session: PagedNativeSession?
  var input: PagedNativeInputOwner?
  var commands: PagedNativeUndoOwner?
  var standaloneInput: PagedNativeInputOwner?
  var window: NSWindow?
  var scroll: PagedDocumentViewport?
  var sourceFile: FileHandle?
  private var outputs: [PagedTextRootLease] = []
  private var enteredNavigation: [Task<PagedTextWindow, Error>] = []
  private(set) var originalErrors: [Error] = []
  private(set) var mounts: [PagedNativeInputIdentity] = []
  private(set) var closed = false
  var refuseNextActualMount = false
  var view: PagedNativeTextView { input!.activeView }

  init(root: URL, text: String = String(repeating: "a", count: 72_196) + "🙂e\u{301}\n") {
    self.root = root; originalText = text
  }
  func preserve(_ error: Error) {
    precondition(originalErrors.count < 16, "Public navigation original-error bound exceeded.")
    originalErrors.append(error)
  }
  func receive<T: Sendable>(_ output: PagedTextCustodiedValue<T>) throws -> T {
    guard outputs.count < 32 else { throw PagedTextCustodyFailure(original: BoomError.budget("Public native receiver exceeds 32 actual leases; the original overflow producer remains owned."), lease: output.lease) }
    outputs.append(output.lease); return output.value
  }
  func removeReceived(_ lease: PagedTextRootLease) {
    precondition(outputs.contains(lease)); outputs.removeAll { $0 == lease }
  }
  func open() async throws {
    _ = NSApplication.shared
    let root = root
    let opened = try await Task.detached {
      try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x61, count: 32)))
    }.value
    vault = opened
    let actual = try await PagedTextEngineAdapter.create(vault: opened, ownerID: ownerID, sqliteOpening: .fresh(storeID: storeID))
    engine = actual // strong ownership before any later setup/observation can refuse
    let text = originalText
    let file = try await Task.detached {
      let path = root.appendingPathComponent("public-navigation.utf8")
      try Data(text.utf8).write(to: path, options: .withoutOverwriting)
      return try FileHandle(forReadingFrom: path)
    }.value
    sourceFile = file
    let imported = try await actual.importUTF8Retaining(documentID: UUID(), from: file)
    let revision = try receive(imported).revision
    try await Task.detached { try file.close() }.value; sourceFile = nil
    let descriptor = PagedDocumentDescriptor(id: revision.documentID, title: "Public navigation", revision: revision)
    let initial = try await actual.initialNativeRecordRetaining(descriptor)
    let record = try receive(initial)
    let pub = try await actual.makeWorkspacePublisher(); publisher = pub
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: descriptor.id, title: descriptor.title)]
    state.selectedDocument = descriptor.id
    let saved = try await actual.initializeWorkspaceRetaining(pub, state: state, documents: [record])
    _ = try receive(saved)
    try await actual.finishWorkspacePublication(saved, publisher: pub)
    try await actual.transferJoinedRootToHead(imported.lease, publisher: pub, expected: record); removeReceived(imported.lease)
    try await actual.transferJoinedRootToHead(initial.lease, publisher: pub, expected: record); removeReceived(initial.lease)
    try await actual.abandonJoinedRootOutput(saved.lease); removeReceived(saved.lease)
    let storage = try await actual.makeNativeStorage(pub, expected: record); backend = storage
    let opening = try await storage.opening(sessionID: UUID())
    let forwarding = PagedStagedControlledStorage(storage); route = forwarding
    let source = try PagedNativeSession(opening: opening, storage: forwarding); session = source
    let physical = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: source)
    input = physical
    let history = try PagedNativeUndoOwner(input: physical); commands = history
    let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    nativeWindow.isReleasedWhenClosed = false; window = nativeWindow
    let host = try PagedDocumentViewport(frame: nativeWindow.contentView!.bounds, input: physical); scroll = host
    host.hasVerticalScroller = true; nativeWindow.contentView = host
    history.mountView = { [weak self] old, new in
      guard let self, let host = self.scroll, let window = self.window else {
        throw BoomError.unavailable("Actual public navigation mount lost its physical owner.")
      }
      XCTAssertTrue(host.documentView === old); XCTAssertTrue(self.input?.activeView === new)
      if self.refuseNextActualMount {
        self.refuseNextActualMount = false
        host.documentView = nil // force the actual viewport precondition to refuse after adoption
      }
      do { try host.mountManagedView(from: old, to: new) }
      catch {
        self.preserve(error)
        throw error
      }
      XCTAssertTrue(host.textView === new); XCTAssertTrue(window.firstResponder === new)
      guard self.mounts.count < 16, let identity = new.inputBinding?.identity else {
        throw BoomError.budget("Actual public mount exceeds 16 identities or lost its binding.")
      }
      self.mounts.append(identity)
    }
    try host.enableDocumentNavigation(engine: actual, publisher: pub)
    host.documentView = physical.activeView
    nativeWindow.makeKeyAndOrderFront(nil)
    guard nativeWindow.makeFirstResponder(physical.activeView), nativeWindow.firstResponder === physical.activeView,
      nativeWindow.isKeyWindow else { throw BoomError.unavailable("Public native source did not acquire actual focus.") }
  }
  func startNavigation(anchor: UInt64 = 48_000, caret: UInt64? = 50_000) throws -> Task<PagedTextWindow, Error> {
    guard enteredNavigation.count < 8, let commands else { throw BoomError.budget("Public navigation task/owner bound exceeded.") }
    let selection = caret.map { PagedNativeNavigationSelection(utf16Offset: $0, utf16Length: 0) }
    let task = Task { try await commands.navigate(toUTF16: anchor, selectingUTF16: selection) }
    enteredNavigation.append(task); return task
  }
  func requireStale(_ task: Task<PagedTextWindow, Error>) async throws {
    do { _ = try await task.value }
    catch {
      let original = error; preserve(original)
      guard case BoomError.stale = original else { throw original }
      return
    }
    throw BoomError.invalid("An actual stale navigation unexpectedly adopted another physical view.")
  }
  func replaceFirst(_ text: String) throws {
    let source = session!, before = source.generation
    view.setSelectedRange(NSRange(location: 0, length: 1))
    view.insertText(text, replacementRange: NSRange(location: 0, length: 1))
    guard source.generation == before + 1, input?.firstRefusal == nil,
      view.boundedStorage.mutationFailure == nil else { throw BoomError.stale("Actual public native replacement was refused.") }
  }
  func seal() async throws {
    let source = session!
    _ = try await source.flush(through: source.generation)
    guard source.persistenceFailure == nil, source.historyFailure == nil, source.pendingCommitInstallation == nil,
      commands?.firstFailure == nil else { throw BoomError.unavailable("Actual native source or canonical receiving did not join.") }
  }
  func record() async throws -> PagedDocumentRootRecord {
    guard let engine, let publisher else { throw BoomError.stale("Actual public source owner is missing.") }
    let loaded = try receive(try await engine.loadWorkspaceRetaining(publisher))
    guard loaded.documents.count == 1 else { throw BoomError.invalid("Public source acquired another document.") }
    return loaded.documents[0]
  }
  func assertSource(_ expected: String) async throws {
    try await seal(); let record = try await record()
    let digest = try await engine!.wholeTextSha256(record.document.revision)
    XCTAssertEqual(digest, Digest.sha256(Data(expected.utf8)))
    XCTAssertEqual(session?.canonicalHistory?.record, record)
  }
  func key() throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window!.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
      isARepeat: false, keyCode: 6))
  }
  func close() async throws {
    for task in enteredNavigation { _ = await task.result } // actual entered task joins, including expected refusal
    if let standaloneInput { try standaloneInput.retireInputForClose(); try standaloneInput.requireJoinedClose(); self.standaloneInput = nil }
    try await commands!.joinPendingCommand(); try await seal()
    try await scroll!.closePresentation()
    let current = try await record()
    try commands!.closeInput(); try commands!.requireJoinedClose()
    _ = window?.makeFirstResponder(nil); scroll?.documentView = nil
    await route!.closeAndJoin()
    let joined = await route!.snapshot
    guard joined.activeCalls == 0, joined.startedCalls == joined.finishedCalls,
      session!.activeNavigationOperationCount == 0, !session!.hasPendingHistoryCommand else {
      throw BoomError.unavailable("Actual navigation/source producers remain owned.")
    }
    try await backend!.detachJoinedController(sessionID: session!.sessionID, sequence: session!.generation, record: current)
    for lease in outputs { try await engine!.abandonJoinedRootOutput(lease) }
    outputs.removeAll()
    let wal = try await engine!.joinScheduledWALMaintenance()
    if let failure = wal.failure { throw failure }
    try await engine!.close(); closed = true; window?.close()
  }
  func joinEnteredOnFailure() async {
    // Release/join the actual shared scheduling gates before awaiting a held
    // caller. Preserve original errors, input/source custody and failed files;
    // no publication, physical retirement, Engine close or cleanup retry here.
    if let route { await route.closeAndJoin() }
    for task in enteredNavigation { _ = await task.result }
    if let commands { do { try await commands.joinPendingCommand() } catch { preserve(error) } }
    if let scroll { do { try await scroll.joinPresentation() } catch { preserve(error) } }
    if let route {
      let joined = await route.snapshot
      XCTAssertEqual(joined.activeCalls, 0); XCTAssertEqual(joined.startedCalls, joined.finishedCalls)
    }
  }
}


@MainActor final class PagedNativeGlobalViewportTests: XCTestCase {
  private static var retained: ManagedViewportFixture?
  private func fixture(_ name: String, retainedTerminal: Bool = false,
    _ body: (ManagedViewportFixture) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["BLOOM_PAGED_GLOBAL_VIEWPORT_CASE"] == name else {
      throw BoomError.denied("Nominate this exact public global viewport case; no skip or implicit multi-case run.")
    }
    guard Self.retained == nil else { throw BoomError.stale("An earlier failed actual native owner still owns this process.") }
    let failures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-global-viewport-" + UUID().uuidString)
    let held = ManagedViewportFixture(root: root); Self.retained = held
    print("Actual public managed viewport: \(root.path)")
    do {
      try await held.open(); try await body(held)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual viewport assertion failed; source/input/evidence retained.") }
      if retainedTerminal {
        await held.route!.closeAndJoin()
        let actual = await held.route!.snapshot
        guard name == "testFocusChangeDuringBoundaryReadKeepsOriginalRawKeyAndRefusesFalseClose()",
          held.commands?.firstFailure != nil, held.commands?.queuedRawKeyCount == 1,
          held.commands?.unretainedRawKeyCount == 0, held.session?.activeNavigationOperationCount == 0,
          actual.activeCalls == 0, actual.startedCalls == actual.finishedCalls, !held.closed else {
          throw BoomError.stale("The actual isolated navigation refusal lost original input or its producer join.")
        }
        print("RETAINED_TERMINAL actual original boundary key/source/focus refusal; receiving disposition remains open; no false native or Engine close.")
        return
      }
      try await held.close()
      guard held.closed, held.sourceFile == nil else { throw BoomError.unavailable("Actual viewport Engine/file close did not join.") }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      Self.retained = nil
    } catch {
      held.preserve(error); await held.joinEnteredOnFailure()
      XCTFail("Original actual viewport failure retained at \(root.path): \(error)")
      throw error
    }
  }
  func testScrollTailRetainsOneActualProjectionWithoutMovingCaretOrInventingScalarSelection() async throws {
    try await fixture(#function) { f in
      let old = f.view, source = f.session!, host = f.scroll!, observed = try f.input!.observeSelection()
      let original = source.canonicalHistory!.record, manager = f.commands!.manager
      try host.requestScroll(toUTF16: 48_000); try await host.joinPresentation()
      let middle = try XCTUnwrap(host.visibleScrollWindow)
      XCTAssertEqual(middle.utf16Start, 48_000); XCTAssertLessThanOrEqual(middle.text.utf8.count, 16_384)
      XCTAssertEqual(middle.revision, original.document.revision)
      XCTAssertTrue(f.view === old); XCTAssertEqual(try f.input!.observeSelection(), observed)
      XCTAssertEqual(host.retainedScrollOutputCount, 1); XCTAssertTrue(manager === f.commands!.manager)
      XCTAssertEqual(source.canonicalHistory?.record, original); XCTAssertEqual(source.generation, 0)
      try host.requestScroll(toUTF16: 72_197) // real half-surrogate in the immutable tail
      try await host.joinPresentation()
      let tail = try XCTUnwrap(host.visibleScrollWindow)
      XCTAssertEqual(tail.utf16Start, 72_196); XCTAssertEqual(tail.byteStart, 72_196)
      XCTAssertEqual(tail.text, "🙂e\u{301}\n"); XCTAssertEqual(host.retainedScrollOutputCount, 1)
      var refused = false
      do { try host.selectVisibleUTF16(1) }
      catch { f.preserve(error); guard case BoomError.invalid = error else { throw error }; refused = true }
      XCTAssertTrue(refused); XCTAssertTrue(f.view === old); XCTAssertEqual(try f.input!.observeSelection(), observed)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      XCTAssertEqual(source.canonicalHistory?.record, original); XCTAssertEqual(host.retainedScrollOutputCount, 1)
      try await host.closePresentation(); XCTAssertEqual(host.retainedScrollOutputCount, 0)
      XCTAssertNil(host.visibleScrollWindow)
    }
  }
  func testVisibleAbsoluteSelectionUsesRealMountTypingUndoRedoAndInertEarlierClient() async throws {
    try await fixture(#function) { f in
      let old = f.view, source = f.session!, host = f.scroll!, commands = f.commands!
      let oldClient = try XCTUnwrap(old.inputContext?.client as? PagedNativeTextInputClient)
      let record = source.canonicalHistory!.record
      try host.requestScroll(toUTF16: 48_000); try await host.joinPresentation()
      // Selecting the read surface must acquire its editable physical client
      // even when the document was not the current keyboard responder.
      XCTAssertTrue(f.window!.makeFirstResponder(nil))
      XCTAssertFalse(try f.input!.observeSelection().inputLease.isFirstResponder)
      try host.selectVisibleUTF16(2_000)
      try await commands.joinPendingCommand(); try await host.joinPresentation()
      XCTAssertTrue(f.window!.firstResponder === f.view)
      XCTAssertFalse(f.view === old); XCTAssertEqual(old.inputBinding?.state, .retired); XCTAssertTrue(oldClient.isRetired)
      XCTAssertEqual(try source.navigationSelection(f.view.selectedRange()).utf16Offset, 50_000)
      XCTAssertEqual(source.canonicalHistory?.record, record); XCTAssertEqual(source.generation, 0)
      XCTAssertEqual(host.retainedScrollOutputCount, 0); XCTAssertNil(host.visibleScrollWindow)
      f.view.keyDown(with: try f.key())
      var changed = f.originalText; changed.insert("z", at: changed.index(changed.startIndex, offsetBy: 50_000))
      try await f.assertSource(changed)
      let accepted = source.generation, bytes = Data(f.view.string.utf8)
      oldClient.insertText("OLD", replacementRange: NSRange(location: 0, length: 1)); oldClient.doCommand(by: NSSelectorFromString("undo:"))
      XCTAssertEqual(source.generation, accepted); XCTAssertEqual(Data(f.view.string.utf8), bytes)
      commands.manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertEqual(try source.navigationSelection(f.view.selectedRange()).utf16Offset, 50_000)
      commands.manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(changed)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }
  func testBoundaryKeyIsOwnedBeforeAwaitAndReplayedBeforeLaterUndo() async throws {
    try await fixture(#function) { f in
      try f.replaceFirst("A"); try await f.seal()
      _ = try await f.startNavigation(anchor: 48_000, caret: 48_032).value
      let old = f.view, source = f.session!, commands = f.commands!, generation = source.generation
      let before = Data(old.string.utf8), manager = commands.manager
      let hold = try await f.route!.holdNext(.windowAfter)
      old.keyDown(with: try f.key())
      // Synchronous custody precedes the actual producer's first suspension.
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(Data(old.string.utf8), before)
      try await f.route!.awaitHeld(hold)
      manager.undo() // this direction arrived AFTER the retained original key
      XCTAssertEqual(commands.queuedRawKeyCount, 1)
      try await f.route!.release(hold); try await commands.joinPendingCommand()
      var initialEdit = f.originalText; initialEdit.replaceSubrange(initialEdit.startIndex..<initialEdit.index(after: initialEdit.startIndex), with: "A")
      try await f.assertSource(initialEdit) // the later Undo removed z, not A
      XCTAssertFalse(f.view === old); XCTAssertEqual(old.inputBinding?.state, .retired)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(f.input!.firstRefusal)
      manager.redo(); try await commands.joinPendingCommand()
      var redone = initialEdit; redone.insert("z", at: redone.index(redone.startIndex, offsetBy: 48_032))
      try await f.assertSource(redone); XCTAssertTrue(commands.manager === manager)
    }
  }
  func testActualDocumentMovementUsesGlobalEndThenBeginningAndKeepsRealUndoCaret() async throws {
    try await fixture(#function) { f in
      let source = f.session!, commands = f.commands!, initial = f.view
      let end = UInt64(f.originalText.utf16.count)
      initial.doCommand(by: NSSelectorFromString("moveToEndOfDocument:"))
      try await commands.joinPendingCommand()
      XCTAssertFalse(f.view === initial); XCTAssertEqual(try source.navigationSelection(f.view.selectedRange()).utf16Offset, end)
      XCTAssertEqual(source.generation, 0); XCTAssertEqual(source.sealedRevision.summary.utf16, end)
      f.view.insertText("E", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await f.assertSource(f.originalText + "E")
      commands.manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertEqual(try source.navigationSelection(f.view.selectedRange()).utf16Offset, end)
      // The actual AppKit key dispatch nests doCommand inside inputCommand.
      // Its typed movement must wait until that source/group scope closes.
      let home = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: f.window!.windowNumber, context: nil, characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}",
        isARepeat: false, keyCode: 126))
      f.view.keyDown(with: home); try await commands.joinPendingCommand()
      XCTAssertEqual(try source.navigationSelection(f.view.selectedRange()).utf16Offset, 0)
      XCTAssertTrue(f.view.inputCommandIsClosed); XCTAssertFalse(f.view.hasMarkedText())
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(commands.firstFailure)
      f.view.keyDown(with: try f.key()); try await f.assertSource("z" + f.originalText)
    }
  }
  func testFocusChangeDuringBoundaryReadKeepsOriginalRawKeyAndRefusesFalseClose() async throws {
    try await fixture(#function, retainedTerminal: true) { f in
      _ = try await f.startNavigation(anchor: 48_000, caret: 48_032).value
      let old = f.view, commands = f.commands!, source = f.session!
      let observed = try f.input!.observeSelection(), record = source.canonicalHistory!.record
      let hold = try await f.route!.holdNext(.windowAfter)
      old.keyDown(with: try f.key())
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(source.generation, observed.generation)
      try await f.route!.awaitHeld(hold)
      XCTAssertTrue(f.window!.makeFirstResponder(nil)); XCTAssertTrue(f.window!.makeFirstResponder(old))
      XCTAssertNotEqual(try f.input!.observeSelection().inputLease, observed.inputLease)
      try await f.route!.release(hold)
      var refused = false
      do { try await commands.joinPendingCommand() }
      catch { f.preserve(error); guard case BoomError.stale = error else { throw error }; refused = true }
      XCTAssertTrue(refused); XCTAssertTrue(f.view === old); XCTAssertEqual(old.inputBinding?.state, .active)
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertEqual(source.generation, observed.generation); XCTAssertEqual(source.canonicalHistory?.record, record)
      XCTAssertEqual(source.activeNavigationOperationCount, 0); XCTAssertNil(f.input!.firstRefusal)
      XCTAssertNotNil(commands.firstFailure); XCTAssertThrowsError(try commands.closeInput())
      XCTAssertThrowsError(try commands.requireJoinedClose()); XCTAssertFalse(f.closed)
    }
  }

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  func testReadNavigationRejectsStaleFullRecordAndActualCurrentSourceAuthenticationFailure() async throws {
    try await fixture(#function) { f in
      let engine = f.engine!, publisher = f.publisher!, original = f.session!.canonicalHistory!.record
      try f.replaceFirst("B"); try await f.seal()
      let current = f.session!.canonicalHistory!.record
      XCTAssertNotEqual(current, original)
      var stale = false
      do {
        let unexpected = try await engine.nativeWindowRetaining(publisher: publisher,
          expected: original, utf16Anchor: 0, maximumBytes: 16_384)
        _ = try f.receive(unexpected)
      } catch { f.preserve(error); guard case BoomError.stale = pagedSQLUnderlyingRefusal(error) else { throw error }; stale = true }
      XCTAssertTrue(stale); XCTAssertEqual(f.session!.canonicalHistory?.record, current)
      let identity = try await engine._publicSQLControlIdentity(expectedVault: f.vault!, expectedStoreID: f.storeID)
      let witnessed = try await engine._publicSQLControlCiphertextWitnessRetaining(identity: identity,
        record: current, target: .sourceRoot)
      let witness = try f.receive(witnessed)
      let mutated = try await engine._publicSQLControlCorruptRetaining(identity: identity, witness: witness)
      _ = try f.receive(mutated) // actual known-success public tag mutation + cache invalidation
      var refused = false
      do {
        let unexpected = try await engine.nativeWindowRetaining(publisher: publisher,
          expected: current, utf16Anchor: 0, maximumBytes: 16_384)
        _ = try f.receive(unexpected)
      } catch {
        f.preserve(error)
        guard case CryptoKitError.authenticationFailure = pagedSQLUnderlyingRefusal(error) else { throw error }
        refused = true
      }
      XCTAssertTrue(refused); XCTAssertEqual(f.session!.canonicalHistory?.record, current)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      let restored = try await engine._publicSQLControlRestoreRetaining(identity: identity, witness: witness)
      _ = try f.receive(restored) // original ciphertext and both real mutation producers still held
      let admitted = try await engine.nativeWindowRetaining(publisher: publisher,
        expected: current, utf16Anchor: 0, maximumBytes: 16_384)
      let window = try f.receive(admitted)
      XCTAssertEqual(window.revision, current.document.revision); XCTAssertTrue(window.text.hasPrefix("B"))
      var expected = f.originalText; expected.replaceSubrange(expected.startIndex..<expected.index(after: expected.startIndex), with: "B")
      try await f.assertSource(expected)
    }
  }
#endif

}
