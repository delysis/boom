import AppKit
import AVFoundation
import BoomCore
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import PDFKit

struct WritingMediaReference: Codable, Equatable, Sendable {
  let id: UUID
  let name: String
  let rootDigest: String
  let kind: String
  var text: String? = nil
  var sourceDigest: String? = nil
  var frameDigests: [String]? = nil
  var source: SourceReference { SourceReference(id: id, title: name, digest: sourceDigest ?? rootDigest,
    kind: kind == "text" ? "attachment" : "media") }
}
struct WritingMediaData: Sendable {
  var reference: WritingMediaReference
  let bytes: Data
  var samples: [Float] = []
  var images: [Data] = []
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
    try prepare(tokens: context.tokenizer.encode(text: raw, addSpecialTokens: false), media: media, context: context)
  }
  static func prepare(tokens encoded: [Int], media: [WritingMediaData], context: ModelContext) throws -> LMInput {
    guard media.contains(where: { $0.reference.kind != "text" }) else { return LMInput(tokens: MLXArray(encoded)) }
    guard let model = context.model as? Gemma4Unified, let processor = context.processor as? Gemma4UnifiedProcessor else {
      throw BoomError.unavailable("This model does not support raw image and audio continuations.")
    }
    let config = model.config
    let images = try media.flatMap { payload -> [CIImage] in
      if payload.reference.kind == "image" { return [try LocalImage.decode(payload.bytes)] }
      if ["pdf", "video"].contains(payload.reference.kind) {
        guard payload.reference.frameDigests == payload.images.map(Digest.sha256) else { throw BoomError.invalid("Rendered media frames changed.") }
        return try payload.images.map(LocalImage.decode)
      }
      return []
    }
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
    var records: [AttachmentRecord] = []
    for span in spans where !records.contains(where: { $0.id == span.id }) {
      guard let record = state.attachments.first(where: { $0.id == span.id }) else { throw BoomError.stale("A writing attachment was removed.") }
      guard [.image, .audio, .pdf, .video].contains(record.kind) || !record.text.isEmpty else {
        throw BoomError.unavailable("A writing attachment can't be read locally. Its original has been kept.")
      }
      records.append(record)
    }
    guard records.count <= 8 else { throw BoomError.budget("Writing context exceeds eight media inputs.") }
    let vault = store.vault
    return try await detachedWork { [records] in
      var result: [WritingMediaData] = []
      for record in records {
        try flag.check()
        let bytes = try vault.get(.attachment, id: record.id, limit: 67_108_864)
        guard Digest.sha256(bytes) == record.rootDigest else { throw BoomError.invalid("Writing media original changed.") }
        let kind = record.kind == .image ? "image" : record.kind == .audio ? "audio" : record.kind == .video ? "video" : record.kind == .pdf && record.text.isEmpty ? "pdf" : "text"
        var payload = WritingMediaData(reference: WritingMediaReference(id: record.id, name: record.name,
          rootDigest: record.rootDigest, kind: kind, text: kind == "text" ? record.text : nil,
          sourceDigest: kind == "text" ? record.digest : nil), bytes: bytes)
        if kind == "audio" {
          let reader = try await MemoryMedia(bytes: bytes).audioReader()
          while let buffer = try reader.next(flag: flag) {
            guard let channel = buffer.floatChannelData?[0] else { throw BoomError.invalid("Audio has no waveform samples.") }
            payload.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard payload.samples.count <= 16_384 * 640 else { throw BoomError.budget("Audio exceeds the model's context capacity.") }
          }
        }
        if ["pdf", "video"].contains(kind) {
          if kind == "pdf" { payload.images = try NativePDF.pages(bytes, flag: flag) }
          else {
            guard case .video(let frames, _) = try await NativeMedia.prepare(data: bytes, name: record.name, audioSeconds: 0, flag: flag) else { throw BoomError.unavailable("Video frames unavailable.") }
            payload.images = try frames.map { frame in
              guard let png = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else { throw BoomError.invalid("Video frame cannot be decoded.") }
              return png
            }
          }
          payload.reference.frameDigests = payload.images.map(Digest.sha256)
        }
        result.append(payload)
      }
      return result
    }
  }
}

enum NativePDF {
  static func pages(_ bytes: Data, flag: CancellationFlag) throws -> [Data] {
    guard let pdf = PDFDocument(data: bytes), !pdf.isLocked, (1...8).contains(pdf.pageCount) else {
      throw BoomError.budget("Image-only PDFs must be unlocked and contain at most eight pages for model input.")
    }
    return try (0..<pdf.pageCount).map { index in
      try flag.check()
      guard let page = pdf.page(at: index), let bitmap = page.thumbnail(of: NSSize(width: 1200, height: 1200), for: .mediaBox).tiffRepresentation
        .flatMap({ NSBitmapImageRep(data: $0) }), let png = bitmap.representation(using: .png, properties: [:]) else {
        throw BoomError.invalid("A PDF page cannot be rendered locally.")
      }
      return png
    }
  }
}
