import Foundation
import XCTest
@testable import BoomCore

final class DocumentSourceIdentityTests: XCTestCase {
  func testLocalTextIdentityDoesNotEnterRecordsOrReplacePersistentRevision() throws {
    let document = DocumentSnapshot(title: "Public fixture", text: "Cafe\u{301}")
    let bytes = try JSONEncoder().encode(document)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set(["id", "title", "text"]))
    let restored = try JSONDecoder().decode(DocumentSnapshot.self, from: bytes)
    XCTAssertEqual(restored, document)
    XCTAssertEqual(restored.revision, document.revision)
    XCTAssertEqual(Data(restored.text.utf8), Data(document.text.utf8))
    XCTAssertNotEqual(restored.textVersion, document.textVersion)
    var renamed = document; renamed.title = "Renamed fixture"
    XCTAssertEqual(renamed.textVersion, document.textVersion)
    var changed = document; changed.text = "Café"
    XCTAssertNotEqual(changed.textVersion, document.textVersion)
    XCTAssertNotEqual(changed.revision, document.revision)
    XCTAssertNotEqual(changed, document, "Different authored bytes are different snapshots.")
    XCTAssertEqual(Data(document.text.utf8), Data("Cafe\u{301}".utf8))
  }

  func testIndependentValueEditsCannotShareAContentIdentity() {
    let original = DocumentSnapshot(title: "Public fixture", text: "The harbor.")
    var first = original, second = original
    first.text.append(" A lantern.")
    second.text.replaceSubrange(second.text.startIndex..<second.text.startIndex, with: "At dawn, ")
    XCTAssertNotEqual(first.textVersion, second.textVersion)
    XCTAssertNotEqual(first.textVersion, original.textVersion)
    XCTAssertNotEqual(second.textVersion, original.textVersion)
    XCTAssertEqual(Data(original.text.utf8), Data("The harbor.".utf8))
  }
}
