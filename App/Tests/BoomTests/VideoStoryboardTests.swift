import AppKit
import AVFoundation
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class VideoStoryboardTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Storyboard")))
  }
  func testShotsAndContinuousSoundKeepOriginalTimingAndIdentities() async throws {
    let bytes = try fixture("scene-speech.mp4")
    let storyboard = try await NativeStoryboard.prepare(bytes, flag: CancellationFlag())
    XCTAssertEqual(storyboard.timeline.durationMs, 8000)
    XCTAssertEqual(storyboard.timeline.detectedCuts, 2)
    XCTAssertEqual(storyboard.frames.count, 3, "Redundant periodic frames must not duplicate a captured shot.")
    XCTAssertTrue(storyboard.timeline.frameTimesMs.contains(2750))
    XCTAssertTrue(storyboard.timeline.frameTimesMs.contains(5500))
    XCTAssertEqual(storyboard.sound.count, 1)
    let original = try await MemoryMedia(bytes: bytes).timedWaveform(endMs: 8000, flag: CancellationFlag())
    XCTAssertEqual(storyboard.sound.flatMap { $0 }, original)
    XCTAssertEqual(original.count, 128_000)
    XCTAssertLessThan(original.prefix(14_000).map { abs($0) }.max() ?? 1, 0.001)
    XCTAssertGreaterThan(original.dropFirst(16_000).map { abs($0) }.max() ?? 0, 0.1)
    for (segment, samples) in zip(storyboard.timeline.audio, storyboard.sound) {
      XCTAssertEqual(samples.count, Int(segment.endMs - segment.startMs) * 16)
      XCTAssertEqual(segment.digest, NativeStoryboard.waveformDigest(samples))
      XCTAssertLessThanOrEqual(segment.endMs - segment.startMs, 30_000)
    }
    let colors = try storyboard.frames.map { frame in
      try XCTUnwrap(NSBitmapImageRep(cgImage: frame.image).colorAt(x: frame.image.width / 2, y: frame.image.height / 2)?.usingColorSpace(.deviceRGB))
    }
    XCTAssertGreaterThan(colors[0].redComponent, 0.8)
    XCTAssertGreaterThan(colors[storyboard.timeline.frameTimesMs.firstIndex(of: 2750)!].blueComponent, 0.8)
    XCTAssertGreaterThan(colors[storyboard.timeline.frameTimesMs.firstIndex(of: 5500)!].greenComponent, 0.35)
  }
  func testLongAndSparseSilentVideosRemainBoundedAndDiscloseOmissions() async throws {
    for name in ["static-long.mp4", "static-sparse.mp4"] {
      let storyboard = try await NativeStoryboard.prepare(fixture(name), flag: CancellationFlag())
      XCTAssertTrue(storyboard.sound.isEmpty); XCTAssertTrue(storyboard.timeline.audio.isEmpty)
      XCTAssertLessThanOrEqual(storyboard.frames.count, 16)
      XCTAssertEqual(storyboard.timeline.detectedCuts, 0)
      let times = storyboard.timeline.frameTimesMs
      XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $1 - $0 <= 5000 })
      XCTAssertLessThanOrEqual(storyboard.timeline.coveredMs - times.last!, 5000)
      if name == "static-long.mp4" {
        XCTAssertEqual(storyboard.timeline.coveredMs, 60_000); XCTAssertEqual(storyboard.timeline.durationMs, 70_000)
        let reference = WritingMediaReference(id: UUID(), name: name, rootDigest: Digest.sha256(try fixture(name)), kind: "video",
          frameDigests: storyboard.frames.map { Digest.sha256(Data(NSBitmapImageRep(cgImage: $0.image).tiffRepresentation!)) }, video: storyboard.timeline)
        let prompt = try RawWritingInput.compiled("[Attachment: video](boom-attachment:\(reference.id))", media: [reference])
        XCTAssertTrue(prompt.prompt.contains("after 60.000s omitted"))
      }
    }
  }
  func testOffsetAudioTrackDoesNotMoveSpeechToTheStart() async throws {
    let bytes = try fixture("offset-audio.mp4")
    let owner = try MemoryMedia(bytes: bytes)
    let tracks = try await owner.asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(tracks.first)
    let segments = try await track.load(.segments)
    XCTAssertGreaterThan(segments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds ?? 0, 0.9)
    let samples = try await owner.timedWaveform(endMs: 8000, flag: CancellationFlag())
    XCTAssertLessThan(samples.prefix(14_000).map { abs($0) }.max() ?? 1, 0.001)
    XCTAssertGreaterThan(samples.dropFirst(16_000).map { abs($0) }.max() ?? 0, 0.1)
    XCTAssertLessThan(samples.suffix(16_000).map { abs($0) }.max() ?? 1, 0.001)
  }
  func testCancelledProbeDoesNotReturnPartialStoryboard() async throws {
    let flag = CancellationFlag(); flag.cancel()
    do { _ = try await NativeStoryboard.prepare(fixture("scene-speech.mp4"), flag: flag); XCTFail("Cancelled work returned media.") }
    catch { XCTAssertTrue(flag.isCancelled) }
  }
  func testCachedVideoStillChecksTheOriginalIdentity() async throws {
    let bytes = try fixture("scene-speech.mp4"), cache = VideoPreparationCache()
    _ = try await cache.prepare(bytes, digest: Digest.sha256(bytes), flag: CancellationFlag())
    do { _ = try await cache.prepare(Data([0]), digest: Digest.sha256(bytes), flag: CancellationFlag()); XCTFail("Cached frame hashes bypassed original validation.") }
    catch { }
  }
  func testCancellationDuringScanningJoinsWithoutPublishingPartialData() async throws {
    let bytes = try fixture("static-long.mp4"), flag = CancellationFlag()
    let task = Task { try await VideoPreparationCache.shared.prepare(bytes, digest: Digest.sha256(bytes), flag: flag) }
    try await Task.sleep(for: .milliseconds(10))
    let stopped = Date(); flag.cancel()
    do { _ = try await task.value; XCTFail("Cancelled scan returned a prepared video.") }
    catch { XCTAssertTrue(flag.isCancelled) }
    XCTAssertLessThan(Date().timeIntervalSince(stopped), 2)
  }
  @MainActor func testSharedDocumentAndChatPreparationCaptureSameEncryptedVideoTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-storyboard-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root,
      testKey: SymmetricKey(data: Data(repeating: 0x71, count: 32))), loadModels: false)
    model.state.autocomplete = false
    if model.selectedChat == nil { try model.newChat() }
    let bytes = try fixture("scene-speech.mp4")
    model.attachToCurrentChat([.bytes(name: "scene-speech.mp4", data: bytes)])
    for _ in 0..<1000 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let record = try XCTUnwrap(model.state.attachments.last)
    let writing = try await model.writingMedia(in: "👩🏽‍💻\n[Attachment: video](boom-attachment:\(record.id))\nContinue:", flag: CancellationFlag())
    let chat = try await model.consultationMedia([record], rawAudio: true, flag: CancellationFlag())
    XCTAssertTrue(chat.images.isEmpty); XCTAssertEqual(chat.media.map(\.reference), writing.map(\.reference))
    XCTAssertEqual(chat.media.first?.audioSegments, writing.first?.audioSegments)
    let prompt = try RawWritingInput.compiled("[Attachment: video](boom-attachment:\(record.id))", media: writing.map(\.reference))
    XCTAssertTrue(prompt.prompt.contains("[Video 00:02.750]")); XCTAssertTrue(prompt.prompt.contains("[Sound 0.000–8.000s]"))
    XCTAssertEqual(prompt.prompt.components(separatedBy: "<|audio|>").count - 1, writing[0].audioSegments.count)
    try await model.flush()
    XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), bytes)
    let reopened = try await model.store.load().get().0
    XCTAssertEqual(reopened.attachments.first { $0.id == record.id }?.rootDigest, Digest.sha256(bytes))
    try await model.shutdown()
  }
}
