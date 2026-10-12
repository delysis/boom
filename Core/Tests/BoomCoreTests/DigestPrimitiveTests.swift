import Foundation
import XCTest

@testable import BoomCore

final class DigestPrimitiveTests: XCTestCase {
  func testStandardLongSHA256Vector() {
    let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    let expected = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    XCTAssertEqual(Digest.sha256(input), expected)
    XCTAssertEqual(Digest.sha256(Data(input.utf8)), expected)
  }

  func testPaddingAndBlockBoundaries() {
    let vectors: [(Int, String)] = [
      (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
      (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
      (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
      (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
      (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
      (119, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"),
      (120, "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c"),
      (127, "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a"),
      (128, "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e"),
      (129, "c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae"),
    ]
    for (count, expected) in vectors {
      let input = String(repeating: "a", count: count)
      XCTAssertEqual(Digest.sha256(input), expected, "String length \(count)")
      XCTAssertEqual(Digest.sha256(Data(input.utf8)), expected, "Data length \(count)")
    }
  }

  func testBinaryOctetsAndLeadingZeroHex() {
    XCTAssertEqual(Digest.sha256(Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    let bytes = Data((0..<256).map { UInt8($0) })
    XCTAssertEqual(Digest.sha256(bytes),
      "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
    XCTAssertEqual(Digest.sha256(Data([0x03])),
      "084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5")
  }

  func testDataSliceHashesOnlySelectedBytes() {
    let bytes = Data([0xff, 0x61, 0x62, 0x63, 0x00])
    let selected = bytes.dropFirst().dropLast()
    XCTAssertEqual(Digest.sha256(selected),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testCanonicallyEquivalentUnicodeKeepsDistinctByteIdentities() {
    let composed = "\u{00e9}"
    let decomposed = "e\u{301}"
    let composedDigest = "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c"
    let decomposedDigest = "bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6"
    XCTAssertEqual(composed, decomposed)
    XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
    XCTAssertEqual(Digest.sha256(composed), composedDigest)
    XCTAssertEqual(Digest.sha256(Data(composed.utf8)), composedDigest)
    XCTAssertEqual(Digest.sha256(decomposed), decomposedDigest)
    XCTAssertEqual(Digest.sha256(Data(decomposed.utf8)), decomposedDigest)
  }

  func testStringRetainsNULNonASCIIAndLineEndings() {
    let input = "A\0\u{00e9}\u{1f642}\r\n"
    let expected = "e024b3abb442963c331f162820c6d026520d9575990361ca4f960a7a2b053d61"
    XCTAssertEqual(Digest.sha256(input), expected)
    XCTAssertEqual(Digest.sha256(Data(input.utf8)), expected)
  }

  func testFoundationBridgedStringRetainsUTF8Identity() {
    let input = NSString(string: "d\u{00e9}j\u{00e0} e\u{301}\u{1f642}/\r\n") as String
    let expected = "ca4188c35b283c5a2aa22e510060095d128e1318a5fd05b1ae2d35bcf9ac245a"
    XCTAssertEqual(Digest.sha256(input), expected)
    XCTAssertEqual(Digest.sha256(Data(input.utf8)), expected)
  }

  func testCanonicalBytesAndIdentityRetainJSONEncoderOptions() throws {
    let value = ["nfd": "e\u{301}", "a": "https://example.test/a/b", "nfc": "\u{00e9}"]
    let expected = Data("{\"a\":\"https://example.test/a/b\",\"nfc\":\"\u{00e9}\",\"nfd\":\"e\u{301}\"}".utf8)
    XCTAssertEqual(try Digest.canonical(value), expected)
    XCTAssertEqual(try Digest.identity(value),
      "438fd4f61fca73c19e3799b3c16162e58177629c1992db66ad2476936098f356")
  }
}
