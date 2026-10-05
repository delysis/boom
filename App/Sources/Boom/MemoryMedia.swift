import AVFoundation
import BoomCore
import Foundation
import UniformTypeIdentifiers

/// AVFoundation reads a private custom URL entirely through this delegate.
/// The delegate is retained by its owner; it never writes bytes to a file.
final class MemoryMedia: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  let asset: AVURLAsset
  private let bytes: Data
  private let contentType: String
  private let queue = DispatchQueue(label: "com.delysis.Bloom.media")
  init(bytes: Data, extension ext: String) {
    self.bytes = bytes
    contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
    asset = AVURLAsset(url: URL(string: "bloom-media://local/\(UUID().uuidString)")!)
    super.init()
    asset.resourceLoader.setDelegate(self, queue: queue)
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

  func audioReader() async throws -> MemoryAudioReader {
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0, duration <= 7200,
      let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw BoomError.budget("Audio must contain a local track of at most two hours.")
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
