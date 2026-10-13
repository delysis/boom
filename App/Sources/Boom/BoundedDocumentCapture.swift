import BoomCore
import Foundation

/// Text supplied to a model belongs to one explicit range of an immutable
/// file revision. Its text digest is deliberately separate from that revision.
struct BoundedDocumentCapture: Codable, Equatable, Sendable {
  let record: PagedDocumentRootRecord
  let window: PagedTextWindow
  let generation: UInt64?
  let title: String
  let revisionDigest: String
  let textDigest: String

  init(record: PagedDocumentRootRecord, window: PagedTextWindow,
    generation: UInt64? = nil, title: String) throws {
    try record.validate(); try window.validate()
    guard record.document.revision == window.revision else {
      throw BoomError.stale("The captured range belongs to another source revision.")
    }
    self.record = record; self.window = window; self.generation = generation; self.title = title
    revisionDigest = try Self.digest(record.document.revision)
    textDigest = Digest.sha256(window.text)
  }
  var documentID: UUID { record.document.id }
  var byteRange: Range<UInt64> { window.byteStart ..< window.byteStart + UInt64(window.text.utf8.count) }
  var utf16Range: Range<UInt64> { window.utf16Start ..< window.utf16Start + UInt64(window.text.utf16.count) }
  var isWholeSource: Bool { window.byteStart == 0 && UInt64(window.text.utf8.count) == window.revision.summary.bytes }
  var source: SourceReference { SourceReference(id: documentID, title: title, digest: revisionDigest, kind: "document") }
  /// Used only by the existing bounded model planner. Callers retain this
  /// capture and translate planned local ranges through its explicit origin.
  var modelSnapshot: DocumentSnapshot {
    DocumentSnapshot(id: documentID, title: isWholeSource ? title : title + " [" + coverage + "]", text: window.text)
  }
  var completeSnapshot: DocumentSnapshot? { isWholeSource ? modelSnapshot : nil }
  static func digest(_ revision: PagedTextRevision) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return Digest.sha256(try encoder.encode(revision))
  }
  func admit() throws {
    try record.validate(); try window.validate()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard window.revision == record.document.revision,
      Digest.sha256(try encoder.encode(window.revision)) == revisionDigest,
      Digest.sha256(window.text) == textDigest else {
      throw BoomError.invalid("The retained model range changed.")
    }
  }
  var coverage: String { "UTF-8 bytes \(byteRange.lowerBound)..<\(byteRange.upperBound) of \(window.revision.summary.bytes); UTF-16 origin \(window.utf16Start)" }
  func localCaret(_ absolute: UInt64) throws -> Int {
    guard absolute >= utf16Range.lowerBound, absolute <= utf16Range.upperBound,
      let local = Int(exactly: absolute - utf16Range.lowerBound) else {
      throw BoomError.stale("The caret is outside its captured source range.")
    }
    _ = try TextBoundary.index(local, in: window.text)
    return local
  }
  func absoluteEdit(_ edit: ValidatedEdit) throws -> PagedTextLocalEdit {
    let start = try TextBoundary.index(edit.range.location, in: window.text)
    let end = try TextBoundary.index(NSMaxRange(edit.range), in: window.text)
    let before = window.text[..<start].utf8.count
    let old = Data(window.text[start..<end].utf8)
    return PagedTextLocalEdit(revision: window.revision, windowID: window.windowID,
      byteStart: window.byteStart + UInt64(before), byteEnd: window.byteStart + UInt64(before + old.count),
      oldBytes: old, newBytes: Data(edit.replacement.utf8))
  }
}
