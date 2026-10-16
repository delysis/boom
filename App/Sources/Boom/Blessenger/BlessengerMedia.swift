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
  static func deliveredHistory(_ messages: [ChatMessage], product: BlessengerState) -> [ChatMessage] {
    messages.compactMap { message in
      if let audio = product.audio[message.id], product.callResponses?.contains(message.id) == true,
        audio.interrupted || message.state != .complete {
        var projected = message
        projected.text = (audio.deliveredText ?? "") + "\n[This spoken response was interrupted. The remaining generated text was not delivered.]"
        projected.state = .complete; return projected
      }
      return message.state == .complete ? message : nil
    }
  }
  struct History: Sendable { let prepared: Prepared; let occurrences: [UUID: [UUID]] }
  static func history(_ messages: [ChatMessage], state: WorkspaceState, store: WorkspaceStore,
    runner: MLXGemmaRunner, flag: CancellationFlag) async throws -> History {
    var ids: [UUID] = [], occurrences: [UUID: [UUID]] = [:]
    for message in messages where message.role == .user {
      let references = (message.directAttachments ?? []) + message.sources.filter { $0.kind == "attachment" }.map(\.id)
      for id in references where !ids.contains(id) { ids.append(id) }
      occurrences[message.id] = (message.directAttachments ?? []).filter { id in
        state.attachments.first(where: { $0.id == id }).map {
          [.audio, .image, .video].contains($0.kind) || ($0.kind == .pdf && $0.text.isEmpty)
        } ?? false
      }
    }
    guard ids.count <= 32 else { throw BoomError.budget("The selected history has more than 32 retained media sources; choose a shorter branch.") }
    return History(prepared: try await prepare(ids, state: state, store: store, runner: runner, flag: flag), occurrences: occurrences)
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
        let samples = try await detachedWork { () throws -> [Float] in
          let reader = try await MemoryMedia(bytes: bytes).audioReader()
          var samples: [Float] = []
          while let buffer = try reader.next(flag: flag) {
            guard let values = buffer.floatChannelData?[0] else { throw BoomError.invalid("The audio contains no waveform samples.") }
            let count = Int(buffer.frameLength)
            guard count <= 16_384 * 640 - samples.count else { throw BoomError.budget("Audio exceeds the model's admitted context capacity. Its complete original is retained.") }
            samples.append(contentsOf: UnsafeBufferPointer(start: values, count: count))
          }
          guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw BoomError.invalid("Audio contains no valid samples.") }
          return samples
        }
        payloads.append(WritingMediaData(reference: WritingMediaReference(id: id, name: item.name,
          rootDigest: item.rootDigest, kind: "audio", sourceDigest: item.digest), bytes: bytes, samples: samples))
      case .video:
        let storyboard = try await VideoPreparationCache.shared.prepare(bytes, digest: item.rootDigest, flag: flag)
        guard runner.supportsRawAudio || storyboard.sound.isEmpty else { throw BoomError.unavailable("This model cannot receive the video soundtrack. Choose an audio-capable model; no soundtrack was silently omitted.") }
        payloads.append(WritingMediaData(reference: WritingMediaReference(id: id, name: item.name,
          rootDigest: item.rootDigest, kind: "video", sourceDigest: item.digest,
          frameDigests: storyboard.images.map(Digest.sha256), video: storyboard.timeline),
          bytes: bytes, images: storyboard.images, audioSegments: storyboard.sound))
      case .pdf where item.text.isEmpty:
        let pages = try await detachedWork { try NativePDF.pages(bytes, flag: flag) }
        payloads.append(WritingMediaData(reference: WritingMediaReference(id: id, name: item.name,
          rootDigest: item.rootDigest, kind: "pdf", sourceDigest: item.digest,
          frameDigests: pages.map(Digest.sha256)), bytes: bytes, images: pages))
      default:
        guard !item.text.isEmpty else { throw BoomError.unavailable("This attachment has no admitted model representation. Its original was retained.") }
      }
    }
    let text = context.joined(separator: "\n")
    guard text.utf8.count <= 2_097_152 else { throw BoomError.budget("Selected source text exceeds its bounded context.") }
    return Prepared(context: text, sources: sources, payloads: payloads)
  }
}
