import AVFoundation
import XCTest
@testable import Boom

final class AudioChunkTests: XCTestCase {
  func testConsecutiveChunksAndShortTailContainAudio() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "boom-audio-chunk-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("source.wav")
    let source = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    let frames: AVAudioFrameCount = 22_050
    do {
      let writer = try AVAudioFile(forWriting: url, settings: source.settings)
      for part in 0..<3 {
        let count: AVAudioFrameCount = part == 2 ? frames / 4 : frames
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) {
          buffer.floatChannelData![0][index] = sin(Float(index) * 0.02)
        }
        try writer.write(from: buffer)
      }
    }
    let reader = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
      interleaved: false)!
    for part in 0..<3 {
      let start = AVAudioFramePosition(part) * AVAudioFramePosition(frames)
      let count: AVAudioFrameCount = part == 2 ? frames / 4 : frames
      let output = try LocalAudioChunk.convert(reader, start: start, frames: count, to: target)
      XCTAssertGreaterThan(output.frameLength, 0, "segment \(part + 1) was empty")
      XCTAssertNotEqual(output.floatChannelData![0][Int(output.frameLength / 2)], 0)
    }
  }
}
