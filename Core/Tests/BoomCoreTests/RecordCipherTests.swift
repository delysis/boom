import XCTest
@testable import BoomCore

final class RecordCipherTests: XCTestCase {
  func testExactUnicodeRoundTripAndIdentityBinding() throws {
    let cipher = try RecordCipher(key: Data(repeating: 7, count: 32))
    let bytes = Data("Private case\r\n🪷 e\u{301}\0".utf8)
    let sealed = try cipher.seal(bytes, binding: "chat:one")
    XCTAssertEqual(sealed.count, bytes.count + RecordCipher.overhead)
    XCTAssertNotEqual(sealed, try cipher.seal(bytes, binding: "chat:one"))
    XCTAssertEqual(try cipher.open(sealed, binding: "chat:one", limit: bytes.count), bytes)
    XCTAssertThrowsError(try cipher.open(sealed, binding: "chat:two", limit: bytes.count))
    XCTAssertThrowsError(try cipher.open(sealed, binding: "chat:one", limit: bytes.count - 1))
  }
  func testCorruptionPlaintextAndWrongKeyNeverBecomeEmptyState() throws {
    let cipher = try RecordCipher(key: Data(repeating: 1, count: 32))
    let other = try RecordCipher(key: Data(repeating: 2, count: 32))
    let source = Data("A private consultation.".utf8)
    let sealed = try cipher.seal(source, binding: "workspace")
    XCTAssertThrowsError(try other.open(sealed, binding: "workspace", limit: 100))
    XCTAssertThrowsError(try cipher.open(source, binding: "workspace", limit: 100))
    for index in sealed.indices {
      var changed = sealed; changed[index] ^= 1
      XCTAssertThrowsError(try cipher.open(changed, binding: "workspace", limit: 100))
    }
    XCTAssertThrowsError(try RecordCipher(key: Data(repeating: 0, count: 31)))
  }
  func testEmptyRecordIsAuthenticatedAndEphemeralKeysAreIsolated() throws {
    let first = RecordCipher.ephemeral(), second = RecordCipher.ephemeral()
    let sealed = try first.seal(Data(), binding: "empty")
    XCTAssertEqual(try first.open(sealed, binding: "empty", limit: 0), Data())
    XCTAssertThrowsError(try second.open(sealed, binding: "empty", limit: 0))
  }
}
