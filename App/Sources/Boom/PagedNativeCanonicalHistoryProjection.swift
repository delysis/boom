import BoomCore
import Foundation

private let pagedCanonicalZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

/// This value is not Codable, a cache, a root lease or another
/// source history. The existing engine produces it from the actual admitted
/// encrypted history while its worker job already owns every referenced root.
struct PagedNativeCanonicalHistoryProjection: Sendable, Equatable {
  /// Conservative admission charge for one immutable metadata projection.
  /// This is a reservation, not a measured Swift allocator footprint.
  static let chargedBytes = 65_536

  enum Scope: Sendable, Equatable {
    case opening(sessionID: UUID, windowID: UUID)
    case nativeBatch(sessionID: UUID, batchID: UUID, first: UInt64, last: UInt64)
    case historyCandidate(sessionID: UUID, routeID: UUID, commandID: UUID, expected: UInt64)
    case historyPublished(sessionID: UUID, routeID: UUID, commandID: UUID,
      preparationID: UUID, expected: UInt64, admitted: UInt64)

    var sessionID: UUID {
      switch self {
      case .opening(let session, _), .nativeBatch(let session, _, _, _),
        .historyCandidate(let session, _, _, _), .historyPublished(let session, _, _, _, _, _): return session
      }
    }
    var coveredSequence: UInt64 {
      switch self {
      case .opening: return 0
      case .nativeBatch(_, _, _, let last): return last
      case .historyCandidate(_, _, _, let expected): return expected
      case .historyPublished(_, _, _, _, _, let admitted): return admitted
      }
    }
    fileprivate func validate() throws {
      var identities = [sessionID]
      switch self {
      case .opening(_, let window): identities.append(window)
      case .nativeBatch(_, let batch, let first, let last):
        identities.append(batch)
        guard first > 0, first <= last else { throw BoomError.invalid("Canonical native history has an invalid batch prefix.") }
      case .historyCandidate(_, let route, let command, let expected):
        identities += [route, command]
        guard expected < UInt64.max else { throw BoomError.budget("Canonical history command sequence is exhausted.") }
      case .historyPublished(_, let route, let command, let preparation, let expected, let admitted):
        identities += [route, command, preparation]
        guard expected < UInt64.max, admitted == expected + 1 else {
          throw BoomError.invalid("Canonical history publication lost its ordered command sequence.")
        }
      }
      guard !identities.contains(pagedCanonicalZero) else {
        throw BoomError.invalid("Canonical history lacks an exact controller or producer identity.")
      }
    }
  }

  /// Made by the actual commit-plan replay. A closed native chunk is mapped
  /// to the full retained BEFORE root/cursor, never to a guessed UUID match.
  /// Nil means the replay expired this meaningful checkpoint before final seal.
  struct Resolution: Sendable, Equatable {
    let groupID: UUID
    let firstSequence: UInt64
    let lastSequence: UInt64
    let undoIndex: Int?
    let entry: PagedRootHistoryEntry?
  }

  let record: PagedDocumentRootRecord
  let beforeRecord: PagedDocumentRootRecord?
  let currentCursor: PagedSealedCursor
  let undo: [PagedRootHistoryEntry]
  let redo: [PagedRootHistoryEntry]
  let activeGroup: UUID?
  let scope: Scope
  /// A provenance receipt copied from the real entered job. Its ID may cease
  /// to be live after same-engine transfer; it never itself establishes custody.
  let producer: PagedTextRootLease
  let resolutions: [Resolution]
  /// Final same-direction slot -> exact before-record slot. Nil identifies a
  /// newly appended/inverse slot. Indices distinguish even identical entries.
  let undoFromBefore: [Int?]
  let redoFromBefore: [Int?]

  /// The engine constructs this on its queue after authenticating the exact
  /// record/history and checking actual job claims. Value validation alone
  /// does not authenticate storage.
  init(storageHistory history: PagedRootHistory, record: PagedDocumentRootRecord,
    beforeRecord: PagedDocumentRootRecord?, beforeHistory: PagedRootHistory?,
    scope: Scope, producer: PagedTextRootLease,
    undoFromBefore: [Int?], redoFromBefore: [Int?], resolutions: [Resolution] = []) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Canonical history construction belongs to the existing storage owner.") }
    try record.validate(); try history.validate(expected: record.document.revision); try scope.validate()
    guard history.generation == record.historyGeneration,
      producer.ownerID == history.ownerID,
      producer.engineIncarnation != pagedCanonicalZero,
      producer.id != pagedCanonicalZero,
      resolutions.count <= PagedRootHistory.maximumEntries,
      !(history.undo + history.redo).contains(where: { $0.groupID == pagedCanonicalZero }),
      history.activeGroup != pagedCanonicalZero else {
      throw BoomError.invalid("Canonical history has another authenticated record or producer.")
    }
    guard undoFromBefore.count == history.undo.count, redoFromBefore.count == history.redo.count else {
      throw BoomError.invalid("Canonical history lacks its bounded ordered slot lineage.")
    }
    if let beforeRecord {
      try beforeRecord.validate()
      guard let beforeHistory else { throw BoomError.invalid("Canonical history lacks the actual admitted before history.") }
      try beforeHistory.validate(expected: beforeRecord.document.revision)
      guard beforeHistory.generation == beforeRecord.historyGeneration else {
        throw BoomError.invalid("Canonical history before-lineage has another authenticated epoch.")
      }
      try Self.validateLineage(undoFromBefore, before: beforeHistory.undo, after: history.undo)
      try Self.validateLineage(redoFromBefore, before: beforeHistory.redo, after: history.redo)
      guard beforeRecord.document.id == record.document.id,
        beforeRecord.document.revision.ownerID == record.document.revision.ownerID,
        beforeRecord.document.title.utf8.elementsEqual(record.document.title.utf8),
        beforeRecord.historyGeneration < record.historyGeneration else {
        throw BoomError.stale("Canonical history does not advance its complete captured document record.")
      }
    }
    switch scope {
    case .opening:
      guard beforeRecord == nil, beforeHistory == nil, resolutions.isEmpty,
        undoFromBefore.allSatisfy({ $0 == nil }), redoFromBefore.allSatisfy({ $0 == nil }) else { throw BoomError.invalid("Opening metadata cannot impersonate an accepted native seal.") }
    case .historyCandidate, .historyPublished:
      guard let beforeRecord, beforeRecord.historyGeneration < UInt64.max,
        record.historyGeneration == beforeRecord.historyGeneration + 1, resolutions.isEmpty else {
        throw BoomError.invalid("Canonical history move has another exact root/history epoch.")
      }
    case .nativeBatch(_, _, let first, let last):
      guard beforeRecord != nil else { throw BoomError.invalid("Native history seal lacks its full before record.") }
      var end = first - 1
      for resolution in resolutions {
        guard resolution.groupID != pagedCanonicalZero,
          resolution.firstSequence > end, resolution.firstSequence <= resolution.lastSequence,
          resolution.lastSequence <= last else {
          throw BoomError.invalid("Canonical native group resolutions have unordered coverage.")
        }
        guard (resolution.entry == nil) == (resolution.undoIndex == nil) else {
          throw BoomError.invalid("Canonical checkpoint expiry loses its exact slot disposition.")
        }
        if let entry = resolution.entry, let index = resolution.undoIndex {
          guard history.undo.indices.contains(index), entry.groupID == resolution.groupID,
            history.undo[index] == entry else {
            throw BoomError.invalid("Canonical group resolution is not the full retained history entry.")
          }
        }
        end = resolution.lastSequence
      }
    }
    self.record = record; self.beforeRecord = beforeRecord; currentCursor = history.currentCursor
    undo = history.undo; redo = history.redo; activeGroup = history.activeGroup
    self.scope = scope; self.producer = producer; self.resolutions = resolutions
    self.undoFromBefore = undoFromBefore; self.redoFromBefore = redoFromBefore
  }

  private static func validateLineage(_ indices: [Int?], before: [PagedRootHistoryEntry],
    after: [PagedRootHistoryEntry]) throws {
    let retained = indices.compactMap { $0 }
    guard Set(retained).count == retained.count, retained == retained.sorted() else {
      throw BoomError.invalid("Canonical lineage cannot duplicate a before-record slot.")
    }
    for (index, prior) in indices.enumerated() {
      if let prior {
        guard before.indices.contains(prior), before[prior] == after[index] else {
          throw BoomError.invalid("Canonical slot lineage differs from its actual retained root and cursor.")
        }
      }
    }
  }

  /// Main checks only small exact identities. This does not read pages,
  /// encode history, hash text, scan a window or authorize root collection.
  func admit(record expected: PagedDocumentRootRecord, sessionID: UUID,
    engineIncarnation: UUID, scope expectedScope: Scope) throws {
    guard record == expected, producer.ownerID == expected.document.revision.ownerID,
      producer.engineIncarnation == engineIncarnation,
      scope == expectedScope, scope.sessionID == sessionID,
      undo.count + redo.count <= PagedRootHistory.maximumEntries else {
      throw BoomError.stale("Canonical history receipt differs from the actual source installation.")
    }
  }

  /// A fresh recovery job may authenticate the same already-installed seal.
  /// Producer.id is that job's provenance, not the identity of its publication.
  /// Every published source/history/slot/coverage field remains exact. This
  /// comparison grants neither authentication nor a new root-custody finish.
  func hasSamePublishedMetadata(as other: Self) -> Bool {
    switch scope { case .nativeBatch, .historyPublished: break; default: return false }
    return record == other.record && beforeRecord == other.beforeRecord
      && currentCursor == other.currentCursor && undo == other.undo && redo == other.redo
      && activeGroup == other.activeGroup && scope == other.scope
      && resolutions == other.resolutions && undoFromBefore == other.undoFromBefore
      && redoFromBefore == other.redoFromBefore
      && producer.ownerID == other.producer.ownerID
      && producer.engineIncarnation == other.producer.engineIncarnation
  }

  func selection(_ direction: PagedNativeHistoryHandle.Direction) throws -> PagedNativeSealedHistorySelection {
    guard let entry = direction == .undo ? undo.last : redo.last else {
      throw BoomError.unavailable("The authenticated retained-root direction is empty.")
    }
    return PagedNativeSealedHistorySelection(record: record, entry: entry, direction: direction,
      index: (direction == .undo ? undo.count : redo.count) - 1,
      sessionID: scope.sessionID, coveredSequence: scope.coveredSequence,
      engineIncarnation: producer.engineIncarnation)
  }
}

/// A source selection is distinct from a Foundation node/ordinal and from a
/// native group UUID. Worker preparation must compare every field against its
/// exact current full record and freshly admitted retained-history top.
struct PagedNativeSealedHistorySelection: Sendable, Equatable {
  let record: PagedDocumentRootRecord
  let entry: PagedRootHistoryEntry
  let direction: PagedNativeHistoryHandle.Direction
  let index: Int
  let sessionID: UUID
  let coveredSequence: UInt64
  let engineIncarnation: UUID
  func admit(record expected: PagedDocumentRootRecord, history: PagedRootHistory,
    sessionID expectedSession: UUID, sequence: UInt64, engineIncarnation expectedEngine: UUID) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Canonical root selection belongs to storage admission.") }
    try history.validate(expected: expected.document.revision)
    let entries = direction == .undo ? history.undo : history.redo
    let top = entries.last
    guard record == expected, history.generation == expected.historyGeneration,
      sessionID == expectedSession, coveredSequence == sequence, engineIncarnation == expectedEngine,
      index == entries.count - 1, entry == top else {
      throw BoomError.stale("The requested canonical history entry is not this exact admitted source top.")
    }
  }
}

/// Opening uses the actual retained cursor and one bounded island, not the
/// first document page. Physical input remains unexposed until metadata-only
/// Foundation construction and the exact initial caret have joined on Main.
struct PagedNativeCanonicalOpening: Sendable {
  let sessionID: UUID
  let record: PagedDocumentRootRecord
  let window: PagedTextWindow
  let history: PagedNativeCanonicalHistoryProjection
  let localCaretUTF16: Int
}

/// The exact already-published source ACK delivered inside the Session's
/// owned throwing metadata hook, before actual storage installation custody
/// finishes. Opening and uncommitted candidates cannot create this receipt.
enum PagedNativeCanonicalSeal: Sendable {
  case native(PagedNativeCommitAcknowledgement)
  case history(PagedNativeHistoryAcknowledgement)
  var projection: PagedNativeCanonicalHistoryProjection? {
    switch self { case .native(let ack): return ack.canonicalHistory; case .history(let ack): return ack.canonicalHistory }
  }
}

/// Ephemeral worker metadata, advanced alongside the actual RootHistory
/// methods. It names positions even when two retained entries are identical.
/// It never decides a source revision or survives as an independent history.
struct PagedNativeHistorySlotLineage {
  private struct Binding {
    let checkpoint: PagedNativeGroupCheckpoint
    var index: Int?
  }
  private(set) var undo: [Int?]
  private(set) var redo: [Int?]
  private var bindings: [Binding] = []
  init(_ history: PagedRootHistory) {
    undo = history.undo.indices.map { Optional($0) }
    redo = history.redo.indices.map { Optional($0) }
    bindings.reserveCapacity(PagedRootHistory.maximumEntries)
  }
  mutating func expiredBaseline() { undo.removeAll(); redo.removeAll(); bindings.removeAll() }
  mutating func nativeRecord(priorRevision: PagedTextRevision, priorActive: UUID?,
    priorUndoCount: Int, beforeCursor: PagedSealedCursor,
    after: PagedRootHistory, checkpoint: PagedNativeGroupCheckpoint) throws {
    guard bindings.count < PagedRootHistory.maximumEntries else {
      throw BoomError.budget("Canonical checkpoint lineage exceeds its admitted plan.")
    }
    if priorRevision != after.current {
      if priorActive != checkpoint.groupID {
        undo.append(nil)
        let expired = max(0, priorUndoCount + 1 - after.undo.count)
        guard expired <= 1, expired <= undo.count else { throw BoomError.invalid("Native history lineage has an invalid expiry.") }
        if expired == 1 {
          undo.removeFirst()
          for index in bindings.indices {
            if let old = bindings[index].index { bindings[index].index = old == 0 ? nil : old - 1 }
          }
        }
      }
      redo.removeAll()
    }
    guard undo.count == after.undo.count, redo.count == after.redo.count,
      let entry = after.undo.last, entry.groupID == checkpoint.groupID else {
      throw BoomError.invalid("Meaningful native group has no actual retained canonical slot.")
    }
    if priorActive != checkpoint.groupID {
      guard entry.revision == priorRevision, entry.cursor == beforeCursor else {
        throw BoomError.invalid("Canonical group lost its exact observed before-source cursor.")
      }
    }
    bindings.append(Binding(checkpoint: checkpoint, index: after.undo.count - 1))
  }
  mutating func moved(_ direction: PagedNativeHistoryHandle.Direction) {
    switch direction {
    case .undo: _ = undo.removeLast(); redo.append(nil)
    case .redo: _ = redo.removeLast(); undo.append(nil)
    }
  }
  func resolutions(_ history: PagedRootHistory) throws -> [PagedNativeCanonicalHistoryProjection.Resolution] {
    guard undo.count == history.undo.count, redo.count == history.redo.count else {
      throw BoomError.invalid("Canonical slot lineage differs from the actual final history.")
    }
    return try bindings.map { binding in
      if let index = binding.index {
        guard history.undo.indices.contains(index), history.undo[index].groupID == binding.checkpoint.groupID else {
          throw BoomError.invalid("Canonical checkpoint names another final retained slot.")
        }
      }
      return PagedNativeCanonicalHistoryProjection.Resolution(groupID: binding.checkpoint.groupID,
        firstSequence: binding.checkpoint.firstSequence, lastSequence: binding.checkpoint.lastSequence,
        undoIndex: binding.index, entry: binding.index.map { history.undo[$0] })
    }
  }
}
