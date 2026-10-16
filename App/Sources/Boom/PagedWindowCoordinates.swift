import AppKit
import BoomCore
import Foundation

struct PagedTextLocalEdit: Sendable {
  let revision: PagedTextRevision
  let windowID: UUID
  let byteStart: UInt64
  let byteEnd: UInt64
  let oldBytes: Data
  let newBytes: Data
}

/// Sparse, window-local scalar checkpoints. The complete file is never scanned
/// or retained to convert a native selection into exact absolute byte bounds.
/// These bounds are not authority: the engine still admits the revision/edit.
final class PagedWindowCoordinates {
  private struct Checkpoint {
    let byte: Int
    let utf16: Int
  }
  private let window: PagedTextWindow
  private var text: String
  private let checkpoints: [Checkpoint]
  let localByteCount: Int
  let localUTF16Count: Int

  init(window: PagedTextWindow) throws {
    try window.validate()
    var source = window.text
    source.makeContiguousUTF8()
    var checkpoints = [Checkpoint(byte: 0, utf16: 0)]
    var byte = 0, utf16 = 0, next = 256
    source.withUTF8 { bytes in
      while byte < bytes.count {
        let width = Self.width(bytes[byte])
        byte += width; utf16 += width == 4 ? 2 : 1
        if utf16 >= next {
          checkpoints.append(Checkpoint(byte: byte, utf16: utf16))
          next = utf16 + 256
        }
      }
    }
    if checkpoints.last?.byte != byte { checkpoints.append(Checkpoint(byte: byte, utf16: utf16)) }
    self.window = window; text = source
    self.checkpoints = checkpoints; localByteCount = byte; localUTF16Count = utf16
  }

  func absoluteByteRange(for range: NSRange) throws -> Range<UInt64> {
    guard range.location >= 0, range.length >= 0, range.location <= localUTF16Count,
      range.length <= localUTF16Count - range.location else {
      throw BoomError.invalid("Native selection is outside its captured window.")
    }
    let start = try byteOffset(forUTF16: range.location)
    let end = try byteOffset(forUTF16: range.location + range.length)
    let absoluteStart = window.byteStart.addingReportingOverflow(UInt64(start))
    let absoluteEnd = window.byteStart.addingReportingOverflow(UInt64(end))
    guard !absoluteStart.overflow, !absoluteEnd.overflow else {
      throw BoomError.invalid("Native selection cannot be represented in its source.")
    }
    return absoluteStart.partialValue..<absoluteEnd.partialValue
  }

  func localRange(forAbsoluteBytes range: Range<UInt64>) throws -> NSRange {
    guard range.lowerBound >= window.byteStart,
      range.upperBound >= range.lowerBound,
      range.upperBound - window.byteStart <= UInt64(localByteCount) else {
      throw BoomError.invalid("Global selection needs another native window.")
    }
    let start = try utf16Offset(forByte: Int(range.lowerBound - window.byteStart))
    let end = try utf16Offset(forByte: Int(range.upperBound - window.byteStart))
    return NSRange(location: start, length: end - start)
  }

  func edit(in range: NSRange, replacement: String) throws -> PagedTextLocalEdit {
    let absolute = try absoluteByteRange(for: range)
    let start = Int(absolute.lowerBound - window.byteStart), end = Int(absolute.upperBound - window.byteStart)
    let replacementCount = replacement.utf8.count
    guard replacementCount <= PagedTextWindow.maximumBytes,
      replacementCount <= PagedTextWindow.maximumBytes - (localByteCount - (end - start)) else {
      throw BoomError.budget("Native edit needs a recentered or streamed window.")
    }
    let old = text.withUTF8 { Data($0[start..<end]) }
    return PagedTextLocalEdit(revision: window.revision, windowID: window.windowID,
      byteStart: absolute.lowerBound, byteEnd: absolute.upperBound,
      oldBytes: old, newBytes: Data(replacement.utf8))
  }

  private func byteOffset(forUTF16 target: Int) throws -> Int {
    var low = 0, high = checkpoints.count
    while low < high {
      let middle = low + (high - low) / 2
      if checkpoints[middle].utf16 <= target { low = middle + 1 } else { high = middle }
    }
    var point = checkpoints[max(0, low - 1)]
    return try text.withUTF8 { bytes in
      while point.utf16 < target {
        let width = Self.width(bytes[point.byte]), units = width == 4 ? 2 : 1
        guard point.utf16 + units <= target else {
          throw BoomError.invalid("Native selection splits a Unicode scalar.")
        }
        point = Checkpoint(byte: point.byte + width, utf16: point.utf16 + units)
      }
      return point.byte
    }
  }
  private func utf16Offset(forByte target: Int) throws -> Int {
    var low = 0, high = checkpoints.count
    while low < high {
      let middle = low + (high - low) / 2
      if checkpoints[middle].byte <= target { low = middle + 1 } else { high = middle }
    }
    var point = checkpoints[max(0, low - 1)]
    return try text.withUTF8 { bytes in
      while point.byte < target {
        let width = Self.width(bytes[point.byte])
        guard point.byte + width <= target else {
          throw BoomError.invalid("Global selection splits a Unicode scalar.")
        }
        point = Checkpoint(byte: point.byte + width, utf16: point.utf16 + (width == 4 ? 2 : 1))
      }
      return point.utf16
    }
  }
  private static func width(_ first: UInt8) -> Int {
    // Swift String's contiguous UTF8 has already validated scalar encoding.
    if first < 0x80 { return 1 }
    if first < 0xe0 { return 2 }
    return first < 0xf0 ? 3 : 4
  }
}
