import XCTest
@testable import Boom

final class WikiDisplayTests: XCTestCase {
  @MainActor func testStableReferenceKeepsIdentityInSourceButDisplaysTitle() {
    let id = UUID()
    let source = "Before [[A document|\(id.uuidString)]] after"
    let displays = MarkdownStyle.wikiDisplays(in: source)
    XCTAssertEqual(displays.count, 1)
    let text = source as NSString
    XCTAssertEqual(text.substring(with: displays[0].title), "A document")
    XCTAssertEqual(displays[0].hidden.map { text.substring(with: $0) },
      ["[[", "|\(id.uuidString)]]"])
    XCTAssertEqual(source, "Before [[A document|\(id.uuidString)]] after")
  }

  @MainActor func testMalformedStableReferenceRemainsVisibleForRepair() {
    XCTAssertTrue(MarkdownStyle.wikiDisplays(in: "[[Draft|not-an-id]]").isEmpty)
  }
}
