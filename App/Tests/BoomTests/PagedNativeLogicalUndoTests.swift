import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

private struct LogicalUndoCleanupFailure: Error {
  let original: Error
  let cleanup: Error
}

@MainActor private final class LogicalUndoDuringCharacters: NSObject, NSTextStorageDelegate {
  weak var view: PagedNativeTextView?
  private(set) var delivered = false
  init(view: PagedNativeTextView) { self.view = view }
  func textStorage(_ textStorage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
    range: NSRange, changeInLength: Int) {
    guard mask.contains(.editedCharacters), !delivered else { return }
    delivered = true
    view?.doCommand(by: NSSelectorFromString("undo:"))
  }
}

/// Delivery gates retain only actual values returned by the real file
/// backend. They create no source, ACK, snapshot, root lease or SDK action.
private actor LogicalUndoDelivery: PagedNativeLogicalSessionStorage {
  nonisolated let engineIncarnation: UUID
  private let backend: PagedNativeStorageBackend
  private var readSignal: (@MainActor @Sendable () -> Void)?
  private var publicationSignal: (@MainActor @Sendable () -> Void)?
  private var readWaiter: CheckedContinuation<Void, Never>?
  private var publicationWaiter: CheckedContinuation<Void, Never>?
  private var readReleased = false
  private var publicationReleased = false
  private(set) var readReturns = 0
  private(set) var publicationReturns = 0
  init(_ backend: PagedNativeStorageBackend) {
    self.backend = backend; engineIncarnation = backend.engineIncarnation
  }
  func holdRead(_ signal: @escaping @MainActor @Sendable () -> Void) {
    precondition(readSignal == nil && readWaiter == nil)
    readReleased = false; readSignal = signal
  }
  func holdPublication(_ signal: @escaping @MainActor @Sendable () -> Void) {
    precondition(publicationSignal == nil && publicationWaiter == nil)
    publicationReleased = false; publicationSignal = signal
  }
  func release() {
    readReleased = true; publicationReleased = true
    readWaiter?.resume(); readWaiter = nil
    publicationWaiter?.resume(); publicationWaiter = nil
  }
  func logicalWindow(_ snapshot: PagedNativeLogicalSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int, cancellation: CancellationFlag) async throws -> PagedNativeLogicalWindow {
    let result = try await backend.logicalWindow(snapshot, utf16Anchor: utf16Anchor,
      maximumBytes: maximumBytes, cancellation: cancellation)
    readReturns += 1
    if let signal = readSignal {
      readSignal = nil; await signal()
      if !readReleased { await withCheckedContinuation { readWaiter = $0 } }
    }
    return result
  }
  func logicalPosition(_ snapshot: PagedNativeLogicalSnapshot, utf16Offset: UInt64,
    rounding: UInt8, cancellation: CancellationFlag) async throws -> PagedTextSummary {
    try await backend.logicalPosition(snapshot, utf16Offset: utf16Offset,
      rounding: rounding, cancellation: cancellation)
  }
  func logicalReplacement(_ snapshot: PagedNativeLogicalSnapshot,
    selection: PagedNativeNavigationSelection, replacement: Data,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalEdit {
    try await backend.logicalReplacement(snapshot, selection: selection,
      replacement: replacement, cancellation: cancellation)
  }
  func logicalCommand(_ snapshot: PagedNativeLogicalSnapshot, command: PagedNativeLogicalCommand,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalCommandResult {
    try await backend.logicalCommand(snapshot, command: command, cancellation: cancellation)
  }
  nonisolated func prepareImportedSourceTransfer(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    sessionID: UUID) throws -> () -> Void {
    try backend.prepareImportedSourceTransfer(imported, sessionID: sessionID)
  }
  func publishLogical(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    let result = try await backend.publishLogical(publication)
    publicationReturns += 1
    if let signal = publicationSignal {
      publicationSignal = nil; await signal()
      if !publicationReleased { await withCheckedContinuation { publicationWaiter = $0 } }
    }
    return result
  }
  func finishLogicalPublication(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    try await backend.finishLogicalPublication(acknowledgement)
  }
  func resumeLogicalPublication(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    try await backend.resumeLogicalPublication(publication)
  }
}

@MainActor private final class LogicalUndoFixture {
  let root: URL
  let store: WorkspaceStore
  var engine: PagedTextEngineAdapter?
  var publisher: PagedWorkspacePublisher?
  var backend: PagedNativeStorageBackend?
  var route: LogicalUndoDelivery?
  var session: PagedNativeSession?
  var input: PagedNativeInputOwner?
  var commands: PagedNativeUndoOwner?
  var sourceFile: FileHandle?
  let window: NSWindow
  let scroll: NSScrollView
  init(root: URL, store: WorkspaceStore) {
    self.root = root; self.store = store
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    scroll = NSScrollView(frame: window.contentView!.bounds)
    window.contentView = scroll
  }
  var view: PagedNativeTextView { input!.activeView! }
  func install(_ record: PagedDocumentRootRecord) async throws {
    let backend = try await engine!.makeNativeStorage(publisher!, expected: record)
    self.backend = backend
    let opening = try await backend.opening(sessionID: UUID())
    let route = LogicalUndoDelivery(backend); self.route = route
    let session = try PagedNativeSession(opening: opening, storage: route); self.session = session
    let input = try PagedNativeInputOwner(frame: scroll.bounds, session: session); self.input = input
    let commands = try PagedNativeUndoOwner(input: input); self.commands = commands
    commands.mountView = { [weak self] old, new in
      guard let self, self.scroll.documentView === old else {
        throw BoomError.stale("The real logical fixture lost its physical receiving view.")
      }
      self.scroll.documentView = new
      guard self.window.makeFirstResponder(new), self.window.firstResponder === new else {
        throw BoomError.unavailable("The real logical fixture mount did not retain focus.")
      }
    }
    scroll.documentView = view
    try await focus()
  }
  func focus() async throws {
    let becameKey = window.isKeyWindow ? nil : XCTNSNotificationExpectation(
      name: NSWindow.didBecomeKeyNotification, object: window)
    window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    if let becameKey {
      guard await XCTWaiter.fulfillment(of: [becameKey], timeout: 10) == .completed else {
        throw BoomError.unavailable("The public logical fixture did not receive its actual key-window notification.")
      }
    }
    try Task.checkCancellation()
    guard view.window === window, window.isKeyWindow,
      window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.unavailable("The public logical fixture has no actual editable native focus.")
    }
  }
  func detach() async throws -> PagedDocumentRootRecord {
    let session = session!, commands = commands!, backend = backend!
    let record = try await session.flushRecord(through: session.generation)
    try await commands.joinPendingCommand()
    try commands.closeInput()
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: session.sealedGeneration, record: record)
    scroll.documentView = nil
    self.commands = nil; input = nil; self.session = nil; route = nil; self.backend = nil
    return record
  }
  func close() async throws {
    _ = try await detach()
    try await engine!.close(); engine = nil; publisher = nil
    try await store.releaseExclusiveWorkspace()
    window.orderOut(nil); window.close()
  }
}

/// Actual file-backed source, native responder action, Foundation inverse,
/// reader/publication join and cleanup. These controls are source-authored;
/// the normal native test owner must nominate and run them explicitly.
@MainActor final class PagedNativeLogicalUndoTests: XCTestCase {
  private static var retained: LogicalUndoFixture?
  private func fixture() async throws -> LogicalUndoFixture {
    guard Self.retained == nil else { throw BoomError.denied("A failed public logical fixture remains owned by this process.") }
    try PagedNativeFixtureApplication.bootstrap()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-logical-undo-" + UUID().uuidString)
    let store = try await Task.detached { try WorkspaceStore(rootOverride: root) }.value
    let f = LogicalUndoFixture(root: root, store: store); Self.retained = f
    try await store.acquireExclusiveWorkspace()
    let identity = try await store.storageIdentity()
    let engine = try await PagedTextEngineAdapter.create(root: root, ownerID: identity.ownerID, storeID: identity.storeID)
    f.engine = engine
    let publisher = try await engine.makeWorkspacePublisher(); f.publisher = publisher
    let source = root.appendingPathComponent("public.txt")
    try await Task.detached { try Data("abc".utf8).write(to: source, options: .withoutOverwriting) }.value
    let file = try await Task.detached { try FileHandle(forReadingFrom: source) }.value
    f.sourceFile = file
    let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
    do { imported = try await engine.importUTF8Retaining(documentID: UUID(), from: file, expectedBytes: 3) }
    catch {
      let original = error
      do { try await Task.detached { try file.close() }.value; f.sourceFile = nil }
      catch { throw LogicalUndoCleanupFailure(original: original, cleanup: error) }
      throw original
    }
    do { try await Task.detached { try file.close() }.value }
    catch { throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
    f.sourceFile = nil
    let initialized = try await engine.initialNativeRecordRetaining(PagedDocumentDescriptor(
      id: imported.value.revision.documentID, title: "Public", revision: imported.value.revision))
    let record = try await engine.publishInitialDocumentRetaining(publisher, imported: imported, initialized: initialized)
    try await f.install(record)
    return f
  }
  private func run(_ body: @MainActor (LogicalUndoFixture) async throws -> Void) async throws {
    let failures = testRun?.failureCount ?? 0
    let f = try await fixture()
    do {
      try await body(f)
      await f.route?.release()
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("The actual logical control recorded an assertion failure.") }
      try await f.close()
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("The actual logical source close recorded a failure.") }
      Self.retained = nil
      try await Task.detached { try FileManager.default.removeItem(at: f.root) }.value
    } catch {
      await f.route?.release()
      do { try await f.commands?.joinPendingCommand() } catch { print("Actual logical read join retained at \(f.root.path): \(error)") }
      await f.session?.joinPendingSave()
      print("Failed public logical fixture preserved at \(f.root.path)")
      throw error
    }
  }
  func testResidentResponderUndoRedoIsSynchronousWhileActualSaveReplyIsHeld() async throws {
    try await run { f in
      let session = f.session!, input = f.input!, commands = f.commands!, route = f.route!
      let saved = expectation(description: "actual publication returned")
      await route.holdPublication { saved.fulfill() }
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 1, utf16Length: 0))
      f.view.insertText("X", replacementRange: f.view.selectedRange())
      XCTAssertEqual(session.generation, 1); XCTAssertEqual(f.view.string, "aXbc")
      guard await XCTWaiter.fulfillment(of: [saved], timeout: 10) == .completed else {
        throw BoomError.unavailable("The actual captured save did not return to its held delivery boundary.")
      }
      let manager = commands.manager, generation = session.generation
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      XCTAssertEqual(session.generation, generation + 1)
      XCTAssertEqual(f.view.string, "abc")
      XCTAssertEqual(commands.manager.undoCount, 0); XCTAssertEqual(commands.manager.redoCount, 1)
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
      XCTAssertEqual(session.generation, generation + 2); XCTAssertEqual(f.view.string, "aXbc")
      XCTAssertTrue(commands.manager === manager); XCTAssertNil(commands.firstFailure)
      let history = try commands.captureLogicalHistory()
      XCTAssertEqual(history.undo.count, 1)
      let live = try session.captureLogicalState(), arena = session.arenaID
      await route.release()
      _ = try await session.flushRecord(through: session.generation)
      XCTAssertEqual(session.arenaID, arena)
      XCTAssertTrue(try session.captureLogicalState().source.isSame(live.source))
      XCTAssertEqual(f.view.string, "aXbc")
    }
  }
  func testSelectionSupersedesColdUndoRetainsOriginalKeysAndLaterNativeTypingStaysLive() async throws {
    try await run { f in
      try f.input!.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 1, utf16Length: 0))
      f.view.insertText("X", replacementRange: f.view.selectedRange())
      let record = try await f.detach()
      try await f.install(record) // genuine file opening; persisted targets have no eager seeds
      let session = f.session!, input = f.input!, commands = f.commands!, route = f.route!
      let read = expectation(description: "actual cold logical read returned")
      await route.holdRead { read.fulfill() }
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      guard await XCTWaiter.fulfillment(of: [read], timeout: 10) == .completed else {
        throw BoomError.unavailable("The original cold Undo did not join its actual file read.")
      }
      let originalGeneration = session.generation
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber,
        context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
      f.view.keyDown(with: event)
      XCTAssertEqual(commands.queuedRawKeyCount, 1); XCTAssertEqual(session.generation, originalGeneration)
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 0, utf16Length: 0))
      commands.inputSelectionDidChange() // same confirmed ingress; redundant call is inert
      XCTAssertFalse(commands.hasPendingCommand)
      XCTAssertEqual(commands.queuedRawKeyCount, 0)
      XCTAssertEqual(commands.retainedRefusedInputCount, 2) // exact Undo request + original key
      XCTAssertNotNil(commands.refusedInputFailure)
      XCTAssertLessThanOrEqual(commands.retainedInputBytes, PagedNativeUndoOwner.maximumRawKeyBytes)
      f.view.insertText("Y", replacementRange: f.view.selectedRange())
      XCTAssertEqual(session.generation, originalGeneration + 1); XCTAssertEqual(f.view.string, "YaXbc")
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      await route.release()
      do { try await commands.joinPendingCommand(); XCTFail("Superseded cold read must report its original refusal once.") }
      catch {
        if error is CancellationError { }
        else if case BoomError.stale = error { }
        else { throw error }
      }
      XCTAssertEqual(f.view.string, "YaXbc"); XCTAssertFalse(f.view.string.contains("z"))
      f.view.insertText("Q", replacementRange: f.view.selectedRange())
      XCTAssertEqual(f.view.string, "YQaXbc")
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      XCTAssertNil(f.view.boundedStorage.mutationFailure)
      XCTAssertEqual(commands.retainedRefusedInputCount, 2)
      let actualReads = await route.readReturns
      XCTAssertEqual(actualReads, 1)
    }
  }

  func testFullDiagnosticCustodyDoesNotSwallowUnretainedKeyOrBlockResidentUndoWhileReadJoins() async throws {
    try await run { f in
      try f.input!.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 1, utf16Length: 0))
      f.view.insertText("X", replacementRange: f.view.selectedRange())
      let record = try await f.detach()
      try await f.install(record)
      let session = f.session!, input = f.input!, commands = f.commands!, route = f.route!
      let read = expectation(description: "actual cold read held before delivery")
      await route.holdRead { read.fulfill() }
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      guard await XCTWaiter.fulfillment(of: [read], timeout: 10) == .completed else {
        throw BoomError.unavailable("The full-custody control did not join its actual cold file read.")
      }
      for _ in 1..<PagedNativeUndoOwner.maximumQueuedCommands {
        XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      }
      let before = session.generation
      for _ in 0...PagedNativeUndoOwner.maximumQueuedRawKeys {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber,
          context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        f.view.keyDown(with: event)
        if commands.unretainedRawKeyCount > 0 { break }
      }
      XCTAssertEqual(commands.unretainedRawKeyCount, 1)
      XCTAssertEqual(session.generation, before + 1) // the unretained event went to actual native input once
      XCTAssertEqual(f.view.string, "aXzbc")
      XCTAssertEqual(commands.queuedRawKeyCount, 0)
      XCTAssertGreaterThan(commands.retainedRefusedInputCount, 500)
      XCTAssertLessThanOrEqual(commands.retainedRefusedInputCount, PagedNativeUndoOwner.maximumQueuedEntries)
      XCTAssertLessThanOrEqual(commands.retainedInputBytes, PagedNativeUndoOwner.maximumRawKeyBytes)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      // The canceled read has deliberately not been released or joined yet.
      // Resident Undo still enters and finishes its genuine SDK action now.
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      XCTAssertEqual(session.generation, before + 2); XCTAssertEqual(f.view.string, "aXbc")
      XCTAssertNil(commands.firstFailure)
      let duringCharacters = LogicalUndoDuringCharacters(view: f.view)
      f.view.boundedStorage.delegate = duringCharacters
      f.view.insertText("N", replacementRange: f.view.selectedRange())
      XCTAssertTrue(duringCharacters.delivered)
      XCTAssertEqual(session.generation, before + 4); XCTAssertEqual(f.view.string, "aXbc")
      // Its actual selector arrived inside character processing. It restored
      // only after that outer scope closed, despite full refused-history cap.
      f.view.insertText("Q", replacementRange: f.view.selectedRange())
      XCTAssertEqual(f.view.string, "aXQbc")
      await route.release()
      do { try await commands.joinPendingCommand(); XCTFail("The actual bounded custody refusal must remain reported.") }
      catch {
        if error is CancellationError { }
        else if case BoomError.stale = error { }
        else if case BoomError.budget = error { }
        else { throw error }
      }
      XCTAssertEqual(f.view.string, "aXQbc")
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      XCTAssertNil(f.view.boundedStorage.mutationFailure)
    }
  }
}
