import BoomCore
import Foundation

/// Native command intent only, never a decoded model edit or retained-root
/// grant. Preparation does not admit its next sequence or publish a head.
struct PagedNativeHistoryMoveCommand: Sendable, Equatable {
  let sessionID: UUID
  let commandID: UUID
  let sourceArenaID: UUID
  let sourceWindowID: UUID
  let expectedSequence: UInt64
  let expectedRootRecord: PagedDocumentRootRecord
  let handle: PagedNativeHistoryHandle
  let canonicalSelection: PagedNativeSealedHistorySelection?

  init(sessionID: UUID, commandID: UUID, sourceArenaID: UUID, sourceWindowID: UUID,
    expectedSequence: UInt64, expectedRootRecord: PagedDocumentRootRecord,
    handle: PagedNativeHistoryHandle, canonicalSelection: PagedNativeSealedHistorySelection? = nil) {
    self.sessionID = sessionID; self.commandID = commandID; self.sourceArenaID = sourceArenaID
    self.sourceWindowID = sourceWindowID; self.expectedSequence = expectedSequence
    self.expectedRootRecord = expectedRootRecord; self.handle = handle; self.canonicalSelection = canonicalSelection
  }

  static func == (left: Self, right: Self) -> Bool {
    left.sessionID == right.sessionID && left.commandID == right.commandID
      && left.sourceArenaID == right.sourceArenaID && left.sourceWindowID == right.sourceWindowID
      && left.expectedSequence == right.expectedSequence && left.expectedRootRecord == right.expectedRootRecord
      && left.handle.documentID == right.handle.documentID && left.handle.groupID == right.handle.groupID
      && left.handle.direction == right.handle.direction && left.canonicalSelection == right.canonicalSelection
  }
  func validate() throws {
    try expectedRootRecord.validate()
    guard ![sessionID, commandID, sourceArenaID, sourceWindowID, handle.groupID].contains(Self.zero),
      handle.documentID == expectedRootRecord.document.id else {
      throw BoomError.invalid("Native history command has inconsistent controller, arena or document identity.")
    }
    if let canonicalSelection {
      guard canonicalSelection.record == expectedRootRecord, canonicalSelection.sessionID == sessionID,
        canonicalSelection.coveredSequence == expectedSequence,
        canonicalSelection.entry.groupID == handle.groupID, canonicalSelection.direction == handle.direction else {
        throw BoomError.stale("Native command differs from its exact canonical record/direction/slot selection.")
      }
    }
    _ = try nextSequence()
  }
  func nextSequence() throws -> UInt64 {
    let next = expectedSequence.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Native command sequence is exhausted.") }
    return next.partialValue
  }
  fileprivate static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// Worker-produced unpublished history metadata and one immutable retained
/// source island. The backend pins this value until explicit disposition.
struct PagedNativePreparedHistoryMove: Sendable, Equatable {
  let routeID: UUID
  let preparationID: UUID
  let command: PagedNativeHistoryMoveCommand
  let candidateRecord: PagedDocumentRootRecord
  let window: PagedTextWindow
  let cursor: PagedSealedCursor
  let localCaretUTF16: Int
  let windowBytes: Int
  let canonicalHistory: PagedNativeCanonicalHistoryProjection?

  init(validating command: PagedNativeHistoryMoveCommand, routeID: UUID,
    candidateRecord: PagedDocumentRootRecord, window: PagedTextWindow,
    cursor: PagedSealedCursor, localCaretUTF16: Int,
    canonicalHistory: PagedNativeCanonicalHistoryProjection? = nil) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("History preparation belongs to storage execution.") }
    try command.validate(); try candidateRecord.validate()
    let generation = command.expectedRootRecord.historyGeneration.addingReportingOverflow(1)
    guard routeID != PagedNativeHistoryMoveCommand.zero, !generation.overflow,
      candidateRecord.historyGeneration == generation.partialValue,
      candidateRecord.document.id == command.expectedRootRecord.document.id,
      candidateRecord.document.title.utf8.elementsEqual(command.expectedRootRecord.document.title.utf8),
      candidateRecord.document.revision.ownerID == command.expectedRootRecord.document.revision.ownerID,
      candidateRecord.document.revision == window.revision else {
      throw BoomError.invalid("Prepared history loses its exact source/history identity.")
    }
    try Self.validate(window: window, cursor: cursor, localCaretUTF16: localCaretUTF16)
    self.routeID = routeID; preparationID = UUID(); self.command = command
    self.candidateRecord = candidateRecord; self.window = window; self.cursor = cursor
    self.localCaretUTF16 = localCaretUTF16; windowBytes = window.text.utf8.count
    if let canonicalHistory {
      guard canonicalHistory.record == candidateRecord, canonicalHistory.beforeRecord == command.expectedRootRecord,
        canonicalHistory.scope == .historyCandidate(sessionID: command.sessionID, routeID: routeID,
          commandID: command.commandID, expected: command.expectedSequence) else {
        throw BoomError.invalid("History preparation lost its canonical candidate scope.")
      }
    }
    self.canonicalHistory = canonicalHistory
  }
  static func == (left: Self, right: Self) -> Bool {
    left.routeID == right.routeID && left.preparationID == right.preparationID && left.command == right.command
      && left.candidateRecord == right.candidateRecord && left.window.revision == right.window.revision
      && left.window.windowID == right.window.windowID && left.window.byteStart == right.window.byteStart
      && left.window.utf16Start == right.window.utf16Start && left.window.lfStart == right.window.lfStart
      && left.window.text.utf8.elementsEqual(right.window.text.utf8)
      && left.cursor == right.cursor && left.localCaretUTF16 == right.localCaretUTF16
      && left.windowBytes == right.windowBytes && left.canonicalHistory == right.canonicalHistory
  }
  static func validate(window: PagedTextWindow, cursor: PagedSealedCursor, localCaretUTF16: Int) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("History island validation belongs to storage execution.") }
    try window.validate(); try cursor.validate(in: window.revision)
    guard window.text.utf8.count <= PagedWorkingWindow.targetBytes, localCaretUTF16 >= 0 else {
      throw BoomError.budget("Prepared history exceeds its fixed native island.")
    }
    var byte = 0, units = 0
    for scalar in window.text.unicodeScalars {
      if units == localCaretUTF16 { break }
      let value = scalar.value
      byte += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
      units += value < 0x10000 ? 1 : 2
    }
    let globalByte = window.byteStart.addingReportingOverflow(UInt64(byte))
    let globalUnit = window.utf16Start.addingReportingOverflow(UInt64(units))
    // This island proves the exact focus scalar. The real worker independently
    // admits the normalized lower byte and a distant other endpoint in its tree.
    guard units == localCaretUTF16, !globalByte.overflow, !globalUnit.overflow,
      globalUnit.partialValue == cursor.focusUTF16,
      (cursor.focusUTF16 != cursor.utf16Offset || globalByte.partialValue == cursor.byteOffset) else {
      throw BoomError.invalid("Prepared history cursor splits a scalar or differs from its exact source coordinates.")
    }
  }
}

/// Created only after Main synchronously admits the command and provisionally
/// installs the prepared source. Later input belongs to this distinct arena.
struct PagedNativeHistoryAdmission: Sendable, Equatable {
  let commandID: UUID
  let preparationID: UUID
  let sessionID: UUID
  let sourceArenaID: UUID
  let provisionalArenaID: UUID
  let sourceWindowID: UUID
  let preparedWindowID: UUID
  let expectedSequence: UInt64
  let admittedSequence: UInt64
  let expectedRootRecord: PagedDocumentRootRecord

  func validate(for prepared: PagedNativePreparedHistoryMove) throws {
    let command = prepared.command
    try command.validate()
    guard commandID == command.commandID, preparationID == prepared.preparationID,
      sessionID == command.sessionID, sourceArenaID == command.sourceArenaID,
      provisionalArenaID != PagedNativeHistoryMoveCommand.zero, provisionalArenaID != sourceArenaID,
      sourceWindowID == command.sourceWindowID, preparedWindowID == prepared.window.windowID,
      expectedSequence == command.expectedSequence, admittedSequence == (try command.nextSequence()),
      expectedRootRecord == command.expectedRootRecord else {
      throw BoomError.stale("Native history admission has another command, arena, sequence or complete root record.")
    }
  }
}

/// An observation of input already admitted while preparation was in flight.
/// It is a conflict disposition, never permission to rebase or discard input.
struct PagedNativeHistoryInputObservation: Sendable, Equatable {
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
  let compositionPinned: Bool
  func validate(for prepared: PagedNativePreparedHistoryMove) throws {
    let command = prepared.command
    guard sessionID == command.sessionID, arenaID != PagedNativeHistoryMoveCommand.zero,
      generation >= command.expectedSequence,
      generation > command.expectedSequence || arenaID != command.sourceArenaID || compositionPinned else {
      throw BoomError.invalid("History input conflict has no intervening admitted input or arena change.")
    }
  }
}

enum PagedNativeHistoryCommandConflict: Error, Sendable {
  case pendingCommand(UUID)
  case interveningInput(UUID, PagedNativeHistoryInputObservation)
  case publicationUnresolved(UUID)
}

struct PagedNativeHistoryInputConflictReceipt: Sendable {
  let prepared: PagedNativePreparedHistoryMove
  let observation: PagedNativeHistoryInputObservation
}

/// Only an explicit owner disposition releases an unadmitted command. A
/// retained-owner transfer must enter that owner's pin/intent ledger first.
enum PagedNativeHistoryIntentDisposition: Sendable {
  case explicitlyAbandoned
  case transferredToRetainedOwner(receiptID: UUID)
}
struct PagedNativeHistoryIntentDispositionReceipt: Sendable {
  let prepared: PagedNativePreparedHistoryMove
  let disposition: PagedNativeHistoryIntentDisposition
}

/// Both records remain reachable while preparation, conflict, provisional
/// publication or installation is unresolved. Future GC must admit these pins.
struct PagedNativeHistoryReachability: Sendable {
  enum Phase: Sendable { case prepared, inputConflict, admitted, verifiedNotPublished, published }
  let routeID: UUID
  let commandID: UUID
  let preparationID: UUID
  let phase: Phase
  let before: PagedDocumentRootRecord
  let candidate: PagedDocumentRootRecord
}

/// A durable result only. It does not install or overwrite native characters.
struct PagedNativeHistoryAcknowledgement: Sendable {
  let commandID: UUID
  let preparationID: UUID
  let sessionID: UUID
  let sourceArenaID: UUID
  let provisionalArenaID: UUID
  let sourceWindowID: UUID
  let preparedWindowID: UUID
  let expectedSequence: UInt64
  let admittedSequence: UInt64
  let expectedRootRecord: PagedDocumentRootRecord
  let sealedRootRecord: PagedDocumentRootRecord
  let sealedWindow: PagedTextWindow
  let cursor: PagedSealedCursor
  let localCaretUTF16: Int
  let sealedBytes: Int
  let canonicalHistory: PagedNativeCanonicalHistoryProjection?

  init(validating prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission,
    publishedRecord: PagedDocumentRootRecord, readWindow: PagedTextWindow,
    canonicalHistory: PagedNativeCanonicalHistoryProjection? = nil) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("History acknowledgement belongs to storage execution.") }
    try admission.validate(for: prepared)
    try PagedNativePreparedHistoryMove.validate(window: readWindow, cursor: prepared.cursor,
      localCaretUTF16: prepared.localCaretUTF16)
    guard publishedRecord == prepared.candidateRecord, readWindow.revision == prepared.window.revision,
      readWindow.byteStart == prepared.window.byteStart, readWindow.utf16Start == prepared.window.utf16Start,
      readWindow.lfStart == prepared.window.lfStart,
      readWindow.text.utf8.elementsEqual(prepared.window.text.utf8) else {
      throw BoomError.invalid("History publication differs from its authenticated preparation.")
    }
    commandID = admission.commandID; preparationID = admission.preparationID; sessionID = admission.sessionID
    sourceArenaID = admission.sourceArenaID; provisionalArenaID = admission.provisionalArenaID
    sourceWindowID = admission.sourceWindowID; preparedWindowID = admission.preparedWindowID
    expectedSequence = admission.expectedSequence; admittedSequence = admission.admittedSequence
    // Actual readback was admitted above. Reuse the immutable preparation's
    // exact window identity/backing rather than retaining a second source copy.
    expectedRootRecord = admission.expectedRootRecord; sealedRootRecord = publishedRecord; sealedWindow = prepared.window
    cursor = prepared.cursor; localCaretUTF16 = prepared.localCaretUTF16; sealedBytes = prepared.windowBytes
    if let canonicalHistory {
      guard canonicalHistory.record == publishedRecord,
        canonicalHistory.beforeRecord == admission.expectedRootRecord,
        canonicalHistory.scope == .historyPublished(sessionID: admission.sessionID, routeID: prepared.routeID,
          commandID: admission.commandID, preparationID: admission.preparationID,
          expected: admission.expectedSequence, admitted: admission.admittedSequence) else {
        throw BoomError.invalid("History ACK lost its exact canonical publication scope.")
      }
    }
    self.canonicalHistory = canonicalHistory
  }
}

/// Inspection first recovers any authenticated journal, then classifies the
/// exact document record. Only a verified before-record permits explicit finish.
enum PagedNativeHistoryPublicationInspection: Sendable {
  case published(PagedNativeHistoryAcknowledgement)
  case notPublished
  case conflict(PagedDocumentRootRecord?)
}
enum PagedNativeHistoryRecovery: Sendable {
  case published(PagedNativeHistoryAcknowledgement)
  case verifiedNotPublished(verificationID: UUID)
  case conflict(PagedDocumentRootRecord?)
}
