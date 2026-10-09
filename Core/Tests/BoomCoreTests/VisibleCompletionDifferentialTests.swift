import Foundation
import XCTest
@testable import BoomCore

final class VisibleCompletionDifferentialTests: XCTestCase {
  private func original(_ text: String) -> String? {
    guard let content = text.firstIndex(where: { !$0.isWhitespace }) else {
      return GemmaPrompt.admissibleCompletion(text) ? text : nil
    }
    let paragraph = text[content...].components(separatedBy: "\n\n").first ?? ""
    let visible = String(text[..<content])
      + paragraph.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
    return GemmaPrompt.admissibleCompletion(visible) ? visible : nil
  }
  func testEveryShortLFCRSpaceCombination() {
    let alphabet = ["a", " ", "\n", "\r"]
    var frontier = [""]
    for _ in 0...7 {
      for text in frontier {
        XCTAssertEqual(GemmaPrompt.visibleCompletion(text), original(text), text.debugDescription)
      }
      frontier = frontier.flatMap { prefix in alphabet.map { prefix + $0 } }
    }
  }
  func testUnicodeAndInvalidContentAtSelectedAndUnselectedEnds() {
    let corpus = ["👩🏽‍💻", "e\u{301}", "\u{FFFD}", "\0", "\u{2028}", "\t", "\r\n"]
    for left in corpus {
      for right in corpus {
        for separator in ["", "\n", "\n\n", "\r\n\r\n", "\na\nb\nc"] {
          let text = left + "a" + separator + right
          XCTAssertEqual(GemmaPrompt.visibleCompletion(text), original(text), text.debugDescription)
        }
      }
    }
  }
  func testByteLimitAndParagraphDelimiterInteractWithoutOffByOne() {
    for count in [4094, 4095, 4096, 4097, 8192] {
      for suffix in ["", "\n", "\n\nignored", "\r\n\r\nignored", "\nb\nc\nd"] {
        let text = String(repeating: "a", count: count) + suffix
        XCTAssertEqual(GemmaPrompt.visibleCompletion(text), original(text))
      }
    }
    XCTAssertEqual(GemmaPrompt.visibleCompletion(String(repeating: "a", count: 4096) + "\n\nignored"),
      String(repeating: "a", count: 4096))
  }
  func testLargeUnselectedTailDoesNotAffectResult() {
    let prefix = "  first\nsecond\nthird"
    let text = prefix + "\n" + String(repeating: "z", count: 1_000_000)
    XCTAssertEqual(GemmaPrompt.visibleCompletion(text), prefix)
  }
}
