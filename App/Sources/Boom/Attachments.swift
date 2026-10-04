import AVFoundation
import AppKit
import CAttachment
import CoreImage
import Foundation
import ImageIO
import BoomCore
import PDFKit
import UniformTypeIdentifiers

/// Image identity is derived from bounded bytes, never from the filename or
/// whether a text extractor happened to find words in the image.
enum LocalImage {
  static func decode(_ data: Data) throws -> CIImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?,
      UTType(type)?.conforms(to: .image) == true,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 8_192, height <= 8_192,
      width * height <= 32_000_000,
      let image = CIImage(data: data)
    else { throw BoomError.invalid("The selected image cannot be decoded locally.") }
    return image
  }
  static func canDecode(_ data: Data) -> Bool { (try? decode(data)) != nil }
}

/// Decode a paste or drop once, before either editor chooses its destination.
/// Plain text remains the text view's own paste operation.
enum AttachmentInput {
  case file(URL)
  case bytes(name: String, data: Data)

  static func read(_ pasteboard: NSPasteboard) -> [AttachmentInput]? {
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty {
      return urls.map(AttachmentInput.file)
    }
    return readImage(pasteboard).map { [$0] }
  }

  static func readImage(_ pasteboard: NSPasteboard) -> AttachmentInput? {
    if let data = pasteboard.data(forType: .png) {
      return .bytes(name: "Pasted image.png", data: data)
    }
    if let data = pasteboard.data(forType: .tiff) {
      return .bytes(name: "Pasted image.tiff", data: data)
    }
    return nil
  }

  static func canRead(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
  }
}

/// AVAudioConverter's input block is Sendable even for a synchronous convert.
/// Serialize access to the one local buffer rather than exposing a mutable
/// captured variable or passing the non-Sendable AVAudioPCMBuffer across tasks.
final class OneShotAudioInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if supplied {
      status.pointee = .endOfStream
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}

struct AttachmentImport: Sendable {
  let record: AttachmentRecord
  let receipt: Data
  let original: Data
}
enum AttachmentProcessor {
  static func inspect(name: String, data: Data) throws -> AttachmentImport {
    guard !data.isEmpty, data.count <= 67_108_864 else {
      throw BoomError.budget("Attachments must be nonempty and at most 64 MiB.")
    }
    let nameBytes = Data(name.utf8)
    let buffer = nameBytes.withUnsafeBytes { namePointer in
      data.withUnsafeBytes { dataPointer in
        boom_attachment_inspect(
          namePointer.bindMemory(to: UInt8.self).baseAddress, nameBytes.count,
          dataPointer.bindMemory(to: UInt8.self).baseAddress, data.count)
      }
    }
    defer { boom_attachment_free(buffer) }
    guard let pointer = buffer.data, buffer.length > 0, buffer.length <= 8_388_608 else {
      throw BoomError.invalid("Attachment bridge returned an invalid owned buffer.")
    }
    let response = Data(bytes: pointer, count: buffer.length)
    let digest = Digest.sha256(data)
    func blocked(_ reason: String) -> AttachmentImport {
      AttachmentImport(
        record: AttachmentRecord(
          id: UUID(), name: name, rootDigest: digest, text: "", coverage: "Blocked: " + reason,
          transform: nil), receipt: response, original: data)
    }
    guard let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
      object["schema"] as? Int == 1
    else {
      return blocked(
        "Unknown attachment response; no context admitted. Original and raw receipt retained.")
    }
    guard object["ok"] as? Bool == true else {
      let error = object["error"] as? [String: Any]
      return blocked(error?["message"] as? String ?? "Attachment inspection failed.")
    }
    guard let root = object["root"] as? String, !root.isEmpty,
      let texts = object["texts"] as? [String], let receipt = object["receipt"] as? [String: Any],
      object["input_sha256"] as? String == digest
    else {
      return blocked("Bridge input identity or receipt is invalid; no context admitted.")
    }
    guard receipt["network_used"] as? Bool == false, receipt["process_used"] as? Bool == false
    else {
      return blocked("The host did not attest to in-process, network-free inspection.")
    }
    let text = texts.joined(separator: "\n\n")
    let status = (receipt["status"] as? String ?? "unknown").lowercased()
    guard text.utf8.count <= 262_144 else {
      return blocked("Canonical attachment text exceeds 256 KiB.")
    }
    let complete = (receipt["complete_coverage"] as? Bool == true) && status == "passed"
    let coverage =
      complete
      ? "Canonical text; complete reported coverage"
      : "Partial or blocked coverage; see processing receipt"
    return AttachmentImport(
      record: AttachmentRecord(
        id: UUID(), name: name, rootDigest: digest, text: text, coverage: coverage, transform: nil),
      receipt: response, original: data)
  }
  static func readGranted(_ url: URL) throws -> Data {
    let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size > 0,
      size <= 67_108_864
    else {
      throw BoomError.budget(
        "Choose a regular file up to 64 MiB; symlinks and directories are not attachments.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 67_108_865) ?? Data()
    guard data.count <= 67_108_864 else {
      throw BoomError.budget("Attachment grew beyond 64 MiB while reading.")
    }
    return data
  }
}

struct NativeFrame: @unchecked Sendable {
  let seconds: Double
  let image: CGImage
}
enum NativePreparedMedia: @unchecked Sendable {
  case image(CGImage)
  case audio([Float], String)
  case video([NativeFrame], String)
  case text(String, String)
}
enum NativeMedia {
  static func thumbnail(_ data: Data, maximum: Int = 1600) -> CGImage? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let type = CGImageSourceGetType(source) as String?,
      [
        "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff",
        "com.compuserve.gif", "org.webmproject.webp",
      ].contains(type),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 32768, height <= 32768,
      Int64(width) * Int64(height) <= 50_000_000
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maximum,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  }
  static func prepare(
    data: Data, name: String, audioSeconds: Double, flag: CancellationFlag
  ) async throws
    -> NativePreparedMedia
  {
    try flag.check()
    // AppKit's document reader understands the legacy OLE Word container. The
    // attachment remains in the vault; this is a bounded text view of it.
    if (name as NSString).pathExtension.lowercased() == "doc",
      data.starts(with: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
      let document = try NSAttributedString(
        data: data, options: [.documentType: NSAttributedString.DocumentType.docFormat],
        documentAttributes: nil)
      let source = document.string
      guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BoomError.invalid("This Word document contains no extractable text.")
      }
      var excerpt = ""
      excerpt.reserveCapacity(min(source.utf8.count, 262_144))
      var bytes = 0
      for character in source {
        let count = String(character).utf8.count
        if bytes + count > 262_144 { break }
        excerpt.append(character)
        bytes += count
      }
      return .text(
        excerpt,
        "AppKit legacy Word text extraction; \(bytes) of \(source.utf8.count) UTF-8 bytes. "
          + "Formatting, embedded media and later text are not represented when excerpted.")
    }
    if data.starts(with: Data("%PDF-".utf8)) {
      guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount <= 128 else {
        throw BoomError.budget(
          "PDF is locked, malformed, or exceeds 128 pages for native text extraction.")
      }
      var parts: [String] = []
      var bytes = 0
      var empty = 0
      for i in 0..<pdf.pageCount {
        try flag.check()
        let text = pdf.page(at: i)?.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
        bytes += text.utf8.count
        guard bytes <= 262_144 else {
          throw BoomError.budget(
            "PDF text exceeds 256 KiB. No partial extraction was silently accepted.")
        }
        parts.append("[Page \(i+1)]\n" + text)
      }
      guard !parts.isEmpty else { throw BoomError.invalid("PDF has no pages.") }
      return .text(
        parts.joined(separator: "\n\n"),
        "PDFKit text extraction; \(pdf.pageCount) pages, \(empty) pages without extractable text. No OCR. Layout, images and scans are not fully represented."
      )
    }
    if let image = thumbnail(data) { return .image(image) }
    let head = Array(data.prefix(16))
    let isWave =
      head.count >= 12 && String(bytes: head[0..<4], encoding: .ascii) == "RIFF"
      && String(bytes: head[8..<12], encoding: .ascii) == "WAVE"
    let isAIFF =
      head.count >= 12 && String(bytes: head[0..<4], encoding: .ascii) == "FORM"
      && ["AIFF", "AIFC"].contains(String(bytes: head[8..<12], encoding: .ascii) ?? "")
    let isFLAC = data.starts(with: Data("fLaC".utf8))
    let isMP3 =
      data.starts(with: Data("ID3".utf8))
      || (head.count >= 2 && head[0] == 0xff && head[1] & 0xe0 == 0xe0)
    if isWave || isAIFF || isFLAC || isMP3 {
      return try await temporary(
        data, extension: isWave ? "wav" : isAIFF ? "aiff" : isFLAC ? "flac" : "mp3"
      ) { url in
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate >= 8000, format.sampleRate <= 192000, format.channelCount > 0,
          format.channelCount <= 8, audioSeconds > 0
        else { throw BoomError.invalid("Unsupported audio format or no local audio encoder.") }
        let seconds = min(audioSeconds, 30)
        let frames = AVAudioFrameCount(
          min(file.length, AVAudioFramePosition(seconds * format.sampleRate)))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
          let output = AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: AVAudioFrameCount(seconds * 16000)),
          let converter = AVAudioConverter(from: format, to: target)
        else { throw BoomError.invalid("Cannot allocate the bounded audio conversion.") }
        try flag.check()
        try file.read(into: input, frameCount: frames)
        let source = OneShotAudioInput(input)
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
          source.take(status)
        }
        if let error { throw error }
        guard result != .error, let samples = output.floatChannelData?[0], output.frameLength > 0
        else { throw BoomError.invalid("Native audio decoding failed.") }
        let array = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        guard array.allSatisfy(\.isFinite) else {
          throw BoomError.invalid("Audio contains nonfinite samples.")
        }
        return .audio(
          array,
          "First \(String(format:"%.2f",Double(array.count)/16000)) seconds of \(String(format:"%.2f",Double(file.length)/format.sampleRate)) seconds; local Gemma transcript, not guaranteed verbatim."
        )
      }
    }
    guard try MediaContainerPolicy.selfContainedMP4(data) else {
      throw BoomError.unavailable(
        "No supported native transform. Use canonical text or a supported image, WAV/AIFF/FLAC/MP3 audio, or self-contained MP4 video. The original and processing receipt remain available."
      )
    }
    return try await temporary(data, extension: "mp4") { url in
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration).seconds
      guard duration.isFinite, duration > 0, duration <= 7200 else {
        throw BoomError.budget("Video duration is invalid or exceeds two hours.")
      }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 1600, height: 1600)
      var frames: [NativeFrame] = []
      for i in 0..<4 {
        try flag.check()
        let seconds = min(max(0, duration - 0.05), duration * Double(i) / 4)
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        frames.append(NativeFrame(seconds: frame.actualTime.seconds, image: frame.image))
      }
      return .video(
        frames,
        "Four sampled still frames from a \(String(format:"%.1f",duration))-second MP4. No audio or continuous motion was analyzed; descriptions are machine-generated and partial."
      )
    }
  }
  private static func temporary<T>(
    _ data: Data, extension ext: String, body: (URL) async throws -> T
  ) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "boom-media-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = root.appendingPathComponent("source." + ext)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(file)
  }
}
