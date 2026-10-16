import BoomCore
import Foundation

private let pagedCanonicalZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

/// Immutable metadata read from the actual complete file history. Foundation
/// owns live Undo/Redo; the worker never advances a parallel native timeline.
struct PagedNativeCanonicalHistoryProjection: Sendable, Equatable {
  static let chargedBytes = 65_536
  enum Scope: Sendable, Equatable {
    case opening(sessionID: UUID, windowID: UUID)
    case nativeBatch(sessionID: UUID, batchID: UUID, first: UInt64, last: UInt64)
    var sessionID: UUID {
      switch self { case .opening(let session, _), .nativeBatch(let session, _, _, _): return session }
    }
    fileprivate func validate() throws {
      switch self {
      case .opening(let session, let window):
        guard session != pagedCanonicalZero, window != pagedCanonicalZero else {
          throw BoomError.invalid("Canonical opening lacks its actual source identity.")
        }
      case .nativeBatch(let session, let batch, let first, let last):
        guard session != pagedCanonicalZero, batch != pagedCanonicalZero, first > 0, first <= last else {
          throw BoomError.invalid("Canonical save has another captured native prefix.")
        }
      }
    }
  }
  let record: PagedDocumentRootRecord
  let beforeRecord: PagedDocumentRootRecord?
  let currentCursor: PagedSealedCursor
  let undo: [PagedRootHistoryEntry]
  let redo: [PagedRootHistoryEntry]
  let activeGroup: UUID?
  let scope: Scope
  /// Actual entered job provenance. It does not grant future page/root access.
  let producer: PagedTextRootLease

  init(storageHistory history: PagedRootHistory, record: PagedDocumentRootRecord,
    beforeRecord: PagedDocumentRootRecord?, beforeHistory: PagedRootHistory?,
    scope: Scope, producer: PagedTextRootLease) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Canonical file history belongs to storage execution.") }
    try record.validate(); try history.validate(expected: record.document.revision); try scope.validate()
    guard history.generation == record.historyGeneration, producer.ownerID == history.ownerID,
      producer.engineIncarnation != pagedCanonicalZero, producer.id != pagedCanonicalZero,
      !(history.undo + history.redo).contains(where: { $0.groupID == pagedCanonicalZero }),
      history.activeGroup != pagedCanonicalZero else {
      throw BoomError.invalid("Canonical file history has another actual record or producer.")
    }
    switch scope {
    case .opening:
      guard beforeRecord == nil, beforeHistory == nil else {
        throw BoomError.invalid("Cold history opening cannot impersonate a native save.")
      }
    case .nativeBatch:
      guard let beforeRecord, let beforeHistory else { throw BoomError.invalid("Canonical save lost its full before record.") }
      try beforeRecord.validate(); try beforeHistory.validate(expected: beforeRecord.document.revision)
      guard beforeHistory.generation == beforeRecord.historyGeneration,
        beforeRecord.document.id == record.document.id,
        beforeRecord.document.revision.ownerID == record.document.revision.ownerID,
        beforeRecord.document.title.utf8.elementsEqual(record.document.title.utf8),
        beforeRecord.historyGeneration < UInt64.max, record.historyGeneration == beforeRecord.historyGeneration + 1 else {
        throw BoomError.stale("Canonical save did not advance the exact admitted history epoch.")
      }
    }
    self.record = record; self.beforeRecord = beforeRecord; currentCursor = history.currentCursor
    undo = history.undo; redo = history.redo; activeGroup = history.activeGroup
    self.scope = scope; self.producer = producer
  }
  func admit(record expected: PagedDocumentRootRecord, sessionID: UUID,
    engineIncarnation: UUID, scope expectedScope: Scope) throws {
    guard record == expected, producer.ownerID == expected.document.revision.ownerID,
      producer.engineIncarnation == engineIncarnation, scope == expectedScope,
      scope.sessionID == sessionID, undo.count + redo.count <= PagedRootHistory.maximumEntries else {
      throw BoomError.stale("Canonical file history differs from its actual receiving source.")
    }
  }
}

/// Real retained cursor and bounded opening island before native exposure.
struct PagedNativeCanonicalOpening: Sendable {
  // Current + at most 100 immutable history seeds, and bounded conversion scratch.
  static let maximumPayloadBytes = (PagedRootHistory.maximumEntries + 2) * PagedWorkingWindow.targetBytes
  let sessionID: UUID
  let record: PagedDocumentRootRecord
  let window: PagedTextWindow
  let history: PagedNativeCanonicalHistoryProjection
  let localCaretUTF16: Int
  let preparedUndo: [PagedNativeLogicalHistoryEntry]?
  let preparedRedo: [PagedNativeLogicalHistoryEntry]?
  let historyPayloadBytes: Int
  let prepareNativeHandoff: @Sendable () throws -> (@Sendable () -> Void)
}
