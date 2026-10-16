import BoomCore
import Foundation

/// Bounded history records on the host's existing owner/document page provider.
/// The serialized storage host supplies this provider; no Vault, key, executor,
/// cache or current-root authority is created here.
struct PagedRootHistoryStore: Sendable {
  static let segmentBytes = 16_384
  static let maximumSegments = 4
  static let maximumManifestBytes = 4_096
  private let pages: any PagedTextDocumentPages

  init(pages: any PagedTextDocumentPages) throws {
    guard !Thread.isMainThread else {
      throw BoomError.invalid("Root history storage must open off the main thread.")
    }
    self.pages = pages
  }

  /// Writes unpublished history records through this same provider.
  /// The complete document root is replaced only after these pages synchronize.
  func writeNew(_ history: PagedRootHistory,
    document: PagedDocumentDescriptor) throws -> PagedDocumentRootRecord {
    try admit(document)
    let bytes = try history.encoded(expected: document.revision)
    guard !bytes.isEmpty, bytes.count <= Self.segmentBytes * Self.maximumSegments else {
      throw BoomError.budget("Root history exceeds its fixed storage budget.")
    }
    var segments: [PagedTextPageRef] = []
    segments.reserveCapacity(Self.maximumSegments)
    for start in stride(from: 0, to: bytes.count, by: Self.segmentBytes) {
      let end = min(start + Self.segmentBytes, bytes.count)
      segments.append(try append(bytes.subdata(in: start..<end)))
    }
    let manifest = PagedRootHistoryManifest(schema: 1,
      purpose: "bloom/native-root-history-manifest/v1", ownerID: pages.ownerID,
      documentID: pages.documentID, generation: history.generation,
      plaintextBytes: bytes.count, digest: Digest.sha256(bytes), segments: segments)
    let manifestBytes = try JSONEncoder().encode(manifest)
    guard manifestBytes.count <= Self.maximumManifestBytes else {
      throw BoomError.budget("Root history manifest exceeds its fixed page budget.")
    }
    let record = PagedDocumentRootRecord(document: document,
      historyPage: try append(manifestBytes), historyGeneration: history.generation)
    try manifest.validate(expected: record)
    return record
  }

  /// The expected record comes from the current document root. Loading history
  /// validates its metadata; the host/engine still validates source roots.
  func load(_ expected: PagedDocumentRootRecord) throws -> PagedRootHistory {
    try admit(expected.document)
    try expected.validate()
    let manifestBytes = try authenticated(expected.historyPage,
      maximumBytes: Self.maximumManifestBytes)
    let manifest = try JSONDecoder().decode(PagedRootHistoryManifest.self, from: manifestBytes)
    try manifest.validate(expected: expected)
    guard manifest.plaintextBytes <= Self.segmentBytes * Self.maximumSegments,
      manifest.segments.count <= Self.maximumSegments else {
      throw BoomError.budget("Root history exceeds its fixed storage budget.")
    }

    var bytes = Data()
    bytes.reserveCapacity(manifest.plaintextBytes)
    for (index, segment) in manifest.segments.enumerated() {
      let remaining = manifest.plaintextBytes - index * Self.segmentBytes
      let required = min(Self.segmentBytes, remaining)
      // The manifest count/total bounds are admitted before this arithmetic.
      // Every segment except the last is full; empty/short coverage cannot be
      // hidden by a valid aggregate digest or valid page frame alone.
      guard required > 0,
        Int(segment.locator.bytes) == required else {
        throw BoomError.invalid("Root history segment has an incorrect extent.")
      }
      bytes.append(try authenticated(segment, maximumBytes: Self.segmentBytes))
    }
    return try manifest.decode(bytes, expected: expected)
  }

  private func admit(_ document: PagedDocumentDescriptor) throws {
    guard !Thread.isMainThread else {
      throw BoomError.invalid("Root history storage belongs to the off-main executor.")
    }
    try document.validate()
    guard document.revision.ownerID == pages.ownerID,
      document.id == pages.documentID else {
      throw BoomError.denied("Root history belongs to a different source.")
    }
  }

  private func append(_ bytes: Data) throws -> PagedTextPageRef {
    let locator = try pages.writeNew(ownerID: pages.ownerID, documentID: pages.documentID,
      kind: .index, bytes: bytes)
    let page = PagedTextPageRef(locator: locator, digest: Digest.sha256(bytes))
    try page.validate(maximumPlaintextBytes: Self.segmentBytes)
    return page
  }

  private func authenticated(_ page: PagedTextPageRef, maximumBytes: Int) throws -> Data {
    try page.validate(maximumPlaintextBytes: maximumBytes)
    let bytes = try pages.read(ownerID: pages.ownerID, documentID: pages.documentID,
      kind: .index, page: page, maximumPlaintextBytes: maximumBytes)
    // The provider checks framing and the page digest. Its read path delegates the PageRef
    // digest check to consumers; history performs that exact check here.
    guard bytes.count == Int(page.locator.bytes),
      Digest.sha256(bytes) == page.digest else {
      throw BoomError.invalid("Root history page differs from its authenticated reference.")
    }
    return bytes
  }
}
