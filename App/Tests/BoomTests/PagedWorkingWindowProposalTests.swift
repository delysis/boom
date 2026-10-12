import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

/// Public unit fixtures validate coordinator mechanics only. Page identities
/// below have no production AEAD provider or current-root authority.
@MainActor final class PagedWorkingWindowProposalTests: XCTestCase {
  private let ownerID = UUID(), documentID = UUID()
  private func capture(_ text: String, previous: PagedTextWindow? = nil) -> PagedTextWindow {
    let summary = PagedTextSummary(bytes: UInt64(text.utf8.count), utf16: UInt64(text.utf16.count),
      lfCount: UInt64(text.utf8.filter { $0 == 10 }.count))
    let page = PagedTextPageRef(locator: PagedTextPageLocator(storeID: UUID(), recordID: UUID(),
      ciphertextBytes: 128), digest: String(repeating: "a", count: 64))
    let revision = PagedTextRevision(schema: 1, ownerID: ownerID, documentID: documentID,
      root: text.isEmpty ? nil : PagedTextTreeRef(page: page, summary: summary, height: 0))
    return PagedTextWindow(revision: revision, windowID: UUID(), byteStart: previous?.byteStart ?? 0,
      utf16Start: previous?.utf16Start ?? 0, lfStart: previous?.lfStart ?? 0, text: text)
  }
  private func record(_ window: PagedTextWindow, generation: UInt64 = 0) -> PagedDocumentRootRecord {
    let page = PagedTextPageRef(locator: PagedTextPageLocator(storeID: UUID(), recordID: UUID(),
      ciphertextBytes: 128), digest: String(repeating: "b", count: 64))
    return PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: documentID,
      title: "Unit fixture", revision: window.revision), historyPage: page, historyGeneration: generation)
  }
  private func arena(_ window: PagedTextWindow) throws -> PagedWorkingWindow {
    try PagedWorkingWindow(window: window, rootRecord: record(window))
  }

  func testExactScalarRangesPreserveNFDAndRejectHalfSurrogate() throws {
    var working = try arena(capture("👩‍💻 Café e\u{301}\r\n"))
    let before = working.bytes
    XCTAssertThrowsError(try working.replace(NSRange(location: 1, length: 0), with: "X", groupID: UUID()))
    XCTAssertEqual(working.generation, 0); XCTAssertEqual(working.bytes, before)
    try working.replace(NSRange(location: 6, length: 4), with: "Cafe\u{301}", groupID: UUID())
    XCTAssertEqual(working.bytes, Data("👩‍💻 Cafe\u{301} e\u{301}\r\n".utf8))
    let batch = try XCTUnwrap(working.takeCommitBatch())
    XCTAssertEqual(batch.deltas[0].oldBytes, Data("Café".utf8))
    XCTAssertEqual(batch.afterBytes, working.bytes)
    XCTAssertEqual(batch.expected.revision, working.sealedWindow.revision)
  }

  func testAcknowledgementDoesNotOverwriteLaterNativeCharacters() async throws {
    let initial = capture("start")
    var working = try arena(initial)
    try working.replace(NSRange(location: 5, length: 0), with: " A", groupID: UUID())
    let first = try XCTUnwrap(working.takeCommitBatch())
    try working.replace(NSRange(location: 7, length: 0), with: " B", groupID: UUID())
    let sealed = capture("start A", previous: initial)
    let sealedRecord = record(sealed, generation: 1)
    let ack = try await Task.detached {
      try PagedNativeCommitAcknowledgement(validating: first, sealedWindow: sealed, sealedRootRecord: sealedRecord)
    }.value
    try working.acknowledge(ack)
    XCTAssertEqual(working.bytes, Data("start A B".utf8))
    XCTAssertEqual(working.sealedGeneration, 1); XCTAssertEqual(working.generation, 2)
    let second = try XCTUnwrap(working.takeCommitBatch())
    XCTAssertEqual(second.expected.revision, sealed.revision)
    XCTAssertEqual(second.firstSequence, 2); XCTAssertEqual(second.lastSequence, 2)
    XCTAssertEqual(second.deltas[0].oldBytes, Data())
    XCTAssertEqual(second.deltas[0].newBytes, Data(" B".utf8))
  }

  func testIMEPinAndQueueCompactionKeepExactOrderedCoverage() throws {
    let initial = capture("e\u{301} 👩‍💻")
    var working = try arena(initial)
    working.beginComposition()
    for _ in 0..<1_024 {
      try working.replace(NSRange(location: working.localUTF16Count, length: 0), with: "x", groupID: UUID())
      XCTAssertLessThanOrEqual(working.queuedDeltaCount, PagedWorkingWindow.maximumQueuedDeltas)
      XCTAssertLessThanOrEqual(working.chargedQueueBytes, PagedWorkingWindow.maximumQueuedBytes)
    }
    XCTAssertNil(try working.takeCommitBatch())
    working.endComposition()
    let batch = try XCTUnwrap(working.takeCommitBatch())
    XCTAssertEqual(batch.firstSequence, 1); XCTAssertEqual(batch.lastSequence, 1_024)
    XCTAssertEqual(batch.groupCheckpoints.count, 1)
    XCTAssertEqual(batch.groupCheckpoints[0].firstSequence, 1)
    XCTAssertEqual(batch.groupCheckpoints[0].lastSequence, 1_024)
    var oracle = Data(initial.text.utf8), sequence: UInt64 = 1
    for delta in batch.deltas {
      XCTAssertEqual(delta.firstSequence, sequence)
      let range = delta.localByteStart..<(delta.localByteStart + delta.oldBytes.count)
      XCTAssertEqual(oracle.subdata(in: range), delta.oldBytes)
      oracle.replaceSubrange(range, with: delta.newBytes)
      sequence = delta.lastSequence + 1
    }
    XCTAssertEqual(oracle, working.bytes); XCTAssertEqual(sequence, 1_025)
  }

  func testCompactionRetainsTheLastHundredNativeGroupsAndTheirExactBaseline() throws {
    var working = try arena(capture("base"))
    for index in 1...120 {
      try working.replace(NSRange(location: working.localUTF16Count, length: 0), with: "x", groupID: UUID())
      XCTAssertLessThanOrEqual(working.queuedDeltaCount, PagedWorkingWindow.maximumQueuedDeltas)
      XCTAssertLessThanOrEqual(working.chargedGroupBytes, 101 * (PagedWorkingWindow.hardBytes + 128))
      XCTAssertEqual(working.generation, UInt64(index))
    }
    let batch = try XCTUnwrap(working.takeCommitBatch())
    XCTAssertEqual(batch.groupCheckpoints.count, 100)
    XCTAssertEqual(batch.historyBaseline?.lastSequence, 20)
    XCTAssertEqual(batch.historyBaseline?.afterBytes, Data(("base" + String(repeating: "x", count: 20)).utf8))
    XCTAssertEqual(batch.groupCheckpoints.first?.firstSequence, 21)
    XCTAssertEqual(batch.groupCheckpoints.last?.afterBytes, batch.afterBytes)
  }

  func testBudgetFailureRetainsSourceAndFailedBatch() throws {
    var working = try arena(capture(String(repeating: "a", count: 16_384)))
    working.beginComposition()
    try working.replace(NSRange(location: 16_384, length: 0), with: String(repeating: "b", count: 8_192), groupID: UUID())
    let before = working.bytes, generation = working.generation
    XCTAssertThrowsError(try working.replace(NSRange(location: 24_576, length: 0), with: "c", groupID: UUID()))
    XCTAssertEqual(working.bytes, before); XCTAssertEqual(working.generation, generation)
    working.endComposition()
    let batch = try XCTUnwrap(working.takeCommitBatch())
    XCTAssertEqual(working.failedBatchRetained?.batchID, batch.batchID)
    XCTAssertEqual(working.sealedGeneration, 0)
  }

  func testUndoRegistersItsInverseInsideTheSynchronousManagerInvocation() {
    let manager = UndoManager()
    var undoFlag = false, redoFlag = false, directions: [PagedNativeHistoryHandle.Direction] = []
    let registration = PagedNativeUndoRegistration(manager: manager) { handle in
      directions.append(handle.direction)
      if handle.direction == .undo { undoFlag = manager.isUndoing }
      else { redoFlag = manager.isRedoing }
    }
    manager.beginUndoGrouping()
    registration.register(PagedNativeHistoryHandle(documentID: documentID, groupID: UUID(), direction: .undo), actionName: "Typing")
    manager.endUndoGrouping()
    manager.undo()
    XCTAssertTrue(undoFlag); XCTAssertTrue(manager.canRedo)
    manager.redo()
    XCTAssertTrue(redoFlag); XCTAssertTrue(manager.canUndo)
    XCTAssertEqual(directions, [.undo, .redo]); XCTAssertEqual(manager.levelsOfUndo, 100)
  }

  func testHistoryPreservesTheExistingHundredGroupLimitWithoutTextSnapshots() throws {
    let initial = capture("0").revision
    let cursor = PagedSealedCursor(byteOffset: 0, utf16Offset: 0)
    var history = try PagedRootHistory(revision: initial, cursor: cursor)
    for index in 1...100 { try history.record(capture(String(index)).revision, cursor: cursor, beforeCursor: cursor, groupID: UUID()) }
    let final = history.current
    XCTAssertEqual(history.undo.count, 100)
    XCTAssertLessThanOrEqual(try history.encoded(expected: final).count, PagedRootHistory.maximumEncodedBytes)
    for _ in 0..<100 { _ = try history.stepUndo(expected: history.current) }
    XCTAssertEqual(history.current, initial); XCTAssertEqual(history.redo.count, 100)
    for _ in 0..<100 { _ = try history.stepRedo(expected: history.current) }
    XCTAssertEqual(history.current, final)
  }

  func testNoNetSourceBatchAdvancesHistoryEpochWithoutAnEmptyUndoGroup() throws {
    let initial = capture("").revision
    let cursor = PagedSealedCursor(byteOffset: 0, utf16Offset: 0)
    var history = try PagedRootHistory(revision: initial, cursor: cursor)
    try history.record(initial, cursor: cursor, beforeCursor: cursor, groupID: UUID())
    XCTAssertEqual(history.current, initial)
    XCTAssertEqual(history.generation, 1)
    XCTAssertTrue(history.undo.isEmpty)
    XCTAssertTrue(history.redo.isEmpty)
  }

  func testWorkerAcknowledgementRefusesAnUnadvancedHistoryEpoch() async throws {
    let initial = capture("a")
    var working = try arena(initial)
    try working.replace(NSRange(location: 1, length: 0), with: "b", groupID: UUID())
    let batch = try XCTUnwrap(working.takeCommitBatch())
    let after = capture("ab", previous: initial), unchangedEpoch = record(after, generation: 0)
    let refused = await Task.detached {
      do {
        _ = try PagedNativeCommitAcknowledgement(validating: batch, sealedWindow: after,
          sealedRootRecord: unchangedEpoch)
        return false
      } catch { return true }
    }.value
    XCTAssertTrue(refused)
    XCTAssertEqual(working.failedBatchRetained?.batchID, batch.batchID)
    XCTAssertEqual(working.sealedGeneration, 0)
  }

  func testFlushRefusesInteriorAndSupersededGenerationsOfACoalescedSeal() async throws {
    let initial = capture("a"), storage = HeldPagedNativeStorage()
    let session = try PagedNativeSession(window: initial, rootRecord: record(initial), storage: storage)
    session.beginComposition()
    try session.nativeCharacterTransactionWillBegin()
    try session.replace(NSRange(location: 1, length: 0), with: "b", groupID: UUID())
    try session.replace(NSRange(location: 2, length: 0), with: "c", groupID: UUID())
    session.nativeCharacterTransactionDidClose()
    session.endComposition()
    let interior = Task { try await session.flush(through: 1) }
    let batch = await storage.nextBatch()
    XCTAssertEqual(batch.firstSequence, 1); XCTAssertEqual(batch.lastSequence, 2)
    let after = capture("abc", previous: initial)
    _ = try await storage.seal(window: after, record: record(after, generation: 1))
    do {
      _ = try await interior.value
      XCTFail("An interior generation must not acquire the later root.")
    } catch BoomError.stale { /* Explicitly refused, never relabeled. */ }
    do {
      _ = try await session.flush(through: 1)
      XCTFail("A superseded generation must not acquire the current root.")
    } catch BoomError.stale { /* No historical generation map is implied. */ }
    let current = try await session.flush(through: 2)
    XCTAssertEqual(current, after.revision)
    XCTAssertEqual(try session.windowForNativeInstallation().text, "abc")
  }

  func testFlushReturnsItsExactAcknowledgementWhileLaterNativeInputRemainsPending() async throws {
    let initial = capture("a"), storage = HeldPagedNativeStorage()
    let session = try PagedNativeSession(window: initial, rootRecord: record(initial), storage: storage)
    try session.nativeCharacterTransactionWillBegin()
    try session.replace(NSRange(location: 1, length: 0), with: "b", groupID: UUID())
    session.nativeCharacterTransactionDidClose()
    let first = await storage.nextBatch()
    XCTAssertEqual(first.lastSequence, 1)
    let captured = Task { try await session.flush(through: 1) }
    try session.nativeCharacterTransactionWillBegin()
    try session.replace(NSRange(location: 2, length: 0), with: "c", groupID: UUID())
    session.nativeCharacterTransactionDidClose()
    let firstWindow = capture("ab", previous: initial)
    let firstAck = try await storage.seal(window: firstWindow, record: record(firstWindow, generation: 1))
    let capturedRevision = try await captured.value
    XCTAssertEqual(capturedRevision, firstAck.sealedWindow.revision)
    XCTAssertEqual(session.generation, 2)
    XCTAssertThrowsError(try session.windowForNativeInstallation())
    let second = await storage.nextBatch()
    XCTAssertEqual(second.firstSequence, 2); XCTAssertEqual(second.lastSequence, 2)
    XCTAssertEqual(second.expected.revision, firstWindow.revision)
    XCTAssertEqual(second.afterBytes, Data("abc".utf8))
    let secondWindow = capture("abc", previous: initial)
    _ = try await storage.seal(window: secondWindow, record: record(secondWindow, generation: 2))
    let current = try await session.flush(through: 2)
    XCTAssertEqual(current, secondWindow.revision)
    XCTAssertEqual(try session.windowForNativeInstallation().text, "abc")
  }
}

/// Explicitly held storage acknowledgements expose source-generation races
/// without wall-clock sleeps, filesystem timing, or a synthetic full document.
private actor HeldPagedNativeStorage: PagedNativeSessionStorage {
  private var pending: (PagedNativeCommitBatch, CheckedContinuation<PagedNativeCommitAcknowledgement, Error>)?
  private var batchWaiter: CheckedContinuation<PagedNativeCommitBatch, Never>?

  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    try await withCheckedThrowingContinuation { continuation in
      precondition(pending == nil)
      pending = (batch, continuation)
      if let waiter = batchWaiter { batchWaiter = nil; waiter.resume(returning: batch) }
    }
  }
  func nextBatch() async -> PagedNativeCommitBatch {
    if let pending { return pending.0 }
    return await withCheckedContinuation { continuation in
      precondition(batchWaiter == nil)
      batchWaiter = continuation
    }
  }
  func seal(window: PagedTextWindow, record: PagedDocumentRootRecord) async throws -> PagedNativeCommitAcknowledgement {
    guard let item = pending else { throw BoomError.unavailable("The held test batch has not arrived.") }
    do {
      let acknowledgement = try await Task.detached {
        try PagedNativeCommitAcknowledgement(validating: item.0, sealedWindow: window, sealedRootRecord: record)
      }.value
      pending = nil
      item.1.resume(returning: acknowledgement)
      return acknowledgement
    } catch {
      pending = nil
      item.1.resume(throwing: error)
      throw error
    }
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    throw BoomError.unavailable("The held test backend never navigates.")
  }
}
