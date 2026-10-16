import AVFoundation
import BoomCore
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import XCTest
@testable import Boom

extension BlessengerTests {
  private func tinyCallerModel() throws -> Gemma4Unified {
    let json = """
    {"model_type":"gemma4_unified","vocab_size":32,
     "image_token_id":31,"audio_token_id":30,"video_token_id":29,"boa_token_id":25,"eoa_token_id":26,
     "text_config":{"hidden_size":16,"num_hidden_layers":4,"intermediate_size":32,
       "num_attention_heads":2,"num_key_value_heads":1,"num_global_key_value_heads":1,
       "head_dim":8,"global_head_dim":8,"vocab_size":32,"vocab_size_per_layer_input":32,
       "num_kv_shared_layers":2,"hidden_size_per_layer_input":4,"sliding_window":512,
       "max_position_embeddings":4096,"attention_k_eq_v":true,"use_double_wide_mlp":false,
       "tie_word_embeddings":true,
       "layer_types":["sliding_attention","full_attention","sliding_attention","full_attention"]},
     "vision_config":null,"audio_config":{}}
    """
    let config = try JSONDecoder().decode(Gemma4UnifiedConfiguration.self, from: Data(json.utf8))
    let model = withRandomState(MLXRandom.RandomState(seed: 901)) { Gemma4Unified(config) }
    eval(model); return model
  }

  func testPreparedCallerOwnershipTransfersExactHistoryAndOnlyUnprocessedTail() throws {
    try Device.withDefaultDevice(.cpu) {
      let model = try tinyCallerModel(), owner = CausalAudioPrefix(), id = UUID(), historicalID = UUID()
      func payload(_ id: UUID, _ samples: [Float]) throws -> WritingMediaData {
        let bytes = try BlessengerWave.encode(samples, rate: 16_000)
        return .init(reference: .init(id: id, name: "Caller.wav", rootDigest: Digest.sha256(bytes), kind: "audio"), bytes: bytes, samples: samples)
      }
      let historical = try payload(historicalID, [Float](repeating: 0.05, count: 640))
      let plan = ConsultationPlan(messages: [
        .init(role: "user", content: "Previous", media: [.init(id: historicalID, end: 8)]),
        .init(role: "assistant", content: "Reply", media: []),
        .init(role: "user", content: "", media: [.init(id: id, end: 0)])
      ], rawPrompt: "captured request", promptContract: .referenceHistoryV2)
      let prefix: [Int32] = [1, 25, 30, 26, 2, 25], suffix: [Int32] = [26, 3, 4]
      func input(_ samples: [Float]) -> LMInput {
        let rows = (samples.count + 639) / 640
        let padded = samples + Array(repeating: Float(0), count: rows * 640 - samples.count)
        let ids = prefix + Array(repeating: Int32(30), count: rows) + suffix
        return LMInput(text: .init(tokens: MLXArray(ids).reshaped([1, ids.count])),
          audio: .init(features: MLXArray(historical.samples + padded).reshaped([1, rows + 1, 640])))
      }
      let stub = try payload(id, [Float](repeating: 0, count: 640))
      let start = try owner.begin(id: id, model: model, plan: plan, media: [historical, stub], input: input(stub.samples))
      XCTAssertEqual(start.preparedTokens, prefix.count)
      let actual: [Float] = (0..<1301).map { sin(Float($0) * 0.037) * 0.07 }
      _ = try owner.append(id: id, offset: 0, samples: Array(actual[..<640]), model: model)
      let progress = try owner.append(id: id, offset: 640, samples: Array(actual[640..<1280]), model: model)
      XCTAssertEqual(progress.preparedSamples, 1280)
      XCTAssertEqual(progress.forwards, 3)
      XCTAssertThrowsError(try owner.append(id: id, offset: 0, samples: Array(actual[..<640]), model: model))
      XCTAssertThrowsError(try owner.append(id: UUID(), offset: 1280, samples: stub.samples, model: model))
      var changed = actual; changed[1] += 0.001
      XCTAssertThrowsError(try owner.take(id: id, model: model, plan: plan,
        media: [historical, payload(id, changed)], input: input(changed)))
      let differentPlan = ConsultationPlan(messages: plan.messages, rawPrompt: "changed captured request")
      XCTAssertThrowsError(try owner.take(id: id, model: model, plan: differentPlan,
        media: [historical, payload(id, actual)], input: input(actual)))
      let completed = try payload(id, actual)
      let continuation = try owner.take(id: id, model: model, plan: plan,
        media: [historical, completed], input: input(actual))
      XCTAssertNil(owner.observation)
      XCTAssertEqual(continuation.preparedTokens, prefix.count + 2)
      XCTAssertEqual(continuation.input.text.tokens.asArray(Int32.self), [30] + suffix)
      XCTAssertEqual(continuation.input.audio?.features.shape, [1, 1, 640])
      XCTAssertEqual(continuation.cache.map(\.offset), Array(repeating: prefix.count + 2, count: continuation.cache.count))
      let oneShot = try model.newCache(parameters: nil)
      let whole = try model.prepare(input(actual), cache: oneShot, state: nil, prefill: .init())
      guard case .logits(let full) = whole else { XCTFail("Missing one-shot logits"); return }
      let tail = try model.prepareCausalAudioChunk(continuation.input, cache: continuation.cache)
      let a = full.logits[0..., -1, 0...], b = tail.logits[0..., -1, 0...]
      eval(a, b)
      XCTAssertLessThan(abs(a - b).max().item(Float.self), 5e-4)
      XCTAssertEqual(oneShot.map(\.offset), continuation.cache.map(\.offset))
      XCTAssertThrowsError(try owner.take(id: id, model: model, plan: plan,
        media: [historical, completed], input: input(actual)))
    }
  }

  func testProvisionalAudioPlacementDoesNotDependOnFutureWaveformDigest() throws {
    let id = UUID(), previousID = UUID()
    let history = [ChatMessage(id: previousID, role: .user, text: "Earlier", speaker: Speaker(name: "Human"))]
    let plans = try ProductCore.consultationRound(voices: [nil], history: history, instructions: "Case instructions",
      context: "", request: "", routing: [], promptContract: .referenceHistoryV2,
      historyMedia: [:], currentMedia: [id])
    let plan = try XCTUnwrap(plans.first)
    XCTAssertEqual(plan.messages.last?.media?.last?.id, id)
    XCTAssertEqual(plan.messages.flatMap { $0.media ?? [] }.filter { $0.id == id }.count, 1)
    func expand(_ value: Float) throws -> String {
      let bytes = try BlessengerWave.encode([Float](repeating: value, count: 640), rate: 16000)
      let media = WritingMediaData(reference: .init(id: id, name: "Caller.wav", rootDigest: Digest.sha256(bytes),
        kind: "audio", sourceDigest: Digest.sha256(bytes + Data([1]))), bytes: bytes, samples: [value])
      return try RawWritingInput.expandChatMedia(plan, media: [media]).messages.map(\.content).joined(separator: "\n")
    }
    XCTAssertEqual(try expand(0), try expand(0.1), "Uncommitted samples must not change immutable role/text placement.")
  }

  func testCapturePrefixRemainsExactAcrossPauseResumeAndMute() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let capture = try BlessengerCaptureBuffer(source: format)
    let packet = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    packet.frameLength = 1024
    var sampleTime: AVAudioFramePosition = 0
    func append(_ value: Float, packets: Int) {
      for _ in 0..<packets {
        packet.floatChannelData![0].update(repeating: value, count: 1024)
        capture.append(packet, at: AVAudioTime(sampleTime: sampleTime, atRate: 16000)); sampleTime += 1024
      }
    }
    append(0.1, packets: 4)
    let first = try XCTUnwrap(capture.nextPrefix(after: nil, samples: 0))
    XCTAssertEqual(first.offset, 0); XCTAssertEqual(first.samples.count % 640, 0)
    append(0, packets: 8)
    _ = capture.drain()
    append(0.2, packets: 4)
    let second = try XCTUnwrap(capture.nextPrefix(after: first.captureID, samples: first.samples.count))
    XCTAssertEqual(second.captureID, first.captureID)
    XCTAssertEqual(second.offset, first.samples.count)
    append(0, packets: 8)
    let pause = try XCTUnwrap(capture.drain().compactMap { event -> (UInt64, Double)? in
      if case .pause(let frame, let uptime) = event { return (frame, uptime) }; return nil
    }.last)
    let clip = try capture.clip(through: pause.0, ended: pause.1, decision: "explicit")
    XCTAssertEqual(clip.captureID, first.captureID)
    let submitted = first.samples + second.samples
    XCTAssertEqual(Array(clip.samples.prefix(submitted.count)).map(\.bitPattern), submitted.map(\.bitPattern))
    XCTAssertNil(try capture.nextPrefix(after: first.captureID, samples: submitted.count))
    capture.mute(true); append(0.4, packets: 4)
    XCTAssertNil(try capture.nextPrefix(after: nil, samples: 0))
    capture.mute(false); append(0.3, packets: 4)
    let third = try XCTUnwrap(capture.nextPrefix(after: first.captureID, samples: submitted.count))
    XCTAssertNotEqual(third.captureID, first.captureID); XCTAssertEqual(third.offset, 0)
    capture.stop(); XCTAssertNil(try capture.nextPrefix(after: third.captureID, samples: third.samples.count))
  }
}
