import Foundation
import XCTest
@testable import Boom

final class PagedSealedCursorTests: XCTestCase {
  func testCursorRoundTripKeepsDirectionIndependentFromVisualAffinity() throws {
    let cursor = PagedSealedCursor(byteOffset: 1_073_741_824, utf16Offset: 4096,
      selectionLengthUTF16: 8192, focusAtEnd: true, affinity: .upstream)
    let data = try JSONEncoder().encode(cursor)
    XCTAssertEqual(try JSONDecoder().decode(PagedSealedCursor.self, from: data), cursor)
    XCTAssertEqual(cursor.focusUTF16, 12_288)
    XCTAssertLessThan(data.count, 160)
    let ordinary = try JSONEncoder().encode(PagedSealedCursor(byteOffset: 0, utf16Offset: 0))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: ordinary) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set(["byteOffset", "utf16Offset"]))
  }

  func testCursorRejectsUnknownAffinityInsteadOfChangingDirection() {
    let malformed = Data(#"{"byteOffset":0,"utf16Offset":0,"affinity":2}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(PagedSealedCursor.self, from: malformed))
  }
}
