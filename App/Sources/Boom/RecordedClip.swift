import AVFoundation
import BoomCore
import Foundation

/// Memory-only PCM packaging. Recording and recognition have distinct results;
/// an audio attachment never invokes Speech or consumes the composer draft.
enum VoiceCapture {
  case audio(Data)
  case transcript(String)
}

enum RecordedClip {
  static func wav(_ buffer: AVAudioPCMBuffer) throws -> Data {
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
      !buffer.format.isInterleaved, buffer.frameLength > 1_024,
      buffer.frameLength <= 960_000, buffer.frameLength <= buffer.frameCapacity,
      let samples = buffer.floatChannelData?[0] else {
      throw BoomError.invalid("The recording has no usable audio.")
    }
    var data = Data(capacity: 44 + Int(buffer.frameLength) * 2)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    let size = UInt32(buffer.frameLength) * 2
    data.append(contentsOf: "RIFF".utf8); append(size + 36)
    data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16))
    append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000))
    append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: "data".utf8); append(size)
    for i in 0..<Int(buffer.frameLength) {
      let value = samples[i]
      guard value.isFinite else { throw BoomError.invalid("The recording contains invalid samples.") }
      append(Int16((max(-1, min(1, value)) * 32_767).rounded()))
    }
    _ = try ProductCore.admitMedia(data)
    return data
  }
}
