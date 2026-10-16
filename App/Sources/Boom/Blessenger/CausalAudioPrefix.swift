import BoomCore
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// One live, revocable preparation of a caller's immutable waveform. This is
/// neither a second history nor a persistent prefix cache. All methods run on
/// InferenceExecutor, under the runner's ordinary model/admission lease.
final class CausalAudioPrefix: @unchecked Sendable {
  static let maximumSamples = 1_920_000
  struct Observation: Sendable {
    let captureID: UUID
    let preparedSamples: Int
    let preparedTokens: Int
    let forwards: Int
  }
  struct Continuation {
    let input: LMInput
    let cache: [any KVCache]
    let promptIDs: [Int]
    let preparedTokens: Int
  }
  private struct Piece {
    let offset: Int
    let count: Int
    let digest: String
  }
  private struct State {
    let captureID: UUID
    let modelID: ObjectIdentifier
    let plan: String
    let historicalMedia: [WritingMediaReference]
    let prefixIDs: [Int]
    let historicalRows: Int
    let audioToken: Int
    let width: Int
    let cache: [any KVCache]
    var pieces: [Piece] = []
    var preparedSamples = 0
    var forwards = 1
    var preparedTokens: Int { prefixIDs.count + preparedSamples / width }
    var observation: Observation { .init(captureID: captureID, preparedSamples: preparedSamples,
      preparedTokens: preparedTokens, forwards: forwards) }
  }
  private var state: State?
  var observation: Observation? { state?.observation }

  static func sampleDigest(_ values: ArraySlice<Float>) -> String {
    var bytes = Data(capacity: values.count * 4)
    for value in values {
      var bits = value.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }
    return Digest.sha256(bytes)
  }

  /// The provisional current audio has exactly one zero row. It determines only
  /// placement, never a model feature: preparation stops *before* that row.
  func begin(id: UUID, model: Gemma4Unified, plan: ConsultationPlan,
    media: [WritingMediaData], input: LMInput) throws -> Observation {
    guard state == nil, let configuration = model.config.audioConfiguration,
      configuration.audioSamplesPerToken == 640,
      configuration.outputProjectionDimensions == configuration.audioSamplesPerToken,
      let token = model.config.audioTokenId, let audio = input.audio,
      input.text.mask == nil, input.text.tokens.ndim == 2, input.text.tokens.dim(0) == 1,
      audio.mask == nil, audio.features.ndim == 3, audio.features.dim(0) == 1,
      audio.features.dim(2) == configuration.audioSamplesPerToken,
      let current = media.first(where: { $0.reference.id == id }), current.reference.kind == "audio",
      current.samples.count == configuration.audioSamplesPerToken,
      current.samples.allSatisfy({ $0.bitPattern == Float(0).bitPattern }),
      plan.messages.last?.media?.last?.id == id,
      plan.messages.flatMap({ $0.media ?? [] }).filter({ $0.id == id }).count == 1 else {
      throw BoomError.invalid("The caller prefix lacks its exact provisional audio placement.")
    }
    let ids = input.text.tokens.asArray(Int.self)
    guard let boundary = ids.lastIndex(of: token), boundary > 0,
      ids[boundary - 1] == model.config.boaTokenId,
      boundary + 1 < ids.count, ids[boundary + 1] != token,
      audio.features.dim(1) > 0 else { throw BoomError.invalid("The current audio boundary changed.") }
    let prefix = Array(ids[..<boundary]), historicalRows = audio.features.dim(1) - 1
    guard prefix.filter({ $0 == token }).count == historicalRows else {
      throw BoomError.invalid("Historical audio coverage does not match the prepared prefix.")
    }
    let historicalAudio: LMInput.ProcessedAudio? = historicalRows == 0 ? nil
      : .init(features: audio.features[0..., ..<historicalRows, 0...])
    let cache = try model.newCache(parameters: nil)
    let owned = State(captureID: id, modelID: ObjectIdentifier(model), plan: try BlessengerPolicy.exactDigest(plan),
      historicalMedia: media.filter { $0.reference.id != id }.map(\.reference), prefixIDs: prefix,
      historicalRows: historicalRows, audioToken: token, width: configuration.audioSamplesPerToken, cache: cache)
    // Assign ownership before the first native call so every failure has a
    // joined cleanup path. The caller fences all already-submitted work.
    state = owned
    let prepared = LMInput(text: .init(tokens: MLXArray(prefix).reshaped([1, prefix.count])),
      image: input.image, video: input.video, audio: historicalAudio)
    _ = try model.prepareCausalAudioChunk(prepared, cache: cache)
    eval(cache)
    guard !cache.isEmpty, cache.allSatisfy({ $0.offset == prefix.count }) else {
      throw BoomError.invalid("Native caller-prefix coverage is incomplete.")
    }
    return owned.observation
  }

  func append(id: UUID, offset: Int, samples: [Float], model: Gemma4Unified) throws -> Observation {
    guard var owned = state, owned.captureID == id, owned.modelID == ObjectIdentifier(model),
      offset == owned.preparedSamples, !samples.isEmpty, samples.count <= 40_960,
      samples.count % owned.width == 0, offset <= Self.maximumSamples - samples.count,
      samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }),
      owned.cache.allSatisfy({ $0.offset == owned.preparedTokens }) else {
      throw BoomError.stale("The incremental caller input is not the next immutable audio span.")
    }
    let rows = samples.count / owned.width
    let chunk = LMInput(text: .init(tokens: MLXArray(Array(repeating: owned.audioToken, count: rows)).reshaped([1, rows])),
      audio: .init(features: MLXArray(samples).reshaped([1, rows, owned.width])))
    _ = try model.prepareCausalAudioChunk(chunk, cache: owned.cache)
    eval(owned.cache)
    owned.pieces.append(.init(offset: offset, count: samples.count, digest: Self.sampleDigest(samples[...])))
    owned.preparedSamples += samples.count; owned.forwards += 1
    // Native caches may mutate before an error. Record no invented successful
    // coverage; the runner retires the whole prefix on any failed operation.
    guard owned.cache.allSatisfy({ $0.offset == owned.preparedTokens }) else {
      throw BoomError.invalid("Native audio-prefix layers did not complete the same span.")
    }
    state = owned
    return owned.observation
  }

  /// Validate the actual admitted full input, then move its sole cache into the
  /// normal or actual-MTP iterator. No submitted audio row is forwarded again.
  func take(id: UUID, model: Gemma4Unified, plan: ConsultationPlan,
    media: [WritingMediaData], input: LMInput) throws -> Continuation {
    guard let owned = state, owned.captureID == id, owned.modelID == ObjectIdentifier(model),
      owned.plan == (try BlessengerPolicy.exactDigest(plan)),
      owned.historicalMedia == media.filter({ $0.reference.id != id }).map(\.reference),
      let current = media.first(where: { $0.reference.id == id }), current.reference.kind == "audio",
      current.samples.count >= owned.preparedSamples, current.samples.count <= Self.maximumSamples,
      current.samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }),
      input.text.mask == nil, input.text.tokens.ndim == 2, input.text.tokens.dim(0) == 1,
      let audio = input.audio, audio.mask == nil, audio.features.ndim == 3,
      audio.features.dim(0) == 1, audio.features.dim(2) == owned.width else {
      throw BoomError.stale("The final caller input differs from its captured preparation.")
    }
    for piece in owned.pieces {
      guard Self.sampleDigest(current.samples[piece.offset..<(piece.offset + piece.count)]) == piece.digest else {
        throw BoomError.stale("A submitted caller sample changed before finalization.")
      }
    }
    let ids = input.text.tokens.asArray(Int.self), count = owned.preparedTokens
    let expectedPrefix = owned.prefixIDs + Array(repeating: owned.audioToken, count: owned.preparedSamples / owned.width)
    guard count < ids.count, Array(ids.prefix(count)) == expectedPrefix,
      audio.features.dim(1) == owned.historicalRows + (current.samples.count + owned.width - 1) / owned.width,
      owned.cache.allSatisfy({ $0.offset == count }) else {
      throw BoomError.stale("Final token placement or actual native audio coverage changed.")
    }
    let consumedRows = owned.historicalRows + owned.preparedSamples / owned.width
    let tailAudio: LMInput.ProcessedAudio? = consumedRows == audio.features.dim(1) ? nil
      : .init(features: audio.features[0..., consumedRows..., 0...])
    let tail = LMInput(text: .init(tokens: MLXArray(Array(ids.dropFirst(count))).reshaped([1, ids.count - count])), audio: tailAudio)
    state = nil
    return .init(input: tail, cache: owned.cache, promptIDs: ids, preparedTokens: count)
  }

  /// Only after the owner has joined and fenced its current native operation.
  func clear() { state = nil }
}
