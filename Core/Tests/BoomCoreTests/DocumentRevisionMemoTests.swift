import Foundation
import Synchronization
import XCTest
@testable import BoomCore

/// Content identity, value-copy isolation and wire authority remain the contract.
/// These checks make no timing or ordinary-use performance claim.
final class DocumentRevisionMemoTests: XCTestCase {
  private final class Observations: Sendable {
    private let values: Mutex<[String?]>
    init(count: Int) { values = Mutex(Array(repeating: nil, count: count)) }
    func record(_ value: String, at index: Int) { values.withLock { $0[index] = value } }
    func snapshot() -> [String?] { values.withLock { $0 } }
  }
  func testWarmRevisionDoesNotChangeSerializedSnapshotOrContentIdentity() throws {
    let document = DocumentSnapshot(title: "Public fixture", text: "Cafe\u{301}\n🙂\r\n")
    let before = try Digest.canonical(document)
    let expected = Digest.sha256(Data(document.text.utf8))
    for _ in 0..<8 { XCTAssertEqual(document.revision, expected) }
    XCTAssertEqual(try Digest.canonical(document), before)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["id", "title", "text"]))
    XCTAssertEqual(Data(try XCTUnwrap(object["text"] as? String).utf8), Data(document.text.utf8))
  }

  func testOwnedCopyMutationCannotPoisonOriginalOrAnotherUnchangedCopy() {
    let original = DocumentSnapshot(title: "Public fixture", text: "The harbor was quiet.")
    var changed = original
    let unchanged = original
    let originalRevision = original.revision
    XCTAssertEqual(changed.revision, originalRevision)
    changed.text = "The harbor was bright."
    XCTAssertNotEqual(changed.textVersion, original.textVersion)
    XCTAssertEqual(changed.revision, Digest.sha256(changed.text))
    XCTAssertNotEqual(changed.revision, originalRevision)
    XCTAssertEqual(original.revision, originalRevision)
    XCTAssertEqual(unchanged.revision, originalRevision)
    XCTAssertEqual(unchanged, original)
    XCTAssertNotEqual(changed, original)
    let independentlyCreated = DocumentSnapshot(id: original.id, title: original.title, text: original.text)
    XCTAssertEqual(independentlyCreated, original)
  }

  func testEveryTextAssignmentRotatesVersionIncludingSameBytesAndReversion() {
    var document = DocumentSnapshot(title: "Public fixture", text: "The harbor.")
    let original = document, originalRevision = document.revision
    let sameBytes = document.text
    document.text = sameBytes
    XCTAssertNotEqual(document.textVersion, original.textVersion)
    XCTAssertEqual(document.revision, originalRevision)
    XCTAssertEqual(document, original)
    let assignedVersion = document.textVersion
    document.text.append(" A boat arrived.")
    XCTAssertNotEqual(document.textVersion, assignedVersion)
    XCTAssertEqual(document.revision, Digest.sha256(document.text))
    XCTAssertNotEqual(document.revision, originalRevision)
    let changedVersion = document.textVersion
    document.text = original.text
    XCTAssertNotEqual(document.textVersion, changedVersion)
    XCTAssertEqual(document.revision, originalRevision)
    XCTAssertEqual(document, original)
  }

  func testTitleOnlyChangePreservesContentDigestAndTextVersion() {
    let original = DocumentSnapshot(title: "Public fixture", text: "The harbor.")
    let revision = original.revision
    var renamed = original
    renamed.title = "Renamed public fixture"
    XCTAssertEqual(renamed.textVersion, original.textVersion)
    XCTAssertEqual(renamed.revision, revision)
    XCTAssertEqual(Data(renamed.text.utf8), Data(original.text.utf8))
    XCTAssertNotEqual(renamed, original)
  }

  func testDecodeIgnoresUntrustedCachedFieldsAndStartsFreshLocalVersion() throws {
    let original = DocumentSnapshot(title: "Public fixture", text: "Cafe\u{301}\r\n")
    let originalRevision = original.revision
    let encoded = try Digest.canonical(original)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["revision"] = String(repeating: "0", count: 64)
    object["revisionMemo"] = ["cached": String(repeating: "f", count: 64)]
    object["textVersion"] = original.textVersion.uuidString
    var restored = try JSONDecoder().decode(DocumentSnapshot.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNotEqual(restored.textVersion, original.textVersion)
    XCTAssertEqual(restored.revision, originalRevision)
    XCTAssertEqual(try Digest.canonical(restored), encoded)
    XCTAssertEqual(restored, original)
    restored.text = "Changed public source."
    XCTAssertEqual(restored.revision, Digest.sha256(restored.text))
    XCTAssertNotEqual(restored.revision, originalRevision)
    XCTAssertEqual(original.revision, originalRevision)
  }

  func testPropertyListRestoreAndSameByteAssignmentKeepContentBasedGhostAuthority() throws {
    let document = DocumentSnapshot(title: "Public fixture", text: "The harbor.")
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let coldBytes = try encoder.encode(document)
    let stamp = try GhostStamp(document: document, caretUTF16: document.text.utf16.count, epoch: 7)
    XCTAssertEqual(try encoder.encode(document), coldBytes)
    var restored = try PropertyListDecoder().decode(DocumentSnapshot.self, from: coldBytes)
    XCTAssertEqual(restored.revision, document.revision)
    XCTAssertNotEqual(restored.textVersion, document.textVersion)
    XCTAssertTrue(stamp.accepts(document: restored, caretUTF16: document.text.utf16.count,
      epoch: 7, hasMarkedText: false))
    let identical = restored.text
    restored.text = identical
    XCTAssertTrue(stamp.accepts(document: restored, caretUTF16: document.text.utf16.count,
      epoch: 7, hasMarkedText: false))
    restored.text = "The bright."
    XCTAssertFalse(stamp.accepts(document: restored, caretUTF16: document.text.utf16.count,
      epoch: 7, hasMarkedText: false))
    XCTAssertFalse(stamp.accepts(document: document, caretUTF16: document.text.utf16.count,
      epoch: 8, hasMarkedText: false))
    XCTAssertFalse(stamp.accepts(document: document, caretUTF16: document.text.utf16.count,
      epoch: 7, hasMarkedText: true))
  }

  func testRawUTF8IdentityDoesNotNormalizeUnicodeLineEndingsOrNul() {
    let composed = "Café", decomposed = "Cafe\u{301}"
    XCTAssertEqual(composed, decomposed)
    XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
    for (first, second) in [(composed, decomposed), ("A\r\nB", "A\nB"), ("A\0B", "AB")] {
      let a = DocumentSnapshot(title: "Public fixture", text: first)
      let b = DocumentSnapshot(id: a.id, title: a.title, text: second)
      XCTAssertEqual(a.revision, Digest.sha256(Data(first.utf8)))
      XCTAssertEqual(b.revision, Digest.sha256(Data(second.utf8)))
      XCTAssertNotEqual(a.revision, b.revision)
      XCTAssertNotEqual(a, b)
    }
    XCTAssertEqual(DocumentSnapshot(title: "Empty", text: "").revision,
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  func testConcurrentReadsAndOwnedCopyMutationsPreserveSharedSnapshotIdentity() {
    let original = DocumentSnapshot(title: "Public fixture", text: String(repeating: "Cafe\u{301}\n", count: 128))
    let count = 64
    let expected = (0..<count).map { index in
      index.isMultiple(of: 3) ? Digest.sha256(original.text + String(index)) : Digest.sha256(original.text)
    }
    let observations = Observations(count: count)
    DispatchQueue.concurrentPerform(iterations: count) { index in
      var owned = original
      if index.isMultiple(of: 3) { owned.text += String(index) }
      else if index.isMultiple(of: 2) { owned.title = "Renamed \(index)" }
      let first = owned.revision
      var consistent = true
      for _ in 0..<8 { consistent = consistent && owned.revision == first }
      observations.record(consistent ? first : "inconsistent", at: index)
    }
    XCTAssertEqual(observations.snapshot(), expected.map(Optional.some))
    XCTAssertEqual(original.revision, Digest.sha256(original.text))
    XCTAssertEqual(original.title, "Public fixture")
  }
}
