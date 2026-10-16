import BoomCore
import Darwin
import Foundation

/// Plain immutable pages and small atomic roots on the existing storage queue.
/// The workspace host holds its process lock for this store's lifetime.
final class PagedTextFileStore: @unchecked Sendable {
  static let pageHeaderBytes = 12
  let root: URL
  let ownerID: UUID
  let storeID: UUID
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UUID>()
  private let queueIdentity = UUID()
  private var closed = false
  struct Statistics: Sendable {
    let appendedBytes: UInt64
    let appendedPages: UInt64
    let pageReadBytes: UInt64
    let pageReads: UInt64
    let rootPublications: UInt64
  }
  struct FileExtent: Sendable {
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
  }
  func documentExtent(_ documentID: UUID) throws -> FileExtent {
    try requireQueue()
    let file = try openPageFile(documentID, writing: false)
    defer { try? file.close() }
    var status = stat()
    guard fstat(file.fileDescriptor, &status) == 0, status.st_size >= 0, status.st_blocks >= 0 else {
      throw BoomError.invalid("Document append-file extent is unavailable.")
    }
    let allocated = UInt64(status.st_blocks).multipliedReportingOverflow(by: 512)
    guard !allocated.overflow else { throw BoomError.budget("Document allocation counter overflowed.") }
    return FileExtent(logicalBytes: UInt64(status.st_size), allocatedBytes: allocated.partialValue)
  }
  private var appendedBytes: UInt64 = 0
  private var appendedPages: UInt64 = 0
  private var pageReadBytes: UInt64 = 0
  private var pageReads: UInt64 = 0
  private var rootPublications: UInt64 = 0
  func statistics() throws -> Statistics {
    try requireQueue()
    return Statistics(appendedBytes: appendedBytes, appendedPages: appendedPages,
      pageReadBytes: pageReadBytes, pageReads: pageReads, rootPublications: rootPublications)
  }
  private func adding(_ current: UInt64, _ next: UInt64) -> UInt64 {
    let sum = current.addingReportingOverflow(next)
    return sum.overflow ? UInt64.max : sum.partialValue
  }

  init(root: URL, ownerID: UUID, storeID: UUID, queue: DispatchQueue) throws {
    self.root = root; self.ownerID = ownerID; self.storeID = storeID; self.queue = queue
    queue.setSpecific(key: queueKey, value: queueIdentity)
    try requireQueue()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("documents", isDirectory: true),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func requireQueue() throws {
    guard !Thread.isMainThread, DispatchQueue.getSpecific(key: queueKey) == queueIdentity, !closed else {
      throw BoomError.unavailable("Document files belong to their open storage queue.")
    }
  }

  func documentPages(_ documentID: UUID) throws -> PagedFileDocumentPages {
    try requireQueue()
    return PagedFileDocumentPages(store: self, ownerID: ownerID, documentID: documentID)
  }

  func appendPage(documentID: UUID, kind: PagedTextPageKind, bytes: Data) throws -> PagedTextPageLocator {
    try requireQueue()
    guard bytes.count <= kind.maximumBytes else { throw BoomError.budget("Document page exceeds its fixed bound.") }
    let directory = documentDirectory(documentID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = try openPageFile(documentID, writing: true)
    defer { try? file.close() }
    let offset = try file.seekToEnd()
    let end = offset.addingReportingOverflow(UInt64(Self.pageHeaderBytes + bytes.count))
    guard !end.overflow, end.partialValue <= UInt64(Int64.max) else { throw BoomError.budget("Document page address is exhausted.") }
    var header = Data([0x42, 0x50, 0x47, 1, kind.rawValue, 0, 0, 0])
    let count = UInt32(bytes.count)
    for shift in stride(from: 0, through: 24, by: 8) { header.append(UInt8(truncatingIfNeeded: count >> shift)) }
    do { try file.write(contentsOf: header); try file.write(contentsOf: bytes) }
    catch {
      // A failed ordinary write can still extend the append file. Preserve its
      // real extent in diagnostics without pretending that a page completed.
      if let actual = try? file.offset(), actual >= offset { appendedBytes = adding(appendedBytes, actual - offset) }
      throw error
    }
    appendedBytes = adding(appendedBytes, UInt64(Self.pageHeaderBytes + bytes.count))
    appendedPages = adding(appendedPages, 1)
    return PagedTextPageLocator(storeID: storeID, offset: offset, bytes: count)
  }

  func readPage(documentID: UUID, kind: PagedTextPageKind, page: PagedTextPageRef,
    maximumBytes: Int) throws -> Data {
    try requireQueue()
    let bytes = try Self.readImmutablePage(root: root, storeID: storeID, documentID: documentID,
      kind: kind, page: page, maximumBytes: maximumBytes)
    pageReadBytes = adding(pageReadBytes, UInt64(bytes.count)); pageReads = adding(pageReads, 1)
    return bytes
  }

  /// Existing extents are immutable during an open workspace. A read-only
  /// request pins its source in RootCustody; it never reads mutable root files
  /// or touches this store's queue, closed flag, callbacks or counters.
  static func readImmutablePage(root: URL, storeID: UUID, documentID: UUID,
    kind: PagedTextPageKind, page: PagedTextPageRef, maximumBytes: Int) throws -> Data {
    guard !Thread.isMainThread else { throw BoomError.denied("Immutable page IO belongs off Main.") }
    try page.validate(maximumPlaintextBytes: maximumBytes); try page.locator.admit(storeID: storeID)
    guard maximumBytes <= kind.maximumBytes else { throw BoomError.budget("Document page read exceeds its kind.") }
    let file = try openPageFile(root: root, documentID: documentID, writing: false)
    defer { try? file.close() }
    try file.seek(toOffset: page.locator.offset)
    let header = try Self.readExactly(file, count: Self.pageHeaderBytes)
    guard header.prefix(4).elementsEqual([0x42, 0x50, 0x47, 1]), header[4] == kind.rawValue,
      header[5...7].allSatisfy({ $0 == 0 }) else { throw BoomError.invalid("Document page frame changed.") }
    var count: UInt32 = 0
    for index in 0..<4 { count |= UInt32(header[8 + index]) << (index * 8) }
    guard count == page.locator.bytes, Int(count) <= maximumBytes else { throw BoomError.invalid("Document page extent changed.") }
    let bytes = try Self.readExactly(file, count: Int(count))
    guard Digest.sha256(bytes) == page.digest else { throw BoomError.invalid("Document page differs from its immutable reference.") }
    try file.close()
    return bytes
  }

  func readDocument(_ documentID: UUID) throws -> PagedDocumentRootRecord? {
    try requireQueue()
    guard let bytes = try readMetadata(relativePath: documentRootPath(documentID), maximumBytes: 16_384) else { return nil }
    let record = try JSONDecoder().decode(PagedDocumentRootRecord.self, from: bytes)
    try record.validate()
    guard record.document.id == documentID, record.document.revision.ownerID == ownerID,
      record.historyPage.locator.storeID == storeID else { throw BoomError.invalid("Document root has another source identity.") }
    return record
  }

  @discardableResult
  func publishDocument(_ record: PagedDocumentRootRecord, expected: PagedDocumentRootRecord?) throws -> PagedDocumentRootRecord {
    try requireQueue(); try record.validate()
    guard record.document.revision.ownerID == ownerID, record.historyPage.locator.storeID == storeID,
      try readDocument(record.document.id) == expected else { throw BoomError.stale("The complete document and history root changed.") }
    // Appends remain unpublished until the complete root file is replaced.
    let pages = try openPageFile(record.document.id, writing: false)
    do { try pages.synchronize(); try pages.close() } catch { try? pages.close(); throw error }
    let bytes = try JSONEncoder().encode(record)
    guard bytes.count <= 16_384 else { throw BoomError.budget("Document root exceeds its metadata bound.") }
    try writeMetadata(relativePath: documentRootPath(record.document.id), bytes: bytes)
    rootPublications = adding(rootPublications, 1)
    return record
  }

  func readMetadata(relativePath: String, maximumBytes: Int) throws -> Data? {
    try requireQueue()
    guard maximumBytes > 0 else { throw BoomError.invalid("Metadata read has no bound.") }
    let url = try metadataURL(relativePath)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw Self.fileError("open", url)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximumBytes) else {
      throw BoomError.budget("Metadata is not a bounded ordinary file.")
    }
    return try Self.readExactly(file, count: Int(status.st_size))
  }

  /// One standard temporary-file/rename publication; no side journal or receipt.
  func writeMetadata(relativePath: String, bytes: Data) throws {
    try requireQueue()
    let url = try metadataURL(relativePath), parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = parent.appendingPathComponent(".\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Self.fileError("create", temporary) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var published = false
    defer { if !published { try? FileManager.default.removeItem(at: temporary) }; try? file.close() }
    try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
    guard Darwin.rename(temporary.path, url.path) == 0 else { throw Self.fileError("rename", url) }
    published = true
    let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw Self.fileError("open directory", parent) }
    defer { Darwin.close(directory) }
    guard fsync(directory) == 0 else { throw Self.fileError("sync directory", parent) }
  }

  /// Finish a previously reported file-sync failure without replaying an edit.
  func synchronizeDocument(_ expected: PagedDocumentRootRecord) throws {
    try requireQueue()
    guard try readDocument(expected.document.id) == expected else { throw BoomError.stale("The saved document changed before sync.") }
    let pages = try openPageFile(expected.document.id, writing: false)
    do { try pages.synchronize(); try pages.close() } catch { try? pages.close(); throw error }
    let url = try metadataURL(documentRootPath(expected.document.id))
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Self.fileError("open root", url) }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw Self.fileError("sync root", url) }
    let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw Self.fileError("open directory", url) }
    defer { Darwin.close(directory) }
    guard fsync(directory) == 0 else { throw Self.fileError("sync directory", url) }
  }

  func removeMetadata(relativePath: String) throws {
    try requireQueue(); let url = try metadataURL(relativePath)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }

  func close() throws { try requireQueue(); closed = true }
  private func documentDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent("documents", isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }
  private func documentRootPath(_ id: UUID) -> String { "documents/\(id.uuidString.lowercased())/document-root.json" }
  private func metadataURL(_ relative: String) throws -> URL {
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
      throw BoomError.invalid("Metadata path is not workspace-relative.")
    }
    return root.appendingPathComponent(relative)
  }
  private func openPageFile(_ id: UUID, writing: Bool) throws -> FileHandle {
    try Self.openPageFile(root: root, documentID: id, writing: writing)
  }
  private static func openPageFile(root: URL, documentID: UUID, writing: Bool) throws -> FileHandle {
    let url = root.appendingPathComponent("documents", isDirectory: true)
      .appendingPathComponent(documentID.uuidString.lowercased(), isDirectory: true).appendingPathComponent("pages")
    let descriptor = Darwin.open(url.path, (writing ? O_RDWR | O_CREAT : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Self.fileError("open pages", url) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor); throw BoomError.invalid("Document pages are not an ordinary file.")
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }
  private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
    var result = Data(); result.reserveCapacity(count)
    while result.count < count {
      guard let bytes = try file.read(upToCount: count - result.count), !bytes.isEmpty else {
        throw BoomError.invalid("Document file ended before its declared extent.")
      }
      result.append(bytes)
    }
    return result
  }
  private static func fileError(_ operation: String, _ url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) \(url.lastPathComponent)."])
  }
}
