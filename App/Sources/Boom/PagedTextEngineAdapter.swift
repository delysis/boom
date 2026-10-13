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
        initial.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        initial.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, initial.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
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
  /// Read-only copied display text from a captured immutable root plus the
  /// current bounded working island. No durable-head CAS, flush, writer queue,
  /// actor commit guard or retained output lease participates in this read.
  func scrollProjection(_ snapshot: PagedNativeScrollSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int = PagedWorkingWindow.targetBytes) async throws -> PagedNativeScrollProjection {
    try Task.checkCancellation()
    guard snapshot.revision.ownerID == ownerID,
      (4...PagedWorkingWindow.targetBytes).contains(maximumBytes) else {
      throw BoomError.denied("Scroll read has another owner or display bound.")
    }
    let charge = snapshot.source.text.utf8.count + snapshot.replacement.count + maximumBytes
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.source(snapshot.revision)], payloadBytes: charge)
    let cancellation = PagedTextCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        scrollReadQueue.async {
          do {
            try self.rootCustody.start(lease)
            if cancellation.isCancelled { throw CancellationError() }
            let value = try autoreleasepool {
              let reader = PagedImmutableScrollReadContext(root: self.sourceRoot, ownerID: self.ownerID,
                storeID: self.sourceStoreID, documentID: snapshot.revision.documentID, cancellation: cancellation)
              return try PagedNativeScrollProjection.compose(snapshot, utf16Anchor: utf16Anchor,
                maximumBytes: maximumBytes) { offset, budget in
                try self.readImmutableScrollWindow(snapshot.revision, utf16Offset: offset,
                  maximumBytes: budget, reader: reader)
              }
            }
            if cancellation.isCancelled { throw CancellationError() }
            // All C callbacks/cache/file handles have returned before this
            // source pin disappears. Display text needs no later file access.
            try self.rootCustody.finishRead(lease)
            continuation.resume(returning: value)
          } catch {
            do {
              if try self.rootCustody.joinedFailure(lease, error: error) {
                continuation.resume(throwing: PagedTextCustodyFailure(original: error, lease: lease))
              } else { continuation.resume(throwing: error) }
            } catch let handoff {
              continuation.resume(throwing: PagedTextCustodyHandoffFailure(original: error, handoff: handoff, lease: lease))
            }
          }
        }
      }
    } onCancel: { cancellation.cancel() }
  }

  private func readImmutableScrollWindow(_ revision: PagedTextRevision, utf16Offset: UInt64,
    maximumBytes: Int, reader: PagedImmutableScrollReadContext) throws -> PagedTextWindow {
    let bytes = try JSONEncoder().encode(revision)
    guard bytes.count <= 16_384 else { throw BoomError.budget("Immutable revision exceeds its read envelope.") }
    let pointer = Unmanaged.passUnretained(reader).toOpaque()
    let host = BloomTextHost(schema: 3, context: pointer, read_page: pagedImmutableScrollRead, write_page: nil)
    let operation = BloomTextOperation(context: pointer, read_stream: nil, write_stream: nil,
      is_cancelled: pagedImmutableScrollCancelled)
    let buffer = withExtendedLifetime(reader) {
      bytes.withUnsafeBytes {
        bloom_text_read_window(host, $0.bindMemory(to: UInt8.self).baseAddress,
          bytes.count, utf16Offset, maximumBytes, operation)
      }
    }
    defer { boom_attachment_free(buffer) }
    if let failure = reader.failure { throw failure }
    guard let data = buffer.data, (1...131_072).contains(buffer.length) else {
      throw BoomError.invalid("Invalid bounded immutable read reply.")
    }
    let reply = try JSONDecoder().decode(Envelope<PagedTextWindow>.self, from: Data(bytes: data, count: buffer.length))
    guard reply.schema == 1, reply.ok, let value = reply.value else {
      if reply.error?.code == "cancelled" { throw CancellationError() }
      throw BoomError.unavailable(reply.error?.message ?? "Immutable scroll read failed.")
    }
    return value
  }

  func makeWorkspacePublisher() async throws -> PagedWorkspacePublisher {
    try await onQueue { PagedWorkspacePublisher(store: try self.router.files()) }
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

  func commitCapturedEditRetaining(_ input: PagedCapturedEditInput,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedCapturedEditResult> {
    if case .linePrefix(let selection, let prefix) = input.operation {
      return try await commitLinePrefixRetaining(input, selection: selection, prefix: prefix, publisher: publisher)
    }
    return try await rootOutput(purpose: .capturedEdit(sessionID: input.sessionID, commandID: input.commandID, sequence: input.sequence),
      claims: [.record(input.expected), .writerDocument(input.expected.document.id), .workspace],
      payloadBytes: PagedWorkingWindow.targetBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { [.record(input.expected), .record($0.record), .writerDocument(input.expected.document.id), .workspace] },
      outputBytes: { $0.window.text.utf8.count + PagedNativeCanonicalHistoryProjection.chargedBytes }, capturedInput: input) {
      try self.makeCapturedEdit(input, publisher: publisher)
    }
  }

  private struct LinePrefixProgress: Decodable, Sendable {
    let complete: Bool
    let processedBytes: UInt64
    let examinedBytes: UInt64
    let bufferedBytes: Int
  }
  private struct LinePrefixResult: Decodable, Sendable {
    let revision: PagedTextRevision
    let byteStart: UInt64
    let byteEnd: UInt64
    let utf16Start: UInt64
    let utf16Length: UInt64
    let removing: Bool
    let changed: Bool
  }

  /// A long selection occupies one existing bulk slot and one source job.
  /// Each source step yields this executor; only the final root enters history.
  private func commitLinePrefixRetaining(_ input: PagedCapturedEditInput,
    selection: PagedNativeNavigationSelection, prefix: String,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedCapturedEditResult> {
    let cancellation = PagedTextCancellation()
    let lease = try rootCustody.reserve(engine: self,
      purpose: .capturedEdit(sessionID: input.sessionID, commandID: input.commandID, sequence: input.sequence),
      claims: [.record(input.expected), .writerDocument(input.expected.document.id), .workspace],
      payloadBytes: 65_536, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes, capturedInput: input)
    let bulk: UUID
    do { bulk = try executor.reserveBulk(cancellation, priority: .foreground); try rootCustody.start(lease) }
    catch { _ = try rootCustody.joinedFailure(lease, error: error); throw error }
    defer { executor.releaseBulk(bulk) }
    do {
      return try await withTaskCancellationHandler {
        let id: UUID = try await onQueue(cancellation: cancellation, custody: lease) {
          try self.admitCapturedEdit(input, publisher: publisher)
          let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
          guard !end.overflow, end.partialValue <= input.expected.document.revision.summary.utf16 else {
            throw BoomError.invalid("Line prefix has another source selection.")
          }
          let id: UUID = try self.execute(Request(op: "line_prefix_begin", revision: input.expected.document.revision,
            utf16Start: selection.utf16Offset, utf16End: end.partialValue, prefix: prefix), cancellation: cancellation)
          try self.rootCustody.beganBulk(lease, operationID: id)
          return id
        }
        let transformed: LinePrefixResult
        do {
          var processed: UInt64 = 0, examined: UInt64 = 0
          while true {
            let previousProcessed = processed, previousExamined = examined
            let progress: LinePrefixProgress = try await onQueue(priority: .background, cancellation: cancellation, custody: lease) {
              try self.execute(Request(op: "line_prefix_step", revision: input.expected.document.revision,
                operationID: id), cancellation: cancellation, writes: true)
            }
            // Sharing a whole immutable subtree can advance processedBytes
            // by more than one page without reading its text.
            guard progress.processedBytes >= previousProcessed,
              progress.examinedBytes >= previousExamined,
              progress.examinedBytes - previousExamined <= 65_536,
              (0...65_536).contains(progress.bufferedBytes) else {
              throw BoomError.invalid("Line prefix exceeded its bounded source step.")
            }
            processed = progress.processedBytes; examined = progress.examinedBytes
            if progress.complete { break }
          }
          transformed = try await onQueue(priority: .background, cancellation: cancellation, custody: lease) {
            let result: LinePrefixResult = try self.execute(Request(op: "line_prefix_finish",
              revision: input.expected.document.revision, operationID: id), cancellation: cancellation)
            try result.revision.validate()
            let end = result.utf16Start.addingReportingOverflow(result.utf16Length)
            guard result.revision.ownerID == self.ownerID,
              result.revision.documentID == input.expected.document.id,
              result.byteStart <= result.byteEnd, result.byteEnd <= result.revision.summary.bytes,
              result.byteStart <= input.expected.document.revision.summary.bytes,
              result.utf16Start <= input.expected.document.revision.summary.utf16,
              !end.overflow, end.partialValue <= result.revision.summary.utf16,
              result.revision.summary.lfCount == input.expected.document.revision.summary.lfCount,
              result.changed == (result.revision != input.expected.document.revision) else {
              throw BoomError.invalid("Line prefix finish lost its actual source extent.")
            }
            let startByte: UInt64 = try self.execute(Request(op: "position", revision: result.revision,
              utf16Offset: result.utf16Start), cancellation: cancellation)
            let endByte: UInt64 = try self.execute(Request(op: "position", revision: result.revision,
              utf16Offset: end.partialValue), cancellation: cancellation)
            guard startByte == result.byteStart, endByte == result.byteEnd else {
              throw BoomError.invalid("Line prefix selection lost its scalar coordinates.")
            }
            // Validate before joining: if the finish consumed its Rust token,
            // the existing idempotent abort still supplies the exact join.
            try self.rootCustody.joinedBulk(lease, operationID: id)
            return result
          }
        } catch {
          try await abort(id, documentID: input.expected.document.id, original: error, custody: lease)
          throw error
        }
        return try await onQueue(cancellation: cancellation, custody: lease) {
          let after = PagedNativeNavigationSelection(utf16Offset: transformed.utf16Start,
            utf16Length: transformed.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
          let result = try self.publishCapturedCandidate(input, publisher: publisher, candidate: transformed.revision,
            endpoint: transformed.byteEnd, afterSelection: after)
          try self.rootCustody.finishOutput(lease,
            claims: [.record(input.expected), .record(result.record), .writerDocument(input.expected.document.id), .workspace],
            payloadBytes: result.window.text.utf8.count + PagedNativeCanonicalHistoryProjection.chargedBytes,
            inFlightWitness: self.inFlightWitness)
          return PagedTextCustodiedValue(value: result, lease: lease)
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(lease, error: error) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }

  private func admitCapturedEdit(_ input: PagedCapturedEditInput,
    publisher: PagedWorkspacePublisher) throws {
    try admit(publisher); try input.expected.validate(); try input.beforeCursor.validate(in: input.expected.document.revision)
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard input.sessionID != zero, input.commandID != zero, input.groupID != zero, input.sequence > 0 else {
      throw BoomError.invalid("Captured edit lacks an exact native command identity.")
    }
    try publisher.admitCurrentRecord(input.expected, validateRecord: { try self.validateNativeRecord($0) })
    let beforeByte: UInt64 = try execute(Request(op: "position", revision: input.expected.document.revision,
      utf16Offset: input.beforeCursor.utf16Offset))
    guard beforeByte == input.beforeCursor.byteOffset else { throw BoomError.stale("Captured edit has another observed start cursor.") }
    if input.beforeCursor.selectionLengthUTF16 > 0 {
      let selectionEnd = input.beforeCursor.utf16Offset + input.beforeCursor.selectionLengthUTF16
      let _: UInt64 = try execute(Request(op: "position", revision: input.expected.document.revision, utf16Offset: selectionEnd))
    }
    switch input.operation {
    case .replacement, .linePrefix:
      guard input.afterSelection == nil else { throw BoomError.invalid("This command uses its actual transformed source selection.") }
    case .edits: break
    }
  }

  private func makeCapturedEdit(_ input: PagedCapturedEditInput,
    publisher: PagedWorkspacePublisher) throws -> PagedCapturedEditResult {
    try admitCapturedEdit(input, publisher: publisher)
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    var candidate = input.expected.document.revision
    var endpoint: UInt64?
    switch input.operation {
    case .edits(let edits):
      var previousStart: UInt64?, previousWasInsertion = false
      for edit in edits {
        guard edit.revision == input.expected.document.revision, edit.windowID != zero,
          edit.byteStart <= edit.byteEnd, edit.byteEnd <= input.expected.document.revision.summary.bytes,
          edit.byteEnd - edit.byteStart == UInt64(edit.oldBytes.count),
          let old = String(data: edit.oldBytes, encoding: .utf8), let new = String(data: edit.newBytes, encoding: .utf8) else {
          throw BoomError.stale("Captured edit has another immutable source or exact scalar range.")
        }
        if let previousStart {
          guard edit.byteEnd <= previousStart,
            !(previousWasInsertion && edit.byteStart == previousStart && edit.byteStart == edit.byteEnd) else {
            throw BoomError.invalid("Captured edits must be nonoverlapping and ordered from tail to head.")
          }
        }
        previousStart = edit.byteStart; previousWasInsertion = edit.byteStart == edit.byteEnd
        // Even an unchanged primitive must authenticate its exact old bytes.
        let prior = candidate
        candidate = try execute(Request(op: "splice", revision: candidate, byteStart: edit.byteStart,
          byteEnd: edit.byteEnd, oldText: old, newText: new), writes: true)
        if candidate != prior {
          let end = edit.byteStart.addingReportingOverflow(UInt64(edit.newBytes.count))
          guard !end.overflow else { throw BoomError.budget("Captured edit cursor exceeds source coordinates.") }
          endpoint = end.partialValue
        }
      }
    case .replacement(let selection, let replacement):
      let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
      guard !end.overflow, end.partialValue <= input.expected.document.revision.summary.utf16,
        let new = String(data: replacement, encoding: .utf8) else {
        throw BoomError.invalid("User replacement has another exact global selection or UTF8 buffer.")
      }
      let startByte: UInt64 = try execute(Request(op: "position", revision: candidate, utf16Offset: selection.utf16Offset))
      let endByte: UInt64 = try execute(Request(op: "position", revision: candidate, utf16Offset: end.partialValue))
      candidate = try execute(Request(op: "replace_user_range", revision: candidate,
        byteStart: startByte, byteEnd: endByte, newText: new), writes: true)
      let afterByte = startByte.addingReportingOverflow(UInt64(replacement.count))
      guard !afterByte.overflow else { throw BoomError.budget("Replacement cursor exceeds source coordinates.") }
      endpoint = afterByte.partialValue
    case .linePrefix:
      throw BoomError.invalid("Line prefix must enter its bounded source continuation.")
    }
    return try publishCapturedCandidate(input, publisher: publisher, candidate: candidate,
      endpoint: endpoint, afterSelection: input.afterSelection)
  }

  /// All explicit source transforms publish the same complete history/root,
  /// canonical projection and bounded cursor island exactly once.
  private func publishCapturedCandidate(_ input: PagedCapturedEditInput,
    publisher: PagedWorkspacePublisher, candidate: PagedTextRevision, endpoint: UInt64?,
    afterSelection: PagedNativeNavigationSelection?) throws -> PagedCapturedEditResult {
    try admit(publisher)
    try publisher.admitCurrentRecord(input.expected, validateRecord: { try self.admitNavigationRecord($0) })
    var history = try withNativeHistory(documentID: input.expected.document.id, writes: false) { try $0.load(input.expected) }
    let beforeHistory = history
    guard candidate != input.expected.document.revision, let endpoint else {
      try publisher.admitCurrentRecord(input.expected, validateRecord: { try self.admitNavigationRecord($0) })
      throw PagedCapturedEditUnchanged(record: input.expected, commandID: input.commandID)
    }
    let cursor: PagedSealedCursor
    if let selection = afterSelection {
      let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
      guard !end.overflow, end.partialValue <= candidate.summary.utf16 else {
        throw BoomError.invalid("Formatted selection exceeds its actual changed source.")
      }
      let startByte: UInt64 = try execute(Request(op: "position", revision: candidate, utf16Offset: selection.utf16Offset))
      let _: UInt64 = try execute(Request(op: "position", revision: candidate, utf16Offset: end.partialValue))
      cursor = PagedSealedCursor(byteOffset: startByte, utf16Offset: selection.utf16Offset,
        selectionLengthUTF16: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
    } else {
      let position: PagedTextSummary = try execute(Request(op: "byte_position", revision: candidate, byteStart: endpoint))
      try position.validate()
      guard position.bytes == endpoint else { throw BoomError.invalid("Captured edit lost its exact changed endpoint.") }
      cursor = PagedSealedCursor(byteOffset: position.bytes, utf16Offset: position.utf16)
    }
    try history.record(candidate, cursor: cursor, beforeCursor: input.beforeCursor, groupID: input.groupID)
    let window = try nativeHistoryWindow(candidate, cursor: cursor)
    let localCaret = cursor.focusUTF16 - window.utf16Start
    guard let localCaretUTF16 = Int(exactly: localCaret) else { throw BoomError.budget("Captured caret exceeds the bounded native island.") }
    let document = PagedDocumentDescriptor(id: input.expected.document.id, title: input.expected.document.title, revision: candidate)
    let record = try withNativeHistory(documentID: document.id, writes: true) { try $0.writeNew(history, document: document) }
    try pinCandidate([.record(input.expected), .record(record), .writerDocument(document.id), .workspace])
    let undoLineage: [Int?]
    if beforeHistory.activeGroup == input.groupID {
      undoLineage = beforeHistory.undo.indices.map { Optional($0) }
    } else {
      let expired = beforeHistory.undo.count + 1 - history.undo.count
      guard (0...1).contains(expired) else { throw BoomError.invalid("Captured Undo lineage has another expiry.") }
      undoLineage = (expired..<beforeHistory.undo.count).map { Optional($0) } + [nil]
    }
    guard let producer = activeCustody else { throw BoomError.denied("Captured edit lost its entered source job.") }
    let canonical = try PagedNativeCanonicalHistoryProjection(storageHistory: history, record: record,
      beforeRecord: input.expected, beforeHistory: beforeHistory,
      scope: .capturedEdit(sessionID: input.sessionID, commandID: input.commandID, sequence: input.sequence),
      producer: producer, undoFromBefore: undoLineage, redoFromBefore: [])
    let result = PagedCapturedEditResult(sessionID: input.sessionID, commandID: input.commandID, groupID: input.groupID,
      sequence: input.sequence, beforeRecord: input.expected, record: record, window: window, cursor: cursor,
      localCaretUTF16: localCaretUTF16, canonicalHistory: canonical)
    try result.validate(); try rootCustody.stageCaptured(producer, result: result)
    try willPublish()
    let published = try publisher.publishDocument(record, expected: input.expected, validateRecord: { try self.validateNativeRecord($0) })
    guard published.record == record else { throw BoomError.invalid("Captured file publication changed its complete root.") }
    try rootCustody.publicationCompleted(producer)
    return result
  }

  func finishCapturedEditCustody(_ controller: PagedTextRootLease, result: PagedCapturedEditResult,
    publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(custody: controller) {
      try self.admit(publisher)
      try publisher.admitCurrentRecord(result.record, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.finishCapturedInstallation(controller, result: result)
    }
  }

  func commitNativeRetaining(_ batch: PagedNativeCommitBatch,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    try await rootOutput(purpose: .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID,
      first: batch.firstSequence, last: batch.lastSequence),
      claims: [.record(batch.expectedRootRecord), .writerDocument(batch.expected.revision.documentID), .workspace],
      payloadBytes: PagedWorkingWindow.hardBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { [.record(batch.expectedRootRecord), .record($0.sealedRootRecord), .writerDocument(batch.expected.revision.documentID), .workspace] },
      outputBytes: { $0.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes },
      nativeAcknowledgement: { $0 }, nativeInput: batch) {
      try self.makeNativeAcknowledgement(batch, publisher: publisher)
    }
  }
  private func makeNativeAcknowledgement(_ batch: PagedNativeCommitBatch,
    publisher: PagedWorkspacePublisher) throws -> PagedNativeCommitAcknowledgement {
      try self.admit(publisher)
      let plan = try PagedNativeCommitPlan(batch)
      try self.willPublish() // Actual transaction publication, never a read-only mark.
      try publisher.admitCurrentRecord(batch.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      _ = try self.readNativeIsland(batch.expected.revision, anchor: batch.expected,
        exactBytes: plan.initialBytes)
      var history = try self.withNativeHistory(documentID: batch.expected.revision.documentID, writes: false) {
        try $0.load(batch.expectedRootRecord)
      }
      let beforeHistory = history
      var lineage = PagedNativeHistorySlotLineage(history)
      var candidate = batch.expected.revision, priorBytes = plan.initialBytes
      for step in plan.steps {
        if case .epochOnly = step.kind, priorBytes != step.afterBytes {
          throw BoomError.invalid("An epoch-only native step cannot change source bytes.")
        }
        if priorBytes != step.afterBytes {
          let end = batch.expected.byteStart.addingReportingOverflow(UInt64(priorBytes.count))
          guard !end.overflow, let old = String(data: priorBytes, encoding: .utf8),
            let new = String(data: step.afterBytes, encoding: .utf8) else {
            throw BoomError.invalid("Native candidate loses its exact scalar island.")
          }
          candidate = try self.execute(Request(op: "splice", revision: candidate,
            byteStart: batch.expected.byteStart, byteEnd: end.partialValue, oldText: old, newText: new), writes: true)
        }
        let cursorByte = batch.expected.byteStart.addingReportingOverflow(UInt64(step.localCursorByte))
        let cursorUTF16 = batch.expected.utf16Start.addingReportingOverflow(UInt64(step.localCursorUTF16))
        guard !cursorByte.overflow, !cursorUTF16.overflow else {
          throw BoomError.budget("Native candidate cursor exceeds global source coordinates.")
        }
        let cursor = PagedSealedCursor(byteOffset: cursorByte.partialValue, utf16Offset: cursorUTF16.partialValue,
          selectionLengthUTF16: UInt64(step.localSelectionLengthUTF16),
          focusAtEnd: step.localFocusAtEnd, affinity: step.localAffinity)
        switch step.kind {
        case .expiredGroupBaseline:
          try history.advanceExpiredNativeGroups(to: candidate, cursor: cursor); lineage.expiredBaseline()
        case .nativeGroup:
          guard let groupID = step.groupID else { throw BoomError.invalid("A native history group has no captured identity.") }
          guard let localBefore = step.beforeCursor else { throw BoomError.invalid("A native history group has no observed start cursor.") }
          let beforeByte = batch.expected.byteStart.addingReportingOverflow(UInt64(localBefore.byteOffset))
          let beforeUTF16 = batch.expected.utf16Start.addingReportingOverflow(UInt64(localBefore.utf16Offset))
          guard !beforeByte.overflow, !beforeUTF16.overflow else {
            throw BoomError.budget("Native group start cursor exceeds global source coordinates.")
          }
          let beforeCursor = PagedSealedCursor(byteOffset: beforeByte.partialValue, utf16Offset: beforeUTF16.partialValue,
            selectionLengthUTF16: UInt64(localBefore.selectionLengthUTF16),
            focusAtEnd: localBefore.focusAtEnd, affinity: localBefore.affinity)
          let priorRevision = history.current, priorActive = history.activeGroup, priorCount = history.undo.count
          try history.record(candidate, cursor: cursor, beforeCursor: beforeCursor, groupID: groupID)
          guard let checkpoint = batch.groupCheckpoints.first(where: { $0.lastSequence == step.lastSequence && $0.groupID == groupID }) else {
            throw BoomError.invalid("Canonical native lineage lost its actual bounded checkpoint.")
          }
          try lineage.nativeRecord(priorRevision: priorRevision, priorActive: priorActive,
            priorUndoCount: priorCount, beforeCursor: beforeCursor, after: history, checkpoint: checkpoint)
        case .epochOnly:
          guard candidate == history.current else { throw BoomError.invalid("Native epoch advancement has another source root.") }
          try history.advanceNativeEpoch(cursor: cursor)
        }
        priorBytes = step.afterBytes
      }
      let sealedWindow = try self.readNativeIsland(candidate, anchor: batch.expected, exactBytes: batch.afterBytes)
      let document = PagedDocumentDescriptor(id: batch.expectedRootRecord.document.id,
        title: batch.expectedRootRecord.document.title, revision: candidate)
      let sealedRecord = try self.withNativeHistory(documentID: document.id, writes: true) {
        try $0.writeNew(history, document: document)
      }
      try self.pinCandidate([.record(batch.expectedRootRecord), .record(sealedRecord),
        .writerDocument(document.id), .workspace])
      let canonical = try self.nativeCanonicalProjection(history: history, beforeHistory: beforeHistory,
        record: sealedRecord, beforeRecord: batch.expectedRootRecord,
        scope: .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID,
          first: batch.firstSequence, last: batch.lastSequence), lineage: lineage)
      let acknowledgement = try PagedNativeCommitAcknowledgement(validating: batch, sealedWindow: sealedWindow,
        sealedRootRecord: sealedRecord, canonicalHistory: canonical)
      guard let lease = activeCustody else { throw BoomError.denied("Native write lost its entered job.") }
      try rootCustody.stageNative(lease, acknowledgement: acknowledgement)
      let published = try publisher.publishDocument(sealedRecord, expected: batch.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      guard published.record == sealedRecord else { throw BoomError.invalid("File publication changed its complete root.") }
      try rootCustody.publicationCompleted(lease)
      return acknowledgement

  }

  private func admitNavigationRecord(_ record: PagedDocumentRootRecord) throws {
    try record.validate(); try admit(record.document.revision)
    let actual: PagedTextRevision = try execute(Request(op: "open", revision: record.document.revision))
    guard actual == record.document.revision else { throw BoomError.stale("Navigation source changed during admission.") }
  }

  func nativeNavigationPosition(publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord,
    utf16Offset: UInt64, forward: Bool = false) async throws -> PagedTextSummary {
    try await rootRead(claims: [.record(expected), .workspace]) {
      try self.admit(publisher)
        try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
        let position: PagedTextSummary = try self.execute(Request(op: "scalar_position",
          revision: expected.document.revision, utf16Offset: utf16Offset, forward: forward))
        try position.validate()
        let next = utf16Offset.addingReportingOverflow(1)
        guard position.bytes <= expected.document.revision.summary.bytes,
          position.utf16 <= expected.document.revision.summary.utf16,
          position.lfCount <= expected.document.revision.summary.lfCount,
          position.utf16 == utf16Offset || (forward
            ? !next.overflow && position.utf16 == next.partialValue
            : utf16Offset > 0 && position.utf16 == utf16Offset - 1) else {
          throw BoomError.invalid("Navigation did not return its actual bounded scalar position.")
        }
        try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
        return position
    }
  }

  func nativeScrollWindowRetaining(publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord,
    utf16Anchor: UInt64) async throws -> PagedTextCustodiedValue<PagedTextWindow> {
    try await rootOutput(claims: [.record(expected), .workspace], payloadBytes: PagedWorkingWindow.targetBytes,
      outputClaims: { _ in [.record(expected), .workspace] }, outputBytes: { $0.text.utf8.count }) {
      try self.admit(publisher)
        try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
        let position: PagedTextSummary = try self.execute(Request(op: "scalar_position",
          revision: expected.document.revision, utf16Offset: utf16Anchor, forward: false))
        let window: PagedTextWindow = try self.execute(Request(op: "window", revision: expected.document.revision,
          byteStart: position.bytes, maximumBytes: PagedWorkingWindow.targetBytes))
        try window.validate()
        guard window.byteStart == position.bytes, window.utf16Start == position.utf16,
          window.lfStart == position.lfCount, window.revision == expected.document.revision else {
          throw BoomError.invalid("Scroll projection has another source or actual prefix.")
        }
        try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
        return window
    }
  }

  func nativeWindowRetaining(publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord,
    utf16Anchor: UInt64, maximumBytes: Int) async throws -> PagedTextCustodiedValue<PagedTextWindow> {
    guard maximumBytes > 0, maximumBytes <= PagedWorkingWindow.targetBytes else {
      throw BoomError.budget("Native navigation exceeds its fixed TextKit island.")
    }
    return try await rootOutput(claims: [.record(expected), .workspace], payloadBytes: maximumBytes,
      outputClaims: { _ in [.record(expected), .workspace] }, outputBytes: { $0.text.utf8.count }) {
      try self.admit(publisher)
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
      let start: UInt64 = try self.execute(Request(op: "position", revision: expected.document.revision,
        utf16Offset: utf16Anchor))
      let window: PagedTextWindow = try self.execute(Request(op: "window", revision: expected.document.revision,
        byteStart: start, maximumBytes: maximumBytes))
      try window.validate()
      guard window.revision == expected.document.revision, window.byteStart == start,
        window.utf16Start == utf16Anchor, window.text.utf8.count <= maximumBytes else {
        throw BoomError.invalid("Native navigation returned another source or anchor.")
      }
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.admitNavigationRecord($0) })
      return window
    }
  }

  func prepareNativeHistoryMoveRetaining(_ command: PagedNativeHistoryMoveCommand, routeID: UUID,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativePreparedHistoryMove> {
    try await rootOutput(purpose: .nativePreparation(routeID: routeID, commandID: command.commandID),
      claims: [.record(command.expectedRootRecord), .writerDocument(command.handle.documentID), .workspace],
      payloadBytes: PagedWorkingWindow.targetBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { [.record(command.expectedRootRecord), .record($0.candidateRecord),
        .writerDocument(command.handle.documentID), .workspace] },
      outputBytes: { $0.windowBytes + PagedNativeCanonicalHistoryProjection.chargedBytes }, preparation: { $0 }) {
      try self.admit(publisher); try command.validate()
      try publisher.admitCurrentRecord(command.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      let planned = try self.plannedNativeHistory(command)
      let history = planned.after
      let window = try self.nativeHistoryWindow(history.current, cursor: history.currentCursor)
      let localCaret = history.currentCursor.focusUTF16 - window.utf16Start
      guard let localCaretUTF16 = Int(exactly: localCaret) else {
        throw BoomError.budget("Retained history cursor exceeds native island coordinates.")
      }
      let document = PagedDocumentDescriptor(id: command.expectedRootRecord.document.id,
        title: command.expectedRootRecord.document.title, revision: history.current)
      let record = try self.withNativeHistory(documentID: document.id, writes: true) { store in
        let written = try store.writeNew(history, document: document)
        guard try store.load(written) == history else {
          throw BoomError.invalid("Prepared history differs from the exact retained-root move.")
        }
        return written
      }
      try self.pinCandidate([.record(command.expectedRootRecord), .record(record),
        .writerDocument(command.handle.documentID), .workspace])
      try publisher.admitCurrentRecord(command.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      return try PagedNativePreparedHistoryMove(validating: command, routeID: routeID,
        candidateRecord: record, window: window, cursor: history.currentCursor,
        localCaretUTF16: localCaretUTF16,
        canonicalHistory: try self.nativeCanonicalProjection(history: history, beforeHistory: planned.before,
          record: record, beforeRecord: command.expectedRootRecord,
          scope: .historyCandidate(sessionID: command.sessionID, routeID: routeID,
            commandID: command.commandID, expected: command.expectedSequence), lineage: planned.lineage))
    }
  }

  private struct NativeHistoryPlan { let before: PagedRootHistory; let after: PagedRootHistory; let lineage: PagedNativeHistorySlotLineage }
  private struct ValidatedNativeHistory { let window: PagedTextWindow; let plan: NativeHistoryPlan }
  private func plannedNativeHistory(_ command: PagedNativeHistoryMoveCommand) throws -> NativeHistoryPlan {
    try command.validate(); try admit(command.expectedRootRecord.document.revision)
    var history = try withNativeHistory(documentID: command.handle.documentID, writes: false) {
      try $0.load(command.expectedRootRecord)
    }
    let before = history
    var lineage = PagedNativeHistorySlotLineage(history)
    if let selection = command.canonicalSelection {
      try selection.admit(record: command.expectedRootRecord, history: history,
        sessionID: command.sessionID, sequence: command.expectedSequence, engineIncarnation: custodyIncarnation)
    }
    let entry = command.handle.direction == .undo ? history.undo.last : history.redo.last
    guard let entry, entry.groupID == command.handle.groupID else {
      throw BoomError.stale("Native history handle is not the exact next retained group in this direction.")
    }
    let target: PagedTextRevision = try execute(Request(op: "checkout",
      revision: history.current, retained: entry.revision))
    guard target == entry.revision else {
      throw BoomError.invalid("Retained history checkout changed its exact immutable root.")
    }
    switch command.handle.direction {
    case .undo: _ = try history.stepUndo(expected: command.expectedRootRecord.document.revision)
    case .redo: _ = try history.stepRedo(expected: command.expectedRootRecord.document.revision)
    }
    guard history.current == target, history.currentCursor == entry.cursor else {
      throw BoomError.invalid("Retained history move lost its selected root or cursor.")
    }
    // Cursor bounds alone do not prove exact byte/UTF16 agreement or scalar
    // boundaries. This visits a tree path and one bounded source page.
    let byte: UInt64 = try execute(Request(op: "position", revision: target,
      utf16Offset: history.currentCursor.utf16Offset))
    guard byte == history.currentCursor.byteOffset else {
      throw BoomError.invalid("Retained history cursor differs from its actual source coordinates.")
    }
    lineage.moved(command.handle.direction)
    return NativeHistoryPlan(before: before, after: history, lineage: lineage)
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
    try PagedNativePreparedHistoryMove.validate(window: window, cursor: cursor, localCaretUTF16: localCaret)
    return window
  }

  private func validatePreparedNativeHistory(_ prepared: PagedNativePreparedHistoryMove) throws -> ValidatedNativeHistory {
    let planned = try plannedNativeHistory(prepared.command)
    let history = planned.after
    let expectedDocument = PagedDocumentDescriptor(id: prepared.command.handle.documentID,
      title: prepared.command.expectedRootRecord.document.title, revision: history.current)
    guard prepared.candidateRecord.document == expectedDocument,
      prepared.candidateRecord.historyGeneration == history.generation,
      prepared.cursor == history.currentCursor else {
      throw BoomError.invalid("Prepared native history has another retained root, generation or exact cursor.")
    }
    let stored = try withNativeHistory(documentID: expectedDocument.id, writes: false) {
      try $0.load(prepared.candidateRecord)
    }
    guard stored == history,
      let canonical = prepared.canonicalHistory, canonical.record == prepared.candidateRecord,
      canonical.beforeRecord == prepared.command.expectedRootRecord,
      canonical.undo == history.undo, canonical.redo == history.redo, canonical.currentCursor == history.currentCursor,
      canonical.activeGroup == history.activeGroup,
      canonical.undoFromBefore == planned.lineage.undo, canonical.redoFromBefore == planned.lineage.redo,
      canonical.producer.ownerID == ownerID, canonical.producer.engineIncarnation == custodyIncarnation,
      canonical.scope == .historyCandidate(sessionID: prepared.command.sessionID, routeID: prepared.routeID,
        commandID: prepared.command.commandID, expected: prepared.command.expectedSequence) else {
      throw BoomError.invalid("prepared history differs from the admitted native move.")
    }
    let window = try readNativeIsland(history.current, anchor: prepared.window,
      exactBytes: Data(prepared.window.text.utf8))
    try PagedNativePreparedHistoryMove.validate(window: window, cursor: prepared.cursor,
      localCaretUTF16: prepared.localCaretUTF16)
    return ValidatedNativeHistory(window: window, plan: planned)
  }

  private func nativeCanonicalProjection(history: PagedRootHistory, beforeHistory: PagedRootHistory?,
    record: PagedDocumentRootRecord, beforeRecord: PagedDocumentRootRecord?,
    scope: PagedNativeCanonicalHistoryProjection.Scope, lineage: PagedNativeHistorySlotLineage?) throws -> PagedNativeCanonicalHistoryProjection {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let activeCustody, activeCustody.ownerID == ownerID,
      activeCustody.engineIncarnation == custodyIncarnation else {
      throw BoomError.denied("Canonical metadata has no actual entered same-engine producer.")
    }
    let claims = try rootCustody.claims(activeCustody)
    guard claims.contains(.record(record)) else { throw BoomError.denied("Canonical metadata escaped actual full-record job custody.") }
    if let beforeRecord, !claims.contains(.record(beforeRecord)) { throw BoomError.denied("Canonical metadata lost its before-record job custody.") }
    return try PagedNativeCanonicalHistoryProjection(storageHistory: history, record: record,
      beforeRecord: beforeRecord, beforeHistory: beforeHistory, scope: scope, producer: activeCustody,
      undoFromBefore: lineage?.undo ?? history.undo.map { _ in nil },
      redoFromBefore: lineage?.redo ?? history.redo.map { _ in nil },
      resolutions: try lineage?.resolutions(history) ?? [])
  }

  private func nativePublishedProjection(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, validated: ValidatedNativeHistory) throws -> PagedNativeCanonicalHistoryProjection {
    try nativeCanonicalProjection(history: validated.plan.after, beforeHistory: validated.plan.before,
      record: prepared.candidateRecord, beforeRecord: prepared.command.expectedRootRecord,
      scope: .historyPublished(sessionID: admission.sessionID, routeID: prepared.routeID,
        commandID: admission.commandID, preparationID: admission.preparationID,
        expected: admission.expectedSequence, admitted: admission.admittedSequence), lineage: validated.plan.lineage)
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
        record: expected, beforeRecord: nil, scope: .opening(sessionID: sessionID, windowID: window.windowID), lineage: nil)
      return PagedNativeCanonicalOpening(sessionID: sessionID, record: expected, window: window,
        history: projection, localCaretUTF16: caret)
    }
  }

  func commitNativeHistoryMoveRetaining(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, publisher: PagedWorkspacePublisher)
    async throws -> PagedTextCustodiedValue<PagedNativeHistoryAcknowledgement> {
    try await rootOutput(purpose: .nativePublication(routeID: prepared.routeID, preparationID: prepared.preparationID),
      claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord), .workspace],
      payloadBytes: PagedWorkingWindow.targetBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { _ in [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord), .workspace] },
      outputBytes: { $0.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes }) {
      try self.admit(publisher); try admission.validate(for: prepared)
      try publisher.admitCurrentRecord(prepared.command.expectedRootRecord, validateRecord: { try self.validateNativeRecord($0) })
      let validated = try self.validatePreparedNativeHistory(prepared)
      let acknowledgement = try PagedNativeHistoryAcknowledgement(validating: prepared, admission: admission,
        publishedRecord: prepared.candidateRecord, readWindow: validated.window,
        canonicalHistory: try self.nativePublishedProjection(prepared, admission: admission, validated: validated))
      guard let lease = self.activeCustody else { throw BoomError.denied("History publication lost its actual producer.") }
      try self.rootCustody.stageHistory(lease, prepared: prepared, acknowledgement: acknowledgement)
      try self.willPublish()
      _ = try publisher.publishDocument(prepared.candidateRecord, expected: prepared.command.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      try self.rootCustody.publicationCompleted(lease)
      return acknowledgement
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
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision> {
    let rootLease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.writerDocument(documentID)])
    let bulkLease: UUID
    do { bulkLease = try executor.reserveBulk(cancellation); try rootCustody.start(rootLease) }
    catch { _ = try rootCustody.joinedFailure(rootLease, error: error); throw error }
    defer { executor.releaseBulk(bulkLease) }
    do {
      return try await withTaskCancellationHandler {
        let context = try await performStreamIO {
          try PagedTextOperationContext(cancellation: cancellation, file: file, importing: true)
        }
        guard let expectedBytes = context.expectedBytes else { throw BoomError.invalid("Import has no captured file extent.") }
        if let requestedBytes, requestedBytes != expectedBytes { throw BoomError.stale("The imported file extent changed.") }
        let operationID: UUID = try await onQueue(priority: .background, cancellation: cancellation, custody: rootLease) {
          let id: UUID = try self.execute(Request(op: "import_begin", ownerID: self.ownerID,
            documentID: documentID, expectedBytes: expectedBytes), cancellation: cancellation, writes: false)
          try self.rootCustody.beganBulk(rootLease, operationID: id)
          return id
        }
        do {
          try await pump(Request(op: "import_step", ownerID: ownerID, documentID: documentID, operationID: operationID),
            expectedBytes: expectedBytes, context: context, writes: true, custody: rootLease)
          try await performStreamIO { try context.finish() }
          return try await onQueue(priority: .background, cancellation: cancellation, custody: rootLease) {
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
    _ = try await stream(revision, to: file, cancellation: cancellation)
  }

  func wholeTextSha256(_ revision: PagedTextRevision,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> String {
    try await stream(revision, to: nil, cancellation: cancellation)
  }

  private func stream(_ revision: PagedTextRevision, to file: FileHandle?,
    cancellation: PagedTextCancellation) async throws -> String {
    let rootLease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.source(revision)])
    let bulkLease: UUID
    do { bulkLease = try executor.reserveBulk(cancellation); try rootCustody.start(rootLease) }
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
        let operationID: UUID = try await onQueue(priority: .background, cancellation: cancellation, custody: rootLease) {
          let id: UUID = try self.execute(Request(op: file == nil ? "hash_begin" : "export_begin", revision: revision), cancellation: cancellation)
          try self.rootCustody.beganBulk(rootLease, operationID: id)
          return id
        }
        do {
          try await pump(Request(op: "stream_step", revision: revision, operationID: operationID),
            expectedBytes: revision.summary.bytes, context: context, writes: false, custody: rootLease)
          if context.hasOutput { try await performStreamIO { try context.finish() } }
          return try await onQueue(priority: .background, cancellation: cancellation, custody: rootLease) {
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
    writes: Bool, custody: PagedTextRootLease) async throws {
    var previous = PagedTextBulkProgress(processedBytes: 0, validatedBytes: 0, complete: false)
    while !previous.complete {
      if context.needsInputRead { try await performStreamIO { try context.prepareInput() } }
      let captured = previous
      previous = try await onQueue(priority: .background, cancellation: context.cancellation, custody: custody) {
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
    preparation: (@Sendable (T) -> PagedNativePreparedHistoryMove)? = nil,
    nativeAcknowledgement: (@Sendable (T) -> PagedNativeCommitAcknowledgement)? = nil,
    nativeInput: PagedNativeCommitBatch? = nil, capturedInput: PagedCapturedEditInput? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> PagedTextCustodiedValue<T> {
    let lease = try rootCustody.reserve(engine: self, purpose: purpose, claims: claims,
      payloadBytes: payloadBytes, metadataBytes: metadataBytes, nativeInput: nativeInput, capturedInput: capturedInput)
    do {
      return try await onQueue(priority: priority, cancellation: cancellation, custody: lease) {
        try self.rootCustody.start(lease)
        let value = try work()
        try self.rootCustody.finishOutput(lease, claims: outputClaims(value), payloadBytes: outputBytes(value),
          inFlightWitness: self.inFlightWitness, preparation: preparation?(value), nativeAcknowledgement: nativeAcknowledgement?(value))
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
  func retainNativeHistoryIntent(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeRetainedHistoryIntent { try rootCustody.retainHistory(prepared, engine: self) }
  func releaseRetainedHistoryIntent(_ receipt: PagedNativeRetainedHistoryIntent) throws { try rootCustody.resolvePrepared(receipt.lease, prepared: receipt.prepared, disposition: .explicitlyAbandoned) }
  func resolvePreparedCustody(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) throws { try rootCustody.resolvePrepared(lease, prepared: prepared, disposition: disposition) }
  func admitPreparedCustody(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws { try rootCustody.admitHistoryPublication(lease, prepared: prepared) }
  func verifyPreparedCustodyBefore(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws { try rootCustody.verifiedHistoryBefore(lease, prepared: prepared) }
  func absorbJoinedCustody(_ output: PagedTextRootLease, into receiver: PagedTextRootLease) throws { try rootCustody.absorbJoined(output, into: receiver) }
  func installNativeCustody(_ output: PagedTextRootLease, controller: PagedTextRootLease,
    expected: PagedDocumentRootRecord, record: PagedDocumentRootRecord) throws { try rootCustody.installControllerOutput(output, into: controller, expected: expected, record: record) }
  func confirmNativeInputCustody(_ controller: PagedTextRootLease, sessionID: UUID, sequence: UInt64,
    record: PagedDocumentRootRecord, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(custody: controller) {
      try self.admit(publisher); try publisher.admitCurrentRecord(record, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.confirmNativeInput(controller, sessionID: sessionID, sequence: sequence, record: record)
    }
  }
  func finishNativeCommitCustody(_ controller: PagedTextRootLease,
    acknowledgement: PagedNativeCommitAcknowledgement, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(custody: controller) {
      try self.admit(publisher); try publisher.admitCurrentRecord(acknowledgement.sealedRootRecord, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.finishNativeCommit(controller, acknowledgement: acknowledgement)
    }
  }
  func finishNativeHistoryCustody(_ preparedLease: PagedTextRootLease, controller: PagedTextRootLease,
    prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission,
    record: PagedDocumentRootRecord, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(custody: preparedLease) {
      try self.admit(publisher); try publisher.admitCurrentRecord(record, validateRecord: { try self.admitNavigationRecord($0) })
      try self.rootCustody.finishHistoryInstallation(preparedLease, controller: controller, prepared: prepared, admission: admission, record: record)
    }
  }
  func admitRetainedNativeInput(_ lease: PagedTextRootLease, batch: PagedNativeCommitBatch) throws { try rootCustody.admitActualNativeInput(lease, batch: batch) }
  enum NativeCommitInspection: Sendable { case before, native(PagedNativeCommitAcknowledgement) }
  func inspectFailedNativeCommitRetaining(_ batch: PagedNativeCommitBatch, custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<NativeCommitInspection> {
    let result: NativeCommitInspection = try await rootRead(claims: [.record(batch.expectedRootRecord), .workspace]) {
      try self.admit(publisher)
      let retained = try self.rootCustody.nativeFailure(custody, batch: batch)
      let current = try publisher.currentRecord(id: batch.expectedRootRecord.document.id)
      if current == batch.expectedRootRecord { return .before }
      guard let acknowledgement = retained.acknowledgement, current == acknowledgement.sealedRootRecord else {
        throw BoomError.stale("The failed edit has another saved document root; accepted input retained.")
      }
      if !retained.publicationComplete { try self.router.files().synchronizeDocument(acknowledgement.sealedRootRecord) }
      try self.validateNativeRecord(acknowledgement.sealedRootRecord)
      _ = try self.readNativeIsland(acknowledgement.sealedWindow.revision, anchor: acknowledgement.sealedWindow, exactBytes: batch.afterBytes)
      try self.rootCustody.recoverNativeOutput(custody)
      return .native(acknowledgement)
    }
    return PagedTextCustodiedValue(value: result, lease: custody)
  }
  func inspectInstalledNativeCommit(_ controller: PagedTextRootLease,
    batch: PagedNativeCommitBatch, publisher: PagedWorkspacePublisher) async throws -> PagedNativeCommitAcknowledgement {
    try await rootRead(claims: [.workspace]) {
      try self.admit(publisher)
      let acknowledgement = try self.rootCustody.borrowNativeAcknowledgement(controller, batch: batch)
      try publisher.admitCurrentRecord(acknowledgement.sealedRootRecord, validateRecord: { try self.admitNavigationRecord($0) })
      _ = try self.readNativeIsland(acknowledgement.sealedWindow.revision, anchor: acknowledgement.sealedWindow, exactBytes: batch.afterBytes)
      return acknowledgement
    }
  }
  func retryNativeCommitBeforeRetaining(_ custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    let batch = try rootCustody.retryNative(custody)
    do {
      return try await onQueue(custody: custody) {
        try self.rootCustody.start(custody)
        let acknowledgement = try self.makeNativeAcknowledgement(batch, publisher: publisher)
        try self.rootCustody.finishOutput(custody, claims: [.record(batch.expectedRootRecord), .record(acknowledgement.sealedRootRecord), .workspace],
          payloadBytes: acknowledgement.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes,
          inFlightWitness: self.inFlightWitness, nativeAcknowledgement: acknowledgement)
        return PagedTextCustodiedValue(value: acknowledgement, lease: custody)
      }
    } catch { _ = try rootCustody.joinedFailure(custody, error: error); throw PagedTextCustodyFailure(original: error, lease: custody) }
  }
  private func inspectHistoryFile(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, publisher: PagedWorkspacePublisher) throws -> PagedNativeHistoryPublicationInspection {
    try self.admit(publisher); try admission.validate(for: prepared)
    let current = try publisher.currentRecord(id: prepared.command.handle.documentID)
    if current == prepared.command.expectedRootRecord { return .notPublished }
    guard current == prepared.candidateRecord else { return .conflict(current) }
    let retained = try rootCustody.historyOutput(for: prepared)
    guard let acknowledgement = retained.acknowledgement,
      acknowledgement.admittedSequence == admission.admittedSequence else { throw BoomError.stale("Saved history has no original admitted output.") }
    if !retained.completed { try router.files().synchronizeDocument(prepared.candidateRecord) }
    _ = try validatePreparedNativeHistory(prepared)
    try rootCustody.recoverHistoryOutput(retained.lease)
    return .published(acknowledgement)
  }
  func inspectNativeHistoryPublicationRetaining(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, publisher: PagedWorkspacePublisher)
    async throws -> PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection> {
    try await rootOutput(claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord)],
      payloadBytes: PagedWorkingWindow.targetBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { _ in [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord)] },
      outputBytes: { if case .published(let acknowledgement) = $0 { return acknowledgement.sealedBytes }; return 0 }) {
      try self.inspectHistoryFile(prepared, admission: admission, publisher: publisher)
    }
  }
  func repairFailedNativeHistoryPublicationRetaining(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, custody: PagedTextRootLease, publisher: PagedWorkspacePublisher)
    async throws -> PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection> {
    let result = try await rootRead(claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord)]) {
      try self.inspectHistoryFile(prepared, admission: admission, publisher: publisher)
    }
    return PagedTextCustodiedValue(value: result, lease: custody)
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
