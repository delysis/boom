import AppKit
import BoomCore
import Darwin
import Foundation
import XCTest
@testable import Boom

private struct LogicalUndoCleanupFailure: Error {
  let original: Error
  let cleanup: Error
}

/// A deliberately failed forwarding reply AFTER the real file backend has
/// committed and installed its original output. This is not an IO fault.
private struct LogicalSaveDeliveryFailure: Error, Equatable {
  let publicationID: UUID
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
  private var failingNextPublicationReply = false
  private(set) var readReturns = 0
  private(set) var publicationReturns = 0
  private(set) var resumeCalls = 0
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
  func failNextPublicationReply() throws {
    guard !failingNextPublicationReply else { throw BoomError.invalid("An actual publication reply already has its one-shot failure.") }
    failingNextPublicationReply = true
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
    let failReply = failingNextPublicationReply
    failingNextPublicationReply = false
    let result = try await backend.publishLogical(publication)
    publicationReturns += 1
    if let signal = publicationSignal {
      publicationSignal = nil; await signal()
      if !publicationReleased { await withCheckedContinuation { publicationWaiter = $0 } }
    }
    if failReply { throw LogicalSaveDeliveryFailure(publicationID: publication.publicationID) }
    return result
  }
  func finishLogicalPublication(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    try await backend.finishLogicalPublication(acknowledgement)
  }
  func resumeLogicalPublication(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    resumeCalls += 1
    return try await backend.resumeLogicalPublication(publication)
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
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "Bloom-logical-undo-")
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
  /// Real Backend publications and receiving, with an injected forwarding
  /// reply failure only. It exercises the explicit Session retry API; it does
  /// not qualify disk IO failure recovery or the packaged Save menu action.
  func testFailedActualPublicationReplyKeepsTypingAndResponderUndoLiveAndOnlyExactSaveIdentityCanRetry() async throws {
    try await run { f in
      let session = f.session!, input = f.input!, commands = f.commands!, route = f.route!
      let engine = f.engine!, originalRecord = session.sealedRootRecord
      try await route.failNextPublicationReply()
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 1, utf16Length: 0))
      f.view.insertText("X", replacementRange: f.view.selectedRange())
      let firstGeneration = session.generation
      do {
        _ = try await session.flushRecord(through: firstGeneration)
        XCTFail("The actual saver must expose its injected failed forwarding reply.")
      } catch { guard error is LogicalSaveDeliveryFailure else { throw error } }
      await session.joinPendingSave()
      let firstID = try XCTUnwrap(session.failedSaveIdentity)
      XCTAssertEqual(session.persistenceFailure as? LogicalSaveDeliveryFailure,
        LogicalSaveDeliveryFailure(publicationID: firstID))
      XCTAssertEqual(session.sealedRootRecord, originalRecord)
      XCTAssertEqual(session.sealedGeneration, 0)
      let firstReturns = await route.publicationReturns
      XCTAssertEqual(firstReturns, 1, "The failure is after an actual Backend publication, not a manufactured ACK")

      // Real native primitives and responder actions remain synchronous even
      // though the original save output has not reached Session receiving.
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 2, utf16Length: 0))
      f.view.insertText("Y", replacementRange: f.view.selectedRange())
      let typedGeneration = session.generation
      XCTAssertEqual(f.view.string, "aXYbc")
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
      XCTAssertEqual(session.generation, typedGeneration + 1); XCTAssertEqual(f.view.string, "aXbc")
      XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
      XCTAssertEqual(session.generation, typedGeneration + 2); XCTAssertEqual(f.view.string, "aXYbc")
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      XCTAssertNil(f.view.boundedStorage.mutationFailure)
      let later = try session.captureLogicalState(), arena = session.arenaID

      do {
        _ = try await session.retryFailedSave(expectedIdentity: UUID())
        XCTFail("An unrelated identity cannot receive or retry the original save.")
      } catch { guard case BoomError.stale = error else { throw error } }
      let unrelatedResumeCalls = await route.resumeCalls
      XCTAssertEqual(unrelatedResumeCalls, 0)
      XCTAssertEqual(session.failedSaveIdentity, firstID)
      XCTAssertEqual(session.persistenceFailure as? LogicalSaveDeliveryFailure,
        LogicalSaveDeliveryFailure(publicationID: firstID))

      // The next distinct publication is held only after its genuine file
      // output returns, then fails its reply. No timing sleep chooses a race.
      let nextReturned = expectation(description: "next actual captured publication returned")
      await route.holdPublication { nextReturned.fulfill() }
      try await route.failNextPublicationReply()
      let firstCheckpoint = try await session.retryFailedSave(expectedIdentity: firstID)
      XCTAssertEqual(session.sealedGeneration, firstGeneration)
      XCTAssertEqual(session.arenaID, arena)
      XCTAssertTrue(try session.captureLogicalState().source.isSame(later.source))
      XCTAssertEqual(f.view.string, "aXYbc"); XCTAssertNil(session.persistenceFailure)
      let firstDigest = try await engine.wholeTextSha256(firstCheckpoint.document.revision)
      XCTAssertEqual(firstDigest, Digest.sha256(Data("aXbc".utf8)))
      guard await XCTWaiter.fulfillment(of: [nextReturned], timeout: 10) == .completed else {
        throw BoomError.unavailable("The newer actual publication did not reach its controlled reply boundary.")
      }
      let heldGeneration = session.generation
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 3, utf16Length: 0))
      f.view.insertText("Z", replacementRange: f.view.selectedRange())
      let newest = try session.captureLogicalState(), newestArena = session.arenaID
      XCTAssertEqual(f.view.string, "aXYZbc"); XCTAssertEqual(newest.generation, heldGeneration + 1)
      await route.release()
      await session.joinPendingSave()
      let secondID = try XCTUnwrap(session.failedSaveIdentity)
      XCTAssertNotEqual(secondID, firstID)
      XCTAssertEqual(session.persistenceFailure as? LogicalSaveDeliveryFailure,
        LogicalSaveDeliveryFailure(publicationID: secondID))
      let resumesBeforeStaleRetry = await route.resumeCalls
      do {
        _ = try await session.retryFailedSave(expectedIdentity: firstID)
        XCTFail("A prior failed operation cannot authorize this newer failure's retry.")
      } catch { guard case BoomError.stale = error else { throw error } }
      let resumesAfterStaleRetry = await route.resumeCalls
      XCTAssertEqual(resumesAfterStaleRetry, resumesBeforeStaleRetry)
      XCTAssertEqual(session.failedSaveIdentity, secondID)
      XCTAssertEqual(session.persistenceFailure as? LogicalSaveDeliveryFailure,
        LogicalSaveDeliveryFailure(publicationID: secondID))

      let secondCheckpoint = try await session.retryFailedSave(expectedIdentity: secondID)
      XCTAssertEqual(session.arenaID, newestArena)
      XCTAssertTrue(try session.captureLogicalState().source.isSame(newest.source))
      XCTAssertEqual(session.generation, newest.generation); XCTAssertEqual(f.view.string, "aXYZbc")
      let secondDigest = try await engine.wholeTextSha256(secondCheckpoint.document.revision)
      XCTAssertEqual(secondDigest, Digest.sha256(Data("aXYbc".utf8)))
      let finalRecord = try await session.flushRecord(through: newest.generation)
      let finalDigest = try await engine.wholeTextSha256(finalRecord.document.revision)
      XCTAssertEqual(finalDigest, Digest.sha256(Data("aXYZbc".utf8)))
      XCTAssertNil(session.failedSaveIdentity); XCTAssertNil(session.persistenceFailure)
      XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
      XCTAssertNil(f.view.boundedStorage.mutationFailure)
      let finalResumeCalls = await route.resumeCalls
      XCTAssertEqual(finalResumeCalls, 2)
    }
  }
  /// Genuine FileStore per-call O_RDWR permission refusal before any append.
  /// No forwarding fault is armed; partial-write/fsync failure is not covered.
  func testActualPagesWriteOpenEACCESKeepsNativeUndoLiveAndExactBeforeRetryPreservesLaterHead() async throws {
    let failures = testRun?.failureCount ?? 0
    try await run { f in
      let session = f.session!, input = f.input!, commands = f.commands!, route = f.route!
      let engine = f.engine!, publisher = f.publisher!, before = session.sealedRootRecord
      // This is the actual FileStore path, not another store or source lane.
      let pagesURL = f.root.appendingPathComponent("documents", isDirectory: true)
        .appendingPathComponent(before.document.id.uuidString.lowercased(), isDirectory: true)
        .appendingPathComponent("pages")
      let descriptor = Darwin.open(pagesURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      var originalStatus: stat?
      var restricted = false
      var pagesClosed = false
      func admitPages() throws -> stat {
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard let original = originalStatus, actual.st_mode & S_IFMT == S_IFREG,
          actual.st_dev == original.st_dev, actual.st_ino == original.st_ino,
          actual.st_uid == original.st_uid, actual.st_uid == geteuid() else {
          throw BoomError.stale("The held public pages descriptor has another actual owner or inode.")
        }
        return actual
      }
      func restorePagesMode() throws {
        guard restricted, let original = originalStatus else { return }
        _ = try admitPages()
        guard fchmod(descriptor, original.st_mode & 0o7777) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let restored = try admitPages()
        guard restored.st_mode & 0o7777 == original.st_mode & 0o7777 else {
          throw BoomError.invalid("The actual public pages mode did not restore.")
        }
        restricted = false
      }
      do {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0, lstat(pagesURL.path, &named) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard geteuid() != 0, opened.st_uid == geteuid(), opened.st_mode & S_IFMT == S_IFREG,
          opened.st_mode & 0o7777 == 0o600, opened.st_size > 0,
          named.st_mode & S_IFMT == S_IFREG, named.st_dev == opened.st_dev,
          named.st_ino == opened.st_ino, named.st_uid == opened.st_uid,
          named.st_mode == opened.st_mode else {
          throw BoomError.denied("The genuine write-open control requires its own regular 0600 pages inode and unprivileged owner.")
        }
        originalStatus = opened
        restricted = true // restore even if the attempted chmod itself fails
        guard fchmod(descriptor, 0o400) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        XCTAssertEqual(try admitPages().st_mode & 0o7777, 0o400)
        try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 1, utf16Length: 0))
        f.view.insertText("X", replacementRange: f.view.selectedRange())
        let failedGeneration = session.generation
        var failed: PagedTextCustodyFailure?
        do {
          _ = try await session.flushRecord(through: failedGeneration)
          XCTFail("The actual FileStore O_RDWR must refuse the read-only pages inode.")
        } catch {
          guard let actual = error as? PagedTextCustodyFailure else { throw error }
          let posix = actual.original as NSError
          guard posix.domain == NSPOSIXErrorDomain, posix.code == Int(EACCES) else { throw error }
          failed = actual
        }
        await session.joinPendingSave()
        let originalFailure = try XCTUnwrap(failed), failedID = try XCTUnwrap(session.failedSaveIdentity)
        let retainedFailure = try XCTUnwrap(session.persistenceFailure as? PagedTextCustodyFailure)
        XCTAssertEqual(retainedFailure.lease, originalFailure.lease)
        XCTAssertEqual((retainedFailure.original as NSError).domain, NSPOSIXErrorDomain)
        XCTAssertEqual((retainedFailure.original as NSError).code, Int(EACCES))
        let joined = try XCTUnwrap(engine.custodySnapshot.items.first { $0.id == originalFailure.lease.id })
        XCTAssertEqual(joined.purpose, .nativeBatch(sessionID: session.sessionID, batchID: failedID,
          first: 1, last: failedGeneration))
        XCTAssertEqual(joined.phase, .unresolved); XCTAssertTrue(joined.producerJoined)
        XCTAssertTrue(joined.writesAttempted); XCTAssertFalse(joined.publicationAttempted)
        XCTAssertFalse(joined.bulkActive); XCTAssertEqual(engine.custodySnapshot.jobs, 0)
        XCTAssertEqual(try admitPages().st_size, opened.st_size)
        XCTAssertEqual(session.sealedRootRecord, before); XCTAssertEqual(session.sealedGeneration, 0)
        let beforeRead = try await engine.currentDocumentRecordRetaining(publisher, documentID: before.document.id)
        XCTAssertEqual(beforeRead.value, before, "Compare the actual complete disk head, not only Session's checkpoint")
        do { try await engine.abandonJoinedRootOutput(beforeRead.lease) }
        catch { throw PagedTextCustodyFailure(original: error, lease: beforeRead.lease) }
        let returnedBeforeRetry = await route.publicationReturns
        XCTAssertEqual(returnedBeforeRetry, 0, "The Backend threw the real write-open error before returning an ACK")

        try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 2, utf16Length: 0))
        f.view.insertText("Y", replacementRange: f.view.selectedRange())
        let typed = session.generation
        XCTAssertEqual(f.view.string, "aXYbc")
        XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil))
        XCTAssertEqual(session.generation, typed + 1); XCTAssertEqual(f.view.string, "aXbc")
        XCTAssertTrue(NSApplication.shared.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil))
        XCTAssertEqual(session.generation, typed + 2); XCTAssertEqual(f.view.string, "aXYbc")
        XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
        XCTAssertNil(f.view.boundedStorage.mutationFailure)
        let later = try session.captureLogicalState(), arena = session.arenaID
        do {
          _ = try await session.retryFailedSave(expectedIdentity: UUID())
          XCTFail("An unrelated identity cannot retry the real BEFORE failure.")
        } catch { guard case BoomError.stale = error else { throw error } }
        let refusedRetryCalls = await route.resumeCalls
        XCTAssertEqual(refusedRetryCalls, 0); XCTAssertEqual(session.failedSaveIdentity, failedID)
        XCTAssertEqual((session.persistenceFailure as? PagedTextCustodyFailure)?.lease, originalFailure.lease)

        try restorePagesMode() // same verified FD; no pathname replacement
        let checkpoint = try await session.retryFailedSave(expectedIdentity: failedID)
        XCTAssertEqual(session.arenaID, arena); XCTAssertEqual(session.generation, later.generation)
        XCTAssertTrue(try session.captureLogicalState().source.isSame(later.source))
        XCTAssertEqual(f.view.string, "aXYbc")
        let checkpointDigest = try await engine.wholeTextSha256(checkpoint.document.revision)
        XCTAssertEqual(checkpointDigest, Digest.sha256(Data("aXbc".utf8)))
        let final = try await session.flushRecord(through: later.generation)
        XCTAssertNil(session.failedSaveIdentity); XCTAssertNil(session.persistenceFailure)
        XCTAssertNil(commands.firstFailure); XCTAssertNil(input.firstRefusal)
        let expected = Data("aXYbc".utf8)
        let exportURL = f.root.appendingPathComponent("actual-write-open-retry-export.txt")
        try Data().write(to: exportURL, options: .withoutOverwriting)
        let writer = try FileHandle(forWritingTo: exportURL)
        do { try await engine.export(final.document.revision, to: writer); try writer.close() }
        catch {
          let original = error
          do { try writer.close() } catch { throw LogicalUndoCleanupFailure(original: original, cleanup: error) }
          throw original
        }
        XCTAssertEqual(try Data(contentsOf: exportURL), expected)
        XCTAssertEqual(try admitPages().st_mode & 0o7777, 0o600)
        try file.close(); pagesClosed = true
        guard (testRun?.failureCount ?? 0) == failures else {
          throw BoomError.invalid("The real write-open/receiving oracles failed; original owners and public source remain retained.")
        }

        // Close the actual first Engine before acquiring the singleton again.
        // This is a fresh file/backend opening, not a cached-window oracle.
        let detached = try await f.detach()
        XCTAssertEqual(detached, final)
        try await engine.close(); f.engine = nil; f.publisher = nil
        try await f.store.releaseExclusiveWorkspace()
        try await f.store.acquireExclusiveWorkspace()
        let identity = try await f.store.storageIdentity()
        let coldEngine = try await PagedTextEngineAdapter.create(root: f.root,
          ownerID: identity.ownerID, storeID: identity.storeID)
        f.engine = coldEngine
        let coldPublisher = try await coldEngine.makeWorkspacePublisher(); f.publisher = coldPublisher
        let coldRead = try await coldEngine.currentDocumentRecordRetaining(coldPublisher, documentID: final.document.id)
        let cold = coldRead.value
        do { try await coldEngine.abandonJoinedRootOutput(coldRead.lease) }
        catch { throw PagedTextCustodyFailure(original: error, lease: coldRead.lease) }
        XCTAssertEqual(cold, final)
        try await f.install(cold)
        XCTAssertEqual(f.view.string, "aXYbc"); XCTAssertEqual(f.session?.sealedRootRecord, final)
        XCTAssertEqual(try f.commands!.captureLogicalHistory().undo.count, 2)
      } catch {
        let original = error
        do {
          try restorePagesMode()
          if !pagesClosed { try file.close(); pagesClosed = true }
        }
        catch { throw LogicalUndoCleanupFailure(original: original, cleanup: error) }
        throw original
      }
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
