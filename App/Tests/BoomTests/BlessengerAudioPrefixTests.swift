import BoomCore
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import XCTest
@testable import Boom

extension BlessengerTests {
  /// Actual CPU Gemma forwards, including its raw-audio projector, shared KV
  /// layers and rotating-window boundary. This is not a real-weight call test.
  func testCausalAudioPrefixesMatchOneShotGemmaIncludingPerLayerInputs() throws {
    try Device.withDefaultDevice(.cpu) {
      for perLayer in [0, 4] {
        let json = """
        {"model_type":"gemma4_unified","vocab_size":32,
         "image_token_id":31,"audio_token_id":30,"video_token_id":29,
         "boa_token_id":25,"eoa_token_id":26,
         "text_config":{"hidden_size":16,"num_hidden_layers":4,"intermediate_size":32,
           "num_attention_heads":2,"num_key_value_heads":1,"num_global_key_value_heads":1,
           "head_dim":8,"global_head_dim":8,"vocab_size":32,"vocab_size_per_layer_input":32,
           "num_kv_shared_layers":2,"hidden_size_per_layer_input":\(perLayer),
           "sliding_window":512,"max_position_embeddings":4096,"attention_k_eq_v":true,
           "use_double_wide_mlp":false,"tie_word_embeddings":true,
           "layer_types":["sliding_attention","full_attention","sliding_attention","full_attention"]},
         "vision_config":null,"audio_config":{}}
        """
        let configuration = try JSONDecoder().decode(Gemma4UnifiedConfiguration.self, from: Data(json.utf8))
        let model = withRandomState(MLXRandom.RandomState(seed: 1984)) { Gemma4Unified(configuration) }
        eval(model)
        let width = try XCTUnwrap(configuration.audioConfiguration).audioSamplesPerToken
        XCTAssertEqual(width, 640)
        let audio: [Float] = (0..<(9 * width)).map { sin(Float($0) * 0.017) * 0.1 }
        let prefix: [Int32] = (0..<510).map { Int32(1 + $0 % 20) } + [25]
        let suffix: [Int32] = [26, 3, 4]
        let whole = prefix + Array(repeating: Int32(30), count: 9) + suffix
        let full = try model.newCache(parameters: nil), live = try model.newCache(parameters: nil)
        let input = LMInput(text: .init(tokens: MLXArray(whole).reshaped([1, whole.count])),
          audio: .init(features: MLXArray(audio).reshaped([1, 9, width])))
        let reference = try model.prepare(input, cache: full, state: nil, prefill: .init())
        guard case .logits(let expected) = reference else { XCTFail("The audio prompt did not produce logits."); return }
        let last = expected.logits[0..., -1, 0...]; eval(last, full)
        for start in stride(from: 0, to: prefix.count, by: 128) {
          let part = Array(prefix[start..<min(prefix.count, start + 128)])
          _ = try model.prepareCausalAudioChunk(LMInput(text: .init(tokens: MLXArray(part).reshaped([1, part.count]))), cache: live)
          eval(live)
        }
        for rows in [0..<2, 2..<5, 5..<9] {
          let chunk = LMInput(text: .init(tokens: MLXArray(Array(repeating: Int32(30), count: rows.count)).reshaped([1, rows.count])),
            audio: .init(features: MLXArray(Array(audio[(rows.lowerBound * width)..<(rows.upperBound * width)])).reshaped([1, rows.count, width])))
          _ = try model.prepareCausalAudioChunk(chunk, cache: live); eval(live)
        }
        let ending = try model.prepareCausalAudioChunk(LMInput(text: .init(tokens: MLXArray(suffix).reshaped([1, suffix.count]))), cache: live)
        let actual = ending.logits[0..., -1, 0...]; eval(actual, live)
        XCTAssertTrue(all(isFinite(actual)).item(Bool.self))
        XCTAssertLessThan(abs(actual - last).max().item(Float.self), 5e-4)
        XCTAssertEqual(live.map(\.offset), full.map(\.offset))
        // Equal next-token forwards prove usable continuation, not merely a
        // matching published prefix count or a relabeled row.
        for token: Int32 in [7, 8, 9] {
          let a = model(MLXArray([token]).reshaped([1, 1]), cache: full)
          let b = model(MLXArray([token]).reshaped([1, 1]), cache: live)
          eval(a, b)
          XCTAssertLessThan(abs(a - b).max().item(Float.self), 5e-4)
        }
      }
    }
  }

  func testAdmittedCallerWaveRetainsEveryOriginalFloatBit() throws {
    let samples: [Float] = (0..<1291).map { sin(Float($0) * 0.137) * 0.12345 }
    let clip = BlessengerCallerClip(samples: samples, firstFrame: 4000, endFrame: 5291,
      speechEndedUptime: 2, admittedUptime: 3, decision: "semantic")
    let decoded = try BlessengerWave.decode(clip.wav())
    XCTAssertEqual(decoded.rate, 16000)
    XCTAssertEqual(decoded.samples.map(\.bitPattern), samples.map(\.bitPattern))
    XCTAssertEqual(decoded.samples.count, Int(clip.endFrame - clip.firstFrame))
  }
}
