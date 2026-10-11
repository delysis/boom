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
      "--memory-budget", "--residency-fallback", "--preempt", "--writing-fixtures", "--batch",
      "--prompt-cache-smoke", "--cache-consultation-fixture"] {
      XCTAssertThrowsError(try MLXNativeSmoke.validateConsultationArguments(pair + [other]))
    }
  }

  func testCacheDiagnosticRequiresBothExactPacksAndItsDedicatedFixture() throws {
    let cache = ["--mlx-smoke", "--prompt-cache-smoke", "--pack", "/public/writing",
      "--consultation-pack", "/public/consultation", "--evidence", "/public/fresh"]
    try MLXNativeSmoke.validateConsultationArguments(cache)
    try MLXNativeSmoke.validateCacheArguments(cache)
    try MLXNativeSmoke.validateCacheArguments(cache + ["--cache-consultation-fixture", "/public/4k.json", "--seed", "42"])
    XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(["--cache-consultation-fixture", "/public/4k.json"]))
    for other in ["--base", "--edit-smoke", "--propose-smoke", "--unchanged-smoke",
      "--memory-budget", "--residency-fallback", "--preempt", "--writing-fixtures", "--batch",
      "--shared-model", "--consultation-fixture", "--consultation-warmup",
      "--benchmark-prefill-tokens", "--benchmark-cache-mib", "--fixture", "--unknown"] {
      XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(cache + [other]), other)
    }
    XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(cache + ["--seed", "43"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(cache + ["--seed", "42", "--seed", "42"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(cache + ["--prompt-cache-smoke"]))
  }

  func testCachePathsRejectMissingDuplicatedRelativeAndFlagValuesBeforeExecution() throws {
    let paths = ["--pack", "--consultation-pack", "--evidence", "--cache-consultation-fixture"]
    let cache = ["--prompt-cache-smoke", "--pack", "/public/writing",
      "--consultation-pack", "/public/consultation", "--evidence", "/public/fresh",
      "--cache-consultation-fixture", "/public/4k.json"]
    for path in paths {
      let index = try XCTUnwrap(cache.firstIndex(of: path))
      var missingValue = cache; missingValue.remove(at: index + 1)
      XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(missingValue), path)
      var relative = cache; relative[index + 1] = "public/relative"
      XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(relative), path)
      XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(cache + [path, "/public/duplicate"]), path)
      if path != "--cache-consultation-fixture" {
        var missingPath = cache; missingPath.removeSubrange(index...(index + 1))
        XCTAssertThrowsError(try MLXNativeSmoke.validateCacheArguments(missingPath), path)
      }
    }
  }
}
