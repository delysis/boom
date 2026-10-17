import Foundation
import XCTest
@testable import BoomCore

final class TextInputLimitTests: XCTestCase {
  func testEveryUTF16BoundaryIncludingNSStringBackedInput() throws {
    let inputs = ["🪶e\u{301}", String(NSString(string: "🪶e\u{301}")), "a👩‍👩‍👧‍👧z", "", "a\r\nb"]
    for text in inputs {
      let units = Array(text.utf16)
      func valid(_ i: Int) -> Bool {
        i == 0 || i == units.count || !(0xD800...0xDBFF).contains(units[i - 1]) || !(0xDC00...0xDFFF).contains(units[i])
      }
      for start in 0...units.count {
        for end in start...units.count {
          let result = Result { try TextInputLimit.validateReplacement(in: text,
            range: NSRange(location: start, length: end - start), replacement: "x", maximumUTF8Bytes: Int.max) }
          if valid(start) && valid(end) { XCTAssertNoThrow(try result.get(), "\(start)..<\(end) in \(text)") }
          else { XCTAssertThrowsError(try result.get()) }
        }
      }
    }
  }
  func testBoundsAreCheckedWithoutOverflowAndDeletingCanRecoverAnOverlimitInput() throws {
    let text = "🪶e\u{301}", count = text.utf8.count
    XCTAssertThrowsError(try TextInputLimit.validateReplacement(in: text, range: NSRange(location: 4, length: 0), replacement: "a", maximumUTF8Bytes: count))
    try TextInputLimit.validateReplacement(in: text, range: NSRange(location: 0, length: 2), replacement: "a", maximumUTF8Bytes: count - 3)
    for range in [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1), NSRange(location: Int.max, length: 1), NSRange(location: 2, length: Int.max)] {
      XCTAssertThrowsError(try TextInputLimit.validateReplacement(in: text, range: range, replacement: "", maximumUTF8Bytes: Int.max))
    }
    XCTAssertThrowsError(try TextInputLimit.validateReplacement(in: "", range: NSRange(location: 0, length: 0), replacement: "", maximumUTF8Bytes: -1))
  }
}
