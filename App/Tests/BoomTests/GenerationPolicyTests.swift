import XCTest
@testable import Boom

final class GenerationPolicyTests: XCTestCase {
  private func policy() throws -> ModelGenerationPolicy {
    try ProductCore.generationPolicy(vocabularySize: 16,
      configuration: Data(#"{"eos_token_id":[1,3],"suppress_tokens":[14,15]}"#.utf8),
      controls: [0, 1, 3, 14, 15], tokenizerEOS: 1)
  }

  private func changed(_ policy: ModelGenerationPolicy, field: String,
    value: Any) throws -> ModelGenerationPolicy {
    let data = try JSONEncoder().encode(policy)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object[field] = value
    return try JSONDecoder().decode(ModelGenerationPolicy.self,
      from: JSONSerialization.data(withJSONObject: object))
  }

  func testFutureDefaultAndHistoricalBalancedResolveToTheirRecordedPolicy() throws {
    let current = try policy()
    XCTAssertEqual(current.prefill, PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512))
    var historical = current
    historical.prefill = PrefillGeometry(chunking: "balanced_v1", tokenCeiling: 512)
    let originalBytes = try JSONEncoder().encode(historical)
    let restored = try JSONDecoder().decode(ModelGenerationPolicy.self, from: originalBytes)
    let effective = try ProductCore.resolvedGenerationPolicy(restored, loaded: current)
    XCTAssertEqual(effective, historical)
    XCTAssertEqual(historical.prefill?.chunking, "balanced_v1")
    try ProductCore.admitGenerationPolicy(historical, loaded: current)
    XCTAssertEqual(try ProductCore.resolvedGenerationPolicy(current, loaded: current), current)
  }

  func testResolutionRejectsChangedCheckpointFieldsAndTokenCeiling() throws {
    let current = try policy()
    let changes: [(String, Any)] = [
      ("schema", 2), ("vocabularySize", 32), ("eosTokenIDs", [1]),
      ("suppressedTokenIDs", [Int]()), ("controlTokenIDs", [0, 1, 2, 3, 14, 15]),
      ("textDecoding", "future_decoder"),
      ("prefill", ["chunking": "balanced_v1", "tokenCeiling": 1024]),
      ("prefill", ["chunking": "fixed_v1", "tokenCeiling": 513]),
      ("prefill", ["chunking": "future_chunking", "tokenCeiling": 512]),
    ]
    for (field, value) in changes {
      let captured = try changed(current, field: field, value: value)
      XCTAssertThrowsError(try ProductCore.resolvedGenerationPolicy(captured, loaded: current), field)
      XCTAssertThrowsError(try ProductCore.admitGenerationPolicy(captured, loaded: current), field)
    }
  }

  func testResolutionNeverSuppliesMissingCapturedOrLoadedSettings() throws {
    let current = try policy()
    XCTAssertThrowsError(try ProductCore.resolvedGenerationPolicy(nil, loaded: current))
    for field in ["textDecoding", "prefill"] {
      let incomplete = try changed(current, field: field, value: NSNull())
      XCTAssertThrowsError(try ProductCore.resolvedGenerationPolicy(incomplete, loaded: current), field)
      XCTAssertThrowsError(try ProductCore.resolvedGenerationPolicy(current, loaded: incomplete), field)
      XCTAssertThrowsError(try ProductCore.resolvedGenerationPolicy(incomplete, loaded: incomplete), field)
    }
  }
}
