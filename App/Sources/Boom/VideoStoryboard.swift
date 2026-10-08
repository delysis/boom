import AppKit
import AVFoundation
import BoomCore
import Foundation

struct VideoSoundSegment: Codable, Equatable, Sendable {
  let startMs: UInt64
  let endMs: UInt64
  let digest: String
}
struct VideoTimeline: Codable, Equatable, Sendable {
  let durationMs: UInt64
  let coveredMs: UInt64
  let frameTimesMs: [UInt64]
  var audio: [VideoSoundSegment]
  let detectedCuts: Int
  let omittedCuts: Int
  var soundtrackOmitted = false
}
struct VideoStoryboard: @unchecked Sendable {
  let frames: [NativeFrame]
  let timeline: VideoTimeline
  let sound: [[Float]]
  var coverage: String {
    "Storyboard: \(frames.count) frames, \(timeline.detectedCuts) detected cuts (\(timeline.omittedCuts) omitted); "
      + "visual gaps ≤5s, 4Hz probes; \(timeline.coveredMs)/\(timeline.durationMs)ms represented. "
      + (sound.isEmpty ? "No soundtrack track." : "Continuous timed 16kHz mono soundtrack, including silence.")
  }
}

/// Decoder and memory ownership live here; Rust owns selection and timeline policy.
/// Only tiny probes are retained during scanning. Selected full-size frames are
/// decoded in a second pass. Original bytes never leave the vault/memory loader.
enum NativeStoryboard {
  private struct Probe: Encodable { let atMs: UInt64; let rgb: [UInt8] }
  private struct AudioWindow: Decodable { let startMs: UInt64; let endMs: UInt64 }
  private struct ScanPlan: Decodable { let coveredMs: UInt64; let probeTimesMs: [UInt64]; let audioWindows: [AudioWindow] }
  private struct Selection: Decodable {
    let indices: [Int]; let coveredMs: UInt64; let detectedCuts: Int; let omittedCuts: Int
  }
  static func prepare(_ bytes: Data, flag: CancellationFlag) async throws -> VideoStoryboard {
    try flag.check()
    let media = try MemoryMedia(bytes: bytes)
    let duration = try await media.asset.load(.duration).seconds
    try ProductCore.mediaDuration(duration)
    let durationMs = UInt64(ceil(duration * 1000))
    let plan: ScanPlan = try ProductCore.call(["op": "storyboard_scan", "durationMs": durationMs])
    let coveredMs = plan.coveredMs
    let scan = AVAssetImageGenerator(asset: media.asset)
    scan.appliesPreferredTrackTransform = true
    scan.maximumSize = CGSize(width: 64, height: 64)
    scan.requestedTimeToleranceBefore = .zero; scan.requestedTimeToleranceAfter = .zero
    let scanCancellation = flag.onCancel { scan.cancelAllCGImageGeneration() }
    defer { flag.removeCancellationHandler(scanCancellation); scan.cancelAllCGImageGeneration() }
    var probes: [Probe] = []
    for requested in plan.probeTimesMs {
      try flag.check(); try Task.checkCancellation()
      let frame = try await withTaskCancellationHandler {
        try await scan.image(at: CMTime(value: Int64(requested), timescale: 1000))
      } onCancel: { scan.cancelAllCGImageGeneration() }
      guard frame.actualTime.seconds.isFinite, frame.actualTime.seconds >= 0, frame.actualTime.seconds * 1000 <= Double(coveredMs) else { throw BoomError.invalid("Video frame time is invalid.") }
      let at = UInt64((frame.actualTime.seconds * 1000).rounded())
      if at < coveredMs && (probes.last.map { $0.atMs < at } ?? true) {
        probes.append(Probe(atMs: at, rgb: try fingerprint(frame.image)))
      }
    }
    try flag.check()
    let selection: Selection = try ProductCore.call(["op": "select_storyboard", "durationMs": durationMs, "probes": ProductCore.object(probes)])
    let render = AVAssetImageGenerator(asset: media.asset)
    render.appliesPreferredTrackTransform = true; render.maximumSize = CGSize(width: 1200, height: 1200)
    render.requestedTimeToleranceBefore = .zero; render.requestedTimeToleranceAfter = .zero
    let renderCancellation = flag.onCancel { render.cancelAllCGImageGeneration() }
    defer { flag.removeCancellationHandler(renderCancellation); render.cancelAllCGImageGeneration() }
    var frames: [NativeFrame] = []
    for index in selection.indices {
      try flag.check(); try Task.checkCancellation()
      let at = probes[index].atMs
      let frame = try await withTaskCancellationHandler {
        try await render.image(at: CMTime(value: Int64(at), timescale: 1000))
      } onCancel: { render.cancelAllCGImageGeneration() }
      guard abs(frame.actualTime.seconds * 1000 - Double(at)) <= 1 else { throw BoomError.invalid("Selected video frame time changed.") }
      frames.append(NativeFrame(seconds: Double(at) / 1000, image: frame.image))
    }
    let times = selection.indices.map { probes[$0].atMs }
    var timeline = VideoTimeline(durationMs: durationMs, coveredMs: selection.coveredMs,
      frameTimesMs: times, audio: [], detectedCuts: selection.detectedCuts, omittedCuts: selection.omittedCuts)
    var sound: [[Float]] = []
    if !(try await media.asset.loadTracks(withMediaType: .audio)).isEmpty {
      let waveform = try await media.timedWaveform(endMs: selection.coveredMs, flag: flag)
      for window in plan.audioWindows {
        let start = window.startMs, end = window.endMs
        let samples = Array(waveform[Int(start) * 16..<Int(end) * 16])
        sound.append(samples)
        timeline.audio.append(VideoSoundSegment(startMs: start, endMs: end, digest: waveformDigest(samples)))
      }
    }
    try flag.check()
    return VideoStoryboard(frames: frames, timeline: timeline, sound: sound)
  }
  static func waveformDigest(_ samples: [Float]) -> String {
    var bytes = Data(); bytes.reserveCapacity(samples.count * 4)
    for sample in samples { var value = sample.bitPattern.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
    return Digest.sha256(bytes)
  }
  private static func fingerprint(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 32 * 18 * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 18, bitsPerComponent: 8,
        bytesPerRow: 32 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw BoomError.invalid("Video probe cannot be decoded.") }
      context.interpolationQuality = .low
      context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
    }
    return stride(from: 0, to: pixels.count, by: 4).flatMap { Array(pixels[$0..<$0 + 3]) }
  }
}

struct PreparedVideo: Sendable {
  let images: [Data]
  let timeline: VideoTimeline
  let sound: [[Float]]
  let coverage: String
  var byteCount: Int { images.reduce(0) { $0 + $1.count } + sound.reduce(0) { $0 + $1.count * 4 } }
}

/// Completed immutable derivations only. A cancelled consumer cannot poison
/// another consumer's cache entry or leave a partial shared task behind.
actor VideoPreparationCache {
  static let shared = VideoPreparationCache()
  private var entries: [(String, PreparedVideo)] = []
  func prepare(_ bytes: Data, digest: String, flag: CancellationFlag) async throws -> PreparedVideo {
    try flag.check(); try Task.checkCancellation()
    guard Digest.sha256(bytes) == digest else { throw BoomError.invalid("Video original changed.") }
    if let index = entries.firstIndex(where: { $0.0 == digest }) {
      let entry = entries.remove(at: index); entries.append(entry); return entry.1
    }
    let prepared = try await detachedWork {
      let storyboard = try await NativeStoryboard.prepare(bytes, flag: flag)
      let images = try storyboard.frames.map { frame -> Data in
        try flag.check()
        guard let png = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else { throw BoomError.invalid("Video frame cannot be decoded.") }
        return png
      }
      return PreparedVideo(images: images, timeline: storyboard.timeline, sound: storyboard.sound, coverage: storyboard.coverage)
    }
    try flag.check(); try Task.checkCancellation()
    entries.removeAll { $0.0 == digest }
    let budget = 24 * 1024 * 1024
    if prepared.byteCount <= budget {
      while !entries.isEmpty && (entries.count >= 4 || entries.reduce(prepared.byteCount, { $0 + $1.1.byteCount }) > budget) { entries.removeFirst() }
      entries.append((digest, prepared))
    }
    return prepared
  }
  func release() { entries.removeAll() }
}
