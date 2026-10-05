import AppKit
import AVFoundation
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class MediaPrivacyTests: XCTestCase {
  private func atom(_ kind: String, _ payload: Data) -> Data {
    var size = UInt32(payload.count + 8).bigEndian
    return withUnsafeBytes(of: &size) { Data($0) } + Data(kind.utf8) + payload
  }
  private func referenceMovie() -> Data {
    // One local track does not authorize a reference movie beside that track.
    let local = atom("dref", Data([0, 0, 0, 0, 0, 0, 0, 1]) + atom("url ", Data([0, 0, 0, 1])))
    let track = atom("trak", atom("mdia", atom("minf", atom("dinf", local))))
    let remote = atom("rmra", atom("rmda", atom("rdrf", Data("https://example.invalid/video.mov\0".utf8))))
    return atom("ftyp", Data("isom\0\0\0\0".utf8)) + atom("moov", track + remote)
  }
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
  func testBothNativeDecoderEntrypointsRejectReferencesBeforeCreatingPlayers() {
    for bytes in [referenceMovie(), Data("#EXTM3U\nhttps://example.invalid/video".utf8)] {
      XCTAssertThrowsError(try MemoryMedia(bytes: bytes)) { error in
        XCTAssertTrue(error.localizedDescription.contains("forbidden"), "\(error)")
      }
      XCTAssertThrowsError(try MemoryMedia.audioPlayer(bytes: bytes)) { error in
        XCTAssertTrue(error.localizedDescription.contains("forbidden"), "\(error)")
      }
    }
  }
  @MainActor func testInvalidSpeechAttachmentIsRejectedBeforeAssetSetupOrAuthorization() async {
    do {
      _ = try await VoiceInput().transcribeAttachment(data: referenceMovie(), flag: CancellationFlag()) { _, _ in
        XCTFail("Rejected media must not reach recognition progress.")
      }
      XCTFail("Reference movie reached speech.")
    } catch { XCTAssertTrue(error.localizedDescription.contains("forbidden"), "\(error)") }
  }
  @MainActor func testCancelledValidAudioCannotReachSpeechSetupOrRecognition() async throws {
    let flag = CancellationFlag(); flag.cancel()
    do {
      _ = try await VoiceInput().transcribeAttachment(data: fixture("local-audio.m4a"), flag: flag) { _, _ in
        XCTFail("Cancelled audio reached recognition progress.")
      }
      XCTFail("Cancelled audio reached speech.")
    } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
  }
  @MainActor func testRejectedImportedMediaRetainsEncryptedOriginalAndFailureCoverage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-media-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let bytes = referenceMovie()
    model.attachToCurrentChat([.bytes(name: "Reference.m4a", data: bytes)])
    for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.isBusy)
    let record = try XCTUnwrap(model.state.attachments.first)
    XCTAssertTrue(record.text.isEmpty)
    XCTAssertTrue(record.coverage.contains("forbidden"), record.coverage)
    XCTAssertEqual(record.rootDigest, Digest.sha256(bytes))
    XCTAssertEqual(try store.vault.get(.attachment, id: record.id), bytes)
    let encrypted = try Data(contentsOf: store.vault.recordURL(.attachment, record.id))
    XCTAssertNil(encrypted.range(of: Data("https://example.invalid".utf8)))
    XCTAssertTrue(model.pendingAttachments.contains(record.id))
    try await model.shutdown()
  }
  func testRealMP4FramesAreDecodedAndSeekedEntirelyFromMemory() async throws {
    let owner = try MemoryMedia(bytes: fixture("local-video.mp4"))
    XCTAssertEqual(owner.container, .mp4)
    let duration = try await owner.asset.load(.duration).seconds
    XCTAssertEqual(duration, 1, accuracy: 0.05)
    let generator = AVAssetImageGenerator(asset: owner.asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    for (time, red) in [(0.0, true), (0.75, false)] {
      let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
      XCTAssertEqual(frame.actualTime.seconds, time, accuracy: 0.01)
      XCTAssertEqual(frame.image.width, 64); XCTAssertEqual(frame.image.height, 48)
      let bitmap = NSBitmapImageRep(cgImage: frame.image)
      let color = try XCTUnwrap(bitmap.colorAt(x: 32, y: 24)?.usingColorSpace(.deviceRGB))
      XCTAssertLessThan(color.greenComponent, 0.2)
      XCTAssertGreaterThan(red ? color.redComponent : color.blueComponent, 0.8)
      XCTAssertLessThan(red ? color.blueComponent : color.redComponent, 0.2)
    }
    withExtendedLifetime(owner) {}
  }
  func testRealM4AAudioPlayerAndPCMReaderUseAdmittedMemoryBytes() async throws {
    let bytes = try fixture("local-audio.m4a")
    let player = try MemoryMedia.audioPlayer(bytes: bytes)
    XCTAssertTrue(player.prepareToPlay()) // No sound is played.
    XCTAssertEqual(player.duration, 1.25, accuracy: 0.1)
    let owner = try MemoryMedia(bytes: bytes)
    let reader = try await owner.audioReader()
    var samples: [Float] = []
    while let buffer = try reader.next(flag: CancellationFlag(), seconds: 1) {
      XCTAssertEqual(buffer.format.sampleRate, 16_000)
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    XCTAssertTrue((18_000...22_000).contains(samples.count))
    XCTAssertTrue(samples.allSatisfy(\.isFinite))
    XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.05)
    let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
    let frequency = Double(crossings) / (Double(samples.count) / 16_000)
    XCTAssertEqual(frequency, 523, accuracy: 20)
    player.stop()
  }
}
