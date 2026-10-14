import BoomCore
import Foundation

enum PagedSelectionAffinity: UInt8, Codable, Equatable, Sendable {
  case upstream = 0, downstream = 1
}

/// A sealed source cursor. Working NSRanges are never encoded here.
struct PagedSealedCursor: Codable, Equatable, Sendable {
  let byteOffset: UInt64
  let utf16Offset: UInt64
  let selectionLengthUTF16: UInt64
  let focusAtEnd: Bool
  let affinity: PagedSelectionAffinity
  private enum CodingKeys: String, CodingKey { case byteOffset, utf16Offset, selectionLengthUTF16, focusAtEnd, affinity }
  init(byteOffset: UInt64, utf16Offset: UInt64, selectionLengthUTF16: UInt64 = 0,
    focusAtEnd: Bool = false, affinity: PagedSelectionAffinity = .downstream) {
    self.byteOffset = byteOffset; self.utf16Offset = utf16Offset
    self.selectionLengthUTF16 = selectionLengthUTF16
    self.focusAtEnd = focusAtEnd; self.affinity = affinity
  }
  // Callers admit the range against its immutable revision before reading its focus.
  var focusUTF16: UInt64 { focusAtEnd ? utf16Offset + selectionLengthUTF16 : utf16Offset }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    byteOffset = try values.decode(UInt64.self, forKey: .byteOffset)
    utf16Offset = try values.decode(UInt64.self, forKey: .utf16Offset)
    selectionLengthUTF16 = try values.decodeIfPresent(UInt64.self, forKey: .selectionLengthUTF16) ?? 0
    focusAtEnd = try values.decodeIfPresent(Bool.self, forKey: .focusAtEnd) ?? false
    affinity = try values.decodeIfPresent(PagedSelectionAffinity.self, forKey: .affinity) ?? .downstream
  }
  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(byteOffset, forKey: .byteOffset)
    try values.encode(utf16Offset, forKey: .utf16Offset)
    if selectionLengthUTF16 > 0 { try values.encode(selectionLengthUTF16, forKey: .selectionLengthUTF16) }
    if focusAtEnd { try values.encode(true, forKey: .focusAtEnd) }
    if affinity != .downstream { try values.encode(affinity, forKey: .affinity) }
  }
  func validate(in revision: PagedTextRevision) throws {
    guard byteOffset <= revision.summary.bytes, utf16Offset <= revision.summary.utf16,
      selectionLengthUTF16 <= revision.summary.utf16 - utf16Offset else {
      throw BoomError.invalid("Root history cursor is outside its sealed source.")
    }
  }
}

struct PagedRootHistoryEntry: Codable, Equatable, Sendable {
  let revision: PagedTextRevision
  let cursor: PagedSealedCursor
  let groupID: UUID
}

/// At most 100 small roots, preserving the existing native Undo limit. Its
/// <=64 KiB encoding is split into <=4 immutable 16 KiB index-kind records,
/// named by a small authenticated manifest. The manifest PageRef is published
/// in the SAME catalog entry/CAS as current. No source strings are retained.
struct PagedRootHistory: Codable, Equatable, Sendable {
  static let maximumEntries = 100
  static let maximumEncodedBytes = 65_536
  let schema: UInt8
  let purpose: String
  let ownerID: UUID
  let documentID: UUID
  private(set) var generation: UInt64
  private(set) var current: PagedTextRevision
  private(set) var currentCursor: PagedSealedCursor
  private(set) var undo: [PagedRootHistoryEntry]
  private(set) var redo: [PagedRootHistoryEntry]
  private(set) var activeGroup: UUID?

  init(revision: PagedTextRevision, cursor: PagedSealedCursor) throws {
    try revision.validate(); try cursor.validate(in: revision)
    schema = 1; purpose = "bloom/native-root-history/v1"
    ownerID = revision.ownerID; documentID = revision.documentID
    generation = 0; current = revision; currentCursor = cursor
    undo = []; redo = []; activeGroup = nil
  }

  /// The worker materializes the actual Foundation projection. This is one
  /// immutable save capture, not independently stepped storage history.
  init(materializedCurrent: PagedTextRevision, cursor: PagedSealedCursor,
    undo: [PagedRootHistoryEntry], redo: [PagedRootHistoryEntry], activeGroup: UUID?, generation: UInt64) throws {
    schema = 1; purpose = "bloom/native-root-history/v1"
    ownerID = materializedCurrent.ownerID; documentID = materializedCurrent.documentID
    current = materializedCurrent; currentCursor = cursor
    self.undo = undo; self.redo = redo; self.activeGroup = activeGroup; self.generation = generation
    try validate(expected: materializedCurrent)
  }
  func validate(expected: PagedTextRevision) throws {
    guard schema == 1, purpose == "bloom/native-root-history/v1",
      ownerID == expected.ownerID, documentID == expected.documentID,
      current == expected, undo.count + redo.count <= Self.maximumEntries else {
      throw BoomError.invalid("Root history differs from its authenticated catalog entry.")
    }
    try admit(current); try currentCursor.validate(in: current)
    for entry in undo + redo {
      try admit(entry.revision); try entry.cursor.validate(in: entry.revision)
    }
  }
  func encoded(expected: PagedTextRevision) throws -> Data {
    try validate(expected: expected)
    let data = try JSONEncoder().encode(self)
    guard data.count <= Self.maximumEncodedBytes else {
      throw BoomError.budget("Root history exceeds its authenticated page bound.")
    }
    return data
  }
  /// A new group's before cursor comes from its admitted native selection,
  /// rather than a persisted endpoint from a previous, unrelated edit.
  mutating func record(_ after: PagedTextRevision, cursor: PagedSealedCursor,
    beforeCursor: PagedSealedCursor, groupID: UUID) throws {
    try admit(after); try cursor.validate(in: after); try beforeCursor.validate(in: current)
    let next = try nextGeneration()
    // A joined native batch can have no net source change. Its head/history
    // epoch still advances, preventing an old full-record CAS from succeeding
    // after that accepted batch. It creates no empty Undo group.
    if after == current { currentCursor = cursor; generation = next; return }
    if activeGroup != groupID {
      undo.append(PagedRootHistoryEntry(revision: current, cursor: beforeCursor, groupID: groupID))
    }
    redo.removeAll(keepingCapacity: true)
    if undo.count > Self.maximumEntries { undo.removeFirst(undo.count - Self.maximumEntries) }
    current = after; currentCursor = cursor; generation = next; activeGroup = groupID
  }
  /// Genuine transient native edits can end at the same bytes. They invalidate
  /// older full-record captures without replacing source or retained history.
  mutating func advanceNativeEpoch(cursor: PagedSealedCursor) throws {
    try cursor.validate(in: current)
    let next = try nextGeneration()
    currentCursor = cursor; generation = next
  }
  mutating func stepUndo(expected: PagedTextRevision) throws -> PagedTextRevision {
    try validate(expected: expected)
    guard let previous = undo.last else { throw BoomError.unavailable("No retained root to undo.") }
    let next = try nextGeneration()
    _ = undo.removeLast()
    redo.append(PagedRootHistoryEntry(revision: current, cursor: currentCursor, groupID: previous.groupID))
    current = previous.revision; currentCursor = previous.cursor
    generation = next; activeGroup = nil
    return current
  }
  mutating func stepRedo(expected: PagedTextRevision) throws -> PagedTextRevision {
    try validate(expected: expected)
    guard let following = redo.last else { throw BoomError.unavailable("No retained root to redo.") }
    let next = try nextGeneration()
    _ = redo.removeLast()
    undo.append(PagedRootHistoryEntry(revision: current, cursor: currentCursor, groupID: following.groupID))
    current = following.revision; currentCursor = following.cursor
    generation = next; activeGroup = nil
    return current
  }
  /// Used only when >100 distinct accepted native groups were queued before a
  /// seal. It advances to the bounded checkpoint preceding the oldest retained
  /// native group; the next 100 group roots rebuild that same UI history. This
  /// does not remove disk recipe/receipt pins or authorize their collection.
  mutating func advanceExpiredNativeGroups(to baseline: PagedTextRevision,
    cursor: PagedSealedCursor) throws {
    try admit(baseline); try cursor.validate(in: baseline)
    let next = try nextGeneration()
    current = baseline; currentCursor = cursor; undo.removeAll(keepingCapacity: true)
    redo.removeAll(keepingCapacity: true); activeGroup = nil; generation = next
  }
  private func admit(_ revision: PagedTextRevision) throws {
    try revision.validate()
    guard revision.ownerID == ownerID, revision.documentID == documentID else {
      throw BoomError.denied("Root history crosses private document ownership.")
    }
  }
  private func nextGeneration() throws -> UInt64 {
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Root history generation is exhausted.") }
    return next.partialValue
  }
}

/// This replaces the new-format catalog's bare descriptor before activation.
/// Existing legacy .sealed documents and WorkspaceState schema 1 remain read.
/// The new paged schema must be bumped or be settled before any user data ships.
struct PagedDocumentRootRecord: Codable, Equatable, Sendable {
  let document: PagedDocumentDescriptor
  let historyPage: PagedTextPageRef
  let historyGeneration: UInt64
  func validate() throws {
    try document.validate()
    try historyPage.validate(maximumPlaintextBytes: 16_384)
  }
}

/// The head points to this independently authenticated bounded page, never
/// a JSON array of every historical revision in the workspace. Segments are
/// index-kind records whose plaintext is history data, not text-tree nodes.
struct PagedRootHistoryManifest: Codable, Sendable {
  let schema: UInt8
  let purpose: String
  let ownerID: UUID
  let documentID: UUID
  let generation: UInt64
  let plaintextBytes: Int
  let digest: String
  let segments: [PagedTextPageRef]
  func validate(expected: PagedDocumentRootRecord) throws {
    try expected.validate()
    guard schema == 1, purpose == "bloom/native-root-history-manifest/v1",
      ownerID == expected.document.revision.ownerID, documentID == expected.document.id,
      generation == expected.historyGeneration, plaintextBytes > 0,
      plaintextBytes <= PagedRootHistory.maximumEncodedBytes,
      segments.count == (plaintextBytes + 16_383) / 16_384,
      digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw BoomError.invalid("History manifest differs from its authenticated catalog record.")
    }
    for page in segments { try page.validate(maximumPlaintextBytes: 16_384) }
  }
  /// Called after the provider has authenticated each bounded segment and its
  /// exact PageRef digest. Reconstructing <=64 KiB is a fixed history budget.
  func decode(_ data: Data, expected: PagedDocumentRootRecord) throws -> PagedRootHistory {
    guard !Thread.isMainThread else { throw BoomError.invalid("Root history decode belongs to storage execution.") }
    try validate(expected: expected)
    guard data.count == plaintextBytes, Digest.sha256(data) == digest else {
      throw BoomError.invalid("History segments differ from their manifest.")
    }
    let history = try JSONDecoder().decode(PagedRootHistory.self, from: data)
    try history.validate(expected: expected.document.revision)
    guard history.generation == generation else { throw BoomError.invalid("History generation changed.") }
    return history
  }
}
