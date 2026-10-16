import BoomCore
import Foundation
import XCTest

final class ForwardOperandBindingTests: XCTestCase {
  private typealias Binding = ForwardOperandBinding
  private func member(_ row: Int, padding: String = "actual-left-padding") -> Binding.Member {
    .init(logicalRequests: [Digest.sha256("request-\(row)")],
      preparedTokenDigest: Digest.sha256("prepared-\(row)"), preparedTokenCount: 8,
      cachedTokenCount: 4, cachedTokenDigest: Digest.sha256("cached-tokens-\(row)"),
      cachedSourceDigest: Digest.sha256("joined-source-\(row)"), cachePaddingDigest: Digest.sha256(padding))
  }
  private func candidate(_ rows: [[Int]], members: [Binding.Member]? = nil,
    start: Int = 4, valid: [Int]? = nil) -> Binding? {
    Binding.candidate(phase: .decode, modelBinding: Digest.sha256("actual-model-and-policy"),
      members: members ?? rows.indices.map { member($0) }, inputRangeStart: 0, tokenRows: rows,
      logicalStarts: Array(repeating: start, count: rows.count),
      validLengths: valid ?? rows.map(\.count), generationActive: Array(repeating: true, count: rows.count))
  }

  func testActualMatrixAndDeclaredMembershipMustHaveIdenticalDimensions() throws {
    XCTAssertNil(candidate([[11], [22]], members: [member(0)]))
    XCTAssertNil(candidate([[11]], members: [member(0), member(1)]))
    XCTAssertNil(candidate([[11], [22, 23]]))
    XCTAssertNil(candidate([[11], [-1]]))
    XCTAssertNil(candidate(Array(repeating: [11], count: 5)))
    let actual = try XCTUnwrap(candidate([[11], [22]]))
    XCTAssertEqual(actual.physicalWidth, 2)
    XCTAssertEqual(actual.logicalStarts, [4, 4])
  }

  func testUnchangedSelectedRowDoesNotHideChangedPeerOperandsOrMembership() throws {
    let original = try XCTUnwrap(candidate([[11], [22]]))
    let peerChanged = try XCTUnwrap(candidate([[11], [23]]))
    XCTAssertNotEqual(original.tokenMatrixDigest, peerChanged.tokenMatrixDigest)
    let membershipChanged = try XCTUnwrap(candidate([[11], [22]], members: [member(0), member(2)]))
    XCTAssertEqual(original.tokenMatrixDigest, membershipChanged.tokenMatrixDigest)
    XCTAssertNotEqual(original, membershipChanged)
    XCTAssertNil(candidate([[11], [22]], members: [member(0), member(0)]))
  }

  func testPaddingAndPhysicalTokensRemainBoundBeyondTheSelectedPrefix() throws {
    let padded = try XCTUnwrap(candidate([[11, 0], [22, 23]], valid: [1, 2]))
    let differentOperand = try XCTUnwrap(candidate([[11, 9], [22, 23]], valid: [1, 2]))
    let differentPadding = try XCTUnwrap(candidate([[11, 0], [22, 23]],
      members: [member(0), member(1, padding: "different-cache-left-padding")], valid: [1, 2]))
    XCTAssertNotEqual(padded.tokenMatrixDigest, differentOperand.tokenMatrixDigest)
    XCTAssertNotEqual(padded, differentPadding)
    let submitted = try XCTUnwrap(padded.committed(allOwningLayersComplete: true, actuallySubmitted: true))
    XCTAssertTrue(submitted.covers(start: 4, end: 5, evaluatedEnd: 6, width: 2, row: 0))
    XCTAssertFalse(submitted.covers(start: 4, end: 6, evaluatedEnd: 6, width: 2, row: 0))
    XCTAssertFalse(submitted.covers(start: 4, end: 5, evaluatedEnd: 5, width: 2, row: 0))
  }

  func testPredictionCancellationAndPartialLayerUpdatesAreNotCompletedForwards() throws {
    let predicted = try XCTUnwrap(candidate([[11], [22]]))
    XCTAssertFalse(predicted.submittedAndCompleted)
    XCTAssertFalse(predicted.covers(start: 4, end: 5, evaluatedEnd: 5, width: 2, row: 0))
    XCTAssertNil(predicted.committed(allOwningLayersComplete: false, actuallySubmitted: true))
    XCTAssertNil(predicted.committed(allOwningLayersComplete: true, actuallySubmitted: false))
    let actual = try XCTUnwrap(predicted.committed(allOwningLayersComplete: true, actuallySubmitted: true))
    XCTAssertTrue(actual.covers(start: 4, end: 5, evaluatedEnd: 5, width: 2, row: 0))
  }

  func testClippedAndHydratedMetadataKeepsTheOriginalFullOperandBinding() throws {
    let original = try XCTUnwrap(candidate([[11, 12, 13], [21, 22, 23]]))
    let submitted = try XCTUnwrap(original.committed(allOwningLayersComplete: true, actuallySubmitted: true))
    let restored = try JSONDecoder().decode(Binding.self, from: JSONEncoder().encode(submitted))
    XCTAssertEqual(restored, submitted)
    XCTAssertTrue(restored.covers(start: 4, end: 5, evaluatedEnd: 7, width: 2, row: 1))
    XCTAssertEqual(restored.tokenMatrixDigest, original.tokenMatrixDigest)
    XCTAssertEqual(restored.members, original.members)
    XCTAssertFalse(restored.covers(start: 4, end: 5, evaluatedEnd: 5, width: 2, row: 1))
    XCTAssertFalse(restored.covers(start: 4, end: 5, evaluatedEnd: 7, width: 1, row: nil))
  }

  func testUnsupportedScopeAndOverflowCannotLaunderCapturedEvidence() throws {
    let actual = try XCTUnwrap(candidate([[11], [22]], start: 12))
    // Generated positions may exceed the original prepared prompt's eight IDs.
    XCTAssertTrue(actual.wellFormed)
    XCTAssertNil(candidate([[11]], start: -1))
    XCTAssertNil(candidate([[11]], start: Int.max))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as? [String: Any])
    json["evidenceScope"] = "multimodal-features-not-observed"
    let unsupported = try JSONDecoder().decode(Binding.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertFalse(unsupported.wellFormed)
    XCTAssertNil(unsupported.committed(allOwningLayersComplete: true, actuallySubmitted: true))
    json["evidenceScope"] = Binding.scope
    json["logicalStarts"] = [Int.max, 12]
    let overflow = try JSONDecoder().decode(Binding.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertFalse(overflow.wellFormed)
  }

  func testMaximumRowMetadataFitsItsFixedExistingPoolCharge() throws {
    let actual = try XCTUnwrap(candidate([[11], [22], [33], [44]]))
    XCTAssertLessThanOrEqual(UInt64(try JSONEncoder().encode(actual).count), Binding.metadataBytesUpperBound)
  }
}
