import AppKit
import AVFoundation
import BoomCore
import XCTest
@testable import Boom

final class NativeDemoRecorderTests: XCTestCase {
  @MainActor func testRecordedNativeFramesProduceReadableVideoAndBoundHashes() async throws {
    let app = NSApplication.shared, previous = NSApplication.shared.activationPolicy()
    app.setActivationPolicy(.prohibited); defer { app.setActivationPolicy(previous) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-video-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 900))
    window.isReleasedWhenClosed = false; defer { window.close() }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    view.wantsLayer = true; view.layer?.backgroundColor = NSColor.systemBlue.cgColor
    window.contentView = view
    let recorder = try NativeDemoRecorder(view: view, evidence: root)
    defer { recorder.cancel() }
    try await recorder.checkpoint("First public native state")
    view.layer?.backgroundColor = NSColor.systemRed.cgColor
    try await recorder.checkpoint("Second public native state")
    try await recorder.finish()
    let movie = root.appendingPathComponent("demonstration.mp4")
    let asset = AVURLAsset(url: movie)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
    let dimensions = try await XCTUnwrap(tracks.first).load(.naturalSize)
    XCTAssertEqual(dimensions, CGSize(width: 1440, height: 900))
    let duration = try await asset.load(.duration)
    XCTAssertGreaterThan(duration.seconds, 1)
    let generated = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
    let image = generated.image
    XCTAssertEqual(image.width, 1440); XCTAssertEqual(image.height, 900)
    let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("demonstration.json"))) as? [String: Any])
    XCTAssertEqual(metadata["movie_sha256"] as? String, try ModelInstaller.hashFile(movie, maxBytes: 268_435_456).sha256)
    let ledger = try Data(contentsOf: root.appendingPathComponent("demonstration-frames.json"))
    XCTAssertEqual(metadata["frame_ledger_sha256"] as? String, Digest.sha256(ledger))
    XCTAssertEqual(metadata["desktop_capture"] as? Bool, false)
    XCTAssertEqual(metadata["physical_interaction_qualified"] as? Bool, false)
    let frames = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger) as? [[String: Any]])
    XCTAssertTrue(frames.contains { $0["phase"] as? String == "First public native state" })
    XCTAssertTrue(frames.contains { $0["phase"] as? String == "Second public native state" })
    let times = try frames.map { try XCTUnwrap($0["seconds"] as? Double) }
    XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    XCTAssertThrowsError(try NativeDemoRecorder(view: view, evidence: root))
  }
}
