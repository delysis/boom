import BoomCore
import Darwin
import Dispatch
import Foundation
import MLX

/// Disposable process-local KV bytes. No restart catalog, durability or author
/// storage is involved. Only one completed allocation cohort can be in flight.
/// File creation, raw copying, write/close and last-owner unlink run off Main and
/// off the MLX producer. The producer submits metadata and ready storage only.
final class PrefixKVDiskStore: @unchecked Sendable {
  struct ReadySpan: Sendable {
    let start: Int
    let layer: Int
    let keys: MLXReadyBuffer
    let values: MLXReadyBuffer
    let positions: Range<Int>
    let rows: Range<Int>
    let byteCount: UInt64
    var count: Int { positions.count }
    init(start: Int, layer: Int, keys: MLXReadyBuffer, values: MLXReadyBuffer,
      positions: Range<Int>, rows selectedRows: Range<Int>? = nil) throws {
      let rows = selectedRows ?? (0..<(keys.shape.first ?? 0))
      guard !rows.isEmpty, rows.lowerBound >= 0,
        keys.shape.count == 4, rows.upperBound <= keys.shape[0], values.shape.count == 4,
        keys.shape[0...2] == values.shape[0...2], start >= 0, layer >= 0,
        positions.lowerBound >= 0, !positions.isEmpty, positions.upperBound <= keys.shape[2] else {
        throw BoomError.invalid("Invalid completed KV span.")
      }
      let keyBytes = try PrefixKVDiskStore.arrayBytes([rows.count] + Array(keys.shape.dropFirst()), positions: positions.count, type: keys.dtype)
      let valueBytes = try PrefixKVDiskStore.arrayBytes([rows.count] + Array(values.shape.dropFirst()), positions: positions.count, type: values.dtype)
      _ = try PrefixKVDiskStore.arrayBytes(keys.shape, positions: keys.shape[2], type: keys.dtype)
      _ = try PrefixKVDiskStore.arrayBytes(values.shape, positions: values.shape[2], type: values.dtype)
      let (total, overflow) = UInt64(keyBytes).addingReportingOverflow(UInt64(valueBytes))
      guard !overflow else { throw BoomError.invalid("Completed KV extent overflowed.") }
      self.start = start; self.layer = layer; self.keys = keys; self.values = values
      self.positions = positions; self.rows = rows; byteCount = total
    }
  }
  struct Observation: Sendable {
    let bytes: UInt64
    let inFlight: Bool
    let misses: UInt64
    let quotaMisses: UInt64
    let submittedJobs: UInt64
    let createdFiles: UInt64
    let writeCalls: UInt64
    let writtenBytes: UInt64
    let directoryPath: String?
  }
  private let queue = DispatchQueue(label: "Bloom.prefix-kv-spill", qos: .utility)
  private let lock = NSLock()
  fileprivate let protection: RecordCipher?
  private let temporaryParent: URL?
  private var directory: URL?
  private let byteLimit: UInt64
  private let maximumFiles: Int
  private var bytes: UInt64 = 0
  private var files = 0
  private var inFlight = false
  private var misses: UInt64 = 0
  private var quotaMisses: UInt64 = 0
  private var submittedJobs: UInt64 = 0
  private var createdFiles: UInt64 = 0
  private var writeCalls: UInt64 = 0
  private var writtenBytes: UInt64 = 0
  // Initialized on the file worker before a span can be returned. Files retain
  // this store, so the descriptor cannot close while hydration uses openat.
  private var directoryFD: Int32 = -1
  private var directoryPath: String?
  private var directoryIdentity: stat?
  private final class Work: @unchecked Sendable {
    var spans: [ReadySpan]
    init(_ spans: [ReadySpan]) { self.spans = spans }
  }

  fileprivate static func arrayBytes(_ shape: [Int], positions: Int, type: DType) throws -> Int {
    guard shape.count == 4, shape.allSatisfy({ $0 > 0 }), positions > 0, positions <= shape[2] else {
      throw BoomError.invalid("Invalid KV byte shape.")
    }
    var bytes = type.size
    for length in [shape[0], shape[1], positions, shape[3]] {
      let (next, overflow) = bytes.multipliedReportingOverflow(by: length)
      guard !overflow else { throw BoomError.invalid("KV byte extent overflowed.") }; bytes = next
    }
    return bytes
  }

  init(byteLimit: UInt64 = 4_294_967_296, maximumFiles: Int = 4096,
    temporaryParent: URL? = nil, protection: RecordCipher? = nil) {
    precondition(byteLimit <= UInt64(Int64.max) && maximumFiles > 0)
    self.byteLimit = byteLimit; self.maximumFiles = maximumFiles
    self.temporaryParent = temporaryParent // explicit isolated parent for fixtures
    self.protection = protection
  }
  deinit {
    let path = directory?.path, fd = directoryFD, identity = directoryIdentity
    queue.async {
      if fd >= 0 { _ = Darwin.close(fd) }
      var current = stat()
      if let path, let identity, lstat(path, &current) == 0, current.st_dev == identity.st_dev,
        current.st_ino == identity.st_ino, current.st_mode & S_IFMT == S_IFDIR {
        _ = Darwin.rmdir(path)
      }
    }
  }
  var observation: Observation {
    lock.lock(); defer { lock.unlock() }
    return Observation(bytes: bytes, inFlight: inFlight, misses: misses,
      quotaMisses: quotaMisses, submittedJobs: submittedJobs, createdFiles: createdFiles,
      writeCalls: writeCalls, writtenBytes: writtenBytes, directoryPath: directoryPath)
  }
  var canSubmit: Bool { lock.lock(); defer { lock.unlock() }; return !inFlight }

  func fitsEmpty(_ spans: [ReadySpan]) -> Bool {
    var amount: UInt64 = 0
    for span in spans {
      let (sum, overflow) = amount.addingReportingOverflow(span.byteCount)
      guard !overflow else { return false }; amount = sum
    }
    guard let physical = try? chargedBytes(spans) else { return false }
    return physical <= byteLimit && Set(spans.map(\.layer)).count <= maximumFiles
  }

  private func chargedBytes(_ spans: [ReadySpan]) throws -> UInt64 {
    var total: UInt64 = 0
    for group in Dictionary(grouping: spans, by: \.layer).values {
      var raw: UInt64 = 0
      for span in group {
        let (sum, overflow) = raw.addingReportingOverflow(span.byteCount)
        guard !overflow else { throw BoomError.budget("KV byte extent overflowed.") }; raw = sum
      }
      let charge = try protection == nil ? raw : SealedBlockWriter.cost(raw)
      let (sum, overflow) = total.addingReportingOverflow(charge)
      guard !overflow else { throw BoomError.budget("KV quota overflowed.") }; total = sum
    }
    return total
  }

  /// Admission never touches a file or waits for a worker. Refusal is a real
  /// optimization miss. Source leases keep the FULL physical parent charged.
  @discardableResult func submit(_ spans: [ReadySpan],
    isLive: @escaping @Sendable () -> Bool,
    completed: @escaping @Sendable ([PrefixKVSpan]?) -> Void) -> Bool {
    guard !spans.isEmpty else { return false }
    var amount: UInt64 = 0
    for span in spans {
      guard span.keys.shape.count == 4, span.values.shape.count == 4,
        span.keys.shape[0...2] == span.values.shape[0...2],
        span.positions.lowerBound >= 0, span.positions.upperBound <= span.keys.shape[2],
        !span.positions.isEmpty, !span.rows.isEmpty, span.rows.lowerBound >= 0,
        span.rows.upperBound <= span.keys.shape[0] else { return false }
      let (sum, overflow) = amount.addingReportingOverflow(span.byteCount)
      guard !overflow else { return false }; amount = sum
    }
    guard let physical = try? chargedBytes(spans) else { return false }
    amount = physical
    let fileCount = Set(spans.map(\.layer)).count
    lock.lock()
    guard !inFlight else { misses &+= 1; lock.unlock(); return false }
    guard amount <= byteLimit, bytes <= byteLimit - amount,
      fileCount <= maximumFiles - files else {
      misses &+= 1; quotaMisses &+= 1; lock.unlock(); return false
    }
    inFlight = true; bytes += amount; files += fileCount; submittedJobs &+= 1
    lock.unlock()
    let reservedBytes = amount
    let work = Work(spans)
    queue.async { [self, work] in
      var result: [PrefixKVSpan]?
      do { result = try write(work.spans, amount: reservedBytes, fileCount: fileCount, isLive: isLive) }
      catch { result = nil }
      work.spans.removeAll() // release raw parents before publication/idle
      completed(result)
      lock.lock(); inFlight = false
      if result == nil { misses &+= 1 }
      lock.unlock()
    }
    return true
  }
  func joinPending() async {
    await withCheckedContinuation { waiter in
      // A completed write may enqueue last-owner cleanup behind this first
      // marker. The second marker joins those actual unlinks too, with no
      // optimistic quota credit or hot-loop wait.
      queue.async { [self] in queue.async { waiter.resume() } }
    }
  }
  fileprivate func remove(_ url: URL, bytes amount: UInt64) {
    queue.async { [self] in
      let rc = Darwin.unlinkat(directoryFD, url.lastPathComponent, 0)
      let absent = rc == 0 || errno == ENOENT
      lock.lock()
      if absent { bytes -= amount; files -= 1 }
      else { misses &+= 1 } // failed unlink remains quota charged
      lock.unlock()
    }
  }
  private func releaseReservation(_ amount: UInt64, files count: Int = 1) {
    lock.lock(); bytes -= amount; files -= count; lock.unlock()
  }
  private func prepareDirectory(isLive: @Sendable () -> Bool) throws {
    guard isLive() else { throw CancellationError() }
    if directoryFD < 0 {
      let directory: URL
      do {
        if let temporaryParent {
          directory = temporaryParent.appendingPathComponent("Bloom-KV-" + UUID().uuidString, isDirectory: true)
          guard mkdir(directory.path, 0o700) == 0 else { throw Self.ioError() }
        } else {
          // Native system-managed replacement lifetime also covers abandoned
          // directories after process death. No restart catalog or app janitor.
          directory = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        }
      } catch { throw error }
      guard isLive() else {
        _ = Darwin.rmdir(directory.path); throw CancellationError()
      }
      let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      var identity = stat()
      guard fd >= 0 else { throw Self.ioError() }
      guard fstat(fd, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR,
        identity.st_uid == getuid(), identity.st_mode & 0o777 == 0o700,
        let physical = Darwin.realpath(directory.path, nil) else {
        _ = Darwin.close(fd); _ = Darwin.rmdir(directory.path)
        throw BoomError.invalid("Disposable KV directory admission failed.")
      }
      let actualPath = String(cString: physical); free(physical)
      self.directory = directory
      directoryFD = fd; directoryIdentity = identity
      lock.lock(); directoryPath = actualPath; lock.unlock()
    }
  }
  private func write(_ spans: [ReadySpan], amount: UInt64, fileCount: Int,
    isLive: @Sendable () -> Bool) throws -> [PrefixKVSpan] {
    do { try prepareDirectory(isLive: isLive) }
    catch { releaseReservation(amount, files: fileCount); throw error }
    // A sliding window can retire its own files even while full-attention
    // history remains. Still one admitted raw cohort and one utility job.
    let groups = Dictionary(grouping: spans, by: \.layer)
    var remainingBytes = amount, remainingFiles = fileCount
    var result: [PrefixKVSpan] = []
    for layer in groups.keys.sorted() {
      let group = groups[layer]!
      let layerBytes = try chargedBytes(group)
      remainingBytes -= layerBytes; remainingFiles -= 1
      do { result.append(contentsOf: try writeLayer(group, amount: layerBytes, isLive: isLive)) }
      catch {
        // This layer owns its cleanup; earlier files leave through their real
        // last references, and groups never started have no files to unlink.
        releaseReservation(remainingBytes, files: remainingFiles)
        throw error
      }
    }
    guard isLive() else { throw CancellationError() }
    return result
  }
  private func writeLayer(_ spans: [ReadySpan], amount: UInt64,
    isLive: @Sendable () -> Bool) throws -> [PrefixKVSpan] {
    guard isLive() else { releaseReservation(amount); throw CancellationError() }
    guard let directory else { releaseReservation(amount); throw BoomError.invalid("Disposable KV directory is absent.") }
    let url = directory.appendingPathComponent(UUID().uuidString + ".kv")
    var fd = openat(directoryFD, url.lastPathComponent,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { releaseReservation(amount); throw Self.ioError() }
    lock.lock(); createdFiles &+= 1; lock.unlock()
    var calls: UInt64 = 0, payloadWritten: UInt64 = 0
    defer {
      lock.lock(); writeCalls &+= calls; writtenBytes &+= payloadWritten; lock.unlock()
    }
    let wrote: (Int) -> Void = { count in calls &+= 1; payloadWritten &+= UInt64(max(0, count)) }
    var published = false
    defer {
      if fd >= 0 { _ = Darwin.close(fd) }
      if !published {
        // Unlink is on the worker; retain quota on a genuine refusal.
        if Darwin.unlinkat(directoryFD, url.lastPathComponent, 0) == 0 || errno == ENOENT { releaseReservation(amount) }
      }
    }
    var offset: UInt64 = 0
    let logicalAmount = spans.reduce(UInt64(0)) { $0 + $1.byteCount }
    let sealed = protection.map { SealedBlockWriter(fd: fd, total: logicalAmount,
      binding: url.lastPathComponent, cipher: $0, wrote: wrote) }
    var records: [(ReadySpan, UInt64, UInt64)] = []
    for span in spans {
      let keysOffset = offset
      try Self.writeArray(span.keys, positions: span.positions, rows: span.rows, fd: fd, offset: &offset, isLive: isLive, wrote: wrote, sealed: sealed)
      let valuesOffset = offset
      try Self.writeArray(span.values, positions: span.positions, rows: span.rows, fd: fd, offset: &offset, isLive: isLive, wrote: wrote, sealed: sealed)
      records.append((span, keysOffset, valuesOffset))
    }
    guard isLive() else { throw CancellationError() }
    try sealed?.finish()
    guard offset == logicalAmount, fchmod(fd, 0o400) == 0 else { throw Self.ioError() }
    var identity = stat()
    guard fstat(fd, &identity) == 0, identity.st_size == Int64(amount) else { throw Self.ioError() }
    let closed = Darwin.close(fd); fd = -1
    guard closed == 0 else { throw Self.ioError() }
    let file = PrefixKVDiskFile(store: self, url: url, bytes: amount, identity: identity, logicalBytes: logicalAmount)
    published = true // file now owns quota/unlink, including construction failure
    let values = try records.map { span, keys, values in
      try PrefixKVSpan(disk: file, offset: span.start, layer: span.layer,
        keyShape: [span.rows.count, span.keys.shape[1], span.count, span.keys.shape[3]],
        valueShape: [span.rows.count, span.values.shape[1], span.count, span.values.shape[3]],
        keyType: span.keys.dtype, valueType: span.values.dtype,
        keysOffset: keys, valuesOffset: values)
    }
    return values
  }
  private static func writeArray(_ source: MLXReadyBuffer, positions: Range<Int>, rows: Range<Int>,
    fd: Int32, offset: inout UInt64, isLive: @Sendable () -> Bool, wrote: (Int) -> Void, sealed: SealedBlockWriter?) throws {
    try source.withUnsafeBytes { bytes in
      let item = source.dtype.size, shape = source.shape, strides = source.strides
      if strides[3] == 1, strides[2] == shape[3] {
        let length = positions.count * shape[3] * item
        for row in rows { for head in 0..<shape[1] {
          let start = source.byteOffset + (row * strides[0] + head * strides[1]
            + positions.lowerBound * strides[2]) * item
          var done = 0
          while done < length {
            guard isLive() else { throw CancellationError() }
            let count = min(65_536, length - done)
            try writeAll(fd, bytes.baseAddress!.advanced(by: start + done), count, offset: &offset, wrote: wrote, sealed: sealed)
            done += count
          }
        } }
        return
      }
      // One bounded scratch block handles non-contiguous feature strides.
      var scratch = [UInt8](repeating: 0, count: 65_536)
      for row in rows { for head in 0..<shape[1] { for position in positions {
        var feature = 0
        while feature < shape[3] {
          guard isLive() else { throw CancellationError() }
          let count = min(scratch.count / item, shape[3] - feature), length = count * item
          let start = source.byteOffset + (row * strides[0] + head * strides[1]
            + position * strides[2] + feature * strides[3]) * item
          if strides[3] == 1 {
            try writeAll(fd, bytes.baseAddress!.advanced(by: start), length, offset: &offset, wrote: wrote, sealed: sealed)
          } else {
            try scratch.withUnsafeMutableBytes { destination in
              for index in 0..<count {
                destination.baseAddress!.advanced(by: index * item).copyMemory(
                  from: bytes.baseAddress!.advanced(by: start + index * strides[3] * item), byteCount: item)
              }
              try writeAll(fd, destination.baseAddress!, length, offset: &offset, wrote: wrote, sealed: sealed)
            }
          }
          feature += count
        }
      } } }
    }
  }
  private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int,
    offset: inout UInt64, wrote: (Int) -> Void, sealed: SealedBlockWriter?) throws {
    if let sealed { try sealed.append(bytes, count: count); offset += UInt64(count); return }
    var done = 0
    while done < count {
      let n = pwrite(fd, bytes.advanced(by: done), count - done, off_t(offset))
      wrote(n)
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { throw ioError() }
      done += n; offset += UInt64(n)
    }
  }
  fileprivate static func ioError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  fileprivate func openFile(_ url: URL) -> Int32 {
    openat(directoryFD, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  }
}

/// Immutable file ownership is shared across rows/entries. There is no RAM mirror.
final class PrefixKVDiskFile: @unchecked Sendable {
  let id = UUID()
  private let store: PrefixKVDiskStore
  let url: URL
  private let bytes: UInt64
  private let logicalBytes: UInt64
  private let identity: stat
  init(store: PrefixKVDiskStore, url: URL, bytes: UInt64, identity: stat, logicalBytes: UInt64? = nil) {
    self.store = store; self.url = url; self.bytes = bytes; self.identity = identity
    self.logicalBytes = logicalBytes ?? bytes
  }
  deinit { store.remove(url, bytes: bytes) }
  func read(offset: UInt64, shape: [Int], dtype: DType, row: Int,
    positions: Range<Int>) throws -> MLXArray {
    var fd = store.openFile(url)
    guard fd >= 0 else { throw PrefixKVDiskStore.ioError() }
    defer { if fd >= 0 { _ = Darwin.close(fd) } }
    func admit() throws {
      var actual = stat()
      guard fstat(fd, &actual) == 0, actual.st_mode & S_IFMT == S_IFREG,
        actual.st_uid == getuid(), actual.st_dev == identity.st_dev, actual.st_ino == identity.st_ino,
        actual.st_size == identity.st_size, actual.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
        actual.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
        actual.st_mode & 0o777 == 0o400 else { throw BoomError.invalid("Disposable KV file changed.") }
    }
    try admit()
    guard shape.count == 4, row >= 0, row < shape[0], positions.lowerBound >= 0,
      !positions.isEmpty, positions.upperBound <= shape[2] else {
      throw BoomError.invalid("Invalid disposable KV range.")
    }
    let rowBytes = try PrefixKVDiskStore.arrayBytes([1] + Array(shape.dropFirst()),
      positions: positions.count, type: dtype)
    let fullBytes = try PrefixKVDiskStore.arrayBytes(shape, positions: shape[2], type: dtype)
    guard offset <= logicalBytes, UInt64(fullBytes) <= logicalBytes - offset else {
      throw BoomError.invalid("Disposable KV array exceeds its file.")
    }
    var data = Data(count: rowBytes)
    try data.withUnsafeMutableBytes { output in
      let length = positions.count * shape[3] * dtype.size
      for head in 0..<shape[1] {
        let start = offset + UInt64(((row * shape[1] + head) * shape[2]
          + positions.lowerBound) * shape[3] * dtype.size)
        guard start <= logicalBytes, UInt64(length) <= logicalBytes - start else {
          throw BoomError.invalid("Disposable KV range exceeds its file.")
        }
        if let cipher = store.protection {
          let plaintext = try SealedBlockWriter.read(fd, start: start, count: length,
            total: logicalBytes, binding: url.lastPathComponent, cipher: cipher)
          plaintext.withUnsafeBytes { input in
            output.baseAddress!.advanced(by: head * length).copyMemory(from: input.baseAddress!, byteCount: length)
          }
          continue
        }
        var done = 0
        while done < length {
          let n = pread(fd, output.baseAddress!.advanced(by: head * length + done),
            min(65_536, length - done), off_t(start + UInt64(done)))
          if n < 0, errno == EINTR { continue }
          guard n > 0 else { throw PrefixKVDiskStore.ioError() }
          done += n
        }
      }
    }
    try admit()
    let closed = Darwin.close(fd); fd = -1
    guard closed == 0 else { throw PrefixKVDiskStore.ioError() }
    // Native dtype initializer copies raw bit patterns, never casts to UInt8.
    return MLXArray(data, [1, shape[1], positions.count, shape[3]], dtype: dtype)
  }
}

/// A failed disposable backing is excluded only from this lookup. Surviving
/// earlier prefixes remain eligible. Keep the actual IO/refusal error intact.
struct PrefixKVDiskUnavailable: Error {
  let fileID: UUID
  let original: Error
}
