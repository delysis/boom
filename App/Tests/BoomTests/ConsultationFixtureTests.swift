import XCTest
@testable import Boom

final class ConsultationFixtureTests: XCTestCase {
  func testCapturedWorkloadCannotChangeModelSeedOrBudgets() throws {
    var object: [String: Any] = [
      "model": "public-instruction-fixture", "plan": ["messages": [], "rawPrompt": "public text"],
      "generation_policy": ["schema": 1, "vocabularySize": 262144, "eosTokenIDs": [1],
        "suppressedTokenIDs": [], "controlTokenIDs": [1]],
      "seeds": [42], "max_tokens_per_row": 256,
      "outputs": [["prompt_digest": String(repeating: "a", count: 64), "prompt_tokens": 4096]]]
    func decode(_ model: String = "public-instruction-fixture", seed: UInt64 = 42) throws {
      _ = try MLXNativeSmoke.ConsultationFixture.decode(JSONSerialization.data(withJSONObject: object),
        model: model, seed: seed, promptTokens: 4096, outputTokens: 256)
    }
    try decode()
    XCTAssertThrowsError(try decode("another-checkpoint"))
    XCTAssertThrowsError(try decode(seed: 2026))
    object["max_tokens_per_row"] = 1
    XCTAssertThrowsError(try decode())
    object["max_tokens_per_row"] = 256
    object["outputs"] = [["prompt_digest": String(repeating: "a", count: 64), "prompt_tokens": 512]]
    XCTAssertThrowsError(try decode())
  }

  func testConsultationModeCannotBeShadowedByAnotherDiagnostic() throws {
    let pair = ["--consultation-fixture", "/public/4k.json", "--consultation-warmup", "/public/warmup.json"]
    try MLXNativeSmoke.validateConsultationArguments(pair)
    try MLXNativeSmoke.validateConsultationArguments(["--base"])
    XCTAssertThrowsError(try MLXNativeSmoke.validateConsultationArguments(["--consultation-fixture"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateConsultationArguments(["--consultation-warmup"]))
    for other in ["--base", "--edit-smoke", "--propose-smoke", "--unchanged-smoke",
      "--memory-budget", "--residency-fallback", "--preempt", "--writing-fixtures", "--batch"] {
      XCTAssertThrowsError(try MLXNativeSmoke.validateConsultationArguments(pair + [other]))
    }
  }
}
