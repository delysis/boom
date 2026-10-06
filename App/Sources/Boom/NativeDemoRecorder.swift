import AppKit
import AVFoundation
import BoomCore
import Foundation

/// Opt-in public-fixture recording. Never captures a desktop or shown window.
@MainActor final class NativeDemoRecorder {
  private struct Frame: Codable {
    let index: Int
    let seconds: Double
    let phase: String
  }
  private let view: NSView
  private let evidence: URL
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let clock = ContinuousClock()
  private let started: ContinuousClock.Instant
  private var frames: [Frame] = []
  private var ended = false
  private let width = 1440, height = 900

  init(view: NSView, evidence: URL) throws {
    guard NSApp.activationPolicy() == .prohibited, let window = view.window,
      !window.isVisible, !window.isRestorable, window.restorationClass == nil,
      view.bounds.width == 1440, view.bounds.height == 900 else {
      throw BoomError.invalid("Record only an offscreen public diagnostic view.")
    }
    self.view = view; self.evidence = evidence; started = clock.now
    let url = evidence.appendingPathComponent("demonstration.mp4")
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw BoomError.invalid("Refuse to replace a demonstration recording.")
    }
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
    guard writer.canAdd(input) else { throw BoomError.unavailable("Native video encoding is unavailable.") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? BoomError.unavailable("Cannot start native video encoding.") }
    writer.startSession(atSourceTime: .zero)
  }

  func frame(_ phase: String) throws {
    let seconds = started.duration(to: clock.now).timeInterval
    guard !ended, seconds <= 300, frames.count < 1800,
      NSApp.activationPolicy() == .prohibited, view.window?.isVisible == false,
      view.window?.isRestorable == false, view.window?.restorationClass == nil else {
      throw BoomError.invalid("The public recording exceeded its scope or deadline.")
    }
    if let last = frames.last, last.phase == phase, seconds - last.seconds < 0.2 { return }
    guard input.isReadyForMoreMediaData else {
      throw writer.error ?? BoomError.unavailable("The native recorder could not keep up; retain the incomplete recording.")
    }
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw BoomError.unavailable("The native demonstration view could not be captured.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.cgImage, let pool = adaptor.pixelBufferPool else {
      throw BoomError.unavailable("The native recorder has no image or pixel-buffer pool.")
    }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
      throw BoomError.unavailable("The native recorder could not allocate a frame.")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
      throw BoomError.unavailable("The native recorder could not draw a frame.")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    guard adaptor.append(buffer, withPresentationTime: time) else {
      throw writer.error ?? BoomError.unavailable("The native recorder refused a frame.")
    }
    frames.append(Frame(index: frames.count, seconds: seconds, phase: phase))
  }

  func checkpoint(_ phase: String) async throws {
    // Let SwiftUI publish the real state; preserve the hold in actual elapsed time.
    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(200))
      try frame(phase)
    }
  }

  func finish() async throws {
    guard !ended, frames.count >= 2 else { throw BoomError.invalid("The demonstration has no recorded journey.") }
    guard view.window?.isRestorable == false, view.window?.restorationClass == nil else {
      throw BoomError.invalid("The diagnostic window enabled system restoration; recording retained.")
    }
    try JSONEncoder().encode(frames).write(to: evidence.appendingPathComponent("demonstration-frames.json"), options: .atomic)
    ended = true; input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw writer.error ?? BoomError.unavailable("The native demonstration recording is incomplete.")
    }
    let frames = frames, evidence = evidence
    try await detachedWork {
      let encoded = try JSONEncoder().encode(frames)
      try encoded.write(to: evidence.appendingPathComponent("demonstration-frames.json"), options: .atomic)
      let movie = try ModelInstaller.hashFile(evidence.appendingPathComponent("demonstration.mp4"), maxBytes: 268_435_456)
      let receipt: [String: Any] = ["scope": "offscreen production native view, public controller-driven fixture",
        "desktop_capture": false, "physical_interaction_qualified": false, "keychain_dialogs_qualified": false,
        "appkit_window_restoration_disabled": true,
        "appkit_snapshot_policy": "disabled_in_workspace_window_factory",
        "frames": frames.count, "width": 1440, "height": 900,
        "first_frame_seconds": frames[0].seconds, "last_frame_seconds": frames[frames.count - 1].seconds,
        "movie_sha256": movie.sha256, "movie_bytes": movie.bytes,
        "frame_ledger_sha256": Digest.sha256(encoded), "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as Any? ?? NSNull()]
      try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        .write(to: evidence.appendingPathComponent("demonstration.json"), options: .atomic)
    }
  }

  func cancel() {
    guard !ended else { return }
    ended = true
    do {
      try JSONEncoder().encode(frames).write(to: evidence.appendingPathComponent("demonstration-frames.json"), options: .atomic)
      let movie = evidence.appendingPathComponent("demonstration.mp4")
      if FileManager.default.fileExists(atPath: movie.path) {
        try FileManager.default.copyItem(at: movie, to: evidence.appendingPathComponent("demonstration-incomplete.mp4"))
      }
    } catch { fputs("Could not retain incomplete native recording: \(error.localizedDescription)\n", stderr) }
    writer.cancelWriting()
  }
}
