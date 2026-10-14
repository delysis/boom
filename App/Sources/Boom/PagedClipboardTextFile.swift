import AppKit
import BoomCore
import Darwin
import Foundation
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
  static let bloomTextFile = Self("com.delysis.bloom.text-file")
}

/// Explicit clipboard text intent plus its original board generation. A URL
/// alone remains an attachment; the marker grants no filesystem authority.
struct PagedClipboardTextFile: Sendable, Equatable {
  let url: URL
  let pasteboardName: String
  let changeCount: Int
  let explicitlyPlainText: Bool

  @MainActor static func read(_ pasteboard: NSPasteboard, explicitlyPlainText: Bool = false) throws -> Self? {
    guard let items = pasteboard.pasteboardItems else { return nil }
    let marked = items.contains { $0.types.contains(.bloomTextFile) }
    guard marked || explicitlyPlainText else { return nil }
    guard items.count == 1 else {
      if marked { throw BoomError.unavailable("Paste one streamed text selection at a time.") }
      return nil
    }
    let item = items[0]
    guard let value = item.string(forType: .fileURL) else {
      if marked { throw BoomError.invalid("The streamed text clipboard has no file URL.") }
      return nil
    }
    guard value.utf8.count <= 4_096, let url = URL(string: value), url.isFileURL,
      url.path.hasPrefix("/"), url.path.utf8.count <= 4_096,
      url.host == nil || url.host == "" || url.host == "localhost",
      url.query == nil, url.fragment == nil else { throw BoomError.invalid("The clipboard text URL is not a bounded local file.") }
    if marked {
      guard item.string(forType: .bloomTextFile) == value else {
        throw BoomError.stale("The streamed text clipboard does not name its original file.")
      }
    } else {
      guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) == true else { return nil }
    }
    return Self(url: url, pasteboardName: pasteboard.name.rawValue, changeCount: pasteboard.changeCount,
      explicitlyPlainText: explicitlyPlainText)
  }

  @MainActor func admitCurrent() throws {
    let board = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
    guard board.changeCount == changeCount,
      try Self.read(board, explicitlyPlainText: explicitlyPlainText) == self else {
      throw BoomError.stale("The clipboard changed before its text source was captured.")
    }
  }

  @MainActor static func write(_ file: URL, to pasteboard: NSPasteboard) throws {
    let value = file.absoluteString, item = NSPasteboardItem()
    guard file.isFileURL, value.utf8.count <= 4_096,
      item.setString(value, forType: .fileURL), item.setString(value, forType: .bloomTextFile) else {
      throw BoomError.invalid("The selected text file could not prepare its clipboard representations.")
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw BoomError.unavailable("The selected text file was not written to the clipboard.") }
  }

  struct Opened: Sendable {
    private struct Identity: Sendable, Equatable {
      let device: Int32
      let inode: UInt64
      let size: Int64
      let modifiedSeconds: Int
      let modifiedNanos: Int
      let changedSeconds: Int
      let changedNanos: Int
      init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
      }
      func matchesContentObservation(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size
          && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
      }
    }
    let file: FileHandle
    let expectedBytes: UInt64
    private let identity: Identity

    init(url: URL) throws {
      var before = stat()
      guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
        before.st_size >= 0 else {
        throw BoomError.budget("Paste requires an ordinary UTF8 text file.")
      }
      let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw BoomError.unavailable("The clipboard text file could not be opened.") }
      file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      identity = Identity(before); expectedBytes = UInt64(before.st_size)
      do {
        var captured = stat()
        guard fstat(file.fileDescriptor, &captured) == 0, captured.st_mode & S_IFMT == S_IFREG,
          Identity(captured) == identity else {
          throw BoomError.stale("The clipboard text file changed before its descriptor was captured.")
        }
      }
      catch {
        let original = error
        do { try close() }
        catch { throw PagedClipboardFileCleanupFailure(original: original, cleanup: error) }
        throw original
      }
    }

    /// The no-follow open must match the initial file observation. Once
    /// captured, this descriptor owns the Paste source independently of its
    /// pathname and clipboard. ctime observes rename/chmod too, so only the
    /// content's extent/mtime remain part of post-capture integrity admission.
    func admit() throws {
      var descriptor = stat()
      guard fstat(file.fileDescriptor, &descriptor) == 0,
        descriptor.st_mode & S_IFMT == S_IFREG, Identity(descriptor).matchesContentObservation(identity) else {
        throw BoomError.stale("The original clipboard text file changed during capture.")
      }
    }

    func close() throws {
      do { try file.close() }
      catch { throw PagedClipboardFileCloseFailure(original: error, file: file) }
    }
  }

  func open() throws -> Opened { try Opened(url: url) }
}

/// A refused close retains the exact descriptor object and original error.
/// Neither the selected source nor its filename is deleted during cleanup.
private struct PagedClipboardFileCloseFailure: Error, LocalizedError {
  let original: Error
  let file: FileHandle
  var errorDescription: String? { original.localizedDescription }
}
private struct PagedClipboardFileCleanupFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? { "\(original.localizedDescription) Clipboard handle cleanup: \(cleanup.localizedDescription)" }
}
