import AVFoundation
import BoomCore
import Speech
import XCTest
@testable import Boom

final class SpeechAudioInputTests: XCTestCase {
  @available(macOS 26.0, *)
  private func module() async throws -> DictationTranscriber {
    let locales = await DictationTranscriber.supportedLocales
    guard let locale = locales.first(where: { $0.identifier == Locale.current.identifier })
      ?? locales.first(where: { $0.language.languageCode == Locale.current.language.languageCode }) else {
      throw XCTSkip("The current language has no dictation module.")
    }
    let module = DictationTranscriber(locale: locale, preset: .shortDictation)
    // Format admission does not run recognition or require an installed asset.
    // A signed-bundle speech check separately qualifies actual transcription.
    let formats = await module.availableCompatibleAudioFormats
    XCTAssertFalse(formats.isEmpty, "The real module must advertise its input contract.")
    return module
  }
  private func tone(rate: Double, channels: AVAudioChannelCount, interleaved: Bool) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
    buffer.frameLength = buffer.frameCapacity
    let data = try XCTUnwrap(buffer.floatChannelData)
    for i in 0..<Int(buffer.frameLength) {
      for channel in 0..<Int(channels) {
        let value = Float(sin(Double(i) * 2 * .pi * 440 / rate)) * 0.2
        if interleaved { data[0][i * Int(channels) + channel] = value }
        else { data[channel][i] = value }
      }
    }
    return buffer
  }
  func testMicrophoneAndStereoBuffersCrossTheActualSpeechInitializer() async throws {
    guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26.") }
    let module = try await module()
    for (rate, channels, interleaved) in [(16_000.0, UInt32(1), false), (48_000, 2, false), (44_100, 2, true)] {
      let buffer = try tone(rate: rate, channels: channels, interleaved: interleaved)
      let prepared = try await SpeechAudioInput.prepare(buffer, for: module, flag: CancellationFlag())
      XCTAssertEqual(prepared.format.commonFormat, .pcmFormatInt16)
      XCTAssertEqual(prepared.format.channelCount, 1)
      let compatible = await module.availableCompatibleAudioFormats
      XCTAssertTrue(compatible.contains { $0.isEqual(prepared.format) })
      XCTAssertEqual(Double(prepared.frames) / prepared.format.sampleRate, 1, accuracy: 0.01)
      // This is the actual framework object, whose initializer used to trap.
      let retained = prepared.element.buffer
      XCTAssertEqual(retained.frameLength, prepared.frames)
      let samples = try XCTUnwrap(retained.int16ChannelData?[0])
      XCTAssertTrue((0..<Int(retained.frameLength)).contains { abs(Int(samples[$0])) > 1_000 })
    }
  }
  func testDecodedAttachmentSegmentsCrossTheSameSpeechBoundary() async throws {
    guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26.") }
    let module = try await module()
    let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "local-audio", withExtension: "m4a", subdirectory: "Fixtures")))
    let reader = try await MemoryMedia(bytes: bytes).audioReader()
    var count = 0
    while let buffer = try reader.next(flag: CancellationFlag(), seconds: 1) {
      let prepared = try await SpeechAudioInput.prepare(buffer, for: module, flag: CancellationFlag())
      XCTAssertGreaterThan(prepared.frames, 0)
      XCTAssertEqual(prepared.format.commonFormat, .pcmFormatInt16)
      count += 1
    }
    XCTAssertGreaterThan(count, 1)
  }
  func testEmptyOversizedAndCancelledAudioNeverReachesSpeechInitializer() async throws {
    guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26.") }
    let module = try await module()
    let empty = try tone(rate: 16_000, channels: 1, interleaved: false)
    empty.frameLength = 0
    do { _ = try await SpeechAudioInput.prepare(empty, for: module, flag: CancellationFlag()); XCTFail("Empty buffer accepted.") }
    catch is BoomError {}
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let oversized = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 61))
    oversized.frameLength = oversized.frameCapacity
    do { _ = try await SpeechAudioInput.prepare(oversized, for: module, flag: CancellationFlag()); XCTFail("Overlong buffer accepted.") }
    catch is BoomError {}
    let flag = CancellationFlag(); flag.cancel()
    do { _ = try await SpeechAudioInput.prepare(try tone(rate: 16_000, channels: 1, interleaved: false), for: module, flag: flag); XCTFail("Cancelled buffer accepted.") }
    catch is CancellationError {}
  }
}
