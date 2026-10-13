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

struct PagedNativeDelta: Sendable {
  /// A compacted replacement covers every sequence in this inclusive range.
  let firstSequence: UInt64
  let lastSequence: UInt64
  let localByteStart: Int
  let oldBytes: Data
  let newBytes: Data
  let groupID: UUID
  var chargedBytes: Int { oldBytes.count + newBytes.count + 128 }
}

/// Scalar coordinates in one bounded native island, with no durable-root grant.
struct PagedNativeLocalCursor: Equatable, Sendable {
  let byteOffset: Int
  let utf16Offset: Int
  let selectionLengthUTF16: Int
  let focusAtEnd: Bool
  let affinity: PagedSelectionAffinity
  init(byteOffset: Int, utf16Offset: Int, selectionLengthUTF16: Int = 0,
    focusAtEnd: Bool = false, affinity: PagedSelectionAffinity = .downstream) {
    self.byteOffset = byteOffset; self.utf16Offset = utf16Offset
    self.selectionLengthUTF16 = selectionLengthUTF16
    self.focusAtEnd = focusAtEnd; self.affinity = affinity
  }
}

/// Bounded native Undo grouping survives queue compaction. This is a resident
/// island checkpoint, not a document snapshot or a published history root.
struct PagedNativeGroupCheckpoint: Sendable {
  let groupID: UUID
  let firstSequence: UInt64
  let lastSequence: UInt64
  let beforeCursor: PagedNativeLocalCursor
  let afterBytes: Data
  let caretUTF16: Int
  let afterSelectionLengthUTF16: Int
  let afterFocusAtEnd: Bool
  let afterAffinity: PagedSelectionAffinity

  init(groupID: UUID, firstSequence: UInt64, lastSequence: UInt64,
    beforeCursor: PagedNativeLocalCursor, afterBytes: Data, caretUTF16: Int,
    afterSelectionLengthUTF16: Int = 0, afterFocusAtEnd: Bool = false,
    afterAffinity: PagedSelectionAffinity = .downstream) {
    self.groupID = groupID; self.firstSequence = firstSequence; self.lastSequence = lastSequence
    self.beforeCursor = beforeCursor; self.afterBytes = afterBytes; self.caretUTF16 = caretUTF16
    self.afterSelectionLengthUTF16 = afterSelectionLengthUTF16
    self.afterFocusAtEnd = afterFocusAtEnd; self.afterAffinity = afterAffinity
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
  var sourceGeneration: UInt64 { lastSequence }
}

struct PagedNativeCommitBatch: Sendable {
  let sessionID: UUID
  let batchID: UUID
  let expected: PagedTextWindow
  let expectedRootRecord: PagedDocumentRootRecord
  let firstSequence: UInt64
  let lastSequence: UInt64
  let deltas: [PagedNativeDelta]
  /// Exact bounded result of the included deltas, never a full-source snapshot.
  let afterBytes: Data
  /// Last genuinely accepted primitive, including a group that returns to its
  /// starting bytes. Exact unchanged replacements do not advance this cursor.
  let finalCaretUTF16: Int
  /// When >100 meaningful groups arrived while storage was stalled, this is
  /// the state before the oldest still-retained meaningful group. Source-
  /// neutral groups never evict Undo. Disk evidence/recipe pins are separate.
  let historyBaseline: PagedNativeGroupCheckpoint?
  let groupCheckpoints: [PagedNativeGroupCheckpoint]
  let finalSelectionLengthUTF16: Int
  let finalFocusAtEnd: Bool
  let finalAffinity: PagedSelectionAffinity

  init(sessionID: UUID, batchID: UUID, expected: PagedTextWindow,
    expectedRootRecord: PagedDocumentRootRecord, firstSequence: UInt64, lastSequence: UInt64,
    deltas: [PagedNativeDelta], afterBytes: Data, finalCaretUTF16: Int,
    historyBaseline: PagedNativeGroupCheckpoint?, groupCheckpoints: [PagedNativeGroupCheckpoint],
    finalSelectionLengthUTF16: Int = 0, finalFocusAtEnd: Bool = false,
    finalAffinity: PagedSelectionAffinity = .downstream) {
    self.sessionID = sessionID; self.batchID = batchID; self.expected = expected
    self.expectedRootRecord = expectedRootRecord; self.firstSequence = firstSequence; self.lastSequence = lastSequence
    self.deltas = deltas; self.afterBytes = afterBytes; self.finalCaretUTF16 = finalCaretUTF16
    self.historyBaseline = historyBaseline; self.groupCheckpoints = groupCheckpoints
    self.finalSelectionLengthUTF16 = finalSelectionLengthUTF16
    self.finalFocusAtEnd = finalFocusAtEnd; self.finalAffinity = finalAffinity
  }
}

/// Only a storage implementation may construct a successful commit ack. It
/// must compare the engine-read bounded bytes with batch.afterBytes off Main,
/// and finish page sync + history/root CAS + recovery journal removal first.
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
  /// Nil exists only for the old inactive primitive controls. Real engine ACKs
  /// always carry authenticated metadata; canonical Backend/Session require it.
  let canonicalHistory: PagedNativeCanonicalHistoryProjection?
  var historyGeneration: UInt64 { sealedRootRecord.historyGeneration }

  init(validating batch: PagedNativeCommitBatch, sealedWindow: PagedTextWindow,
    sealedRootRecord: PagedDocumentRootRecord,
    canonicalHistory: PagedNativeCanonicalHistoryProjection? = nil) throws {
    guard !Thread.isMainThread else {
      throw BoomError.invalid("Durable acknowledgement validation belongs to storage execution.")
    }
    try sealedWindow.validate()
    try sealedRootRecord.validate()
    guard sealedRootRecord.document.revision == sealedWindow.revision,
      sealedRootRecord.historyGeneration > batch.expectedRootRecord.historyGeneration,
      sealedWindow.revision.ownerID == batch.expected.revision.ownerID,
      sealedWindow.revision.documentID == batch.expected.revision.documentID,
      sealedWindow.byteStart == batch.expected.byteStart,
      sealedWindow.utf16Start == batch.expected.utf16Start,
      sealedWindow.lfStart == batch.expected.lfStart,
      sealedWindow.text.utf8.elementsEqual(batch.afterBytes) else {
      throw BoomError.invalid("The sealed range differs from the exact accepted native batch.")
    }
    sessionID = batch.sessionID; batchID = batch.batchID; lastSequence = batch.lastSequence
    expectedRevision = batch.expected.revision; expectedRootRecord = batch.expectedRootRecord
    self.sealedWindow = sealedWindow; self.sealedRootRecord = sealedRootRecord
    sealedBytes = batch.afterBytes.count
    if let canonicalHistory {
      guard canonicalHistory.record == sealedRootRecord,
        canonicalHistory.beforeRecord == batch.expectedRootRecord,
        canonicalHistory.scope == .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID,
          first: batch.firstSequence, last: batch.lastSequence) else {
        throw BoomError.invalid("Native ACK lost its exact canonical history producer scope.")
      }
    }
    self.canonicalHistory = canonicalHistory
  }
}

/// A synchronous cut in accepted input. Later primitives keep their own
/// ordered queue and cannot be compacted into this capture's sealed prefix.
struct PagedNativePrefixReservation: Sendable, Equatable {
  let reservationID: UUID
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
}

struct PagedNativeSealedPrefix: Sendable {
  let reservation: PagedNativePrefixReservation
  let window: PagedTextWindow
  let rootRecord: PagedDocumentRootRecord
}

/// One bounded native arena, sparse-independent scalar coordinates, one
/// in-flight seal and one bounded unsent queue. No String equality or Unicode
/// grapheme traversal is used to identify source ownership.
struct PagedWorkingWindow: Sendable {
  static let targetBytes = 16_384
  static let hardBytes = 24_576
  static let maximumQueuedDeltas = 64
  static let maximumQueuedBytes = 262_144
  /// At most 100 meaningful endpoints, one expired meaningful baseline, and
  /// one open group's original bytes. The live arena is charged separately.
  static let maximumResidentGroupBytes = (PagedRootHistory.maximumEntries + 2) * (hardBytes + 128)
  /// Earlier admitted batch, one exact command prefix, and later native input
  /// each have the same fixed endpoint budget. No per-keystroke capture list.
  static let maximumOwnedGroupBytes = 3 * maximumResidentGroupBytes
  static let maximumOwnedDeltaBytes = 3 * maximumQueuedBytes

  private struct ScalarPoint: Sendable { var byte: Int; var utf16: Int }
  private struct OpenGroup: Sendable {
    let groupID: UUID
    let firstSequence: UInt64
    var lastSequence: UInt64
    let beforeBytes: Data
    let beforeCursor: PagedNativeLocalCursor
  }
  private struct CapturedQueue: Sendable {
    let deltas: [PagedNativeDelta]
    let afterBytes: Data
    let finalCaretUTF16: Int
    let historyBaseline: PagedNativeGroupCheckpoint?
    let groupCheckpoints: [PagedNativeGroupCheckpoint]
    let finalSelectionLengthUTF16: Int
    let finalFocusAtEnd: Bool
    let finalAffinity: PagedSelectionAffinity
  }
  private struct ProvisionalHistory: Sendable {
    let prepared: PagedNativePreparedHistoryMove
    let admission: PagedNativeHistoryAdmission
  }
  let sessionID: UUID
  /// Navigation replaces the arena without resetting the controller's edit
  /// sequence. A local range from the old island must still become stale.
  private(set) var arenaID = UUID()
  private(set) var sealedWindow: PagedTextWindow
  private(set) var sealedRootRecord: PagedDocumentRootRecord
  private(set) var generation: UInt64 = 0
  private(set) var sealedGeneration: UInt64 = 0
  private(set) var bytes: Data
  private var points: [ScalarPoint]
  private var queue: [PagedNativeDelta] = []
  private var queuedBytes = 0
  private var groups: [PagedNativeGroupCheckpoint] = []
  private var openGroup: OpenGroup?
  private var historyBaseline: PagedNativeGroupCheckpoint?
  private var finalCaretUTF16 = 0
  private var finalSelectionLengthUTF16 = 0
  private var finalFocusAtEnd = false
  private var finalAffinity: PagedSelectionAffinity = .downstream
  private var unsentBase: Data
  private(set) var inFlight: PagedNativeCommitBatch?
  private(set) var compositionGroup: UUID?
  private(set) var reservedPrefix: PagedNativePrefixReservation?
  private var capturedPrefixQueue: CapturedQueue?
  private var provisionalHistory: ProvisionalHistory?

  init(window: PagedTextWindow, rootRecord: PagedDocumentRootRecord,
    sessionID: UUID = UUID(), generation: UInt64 = 0) throws {
    try window.validate()
    try rootRecord.validate()
    guard rootRecord.document.revision == window.revision else {
      throw BoomError.stale("Native window belongs to another captured root/history record.")
    }
    let bytes = Data(window.text.utf8)
    guard bytes.count <= Self.targetBytes else {
      throw BoomError.budget("Editable native windows are limited to their target budget.")
    }
    self.sessionID = sessionID; self.generation = generation; sealedGeneration = generation
    sealedWindow = window; sealedRootRecord = rootRecord; self.bytes = bytes; unsentBase = bytes
    points = Self.scalarPoints(window.text)
  }

  var localUTF16Count: Int { points.last?.utf16 ?? 0 }
  var hasUnsealedChanges: Bool { generation != sealedGeneration }
  var hasProvisionalHistory: Bool { provisionalHistory != nil }
  /// The source represented by the working island can be unpublished after
  /// Undo. Keep it distinct from the authenticated durable sealedWindow.
  var sourceBaseRevision: PagedTextRevision { provisionalHistory?.prepared.window.revision ?? sealedWindow.revision }
  var projectionWindow: PagedTextWindow { provisionalHistory?.prepared.window ?? sealedWindow }
  /// A COW copy of the current arena replaces its entire immutable source span.
  /// In-flight/prefix queues and marked text are already reflected in bytes.
  func captureScrollSnapshot() throws -> PagedNativeScrollSnapshot {
    try PagedNativeScrollSnapshot(source: projectionWindow, replacement: bytes,
      replacementUTF16: localUTF16Count, sessionID: sessionID, arenaID: arenaID,
      generation: generation)
  }
  var isPinned: Bool { compositionGroup != nil }
  var hasOpenNativeGroup: Bool { openGroup != nil }
  var queuedDeltaCount: Int { queue.count }
  var chargedQueueBytes: Int { queuedBytes }
  var chargedGroupBytes: Int {
    let extra = (historyBaseline.map { $0.afterBytes.count + 128 } ?? 0)
      + (openGroup.map { $0.beforeBytes.count + 128 } ?? 0)
    return groups.reduce(extra) { $0 + $1.afterBytes.count + 128 }
  }
  var chargedOwnedGroupBytes: Int {
    func charge(_ checkpoints: [PagedNativeGroupCheckpoint], _ baseline: PagedNativeGroupCheckpoint?) -> Int {
      checkpoints.reduce(baseline.map { $0.afterBytes.count + 128 } ?? 0) { $0 + $1.afterBytes.count + 128 }
    }
    return chargedGroupBytes
      + (capturedPrefixQueue.map { charge($0.groupCheckpoints, $0.historyBaseline) } ?? 0)
      + (inFlight.map { charge($0.groupCheckpoints, $0.historyBaseline) } ?? 0)
  }
  var chargedOwnedDeltaBytes: Int {
    queuedBytes + (capturedPrefixQueue?.deltas.reduce(0) { $0 + $1.chargedBytes } ?? 0)
      + (inFlight?.deltas.reduce(0) { $0 + $1.chargedBytes } ?? 0)
  }
  /// Recenter after joining unsent changes; a marked-text transaction keeps
  /// its current arena and can use the explicitly bounded reserve.
  var needsRecentering: Bool { bytes.count > Self.targetBytes }

  mutating func beginComposition(groupID: UUID? = nil) {
    if compositionGroup == nil { compositionGroup = groupID ?? UUID() }
  }
  mutating func endComposition() { compositionGroup = nil }

  func selection(_ range: NSRange, focusAtEnd: Bool = false,
    affinity: PagedSelectionAffinity = .downstream) throws -> PagedWorkingSelection {
    _ = try localBytes(forUTF16: range)
    return PagedWorkingSelection(sessionID: sessionID, arenaID: arenaID,
      generation: generation, localUTF16: range, focusAtEnd: focusAtEnd, affinity: affinity)
  }
  func localBytes(for selection: PagedWorkingSelection) throws -> Range<Int> {
    guard selection.sessionID == sessionID, selection.arenaID == arenaID,
      selection.generation == generation else {
      throw BoomError.stale("Working selection belongs to another native generation.")
    }
    return try localBytes(forUTF16: selection.localUTF16)
  }

  /// Called for the exact accepted NSTextStorage mutation, before observers
  /// can initiate projection or capture. Native large paste has a separate
  /// stream route; it must not first create an unbounded NSString here.
  @discardableResult
  mutating func replace(_ range: NSRange, with replacement: String, groupID: UUID,
    beforeSelection: PagedWorkingSelection? = nil) throws -> Bool {
    try replaceReportingClosure(range, with: replacement, groupID: groupID,
      beforeSelection: beforeSelection).accepted
  }

  /// The controller delivers this exact closure before it can start storage.
  /// Refused and unchanged replacements cannot close an existing group.
  mutating func replaceReportingClosure(_ range: NSRange, with replacement: String,
    groupID: UUID, beforeSelection: PagedWorkingSelection? = nil)
    throws -> (accepted: Bool, closedGroup: PagedNativeGroupClosureReceipt?) {
    let local = try localBytes(forUTF16: range)
    let retained = bytes.count - local.count
    guard replacement.utf8.count <= Self.hardBytes - retained else {
      throw BoomError.budget("Native replacement requires the bounded stream/recenter route.")
    }
    let newBytes = Data(replacement.utf8)
    let oldBytes = bytes.subdata(in: local)
    // An exact unchanged primitive is not a source edit. Admit its scalar
    // range first, then stop before generation, grouping or Data mutation.
    if oldBytes == newBytes { return (false, nil) }
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Native edit generation is exhausted.") }
    let newPoints = Self.scalarPoints(replacement)
    let firstPoint = try point(atUTF16: range.location)
    let endPoint = try point(atUTF16: range.location + range.length)
    let byteDelta = newBytes.count - local.count
    let unitDelta = (newPoints.last?.utf16 ?? 0) - range.length
    let actualGroupID = compositionGroup ?? groupID
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard actualGroupID != zero else { throw BoomError.invalid("Native group identity is empty.") }
    var closedGroup: PagedNativeGroupClosureReceipt?
    if openGroup?.groupID != actualGroupID {
      // Physical input supplies its selection captured before command dispatch.
      // A programmatic storage primitive has no view selection; its explicit
      // affected-range start is its Undo cursor. Neither uses the last edit.
      let observed = try beforeSelection ?? selection(NSRange(location: range.location, length: 0))
      let observedBytes = try localBytes(for: observed)
      closedGroup = closeOpenGroup()
      openGroup = OpenGroup(groupID: actualGroupID, firstSequence: next.partialValue,
        lastSequence: next.partialValue, beforeBytes: bytes,
        beforeCursor: PagedNativeLocalCursor(byteOffset: observedBytes.lowerBound,
          utf16Offset: observed.localUTF16.location, selectionLengthUTF16: observed.localUTF16.length,
          focusAtEnd: observed.focusAtEnd, affinity: observed.affinity))
    } else if let beforeSelection {
      guard let group = openGroup, beforeSelection.sessionID == sessionID,
        beforeSelection.arenaID == arenaID,
        beforeSelection.generation >= group.firstSequence - 1,
        beforeSelection.generation <= generation else {
        throw BoomError.stale("Native input selection belongs to another source island.")
      }
    }
    var inserted: [ScalarPoint] = []
    inserted.reserveCapacity(max(0, newPoints.count - 1))
    // The existing end point is retained and shifted; inserted points omit
    // their final end point, preventing duplicates for empty replacements.
    for point in newPoints.dropLast() {
      inserted.append(ScalarPoint(byte: local.lowerBound + point.byte,
        utf16: range.location + point.utf16))
    }
    points.replaceSubrange(firstPoint..<endPoint, with: inserted)
    let shiftedStart = firstPoint + inserted.count
    for index in shiftedStart..<points.count {
      points[index].byte += byteDelta; points[index].utf16 += unitDelta
    }
    bytes.replaceSubrange(local, with: newBytes)
    generation = next.partialValue
    let delta = PagedNativeDelta(firstSequence: generation, lastSequence: generation,
      localByteStart: local.lowerBound, oldBytes: oldBytes, newBytes: newBytes,
      groupID: actualGroupID)
    queue.append(delta); queuedBytes += delta.chargedBytes
    let caret = range.location + (newPoints.last?.utf16 ?? 0)
    openGroup?.lastSequence = generation
    finalCaretUTF16 = caret
    // A programmatic primitive has only its explicit replacement endpoint.
    // A real managed view captures its complete selection after AppKit returns.
    finalSelectionLengthUTF16 = 0; finalFocusAtEnd = false; finalAffinity = .downstream
    if queue.count > Self.maximumQueuedDeltas || queuedBytes > Self.maximumQueuedBytes {
      compactUnsent(groupID: delta.groupID)
    }
    return (true, closedGroup)
  }

  mutating func captureNativeAfterSelection(_ selection: PagedWorkingSelection) throws {
    guard openGroup != nil else { return }
    _ = try localBytes(for: selection) // exact current arena/generation and both scalar endpoints
    finalCaretUTF16 = selection.localUTF16.location
    finalSelectionLengthUTF16 = selection.localUTF16.length
    finalFocusAtEnd = selection.focusAtEnd; finalAffinity = selection.affinity
  }

  mutating func reservePrefix() throws -> PagedNativePrefixReservation {
    try reservePrefixReportingClosure().reservation
  }

  mutating func reservePrefixReportingClosure()
    throws -> (reservation: PagedNativePrefixReservation, closedGroup: PagedNativeGroupClosureReceipt?) {
    guard reservedPrefix == nil, provisionalHistory == nil, !isPinned else {
      throw BoomError.stale("A native command or composition already owns this capture boundary.")
    }
    let reservation = PagedNativePrefixReservation(reservationID: UUID(), sessionID: sessionID,
      arenaID: arenaID, generation: generation)
    let closedGroup = closeOpenGroup()
    if !queue.isEmpty {
      capturedPrefixQueue = CapturedQueue(deltas: queue, afterBytes: bytes,
        finalCaretUTF16: finalCaretUTF16, historyBaseline: historyBaseline, groupCheckpoints: groups,
        finalSelectionLengthUTF16: finalSelectionLengthUTF16,
        finalFocusAtEnd: finalFocusAtEnd, finalAffinity: finalAffinity)
      queue.removeAll(keepingCapacity: true); queuedBytes = 0
      groups.removeAll(keepingCapacity: true); historyBaseline = nil
      unsentBase = bytes
    }
    reservedPrefix = reservation
    return (reservation, closedGroup)
  }

  func sealedPrefix(_ reservation: PagedNativePrefixReservation) throws -> PagedNativeSealedPrefix {
    guard reservedPrefix == reservation, reservation.sessionID == sessionID,
      reservation.arenaID == arenaID, sealedGeneration == reservation.generation,
      capturedPrefixQueue == nil, inFlight == nil, provisionalHistory == nil else {
      throw BoomError.stale("The exact reserved native prefix has not joined.")
    }
    return PagedNativeSealedPrefix(reservation: reservation, window: sealedWindow, rootRecord: sealedRootRecord)
  }

  mutating func releasePrefix(_ reservation: PagedNativePrefixReservation) throws {
    _ = try sealedPrefix(reservation)
    reservedPrefix = nil
  }

  mutating func takeCommitBatch() throws -> PagedNativeCommitBatch? {
    try takeCommitBatchReportingClosure().batch
  }

  mutating func takeCommitBatchReportingClosure()
    throws -> (batch: PagedNativeCommitBatch?, closedGroup: PagedNativeGroupClosureReceipt?) {
    guard inFlight == nil, provisionalHistory == nil else { return (nil, nil) }
    if let reservation = reservedPrefix {
      guard sealedGeneration < reservation.generation else { return (nil, nil) }
      guard let captured = capturedPrefixQueue, let first = captured.deltas.first,
        let last = captured.deltas.last else {
        throw BoomError.invalid("The reserved native prefix lost its exact accepted queue.")
      }
      let next = sealedGeneration.addingReportingOverflow(1)
      guard !next.overflow, first.firstSequence == next.partialValue,
        last.lastSequence == reservation.generation else {
        throw BoomError.invalid("The reserved native prefix has a sequence gap.")
      }
      let batch = PagedNativeCommitBatch(sessionID: sessionID, batchID: UUID(), expected: sealedWindow,
        expectedRootRecord: sealedRootRecord, firstSequence: first.firstSequence,
        lastSequence: last.lastSequence, deltas: captured.deltas, afterBytes: captured.afterBytes,
        finalCaretUTF16: captured.finalCaretUTF16, historyBaseline: captured.historyBaseline,
        groupCheckpoints: captured.groupCheckpoints,
        finalSelectionLengthUTF16: captured.finalSelectionLengthUTF16,
        finalFocusAtEnd: captured.finalFocusAtEnd, finalAffinity: captured.finalAffinity)
      inFlight = batch; capturedPrefixQueue = nil
      return (batch, nil)
    }
    guard !isPinned, let first = queue.first, let last = queue.last else { return (nil, nil) }
    let next = sealedGeneration.addingReportingOverflow(1)
    guard !next.overflow, first.firstSequence == next.partialValue,
      last.lastSequence == generation else {
      throw BoomError.invalid("Native queue has a sequence gap.")
    }
    let closedGroup = closeOpenGroup()
    let batch = PagedNativeCommitBatch(sessionID: sessionID, batchID: UUID(), expected: sealedWindow,
      expectedRootRecord: sealedRootRecord,
      firstSequence: first.firstSequence, lastSequence: last.lastSequence, deltas: queue,
      afterBytes: bytes, finalCaretUTF16: finalCaretUTF16,
      historyBaseline: historyBaseline, groupCheckpoints: groups,
      finalSelectionLengthUTF16: finalSelectionLengthUTF16,
      finalFocusAtEnd: finalFocusAtEnd, finalAffinity: finalAffinity)
    inFlight = batch; queue.removeAll(keepingCapacity: true); queuedBytes = 0
    groups.removeAll(keepingCapacity: true); historyBaseline = nil
    unsentBase = bytes
    return (batch, closedGroup)
  }

  /// Admit the retained-root command without pretending its candidate has
  /// already been published. New primitives use G+2 in the distinct arena.
  mutating func installProvisionalHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) throws {
    self = try stagingProvisionalHistory(prepared, admission: admission)
  }

  /// All fallible authority checks, UTF-8 allocation and scalar-map work are
  /// complete before the native owner advances UndoManager. Adoption merely
  /// moves this prevalidated value into its session, with no repeated checks.
  func stagingProvisionalHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) throws -> PagedWorkingWindow {
    try admission.validate(for: prepared)
    guard provisionalHistory == nil, let reservation = reservedPrefix,
      reservation.sessionID == sessionID, reservation.arenaID == arenaID,
      reservation.generation == prepared.command.expectedSequence,
      prepared.command.sessionID == sessionID, prepared.command.sourceArenaID == arenaID,
      prepared.command.sourceWindowID == sealedWindow.windowID,
      prepared.command.expectedRootRecord == sealedRootRecord,
      generation == prepared.command.expectedSequence, sealedGeneration == generation,
      inFlight == nil, capturedPrefixQueue == nil, queue.isEmpty, !isPinned,
      prepared.windowBytes <= Self.targetBytes else {
      throw BoomError.stale("Intervening native input prevents provisional history installation.")
    }
    let source = prepared.window
    let nextBytes = Data(source.text.utf8), nextPoints = Self.scalarPoints(source.text)
    var candidate = self
    candidate.arenaID = admission.provisionalArenaID; candidate.generation = admission.admittedSequence
    candidate.bytes = nextBytes; candidate.points = nextPoints; candidate.unsentBase = nextBytes
    candidate.finalCaretUTF16 = prepared.localCaretUTF16
    candidate.finalSelectionLengthUTF16 = 0; candidate.finalFocusAtEnd = false; candidate.finalAffinity = .downstream
    candidate.openGroup = nil; candidate.groups.removeAll(keepingCapacity: true); candidate.historyBaseline = nil
    candidate.reservedPrefix = nil
    candidate.provisionalHistory = ProvisionalHistory(prepared: prepared, admission: admission)
    return candidate
  }

  /// Seal only the provisional source base. Later input, including a marked
  /// composition, keeps its native bytes, points, generation and queue.
  mutating func acknowledgeHistory(_ ack: PagedNativeHistoryAcknowledgement) throws {
    guard let provisional = provisionalHistory else {
      throw BoomError.stale("No provisional native history command owns this acknowledgement.")
    }
    let prepared = provisional.prepared, admission = provisional.admission
    guard ack.commandID == admission.commandID, ack.preparationID == admission.preparationID,
      ack.sessionID == sessionID, ack.sourceArenaID == admission.sourceArenaID,
      ack.provisionalArenaID == arenaID, ack.sourceWindowID == admission.sourceWindowID,
      ack.preparedWindowID == admission.preparedWindowID,
      ack.expectedSequence == admission.expectedSequence, ack.admittedSequence == admission.admittedSequence,
      ack.expectedRootRecord == sealedRootRecord, ack.sealedRootRecord == prepared.candidateRecord,
      ack.sealedWindow.windowID == prepared.window.windowID,
      ack.sealedWindow.revision == prepared.window.revision,
      ack.sealedWindow.byteStart == prepared.window.byteStart,
      ack.sealedWindow.utf16Start == prepared.window.utf16Start, ack.sealedWindow.lfStart == prepared.window.lfStart,
      ack.sealedBytes == prepared.windowBytes, ack.cursor == prepared.cursor,
      ack.localCaretUTF16 == prepared.localCaretUTF16,
      sealedGeneration == admission.expectedSequence, generation >= admission.admittedSequence,
      inFlight == nil else {
      throw BoomError.stale("Native history acknowledgement differs from its exact provisional command.")
    }
    sealedWindow = ack.sealedWindow; sealedRootRecord = ack.sealedRootRecord
    sealedGeneration = ack.admittedSequence; provisionalHistory = nil
  }

  /// Does not replace native characters: the user may already be composing
  /// later generations. Only the sealed base and ordered acknowledgement move.
  mutating func acknowledge(_ ack: PagedNativeCommitAcknowledgement) throws {
    guard let batch = inFlight, ack.sessionID == sessionID, ack.batchID == batch.batchID,
      ack.lastSequence == batch.lastSequence, ack.expectedRevision == batch.expected.revision else {
      throw BoomError.stale("Native durable acknowledgement belongs to another batch.")
    }
    guard ack.expectedRootRecord == batch.expectedRootRecord,
      batch.expectedRootRecord == sealedRootRecord else {
      throw BoomError.stale("Native root history changed before its durable acknowledgement.")
    }
    // The acknowledgement has no decoded or unchecked construction path;
    // source validation and byte comparison already joined off Main.
    let after = ack.sealedWindow
    guard after.revision.ownerID == sealedWindow.revision.ownerID,
      after.revision.documentID == sealedWindow.revision.documentID,
      after.byteStart == sealedWindow.byteStart,
      after.utf16Start == sealedWindow.utf16Start, after.lfStart == sealedWindow.lfStart,
      ack.sealedBytes == batch.afterBytes.count,
      ack.sealedBytes <= Self.hardBytes else {
      throw BoomError.invalid("Native durable acknowledgement changes the captured window anchor.")
    }
    // Byte equality belongs to the storage implementation's trusted ack
    // construction; do not rescan the resident text for status/caret updates.
    sealedWindow = after; sealedRootRecord = ack.sealedRootRecord
    sealedGeneration = batch.lastSequence; inFlight = nil
    if queue.isEmpty, capturedPrefixQueue == nil { unsentBase = batch.afterBytes }
  }

  /// Storage errors preserve the working arena and exact failed batch. Do not
  /// clear it, roll back later characters or silently retry a stale root.
  var failedBatchRetained: PagedNativeCommitBatch? { inFlight }

  /// A capture may end a chunk of a still-continuing native group. Its UUID
  /// remains unchanged so persisted history can coalesce the following chunk.
  /// Net-zero groups keep their exact deltas/sequence but consume no Undo slot.
  mutating func closeNativeGroup() -> PagedNativeGroupClosureReceipt? { closeOpenGroup() }

  @discardableResult
  private mutating func closeOpenGroup() -> PagedNativeGroupClosureReceipt? {
    guard let group = openGroup else { return nil }
    let hasEffectiveSourceChange = bytes != group.beforeBytes
    let receipt = PagedNativeGroupClosureReceipt(sessionID: sessionID, arenaID: arenaID,
      effectiveGroupID: group.groupID, firstSequence: group.firstSequence,
      lastSequence: group.lastSequence, localCaretUTF16: finalCaretUTF16,
      hasEffectiveSourceChange: hasEffectiveSourceChange)
    if hasEffectiveSourceChange {
      if let previous = groups.last, previous.groupID == group.groupID {
        // A disk seal or key-command boundary can close a chunk without
        // ending the user's typing transaction. Keep one bounded checkpoint
        // and its original Undo selection for adjacent chunks of that group.
        groups[groups.count - 1] = PagedNativeGroupCheckpoint(groupID: group.groupID,
          firstSequence: previous.firstSequence, lastSequence: group.lastSequence,
          beforeCursor: previous.beforeCursor, afterBytes: bytes, caretUTF16: finalCaretUTF16,
          afterSelectionLengthUTF16: finalSelectionLengthUTF16,
          afterFocusAtEnd: finalFocusAtEnd, afterAffinity: finalAffinity)
      } else {
        groups.append(PagedNativeGroupCheckpoint(groupID: group.groupID,
          firstSequence: group.firstSequence, lastSequence: group.lastSequence,
          beforeCursor: group.beforeCursor, afterBytes: bytes, caretUTF16: finalCaretUTF16,
          afterSelectionLengthUTF16: finalSelectionLengthUTF16,
          afterFocusAtEnd: finalFocusAtEnd, afterAffinity: finalAffinity))
      }
      if groups.count > PagedRootHistory.maximumEntries { historyBaseline = groups.removeFirst() }
    }
    openGroup = nil
    return receipt
  }

  private mutating func compactUnsent(groupID: UUID) {
    let first = queue.first?.firstSequence ?? generation
    queue = [PagedNativeDelta(firstSequence: first, lastSequence: generation,
      localByteStart: 0, oldBytes: unsentBase, newBytes: bytes, groupID: groupID)]
    queuedBytes = queue[0].chargedBytes
  }

  private func localBytes(forUTF16 range: NSRange) throws -> Range<Int> {
    guard range.location >= 0, range.length >= 0, range.location <= localUTF16Count,
      range.length <= localUTF16Count - range.location else {
      throw BoomError.invalid("Native range is outside the resident arena.")
    }
    let start = try point(atUTF16: range.location), end = try point(atUTF16: range.location + range.length)
    return points[start].byte..<points[end].byte
  }
  private func point(atUTF16 offset: Int) throws -> Int {
    var low = 0, high = points.count
    while low < high {
      let middle = low + (high - low) / 2
      if points[middle].utf16 < offset { low = middle + 1 } else { high = middle }
    }
    guard low < points.count, points[low].utf16 == offset else {
      throw BoomError.invalid("Native range splits a Unicode scalar.")
    }
    return low
  }
  private static func scalarPoints(_ text: String) -> [ScalarPoint] {
    var points = [ScalarPoint(byte: 0, utf16: 0)]
    points.reserveCapacity(min(Self.hardBytes + 1, text.utf8.count + 1))
    var byte = 0, units = 0
    for scalar in text.unicodeScalars {
      let value = scalar.value
      byte += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
      units += value < 0x10000 ? 1 : 2
      points.append(ScalarPoint(byte: byte, utf16: units))
    }
    return points
  }
}
