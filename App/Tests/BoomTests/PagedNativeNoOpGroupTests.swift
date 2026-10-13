import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

/// These synthetic bounded roots qualify coordinator behavior only. Actual
/// file-backed source/history publication is covered by integration checks.
@MainActor final class PagedNativeNoOpGroupTests: XCTestCase {
  private let owner = UUID(), document = UUID()

  private func window(_ text: String) -> PagedTextWindow {
    let page = PagedTextPageRef(locator: PagedTextPageLocator(storeID: UUID(), offset: 0,
      bytes: 128), digest: String(repeating: "a", count: 64))
    let summary = PagedTextSummary(bytes: UInt64(text.utf8.count), utf16: UInt64(text.utf16.count),
      lfCount: UInt64(text.utf8.filter { $0 == 10 }.count))
    let revision = PagedTextRevision(schema: 1, ownerID: owner, documentID: document,
      root: text.isEmpty ? nil : PagedTextTreeRef(page: page, summary: summary, height: 0))
    return PagedTextWindow(revision: revision, windowID: UUID(), byteStart: 0, utf16Start: 0, lfStart: 0, text: text)
  }
  private func working(_ text: String) throws -> PagedWorkingWindow {
    let captured = window(text)
    let page = PagedTextPageRef(locator: PagedTextPageLocator(storeID: UUID(), offset: 0,
      bytes: 128), digest: String(repeating: "b", count: 64))
    let record = PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: document,
      title: "Unit fixture", revision: captured.revision), historyPage: page, historyGeneration: 0)
    return try PagedWorkingWindow(window: captured, rootRecord: record)
  }
  private func assertExactCoverage(_ batch: PagedNativeCommitBatch) {
    var oracle = Data(batch.expected.text.utf8), sequence = batch.firstSequence
    for delta in batch.deltas {
      XCTAssertEqual(delta.firstSequence, sequence)
      let range = delta.localByteStart..<(delta.localByteStart + delta.oldBytes.count)
      XCTAssertEqual(oracle.subdata(in: range), delta.oldBytes)
      oracle.replaceSubrange(range, with: delta.newBytes)
      sequence = delta.lastSequence + 1
    }
    XCTAssertEqual(sequence, batch.lastSequence + 1); XCTAssertEqual(oracle, batch.afterBytes)
  }
  private func limits(_ arena: PagedWorkingWindow) {
    XCTAssertLessThanOrEqual(arena.chargedGroupBytes, PagedWorkingWindow.maximumResidentGroupBytes)
    XCTAssertLessThanOrEqual(arena.queuedDeltaCount, PagedWorkingWindow.maximumQueuedDeltas)
    XCTAssertLessThanOrEqual(arena.chargedQueueBytes, PagedWorkingWindow.maximumQueuedBytes)
  }

  func testExactUnchangedScalarPrimitiveDoesNotAdvanceOrAllocateAnEditGroup() throws {
    var arena = try working("ae\u{301}🙂")
    let before = arena.bytes, selection = try arena.selection(NSRange(location: 1, length: 2))
    for _ in 0..<105 {
      XCTAssertFalse(try arena.replace(NSRange(location: 1, length: 2), with: "e\u{301}", groupID: UUID()))
    }
    XCTAssertEqual(arena.bytes, before); XCTAssertEqual(arena.generation, 0)
    XCTAssertEqual(arena.queuedDeltaCount, 0); XCTAssertEqual(arena.chargedGroupBytes, 0)
    XCTAssertEqual(try arena.localBytes(for: selection), 1..<4)
    XCTAssertNil(try arena.takeCommitBatch())
  }

  func testAdjacentCommandChunksKeepOneTypingGroupAndOriginalSelection() async throws {
    var arena = try working("abc")
    let group = UUID(), selected = try arena.selection(NSRange(location: 1, length: 1))
    try arena.replace(NSRange(location: 1, length: 1), with: "x", groupID: group, beforeSelection: selected)
    XCTAssertNotNil(arena.closeNativeGroup())
    for _ in 0..<140 {
      try arena.replace(NSRange(location: arena.localUTF16Count, length: 0), with: "y", groupID: group)
      XCTAssertNotNil(arena.closeNativeGroup())
      limits(arena)
    }
    let batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertNil(batch.historyBaseline)
    XCTAssertEqual(batch.groupCheckpoints.count, 1)
    let checkpoint = try XCTUnwrap(batch.groupCheckpoints.first)
    XCTAssertEqual(checkpoint.firstSequence, 1); XCTAssertEqual(checkpoint.lastSequence, 141)
    XCTAssertEqual(checkpoint.beforeCursor.utf16Offset, 1)
    XCTAssertEqual(checkpoint.beforeCursor.selectionLengthUTF16, 1)
    assertExactCoverage(batch)
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    XCTAssertEqual(plan.steps.filter { $0.kind == .nativeGroup }.count, 1)
  }

  func testClosedChunksReturningToOriginalTextResolveWithoutAnUndoSlot() async throws {
    var arena = try working("a")
    let group = UUID()
    try arena.replace(NSRange(location: 1, length: 0), with: "x", groupID: group)
    XCTAssertNotNil(arena.closeNativeGroup())
    try arena.replace(NSRange(location: 1, length: 1), with: "", groupID: group)
    XCTAssertNotNil(arena.closeNativeGroup())
    let batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertEqual(batch.afterBytes, Data("a".utf8))
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    XCTAssertEqual(plan.steps.count, 1)
    let checkpoint = try XCTUnwrap(batch.groupCheckpoints.first)
    let cursor = PagedSealedCursor(byteOffset: 1, utf16Offset: 1)
    var history = try PagedRootHistory(revision: batch.expected.revision, cursor: cursor)
    var lineage = PagedNativeHistorySlotLineage(history)
    try history.record(batch.expected.revision, cursor: cursor, beforeCursor: cursor, groupID: group)
    try lineage.nativeRecord(priorRevision: batch.expected.revision, priorActive: nil,
      priorUndoCount: 0, beforeCursor: cursor, after: history, checkpoint: checkpoint)
    XCTAssertTrue(history.undo.isEmpty)
    XCTAssertNil(try lineage.resolutions(history).first?.undoIndex)
  }

  func testCapturedAfterSelectionKeepsUnicodeEndpointsDirectionAndAffinityAcrossChunks() async throws {
    var arena = try working("ae\u{301}🙂")
    let group = UUID()
    let before = try arena.selection(NSRange(location: 1, length: 2), focusAtEnd: true, affinity: .downstream)
    try arena.replace(NSRange(location: 1, length: 2), with: "é", groupID: group, beforeSelection: before)
    let firstAfter = try arena.selection(NSRange(location: 1, length: 3), focusAtEnd: false, affinity: .upstream)
    try arena.captureNativeAfterSelection(firstAfter)
    XCTAssertNotNil(arena.closeNativeGroup())
    let stale = try arena.selection(NSRange(location: 1, length: 3), focusAtEnd: false, affinity: .upstream)
    try arena.replace(NSRange(location: 4, length: 0), with: "x", groupID: group, beforeSelection: stale)
    XCTAssertThrowsError(try arena.captureNativeAfterSelection(stale))
    XCTAssertEqual(arena.generation, 2); XCTAssertEqual(arena.bytes, Data("aé🙂x".utf8))
    let final = try arena.selection(NSRange(location: 1, length: 4), focusAtEnd: true, affinity: .upstream)
    try arena.captureNativeAfterSelection(final)
    XCTAssertNotNil(arena.closeNativeGroup()); limits(arena)
    let prefix = try arena.reservePrefix(), batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertEqual(batch.lastSequence, prefix.generation); XCTAssertEqual(batch.groupCheckpoints.count, 1)
    let checkpoint = try XCTUnwrap(batch.groupCheckpoints.first)
    XCTAssertEqual(checkpoint.beforeCursor.utf16Offset, 1); XCTAssertEqual(checkpoint.beforeCursor.selectionLengthUTF16, 2)
    XCTAssertTrue(checkpoint.beforeCursor.focusAtEnd); XCTAssertEqual(checkpoint.beforeCursor.affinity, .downstream)
    XCTAssertEqual(checkpoint.caretUTF16, 1); XCTAssertEqual(checkpoint.afterSelectionLengthUTF16, 4)
    XCTAssertTrue(checkpoint.afterFocusAtEnd); XCTAssertEqual(checkpoint.afterAffinity, .upstream)
    XCTAssertEqual(batch.finalCaretUTF16, 1); XCTAssertEqual(batch.finalSelectionLengthUTF16, 4)
    XCTAssertTrue(batch.finalFocusAtEnd); XCTAssertEqual(batch.finalAffinity, .upstream)
    assertExactCoverage(batch)
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    let step = try XCTUnwrap(plan.steps.last)
    XCTAssertEqual(step.localCursorByte, 1); XCTAssertEqual(step.localCursorUTF16, 1)
    XCTAssertEqual(step.localSelectionLengthUTF16, 4); XCTAssertTrue(step.localFocusAtEnd)
    XCTAssertEqual(step.localAffinity, .upstream)
  }

  func testManyGenuineNetZeroGroupsKeepExactSequencesWithoutExpiringUndo() async throws {
    var arena = try working("a")
    for _ in 0..<105 {
      let id = UUID()
      XCTAssertTrue(try arena.replace(NSRange(location: 1, length: 0), with: "x", groupID: id))
      XCTAssertTrue(try arena.replace(NSRange(location: 1, length: 1), with: "", groupID: id))
      limits(arena)
    }
    let batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertEqual(batch.firstSequence, 1); XCTAssertEqual(batch.lastSequence, 210)
    XCTAssertEqual(batch.afterBytes, Data("a".utf8)); XCTAssertEqual(batch.finalCaretUTF16, 1)
    XCTAssertTrue(batch.groupCheckpoints.isEmpty); XCTAssertNil(batch.historyBaseline)
    assertExactCoverage(batch)
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    XCTAssertEqual(plan.steps.count, 1); XCTAssertEqual(plan.steps[0].kind, .epochOnly)
    XCTAssertNil(plan.steps[0].groupID); XCTAssertEqual(plan.steps[0].lastSequence, 210)
    XCTAssertEqual(plan.steps[0].localCursorUTF16, 1)
  }

  func testInterleavedNeutralGroupsPreserveActualSparseMeaningfulIDsAndBoundedBaseline() async throws {
    var arena = try working("base"), actualIDs: [UUID] = []
    for _ in 0..<120 {
      let meaningful = UUID(); actualIDs.append(meaningful)
      try arena.replace(NSRange(location: arena.localUTF16Count, length: 0), with: "x", groupID: meaningful)
      let neutral = UUID(), end = arena.localUTF16Count
      try arena.replace(NSRange(location: end, length: 0), with: "?", groupID: neutral)
      try arena.replace(NSRange(location: end, length: 1), with: "", groupID: neutral)
      limits(arena)
    }
    let batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertEqual(batch.groupCheckpoints.map(\.groupID), Array(actualIDs.suffix(100)))
    XCTAssertEqual(batch.historyBaseline?.groupID, actualIDs[19])
    XCTAssertEqual(batch.historyBaseline?.lastSequence, 58)
    XCTAssertEqual(batch.groupCheckpoints.first?.firstSequence, 61)
    XCTAssertEqual(batch.groupCheckpoints.last?.lastSequence, 358)
    XCTAssertEqual(batch.lastSequence, 360)
    XCTAssertEqual(batch.historyBaseline?.afterBytes, Data(("base" + String(repeating: "x", count: 20)).utf8))
    assertExactCoverage(batch)
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    XCTAssertEqual(plan.steps.count, 102)
    XCTAssertEqual(plan.steps.first?.kind, .expiredGroupBaseline)
    XCTAssertEqual(plan.steps.filter { $0.kind == .nativeGroup }.compactMap(\.groupID), Array(actualIDs.suffix(100)))
    XCTAssertEqual(plan.steps.last?.kind, .epochOnly); XCTAssertNil(plan.steps.last?.groupID)
  }

  func testOpenHundredAndFirstGroupReturningToItsStartDoesNotExpireFirstMeaningfulGroup() async throws {
    var arena = try working("a"), actualIDs: [UUID] = []
    for _ in 0..<100 {
      let id = UUID(); actualIDs.append(id)
      try arena.replace(NSRange(location: arena.localUTF16Count, length: 0), with: "x", groupID: id)
    }
    let end = arena.localUTF16Count, neutral = UUID()
    try arena.replace(NSRange(location: end, length: 0), with: "?", groupID: neutral)
    limits(arena)
    try arena.replace(NSRange(location: end, length: 1), with: "", groupID: neutral)
    let batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertNil(batch.historyBaseline); XCTAssertEqual(batch.groupCheckpoints.map(\.groupID), actualIDs)
    XCTAssertEqual(batch.lastSequence, 102); assertExactCoverage(batch)
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    XCTAssertEqual(plan.steps.count, 101); XCTAssertEqual(plan.steps.last?.kind, .epochOnly)
  }

  func testSparseCheckpointCannotSkipDeltaCoverageOrMisstateAnUncompactedEndpoint() async throws {
    var arena = try working("a")
    try arena.replace(NSRange(location: 1, length: 0), with: "b", groupID: UUID())
    let neutral = UUID()
    try arena.replace(NSRange(location: 2, length: 0), with: "x", groupID: neutral)
    try arena.replace(NSRange(location: 2, length: 1), with: "", groupID: neutral)
    try arena.replace(NSRange(location: 2, length: 0), with: "c", groupID: UUID())
    let batch = try XCTUnwrap(arena.takeCommitBatch()), first = try XCTUnwrap(batch.groupCheckpoints.first)
    let wrong = PagedNativeGroupCheckpoint(groupID: first.groupID, firstSequence: first.firstSequence,
      lastSequence: first.lastSequence, beforeCursor: first.beforeCursor,
      afterBytes: Data("az".utf8), caretUTF16: 2)
    let wrongEndpoint = PagedNativeCommitBatch(sessionID: batch.sessionID, batchID: batch.batchID,
      expected: batch.expected, expectedRootRecord: batch.expectedRootRecord,
      firstSequence: batch.firstSequence, lastSequence: batch.lastSequence, deltas: batch.deltas,
      afterBytes: batch.afterBytes, finalCaretUTF16: batch.finalCaretUTF16,
      historyBaseline: nil, groupCheckpoints: [wrong, batch.groupCheckpoints[1]])
    let missingDelta = PagedNativeCommitBatch(sessionID: batch.sessionID, batchID: batch.batchID,
      expected: batch.expected, expectedRootRecord: batch.expectedRootRecord,
      firstSequence: batch.firstSequence, lastSequence: batch.lastSequence,
      deltas: [batch.deltas[0], batch.deltas[2], batch.deltas[3]], afterBytes: batch.afterBytes,
      finalCaretUTF16: batch.finalCaretUTF16, historyBaseline: nil, groupCheckpoints: batch.groupCheckpoints)
    for invalid in [wrongEndpoint, missingDelta] {
      let refused = await Task.detached {
        do { _ = try PagedNativeCommitPlan(invalid); return false } catch { return true }
      }.value
      XCTAssertTrue(refused)
    }
  }

  func testObservedStartCursorSurvivesCompositionAndDeltaCompaction() async throws {
    var arena = try working("abcdef🙂")
    let before = try arena.selection(NSRange(location: 6, length: 0))
    arena.beginComposition()
    try arena.replace(NSRange(location: 5, length: 1), with: "", groupID: UUID(), beforeSelection: before)
    for _ in 0..<100 {
      try arena.replace(NSRange(location: 5, length: 0), with: "x", groupID: UUID(), beforeSelection: before)
      limits(arena)
    }
    arena.endComposition()
    let batch = try XCTUnwrap(arena.takeCommitBatch())
    XCTAssertEqual(batch.groupCheckpoints.count, 1)
    XCTAssertEqual(batch.groupCheckpoints[0].beforeCursor,
      PagedNativeLocalCursor(byteOffset: 6, utf16Offset: 6))
    assertExactCoverage(batch)
    let plan = try await Task.detached { try PagedNativeCommitPlan(batch) }.value
    XCTAssertEqual(plan.steps[0].beforeCursor, batch.groupCheckpoints[0].beforeCursor)
    XCTAssertEqual(plan.steps[0].localCursorUTF16, 6)

    let original = batch.groupCheckpoints[0]
    let forged = PagedNativeGroupCheckpoint(groupID: original.groupID,
      firstSequence: original.firstSequence, lastSequence: original.lastSequence,
      beforeCursor: PagedNativeLocalCursor(byteOffset: 7, utf16Offset: 6),
      afterBytes: original.afterBytes, caretUTF16: original.caretUTF16)
    let invalid = PagedNativeCommitBatch(sessionID: batch.sessionID, batchID: batch.batchID,
      expected: batch.expected, expectedRootRecord: batch.expectedRootRecord,
      firstSequence: batch.firstSequence, lastSequence: batch.lastSequence, deltas: batch.deltas,
      afterBytes: batch.afterBytes, finalCaretUTF16: batch.finalCaretUTF16,
      historyBaseline: batch.historyBaseline, groupCheckpoints: [forged])
    let refused = await Task.detached {
      do { _ = try PagedNativeCommitPlan(invalid); return false } catch { return true }
    }.value
    XCTAssertTrue(refused)
  }

  func testStaleStartSelectionCannotOpenAnotherGroup() throws {
    var arena = try working("abc🙂")
    let before = try arena.selection(NSRange(location: 3, length: 0))
    try arena.replace(NSRange(location: 2, length: 1), with: "", groupID: UUID(), beforeSelection: before)
    _ = arena.closeNativeGroup()
    let bytes = arena.bytes, generation = arena.generation
    XCTAssertThrowsError(try arena.replace(NSRange(location: 0, length: 0),
      with: "x", groupID: UUID(), beforeSelection: before))
    XCTAssertEqual(arena.bytes, bytes); XCTAssertEqual(arena.generation, generation)
  }
}
