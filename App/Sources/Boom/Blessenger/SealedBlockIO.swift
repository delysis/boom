import BoomCore
import Darwin
import Foundation

/// Fixed-size authenticated blocks preserve the existing KV logical offsets.
/// Only a single 64 KiB plaintext block is staged; ciphertext overhead is part
/// of quota admission, not credited back before the owning file is unlinked.
final class SealedBlockWriter {
  static let blockBytes: UInt64 = 65_536
  private let fd: Int32
  private let total: UInt64
  private let binding: String
  private let cipher: RecordCipher
  private let wrote: (Int) -> Void
  private var pending = Data()
  private(set) var logical: UInt64 = 0
  private(set) var physical: UInt64 = 0
  private var index: UInt64 = 0

  static func cost(_ logical: UInt64) throws -> UInt64 {
    let blocks = logical / blockBytes + (logical % blockBytes == 0 ? 0 : 1)
    let (overhead, overflow) = blocks.multipliedReportingOverflow(by: UInt64(RecordCipher.overhead))
    let (bytes, sumOverflow) = logical.addingReportingOverflow(overhead)
    guard !overflow, !sumOverflow, bytes <= UInt64(Int64.max) else { throw BoomError.budget("Encrypted KV extent overflowed.") }
    return bytes
  }
  init(fd: Int32, total: UInt64, binding: String, cipher: RecordCipher, wrote: @escaping (Int) -> Void) {
    self.fd = fd; self.total = total; self.binding = binding; self.cipher = cipher; self.wrote = wrote
    pending.reserveCapacity(Int(Self.blockBytes))
  }
  func append(_ bytes: UnsafeRawPointer, count: Int) throws {
    guard count >= 0, logical <= total, UInt64(count) <= total - logical else { throw BoomError.invalid("Encrypted KV write exceeds its reservation.") }
    var offset = 0
    while offset < count {
      let n = min(count - offset, Int(Self.blockBytes) - pending.count)
      pending.append(bytes.assumingMemoryBound(to: UInt8.self).advanced(by: offset), count: n)
      logical += UInt64(n); offset += n
      if pending.count == Int(Self.blockBytes) { try flush() }
    }
  }
  func finish() throws {
    guard logical == total else { throw BoomError.invalid("Encrypted KV write is incomplete.") }
    if !pending.isEmpty { try flush() }
    guard physical == (try Self.cost(total)) else { throw BoomError.invalid("Encrypted KV physical extent changed.") }
  }
  private func flush() throws {
    let sealed = try cipher.seal(pending, binding: Self.binding(binding, total: total, index: index))
    try sealed.withUnsafeBytes { bytes in
      var done = 0
      while done < sealed.count {
        let n = pwrite(fd, bytes.baseAddress!.advanced(by: done), sealed.count - done, off_t(physical))
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        wrote(n); physical += UInt64(n); done += n
      }
    }
    pending.removeAll(keepingCapacity: true); index += 1
  }
  private static func binding(_ file: String, total: UInt64, index: UInt64) -> String {
    "kv-v1:\(file):\(total):\(index)"
  }
  static func read(_ fd: Int32, start: UInt64, count: Int, total: UInt64,
    binding file: String, cipher: RecordCipher) throws -> Data {
    guard count >= 0, start <= total, UInt64(count) <= total - start else { throw BoomError.invalid("Encrypted KV range exceeds its file.") }
    var result = Data(); result.reserveCapacity(count)
    var offset = start
    while result.count < count {
      let block = offset / blockBytes, within = Int(offset % blockBytes)
      let length = Int(min(blockBytes, total - block * blockBytes))
      let physical = block * (blockBytes + UInt64(RecordCipher.overhead))
      var bytes = Data(count: length + RecordCipher.overhead)
      try bytes.withUnsafeMutableBytes { output in
        var done = 0
        while done < output.count {
          let n = pread(fd, output.baseAddress!.advanced(by: done), output.count - done, off_t(physical + UInt64(done)))
          if n < 0, errno == EINTR { continue }
          guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
          done += n
        }
      }
      let opened = try cipher.open(bytes, binding: binding(file, total: total, index: block), limit: length)
      guard opened.count == length else { throw BoomError.invalid("Encrypted KV block changed its length.") }
      let n = min(count - result.count, length - within)
      result.append(opened[within..<(within + n)]); offset += UInt64(n)
    }
    return result
  }
}
