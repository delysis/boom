import BoomCore
import Foundation

/// Each transcript version is an ordinary immutable private text attachment.
/// This index adds provenance, not a duplicate text store or message history.
struct BlessengerTranscript: Codable, Equatable, Identifiable, Sendable {
  enum Origin: String, Codable, Sendable { case onDevice, edited, manual }
  let id: UUID
  let originalID: UUID
  let originalDigest: String
  let previousID: UUID?
  let textDigest: String
  let coverage: String
  let origin: Origin
  let createdAt: Date
}

extension BlessengerState {
  func validateTranscripts(in state: WorkspaceState) throws {
    let items = transcripts ?? [:]
    let records = Dictionary(uniqueKeysWithValues: state.attachments.map { ($0.id, $0) })
    guard items.count <= 16_384, items.values.reduce(0, { $0 + $1.count }) <= 16_384 else {
      throw BoomError.budget("The retained transcript index exceeds its bound.")
    }
    var seen = Set<UUID>()
    for (id, versions) in items {
      guard let source = records[id], [.audio, .video].contains(source.kind), !versions.isEmpty else {
        throw BoomError.invalid("A transcript has lost its original audio or video.")
      }
      var prior: UUID?
      for version in versions {
        guard seen.insert(version.id).inserted, version.id != id,
          version.originalID == id, version.originalDigest == source.rootDigest,
          version.previousID == prior, version.coverage.utf8.count <= 4096,
          let record = records[version.id], record.kind == .document,
          !record.text.isEmpty, record.text.utf8.count <= 262_144,
          record.rootDigest == version.textDigest, Digest.sha256(record.text) == version.textDigest,
          record.coverage == version.coverage else {
          throw BoomError.invalid("The immutable transcript lineage or text identity is inconsistent.")
        }
        prior = version.id
      }
    }
  }
}

extension WorkspaceStore {
  /// The selected original and prior transcript are captured by the review, not
  /// re-resolved from the currently selected chat. Refuse stale editors intact.
  func blessengerSaveTranscript(original: AttachmentRecord, expectedLatest: UUID?, text: String,
    coverage: String, origin: BlessengerTranscript.Origin, flag: CancellationFlag) throws -> (WorkspaceState, BlessengerTranscript) {
    try flag.check(); try Task.checkCancellation()
    guard [.audio, .video].contains(original.kind), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 262_144, !text.contains("\0"), !coverage.isEmpty, coverage.utf8.count <= 4096 else {
      throw BoomError.invalid("A transcript needs nonempty bounded text and honest coverage. The original is unchanged.")
    }
    let snapshot = try blessengerSnapshot()
    guard try snapshot.attachments.first(where: { $0.id == original.id }).map(BlessengerPolicy.exactDigest) == BlessengerPolicy.exactDigest(original),
      snapshot.blessenger?.transcripts?[original.id]?.last?.id == expectedLatest else {
      throw BoomError.stale("The original or its latest transcript changed. Your edited text was not overwritten.")
    }
    // Recheck actual authenticated bytes; a mutable URL is not the source.
    guard try Digest.sha256(vault.get(.attachment, id: original.id, limit: 67_108_864)) == original.rootDigest else {
      throw BoomError.stale("The transcript's original failed its identity check.")
    }
    let data = Data(text.utf8), id = UUID()
    let imported = try AttachmentProcessor.inspect(name: original.name + " · Transcript.txt", data: data, id: id)
    // The canonical transcript is EXACT authored text, including whitespace and
    // normalization. Inspection still supplies the immutable content receipt.
    var record = imported.record
    record.text = text; record.coverage = coverage; record.transform = "blessenger.transcript-exact-utf8.v1"
    let version = BlessengerTranscript(id: id, originalID: original.id, originalDigest: original.rootDigest,
      previousID: expectedLatest, textDigest: Digest.sha256(data), coverage: coverage, origin: origin, createdAt: Date())
    guard !vault.exists(.attachment, id), !vault.exists(.receipt, id) else { throw BoomError.stale("Transcript identity collision.") }
    try flag.check(); try Task.checkCancellation()
    try vault.put(data, kind: .attachment, id: id)
    try vault.put(imported.receipt, kind: .receipt, id: id)
    let publishedRecord = record
    return try blessengerTransaction { state, product in
      try flag.check(); try Task.checkCancellation()
      guard try state.attachments.first(where: { $0.id == original.id }).map(BlessengerPolicy.exactDigest) == BlessengerPolicy.exactDigest(original),
        product.transcripts?[original.id]?.last?.id == expectedLatest else {
        throw BoomError.stale("The source changed before transcript publication. Existing records were retained.")
      }
      state.attachments.append(publishedRecord)
      if product.transcripts == nil { product.transcripts = [:] }
      product.transcripts![original.id, default: []].append(version)
      return version
    }
  }
  func blessengerAttachTranscript(_ version: BlessengerTranscript, draftID: UUID, expectedVersion: UUID) throws -> WorkspaceState {
    try blessengerTransaction { state, product in
      guard product.transcripts?[version.originalID]?.contains(version) == true,
        state.attachments.contains(where: { $0.id == version.id && $0.rootDigest == version.textDigest }),
        let d = product.drafts.firstIndex(where: { $0.id == draftID }), product.drafts[d].version == expectedVersion else {
        throw BoomError.stale("The transcript or target draft changed. Nothing was attached or sent.")
      }
      if !product.drafts[d].attachments.contains(version.id) {
        product.drafts[d].attachments.append(version.id); product.drafts[d].version = UUID()
      }
      _ = try BlessengerPolicy.validate(product.drafts[d])
    }.0
  }
}
