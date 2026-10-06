import CryptoKit
import XCTest
@testable import Boom

final class ModelHashTests: XCTestCase {
  func testStreamingDigestIncludesFullChunksAndFinalTailWithExactBounds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-model-hash-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("public-fixture.bin")
    var bytes = Data(repeating: 0x7a, count: 8_388_621)
    bytes[4_194_304] = 0x51; bytes[8_388_620] = 0x19
    try bytes.write(to: source)
    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let result = try ModelInstaller.hashFile(source, maxBytes: Int64(bytes.count))
    XCTAssertEqual(result.sha256, expected); XCTAssertEqual(result.bytes, Int64(bytes.count))
    XCTAssertThrowsError(try ModelInstaller.hashFile(source, maxBytes: Int64(bytes.count - 1)))
    let link = root.appendingPathComponent("link.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertThrowsError(try ModelInstaller.hashFile(link, maxBytes: Int64(bytes.count)))
  }
}
