import AVFoundation
import BoomCore
import XCTest
@testable import Boom

final class AudioChunkTests: XCTestCase {
  func testMemoryDecoderConvertsConsecutiveSegmentsAndShortTail() async throws {
    // Authored audio fixture lives entirely in memory, including its WAV header.
    let rate: UInt32 = 22_050, frames = Int(22_050 * 9 / 4)
    var pcm = Data(capacity: frames * 4)
    for index in 0..<frames {
      var bits = sin(Float(index) * 0.02).bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
    }
    var wav = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    append(UInt32(pcm.count + 36)); wav.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
    append(rate); append(rate * 4); append(UInt16(4)); append(UInt16(32))
    wav.append(Data("data".utf8)); append(UInt32(pcm.count)); wav.append(pcm)
    let owner = try MemoryMedia(bytes: wav)
    let reader = try await owner.audioReader()
    for part in 0..<3 {
      let output = try XCTUnwrap(reader.next(flag: CancellationFlag(), seconds: 1))
      XCTAssertEqual(output.format.sampleRate, 16_000)
      XCTAssertGreaterThan(output.frameLength, 0, "segment \(part + 1) was empty")
      XCTAssertTrue((0..<Int(output.frameLength)).contains { abs(output.floatChannelData![0][$0]) > 0.01 })
      if part < 2 { XCTAssertEqual(output.frameLength, 16_000) }
      else { XCTAssertLessThan(output.frameLength, 16_000) }
    }
    XCTAssertNil(try reader.next(flag: CancellationFlag(), seconds: 1))
  }
}
