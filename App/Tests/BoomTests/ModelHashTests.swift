import CryptoKit
import Darwin
import XCTest
@testable import Boom

final class ModelHashTests: XCTestCase {
  func testInstallationLeaseExcludesOtherConsumersAndRejectsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-install-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ModelInstallLease(root: root, identity: "writing")
    XCTAssertThrowsError(try ModelInstallLease(root: root, identity: "writing"))
    first.release()
    let second = try ModelInstallLease(root: root, identity: "writing"); second.release()
    let outside = root.appendingPathComponent("outside")
    try Data("Retain this public fixture".utf8).write(to: outside)
    let link = root.appendingPathComponent(".bloom-install-linked.lock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try ModelInstallLease(root: root, identity: "linked"))
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Retain this public fixture")
    let fifo = root.appendingPathComponent(".bloom-install-pipe.lock")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let reader = open(fifo.path, O_RDWR | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0); defer { if reader >= 0 { close(reader) } }
    XCTAssertThrowsError(try ModelInstallLease(root: root, identity: "pipe"))
  }
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
