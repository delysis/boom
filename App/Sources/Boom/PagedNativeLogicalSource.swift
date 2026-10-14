import BoomCore
import CAttachment
import Foundation

private struct LogicalFailure: Decodable {
  struct Detail: Decodable { let code: String; let message: String }
  let error: Detail
}
func pagedLogicalResult(_ status: Int32, _ buffer: BoomAttachmentBuffer) throws {
  defer { if buffer.data != nil { boom_attachment_free(buffer) } }
  guard status == 0 else {
    guard let pointer = buffer.data, (1...16_384).contains(buffer.length),
      let value = try? JSONDecoder().decode(LogicalFailure.self, from: Data(bytes: pointer, count: buffer.length)) else {
      throw BoomError.invalid("Native logical source returned an invalid error.")
    }
    if value.error.code == "cancelled" { throw CancellationError() }
    if value.error.code == "stale" { throw BoomError.stale(value.error.message) }
    throw BoomError.invalid(value.error.message)
  }
}
private func logicalSummary(_ point: BloomLogicalPoint) -> PagedTextSummary {
  PagedTextSummary(bytes: point.bytes, utf16: point.utf16, lfCount: point.lf_count)
}

/// An ordinary retained immutable value, not a file Revision, published head,
/// second cache or storage lease. Existing Foundation entries retain these
/// exact values/cursors; only their existing owner advances native history.
final class PagedNativeLogicalSnapshot: @unchecked Sendable {
  let sessionID: UUID
  let engineIncarnation: UUID
  let rootID: UUID
  let summary: PagedTextSummary
  /// Actual original file root used to pin/read this document's immutable file.
  /// Never label unsaved logical text with this revision's digest/summary.
  let sourceRevision: PagedTextRevision
  let pointer: OpaquePointer

  init(taking pointer: OpaquePointer, sourceRevision: PagedTextRevision,
    sessionID: UUID, engineIncarnation: UUID) throws {
    var accepted = false
    defer { if !accepted { bloom_logical_snapshot_free(pointer) } }
    var info = BloomLogicalSnapshotInfo()
    guard bloom_logical_snapshot_info(pointer, &info) == 0,
      UUID(uuid: info.owner_id) == sourceRevision.ownerID,
      UUID(uuid: info.document_id) == sourceRevision.documentID else {
      throw BoomError.invalid("Logical source crossed its actual document owner.")
    }
    let summary = logicalSummary(info.summary)
    try summary.validate()
    self.pointer = pointer; self.sourceRevision = sourceRevision
    self.sessionID = sessionID; self.engineIncarnation = engineIncarnation
    rootID = UUID(uuid: info.root_id); self.summary = summary
    accepted = true
  }
  deinit { bloom_logical_snapshot_free(pointer) }
  func isSame(_ other: PagedNativeLogicalSnapshot) -> Bool {
    sessionID == other.sessionID && engineIncarnation == other.engineIncarnation && rootID == other.rootID
  }
  /// Existing writer only, after real page-file sync. This releases insertion
  /// RAM, not an ACK/root/task; no source/history sequence is advanced.
  func releaseSyncedInsertions() throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Insertion backing joins on storage execution.") }
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_release_synced_insertions(pointer, &error), error)
  }
}

/// Real prepared native text from a logical snapshot. Distinct from both the
/// file-authenticated PagedTextWindow and the read-only ScrollProjection.
/// This owns the ONE scalar table used by native Working range admission.
final class PagedNativeLogicalWindow: @unchecked Sendable {
  let snapshot: PagedNativeLogicalSnapshot
  let windowID: UUID
  let start: PagedTextSummary
  let summary: PagedTextSummary
  let text: String
  let pointer: OpaquePointer

  init(taking pointer: OpaquePointer, sourceRevision: PagedTextRevision,
    sessionID: UUID, engineIncarnation: UUID) throws {
    var accepted = false
    defer { if !accepted { bloom_logical_window_free(pointer) } }
    var info = BloomLogicalWindowInfo()
    var root: OpaquePointer?
    guard bloom_logical_window_info(pointer, &info) == 0,
      bloom_logical_window_snapshot(pointer, &root) == 0, let root else {
      throw BoomError.invalid("Logical window lost its actual source value.")
    }
    let snapshot = try PagedNativeLogicalSnapshot(taking: root, sourceRevision: sourceRevision,
      sessionID: sessionID, engineIncarnation: engineIncarnation)
    guard UUID(uuid: info.root_id) == snapshot.rootID,
      info.summary.bytes == UInt64(info.text_length),
      info.start.bytes <= snapshot.summary.bytes,
      info.summary.bytes <= snapshot.summary.bytes - info.start.bytes,
      info.start.utf16 <= snapshot.summary.utf16,
      info.summary.utf16 <= snapshot.summary.utf16 - info.start.utf16,
      info.start.lf_count <= snapshot.summary.lfCount,
      info.summary.lf_count <= snapshot.summary.lfCount - info.start.lf_count else {
      throw BoomError.invalid("Logical island differs from its actual source counters.")
    }
    self.pointer = pointer; self.snapshot = snapshot
    windowID = UUID(uuid: info.window_id); start = logicalSummary(info.start)
    summary = logicalSummary(info.summary)
    // Rust supplies an immutable str; no re-summary/table/JSON decoding occurs.
    text = String(decoding: UnsafeBufferPointer(start: info.text, count: info.text_length), as: UTF8.self)
    accepted = true
  }
  deinit { bloom_logical_window_free(pointer) }

  func position(localUTF16: Int) throws -> PagedTextSummary {
    guard let offset = UInt64(exactly: localUTF16) else { throw BoomError.invalid("Negative logical local selection.") }
    var point = BloomLogicalPoint()
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_window_position(pointer, offset, &point, &error), error)
    return logicalSummary(point)
  }
  func localBytes(for range: NSRange) throws -> Range<Int> {
    guard range.location >= 0, range.length >= 0,
      let extent = Int(exactly: summary.utf16), range.location <= extent,
      range.length <= extent - range.location else {
      throw BoomError.invalid("Native selection is outside its logical island.")
    }
    let a = try position(localUTF16: range.location), b = try position(localUTF16: range.location + range.length)
    guard let lower = Int(exactly: a.bytes - start.bytes), let upper = Int(exactly: b.bytes - start.bytes) else {
      throw BoomError.invalid("Logical local bytes exceed native coordinates.")
    }
    return lower..<upper
  }
  func makeSeed(localFocusUTF16: Int? = nil) throws -> PagedNativeLogicalWindowSeed {
    let local = localFocusUTF16 ?? Int(exactly: summary.utf16)
    guard let local, let focus = UInt64(exactly: local) else { throw BoomError.invalid("Invalid logical seed focus.") }
    var output: OpaquePointer?
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_window_seed(pointer, focus, &output, &error), error)
    guard let output else { throw BoomError.invalid("Logical seed returned no bounded value.") }
    return try PagedNativeLogicalWindowSeed(taking: output, snapshot: snapshot)
  }
  func localRange(for selection: PagedNativeNavigationSelection) throws -> NSRange {
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    guard !end.overflow, end.partialValue <= snapshot.summary.utf16 else {
      throw BoomError.invalid("Selection exceeds its actual logical source.")
    }
    let extent = start.utf16.addingReportingOverflow(summary.utf16)
    guard !extent.overflow else { throw BoomError.invalid("Logical island extent overflow.") }
    let first = min(extent.partialValue, max(start.utf16, selection.utf16Offset))
    let last = min(extent.partialValue, max(first, end.partialValue))
    guard let a = Int(exactly: first - start.utf16), let count = Int(exactly: last - first) else {
      throw BoomError.invalid("Logical native range overflow.")
    }
    _ = try position(localUTF16: a); _ = try position(localUTF16: a + count)
    return NSRange(location: a, length: count)
  }
  /// Only after the actual outer Cocoa character command closes. Does no I/O
  /// or source mutation; the same logical head survives physical recentering.
  func trimmed(localFocusUTF16: Int, maximumBytes: Int = PagedWorkingWindow.targetBytes) throws -> PagedNativeLogicalWindow {
    guard let focus = UInt64(exactly: localFocusUTF16) else { throw BoomError.invalid("Negative logical trim focus.") }
    var output: OpaquePointer?
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_window_trim(pointer, focus, maximumBytes, &output, &error), error)
    guard let output else { throw BoomError.invalid("Logical trim returned no island.") }
    return try PagedNativeLogicalWindow(taking: output, sourceRevision: snapshot.sourceRevision,
      sessionID: snapshot.sessionID, engineIncarnation: snapshot.engineIncarnation)
  }
}

final class PagedNativeLogicalWindowSeed: @unchecked Sendable {
  let snapshot: PagedNativeLogicalSnapshot
  private let pointer: OpaquePointer
  let start: PagedTextSummary
  let summary: PagedTextSummary
  init(taking pointer: OpaquePointer, snapshot: PagedNativeLogicalSnapshot) throws {
    var info = BloomLogicalSeedInfo()
    guard bloom_logical_seed_info(pointer, &info) == 0 else {
      bloom_logical_seed_free(pointer); throw BoomError.invalid("Logical seed lost its actual metadata.")
    }
    self.pointer = pointer; self.snapshot = snapshot
    start = logicalSummary(info.start); summary = logicalSummary(info.summary)
  }
  func containsFocusUTF16(_ focus: UInt64) -> Bool {
    focus >= start.utf16 && focus - start.utf16 <= summary.utf16
  }
  deinit { bloom_logical_seed_free(pointer) }
  func preparedWindow() throws -> PagedNativeLogicalWindow {
    var output: OpaquePointer?
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_seed_window(pointer, &output, &error), error)
    guard let output else { throw BoomError.invalid("Logical seed returned no prepared island.") }
    let window = try PagedNativeLogicalWindow(taking: output, sourceRevision: snapshot.sourceRevision,
      sessionID: snapshot.sessionID, engineIncarnation: snapshot.engineIncarnation)
    guard window.snapshot.isSame(snapshot) else { throw BoomError.invalid("Logical seed has another retained root.") }
    return window
  }
}

struct PagedNativeLogicalCursor: Sendable, Equatable {
  let byteOffset: UInt64
  let utf16Offset: UInt64
  let selectionLengthUTF16: UInt64
  let focusAtEnd: Bool
  let affinity: PagedSelectionAffinity
  init(byteOffset: UInt64, utf16Offset: UInt64, selectionLengthUTF16: UInt64 = 0,
    focusAtEnd: Bool = false, affinity: PagedSelectionAffinity = .downstream) {
    self.byteOffset = byteOffset; self.utf16Offset = utf16Offset
    self.selectionLengthUTF16 = selectionLengthUTF16; self.focusAtEnd = focusAtEnd; self.affinity = affinity
  }
  init(_ cursor: PagedSealedCursor) {
    self.init(byteOffset: cursor.byteOffset, utf16Offset: cursor.utf16Offset,
      selectionLengthUTF16: cursor.selectionLengthUTF16, focusAtEnd: cursor.focusAtEnd, affinity: cursor.affinity)
  }
  var selection: PagedNativeNavigationSelection {
    PagedNativeNavigationSelection(utf16Offset: utf16Offset, utf16Length: selectionLengthUTF16,
      focusAtEnd: focusAtEnd, affinity: affinity)
  }
  var sealed: PagedSealedCursor {
    PagedSealedCursor(byteOffset: byteOffset, utf16Offset: utf16Offset,
      selectionLengthUTF16: selectionLengthUTF16, focusAtEnd: focusAtEnd, affinity: affinity)
  }
  func validate(in snapshot: PagedNativeLogicalSnapshot) throws {
    guard byteOffset <= snapshot.summary.bytes, utf16Offset <= snapshot.summary.utf16,
      selectionLengthUTF16 <= snapshot.summary.utf16 - utf16Offset else {
      throw BoomError.invalid("Logical cursor exceeds its retained source.")
    }
  }
}
struct PagedNativeLogicalReadSnapshot: Sendable {
  let source: PagedNativeLogicalSnapshot
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
}
struct PagedNativeLogicalHistoryEntry: Sendable {
  let snapshot: PagedNativeLogicalSnapshot
  let cursor: PagedNativeLogicalCursor
  let groupID: UUID
}
/// A capture of the actual Foundation entries, never another history owner.
struct PagedNativeLogicalHistoryProjection: Sendable {
  let snapshot: PagedNativeLogicalSnapshot
  let cursor: PagedNativeLogicalCursor
  let undo: [PagedNativeLogicalHistoryEntry]
  let redo: [PagedNativeLogicalHistoryEntry]
  let activeGroup: UUID?
  let generation: UInt64
  func validate() throws {
    guard undo.count + redo.count <= PagedRootHistory.maximumEntries else { throw BoomError.budget("Logical Undo retention exceeds its native limit.") }
    try cursor.validate(in: snapshot)
    for entry in undo + redo {
      guard entry.snapshot.sessionID == snapshot.sessionID,
        entry.snapshot.engineIncarnation == snapshot.engineIncarnation,
        entry.snapshot.sourceRevision.documentID == snapshot.sourceRevision.documentID else {
        throw BoomError.invalid("Logical history crossed its native source.")
      }
      try entry.cursor.validate(in: entry.snapshot)
    }
  }
}
struct PagedNativeLogicalPublication: Sendable {
  let publicationID: UUID
  let sessionID: UUID
  let firstSequence: UInt64
  let generation: UInt64
  let expectedRecord: PagedDocumentRootRecord
  let history: PagedNativeLogicalHistoryProjection
  let window: PagedNativeLogicalWindow
}
protocol PagedNativeLogicalSessionStorage: Sendable {
  var engineIncarnation: UUID { get }
  func logicalWindow(_ snapshot: PagedNativeLogicalSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int, cancellation: CancellationFlag) async throws -> PagedNativeLogicalWindow
  func logicalPosition(_ snapshot: PagedNativeLogicalSnapshot, utf16Offset: UInt64,
    rounding: UInt8, cancellation: CancellationFlag) async throws -> PagedTextSummary
  func logicalReplacement(_ snapshot: PagedNativeLogicalSnapshot, selection: PagedNativeNavigationSelection,
    replacement: Data, cancellation: CancellationFlag) async throws -> PagedNativeLogicalEdit
  func logicalCommand(_ snapshot: PagedNativeLogicalSnapshot, command: PagedNativeLogicalCommand,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalCommandResult
  func prepareImportedSourceTransfer(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>, sessionID: UUID) throws -> () -> Void
  func publishLogical(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement
  func finishLogicalPublication(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws
  func resumeLogicalPublication(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement
}

enum PagedNativeLogicalCommand: Sendable {
  case grapheme(UInt64, Bool)
  case paragraph(UInt64, Bool)
  case edits([PagedTextLocalEdit], PagedNativeNavigationSelection?)
  case wrapping(PagedNativeNavigationSelection, String, String, Bool)
  case imported(PagedNativeNavigationSelection, PagedTextCustodiedValue<PagedTextImportedRevision>)
  case linePrefix(PagedNativeNavigationSelection, String)

  struct Selection: Codable, Sendable {
    let start: UInt64, length: UInt64
    let focusAtEnd: Bool
    init(_ value: PagedNativeNavigationSelection) { start = value.utf16Offset; length = value.utf16Length; focusAtEnd = value.focusAtEnd }
    var native: PagedNativeNavigationSelection { PagedNativeNavigationSelection(utf16Offset: start, utf16Length: length, focusAtEnd: focusAtEnd) }
  }
  struct TextEdit: Encodable, Sendable { let start: UInt64, end: UInt64; let oldText: String, newText: String }
  struct Payload: Encodable, Sendable {
    let kind: String
    var at: UInt64? = nil, forward: Bool? = nil, includeLineEndings: Bool? = nil
    var edits: [TextEdit]? = nil, selection: Selection? = nil
    var prefix: String? = nil, suffix: String? = nil, toggles: Bool? = nil
    var revision: PagedTextRevision? = nil
  }
  func payload() throws -> Payload {
    switch self {
    case .grapheme(let at, let forward): return Payload(kind: "grapheme", at: at, forward: forward)
    case .paragraph(let at, let lines): return Payload(kind: "paragraph", at: at, includeLineEndings: lines)
    case .edits(let values, let selection):
      guard !values.isEmpty, values.count <= 32 else { throw BoomError.budget("Explicit logical edits exceed their bounded command.") }
      var charge = 0
      let edits = try values.map { value -> TextEdit in
        let bytes = value.oldBytes.count.addingReportingOverflow(value.newBytes.count)
        let next = charge.addingReportingOverflow(bytes.partialValue)
        guard !bytes.overflow, !next.overflow, next.partialValue <= PagedCapturedEditInput.maximumInputBytes,
          let old = String(data: value.oldBytes, encoding: .utf8), let new = String(data: value.newBytes, encoding: .utf8) else {
          throw BoomError.invalid("Explicit logical replacement bytes are not bounded UTF8.")
        }
        charge = next.partialValue
        return TextEdit(start: value.byteStart, end: value.byteEnd, oldText: old, newText: new)
      }
      return Payload(kind: "edits", edits: edits, selection: selection.map(Selection.init))
    case .wrapping(let selection, let prefix, let suffix, let toggles):
      return Payload(kind: "wrapping", selection: Selection(selection), prefix: prefix, suffix: suffix, toggles: toggles)
    case .imported(let selection, let imported): return Payload(kind: "imported", selection: Selection(selection), revision: imported.value.revision)
    case .linePrefix(let selection, let prefix): return Payload(kind: "linePrefix", selection: Selection(selection), prefix: prefix)
    }
  }
  /// JSON escaping and the bounded scalar-piece continuation are charged
  /// against the SAME existing Root aggregate, not another input ledger.
  func reservation() throws -> Int {
    switch self {
    case .edits(let edits, _):
      guard !edits.isEmpty, edits.count <= 32 else { throw BoomError.budget("Explicit logical edits exceed their bounded command.") }
      var charge = 0
      for edit in edits {
        for bytes in [edit.oldBytes.count, edit.newBytes.count] {
          let sum = charge.addingReportingOverflow(bytes)
          guard !sum.overflow, sum.partialValue <= PagedCapturedEditInput.maximumInputBytes else { throw BoomError.budget("Logical command exceeds its actual input bound.") }
          charge = sum.partialValue
        }
      }
      return 65_536 + 4_096 + charge * 6
    case .wrapping(_, let prefix, let suffix, _):
      guard !prefix.isEmpty, !suffix.isEmpty, prefix.utf8.count <= 64, suffix.utf8.count <= 64 else {
        throw BoomError.invalid("Logical delimiters exceed their native command bound.")
      }
      return 65_536 + 16_384
    case .linePrefix(_, let prefix):
      guard !prefix.isEmpty, prefix.utf8.count <= 256 else { throw BoomError.invalid("Logical prefix exceeds its bounded command.") }
      // Two fixed text buffers plus the existing fixed import frontier. Never
      // retain a source-sized list of lines, page references or native edits.
      return 262_144 + 16_384
    default: return 65_536 + 16_384
    }
  }
}
enum PagedNativeLogicalCommandResult: Sendable {
  case point(PagedTextSummary), paragraph(PagedTextParagraphBounds), edit(PagedNativeLogicalEdit)
}

struct PagedNativeLogicalEdit: Sendable {
  let changed: Bool
  let window: PagedNativeLogicalWindow
  let cursor: PagedTextSummary
  let selection: PagedNativeNavigationSelection?
  init(changed: Bool, window: PagedNativeLogicalWindow, cursor: PagedTextSummary,
    selection: PagedNativeNavigationSelection? = nil) {
    self.changed = changed; self.window = window; self.cursor = cursor; self.selection = selection
  }
}

/// Main's single mutable source head. Publication owns captured immutable
/// snapshots, never this value/lock. No Foundation history stack lives here.
@MainActor final class PagedNativeLogicalSource {
  let sessionID: UUID
  let engineIncarnation: UUID
  private var sourceRevision: PagedTextRevision
  private let pointer: OpaquePointer

  init(revision: PagedTextRevision, sessionID: UUID, engineIncarnation: UUID) throws {
    let bytes = try JSONEncoder().encode(revision) // one bounded opening, not input
    var output: OpaquePointer?
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    let status = bytes.withUnsafeBytes {
      bloom_logical_source_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output, &error)
    }
    try pagedLogicalResult(status, error)
    guard let output else { throw BoomError.invalid("Logical opening returned no source.") }
    pointer = output; sourceRevision = revision
    self.sessionID = sessionID; self.engineIncarnation = engineIncarnation
  }
  func openingWindow(_ window: PagedTextWindow) throws -> PagedNativeLogicalWindow {
    guard window.revision == sourceRevision else { throw BoomError.invalid("Opening island belongs to another file root.") }
    let bytes = try JSONEncoder().encode(window)
    var output: OpaquePointer?
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    let status = bytes.withUnsafeBytes {
      bloom_logical_source_opening_window(pointer, $0.bindMemory(to: UInt8.self).baseAddress,
        bytes.count, &output, &error)
    }
    try pagedLogicalResult(status, error)
    guard let output else { throw BoomError.invalid("Opening lost its actual logical island.") }
    return try PagedNativeLogicalWindow(taking: output, sourceRevision: sourceRevision,
      sessionID: sessionID, engineIncarnation: engineIncarnation)
  }
  func installPrepared(_ snapshot: PagedNativeLogicalSnapshot) {
    precondition(snapshot.sessionID == sessionID && snapshot.engineIncarnation == engineIncarnation)
    bloom_logical_source_install_prepared(pointer, snapshot.pointer)
    sourceRevision = snapshot.sourceRevision
  }
  func prepareResidentReplacement(in window: PagedNativeLogicalWindow,
    selection: PagedNativeNavigationSelection, replacement: String) throws -> PagedNativeLogicalEdit? {
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    guard !end.overflow else { throw BoomError.invalid("Logical replacement selection overflow.") }
    var output: OpaquePointer?
    var point = BloomLogicalPoint(), changed: UInt8 = 0, resident: UInt8 = 0
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    let bytes = replacement.utf8
    let status = bytes.withContiguousStorageIfAvailable {
      bloom_logical_source_prepare_replacement(pointer, window.pointer, selection.utf16Offset,
        end.partialValue, $0.baseAddress, $0.count, &output, &point, &changed, &resident, &error)
    } ?? Data(bytes).withUnsafeBytes {
      bloom_logical_source_prepare_replacement(pointer, window.pointer, selection.utf16Offset,
        end.partialValue, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &output, &point, &changed, &resident, &error)
    }
    try pagedLogicalResult(status, error)
    guard resident != 0 else { return nil }
    guard let output else { throw BoomError.invalid("Resident replacement returned no candidate.") }
    return try PagedNativeLogicalEdit(changed: changed != 0,
      window: PagedNativeLogicalWindow(taking: output, sourceRevision: sourceRevision,
        sessionID: sessionID, engineIncarnation: engineIncarnation), cursor: logicalSummary(point))
  }
  deinit { bloom_logical_source_free(pointer) }
  func capture(forPublication: Bool = false) throws -> PagedNativeLogicalSnapshot {
    var output: OpaquePointer?
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_source_capture(pointer, forPublication ? 1 : 0, &output, &error), error)
    guard let output else { throw BoomError.invalid("Logical capture returned no source.") }
    return try PagedNativeLogicalSnapshot(taking: output, sourceRevision: sourceRevision,
      sessionID: sessionID, engineIncarnation: engineIncarnation)
  }
  func restore(_ snapshot: PagedNativeLogicalSnapshot) throws {
    guard snapshot.sessionID == sessionID, snapshot.engineIncarnation == engineIncarnation else {
      throw BoomError.stale("Logical Undo snapshot belongs to another native source.")
    }
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    try pagedLogicalResult(bloom_logical_source_restore(pointer, snapshot.pointer, &error), error)
    sourceRevision = snapshot.sourceRevision
  }
  func replace(in window: PagedNativeLogicalWindow, range: NSRange, with replacement: String) throws -> PagedNativeLogicalEdit {
    guard window.snapshot.sessionID == sessionID, window.snapshot.engineIncarnation == engineIncarnation else {
      throw BoomError.stale("Native primitive has another source owner.")
    }
    let local = try window.localBytes(for: range)
    var output: OpaquePointer?
    var point = BloomLogicalPoint(), changed: UInt8 = 0
    var error = BoomAttachmentBuffer(data: nil, length: 0)
    let status = replacement.utf8.withContiguousStorageIfAvailable {
      bloom_logical_source_replace(pointer, window.pointer, local.lowerBound, local.upperBound,
        $0.baseAddress, $0.count, &output, &point, &changed, &error)
    } ?? Data(replacement.utf8).withUnsafeBytes {
      bloom_logical_source_replace(pointer, window.pointer, local.lowerBound, local.upperBound,
        $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &output, &point, &changed, &error)
    }
    try pagedLogicalResult(status, error)
    guard let output else { throw BoomError.invalid("Native primitive returned no logical island.") }
    return try PagedNativeLogicalEdit(changed: changed != 0,
      window: PagedNativeLogicalWindow(taking: output, sourceRevision: sourceRevision,
        sessionID: sessionID, engineIncarnation: engineIncarnation), cursor: logicalSummary(point))
  }
}
