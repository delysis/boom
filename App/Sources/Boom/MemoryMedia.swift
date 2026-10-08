import AVFoundation
import CAttachment
import BoomCore
import Foundation
import UniformTypeIdentifiers

/// AVFoundation reads a private custom URL entirely through this delegate.
/// The delegate is retained by its owner; it never writes bytes to a file.
final class MemoryMedia: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  let asset: AVURLAsset
  let container: MediaContainer
  private let bytes: Data
  private let contentType: String
  private let queue = DispatchQueue(label: "com.delysis.Bloom.media")
  init(bytes: Data) throws {
    let original = try ProductCore.admitMedia(bytes)
    let admitted = original == .caf ? try Self.cafWave(bytes) : bytes
    container = original == .caf ? .wav : original
    self.bytes = admitted
    contentType = UTType(filenameExtension: container.rawValue)?.identifier ?? UTType.data.identifier
    asset = AVURLAsset(url: URL(string: "bloom-media://local/\(UUID().uuidString)")!)
    super.init()
    asset.resourceLoader.setDelegate(self, queue: queue)
  }
  /// Decoder admission is not playback readiness. Both media controls use the
  /// actual AVPlayer consumer, retain this memory owner, and expose playback
  /// only after the item has negotiated its codec and reached readyToPlay.
  @MainActor func readyPlayer(flag: CancellationFlag) async throws -> AVPlayer {
    try flag.check(); try Task.checkCancellation()
    let item = AVPlayerItem(asset: asset), player = AVPlayer(playerItem: item)
    for _ in 0..<500 where item.status == .unknown {
      try flag.check(); try await Task.sleep(for: .milliseconds(10))
    }
    try flag.check(); try Task.checkCancellation()
    guard item.status == .readyToPlay else {
      player.pause()
      throw item.error ?? BoomError.unavailable("This media cannot be played locally.")
    }
    return player
  }
  private static func cafWave(_ bytes: Data) throws -> Data {
    let buffer = bytes.withUnsafeBytes { pointer in bloom_caf_wave(pointer.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
    defer { boom_attachment_free(buffer) }
    guard let pointer = buffer.data, buffer.length >= 44, buffer.length <= 67_108_910 else { throw BoomError.invalid("CAF cannot be decoded locally.") }
    let wave = Data(bytes: pointer, count: buffer.length)
    guard wave.starts(with: Data("RIFF".utf8)), try ProductCore.admitMedia(wave) == .wav else { throw BoomError.invalid("CAF cannot be decoded locally.") }
    return wave
  }
  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
    if let info = request.contentInformationRequest {
      info.contentType = contentType
      info.contentLength = Int64(bytes.count)
      info.isByteRangeAccessSupported = true
    }
    if let read = request.dataRequest {
      let offset = max(read.requestedOffset, read.currentOffset)
      guard offset >= 0, offset <= Int64(bytes.count), read.requestedLength >= 0 else {
        request.finishLoading(with: BoomError.invalid("Invalid media byte range.")); return true
      }
      let start = Int(offset)
      let requestedEnd = read.requestsAllDataToEndOfResource ? bytes.count
        : min(bytes.count, Int(clamping: read.requestedOffset) + read.requestedLength)
      guard requestedEnd >= start else {
        request.finishLoading(with: BoomError.invalid("Media byte range ended before its offset.")); return true
      }
      read.respond(with: bytes.subdata(in: start..<requestedEnd))
    }
    request.finishLoading()
    return true
  }

  func audioReader(automaticAudio: Bool = false) async throws -> MemoryAudioReader {
    let duration = try await asset.load(.duration).seconds
    try ProductCore.mediaDuration(duration, automaticAudio: automaticAudio)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw BoomError.invalid("Audio has no local audio track.")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw BoomError.invalid("Unsupported audio track.") }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? BoomError.invalid("Audio decoder did not start.") }
    return MemoryAudioReader(owner: self, reader: reader, output: output, duration: duration)
  }

  /// Video sound is placed by presentation time, not concatenated packet order.
  /// Track offsets and silent gaps remain silence at their original positions.
  func timedWaveform(endMs: UInt64, flag: CancellationFlag) async throws -> [Float] {
    guard endMs > 0, endMs <= 60_000,
      let track = try await asset.loadTracks(withMediaType: .audio).first else { throw BoomError.invalid("Invalid video soundtrack range.") }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: Int64(endMs), timescale: 1000))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw BoomError.invalid("Video soundtrack cannot be decoded.") }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? BoomError.invalid("Video soundtrack did not start.") }
    // AVAssetReader is not Sendable. Keep reads and cancellation on this
    // consumer; the flag is checked at each memory-backed PCM packet boundary.
    defer { reader.cancelReading(); withExtendedLifetime(self) {} }
    var samples = [Float](repeating: 0, count: Int(endMs) * 16), lastStart = Int.min, decoded = false
    while let buffer = output.copyNextSampleBuffer() {
      try flag.check(); try Task.checkCancellation()
      let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
      guard time.isFinite, abs(time) < 7201, let block = CMSampleBufferGetDataBuffer(buffer) else { throw BoomError.invalid("Video soundtrack timestamp is invalid.") }
      let start = Int((time * 16_000).rounded()), length = CMBlockBufferGetDataLength(block)
      guard start >= lastStart, length > 0, length % 4 == 0, length <= 4_194_304 else { throw BoomError.invalid("Invalid video soundtrack packet.") }
      lastStart = start
      var bytes = Data(count: length)
      let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
      guard status == kCMBlockBufferNoErr else { throw BoomError.invalid("Video soundtrack packet cannot be read.") }
      try bytes.withUnsafeBytes { raw in
        for i in 0..<length / 4 {
          let value = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
          guard value.isFinite else { throw BoomError.invalid("Video soundtrack contains nonfinite samples.") }
          if samples.indices.contains(start + i) { samples[start + i] = value; decoded = true }
        }
      }
    }
    try flag.check()
    guard reader.status != .failed, decoded else { throw reader.error ?? BoomError.invalid("Video soundtrack decoding failed.") }
    return samples
  }
}

/// Decode one bounded recognition segment at a time, retaining the memory URL owner.
final class MemoryAudioReader: @unchecked Sendable {
  private let owner: MemoryMedia
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private var pending: [Float] = []
  let duration: Double
  init(owner: MemoryMedia, reader: AVAssetReader, output: AVAssetReaderTrackOutput, duration: Double) {
    self.owner = owner; self.reader = reader; self.output = output; self.duration = duration
  }
  deinit { reader.cancelReading() }
  func next(flag: CancellationFlag, seconds: Int = 50) throws -> AVAudioPCMBuffer? {
    let limit = seconds * 16_000
    guard seconds > 0, seconds <= 50 else { throw BoomError.invalid("Invalid audio segment size.") }
    while pending.count < limit {
      try flag.check()
      guard let sample = output.copyNextSampleBuffer() else {
        if reader.status == .failed { throw reader.error ?? BoomError.invalid("Audio decoding failed.") }
        break
      }
      guard let block = CMSampleBufferGetDataBuffer(sample) else { throw BoomError.invalid("Audio has no PCM data.") }
      let length = CMBlockBufferGetDataLength(block)
      guard length > 0, length % 4 == 0, length <= 4_194_304 else { throw BoomError.invalid("Invalid PCM sample block.") }
      var bytes = Data(count: length)
      let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
      guard status == kCMBlockBufferNoErr else { throw BoomError.invalid("Could not read PCM samples.") }
      bytes.withUnsafeBytes { raw in
        for offset in stride(from: 0, to: length, by: 4) { pending.append(raw.loadUnaligned(fromByteOffset: offset, as: Float.self)) }
      }
    }
    guard !pending.isEmpty else { return nil }
    let count = min(limit, pending.count)
    guard pending.prefix(count).allSatisfy(\.isFinite),
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
      let channel = buffer.floatChannelData?[0] else { throw BoomError.invalid("Could not allocate a speech segment.") }
    buffer.frameLength = AVAudioFrameCount(count)
    for index in 0..<count { channel[index] = pending[index] }
    pending.removeFirst(count)
    return buffer
  }
}
