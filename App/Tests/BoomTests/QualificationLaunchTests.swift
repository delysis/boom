import XCTest
@testable import Boom

final class QualificationLaunchTests: XCTestCase {
  func testOrdinaryLaunchRetainsArgumentsAndRejectsFixtureOverlay() throws {
    let original = ["Bloom", "--native-check-workspace", "/explicit"]
    XCTAssertEqual(try QualificationLaunch.arguments(original, bundleID: "com.delysis.Bloom", fixture: nil, pid: 7), original)
    XCTAssertThrowsError(try QualificationLaunch.arguments(original, bundleID: "com.delysis.Bloom", fixture: [:], pid: 7))
  }
  func testArgumentFreeQualificationCannotFallThroughToPrivateDefault() throws {
    XCTAssertThrowsError(try QualificationLaunch.arguments(["BloomCheck"], bundleID: QualificationLaunch.bundleID, fixture: nil, pid: 7))
    let fixture = ["workspace": "/public/workspace", "evidenceBase": "/public/evidence", "qualificationID": "A473B87F-9F66-43E1-9444-29EB87E36672"]
    let expected = ["BloomCheck", "--native-check-workspace", "/public/workspace", "--native-check-qualification-id", fixture["qualificationID"]!, "--native-check-evidence", "/public/evidence/7", "--native-check-no-models"]
    XCTAssertEqual(try QualificationLaunch.arguments(["BloomCheck"], bundleID: QualificationLaunch.bundleID, fixture: fixture, pid: 7), expected)
    XCTAssertEqual(try QualificationLaunch.arguments(["BloomCheck", "--native-check-workspace", "/private"], bundleID: QualificationLaunch.bundleID, fixture: fixture, pid: 7), expected)
    var malformed = fixture; malformed["qualificationID"] = "invalid"
    XCTAssertThrowsError(try QualificationLaunch.arguments(["BloomCheck"], bundleID: QualificationLaunch.bundleID, fixture: malformed, pid: 7))
  }
  func testUniqueQualificationIdentityIsBoundToItsOwnFixture() throws {
    let scope = UUID(), identity = QualificationLaunch.scopedBundleID(scope)
    let fixture = ["workspace": "/public/workspace", "evidenceBase": "/public/evidence", "qualificationID": scope.uuidString]
    let args = try QualificationLaunch.arguments(["BloomCheck"], bundleID: identity, fixture: fixture, pid: 9)
    XCTAssertTrue(args.contains("/public/workspace"))
    XCTAssertThrowsError(try QualificationLaunch.arguments(["BloomCheck"], bundleID: identity, fixture: nil, pid: 9))
    XCTAssertThrowsError(try QualificationLaunch.arguments(["BloomCheck"], bundleID: QualificationLaunch.scopedBundleID(UUID()), fixture: fixture, pid: 9))
    XCTAssertThrowsError(try QualificationLaunch.arguments(["BloomCheck"], bundleID: QualificationLaunch.bundleID + ".invalid", fixture: fixture, pid: 9))
  }
}
