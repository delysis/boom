import Darwin
import XCTest
@testable import Boom

final class RegularFileTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-opened-file-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func testOpenedBytesKeepTheirIdentityWhenTheGrantedPathIsReplaced() throws {
    let root = try fixture(), path = root.appendingPathComponent("grant"), old = root.appendingPathComponent("captured")
    let other = root.appendingPathComponent("outside")
    let original = Data("Original granted bytes 🦋".utf8)
    try original.write(to: path); try Data(repeating: 42, count: 256).write(to: other)
    let capture = try RegularFile(path, limit: Int64(original.count), allowEmpty: false)
    try FileManager.default.moveItem(at: path, to: old)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: other)
    XCTAssertEqual(try capture.data(), original)
    XCTAssertThrowsError(try AttachmentProcessor.readGranted(path))
    XCTAssertThrowsError(try ModelInstaller.hashFile(path, maxBytes: 256))
  }
  func testRegularTypeAndExactBoundAreCheckedOnTheOpenedDescriptor() throws {
    let root = try fixture(), path = root.appendingPathComponent("data")
    let bytes = Data(repeating: 31, count: 1_048_579)
    try bytes.write(to: path)
    XCTAssertEqual(try RegularFile(path, limit: Int64(bytes.count)).data(), bytes)
    XCTAssertThrowsError(try RegularFile(path, limit: Int64(bytes.count - 1)))
    XCTAssertThrowsError(try RegularFile(root, limit: 16))
    let fifo = root.appendingPathComponent("pipe")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    XCTAssertThrowsError(try RegularFile(fifo, limit: 16), "Nonblocking open must refuse a pipe without waiting for a writer")
    try Data().write(to: path)
    XCTAssertEqual(try RegularFile(path, limit: 0).data(), Data())
    XCTAssertThrowsError(try RegularFile(path, limit: 0, allowEmpty: false))
  }
  func testGrowthAndTruncationCannotBecomeSuccessfulCaptures() throws {
    let root = try fixture(), path = root.appendingPathComponent("changing")
    try Data(repeating: 1, count: 8).write(to: path)
    let growing = try RegularFile(path, limit: 8)
    let writer = try FileHandle(forWritingTo: path)
    try writer.seekToEnd(); try writer.write(contentsOf: Data([2])); try writer.close()
    XCTAssertThrowsError(try growing.data())
    let shrinking = try RegularFile(path, limit: 9)
    let truncator = try FileHandle(forWritingTo: path)
    try truncator.truncate(atOffset: 3); try truncator.close()
    XCTAssertThrowsError(try shrinking.data())
  }
}
