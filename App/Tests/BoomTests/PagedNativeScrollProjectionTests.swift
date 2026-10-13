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

@MainActor final class PagedNativeScrollProjectionTests: XCTestCase {
  private static var failedOutputs: PagedFileEngineControlOutputs?
  private static var nativeOwners: (PagedNativeSession, PagedNativeInputOwner,
    PagedNativeUndoOwner, PagedStagedControlledStorage, PagedNativeStorageBackend, NSWindow)?

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
      Self.failedOutputs = outputs
      print("Failed public scroll retained: \(store.root.path)")
      throw error
    }
  }

  /// Small public oracle only; this is never a production document read.
  private func assertProjection(_ result: PagedNativeScrollProjection, text: String, anchor: UInt64) throws {
    try result.validate()
    var units: UInt64 = 0, bytes = 0, lfs: UInt64 = 0
    for scalar in text.unicodeScalars {
      let count: UInt64 = scalar.value > 0xffff ? 2 : 1
      if units + count > min(anchor, UInt64(text.utf16.count)) { break }
      units += count; bytes += (scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4)
      if scalar.value == 10 { lfs += 1 }
    }
    XCTAssertEqual(result.utf16Start, units); XCTAssertEqual(result.byteStart, UInt64(bytes)); XCTAssertEqual(result.lfStart, lfs)
    let remaining = Data(text.utf8).dropFirst(bytes)
    XCTAssertEqual(Data(result.text.utf8), Data(remaining.prefix(result.text.utf8.count)))
    XCTAssertFalse(result.text.isEmpty && units < UInt64(text.utf16.count))
    XCTAssertEqual(result.projectedSummary.bytes, UInt64(text.utf8.count))
    XCTAssertEqual(result.projectedSummary.utf16, UInt64(text.utf16.count))
    XCTAssertLessThanOrEqual(result.text.utf8.count, PagedWorkingWindow.targetBytes)
    try result.validateLocalPosition(result.text.utf16.count)
  }

  func testActualImmutableScrollCompletesWhileWriterExecutorIsEnteredAndHeld() async throws {
    try await fixture { outputs, publisher in
      let text = String(repeating: "public é🙂\n", count: 4_000)
      let imported = try await outputs.imported(Data(text.utf8))
      let record = try await outputs.publish(imported, title: "Public held writer", publisher: publisher)
      let window = outputs.retain(try await outputs.engine.windowRetaining(record.document.revision,
        byteStart: 0, maximumBytes: PagedWorkingWindow.targetBytes))
      let working = try PagedWorkingWindow(window: window, rootRecord: record)
      let snapshot = try working.captureScrollSnapshot()
      let gate = ScrollWriterHold(expectation(description: "actual writer executor entered"))
      let writer = Task { try await outputs.engine.storageExecutorForTesting.run { gate.enter() } }
      await fulfillment(of: [gate.entered], timeout: 5)
      let completed = expectation(description: "immutable file read returned before writer release")
      let read = Task {
        defer { completed.fulfill() }
        return try await outputs.engine.scrollProjection(snapshot, utf16Anchor: 24_003)
      }
      await fulfillment(of: [completed], timeout: 5)
      XCTAssertTrue(gate.isHeld, "This is an entered writer-body hold, not an actor preflight hold")
      // Release and join both real tasks even when the bounded timeout exposed
      // reader coupling; fixture teardown never runs across a live writer.
      gate.release(); try await writer.value
      let result = try await read.value
      try assertProjection(result, text: text, anchor: 24_003)
      XCTAssertEqual(result.revision, record.document.revision)
      XCTAssertEqual(outputs.engine.custodySnapshot.jobs, 0)
    }
  }

  func testActualNetOverlayInsertionAndEmptyDeletionMapBeforeInsideAfterAndSurrogates() async throws {
    try await fixture { outputs, publisher in
      let prefix = String(repeating: "p", count: 400) + "\n"
      let island = "A🙂é\nBé🙂\n"
      let suffix = String(repeating: "tail🙂é\n", count: 5_000)
      let text = prefix + island + suffix
      let imported = try await outputs.imported(Data(text.utf8))
      let record = try await outputs.publish(imported, title: "Public Unicode overlay", publisher: publisher)
      let window = outputs.retain(try await outputs.engine.windowRetaining(record.document.revision,
        byteStart: UInt64(prefix.utf8.count), maximumBytes: island.utf8.count))
      XCTAssertEqual(Data(window.text.utf8), Data(island.utf8))
      var working = try PagedWorkingWindow(window: window, rootRecord: record)
      try working.replace(NSRange(location: 1, length: 2), with: "e\u{301}🙂\n", groupID: UUID())
      let inFlight = try XCTUnwrap(working.takeCommitBatch())
      try working.replace(NSRange(location: working.localUTF16Count, length: 0), with: "Ω🙂", groupID: UUID())
      XCTAssertEqual(working.failedBatchRetained?.batchID, inFlight.batchID)
      let replacement = try XCTUnwrap(String(data: working.bytes, encoding: .utf8))
      let expected = prefix + replacement + suffix
      let snapshot = try working.captureScrollSnapshot()
      for anchor in [UInt64(0), 399, 400, 401, 404, 405,
        UInt64(prefix.utf16.count + replacement.utf16.count - 1),
        UInt64(prefix.utf16.count + replacement.utf16.count),
        UInt64(expected.utf16.count - 1), UInt64(expected.utf16.count)] {
        try assertProjection(try await outputs.engine.scrollProjection(snapshot, utf16Anchor: anchor),
          text: expected, anchor: anchor)
      }
      try working.replace(NSRange(location: 0, length: working.localUTF16Count), with: "", groupID: UUID())
      let deleted = try working.captureScrollSnapshot(), afterDelete = prefix + suffix
      for anchor in [UInt64(399), 400, 401, 402, 406, UInt64(afterDelete.utf16.count)] {
        try assertProjection(try await outputs.engine.scrollProjection(deleted, utf16Anchor: anchor),
          text: afterDelete, anchor: anchor)
      }
      XCTAssertEqual(record.document.revision, deleted.revision)
      XCTAssertEqual(outputs.engine.custodySnapshot.jobs, 0)
    }
  }

  func testActualHeldNativeCommitAndIMEReadKeepLaterTypingAndSameGenerationACKSnapshot() async throws {
    try await fixture { outputs, publisher in
      let failuresBeforeNativeCase = testRun?.failureCount ?? 0
      _ = NSApplication.shared
      let text = "aé🙂\n" + String(repeating: "public tail🙂é\n", count: 3_000)
      let imported = try await outputs.imported(Data(text.utf8))
      let record = try await outputs.publish(imported, title: "Public pending native", publisher: publisher)
      let backend = try await outputs.engine.makeNativeStorage(publisher, expected: record)
      let opening = try await backend.opening(sessionID: UUID())
      let route = PagedStagedControlledStorage(backend)
      let session = try PagedNativeSession(opening: opening, storage: route)
      let input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 320), session: session)
      let commands = try PagedNativeUndoOwner(input: input)
      let view = try XCTUnwrap(input.activeView)
      let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = view
      window.makeKeyAndOrderFront(nil); XCTAssertTrue(window.makeFirstResponder(view))
      Self.nativeOwners = (session, input, commands, route, backend, window)
      let hold = try await route.holdNext(.commitBefore)
      let expected = NSMutableString(string: text)
      view.insertText("🙂e\u{301}\n", replacementRange: NSRange(location: 1, length: 0))
      expected.replaceCharacters(in: NSRange(location: 1, length: 0), with: "🙂e\u{301}\n")
      try await route.awaitHeld(hold)
      view.setMarkedText("界", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 2))
      expected.replaceCharacters(in: NSRange(location: 1, length: 2), with: "界")
      XCTAssertTrue(session.isPinned); XCTAssertTrue(view.hasMarkedText())
      let stale = try session.captureScrollSnapshot()
      try assertProjection(try await outputs.engine.scrollProjection(stale, utf16Anchor: 17_003),
        text: expected as String, anchor: 17_003)
      view.setMarkedText("界Z", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      expected.replaceCharacters(in: NSRange(location: 1, length: 1), with: "界Z")
      XCTAssertFalse(session.isCurrent(stale), "A later real marked-text primitive invalidates old delivery")
      let marked = try session.captureScrollSnapshot()
      XCTAssertTrue(session.isCurrent(marked))
      // Unmark is an actual Cocoa character-command scope, not the ACK. It
      // can perform several accepted primitives even when final bytes match.
      // Keep the first real commit held until this synchronous input returns.
      view.unmarkText()
      let latest = try session.captureScrollSnapshot()
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
      XCTAssertNotEqual(session.sealedRevision, latest.revision)
      for anchor in [UInt64(0), 4, 16_380, 17_003] {
        try assertProjection(try await outputs.engine.scrollProjection(latest, utf16Anchor: anchor),
          text: expected as String, anchor: anchor)
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
      try commands.closeInput(); window.contentView = nil; window.close()
      await route.closeAndJoin()
      try await backend.detachJoinedController(sessionID: session.sessionID, sequence: session.generation, record: saved)
      Self.nativeOwners = nil
    }
  }
}
