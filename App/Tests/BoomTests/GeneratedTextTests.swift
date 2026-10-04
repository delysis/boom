import XCTest
@testable import Boom

final class GeneratedTextTests: XCTestCase {
  func testProtocolTokenSplitAcrossChunksNeverAppears() {
    XCTAssertEqual(GemmaGeneratedText.visiblePrefix("A harbor <imag", final: false), "A harbor ")
    XCTAssertEqual(GemmaGeneratedText.visiblePrefix(
      "A harbor <image|>hidden", final: false), "A harbor ")
    XCTAssertEqual(GemmaGeneratedText.visiblePrefix(
      "A harbor <image|>hidden", final: true), "A harbor ")
    XCTAssertEqual(GemmaGeneratedText.visiblePrefix("A harbor <3", final: true), "A harbor <3")
  }
}
