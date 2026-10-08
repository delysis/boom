import AVFoundation
import BoomCore
import Speech

/// The sole PCM-to-Speech boundary. A decoder's valid audio buffer is not
/// necessarily valid input for the installed recognizer. AnalyzerInput has a
/// nonthrowing initializer that traps on Float32 on macOS 27; negotiate the
/// DictationTranscriber's Int16 format and validate before entering it.
@available(macOS 26.0, *)
struct SpeechAudioInput {
  let element: AnalyzerInput
  let format: AVAudioFormat
  let frames: AVAudioFrameCount

  private init(_ buffer: AVAudioPCMBuffer) throws {
    guard buffer.format.commonFormat == .pcmFormatInt16, buffer.format.channelCount == 1,
      buffer.frameLength > 0, buffer.frameLength <= buffer.frameCapacity,
      buffer.audioBufferList.pointee.mNumberBuffers == 1,
      buffer.int16ChannelData?[0] != nil,
      buffer.audioBufferList.pointee.mBuffers.mData != nil,
      Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize) >= Int(buffer.frameLength) * 2 else {
      throw BoomError.invalid("The recording could not be prepared for on-device speech.")
    }
    format = buffer.format; frames = buffer.frameLength
    element = AnalyzerInput(buffer: buffer)
  }

  static func prepare(_ source: AVAudioPCMBuffer, for module: DictationTranscriber,
    flag: CancellationFlag) async throws -> SpeechAudioInput {
    try flag.check()
    try validate(source)
    let compatible = await module.availableCompatibleAudioFormats
    guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: source.format),
      compatible.contains(where: { $0.isEqual(target) }),
      target.commonFormat == .pcmFormatInt16, target.channelCount == 1,
      target.sampleRate.isFinite, target.sampleRate > 0, target.sampleRate <= 192_000 else {
      throw BoomError.unavailable("The on-device speech model has no usable audio format.")
    }
    try flag.check()
    let count = ceil(Double(source.frameLength) * target.sampleRate / source.format.sampleRate) + 64
    guard count > 0, count <= Double(UInt32.max),
      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)),
      let converter = AVAudioConverter(from: source.format, to: target) else {
      throw BoomError.invalid("The recording could not be converted for on-device speech.")
    }
    let input = OneShotAudioInput(source)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, state in input.take(state) }
    if let error { throw error }
    guard status != .error else { throw BoomError.invalid("The recording could not be converted for on-device speech.") }
    try flag.check()
    return try SpeechAudioInput(output)
  }

  private static func validate(_ buffer: AVAudioPCMBuffer) throws {
    let format = buffer.format
    guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 192_000,
      format.channelCount > 0, format.channelCount <= 8,
      buffer.frameLength > 0, buffer.frameLength <= buffer.frameCapacity,
      Double(buffer.frameLength) / format.sampleRate <= 60,
      [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32].contains(format.commonFormat) else {
      throw BoomError.invalid("The recording has no usable audio samples.")
    }
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let expectedBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    guard list.count == expectedBuffers, bytesPerFrame > 0,
      list.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= Int(buffer.frameLength) * bytesPerFrame }) else {
      throw BoomError.invalid("The recording has incomplete audio samples.")
    }
  }
}
