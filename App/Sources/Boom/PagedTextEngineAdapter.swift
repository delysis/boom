import BoomCore
import CAttachment
import Darwin
import Foundation
import Synchronization

/// Cancellation never calls back into Rust or takes the storage queue's lock.
final class PagedTextCancellation: Sendable {
  private let flag = Atomic(false)
  func cancel() { flag.store(true, ordering: .relaxed) }
  var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

struct PagedTextCacheStats: Decodable, Sendable {
  let chargedBytes: Int
  let entries: Int
  let pageReads: UInt64
  let readBytes: UInt64
  let pageWrites: UInt64
  let cacheHits: UInt64
}
struct PagedDocumentStorageStatistics: Sendable {
  let file: PagedTextFileStore.FileExtent
  let sourceBytes: UInt64
  let undoRoots: Int
  let redoRoots: Int
}
struct PagedTextImportedRevision: Decodable, Sendable {
  let revision: PagedTextRevision
  /// A separately streamed whole-source SHA256, never a paged root identity.
  let wholeTextSha256: String
}
struct PagedTextBulkProgress: Decodable, Sendable {
  let processedBytes: UInt64
  let validatedBytes: UInt64
  let complete: Bool
}
private struct PagedTextCleanupFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? { "\(original.localizedDescription) Cleanup failed: \(cleanup.localizedDescription)" }
}
private struct PagedReadMetadata: Decodable {
  private enum CodingKeys: String, CodingKey { case ownerID = "ownerId", documentID = "documentId", kind, page, maximumBytes }
  let ownerID: UUID
  let documentID: UUID
  let kind: String
  let page: PagedTextPageRef
  let maximumBytes: Int
}
private struct PagedWriteMetadata: Decodable {
  private enum CodingKeys: String, CodingKey { case ownerID = "ownerId", documentID = "documentId", kind }
  let ownerID: UUID
  let documentID: UUID
  let kind: String
}

private final class PagedLogicalCommandHandle: @unchecked Sendable {
  private(set) var pointer: OpaquePointer?
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  func release() { if let pointer { bloom_logical_command_free(pointer); self.pointer = nil } }
  deinit { release() }
}
/// One borrowed document route on the existing engine queue.
private final class PagedTextPageRouter {
  let ownerID: UUID
  var store: PagedTextFileStore?
  private var activeDocument: UUID?
  private var permitsWrites = false
  private var writeAdmission: (() throws -> Void)?
  var failure: Error?
  init(ownerID: UUID) { self.ownerID = ownerID }
  func files() throws -> PagedTextFileStore {
    guard let store else { throw BoomError.unavailable("Document files are closed.") }; return store
  }
  func begin(document: UUID?, writes: Bool, beforeWrite: (() throws -> Void)? = nil) throws {
    guard !Thread.isMainThread, activeDocument == nil, !writes || beforeWrite != nil else {
      throw BoomError.denied("Page callback lost its captured storage route.")
    }
    activeDocument = document; permitsWrites = writes; writeAdmission = beforeWrite; failure = nil
  }
  func end() { activeDocument = nil; permitsWrites = false; writeAdmission = nil }
  func provider(owner: UUID, document: UUID, writing: Bool) throws -> any PagedTextDocumentPages {
    guard !Thread.isMainThread, owner == ownerID, document == activeDocument,
      !writing || permitsWrites else { throw BoomError.denied("Page callback has another source.") }
    if writing { try writeAdmission?() }
    return try files().documentPages(document)
  }
  func failed(_ error: Error) { if failure == nil { failure = error } }
  static func kind(_ name: String) throws -> PagedTextPageKind {
    switch name { case "text": return .text; case "index": return .index; default: throw BoomError.invalid("Unknown page kind.") }
  }
}
private let pagedPageRead: BloomTextPageRead = { context, metadata, metadataCount, output, capacity, written in
  guard let context, let written else { return 1 }
  written.pointee = 0
  let router = Unmanaged<PagedTextPageRouter>.fromOpaque(context).takeUnretainedValue()
  do {
    guard let metadata, metadataCount > 0, metadataCount <= 4_096, capacity > 0,
      capacity <= 65_536, let output else { throw BoomError.invalid("Invalid bounded page-read callback.") }
    let request = try JSONDecoder().decode(PagedReadMetadata.self, from: Data(bytes: metadata, count: metadataCount))
    let kind = try PagedTextPageRouter.kind(request.kind)
    guard request.maximumBytes > 0, request.maximumBytes <= kind.maximumBytes, request.maximumBytes <= capacity else {
      throw BoomError.budget("Page-read callback exceeds its captured capacity.")
    }
    let store = try router.provider(owner: request.ownerID, document: request.documentID, writing: false)
    let bytes = try store.read(ownerID: request.ownerID, documentID: request.documentID, kind: kind,
      page: request.page, maximumPlaintextBytes: request.maximumBytes)
    try pagedCopy(bytes, to: output, capacity: capacity, written: written)
    return 0
  } catch { router.failed(error); return 1 }
}
/// This callback borrows only immutable file extents on the read worker. It
/// never shares the mutable writer router, activeCustody or store counters.
private final class PagedImmutableScrollReadContext {
  let root: URL
  let ownerID: UUID
  let storeID: UUID
  let documentID: UUID
  let cancellation: PagedTextCancellation
  var failure: Error?
  init(root: URL, ownerID: UUID, storeID: UUID, documentID: UUID,
    cancellation: PagedTextCancellation) {
    self.root = root; self.ownerID = ownerID; self.storeID = storeID
    self.documentID = documentID; self.cancellation = cancellation
  }
}
private let pagedImmutableScrollRead: BloomTextPageRead = { context, metadata, count, output, capacity, written in
  guard let context, let written else { return 1 }
  written.pointee = 0
  let reader = Unmanaged<PagedImmutableScrollReadContext>.fromOpaque(context).takeUnretainedValue()
  do {
    if reader.cancellation.isCancelled { throw CancellationError() }
    guard let metadata, (1...4_096).contains(count), let output, (1...65_536).contains(capacity) else {
      throw BoomError.invalid("Invalid immutable page callback.")
    }
    let request = try JSONDecoder().decode(PagedReadMetadata.self, from: Data(bytes: metadata, count: count))
    let kind = try PagedTextPageRouter.kind(request.kind)
    guard request.ownerID == reader.ownerID, request.documentID == reader.documentID,
      request.maximumBytes > 0, request.maximumBytes <= kind.maximumBytes, request.maximumBytes <= capacity else {
      throw BoomError.denied("Immutable page read has another captured source.")
    }
    let bytes = try PagedTextFileStore.readImmutablePage(root: reader.root, storeID: reader.storeID,
      documentID: reader.documentID, kind: kind, page: request.page, maximumBytes: request.maximumBytes)
    try pagedCopy(bytes, to: output, capacity: capacity, written: written)
    return 0
  } catch { if reader.failure == nil { reader.failure = error }; return 1 }
}
private let pagedImmutableScrollCancelled: BloomTextCancelled = { context in
  guard let context else { return 1 }
  return Unmanaged<PagedImmutableScrollReadContext>.fromOpaque(context).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
}

private let pagedPageWrite: BloomTextPageWrite = { context, metadata, metadataCount, plaintext, plaintextCount, output, capacity, written in
  guard let context, let written else { return 1 }
  written.pointee = 0
  let router = Unmanaged<PagedTextPageRouter>.fromOpaque(context).takeUnretainedValue()
  do {
    guard let metadata, metadataCount > 0, metadataCount <= 4_096, plaintextCount >= 0,
      plaintextCount <= 65_536, plaintext != nil || plaintextCount == 0, let output, capacity > 0, capacity <= 4_096 else {
      throw BoomError.invalid("Invalid bounded page-write callback.")
    }
    let request = try JSONDecoder().decode(PagedWriteMetadata.self, from: Data(bytes: metadata, count: metadataCount))
    let kind = try PagedTextPageRouter.kind(request.kind)
    guard plaintextCount <= kind.maximumBytes else { throw BoomError.budget("Page-write callback exceeds its kind bound.") }
    let store = try router.provider(owner: request.ownerID, document: request.documentID, writing: true)
    let bytes = plaintextCount == 0 ? Data() : Data(bytes: plaintext!, count: plaintextCount)
    let locator = try store.writeNew(ownerID: request.ownerID, documentID: request.documentID, kind: kind, bytes: bytes)
    try pagedCopy(JSONEncoder().encode(locator), to: output, capacity: capacity, written: written)
    return 0
  } catch { router.failed(error); return 1 }
}
private func pagedCopy(_ bytes: Data, to output: UnsafeMutablePointer<UInt8>, capacity: Int,
  written: UnsafeMutablePointer<Int>) throws {
  guard bytes.count <= capacity else { throw BoomError.budget("Paged callback reply exceeds its capacity.") }
  bytes.withUnsafeBytes { buffer in
    if let source = buffer.bindMemory(to: UInt8.self).baseAddress, !buffer.isEmpty {
      output.update(from: source, count: buffer.count)
    }
  }
  written.pointee = bytes.count
}

/// Retained by one async bulk owner across its steps. Every C call borrows this
/// context only until return. One async owner transfers exclusive access
/// between its utility I/O worker and the serialized memory-only callbacks.
private final class PagedTextOperationContext: @unchecked Sendable {
  let cancellation: PagedTextCancellation
  private let stream: FileHandle?
  private let initial: stat?
  private let importing: Bool
  private var offset: Int64 = 0
  private var fileOffset: Int64 = 0
  private var staged = Data()
  private var stagedOffset = 0
  var failure: Error?
  var expectedBytes: UInt64? { importing ? initial.map { UInt64($0.st_size) } : nil }
  var streamBytesTransferred: UInt64? { stream == nil ? nil : UInt64(offset) }
  var hasInput: Bool { stream != nil && importing }
  var hasOutput: Bool { stream != nil && !importing }
  var needsInputRead: Bool { importing && stagedOffset == staged.count && fileOffset < (initial?.st_size ?? 0) }
  var needsOutputFlush: Bool { !importing && !staged.isEmpty }

  init(cancellation: PagedTextCancellation, file: FileHandle? = nil, importing: Bool = false) throws {
    self.cancellation = cancellation; self.importing = importing
    guard let file else { stream = nil; initial = nil; return }
    let descriptor = fcntl(file.fileDescriptor, F_DUPFD_CLOEXEC, 0)
    guard descriptor >= 0 else { throw BoomError.invalid("Could not retain the owned text stream.") }
    let retained = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
      importing || (info.st_size == 0 && info.st_nlink == 1) else {
      throw BoomError.invalid("Text streams require a regular input or a fresh owned output.")
    }
    stream = retained; initial = info
  }
  func read(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> Int {
    try checkCancellation()
    guard importing, stream != nil, let initial, capacity > 0, capacity <= 65_536 else {
      throw BoomError.invalid("Text import has no bounded stream.")
    }
    if offset == initial.st_size { return 0 }
    let count = min(capacity, staged.count - stagedOffset)
    guard count > 0 else { throw BoomError.invalid("Text import step has no prepared input.") }
    staged.withUnsafeBytes { buffer in
      bytes.update(from: buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: stagedOffset), count: count)
    }
    stagedOffset += count; offset += Int64(count); return count
  }
  func write(_ bytes: UnsafePointer<UInt8>, count: Int) throws -> Int {
    try checkCancellation()
    guard !importing, stream != nil, count > 0, count <= 65_536,
      !offset.addingReportingOverflow(Int64(count)).overflow else {
      throw BoomError.invalid("Text export has no bounded owned stream.")
    }
    let admitted = min(count, 65_536 - staged.count)
    guard admitted > 0 else { throw BoomError.invalid("Text export step exceeds its staging budget.") }
    staged.append(bytes, count: admitted)
    offset += Int64(admitted); return admitted
  }
  /// External files can live on a slow volume. Read one bounded chunk outside
  /// the engine queue; the next C callback only copies these resident bytes.
  func prepareInput() throws {
    try checkCancellation()
    guard importing, let stream, let initial else { return }
    guard stagedOffset == staged.count else { return }
    staged.removeAll(keepingCapacity: true); stagedOffset = 0
    guard fileOffset < initial.st_size else { return }
    let count = Int(min(65_536, initial.st_size - fileOffset))
    var buffer = Data(count: count)
    let read = try buffer.withUnsafeMutableBytes { bytes in
      try boundedIO { pread(stream.fileDescriptor, bytes.baseAddress, count, fileOffset) }
    }
    guard read > 0, read <= count else { throw BoomError.stale("Text import changed or ended before its captured size.") }
    buffer.count = read; staged = buffer; fileOffset += Int64(read)
  }
  /// One step's <=64 KiB output is drained before that stream advances. Slow
  /// writes never hold the engine lock or the foreground storage executor.
  func flushOutput() throws {
    try checkCancellation()
    guard !importing, let stream else { return }
    while stagedOffset < staged.count {
      let count = staged.count - stagedOffset
      let written = try staged.withUnsafeBytes { bytes in
        try boundedIO { pwrite(stream.fileDescriptor, bytes.baseAddress!.advanced(by: stagedOffset), count, fileOffset) }
      }
      guard written > 0, written <= count else { throw BoomError.unavailable("Could not write the owned text export.") }
      stagedOffset += written; fileOffset += Int64(written)
    }
    staged.removeAll(keepingCapacity: true); stagedOffset = 0
  }
  func finish() throws {
    try checkCancellation()
    guard let stream, let initial else { return }
    var after = stat()
    guard fstat(stream.fileDescriptor, &after) == 0, initial.st_dev == after.st_dev, initial.st_ino == after.st_ino,
      after.st_mode & S_IFMT == S_IFREG else { throw BoomError.stale("Owned text stream changed during execution.") }
    if importing {
      guard offset == initial.st_size, fileOffset == offset, stagedOffset == staged.count,
        initial.st_size == after.st_size,
        initial.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
        throw BoomError.stale("Text import changed during execution; unpublished pages retained.")
      }
    } else {
      guard staged.isEmpty, fileOffset == offset, after.st_nlink == 1,
        after.st_size == offset else { throw BoomError.stale("Owned export has unexpected writes.") }
      try stream.synchronize()
    }
  }
  private func checkCancellation() throws { if cancellation.isCancelled { throw CancellationError() } }
  private func boundedIO(_ operation: () -> Int) throws -> Int {
    for _ in 0..<4 {
      try checkCancellation()
      let result = operation()
      if result >= 0 || errno != EINTR { return result }
    }
    throw BoomError.unavailable("The owned text stream was repeatedly interrupted.")
  }
}
private let pagedStreamRead: BloomTextStreamRead = { context, output, capacity, written in
  guard let context, let output, let written else { return 1 }
  written.pointee = 0
  let operation = Unmanaged<PagedTextOperationContext>.fromOpaque(context).takeUnretainedValue()
  do { written.pointee = try operation.read(into: output, capacity: capacity); return 0 }
  catch { operation.failure = error; return 1 }
}
private let pagedStreamWrite: BloomTextStreamWrite = { context, input, count, written in
  guard let context, let input, let written else { return 1 }
  written.pointee = 0
  let operation = Unmanaged<PagedTextOperationContext>.fromOpaque(context).takeUnretainedValue()
  do { written.pointee = try operation.write(input, count: count); return 0 }
  catch { operation.failure = error; return 1 }
}
private let pagedCancelled: BloomTextCancelled = { context in
  guard let context else { return 1 }
  return Unmanaged<PagedTextOperationContext>.fromOpaque(context).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
}


/// One file source engine and bounded cache on the existing executor.
final class PagedTextEngineAdapter: @unchecked Sendable {
  private struct Request: Encodable, Sendable {
    private enum CodingKeys: String, CodingKey {
      case op, revision, retained, tree, byteStart, byteEnd, maximumBytes, oldText, newText
      case ownerID = "ownerId", documentID = "documentId", utf16Offset
      case operationID = "operationId", expectedBytes, forward, includeLineEndings, utf16Start, utf16End, prefix
    }
    let op: String
    var revision: PagedTextRevision?
    var retained: PagedTextRevision?
    var tree: PagedTextTreeRef?
    var byteStart: UInt64?
    var byteEnd: UInt64?
    var maximumBytes: Int?
    var oldText: String?
    var newText: String?
    var ownerID: UUID?
    var documentID: UUID?
    var utf16Offset: UInt64?
    var operationID: UUID?
    var expectedBytes: UInt64?
    var forward: Bool?
    var includeLineEndings: Bool?
    var utf16Start: UInt64?
    var utf16End: UInt64?
    var prefix: String?
  }
  private struct Envelope<T: Decodable>: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    let schema: Int
    let ok: Bool
    let value: T?
    let error: Failure?
  }
  let ownerID: UUID
  private let sourceRoot: URL
  private let sourceStoreID: UUID
  private let rootCustody: PagedTextRootCustody
  var custodyIncarnation: UUID { rootCustody.engineIncarnation }
  var custodySnapshot: PagedTextRootCustody.Snapshot { rootCustody.snapshot }
  private let executor = PagedTextStorageExecutor()
  // Test code can hold this actual writer executor; no production hold/hook.
  var storageExecutorForTesting: PagedTextStorageExecutor { executor }
  // One ephemeral <=256KiB reader cache at a time, separate from writer fsync.
  // Existing Root job/count/buffer admission bounds this queue before enqueue.
  private let scrollReadQueue = DispatchQueue(label: "com.delysis.Bloom.paged-scroll-read", qos: .userInitiated)
  private var queue: DispatchQueue { executor.queue }
  private static let streamIOQueue = DispatchQueue(label: "com.delysis.Bloom.paged-stream-io", qos: .utility, attributes: .concurrent)
  private let router: PagedTextPageRouter
  private var handle: UInt64 = 0
  private var hostContext: UnsafeMutableRawPointer?
  private var activeCustody: PagedTextRootLease?
  private var filesClosed = false
  private init(root: URL, ownerID: UUID, storeID: UUID) {
    self.sourceRoot = root; self.sourceStoreID = storeID
    self.ownerID = ownerID; rootCustody = PagedTextRootCustody(ownerID: ownerID)
    router = PagedTextPageRouter(ownerID: ownerID)
  }
  static func create(root: URL, ownerID: UUID, storeID: UUID) async throws -> PagedTextEngineAdapter {
    let adapter = PagedTextEngineAdapter(root: root, ownerID: ownerID, storeID: storeID)
    try await adapter.onQueue {
      let context = Unmanaged.passRetained(adapter.router).toOpaque()
      let host = BloomTextHost(schema: 3, context: context, read_page: pagedPageRead, write_page: pagedPageWrite)
      let handle = bloom_text_create(host)
      guard handle != 0 else { Unmanaged<PagedTextPageRouter>.fromOpaque(context).release(); throw BoomError.unavailable("The process text engine is already open.") }
      adapter.hostContext = context; adapter.handle = handle
      do { adapter.router.store = try PagedTextFileStore(root: root, ownerID: ownerID, storeID: storeID, queue: adapter.queue) }
      catch {
        guard bloom_text_close(handle) == 1 else { throw PagedTextCleanupFailure(original: error, cleanup: BoomError.unavailable("Text engine setup did not close.")) }
        adapter.handle = 0; adapter.hostContext = nil; Unmanaged<PagedTextPageRouter>.fromOpaque(context).release(); throw error
      }
    }
    return adapter
  }
  deinit {
    if handle != 0, bloom_text_close(handle) == 1, let context = hostContext {
      Unmanaged<PagedTextPageRouter>.fromOpaque(context).release()
    }
  }
  func close() async throws {
    try rootCustody.beginCloseIfEmpty()
    try await executor.beginClose()
    defer { executor.endCloseAttempt() }
    try await onQueue(priority: .lifecycle) {
      try self.rootCustody.requireEmptyForClose()
      if !self.filesClosed { try self.router.files().close(); self.filesClosed = true }
      guard self.handle != 0 else { return }
      guard bloom_text_close(self.handle) == 1 else { throw BoomError.unavailable("The text engine still owns entered work.") }
      self.handle = 0
      if let context = self.hostContext { self.hostContext = nil; Unmanaged<PagedTextPageRouter>.fromOpaque(context).release() }
      self.router.store = nil
    }
  }
  /// A captured source is pinned BEFORE yielding and borrowed only on the
  /// independent existing read worker. The job joins before copied results
  /// return; it never borrows the mutable writer router or activeCustody.
  private func logicalRead<T: Sendable>(_ snapshot: PagedNativeLogicalSnapshot, payloadBytes: Int,
    cancellation supplied: CancellationFlag,
    body: @escaping @Sendable (BloomTextHost, BloomTextOperation) throws -> T) async throws -> T {
    guard snapshot.engineIncarnation == custodyIncarnation, snapshot.sourceRevision.ownerID == ownerID,
      (0...PagedTextWindow.maximumBytes).contains(payloadBytes) else {
      throw BoomError.stale("Logical read crossed its actual source owner or bounded buffer.")
    }
    try supplied.check()
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.source(snapshot.sourceRevision), .writerDocument(snapshot.sourceRevision.documentID)], payloadBytes: payloadBytes)
    let cancellation = PagedTextCancellation()
    let registration = supplied.onCancel { cancellation.cancel() }
    defer { supplied.removeCancellationHandler(registration) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        scrollReadQueue.async { [self] in
          do {
            try rootCustody.start(lease); try supplied.check()
            let result = try autoreleasepool {
              let reader = PagedImmutableScrollReadContext(root: sourceRoot, ownerID: ownerID,
                storeID: sourceStoreID, documentID: snapshot.sourceRevision.documentID, cancellation: cancellation)
              let pointer = Unmanaged.passUnretained(reader).toOpaque()
              let host = BloomTextHost(schema: 3, context: pointer, read_page: pagedImmutableScrollRead, write_page: nil)
              let operation = BloomTextOperation(context: pointer, read_stream: nil, write_stream: nil, is_cancelled: pagedImmutableScrollCancelled)
              do {
                let value = try withExtendedLifetime((snapshot, reader)) { try body(host, operation) }
                if let failure = reader.failure { throw failure }; return value
              } catch { throw reader.failure ?? error }
            }
            try supplied.check(); try rootCustody.finishRead(lease)
            continuation.resume(returning: result)
          } catch {
            do {
              if try rootCustody.joinedFailure(lease, error: error) {
                continuation.resume(throwing: PagedTextCustodyFailure(original: error, lease: lease))
              } else { continuation.resume(throwing: error) }
            } catch let handoff {
              continuation.resume(throwing: PagedTextCustodyHandoffFailure(original: error, handoff: handoff, lease: lease))
            }
          }
        }
      }
    } onCancel: { supplied.cancel() }
  }
  func logicalWindow(_ snapshot: PagedNativeLogicalSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int, cancellation: CancellationFlag = CancellationFlag()) async throws -> PagedNativeLogicalWindow {
    guard (4...PagedWorkingWindow.hardBytes).contains(maximumBytes), utf16Anchor <= snapshot.summary.utf16 else {
      throw BoomError.invalid("Logical window is outside its bounded source.")
    }
    return try await logicalRead(snapshot, payloadBytes: maximumBytes, cancellation: cancellation) { host, operation in
      var output: OpaquePointer?, error = BoomAttachmentBuffer(data: nil, length: 0)
      try pagedLogicalResult(bloom_logical_read_window(host, snapshot.pointer, utf16Anchor, maximumBytes, operation, &output, &error), error)
      guard let output else { throw BoomError.invalid("Logical reader returned no real island.") }
      let window = try PagedNativeLogicalWindow(taking: output, sourceRevision: snapshot.sourceRevision,
        sessionID: snapshot.sessionID, engineIncarnation: snapshot.engineIncarnation)
      guard window.snapshot.isSame(snapshot) else { throw BoomError.invalid("Logical reader changed its immutable source.") }
      return window
    }
  }
  /// rounding is 0 for every explicit source endpoint, 1/2 only for generated
  /// native movement anchors which may land inside a UTF16 surrogate pair.
  func logicalPosition(_ snapshot: PagedNativeLogicalSnapshot, utf16Offset: UInt64,
    rounding: UInt8 = 0, cancellation: CancellationFlag = CancellationFlag()) async throws -> PagedTextSummary {
    guard utf16Offset <= snapshot.summary.utf16, rounding <= 2 else { throw BoomError.invalid("Invalid logical position.") }
    return try await logicalRead(snapshot, payloadBytes: 0, cancellation: cancellation) { host, operation in
      var point = BloomLogicalPoint(), error = BoomAttachmentBuffer(data: nil, length: 0)
      try pagedLogicalResult(bloom_logical_read_position(host, snapshot.pointer, utf16Offset, rounding, operation, &point, &error), error)
      return PagedTextSummary(bytes: point.bytes, utf16: point.utf16, lfCount: point.lf_count)
    }
  }
  func logicalBytes(_ snapshot: PagedNativeLogicalSnapshot, byteRange: Range<UInt64>,
    cancellation: CancellationFlag = CancellationFlag()) async throws -> Data {
    guard byteRange.upperBound <= snapshot.summary.bytes,
      let count = Int(exactly: byteRange.upperBound - byteRange.lowerBound), count <= PagedTextWindow.maximumBytes else {
      throw BoomError.invalid("Logical byte read exceeds its bounded source.")
    }
    return try await logicalRead(snapshot, payloadBytes: count, cancellation: cancellation) { host, operation in
      var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
      defer { if output.data != nil { boom_attachment_free(output) } }
      try pagedLogicalResult(bloom_logical_read_bytes(host, snapshot.pointer, byteRange.lowerBound, byteRange.upperBound,
        operation, &output, &error), error)
      guard output.length == count else { throw BoomError.invalid("Logical byte read returned an incomplete range.") }
      if count == 0 { return Data() }
      guard let bytes = output.data else { throw BoomError.invalid("Logical byte read lost its buffer.") }
      return Data(bytes: bytes, count: count)
    }
  }
  func exportLogical(_ snapshot: PagedNativeLogicalSnapshot, to file: FileHandle,
    byteRange suppliedRange: Range<UInt64>? = nil,
    cancellation: CancellationFlag = CancellationFlag()) async throws {
    let range = suppliedRange ?? 0..<snapshot.summary.bytes
    guard range.upperBound <= snapshot.summary.bytes else { throw BoomError.invalid("Logical export is outside its captured source.") }
    var at = range.lowerBound
    while at < range.upperBound {
      try cancellation.check()
      let end = at + min(65_536, range.upperBound - at)
      let bytes = try await logicalBytes(snapshot, byteRange: at..<end, cancellation: cancellation)
      try await detachedWork {
        try autoreleasepool {
          try cancellation.check()
          try file.write(contentsOf: bytes)
        }
      }
      at = end; await Task.yield()
    }
    try cancellation.check()
  }

  func logicalReplacement(_ snapshot: PagedNativeLogicalSnapshot, selection: PagedNativeNavigationSelection,
    replacement: Data, cancellation: CancellationFlag) async throws -> PagedNativeLogicalEdit {
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    guard !end.overflow, end.partialValue <= snapshot.summary.utf16,
      replacement.count <= PagedCapturedEditInput.maximumInputBytes else { throw BoomError.invalid("Logical replacement exceeds its actual source/input.") }
    return try await logicalRead(snapshot, payloadBytes: max(replacement.count, PagedWorkingWindow.targetBytes), cancellation: cancellation) { host, operation in
      var output: OpaquePointer?, cursor = BloomLogicalPoint(), changed: UInt8 = 0
      var error = BoomAttachmentBuffer(data: nil, length: 0)
      let status = replacement.withUnsafeBytes {
        bloom_logical_prepare_replacement(host, snapshot.pointer, selection.utf16Offset, end.partialValue,
          $0.bindMemory(to: UInt8.self).baseAddress, replacement.count, operation, &output, &cursor, &changed, &error)
      }
      try pagedLogicalResult(status, error)
      guard let output else { throw BoomError.invalid("Logical replacement returned no candidate.") }
      return try PagedNativeLogicalEdit(changed: changed != 0,
        window: PagedNativeLogicalWindow(taking: output, sourceRevision: snapshot.sourceRevision,
          sessionID: snapshot.sessionID, engineIncarnation: snapshot.engineIncarnation),
        cursor: PagedTextSummary(bytes: cursor.bytes, utf16: cursor.utf16, lfCount: cursor.lf_count))
    }
  }

  private func onLogicalReadQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      scrollReadQueue.async {
        do { continuation.resume(returning: try autoreleasepool(invoking: body)) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
  func prepareLogicalImportedSourceTransfer(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    controller: PagedTextRootLease, sessionID: UUID) throws -> () -> Void {
    try rootCustody.prepareImportedSourceTransfer(imported, controller: controller, sessionID: sessionID)
  }
  /// One captured derived operation. Index append quanta yield the existing
  /// background writer lane; cached-index queries use independent reads only.
  /// No fsync, native source adoption, or durable current-record CAS occurs.
  func logicalMarkup(_ window: PagedNativeLogicalWindow,
    cancellation: CancellationFlag = CancellationFlag(),
    latestWindow: (@MainActor @Sendable () -> PagedNativeLogicalWindow?)? = nil,
    onMode: (@MainActor @Sendable (UInt8, PagedNativeMarkupProjection.Mode) -> Void)? = nil) async throws -> PagedNativeMarkupProjection {
    let snapshot = window.snapshot
    guard snapshot.engineIncarnation == custodyIncarnation, snapshot.sourceRevision.ownerID == ownerID,
      window.summary.bytes <= UInt64(PagedWorkingWindow.hardBytes) else {
      throw BoomError.stale("Derived Markdown belongs to another source or window.")
    }
    try cancellation.check()
    let claims: [PagedTextRootClaim] = [.source(snapshot.sourceRevision), .writerDocument(snapshot.sourceRevision.documentID)]
    // One shared operation pin, not two maximum-sized independent reservations.
    // Both option modes retain bounded prefixes; all actual callbacks still run
    // on the existing serial queues, under this same entered source job.
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: claims,
      payloadBytes: 3_145_728)
    let token = PagedTextCancellation()
    let registration = cancellation.onCancel { token.cancel() }
    defer { cancellation.removeCancellationHandler(registration) }
    do {
      try rootCustody.start(lease)
      let (value, appendedIndex) = try await withTaskCancellationHandler {
        var target = window
        var appended = false
        while true {
          let queryWindow = target
          async let style = logicalMarkupModeResult(queryWindow, mode: 0, cancellation: cancellation,
            token: token, lease: lease, latestWindow: latestWindow, onMode: onMode)
          async let media = logicalMarkupModeResult(queryWindow, mode: 1, cancellation: cancellation,
            token: token, lease: lease, latestWindow: latestWindow, onMode: onMode)
          let (styleResult, mediaResult) = await (style, media)
          // Both actual commands have joined. Cancellation of a sibling is a
          // consequence, never a replacement for the original failing mode.
          if case .failure(let error) = styleResult, !(error is CancellationError) { throw error }
          if case .failure(let error) = mediaResult { throw error }
          let styled = try styleResult.get(), linked = try mediaResult.get()
          appended = appended || styled.appendedIndex || linked.appendedIndex
          try cancellation.check()
          let latest = await latestWindow?() ?? queryWindow
          guard latest.snapshot.isSame(snapshot) else { throw CancellationError() }
          if styled.value.matches(latest) && linked.value.matches(latest) {
            return (PagedNativeMarkupProjection(style: styled.value, media: linked.value), appended)
          }
          // A mode may have already joined before a new same-source target.
          // Its exact index is now cached; requery under this SAME source pin.
          target = latest
          await Task.yield()
        }
      } onCancel: { cancellation.cancel() }
      try cancellation.check()
      // Structured children have joined every entered callback and freed both
      // commands before the sole source pin is released.
      if appendedIndex {
        try await onQueue(priority: .cleanup, custody: lease) {
          try self.rootCustody.finishOutput(lease, claims: claims, payloadBytes: 0, inFlightWitness: self.inFlightWitness)
          try self.rootCustody.abandonJoined(lease)
        }
      } else { try rootCustody.finishRead(lease) }
      return value
    } catch {
      cancellation.cancel()
      if try rootCustody.joinedFailure(lease, error: error) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }
  private func logicalMarkupModeResult(_ window: PagedNativeLogicalWindow, mode: UInt8,
    cancellation: CancellationFlag, token: PagedTextCancellation, lease: PagedTextRootLease,
    latestWindow: (@MainActor @Sendable () -> PagedNativeLogicalWindow?)?,
    onMode: (@MainActor @Sendable (UInt8, PagedNativeMarkupProjection.Mode) -> Void)?) async
    -> Result<(value: PagedNativeMarkupProjection.Mode, appendedIndex: Bool), Error> {
    do {
      return .success(try await logicalMarkupMode(window, mode: mode, cancellation: cancellation,
        token: token, lease: lease, latestWindow: latestWindow, onMode: onMode))
    } catch { return .failure(error) }
  }
  private func logicalMarkupMode(_ window: PagedNativeLogicalWindow, mode: UInt8,
    cancellation: CancellationFlag, token: PagedTextCancellation, lease: PagedTextRootLease,
    latestWindow: (@MainActor @Sendable () -> PagedNativeLogicalWindow?)?,
    onMode: (@MainActor @Sendable (UInt8, PagedNativeMarkupProjection.Mode) -> Void)?) async throws -> (value: PagedNativeMarkupProjection.Mode, appendedIndex: Bool) {
    let snapshot = window.snapshot
    var retained: PagedLogicalMarkupHandle?
    do {
      let command: PagedLogicalMarkupHandle = try await onLogicalReadQueue {
        try cancellation.check()
        var pointer: OpaquePointer?, error = BoomAttachmentBuffer(data: nil, length: 0)
        try pagedLogicalResult(bloom_logical_markup_begin(window.pointer, mode, &pointer, &error), error)
        guard let pointer else { throw BoomError.invalid("Derived Markdown returned no continuation.") }
        return PagedLogicalMarkupHandle(pointer)
      }
      retained = command
      struct Progress: Decodable, Sendable { let complete: Bool; let final: Bool; let needsWriter: Bool; let bufferedBytes: Int }
      var writer = true
      var appendedIndex = false
      // A ready cached index needs no writer. Querying first returns only the
      // current immutable progress when a cold builder has not yet entered.
      let initial: Progress = try await logicalRead(snapshot, payloadBytes: 0, cancellation: cancellation) { host, operation in
        var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
        defer { if output.data != nil { boom_attachment_free(output) } }
        try pagedLogicalResult(bloom_logical_markup_step(host, command.pointer, operation, &output, &error), error)
        guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid derived Markdown progress.") }
        return try JSONDecoder().decode(Progress.self, from: Data(bytes: bytes, count: output.length))
      }
      writer = initial.needsWriter
      var complete = initial.complete
      var final = initial.final
      var value: PagedNativeMarkupProjection.Mode?
      var currentWindow = window
      while true {
        if let latest = await latestWindow?(), latest.windowID != currentWindow.windowID {
          try cancellation.check()
          guard latest.snapshot.isSame(snapshot), latest.summary.bytes <= UInt64(PagedWorkingWindow.hardBytes) else {
            throw CancellationError()
          }
          let rebound: Progress = try await onLogicalReadQueue {
            try cancellation.check()
            var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
            defer { if output.data != nil { boom_attachment_free(output) } }
            let status = withExtendedLifetime(latest) {
              bloom_logical_markup_bind_window(command.pointer, latest.pointer, &output, &error)
            }
            try pagedLogicalResult(status, error)
            guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid derived-window rebind progress.") }
            return try JSONDecoder().decode(Progress.self, from: Data(bytes: bytes, count: output.length))
          }
          currentWindow = latest
          complete = rebound.complete; final = rebound.final; writer = rebound.needsWriter
        }
        let queryWindow = currentWindow
        if complete {
          let delivered: PagedNativeMarkupProjection.Mode = try await logicalRead(snapshot, payloadBytes: 0, cancellation: cancellation) { _, operation in
            try cancellation.check()
            var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
            defer { if output.data != nil { boom_attachment_free(output) } }
            try pagedLogicalResult(bloom_logical_markup_finish(command.pointer, operation, &output, &error), error)
            guard let bytes = output.data, (1...2_097_152).contains(output.length) else { throw BoomError.invalid("Invalid derived Markdown projection.") }
            let value = try JSONDecoder().decode(PagedNativeMarkupProjection.Mode.self, from: Data(bytes: bytes, count: output.length))
            guard value.matches(queryWindow) else { throw BoomError.stale("Derived Markdown changed its actual window.") }
            return value
          }
          try cancellation.check()
          if let onMode { await onMode(mode, delivered) }
          if final { value = delivered; break }
          // Taking a prefix result leaves the original builder in this SAME
          // command. Continue it only while its captured source is requested.
          complete = false; writer = true
        }
        let progress: Progress
        if writer {
          appendedIndex = true
          progress = try await onQueue(priority: .background, cancellation: token, custody: lease) {
            try cancellation.check()
            let context = try PagedTextOperationContext(cancellation: token)
            try self.router.begin(document: snapshot.sourceRevision.documentID, writes: true,
              beforeWrite: { try self.willWrite(snapshot.sourceRevision.documentID) })
            defer { self.router.end() }
            let operation = BloomTextOperation(context: Unmanaged.passUnretained(context).toOpaque(),
              read_stream: nil, write_stream: nil, is_cancelled: pagedCancelled)
            var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
            defer { if output.data != nil { boom_attachment_free(output) } }
            let status = withExtendedLifetime((queryWindow, context)) {
              bloom_logical_markup_writer_step(self.handle, command.pointer, operation, &output, &error)
            }
            if let failure = self.router.failure ?? context.failure {
              if error.data != nil { boom_attachment_free(error) }; throw failure
            }
            try pagedLogicalResult(status, error)
            guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid derived index append progress.") }
            return try JSONDecoder().decode(Progress.self, from: Data(bytes: bytes, count: output.length))
          }
        } else {
          progress = try await logicalRead(snapshot, payloadBytes: 0, cancellation: cancellation) { host, operation in
            var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
            defer { if output.data != nil { boom_attachment_free(output) } }
            try pagedLogicalResult(bloom_logical_markup_step(host, command.pointer, operation, &output, &error), error)
            guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid derived window query progress.") }
            return try JSONDecoder().decode(Progress.self, from: Data(bytes: bytes, count: output.length))
          }
        }
        guard (0...393_216).contains(progress.bufferedBytes) else { throw BoomError.budget("Derived Markdown exceeded its bounded buffers.") }
        complete = progress.complete; final = progress.final; writer = progress.needsWriter
        await Task.yield()
      }
      guard let value else { throw BoomError.invalid("Derived Markdown lost its joined final projection.") }
      try await onLogicalReadQueue { command.release() }
      retained = nil
      try cancellation.check()
      return (value, appendedIndex)
    } catch {
      cancellation.cancel()
      if let retained {
        do { try await onLogicalReadQueue { retained.release() } }
        catch let cleanup { throw PagedTextCleanupFailure(original: error, cleanup: cleanup) }
      }
      throw error
    }
  }

  func logicalCommand(_ snapshot: PagedNativeLogicalSnapshot, command request: PagedNativeLogicalCommand,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalCommandResult {
    guard snapshot.engineIncarnation == custodyIncarnation, snapshot.sourceRevision.ownerID == ownerID else {
      throw BoomError.stale("Logical command belongs to another actual reader/source.")
    }
    var claims: [PagedTextRootClaim] = [.source(snapshot.sourceRevision), .writerDocument(snapshot.sourceRevision.documentID)]
    if case .imported(_, let output) = request {
      try rootCustody.admitJoinedSource(output.lease, revision: output.value.revision)
      claims.append(.source(output.value.revision))
    }
    let capturedClaims = claims
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: capturedClaims,
      payloadBytes: request.reservation())
    var handle: PagedLogicalCommandHandle?
    do {
      // Hold the exact command/source pin through all steps, while each step
      // yields the SAME read lane and discards its <=256KiB ephemeral cache.
      try rootCustody.start(lease)
      let payload = try await detachedWork { try JSONEncoder().encode(request.payload()) }
      guard payload.count <= 1_048_576 else { throw BoomError.budget("Logical command encoding exceeds its actual fixed bound.") }
      let command: PagedLogicalCommandHandle = try await logicalRead(snapshot, payloadBytes: 0, cancellation: cancellation) { host, operation in
        var pointer: OpaquePointer?, error = BoomAttachmentBuffer(data: nil, length: 0)
        let status = payload.withUnsafeBytes {
          bloom_logical_command_begin(host, snapshot.pointer, $0.bindMemory(to: UInt8.self).baseAddress,
            payload.count, operation, &pointer, &error)
        }
        try pagedLogicalResult(status, error)
        guard let pointer else { throw BoomError.invalid("Logical command returned no actual continuation.") }
        return PagedLogicalCommandHandle(pointer)
      }
      handle = command
      struct Progress: Decodable, Sendable { let complete: Bool, bufferedBytes: Int, needsWriter: Bool }
      var needsWriter = false
      var appendedCandidate = false
      while true {
        let progress: Progress
        if needsWriter {
          let token = PagedTextCancellation()
          let registration = cancellation.onCancel { token.cancel() }
          defer { cancellation.removeCancellationHandler(registration) }
          appendedCandidate = true
          progress = try await onQueue(cancellation: token, custody: lease) {
            try cancellation.check()
            let context = try PagedTextOperationContext(cancellation: token)
            try self.router.begin(document: snapshot.sourceRevision.documentID, writes: true,
              beforeWrite: { try self.willWrite(snapshot.sourceRevision.documentID) })
            defer { self.router.end() }
            let operation = BloomTextOperation(context: Unmanaged.passUnretained(context).toOpaque(),
              read_stream: nil, write_stream: nil, is_cancelled: pagedCancelled)
            var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
            defer { if output.data != nil { boom_attachment_free(output) } }
            let status = withExtendedLifetime(context) {
              bloom_logical_command_writer_step(self.handle, command.pointer, operation, &output, &error)
            }
            if let failure = self.router.failure ?? context.failure {
              if error.data != nil { boom_attachment_free(error) }; throw failure
            }
            try pagedLogicalResult(status, error)
            guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid candidate append progress.") }
            let value = try JSONDecoder().decode(Progress.self, from: Data(bytes: bytes, count: output.length))
            guard (0...131_072).contains(value.bufferedBytes) else { throw BoomError.invalid("Candidate preparation exceeded its fixed buffers.") }
            return value
          }
        } else { progress = try await logicalRead(snapshot, payloadBytes: 0, cancellation: cancellation) { host, operation in
          var output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
          defer { if output.data != nil { boom_attachment_free(output) } }
          try pagedLogicalResult(bloom_logical_command_step(host, command.pointer, operation, &output, &error), error)
          guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid logical command progress.") }
          let value = try JSONDecoder().decode(Progress.self, from: Data(bytes: bytes, count: output.length))
          guard (0...131_072).contains(value.bufferedBytes) else { throw BoomError.invalid("Logical command exceeded its bounded buffers.") }
          return value
        } }
        if progress.complete { break }
        needsWriter = progress.needsWriter
        await Task.yield()
      }
      struct Result: Decodable {
        let kind: String
        let point: PagedTextSummary?
        let bounds: PagedTextParagraphBounds?
        let selection: PagedNativeLogicalCommand.Selection?
        let changed: Bool?
      }
      let value: PagedNativeLogicalCommandResult = try await onLogicalReadQueue {
        var window: OpaquePointer?, output = BoomAttachmentBuffer(data: nil, length: 0), error = BoomAttachmentBuffer(data: nil, length: 0)
        var windowTaken = false
        defer {
          if output.data != nil { boom_attachment_free(output) }
          if !windowTaken, let window { bloom_logical_window_free(window) }
        }
        try cancellation.check()
        try pagedLogicalResult(bloom_logical_command_finish(command.pointer, &window, &output, &error), error)
        guard let bytes = output.data, (1...4096).contains(output.length) else { throw BoomError.invalid("Invalid logical command result.") }
        let result = try JSONDecoder().decode(Result.self, from: Data(bytes: bytes, count: output.length))
        switch result.kind {
        case "point":
          guard let point = result.point, window == nil else { throw BoomError.invalid("Logical character result lost its actual point.") }
          return .point(point)
        case "paragraph":
          guard let bounds = result.bounds, window == nil else { throw BoomError.invalid("Logical paragraph result lost its actual bounds.") }
          return .paragraph(bounds)
        case "edit":
          guard let point = result.point, let selected = result.selection, let changed = result.changed, let window else {
            throw BoomError.invalid("Logical command lost its actual candidate/selection.")
          }
          windowTaken = true
          return .edit(try PagedNativeLogicalEdit(changed: changed,
            window: PagedNativeLogicalWindow(taking: window, sourceRevision: snapshot.sourceRevision,
              sessionID: snapshot.sessionID, engineIncarnation: snapshot.engineIncarnation),
            cursor: point, selection: selected.native))
        default: throw BoomError.invalid("Logical command returned another result kind.")
        }
      }
      try await onLogicalReadQueue { command.release() }
      handle = nil
      try cancellation.check()
      if appendedCandidate {
        // The actual append steps and read callbacks joined. The installed
        // editor controller retains this document; cold GC never runs live.
        // This receives an unpublished candidate, not a file/native ACK.
        try await onQueue(custody: lease) {
          try self.rootCustody.finishOutput(lease, claims: capturedClaims, payloadBytes: 0,
            inFlightWitness: self.inFlightWitness)
          try self.rootCustody.abandonJoined(lease)
        }
      } else { try rootCustody.finishRead(lease) }
      return value
    } catch {
      // Cleanup is not cancelled. The actual last reader/callback must return
      // and its continuation/cache must die before the operation pin releases.
      if let handle { try await onLogicalReadQueue { handle.release() } }
      if try rootCustody.joinedFailure(lease, error: error) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }

  func publishLogicalRetaining(_ publication: PagedNativeLogicalPublication,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    try await rootOutput(purpose: .nativeBatch(sessionID: publication.sessionID,
        batchID: publication.publicationID, first: publication.firstSequence, last: publication.generation),
      claims: [.record(publication.expectedRecord), .writerDocument(publication.expectedRecord.document.id), .workspace],
      payloadBytes: PagedWorkingWindow.hardBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { [.record(publication.expectedRecord), .record($0.sealedRootRecord),
        .writerDocument(publication.expectedRecord.document.id), .workspace] },
      outputBytes: { $0.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes },
      nativeAcknowledgement: { $0 }, logicalInput: publication) {
        try self.makeLogicalAcknowledgement(publication, publisher: publisher)
      }
  }
  private func materializeLogical(_ snapshot: PagedNativeLogicalSnapshot) throws -> PagedTextRevision {
    guard snapshot.engineIncarnation == custodyIncarnation, snapshot.sourceRevision.ownerID == ownerID,
      handle != 0, !filesClosed else { throw BoomError.stale("Logical materialization has another engine.") }
    try router.begin(document: snapshot.sourceRevision.documentID, writes: true,
      beforeWrite: { try self.willWrite(snapshot.sourceRevision.documentID) })
    defer { router.end() }
    let operation = BloomTextOperation(context: nil, read_stream: nil, write_stream: nil, is_cancelled: nil)
    let buffer = withExtendedLifetime(snapshot) { bloom_text_materialize_logical(handle, snapshot.pointer, operation) }
    defer { boom_attachment_free(buffer) }
    if let failure = router.failure { throw failure }
    guard let bytes = buffer.data, (1...16_384).contains(buffer.length) else { throw BoomError.invalid("Logical materialization returned an invalid root.") }
    let reply = try JSONDecoder().decode(Envelope<PagedTextRevision>.self, from: Data(bytes: bytes, count: buffer.length))
    guard reply.schema == 1, reply.ok, let revision = reply.value,
      revision.ownerID == ownerID, revision.documentID == snapshot.sourceRevision.documentID,
      revision.summary == snapshot.summary else { throw BoomError.invalid(reply.error?.message ?? "Logical file candidate differs from its source.") }
    try revision.validate(); return revision
  }
  private func makeLogicalAcknowledgement(_ publication: PagedNativeLogicalPublication,
    publisher: PagedWorkspacePublisher) throws -> PagedNativeCommitAcknowledgement {
    try admit(publisher); try publication.history.validate()
    try publisher.admitCurrentRecord(publication.expectedRecord, validateRecord: { try self.admitNavigationRecord($0) })
    let before = try withNativeHistory(documentID: publication.expectedRecord.document.id, writes: false) { try $0.load(publication.expectedRecord) }
    let current = try materializeLogical(publication.history.snapshot)
    func entry(_ value: PagedNativeLogicalHistoryEntry) throws -> PagedRootHistoryEntry {
      let revision = try materializeLogical(value.snapshot)
      let actual: UInt64 = try execute(Request(op: "position", revision: revision, utf16Offset: value.cursor.utf16Offset))
      guard actual == value.cursor.byteOffset else { throw BoomError.invalid("Logical history cursor differs from its actual file candidate.") }
      if value.cursor.selectionLengthUTF16 != 0 {
        let end = value.cursor.utf16Offset.addingReportingOverflow(value.cursor.selectionLengthUTF16)
        guard !end.overflow else { throw BoomError.invalid("Logical history selection overflow.") }
        let _: UInt64 = try execute(Request(op: "position", revision: revision, utf16Offset: end.partialValue))
      }

      return PagedRootHistoryEntry(revision: revision, cursor: value.cursor.sealed, groupID: value.groupID)
    }
    let undo = try publication.history.undo.map(entry), redo = try publication.history.redo.map(entry)
    let next = publication.expectedRecord.historyGeneration.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("File history generation is exhausted.") }
    let history = try PagedRootHistory(materializedCurrent: current, cursor: publication.history.cursor.sealed,
      undo: undo, redo: redo, activeGroup: publication.history.activeGroup, generation: next.partialValue)
    let actualCursor: UInt64 = try execute(Request(op: "position", revision: current, utf16Offset: history.currentCursor.utf16Offset))
    guard actualCursor == history.currentCursor.byteOffset else { throw BoomError.invalid("Logical current cursor has another scalar endpoint.") }
    if history.currentCursor.selectionLengthUTF16 != 0 {
      let end = history.currentCursor.utf16Offset.addingReportingOverflow(history.currentCursor.selectionLengthUTF16)
      guard !end.overflow else { throw BoomError.invalid("Logical current selection overflow.") }
      let _: UInt64 = try execute(Request(op: "position", revision: current, utf16Offset: end.partialValue))
    }

    let anchor = publication.window
    guard let count = Int(exactly: anchor.summary.bytes), count <= PagedWorkingWindow.hardBytes else {
      throw BoomError.invalid("Logical publication must capture its bounded post-command window.")
    }
    let window: PagedTextWindow = try execute(Request(op: "window", revision: current, byteStart: anchor.start.bytes,
      maximumBytes: max(4, count)))
    let exactWindow = count == 0
      ? PagedTextWindow(revision: current, windowID: window.windowID, byteStart: window.byteStart,
          utf16Start: window.utf16Start, lfStart: window.lfStart, text: "") : window
    let document = PagedDocumentDescriptor(id: publication.expectedRecord.document.id,
      title: publication.expectedRecord.document.title, revision: current)
    let record = try withNativeHistory(documentID: document.id, writes: true) { try $0.writeNew(history, document: document) }
    try pinCandidate([.record(publication.expectedRecord), .record(record), .writerDocument(document.id), .workspace])
    let canonical = try nativeCanonicalProjection(history: history, beforeHistory: before, record: record,
      beforeRecord: publication.expectedRecord, scope: .nativeBatch(sessionID: publication.sessionID,
        batchID: publication.publicationID, first: publication.firstSequence, last: publication.generation))
    let ack = try PagedNativeCommitAcknowledgement(validating: publication, sealedWindow: exactWindow,
      sealedRootRecord: record, canonicalHistory: canonical)
    guard let lease = activeCustody else { throw BoomError.denied("Logical save lost its entered source job.") }
    try rootCustody.stageNative(lease, acknowledgement: ack)
    try willPublish()
    _ = try publisher.publishDocument(record, expected: publication.expectedRecord, validateRecord: { try self.validateNativeRecord($0) })
    try rootCustody.publicationCompleted(lease)
    // Actual publication sync joined, not merely candidate tree construction.
    try publication.history.snapshot.releaseSyncedInsertions()
    for entry in publication.history.undo + publication.history.redo { try entry.snapshot.releaseSyncedInsertions() }
    return ack
  }
  func inspectLogicalPublication(_ publication: PagedNativeLogicalPublication, custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedNativeCommitAcknowledgement? {
    try await rootRead(claims: [.record(publication.expectedRecord), .workspace]) {
      try self.admit(publisher)
      let original = try self.rootCustody.logicalFailure(custody, publication: publication)
      let actual = try publisher.currentRecord(id: publication.expectedRecord.document.id)
      if actual == publication.expectedRecord { return nil }
      guard let ack = original.acknowledgement, actual == ack.sealedRootRecord else {
        throw BoomError.stale("Failed logical save has another complete file root; all native input remains owned.")
      }
      if !original.completed { try self.router.files().synchronizeDocument(ack.sealedRootRecord) }
      try self.validateNativeRecord(ack.sealedRootRecord)
      try self.rootCustody.recoverLogicalOutput(custody)
      return ack
    }
  }
  func retryLogicalBeforeRetaining(_ publication: PagedNativeLogicalPublication, custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    try await onQueue(custody: custody) {
      try self.admit(publisher)
      try publisher.admitCurrentRecord(publication.expectedRecord, validateRecord: { try self.validateNativeRecord($0) })
      try self.rootCustody.retryLogical(custody, publication: publication)
      try self.rootCustody.start(custody)
      do {
        let ack = try self.makeLogicalAcknowledgement(publication, publisher: publisher)
        try self.rootCustody.finishOutput(custody, claims: [.record(publication.expectedRecord), .record(ack.sealedRootRecord),
          .writerDocument(publication.expectedRecord.document.id), .workspace],
          payloadBytes: ack.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes,
          inFlightWitness: self.inFlightWitness, nativeAcknowledgement: ack)
        return PagedTextCustodiedValue(value: ack, lease: custody)
      } catch { _ = try self.rootCustody.joinedFailure(custody, error: error); throw error }
    }
  }

  func makeWorkspacePublisher() async throws -> PagedWorkspacePublisher {
    try await onQueue { PagedWorkspacePublisher(store: try self.router.files()) }
  }
  /// Capture only: the live SDK/source/read lane stays open. The complete
  /// physical document head is published within one writer job; ACK receiving
  /// afterwards changes custody, not these files or the metadata index.
  func captureWorkspaceBackup(vault: Vault, cancellation: CancellationFlag, temporaryParent: URL? = nil) async throws -> WorkspaceBackup.CapturedDirectory {
    guard vault.root.deletingLastPathComponent().standardizedFileURL.path == sourceRoot.standardizedFileURL.path else {
      throw BoomError.denied("Backup has another actual workspace namespace.")
    }
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.workspace])
    return try await withTaskCancellationHandler {
      do {
        return try await onQueue(custody: lease) {
          try self.rootCustody.start(lease)
          try cancellation.check(); try self.router.files().requireQueue()
          // Fixed lock order: existing writer queue, then Vault's mutex.
          // Vault's synchronous operations never call back into Engine.
          let captured = try vault.captureBackupSource(cancellation: cancellation, temporaryParent: temporaryParent)
          do { try self.rootCustody.finishRead(lease) }
          catch {
            try WorkspaceBackup.discard(captured, preserving: error)
            throw error
          }
          return captured
        }
      } catch {
        let original = error
        do { _ = try self.rootCustody.joinedFailure(lease, error: original) }
        catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: lease) }
        throw original
      }
    } onCancel: { cancellation.cancel() }
  }
  func currentDocumentRecordRetaining(_ publisher: PagedWorkspacePublisher, documentID: UUID)
    async throws -> PagedTextCustodiedValue<PagedDocumentRootRecord> {
    try await rootOutput(claims: [.workspace], outputClaims: { [.record($0)] }) {
      try self.admit(publisher)
      guard let record = try publisher.currentRecord(id: documentID) else { throw BoomError.stale("The document has no saved root.") }
      try self.admitNavigationRecord(record); return record
    }
  }
  func publishInitialDocumentRetaining(_ publisher: PagedWorkspacePublisher,
    imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    initialized: PagedTextCustodiedValue<PagedDocumentRootRecord>) async throws -> PagedDocumentRootRecord {
    let record = initialized.value
    guard record.document.revision == imported.value.revision,
      try rootCustody.claims(imported.lease).contains(.source(imported.value.revision)),
      try rootCustody.claims(initialized.lease).contains(.record(record)) else { throw BoomError.stale("Initial publication lost its actual source producers.") }
    let output = try await rootOutput(claims: [.record(record), .workspace], outputClaims: { [.record($0)] }) {
      try self.admit(publisher); try self.willPublish()
      return try publisher.publishInitialDocument(record, validateRecord: { try self.validateNativeRecord($0) })
    }
    // All three outputs stay owned until this actual receiving join.
    try await onQueue(custody: output.lease) {
      try publisher.admitCurrentRecord(record, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.transferJoinedToHead(imported.lease, record: record)
      try self.rootCustody.transferJoinedToHead(initialized.lease, record: record)
      try self.rootCustody.transferJoinedToHead(output.lease, record: record)
    }
    return record
  }
  func loadDocumentIndexPageRetaining(_ publisher: PagedWorkspacePublisher, afterOrdinal: Int = -1,
    expectedHead: PagedWorkspaceHead? = nil) async throws -> PagedTextCustodiedValue<PagedDocumentIndexPage> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      try self.admit(publisher)
      return try publisher.documentIndexPage(afterOrdinal: afterOrdinal, expectedHead: expectedHead,
        validateRecord: { try self.admitNavigationRecord($0) })
    }
  }
  func loadWorkspaceCatalogRetaining(_ publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedWorkspaceDocumentCatalog> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      try self.admit(publisher); return try publisher.loadCatalogAndWorkspace(validateRecord: { try self.admitNavigationRecord($0) })
    }
  }
  func rootHistoryRetaining(_ publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord)
    async throws -> PagedTextCustodiedValue<PagedRootHistory> {
    try await rootOutput(claims: [.record(expected)], metadataBytes: PagedRootHistory.maximumEncodedBytes,
      outputClaims: { _ in [.record(expected)] }, outputBytes: { _ in PagedRootHistory.maximumEncodedBytes }) {
      try self.admit(publisher)
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
      return try self.withNativeHistory(documentID: expected.document.id, writes: false) { try $0.load(expected) }
    }
  }

  func initialNativeRecordRetaining(_ document: PagedDocumentDescriptor) async throws -> PagedTextCustodiedValue<PagedDocumentRootRecord> {
    try await rootOutput(claims: [.source(document.revision), .writerDocument(document.id)],
      outputClaims: { [.source(document.revision), .record($0), .writerDocument(document.id)] }) {
      try document.validate(); try self.admit(document.revision)
      let opened: PagedTextRevision = try self.execute(Request(op: "open", revision: document.revision))
      guard opened == document.revision else { throw BoomError.invalid("Initial native root changed during admission.") }
      let history = try PagedRootHistory(revision: opened, cursor: PagedSealedCursor(byteOffset: 0, utf16Offset: 0))
      return try self.withNativeHistory(documentID: document.id, writes: true) {
        try $0.writeNew(history, document: document)
      }
    }
  }

  func makeNativeStorage(_ publisher: PagedWorkspacePublisher,
    expected: PagedDocumentRootRecord) async throws -> PagedNativeStorageBackend {
    let routeID = UUID()
    let lease = try rootCustody.reserve(engine: self, purpose: .controller(routeID),
      claims: [.record(expected), .workspace], payloadBytes: PagedWorkingWindow.hardBytes,
      metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes)
    do {
      return try await onQueue(custody: lease) {
        try self.rootCustody.start(lease)
        try self.admit(publisher)
        try publisher.admitCurrentRecord(expected, validateRecord: { try self.validateNativeRecord($0) })
        try self.rootCustody.finishOutput(lease, claims: [.record(expected)], payloadBytes: 0,
          inFlightWitness: self.inFlightWitness)
        let live = try self.rootCustody.makeController(from: lease, routeID: routeID, record: expected)
        return PagedNativeStorageBackend(engine: self, publisher: publisher, admittedRecord: expected,
          routeID: routeID, controllerCustody: live)
      }
    } catch {
      if try rootCustody.joinedFailure(lease, error: error) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }

  private func admitNavigationRecord(_ record: PagedDocumentRootRecord) throws {
    try record.validate(); try admit(record.document.revision)
    let actual: PagedTextRevision = try execute(Request(op: "open", revision: record.document.revision))
    guard actual == record.document.revision else { throw BoomError.stale("Navigation source changed during admission.") }
  }

  private func nativeHistoryWindow(_ revision: PagedTextRevision,
    cursor: PagedSealedCursor) throws -> PagedTextWindow {
    try cursor.validate(in: revision)
    // The normalized lower endpoint retains its own byte/UTF16 admission,
    // even when the physical window must be at the distant focus endpoint.
    let lowerByte: UInt64 = try execute(Request(op: "position", revision: revision, utf16Offset: cursor.utf16Offset))
    guard lowerByte == cursor.byteOffset else { throw BoomError.invalid("History selection lower endpoint has another byte coordinate.") }
    if cursor.selectionLengthUTF16 > 0, !cursor.focusAtEnd {
      // The bounded focus window cannot validate the distant other endpoint.
      let _: UInt64 = try execute(Request(op: "position", revision: revision,
        utf16Offset: cursor.utf16Offset + cursor.selectionLengthUTF16))
    }
    // At most 4096 UTF16 units precede the exact cursor, using <=12288 bytes.
    // This leaves room for its scalar in the fixed 16KiB projection. Only this
    // approximate context anchor may move by one unit past a half-surrogate;
    // the exact retained cursor is never rounded or truncated.
    var anchor = cursor.focusUTF16 > 4_096 ? cursor.focusUTF16 - 4_096 : 0
    let start: UInt64
    do { start = try execute(Request(op: "position", revision: revision, utf16Offset: anchor)) }
    catch BoomError.invalid(let message) where message == "Invalid paged text: half-surrogate offset" {
      anchor += 1
      start = try execute(Request(op: "position", revision: revision, utf16Offset: anchor))
    }
    let window: PagedTextWindow = try execute(Request(op: "window", revision: revision,
      byteStart: start, maximumBytes: PagedWorkingWindow.targetBytes))
    try window.validate()
    guard window.revision == revision, window.byteStart == start, window.utf16Start == anchor,
      window.text.utf8.count <= PagedWorkingWindow.targetBytes, cursor.focusUTF16 >= anchor,
      let localCaret = Int(exactly: cursor.focusUTF16 - anchor) else {
      throw BoomError.invalid("Retained history projection has another root, anchor or cursor.")
    }
    var bytes = 0, units = 0
    for scalar in window.text.unicodeScalars {
      if units == localCaret { break }
      let value = scalar.value
      bytes += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
      units += value < 0x10000 ? 1 : 2
    }
    let focusByte = window.byteStart.addingReportingOverflow(UInt64(bytes))
    guard units == localCaret, !focusByte.overflow,
      cursor.focusUTF16 != cursor.utf16Offset || focusByte.partialValue == cursor.byteOffset else {
      throw BoomError.invalid("History window does not contain its exact scalar focus.")
    }
    return window
  }

  private func nativeCanonicalProjection(history: PagedRootHistory, beforeHistory: PagedRootHistory?,
    record: PagedDocumentRootRecord, beforeRecord: PagedDocumentRootRecord?,
    scope: PagedNativeCanonicalHistoryProjection.Scope) throws -> PagedNativeCanonicalHistoryProjection {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let activeCustody, activeCustody.ownerID == ownerID,
      activeCustody.engineIncarnation == custodyIncarnation else {
      throw BoomError.denied("Canonical metadata has no actual entered same-engine producer.")
    }
    let claims = try rootCustody.claims(activeCustody)
    guard claims.contains(.record(record)) else { throw BoomError.denied("Canonical metadata escaped actual full-record job custody.") }
    if let beforeRecord, !claims.contains(.record(beforeRecord)) { throw BoomError.denied("Canonical metadata lost its before-record job custody.") }
    return try PagedNativeCanonicalHistoryProjection(storageHistory: history, record: record,
      beforeRecord: beforeRecord, beforeHistory: beforeHistory, scope: scope, producer: activeCustody)
  }

  func bindNativeOpeningCustody(_ controller: PagedTextRootLease, sessionID: UUID,
    record: PagedDocumentRootRecord) throws {
    try rootCustody.bindNativeOpening(controller, sessionID: sessionID, record: record)
  }

  func nativeCanonicalOpeningRetaining(publisher: PagedWorkspacePublisher,
    expected: PagedDocumentRootRecord, sessionID: UUID) async throws -> PagedTextCustodiedValue<PagedNativeCanonicalOpening> {
    try await rootOutput(claims: [.record(expected), .workspace], payloadBytes: PagedWorkingWindow.targetBytes,
      metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { _ in [.record(expected)] },
      outputBytes: { $0.window.text.utf8.count + PagedNativeCanonicalHistoryProjection.chargedBytes }) {
      try self.admit(publisher)
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.validateNativeRecord($0) })
      let history = try self.withNativeHistory(documentID: expected.document.id, writes: false) { try $0.load(expected) }
      let window = try self.nativeHistoryWindow(history.current, cursor: history.currentCursor)
      guard let caret = Int(exactly: history.currentCursor.focusUTF16 - window.utf16Start) else {
        throw BoomError.budget("Canonical opening cursor exceeds its bounded island.")
      }
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.validateNativeRecord($0) })
      let projection = try self.nativeCanonicalProjection(history: history, beforeHistory: nil,
        record: expected, beforeRecord: nil, scope: .opening(sessionID: sessionID, windowID: window.windowID))
      return PagedNativeCanonicalOpening(sessionID: sessionID, record: expected, window: window,
        history: projection, localCaretUTF16: caret)
    }
  }

  private func withNativeHistory<T>(documentID: UUID, writes: Bool,
    _ work: (PagedRootHistoryStore) throws -> T) throws -> T {
    try router.begin(document: documentID, writes: writes, beforeWrite: writes ? { try self.willWrite(documentID) } : nil)
    defer { router.end() }
    return try work(PagedRootHistoryStore(pages: router.provider(owner: ownerID, document: documentID, writing: writes)))
  }
  private func validateNativeRecord(_ record: PagedDocumentRootRecord) throws {
    try record.validate(); try admit(record.document.revision)
    let opened: PagedTextRevision = try execute(Request(op: "open", revision: record.document.revision))
    guard opened == record.document.revision else { throw BoomError.invalid("Native history source changed during admission.") }
    let history = try withNativeHistory(documentID: record.document.id, writes: false) { try $0.load(record) }
    // This admits bounded root/index metadata, not entire historical sources.
    // Text-page validation remains lazy when a captured range is read.
    for entry in history.undo + history.redo {
      let retained: PagedTextRevision = try execute(Request(op: "open", revision: entry.revision))
      guard retained == entry.revision else { throw BoomError.invalid("Retained native history root changed.") }
    }
  }

  private func readNativeIsland(_ revision: PagedTextRevision, anchor: PagedTextWindow,
    exactBytes: Data) throws -> PagedTextWindow {
    // The suffix may begin with any Unicode scalar after deleting an island.
    // Read enough bytes to authenticate its anchor without splitting that scalar.
    let read: PagedTextWindow = try execute(Request(op: "window", revision: revision,
      byteStart: anchor.byteStart, maximumBytes: exactBytes.isEmpty ? 4 : exactBytes.count))
    try read.validate()
    guard read.revision == revision, read.byteStart == anchor.byteStart,
      read.utf16Start == anchor.utf16Start, read.lfStart == anchor.lfStart,
      exactBytes.isEmpty || read.text.utf8.elementsEqual(exactBytes) else {
      throw BoomError.invalid("Native candidate readback differs from its captured island.")
    }
    // An empty local replacement may have a nonempty suffix outside the
    // island. Do not smuggle a following character into its acknowledgement.
    if exactBytes.isEmpty {
      return PagedTextWindow(revision: revision, windowID: read.windowID, byteStart: read.byteStart,
        utf16Start: read.utf16Start, lfStart: read.lfStart, text: "")
    }
    return read
  }

  func openRetaining(_ revision: PagedTextRevision) async throws -> PagedTextCustodiedValue<PagedTextRevision> {
    try await rootOutput(claims: [.source(revision)], outputClaims: { [.source($0)] }) {
      let opened: PagedTextRevision = try self.execute(Request(op: "open", revision: revision))
      guard opened == revision else { throw BoomError.invalid("Paged engine opened a different revision.") }
      return opened
    }
  }

  func windowRetaining(_ revision: PagedTextRevision, byteStart: UInt64,
    maximumBytes: Int = PagedTextWindow.maximumBytes, priority: PagedTextStorageExecutor.Priority = .foreground) async throws -> PagedTextCustodiedValue<PagedTextWindow> {
    guard maximumBytes > 0, maximumBytes <= PagedTextWindow.maximumBytes else { throw BoomError.budget("Invalid native window bound.") }
    return try await rootOutput(claims: [.source(revision)], payloadBytes: maximumBytes, priority: priority,
      outputClaims: { [.source($0.revision)] }, outputBytes: { $0.text.utf8.count }) {
      let window: PagedTextWindow = try self.execute(Request(op: "window", revision: revision, byteStart: byteStart, maximumBytes: maximumBytes))
      try window.validate()
      guard window.revision == revision, window.byteStart == byteStart, window.text.utf8.count <= maximumBytes else {
        throw BoomError.invalid("Paged engine returned a different window capture.")
      }
      return window
    }
  }

  func prefixWindowRetaining(_ revision: PagedTextRevision, utf16Caret: UInt64, maximumBytes: Int = 16_384)
    async throws -> PagedTextCustodiedValue<PagedTextWindow> {
    guard maximumBytes >= 4, maximumBytes <= PagedTextWindow.maximumBytes else { throw BoomError.budget("Invalid model source window bound.") }
    return try await rootOutput(claims: [.source(revision)], payloadBytes: maximumBytes,
      outputClaims: { [.source($0.revision)] }, outputBytes: { $0.text.utf8.count }) {
      let window: PagedTextWindow = try self.execute(Request(op: "prefix_window", revision: revision,
        maximumBytes: maximumBytes, utf16Offset: utf16Caret))
      try window.validate()
      guard window.revision == revision, window.utf16Start + UInt64(window.text.utf16.count) == utf16Caret,
        window.text.utf8.count <= maximumBytes else { throw BoomError.invalid("Model source capture has another caret or revision.") }
      return window
    }
  }
  func spliceRetaining(_ edit: PagedTextLocalEdit,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedTextRevision> {
    guard edit.oldBytes.count <= PagedTextWindow.maximumBytes, edit.newBytes.count <= PagedTextWindow.maximumBytes,
      let old = String(data: edit.oldBytes, encoding: .utf8), let new = String(data: edit.newBytes, encoding: .utf8),
      edit.byteEnd >= edit.byteStart, edit.byteEnd - edit.byteStart == UInt64(edit.oldBytes.count) else {
      throw BoomError.invalid("Native splice must retain exact bounded UTF-8 bytes.")
    }
    return try await rootOutput(claims: [.source(edit.revision), .writerDocument(edit.revision.documentID)],
      cancellation: cancellation, outputClaims: { [.source(edit.revision), .source($0), .writerDocument(edit.revision.documentID)] }) {
      let revision: PagedTextRevision = try self.execute(Request(op: "splice", revision: edit.revision, byteStart: edit.byteStart,
        byteEnd: edit.byteEnd, oldText: old, newText: new), cancellation: cancellation, writes: true)
      try revision.validate(); try self.admit(revision)
      guard revision.documentID == edit.revision.documentID else { throw BoomError.invalid("Splice returned another document.") }
      return revision
    }
  }

  func deleteUserRangeRetaining(_ revision: PagedTextRevision, range: Range<UInt64>,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedTextRevision> {
    try await rootOutput(claims: [.source(revision), .writerDocument(revision.documentID)],
      cancellation: cancellation, outputClaims: { [.source(revision), .source($0), .writerDocument(revision.documentID)] }) {
      let result: PagedTextRevision = try self.execute(Request(op: "delete_user_range", revision: revision, byteStart: range.lowerBound,
        byteEnd: range.upperBound), cancellation: cancellation, writes: true)
      try result.validate(); try self.admit(result)
      guard result.documentID == revision.documentID else { throw BoomError.invalid("Deletion returned another document.") }
      return result
    }
  }

  func checkoutRetaining(_ revision: PagedTextRevision, retained: PagedTextRevision) async throws -> PagedTextCustodiedValue<PagedTextRevision> {
    try await rootOutput(claims: [.source(revision), .source(retained)], outputClaims: { [.source($0)] }) {
      let checked: PagedTextRevision = try self.execute(Request(op: "checkout", revision: revision, retained: retained))
      guard checked == retained else { throw BoomError.invalid("Checkout returned another retained root.") }
      return checked
    }
  }

  func importUTF8Retaining(documentID: UUID, from file: FileHandle, expectedBytes requestedBytes: UInt64? = nil,
    cancellation: PagedTextCancellation = PagedTextCancellation(),
    priority: PagedTextStorageExecutor.Priority = .background) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision> {
    let rootLease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.writerDocument(documentID)])
    let bulkLease: UUID
    do { bulkLease = try executor.reserveBulk(cancellation, priority: priority); try rootCustody.start(rootLease) }
    catch { _ = try rootCustody.joinedFailure(rootLease, error: error); throw error }
    defer { executor.releaseBulk(bulkLease) }
    do {
      return try await withTaskCancellationHandler {
        let context = try await performStreamIO {
          try PagedTextOperationContext(cancellation: cancellation, file: file, importing: true)
        }
        guard let expectedBytes = context.expectedBytes else { throw BoomError.invalid("Import has no captured file extent.") }
        if let requestedBytes, requestedBytes != expectedBytes { throw BoomError.stale("The imported file extent changed.") }
        let operationID: UUID = try await onQueue(priority: priority, cancellation: cancellation, custody: rootLease) {
          let id: UUID = try self.execute(Request(op: "import_begin", ownerID: self.ownerID,
            documentID: documentID, expectedBytes: expectedBytes), cancellation: cancellation, writes: false)
          try self.rootCustody.beganBulk(rootLease, operationID: id)
          return id
        }
        do {
          try await pump(Request(op: "import_step", ownerID: ownerID, documentID: documentID, operationID: operationID),
            expectedBytes: expectedBytes, context: context, writes: true, custody: rootLease, priority: priority)
          try await performStreamIO { try context.finish() }
          return try await onQueue(priority: priority, cancellation: cancellation, custody: rootLease) {
            let result: PagedTextImportedRevision = try self.execute(Request(op: "import_finish", ownerID: self.ownerID,
              documentID: documentID, operationID: operationID), cancellation: cancellation, writes: true)
            try result.revision.validate(); try self.validateDigest(result.wholeTextSha256)
            guard result.revision.ownerID == self.ownerID, result.revision.documentID == documentID,
              result.revision.summary.bytes == expectedBytes else {
              throw BoomError.invalid("Paged import returned a different source or extent.")
            }
            try self.rootCustody.joinedBulk(rootLease, operationID: operationID)
            try self.rootCustody.finishOutput(rootLease, claims: [.source(result.revision), .writerDocument(documentID)],
              payloadBytes: 0, inFlightWitness: self.inFlightWitness)
            return PagedTextCustodiedValue(value: result, lease: rootLease)
          }
        } catch {
          try await abort(operationID, documentID: documentID, original: error, custody: rootLease)
          throw error
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      // This runs before releaseBulk: failed/uncertain output custody is not
      // first established in a later actor callback or after in-flight release.
      if try rootCustody.joinedFailure(rootLease, error: error) { throw PagedTextCustodyFailure(original: error, lease: rootLease) }
      throw error
    }
  }

  func export(_ revision: PagedTextRevision, to file: FileHandle,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws {
    _ = try await stream(revision, to: file, cancellation: cancellation, priority: .foreground)
  }

  func wholeTextSha256(_ revision: PagedTextRevision,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> String {
    try await stream(revision, to: nil, cancellation: cancellation, priority: .background)
  }

  private func stream(_ revision: PagedTextRevision, to file: FileHandle?,
    cancellation: PagedTextCancellation, priority: PagedTextStorageExecutor.Priority) async throws -> String {
    let rootLease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.source(revision)])
    let bulkLease: UUID
    do { bulkLease = try executor.reserveBulk(cancellation, priority: priority); try rootCustody.start(rootLease) }
    catch { _ = try rootCustody.joinedFailure(rootLease, error: error); throw error }
    defer { executor.releaseBulk(bulkLease) }
    do {
      return try await withTaskCancellationHandler {
        let context: PagedTextOperationContext
        if let file {
          context = try await performStreamIO { try PagedTextOperationContext(cancellation: cancellation, file: file) }
        } else {
          context = try PagedTextOperationContext(cancellation: cancellation)
        }
        let operationID: UUID = try await onQueue(priority: priority, cancellation: cancellation, custody: rootLease) {
          let id: UUID = try self.execute(Request(op: file == nil ? "hash_begin" : "export_begin", revision: revision), cancellation: cancellation)
          try self.rootCustody.beganBulk(rootLease, operationID: id)
          return id
        }
        do {
          try await pump(Request(op: "stream_step", revision: revision, operationID: operationID),
            expectedBytes: revision.summary.bytes, context: context, writes: false, custody: rootLease, priority: priority)
          if context.hasOutput { try await performStreamIO { try context.finish() } }
          return try await onQueue(priority: priority, cancellation: cancellation, custody: rootLease) {
            let digest: String = try self.execute(Request(op: "stream_finish", revision: revision,
              operationID: operationID), cancellation: cancellation)
            try self.validateDigest(digest)
            try self.rootCustody.joinedBulk(rootLease, operationID: operationID)
            try self.rootCustody.finishRead(rootLease)
            return digest
          }
        } catch {
          try await abort(operationID, documentID: revision.documentID, original: error, custody: rootLease)
          throw error
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(rootLease, error: error) { throw PagedTextCustodyFailure(original: error, lease: rootLease) }
      throw error
    }
  }

  private func pump(_ request: Request, expectedBytes: UInt64, context: PagedTextOperationContext,
    writes: Bool, custody: PagedTextRootLease, priority: PagedTextStorageExecutor.Priority = .background) async throws {
    var previous = PagedTextBulkProgress(processedBytes: 0, validatedBytes: 0, complete: false)
    while !previous.complete {
      if context.needsInputRead { try await performStreamIO { try context.prepareInput() } }
      let captured = previous
      previous = try await onQueue(priority: priority, cancellation: context.cancellation, custody: custody) {
        let progress: PagedTextBulkProgress = try self.execute(request, cancellation: context.cancellation,
          writes: writes, context: context)
        guard progress.processedBytes >= captured.processedBytes,
          progress.processedBytes - captured.processedBytes <= 65_536,
          progress.validatedBytes >= captured.validatedBytes, progress.validatedBytes <= progress.processedBytes,
          progress.processedBytes <= expectedBytes,
          !progress.complete || (progress.processedBytes == expectedBytes && progress.validatedBytes == expectedBytes),
          context.streamBytesTransferred == nil || context.streamBytesTransferred == progress.processedBytes else {
          throw BoomError.invalid("Paged background progress differs from its bounded owned stream.")
        }
        return progress
      }
      if context.needsOutputFlush { try await performStreamIO { try context.flushOutput() } }
    }
  }

  private func performStreamIO<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Self.streamIOQueue.async {
        do { continuation.resume(returning: try autoreleasepool(invoking: work)) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func abort(_ id: UUID, documentID: UUID, original: Error, custody: PagedTextRootLease) async throws {
    do {
      try await onQueue(priority: .cleanup, custody: custody) {
        let joined: Bool = try self.execute(Request(op: "bulk_abort", ownerID: self.ownerID,
          documentID: documentID, operationID: id))
        guard joined else { throw BoomError.unavailable("Paged bulk cleanup did not join.") }
        try self.rootCustody.joinedBulk(custody, operationID: id)
      }
    } catch { throw PagedTextCleanupFailure(original: original, cleanup: error) }
  }

  private func validateDigest(_ digest: String) throws {
    guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw BoomError.invalid("Paged stream returned an invalid whole-source digest.")
    }
  }

  /// Each await releases the shared engine lane. Even an unusually long
  /// grapheme retains only one page while ordinary foreground work can enter.
  func graphemeBoundary(_ revision: PagedTextRevision, utf16Offset: UInt64, forward: Bool,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextSummary {
    struct Progress: Decodable, Sendable {
      let complete: Bool
      let result: PagedTextSummary?
      let bufferedBytes: Int
      let examinedBytes: UInt64
    }
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.source(revision)], payloadBytes: 65_536)
    let bulk: UUID
    do { bulk = try executor.reserveBulk(cancellation, priority: .foreground); try rootCustody.start(lease) }
    catch { _ = try rootCustody.joinedFailure(lease, error: error); throw error }
    defer { executor.releaseBulk(bulk) }
    do {
      return try await withTaskCancellationHandler {
        let id: UUID = try await onQueue(cancellation: cancellation, custody: lease) {
          let id: UUID = try self.execute(Request(op: "grapheme_seek_begin", revision: revision,
            utf16Offset: utf16Offset, forward: forward), cancellation: cancellation)
          try self.rootCustody.beganBulk(lease, operationID: id)
          return id
        }
        do {
          var examined: UInt64 = 0
          while true {
            let previous = examined
            let progress: Progress = try await onQueue(cancellation: cancellation, custody: lease) {
              try self.execute(Request(op: "grapheme_seek_step", revision: revision,
                operationID: id), cancellation: cancellation)
            }
            guard (0...65_536).contains(progress.bufferedBytes), progress.examinedBytes >= previous,
              progress.examinedBytes - previous <= 65_536,
              progress.complete == (progress.result != nil) else {
              throw BoomError.invalid("Grapheme continuation exceeded its bounded source step.")
            }
            examined = progress.examinedBytes
            if progress.complete {
              return try await onQueue(cancellation: cancellation, custody: lease) {
                let result: PagedTextSummary = try self.execute(Request(op: "grapheme_seek_finish",
                  revision: revision, operationID: id), cancellation: cancellation)
                try result.validate()
                guard result == progress.result, result.bytes <= revision.summary.bytes,
                  result.utf16 <= revision.summary.utf16, result.lfCount <= revision.summary.lfCount,
                  forward ? result.utf16 >= utf16Offset : result.utf16 <= utf16Offset else {
                  throw BoomError.invalid("Grapheme boundary belongs to another source extent.")
                }
                try self.rootCustody.joinedBulk(lease, operationID: id)
                try self.rootCustody.finishRead(lease)
                return result
              }
            }
          }
        } catch {
          try await abort(id, documentID: revision.documentID, original: error, custody: lease)
          throw error
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(lease, error: error) {
        throw PagedTextCustodyFailure(original: error, lease: lease)
      }
      throw error
    }
  }

  /// Optional paragraph aggregates skip giant runs. Missing aggregates scan
  /// through bounded steps on the same lane; no LF-only boundary is invented.
  func paragraphBounds(_ revision: PagedTextRevision, utf16Offset: UInt64,
    includeLineEndings: Bool = true, cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextParagraphBounds {
    struct Progress: Decodable, Sendable {
      let complete: Bool
      let result: PagedTextParagraphBounds?
      let bufferedBytes: Int
      let examinedBytes: UInt64
    }
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.source(revision)], payloadBytes: 65_536)
    let bulk: UUID
    do { bulk = try executor.reserveBulk(cancellation, priority: .foreground); try rootCustody.start(lease) }
    catch { _ = try rootCustody.joinedFailure(lease, error: error); throw error }
    defer { executor.releaseBulk(bulk) }
    do {
      return try await withTaskCancellationHandler {
        let id: UUID = try await onQueue(cancellation: cancellation, custody: lease) {
          let id: UUID = try self.execute(Request(op: "paragraph_bounds_begin", revision: revision,
            utf16Offset: utf16Offset, includeLineEndings: includeLineEndings), cancellation: cancellation)
          try self.rootCustody.beganBulk(lease, operationID: id)
          return id
        }
        do {
          var examined: UInt64 = 0
          while true {
            let previous = examined
            let progress: Progress = try await onQueue(cancellation: cancellation, custody: lease) {
              try self.execute(Request(op: "paragraph_bounds_step", revision: revision,
                operationID: id), cancellation: cancellation)
            }
            guard (0...65_536).contains(progress.bufferedBytes), progress.examinedBytes >= previous,
              progress.examinedBytes - previous <= 65_536,
              progress.complete == (progress.result != nil) else {
              throw BoomError.invalid("Paragraph continuation exceeded its bounded source step.")
            }
            examined = progress.examinedBytes
            if progress.complete {
              return try await onQueue(cancellation: cancellation, custody: lease) {
                let result: PagedTextParagraphBounds = try self.execute(Request(op: "paragraph_bounds_finish",
                  revision: revision, operationID: id), cancellation: cancellation)
                try result.validate(in: revision, originUTF16: utf16Offset)
                guard result == progress.result else { throw BoomError.invalid("Paragraph finish lost its actual result.") }
                try self.rootCustody.joinedBulk(lease, operationID: id)
                try self.rootCustody.finishRead(lease)
                return result
              }
            }
          }
        } catch {
          try await abort(id, documentID: revision.documentID, original: error, custody: lease)
          throw error
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(lease, error: error) {
        throw PagedTextCustodyFailure(original: error, lease: lease)
      }
      throw error
    }
  }

  func byteAtUTF16(_ revision: PagedTextRevision, offset: UInt64) async throws -> UInt64 {
    try await rootRead(claims: [.source(revision)]) { try self.execute(Request(op: "position", revision: revision, utf16Offset: offset)) }
  }

  func documentStorageStatistics(_ publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord)
    async throws -> PagedDocumentStorageStatistics {
    try await rootRead(claims: [.record(expected)]) {
      try self.admit(publisher)
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
      let history = try self.withNativeHistory(documentID: expected.document.id, writes: false) { try $0.load(expected) }
      return PagedDocumentStorageStatistics(file: try self.router.files().documentExtent(expected.document.id),
        sourceBytes: expected.document.revision.summary.bytes, undoRoots: history.undo.count, redoRoots: history.redo.count)
    }
  }
  /// Initial constructor only: the caller holds WorkspaceStore's flock and
  /// has not exposed native/model/capture tasks. Backup reopen must not call it.
  func reclaimColdWorkspace(state: WorkspaceState,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextColdReclamation.Statistics {
    let lease = try rootCustody.reserveColdMaintenance(engine: self)
    do {
      let result = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await onQueue(priority: .background, cancellation: cancellation, custody: lease) {
          try self.rootCustody.start(lease)
          let collector = PagedTextColdReclamation(store: try self.router.files(), cancellation: cancellation,
            children: { revision, tree in try self.execute(Request(op: "page_children", revision: revision, tree: tree)) })
          return try collector.run(state: state)
        }
      } onCancel: { cancellation.cancel() }
      try rootCustody.finishColdMaintenance(lease)
      return result
    } catch {
      let original = error
      do { try rootCustody.finishColdMaintenance(lease) }
      catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: lease) }
      throw original
    }
  }
  func fileStatistics() async throws -> PagedTextFileStore.Statistics {
    try await onQueue { try self.router.files().statistics() }
  }

  func stats() async throws -> PagedTextCacheStats {
    try await onQueue { try self.execute(Request(op: "stats")) }
  }

  private func admit(_ publisher: PagedWorkspacePublisher) throws {
    guard publisher.ownerID == ownerID, publisher.store === router.store else { throw BoomError.denied("Publisher belongs to another file workspace.") }
  }
  private func execute<T: Decodable>(_ request: Request, cancellation: PagedTextCancellation = PagedTextCancellation(),
    writes: Bool = false, context retainedContext: PagedTextOperationContext? = nil) throws -> T {
    dispatchPrecondition(condition: .onQueue(queue))
    guard handle != 0, !filesClosed, router.store != nil, !Thread.isMainThread else {
      throw BoomError.unavailable("Paged text source is closed or on the main thread.")
    }
    if cancellation.isCancelled { throw CancellationError() }
    if let revision = request.revision { try revision.validate(); try admit(revision) }
    if let retained = request.retained { try retained.validate(); try admit(retained) }
    if let retained = request.retained, retained.documentID != request.revision?.documentID {
      throw BoomError.denied("Paged checkout crosses document ownership.")
    }
    let document = request.revision?.documentID ?? request.documentID
    if let document {
      guard document != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
        throw BoomError.invalid("Invalid paged operation document.")
      }
    }
    let bytes = try JSONEncoder().encode(request)
    guard !bytes.isEmpty, bytes.count <= 2_097_152 else { throw BoomError.budget("Paged request exceeds its bounded wire format.") }
    let context = try retainedContext ?? PagedTextOperationContext(cancellation: cancellation)
    guard context.cancellation === cancellation else { throw BoomError.invalid("Paged callback has another cancellation owner.") }
    try router.begin(document: document, writes: writes,
      beforeWrite: writes ? { guard let document else { throw BoomError.invalid("Paged writer has no document.") }
        try self.willWrite(document) } : nil)
    defer { router.end() }
    let operation = BloomTextOperation(context: Unmanaged.passUnretained(context).toOpaque(),
      read_stream: context.hasInput ? pagedStreamRead : nil, write_stream: context.hasOutput ? pagedStreamWrite : nil,
      is_cancelled: pagedCancelled)
    if ["import_begin", "hash_begin", "export_begin", "grapheme_seek_begin", "paragraph_bounds_begin", "line_prefix_begin"].contains(request.op) {
      guard let activeCustody else { throw BoomError.denied("Bulk admission has no pre-yield root custody.") }
      // Every throwing Swift preflight has finished. Cancellation before this
      // exact C-entry boundary cannot invent an unjoined unknown Rust producer.
      try rootCustody.willBeginBulk(activeCustody)
    }
    let buffer = withExtendedLifetime(context) {
      bytes.withUnsafeBytes { bloom_text_request(handle, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, operation) }
    }
    defer { boom_attachment_free(buffer) }
    if let failure = router.failure ?? context.failure { throw failure }
    guard let pointer = buffer.data, buffer.length > 0, buffer.length <= 1_048_576 else {
      throw BoomError.invalid("Invalid bounded paged engine reply.")
    }
    let reply = try JSONDecoder().decode(Envelope<T>.self, from: Data(bytes: pointer, count: buffer.length))
    guard reply.schema == 1, reply.ok, let value = reply.value else {
      let message = reply.error?.message ?? "Paged text operation failed."
      switch reply.error?.code {
      case "cancelled": throw CancellationError()
      case "stale": throw BoomError.stale(message)
      case "input_limit", "output_limit": throw BoomError.budget(message)
      case "storage_failed", "engine_closed", "engine_busy", "engine_failed", "engine_panic": throw BoomError.unavailable(message)
      default: throw BoomError.invalid(message)
      }
    }
    return value
  }

  private func admit(_ revision: PagedTextRevision) throws {
    guard revision.ownerID == ownerID else { throw BoomError.denied("Paged operation has another private owner.") }
  }
  private var inFlightWitness: Int {
    let value = executor.snapshot
    return value.foregroundRequests + value.backgroundRequests + value.cleanupRequests
  }
  private func willWrite(_ documentID: UUID) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let activeCustody else { throw BoomError.denied("Paged writer has no admitted root job.") }
    try rootCustody.willWrite(activeCustody, documentID: documentID)
  }

  private func willPublish() throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let activeCustody else { throw BoomError.denied("Paged head has no admitted root job.") }
    try rootCustody.willPublish(activeCustody)
  }

  private func pinCandidate(_ claims: [PagedTextRootClaim]) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let activeCustody else { throw BoomError.denied("Paged candidate has no admitted root job.") }
    try rootCustody.candidate(activeCustody, claims: claims)
  }

  private func onQueue<T: Sendable>(priority: PagedTextStorageExecutor.Priority = .foreground,
    cancellation: PagedTextCancellation? = nil,
    custody: PagedTextRootLease? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await executor.run(priority: priority, cancellation: cancellation) {
      dispatchPrecondition(condition: .onQueue(self.queue))
      guard self.activeCustody == nil else { throw BoomError.invalid("Paged storage has overlapping custody bodies.") }
      self.activeCustody = custody
      defer { self.activeCustody = nil }
      return try work()
    }
  }

  private func rootOutput<T: Sendable>(purpose: PagedTextRootCustody.Purpose = .operation(UUID()),
    claims: [PagedTextRootClaim], payloadBytes: Int = 0, metadataBytes: Int = 0,
    cancellation: PagedTextCancellation? = nil, priority: PagedTextStorageExecutor.Priority = .foreground,
    outputClaims: @escaping @Sendable (T) throws -> [PagedTextRootClaim],
    outputBytes: @escaping @Sendable (T) -> Int = { _ in 0 },
    nativeAcknowledgement: (@Sendable (T) -> PagedNativeCommitAcknowledgement)? = nil,
    logicalInput: PagedNativeLogicalPublication? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> PagedTextCustodiedValue<T> {
    let lease = try rootCustody.reserve(engine: self, purpose: purpose, claims: claims,
      payloadBytes: payloadBytes, metadataBytes: metadataBytes, logicalInput: logicalInput)
    do {
      return try await onQueue(priority: priority, cancellation: cancellation, custody: lease) {
        try self.rootCustody.start(lease)
        let value = try work()
        try self.rootCustody.finishOutput(lease, claims: outputClaims(value), payloadBytes: outputBytes(value),
          inFlightWitness: self.inFlightWitness, nativeAcknowledgement: nativeAcknowledgement?(value))
        return PagedTextCustodiedValue(value: value, lease: lease)
      }
    } catch {
      if try rootCustody.joinedFailure(lease, error: error) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }
  private func rootRead<T: Sendable>(claims: [PagedTextRootClaim],
    _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: claims)
    do {
      return try await onQueue(custody: lease) {
        try self.rootCustody.start(lease); let result = try work(); try self.rootCustody.finishRead(lease); return result
      }
    } catch { _ = try rootCustody.joinedFailure(lease, error: error); throw error }
  }
  func adoptUnclaimedRootOutput(_ id: UUID) throws -> PagedTextRootLease { try rootCustody.adoptUnclaimed(id) }
  func abandonJoinedRootOutput(_ lease: PagedTextRootLease) async throws { try await onQueue(custody: lease) { try self.rootCustody.abandonJoined(lease) } }
  func transferJoinedRootToHead(_ lease: PagedTextRootLease, publisher: PagedWorkspacePublisher,
    expected: PagedDocumentRootRecord) async throws {
    try await onQueue(custody: lease) {
      try self.admit(publisher); try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.transferJoinedToHead(lease, record: expected)
    }
  }
  func installNativeCustody(_ output: PagedTextRootLease, controller: PagedTextRootLease,
    expected: PagedDocumentRootRecord, record: PagedDocumentRootRecord) throws { try rootCustody.installControllerOutput(output, into: controller, expected: expected, record: record) }
  func finishNativeCommitCustody(_ controller: PagedTextRootLease,
    acknowledgement: PagedNativeCommitAcknowledgement, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(custody: controller) {
      try self.admit(publisher); try publisher.admitCurrentRecord(acknowledgement.sealedRootRecord, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.finishNativeCommit(controller, acknowledgement: acknowledgement)
    }
  }
  func joinRetainedBulkFailure(_ lease: PagedTextRootLease, documentID: UUID) async throws {
    let token = try rootCustody.unresolvedBulk(lease)
    try await onQueue(priority: .cleanup, custody: lease) {
      let joined: Bool = try self.execute(Request(op: "bulk_abort", ownerID: self.ownerID, documentID: documentID, operationID: token))
      guard joined else { throw BoomError.unavailable("Source stream did not join.") }
      try self.rootCustody.joinedBulk(lease, operationID: token)
    }
  }

}
