import AppKit
import BoomCore
import Darwin
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
  var markupTarget: PagedNativeLogicalWindow?
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
      let capturedResponder = window.firstResponder
      let ownedFocus = capturedResponder === old
      do { try host.mountManagedView(from: old, to: new) }
      catch {
        self.preserve(error)
        throw error
      }
      XCTAssertTrue(host.textView === new)
      if ownedFocus { XCTAssertTrue(window.firstResponder === new) }
      else { XCTAssertTrue(window.firstResponder === capturedResponder) }
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

/// Ordinary TextKit reference only: its actual automatic string Undo is
/// independent of the product's sole canonical logical source/SDK manager.
@MainActor private final class NativeContextReferenceTextView: NSTextView {
  let referenceUndo = UndoManager()
  private(set) var interpretedCommands: [Selector] = []
  override var undoManager: UndoManager? { referenceUndo }
  override func doCommand(by selector: Selector) {
    precondition(interpretedCommands.count < 64)
    interpretedCommands.append(selector); super.doCommand(by: selector)
  }
}

/// Mutable test inputs only; production still uses the existing native owner.
@MainActor private final class NativeContextCustodyProbe {
  var entered = false
  var chargedBytes = 0
  let directions = NSMutableArray(array: [NSNumber(value: 0), NSNumber(value: 2)])
  lazy var marked = NSMutableAttributedString(string: "候補", attributes: [
    .markedClauseSegment: NSNumber(value: 3), .underlineStyle: NSNumber(value: NSUnderlineStyle.double.rawValue),
    .writingDirection: directions,
  ])
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
  func testActualDerivedMarkupWriteOpenFailureStaysObservableAndLaterNativeTypingUndoRemainLive() async throws {
    let text = "# Public heading 🙂\n\n" + String(repeating: "ordinary source\n\n", count: 2600)
    try await fixture(#function, text: text) { f in
      let session = f.session!, engine = f.engine!, view = f.view, viewport = f.scroll!
      let before = try session.captureLogicalState(), version = view.sourceVersion
      let custody = engine.custodySnapshot
      let path = f.root.appendingPathComponent("documents", isDirectory: true)
        .appendingPathComponent(session.sourceBaseRevision.documentID.uuidString.lowercased(), isDirectory: true)
        .appendingPathComponent("pages")
      let descriptor = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      var opened = stat(), modeToRestore: mode_t?, descriptorOwned = true
      @MainActor func restoreMode() throws {
        guard let mode = modeToRestore else { return }
        var actual = stat(), named = stat()
        guard fstat(descriptor, &actual) == 0, lstat(path.path, &named) == 0,
          actual.st_dev == opened.st_dev, actual.st_ino == opened.st_ino,
          named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
          actual.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG else {
          throw BoomError.stale("The owned public append file changed before permission restoration.")
        }
        guard fchmod(descriptor, mode) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        modeToRestore = nil
      }
      @MainActor func closeDescriptor() throws {
        guard descriptorOwned else { return }
        descriptorOwned = false
        guard Darwin.close(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      }
      do {
        var named = stat()
        guard geteuid() != 0, fstat(descriptor, &opened) == 0, lstat(path.path, &named) == 0,
          opened.st_uid == geteuid(), opened.st_mode & S_IFMT == S_IFREG,
          opened.st_mode & 0o7777 == 0o600,
          named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
          named.st_mode & S_IFMT == S_IFREG else {
          throw BoomError.denied("The public control requires its real owned ordinary0600 append file.")
        }
        modeToRestore = opened.st_mode & 0o7777
        guard fchmod(descriptor, 0o400) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try viewport.enableDocumentNavigation(engine: engine, publisher: f.publisher!)
        await viewport.joinMarkup()
        let failure = try XCTUnwrap(viewport.markupFailure, "Sibling cancellation must preserve the actual writer error.") as NSError
        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain); XCTAssertEqual(failure.code, Int(EACCES))
        XCTAssertEqual(engine.custodySnapshot.jobs, custody.jobs)
        XCTAssertEqual(engine.custodySnapshot.reservedPayloadBytes, custody.reservedPayloadBytes)
        XCTAssertTrue(session.isCurrent(before)); XCTAssertEqual(view.sourceVersion, version)
        XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
        // Native source admission remains immediate. Restore the actual FD
        // before yielding so the independent normal saver need not also fail.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("X", replacementRange: view.selectedRange())
        XCTAssertTrue(view.string.hasPrefix("X# Public"))
        try restoreMode(); try closeDescriptor()
        f.commands!.manager.undo(); try await f.commands!.joinPendingCommand()
        await viewport.joinMarkup()
        XCTAssertNil(viewport.markupFailure)
        XCTAssertTrue(view.markupProjection.markdown.contains { $0.kind == "heading" })
        XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
        try await f.assertSource(text)
      } catch {
        do { try restoreMode() } catch let cleanup { f.preserve(cleanup) }
        do { try closeDescriptor() } catch let cleanup { f.preserve(cleanup) }
        throw error
      }
    }
  }

  func testActualPagedMarkupSuppressesRemoteFenceAndResolvesFirstGlobalReferenceInEditingAndScroll() async throws {
    let id = UUID(uuidString: "884646c1-14b4-490d-be8c-8953af793315")!
    let later = "adfcd7f6-e0c9-4d06-a75c-f64794d7760b"
    let definition = "[First]: boom-attachment:\(id.uuidString)\n\n"
    let body = "# fake **bold** [fake](boom-attachment:\(later))\n"
    let text = definition + "```\n" + String(repeating: body, count: 650)
      + "```\n\n[real][FIRST]\n\n[first]: boom-attachment:\(later)\n\n# Tail 🙂\n"
    try await fixture(#function, text: text) { f in
      let source = f.session!, input = f.input!, commands = f.commands!, view = f.view
      let version = view.sourceVersion, generation = source.generation, arena = source.arenaID
      try f.scroll!.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      await f.scroll!.joinMarkup()
      XCTAssertNil(f.scroll!.markupFailure)
      XCTAssertTrue(view.markupProjection.media.isEmpty)
      XCTAssertTrue(view.markupProjection.markdown.contains { $0.kind == "code" })
      XCTAssertFalse(view.markupProjection.markdown.contains { $0.kind == "heading" || $0.kind == "strong" })
      XCTAssertEqual(view.sourceVersion, version)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.arenaID, arena)
      try f.scroll!.requestScroll(toUTF16: UInt64(text.utf16.count))
      try await f.scroll!.joinPresentation(); await f.scroll!.joinMarkup()
      let visible = try XCTUnwrap(f.scroll!.visibleScrollWindow)
      let projection = try XCTUnwrap(f.scroll!.visibleScrollMarkup)
      XCTAssertEqual(projection.media.map(\.id), [id])
      let span = try XCTUnwrap(projection.media.first)
      XCTAssertEqual((visible.text as NSString).substring(with: span.range), "[real][FIRST]")
      XCTAssertTrue(projection.markdown.contains { $0.kind == "heading" })
      XCTAssertTrue(f.view === view); XCTAssertTrue(input.commandOwner === commands)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.arenaID, arena)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualColdMarkupDeliversLocalHeadingThenCancellationJoinsItsSameSourceJob() async throws {
    let text = "# **Ready 🙂**\n\n```\n" + String(repeating: "unread distant code\n", count: 3000) + "```\n"
    try await fixture(#function, text: text) { f in
      let source = f.session!, engine = f.engine!, view = f.view
      let generation = source.generation, arena = source.arenaID, version = view.sourceVersion
      let baseline = engine.custodySnapshot
      let delivered = expectation(description: "actual early local parser proof")
      let cancellation = CancellationFlag()
      do {
        _ = try await engine.logicalMarkup(source.logicalWindow, cancellation: cancellation) { mode, value in
          guard mode == 0 && value.complete else { return }
          XCTAssertTrue(value.matches(source.logicalWindow))
          XCTAssertTrue(value.markdown.contains { $0.kind == "heading" })
          XCTAssertTrue(value.markdown.contains { $0.kind == "strong" })
          delivered.fulfill()
          cancellation.cancel()
        }
        XCTFail("A cancelled actual builder unexpectedly finished its distant index.")
      } catch is CancellationError { }
      guard await XCTWaiter.fulfillment(of: [delivered], timeout: 5) == .completed else {
        throw BoomError.unavailable("The actual cold operation failed to deliver its local proof.")
      }
      XCTAssertEqual(engine.custodySnapshot.jobs, baseline.jobs)
      XCTAssertEqual(engine.custodySnapshot.reservedPayloadBytes, baseline.reservedPayloadBytes)
      XCTAssertTrue(f.view === view)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.arenaID, arena)
      XCTAssertEqual(view.sourceVersion, version)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      // The actual source and Foundation owner remain usable after the joined
      // cancellation; derived work never adopted or persisted a source root.
      view.setSelectedRange(NSRange(location: 0, length: 0))
      view.insertText("X", replacementRange: view.selectedRange())
      f.commands!.manager.undo(); try await f.commands!.joinPendingCommand()
      XCTAssertEqual(view.string.hasPrefix("# **Ready"), true)
      try await f.assertSource(text)
    }
  }

  func testActualColdMarkupRebindsSameSourceWindowWithoutRestartingItsEnteredBuilder() async throws {
    let prefix = "# First\n\n" + String(repeating: "plain paragraph\n\n", count: 1000)
    let text = prefix + "# **Second 🙂**\n\n```\n" + String(repeating: "code tail\n", count: 4000) + "```\n"
    try await fixture(#function, text: text) { f in
      let source = f.session!, engine = f.engine!, view = f.view
      let original = source.logicalWindow
      let captured = try source.captureLogicalRead()
      let second = try await engine.logicalWindow(captured.source, utf16Anchor: UInt64(prefix.utf16.count), maximumBytes: 128)
      XCTAssertFalse(second.windowID == original.windowID)
      f.markupTarget = original
      let changed = expectation(description: "actual first local proof")
      let rebound = expectation(description: "actual same-builder query of second heading")
      let cancellation = CancellationFlag()
      let before = engine.custodySnapshot
      let generation = source.generation, arena = source.arenaID, version = view.sourceVersion
      do {
        _ = try await engine.logicalMarkup(original, cancellation: cancellation,
          latestWindow: { f.markupTarget }) { mode, value in
          guard mode == 0 && value.complete else { return }
          if value.matches(original), f.markupTarget?.windowID == original.windowID {
            XCTAssertTrue(value.markdown.contains { $0.kind == "heading" })
            f.markupTarget = second; changed.fulfill()
          } else if value.matches(second) {
            XCTAssertTrue(value.markdown.contains { $0.kind == "heading" })
            XCTAssertTrue(value.markdown.contains { $0.kind == "strong" })
            rebound.fulfill(); cancellation.cancel()
          }
        }
        XCTFail("The actual rebound operation ignored cancellation.")
      } catch is CancellationError { }
      guard await XCTWaiter.fulfillment(of: [changed, rebound], timeout: 5, enforceOrder: true) == .completed else {
        throw BoomError.unavailable("The actual cold builder failed its ordered same-source query replacement.")
      }
      XCTAssertEqual(engine.custodySnapshot.jobs, before.jobs)
      XCTAssertEqual(engine.custodySnapshot.reservedPayloadBytes, before.reservedPayloadBytes)
      XCTAssertTrue(f.view === view)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.arenaID, arena)
      XCTAssertEqual(view.sourceVersion, version)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      f.markupTarget = nil
      try await f.assertSource(text)
    }
  }

  func testActualTwoModeReferenceCapacityAndRefusalStayBoundedWithoutChangingNativeSource() async throws {
    let labels: (Range<Int>) -> String = { range in
      let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
      return range.map { value in "[\(alphabet[value / 1296])\(alphabet[(value / 36) % 36])\(alphabet[value % 36])] " }.joined() + "\n\n"
    }
    let first = labels(0..<5000)
    let text = first + labels(5000..<9000)
      + "# [after]\n\n[after]: boom-attachment:884646c1-14b4-490d-be8c-8953af793315\n"
    try await fixture(#function, text: text) { f in
      let engine = f.engine!, source = f.session!, view = f.view
      let captured = try source.captureLogicalRead()
      let window = try await engine.logicalWindow(captured.source, utf16Anchor: UInt64(first.utf16.count + 6_000),
        maximumBytes: PagedWorkingWindow.hardBytes)
      XCTAssertLessThan(window.start.bytes, UInt64(first.utf8.count), "The actual window overlaps both complete label blocks.")
      XCTAssertGreaterThan(window.start.bytes + window.summary.bytes,
        UInt64(first.utf8.count + labels(5000..<9000).utf8.count + "# [after]\n".utf8.count))
      let before = engine.custodySnapshot
      let generation = source.generation, arena = source.arenaID, version = view.sourceVersion
      let actual = try await engine.logicalMarkup(window)
      XCTAssertTrue(actual.matches(window))
      XCTAssertFalse(actual.style.complete); XCTAssertFalse(actual.media.complete)
      XCTAssertEqual(actual.style.maxReferenceCount, 8192); XCTAssertEqual(actual.media.maxReferenceCount, 8192)
      XCTAssertLessThanOrEqual(actual.style.maxReferenceProbes, 64)
      XCTAssertLessThanOrEqual(actual.media.maxReferenceProbes, 64)
      XCTAssertGreaterThan(actual.trackedReferenceCapacityUpperBytes, 8192 * 3 * 2)
      XCTAssertLessThan(actual.trackedReferenceCapacityUpperBytes, 3_145_728)
      print("Actual two-mode retained-reference-capacity upper: \(actual.trackedReferenceCapacityUpperBytes); excludes temporary parser/host/decoder/allocator peak.")
      XCTAssertFalse(actual.style.markdown.contains { $0.kind == "heading" })
      XCTAssertTrue(actual.media.media.isEmpty)
      XCTAssertEqual(engine.custodySnapshot.jobs, before.jobs)
      XCTAssertEqual(engine.custodySnapshot.reservedPayloadBytes, before.reservedPayloadBytes)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.arenaID, arena)
      XCTAssertEqual(view.sourceVersion, version); XCTAssertTrue(f.view === view)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(f.commands!.firstFailure)
      try await f.assertSource(text)
    }
  }

  func testActualCachedMarkupReadCompletesUnderEnteredWriterAndStaleTypingConvergesAfterRelease() async throws {
    let text = "# Head 🙂\n\n" + String(repeating: "ordinary paragraph\n\n", count: 2600) + "# Tail\n"
    try await fixture(#function, text: text) { f in
      let engine = f.engine!, source = f.session!, view = f.view, commands = f.commands!
      let original = try source.captureLogicalRead()
      _ = try await engine.logicalMarkup(source.logicalWindow)
      try f.scroll!.enableDocumentNavigation(engine: engine, publisher: f.publisher!)
      await f.scroll!.joinMarkup()
      let tail = try await engine.logicalWindow(original.source, utf16Anchor: original.source.summary.utf16,
        maximumBytes: PagedWorkingWindow.targetBytes)
      let release = DispatchSemaphore(value: 0)
      let entered = expectation(description: "actual writer executor entered")
      let writer = Task { try await engine.storageExecutorForTesting.run {
        entered.fulfill()
        guard release.wait(timeout: .now() + 10) == .success else {
          throw BoomError.unavailable("Actual writer hold exceeded its bounded deadline.")
        }
      } }
      defer { release.signal() }
      guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else {
        release.signal(); _ = await writer.result
        throw BoomError.unavailable("Actual writer did not enter.")
      }
      let completed = expectation(description: "real cached-context query returned under held writer")
      let reader = Task { defer { completed.fulfill() }; return try await engine.logicalMarkup(tail) }
      do {
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 5) == .completed else {
          throw BoomError.unavailable("Cached Markdown query remained coupled to writer/finalization.")
        }
        let result = try await reader.value
        XCTAssertTrue(result.matches(tail)); XCTAssertTrue(result.style.complete && result.media.complete)
        XCTAssertTrue(result.style.markdown.contains { $0.kind == "heading" })
        let generation = source.generation
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("X", replacementRange: view.selectedRange())
        XCTAssertEqual(source.generation, generation + 1)
        // This derived request waits behind the actual writer. A later edit
        // supersedes it while the same real view/native history remain live.
        await Task.yield()
        view.insertText("Y", replacementRange: view.selectedRange())
        XCTAssertEqual(source.generation, generation + 2)
        commands.manager.undo(); try await commands.joinPendingCommand()
        XCTAssertEqual(source.generation, generation + 3)
        commands.manager.redo(); try await commands.joinPendingCommand()
        XCTAssertEqual(source.generation, generation + 4)
        XCTAssertTrue(view.string.hasPrefix("XY# Head"))
        XCTAssertFalse(source.isCurrent(original))
        release.signal(); try await writer.value
        await f.scroll!.joinMarkup()
        XCTAssertNil(f.scroll!.markupFailure)
        XCTAssertFalse(view.markupProjection.markdown.contains { $0.kind == "heading" })
        XCTAssertTrue(f.view === view); XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(commands.firstFailure)
        try await f.assertSource("XY" + text)
      } catch {
        release.signal(); _ = await reader.result; _ = await writer.result
        throw error
      }
    }
  }

  func testManagedRecenterKeepsDocumentContextAndAllowsTypingUndoRedoWithInertOldStorage() async throws {
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
      XCTAssertTrue(f.view.inputContext === context)
      XCTAssertTrue(oldManager.textStorage === f.view.boundedStorage)
      XCTAssertTrue(oldContainer.textView === f.view)
      XCTAssertTrue(oldManager.delegate === f.view.inlineMedia.layout)
      XCTAssertThrowsError(try oldBinding.admitsInput(in: source))
      XCTAssertEqual(try input.inputLease(for: old).identity, input.activeIdentity)
      XCTAssertEqual(oldClient.identity.ownerID, oldIdentity.ownerID)
      XCTAssertEqual(oldClient.identity.sessionID, oldIdentity.sessionID)
      XCTAssertFalse(oldClient.isRetired)
      XCTAssertTrue((context.client as? PagedNativeTextInputClient) === oldClient)
      XCTAssertEqual(oldClient.selectedRange(), NSRange(location: 8_000, length: 0))
      XCTAssertEqual(oldClient.markedRange(), NSRange(location: NSNotFound, length: 0))
      XCTAssertFalse(oldClient.hasMarkedText())
      var absent = NSRange(location: 0, length: 1)
      XCTAssertNil(oldClient.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &absent))
      XCTAssertEqual(absent, NSRange(location: NSNotFound, length: 0))
      let newClient = try XCTUnwrap(f.view.inputContext?.client as? PagedNativeTextInputClient)
      XCTAssertTrue(newClient === oldClient)
      let currentBytes = Data(f.view.string.utf8), count = manager.undoCount
      oldStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "OLD")
      oldStorage.setAttributes([.foregroundColor: NSColor.red], range: NSRange(location: 0, length: 1))
      XCTAssertEqual(oldStorage.string, oldText)
      XCTAssertEqual(Data(f.view.string.utf8), currentBytes); XCTAssertEqual(source.generation, sequence)
      XCTAssertEqual(manager.undoCount, count); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      // This retained reference IS the current physical view; ordinary input
      // must still reach its new source, unlike retired storage/binding handles.
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
      XCTAssertEqual(oldBinding.state, .retired); XCTAssertFalse(client.isRetired)
      XCTAssertEqual(client.identity.ownerID, oldIdentity?.ownerID)
      XCTAssertEqual(client.identity.sessionID, oldIdentity?.sessionID)
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
      XCTAssertEqual(manager.undoCount, 1); XCTAssertFalse(oldClient.isRetired)
      let changed = try await f.record(), changedLogical = try source.captureLogicalState().source
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
      XCTAssertFalse(oldClient.isRetired); XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
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
      XCTAssertEqual(source.sealedRevision, record); XCTAssertFalse(oldClient.isRetired)
      XCTAssertTrue(f.view.inputContext?.client === oldClient)
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
      XCTAssertEqual(commands.queuedNativeContinuationCount, 0, "A same-selection preload must not escrow the actual immediate native callbacks.")
      XCTAssertEqual(commands.retainedInputBytes, 0)
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

  /// Actual NSWindow dispatch through the managed mouse responder. These SDK
  /// drag/up events are not a packaged physical-mouse acceptance.
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
        // The partial-window gesture uses actual responder dispatch for all
        // three events. Whole-document/multiclick Cocoa tracking is separate.
        window.sendEvent(down)
        window.sendEvent(dragged)
        window.sendEvent(up)
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

  func testActualPointerAutoscrollExtendsAcrossLogicalWindowsDuringHeldSaveThenEditsAndResponderUndo() async throws {
    let line = "abcdefghijklmné🙂\n"
    try await fixture(#function, text: String(repeating: line, count: 3_000)) { f in
      let input = f.input!, source = f.session!, commands = f.commands!, window = f.window!, viewport = f.scroll!
      try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      let hold = try await f.route!.holdNext(.commitBefore)
      f.view.setSelectedRange(NSRange(location: 4, length: 0))
      f.view.insertText("X", replacementRange: f.view.selectedRange())
      try await f.route!.awaitHeld(hold)
      let generation = source.generation, before = source.sealedRootRecord, manager = commands.manager
      let withX = NSMutableString(string: f.originalText)
      withX.insert("X", at: 4)
      try viewport.requestScroll(toUTF16: 12_000); try await viewport.joinPresentation()
      let projection = try XCTUnwrap(viewport.visibleScrollWindow)
      let surface = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
      let display = try XCTUnwrap(surface.documentView as? NSTextView)
      try XCTUnwrap(display.layoutManager).ensureLayout(for: try XCTUnwrap(display.textContainer))
      surface.contentView.scroll(to: NSPoint(x: 0, y: max(0, display.frame.height - surface.contentSize.height)))
      surface.reflectScrolledClipView(surface.contentView)
      let point = NSPoint(x: display.textContainerOrigin.x + 22, y: display.visibleRect.minY + 24)
      let downLocal = display.characterIndexForInsertion(at: point)
      let anchor = try projection.position(localUTF16: downLocal).utf16
      @MainActor func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
      }
      let down = try event(.leftMouseDown, display.convert(point, to: nil), 1)
      window.sendEvent(down)
      XCTAssertEqual(try input.currentDocumentSelection().anchorUTF16, anchor)
      let native = f.view, arena = source.arenaID
      let outside = viewport.contentView.convert(NSPoint(x: 40, y: viewport.contentView.bounds.maxY + 48), to: nil)
      let dragged = try event(.leftMouseDragged, outside, 2)
      window.sendEvent(dragged)
      try await viewport.joinPresentation()
      let visible = try XCTUnwrap(viewport.visibleScrollWindow)
      let selected = try input.currentDocumentSelection()
      XCTAssertEqual(selected.anchorUTF16, anchor); XCTAssertTrue(selected.focusAtEnd)
      XCTAssertGreaterThan(selected.focusUTF16, projection.start.utf16 + projection.summary.utf16)
      XCTAssertTrue(visible.snapshot.isSame(source.logicalWindow.snapshot))
      XCTAssertEqual(source.arenaID, arena, "Dragging does not rebind inside Cocoa's private tracking.")
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.sealedRootRecord, before)
      XCTAssertTrue(f.view === native); XCTAssertTrue(window.firstResponder === native)
      XCTAssertTrue(window.isKeyWindow); XCTAssertFalse(commands.hasPendingCommand)
      window.sendEvent(try event(.leftMouseUp, outside, 3))
      try await viewport.joinPresentation()
      XCTAssertNil(viewport.visibleScrollWindow)
      XCTAssertNotEqual(source.arenaID, arena, "Release adopts the already displayed exact focus window.")
      let finalSelection = try input.currentDocumentSelection()
      XCTAssertEqual(finalSelection.anchorUTF16, anchor)
      XCTAssertGreaterThan(finalSelection.focusUTF16, projection.start.utf16 + projection.summary.utf16)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.activeNavigationOperationCount, 0)
      let expected = NSMutableString(string: withX as String)
      expected.replaceCharacters(in: NSRange(location: Int(finalSelection.utf16Offset),
        length: Int(finalSelection.utf16Length)), with: "Q")
      native.insertText("Q", replacementRange: native.selectedRange())
      try await commands.joinPendingCommand()
      XCTAssertEqual(source.generation, generation + 1); XCTAssertEqual(source.sealedRootRecord, before)
      XCTAssertTrue(commands.manager === manager); XCTAssertNil(input.firstRefusal)
      try await f.route!.release(hold); try await f.assertSource(expected as String)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(withX as String)
      XCTAssertEqual(try input.currentDocumentSelection(), finalSelection)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(expected as String)
      XCTAssertNil(viewport.presentationFailure); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualMouseUpAndCloseStopAutoscrollWhileOriginalWindowDeliveryIsHeldAndJoined() async throws {
    let line = "abcdefghijklmné🙂\n"
    try await fixture(#function, text: String(repeating: line, count: 3_000)) { f in
      let source = f.session!, input = f.input!, commands = f.commands!, window = f.window!, viewport = f.scroll!
      try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      @MainActor func beginHeldDrag() async throws -> (PagedNativeLogicalControlStorage.Ticket, PagedNativeNavigationSelection) {
        let view = f.view
        try XCTUnwrap(view.layoutManager).ensureLayout(for: try XCTUnwrap(view.textContainer))
        viewport.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - viewport.contentSize.height)))
        viewport.reflectScrolledClipView(viewport.contentView)
        let point = NSPoint(x: view.textContainerOrigin.x + 22, y: view.visibleRect.minY + 24)
        @MainActor func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
          try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1, pressure: 1))
        }
        window.sendEvent(try event(.leftMouseDown, at: view.convert(point, to: nil)))
        let hold = try await f.route!.holdNext(.windowAfter)
        let outside = viewport.contentView.convert(NSPoint(x: 40, y: viewport.contentView.bounds.maxY + 48), to: nil)
        window.sendEvent(try event(.leftMouseDragged, at: outside))
        try await f.route!.awaitHeld(hold) // actual backend window has returned; forwarding reply still owned
        XCTAssertTrue(viewport.hasPendingPresentationRead); XCTAssertTrue(viewport.isMouseAutoscrolling)
        XCTAssertNil(viewport.visibleScrollWindow)
        return (hold, try input.currentDocumentSelection())
      }
      let (first, selected) = try await beginHeldDrag()
      let arena = source.arenaID, generation = source.generation
      let outside = viewport.contentView.convert(NSPoint(x: 40, y: viewport.contentView.bounds.maxY + 48), to: nil)
      let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: outside, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
      window.sendEvent(up)
      XCTAssertTrue(viewport.hasPendingPresentationRead, "Mouse release must not await the actual held reply.")
      XCTAssertFalse(viewport.isMouseAutoscrolling); XCTAssertEqual(source.arenaID, arena)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(try input.currentDocumentSelection(), selected)
      f.view.insertText("Y", replacementRange: f.view.selectedRange())
      XCTAssertEqual(source.generation, generation + 1); XCTAssertNil(input.firstRefusal)
      try await f.route!.release(first); try await viewport.joinPresentation()
      XCTAssertFalse(viewport.hasPendingPresentationRead); XCTAssertNil(viewport.visibleScrollWindow)
      XCTAssertEqual(source.arenaID, arena, "The superseded actual returned window never installs at a newer source.")
      let expected = NSMutableString(string: f.originalText)
      expected.replaceCharacters(in: NSRange(location: Int(selected.utf16Offset), length: Int(selected.utf16Length)), with: "Y")
      try await f.assertSource(expected as String)
      // A second genuine entered/read-return hold keeps close asynchronous.
      // Actual close owns/join the same task and invalidates its actual timer.
      let (second, _) = try await beginHeldDrag()
      let closed = Task { try await viewport.closePresentation() }
      try await f.route!.release(second)
      try await closed.value
      XCTAssertFalse(viewport.isMouseAutoscrolling); XCTAssertFalse(viewport.hasPendingPresentationRead)
      XCTAssertNil(viewport.visibleScrollWindow); XCTAssertNil(f.view.documentViewport)
      let joined = await f.route!.snapshot
      XCTAssertEqual(joined.activeCalls, 0); XCTAssertEqual(joined.startedCalls, joined.finishedCalls)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
    }
  }


  func testActualNavigationThenQueuedKeyPointerAndLaterKeyKeepChronologicalMappedSelectionAndUndo() async throws {
    let line = "abcdefghijklmné🙂\n"
    try await fixture(#function, text: String(repeating: line, count: 3_000)) { f in
      let input = f.input!, source = f.session!, commands = f.commands!, window = f.window!, viewport = f.scroll!
      try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      try viewport.requestScroll(toUTF16: 40_000); try await viewport.joinPresentation()
      let projection = try XCTUnwrap(viewport.visibleScrollWindow)
      let surface = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
      let display = try XCTUnwrap(surface.documentView as? NSTextView)
      let point = NSPoint(x: display.textContainerOrigin.x + 22, y: display.textContainerOrigin.y + 10)
      let local = display.characterIndexForInsertion(at: point)
      let capturedCaret = try projection.position(localUTF16: local).utf16
      let originalArena = source.arenaID, generation = source.generation
      let navigationCaret: UInt64 = 12_001
      XCTAssertGreaterThan(capturedCaret, navigationCaret)
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 12_000, caret: navigationCaret)
      try await f.route!.awaitHeld(hold)
      window.sendEvent(try f.key()) // original z belongs to the preceding navigation target
      XCTAssertEqual(commands.queuedRawKeyCount, 1)
      XCTAssertTrue(commands.canOrderPointerAfterNavigation)
      let location = display.convert(point, to: nil)
      @MainActor func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1,
          pressure: type == .leftMouseUp ? 0 : 1))
      }
      window.sendEvent(try mouse(.leftMouseDown))
      XCTAssertEqual(source.generation, generation)
      XCTAssertEqual(source.arenaID, originalArena)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, 0,
        "The visible pointer paints its captured intent without canceling or retargeting preceding input.")
      XCTAssertEqual(display.selectedRange(), NSRange(location: local, length: 0))
      window.sendEvent(try mouse(.leftMouseUp))
      let y = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
      window.sendEvent(y)
      XCTAssertEqual(commands.queuedRawKeyCount, 2)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertLessThanOrEqual(commands.retainedInputBytes, PagedNativeUndoOwner.maximumRawKeyBytes)
      XCTAssertEqual(source.activeNavigationOperationCount, 1)
      XCTAssertNil(viewport.presentationFailure); XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      try await f.route!.release(hold); _ = try await loading.value
      try await commands.joinPendingCommand()
      XCTAssertEqual(source.activeNavigationOperationCount, 0)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.retainedInputBytes, 0)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      let mappedCaret = capturedCaret + 1 // the actual preceding z splice is before this captured point
      let selected = try input.currentDocumentSelection()
      XCTAssertEqual(selected.utf16Offset, mappedCaret + 1); XCTAssertEqual(selected.utf16Length, 0)
      let expected = NSMutableString(string: f.originalText)
      expected.insert("z", at: Int(navigationCaret)); expected.insert("Y", at: Int(mappedCaret))
      try await f.assertSource(expected as String)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: window))
      try await commands.joinPendingCommand()
      let beforeY = NSMutableString(string: f.originalText); beforeY.insert("z", at: Int(navigationCaret))
      try await f.assertSource(beforeY as String)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, mappedCaret)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: window))
      try await commands.joinPendingCommand(); try await f.assertSource(expected as String)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      XCTAssertNil(f.view.boundedStorage.mutationFailure); XCTAssertNil(viewport.presentationFailure)
    }
  }


  func testActualQueuedTabAndBacktabThenPointerAndTypingMatchOrdinaryNativeInterpretation() async throws {
    let line = "abcdefghijklmné🙂\n"
    for shifting in [false, true] {
      try await fixture(#function, text: String(repeating: line, count: 3_000)) { f in
        let input = f.input!, source = f.session!, commands = f.commands!, window = f.window!, viewport = f.scroll!
        let flags: NSEvent.ModifierFlags = shifting ? [.shift] : []
        let characters = shifting ? "\u{19}" : "\t"
        @MainActor func tab() throws -> NSEvent {
          try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        }
        // The actual ordinary NSTextView decides whether this native key
        // inserts, moves focus, or only moves selection. No guessed Tab text.
        let reference = NativeContextReferenceTextView(frame: NSRect(x: 0, y: 260, width: 280, height: 48))
        reference.isRichText = false; reference.string = "ab"
        let before = NSTextField(frame: NSRect(x: 300, y: 260, width: 100, height: 24))
        let after = NSTextField(frame: NSRect(x: 410, y: 260, width: 100, height: 24))
        window.contentView!.addSubview(reference); window.contentView!.addSubview(before); window.contentView!.addSubview(after)
        before.nextKeyView = reference; reference.nextKeyView = after
        after.nextKeyView = f.view; f.view.nextKeyView = before
        reference.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(window.makeFirstResponder(reference)); window.sendEvent(try tab())
        let ordinary = reference.string
        guard ordinary.hasPrefix("a"), ordinary.hasSuffix("b"), ordinary.utf16.count <= 34 else {
          throw BoomError.invalid("The ordinary native Tab oracle produced an unsupported edit shape: \(ordinary.debugDescription)")
        }
        let inserted = String(ordinary.dropFirst().dropLast())
        XCTAssertFalse(reference.interpretedCommands.isEmpty, "The reference must actually interpret the native key.")
        let ordinaryKeptFocus = window.firstResponder === reference
        print("Ordinary native \(shifting ? "Backtab" : "Tab"): insertedUTF16=\(inserted.utf16.count), keptEditorFocus=\(ordinaryKeptFocus)")
        try await PagedNativeFixtureApplication.focus(f.view, in: window)
        try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
        try viewport.requestScroll(toUTF16: 40_000); try await viewport.joinPresentation()
        let projection = try XCTUnwrap(viewport.visibleScrollWindow)
        let surface = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
        let display = try XCTUnwrap(surface.documentView as? NSTextView)
        let point = NSPoint(x: display.textContainerOrigin.x + 22, y: display.textContainerOrigin.y + 10)
        let local = display.characterIndexForInsertion(at: point)
        let capturedCaret = try projection.position(localUTF16: local).utf16
        let navigationCaret: UInt64 = 12_001
        XCTAssertGreaterThan(capturedCaret, navigationCaret)
        let generation = source.generation
        let hold = try await f.route!.holdNext(.windowAfter)
        let loading = try f.startNavigation(anchor: 12_000, caret: navigationCaret)
        try await f.route!.awaitHeld(hold)
        window.sendEvent(try tab())
        XCTAssertEqual(commands.queuedRawKeyCount, 1)
        XCTAssertTrue(commands.canOrderPointerAfterNavigation, "An admitted Tab cannot discard the later real pointer intent.")
        let location = display.convert(point, to: nil)
        @MainActor func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
          try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1))
        }
        window.sendEvent(try mouse(.leftMouseDown)); window.sendEvent(try mouse(.leftMouseUp))
        let y = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
        window.sendEvent(y)
        XCTAssertEqual(commands.queuedRawKeyCount, 2); XCTAssertEqual(commands.retainedRefusedInputCount, 0)
        try await f.route!.release(hold); _ = try await loading.value
        try await commands.joinPendingCommand()
        let mappedCaret = capturedCaret + UInt64(inserted.utf16.count)
        let expected = NSMutableString(string: f.originalText)
        expected.insert(inserted, at: Int(navigationCaret)); expected.insert("Y", at: Int(mappedCaret))
        try await f.assertSource(expected as String)
        XCTAssertEqual(source.generation, generation + (inserted.isEmpty ? 1 : 2))
        XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, mappedCaret + 1)
        XCTAssertTrue(window.firstResponder === f.view, "The later actual mouse-down follows Backtab's focus transition.")
        XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.retainedInputBytes, 0)
        XCTAssertEqual(commands.retainedRefusedInputCount, 0); XCTAssertNil(viewport.presentationFailure)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
        try await commands.joinPendingCommand()
        let beforeY = NSMutableString(string: f.originalText); beforeY.insert(inserted, at: Int(navigationCaret))
        try await f.assertSource(beforeY as String)
        XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, mappedCaret)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
        try await commands.joinPendingCommand(); try await f.assertSource(expected as String)
        XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      }
    }
  }

  func testActualCloseSettlesUnfinishedPointerAtLastDragPointWithoutLosingEarlierOrLaterKeys() async throws {
    let line = "abcdefghijklmné🙂\n"
    try await fixture(#function, text: String(repeating: line, count: 3_000)) { f in
      let input = f.input!, source = f.session!, commands = f.commands!, window = f.window!, viewport = f.scroll!
      try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      try viewport.requestScroll(toUTF16: 40_000); try await viewport.joinPresentation()
      let projection = try XCTUnwrap(viewport.visibleScrollWindow)
      let surface = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
      let display = try XCTUnwrap(surface.documentView as? NSTextView)
      let startPoint = NSPoint(x: display.textContainerOrigin.x + 22, y: display.textContainerOrigin.y + 10)
      let dragPoint = NSPoint(x: display.textContainerOrigin.x + 86, y: display.textContainerOrigin.y + 10)
      let anchor = try projection.position(localUTF16: display.characterIndexForInsertion(at: startPoint)).utf16
      let focus = try projection.position(localUTF16: display.characterIndexForInsertion(at: dragPoint)).utf16
      XCTAssertGreaterThan(focus, anchor)
      let navigationCaret: UInt64 = 12_001, generation = source.generation
      XCTAssertGreaterThan(anchor, navigationCaret)
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 12_000, caret: navigationCaret)
      try await f.route!.awaitHeld(hold)
      window.sendEvent(try f.key())
      @MainActor func mouse(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: display.convert(point, to: nil),
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1, pressure: 1))
      }
      window.sendEvent(try mouse(.leftMouseDown, point: startPoint))
      window.sendEvent(try mouse(.leftMouseDragged, point: dragPoint))
      let y = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
      window.sendEvent(y)
      XCTAssertEqual(commands.queuedRawKeyCount, 2); XCTAssertEqual(source.generation, generation)
      let closeEntered = XCTestExpectation(description: "Actual viewport close entered its original owner join")
      let closing = Task { @MainActor in closeEntered.fulfill(); try await viewport.closePresentation() }
      let started = await XCTWaiter.fulfillment(of: [closeEntered], timeout: 10)
      guard started == .completed else { throw BoomError.unavailable("Actual pointer close did not enter.") }
      XCTAssertEqual(source.activeNavigationOperationCount, 1)
      XCTAssertTrue(window.firstResponder === f.view)
      // No mouseup is fabricated. Close completes the stored LAST real drag
      // point, then owns the original read and both chronological native keys.
      try await f.route!.release(hold); _ = try await loading.value; try await closing.value
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.retainedInputBytes, 0)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertEqual(source.activeNavigationOperationCount, 0)
      XCTAssertNil(viewport.visibleScrollWindow); XCTAssertFalse(viewport.isMouseAutoscrolling)
      XCTAssertFalse(viewport.hasPendingPresentationRead); XCTAssertNil(f.view.documentViewport)
      let expected = NSMutableString(string: f.originalText); expected.insert("z", at: Int(navigationCaret))
      expected.replaceCharacters(in: NSRange(location: Int(anchor + 1), length: Int(focus - anchor)), with: "Y")
      try await f.assertSource(expected as String)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: window))
      try await commands.joinPendingCommand()
      let beforeY = NSMutableString(string: f.originalText); beforeY.insert("z", at: Int(navigationCaret))
      try await f.assertSource(beforeY as String)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, anchor + 1)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Length, focus - anchor)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure); XCTAssertNil(viewport.presentationFailure)
    }
  }

  func testActualOrderedPointerFocusRefusalClearsItsDisplayAndAllowsLaterCurrentTyping() async throws {
    let line = "abcdefghijklmné🙂\n"
    try await fixture(#function, text: String(repeating: line, count: 3_000)) { f in
      let input = f.input!, source = f.session!, commands = f.commands!, window = f.window!, viewport = f.scroll!
      try viewport.enableDocumentNavigation(engine: f.engine!, publisher: f.publisher!)
      try viewport.requestScroll(toUTF16: 40_000); try await viewport.joinPresentation()
      let surface = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
      let display = try XCTUnwrap(surface.documentView as? NSTextView)
      let point = NSPoint(x: display.textContainerOrigin.x + 22, y: display.textContainerOrigin.y + 10)
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 12_000, caret: 12_001)
      try await f.route!.awaitHeld(hold)
      let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: display.convert(point, to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      window.sendEvent(down)
      let observed = try input.observeSelection(), generation = source.generation, arena = source.arenaID
      // No earlier writing is queued in THIS refusal/cleanup control. Delivery
      // of admitted writing across focus changes is a separate required case.
      XCTAssertEqual(commands.queuedRawKeyCount, 0)
      XCTAssertTrue(window.makeFirstResponder(nil)); XCTAssertTrue(window.makeFirstResponder(f.view))
      XCTAssertNotEqual(try input.observeSelection().inputLease, observed.inputLease)
      XCTAssertEqual(commands.retainedRefusedInputCount, 1)
      XCTAssertNil(viewport.visibleScrollWindow)
      try await viewport.joinPresentation()
      XCTAssertFalse(viewport.hasPendingPresentationRead)
      XCTAssertEqual(source.generation, generation); XCTAssertEqual(source.arenaID, arena)
      let v = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "V", charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
      window.sendEvent(v)
      XCTAssertEqual(source.generation, generation + 1)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      try await f.route!.release(hold); try await f.requireStale(loading)
      try await f.assertSource("V" + f.originalText)
      XCTAssertNil(viewport.presentationFailure); XCTAssertFalse(commands.hasPendingCommand)
      XCTAssertNil(f.view.boundedStorage.mutationFailure)
    }
  }


  func testActualAdmittedTypingFinishesItsNavigationAfterFocusMoveWithoutRetargetingOrTakingFocus() async throws {
    try await fixture(#function) { f in
      let input = f.input!, commands = f.commands!, source = f.session!, window = f.window!, view = f.view
      let context = try XCTUnwrap(view.inputContext)
      let client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 48_000, caret: 50_000)
      try await f.route!.awaitHeld(hold)
      window.sendEvent(try f.key())
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(source.generation, 0)
      let other = NSTextView(frame: NSRect(x: 0, y: 240, width: 300, height: 70))
      other.string = "Other"; window.contentView!.addSubview(other)
      XCTAssertTrue(window.makeFirstResponder(other)); XCTAssertTrue(window.firstResponder === other)
      let originalContextSelection = client.selectedRange()
      view.keyDown(with: try f.key()) // foreign new ingress is not the already admitted event
      XCTAssertEqual(source.generation, 0); XCTAssertEqual(client.selectedRange(), originalContextSelection)
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)))
      let otherText = other.string
      try await f.route!.release(hold); _ = try await loading.value
      try await commands.joinPendingCommand()
      XCTAssertTrue(view.inputContext === context); XCTAssertTrue(window.firstResponder === other)
      XCTAssertEqual(other.string, otherText); XCTAssertTrue(otherText.contains("q"))
      XCTAssertEqual(source.generation, 1); XCTAssertEqual(client.selectedRange(), NSRange(location: 50_001, length: 0))
      var expected = f.originalText
      expected.insert("z", at: expected.index(expected.startIndex, offsetBy: 50_000))
      try await f.assertSource(expected)
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertEqual(commands.retainedInputBytes, 0); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      XCTAssertTrue(window.makeFirstResponder(view)); other.removeFromSuperview()
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, 50_000)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(expected)
    }
  }

  func testActualDocumentContextUsesGlobalBoundedRangesAndRetiresOnlyWithItsOwner() async throws {
    try await fixture(#function) { f in
      let view = f.view, input = f.input!, source = f.session!, commands = f.commands!
      let context = try XCTUnwrap(view.inputContext), client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let oldStorage = view.boundedStorage, oldBinding = try XCTUnwrap(view.inputBinding)
      let window = try await f.startNavigation(anchor: 48_000, caret: 50_000).value
      try await commands.joinPendingCommand()
      XCTAssertTrue(view.inputContext === context); XCTAssertFalse(client.isRetired)
      XCTAssertEqual(client.selectedRange(), NSRange(location: 50_000, length: 0))
      XCTAssertEqual(oldBinding.state, .retired)
      let oldText = oldStorage.string
      oldStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "OLD")
      XCTAssertEqual(oldStorage.string, oldText); XCTAssertEqual(source.generation, 0)
      var actual = NSRange(location: NSNotFound, length: 0)
      let requested = NSRange(location: Int(window.start.utf16) - 10, length: 30)
      let bounded = try XCTUnwrap(client.attributedSubstring(forProposedRange: requested, actualRange: &actual))
      XCTAssertEqual(actual, NSRange(location: Int(window.start.utf16), length: 20))
      XCTAssertEqual(bounded.string, String(window.text.prefix(20)))
      XCTAssertNil(client.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &actual))
      XCTAssertEqual(actual, NSRange(location: NSNotFound, length: 0))
      client.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 50_000, length: 0))
      XCTAssertTrue(view.hasMarkedText()); XCTAssertTrue(source.isPinned)
      XCTAssertEqual(client.markedRange(), NSRange(location: 50_000, length: 1))
      client.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      XCTAssertEqual(client.selectedRange(), NSRange(location: 50_002, length: 0))
      var expected = f.originalText
      expected.insert(contentsOf: "日本", at: expected.index(expected.startIndex, offsetBy: 50_000))
      try await commands.joinPendingCommand(); try await f.assertSource(expected)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertTrue(view.inputContext === context); XCTAssertFalse(client.isRetired)
      // A global selection larger than this arena starts one real bounded
      // composition, never an island-only replacement or a full source String.
      view.selectAll(nil); try await commands.joinPendingCommand()
      let global = try input.currentDocumentSelection()
      XCTAssertEqual(client.selectedRange(), NSRange(location: 0, length: f.originalText.utf16.count))
      client.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(view.hasMarkedText()); XCTAssertTrue(source.isPinned)
      client.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await commands.joinPendingCommand(); try await f.assertSource("文")
      XCTAssertTrue(view.inputContext === context)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertEqual(try input.currentDocumentSelection(), global)
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      try commands.closeInput(); try commands.requireJoinedClose()
      let generation = source.generation, bytes = Data(view.string.utf8)
      XCTAssertTrue(client.isRetired); XCTAssertNil(view.inputContext)
      client.insertText("LATE", replacementRange: NSRange(location: 0, length: 0))
      client.setMarkedText("旧", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
      client.doCommand(by: NSSelectorFromString("undo:")); client.unmarkText()
      XCTAssertEqual(client.selectedRange(), NSRange(location: NSNotFound, length: 0))
      XCTAssertEqual(client.markedRange(), NSRange(location: NSNotFound, length: 0))
      XCTAssertFalse(client.hasMarkedText()); XCTAssertEqual(source.generation, generation)
      XCTAssertEqual(Data(view.string.utf8), bytes); XCTAssertNil(input.firstRefusal)
    }
  }

  func testActualNativeDeadKeyUsesOneDocumentContextAcrossQueuedNavigationAndContinuation() async throws {
    try await fixture(#function) { f in
      let view = f.view, source = f.session!, commands = f.commands!, window = f.window!
      let context = try XCTUnwrap(view.inputContext)
      let priorSource = try XCTUnwrap(context.selectedKeyboardInputSource)
      guard context.keyboardInputSources?.contains("com.apple.keylayout.US") == true else {
        throw BoomError.unavailable("This actual dead-key control requires the native U.S. input source.")
      }
      // Fixture setup chooses an actual native layout; production never guesses
      // admission from a source-name prefix or charactersIgnoringModifiers.
      context.selectedKeyboardInputSource = "com.apple.keylayout.US"
      defer { context.selectedKeyboardInputSource = priorSource }
      XCTAssertEqual(context.selectedKeyboardInputSource, "com.apple.keylayout.US")
      let reference = NSTextView(frame: NSRect(x: 0, y: 240, width: 300, height: 70))
      window.contentView!.addSubview(reference)
      defer { reference.removeFromSuperview() }
      XCTAssertTrue(window.makeFirstResponder(reference))
      reference.inputContext?.selectedKeyboardInputSource = "com.apple.keylayout.US"
      let dead = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
      let continuation = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
      window.sendEvent(dead); window.sendEvent(continuation)
      let nativeResult = reference.string
      XCTAssertEqual(nativeResult, "é", "The real native reference must actually exercise a dead-key continuation.")
      XCTAssertFalse(reference.hasMarkedText())
      XCTAssertTrue(window.makeFirstResponder(view))
      XCTAssertEqual(context.selectedKeyboardInputSource, "com.apple.keylayout.US")
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 48_000, caret: 50_000)
      try await f.route!.awaitHeld(hold)
      window.sendEvent(dead)
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(source.generation, 0)
      XCTAssertFalse(view.hasMarkedText()); XCTAssertTrue(view.inputContext === context)
      try await f.route!.release(hold); _ = try await loading.value
      XCTAssertEqual(commands.queuedRawKeyCount, 0); XCTAssertTrue(view.inputContext === context)
      // The real context has now interpreted the dead key exactly once. If it
      // emits no marked callback, a second arena rotation must preserve opaque
      // state. If it marks text, the actual composition pin must forbid rotation.
      if !view.hasMarkedText() {
        let before = source.generation
        _ = try await f.startNavigation(anchor: 49_000, caret: nil).value
        XCTAssertEqual(source.generation, before); XCTAssertTrue(view.inputContext === context)
      } else {
        XCTAssertTrue(source.isPinned)
        let pinnedNavigation = try f.startNavigation(anchor: 49_000, caret: nil)
        do {
          _ = try await pinnedNavigation.value
          XCTFail("Actual marked text must keep its native arena pinned.")
        } catch {
          guard case BoomError.stale = error else { throw error }
          f.preserve(error)
        }
        XCTAssertTrue(view.inputContext === context)
      }
      window.sendEvent(continuation)
      try await commands.joinPendingCommand()
      var expected = f.originalText
      expected.insert(contentsOf: nativeResult, at: expected.index(expected.startIndex, offsetBy: 50_000))
      try await f.assertSource(expected)
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0); XCTAssertNil(commands.firstFailure)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
    }
  }


  // SDK protocol/range control over the genuine backend and native primitive;
  // this is not a claim that a physical input method produced the late callback.
  func testActualReportedContextAnchorMapsNativeSpliceBeforeUnfocusedContinuationWithoutUsingLatestCaret() async throws {
    try await fixture(#function) { f in
      let view = f.view, source = f.session!, input = f.input!, commands = f.commands!, window = f.window!
      let context = try XCTUnwrap(view.inputContext), client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      view.setSelectedRange(NSRange(location: 8, length: 0))
      client.withNativeEvent {
        XCTAssertEqual(client.selectedRange(), NSRange(location: 8, length: 0))
        // No insertion, marked text or command completed this reported range.
      }
      XCTAssertTrue(client.needsSpliceObservation)
      view.setSelectedRange(NSRange(location: 2, length: 0))
      view.insertText("🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertEqual(source.generation, 1)
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, 4)
      XCTAssertEqual(client.selectedRange(), NSRange(location: 10, length: 0))
      let other = NSTextView(frame: NSRect(x: 0, y: 240, width: 300, height: 70))
      other.string = "Unchanged"; window.contentView!.addSubview(other)
      XCTAssertTrue(window.makeFirstResponder(other))
      // The SAME document context, not a new foreign key, completes its
      // earlier globally reported range after a genuine source generation.
      client.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await commands.joinPendingCommand()
      XCTAssertTrue(window.firstResponder === other); XCTAssertEqual(other.string, "Unchanged")
      XCTAssertEqual(source.generation, 2); XCTAssertFalse(client.needsSpliceObservation)
      let expected = (f.originalText as NSString).replacingCharacters(in: NSRange(location: 2, length: 0), with: "🙂") as NSString
      try await f.assertSource(expected.replacingCharacters(in: NSRange(location: 10, length: 0), with: "é"))
      XCTAssertEqual(commands.retainedRefusedInputCount, 0); XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      XCTAssertTrue(window.makeFirstResponder(view)); other.removeFromSuperview()
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand()
      try await f.assertSource((f.originalText as NSString).replacingCharacters(in: NSRange(location: 2, length: 0), with: "🙂"))
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
    }
  }

  func testActualDeadKeyFocusMoveMatchesNativeContextWhileEarlierAdmittedContinuationKeepsDocumentTarget() async throws {
    try await fixture(#function) { f in
      let view = f.view, source = f.session!, input = f.input!, commands = f.commands!, window = f.window!
      let context = try XCTUnwrap(view.inputContext), client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let priorSource = try XCTUnwrap(context.selectedKeyboardInputSource)
      guard context.keyboardInputSources?.contains("com.apple.keylayout.US") == true else {
        throw BoomError.unavailable("This native focus/dead-key control requires the actual U.S. input source.")
      }
      context.selectedKeyboardInputSource = "com.apple.keylayout.US"
      defer { context.selectedKeyboardInputSource = priorSource }
      let reference = NSTextView(frame: NSRect(x: 0, y: 240, width: 140, height: 70))
      let other = NSTextView(frame: NSRect(x: 160, y: 240, width: 140, height: 70))
      other.string = "Other"; window.contentView!.addSubview(reference); window.contentView!.addSubview(other)
      defer { reference.removeFromSuperview(); other.removeFromSuperview() }
      XCTAssertTrue(window.makeFirstResponder(reference))
      let referenceContext = try XCTUnwrap(reference.inputContext)
      referenceContext.selectedKeyboardInputSource = "com.apple.keylayout.US"
      let dead = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
      let continuation = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
      reference.keyDown(with: dead)
      XCTAssertTrue(window.makeFirstResponder(other))
      // The ordinary native reference decides whether losing focus commits,
      // cancels or preserves conversion. No app-invented cancellation rule.
      if !referenceContext.handleEvent(continuation) { reference.keyDown(with: continuation) }
      let nativeResult = reference.string
      XCTAssertFalse(nativeResult.isEmpty)
      XCTAssertEqual(other.string, "Other"); XCTAssertTrue(window.firstResponder === other)
      XCTAssertTrue(window.makeFirstResponder(view))
      let hold = try await f.route!.holdNext(.windowAfter)
      let loading = try f.startNavigation(anchor: 48_000, caret: 50_000)
      try await f.route!.awaitHeld(hold)
      window.sendEvent(dead); window.sendEvent(continuation)
      XCTAssertEqual(commands.queuedRawKeyCount, 2); XCTAssertEqual(source.generation, 0)
      var movedFocus = false
      let previousEdit = input.onNativeEdit, previousSelection = input.onNativeSelection
      let afterDead: @MainActor (PagedNativeStateObservation) -> Void = { _ in
        guard !movedFocus, client.isInterpretingNativeEvent else { return }
        movedFocus = true
        XCTAssertTrue(window.makeFirstResponder(other))
      }
      input.onNativeEdit = { observation in previousEdit?(observation); afterDead(observation) }
      input.onNativeSelection = { observation in previousSelection?(observation); afterDead(observation) }
      defer { input.onNativeEdit = previousEdit; input.onNativeSelection = previousSelection }
      try await f.route!.release(hold); _ = try await loading.value
      try await commands.joinPendingCommand()
      XCTAssertTrue(movedFocus); XCTAssertTrue(window.firstResponder === other)
      XCTAssertEqual(other.string, "Other"); XCTAssertTrue(view.inputContext === context)
      XCTAssertFalse(client.isRetired); XCTAssertEqual(commands.queuedRawKeyCount, 0)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0); XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      var expected = f.originalText
      expected.insert(contentsOf: nativeResult, at: expected.index(expected.startIndex, offsetBy: 50_000))
      try await f.assertSource(expected)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      XCTAssertTrue(window.makeFirstResponder(view))
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
    }
  }


  func testActualDeferredMarkedPreviewSnapshotsMutableRunsBeforeOuterNativeScopeDeliversIt() async throws {
    try await fixture(#function) { f in
      let view = f.view, commands = f.commands!, source = f.session!
      let client = try XCTUnwrap(view.inputContext?.client as? PagedNativeTextInputClient)
      let probe = NativeContextCustodyProbe(), baseline = commands.retainedInputBytes
      view.setSelectedRange(NSRange(location: 0, length: 0))
      let observation = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification,
        object: view, queue: .main) { _ in
        MainActor.assumeIsolated {
          guard !probe.entered, !view.inputCommandIsClosed, source.generation == 1 else { return }
          probe.entered = true
          XCTAssertEqual(source.generation, 1, "The driver primitive is real, before its outer scope closes.")
          let all = NSRange(location: 0, length: Int(source.logicalWindow.snapshot.summary.utf16))
          client.setMarkedText(probe.marked, selectedRange: NSRange(location: 2, length: 0), replacementRange: all)
          probe.chargedBytes = commands.retainedInputBytes - baseline
          XCTAssertGreaterThan(probe.chargedBytes, probe.marked.string.utf8.count + 512)
          XCTAssertFalse(view.hasMarkedText(), "The nonresident preview is deferred until this actual outer input scope closes.")
          XCTAssertFalse(view.inputCommandIsClosed)
          // Mutation AFTER callback return must not affect the stored preview.
          probe.directions.add(NSNumber(value: 7))
          probe.marked.replaceCharacters(in: NSRange(location: 0, length: 2), with: "改変")
          probe.marked.setAttributes([.markedClauseSegment: NSNumber(value: 99)], range: NSRange(location: 0, length: 2))
        }
      }
      defer { NotificationCenter.default.removeObserver(observation) }
      view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(probe.entered, "This control requires an actual synchronous native selection notification inside the outer input scope.")
      XCTAssertTrue(view.hasMarkedText()); XCTAssertTrue(source.isPinned)
      XCTAssertEqual(commands.retainedInputBytes, baseline, "The stored preview is drained, not left in refused/final custody.")
      XCTAssertEqual(commands.queuedNativeContinuationCount, 0); XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertEqual(view.string, "候補", "The caller's later string/run mutation cannot retarget the captured preview.")
      let actual = view.markedRange()
      XCTAssertEqual(actual, NSRange(location: 0, length: 2))
      let attributes = try XCTUnwrap(view.textStorage).attributes(at: actual.location, effectiveRange: nil)
      XCTAssertEqual((attributes[.markedClauseSegment] as? NSNumber)?.intValue, 3)
      XCTAssertEqual((attributes[.writingDirection] as? [NSNumber])?.map(\.intValue), [0, 2])
      client.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await commands.joinPendingCommand(); try await f.assertSource("文")
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource("z" + f.originalText)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualFinalCallbackSupersedesOnlyItsDeferredPreviewBeforeOuterNativeScopeCloses() async throws {
    try await fixture(#function) { f in
      let view = f.view, commands = f.commands!, source = f.session!
      let client = try XCTUnwrap(view.inputContext?.client as? PagedNativeTextInputClient)
      let probe = NativeContextCustodyProbe(), baseline = commands.retainedInputBytes
      view.setSelectedRange(NSRange(location: 0, length: 0))
      let observation = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification,
        object: view, queue: .main) { _ in
        MainActor.assumeIsolated {
          guard !probe.entered, !view.inputCommandIsClosed, source.generation == 1 else { return }
          probe.entered = true
          let all = NSRange(location: 0, length: Int(source.logicalWindow.snapshot.summary.utf16))
          client.setMarkedText(probe.marked, selectedRange: NSRange(location: 2, length: 0), replacementRange: all)
          XCTAssertGreaterThan(commands.retainedInputBytes, baseline)
          client.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
          XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(view.inputCommandIsClosed)
          probe.marked.replaceCharacters(in: NSRange(location: 0, length: 2), with: "改変")
        }
      }
      defer { NotificationCenter.default.removeObserver(observation) }
      view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(probe.entered)
      try await commands.joinPendingCommand()
      XCTAssertEqual(commands.retainedInputBytes, baseline); XCTAssertEqual(commands.queuedNativeContinuationCount, 0)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      try await f.assertSource("文")
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource("z" + f.originalText)
      XCTAssertNil(f.input!.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualAdoptingFinalCallbacksKeepOriginalTargetMutableSnapshotAndJoinBeforeClose() async throws {
    try await fixture(#function) { f in
      let view = f.view, input = f.input!, source = f.session!, commands = f.commands!, window = f.window!
      let context = try XCTUnwrap(view.inputContext), client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let originalMount = try XCTUnwrap(commands.mountView)
      let probe = NativeContextCustodyProbe(), baseline = commands.retainedInputBytes
      let final = NSMutableAttributedString(string: "X", attributes: [.markedClauseSegment: NSNumber(value: 3)])
      view.setSelectedRange(NSRange(location: 8, length: 0))
      client.withNativeEvent { XCTAssertEqual(client.selectedRange(), NSRange(location: 8, length: 0)) }
      commands.mountView = { old, new in
        try originalMount(old, new)
        guard !probe.entered else { return }
        probe.entered = true
        XCTAssertTrue(input.isAdopting); XCTAssertTrue(context === new.inputContext)
        client.insertText(final, replacementRange: NSRange(location: NSNotFound, length: 0))
        client.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commands.queuedNativeContinuationCount, 2)
        XCTAssertEqual(commands.retainedRefusedInputCount, 0)
        XCTAssertGreaterThan(commands.retainedInputBytes, baseline)
        final.replaceCharacters(in: NSRange(location: 0, length: 1), with: "WRONG")
      }
      let navigation = try f.startNavigation()
      _ = try await navigation.value
      XCTAssertTrue(probe.entered)
      let other = NSTextField(frame: NSRect(x: 0, y: 280, width: 200, height: 24))
      window.contentView!.addSubview(other)
      XCTAssertTrue(window.makeFirstResponder(other))
      let actualResponder = window.firstResponder
      try await commands.joinPendingCommand()
      XCTAssertTrue(window.firstResponder === actualResponder, "Completing admitted native text must not take focus back.")
      XCTAssertEqual(commands.queuedNativeContinuationCount, 0)
      XCTAssertEqual(commands.retainedInputBytes, baseline); XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      let expected = (f.originalText as NSString).replacingCharacters(in: NSRange(location: 8, length: 0), with: "XY")
      try await f.assertSource(expected)
      XCTAssertEqual(source.generation, 2)
      try await PagedNativeFixtureApplication.focus(f.view, in: window)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand()
      try await f.assertSource((f.originalText as NSString).replacingCharacters(in: NSRange(location: 8, length: 0), with: "X"))
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      // The fixture's actual close joins this same queue/tasks, retires the
      // document context, detaches Backend, closes Engine and releases flock.
    }
  }

  func testNativeContextAttributePayloadRejectsOpaqueBackingAndSnapshotsSupportedMutableRuns() throws {
    let opaque = NSMutableData(length: PagedNativeUndoOwner.maximumRawKeyBytes + 1)!
    let invalid = NSAttributedString(string: "字", attributes: [.underlineColor: opaque])
    XCTAssertThrowsError(try PagedNativeContextPayload(invalid)) { error in
      guard case BoomError.invalid = error else { return XCTFail("Expected unsupported color-value refusal, got \(error)") }
    }
    let directions = NSMutableArray(array: [NSNumber(value: 0), NSNumber(value: 2)])
    let input = NSMutableAttributedString(string: "候補", attributes: [
      .markedClauseSegment: NSNumber(value: 3), .underlineStyle: NSNumber(value: NSUnderlineStyle.double.rawValue),
      .underlineColor: NSColor.red, .writingDirection: directions,
    ])
    let snapshot = try PagedNativeContextPayload(input)
    XCTAssertGreaterThan(snapshot.chargedBytes, snapshot.text.utf8.count + 512)
    XCTAssertLessThanOrEqual(snapshot.chargedBytes, PagedNativeUndoOwner.maximumRawKeyBytes)
    directions.add(NSNumber(value: 7))
    input.setAttributes([.markedClauseSegment: NSNumber(value: 99)], range: NSRange(location: 0, length: 2))
    let output = try XCTUnwrap(try snapshot.materialize() as? NSAttributedString)
    XCTAssertEqual(output.string, "候補")
    XCTAssertEqual((output.attribute(.markedClauseSegment, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 3)
    XCTAssertEqual((output.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? NSNumber)?.intValue,
      NSUnderlineStyle.double.rawValue)
    XCTAssertEqual((output.attribute(.writingDirection, at: 0, effectiveRange: nil) as? [NSNumber])?.map(\.intValue), [0, 2])
    let excessiveRuns = NSMutableAttributedString(string: String(repeating: "a", count: 65))
    for at in 0..<65 {
      excessiveRuns.addAttribute(.markedClauseSegment, value: NSNumber(value: at), range: NSRange(location: at, length: 1))
    }
    XCTAssertThrowsError(try PagedNativeContextPayload(excessiveRuns))
  }

  func testActualRejectedContextCallbacksKeepOriginalAnchorForLaterValidInsertionAndResponderUndo() async throws {
    try await fixture(#function) { f in
      let view = f.view, input = f.input!, source = f.session!, commands = f.commands!
      let client = try XCTUnwrap(view.inputContext?.client as? PagedNativeTextInputClient)
      view.setSelectedRange(NSRange(location: 8, length: 0))
      client.withNativeEvent { XCTAssertEqual(client.selectedRange(), NSRange(location: 8, length: 0)) }
      view.setSelectedRange(NSRange(location: 2, length: 0))
      view.insertText("🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertEqual(source.generation, 1)
      XCTAssertEqual(client.selectedRange(), NSRange(location: 10, length: 0))
      let bytesBefore = commands.retainedInputBytes
      // The pure custody control above covers opaque attributes. Ordinary
      // resident callbacks retain the original native AppKit attribute path.
      XCTAssertEqual(commands.retainedInputBytes, bytesBefore)
      // Actual scalar refusal used to clear pendingSelection before validation.
      let previous = view.didRejectInput
      var rejected: Error?
      view.didRejectInput = { error in rejected = error; previous?(error) }
      defer { view.didRejectInput = previous }
      client.setMarkedText("🙂", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertEqual(source.generation, 1); XCTAssertTrue(client.needsSpliceObservation)
      XCTAssertEqual(client.selectedRange(), NSRange(location: 10, length: 0)); XCTAssertFalse(view.hasMarkedText())
      guard case BoomError.invalid = try XCTUnwrap(rejected) else { return XCTFail("Expected the actual malformed marked-scalar refusal.") }
      XCTAssertEqual(commands.retainedRefusedInputCount, 0, "Malformed protocol metadata never enters admitted final-input custody.")
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      client.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await commands.joinPendingCommand()
      XCTAssertEqual(source.generation, 2); XCTAssertFalse(client.needsSpliceObservation)
      let edited = (f.originalText as NSString).replacingCharacters(in: NSRange(location: 2, length: 0), with: "🙂")
      try await f.assertSource((edited as NSString).replacingCharacters(in: NSRange(location: 10, length: 0), with: "é"))
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(edited)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualDeadKeyResponderUndoAndContinuationMatchOrdinaryNativeContextLifecycle() async throws {
    try await fixture(#function, text: "abc") { f in
      let view = f.view, window = f.window!, commands = f.commands!, source = f.session!
      let context = try XCTUnwrap(view.inputContext), client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let originalSource = try XCTUnwrap(context.selectedKeyboardInputSource)
      guard context.keyboardInputSources?.contains("com.apple.keylayout.US") == true else {
        throw BoomError.unavailable("The actual native Undo/dead-key reference requires the U.S. input source.")
      }
      context.selectedKeyboardInputSource = "com.apple.keylayout.US"
      defer { context.selectedKeyboardInputSource = originalSource }
      let reference = NativeContextReferenceTextView(frame: NSRect(x: 0, y: 240, width: 300, height: 70))
      reference.isRichText = false; reference.allowsUndo = true; reference.string = "abc"
      window.contentView!.addSubview(reference)
      defer { reference.removeFromSuperview() }
      XCTAssertTrue(window.makeFirstResponder(reference))
      let referenceContext = try XCTUnwrap(reference.inputContext)
      referenceContext.selectedKeyboardInputSource = "com.apple.keylayout.US"
      reference.setSelectedRange(NSRange(location: 1, length: 0))
      reference.referenceUndo.beginUndoGrouping()
      reference.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      reference.breakUndoCoalescing(); reference.referenceUndo.endUndoGrouping()
      XCTAssertEqual(reference.string, "aXbc"); XCTAssertTrue(reference.referenceUndo.canUndo)
      let dead = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
      let continuation = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
      window.sendEvent(dead)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      let nativeAfterUndo = reference.string, nativeMarkedAfterUndo = reference.hasMarkedText()
      let nativeSelectionAfterUndo = reference.selectedRange()
      window.sendEvent(continuation)
      let nativeResult = reference.string, nativeFinalSelection = reference.selectedRange()
      XCTAssertFalse(reference.hasMarkedText())
      XCTAssertTrue(window.makeFirstResponder(view))
      view.setSelectedRange(NSRange(location: 1, length: 0))
      view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await commands.joinPendingCommand(); try await f.assertSource("aXbc")
      window.sendEvent(dead)
      XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      XCTAssertEqual(view.string, nativeAfterUndo); XCTAssertEqual(view.hasMarkedText(), nativeMarkedAfterUndo)
      XCTAssertEqual(view.selectedRange(), nativeSelectionAfterUndo)
      window.sendEvent(continuation)
      try await commands.joinPendingCommand(); try await f.assertSource(nativeResult)
      XCTAssertEqual(view.selectedRange(), nativeFinalSelection)
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(source.isPinned)
      XCTAssertTrue(view.inputContext === context); XCTAssertFalse(client.isRetired)
      XCTAssertEqual(commands.retainedRefusedInputCount, 0)
      XCTAssertNil(f.input?.firstRefusal); XCTAssertNil(commands.firstFailure)
    }
  }

  func testActualFreshArrowHomeEndAndSelectAllThenTypingMatchOrdinaryNativeContextWithoutOldAnchor() async throws {
    try await fixture(#function, text: "abcd\nsecond") { f in
      let view = f.view, commands = f.commands!, window = f.window!
      let client = try XCTUnwrap(view.inputContext?.client as? PagedNativeTextInputClient)
      let reference = NativeContextReferenceTextView(frame: NSRect(x: 0, y: 230, width: 600, height: 80))
      reference.isRichText = false; reference.font = view.font; reference.textContainerInset = view.textContainerInset
      window.contentView!.addSubview(reference)
      defer { reference.removeFromSuperview() }
      let cases: [(String, UInt16, String, NSEvent.ModifierFlags)] = [
        ("Left", 123, "\u{F702}", .function),
        ("Right", 124, "\u{F703}", .function),
        ("Home", 115, "\u{F729}", .function),
        ("End", 119, "\u{F72B}", .function),
        ("SelectAll", 0, "a", .command),
      ]
      for (label, code, characters, flags) in cases {
        reference.string = f.originalText
        reference.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(window.makeFirstResponder(reference))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
          characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        let typed = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
          characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        let commandCount = reference.interpretedCommands.count
        reference.keyDown(with: event)
        let nativeSelection = reference.selectedRange()
        if label == "SelectAll" { XCTAssertEqual(nativeSelection, NSRange(location: 0, length: f.originalText.utf16.count)) }
        else { XCTAssertGreaterThan(reference.interpretedCommands.count, commandCount, "The ordinary reference must actually interpret \(label).") }
        if label == "Left" { XCTAssertEqual(nativeSelection.location, 2) }
        if label == "Right" { XCTAssertEqual(nativeSelection.location, 4) }
        reference.keyDown(with: typed)
        let nativeResult = reference.string
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(client.needsSpliceObservation)
        view.keyDown(with: event)
        try await commands.joinPendingCommand()
        XCTAssertEqual(view.selectedRange(), nativeSelection, label)
        XCTAssertFalse(client.needsSpliceObservation, "A fresh completed selector must not retain its pre-command caret: \(label)")
        view.keyDown(with: typed)
        try await commands.joinPendingCommand(); try await f.assertSource(nativeResult)
        XCTAssertEqual(commands.retainedRefusedInputCount, 0)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
        try await commands.joinPendingCommand(); try await f.assertSource(f.originalText)
        XCTAssertNil(f.input?.firstRefusal); XCTAssertNil(commands.firstFailure)
      }
    }
  }
}
