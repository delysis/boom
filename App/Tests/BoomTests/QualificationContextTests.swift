import XCTest
@testable import Boom

final class QualificationContextTests: XCTestCase {
  func testRustBoundaryRejectsTheObservedReducedWritingContextAndKeepsRegisteredInputs() throws {
    XCTAssertThrowsError(try ProductCore.qualificationContext(writing: 16_128, consultation: 16_384)) { error in
      XCTAssertTrue(error.localizedDescription.contains("was not shortened"))
    }
    XCTAssertThrowsError(try ProductCore.qualificationContext(writing: 16_384, consultation: 16_128))
    let plan = try ProductCore.qualificationContext(writing: 16_384, consultation: 16_384)
    XCTAssertEqual(plan.inputTokens, [16_128, 16_128])
    XCTAssertEqual(plan.outputTokens, 256)
    XCTAssertEqual(plan.contextTokens, 16_384)
    XCTAssertNoThrow(try ProductCore.object(plan))
  }
}
