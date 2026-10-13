import AppKit
import Foundation
import XCTest
@testable import Boom

/// NSString/context properties only. These do not invent a published source,
/// controller ACK or successful storage call; the real-file case is separate.
@MainActor final class PagedContainedCharacterBoundaryTests: XCTestCase {
  private func cluster(_ source: String, caret: Int, forward: Bool,
    start: Bool = false, end: Bool = false) -> NSRange? {
    PagedContainedCharacterBoundary.cluster(in: source as NSString, caretUTF16: caret,
      forward: forward, atDocumentStart: start, atDocumentEnd: end)
  }

  func testNFDAndEmojiZWJAfterActualControlResetHaveCompleteLocalCocoaRanges() {
    for reset in ["\n", "\r\n", "\u{0}", "\u{85}", "\u{2028}", "\u{2029}"] {
      for value in ["e\u{301}", "👩🏽‍💻", "🇺🇸"] {
        let source = "unseen prefix" + reset + value + " next"
        let text = source as NSString, expected = text.range(of: value, options: .literal)
        XCTAssertEqual(cluster(source, caret: expected.location, forward: true), expected)
        XCTAssertEqual(cluster(source, caret: NSMaxRange(expected), forward: false), expected)
      }
    }
  }

  func testTrueStartSuppliesContextButSpaceAndArbitraryOverlapDoNot() {
    let source = "e\u{301} next"
    XCTAssertEqual(cluster(source, caret: 0, forward: true, start: true), NSRange(location: 0, length: 2))
    XCTAssertNil(cluster(source, caret: 0, forward: true))
    XCTAssertNil(cluster("space e\u{301} next", caret: 6, forward: true))
    XCTAssertNil(cluster("🇺🇸🇨🇦 next", caret: 4, forward: true))
    XCTAssertNil(cluster("🏽‍💻 next", caret: 5, forward: false))
  }

  func testTruncatedRightClusterRequiresActualEOFDespiteKnownReset() {
    for value in ["e\u{301}", "👩🏽‍", "🇺"] {
      let source = "\n" + value, range = NSRange(location: 1, length: (value as NSString).length)
      XCTAssertNil(cluster(source, caret: 1, forward: true))
      XCTAssertNil(cluster(source, caret: NSMaxRange(range), forward: false))
      XCTAssertEqual(cluster(source, caret: 1, forward: true, end: true), range)
      XCTAssertEqual(cluster(source, caret: NSMaxRange(range), forward: false, end: true), range)
    }
  }

  func testScalarOrClusterInteriorAndObservedCRLFDoNotAcquirePartialAdmission() {
    XCTAssertNil(cluster("\ne\u{301} next", caret: 2, forward: true))
    XCTAssertNil(cluster("\ne\u{301} next", caret: 2, forward: false))
    XCTAssertNil(cluster("\n🙂 next", caret: 2, forward: true))
    XCTAssertNil(cluster("\n🙂 next", caret: 2, forward: false))
    XCTAssertNil(cluster("\r\nnext", caret: 1, forward: true, start: true))
    XCTAssertNil(cluster("\r\nnext", caret: 1, forward: false, start: true))
    XCTAssertNil(cluster("\n🇺", caret: 1, forward: true))
  }
}
