import AppKit
import BoomCore
import Foundation
import Synchronization
import XCTest
@testable import Boom

private final class ScrollWriterHold: @unchecked Sendable {
  let entered: XCTestExpectation
  private let releaseSignal = DispatchSemaphore(value: 0)
  private let held = Atomic(false)
  init(_ entered: XCTestExpectation) { self.entered = entered }
  func enter() {
    held.store(true, ordering: .relaxed); entered.fulfill()
    releaseSignal.wait(); held.store(false, ordering: .relaxed)
  }
  func release() { releaseSignal.signal() }
  var isHeld: Bool { held.load(ordering: .relaxed) }
}

private struct ScrollClickJoinFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? {
    "\(original.localizedDescription) Actual task join also failed: \(cleanup.localizedDescription)"
  }
}

@MainActor final class PagedNativeScrollProjectionTests: XCTestCase {
  private static var failedOutputs: PagedFileEngineControlOutputs?
  private static var nativeOwners: (PagedNativeSession, PagedNativeInputOwner,
    PagedNativeUndoOwner, PagedNativeLogicalControlStorage, PagedNativeStorageBackend, NSWindow)?

  private func fixture(_ body: (PagedFileEngineControlOutputs, PagedWorkspacePublisher) async throws -> Void) async throws {
    guard Self.failedOutputs == nil, Self.nativeOwners == nil else {
      throw BoomError.unavailable("The previous public scroll failure retains its actual owners.")
    }
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-file-scroll-")
    let store = try WorkspaceStore(rootOverride: root)
    try await store.acquireExclusiveWorkspace()
    let identity = try await store.storageIdentity()
    let engine = try await PagedTextEngineAdapter.create(root: store.root,
      ownerID: identity.ownerID, storeID: identity.storeID)
    let outputs = PagedFileEngineControlOutputs(engine: engine, store: store)
    let failures = testRun?.failureCount ?? 0
    do {
      let publisher = try await engine.makeWorkspacePublisher()
      try await body(outputs, publisher)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Public scroll assertions failed.") }
      try await outputs.close(); try FileManager.default.removeItem(at: store.root)
    } catch {
      var original = error
      Self.failedOutputs = outputs
      if let held = Self.nativeOwners {
        // Join the actual save/read delivery gates and native tasks without
        // retiring the failed physical owner or deleting its source files.
        await held.3.closeAndJoin()
        do { try await held.2.joinPendingCommand() } catch {
          original = ScrollClickJoinFailure(original: original, cleanup: error)
        }
        await held.0.joinPendingSave()
        if let saveFailure = held.0.persistenceFailure {
          original = ScrollClickJoinFailure(original: original, cleanup: saveFailure)
        }
        if let viewport = held.5.contentView as? PagedDocumentViewport {
          do { try await viewport.closePresentation() } catch {
            original = ScrollClickJoinFailure(original: original, cleanup: error)
          }
        }
      }
      print("Failed public scroll retained: \(store.root.path)")
      throw original
    }
  }

  /// Small public oracle only; this is never a production document read.
  /// The logical reader supplies context around the anchor, rather than the
  /// retired overlay's exact-start projection. Check the actual scalar origin
  /// and every returned byte against the complete bounded public oracle.
  private func assertProjection(_ result: PagedNativeLogicalWindow,
    snapshot: PagedNativeLogicalSnapshot, text: String, anchor: UInt64) throws {
    XCTAssertTrue(result.snapshot.isSame(snapshot))
    var units: UInt64 = 0, bytes = 0, lfs: UInt64 = 0
    for scalar in text.unicodeScalars {
      let count: UInt64 = scalar.value > 0xffff ? 2 : 1
      if units + count > result.start.utf16 { break }
      units += count; bytes += (scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4)
      if scalar.value == 10 { lfs += 1 }
    }
    XCTAssertEqual(result.start.utf16, units); XCTAssertEqual(result.start.bytes, UInt64(bytes))
    XCTAssertEqual(result.start.lfCount, lfs)
    let remaining = Data(text.utf8).dropFirst(bytes)
    XCTAssertEqual(Data(result.text.utf8), Data(remaining.prefix(result.text.utf8.count)))
    XCTAssertFalse(result.text.isEmpty && units < UInt64(text.utf16.count))
    XCTAssertEqual(result.snapshot.summary.bytes, UInt64(text.utf8.count))
    XCTAssertEqual(result.snapshot.summary.utf16, UInt64(text.utf16.count))
    XCTAssertEqual(result.snapshot.summary.lfCount, UInt64(text.unicodeScalars.filter { $0.value == 10 }.count))
    XCTAssertLessThanOrEqual(result.text.utf8.count, PagedWorkingWindow.targetBytes)
    XCTAssertLessThanOrEqual(result.start.utf16, anchor)
    XCTAssertLessThanOrEqual(anchor, result.start.utf16 + result.summary.utf16)
    XCTAssertEqual(result.summary.bytes, UInt64(result.text.utf8.count))
    XCTAssertEqual(result.summary.utf16, UInt64(result.text.utf16.count))
    let end = try result.position(localUTF16: result.text.utf16.count)
    XCTAssertEqual(end.bytes, result.start.bytes + result.summary.bytes)
    XCTAssertEqual(end.utf16, result.start.utf16 + result.summary.utf16)
  }

  func testActualImmutableScrollCompletesWhileWriterExecutorIsEnteredAndHeld() async throws {
    try await fixture { outputs, publisher in
      let text = String(repeating: "public é🙂\n", count: 4_000)
      let imported = try await outputs.imported(Data(text.utf8))
      let record = try await outputs.publish(imported, title: "Public held writer", publisher: publisher)
      let window = outputs.retain(try await outputs.engine.windowRetaining(record.document.revision,
        byteStart: 0, maximumBytes: PagedWorkingWindow.targetBytes))
      let source = try PagedNativeLogicalSource(revision: record.document.revision,
        sessionID: UUID(), engineIncarnation: outputs.engine.custodyIncarnation)
      _ = try source.openingWindow(window)
      let snapshot = try source.capture(forPublication: true)
      let gate = ScrollWriterHold(expectation(description: "actual writer executor entered"))
      let writer = Task { try await outputs.engine.storageExecutorForTesting.run { gate.enter() } }
      await fulfillment(of: [gate.entered], timeout: 5)
      let completed = expectation(description: "immutable file read returned before writer release")
      let read = Task {
        defer { completed.fulfill() }
        return try await outputs.engine.logicalWindow(snapshot, utf16Anchor: 24_003,
          maximumBytes: PagedWorkingWindow.targetBytes)
      }
      await fulfillment(of: [completed], timeout: 5)
      XCTAssertTrue(gate.isHeld, "This is an entered writer-body hold, not an actor preflight hold")
      // Join both actual tasks even if the reader timeout or writer exposed a
      // real failure. No failed root is closed while an entered task lives.
      gate.release()
      var failure: Error?, result: PagedNativeLogicalWindow?
      do { try await writer.value } catch { failure = error }
      do { result = try await read.value } catch {
        if let original = failure { failure = ScrollClickJoinFailure(original: original, cleanup: error) }
        else { failure = error }
      }
      if let failure { throw failure }
      try assertProjection(try XCTUnwrap(result), snapshot: snapshot, text: text, anchor: 24_003)
      XCTAssertEqual(snapshot.sourceRevision, record.document.revision)
      XCTAssertEqual(outputs.engine.custodySnapshot.jobs, 0)
    }
  }

  func testActualLogicalInsertionAndEmptyDeletionMapBeforeInsideAfterAndSurrogates() async throws {
    try await fixture { outputs, publisher in
      let prefix = String(repeating: "p", count: 400) + "\n"
      let island = "A🙂é\nBé🙂\n"
      let suffix = String(repeating: "tail🙂é\n", count: 5_000)
      let text = prefix + island + suffix
      let imported = try await outputs.imported(Data(text.utf8))
      let record = try await outputs.publish(imported, title: "Public Unicode logical source", publisher: publisher)
      let window = outputs.retain(try await outputs.engine.windowRetaining(record.document.revision,
        byteStart: UInt64(prefix.utf8.count), maximumBytes: island.utf8.count))
      XCTAssertEqual(Data(window.text.utf8), Data(island.utf8))
      let source = try PagedNativeLogicalSource(revision: record.document.revision,
        sessionID: UUID(), engineIncarnation: outputs.engine.custodyIncarnation)
      var working = try source.openingWindow(window)
      working = try source.replace(in: working, range: NSRange(location: 1, length: 2), with: "e\u{301}🙂\n").window
      let first = try source.capture(forPublication: true)
      let firstText = prefix + working.text + suffix
      working = try source.replace(in: working, range: NSRange(location: Int(working.summary.utf16), length: 0),
        with: "Ω🙂").window
      let replacement = working.text, expected = prefix + replacement + suffix
      let snapshot = try source.capture(forPublication: true)
      XCTAssertFalse(snapshot.isSame(first))
      // Older actual roots remain immutable after later local insertion.
      try assertProjection(try await outputs.engine.logicalWindow(first, utf16Anchor: 405,
        maximumBytes: PagedWorkingWindow.targetBytes), snapshot: first, text: firstText, anchor: 405)
      for anchor in [UInt64(0), 399, 400, 401, 404, 405,
        UInt64(prefix.utf16.count + replacement.utf16.count - 1),
        UInt64(prefix.utf16.count + replacement.utf16.count),
        UInt64(expected.utf16.count - 1), UInt64(expected.utf16.count)] {
        try assertProjection(try await outputs.engine.logicalWindow(snapshot, utf16Anchor: anchor,
          maximumBytes: PagedWorkingWindow.targetBytes), snapshot: snapshot, text: expected, anchor: anchor)
      }
      working = try source.replace(in: working, range: NSRange(location: 0, length: Int(working.summary.utf16)), with: "").window
      XCTAssertEqual(working.summary.bytes, 0)
      let deleted = try source.capture(forPublication: true), afterDelete = prefix + suffix
      for anchor in [UInt64(399), 400, 401, 402, 406, UInt64(afterDelete.utf16.count)] {
        try assertProjection(try await outputs.engine.logicalWindow(deleted, utf16Anchor: anchor,
          maximumBytes: PagedWorkingWindow.targetBytes), snapshot: deleted, text: afterDelete, anchor: anchor)
      }
      // The original file Revision is backing, never the dirty source digest.
      XCTAssertEqual(record.document.revision, deleted.sourceRevision)
      XCTAssertEqual(outputs.engine.custodySnapshot.jobs, 0)
    }
  }

  func testActualHeldNativeCommitAndIMEReadKeepLaterTypingAndSameGenerationACKSnapshot() async throws {
    try await fixture { outputs, publisher in
      let failuresBeforeNativeCase = testRun?.failureCount ?? 0
      try PagedNativeFixtureApplication.bootstrap()
      let text = "aé🙂\n" + String(repeating: "public tail🙂é\n", count: 3_000)
      let imported = try await outputs.imported(Data(text.utf8))
      let record = try await outputs.publish(imported, title: "Public pending native", publisher: publisher)
      let backend = try await outputs.engine.makeNativeStorage(publisher, expected: record)
      let opening = try await backend.opening(sessionID: UUID())
      let route = PagedNativeLogicalControlStorage(backend)
      let session = try PagedNativeSession(opening: opening, storage: route)
      let input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
      let commands = try PagedNativeUndoOwner(input: input)
      let view = try XCTUnwrap(input.activeView)
      let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      let viewport = try PagedDocumentViewport(frame: view.frame, input: input)
      commands.mountView = { old, new in try viewport.mountManagedView(from: old, to: new) }
      window.isReleasedWhenClosed = false; window.contentView = viewport
      Self.nativeOwners = (session, input, commands, route, backend, window)
      try await PagedNativeFixtureApplication.focus(view, in: window)
      let hold = try await route.holdNext(.commitBefore)
      let expected = NSMutableString(string: text)
      view.insertText("🙂e\u{301}\n", replacementRange: NSRange(location: 1, length: 0))
      expected.replaceCharacters(in: NSRange(location: 1, length: 0), with: "🙂e\u{301}\n")
      try await route.awaitHeld(hold)
      view.setMarkedText("界", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 2))
      expected.replaceCharacters(in: NSRange(location: 1, length: 2), with: "界")
      XCTAssertTrue(session.isPinned); XCTAssertTrue(view.hasMarkedText())
      let stale = try session.captureLogicalRead()
      try assertProjection(try await outputs.engine.logicalWindow(stale.source, utf16Anchor: 17_003,
        maximumBytes: PagedWorkingWindow.targetBytes),
        snapshot: stale.source, text: expected as String, anchor: 17_003)
      view.setMarkedText("界Z", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      expected.replaceCharacters(in: NSRange(location: 1, length: 1), with: "界Z")
      XCTAssertFalse(session.isCurrent(stale), "A later real marked-text primitive invalidates old delivery")
      let marked = try session.captureLogicalRead()
      XCTAssertTrue(session.isCurrent(marked))
      // Unmark is an actual Cocoa character-command scope, not the ACK. It
      // can perform several accepted primitives even when final bytes match.
      // Keep the first real commit held until this synchronous input returns.
      view.unmarkText()
      let latest = try session.captureLogicalRead()
      XCTAssertFalse(session.isPinned); XCTAssertFalse(view.hasMarkedText())
      XCTAssertEqual(latest.sessionID, marked.sessionID, "Unmark changed the native session")
      XCTAssertEqual(latest.arenaID, marked.arenaID, "Unmark changed the physical arena")
      XCTAssertGreaterThanOrEqual(latest.generation, marked.generation,
        "Actual unmark must preserve the admitted primitive sequence")
      XCTAssertTrue(session.isCurrent(latest), "Post-unmark snapshot is current before the held writer returns")
      try await route.release(hold)
      _ = try await session.flush(through: latest.generation)
      try await commands.joinPendingCommand()
      XCTAssertNil(session.persistenceFailure); XCTAssertNil(session.pendingCommitInstallation)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(view.boundedStorage.mutationFailure)
      XCTAssertEqual(session.sessionID, latest.sessionID, "ACK changed the captured session")
      XCTAssertEqual(session.arenaID, latest.arenaID, "ACK changed the captured physical arena")
      XCTAssertEqual(session.generation, latest.generation,
        "ACK check: marked generation \(marked.generation), post-unmark generation \(latest.generation), current \(session.generation)")
      XCTAssertTrue(session.isCurrent(latest),
        "Post-unmark ACK identity: session \(latest.sessionID), arena \(latest.arenaID), generation \(latest.generation), entered navigation \(session.activeNavigationOperationCount)")
      XCTAssertNotEqual(session.sealedRevision, latest.source.sourceRevision)
      XCTAssertEqual(session.sealedGeneration, latest.generation)
      for anchor in [UInt64(0), 4, 16_380, 17_003] {
        try assertProjection(try await outputs.engine.logicalWindow(latest.source, utf16Anchor: anchor,
          maximumBytes: PagedWorkingWindow.targetBytes),
          snapshot: latest.source, text: expected as String, anchor: anchor)
      }
      let saved = outputs.retain(try await outputs.engine.currentDocumentRecordRetaining(publisher,
        documentID: record.document.id))
      let digest = try await outputs.engine.wholeTextSha256(saved.document.revision)
      XCTAssertEqual(digest, Digest.sha256(Data((expected as String).utf8)))
      // XCTest assertions do not throw. Refuse success-only teardown before
      // detaching/dropping the actual native graph when any oracle failed.
      // The static owners above retain working input, controller and window;
      // the outer fixture retains outputs and the original error/root files.
      guard (testRun?.failureCount ?? 0) == failuresBeforeNativeCase else {
        throw BoomError.invalid("Native scroll assertions failed; actual input/source owners remain retained.")
      }
      try await viewport.closePresentation(); try commands.closeInput(); try commands.requireJoinedClose()
      window.contentView = nil; window.close()
      await route.closeAndJoin()
      try await backend.detachJoinedController(sessionID: session.sessionID, sequence: session.sealedGeneration, record: saved)
      Self.nativeOwners = nil
    }
  }

  func testActualContainedScrollClickKeepsShiftAnchorAndLaterTypingWhileWriterIsHeld() async throws {
    try await fixture { outputs, publisher in
      let failures = testRun?.failureCount ?? 0
      try PagedNativeFixtureApplication.bootstrap()
      let text = String(repeating: "public é🙂\n", count: 4_000)
      let imported = try await outputs.imported(Data(text.utf8))
      let original = try await outputs.publish(imported, title: "Public dirty local click", publisher: publisher)
      let backend = try await outputs.engine.makeNativeStorage(publisher, expected: original)
      let opening = try await backend.opening(sessionID: UUID())
      let route = PagedNativeLogicalControlStorage(backend)
      let session = try PagedNativeSession(opening: opening, storage: route)
      let input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
      let commands = try PagedNativeUndoOwner(input: input)
      let view = try XCTUnwrap(input.activeView)
      let viewport = try PagedDocumentViewport(frame: view.frame, input: input)
      try viewport.enableDocumentNavigation(engine: outputs.engine, publisher: publisher)
      commands.mountView = { old, new in try viewport.mountManagedView(from: old, to: new) }
      let window = NSWindow(contentRect: viewport.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = viewport
      Self.nativeOwners = (session, input, commands, route, backend, window)
      try await PagedNativeFixtureApplication.focus(view, in: window)
      guard viewport.textView === view else { throw BoomError.stale("The public click control changed its mounted client.") }
      let originalLogical = try session.captureLogicalState().source
      let gate = ScrollWriterHold(expectation(description: "actual writer body entered for local click"))
      let writer = Task { try await outputs.engine.storageExecutorForTesting.run { gate.enter() } }
      var reads: [Task<Void, Error>] = [] // exactly the two entered presentation joins below
      var failure: Error?
      @MainActor func readWhileHeld() async throws {
        guard reads.count < 2 else { throw BoomError.invalid("The local click control exceeded its two real reads.") }
        try viewport.requestScroll(toUTF16: 0)
        let complete = expectation(description: "dirty copied scroll returned while writer remains entered")
        let read = Task { defer { complete.fulfill() }; try await viewport.joinPresentation() }
        reads.append(read)
        guard await XCTWaiter.fulfillment(of: [complete], timeout: 5) == .completed else {
          throw BoomError.unavailable("Local click display remained coupled to the held writer.")
        }
        try await read.value
        XCTAssertTrue(gate.isHeld)
      }
      do {
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 5) == .completed else {
          throw BoomError.unavailable("The actual public writer body did not enter.")
        }
        view.setSelectedRange(NSRange(location: 4, length: 0))
        let beforeGeneration = session.generation
        view.insertText("X", replacementRange: view.selectedRange())
        let accepted = session.generation, arena = session.arenaID
        XCTAssertEqual(accepted, beforeGeneration + 1)
        XCTAssertLessThan(session.localUTF16Count, 30_000)
        XCTAssertEqual(session.sealedRevision, original.document.revision)
        // Actual global anchor lies beyond the native island; focus is local.
        try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 0,
          utf16Length: 30_000, focusAtEnd: false, affinity: .upstream))
        try await readWhileHeld()
        let displayed = try XCTUnwrap(viewport.visibleScrollWindow)
        XCTAssertEqual(displayed.start.utf16, 0); XCTAssertTrue(displayed.text.hasPrefix("publXic"))
        XCTAssertFalse(commands.hasPendingCommand)
        try viewport.selectVisibleUTF16(5, extending: true)
        let extended = try input.currentDocumentSelection()
        XCTAssertEqual(extended.utf16Offset, 5); XCTAssertEqual(extended.utf16Length, 29_995)
        XCTAssertEqual(extended.anchorUTF16, 30_000); XCTAssertFalse(extended.focusAtEnd)
        XCTAssertEqual(extended.affinity, .upstream)
        XCTAssertEqual(session.generation, accepted); XCTAssertEqual(session.arenaID, arena)
        XCTAssertEqual(session.activeNavigationOperationCount, 0); XCTAssertFalse(commands.hasPendingCommand)
        XCTAssertTrue(input.activeView === view); XCTAssertTrue(viewport.textView === view)
        XCTAssertNil(viewport.visibleScrollWindow); XCTAssertEqual(session.sealedRevision, original.document.revision)
        // A second real display/click sets the caret, then ordinary native
        // typing is accepted BEFORE this actual executor/writer is released.
        try await readWhileHeld()
        try viewport.selectVisibleUTF16(5)
        let clicked = try input.currentDocumentSelection()
        XCTAssertEqual(clicked.utf16Offset, 5); XCTAssertEqual(clicked.utf16Length, 0)
        XCTAssertEqual(session.generation, accepted); XCTAssertEqual(session.arenaID, arena)
        XCTAssertEqual(session.activeNavigationOperationCount, 0); XCTAssertFalse(commands.hasPendingCommand)
        view.insertText("Y", replacementRange: view.selectedRange())
        XCTAssertEqual(session.generation, accepted + 1); XCTAssertTrue(view.string.hasPrefix("publXYic"))
        XCTAssertTrue(gate.isHeld); XCTAssertEqual(session.sealedRevision, original.document.revision)
        XCTAssertNil(input.firstRefusal); XCTAssertNil(view.boundedStorage.mutationFailure)
      } catch { failure = error }
      // Join EVERY real task, including a timed-out read, on both paths. No
      // failed public fixture is closed/deleted while an entered writer lives.
      gate.release()
      do { try await writer.value } catch {
        if let original = failure { failure = ScrollClickJoinFailure(original: original, cleanup: error) }
        else { failure = error }
      }
      for read in reads {
        do { try await read.value } catch {
          if let original = failure { failure = ScrollClickJoinFailure(original: original, cleanup: error) }
          else { failure = error }
        }
      }
      // A faulty old path may have entered a real navigation Task despite
      // the local-click oracle. Join it and ordinary accepted edits too;
      // retain any source refusal, without retry/repair or failed teardown.
      do { try await commands.joinPendingCommand() } catch {
        if let original = failure { failure = ScrollClickJoinFailure(original: original, cleanup: error) }
        else { failure = error }
      }
      do { _ = try await session.flush(through: session.generation) } catch {
        if let original = failure { failure = ScrollClickJoinFailure(original: original, cleanup: error) }
        else { failure = error }
      }
      if let failure { throw failure }
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Held local-click assertions failed; actual source/input owners retained.")
      }
      let saved = outputs.retain(try await outputs.engine.currentDocumentRecordRetaining(publisher,
        documentID: original.document.id))
      let expected = NSMutableString(string: text)
      expected.insert("XY", at: 4)
      let digest = try await outputs.engine.wholeTextSha256(saved.document.revision)
      XCTAssertEqual(digest, Digest.sha256(Data((expected as String).utf8)))
      let undo = NSSelectorFromString("undo:"), item = NSMenuItem(title: "Undo", action: undo, keyEquivalent: "z")
      for _ in 0..<2 {
        let active = try XCTUnwrap(input.activeView)
        guard window.isKeyWindow, let responder = window.firstResponder, responder === active,
          active.validateUserInterfaceItem(item), responder.tryToPerform(undo, with: item) else {
          throw BoomError.unavailable("The public local-click responder did not retain actual canonical Undo.")
        }
        try await commands.joinPendingCommand(); _ = try await session.flush(through: session.generation)
      }
      XCTAssertTrue(session.logicalWindow.snapshot.isSame(originalLogical))
      let undone = outputs.retain(try await outputs.engine.currentDocumentRecordRetaining(publisher,
        documentID: original.document.id))
      let undoneDigest = try await outputs.engine.wholeTextSha256(undone.document.revision)
      XCTAssertEqual(undoneDigest, Digest.sha256(Data(text.utf8)))
      XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, 4)
      XCTAssertNil(session.persistenceFailure); XCTAssertNil(input.firstRefusal)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Local-click source/Undo assertions failed; native and file owners retained.")
      }
      try await viewport.closePresentation(); try commands.closeInput(); try commands.requireJoinedClose()
      window.contentView = nil; window.close(); await route.closeAndJoin()
      let final = outputs.retain(try await outputs.engine.currentDocumentRecordRetaining(publisher,
        documentID: original.document.id))
      try await backend.detachJoinedController(sessionID: session.sessionID, sequence: session.sealedGeneration, record: final)
      Self.nativeOwners = nil
    }
  }
}
