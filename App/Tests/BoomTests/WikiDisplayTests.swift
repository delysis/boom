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

  @MainActor func testDenseUnicodeReferencesRespectUnsortedNestedAndTouchingLiteralRanges() throws {
    let source = (0..<256).map { "é🙂 [[Item\($0)]] " }.joined()
    let text = source as NSString
    let pattern = try NSRegularExpression(pattern: #"\[\[[^\]]+\]\]"#)
    let matches = pattern.matches(in: source, range: NSRange(location: 0, length: text.length))
    var excluded: [NSRange] = []
    for (index, match) in matches.enumerated() where index % 3 == 0 {
      excluded.append(match.range)
      excluded.append(NSRange(location: match.range.location + 1, length: 2))
      excluded.append(match.range)
    }
    // Touch both edges without crossing the otherwise visible second marker.
    excluded.append(NSRange(location: matches[1].range.location - 1, length: 1))
    excluded.append(NSRange(location: NSMaxRange(matches[1].range), length: 1))
    excluded.append(NSRange(location: matches[1].range.location + 2, length: 0))
    excluded.reverse()
    let expected = matches.filter { match in
      !excluded.contains { NSIntersectionRange($0, match.range).length > 0 }
    }.map { text.substring(with: NSRange(location: $0.range.location + 2, length: $0.range.length - 4)) }
    let actual = MarkdownStyle.wikiDisplays(in: source, excluding: excluded)
    XCTAssertEqual(actual.map { text.substring(with: $0.title) }, expected)
    XCTAssertTrue(actual.contains { text.substring(with: $0.title) == "Item1" })
    XCTAssertEqual(actual.count, 170)
  }
}
