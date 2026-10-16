import BoomCore
import Foundation

enum PagedTextPageKind: UInt8, Sendable {
  case text = 1, index = 2
  var wireName: String { self == .text ? "text" : "index" }
  var maximumBytes: Int { self == .text ? 65_536 : 16_384 }
}

/// Mirrors bloom-text's paged format. None of these values is the legacy
/// whole-source SHA256, and decoding one does not grant edit authority.
struct PagedTextSummary: Codable, Equatable, Sendable {
  let bytes: UInt64
  let utf16: UInt64
  let lfCount: UInt64
  func validate() throws {
    guard utf16 <= bytes, lfCount <= utf16, bytes == 0 || utf16 > 0 else {
      throw BoomError.invalid("Invalid paged text summary.")
    }
  }
}
/// Byte addresses in one immutable append file for the captured document.
struct PagedTextPageLocator: Codable, Equatable, Sendable {
  private enum Storage: String, Codable, Sendable { case fileV1 = "file_v1" }
  private enum CodingKeys: String, CodingKey { case storage, storeID = "storeId", offset, bytes }
  private let storage: Storage
  let storeID: UUID
  let offset: UInt64
  let bytes: UInt32
  init(storeID: UUID, offset: UInt64, bytes: UInt32) {
    storage = .fileV1; self.storeID = storeID; self.offset = offset; self.bytes = bytes
  }
  func admit(storeID: UUID) throws {
    guard self.storeID == storeID else { throw BoomError.denied("Page belongs to another file store.") }
  }
  func validate(maximumPlaintextBytes: Int) throws {
    let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let end = offset.addingReportingOverflow(UInt64(bytes) + 12)
    guard storeID != empty, maximumPlaintextBytes > 0, maximumPlaintextBytes <= 65_536,
      bytes <= UInt32(maximumPlaintextBytes), !end.overflow, end.partialValue <= UInt64(Int64.max) else {
      throw BoomError.invalid("Invalid bounded file page locator.")
    }
  }
}
struct PagedTextPageRef: Codable, Equatable, Sendable {
  let locator: PagedTextPageLocator
  /// SHA256 of this exact bounded plaintext page, checked by bloom-text.
  let digest: String
  func validate(maximumPlaintextBytes: Int) throws {
    try locator.validate(maximumPlaintextBytes: maximumPlaintextBytes)
    guard digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw BoomError.invalid("Invalid bounded page digest.")
    }
  }
}
struct PagedTextTreeRef: Codable, Equatable, Sendable {
  let page: PagedTextPageRef
  let summary: PagedTextSummary
  let height: UInt8
  func validate() throws {
    try page.validate(maximumPlaintextBytes: 16_384)
    try summary.validate()
    guard height <= 12 else { throw BoomError.budget("Paged text tree exceeds its depth bound.") }
  }
}
struct PagedTextRevision: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey { case schema, ownerID = "ownerId", documentID = "documentId", root }
  let schema: UInt8
  let ownerID: UUID
  let documentID: UUID
  let root: PagedTextTreeRef?
  init(schema: UInt8, ownerID: UUID, documentID: UUID, root: PagedTextTreeRef?) {
    self.schema = schema; self.ownerID = ownerID; self.documentID = documentID; self.root = root
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schema = try values.decode(UInt8.self, forKey: .schema)
    ownerID = try values.decode(UUID.self, forKey: .ownerID)
    documentID = try values.decode(UUID.self, forKey: .documentID)
    guard values.contains(.root) else { throw BoomError.invalid("Paged revision must declare its root.") }
    root = try values.decodeIfPresent(PagedTextTreeRef.self, forKey: .root)
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schema, forKey: .schema)
    try values.encode(ownerID, forKey: .ownerID)
    try values.encode(documentID, forKey: .documentID)
    try values.encode(root, forKey: .root)
  }
  var summary: PagedTextSummary { root?.summary ?? PagedTextSummary(bytes: 0, utf16: 0, lfCount: 0) }
  func validate() throws {
    let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard schema == 1, ownerID != empty, documentID != empty else {
      throw BoomError.invalid("Invalid paged text revision.")
    }
    try root?.validate()
    guard root == nil || summary.bytes > 0 else {
      throw BoomError.invalid("An empty paged revision must use a null root.")
    }
  }
}
struct PagedTextWindow: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey { case revision, windowID = "windowId", byteStart, utf16Start, lfStart, text }
  static let maximumBytes = 131_072
  let revision: PagedTextRevision
  let windowID: UUID
  let byteStart: UInt64
  let utf16Start: UInt64
  let lfStart: UInt64
  let text: String

  /// All arithmetic is checked before a global coordinate becomes a local
  /// NSRange. Source coverage stays explicit; this is not a full manuscript.
  func validate() throws {
    try revision.validate()
    let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard windowID != empty, text.utf8.count <= Self.maximumBytes else {
      throw BoomError.budget("Paged text window exceeds its local bound.")
    }
    let byteEnd = byteStart.addingReportingOverflow(UInt64(text.utf8.count))
    let utf16End = utf16Start.addingReportingOverflow(UInt64(text.utf16.count))
    let localLFs = text.utf8.reduce(UInt64(0)) { $0 + ($1 == 10 ? 1 : 0) }
    let lfEnd = lfStart.addingReportingOverflow(localLFs)
    guard !byteEnd.overflow, !utf16End.overflow, !lfEnd.overflow,
      byteEnd.partialValue <= revision.summary.bytes,
      utf16End.partialValue <= revision.summary.utf16,
      lfEnd.partialValue <= revision.summary.lfCount else {
      throw BoomError.invalid("Paged text window falls outside its captured revision.")
    }
  }
}

/// A validated import prefix remains read-only until its complete revision is
/// sealed. It cannot be passed to the sealed-window editing API.
struct PagedTextImportPreview: Sendable {
  let ownerID: UUID
  let documentID: UUID
  let importID: UUID
  let windowID: UUID
  let expectedBytes: UInt64
  let validatedPrefixBytes: UInt64
  let text: String
  func validate() throws {
    let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard text.utf8.count <= PagedTextWindow.maximumBytes,
      ownerID != empty, documentID != empty, importID != empty, windowID != empty,
      UInt64(text.utf8.count) <= validatedPrefixBytes, validatedPrefixBytes <= expectedBytes else {
      throw BoomError.invalid("Invalid partial text import window.")
    }
  }
}

/// Small UI metadata; root references replace complete source snapshots.
struct PagedDocumentDescriptor: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var title: String
  let revision: PagedTextRevision
  static func == (left: Self, right: Self) -> Bool {
    left.id == right.id && left.revision == right.revision && left.title.utf8.elementsEqual(right.title.utf8)
  }
  func validate() throws {
    try revision.validate()
    guard id == revision.documentID, title.utf8.count <= 1_024 else {
      throw BoomError.invalid("Paged descriptor has a different document owner or an oversized title.")
    }
  }
}
