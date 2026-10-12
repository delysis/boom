import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

// SOURCE ONLY: these controls require exactly one nominated public case per
// process. Every successful root/window/ACK is from the actual current encrypted
// backend; the shared route changes scheduling only and joins its real calls.
@MainActor private final class ManagedNavigationFixture {
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
    if let route {
      let joined = await route.snapshot
      XCTAssertEqual(joined.activeCalls, 0); XCTAssertEqual(joined.startedCalls, joined.finishedCalls)
    }
  }
}

@MainActor final class PagedNativeManagedNavigationTests: XCTestCase {
  private static var retained: ManagedNavigationFixture?
  private static let entryKey = UndoManager.UserInfoKey(rawValue: "bloom.paged.native-entry.v1")
  private func fixture(_ name: String,
    text: String = String(repeating: "a", count: 72_196) + "🙂e\u{301}\n",
    retainedTerminal: Bool = false,
    _ body: (ManagedNavigationFixture) async throws -> Void) async throws {
    guard text.utf8.count <= 72_204 else { throw BoomError.budget("Public navigation source exceeds its unchanged small fixture bound.") }
    guard ProcessInfo.processInfo.environment["BLOOM_PAGED_NATIVE_NAVIGATION_CASE"] == name else {
      throw BoomError.denied("Nominate this exact public native navigation case; no skip or implicit multi-case run.")
    }
    guard Self.retained == nil else { throw BoomError.stale("An earlier failed public owner still owns this process.") }
    let failures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-native-navigation-" + UUID().uuidString)
    let held = ManagedNavigationFixture(root: root, text: text); Self.retained = held
    print("Actual public managed navigation: \(root.path)")
    do {
      try await held.open(); try await body(held)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual native assertion failed; owner/evidence retained.") }
      if retainedTerminal {
        let joined = await held.route!.snapshot
        guard name == "testActualManagedMountRefusalRetainsMovedSourceAndInertOldClientWithoutReplayOrJoinedClose()",
          held.input?.firstRefusal != nil, held.commands?.firstFailure != nil,
          held.commands?.queuedRawKeyCount == 0, held.commands?.unretainedRawKeyCount == 0,
          held.input?.lastReplayTransition == nil, joined.activeCalls == 0,
          joined.startedCalls == joined.finishedCalls,
          held.session?.activeNavigationOperationCount == 0, !held.closed else {
          throw BoomError.stale("Actual isolated mount refusal lost its original input or producer join.")
        }
        print("RETAINED_TERMINAL actual moved native arena/mount refusal/no replay transition; no false joined input/Engine close.")
        return
      }
      try await held.close()
      guard held.closed, held.sourceFile == nil else { throw BoomError.unavailable("Actual public Engine/file close did not join.") }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      Self.retained = nil
    } catch {
      held.preserve(error); await held.joinEnteredOnFailure()
      XCTFail("Original native navigation failure retained at \(root.path): \(error)")
      throw error
    }
  }
  func testManagedRecenterRetainsCanonicalOwnerAndAllowsTypingUndoRedoWithInertOldClients() async throws {
    try await fixture(#function) { f in
      try f.replaceFirst("A"); try await f.seal()
      let input = f.input!, commands = f.commands!, source = f.session!, manager = commands.manager
      let old = f.view, context = try XCTUnwrap(old.inputContext)
      let oldClient = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let oldIdentity = try XCTUnwrap(old.inputBinding?.identity), oldArena = source.arenaID
      let top = try XCTUnwrap(manager.undoActionUserInfoValue(forKey: Self.entryKey) as? NSObject)
      let record = source.canonicalHistory?.record, sequence = source.generation
      old.setSelectedRange(NSRange(location: 8_000, length: 0), affinity: .upstream, stillSelecting: false)
      let task = try f.startNavigation(anchor: 6_000, caret: nil); let window = try await task.value
      XCTAssertTrue(f.input === input); XCTAssertTrue(f.commands === commands); XCTAssertTrue(f.session === source)
      XCTAssertTrue(commands.manager === manager); XCTAssertTrue(input.commandOwner === commands)
      XCTAssertFalse(f.view === old); XCTAssertNotEqual(source.arenaID, oldArena)
      XCTAssertEqual(input.activeIdentity?.arenaID, source.arenaID); XCTAssertEqual(source.generation, sequence)
      XCTAssertEqual(source.canonicalHistory?.record, record)
      XCTAssertTrue((manager.undoActionUserInfoValue(forKey: Self.entryKey) as? NSObject) === top)
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: Int(8_000 - window.utf16Start), length: 0))
      XCTAssertEqual(f.view.selectionAffinity, .upstream); XCTAssertEqual(old.inputBinding?.state, .retired)
      XCTAssertEqual(oldClient.identity, oldIdentity); XCTAssertTrue(oldClient.isRetired)
      let currentBytes = Data(f.view.string.utf8), count = manager.undoCount
      oldClient.insertText("OLD", replacementRange: NSRange(location: 0, length: 1))
      oldClient.setMarkedText("旧", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
      oldClient.unmarkText(); oldClient.doCommand(by: NSSelectorFromString("undo:")); oldClient.doCommand(by: NSSelectorFromString("redo:"))
      old.insertText("OLD", replacementRange: NSRange(location: 0, length: 1)); old.keyDown(with: try f.key())
      old.doCommand(by: NSSelectorFromString("undo:")); old.setSelectedRange(NSRange(location: 1, length: 0))
      old.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "OLD")
      XCTAssertEqual(Data(f.view.string.utf8), currentBytes); XCTAssertEqual(source.generation, sequence)
      XCTAssertEqual(manager.undoCount, count); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      f.view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      var after = f.originalText; after.replaceSubrange(after.startIndex..<after.index(after.startIndex, offsetBy: 1), with: "A")
      let position = after.utf16.index(after.utf16.startIndex, offsetBy: 8_000)
      let scalar = try XCTUnwrap(String.Index(position, within: after)); after.insert("X", at: scalar)
      try await f.assertSource(after)
      manager.undo(); try await commands.joinPendingCommand()
      var before = f.originalText; before.replaceSubrange(before.startIndex..<before.index(before.startIndex, offsetBy: 1), with: "A")
      try await f.assertSource(before)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(after)
      XCTAssertTrue(commands.manager === manager); XCTAssertTrue(input.commandOwner === commands)
      XCTAssertEqual(input.retainedClientCount, 1); XCTAssertNil(source.persistenceFailure)
    }
  }
  func testTypingDuringRealWindowLoadPreservesOldViewAndRefusesStaleNavigation() async throws {
    try await fixture(#function) { f in
      let source = f.session!, old = f.view, identity = f.input!.activeIdentity, arena = source.arenaID
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      XCTAssertTrue(f.commands!.isNavigating); XCTAssertEqual(source.activeNavigationOperationCount, 1)
      try f.replaceFirst("B")
      try await f.route!.release(hold); try await f.requireStale(task)
      XCTAssertTrue(f.view === old); XCTAssertEqual(f.input!.activeIdentity, identity); XCTAssertEqual(source.arenaID, arena)
      XCTAssertEqual(f.view.string.first, "B"); XCTAssertFalse(f.commands!.isNavigating)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      var expected = f.originalText; expected.replaceSubrange(expected.startIndex..<expected.index(after: expected.startIndex), with: "B")
      try await f.assertSource(expected)
    }
  }
  func testSelectionABADuringRealLoadInvalidatesTicketWithoutChangingSourceOrView() async throws {
    try await fixture(#function) { f in
      let old = f.view, identity = f.input!.activeIdentity, arena = f.session!.arenaID
      let original = old.selectedRange(), observed = try f.input!.observeSelection()
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      old.setSelectedRange(NSRange(location: 8, length: 0)); old.setSelectedRange(original)
      XCTAssertGreaterThan(try f.input!.observeSelection().selectionEpoch, observed.selectionEpoch)
      try await f.route!.release(hold); try await f.requireStale(task)
      XCTAssertTrue(f.view === old); XCTAssertEqual(f.input!.activeIdentity, identity); XCTAssertEqual(f.session!.arenaID, arena)
      XCTAssertEqual(old.selectedRange(), original); XCTAssertNil(f.input!.firstRefusal); XCTAssertFalse(f.input!.hasStagedClient)
      try await f.assertSource(f.originalText)
    }
  }
  func testMarkedInputDuringRealLoadStaysPinnedOnOldClientUntilActualUnmark() async throws {
    try await fixture(#function) { f in
      let old = f.view, arena = f.session!.arenaID
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      old.setSelectedRange(NSRange(location: 0, length: 1))
      old.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 1))
      XCTAssertTrue(old.hasMarkedText()); XCTAssertTrue(f.session!.isPinned)
      try await f.route!.release(hold); try await f.requireStale(task)
      XCTAssertTrue(f.view === old); XCTAssertEqual(f.session!.arenaID, arena)
      XCTAssertTrue(old.hasMarkedText()); XCTAssertTrue(f.session!.isPinned); XCTAssertNil(f.input!.firstRefusal)
      old.unmarkText(); XCTAssertFalse(old.hasMarkedText()); XCTAssertFalse(f.session!.isPinned)
      var expected = f.originalText; expected.replaceSubrange(expected.startIndex..<expected.index(after: expected.startIndex), with: "かな")
      try await f.assertSource(expected)
    }
  }
  func testFocusABADuringRealLoadDoesNotMountOrRetargetOriginalPhysicalClient() async throws {
    try await fixture(#function) { f in
      let old = f.view, arena = f.session!.arenaID, observed = try f.input!.observeSelection()
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      XCTAssertTrue(f.window!.makeFirstResponder(nil)); XCTAssertTrue(f.window!.makeFirstResponder(old))
      XCTAssertNotEqual(try f.input!.observeSelection().inputLease, observed.inputLease)
      try await f.route!.release(hold); try await f.requireStale(task)
      XCTAssertTrue(f.view === old); XCTAssertEqual(f.session!.arenaID, arena); XCTAssertTrue(f.mounts.isEmpty)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      try await f.assertSource(f.originalText)
    }
  }
  func testQueuedUndoAndOriginalRawKeyInvalidateRecenterAndKeepChronologicalOwner() async throws {
    try await fixture(#function) { f in
      try f.replaceFirst("A"); try await f.seal()
      let commands = f.commands!, manager = commands.manager
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      manager.undo(); f.view.keyDown(with: try f.key())
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      try await f.route!.release(hold); try await f.requireStale(task)
      try await commands.joinPendingCommand(); try await f.assertSource("z" + f.originalText)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(f.input!.firstRefusal); XCTAssertTrue(commands.manager === manager)
      // Only the genuine Undo mount entered. No recenter-to48000 view adopted.
      XCTAssertEqual(f.mounts.count, 1); XCTAssertEqual(f.session!.generation, 3)
    }
  }
  func testDirectPrototypeNavigationRefusesActualInputOwnerWithoutGroupSubscription() async throws {
    try await fixture(#function) { f in
      try f.commands!.closeInput(); try f.commands!.requireJoinedClose()
      let standalone = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: f.session!)
      f.standaloneInput = standalone
      XCTAssertNil(standalone.commandOwner); XCTAssertEqual(standalone.activeView.inputBinding?.state, .active)
      let before = await f.route!.snapshot, arena = f.session!.arenaID
      var denied = false
      do { _ = try await f.session!.navigate(toUTF16: 48_000) }
      catch { f.preserve(error); guard case BoomError.denied = error else { throw error }; denied = true }
      XCTAssertTrue(denied); XCTAssertEqual(f.session!.arenaID, arena)
      let after = await f.route!.snapshot
      XCTAssertEqual(after.startedCalls, before.startedCalls); XCTAssertEqual(after.finishedCalls, before.finishedCalls)
      try standalone.retireInputForClose(); try standalone.requireJoinedClose(); f.standaloneInput = nil
    }
  }
  func testRequestedScalarInteriorCannotAdoptNewViewOrChangeCanonicalSource() async throws {
    try await fixture(#function) { f in
      let old = f.view, arena = f.session!.arenaID, metadata = f.session!.canonicalHistory
      let task = try f.startNavigation(anchor: 72_000, caret: 72_197) // interior of actual🙂 surrogate pair
      var refused = false
      do { _ = try await task.value }
      catch { f.preserve(error); guard case BoomError.invalid = error else { throw error }; refused = true }
      XCTAssertTrue(refused); XCTAssertTrue(f.view === old); XCTAssertEqual(f.session!.arenaID, arena)
      XCTAssertEqual(f.session!.canonicalHistory, metadata); XCTAssertTrue(f.mounts.isEmpty)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      try await f.assertSource(f.originalText)
    }
  }
  func testExactEOFReuseKeepsPhysicalContextRejectsScalarInteriorAndUsesRealUndo() async throws {
    let publicText = String(repeating: "b", count: 4_088) + "🙂e\u{301}\n" // exactly 4,096 UTF-8 bytes
    try await fixture(#function, text: publicText) { f in
      let old = f.view, input = f.input!, commands = f.commands!, source = f.session!
      let context = try XCTUnwrap(old.inputContext), manager = commands.manager
      let client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let observed = try input.observeSelection(), record = source.canonicalHistory?.record
      let joined = try source.windowForNativeInstallation(), before = await f.route!.snapshot
      XCTAssertEqual(joined.byteStart, 0); XCTAssertEqual(joined.utf16Start, 0)
      XCTAssertEqual(joined.text.utf8.count, 4_096); XCTAssertEqual(joined.revision.summary.bytes, 4_096)
      let invalid = try f.startNavigation(anchor: 0, caret: 4_089) // actual emoji surrogate interior
      var refused = false
      do { _ = try await invalid.value }
      catch { f.preserve(error); guard case BoomError.invalid = error else { throw error }; refused = true }
      XCTAssertTrue(refused); XCTAssertTrue(f.view === old); XCTAssertEqual(try input.observeSelection(), observed)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      let reused = try await f.startNavigation(anchor: 0, caret: 1_024).value
      let after = await f.route!.snapshot
      XCTAssertEqual(after.startedCalls, before.startedCalls); XCTAssertEqual(after.finishedCalls, before.finishedCalls)
      XCTAssertTrue(f.view === old); XCTAssertTrue(old.inputContext === context); XCTAssertFalse(client.isRetired)
      XCTAssertEqual(reused.windowID, joined.windowID); XCTAssertEqual(input.activeIdentity, observed.identity)
      XCTAssertEqual(source.arenaID, observed.identity.arenaID); XCTAssertEqual(source.generation, observed.generation)
      XCTAssertEqual(source.canonicalHistory?.record, record); XCTAssertTrue(commands.manager === manager)
      XCTAssertEqual(old.selectedRange(), NSRange(location: 1_024, length: 0)); XCTAssertTrue(f.mounts.isEmpty)
      XCTAssertEqual(try input.observeSelection().selectionEpoch, observed.selectionEpoch + 1)
      old.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      var expected = publicText; expected.insert("X", at: expected.index(expected.startIndex, offsetBy: 1_024))
      try await f.assertSource(expected)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(publicText)
      XCTAssertTrue(commands.manager === manager); XCTAssertTrue(input.commandOwner === commands)
    }
  }
  func testExactFullWindowReuseWithSameSelectionDoesNotReadMountOrAdvanceEpoch() async throws {
    try await fixture(#function) { f in
      let old = f.view, context = try XCTUnwrap(old.inputContext), source = f.session!, input = f.input!
      old.setSelectedRange(NSRange(location: 8_000, length: 0), affinity: .upstream, stillSelecting: false)
      let observed = try input.observeSelection(), joined = try source.windowForNativeInstallation()
      XCTAssertEqual(joined.text.utf8.count, PagedWorkingWindow.targetBytes)
      XCTAssertLessThan(UInt64(joined.text.utf8.count), joined.revision.summary.bytes)
      let record = source.canonicalHistory?.record, before = await f.route!.snapshot
      let reused = try await f.startNavigation(anchor: 0, caret: nil).value
      let after = await f.route!.snapshot
      XCTAssertTrue(f.view === old); XCTAssertTrue(old.inputContext === context)
      XCTAssertEqual(reused.windowID, joined.windowID); XCTAssertEqual(try input.observeSelection(), observed)
      XCTAssertEqual(source.canonicalHistory?.record, record); XCTAssertEqual(input.retainedClientCount, 1)
      XCTAssertEqual(after.startedCalls, before.startedCalls); XCTAssertEqual(after.finishedCalls, before.finishedCalls)
      XCTAssertTrue(f.mounts.isEmpty); XCTAssertEqual(source.activeNavigationOperationCount, 0)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      try await f.assertSource(f.originalText)
    }
  }
  func testShortenedNonterminalIslandRequiresActualRefillAndManagedMount() async throws {
    try await fixture(#function) { f in
      try f.replaceFirst(""); try await f.seal()
      let old = f.view, source = f.session!, input = f.input!, commands = f.commands!, manager = commands.manager
      let joined = try source.windowForNativeInstallation(), before = await f.route!.snapshot
      XCTAssertEqual(joined.utf16Start, 0); XCTAssertEqual(joined.text.utf8.count, PagedWorkingWindow.targetBytes - 1)
      XCTAssertLessThan(joined.byteStart + UInt64(joined.text.utf8.count), joined.revision.summary.bytes)
      let identity = input.activeIdentity, record = source.canonicalHistory?.record, sequence = source.generation
      let refilled = try await f.startNavigation(anchor: 0, caret: 8).value
      let after = await f.route!.snapshot
      XCTAssertEqual(after.startedCalls, before.startedCalls + 1); XCTAssertEqual(after.finishedCalls, before.finishedCalls + 1)
      XCTAssertFalse(f.view === old); XCTAssertNotEqual(input.activeIdentity?.arenaID, identity?.arenaID)
      XCTAssertEqual(input.activeIdentity?.arenaID, source.arenaID); XCTAssertEqual(f.mounts.count, 1)
      XCTAssertNotEqual(refilled.windowID, joined.windowID); XCTAssertEqual(refilled.text.utf8.count, PagedWorkingWindow.targetBytes)
      XCTAssertEqual(source.generation, sequence); XCTAssertEqual(source.canonicalHistory?.record, record)
      XCTAssertTrue(commands.manager === manager); XCTAssertTrue(input.commandOwner === commands)
      var expected = f.originalText; expected.remove(at: expected.startIndex)
      try await f.assertSource(expected); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualManagedMountRefusalRetainsMovedSourceAndInertOldClientWithoutReplayOrJoinedClose() async throws {
    try await fixture(#function, retainedTerminal: true) { f in
      try f.replaceFirst("B"); try await f.seal()
      let old = f.view, oldIdentity = f.input!.activeIdentity, oldArena = f.session!.arenaID
      let client = try XCTUnwrap(old.inputContext?.client as? PagedNativeTextInputClient)
      let sequence = f.session!.generation, root = f.session!.sealedRevision
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      f.refuseNextActualMount = true
      try await f.route!.release(hold)
      var actualRefusal: Error?
      do { _ = try await task.value }
      catch { actualRefusal = error; f.preserve(error) }
      XCTAssertNotNil(actualRefusal)
      XCTAssertNotNil(f.input!.firstRefusal); XCTAssertNotNil(f.commands!.firstFailure)
      XCTAssertNotEqual(f.session!.arenaID, oldArena); XCTAssertFalse(f.view === old)
      XCTAssertEqual(f.session!.sealedRevision, root); XCTAssertEqual(f.session!.generation, sequence)
      XCTAssertEqual(old.inputBinding?.state, .retired); XCTAssertTrue(client.isRetired)
      XCTAssertEqual(client.identity, oldIdentity)
      XCTAssertEqual(f.commands!.queuedRawKeyCount, 0); XCTAssertEqual(f.commands!.unretainedRawKeyCount, 0)
      XCTAssertNil(f.input!.lastReplayTransition) // the failed physical mount supplies no replay grant
      let bytes = Data(f.view.string.utf8), errors = f.originalErrors.count
      client.insertText("OLD", replacementRange: NSRange(location: 0, length: 1))
      client.doCommand(by: NSSelectorFromString("undo:")); client.unmarkText()
      XCTAssertEqual(Data(f.view.string.utf8), bytes); XCTAssertEqual(f.session!.generation, sequence)
      XCTAssertEqual(f.originalErrors.count, errors)
      XCTAssertThrowsError(try f.commands!.closeInput())
      XCTAssertThrowsError(try f.commands!.requireJoinedClose())
      XCTAssertFalse(f.closed); XCTAssertNil(f.input!.lastReplayTransition)
      let route = await f.route!.snapshot
      XCTAssertEqual(route.activeCalls, 0); XCTAssertEqual(route.startedCalls, route.finishedCalls)
      XCTAssertEqual(f.session!.activeNavigationOperationCount, 0)
    }
  }

}
