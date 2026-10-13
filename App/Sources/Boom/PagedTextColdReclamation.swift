import BoomCore
import Darwin
import Foundation

/// Cold-only mark/sweep of file_v1 extents. The actual Engine job and workspace
/// flock exclude publishers; no live Model capture is admitted during this pass.
/// Locators never move. Scratch ranges are disposable and contain no source text.
final class PagedTextColdReclamation {
  struct Children: Decodable {
    let children: [PagedTextTreeRef]
    let textPages: [PagedTextPageRef]
  }
  struct Statistics: Sendable {
    var eligibleDocuments = 0
    var skippedDocuments = 0
    var allocatedBefore: UInt64 = 0
    var allocatedAfter: UInt64 = 0
    var punchedBytes: UInt64 = 0
    var expandedIndexNodes: UInt64 = 0
    var duplicateIndexNodes: UInt64 = 0
    var skippedReason: String?
  }
  private struct Extent { let start: UInt64; let end: UInt64 }
  private struct Stamp: Codable, Equatable {
    let device: Int64, inode: UInt64, bytes: Int64
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    init(_ value: stat) {
      device = Int64(value.st_dev); inode = UInt64(value.st_ino); bytes = value.st_size
      modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
      changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
  }
  private struct CandidateCapture: Decodable {
    struct Recipe: Decodable { let capture: BoundedDocumentCapture? }
    let id: UUID
    let recipe: Recipe
  }
  private let store: PagedTextFileStore
  private let cancellation: PagedTextCancellation
  private let children: (PagedTextRevision, PagedTextTreeRef) throws -> Children
  private let scratch: URL
  private var statistics = Statistics()
  private var rangeFile: FileHandle?
  private var pageFile: FileHandle?
  private var visitedFile: FileHandle?
  private var activeDocument: UUID?
  private var pageStamp: Stamp?

  init(store: PagedTextFileStore, cancellation: PagedTextCancellation,
    children: @escaping (PagedTextRevision, PagedTextTreeRef) throws -> Children) {
    self.store = store; self.cancellation = cancellation; self.children = children
    scratch = store.root.appendingPathComponent(".reclaim-" + UUID().uuidString, isDirectory: true)
  }
  func run(state: WorkspaceState) throws -> Statistics {
    try store.requireQueue(); try checkCancellation()
    do { try cleanupAbandonedScratch() }
    catch {
      if error is CancellationError { throw error }
      statistics.skippedReason = error.localizedDescription; return statistics
    }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      try FileManager.default.createDirectory(at: extentDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try discover(state: state)
      if statistics.eligibleDocuments > 0 {
        do {
          // Finish the complete persisted mark set before any destructive entry.
          for file in (state.importedFiles ?? [:]).values {
            if let revision = file.originalRevision { try mark(revision) }
          }
          for proposal in state.proposals { if let capture = proposal.capture { try mark(capture) } }
          try entries(store.root.appendingPathComponent("Objects", isDirectory: true)) { name in
            guard name.hasPrefix("candidate-"), name.hasSuffix(".record") else { return }
            guard let id = UUID(uuidString: String(name.dropFirst(10).dropLast(7))) else {
              throw BoomError.invalid("A saved candidate has no exact file identity.")
            }
            // Decode only its source capture, without candidates/prompts/token arrays.
            // A larger valid record conservatively disables this pass, never deletion.
            guard let data = try store.readMetadata(relativePath: "Objects/" + name, maximumBytes: 1_048_576) else {
              throw BoomError.stale("A saved candidate disappeared during cold marking.")
            }
            let saved = try PropertyListDecoder().decode(CandidateCapture.self, from: data)
            guard saved.id == id else { throw BoomError.invalid("Candidate identity differs from its file.") }
            if let capture = saved.recipe.capture { try mark(capture) }
          }
          try closeActive()
          try entries(scratch) { name in
            guard name.hasSuffix(".stamp"), let id = UUID(uuidString: String(name.dropLast(6))) else { return }
            try checkCancellation(); try sortRanges(id)
            // Recheck every source before ANY document is punched.
            let file = try openPages(id, writing: false); defer { try? file.close() }
            guard try status(file).stamp == loadStamp(id) else {
              throw BoomError.stale("Document pages changed during cold marking.")
            }
          }
        } catch {
          let original = error
          do { try closeActive() }
          catch { throw BoomError.unavailable("\(original.localizedDescription) Scratch close failed: \(error.localizedDescription)") }
          if original is CancellationError { throw original }
          statistics.skippedReason = original.localizedDescription
          statistics.allocatedAfter = statistics.allocatedBefore
          try removeScratch(); return statistics
        }
        try checkCancellation()
        try entries(scratch) { name in
          guard name.hasSuffix(".stamp"), let id = UUID(uuidString: String(name.dropLast(6))) else { return }
          try checkCancellation()
          let file = try openPages(id, writing: true); defer { try? file.close() }
          let before = try status(file)
          guard before.stamp == (try loadStamp(id)) else { throw BoomError.stale("Document changed before hole punching.") }
          let ranges = try FileHandle(forReadingFrom: rangeURL(id)); defer { try? ranges.close() }
          let result = try Self.punchGaps(file: file, ranges: ranges, bytes: UInt64(before.stamp.bytes),
            blockBytes: before.blockBytes, cancellation: cancellation)
          statistics.punchedBytes = try sum(statistics.punchedBytes, result.bytes)
          if !result.supported { statistics.skippedDocuments += 1 }
          if result.bytes > 0 { try file.synchronize() }
          statistics.allocatedAfter = try sum(statistics.allocatedAfter, try status(file).allocated)
        }
      }
      try closeActive(); try removeScratch(); return statistics
    } catch {
      let original = error
      do { try closeActive(); try removeScratch() }
      catch { throw BoomError.unavailable("Cold reclamation failed: \(original.localizedDescription). Scratch cleanup failed: \(error.localizedDescription)") }
      throw original
    }
  }

  private func discover(state: WorkspaceState) throws {
    try entries(store.root.appendingPathComponent("documents", isDirectory: true)) { name in
      guard let id = UUID(uuidString: name) else { statistics.skippedDocuments += 1; return }
      try checkCancellation()
      guard let record = try store.readDocument(id) else { statistics.skippedDocuments += 1; return }
      let file = try openPages(id, writing: false); defer { try? file.close() }
      let info = try status(file)
      let source = max(record.document.revision.summary.bytes, state.importedFiles?[id]?.originalRevision?.summary.bytes ?? 0)
      let growth = source.addingReportingOverflow(source / 2)
      let allowance = growth.partialValue.addingReportingOverflow(4_194_304)
      guard info.apfs, !growth.overflow, !allowance.overflow,
        info.allocated > max(67_108_864, allowance.partialValue) else { statistics.skippedDocuments += 1; return }
      let fd = Darwin.open(stampURL(id).path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw posix() }
      let stamp = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      do { try stamp.write(contentsOf: JSONEncoder().encode(info.stamp)); try stamp.close() }
      catch { try? stamp.close(); throw error }
      guard FileManager.default.createFile(atPath: rangeURL(id).path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw posix() }
      statistics.eligibleDocuments += 1
      statistics.allocatedBefore = try sum(statistics.allocatedBefore, info.allocated)
      try mark(record)
    }
  }
  private func mark(_ capture: BoundedDocumentCapture) throws { try capture.admit(); try mark(capture.record) }
  private func mark(_ record: PagedDocumentRootRecord) throws {
    try record.validate()
    let revision = record.document.revision
    guard try select(revision.documentID) else { return }
    let pages = try store.documentPages(revision.documentID)
    let manifestData = try pages.read(ownerID: store.ownerID, documentID: revision.documentID,
      kind: .index, page: record.historyPage, maximumPlaintextBytes: PagedRootHistoryStore.maximumManifestBytes)
    let manifest = try JSONDecoder().decode(PagedRootHistoryManifest.self, from: manifestData)
    try manifest.validate(expected: record)
    try append(record.historyPage, kind: .index)
    for page in manifest.segments { try append(page, kind: .index) }
    let history = try PagedRootHistoryStore(pages: pages).load(record)
    try mark(history.current)
    for entry in history.undo { try mark(entry.revision) }
    for entry in history.redo { try mark(entry.revision) }
  }
  private func mark(_ revision: PagedTextRevision) throws {
    try revision.validate()
    guard revision.ownerID == store.ownerID else { throw BoomError.denied("A retained root has another owner.") }
    guard try select(revision.documentID), let root = revision.root else { return }
    var stack = [root]
    while let node = stack.popLast() {
      try checkCancellation(); try node.validate()
      let refs = try children(revision, node)
      guard refs.children.count <= 32, refs.textPages.count <= 32,
        (node.height == 0 ? refs.children.isEmpty && !refs.textPages.isEmpty : refs.textPages.isEmpty && !refs.children.isEmpty),
        stack.count + refs.children.count <= 373 else { throw BoomError.invalid("Tree traversal exceeded its bounded shape.") }
      try append(node.page, kind: .index)
      // Authenticate each exact ref/summary above, even if its offset was seen.
      // Only descendants of an already-validated immutable node are skipped.
      if try visited(node.page.locator.offset) { statistics.duplicateIndexNodes += 1; continue }
      statistics.expandedIndexNodes += 1
      for page in refs.textPages { try append(page, kind: .text) }
      stack.append(contentsOf: refs.children)
    }
  }
  private func select(_ id: UUID) throws -> Bool {
    if activeDocument == id { return true }
    try closeActive()
    var exists = stat()
    guard lstat(rangeURL(id).path, &exists) == 0 else {
      if errno == ENOENT { return false }; throw posix()
    }
    activeDocument = id
    rangeFile = try FileHandle(forWritingTo: rangeURL(id)); _ = try rangeFile?.seekToEnd()
    pageFile = try openPages(id, writing: false); pageStamp = try loadStamp(id)
    let fd = Darwin.open(extentDirectory.appendingPathComponent(id.uuidString + ".visited").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw posix() }
    visitedFile = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    return true
  }
  private func append(_ page: PagedTextPageRef, kind: PagedTextPageKind) throws {
    try page.validate(maximumPlaintextBytes: kind.maximumBytes); try page.locator.admit(storeID: store.storeID)
    guard let pageFile, let pageStamp, let rangeFile else { throw BoomError.invalid("Cold range lost its document.") }
    let end = page.locator.offset.addingReportingOverflow(UInt64(PagedTextFileStore.pageHeaderBytes) + UInt64(page.locator.bytes))
    guard !end.overflow, end.partialValue <= UInt64(pageStamp.bytes) else { throw BoomError.invalid("Retained page is outside its append file.") }
    try pageFile.seek(toOffset: page.locator.offset)
    let header = try readExactly(pageFile, count: 12)
    var count: UInt32 = 0
    for i in 0..<4 { count |= UInt32(header[8 + i]) << (8 * i) }
    guard header.prefix(4).elementsEqual([0x42, 0x50, 0x47, 1]), header[4] == kind.rawValue,
      header[5...7].allSatisfy({ $0 == 0 }), count == page.locator.bytes else {
      throw BoomError.invalid("A retained page has invalid framing.")
    }
    try rangeFile.write(contentsOf: Self.encode(Extent(start: page.locator.offset, end: end.partialValue)))
  }
  /// Sparse one-bit-per-byte-offset file: only actual visited index positions
  /// allocate disk blocks. No mmap, source-sized RAM, Set or second node cache.
  private func visited(_ offset: UInt64) throws -> Bool {
    guard let visitedFile, let position = Int64(exactly: offset / 8) else {
      throw BoomError.invalid("Cold visited index lost its bounded address.")
    }
    let mask = UInt8(1) << UInt8(offset % 8)
    var byte: UInt8 = 0
    let read = pread(visitedFile.fileDescriptor, &byte, 1, position)
    guard read == 0 || read == 1 else { throw posix() }
    if byte & mask != 0 { return true }
    byte |= mask
    guard pwrite(visitedFile.fileDescriptor, &byte, 1, position) == 1 else { throw posix() }
    return false
  }
  private func closeActive() throws {
    let range = rangeFile, page = pageFile, visited = visitedFile
    rangeFile = nil; pageFile = nil; visitedFile = nil; activeDocument = nil; pageStamp = nil
    var first: Error?
    do { try range?.close() } catch { first = error }
    do { try page?.close() } catch { if let old = first { first = BoomError.unavailable("\(old.localizedDescription) \(error.localizedDescription)") } else { first = error } }
    do { try visited?.close() } catch { if let old = first { first = BoomError.unavailable("\(old.localizedDescription) \(error.localizedDescription)") } else { first = error } }
    if let first { throw first }
  }
  private func openPages(_ id: UUID, writing: Bool) throws -> FileHandle {
    let directory = store.root.appendingPathComponent("documents/" + id.uuidString.lowercased(), isDirectory: true)
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid() else { throw BoomError.invalid("Cold document directory is not owned ordinary storage.") }
    let fd = Darwin.open(directory.appendingPathComponent("pages").path,
      (writing ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw posix() }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do { _ = try status(file); return file } catch { try? file.close(); throw error }
  }
  private func status(_ file: FileHandle) throws -> (stamp: Stamp, allocated: UInt64, blockBytes: UInt64, apfs: Bool) {
    var value = stat(), fs = statfs()
    guard fstat(file.fileDescriptor, &value) == 0, fstatfs(file.fileDescriptor, &fs) == 0,
      value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
      value.st_size >= 0, value.st_blocks >= 0, fs.f_bsize > 0 else { throw BoomError.invalid("Cold pages are not a valid owned file.") }
    let allocated = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
    guard !allocated.overflow else { throw BoomError.budget("Allocation count overflowed.") }
    let apfs = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) == "apfs" }
    return (Stamp(value), allocated.partialValue, UInt64(fs.f_bsize), apfs)
  }
  /// The held cold/workspace flock excludes a live collector. Only our exact
  /// owner-only scratch shape can be removed; suspicious entries disable GC.
  private func cleanupAbandonedScratch() throws {
    func owned(_ url: URL, directory: Bool) throws {
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
        info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
        directory || info.st_nlink == 1 else { throw BoomError.invalid("Old reclamation scratch is not owned ordinary storage.") }
    }
    func named(_ name: String, suffix: String) -> Bool {
      guard name.hasSuffix(suffix), let id = UUID(uuidString: String(name.dropLast(suffix.count))) else { return false }
      return name == id.uuidString + suffix
    }
    while true {
      // Remove outside readdir, then reopen the directory: deleting an entry
      // must not cause the iterator to miss another crash-left scratch.
      var candidate: String?
      try entries(store.root) { name in
        if candidate == nil, name.hasPrefix(".reclaim-") { candidate = name }
      }
      guard let name = candidate else { return }
      try checkCancellation()
      guard let id = UUID(uuidString: String(name.dropFirst(9))), name == ".reclaim-" + id.uuidString else {
        throw BoomError.invalid("An unknown reclamation entry was retained.")
      }
      let old = store.root.appendingPathComponent(name, isDirectory: true)
      try owned(old, directory: true)
      try entries(old) { child in
        let url = old.appendingPathComponent(child)
        if child == "ranges" {
          try owned(url, directory: true)
          try entries(url) { leaf in
            guard [".ranges", ".visited", ".merge"].contains(where: { named(leaf, suffix: $0) }) else {
              throw BoomError.invalid("Unknown scratch content was retained.")
            }
            try owned(url.appendingPathComponent(leaf), directory: false)
          }
        } else {
          guard named(child, suffix: ".stamp") else { throw BoomError.invalid("Unknown scratch content was retained.") }
          try owned(url, directory: false)
        }
      }
      try checkCancellation(); try FileManager.default.removeItem(at: old)
    }
  }
  private func entries(_ directory: URL, _ visit: (String) throws -> Void) throws {
    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { if errno == ENOENT { return }; throw posix() }
    guard let stream = fdopendir(fd) else { Darwin.close(fd); throw posix() }
    defer { closedir(stream) }
    while true {
      errno = 0
      guard let entry = readdir(stream) else { if errno != 0 { throw posix() }; break }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
      }
      guard let name else { throw BoomError.invalid("Cold storage entry is not UTF-8.") }
      if name != ".", name != ".." { try visit(name) }
    }
  }
  private var extentDirectory: URL { scratch.appendingPathComponent("ranges", isDirectory: true) }
  private func rangeURL(_ id: UUID) -> URL { extentDirectory.appendingPathComponent(id.uuidString + ".ranges") }
  private func stampURL(_ id: UUID) -> URL { scratch.appendingPathComponent(id.uuidString + ".stamp") }
  private func loadStamp(_ id: UUID) throws -> Stamp { try JSONDecoder().decode(Stamp.self, from: Data(contentsOf: stampURL(id))) }
  private func removeScratch() throws { try FileManager.default.removeItem(at: scratch) }
  private func checkCancellation() throws { if cancellation.isCancelled { throw CancellationError() } }
  private func sum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let sum = a.addingReportingOverflow(b); guard !sum.overflow else { throw BoomError.budget("Reclamation count overflowed.") }; return sum.partialValue
  }
  private func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

  // 4096 fixed-size ranges per run, then a two-file bottom-up merge. No Set or
  // file-sized memory map: duplicates/overlaps are merged only by the sweep.
  private func sortRanges(_ id: UUID) throws {
    let a = rangeURL(id), b = extentDirectory.appendingPathComponent(id.uuidString + ".merge")
    let input = try FileHandle(forReadingFrom: a); defer { try? input.close() }
    let bytes = try input.seekToEnd()
    guard bytes % 16 == 0 else { throw BoomError.invalid("Scratch range extent is incomplete.") }
    let count = bytes / 16
    guard FileManager.default.createFile(atPath: b.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw posix() }
    var output = try FileHandle(forWritingTo: b)
    do {
      try input.seek(toOffset: 0)
      var remaining = count
      while remaining > 0 {
        try checkCancellation()
        let n = min(remaining, 4096), data = try readExactly(input, count: Int(n * 16))
        var values: [Extent] = []; values.reserveCapacity(Int(n))
        for index in 0..<Int(n) { values.append(Self.decode(data, index * 16)) }
        values.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var sorted = Data(); sorted.reserveCapacity(data.count)
        for value in values { sorted.append(Self.encode(value)) }
        try output.write(contentsOf: sorted); remaining -= n
      }
      try output.close()
    } catch { try? output.close(); throw error }
    var source = b, target = a, run: UInt64 = 4096
    while run < count {
      output = try FileHandle(forWritingTo: target); try output.truncate(atOffset: 0)
      do {
        var start: UInt64 = 0
        while start < count {
          try checkCancellation()
          let leftCount = min(run, count - start), rightCount = min(run, count - start - leftCount)
          let left = try Reader(source, start: start, count: leftCount)
          let right = try Reader(source, start: start + leftCount, count: rightCount)
          defer { left.close(); right.close() }
          var l = try left.next(), r = try right.next(), buffer = Data()
          buffer.reserveCapacity(65_536)
          while l != nil || r != nil {
            let takeLeft = r == nil || (l != nil && (l!.start < r!.start || (l!.start == r!.start && l!.end <= r!.end)))
            if takeLeft { buffer.append(Self.encode(l!)); l = try left.next() }
            else { buffer.append(Self.encode(r!)); r = try right.next() }
            if buffer.count == 65_536 { try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true); try checkCancellation() }
          }
          if !buffer.isEmpty { try output.write(contentsOf: buffer) }
          start += leftCount + rightCount
        }
        try output.close()
      } catch { try? output.close(); throw error }
      swap(&source, &target); run = run > count / 2 ? count : run * 2
    }
    if source != a { try FileManager.default.removeItem(at: a); try FileManager.default.moveItem(at: source, to: a) }
    if FileManager.default.fileExists(atPath: b.path) { try FileManager.default.removeItem(at: b) }
  }
  private final class Reader {
    let file: FileHandle
    var remaining: UInt64, buffer = Data(), offset = 0
    init(_ url: URL, start: UInt64, count: UInt64) throws {
      file = try FileHandle(forReadingFrom: url); remaining = count
      try file.seek(toOffset: start * 16)
    }
    func next() throws -> Extent? {
      if offset == buffer.count {
        guard remaining > 0 else { return nil }
        let count = min(remaining, 4096)
        buffer = try PagedTextColdReclamation.readExactly(file, count: Int(count * 16)); offset = 0; remaining -= count
      }
      defer { offset += 16 }; return PagedTextColdReclamation.decode(buffer, offset)
    }
    func close() { try? file.close() }
  }
  private static func encode(_ extent: Extent) -> Data {
    var data = Data(); data.reserveCapacity(16)
    for value in [extent.start, extent.end] { for shift in stride(from: 0, through: 56, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    return data
  }
  private static func decode(_ bytes: Data, _ offset: Int) -> Extent {
    var a: UInt64 = 0, b: UInt64 = 0
    for index in 0..<8 { a |= UInt64(bytes[offset + index]) << (index * 8); b |= UInt64(bytes[offset + 8 + index]) << (index * 8) }
    return Extent(start: a, end: b)
  }
  static func punchGaps(file: FileHandle, ranges: FileHandle, bytes: UInt64, blockBytes: UInt64,
    cancellation: PagedTextCancellation,
    punch: (Int32, UInt64, UInt64) throws -> Bool = PagedTextColdReclamation.systemPunch) throws -> (bytes: UInt64, supported: Bool) {
    guard blockBytes > 0 else { throw BoomError.invalid("Hole punching has no filesystem block size.") }
    let end = try ranges.seekToEnd()
    guard end % 16 == 0 else { throw BoomError.invalid("Sorted range stream is incomplete.") }
    try ranges.seek(toOffset: 0)
    var cursor: UInt64 = 0, punched: UInt64 = 0, lastStart: UInt64 = 0
    func gap(_ a: UInt64, _ b: UInt64) throws -> Bool {
      if cancellation.isCancelled { throw CancellationError() }
      let remainder = a % blockBytes, addition = remainder == 0 ? 0 : blockBytes - remainder
      let aligned = a.addingReportingOverflow(addition)
      guard !aligned.overflow else { throw BoomError.budget("Hole address overflowed.") }
      let limit = b - b % blockBytes
      guard limit > aligned.partialValue else { return true }
      guard try punch(file.fileDescriptor, aligned.partialValue, limit - aligned.partialValue) else { return false }
      punched += limit - aligned.partialValue; return true
    }
    var remaining = end
    while remaining > 0 {
      let chunk = try readExactly(ranges, count: Int(min(remaining, 65_536)))
      for offset in stride(from: 0, to: chunk.count, by: 16) {
        let extent = decode(chunk, offset)
        guard extent.start >= lastStart, extent.end > extent.start, extent.end <= bytes else { throw BoomError.invalid("Sorted live extent is invalid.") }
        if extent.start > cursor, try !gap(cursor, extent.start) { return (punched, false) }
        cursor = max(cursor, extent.end); lastStart = extent.start
      }
      remaining -= UInt64(chunk.count)
    }
    if try !gap(cursor, bytes) { return (punched, false) }
    return (punched, true)
  }
  private static func systemPunch(_ fd: Int32, _ offset: UInt64, _ length: UInt64) throws -> Bool {
    guard let start = Int64(exactly: offset), let count = Int64(exactly: length) else { throw BoomError.budget("Hole range exceeds off_t.") }
    var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: start, fp_length: count)
    if fcntl(fd, F_PUNCHHOLE, &hole) == 0 { return true }
    let error = errno
    if error == ENOTSUP || error == EOPNOTSUPP { return false }
    throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
  }
  private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
    var data = Data(); data.reserveCapacity(count)
    while data.count < count {
      guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else { throw BoomError.invalid("Cold file ended before its bounded extent.") }
      data.append(part)
    }
    return data
  }
  private func readExactly(_ file: FileHandle, count: Int) throws -> Data { try Self.readExactly(file, count: count) }
}
