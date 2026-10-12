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
/// Existing-queue diagnostic receipt, including the first actual maintenance
/// failure and its retained RootCustody lease when mutation was attempted.
/// Reading it is metadata only and never clears the Store's durability fence.
struct PagedTextSQLMaintenanceSnapshot: Sendable {
  let storage: PagedSQLiteMaintenanceSnapshot
  let executor: PagedTextStorageExecutor.Snapshot
  let failure: Error?
}

/// Caller-visible lookup of the SAME actual setup Engine and its already
/// admitted Root lease. RootCustody independently retains all refused resources;
/// dropping this Error cannot release the Store connection or Rust/context.
struct PagedTextSetupCustodyFailure: Error, LocalizedError {
  let original: Error
  let lease: PagedTextRootLease
  let engine: PagedTextEngineAdapter
  var errorDescription: String? {
    "\(original.localizedDescription) Actual SQL setup owner \(engine.custodyIncarnation) remains retained by root \(lease.id)."
  }
}

enum PagedTextSetupRepairResult: Sendable {
  case opened(engine: PagedTextEngineAdapter, original: Error)
  case closedUnpublished(original: Error)
}
private struct PagedTextCleanupFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? {
    "Paged operation failed: \(original.localizedDescription). Cleanup failed: \(cleanup.localizedDescription). Unpublished records retained."
  }
}

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
/// Test-build identities hold the actual owners; address reuse cannot admit a
/// different engine, Vault or SQLite connection. No public initializer exists.
final class PagedSQLPublicControlIdentity: @unchecked Sendable {
  let ownerID: UUID
  let storeID: UUID
  let engineIncarnation: UUID
  fileprivate let engine: PagedTextEngineAdapter
  fileprivate let vault: Vault
  fileprivate let store: PagedSQLiteStore
  fileprivate init(engine: PagedTextEngineAdapter, vault: Vault, store: PagedSQLiteStore) {
    self.engine = engine; self.vault = vault; self.store = store
    ownerID = engine.ownerID; storeID = store.storeID; engineIncarnation = engine.custodyIncarnation
  }
  func admitConnection(_ connection: PagedSQLiteStore) throws {
    guard store === connection, connection.belongs(to: vault), connection.ownerID == ownerID,
      connection.storeID == storeID, engine.ownerID == ownerID, engine.custodyIncarnation == engineIncarnation else {
      throw BoomError.denied("Guarded SQL helper has another actual Vault/engine/connection identity.")
    }
  }
}
enum PagedSQLPublicPageTarget: Sendable {
  case sourceRoot, historyManifest, historySegment(Int)
}
/// One immutable original index-page ciphertext, returned before any mutation.
/// Its phase is accessed only on the owning engine queue. Failed attempts keep
/// the original bytes, producer lease and operation identity; no reset exists.
final class PagedSQLPublicCiphertextWitness: @unchecked Sendable {
  static let maximumCiphertextBytes = PagedRootHistoryStore.segmentBytes + 28
  let id: UUID
  let record: PagedDocumentRootRecord
  let page: PagedTextPageRef
  var ciphertextBytes: Int { original.count }
  var ciphertextSHA256: String { Digest.sha256(original) }
  fileprivate enum Phase { case prepared, corrupting(UUID), corrupted(UUID), restoring(UUID), restored(UUID) }
  fileprivate let identity: PagedSQLPublicControlIdentity
  fileprivate let producer: PagedTextRootLease
  fileprivate let currentRecord: PagedDocumentRootRecord?
  fileprivate let target: PagedSQLPublicPageTarget
  fileprivate let original: Data
  fileprivate var phase: Phase = .prepared
  fileprivate var historyMetadataAppendOperationID: UUID?
  fileprivate init(identity: PagedSQLPublicControlIdentity, producer: PagedTextRootLease,
    record: PagedDocumentRootRecord, currentRecord: PagedDocumentRootRecord?, target: PagedSQLPublicPageTarget,
    page: PagedTextPageRef, original: Data) throws {
    guard original.count >= 28, original.count <= Self.maximumCiphertextBytes,
      original.count == Int(page.locator.ciphertextBytes) else { throw BoomError.budget("Public ciphertext witness exceeds its exact index-page bound.") }
    id = UUID(); self.identity = identity; self.producer = producer; self.record = record
    self.currentRecord = currentRecord; self.target = target; self.page = page; self.original = original
  }
  fileprivate func corruptedBytes() -> Data {
    var bytes = original; bytes[bytes.count - 1] ^= 1; return bytes
  }
}
/// These fixed limits are unchanged history codec/storage envelopes.
enum PagedSQLPublicHistoryMetadataKind: Sendable, Equatable {
  case manifest, segment
  var maximumBytes: Int {
    self == .manifest ? PagedRootHistoryStore.maximumManifestBytes : PagedRootHistoryStore.segmentBytes
  }
}
/// Evidence from one real candidate-row COMMIT; no head/native ACK, source-root
/// reachability, receiving, installation, durability-repair or GC authority.
/// The actual returned Root output must remain owned until explicitly consumed.
struct PagedSQLPublicHistoryMetadataAppendReceipt: Sendable {
  let operationID: UUID
  let witnessID: UUID
  let anchorRecord: PagedDocumentRootRecord
  let kind: PagedSQLPublicHistoryMetadataKind
  let page: PagedTextPageRef
  fileprivate init(operationID: UUID, witness: PagedSQLPublicCiphertextWitness,
    kind: PagedSQLPublicHistoryMetadataKind, page: PagedTextPageRef) {
    self.operationID = operationID; witnessID = witness.id; anchorRecord = witness.record
    self.kind = kind; self.page = page
  }
}
/// Test-only actual prepared output. Its private producer and immutable payload
/// cannot be replaced by an object UUID, another Vault or a hand-made DTO.
final class PagedSQLPublicPreparedWorkspace: @unchecked Sendable {
  static let maximumEncodedBytes = 1_048_576
  static let maximumPublicationAttempts = 4
  let id = UUID()
  var reference: PagedWorkspaceObjectReference { prepared.reference }
  fileprivate let identity: PagedSQLPublicControlIdentity
  fileprivate let producer: PagedTextRootLease
  fileprivate let prepared: PreparedPagedWorkspace
  fileprivate var attempts = 0
  fileprivate var lastOperationID: UUID?
  fileprivate var lastValidationCount = 0
  fileprivate var lastPublicationChecks = 0
  fileprivate init(identity: PagedSQLPublicControlIdentity, producer: PagedTextRootLease,
    prepared: PreparedPagedWorkspace) {
    self.identity = identity; self.producer = producer; self.prepared = prepared
  }
}
/// Only an actual producer-made unpublished preparation can donate this
/// original authenticated fixed-part ciphertext. No head/record is invented.
final class PagedSQLPublicPreparedPartCiphertextWitness: @unchecked Sendable {
  let id = UUID()
  let preparationID: UUID
  let reference: PagedWorkspaceObjectReference
  let part: Int
  var ciphertextBytes: Int { original.count }
  var ciphertextSHA256: String { Digest.sha256(original) }
  fileprivate let identity: PagedSQLPublicControlIdentity
  fileprivate let producer: PagedTextRootLease
  fileprivate let prepared: PagedSQLPublicPreparedWorkspace
  fileprivate let original: Data
  fileprivate enum Phase { case prepared, corrupting(UUID), corrupted(UUID), restoring(UUID), restored(UUID) }
  fileprivate var phase: Phase = .prepared
  fileprivate init(identity: PagedSQLPublicControlIdentity, producer: PagedTextRootLease,
    prepared: PagedSQLPublicPreparedWorkspace, part: Int, original: Data) throws {
    guard part >= 0, part < prepared.reference.partCount else { throw BoomError.invalid("Original prepared-part witness is outside its actual reference.") }
    let maximum = min(65_536, prepared.reference.plaintextBytes - part * 65_536)
    guard original.count == maximum + 28,
      original.count <= PagedSQLPublicWorkspaceCiphertextWitness.maximumCiphertextBytes else {
      throw BoomError.budget("Original prepared-part witness exceeds its exact admitted extent.")
    }
    self.identity = identity; self.producer = producer; self.prepared = prepared
    preparationID = prepared.id; reference = prepared.reference; self.part = part; self.original = original
  }
  fileprivate func corruptedBytes() -> Data {
    var bytes = original; bytes[bytes.count - 1] ^= 1; return bytes
  }
}
struct PagedSQLPublicPreparedPartMutationReceipt: Sendable {
  let operationID: UUID
  let witnessID: UUID
  let preparationID: UUID
  let restored: Bool
  fileprivate init(operationID: UUID, witness: PagedSQLPublicPreparedPartCiphertextWitness, restored: Bool) {
    self.operationID = operationID; witnessID = witness.id; preparationID = witness.preparationID; self.restored = restored
  }
}

enum PagedSQLPublicInitialPublicationControl: Sendable, Equatable { case ordinary, cancelAfterRecordValidation }
struct PagedSQLPublicPreparedWorkspaceEvidence: Sendable {
  let preparationID: UUID
  let attempts: Int
  let operationID: UUID?
  let validatedRecords: Int
  let publicationChecks: Int
}
struct PagedSQLPublicWorkspacePublication: Sendable {
  let operationID: UUID
  let snapshot: PagedWorkspaceSnapshot
  let validatedRecords: Int
}
struct PagedSQLPublicDocumentPublication: Sendable {
  let publication: PagedWorkspaceDocumentPublication
  let validatedRecords: Int
}
struct PagedSQLPublicRecordAdmission: Sendable {
  let record: PagedDocumentRootRecord
  let validatedRecords: Int
}
enum PagedSQLPublicWorkspaceCiphertextTarget: Sendable {
  case workspacePart(Int), documentRecord, head
}
/// Original authenticated row and its actual producing workspace claim remain
/// live until explicit consumption. Head is observation-only: this hook cannot
/// bypass normal transaction admission to restore a corrupt head.
final class PagedSQLPublicWorkspaceCiphertextWitness: @unchecked Sendable {
  static let maximumCiphertextBytes = 65_536 + 28
  let id = UUID()
  let head: PagedWorkspaceHead
  let record: PagedDocumentRootRecord?
  var ciphertextBytes: Int { original.count }
  var ciphertextSHA256: String { Digest.sha256(original) }
  fileprivate let identity: PagedSQLPublicControlIdentity
  fileprivate let producer: PagedTextRootLease
  fileprivate let target: PagedSQLPublicWorkspaceCiphertextTarget
  fileprivate let objectID: UUID
  fileprivate let documentID: UUID
  fileprivate let role: PagedSQLiteRole
  fileprivate let part: Int
  fileprivate let original: Data
  fileprivate enum Phase { case prepared, corrupting(UUID), corrupted(UUID), restoring(UUID), restored(UUID) }
  fileprivate var phase: Phase = .prepared
  fileprivate init(identity: PagedSQLPublicControlIdentity, producer: PagedTextRootLease,
    head: PagedWorkspaceHead, record: PagedDocumentRootRecord?, target: PagedSQLPublicWorkspaceCiphertextTarget,
    objectID: UUID, documentID: UUID, role: PagedSQLiteRole, part: Int, original: Data) throws {
    guard original.count >= 28, original.count <= Self.maximumCiphertextBytes else {
      throw BoomError.budget("Public workspace row witness exceeds its exact encrypted extent.")
    }
    self.identity = identity; self.producer = producer; self.head = head; self.record = record; self.target = target
    self.objectID = objectID; self.documentID = documentID; self.role = role; self.part = part; self.original = original
  }
  fileprivate func corruptedBytes() -> Data {
    var bytes = original; bytes[bytes.count - 1] ^= 1; return bytes
  }
}
struct PagedSQLPublicWorkspaceMutationReceipt: Sendable {
  let operationID: UUID
  let witnessID: UUID
  let observedHead: PagedWorkspaceHead
  let restored: Bool
  fileprivate init(operationID: UUID, witness: PagedSQLPublicWorkspaceCiphertextWitness,
    observedHead: PagedWorkspaceHead, restored: Bool) {
    self.operationID = operationID; witnessID = witness.id; self.observedHead = observedHead; self.restored = restored
  }
}

struct PagedSQLPublicMutationReceipt: Sendable {
  enum Mutation: Sendable { case corruption, restoration }
  let operationID: UUID
  let witnessID: UUID
  let record: PagedDocumentRootRecord
  let page: PagedTextPageRef
  let mutation: Mutation
  fileprivate init(operationID: UUID, witness: PagedSQLPublicCiphertextWitness, mutation: Mutation) {
    self.operationID = operationID; witnessID = witness.id; record = witness.record
    page = witness.page; self.mutation = mutation
  }
}
#endif

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

/// One host context, one admitted document per C call and the same SQL owner.
/// No per-document append handles, page sync loop or second cache remains.
private final class PagedTextPageRouter {
  let ownerID: UUID
  let vault: Vault
  var sqlite: PagedSQLiteStore?
  private var activeDocument: UUID?
  private var permitsWrites = false
  private var writeAdmission: (() throws -> Void)?
  var failure: Error?
  init(vault: Vault, ownerID: UUID) { self.vault = vault; self.ownerID = ownerID }
  func database() throws -> PagedSQLiteStore {
    guard let sqlite else { throw BoomError.unavailable("The exact SQL connection is not open.") }; return sqlite
  }
  func begin(document: UUID?, writes: Bool, beforeWrite: (() throws -> Void)? = nil) throws {
    guard !Thread.isMainThread, activeDocument == nil else { throw BoomError.invalid("Paged callback route is active or on Main.") }
    guard !writes || beforeWrite != nil else { throw BoomError.denied("Paged writer has no root-custody admission.") }
    activeDocument = document; permitsWrites = writes; writeAdmission = beforeWrite; failure = nil
  }
  func end() { activeDocument = nil; permitsWrites = false; writeAdmission = nil }
  func provider(owner: UUID, document: UUID, writing: Bool) throws -> any PagedTextDocumentPages {
    guard !Thread.isMainThread, owner == ownerID, document == activeDocument,
      !writing || permitsWrites else { throw BoomError.denied("Paged callback has another captured route.") }
    if writing { try writeAdmission?() }
    let store = try database(); try store.requireObjectAccess()
    if writing && !store.hasTransaction { throw BoomError.denied("SQL page writer has no actual outer transaction.") }
    return PagedSQLiteDocumentPages(store: store, ownerID: ownerID, documentID: document)
  }
  func closeStore() throws { if let sqlite { try sqlite.close(); self.sqlite = nil } }
  /// Setup never exposed a consumer. The same installed Store stays retained
  /// until its actual normal or partial-open SQL cleanup succeeds.
  func closeUnexposedStore() throws {
    if let sqlite {
      if sqlite.isSourceAdmitted { try sqlite.close() }
      else { try sqlite.closeUnexposedSetup() }
      self.sqlite = nil
    }
  }
  func failed(_ error: Error) { if failure == nil { failure = error } }
  static func kind(_ value: String) throws -> PagedTextPageKind {
    switch value { case "text": return .text; case "index": return .index; default: throw BoomError.invalid("Unknown paged kind.") }
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

/// One process engine/cache and one serialized storage executor. This is an
/// internal native storage API, not a model tool and not a current-root grant.
/// Ordinary Workspace integration is deliberately not activated here.
final class PagedTextEngineAdapter: @unchecked Sendable {
  private struct Request: Encodable, Sendable {
    private enum CodingKeys: String, CodingKey {
      case op, revision, retained, byteStart, byteEnd, maximumBytes, oldText, newText
      case ownerID = "ownerId", documentID = "documentId", utf16Offset
      case operationID = "operationId", expectedBytes, forward
    }
    let op: String
    var revision: PagedTextRevision?
    var retained: PagedTextRevision?
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
  }
  private struct Envelope<T: Decodable>: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    let schema: Int
    let ok: Bool
    let value: T?
    let error: Failure?
  }
  let ownerID: UUID
  private let rootCustody: PagedTextRootCustody
  var custodyIncarnation: UUID { rootCustody.engineIncarnation }
  var custodySnapshot: PagedTextRootCustody.Snapshot { rootCustody.snapshot }
  private let executor = PagedTextStorageExecutor()
  private var queue: DispatchQueue { executor.queue }
  // Whole bulk lifetimes are capped at two. Each owner submits at most one
  // exclusive I/O operation at a time; one stalled volume cannot block edits.
  private static let streamIOQueue = DispatchQueue(label: "com.delysis.Bloom.paged-stream-io", qos: .utility, attributes: .concurrent)
  private let router: PagedTextPageRouter
  // Accessed only on queue; async work retains self until its operation joins.
  private var handle: UInt64 = 0
  private var hostContext: UnsafeMutableRawPointer?
  private var activeCustody: PagedTextRootLease?
  // Ordinary resource phase, set ONLY after the owned SQL resource cleanup
  // joins: normal close or checked unexposed setup cleanup.
  // A later Rust close refusal retains its slot/context; retry must not infer
  // a SQL join from absence or reopen a closed callback source/cache.
  private var sqlClosedForShutdown = false
  // Same actual Engine and queue; no Task/lifetime service owns maintenance.
  // A first failed job remains reported until a separately implemented exact
  // durability receiver resolves it. This source pass provides no clear/reset.
  // First-error metadata is mutex protected so a refused queue continuation
  // can finish its already-admitted Root lease without another cleanup request.
  private let maintenanceFailure = Mutex<Error?>(nil)
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  // At most one attempted row corruption per real engine. It remains retained
  // on every failed/uncertain path; explicit close cannot erase that custody.
  private var publicSQLWitness: PagedSQLPublicCiphertextWitness?
  private var publicSQLPublisherWitness: PagedSQLPublicWorkspaceCiphertextWitness?
  private var publicSQLPreparedWitness: PagedSQLPublicPreparedPartCiphertextWitness?
#endif

  private init(vault: Vault, ownerID: UUID) throws {
    guard ownerID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
      throw BoomError.invalid("Invalid paged source owner.")
    }
    self.ownerID = ownerID; router = PagedTextPageRouter(vault: vault, ownerID: ownerID)
    rootCustody = PagedTextRootCustody(ownerID: ownerID)
  }
  /// Immutable key-session identity, without IO or another executor/engine.
  func belongs(to vault: Vault) -> Bool { router.vault === vault }
  static func create(vault: Vault, ownerID: UUID, sqliteOpening: PagedSQLiteStore.Opening) async throws -> PagedTextEngineAdapter {
    let adapter = try PagedTextEngineAdapter(vault: vault, ownerID: ownerID)
    // The SAME Engine/Root workspace owner exists before this first await.
    // Error lifetime is not what keeps an unjoined connection/slot reachable.
    let setup = try adapter.rootCustody.reserve(engine: adapter, purpose: .operation(UUID()), claims: [.workspace])
    do {
      try await adapter.onQueue(custody: setup) {
        try adapter.rootCustody.start(setup)
        // Reserve Rust's process slot BEFORE any SQL raw preflight close. This
        // constructor creates bounded state, with no callback/SQL IO.
        let context = Unmanaged.passRetained(adapter.router).toOpaque()
        let host = BloomTextHost(schema: 2, context: context, read_page: pagedPageRead, write_page: pagedPageWrite)
        let handle = bloom_text_create(host)
        guard handle != 0 else {
          Unmanaged<PagedTextPageRouter>.fromOpaque(context).release()
          throw BoomError.unavailable("The process paged text engine is already owned or unavailable.")
        }
        adapter.hostContext = context; adapter.handle = handle // still unexposed
        try adapter.willPublish() // conservative custody before setup IO/resource failure
        do {
          // Construction cannot open files/SQL. Install the actual resource
          // owner before its fallible opening/configuration/format admission.
          let store = try PagedSQLiteStore(vault: vault, ownerID: ownerID,
            engineIncarnation: adapter.custodyIncarnation, queue: adapter.queue, opening: sqliteOpening)
          adapter.router.sqlite = store
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
          if store.openingOperationID != nil,
            ProcessInfo.processInfo.environment["BLOOM_PAGED_SQL_DURABILITY_PUBLIC_CASE"] == "testActualFreshFormatFailureRetainsSameOwnerUntilExplicitRepair" {
            try store._publicArmSetupFault(.moveDatabaseName)
          }
#endif
          if let operationID = store.openingOperationID {
            try adapter.rootCustody.beganSQLiteOperation(setup, operation: PagedSQLiteOperationIdentity(
              store: store.nativeReceivingIdentity, operationID: operationID), intent: .setup)
          }
          try store.openAndAdmit { adapter.rootCustody.finishedSQLiteExecution(setup, execution: $0) }
        } catch {
          let original = error
          if let sqlFailure = original as? PagedSQLiteExecutionFailure {
            adapter.rootCustody.finishedSQLiteExecution(setup, execution: sqlFailure.execution)
          }
          if (try adapter.rootCustody.sqlState(setup))?.execution?.commitEntered == true {
            // Do not close the live failed format COMMIT or release its Rust
            // slot. The actual original Root workspace job owns both resources.
            throw original
          }
          do {
            // No requireSourceAdmission prerequisite for partial-open cleanup.
            // A non-OK raw open with a real pointer must actually close too.
            try adapter.router.closeUnexposedStore()
            adapter.sqlClosedForShutdown = true
          } catch {
            throw PagedTextCleanupFailure(original: original, cleanup: error)
          }
          guard bloom_text_close(handle) == 1 else {
            throw PagedTextCleanupFailure(original: original,
              cleanup: BoomError.unavailable("Unexposed paged engine teardown did not join handle \(handle); actual context retained."))
          }
          adapter.handle = 0; adapter.hostContext = nil
          Unmanaged<PagedTextPageRouter>.fromOpaque(context).release()
          // Actual SQL/slot teardown joined, not a publication/durability ACK.
          do {
            try adapter.rootCustody.finishJoinedSetupClose(setup, inFlightWitness: adapter.inFlightWitness)
          } catch { throw PagedTextCleanupFailure(original: original, cleanup: error) }
          if let result = original as? PagedSQLiteExecutionFailure { throw result.original }
          throw original
        }
        try adapter.rootCustody.finishOutput(setup, claims: [.workspace], payloadBytes: 0,
          inFlightWitness: adapter.inFlightWitness)
        try adapter.rootCustody.abandonJoined(setup)
      }
      return adapter
    } catch {
      let original = error
      let preserved: Bool
      do { preserved = try adapter.rootCustody.joinedFailure(setup) }
      catch {
        throw PagedTextSetupCustodyFailure(
          original: PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: setup),
          lease: setup, engine: adapter)
      }
      if preserved { throw PagedTextSetupCustodyFailure(original: original, lease: setup, engine: adapter) }
      throw original
    }
  }
  /// Explicit resolution stays on this actual Engine/Root/connection. The
  /// original result is retained until normal output or physical setup joins.
  func repairFailedSetupOpening(_ failure: PagedTextSetupCustodyFailure) async throws -> PagedTextSetupRepairResult {
    guard failure.engine === self else { throw BoomError.denied("Setup belongs to another actual Engine.") }
    let sql = try rootCustody.beginSetupResolution(failure.lease)
    do {
      return try await onQueue(priority: .cleanup, custody: failure.lease) {
        try self.rootCustody.start(failure.lease)
        if self.sqlClosedForShutdown {
          try self.closeUnexposedRust()
          try self.rootCustody.finishJoinedSetupClose(failure.lease, inFlightWitness: self.inFlightWitness)
          return .closedUnpublished(original: failure.original)
        }
        let store = try self.router.database()
        guard let sql, let previous = sql.execution, previous.commitEntered else {
          try self.router.closeUnexposedStore(); self.sqlClosedForShutdown = true
          try self.closeUnexposedRust()
          try self.rootCustody.finishJoinedSetupClose(failure.lease, inFlightWitness: self.inFlightWitness)
          return .closedUnpublished(original: failure.original)
        }
        guard case .setup = sql.intent else { throw BoomError.stale("Actual setup intent changed.") }
        let execution = try store.resolve(previous) { try store.inspectFormat(previous) }
        self.rootCustody.finishedSQLiteExecution(failure.lease, execution: execution)
        if execution.outcome == .resolved(.format) {
          try store.acceptFormat(execution)
          try self.rootCustody.finishSQLProducerDisposition(failure.lease, execution: execution, inFlightWitness: self.inFlightWitness)
          try self.rootCustody.abandonJoined(failure.lease)
          return .opened(engine: self, original: failure.original)
        }
        guard execution.selectedBefore else { throw BoomError.stale("Format has no exact unpublished disposition.") }
        try self.router.closeUnexposedStore(); self.sqlClosedForShutdown = true
        try self.closeUnexposedRust()
        try self.rootCustody.finishJoinedSetupClose(failure.lease, inFlightWitness: self.inFlightWitness)
        return .closedUnpublished(original: failure.original)
      }
    } catch {
      _ = try rootCustody.joinedFailure(failure.lease)
      throw PagedTextSetupCustodyFailure(original: PagedTextCleanupFailure(original: failure.original, cleanup: error), lease: failure.lease, engine: self)
    }
  }
  private func closeUnexposedRust() throws {
    guard sqlClosedForShutdown else { throw BoomError.unavailable("Actual SQL cleanup did not join.") }
    if handle != 0 {
      guard bloom_text_close(handle) == 1 else { throw BoomError.unavailable("The same actual Rust slot still refuses close.") }
      handle = 0
    }
    if let context = hostContext { hostContext = nil; Unmanaged<PagedTextPageRouter>.fromOpaque(context).release() }
  }

  enum SQLResolvedOutput: Sendable {
    case before(PagedSQLiteExecution)
    case native(PagedNativeCommitAcknowledgement)
    case history(PagedNativeHistoryAcknowledgement)
    case workspace(PagedWorkspaceSnapshot)
    case metadata(WorkspaceMetadataPublication)
    case producer(PagedSQLiteExecution)
  }
  /// ONE dispatcher over the existing Root's actual intent and normal output.
  /// No receipt lookup, visibility-as-durability, source replay or new owner.
  func resolveSQLiteOutputRetaining(_ lease: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<SQLResolvedOutput> {
    let sql = try rootCustody.beginSQLResolution(lease) // actual owner before yield
    do {
      return try await onQueue(priority: .cleanup, custody: lease) {
        try self.rootCustody.start(lease); try self.admit(publisher)
        if !sql.engineJoined {
          // Join only the retained actual C/cache operation before reading any
          // selected source. No body, splice or publication is replayed.
          let _: PagedTextCacheStats = try self.execute(Request(op: "discard_page_cache_after_rollback"))
          try self.rootCustody.joinedSQLiteEngine(lease)
        }
        let store = try self.router.database()
        guard let previous = sql.execution, previous.identity.store == store.nativeReceivingIdentity else { throw BoomError.stale("Outcome belongs to another actual connection.") }
        let execution = try store.resolve(previous) {
          if previous.kind == .checkpoint { return .checkpoint }
          if previous.selectedBefore && !previous.beforeAdmitted {
            switch sql.intent {
            case .native(let batch):
              try publisher.admitCurrentRecord(batch.expectedRootRecord, validateRecord: { try self.validateNativeRecord($0) })
              _ = try self.readNativeIsland(batch.expected.revision, anchor: batch.expected, exactBytes: Data(batch.expected.text.utf8))
            case .history(let prepared, _):
              try publisher.admitCurrentRecord(prepared.command.expectedRootRecord, validateRecord: { try self.validateNativeRecord($0) })
              _ = try self.validatePreparedNativeHistory(prepared)
            case .metadata(_, _, let expectedHead):
              if let expectedHead {
                guard try publisher.settingsRead().head == expectedHead else { throw BoomError.stale("Unentered metadata has another actual full head.") }
              } else {
                guard try store.headID() == nil, try store.documentIDs().isEmpty, try !store.hasEntityInventory() else { throw BoomError.stale("Unentered initial metadata no longer has its absent authority.") }
              }
            case .workspace(_, _, let expectedHead):
              if let expectedHead {
                guard try publisher.load(validateRecord: { try self.validateNativeRecord($0) }).head == expectedHead else { throw BoomError.stale("Unentered metadata has another full expected head.") }
              } else { guard try store.headID() == nil, try store.documentIDs().isEmpty else { throw BoomError.stale("Unentered initial metadata no longer has its absent authority.") } }
            default: throw BoomError.stale("No actual source authority was captured for this producer.")
            }
            return .before
          }
          return try publisher.selectedAuthority(previous, validateRecord: { try self.validateNativeRecord($0) })
        }
        self.rootCustody.finishedSQLiteExecution(lease, execution: execution)
        let receivingIntent: Bool
        switch sql.intent { case .native, .history, .workspace, .metadata: receivingIntent = true; default: receivingIntent = false }
        if execution.selectedBefore && receivingIntent {
          try self.rootCustody.finishSQLBefore(lease, execution: execution, inFlightWitness: self.inFlightWitness)
          try store.releaseRefusal(execution)
          return PagedTextCustodiedValue(value: .before(execution), lease: lease)
        }
        let output: SQLResolvedOutput
        switch (sql.intent, sql.output) {
        case (.native(let batch), .some(.native(let ack))):
          guard execution.selectedAfter, execution.publication?.beforeRecord == batch.expectedRootRecord,
            execution.publication?.afterRecord == ack.sealedRootRecord else { throw BoomError.stale("Accepted input has no exact AFTER authority.") }
          try store.withOutcomeReads(execution) { try self.validateActualNativeOutput(batch: batch, acknowledgement: ack) }
          try self.rootCustody.finishOutput(lease,
            claims: [.record(batch.expectedRootRecord), .record(ack.sealedRootRecord), .writerDocument(batch.expected.revision.documentID), .workspace],
            payloadBytes: ack.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes,
            inFlightWitness: self.inFlightWitness, nativeAcknowledgement: ack)
          output = .native(ack)
        case (.history(let prepared, let admission), .some(.history(let ack))):
          guard execution.selectedAfter, execution.publication?.beforeRecord == prepared.command.expectedRootRecord,
            execution.publication?.afterRecord == prepared.candidateRecord else { throw BoomError.stale("Prepared command has no exact AFTER authority.") }
          try store.withOutcomeReads(execution) { _ = try self.validatePreparedNativeHistory(prepared) }
          try self.rootCustody.finishOutput(lease,
            claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord), .writerDocument(prepared.command.handle.documentID), .workspace],
            payloadBytes: ack.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes,
            inFlightWitness: self.inFlightWitness,
            nativeHistoryPublication: (prepared, ack, store.nativeReceivingIdentity, prepared.preparationID))
          output = .history(ack)
        case (.workspace(let prepared, let records, _), .some(.workspace(let snapshot))):
          guard execution.selectedAfter, execution.publication?.afterHead == snapshot.head,
            snapshot.documents == records, snapshot.head.workspace == prepared.reference else { throw BoomError.stale("Metadata has no exact actual AFTER snapshot.") }
          let actual = try store.withOutcomeReads(execution) { try publisher.load(validateRecord: { try self.validateNativeRecord($0) }) }
          guard actual == snapshot else { throw BoomError.stale("Normal metadata output differs from the authenticated selected head/catalog.") }
          try self.rootCustody.finishOutput(lease, claims: [.workspace], payloadBytes: 0, inFlightWitness: self.inFlightWitness)
          output = .workspace(snapshot)
        case (.metadata(let input, let prepared, _), .some(.metadata(let publication))):
          guard execution.selectedAfter, input.inputID == prepared.inputID,
            publication.head.workspace.hasSameSettingsPayload(as: prepared.settings),
            execution.publication?.afterHead == publication.head,
            execution.publication?.metadataChanges == publication.changes,
            execution.publication?.documentChanges == publication.documents else { throw BoomError.stale("Metadata has no exact normal AFTER output.") }
          _ = try store.withOutcomeReads(execution) { try publisher.admitMetadataPublication(publication, validateRecord: { try self.validateNativeRecord($0) }) }
          try self.rootCustody.finishOutput(lease, claims: [.workspace], payloadBytes: input.outputReservationBytes, inFlightWitness: self.inFlightWitness)
          output = .metadata(publication)
        case (.producer, _):
          guard execution.publication == nil else { throw BoomError.denied("A producer cannot consume actual head publication.") }
          try store.releaseRefusal(execution)
          try self.rootCustody.finishSQLProducerDisposition(lease, execution: execution, inFlightWitness: self.inFlightWitness)
          self.maintenanceFailure.withLock { first in if let carried = first as? PagedTextCustodyFailure, carried.lease == lease { first = nil } }
          self.scheduleWALMaintenanceIfNeeded()
          output = .producer(execution)
        default: throw BoomError.stale("The actual bounded normal output is unavailable; no ACK was manufactured.")
        }
        return PagedTextCustodiedValue(value: output, lease: lease)
      }
    } catch {
      _ = try rootCustody.joinedFailure(lease)
      throw PagedTextCustodyFailure(original: error, lease: lease)
    }
  }
  private func validateActualNativeOutput(batch: PagedNativeCommitBatch,
    acknowledgement: PagedNativeCommitAcknowledgement) throws {
    guard acknowledgement.sessionID == batch.sessionID, acknowledgement.batchID == batch.batchID,
      acknowledgement.lastSequence == batch.lastSequence, acknowledgement.expectedRootRecord == batch.expectedRootRecord,
      acknowledgement.sealedWindow.text.utf8.elementsEqual(batch.afterBytes), let canonical = acknowledgement.canonicalHistory else { throw BoomError.stale("Actual native output differs from retained ordered input.") }
    _ = try readNativeIsland(acknowledgement.sealedRootRecord.document.revision,
      anchor: batch.expected, exactBytes: batch.afterBytes)
    try validateNativeRecord(batch.expectedRootRecord); try validateNativeRecord(acknowledgement.sealedRootRecord)
    let history = try withNativeHistory(documentID: batch.expected.revision.documentID, writes: false) { try $0.load(acknowledgement.sealedRootRecord) }
    try canonical.admit(record: acknowledgement.sealedRootRecord, sessionID: batch.sessionID, engineIncarnation: custodyIncarnation,
      scope: .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID, first: batch.firstSequence, last: batch.lastSequence))
    guard canonical.currentCursor == history.currentCursor, canonical.undo == history.undo,
      canonical.redo == history.redo, canonical.activeGroup == history.activeGroup else { throw BoomError.stale("Actual output differs from encrypted retained history.") }
  }
  /// Explicit producer-only disposition has no source/metadata return to install.
  func repairFailedSQLiteProducer(_ lease: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedSQLiteExecution {
    let result = try await resolveSQLiteOutputRetaining(lease, publisher: publisher)
    guard case .producer(let execution) = result.value else { throw BoomError.denied("The actual input/output needs its real receiving owner.") }
    do { try await abandonJoinedRootOutput(result.lease) }
    catch { throw PagedTextCustodyFailure(original: error, lease: result.lease) }
    return execution
  }


  deinit {
    // Explicit close is the normal lifecycle. The fallback preserves the same
    // SQL-before-Rust resource order: retain the actual slot/context on any SQL
    // refusal, rather than letting a new factory raw-open a still-locked inode.
    let retainedHandle = handle, context = hostContext
    if retainedHandle != 0, let context {
      let address = UInt(bitPattern: context)
      queue.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let retainedRouter = Unmanaged<PagedTextPageRouter>.fromOpaque(context).takeUnretainedValue()
        do { try retainedRouter.closeStore() } catch { return } // existing bounded retention, no guessed join
        if bloom_text_close(retainedHandle) == 1 {
          Unmanaged<PagedTextPageRouter>.fromOpaque(context).release()
        }
      }
    }
  }
  func close() async throws {
    rootCustody.beginClose()
    try await executor.beginClose()
    defer { executor.endCloseAttempt() }
    let maintenance: PagedTextRootLease? = try await onQueue(priority: .lifecycle) {
      // All earlier executor requests and bulk owners actually joined. Never
      // replace a live controller, uncertain output or failed metadata job.
      try self.rootCustody.requireEmptyForClose()
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
      guard self.publicSQLWitness == nil, self.publicSQLPublisherWitness == nil, self.publicSQLPreparedWitness == nil else {
        throw BoomError.unavailable("An actual public SQL mutation remains owned; close refused.")
      }
#endif
      if let failure = self.maintenanceFailure.withLock({ $0 }) { throw failure }
      if self.sqlClosedForShutdown { return nil } // actual earlier SQL close success only
      // A factory refusal remains in its actual Root ledger; when an exact
      // owner later permits teardown, partial setup must not require source.
      guard let store = self.router.sqlite, store.isSourceAdmitted else { return nil }
      try store.requireMaintenanceAdmission() // BEFORE retiring Rust.
      guard store.needsClosingMaintenance else { return nil }
      return try self.rootCustody.reserveClosingMaintenance(engine: self)
    }
    if let maintenance {
      do {
        try await onQueue(priority: .cleanup, custody: maintenance) {
          try self.rootCustody.start(maintenance)
          try self.performWALMaintenance(maintenance)
          try self.rootCustody.finishOutput(maintenance, claims: [.workspace], payloadBytes: 0, inFlightWitness: self.inFlightWitness)
          try self.rootCustody.abandonJoined(maintenance)
        }
      } catch {
        // Same actual custody metadata path, without a second queue admission.
        // No pending receipt/job or failed COMMIT outcome is discarded.
        throw recordWALMaintenanceFailure(error, lease: maintenance)
      }
    }
    try await onQueue(priority: .lifecycle) {
      try self.rootCustody.requireEmptyForClose()
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
      guard self.publicSQLWitness == nil, self.publicSQLPublisherWitness == nil, self.publicSQLPreparedWitness == nil else {
        throw BoomError.unavailable("An actual public SQL mutation remains owned; close refused.")
      }
#endif
      if let failure = self.maintenanceFailure.withLock({ $0 }) { throw failure }
      if !self.sqlClosedForShutdown {
        if self.router.sqlite?.isSourceAdmitted == true {
          try self.router.database().requireCloseAdmission()
          try self.router.closeStore()
        } else {
          try self.router.closeUnexposedStore()
        }
        // Keep ENGINE_COUNT's actual slot through sqlite3_close. A competing
        // same-process factory cannot raw-open/close this still-locked inode.
        // A failed SQL close leaves this phase false and Rust/context owned.
        self.sqlClosedForShutdown = true
      }
      // No new source request/callback can enter this joined closing interval.
      // A refusal keeps the actual handle/router/context, and a later attempt
      // re-admits quiescence then skips only the proven closed SQL resource.
      if self.handle != 0 {
        guard bloom_text_close(self.handle) == 1 else { throw BoomError.unavailable("Paged engine did not join; host context retained.") }
        self.handle = 0
      }
      if let context = self.hostContext { Unmanaged<PagedTextPageRouter>.fromOpaque(context).release() }
      self.hostContext = nil
    }
  }
  func makeWorkspacePublisher() async throws -> PagedWorkspacePublisher {
    try await onQueue {
      guard self.handle != 0, !self.sqlClosedForShutdown, self.router.sqlite?.isSourceAdmitted == true else {
        throw BoomError.unavailable("Paged text engine source opening is unjoined or closed.")
      }
      return try PagedWorkspacePublisher(store: self.router.database(), vault: self.router.vault)
    }
  }
  /// Initial import produces a small unpublished root/history record. Only
  /// the coherent publisher may attach it to a workspace head.
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
  /// Metadata encoding/encryption runs on the host utility worker. Native
  /// character commits reuse this immutable payload instead of re-encoding it.
  func initializeWorkspaceRetaining(_ publisher: PagedWorkspacePublisher, state: WorkspaceState,
    documents: [PagedDocumentRootRecord],
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedWorkspaceSnapshot> {
    try await writeWorkspaceRetaining(publisher, state: state, documents: documents,
      expectedHead: nil, cancellation: cancellation)
  }
  /// Ordinary metadata/inventory changes use the same encoding, staging and
  /// root-output owner as initialization, with one real full-head SQL CAS.
  func publishWorkspaceRetaining(_ publisher: PagedWorkspacePublisher, state: WorkspaceState,
    documents: [PagedDocumentRootRecord], expectedHead: PagedWorkspaceHead,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedWorkspaceSnapshot> {
    try await writeWorkspaceRetaining(publisher, state: state, documents: documents,
      expectedHead: expectedHead, cancellation: cancellation)
  }
  private func writeWorkspaceRetaining(_ publisher: PagedWorkspacePublisher, state: WorkspaceState,
    documents: [PagedDocumentRootRecord], expectedHead: PagedWorkspaceHead?,
    cancellation: PagedTextCancellation) async throws -> PagedTextCustodiedValue<PagedWorkspaceSnapshot> {
    // A workspace barrier protects all of this owner's immutable metadata and
    // input records while the existing utility encoder is outside the queue.
    let rootLease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.workspace], workspaceDocuments: documents)
    let bulkLease: UUID
    do { bulkLease = try executor.reserveBulk(cancellation); try rootCustody.start(rootLease) }
    catch { _ = try rootCustody.joinedFailure(rootLease); throw error }
    defer { executor.releaseBulk(bulkLease) }
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        try self.admit(publisher)
        // The admitted workspace claim already pins all input/candidate roots.
        // Encoding is not a SQL write: its joined refusal needs no invented
        // transaction outcome. Actual chunk/final writes enter withSQLWrite.
        let encoded = try await performStreamIO {
          guard !cancellation.isCancelled else { throw CancellationError() }
          return try publisher.encodeWorkspace(state)
        }
        for part in 0..<encoded.partCount {
          try await onQueue(priority: .background, cancellation: cancellation, custody: rootLease) {
            try self.withSQLWrite(operationID: UUID()) { try publisher.stageWorkspacePart(encoded, part: part) }
          }
        }
        let prepared = try await onQueue(priority: .background, cancellation: cancellation, custody: rootLease) {
          try publisher.finishWorkspacePreparation(encoded)
        }
        return try await onQueue(cancellation: cancellation, custody: rootLease) {
          try self.admit(publisher)
          let snapshot = try self.withSQLWrite(operationID: UUID(), intent: .workspace(prepared, documents, expectedHead: expectedHead)) {
            let value = try self.publishPreparedWorkspace(publisher, prepared: prepared, documents: documents,
              expectedHead: expectedHead, beforePublication: { if cancellation.isCancelled { throw CancellationError() } })
            try self.rootCustody.stageSQLNativeOutput(rootLease, output: .workspace(value)); return value
          }
          try self.rootCustody.finishOutput(rootLease, claims: [.workspace], payloadBytes: 0,
            inFlightWitness: self.inFlightWitness)
          return PagedTextCustodiedValue(value: snapshot, lease: rootLease)
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(rootLease) { throw PagedTextCustodyFailure(original: error, lease: rootLease) }
      throw error
    }
  }
  private func publishPreparedWorkspace(_ publisher: PagedWorkspacePublisher,
    prepared: PreparedPagedWorkspace, documents: [PagedDocumentRootRecord], expectedHead: PagedWorkspaceHead?,
    beforePublication: () throws -> Void = {}) throws -> PagedWorkspaceSnapshot {
    if let expectedHead {
      try beforePublication(); try willPublish()
      return try publisher.publishWorkspace(prepared, documents: documents, expectedHead: expectedHead,
        validateRecord: { try self.validateNativeRecord($0) })
    }
    return try publisher.initialize(prepared, documents: documents,
      validateRecord: { try self.validateNativeRecord($0) }, beforePublication: { try beforePublication(); try self.willPublish() })
  }
  func loadWorkspaceRetaining(_ publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedWorkspaceSnapshot> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      try self.admit(publisher) // Exact authenticated SQL read; no journal repair.
      return try publisher.load(validateRecord: { try self.validateNativeRecord($0) })
    }
  }
  /// Reuses this process engine, root registry and serialized executor. The
  /// receiving workspace owner must retain/dispose the actual returned lease;
  /// no descriptor, decoded payload or Boolean replaces that root custody.
  /// OPEN ordinary metadata gap: this existing workspace claim charges zero
  /// payload bytes, while WorkspaceState can decode from a 128 MiB object.
  /// It protects roots, not decoded metadata allocation. An independently
  /// bounded metadata receiver is required before ordinary activation; native
  /// island/queue envelopes must not be widened to accommodate this value.
  func loadWorkspaceCatalogRetaining(_ publisher: PagedWorkspacePublisher)
    async throws -> PagedTextCustodiedValue<PagedWorkspaceDocumentCatalog> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      try self.admit(publisher) // Exact authenticated SQL read.
      return try publisher.loadCatalogAndWorkspace(validateRecord: { try self.validateNativeRecord($0) })
    }
  }
  /// Existing executor/Root owner, with a pre-yield fixed receiving reserve.
  /// Receiving Model keeps the lease through adoption/ordinary disposition;
  /// a page's metadata alone cannot install native text or grant model authority.
  func loadDocumentIndexPageRetaining(_ publisher: PagedWorkspacePublisher,
    afterOrdinal: Int = -1, expectedHead: PagedWorkspaceHead? = nil)
    async throws -> PagedTextCustodiedValue<PagedDocumentIndexPage> {
    try await rootOutput(claims: [.workspace],
      payloadBytes: PagedDocumentIndexPage.maximumPayloadBytes,
      outputClaims: { _ in [.workspace] }, outputBytes: { $0.chargedBytes }) {
      try self.admit(publisher)
      return try publisher.documentIndexPage(afterOrdinal: afterOrdinal,
        expectedHead: expectedHead, validateRecord: {
          // Library metadata is not a native opening. Opening the selected
          // record later authenticates its tree and retained canonical history;
          // scrolling titles must not open up to 100 history roots per row.
          try $0.validate(); try self.admit($0.document.revision)
        })
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
      if try rootCustody.joinedFailure(lease) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }

  /// One bounded batch owns the serialized engine until its candidate writes,
  /// readback and coherent head publication join. No UI callback waits for it.
  /// At most102 logical steps can reconstruct at most101 source roots; this is a bounded worker operation,
  /// not a measured foreground latency ceiling or an ordinary-app activation.
  func commitNativeRetaining(_ batch: PagedNativeCommitBatch,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    try await rootOutput(purpose: .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID,
        first: batch.firstSequence, last: batch.lastSequence),
      claims: [.record(batch.expectedRootRecord), .writerDocument(batch.expected.revision.documentID), .workspace],
      payloadBytes: PagedWorkingWindow.hardBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { [.record(batch.expectedRootRecord), .record($0.sealedRootRecord),
        .writerDocument(batch.expected.revision.documentID), .workspace] },
      outputBytes: { $0.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes },
      nativeAcknowledgement: { $0 }, sqlOperation: batch.batchID, sqlExpectedRecord: batch.expectedRootRecord,
      sqlIntent: .native(batch), nativeInput: batch) {
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
        let cursor = PagedSealedCursor(byteOffset: cursorByte.partialValue, utf16Offset: cursorUTF16.partialValue)
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
          let beforeCursor = PagedSealedCursor(byteOffset: beforeByte.partialValue, utf16Offset: beforeUTF16.partialValue)
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
      let published = try publisher.publishDocument(sealedRecord, expected: batch.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      guard published.record == sealedRecord, published.operationID == batch.batchID else {
        throw BoomError.invalid("Coherent publisher did not seal the exact native root/history record.")
      }
      let canonical = try self.nativeCanonicalProjection(history: history, beforeHistory: beforeHistory,
        record: sealedRecord, beforeRecord: batch.expectedRootRecord,
        scope: .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID,
          first: batch.firstSequence, last: batch.lastSequence), lineage: lineage)
      return try PagedNativeCommitAcknowledgement(validating: batch, sealedWindow: sealedWindow,
        sealedRootRecord: sealedRecord, canonicalHistory: canonical)

  }
  /// Read-only source admission: the complete authenticated catalog record
  /// must match, but positioning does not traverse its independent Undo roots.
  private func admitNavigationRecord(_ record: PagedDocumentRootRecord) throws {
    try record.validate(); try admit(record.document.revision)
    let actual: PagedTextRevision = try execute(Request(op: "open", revision: record.document.revision))
    guard actual == record.document.revision else { throw BoomError.stale("Navigation source changed during admission.") }
  }
  func nativeNavigationPosition(publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord,
    utf16Offset: UInt64, forward: Bool = false) async throws -> PagedTextSummary {
    try await rootRead(claims: [.record(expected), .workspace]) {
      try self.admit(publisher)
      return try self.router.database().withReadSnapshot {
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
  }
  /// One actual retained viewport read, independent of the caret's native
  /// island. The receiving viewport holds this lease until it stops displaying
  /// the immutable projection and its read/mount tasks have actually joined.
  func nativeScrollWindowRetaining(publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord,
    utf16Anchor: UInt64) async throws -> PagedTextCustodiedValue<PagedTextWindow> {
    try await rootOutput(claims: [.record(expected), .workspace], payloadBytes: PagedWorkingWindow.targetBytes,
      outputClaims: { _ in [.record(expected), .workspace] }, outputBytes: { $0.text.utf8.count }) {
      try self.admit(publisher)
      return try self.router.database().withReadSnapshot {
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

  /// Prepare one native history intent without admitting a sequence or
  /// publishing any source. Metadata uses the existing routed page provider;
  /// the caller retains both records until explicit command disposition.
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
      let localCaret = history.currentCursor.utf16Offset - window.utf16Start
      guard let localCaretUTF16 = Int(exactly: localCaret) else {
        throw BoomError.budget("Retained history cursor exceeds native island coordinates.")
      }
      let document = PagedDocumentDescriptor(id: command.expectedRootRecord.document.id,
        title: command.expectedRootRecord.document.title, revision: history.current)
      let record = try self.withNativeHistory(documentID: document.id, writes: true) { store in
        let written = try store.writeNew(history, document: document)
        guard try store.load(written) == history else {
          throw BoomError.invalid("Prepared encrypted history differs from the exact retained-root move.")
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

  /// Called only after the registered controller has synchronously admitted
  /// this exact preparation. Observer cancellation cannot cancel an accepted
  /// command between its journal and head writes. Recovery is explicit.
  func commitNativeHistoryMoveRetaining(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeHistoryAcknowledgement> {
    try await rootOutput(purpose: .nativePublication(routeID: prepared.routeID, preparationID: prepared.preparationID),
      claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord),
        .writerDocument(prepared.command.handle.documentID), .workspace],
      payloadBytes: PagedWorkingWindow.targetBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { _ in [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord),
        .writerDocument(prepared.command.handle.documentID), .workspace] },
      outputBytes: { $0.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes },
      nativeHistoryPublication: { (prepared, $0) }, sqlOperation: prepared.preparationID,
      sqlExpectedRecord: prepared.command.expectedRootRecord, sqlIntent: .history(prepared, admission)) {
      try self.admit(publisher); try admission.validate(for: prepared); try self.willPublish()
      try publisher.admitCurrentRecord(prepared.command.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      let validated = try self.validatePreparedNativeHistory(prepared)
      let window = validated.window
      let record = prepared.candidateRecord
      let published = try publisher.publishDocument(record, expected: prepared.command.expectedRootRecord,
        validateRecord: { try self.validateNativeRecord($0) })
      guard published.record == record, published.operationID == prepared.preparationID else {
        throw BoomError.invalid("Coherent publisher did not seal the admitted retained-root history move.")
      }
      return try PagedNativeHistoryAcknowledgement(validating: prepared, admission: admission,
        publishedRecord: record, readWindow: window,
        canonicalHistory: try self.nativePublishedProjection(prepared, admission: admission, validated: validated))
    }
  }

  /// Exceptional inspection may read the complete metadata payload while
  /// recovering a journal. It never guesses success, rebases onto another
  /// document record, deletes unpublished pages or automatically repeats a move.
  func inspectNativeHistoryPublicationRetaining(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection> {
    try await rootOutput(claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord),
        .writerDocument(prepared.command.handle.documentID), .workspace], payloadBytes: PagedWorkingWindow.targetBytes, metadataBytes: PagedTextRootCustody.maximumNativeMetadataBytes,
      outputClaims: { _ in [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord),
        .writerDocument(prepared.command.handle.documentID), .workspace] }, outputBytes: { result in
        if case .published(let acknowledgement) = result {
          return acknowledgement.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes
        }; return 0
      }, historyBeforeProof: { result in
        if case .notPublished = result { return prepared.preparationID }; return nil
      }, nativeHistoryPublication: { result in
        if case .published(let acknowledgement) = result { return (prepared, acknowledgement) }; return nil
      }) {
      try self.admit(publisher); try admission.validate(for: prepared)
      let store = try self.router.database()
      if store.failedOperationID == nil,
        try self.rootCustody.hasJoinedSQLiteRollback(prepared, store: store.nativeReceivingIdentity) {
        try store.requireSourceAdmission()
        try publisher.admitCurrentRecord(prepared.command.expectedRootRecord,
          validateRecord: { try self.validateNativeRecord($0) })
        _ = try self.validatePreparedNativeHistory(prepared)
        // The actual original rollback proved no publication; this entered
        // producer reauthenticates current before and the bounded candidate.
        return .notPublished
      }
      if store.failedOperationID == nil,
        try self.rootCustody.hasJoinedSQLiteHistoryPublication(prepared,
          admission: admission, store: store.nativeReceivingIdentity) {
        try store.requireSourceAdmission() // Any failed/unresolved owner still refuses.
          do {
            try publisher.admitCurrentRecord(prepared.candidateRecord,
              validateRecord: { try self.validateNativeRecord($0) })
          } catch BoomError.stale(_) {
            return .conflict(nil) // A same-document successor is not this publication.
          }
          // Both retained histories, exact cursor and <=16KiB island are
          // authenticated/recomputed by this actual new entered producer.
          let validated = try self.validatePreparedNativeHistory(prepared)
          return .published(try PagedNativeHistoryAcknowledgement(validating: prepared,
            admission: admission, publishedRecord: prepared.candidateRecord,
            readWindow: validated.window,
            canonicalHistory: try self.nativePublishedProjection(prepared,
              admission: admission, validated: validated)))
      }
      return .conflict(nil) // No actual joined success/rollback; visible rows grant no proof.

    }
  }

  func repairFailedNativeHistoryPublicationRetaining(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection> {
    try admission.validate(for: prepared)
    let result = try await resolveSQLiteOutputRetaining(custody, publisher: publisher)
    switch result.value {
    case .history(let ack):
      guard ack.preparationID == prepared.preparationID, ack.expectedRootRecord == prepared.command.expectedRootRecord,
        ack.admittedSequence == admission.admittedSequence else { throw BoomError.stale("History resolution returned another normal output.") }
      return PagedTextCustodiedValue(value: .published(ack), lease: custody)
    case .before: return PagedTextCustodiedValue(value: .notPublished, lease: custody)
    default: throw BoomError.stale("Actual history producer resolved another receiving purpose.")
    }
  }
  func repairFailedNativeCommitRetaining(_ batch: PagedNativeCommitBatch,
    custody: PagedTextRootLease, publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    try rootCustody.admitActualNativeInput(custody, batch: batch)
    let result = try await resolveSQLiteOutputRetaining(custody, publisher: publisher)
    guard case .native(let ack) = result.value, ack.sessionID == batch.sessionID,
      ack.batchID == batch.batchID, ack.expectedRootRecord == batch.expectedRootRecord,
      ack.lastSequence == batch.lastSequence else { throw BoomError.stale("Actual input is known unpublished; retain it for explicit same-batch retry.") }
    return PagedTextCustodiedValue(value: ack, lease: custody)
  }
  /// Exceptional lost-delivery inspection of a known successful native ACK
  /// already in the actual controller. The queued read authenticates the
  /// current AFTER plus original input/history; no SQL write or output transfer.
  func inspectInstalledNativeCommit(_ controller: PagedTextRootLease,
    batch: PagedNativeCommitBatch, publisher: PagedWorkspacePublisher) async throws -> PagedNativeCommitAcknowledgement {
    try await onQueue(priority: .cleanup, custody: controller) {
      try self.admit(publisher)
      let store = try self.router.database()
      let borrowed = try self.rootCustody.borrowNativeAcknowledgement(controller,
        batch: batch, store: store.nativeReceivingIdentity)
      // A repaired AFTER may still own this exact fence until Main finish.
      // Read through its retained actual execution; never release it here.
      try store.withOutcomeReads(borrowed.execution) {
        try store.requireSourceAdmission()
        try publisher.admitCurrentRecord(borrowed.acknowledgement.sealedRootRecord,
          validateRecord: { try self.validateNativeRecord($0) })
        try self.validateActualNativeOutput(batch: batch, acknowledgement: borrowed.acknowledgement)
      }
      return borrowed.acknowledgement // original output remains in the same Root slot
    }
  }

  /// Single explicit known-BEFORE retry, SAME actual retained ordered input and
  /// lease. Later input is never rebased and unknown COMMIT never reaches here.
  func retryNativeCommitBeforeRetaining(_ custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedNativeCommitAcknowledgement> {
    guard case .some(.native) = try rootCustody.sqlState(custody)?.intent else { throw BoomError.denied("The retained intent is not ordinary input.") }
    let sql = try rootCustody.admitSQLBeforeRetry(custody)
    guard case .native(let batch) = sql.intent else { throw BoomError.denied("The retained BEFORE intent is not ordinary input.") }
    do {
      return try await onQueue(priority: .cleanup, custody: custody) {
        try self.rootCustody.start(custody)
        let ack = try self.withSQLWrite(operationID: batch.batchID, expectedRecord: batch.expectedRootRecord, intent: .native(batch)) {
          let value = try self.makeNativeAcknowledgement(batch, publisher: publisher)
          try self.rootCustody.stageSQLNativeOutput(custody, output: .native(value)); return value
        }
        try self.rootCustody.finishOutput(custody,
          claims: [.record(batch.expectedRootRecord), .record(ack.sealedRootRecord), .writerDocument(batch.expected.revision.documentID), .workspace],
          payloadBytes: ack.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes, inFlightWitness: self.inFlightWitness,
          nativeAcknowledgement: ack)
        return PagedTextCustodiedValue(value: ack, lease: custody)
      }
    } catch { _ = try rootCustody.joinedFailure(custody); throw PagedTextCustodyFailure(original: error, lease: custody) }
  }
  func retryWorkspaceBeforeRetaining(_ custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<PagedWorkspaceSnapshot> {
    guard case .some(.workspace) = try rootCustody.sqlState(custody)?.intent else { throw BoomError.denied("The retained intent is not metadata.") }
    let sql = try rootCustody.admitSQLBeforeRetry(custody)
    guard case .workspace(let prepared, let documents, let expectedHead) = sql.intent else { throw BoomError.denied("The retained BEFORE intent is not metadata.") }
    do {
      return try await onQueue(priority: .cleanup, custody: custody) {
        try self.rootCustody.start(custody); try self.admit(publisher)
        let snapshot = try self.withSQLWrite(operationID: sql.operation.operationID, intent: sql.intent) {
          let value = try self.publishPreparedWorkspace(publisher, prepared: prepared, documents: documents, expectedHead: expectedHead)
          try self.rootCustody.stageSQLNativeOutput(custody, output: .workspace(value)); return value
        }
        try self.rootCustody.finishOutput(custody, claims: [.workspace], payloadBytes: 0, inFlightWitness: self.inFlightWitness)
        return PagedTextCustodiedValue(value: snapshot, lease: custody)
      }
    } catch { _ = try rootCustody.joinedFailure(custody); throw PagedTextCustodyFailure(original: error, lease: custody) }
  }

  /// Cancels the exact resolved metadata BEFORE under the SAME actual owner.
  /// No source/native output is manufactured and no staged objects are deleted.
  /// Original failure is returned as evidence; independent state is untouched.
  func cancelResolvedWorkspaceBefore(_ custody: PagedTextRootLease,
    publisher: PagedWorkspacePublisher, execution: PagedSQLiteExecution) async throws -> Error? {
    try await onQueue(priority: .cleanup, custody: custody) {
      try self.admit(publisher)
      guard let sql = try self.rootCustody.sqlState(custody), sql.execution === execution,
        execution.outcome == .resolved(.before), sql.engineJoined else {
        throw BoomError.stale("Cancellation has another actual metadata outcome.")
      }
      let isTypedMetadata: Bool
      switch sql.intent { case .workspace: isTypedMetadata = false; case .metadata: isTypedMetadata = true
      default: throw BoomError.stale("Cancellation has no actual workspace/metadata input.") }
      let store = try self.router.database()
      try store.withOutcomeReads(execution) {
        if let actualBefore = execution.beforeHead {
          let current = try (isTypedMetadata ? publisher.settingsRead().head
            : publisher.load(validateRecord: { try self.validateNativeRecord($0) }).head)
          guard current == actualBefore else {
            throw BoomError.stale("Resolved metadata BEFORE changed its authenticated full head.")
          }
        } else {
          guard execution.beforeHead == nil, try store.headID() == nil,
            try store.documentIDs().isEmpty else {
            throw BoomError.stale("Resolved initial metadata BEFORE is no longer absent.")
          }
          if isTypedMetadata, try store.hasEntityInventory() { throw BoomError.stale("Initial typed metadata BEFORE has another entity inventory.") }
        }
      }
      // Resolution already established durability and released the exact Store
      // refusal. Root now consumes only this actual joined one-use operation.
      return try self.rootCustody.cancelResolvedWorkspaceBefore(custody, execution: execution)
    }
  }

  private struct NativeHistoryPlan {
    let before: PagedRootHistory
    let after: PagedRootHistory
    let lineage: PagedNativeHistorySlotLineage
  }
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
    // At most 4096 UTF16 units precede the exact cursor, using <=12288 bytes.
    // This leaves room for its scalar in the fixed 16KiB projection. Only this
    // approximate context anchor may move by one unit past a half-surrogate;
    // the exact retained cursor is never rounded or truncated.
    var anchor = cursor.utf16Offset > 4_096 ? cursor.utf16Offset - 4_096 : 0
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
      window.text.utf8.count <= PagedWorkingWindow.targetBytes, cursor.utf16Offset >= anchor,
      let localCaret = Int(exactly: cursor.utf16Offset - anchor) else {
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
      throw BoomError.invalid("Encrypted prepared history differs from the admitted native move.")
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
      guard let caret = Int(exactly: history.currentCursor.utf16Offset - window.utf16Start) else {
        throw BoomError.budget("Canonical opening cursor exceeds its bounded island.")
      }
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.validateNativeRecord($0) })
      let projection = try self.nativeCanonicalProjection(history: history, beforeHistory: nil,
        record: expected, beforeRecord: nil, scope: .opening(sessionID: sessionID, windowID: window.windowID), lineage: nil)
      return PagedNativeCanonicalOpening(sessionID: sessionID, record: expected, window: window,
        history: projection, localCaretUTF16: caret)
    }
  }

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  func _publicSQLControlArmCommitFault(identity: PagedSQLPublicControlIdentity,
    fault: PagedSQLitePublicCommitFault) async throws {
    try await onQueue(priority: .cleanup) {
      guard identity.engine === self, identity.engineIncarnation == self.custodyIncarnation else { throw BoomError.denied("Public COMMIT fault has another actual engine.") }
      try self.router.database()._publicArmCommitFault(identity: identity, fault: fault)
    }
  }
  func _publicSQLControlRestoreDatabaseName(identity: PagedSQLPublicControlIdentity) async throws {
    try await onQueue(priority: .cleanup) {
      guard identity.engine === self, identity.engineIncarnation == self.custodyIncarnation else { throw BoomError.denied("Public name restoration has another actual engine.") }
      try self.router.database()._publicRestoreDatabaseName(identity: identity)
    }
  }
  func _publicSQLControlRestoreFailedSetupName(_ failure: PagedTextSetupCustodyFailure) async throws {
    guard failure.engine === self else { throw BoomError.denied("Failed public setup belongs to another actual engine.") }
    try await onQueue(priority: .cleanup, custody: failure.lease) {
      try self.router.database()._publicRestoreFailedSetupName()
    }
  }
  func _publicSQLControlIdentity(expectedVault: Vault, expectedStoreID: UUID) async throws -> PagedSQLPublicControlIdentity {
    try await onQueue {
      let store = try self.router.database(); try store.requireSourceAdmission()
      guard self.handle != 0, self.router.vault === expectedVault, store.belongs(to: expectedVault),
        store.ownerID == self.ownerID, store.storeID == expectedStoreID else {
        throw BoomError.denied("Public SQL control has another actual Vault, engine or connection.")
      }
      return PagedSQLPublicControlIdentity(engine: self, vault: expectedVault, store: store)
    }
  }
  /// Scalar observation only: a UUID pointer is not an authenticated full head,
  /// source reachability, publication, durability or receiving capability. The
  /// actual entered Root job and short-lived returned lease retain the existing
  /// workspace admission claim until explicit abandonment. The scalar pointer
  /// itself supplies no authenticated record or source reachability authority.
  func _publicSQLControlHeadPointerRetaining(identity: PagedSQLPublicControlIdentity)
    async throws -> PagedTextCustodiedValue<UUID?> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmission(identity)
      return try store.withReadSnapshot { try store.headID() }
    }
  }
  /// Same real utility encoder, background chunk transactions, bulk owner and
  /// Root output as the ordinary metadata route. Only the public test carrier
  /// is separate; no connection, executor, key or publication authority is added.
  func _publicSQLControlPrepareWorkspaceRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, state: WorkspaceState,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedSQLPublicPreparedWorkspace> {
    // This is the ordinary workspace barrier, not a larger native window.
    // The <=1MiB public encoder bound does not repair the separate existing
    // metadata-input/utility-allocation accounting gap.
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.workspace])
    let bulk: UUID
    do { bulk = try executor.reserveBulk(cancellation); try rootCustody.start(lease) }
    catch { _ = try rootCustody.joinedFailure(lease); throw error }
    defer { executor.releaseBulk(bulk) }
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        try await onQueue(cancellation: cancellation, custody: lease) {
          _ = try self.publicSQLControlAdmission(identity); try self.admit(publisher)
        }
        let encoded = try await performStreamIO {
          guard !cancellation.isCancelled else { throw CancellationError() }
          let encoded = try publisher.encodeWorkspace(state)
          guard encoded.reference.plaintextBytes <= PagedSQLPublicPreparedWorkspace.maximumEncodedBytes else {
            throw BoomError.budget("Public publisher control exceeds its explicit 1MiB encoded fixture bound.")
          }
          return encoded
        }
        try rootCustody.willWriteWorkspace(lease)
        for part in 0..<encoded.partCount {
          try await onQueue(priority: .background, cancellation: cancellation, custody: lease) {
            _ = try self.publicSQLControlAdmission(identity); try self.admit(publisher)
            try self.withSQLWrite(operationID: UUID()) { try publisher.stageWorkspacePart(encoded, part: part) }
          }
        }
        return try await onQueue(priority: .background, cancellation: cancellation, custody: lease) {
          _ = try self.publicSQLControlAdmission(identity); try self.admit(publisher)
          let prepared = try publisher.finishWorkspacePreparation(encoded)
          let output = PagedSQLPublicPreparedWorkspace(identity: identity, producer: lease, prepared: prepared)
          try self.rootCustody.finishOutput(lease, claims: [.workspace], payloadBytes: 0,
            inFlightWitness: self.inFlightWitness)
          return PagedTextCustodiedValue(value: output, lease: lease)
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(lease) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }
  func _publicSQLControlPreparedPartWitnessRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, prepared: PagedSQLPublicPreparedWorkspace, part: Int)
    async throws -> PagedTextCustodiedValue<PagedSQLPublicPreparedPartCiphertextWitness> {
    try await rootOutput(claims: [.workspace], payloadBytes: PagedSQLPublicWorkspaceCiphertextWitness.maximumCiphertextBytes,
      outputClaims: { _ in [.workspace] }, outputBytes: { $0.ciphertextBytes }) {
      let store = try self.publicSQLControlAdmitPrepared(identity, publisher: publisher, prepared: prepared)
      guard self.publicSQLWitness == nil, self.publicSQLPublisherWitness == nil, self.publicSQLPreparedWitness == nil,
        part >= 0, part < prepared.reference.partCount else { throw BoomError.stale("Public prepared part is already mutated or outside its actual reference.") }
      return try store.withReadSnapshot {
        guard try store.headID() == nil, try store.documentIDs().isEmpty, let producer = self.activeCustody else {
          throw BoomError.denied("Prepared-part corruption controls require an actual unpublished fresh head and Root producer.")
        }
        let bytes = try store._publicControlPreparedPartCiphertext(identity: identity, reference: prepared.reference, part: part)
        return try PagedSQLPublicPreparedPartCiphertextWitness(identity: identity, producer: producer,
          prepared: prepared, part: part, original: bytes)
      }
    }
  }
  func _publicSQLControlCorruptPreparedPartRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicPreparedPartCiphertextWitness) async throws -> PagedTextCustodiedValue<PagedSQLPublicPreparedPartMutationReceipt> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmitPreparedPartWitness(identity, witness: witness)
      guard self.publicSQLWitness == nil, self.publicSQLPublisherWitness == nil, self.publicSQLPreparedWitness == nil,
        case .prepared = witness.phase else { throw BoomError.stale("One public corruption remains attempted/owned.") }
      let operationID = UUID()
      guard let producer = self.activeCustody else { throw BoomError.denied("Prepared corruption has no actual Root writer.") }
      try self.rootCustody.willWriteWorkspace(producer)
      self.publicSQLPreparedWitness = witness; witness.phase = .corrupting(operationID)
      try self.withSQLWrite(operationID: operationID) {
        try store._publicControlReplacePreparedPartCiphertext(identity: identity, reference: witness.reference,
          part: witness.part, original: witness.original, replacement: witness.corruptedBytes())
      }
      witness.phase = .corrupted(operationID) // only after actual COMMIT/namespace admission
      return PagedSQLPublicPreparedPartMutationReceipt(operationID: operationID, witness: witness, restored: false)
    }
  }
  func _publicSQLControlRestorePreparedPartRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicPreparedPartCiphertextWitness) async throws -> PagedTextCustodiedValue<PagedSQLPublicPreparedPartMutationReceipt> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmitPreparedPartWitness(identity, witness: witness)
      guard self.publicSQLPreparedWitness === witness, self.publicSQLWitness == nil, self.publicSQLPublisherWitness == nil,
        case .corrupted(let corruptionID) = witness.phase else { throw BoomError.stale("Prepared restoration needs its exact successful corruption.") }
      let operationID = UUID()
      guard let producer = self.activeCustody else { throw BoomError.denied("Prepared restoration has no actual Root writer.") }
      try self.rootCustody.willWriteWorkspace(producer)
      witness.phase = .restoring(operationID)
      try self.withSQLWrite(operationID: operationID) {
        guard self.rootCustody.hasActualCommittedCandidate(operationID: corruptionID,
          store: store.nativeReceivingIdentity, beforeRecord: nil) else {
          throw BoomError.stale("Prepared restoration lost its actual retained known-success producer.")
        }
        try store._publicControlReplacePreparedPartCiphertext(identity: identity, reference: witness.reference,
          part: witness.part, original: witness.corruptedBytes(), replacement: witness.original)
      }
      try store.withReadSnapshot {
        let restored = try store._publicControlPreparedPartCiphertext(identity: identity, reference: witness.reference, part: witness.part)
        guard restored == witness.original else { throw BoomError.stale("Restored prepared part differs from its actual original ciphertext.") }
      }
      witness.phase = .restored(operationID); self.publicSQLPreparedWitness = nil
      return PagedSQLPublicPreparedPartMutationReceipt(operationID: operationID, witness: witness, restored: true)
    }
  }
  private func publicSQLControlAdmitPreparedPartWitness(_ identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicPreparedPartCiphertextWitness) throws -> PagedSQLiteStore {
    let store = try publicSQLControlAdmission(identity)
    guard witness.identity === identity, witness.prepared.identity === identity,
      witness.preparationID == witness.prepared.id, witness.reference == witness.prepared.reference,
      try rootCustody.claims(witness.producer).contains(.workspace),
      try rootCustody.claims(witness.prepared.producer).contains(.workspace) else {
      throw BoomError.denied("Prepared-part witness lost either actual original preparation/ciphertext producer.")
    }
    try witness.reference.validate(ownerID: ownerID)
    return store
  }

  /// One actual authenticated fixed part from the live producer-made prepared
  /// reference. Digest is observation only, never head/publication authority.
  func _publicSQLControlPreparedPartDigestRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, prepared: PagedSQLPublicPreparedWorkspace, part: Int)
    async throws -> PagedTextCustodiedValue<String> {
    try await rootOutput(claims: [.workspace], payloadBytes: 65_536, outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmitPrepared(identity, publisher: publisher, prepared: prepared)
      guard part >= 0, part < prepared.reference.partCount else { throw BoomError.invalid("Public prepared part is outside the actual reference.") }
      let maximum = min(65_536, prepared.reference.plaintextBytes - part * 65_536)
      let bytes = try store.withReadSnapshot {
        try store.read(objectID: prepared.reference.objectID, documentID: Vault.workspaceID,
          role: .workspace, maximumBytes: maximum, part: part)
      }
      guard bytes.count == maximum else { throw BoomError.invalid("Actual prepared workspace part has another extent.") }
      return Digest.sha256(bytes)
    }
  }
  /// Attempt only the same existing immutable key and exact bytes returned by
  /// the actual authenticated part read. No new object ID, arbitrary plaintext,
  /// UPDATE/REPLACE, connection, head mutation or caller validator is supplied.
  /// SQLite's genuine PRIMARY KEY refusal and real rollback are the oracle.
  func _publicSQLControlRestagePreparedPartRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, prepared: PagedSQLPublicPreparedWorkspace, part: Int)
    async throws -> PagedTextCustodiedValue<String> {
    try await rootOutput(claims: [.workspace], payloadBytes: 65_536, outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmitPrepared(identity, publisher: publisher, prepared: prepared)
      guard part >= 0, part < prepared.reference.partCount else { throw BoomError.invalid("Public immutable-key attempt is outside the actual prepared reference.") }
      guard let producer = self.activeCustody else { throw BoomError.denied("Public immutable-key attempt has no actual Root writer.") }
      try self.rootCustody.willWriteWorkspace(producer)
      return try self.withSQLWrite(operationID: UUID()) {
        try store._publicControlRestagePreparedPart(identity: identity, reference: prepared.reference, part: part)
      }
    }
  }

  /// Exact actual prepared producer plus normal Publisher admission. The
  /// control uses the real cancellation flag only at the initial head boundary
  /// after actual record validation/writes; it does not forge a failure code.
  func _publicSQLControlPublishPreparedWorkspaceRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, prepared: PagedSQLPublicPreparedWorkspace,
    documents: [PagedDocumentRootRecord], expectedHead: PagedWorkspaceHead?,
    initialControl: PagedSQLPublicInitialPublicationControl = .ordinary,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspacePublication> {
    let operationID = UUID()
    return try await rootOutput(claims: [.workspace], cancellation: cancellation,
      outputClaims: { _ in [.workspace] }) {
      _ = try self.publicSQLControlAdmitPrepared(identity, publisher: publisher, prepared: prepared)
      guard prepared.attempts < PagedSQLPublicPreparedWorkspace.maximumPublicationAttempts,
        expectedHead == nil || initialControl == .ordinary else {
        throw BoomError.budget("Public preparation attempt bound or initial-only control was refused.")
      }
      prepared.attempts += 1; prepared.lastOperationID = operationID
      prepared.lastValidationCount = 0; prepared.lastPublicationChecks = 0
      guard let producer = self.activeCustody else { throw BoomError.denied("Public prepared publication has no actual Root writer.") }
      try self.rootCustody.willWriteWorkspace(producer)
      let snapshot = try self.withSQLWrite(operationID: operationID,
        intent: .workspace(prepared.prepared, documents, expectedHead: expectedHead)) {
        if let expectedHead {
          guard !cancellation.isCancelled else { throw CancellationError() }
          try self.willPublish()
          let value = try publisher.publishWorkspace(prepared.prepared, documents: documents, expectedHead: expectedHead,
            validateRecord: { record in
              try self.validateNativeRecord(record); prepared.lastValidationCount += 1
            })
          try self.rootCustody.stageSQLNativeOutput(producer, output: .workspace(value))
          return value
        }
        let value = try publisher.initialize(prepared.prepared, documents: documents,
          validateRecord: { record in
            try self.validateNativeRecord(record); prepared.lastValidationCount += 1
          }, beforePublication: {
            prepared.lastPublicationChecks += 1
            if initialControl == .cancelAfterRecordValidation { cancellation.cancel() }
            guard !cancellation.isCancelled else { throw CancellationError() }
            try self.willPublish()
          })
        try self.rootCustody.stageSQLNativeOutput(producer, output: .workspace(value))
        return value
      }
      return PagedSQLPublicWorkspacePublication(operationID: operationID, snapshot: snapshot,
        validatedRecords: prepared.lastValidationCount)
    }
  }
  /// Fixed scalar evidence is readable on the cleanup lane after refusal. It
  /// does not enter SQL, classify publication, clear a fence or consume custody.
  func _publicSQLControlPreparedWorkspaceEvidence(identity: PagedSQLPublicControlIdentity,
    prepared: PagedSQLPublicPreparedWorkspace) async throws -> PagedSQLPublicPreparedWorkspaceEvidence {
    try await onQueue(priority: .cleanup) {
      let store = try self.router.database(); try store.requireQueue()
      guard identity.engine === self, identity.store === store, identity.vault === self.router.vault,
        identity.engineIncarnation == self.custodyIncarnation, prepared.identity === identity,
        try self.rootCustody.claims(prepared.producer).contains(.workspace) else {
        throw BoomError.denied("Prepared evidence lost its exact live public owners/producer.")
      }
      return PagedSQLPublicPreparedWorkspaceEvidence(preparationID: prepared.id, attempts: prepared.attempts,
        operationID: prepared.lastOperationID, validatedRecords: prepared.lastValidationCount,
        publicationChecks: prepared.lastPublicationChecks)
    }
  }
  /// The actual targeted publisher validates exactly its real after-record.
  /// This returned count is observation, never a supplied validator or native ACK.
  func _publicSQLControlPublishDocumentRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, after: PagedDocumentRootRecord,
    expected: PagedDocumentRootRecord) async throws -> PagedTextCustodiedValue<PagedSQLPublicDocumentPublication> {
    let operationID = UUID()
    return try await rootOutput(claims: [.record(expected), .record(after), .workspace, .writerDocument(after.document.id)],
      outputClaims: { [.record($0.publication.record), .workspace] }) {
      _ = try self.publicSQLControlAdmission(identity); try self.admit(publisher)
      try after.validate(); try self.admit(after.document.revision)
      try self.willWrite(after.document.id)
      var validated = 0
      let publication = try self.withSQLWrite(operationID: operationID, expectedRecord: expected) {
        try self.willPublish()
        return try publisher.publishDocument(after, expected: expected,
          validateRecord: { record in try self.validateNativeRecord(record); validated += 1 })
      }
      return PagedSQLPublicDocumentPublication(publication: publication, validatedRecords: validated)
    }
  }
  func _publicSQLControlAdmitCurrentRecordRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord) async throws -> PagedTextCustodiedValue<PagedSQLPublicRecordAdmission> {
    try await rootOutput(claims: [.record(expected), .workspace], outputClaims: { [.record($0.record), .workspace] }) {
      _ = try self.publicSQLControlAdmission(identity); try self.admit(publisher)
      var validated = 0
      try publisher.admitCurrentRecord(expected,
        validateRecord: { record in try self.validateNativeRecord(record); validated += 1 })
      return PagedSQLPublicRecordAdmission(record: expected, validatedRecords: validated)
    }
  }
  private func publicSQLControlAdmitPrepared(_ identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, prepared: PagedSQLPublicPreparedWorkspace) throws -> PagedSQLiteStore {
    let store = try publicSQLControlAdmission(identity); try admit(publisher)
    guard prepared.identity === identity, try rootCustody.claims(prepared.producer).contains(.workspace),
      prepared.reference.plaintextBytes <= PagedSQLPublicPreparedWorkspace.maximumEncodedBytes else {
      throw BoomError.denied("Publication lost its exact actual prepared producer/fixture bound.")
    }
    return store
  }
  func _publicSQLControlWorkspaceCiphertextWitnessRetaining(identity: PagedSQLPublicControlIdentity,
    publisher: PagedWorkspacePublisher, head: PagedWorkspaceHead, record: PagedDocumentRootRecord?,
    target: PagedSQLPublicWorkspaceCiphertextTarget) async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspaceCiphertextWitness> {
    let claims: [PagedTextRootClaim] = [.workspace] + (record.map { [.record($0)] } ?? [])
    return try await rootOutput(claims: claims, payloadBytes: PagedSQLPublicWorkspaceCiphertextWitness.maximumCiphertextBytes,
      outputClaims: { _ in claims }, outputBytes: { $0.ciphertextBytes }) {
      let store = try self.publicSQLControlAdmission(identity); try self.admit(publisher)
      guard self.publicSQLPublisherWitness == nil, self.publicSQLWitness == nil, self.publicSQLPreparedWitness == nil,
        head.workspace.plaintextBytes <= PagedSQLPublicPreparedWorkspace.maximumEncodedBytes else {
        throw BoomError.budget("Public Publisher witness requires an unmutated <=1MiB fixture.")
      }
      return try store.withReadSnapshot {
        let snapshot = try publisher.load(validateRecord: { try self.validateNativeRecord($0) })
        guard snapshot.head == head else {
          throw BoomError.stale("Public Publisher witness has another authenticated snapshot/full record.")
        }
        if let record, !snapshot.documents.contains(record) { throw BoomError.stale("Public Publisher witness has another exact full record.") }
        guard let producer = self.activeCustody else { throw BoomError.denied("Public Publisher witness has no actual entered Root producer.") }
        let row = try store._publicControlWorkspaceCiphertext(identity: identity, head: head, record: record, target: target)
        return try PagedSQLPublicWorkspaceCiphertextWitness(identity: identity, producer: producer,
          head: head, record: record, target: target, objectID: row.objectID, documentID: row.documentID,
          role: row.role, part: row.part, original: row.ciphertext)
      }
    }
  }
  func _publicSQLControlCorruptWorkspaceCiphertextRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicWorkspaceCiphertextWitness) async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspaceMutationReceipt> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmitWorkspaceWitness(identity, witness: witness)
      guard self.publicSQLPublisherWitness == nil, self.publicSQLWitness == nil, self.publicSQLPreparedWitness == nil,
        case .prepared = witness.phase else { throw BoomError.stale("One real public mutation is already attempted/owned.") }
      if case .head = witness.target { throw BoomError.denied("Public head ciphertext is observation-only; no admission bypass.") }
      // Re-authenticate the entire original fixture before the intentional
      // damage. The immutable witness/producer remains held across any refusal.
      let publisher = try PagedWorkspacePublisher(store: store, vault: self.router.vault)
      _ = try store.withReadSnapshot { try publisher.load(validateRecord: { try self.validateNativeRecord($0) }) }
      let operationID = UUID()
      guard let producer = self.activeCustody else { throw BoomError.denied("Public metadata mutation has no actual Root producer.") }
      try self.rootCustody.willWriteWorkspace(producer)
      self.publicSQLPublisherWitness = witness; witness.phase = .corrupting(operationID)
      try self.withSQLWrite(operationID: operationID) {
        try store._publicControlReplaceWorkspaceCiphertext(identity: identity, expectedHead: witness.head,
          originalHead: witness.head, record: witness.record, target: witness.target,
          objectID: witness.objectID, documentID: witness.documentID, role: witness.role, part: witness.part,
          original: witness.original, replacement: witness.corruptedBytes())
      }
      witness.phase = .corrupted(operationID) // only the actual successful COMMIT/namespace join
      return PagedSQLPublicWorkspaceMutationReceipt(operationID: operationID, witness: witness,
        observedHead: witness.head, restored: false)
    }
  }
  /// Current actual full head may have advanced through genuine character
  /// publication, but it must reuse this exact original workspace and row.
  /// Original producer + the same live known-success candidate Entry + ciphertext
  /// CAS are all required. Failed COMMIT never enters the restoration phase.
  func _publicSQLControlRestoreWorkspaceCiphertextRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicWorkspaceCiphertextWitness, expectedHead: PagedWorkspaceHead)
    async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspaceMutationReceipt> {
    try await rootOutput(claims: [.workspace], outputClaims: { _ in [.workspace] }) {
      let store = try self.publicSQLControlAdmitWorkspaceWitness(identity, witness: witness)
      guard self.publicSQLPublisherWitness === witness, self.publicSQLWitness == nil, self.publicSQLPreparedWitness == nil,
        case .corrupted(let corruptionID) = witness.phase else {
        throw BoomError.stale("Public restoration needs its exact known-successful mutation/producer.")
      }
      let operationID = UUID()
      guard let producer = self.activeCustody else { throw BoomError.denied("Public restoration has no actual Root producer.") }
      try self.rootCustody.willWriteWorkspace(producer)
      witness.phase = .restoring(operationID)
      try self.withSQLWrite(operationID: operationID) {
        guard self.rootCustody.hasActualCommittedCandidate(operationID: corruptionID,
          store: store.nativeReceivingIdentity, beforeRecord: nil) else {
          throw BoomError.stale("Workspace restoration lost its actual retained known-success producer.")
        }
        try store._publicControlReplaceWorkspaceCiphertext(identity: identity, expectedHead: expectedHead,
          originalHead: witness.head, record: witness.record, target: witness.target,
          objectID: witness.objectID, documentID: witness.documentID, role: witness.role, part: witness.part,
          original: witness.corruptedBytes(), replacement: witness.original)
      }
      let publisher = try PagedWorkspacePublisher(store: store, vault: self.router.vault)
      let snapshot = try store.withReadSnapshot { try publisher.load(validateRecord: { try self.validateNativeRecord($0) }) }
      guard snapshot.head == expectedHead else { throw BoomError.stale("Public restoration did not authenticate its exact current head.") }
      witness.phase = .restored(operationID); self.publicSQLPublisherWitness = nil
      return PagedSQLPublicWorkspaceMutationReceipt(operationID: operationID, witness: witness,
        observedHead: expectedHead, restored: true)
    }
  }
  private func publicSQLControlAdmitWorkspaceWitness(_ identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicWorkspaceCiphertextWitness) throws -> PagedSQLiteStore {
    let store = try publicSQLControlAdmission(identity)
    guard witness.identity === identity, try rootCustody.claims(witness.producer).contains(.workspace),
      witness.head.ownerID == ownerID, witness.head.storeID == store.storeID,
      witness.original.count >= 28, witness.original.count <= PagedSQLPublicWorkspaceCiphertextWitness.maximumCiphertextBytes else {
      throw BoomError.denied("Public Publisher ciphertext lost its actual original workspace producer/owners.")
    }
    try witness.head.validate(ownerID: ownerID); try witness.record?.validate()
    return store
  }

  func _publicSQLControlHistoryComponentLoadRetaining(identity: PagedSQLPublicControlIdentity,
    record: PagedDocumentRootRecord) async throws -> PagedTextCustodiedValue<PagedRootHistory> {
    try await rootOutput(claims: [.record(record)], payloadBytes: PagedRootHistory.maximumEncodedBytes,
      outputClaims: { _ in [.record(record)] }, outputBytes: { _ in PagedRootHistory.maximumEncodedBytes }) {
      let store = try self.publicSQLControlAdmission(identity)
      return try store.withReadSnapshot {
        try self.admit(record.document.revision)
        return try self.withNativeHistory(documentID: record.document.id, writes: false) { try $0.load(record) }
      }
    }
  }
  func _publicSQLControlHistoryRetaining(identity: PagedSQLPublicControlIdentity,
    record: PagedDocumentRootRecord) async throws -> PagedTextCustodiedValue<PagedRootHistory> {
    try await rootOutput(claims: [.record(record)], payloadBytes: PagedRootHistory.maximumEncodedBytes,
      outputClaims: { _ in [.record(record)] }, outputBytes: { _ in PagedRootHistory.maximumEncodedBytes }) {
      let store = try self.publicSQLControlAdmission(identity)
      return try store.withReadSnapshot {
        try self.validateNativeRecord(record)
        let history = try self.withNativeHistory(documentID: record.document.id, writes: false) { try $0.load(record) }
        try self.publicSQLControlAdmitHistory(history, document: record.document)
        return history
      }
    }
  }
  func _publicSQLControlWriteHistoryRetaining(identity: PagedSQLPublicControlIdentity,
    history: PagedRootHistory, document: PagedDocumentDescriptor) async throws -> PagedTextCustodiedValue<PagedDocumentRootRecord> {
    try await rootOutput(claims: [.source(document.revision), .writerDocument(document.id), .workspace],
      outputClaims: { [.record($0), .writerDocument(document.id)] }) {
      let store = try self.publicSQLControlAdmission(identity)
      try store.withReadSnapshot { try self.publicSQLControlAdmitHistory(history, document: document) }
      try self.willWrite(document.id) // Preserve this producer even if BEGIN/body/COMMIT is refused.
      return try self.withSQLWrite(operationID: UUID()) {
        try self.publicSQLControlAdmitHistory(history, document: document)
        let record = try self.withNativeHistory(documentID: document.id, writes: true) { try $0.writeNew(history, document: document) }
        try self.validateNativeRecord(record)
        return record
      }
    }
  }
  func _publicSQLControlCiphertextWitnessRetaining(identity: PagedSQLPublicControlIdentity,
    record: PagedDocumentRootRecord, target: PagedSQLPublicPageTarget) async throws -> PagedTextCustodiedValue<PagedSQLPublicCiphertextWitness> {
    try await rootOutput(claims: [.record(record)], payloadBytes: PagedSQLPublicCiphertextWitness.maximumCiphertextBytes,
      outputClaims: { [.record($0.record)] }, outputBytes: { $0.ciphertextBytes }) {
      let store = try self.publicSQLControlAdmission(identity)
      return try store.withReadSnapshot {
        try self.validateNativeRecord(record)
        let page: PagedTextPageRef
        switch target {
        case .sourceRoot:
          guard let root = record.document.revision.root else { throw BoomError.unavailable("An empty source has no root page.") }
          page = root.page
        case .historyManifest: page = record.historyPage
        case .historySegment(let index):
          let pages = PagedSQLiteDocumentPages(store: store, ownerID: self.ownerID, documentID: record.document.id)
          let bytes = try pages.read(ownerID: self.ownerID, documentID: record.document.id, kind: .index,
            page: record.historyPage, maximumPlaintextBytes: PagedRootHistoryStore.maximumManifestBytes)
          let manifest = try JSONDecoder().decode(PagedRootHistoryManifest.self, from: bytes); try manifest.validate(expected: record)
          guard index >= 0, index < manifest.segments.count, manifest.segments.count <= PagedRootHistoryStore.maximumSegments else {
            throw BoomError.invalid("Public history segment is outside its authenticated manifest.")
          }
          page = manifest.segments[index]
        }
        guard let producer = self.activeCustody else { throw BoomError.denied("Public witness has no actual producing root job.") }
        let original = try store._publicControlCiphertext(identity: identity, page: page, documentID: record.document.id)
        let current = try store._publicControlCurrentRecord(identity: identity, documentID: record.document.id)
        return try PagedSQLPublicCiphertextWitness(identity: identity, producer: producer, record: record,
          currentRecord: current, target: target, page: page, original: original)
      }
    }
  }
  func _publicSQLControlCorruptRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicCiphertextWitness) async throws -> PagedTextCustodiedValue<PagedSQLPublicMutationReceipt> {
    try await rootOutput(claims: [.record(witness.record), .writerDocument(witness.record.document.id)],
      outputClaims: { [.record($0.record), .writerDocument($0.record.document.id)] }) {
      let store = try self.publicSQLControlAdmitWitness(identity, witness: witness)
      guard self.publicSQLWitness == nil, case .prepared = witness.phase else { throw BoomError.stale("A public row mutation is already attempted or owned.") }
      try store.withReadSnapshot { try self.validateNativeRecord(witness.record) }
      let operationID = UUID()
      try self.willWrite(witness.record.document.id)
      self.publicSQLWitness = witness; witness.phase = .corrupting(operationID)
      try self.withSQLWrite(operationID: operationID, expectedRecord: witness.currentRecord) {
        try store._publicControlRequireCurrentRecord(identity: identity, expected: witness.currentRecord, documentID: witness.record.document.id)
        try self.validateNativeRecord(witness.record)
        try store._publicControlReplaceCiphertext(identity: identity, page: witness.page, documentID: witness.record.document.id,
          original: witness.original, replacement: witness.corruptedBytes())
      }
      witness.phase = .corrupted(operationID) // Only after actual successful COMMIT + namespace admission.
      // The existing invalidation command runs after C/SQL work has returned;
      // discarding cached page bytes does not classify or repair durability.
      let _: PagedTextCacheStats = try self.execute(Request(op: "discard_page_cache_after_rollback"))
      return PagedSQLPublicMutationReceipt(operationID: operationID, witness: witness, mutation: .corruption)
    }
  }
  func _publicSQLControlRestoreRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicCiphertextWitness) async throws -> PagedTextCustodiedValue<PagedSQLPublicMutationReceipt> {
    try await rootOutput(claims: [.record(witness.record), .writerDocument(witness.record.document.id)],
      outputClaims: { [.record($0.record), .writerDocument($0.record.document.id)] }) {
      let store = try self.publicSQLControlAdmitWitness(identity, witness: witness)
      guard self.publicSQLWitness === witness, case .corrupted(let corruptionID) = witness.phase else {
        throw BoomError.stale("Restoration requires this exact known-successful corruption, never an uncertain COMMIT.")
      }
      let operationID = UUID()
      try self.willWrite(witness.record.document.id)
      witness.phase = .restoring(operationID)
      try self.withSQLWrite(operationID: operationID, expectedRecord: witness.currentRecord) {
        try store._publicControlRequireCurrentRecord(identity: identity, expected: witness.currentRecord, documentID: witness.record.document.id)
        guard self.rootCustody.hasActualCommittedCandidate(operationID: corruptionID,
          store: store.nativeReceivingIdentity, beforeRecord: witness.currentRecord) else {
          throw BoomError.stale("Restoration lost its actual retained known-success corruption producer.")
        }
        try store._publicControlReplaceCiphertext(identity: identity, page: witness.page, documentID: witness.record.document.id,
          original: witness.corruptedBytes(), replacement: witness.original)
      }
      let _: PagedTextCacheStats = try self.execute(Request(op: "discard_page_cache_after_rollback"))
      witness.phase = .restored(operationID); self.publicSQLWitness = nil
      return PagedSQLPublicMutationReceipt(operationID: operationID, witness: witness, mutation: .restoration)
    }
  }
  func _publicSQLControlHistoryBytesRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicCiphertextWitness) async throws -> PagedTextCustodiedValue<Data> {
    try await rootOutput(claims: [.record(witness.record)], payloadBytes: PagedRootHistoryStore.segmentBytes,
      outputClaims: { _ in [.record(witness.record)] }, outputBytes: { $0.count }) {
      let (store, kind) = try self.publicSQLControlAdmitMetadataWitness(identity, witness: witness)
      return try store.withReadSnapshot {
        try self.validateNativeRecord(witness.record)
        let current = try store._publicControlCiphertext(identity: identity, page: witness.page,
          documentID: witness.record.document.id)
        guard current == witness.original else { throw BoomError.stale("History metadata changed after its actual original witness.") }
        let pages = PagedSQLiteDocumentPages(store: store, ownerID: self.ownerID, documentID: witness.record.document.id)
        return try pages.read(ownerID: self.ownerID, documentID: witness.record.document.id, kind: .index,
          page: witness.page, maximumPlaintextBytes: kind.maximumBytes)
      }
    }
  }
  /// One bounded immutable metadata candidate, never an in-place rewrite or
  /// normal history-writer validation bypass. The actual strict load is used
  /// separately to test malformed candidates; no pointer/receiving state moves.
  func _publicSQLControlAppendHistoryMetadataRetaining(identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicCiphertextWitness, kind: PagedSQLPublicHistoryMetadataKind,
    bytes: Data) async throws -> PagedTextCustodiedValue<PagedSQLPublicHistoryMetadataAppendReceipt> {
    guard !bytes.isEmpty, bytes.count <= kind.maximumBytes else { throw BoomError.budget("Public history metadata exceeds its unchanged page-kind admission.") }
    return try await rootOutput(claims: [.record(witness.record), .writerDocument(witness.record.document.id)],
      payloadBytes: bytes.count, outputClaims: { [.record($0.anchorRecord), .writerDocument($0.anchorRecord.document.id)] }) {
      let (store, admittedKind) = try self.publicSQLControlAdmitMetadataWitness(identity, witness: witness)
      guard admittedKind == kind, witness.historyMetadataAppendOperationID == nil else {
        throw BoomError.stale("History metadata kind differs or this exact witness already owns an append attempt.")
      }
      let operationID = UUID()
      witness.historyMetadataAppendOperationID = operationID // BEFORE any fallible write admission; no retry/reset.
      try self.willWrite(witness.record.document.id)
      return try self.withSQLWrite(operationID: operationID, expectedRecord: witness.currentRecord) {
        try store._publicControlRequireCurrentRecord(identity: identity, expected: witness.currentRecord,
          documentID: witness.record.document.id)
        try self.validateNativeRecord(witness.record)
        let current = try store._publicControlCiphertext(identity: identity, page: witness.page,
          documentID: witness.record.document.id)
        guard current == witness.original else { throw BoomError.stale("Original metadata ciphertext changed before candidate append.") }
        let pages = PagedSQLiteDocumentPages(store: store, ownerID: self.ownerID, documentID: witness.record.document.id)
        let locator = try pages.writeNew(ownerID: self.ownerID, documentID: witness.record.document.id,
          kind: .index, bytes: bytes)
        let page = PagedTextPageRef(locator: locator, digest: Digest.sha256(bytes))
        try page.validate(maximumPlaintextBytes: kind.maximumBytes)
        return PagedSQLPublicHistoryMetadataAppendReceipt(operationID: operationID, witness: witness, kind: kind, page: page)
      }
    }
  }
  private func publicSQLControlAdmitMetadataWitness(_ identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicCiphertextWitness) throws -> (PagedSQLiteStore, PagedSQLPublicHistoryMetadataKind) {
    let store = try publicSQLControlAdmitWitness(identity, witness: witness)
    guard publicSQLWitness == nil, publicSQLPublisherWitness == nil, publicSQLPreparedWitness == nil, case .prepared = witness.phase else {
      throw BoomError.stale("History metadata needs its unmutated actual witness, never a pending corruption/restoration.")
    }
    switch witness.target {
    case .historyManifest: return (store, .manifest)
    case .historySegment: return (store, .segment)
    case .sourceRoot: throw BoomError.denied("Public metadata controls cannot read/append source-root objects.")
    }
  }
  private func publicSQLControlAdmission(_ identity: PagedSQLPublicControlIdentity) throws -> PagedSQLiteStore {
    dispatchPrecondition(condition: .onQueue(queue))
    let store = try router.database(); try store.requireSourceAdmission()
    guard handle != 0, identity.engine === self, identity.vault === router.vault, identity.store === store,
      store.belongs(to: identity.vault), identity.ownerID == ownerID, identity.storeID == store.storeID,
      identity.engineIncarnation == custodyIncarnation else { throw BoomError.denied("Public SQL identity is not this exact live engine/Vault/connection.") }
    return store
  }
  private func publicSQLControlAdmitWitness(_ identity: PagedSQLPublicControlIdentity,
    witness: PagedSQLPublicCiphertextWitness) throws -> PagedSQLiteStore {
    let store = try publicSQLControlAdmission(identity)
    guard witness.identity === identity, witness.record.document.revision.ownerID == ownerID,
      try rootCustody.claims(witness.producer).contains(.record(witness.record)) else {
      throw BoomError.denied("Public ciphertext witness lost its exact original producing custody.")
    }
    try witness.record.validate(); try witness.page.validate(maximumPlaintextBytes: PagedRootHistoryStore.segmentBytes)
    try witness.page.locator.admit(storeID: store.storeID)
    return store
  }
  private func publicSQLControlAdmitHistory(_ history: PagedRootHistory, document: PagedDocumentDescriptor) throws {
    try document.validate(); try admit(document.revision); try history.validate(expected: document.revision)
    // Actual engine openings and exact scalar positions, including every
    // retained root. A structural RootRef or a Boolean validator is insufficient.
    let entries = [(history.current, history.currentCursor)] + (history.undo + history.redo).map { ($0.revision, $0.cursor) }
    for (revision, cursor) in entries {
      let opened: PagedTextRevision = try execute(Request(op: "open", revision: revision))
      let byte: UInt64 = try execute(Request(op: "position", revision: revision, utf16Offset: cursor.utf16Offset))
      guard opened == revision, byte == cursor.byteOffset else { throw BoomError.denied("Public history has another actual root or scalar cursor.") }
    }
    _ = try history.encoded(expected: document.revision)
  }
#endif

  private func withNativeHistory<T>(documentID: UUID, writes: Bool,
    _ work: (PagedRootHistoryStore) throws -> T) throws -> T {
    dispatchPrecondition(condition: .onQueue(queue))
    let sql = try router.database(); try sql.requireSourceAdmission()
    if writes && !sql.hasTransaction {
      return try withSQLWrite(operationID: UUID()) { try self.withNativeHistory(documentID: documentID, writes: true, work) }
    }
    try router.begin(document: documentID, writes: writes,
      beforeWrite: writes ? { try self.willWrite(documentID) } : nil)
    defer { router.end() }
    let pages = try router.provider(owner: ownerID, document: documentID, writing: writes)
    let result = try work(PagedRootHistoryStore(pages: pages))
    try sql.requireSourceAdmission(); return result
  }
  private func validateNativeRecord(_ record: PagedDocumentRootRecord) throws {
    try record.validate(); try admit(record.document.revision)
    let opened: PagedTextRevision = try execute(Request(op: "open", revision: record.document.revision))
    guard opened == record.document.revision else { throw BoomError.invalid("Native history source changed during admission.") }
    let history = try withNativeHistory(documentID: record.document.id, writes: false) { try $0.load(record) }
    // This admits bounded root/index metadata, not entire historical sources.
    // Text-page authentication remains lazy when a captured range is read.
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
    maximumBytes: Int = PagedTextWindow.maximumBytes) async throws -> PagedTextCustodiedValue<PagedTextWindow> {
    guard maximumBytes > 0, maximumBytes <= PagedTextWindow.maximumBytes else { throw BoomError.budget("Invalid native window bound.") }
    return try await rootOutput(claims: [.source(revision)], payloadBytes: maximumBytes,
      outputClaims: { [.source($0.revision)] }, outputBytes: { $0.text.utf8.count }) {
      let window: PagedTextWindow = try self.execute(Request(op: "window", revision: revision, byteStart: byteStart, maximumBytes: maximumBytes))
      try window.validate()
      guard window.revision == revision, window.byteStart == byteStart, window.text.utf8.count <= maximumBytes else {
        throw BoomError.invalid("Paged engine returned a different window capture.")
      }
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
  /// Only an explicit native user command calls this unbounded-range deletion.
  /// Model edits continue to require exact bounded oldText through splice.
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
  func importUTF8Retaining(documentID: UUID, from file: FileHandle,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision> {
    let rootLease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()),
      claims: [.writerDocument(documentID)])
    let bulkLease: UUID
    do { bulkLease = try executor.reserveBulk(cancellation); try rootCustody.start(rootLease) }
    catch { _ = try rootCustody.joinedFailure(rootLease); throw error }
    defer { executor.releaseBulk(bulkLease) }
    do {
      return try await withTaskCancellationHandler {
        let context = try await performStreamIO {
          try PagedTextOperationContext(cancellation: cancellation, file: file, importing: true)
        }
        guard let expectedBytes = context.expectedBytes else { throw BoomError.invalid("Import has no captured file extent.") }
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
              payloadBytes: 0, inFlightWitness: self.inFlightWitness, importedOriginal: result)
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
      if try rootCustody.joinedFailure(rootLease) { throw PagedTextCustodyFailure(original: error, lease: rootLease) }
      throw error
    }
  }
  /// Explicit export to a fresh caller-owned destination. Failure retains its
  /// partial bytes; atomic destination publication belongs to the caller.
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
    catch { _ = try rootCustody.joinedFailure(rootLease); throw error }
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
      if try rootCustody.joinedFailure(rootLease) { throw PagedTextCustodyFailure(original: error, lease: rootLease) }
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
  func byteAtUTF16(_ revision: PagedTextRevision, offset: UInt64) async throws -> UInt64 {
    try await rootRead(claims: [.source(revision)]) { try self.execute(Request(op: "position", revision: revision, utf16Offset: offset)) }
  }
  func stats() async throws -> PagedTextCacheStats {
    try await onQueue { try self.execute(Request(op: "stats")) }
  }
  /// Source-authored scheduling control only. It gates the EXISTING real
  /// executor so a control can observe an admitted root before any Rust read.
  /// Never returns a fabricated source/ack; timeout is fixed and finite.
  /// Ordinary application code has no caller of this seam.
  func _rootCustodyControlBarrier(entered: DispatchSemaphore, release: DispatchSemaphore) async throws {
    try await onQueue {
      entered.signal()
      guard release.wait(timeout: .now() + .seconds(2)) == .success else {
        throw BoomError.unavailable("Public root-custody scheduling control did not release its bounded gate.")
      }
    }
  }

  private func admit(_ publisher: PagedWorkspacePublisher) throws {
    guard publisher.ownerID == ownerID, publisher.belongs(to: router.vault),
      publisher.belongs(to: try router.database()) else {
      throw BoomError.denied("Paged publisher has another private owner or Vault session.")
    }
  }
  private func execute<T: Decodable>(_ request: Request, cancellation: PagedTextCancellation = PagedTextCancellation(),
    writes: Bool = false, context retainedContext: PagedTextOperationContext? = nil) throws -> T {
    dispatchPrecondition(condition: .onQueue(queue))
    let sql = try router.database()
    let cleanup = request.op == "bulk_abort" || request.op == "discard_page_cache_after_rollback"
    if !cleanup { try sql.requireSourceAdmission() }
    if writes && !sql.hasTransaction {
      return try withSQLWrite(operationID: UUID()) {
        try self.executeBody(request, cancellation: cancellation, writes: true, context: retainedContext)
      }
    }
    return try executeBody(request, cancellation: cancellation, writes: writes, context: retainedContext)
  }
  private func executeBody<T: Decodable>(_ request: Request, cancellation: PagedTextCancellation = PagedTextCancellation(),
    writes: Bool = false, context retainedContext: PagedTextOperationContext? = nil) throws -> T {
    dispatchPrecondition(condition: .onQueue(queue))
    guard handle != 0, !sqlClosedForShutdown, router.sqlite?.isSourceAdmitted == true, !Thread.isMainThread else {
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
    if ["import_begin", "hash_begin", "export_begin"].contains(request.op) {
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
    if request.op != "bulk_abort" && request.op != "discard_page_cache_after_rollback" {
      try router.database().requireSourceAdmission()
    }
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
    return value.foregroundRequests + value.backgroundRequests + value.cleanupRequests + value.maintenanceRequests
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
  private func withSQLWrite<T>(operationID: UUID, expectedRecord: PagedDocumentRootRecord? = nil,
    intent: PagedTextRootCustody.SQLIntent = .producer, _ work: () throws -> T) throws -> T {
    dispatchPrecondition(condition: .onQueue(queue))
    if let failure = maintenanceFailure.withLock({ $0 }) { throw failure }
    let store = try router.database()
    guard let activeCustody else { throw BoomError.denied("Actual SQL lacks its pre-yield Root owner.") }
    try rootCustody.beganSQLiteOperation(activeCustody,
      operation: PagedSQLiteOperationIdentity(store: store.nativeReceivingIdentity, operationID: operationID), intent: intent)
    do {
      let result = try store.withTransaction(operationID: operationID, expectedRecord: expectedRecord, work)
      rootCustody.finishedSQLiteExecution(activeCustody, execution: result.execution)
      scheduleWALMaintenanceIfNeeded(); return result.value
    } catch {
      if let failure = error as? PagedSQLiteExecutionFailure {
        // Preserve the actual Store result before cache/bulk cleanup can fail.
        rootCustody.finishedSQLiteExecution(activeCustody, execution: failure.execution, engineJoined: false)
        do {
          let _: PagedTextCacheStats = try execute(Request(op: "discard_page_cache_after_rollback"))
          try rootCustody.joinedSQLiteEngine(activeCustody)
        }
        catch { throw PagedTextCleanupFailure(original: failure.original, cleanup: error) }
        throw failure.original
      }
      throw error
    }
  }
  /// Reserve reachability/output memory BEFORE the first await. Finish inside
  /// the worker, before Executor.finished or continuation.resume. The carrier
  /// conveys already-established ownership, not a request for a later pin.
  private func rootOutput<T: Sendable>(
    purpose: PagedTextRootCustody.Purpose = .operation(UUID()),
    claims: [PagedTextRootClaim], payloadBytes: Int = 0, metadataBytes: Int = 0,
    priority: PagedTextStorageExecutor.Priority = .foreground,
    cancellation: PagedTextCancellation? = nil,
    outputClaims: @escaping @Sendable (T) -> [PagedTextRootClaim],
    outputBytes: @escaping @Sendable (T) -> Int = { _ in 0 },
    preparation: @escaping @Sendable (T) -> PagedNativePreparedHistoryMove? = { _ in nil },
    historyBeforeProof: @escaping @Sendable (T) -> UUID? = { _ in nil },
    nativeAcknowledgement: @escaping @Sendable (T) -> PagedNativeCommitAcknowledgement? = { _ in nil },
    nativeHistoryPublication: @escaping @Sendable (T) -> (PagedNativePreparedHistoryMove, PagedNativeHistoryAcknowledgement)? = { _ in nil },
    sqlOperation: UUID? = nil, sqlExpectedRecord: PagedDocumentRootRecord? = nil,
    sqlIntent: PagedTextRootCustody.SQLIntent = .producer, nativeInput: PagedNativeCommitBatch? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> PagedTextCustodiedValue<T> {
    let lease = try rootCustody.reserve(engine: self, purpose: purpose,
      claims: claims, payloadBytes: payloadBytes, metadataBytes: metadataBytes, nativeInput: nativeInput)
    do {
      return try await onQueue(priority: priority, cancellation: cancellation, custody: lease) {
        try self.rootCustody.start(lease)
        let value: T
        if let sqlOperation {
          value = try self.withSQLWrite(operationID: sqlOperation, expectedRecord: sqlExpectedRecord, intent: sqlIntent) {
            let candidate = try work()
            if let acknowledgement = nativeAcknowledgement(candidate) {
              try self.rootCustody.stageSQLNativeOutput(lease, output: .native(acknowledgement))
            }
            if let history = nativeHistoryPublication(candidate) {
              try self.rootCustody.stageSQLNativeOutput(lease, output: .history(history.1))
            }
            return candidate
          }
        } else { value = try work() }
        // Only after actual COMMIT success. A COMMIT error retains the real
        // candidate/operation/bulk identity through the original failed lease.
        let historyPublication = try nativeHistoryPublication(value).map { item in
          (prepared: item.0, acknowledgement: item.1,
            store: try self.router.database().nativeReceivingIdentity,
            committedOperationID: sqlOperation)
        }
        try self.rootCustody.finishOutput(lease, claims: outputClaims(value), payloadBytes: outputBytes(value),
          inFlightWitness: self.inFlightWitness, preparation: preparation(value),
          historyBeforeProof: historyBeforeProof(value),
          nativeAcknowledgement: nativeAcknowledgement(value), nativeHistoryPublication: historyPublication)
        return PagedTextCustodiedValue(value: value, lease: lease)
      }
    } catch {
      if try rootCustody.joinedFailure(lease) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }
  private func rootRead<T: Sendable>(claims: [PagedTextRootClaim],
    priority: PagedTextStorageExecutor.Priority = .foreground,
    cancellation: PagedTextCancellation? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: claims)
    do {
      return try await onQueue(priority: priority, cancellation: cancellation, custody: lease) {
        try self.rootCustody.start(lease)
        let value = try work()
        try self.rootCustody.finishRead(lease)
        return value
      }
    } catch {
      if try rootCustody.joinedFailure(lease) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }

  // Explicit joined ownership operations. Metadata-only transfers do not do
  // MainActor IO. The serialized head transfer authenticates actual storage.
  func admitRetainedNativeInput(_ lease: PagedTextRootLease, batch: PagedNativeCommitBatch) throws {
    try rootCustody.admitActualNativeInput(lease, batch: batch)
  }
  func adoptUnclaimedRootOutput(_ id: UUID) throws -> PagedTextRootLease { try rootCustody.adoptUnclaimed(id) }
  func abandonJoinedRootOutput(_ lease: PagedTextRootLease) async throws {
    try await onQueue(priority: .cleanup) { try self.rootCustody.abandonJoined(lease) }
  }
  func transferJoinedRootToHead(_ lease: PagedTextRootLease,
    publisher: PagedWorkspacePublisher, expected: PagedDocumentRootRecord) async throws {
    try self.admit(publisher)
    try rootCustody.beginHeadTransfer(lease, record: expected)
    try await onQueue(priority: .cleanup, custody: lease) {
      try self.admit(publisher)
      // The existing lease covers this read/recovery even after close begins.
      // No fresh root job or new authority is created in a closing engine.
      let claims = try self.rootCustody.claims(lease)
      guard claims.contains(.record(expected)) || claims.contains(.source(expected.document.revision)) else {
        throw BoomError.denied("Head transfer has another exact leased source/history record.")
      }
      try publisher.admitCurrentRecord(expected, validateRecord: { try self.validateNativeRecord($0) })
      try self.rootCustody.transferJoinedToHead(lease, record: expected)
    }
  }
  /// An uncertain begin with no returned UUID remains unresolvable here. Never
  /// guess a bulk identity. A known real ID can be aborted and joined explicitly
  /// even after close refuses; its original failure receipt remains with caller.
  func joinRetainedBulkFailure(_ lease: PagedTextRootLease, documentID: UUID) async throws {
    let claims = try rootCustody.claims(lease)
    guard claims.contains(.writerDocument(documentID)) || claims.contains(where: {
      if case .source(let revision) = $0 { return revision.documentID == documentID }; return false
    }) else { throw BoomError.denied("Retained bulk cleanup has another document.") }
    let id = try rootCustody.unresolvedBulk(lease)
    try await onQueue(priority: .cleanup, custody: lease) {
      let joined: Bool = try self.execute(Request(op: "bulk_abort", ownerID: self.ownerID,
        documentID: documentID, operationID: id))
      guard joined else { throw BoomError.unavailable("Retained bulk cleanup did not join its exact producer.") }
      try self.rootCustody.joinedBulk(lease, operationID: id)
      _ = try self.rootCustody.joinedFailure(lease)
    }
  }
  func retainNativeHistoryIntent(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeRetainedHistoryIntent {
    try rootCustody.retainHistory(prepared, engine: self)
  }
  func releaseRetainedHistoryIntent(_ receipt: PagedNativeRetainedHistoryIntent) throws {
    try rootCustody.resolvePrepared(receipt.lease, prepared: receipt.prepared, disposition: .explicitlyAbandoned)
  }
  func resolvePreparedCustody(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) throws {
    try rootCustody.resolvePrepared(lease, prepared: prepared, disposition: disposition)
  }
  func admitPreparedCustody(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws {
    try rootCustody.admitHistoryPublication(lease, prepared: prepared)
  }
  func verifyPreparedCustodyBefore(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws {
    try rootCustody.verifiedHistoryBefore(lease, prepared: prepared)
  }
  func absorbJoinedCustody(_ output: PagedTextRootLease, into receiver: PagedTextRootLease) throws {
    try rootCustody.absorbJoined(output, into: receiver)
  }
  func installNativeCustody(_ output: PagedTextRootLease, controller: PagedTextRootLease,
    expected: PagedDocumentRootRecord, record: PagedDocumentRootRecord) throws {
    try rootCustody.installControllerOutput(output, into: controller, expected: expected, record: record)
  }
  func confirmNativeInputCustody(_ controller: PagedTextRootLease, sessionID: UUID,
    sequence: UInt64, record: PagedDocumentRootRecord, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(priority: .cleanup, custody: controller) {
      try self.admit(publisher)
      if let execution = try self.rootCustody.confirmNativeInput(controller, sessionID: sessionID, sequence: sequence, record: record) {
        try self.finishSQLReceiving(controller, execution: execution)
      }
    }
  }
  func finishNativeCommitCustody(_ controller: PagedTextRootLease,
    acknowledgement: PagedNativeCommitAcknowledgement, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(priority: .cleanup, custody: controller) {
      try self.admit(publisher)
      if let execution = try self.rootCustody.finishNativeCommit(controller, acknowledgement: acknowledgement) {
        try self.finishSQLReceiving(controller, execution: execution)
      }
    }
  }
  func finishNativeHistoryCustody(_ preparedLease: PagedTextRootLease, controller: PagedTextRootLease,
    prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission,
    record: PagedDocumentRootRecord, publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(priority: .cleanup, custody: controller) {
      try self.admit(publisher)
      let store = try self.router.database()
      if let execution = try self.rootCustody.finishHistoryInstallation(preparedLease, controller: controller,
        prepared: prepared, record: record, receiving: (store.nativeReceivingIdentity, admission)) {
        try self.finishSQLReceiving(controller, execution: execution)
      }
    }
  }
  func finishWorkspacePublication(_ output: PagedTextCustodiedValue<PagedWorkspaceSnapshot>,
    publisher: PagedWorkspacePublisher) async throws {
    try await onQueue(priority: .cleanup, custody: output.lease) {
      try self.admit(publisher)
      guard let execution = try self.rootCustody.sqlState(output.lease)?.execution else { throw BoomError.stale("The actual metadata output lost its retained outcome.") }
      try self.router.database().withOutcomeReads(execution) {
        try publisher.admitSnapshot(output.value, validateRecord: { try self.validateNativeRecord($0) })
        try publisher.admitPublishedWorkspacePayload(output.value.head)
      }
      let joinedExecution = try self.rootCustody.finishWorkspaceReceiving(output.lease, snapshot: output.value)
      try self.finishSQLReceiving(output.lease, execution: joinedExecution)
    }
  }
  private func finishSQLReceiving(_ lease: PagedTextRootLease, execution: PagedSQLiteExecution) throws {
    let store = try router.database()
    try store.releaseRefusal(execution)
    try rootCustody.finishSQLReceiving(lease, execution: execution)
    scheduleWALMaintenanceIfNeeded()
  }
  /// One finite actual checkpoint on the SAME existing executor/Root owner.
  /// No per-edit disk COMMIT or persistent consumption/retirement index exists.
  func maintainWAL() async throws -> PagedTextSQLMaintenanceSnapshot {
    if let failure = maintenanceFailure.withLock({ $0 }) { throw failure }
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.workspace])
    do {
      return try await onQueue(priority: .cleanup, custody: lease) {
        try self.rootCustody.start(lease); try self.performWALMaintenance(lease)
        try self.rootCustody.finishOutput(lease, claims: [.workspace], payloadBytes: 0, inFlightWitness: self.inFlightWitness)
        try self.rootCustody.abandonJoined(lease)
        return PagedTextSQLMaintenanceSnapshot(storage: try self.router.database().maintenanceSnapshot(),
          executor: self.executor.snapshot, failure: self.maintenanceFailure.withLock({ $0 }))
      }
    } catch { throw recordWALMaintenanceFailure(error, lease: lease) }
  }
  private func performWALMaintenance(_ lease: PagedTextRootLease) throws {
    let store = try router.database(); try store.requireMaintenanceAdmission()
    let operationID = UUID()
    try rootCustody.beganSQLiteOperation(lease, operation: PagedSQLiteOperationIdentity(store: store.nativeReceivingIdentity, operationID: operationID))
    do { rootCustody.finishedSQLiteExecution(lease, execution: try store.checkpoint(operationID: operationID)) }
    catch {
      if let failure = error as? PagedSQLiteExecutionFailure { rootCustody.finishedSQLiteExecution(lease, execution: failure.execution) }
      throw error
    }
  }
  func nativeSQLMaintenanceSnapshot() async throws -> PagedTextSQLMaintenanceSnapshot {
    try await onQueue(priority: .cleanup) {
      PagedTextSQLMaintenanceSnapshot(storage: try self.router.database().maintenanceSnapshot(),
        executor: self.executor.snapshot, failure: self.maintenanceFailure.withLock({ $0 }))
    }
  }
  func joinScheduledWALMaintenance() async throws -> PagedTextSQLMaintenanceSnapshot {
    try await onQueue(priority: .background) {
      PagedTextSQLMaintenanceSnapshot(storage: try self.router.database().maintenanceSnapshot(),
        executor: self.executor.snapshot, failure: self.maintenanceFailure.withLock({ $0 }))
    }
  }
  private func scheduleWALMaintenanceIfNeeded() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard maintenanceFailure.withLock({ $0 == nil }), !executor.snapshot.closing,
      let store = router.sqlite, store.failedOperationID == nil, store.needsWALMaintenance else { return }
    if executor.snapshot.maintenanceRequests != 0 { executor.prioritizeMaintenance(); return }
    let lease: PagedTextRootLease
    do { lease = try rootCustody.reserve(engine: self, purpose: .operation(UUID()), claims: [.workspace]) } catch { return }
    let admitted = executor.enqueueMaintenance(urgent: true, afterJoin: { self.scheduleWALMaintenanceIfNeeded() }) {
      do {
        guard self.activeCustody == nil else { throw BoomError.invalid("WAL maintenance overlaps actual source work.") }
        self.activeCustody = lease; defer { self.activeCustody = nil }
        try self.rootCustody.start(lease); try self.performWALMaintenance(lease)
        try self.rootCustody.finishOutput(lease, claims: [.workspace], payloadBytes: 0, inFlightWitness: self.inFlightWitness)
        try self.rootCustody.abandonJoined(lease)
      } catch { _ = self.recordWALMaintenanceFailure(error, lease: lease) }
    }
    if !admitted {
      do { _ = try rootCustody.joinedFailure(lease) }
      catch { maintenanceFailure.withLock { first in if first == nil { first = PagedTextCustodyHandoffFailure(original: BoomError.unavailable("WAL queue admission refused."), handoff: error, lease: lease) } } }
    }
  }
  private func recordWALMaintenanceFailure(_ error: Error, lease: PagedTextRootLease) -> Error {
    // RootCustody already synchronizes metadata. No Main IO or second queue
    // admission is needed to preserve a failure after an awaited job returns.
    let failure: Error
    let preserved: Bool
    do {
      preserved = try rootCustody.joinedFailure(lease)
      failure = preserved ? PagedTextCustodyFailure(original: error, lease: lease) : error
    } catch let handoff {
      preserved = true
      failure = PagedTextCustodyHandoffFailure(original: error, handoff: handoff, lease: lease)
    }
    // Queue-cap rejection or preflight failure before mutation is not a new
    // maintenance durability failure. Existing failed source owners stay intact.
    if preserved { maintenanceFailure.withLock { if $0 == nil { $0 = failure } } }
    return failure
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
}

extension PagedTextEngineAdapter {
  /// Caller-owned immutable application input is admitted BEFORE the first
  /// yield. One existing Root entry retains it through staging/COMMIT/receiving.
  func publishWorkspaceMetadataRetaining(_ publisher: PagedWorkspacePublisher,
    input: WorkspaceMetadataInput, expectedHead: PagedWorkspaceHead?,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> PagedTextCustodiedValue<WorkspaceMetadataPublication> {
    let lease = try rootCustody.reserve(engine: self, purpose: .operation(input.inputID),
      claims: [.workspace], payloadBytes: input.outputReservationBytes, metadataBytes: 32_768, metadataInput: input)
    let bulk: UUID
    do { bulk = try executor.reserveBulk(cancellation); try rootCustody.start(lease) }
    catch { _ = try rootCustody.joinedFailure(lease); throw error }
    defer { executor.releaseBulk(bulk) }
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        // Admission touches the actual connection only on its existing queue.
        try await onQueue(priority: .background, cancellation: cancellation, custody: lease) { try self.admit(publisher) }
        let prepared = try await performStreamIO { try publisher.prepareMetadata(input, expectedHead: expectedHead) }
        return try await onQueue(cancellation: cancellation, custody: lease) {
          try self.admit(publisher); try self.rootCustody.admitMetadataDocumentInputs(lease); try self.willPublish()
          let value = try self.withSQLWrite(operationID: input.inputID,
            intent: .metadata(input, prepared, expectedHead: expectedHead)) {
            let result = try publisher.publishMetadata(input, prepared: prepared, expectedHead: expectedHead,
              validateRecord: { try self.validateNativeRecord($0) })
            guard !cancellation.isCancelled else { throw CancellationError() }
            try self.rootCustody.stageSQLNativeOutput(lease, output: .metadata(result)); return result
          }
          try self.rootCustody.finishOutput(lease, claims: [.workspace], payloadBytes: input.outputReservationBytes,
            inFlightWitness: self.inFlightWitness)
          return PagedTextCustodiedValue(value: value, lease: lease)
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      if try rootCustody.joinedFailure(lease) { throw PagedTextCustodyFailure(original: error, lease: lease) }
      throw error
    }
  }
  /// Exact actual normal result; a visible head alone cannot join receiving.
  /// Explicit caller abandonment follows this join, never a dropped callback.
  func finishWorkspaceMetadataPublication(_ output: PagedTextCustodiedValue<WorkspaceMetadataPublication>,
    publisher: PagedWorkspacePublisher) async throws -> PagedWorkspaceHead {
    try await onQueue(priority: .cleanup, custody: output.lease) {
      try self.admit(publisher)
      guard let execution = try self.rootCustody.sqlState(output.lease)?.execution else { throw BoomError.stale("Metadata output lost its real producer execution.") }
      let current = try self.router.database().withOutcomeReads(execution) { try publisher.admitMetadataPublication(output.value, validateRecord: { try self.validateNativeRecord($0) }) }
      let joined = try self.rootCustody.finishMetadataReceiving(output.lease, publication: output.value)
      try self.finishSQLReceiving(output.lease, execution: joined); return current
    }
  }
  func loadWorkspaceDocumentArchiveRetaining(_ publisher: PagedWorkspacePublisher,
    documentID: UUID) async throws -> PagedTextCustodiedValue<WorkspaceDocumentArchiveRead?> {
    try await rootOutput(claims: [.workspace], payloadBytes: 20_480,
      outputClaims: { _ in [.workspace] }, outputBytes: { $0 == nil ? 4_096 : 20_480 }) {
      try self.admit(publisher); return try publisher.documentArchiveRead(documentID)
    }
  }
  func loadWorkspaceSettingsRetaining(_ publisher: PagedWorkspacePublisher) async throws -> PagedTextCustodiedValue<WorkspaceSettingsRead> {
    try await rootOutput(claims: [.workspace], payloadBytes: 20_480,
      outputClaims: { _ in [.workspace] }, outputBytes: { _ in 20_480 }) {
      try self.admit(publisher); return try publisher.settingsRead()
    }
  }
  func loadWorkspaceEntityPageRetaining(_ publisher: PagedWorkspacePublisher, kind: WorkspaceEntityKind,
    parentID: UUID, afterOrdinal: Int = -1, expectedHead: PagedWorkspaceHead? = nil) async throws -> PagedTextCustodiedValue<WorkspaceEntityPage> {
    try await rootOutput(claims: [.workspace], payloadBytes: 118_784,
      outputClaims: { _ in [.workspace] }, outputBytes: { 4_096 + $0.entities.count * WorkspaceEntityHeader.maximumBytes }) {
      try self.admit(publisher)
      return try publisher.entityPage(kind: kind, parentID: parentID, afterOrdinal: afterOrdinal, expectedHead: expectedHead)
    }
  }
  func loadWorkspaceEntityRetaining(_ publisher: PagedWorkspacePublisher,
    reference: WorkspaceEntityReference) async throws -> PagedTextCustodiedValue<WorkspaceEntityRead> {
    try await rootOutput(claims: [.workspace], payloadBytes: 20_480,
      outputClaims: { _ in [.workspace] }, outputBytes: { _ in 20_480 }) {
      try self.admit(publisher); return try publisher.entityRead(reference)
    }
  }
  func loadWorkspaceDocumentRetaining(_ publisher: PagedWorkspacePublisher, documentID: UUID,
    expectedHead: PagedWorkspaceHead) async throws -> PagedTextCustodiedValue<WorkspaceDocumentRead> {
    try await rootOutput(claims: [.workspace], payloadBytes: 20_480,
      outputClaims: { _ in [.workspace] }, outputBytes: { _ in 20_480 }) {
      try self.admit(publisher)
      let value = try publisher.documentRead(documentID, expectedHead: expectedHead)
      try value.record.validate(); try self.admit(value.record.document.revision)
      // Selected native activation still requires actual backend.opening and
      // owned Foundation hydration; this descriptor grants neither.
      return value
    }
  }
  func loadWorkspaceDraftRetaining(_ publisher: PagedWorkspacePublisher,
    owner: ComposerOwner) async throws -> PagedTextCustodiedValue<WorkspaceEntityRead?> {
    try await rootOutput(claims: [.workspace], payloadBytes: 20_480,
      outputClaims: { _ in [.workspace] }, outputBytes: { $0 == nil ? 4_096 : 20_480 }) {
      try self.admit(publisher); return try publisher.draftRead(owner)
    }
  }
  func loadWorkspaceEntityBodyPartRetaining(_ publisher: PagedWorkspacePublisher,
    reference: WorkspaceEntityReference, field: String, part: Int) async throws -> PagedTextCustodiedValue<Data> {
    try await rootOutput(claims: [.workspace], payloadBytes: 65_536,
      outputClaims: { _ in [.workspace] }, outputBytes: { $0.count }) {
      try self.admit(publisher); return try publisher.entityBodyPart(reference, field: field, part: part)
    }
  }
}
