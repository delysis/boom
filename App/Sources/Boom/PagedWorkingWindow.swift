import AppKit
import BoomCore
import Foundation

/// Native characters that have not necessarily reached a durable root. This
/// deliberately is not PagedTextWindow and does not expose a forged Revision.
struct PagedWorkingSelection: Equatable, Sendable {
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
  let localUTF16: NSRange
  let focusAtEnd: Bool
  let affinity: PagedSelectionAffinity
  init(sessionID: UUID, arenaID: UUID, generation: UInt64, localUTF16: NSRange,
    focusAtEnd: Bool = false, affinity: PagedSelectionAffinity = .downstream) {
    self.sessionID = sessionID; self.arenaID = arenaID; self.generation = generation
    self.localUTF16 = localUTF16; self.focusAtEnd = focusAtEnd; self.affinity = affinity
  }
}

/// An actual closed native chunk, before its worker publication starts. This
/// is not a durable Undo receipt; the command owner retains native selection
/// and input-client epochs separately. A source-neutral chunk has accepted
/// sequences but consumes no retained-root history slot.
struct PagedNativeGroupClosureReceipt: Sendable, Equatable {
  let sessionID: UUID
  let arenaID: UUID
  let effectiveGroupID: UUID
  let firstSequence: UInt64
  let lastSequence: UInt64
  let localCaretUTF16: Int
  let hasEffectiveSourceChange: Bool
  let beforeSnapshot: PagedNativeLogicalSnapshot
  let snapshot: PagedNativeLogicalSnapshot
  let beforeCursor: PagedNativeLogicalCursor
  let cursor: PagedNativeLogicalCursor
  let beforeSeed: PagedNativeLogicalWindowSeed?
  let seed: PagedNativeLogicalWindowSeed?
  var sourceGeneration: UInt64 { lastSequence }
  static func == (a: Self, b: Self) -> Bool {
    a.sessionID == b.sessionID && a.arenaID == b.arenaID && a.effectiveGroupID == b.effectiveGroupID
      && a.firstSequence == b.firstSequence && a.lastSequence == b.lastSequence
      && a.hasEffectiveSourceChange == b.hasEffectiveSourceChange
      && a.beforeSnapshot.isSame(b.beforeSnapshot) && a.snapshot.isSame(b.snapshot)
      && a.beforeCursor == b.beforeCursor && a.cursor == b.cursor
  }
}

/// Produced from actual immutable logical snapshot materialization and file
/// publication. This advances the saved checkpoint, never the editor head.
struct PagedNativeCommitAcknowledgement: Sendable {
  let sessionID: UUID
  let batchID: UUID
  let lastSequence: UInt64
  let expectedRevision: PagedTextRevision
  let expectedRootRecord: PagedDocumentRootRecord
  let sealedWindow: PagedTextWindow
  let sealedRootRecord: PagedDocumentRootRecord
  /// Validated with the exact worker-read bytes, so Main need not rescan text.
  let sealedBytes: Int
  let canonicalHistory: PagedNativeCanonicalHistoryProjection
  var historyGeneration: UInt64 { sealedRootRecord.historyGeneration }

  init(validating publication: PagedNativeLogicalPublication, sealedWindow: PagedTextWindow,
    sealedRootRecord: PagedDocumentRootRecord, canonicalHistory: PagedNativeCanonicalHistoryProjection) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Logical save admission belongs to the writer.") }
    try sealedWindow.validate(); try sealedRootRecord.validate()
    guard publication.history.snapshot.isSame(publication.window.snapshot),
      sealedRootRecord.document.revision == sealedWindow.revision,
      sealedWindow.revision.summary == publication.history.snapshot.summary,
      sealedWindow.byteStart == publication.window.start.bytes,
      sealedWindow.utf16Start == publication.window.start.utf16,
      sealedWindow.lfStart == publication.window.start.lfCount,
      sealedWindow.text.utf8.elementsEqual(publication.window.text.utf8),
      canonicalHistory.record == sealedRootRecord, canonicalHistory.beforeRecord == publication.expectedRecord,
      canonicalHistory.scope == .nativeBatch(sessionID: publication.sessionID, batchID: publication.publicationID,
        first: publication.firstSequence, last: publication.generation) else {
      throw BoomError.invalid("Logical save differs from the actual captured source/window/history.")
    }
    sessionID = publication.sessionID; batchID = publication.publicationID; lastSequence = publication.generation
    expectedRevision = publication.expectedRecord.document.revision; expectedRootRecord = publication.expectedRecord
    self.sealedWindow = sealedWindow; self.sealedRootRecord = sealedRootRecord
    sealedBytes = sealedWindow.text.utf8.count; self.canonicalHistory = canonicalHistory
  }

}

/// The one physical projection of the logical source. It owns one open
/// native group and one current window. Foundation owns retained Undo/Redo;
/// the saver owns its immutable captured publication independently.
@MainActor struct PagedWorkingWindow {
  nonisolated static let targetBytes = 16_384
  nonisolated static let hardBytes = 24_576
  private struct OpenGroup {
    let id: UUID
    let first: UInt64
    var last: UInt64
    let beforeWindow: PagedNativeLogicalWindow
    let beforeCursor: PagedNativeLogicalCursor
    let beforeSeed: PagedNativeLogicalWindowSeed?
  }
  let sessionID: UUID
  private(set) var arenaID: UUID
  private(set) var generation: UInt64
  private(set) var logicalWindow: PagedNativeLogicalWindow
  private(set) var currentCursor: PagedNativeLogicalCursor
  private(set) var compositionGroup: UUID?
  private var group: OpenGroup?
  init(window: PagedNativeLogicalWindow, arenaID: UUID = UUID(), generation: UInt64 = 0,
    cursor: PagedNativeLogicalCursor) throws {
    try cursor.validate(in: window.snapshot)
    sessionID = window.snapshot.sessionID; self.arenaID = arenaID
    logicalWindow = window; self.generation = generation; currentCursor = cursor
  }
  var localUTF16Count: Int { Int(logicalWindow.summary.utf16) }
  var isPinned: Bool { compositionGroup != nil }
  var needsRecentering: Bool { !isPinned && logicalWindow.summary.bytes > UInt64(Self.hardBytes) }
  var hasOpenNativeGroup: Bool { group != nil }
  var text: String { logicalWindow.text }
  func selection(_ range: NSRange, focusAtEnd: Bool = false,
    affinity: PagedSelectionAffinity = .downstream) throws -> PagedWorkingSelection {
    _ = try logicalWindow.localBytes(for: range)
    return PagedWorkingSelection(sessionID: sessionID, arenaID: arenaID, generation: generation,
      localUTF16: range, focusAtEnd: focusAtEnd, affinity: affinity)
  }
  func localBytes(for selection: PagedWorkingSelection) throws -> Range<Int> {
    guard selection.sessionID == sessionID, selection.arenaID == arenaID,
      selection.generation == generation else { throw BoomError.stale("Native range belongs to an older physical source.") }
    return try logicalWindow.localBytes(for: selection.localUTF16)
  }
  func cursor(for selection: PagedWorkingSelection) throws -> PagedNativeLogicalCursor {
    _ = try localBytes(for: selection)
    let point = try logicalWindow.position(localUTF16: selection.localUTF16.location)
    return PagedNativeLogicalCursor(byteOffset: point.bytes, utf16Offset: point.utf16,
      selectionLengthUTF16: UInt64(selection.localUTF16.length),
      focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
  }
  mutating func beginComposition(groupID: UUID?) { compositionGroup = compositionGroup ?? groupID ?? UUID() }
  mutating func endComposition() { compositionGroup = nil }
  mutating func captureNativeAfterSelection(_ cursor: PagedNativeLogicalCursor) throws {
    try cursor.validate(in: logicalWindow.snapshot); currentCursor = cursor
  }
  mutating func replace(_ range: NSRange, with replacement: String, groupID: UUID,
    beforeCursor: PagedNativeLogicalCursor, source: PagedNativeLogicalSource) throws -> Bool {
    let effective = compositionGroup ?? groupID
    guard group == nil || group?.id == effective else { throw BoomError.invalid("Previous native group must close first.") }
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Native generation is exhausted.") }
    try beforeCursor.validate(in: logicalWindow.snapshot)
    let before = logicalWindow
    let focus = beforeCursor.selection.focusUTF16
    let residentFocus = focus >= before.start.utf16 && focus - before.start.utf16 <= before.summary.utf16
    let seed = group == nil && residentFocus ? try before.makeSeed(localFocusUTF16: Int(focus - before.start.utf16)) : nil
    let result = try source.replace(in: before, range: range, with: replacement)
    guard result.changed else { return false }
    if group == nil {
      group = OpenGroup(id: effective, first: next.partialValue, last: next.partialValue,
        beforeWindow: before, beforeCursor: beforeCursor, beforeSeed: seed)
    } else { group!.last = next.partialValue }
    generation = next.partialValue; logicalWindow = result.window
    currentCursor = PagedNativeLogicalCursor(byteOffset: result.cursor.bytes, utf16Offset: result.cursor.utf16)
    return true
  }
  func requiresGroupClose(_ incoming: UUID) -> Bool { group != nil && group?.id != (compositionGroup ?? incoming) }
  mutating func closeNativeGroup(source: PagedNativeLogicalSource) throws -> PagedNativeGroupClosureReceipt? {
    guard let current = group, !isPinned else { return nil }
    let focus = currentCursor.selection.focusUTF16
    let residentFocus = focus >= logicalWindow.start.utf16 && focus - logicalWindow.start.utf16 <= logicalWindow.summary.utf16
    let seed = residentFocus ? try logicalWindow.makeSeed(localFocusUTF16: Int(focus - logicalWindow.start.utf16)) : nil
    // Only same-size net-zero groups compare bounded resident bytes. Native
    // generation survives, but no empty SDK action is retained.
    let unchanged = current.beforeWindow.start == logicalWindow.start
      && current.beforeWindow.summary == logicalWindow.summary
      && current.beforeWindow.text.utf8.elementsEqual(logicalWindow.text.utf8)
    if unchanged {
      source.installPrepared(current.beforeWindow.snapshot)
      logicalWindow = current.beforeWindow
    }
    group = nil
    return PagedNativeGroupClosureReceipt(sessionID: sessionID, arenaID: arenaID,
      effectiveGroupID: current.id, firstSequence: current.first, lastSequence: current.last,
      localCaretUTF16: Int(min(logicalWindow.summary.utf16, currentCursor.utf16Offset >= logicalWindow.start.utf16
        ? currentCursor.utf16Offset - logicalWindow.start.utf16 : 0)), hasEffectiveSourceChange: !unchanged,
      beforeSnapshot: current.beforeWindow.snapshot, snapshot: logicalWindow.snapshot,
      beforeCursor: current.beforeCursor, cursor: currentCursor,
      beforeSeed: current.beforeSeed, seed: unchanged ? current.beforeSeed : seed)
  }
  /// All candidate/table/cursor checks precede the exclusive consumer.
  mutating func installPrepared(window: PagedNativeLogicalWindow, arenaID: UUID,
    generation: UInt64, cursor: PagedNativeLogicalCursor) {
    precondition(group == nil && compositionGroup == nil && window.snapshot.sessionID == sessionID)
    logicalWindow = window; self.arenaID = arenaID; self.generation = generation; currentCursor = cursor
  }
}
