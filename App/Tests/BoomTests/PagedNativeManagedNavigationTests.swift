import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

// SOURCE ONLY: these controls require exactly one nominated public case per
// process. Every successful root/window/ACK is from the actual current file
// backend; the shared route changes scheduling only and joins its real calls.
@MainActor private final class ManagedNavigationFixture {
  let root: URL
  let ownerID = UUID()
  let storeID = UUID()
  let originalText: String
  var store: WorkspaceStore?
  var engine: PagedTextEngineAdapter?
  var publisher: PagedWorkspacePublisher?
  var backend: PagedNativeStorageBackend?
  var route: PagedNativeLogicalControlStorage?
  var session: PagedNativeSession?
  var input: PagedNativeInputOwner?
  var commands: PagedNativeUndoOwner?
  var window: NSWindow?
  var scroll: PagedDocumentViewport?
  var sourceFile: FileHandle?
  private var outputs: [PagedTextRootLease] = []
  private var enteredNavigation: [Task<PagedNativeLogicalWindow, Error>] = []
  private(set) var originalErrors: [Error] = []
  private(set) var mounts: [PagedNativeInputIdentity] = []
  private(set) var closed = false
  var refuseNextActualMount = false
  var view: PagedNativeTextView { input!.activeView! }

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
    try PagedNativeFixtureApplication.bootstrap()
    let root = root
    let opened = try WorkspaceStore(rootOverride: root)
    store = opened
    try await opened.acquireExclusiveWorkspace()
    let actual = try await PagedTextEngineAdapter.create(root: opened.root, ownerID: ownerID, storeID: storeID)
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
    _ = try await actual.publishInitialDocumentRetaining(pub, imported: imported, initialized: initial)
    removeReceived(imported.lease); removeReceived(initial.lease)
    try await opened.saveState(state)
    let storage = try await actual.makeNativeStorage(pub, expected: record); backend = storage
    let opening = try await storage.opening(sessionID: UUID())
    let forwarding = PagedNativeLogicalControlStorage(storage); route = forwarding
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
      let maximumMounts = self.originalText.utf8.count > 72_204 ? 32 : 16
      guard self.mounts.count < maximumMounts, let identity = new.inputBinding?.identity else {
        throw BoomError.budget("Actual public mount exceeds its explicit fixture bound or lost its binding.")
      }
      self.mounts.append(identity)
    }
    host.documentView = physical.activeView
    try await PagedNativeFixtureApplication.focus(physical.activeView!, in: nativeWindow)
  }
  func startNavigation(anchor: UInt64 = 48_000, caret: UInt64? = 50_000) throws -> Task<PagedNativeLogicalWindow, Error> {
    guard enteredNavigation.count < 8, let commands else { throw BoomError.budget("Public navigation task/owner bound exceeded.") }
    let selection = caret.map { PagedNativeNavigationSelection(utf16Offset: $0, utf16Length: 0) }
    let task = Task { try await commands.navigate(toUTF16: anchor, selectingUTF16: selection) }
    enteredNavigation.append(task); return task
  }
  func requireStale(_ task: Task<PagedNativeLogicalWindow, Error>) async throws {
    do { _ = try await task.value }
    catch {
      let original = error; preserve(original)
      if !(original is CancellationError) {
        guard case BoomError.stale = original else { throw original }
      }
      // Actual selection/source cancellation is a nonfatal joined read
      // outcome. Preserve it and consume the corresponding owner diagnostic.
      try await joinRefusedCommand(original: original)
      return
    }
    throw BoomError.invalid("An actual stale navigation unexpectedly adopted another physical view.")
  }
  func joinRefusedCommand(original: Error) async throws {
    do { try await commands!.joinPendingCommand() }
    catch {
      preserve(error)
      let same = String(reflecting: type(of: error)) == String(reflecting: type(of: original))
        && error.localizedDescription == original.localizedDescription
      // The actual ingress records its stale observation before canceling
      // the reader. That separate original diagnostic can outlive the task's
      // CancellationError; no other owner/source failure is accepted here.
      let superseded: Bool
      if case BoomError.stale(let message) = error,
        message == "Selection or focus superseded its original bounded source read." {
        if original is CancellationError { superseded = true }
        else if case BoomError.stale = original { superseded = true }
        else { superseded = false }
      } else { superseded = false }
      guard same || superseded else { throw error }
    }
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
    guard source.persistenceFailure == nil, source.pendingCommitInstallation == nil,
      commands?.firstFailure == nil else { throw BoomError.unavailable("Actual native source or canonical receiving did not join.") }
  }
  func record() async throws -> PagedDocumentRootRecord {
    guard let engine, let publisher else { throw BoomError.stale("Actual public source owner is missing.") }
    return try receive(try await engine.currentDocumentRecordRetaining(publisher,
      documentID: session!.sourceBaseRevision.documentID))
  }
  func assertSource(_ expected: String) async throws {
    try await seal(); let record = try await record()
    let digest = try await engine!.wholeTextSha256(record.document.revision)
    XCTAssertEqual(digest, Digest.sha256(Data(expected.utf8)))
    XCTAssertEqual(session?.sealedRootRecord, record)
  }
  func key() throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window!.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
      isARepeat: false, keyCode: 6))
  }
  func close() async throws {
    for task in enteredNavigation { _ = await task.result } // actual entered task joins, including expected refusal
    try await commands!.joinPendingCommand(); try await seal()
    let current = try await record()
    try await scroll!.closePresentation()
    try commands!.closeInput(); try commands!.requireJoinedClose()
    _ = window?.makeFirstResponder(nil); scroll?.documentView = nil
    await route!.closeAndJoin()
    let joined = await route!.snapshot
    guard joined.activeCalls == 0, joined.startedCalls == joined.finishedCalls,
      session!.activeNavigationOperationCount == 0, !commands!.hasPendingCommand else {
      throw BoomError.unavailable("Actual navigation/source producers remain owned.")
    }
    try await backend!.detachJoinedController(sessionID: session!.sessionID, sequence: session!.sealedGeneration, record: current)
    for lease in outputs { try await engine!.abandonJoinedRootOutput(lease) }
    outputs.removeAll()
    try await engine!.close()
    try await store!.releaseExclusiveWorkspace()
    closed = true; window?.close()
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
    let largeCase = name == "testActualThreeMiBParagraphCommandsDeleteAcrossWindowsAndRestoreCaretWithUndoRedo()"
      || name == "testActualThreeMiBPrefixWaitsForNavigationAndEarlierTypingThenFormatsTheWholeSourceWithUndoRedo()"
    guard text.utf8.count <= (largeCase ? 3_145_856 : 72_204) else {
      throw BoomError.budget("Public navigation source exceeds its explicitly nominated fixture bound.")
    }
    guard ProcessInfo.processInfo.environment["BLOOM_PAGED_NATIVE_NAVIGATION_CASE"] == name else {
      throw BoomError.denied("Nominate this exact public native navigation case; no skip or implicit multi-case run.")
    }
    guard Self.retained == nil else { throw BoomError.stale("An earlier failed public owner still owns this process.") }
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-native-navigation-")
    let held = ManagedNavigationFixture(root: root, text: text); Self.retained = held
    print("Actual public managed navigation: \(root.path)")
    do {
      try await held.open(); try await body(held)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual native assertion failed; owner/evidence retained.") }
      if retainedTerminal {
        await held.route!.closeAndJoin()
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
      let oldBinding = try XCTUnwrap(old.inputBinding), oldStorage = old.boundedStorage
      let oldManager = try XCTUnwrap(old.layoutManager), oldContainer = try XCTUnwrap(old.textContainer)
      let oldIdentity = oldBinding.identity, oldArena = source.arenaID, oldText = oldStorage.string
      let top = try XCTUnwrap(manager.undoActionUserInfoValue(forKey: Self.entryKey) as? NSObject)
      let record = source.sealedRootRecord, sequence = source.generation
      old.setSelectedRange(NSRange(location: 8_000, length: 0), affinity: .upstream, stillSelecting: false)
      let task = try f.startNavigation(anchor: 17_000, caret: nil); let window = try await task.value
      XCTAssertTrue(f.input === input); XCTAssertTrue(f.commands === commands); XCTAssertTrue(f.session === source)
      XCTAssertTrue(commands.manager === manager); XCTAssertTrue(input.commandOwner === commands)
      XCTAssertTrue(f.view === old); XCTAssertNotEqual(source.arenaID, oldArena)
      XCTAssertEqual(input.activeIdentity?.arenaID, source.arenaID); XCTAssertEqual(source.generation, sequence)
      XCTAssertEqual(source.sealedRootRecord, record)
      XCTAssertTrue((manager.undoActionUserInfoValue(forKey: Self.entryKey) as? NSObject) === top)
      XCTAssertEqual(f.view.selectedRange(), NSRange(location: Int(8_000 - window.start.utf16), length: 0))
      XCTAssertEqual(f.view.selectionAffinity, .upstream); XCTAssertEqual(oldBinding.state, .retired)
      XCTAssertTrue(f.view.layoutManager === oldManager); XCTAssertTrue(f.view.textContainer === oldContainer)
      XCTAssertFalse(f.view.boundedStorage === oldStorage); XCTAssertTrue(oldStorage.layoutManagers.isEmpty)
      XCTAssertFalse(f.view.inputContext === context)
      XCTAssertTrue(oldManager.textStorage === f.view.boundedStorage)
      XCTAssertTrue(oldContainer.textView === f.view)
      XCTAssertTrue(oldManager.delegate === f.view.inlineMedia.layout)
      XCTAssertThrowsError(try oldBinding.admitsInput(in: source))
      XCTAssertEqual(try input.inputLease(for: old).identity, input.activeIdentity)
      XCTAssertEqual(oldClient.identity, oldIdentity); XCTAssertTrue(oldClient.isRetired)
      XCTAssertTrue((context.client as? PagedNativeTextInputClient) === oldClient)
      XCTAssertEqual(oldClient.selectedRange(), NSRange(location: NSNotFound, length: 0))
      XCTAssertEqual(oldClient.markedRange(), NSRange(location: NSNotFound, length: 0))
      XCTAssertFalse(oldClient.hasMarkedText())
      var absent = NSRange(location: 0, length: 1)
      XCTAssertNil(oldClient.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &absent))
      XCTAssertEqual(absent, NSRange(location: NSNotFound, length: 0))
      let newClient = try XCTUnwrap(f.view.inputContext?.client as? PagedNativeTextInputClient)
      XCTAssertFalse(newClient === oldClient); XCTAssertEqual(newClient.identity, input.activeIdentity)
      let currentBytes = Data(f.view.string.utf8), count = manager.undoCount
      oldClient.insertText("OLD", replacementRange: NSRange(location: 0, length: 1))
      oldClient.setMarkedText("旧", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
      oldClient.unmarkText(); oldClient.doCommand(by: NSSelectorFromString("undo:")); oldClient.doCommand(by: NSSelectorFromString("redo:"))
      oldStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "OLD")
      oldStorage.setAttributes([.foregroundColor: NSColor.red], range: NSRange(location: 0, length: 1))
      XCTAssertEqual(oldStorage.string, oldText)
      XCTAssertEqual(Data(f.view.string.utf8), currentBytes); XCTAssertEqual(source.generation, sequence)
      XCTAssertEqual(manager.undoCount, count); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      // This retained reference IS the current physical view; ordinary input
      // must still reach its new source, unlike retired proxy/storage handles.
      old.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
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
  func testPreparedContextCancellationKeepsLiveGraphAndRejectsCanceledTicketBeforeUnicodeInput() async throws {
    try await fixture(#function) { f in
      let input = f.input!, source = f.session!, commands = f.commands!
      let view = f.view, storage = view.boundedStorage, binding = try XCTUnwrap(view.inputBinding)
      let context = try XCTUnwrap(view.inputContext), client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
      let observed = try input.observeSelection(), before = try source.captureLogicalState()
      let ticket = try await source.prepareNavigationInstallation(owner: input, toUTF16: 17_000,
        selectingUTF16: PagedNativeNavigationSelection(utf16Offset: 17_000, utf16Length: 0))
      try input.stageNavigation(ticket, observedSelection: observed)
      XCTAssertTrue(input.hasStagedClient); XCTAssertEqual(input.retainedClientCount, 2)
      XCTAssertTrue(view.inputContext === context); XCTAssertTrue(view.boundedStorage === storage)
      XCTAssertTrue(view.layoutManager === manager); XCTAssertTrue(view.textContainer === container)
      XCTAssertEqual(try input.observeSelection(), observed); XCTAssertTrue(source.isCurrent(before))
      XCTAssertFalse(client.isRetired); XCTAssertEqual(binding.state, .active)
      try input.cancelNavigationStage(ticket)
      XCTAssertFalse(input.hasStagedClient); XCTAssertEqual(input.retainedClientCount, 1)
      XCTAssertTrue(view.inputContext === context); XCTAssertTrue(view.boundedStorage === storage)
      XCTAssertFalse(client.isRetired); XCTAssertEqual(binding.state, .active)
      XCTAssertThrowsError(try input.withStagedNavigationInstallation(ticket) { old, new in
        try f.scroll!.mountManagedView(from: old, to: new)
      })
      XCTAssertFalse(ticket.wasConsumed); XCTAssertTrue(source.isCurrent(before))
      view.insertText("🙂", replacementRange: NSRange(location: 0, length: 0))
      try await f.assertSource("🙂" + f.originalText)
      commands.manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertTrue(f.view === view); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
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
  func testQueuedUndoAndOriginalRawKeyFollowRealRecenterAndKeepChronologicalOwner() async throws {
    try await fixture(#function) { f in
      // A real insertion starts at a caret. Undo restores that actual empty
      // selection, so the later original z inserts before the source.
      f.view.setSelectedRange(NSRange(location: 0, length: 0))
      f.view.insertText("A", replacementRange: f.view.selectedRange())
      XCTAssertEqual(f.session!.generation, 1)
      try await f.seal()
      let commands = f.commands!, manager = commands.manager
      let hold = try await f.route!.holdNext(.windowAfter), task = try f.startNavigation()
      try await f.route!.awaitHeld(hold)
      manager.undo(); f.view.keyDown(with: try f.key())
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      try await f.route!.release(hold); _ = try await task.value
      try await commands.joinPendingCommand(); try await f.assertSource("z" + f.originalText)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(f.input!.firstRefusal); XCTAssertTrue(commands.manager === manager)
      // The requested navigation mounts first, then genuine Undo restores its own seed.
      XCTAssertEqual(f.mounts.count, 2); XCTAssertEqual(f.session!.generation, 3)
      // A later genuine read owns the chronological menu command and two
      // physical keys. Select All changes selection without a mount; the first
      // key then replaces the global range through a real resident mount.
      let beforeGlobal = "z" + f.originalText
      let nextHold = try await f.route!.holdNext(.windowAfter)
      let nextNavigation = try f.startNavigation(anchor: 36_000, caret: 40_000)
      try await f.route!.awaitHeld(nextHold)
      let queuedView = f.view, generation = f.session!.generation
      queuedView.selectAll(nil)
      queuedView.keyDown(with: try f.key())
      let q = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: f.window!.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
        isARepeat: false, keyCode: 12))
      queuedView.keyDown(with: q)
      XCTAssertEqual(commands.queuedRawKeyCount, 2)
      XCTAssertEqual(f.session!.generation, generation)
      try await f.route!.release(nextHold); _ = try await nextNavigation.value
      try await commands.joinPendingCommand(); try await f.assertSource("zq")
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(f.input!.firstRefusal)
      XCTAssertTrue(commands.manager === manager)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(beforeGlobal)
      let restored = try f.input!.currentDocumentSelection()
      XCTAssertEqual(restored.utf16Offset, 0); XCTAssertEqual(restored.utf16Length, UInt64(beforeGlobal.utf16.count))
      XCTAssertTrue(restored.focusAtEnd)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource("zq")
    }
  }
  func testRequestedScalarInteriorCannotAdoptNewViewOrChangeCanonicalSource() async throws {
    try await fixture(#function) { f in
      let old = f.view, arena = f.session!.arenaID, metadata = f.session!.sealedRootRecord
      let task = try f.startNavigation(anchor: 72_000, caret: 72_197) // interior of actual🙂 surrogate pair
      var refused = false
      do { _ = try await task.value }
      catch {
        f.preserve(error); guard case BoomError.invalid = error else { throw error }
        try await f.joinRefusedCommand(original: error); refused = true
      }
      XCTAssertTrue(refused); XCTAssertTrue(f.view === old); XCTAssertEqual(f.session!.arenaID, arena)
      XCTAssertEqual(f.session!.sealedRootRecord, metadata); XCTAssertTrue(f.mounts.isEmpty)
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
      let observed = try input.observeSelection(), record = source.sealedRootRecord
      let joined = source.logicalWindow, before = await f.route!.snapshot
      XCTAssertEqual(joined.start.bytes, 0); XCTAssertEqual(joined.start.utf16, 0)
      XCTAssertEqual(joined.text.utf8.count, 4_096); XCTAssertEqual(joined.snapshot.summary.bytes, 4_096)
      let invalid = try f.startNavigation(anchor: 0, caret: 4_089) // actual emoji surrogate interior
      var refused = false
      do { _ = try await invalid.value }
      catch {
        f.preserve(error); guard case BoomError.invalid = error else { throw error }
        try await f.joinRefusedCommand(original: error); refused = true
      }
      XCTAssertTrue(refused); XCTAssertTrue(f.view === old); XCTAssertEqual(try input.observeSelection(), observed)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      let reused = try await f.startNavigation(anchor: 0, caret: 1_024).value
      let after = await f.route!.snapshot
      XCTAssertEqual(after.startedCalls, before.startedCalls); XCTAssertEqual(after.finishedCalls, before.finishedCalls)
      XCTAssertTrue(f.view === old); XCTAssertTrue(old.inputContext === context); XCTAssertFalse(client.isRetired)
      XCTAssertEqual(reused.windowID, joined.windowID); XCTAssertEqual(input.activeIdentity, observed.identity)
      XCTAssertEqual(source.arenaID, observed.identity.arenaID); XCTAssertEqual(source.generation, observed.generation)
      XCTAssertEqual(source.sealedRootRecord, record); XCTAssertTrue(commands.manager === manager)
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
      let observed = try input.observeSelection(), joined = source.logicalWindow
      XCTAssertEqual(joined.text.utf8.count, PagedWorkingWindow.targetBytes)
      XCTAssertLessThan(UInt64(joined.text.utf8.count), joined.snapshot.summary.bytes)
      let record = source.sealedRootRecord, before = await f.route!.snapshot
      let reused = try await f.startNavigation(anchor: 0, caret: nil).value
      let after = await f.route!.snapshot
      XCTAssertTrue(f.view === old); XCTAssertTrue(old.inputContext === context)
      XCTAssertEqual(reused.windowID, joined.windowID); XCTAssertEqual(try input.observeSelection(), observed)
      XCTAssertEqual(source.sealedRootRecord, record); XCTAssertEqual(input.retainedClientCount, 1)
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
      let joined = source.logicalWindow, before = await f.route!.snapshot
      XCTAssertEqual(joined.start.utf16, 0); XCTAssertEqual(joined.text.utf8.count, PagedWorkingWindow.targetBytes - 1)
      XCTAssertLessThan(joined.start.bytes + UInt64(joined.text.utf8.count), joined.snapshot.summary.bytes)
      let identity = input.activeIdentity, record = source.sealedRootRecord, sequence = source.generation
      let refilled = try await f.startNavigation(anchor: UInt64(PagedWorkingWindow.targetBytes), caret: 8).value
      let after = await f.route!.snapshot
      XCTAssertEqual(after.windowCalls, before.windowCalls + 1)
      XCTAssertEqual(after.startedCalls, before.startedCalls + 3); XCTAssertEqual(after.finishedCalls, before.finishedCalls + 3)
      XCTAssertTrue(f.view === old); XCTAssertNotEqual(input.activeIdentity?.arenaID, identity?.arenaID)
      XCTAssertEqual(input.activeIdentity?.arenaID, source.arenaID); XCTAssertEqual(f.mounts.count, 1)
      XCTAssertNotEqual(refilled.windowID, joined.windowID); XCTAssertEqual(refilled.text.utf8.count, PagedWorkingWindow.targetBytes)
      XCTAssertEqual(source.generation, sequence); XCTAssertEqual(source.sealedRootRecord, record)
      XCTAssertTrue(commands.manager === manager); XCTAssertTrue(input.commandOwner === commands)
      var expected = f.originalText; expected.remove(at: expected.startIndex)
      try await f.assertSource(expected); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualManagedMountRefusalRetainsMovedSourceAndInertOldClientWithoutReplayOrJoinedClose() async throws {
    try await fixture(#function, retainedTerminal: true) { f in
      try f.replaceFirst("B"); try await f.seal()
      let old = f.view, oldIdentity = f.input!.activeIdentity, oldArena = f.session!.arenaID
      let oldBinding = try XCTUnwrap(old.inputBinding), oldStorage = old.boundedStorage
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
      XCTAssertNotEqual(f.session!.arenaID, oldArena); XCTAssertTrue(f.view === old)
      XCTAssertEqual(f.session!.sealedRevision, root); XCTAssertEqual(f.session!.generation, sequence)
      XCTAssertEqual(oldBinding.state, .retired); XCTAssertTrue(client.isRetired)
      XCTAssertEqual(client.identity, oldIdentity)
      XCTAssertEqual(f.commands!.queuedRawKeyCount, 0); XCTAssertEqual(f.commands!.unretainedRawKeyCount, 0)
      XCTAssertNil(f.input!.lastReplayTransition) // the failed physical mount supplies no replay grant
      let bytes = Data(f.view.string.utf8), errors = f.originalErrors.count
      client.insertText("OLD", replacementRange: NSRange(location: 0, length: 1))
      client.doCommand(by: NSSelectorFromString("undo:")); client.unmarkText()
      oldStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "OLD")
      XCTAssertTrue(oldStorage.layoutManagers.isEmpty)
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


  func testActualThreeMiBParagraphCommandsDeleteAcrossWindowsAndRestoreCaretWithUndoRedo() async throws {
    let count = 3 * 1024 * 1024, middle = count / 2
    let tail = "\r\nSecond\u{2028}continued\u{85}still\u{2029}Third\rFourth\n"
    let text = String(repeating: "q", count: count) + tail
    try await fixture(#function, text: text) { f in
      let commands = f.commands!, input = f.input!, source = f.session!, manager = commands.manager
      let originalLogical = try source.captureLogicalState().source
      // The short native reference determines AppKit's actual endpoint and
      // selection conventions. Only its known first paragraph is stretched.
      func mapped(_ offset: Int) throws -> UInt64 {
        if offset >= 4 { return UInt64(count + offset - 4) }
        switch offset {
        case 0: return 0
        case 2: return UInt64(middle)
        default: throw BoomError.invalid("The real Cocoa paragraph command returned an unexpected interior target.")
        }
      }
      for selector in ["moveToBeginningOfParagraph:", "moveToEndOfParagraph:",
        "moveToBeginningOfParagraphAndModifySelection:", "moveToEndOfParagraphAndModifySelection:",
        "moveParagraphForwardAndModifySelection:", "moveParagraphBackwardAndModifySelection:"] {
        _ = try await f.startNavigation(anchor: UInt64(middle - 4096), caret: UInt64(middle)).value
        let reference = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        reference.string = "qqqq" + tail
        reference.setSelectedRange(NSRange(location: 2, length: 0))
        reference.doCommand(by: NSSelectorFromString(selector))
        let native = reference.selectedRange()
        f.view.doCommand(by: NSSelectorFromString(selector))
        try await commands.joinPendingCommand()
        let selection = try input.currentDocumentSelection()
        let lower = try mapped(native.location), upper = try mapped(NSMaxRange(native))
        XCTAssertEqual(selection.utf16Offset, lower); XCTAssertEqual(selection.utf16Length, upper - lower)
        XCTAssertTrue(source.logicalWindow.snapshot.isSame(originalLogical))
        XCTAssertEqual(manager.undoCount, 0); XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
        XCTAssertLessThanOrEqual(f.view.boundedStorage.string.utf8.count, PagedWorkingWindow.targetBytes)
      }
      _ = try await f.startNavigation(anchor: UInt64(middle - 4096), caret: UInt64(middle)).value
      let old = f.view, oldClient = try XCTUnwrap(old.inputContext?.client as? PagedNativeTextInputClient)
      let reference = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
      reference.string = "qqqq" + tail; reference.setSelectedRange(NSRange(location: 2, length: 0))
      reference.doCommand(by: NSSelectorFromString("deleteToEndOfParagraph:"))
      let afterEnd = String(repeating: "q", count: middle) + String(reference.string.dropFirst(2))
      f.view.doCommand(by: NSSelectorFromString("deleteToEndOfParagraph:"))
      try await commands.joinPendingCommand(); try await f.assertSource(afterEnd)
      XCTAssertEqual(manager.undoCount, 1); XCTAssertTrue(oldClient.isRetired)
      let changed = try await f.record(), changedLogical = try source.captureLogicalState().source
      oldClient.insertText("OLD", replacementRange: NSRange(location: 0, length: 0))
      oldClient.doCommand(by: NSSelectorFromString("deleteToBeginningOfParagraph:"))
      XCTAssertEqual(source.sealedRevision, changed.document.revision)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(originalLogical))
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, UInt64(middle))
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(afterEnd)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(changedLogical))
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      f.view.doCommand(by: NSSelectorFromString("deleteToBeginningOfParagraph:"))
      try await commands.joinPendingCommand()
      let afterBeginning = String(repeating: "q", count: count - middle) + tail
      try await f.assertSource(afterBeginning)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, UInt64(middle))
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(afterBeginning)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      // LS and NEL remain within the paragraph; PS and bare CR terminate it.
      let second = UInt64(count + 2), secondLength = UInt64(("Second\u{2028}continued\u{85}still" as NSString).length)
      _ = try await f.startNavigation(anchor: second, caret: second + 3).value
      f.view.doCommand(by: NSSelectorFromString("moveToEndOfParagraph:"))
      try await commands.joinPendingCommand()
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, second + secondLength)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(originalLogical))
      XCTAssertLessThanOrEqual(f.view.boundedStorage.string.utf8.count, PagedWorkingWindow.targetBytes)
    }
  }

  func testActualThreeMiBPrefixWaitsForNavigationAndEarlierTypingThenFormatsTheWholeSourceWithUndoRedo() async throws {
    let line = String(repeating: "q", count: 1020)
    let block = line + "\r\n" + line + "\r" + line + "\u{2029}" + line + "\n"
    let base = String(repeating: block, count: 769)
    let text = base + String(repeating: "q", count: 3 * 1024 * 1024 - base.utf8.count)
    XCTAssertEqual(text.utf8.count, 3 * 1024 * 1024)
    try await fixture(#function, text: text) { f in
      let commands = f.commands!, input = f.input!, source = f.session!, manager = commands.manager
      let coordinates = try source.documentCoordinates(), caret: UInt64 = 1_050_000
      let hold = try await f.route!.holdNext(.windowAfter)
      try commands.requestDocumentNavigation(toUTF16: caret - 4096,
        selectingUTF16: PagedNativeNavigationSelection(utf16Offset: caret, utf16Length: 0), expected: coordinates)
      try await f.route!.awaitHeld(hold)
      let old = f.view, oldClient = try XCTUnwrap(old.inputContext?.client as? PagedNativeTextInputClient)
      old.keyDown(with: try f.key()) // z must enter before formatting
      old.prefixLines("> ") // menu command queues while the actual navigation is held
      let y = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: f.window!.windowNumber, context: nil, characters: "y", charactersIgnoringModifiers: "y",
        isARepeat: false, keyCode: 16))
      old.keyDown(with: y)
      XCTAssertEqual(commands.queuedRawKeyCount, 2)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      try await f.route!.release(hold)
      try await commands.joinPendingCommand(); try await f.seal()
      // Foundation's independent logical-line API supplies the small changed
      // range. Fixture Strings are bounded to this explicit 3 MiB control;
      // production never asks Cocoa to hold the whole document.
      let before = text as NSString
      let withZ = before.replacingCharacters(in: NSRange(location: Int(caret), length: 0), with: "z")
      let changedLine = (withZ as NSString).lineRange(for: NSRange(location: Int(caret + 1), length: 0))
      let formattedLine = (withZ as NSString).replacingCharacters(in: NSRange(location: changedLine.location, length: 0), with: "> ")
      let formattedRange = NSRange(location: changedLine.location, length: changedLine.length + 2)
      let afterY = (formattedLine as NSString).replacingCharacters(in: formattedRange, with: "y")
      try await f.assertSource(afterY)
      XCTAssertEqual(manager.undoCount, 3); XCTAssertEqual(commands.queuedRawKeyCount, 0)
      XCTAssertTrue(oldClient.isRetired); XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(formattedLine)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, UInt64(formattedRange.location))
      XCTAssertEqual(try input.currentDocumentSelection().utf16Length, UInt64(formattedRange.length))
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(withZ)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(withZ)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(formattedLine)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(afterY)
      // The same prefix route handles every logical line, not a flat edit
      // array. Preserve CRLF, bare CR, PS and LF, including final source text.
      let sourceText = afterY as NSString
      var formattedAll = "", offset = 0
      while offset < sourceText.length {
        var start = 0, end = 0, contentEnd = 0
        sourceText.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
          for: NSRange(location: offset, length: 0))
        guard start == offset, end > offset else { throw BoomError.invalid("The independent fixture line oracle did not advance.") }
        formattedAll += "> " + sourceText.substring(with: NSRange(location: offset, length: end - offset))
        offset = end
      }
      let beforeAll = try await f.record(), beforeAllLogical = try source.captureLogicalState().source
      f.view.doCommand(by: NSSelectorFromString("selectAll:")); f.view.prefixLines("> ")
      try await commands.joinPendingCommand(); try await f.assertSource(formattedAll)
      let afterAll = try await f.record(), afterAllLogical = try source.captureLogicalState().source
      XCTAssertNotEqual(afterAll.document.revision, beforeAll.document.revision)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, 0)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Length, afterAll.document.revision.summary.utf16)
      XCTAssertLessThanOrEqual(f.view.boundedStorage.string.utf8.count, PagedWorkingWindow.targetBytes)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(afterY)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(beforeAllLogical))
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(formattedAll)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(afterAllLogical))
      f.view.prefixLines("> ") // all lines carry the marker, so the real worker removes it
      try await commands.joinPendingCommand(); try await f.assertSource(afterY)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(formattedAll)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure); XCTAssertNil(source.persistenceFailure)
    }
  }


  func testActualHeldSaveAllowsResidentUndoGlobalTypingAndParagraphDeletionBeforePublication() async throws {
    try await fixture(#function) { f in
      let commands = f.commands!, input = f.input!, source = f.session!, manager = commands.manager
      let original = source.sealedRootRecord, originalLogical = try source.captureLogicalState().source
      let hold = try await f.route!.holdNext(.commitBefore)
      try f.replaceFirst("A")
      try await f.route!.awaitHeld(hold) // actual captured save, before its real backend call
      let savedGeneration = source.sealedGeneration, beforeUndo = source.generation
      manager.undo() // real seed restore and Foundation inverse complete synchronously
      XCTAssertEqual(source.generation, beforeUndo + 1)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(originalLogical))
      XCTAssertEqual(source.sealedGeneration, savedGeneration); XCTAssertEqual(source.sealedRootRecord, original)
      XCTAssertFalse(commands.hasPendingCommand); XCTAssertEqual(commands.queuedRawKeyCount, 0)
      f.view.selectAll(nil) // the actual responder/menu selector owns the FULL source
      let selected = try input.currentDocumentSelection()
      XCTAssertEqual(selected.utf16Offset, 0)
      XCTAssertEqual(selected.utf16Length, UInt64(f.originalText.utf16.count))
      let generation = source.generation
      f.view.keyDown(with: try f.key()) // actual z replaces the full source without a writer join
      XCTAssertEqual(source.generation, generation + 1); XCTAssertEqual(f.view.string, "z")
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      f.view.doCommand(by: NSSelectorFromString("deleteToBeginningOfParagraph:"))
      try await commands.joinPendingCommand()
      XCTAssertEqual(source.logicalWindow.snapshot.summary.bytes, 0); XCTAssertEqual(f.view.string, "")
      XCTAssertEqual(source.sealedRootRecord, original); XCTAssertEqual(source.sealedGeneration, savedGeneration)
      XCTAssertEqual(manager.undoCount, 2); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      // All these source/history actions join while the SAME real save stays
      // held. A distant retained selection may need its independent reader,
      // but neither that read nor resident Undo waits for publication.
      manager.undo(); try await commands.joinPendingCommand(); XCTAssertEqual(f.view.string, "z")
      manager.undo(); try await commands.joinPendingCommand()
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(originalLogical))
      XCTAssertEqual(try input.currentDocumentSelection(), selected)
      manager.redo(); try await commands.joinPendingCommand(); XCTAssertEqual(f.view.string, "z")
      manager.redo(); try await commands.joinPendingCommand(); XCTAssertEqual(f.view.string, "")
      let latest = try source.captureLogicalState(), arena = source.arenaID
      let stillHeld = await f.route!.snapshot
      XCTAssertEqual(stillHeld.publicationCalls, 1); XCTAssertEqual(stillHeld.activeCalls, 1)
      XCTAssertEqual(source.sealedRootRecord, original); XCTAssertEqual(source.sealedGeneration, savedGeneration)
      try await f.route!.release(hold)
      try await f.assertSource("")
      XCTAssertTrue(source.isCurrent(latest)); XCTAssertEqual(source.arenaID, arena)
      XCTAssertEqual(source.sealedGeneration, source.generation); XCTAssertTrue(commands.manager === manager)
      XCTAssertNil(source.persistenceFailure); XCTAssertNil(source.pendingCommitInstallation)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualShortPrefixUsesTheSameSeparatorRouteAndRealNativeUndoRedo() async throws {
    let text = "one\r\ntwo\rthree\u{2029}four\u{2028}five\u{85}six\n"
    let expected = "> one\r\n> two\r> three\u{2029}> four\u{2028}> five\u{85}> six\n"
    try await fixture(#function, text: text) { f in
      let commands = f.commands!, input = f.input!, source = f.session!, manager = commands.manager
      let originalLogical = try source.captureLogicalState().source
      f.view.doCommand(by: NSSelectorFromString("selectAll:")); f.view.prefixLines("> ")
      try await commands.joinPendingCommand(); try await f.assertSource(expected)
      let prefixedLogical = try source.captureLogicalState().source
      XCTAssertEqual(manager.undoCount, 1)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Length, UInt64(expected.utf16.count))
      f.view.prefixLines("> ")
      try await commands.joinPendingCommand(); try await f.assertSource(text)
      XCTAssertEqual(manager.undoCount, 2)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(expected)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(prefixedLogical))
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      XCTAssertTrue(source.logicalWindow.snapshot.isSame(originalLogical))
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(expected)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(text)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }


  func testActualByteBoundedHeldInputPreservesMoreThanSixtyFourKeysAndOrderedPrefix() async throws {
    try await fixture(#function) { f in
      let source = f.session!, commands = f.commands!, input = f.input!
      let caret: UInt64 = 50_000, before = source.generation
      let hold = try await f.route!.holdNext(.windowAfter)
      let task = try f.startNavigation(anchor: caret - 4096, caret: caret)
      try await f.route!.awaitHeld(hold)
      let old = f.view
      let windowNumber = try XCTUnwrap(f.window).windowNumber
      func key(_ letter: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: windowNumber,
          context: nil, characters: letter, charactersIgnoringModifiers: letter,
          isARepeat: false, keyCode: letter == "z" ? 6 : 16))
      }
      let earlier = String(repeating: "zy", count: 48)
      for letter in earlier { old.keyDown(with: try key(String(letter))) }
      old.prefixLines("> ")
      let later = String(repeating: "yz", count: 16)
      for letter in later { old.keyDown(with: try key(String(letter))) }
      XCTAssertEqual(commands.queuedRawKeyCount, 128)
      XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertEqual(source.generation, before); XCTAssertNil(commands.firstFailure)
      XCTAssertNil(input.firstRefusal)
      try await f.route!.release(hold); _ = try await task.value
      try await commands.joinPendingCommand()
      var expected = f.originalText
      let position = expected.index(expected.startIndex, offsetBy: Int(caret))
      expected.insert(contentsOf: earlier + later, at: position)
      expected = "> " + expected
      try await f.assertSource(expected)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset,
        caret + UInt64(earlier.utf16.count + later.utf16.count) + 2)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      // Actual typing groups may split at the editor's real idle boundary.
      // Traverse the actual Foundation stack, retaining all source assertions.
      let undoCount = commands.manager.undoCount
      XCTAssertGreaterThanOrEqual(undoCount, 3); XCTAssertLessThanOrEqual(undoCount, 100)
      for _ in 0..<undoCount { commands.manager.undo(); try await commands.joinPendingCommand() }
      try await f.assertSource(f.originalText)
      for _ in 0..<undoCount { commands.manager.redo(); try await commands.joinPendingCommand() }
      try await f.assertSource(expected)
    }
  }

  func testActualReplayedCapacityBoundaryKeepsOriginalHeadBeforeLaterKeysAndNativeUndo() async throws {
    try await fixture(#function) { f in
      let commands = f.commands!, source = f.session!, input = f.input!
      let caret: UInt64 = 50_000
      let hold = try await f.route!.holdNext(.windowAfter)
      let task = try f.startNavigation(anchor: caret - 4096, caret: caret)
      try await f.route!.awaitHeld(hold)
      let old = f.view, oldClient = try XCTUnwrap(old.inputContext?.client as? PagedNativeTextInputClient)
      var payload = ""
      // Each original SDK event is bounded 128 units. Ninety-six events exceed
      // the old 64-key cutoff and the actual 24KiB source arena after mounting.
      // The key at that real reserve boundary must remain before later keys.
      for index in 0..<96 {
        let text = String(repeating: index.isMultiple(of: 2) ? "z" : "y", count: 128)
        payload += text
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: f.window!.windowNumber,
          context: nil, characters: text, charactersIgnoringModifiers: text,
          isARepeat: false, keyCode: index.isMultiple(of: 2) ? 6 : 16))
        old.keyDown(with: event)
      }
      XCTAssertEqual(commands.queuedRawKeyCount, 96); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertEqual(source.generation, 0); XCTAssertNil(commands.firstFailure)
      try await f.route!.release(hold); _ = try await task.value
      try await commands.joinPendingCommand()
      var expected = f.originalText
      expected.insert(contentsOf: payload, at: expected.index(expected.startIndex, offsetBy: Int(caret)))
      try await f.assertSource(expected)
      XCTAssertEqual(source.generation, 96)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, caret + UInt64(payload.utf16.count))
      XCTAssertGreaterThanOrEqual(f.mounts.count, 2)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      XCTAssertLessThanOrEqual(f.view.boundedStorage.string.utf8.count, PagedWorkingWindow.hardBytes)
      XCTAssertLessThanOrEqual(source.logicalWindow.summary.bytes, UInt64(PagedWorkingWindow.hardBytes))
      XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      let record = source.sealedRevision
      oldClient.insertText("OLD", replacementRange: NSRange(location: 0, length: 0))
      XCTAssertEqual(source.sealedRevision, record); XCTAssertTrue(oldClient.isRetired)
      let undoCount = commands.manager.undoCount
      XCTAssertGreaterThanOrEqual(undoCount, 1); XCTAssertLessThanOrEqual(undoCount, 100)
      for _ in 0..<undoCount { commands.manager.undo(); try await commands.joinPendingCommand() }
      try await f.assertSource(f.originalText)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, caret)
      for _ in 0..<undoCount { commands.manager.redo(); try await commands.joinPendingCommand() }
      try await f.assertSource(expected)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, caret + UInt64(payload.utf16.count))
    }
  }


  func testSameSelectionPreloadDoesNotEscrowContainedKeysPastTargetSizeAndStaleReadKeepsRealUndo() async throws {
    try await fixture(#function) { f in
      let source = f.session!, old = f.view, input = f.input!, commands = f.commands!
      old.setSelectedRange(NSRange(location: 8_000, length: 0))
      let identity = input.activeIdentity, arena = source.arenaID, generation = source.generation
      let context = try XCTUnwrap(old.inputContext), manager = commands.manager
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 17_000, caret: nil) // actual same logical selection
      try await f.route!.awaitHeld(hold) // the genuine backend window call already entered/joined
      XCTAssertFalse(commands.isNavigating); XCTAssertFalse(commands.hasPendingCommand)
      XCTAssertEqual(source.activeNavigationOperationCount, 1)
      let window = try XCTUnwrap(f.window)
      XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(window.firstResponder === old)
      window.sendEvent(try f.key())
      XCTAssertEqual(source.generation, generation + 1)
      XCTAssertFalse(source.needsRecentering, "The actual hardBytes reserve still admits local typing without another arena.")
      XCTAssertGreaterThan(source.logicalWindow.summary.bytes, UInt64(PagedWorkingWindow.targetBytes))
      XCTAssertLessThan(source.logicalWindow.summary.bytes, UInt64(PagedWorkingWindow.hardBytes))
      let next = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
      window.sendEvent(next)
      XCTAssertEqual(source.generation, generation + 2)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.unretainedRawKeyCount, 0)
      XCTAssertTrue(f.view === old); XCTAssertTrue(old.inputContext === context)
      XCTAssertEqual(input.activeIdentity, identity); XCTAssertEqual(source.arenaID, arena)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      try await f.route!.release(hold); try await f.requireStale(loading)
      XCTAssertTrue(f.mounts.isEmpty); XCTAssertFalse(input.hasStagedClient)
      XCTAssertEqual(source.activeNavigationOperationCount, 0)
      var expected = f.originalText
      expected.insert(contentsOf: "zq", at: expected.index(expected.startIndex, offsetBy: 8_000))
      try await f.assertSource(expected)
      XCTAssertTrue(commands.manager === manager); XCTAssertNil(source.persistenceFailure)
      manager.undo(); try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      manager.redo(); try await commands.joinPendingCommand(); try await f.assertSource(expected)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  /// Actual NSWindow dispatch plus NSTextView's native tracking loop. The
  /// posted SDK drag/up events are not a packaged physical-mouse acceptance.
  func testActualScrollMouseDownTracksDragAtNonzeroClipOriginAndKeepsOutsideShiftAnchorWithUndo() async throws {
    let line = "abcdefghijklmné🙂\n"
    try await fixture(#function, text: String(repeating: line, count: 2_000)) { f in
      let input = f.input!, source = f.session!, commands = f.commands!, window = f.window!, viewport = f.scroll!
      try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      let view = f.view, manager = commands.manager, generation = source.generation
      let saved = source.sealedRootRecord

      @MainActor func drag(extending: Bool) async throws -> (UInt64, UInt64) {
        try viewport.requestScroll(toUTF16: 20_000)
        try await viewport.joinPresentation()
        let projection = try XCTUnwrap(viewport.visibleScrollWindow)
        let surface = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
        let display = try XCTUnwrap(surface.documentView as? NSTextView)
        surface.contentView.scroll(to: NSPoint(x: 0, y: 64))
        surface.reflectScrolledClipView(surface.contentView)
        XCTAssertGreaterThan(surface.contentView.bounds.minY, 0)
        let clip = surface.contentView.bounds.origin
        let layout = try XCTUnwrap(display.layoutManager), container = try XCTUnwrap(display.textContainer)
        layout.ensureLayout(for: container)
        let units = (line as NSString).length
        @MainActor func point(_ location: Int) throws -> NSPoint {
          let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
          let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
          let local = NSPoint(x: rect.minX + display.textContainerOrigin.x + 0.1,
            y: rect.midY + display.textContainerOrigin.y)
          XCTAssertEqual(display.characterIndexForInsertion(at: local), location)
          XCTAssertTrue(surface.contentView.bounds.contains(local), "The SDK pointer must start inside the actual displayed clip.")
          return display.convert(local, to: nil)
        }
        let firstBreak = (projection.text as NSString).range(of: "\n", options: .literal).location
        guard firstBreak != NSNotFound else { throw BoomError.invalid("The public drag projection has no complete line.") }
        let downLocal = firstBreak + 1 + units * 5 + 2, endLocal = firstBreak + 1 + units * 8 + 8
        let downPoint = try point(downLocal), endPoint = try point(endLocal)
        let start = try projection.position(localUTF16: downLocal).utf16
        let end = try projection.position(localUTF16: endLocal).utf16
        let flags: NSEvent.ModifierFlags = extending ? [.shift] : []
        @MainActor func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) throws -> NSEvent {
          try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, downPoint, 1)
        let dragged = try event(.leftMouseDragged, endPoint, 2)
        let up = try event(.leftMouseUp, endPoint, 3)
        // Native mouseDown owns and consumes these actual SDK events. There
        // is no direct global-selection substitution for the drag itself.
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.postEvent(dragged, atStart: true)
        window.sendEvent(down)
        XCTAssertNil(viewport.presentationFailure)
        XCTAssertTrue(viewport.textView === view); XCTAssertTrue(input.activeView === view)
        XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(viewport.contentView.bounds.origin, clip)
        XCTAssertEqual(source.logicalWindow.start, projection.start)
        XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.sealedRootRecord, saved)
        XCTAssertEqual(source.activeNavigationOperationCount, 0); XCTAssertFalse(commands.hasPendingCommand)
        XCTAssertTrue(commands.manager === manager)
        return (start, end)
      }

      let (start, end) = try await drag(extending: false)
      let first = try input.currentDocumentSelection()
      XCTAssertEqual(first.utf16Offset, start); XCTAssertEqual(first.utf16Length, end - start)
      XCTAssertEqual(first.anchorUTF16, start); XCTAssertTrue(first.focusAtEnd)
      // The exact outside endpoint is already owned before the real Shift
      // event; the native range alone cannot manufacture this global anchor.
      let outside: UInt64 = 100
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: outside,
        utf16Length: end - outside, focusAtEnd: true, affinity: .upstream))
      let (_, shiftedEnd) = try await drag(extending: true)
      let shifted = try input.currentDocumentSelection()
      XCTAssertEqual(shifted.anchorUTF16, outside); XCTAssertEqual(shifted.focusUTF16, shiftedEnd)
      XCTAssertEqual(shifted.utf16Offset, outside); XCTAssertEqual(shifted.utf16Length, shiftedEnd - outside)
      let expected = NSMutableString(string: f.originalText)
      expected.replaceCharacters(in: NSRange(location: Int(shifted.utf16Offset), length: Int(shifted.utf16Length)), with: "X")
      view.insertText("X", replacementRange: view.selectedRange())
      try await commands.joinPendingCommand(); try await f.assertSource(expected as String)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertEqual(try input.currentDocumentSelection(), shifted)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(expected as String)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }
}
