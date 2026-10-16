import AVFoundation
import BoomCore
import Foundation

/// Imports retain their original bytes. This adapter only chooses among the
/// existing inspector's admitted text and native media representations.
enum BlessengerMedia {
  struct Prepared: Sendable {
    let context: String
    let sources: [SourceReference]
    let payloads: [WritingMediaData]
  }
  static func prepare(_ ids: [UUID], state: WorkspaceState, store: WorkspaceStore,
    runner: MLXGemmaRunner, flag: CancellationFlag) async throws -> Prepared {
    var context: [String] = [], sources: [SourceReference] = [], payloads: [WritingMediaData] = []
    var byteCount = 0
    for id in ids {
      try flag.check()
      guard let item = state.attachments.first(where: { $0.id == id }) else { throw BoomError.stale("A selected attachment is missing.") }
      let bytes = try await detachedWork { try store.vault.get(.attachment, id: id, limit: 67_108_864) }
      guard Digest.sha256(bytes) == item.rootDigest else { throw BoomError.stale("The selected attachment changed.") }
      byteCount += bytes.count
      guard byteCount <= 134_217_728 else { throw BoomError.budget("Selected media exceeds 128 MiB.") }
      sources.append(item.reference)
      if !item.text.isEmpty {
        // JSON quoting keeps source bytes data, not application instructions.
        let data = try JSONSerialization.data(withJSONObject: ["source": id.uuidString,
          "title": item.name, "coverage": item.coverage, "text": item.text], options: .sortedKeys)
        context.append(String(decoding: data, as: UTF8.self))
      }
      switch item.kind {
      case .image:
        _ = try LocalImage.decode(bytes)
        payloads.append(WritingMediaData(reference: WritingMediaReference(id: id, name: item.name,
          rootDigest: item.rootDigest, kind: "image", sourceDigest: item.digest), bytes: bytes))
      case .audio:
        guard runner.supportsRawAudio else {
          throw BoomError.unavailable("This checkpoint cannot receive the selected audio. Transcribe it explicitly or choose an audio-capable model; the original is retained.")
        }
        let media = try MemoryMedia(bytes: bytes), reader = try await media.audioReader()
        guard reader.duration > 0, reader.duration < 30 else {
          throw BoomError.budget("This audio route requires a clip shorter than 30 seconds. The complete original is retained.")
        }
        let samples = try await detachedWork { () throws -> [Float] in
          guard let buffer = try reader.next(flag: flag, seconds: 30), let values = buffer.floatChannelData?[0] else {
            throw BoomError.invalid("The audio contains no decodable samples.")
          }
          let samples = Array(UnsafeBufferPointer(start: values, count: Int(buffer.frameLength)))
          guard samples.allSatisfy(\.isFinite) else { throw BoomError.invalid("Audio contains invalid samples.") }
          return samples
        }
        payloads.append(WritingMediaData(reference: WritingMediaReference(id: id, name: item.name,
          rootDigest: item.rootDigest, kind: "audio", sourceDigest: item.digest), bytes: bytes, samples: samples))
      case .video:
        throw BoomError.unavailable("Video consultation is not yet connected in this Blessenger view. Its original was retained; no visual or audio coverage was claimed.")
      default:
        guard !item.text.isEmpty else { throw BoomError.unavailable("This attachment has no admitted model representation. Its original was retained.") }
      }
    }
    let text = context.joined(separator: "\n")
    guard text.utf8.count <= 2_097_152 else { throw BoomError.budget("Selected source text exceeds its bounded context.") }
    return Prepared(context: text, sources: sources, payloads: payloads)
  }
}
