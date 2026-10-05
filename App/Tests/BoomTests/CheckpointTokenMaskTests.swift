import MLX
import MLXLMCommon
import XCTest
@testable import Boom

final class CheckpointTokenMaskTests: XCTestCase {
  func testMaskPreservesEveryAllowedLogitAndSamplerCannotChooseExcludedMaxima() {
    // Small CPU arrays exercise the actual MLX processor and all shipped
    // samplers. The signed real-weight evaluation separately exercises Metal.
    Device.withDefaultDevice(.cpu) {
      let input = MLXArray([Float(3), 2, 1, 100, 200], [1, 5])
      let processor = CheckpointTokenMask([3, 4])
      let filtered = processor.process(logits: input)
      XCTAssertEqual(filtered.asArray(Float.self), [3, 2, 1, -.infinity, -.infinity])
      XCTAssertEqual(input.asArray(Float.self), [3, 2, 1, 100, 200])
      XCTAssertEqual(CheckpointTokenMask([]).process(logits: input).asArray(Float.self), input.asArray(Float.self))
      XCTAssertEqual(processor.copy().process(logits: input).asArray(Float.self), filtered.asArray(Float.self))
      for seed in UInt64(0)..<32 {
        for temperature: Float in [0, 0.8, 1, 1.1] {
          let parameters = GenerateParameters(temperature: temperature,
            topP: temperature == 1.1 ? 1 : 0.95, topK: temperature == 1.1 ? 0 : 64,
            minP: temperature == 1.1 ? 0.05 : 0, seed: seed)
          let token = parameters.sampler().sample(logits: filtered).item(Int.self)
          XCTAssertTrue((0..<3).contains(token), "Suppressed maximum won for seed \(seed)")
        }
      }
    }
  }
  func testAllowedEOSRemainsEligibleAndMaskBroadcastsAcrossRows() {
    Device.withDefaultDevice(.cpu) {
      let input = MLXArray([Float(0), 30, 2, 80, 3, 40, 0, 90], [2, 4])
      let filtered = CheckpointTokenMask([3]).process(logits: input)
      XCTAssertEqual(filtered.asArray(Float.self), [0, 30, 2, -.infinity, 3, 40, 0, -.infinity])
      XCTAssertEqual(GenerateParameters(temperature: 0).sampler().sample(logits: filtered).asArray(Int32.self), [1, 1])
    }
  }
}
