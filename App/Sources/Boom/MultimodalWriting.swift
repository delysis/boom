import AppKit
import AVFoundation
import BoomCore
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

struct WritingMediaReference: Codable, Equatable, Sendable {
  let id: UUID
  let name: String
  let rootDigest: String
  let kind: String
  var source: SourceReference { SourceReference(id: id, title: name, digest: rootDigest, kind: "media") }
}
struct WritingMediaData: Sendable {
  let reference: WritingMediaReference
  let bytes: Data
  var samples: [Float] = []
}
struct CompiledMediaPrompt: Decodable {
  let prompt: String
  let media: [WritingMediaReference]
}

/// This adapter supplies raw model input, without invoking a chat template or
/// replacing media with a generated description/transcript. Gemma 4 unified
/// audio uses 16 kHz waveform frames, as specified by the upstream processor:
/// https://github.com/huggingface/transformers/blob/main/src/transformers/models/gemma4_unified/feature_extraction_gemma4_unified.py
/// The dependency's public image preprocessor remains the vision authority.
enum RawWritingInput {
  static func compiled(_ text: String, media: [WritingMediaReference]) throws -> CompiledMediaPrompt {
    try ProductCore.call(["op": "compile_media_prompt", "text": text, "media": ProductCore.object(media)])
  }
  static func prepare(_ raw: String, media: [WritingMediaData], context: ModelContext) throws -> LMInput {
    guard !media.isEmpty else { return LMInput(tokens: MLXArray(context.tokenizer.encode(text: raw, addSpecialTokens: false))) }
    guard let model = context.model as? Gemma4Unified, let processor = context.processor as? Gemma4UnifiedProcessor else {
      throw BoomError.unavailable("This model does not support raw image and audio continuations.")
    }
    let config = model.config
    let images = try media.filter { $0.reference.kind == "image" }.map { try LocalImage.decode($0.bytes) }
    let audio = media.filter { $0.reference.kind == "audio" }
    var processedImage: LMInput.ProcessedImage?, imageCounts: [Int] = []
    if !images.isEmpty {
      let prepared = try processor.preprocess(images: images, processing: nil)
      processedImage = LMInput.ProcessedImage(pixels: prepared.pixels, positionIds: prepared.positionIds, frames: prepared.frames)
      imageCounts = prepared.tokenCounts
    }
    var processedAudio: LMInput.ProcessedAudio?, audioCounts: [Int] = []
    if !audio.isEmpty {
      guard let configuration = config.audioConfiguration, let _ = config.audioTokenId else {
        throw BoomError.unavailable("This checkpoint has no audio input.")
      }
      let width = configuration.audioSamplesPerToken
      guard width > 0, width == configuration.outputProjectionDimensions else { throw BoomError.invalid("Unsupported audio frame geometry.") }
      var features: [Float] = []
      for clip in audio {
        guard !clip.samples.isEmpty, clip.samples.allSatisfy(\.isFinite) else { throw BoomError.invalid("Audio input is empty or nonfinite.") }
        let count = (clip.samples.count + width - 1) / width
        audioCounts.append(count); features.append(contentsOf: clip.samples)
        features.append(contentsOf: repeatElement(0, count: count * width - clip.samples.count))
      }
      processedAudio = LMInput.ProcessedAudio(features: MLXArray(features, [1, audioCounts.reduce(0, +), width]))
    }
    let encoded = context.tokenizer.encode(text: raw, addSpecialTokens: false)
    var tokens: [Int] = [], imageIndex = 0, audioIndex = 0
    for token in encoded {
      if token == config.imageTokenId {
        guard imageCounts.indices.contains(imageIndex) else { throw BoomError.invalid("Image placeholder count changed.") }
        tokens.append(config.boiTokenId); tokens.append(contentsOf: repeatElement(token, count: imageCounts[imageIndex]))
        if let end = config.eoiTokenId { tokens.append(end) }; imageIndex += 1
      } else if token == config.audioTokenId {
        guard audioCounts.indices.contains(audioIndex) else { throw BoomError.invalid("Audio placeholder count changed.") }
        tokens.append(config.boaTokenId); tokens.append(contentsOf: repeatElement(token, count: audioCounts[audioIndex]))
        if let end = config.eoaTokenId { tokens.append(end) }; audioIndex += 1
      } else { tokens.append(token) }
    }
    guard imageIndex == imageCounts.count, audioIndex == audioCounts.count else { throw BoomError.invalid("Media was not represented in the captured prompt.") }
    return LMInput(text: .init(tokens: MLXArray(tokens).expandedDimensions(axis: 0)), image: processedImage, audio: processedAudio)
  }
}

extension WorkspaceModel {
  func writingMedia(in text: String, flag: CancellationFlag) async throws -> [WritingMediaData] {
    let spans: [InlineMediaSpan] = try ProductCore.call(["op": "media_spans", "text": text])
    let records = spans.reduce(into: [AttachmentRecord]()) { records, span in
      if !records.contains(where: { $0.id == span.id }), let record = state.attachments.first(where: { $0.id == span.id }),
        [.image, .audio].contains(AttachmentKind(name: record.name)) { records.append(record) }
    }
    guard records.count <= 8 else { throw BoomError.budget("Writing context exceeds eight media inputs.") }
    let vault = store.vault
    return try await detachedWork {
      var result: [WritingMediaData] = []
      for record in records {
        try flag.check()
        let bytes = try vault.get(.attachment, id: record.id, limit: 67_108_864)
        guard Digest.sha256(bytes) == record.rootDigest else { throw BoomError.invalid("Writing media original changed.") }
        let kind = AttachmentKind(name: record.name) == .image ? "image" : "audio"
        var payload = WritingMediaData(reference: WritingMediaReference(id: record.id, name: record.name,
          rootDigest: record.rootDigest, kind: kind), bytes: bytes)
        if kind == "audio" {
          let reader = try await MemoryMedia(bytes: bytes).audioReader()
          while let buffer = try reader.next(flag: flag) {
            guard let channel = buffer.floatChannelData?[0] else { throw BoomError.invalid("Audio has no waveform samples.") }
            payload.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
          }
        }
        result.append(payload)
      }
      return result
    }
  }
}
