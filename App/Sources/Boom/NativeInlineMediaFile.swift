import AppKit
import AVFoundation
import BoomCore
import CryptoKit
import Darwin
import Foundation
import ObjectiveC
import PDFKit

private nonisolated(unsafe) var nativeMediaFileLifetimeKey: UInt8 = 0

struct NativeInlineMediaCleanupFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? { original.localizedDescription + " Cleanup: " + cleanup.localizedDescription }
}

/// Refusal retains the originally owned path and underlying failure; it does
/// not assert that a replaced path is still our directory or authorize deletion.
struct NativeInlineMediaFileCleanupFailure: Error, LocalizedError {
  let original: Error
  let ownedDirectory: URL
  var errorDescription: String? {
    original.localizedDescription + " Disposable media cleanup retained: " + ownedDirectory.path
  }
}

/// Only deletion jobs live here. A still-owned native asset/PDF or adopted
/// item keeps its file alive; joining never invalidates that shared reference.
final class NativeInlineMediaDisposal: @unchecked Sendable {
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var firstFailure: NativeInlineMediaFileCleanupFailure?

  fileprivate func discard(_ capture: NativeInlineMediaFile.Capture) {
    group.enter()
    DispatchQueue.global(qos: .utility).async { [self] in
      defer { group.leave() }
      do { try autoreleasepool { try capture.discard() } }
      catch {
        lock.lock(); defer { lock.unlock() }
        if firstFailure == nil {
          firstFailure = NativeInlineMediaFileCleanupFailure(original: error, ownedDirectory: capture.directory)
        }
      }
    }
  }
  /// The surface first stops/joins its real producer and releases its own
  /// items. Escaped adopted/native references may enqueue their deletion later.
  func joinQueued() async -> NativeInlineMediaFileCleanupFailure? {
    await withCheckedContinuation { continuation in
      group.notify(queue: .global(qos: .utility)) { [self] in
        lock.lock(); let failure = firstFailure; lock.unlock()
        continuation.resume(returning: failure)
      }
    }
  }
}

/// One verified ordinary file for the actual native consumer. This is a
/// disposable system temporary clone, never a workspace/source replacement.
final class NativeInlineMediaFile: @unchecked Sendable {
  fileprivate struct Capture: Sendable {
    let directory: URL
    let device: dev_t, inode: ino_t, owner: uid_t
    func discard() throws {
      var actual = stat()
      guard lstat(directory.path, &actual) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard actual.st_mode & S_IFMT == S_IFDIR, actual.st_uid == owner,
        actual.st_dev == device, actual.st_ino == inode else {
        throw BoomError.stale("The disposable media directory changed before cleanup.")
      }
      try FileManager.default.removeItem(at: directory)
    }
  }
  let url: URL
  let container: MediaContainer?
  private let capture: Capture
  private let disposal: NativeInlineMediaDisposal

  private init(url: URL, container: MediaContainer?, capture: Capture, disposal: NativeInlineMediaDisposal) {
    self.url = url; self.container = container; self.capture = capture; self.disposal = disposal
  }
  deinit { disposal.discard(capture) }

  /// Native asynchronous reads may outlive their view. Tie the immutable file
  /// to the actual asset/document/item, not an assumed callback completion.
  func retainForLifetime(of object: NSObject) {
    objc_setAssociatedObject(object, &nativeMediaFileLifetimeKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  static func clone(record: AttachmentRecord, vault: Vault,
    disposal: NativeInlineMediaDisposal) throws -> NativeInlineMediaFile {
    precondition(!Thread.isMainThread)
    try Task.checkCancellation()
    let source = vault.recordURL(.attachment, record.id)
    let replacement = try FileManager.default.url(for: .itemReplacementDirectory,
      in: .userDomainMask, appropriateFor: source, create: true)
    // Resolve Foundation's system-directory aliases before capturing ownership;
    // the subsequent clone and reads still refuse every symbolic-link component.
    let directory = try WorkspaceBackup.physicalDirectory(replacement)
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid() else {
      throw BoomError.invalid("Media preview requires its owned temporary directory.")
    }
    let capture = Capture(directory: directory, device: info.st_dev, inode: info.st_ino, owner: info.st_uid)
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let staged = directory.appendingPathComponent("Original")
      // No byte-copy or resident-original fallback on unsupported cloning.
      try WorkspaceBackup.cloneFile(source, to: staged)
      try verify(staged, record: record)
      let container: MediaContainer?
      if record.kind == .audio || record.kind == .video { container = try admittedContainer(staged) }
      else { container = nil }
      guard record.kind != .video || container == .mp4 else {
        throw BoomError.invalid("This attachment is not self-contained MP4 video.")
      }
      // The filename follows actual admitted bytes, never an untrusted or
      // misleading record name. The object becomes immutable after this move.
      let suffix: String?
      if let container { suffix = container.rawValue }
      else if record.kind == .pdf { suffix = "pdf" }
      else { suffix = nil }
      let target = suffix.map { directory.appendingPathComponent("Original." + $0) } ?? staged
      if target != staged { try FileManager.default.moveItem(at: staged, to: target) }
      try Task.checkCancellation()
      return NativeInlineMediaFile(url: target, container: container, capture: capture, disposal: disposal)
    } catch {
      disposal.discard(capture)
      throw error
    }
  }

  private static func verify(_ url: URL, record: AttachmentRecord) throws {
    var hash = SHA256()
    _ = try RegularFile(url, limit: 67_108_864, allowEmpty: false).chunks { bytes in
      try Task.checkCancellation()
      hash.update(data: bytes)
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == record.rootDigest else {
      throw BoomError.stale("The captured media original does not match its record.")
    }
    try Task.checkCancellation()
  }

  /// Reuse the actual Rust descriptor admission without a resident original.
  /// The private immutable clone is mapped only for this call; no mapped Data
  /// escapes, and failed mapping never falls back to a full heap read.
  private static func admittedContainer(_ url: URL) throws -> MediaContainer {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var mapping: UnsafeMutableRawPointer?, length = 0
    var result: MediaContainer?, failure: Error?
    func failedCleanup(_ error: Error) {
      if let original = failure { failure = NativeInlineMediaCleanupFailure(original: original, cleanup: error) }
      else { failure = error }
    }
    do {
      var before = stat(), after = stat()
      guard fstat(descriptor, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= 67_108_864 else {
        throw BoomError.invalid("Media admission requires its bounded regular clone.")
      }
      length = Int(before.st_size)
      guard let pointer = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), pointer != MAP_FAILED else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      mapping = pointer
      try Task.checkCancellation()
      result = try autoreleasepool {
        let borrowed = Data(bytesNoCopy: pointer, count: length, deallocator: .none)
        return try ProductCore.admitMedia(borrowed)
      }
      guard fstat(descriptor, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
        throw BoomError.stale("The captured media changed during admission.")
      }
      try Task.checkCancellation()
    } catch { failure = error }
    if let mapping, munmap(mapping, length) != 0 { failedCleanup(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
    if Darwin.close(descriptor) != 0 { failedCleanup(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
    if let failure { throw failure }
    guard let result else { throw BoomError.invalid("Media admission returned no container.") }
    return result
  }

  /// Only explicit Copy/export reads an entire admitted original into Data.
  func verifiedBytes(for record: AttachmentRecord) throws -> Data {
    precondition(!Thread.isMainThread)
    try Task.checkCancellation()
    let bytes = try RegularFile(url, limit: 67_108_864, allowEmpty: false).data()
    guard Digest.sha256(bytes) == record.rootDigest else {
      throw BoomError.stale("The captured media original does not match its record.")
    }
    try Task.checkCancellation()
    return bytes
  }
}

/// The worker constructs these native objects before transferring their sole
/// use to Main. Only immutable CGImages may be read by several surfaces.
struct NativeInlineMediaPrepared: @unchecked Sendable {
  let file: NativeInlineMediaFile?
  let image: CGImage?
  let imageGeometry: NSSize?
  let pdf: PDFDocument?
  let asset: AVURLAsset?

  static func load(record: AttachmentRecord, vault: Vault, availableWidth: CGFloat,
    scale: CGFloat, disposal: NativeInlineMediaDisposal) throws -> Self {
    precondition(!Thread.isMainThread)
    return try autoreleasepool {
      let file = try NativeInlineMediaFile.clone(record: record, vault: vault, disposal: disposal)
      switch record.kind {
      case .image:
        guard let nominal = NativeMedia.thumbnail(file.url, maximum: 1600) else {
          throw BoomError.invalid("The verified image cannot be previewed locally.")
        }
        let geometry = NSSize(width: CGFloat(nominal.width), height: CGFloat(nominal.height))
        let display = InlineMediaItem.imageSize(geometry: geometry, available: availableWidth)
        let maximum = max(1, min(1600, Int(ceil(max(display.width, display.height) * max(1, scale)))))
        let image: CGImage
        if maximum >= max(nominal.width, nominal.height) { image = nominal }
        else {
          guard let scaled = NativeMedia.thumbnail(file.url, maximum: maximum) else {
            throw BoomError.invalid("The verified image cannot produce its visible preview.")
          }
          image = scaled
        }
        return Self(file: nil, image: image, imageGeometry: geometry, pdf: nil, asset: nil)
      case .audio, .video:
        let asset = AVURLAsset(url: file.url)
        file.retainForLifetime(of: asset)
        return Self(file: file, image: nil, imageGeometry: nil, pdf: nil, asset: asset)
      case .pdf:
        guard let pdf = PDFDocument(url: file.url), pdf.pageCount > 0 else {
          throw BoomError.invalid("The verified PDF cannot be previewed locally.")
        }
        file.retainForLifetime(of: pdf)
        return Self(file: file, image: nil, imageGeometry: nil, pdf: pdf, asset: nil)
      case .document, .unavailable:
        throw BoomError.invalid("This presentation does not require an original-file preview.")
      }
    }
  }
}
