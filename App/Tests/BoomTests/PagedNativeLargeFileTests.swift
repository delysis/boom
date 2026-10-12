import AppKit
import BoomCore
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY. Physical recipe/oracles/memory journal remain literal; real SQL
// receiving/WAL/cold barriers require an exact composed component admission.

private struct PagedGiBControlFailure: Error, CustomStringConvertible, Sendable {
  let description: String
}

/// Public deterministic bytes. Every source/write/hash/read buffer is bounded;
/// no source-sized String, Data, NSArray, mapping or sparse seek is used.
private enum PagedGiBOracle {
  static let bytes: UInt64 = 1_073_741_824
  static let chunkBytes = 65_536
  static let editOffset: UInt64 = bytes / 2 + 64
  static let insertion = Data("EDIT".utf8)
  static let growth: UInt64 = 3

  struct Fixture: Codable, Sendable {
    let bytes: UInt64
    let allocatedBytes: UInt64
    let writeBufferBytes: Int
    let originalSHA256: String
    let editedSHA256: String
  }

  static func byte(at offset: UInt64) -> UInt8 {
    let column = offset % 256
    return column == 255 ? 10 : UInt8(97 + column % 26)
  }

  static func boundedBytes(at start: UInt64, count: Int, edited: Bool) throws -> Data {
    let length = edited ? bytes + growth : bytes
    let end = start.addingReportingOverflow(UInt64(max(0, count)))
    guard count >= 0, count <= PagedWorkingWindow.hardBytes,
      !end.overflow, end.partialValue <= length else {
      throw PagedGiBControlFailure(description: "The public range oracle exceeded its fixed buffer or source extent.")
    }
    var output = Data(count: count)
    output.withUnsafeMutableBytes { raw in
      let target = raw.bindMemory(to: UInt8.self)
      for index in 0..<count {
        let offset = start + UInt64(index)
        if edited, offset >= editOffset, offset < editOffset + UInt64(insertion.count) {
          target[index] = insertion[Int(offset - editOffset)]
        } else {
          let original = edited && offset >= editOffset + UInt64(insertion.count) ? offset - growth : offset
          target[index] = byte(at: original)
        }
      }
    }
    return output
  }

  static func writePhysicalFixture(to url: URL) throws -> Fixture {
    guard !Thread.isMainThread else {
      throw PagedGiBControlFailure(description: "Public fixture creation entered Main.")
    }
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      var chunk = Data(count: chunkBytes)
      chunk.withUnsafeMutableBytes { raw in
        let target = raw.bindMemory(to: UInt8.self)
        for index in 0..<chunkBytes { target[index] = byte(at: UInt64(index)) }
      }
      var originalHash = SHA256(), editedHash = SHA256()
      var offset: UInt64 = 0
      while offset < bytes {
        try Task.checkCancellation()
        // The pattern has period 256 and 65536 is a multiple of 256. All writes
        // are real writes at the current descriptor cursor, never ftruncate.
        try autoreleasepool {
          try file.write(contentsOf: chunk)
          originalHash.update(data: chunk)
          if offset <= editOffset, editOffset < offset + UInt64(chunkBytes) {
            let local = Int(editOffset - offset)
            editedHash.update(data: Data(chunk.prefix(local)))
            editedHash.update(data: insertion)
            editedHash.update(data: Data(chunk.dropFirst(local + 1)))
          } else { editedHash.update(data: chunk) }
        }
        offset += UInt64(chunkBytes)
      }
      try file.synchronize()
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_size == Int64(bytes), info.st_blocks >= 0 else {
        throw PagedGiBControlFailure(description: "The public fixture is not an exact 1 GiB regular file.")
      }
      let allocated = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
      guard !allocated.overflow, allocated.partialValue >= bytes else {
        throw PagedGiBControlFailure(description: "The 1 GiB fixture did not establish nonsparse physical allocation.")
      }
      try file.close()
      return Fixture(bytes: bytes, allocatedBytes: allocated.partialValue, writeBufferBytes: chunkBytes,
        originalSHA256: originalHash.finalize().map { String(format: "%02x", $0) }.joined(),
        editedSHA256: editedHash.finalize().map { String(format: "%02x", $0) }.joined())
    } catch {
      let original = error
      do { try file.close() }
      catch {
        throw PagedGiBControlFailure(description: "Fixture failure: \(original); descriptor close failure: \(error)")
      }
      throw original
    }
  }
}

private struct PagedGiBMemorySample: Codable, Sendable {
  let monotonicNanoseconds: UInt64
  let processID: Int32
  let residentBytes: UInt64
  let footprintBytes: UInt64
  let lifetimePeakResidentBytes: UInt64
  let lifetimePeakFootprintBytes: UInt64

  static func readSelf() throws -> Self {
    var info = task_vm_info_data_t()
    let words = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(words)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS,
      let peakOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
      Int(count) * MemoryLayout<integer_t>.size >= peakOffset + MemoryLayout<Int64>.size,
      info.resident_size > 0, info.phys_footprint > 0, info.ledger_phys_footprint_peak >= 0 else {
      throw PagedGiBControlFailure(description: "Self memory observation was unavailable or returned an incomplete kernel extent (\(result)).")
    }
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
      throw PagedGiBControlFailure(description: "Darwin self peak RSS observation was unavailable.")
    }
    // Darwin ru_maxrss is bytes. These lifetime peaks cannot be reset between
    // phases; sampled interval peaks below are separately named and recorded.
    return Self(monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds, processID: getpid(),
      residentBytes: info.resident_size, footprintBytes: info.phys_footprint,
      lifetimePeakResidentBytes: UInt64(usage.ru_maxrss),
      lifetimePeakFootprintBytes: UInt64(info.ledger_phys_footprint_peak))
  }
}

/// Test diagnostics only. One capped append stream and fixed phase summaries;
/// no source/page cache, key, history or storage publication authority.
private actor PagedGiBMemoryJournal {
  enum Phase: String, Codable, CaseIterable, Sendable {
    case setup, fixtureGeneration, encryptedImport, initialPublication, nativeNavigation
    case nativeEdit, retainedUndo, retainedRedo, firstClose, lazyReopen, reopenIntegrityStream, finalClose, cleanup
  }
  private struct PhaseSummary: Codable, Sendable {
    let phase: Phase
    let baseline: PagedGiBMemorySample
    var last: PagedGiBMemorySample
    var sampledPeakResidentBytes: UInt64
    var sampledPeakFootprintBytes: UInt64
    var sampleCount: UInt64
  }
  private struct SampleLine: Encodable {
    let schema = 1
    let kind = "self-process-memory"
    let phase: Phase
    let sample: PagedGiBMemorySample
  }
  private struct Witness<T: Encodable>: Encodable {
    let schema = 1
    let kind: String
    let phase: Phase
    let value: T
  }
  private struct Terminal: Encodable {
    let schema = 1
    let purpose = "bloom/public-encrypted-1gib-component/v1"
    let outcome: String
    let scratch: String
    let scratchRemoved: Bool
    let fixtureWriterJoined: Bool
    let sourceDescriptorJoined: Bool
    let nativeOwnersJoined: Bool
    let enginesJoined: Bool
    let observerJoined: Bool
    let sampleIntervalNanoseconds: UInt64
    let rawByteLimit: Int
    let rawPrefixBytesWritten: Int
    let droppedSampleLines: UInt64
    let phases: [PhaseSummary]
    let errors: [String]
    let qualificationBoundary = "Encrypted native component only. Sampled peaks are not a hard process ceiling; kernel peaks are process-lifetime values. Integrity streaming is separate from lazy reopen. No installed app, ordinary workspace activation, IME/shortcut or short-file speed acceptance."
  }
  static let sampleInterval: UInt64 = 50_000_000
  private static let rawLimit = 8 * 1_048_576
  private static let terminalReserve = 65_536
  private static let maximumWitnesses = 32
  private static let witnessBytes = 16_384
  private static let witnessReserve = maximumWitnesses * (witnessBytes + 1)
  private let directory: URL
  private let file: FileHandle
  private var phase = Phase.setup
  private var summaries: [Phase: PhaseSummary] = [:]
  private var bytesWritten = 0
  private var dropped: UInt64 = 0
  private var samplesSinceSync = 0
  private var witnessCount = 0
  private var closed = false

  init(directory: URL) throws {
    guard !Thread.isMainThread else {
      throw PagedGiBControlFailure(description: "The diagnostics stream opened on Main.")
    }
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let path = directory.appendingPathComponent("memory-samples.jsonl")
    let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }
  func mark(_ next: Phase) throws {
    guard !closed, next == phase || summaries[next] == nil else {
      throw PagedGiBControlFailure(description: "The fixed memory phase owner was reused or closed.")
    }
    if next != phase { try sample(); phase = next }
    try sample()
    try file.synchronize()
  }
  func sample() throws {
    guard !closed else { throw PagedGiBControlFailure(description: "Memory observation resumed after its join.") }
    let observed = try PagedGiBMemorySample.readSelf()
    if var summary = summaries[phase] {
      summary.last = observed
      summary.sampledPeakResidentBytes = max(summary.sampledPeakResidentBytes, observed.residentBytes)
      summary.sampledPeakFootprintBytes = max(summary.sampledPeakFootprintBytes, observed.footprintBytes)
      summary.sampleCount += 1
      summaries[phase] = summary
    } else {
      summaries[phase] = PhaseSummary(phase: phase, baseline: observed, last: observed,
        sampledPeakResidentBytes: observed.residentBytes, sampledPeakFootprintBytes: observed.footprintBytes, sampleCount: 1)
    }
    let bytes = try JSONEncoder().encode(SampleLine(phase: phase, sample: observed))
    guard bytes.count <= 2_048 else { throw PagedGiBControlFailure(description: "Memory sample exceeded its numeric record bound.") }
    if bytesWritten + bytes.count + 1 <= Self.rawLimit - Self.terminalReserve - Self.witnessReserve {
      try append(bytes)
      samplesSinceSync += 1
      if samplesSinceSync >= 32 { try file.synchronize(); samplesSinceSync = 0 }
    } else { dropped += 1 }
  }
  func witness<T: Encodable & Sendable>(_ kind: String, _ value: T) throws {
    guard !closed, witnessCount < Self.maximumWitnesses, kind.utf8.count <= 64 else {
      throw PagedGiBControlFailure(description: "The bounded source-witness stream is closed or full.")
    }
    let bytes = try JSONEncoder().encode(Witness(kind: kind, phase: phase, value: value))
    guard bytes.count <= Self.witnessBytes, bytesWritten + bytes.count + 1 <= Self.rawLimit - Self.terminalReserve else {
      throw PagedGiBControlFailure(description: "The source witness exceeded its explicit diagnostics extent.")
    }
    witnessCount += 1
    try append(bytes)
    try file.synchronize()
  }
  func finish(outcome: String, scratch: URL, scratchRemoved: Bool, fixtureJoined: Bool, sourceJoined: Bool,
    nativeJoined: Bool, enginesJoined: Bool, observerJoined: Bool, errors: [String]) throws -> Data {
    guard !closed else { throw PagedGiBControlFailure(description: "The terminal diagnostics owner was already joined.") }
    let summary = Terminal(outcome: outcome, scratch: scratch.path, scratchRemoved: scratchRemoved,
      fixtureWriterJoined: fixtureJoined, sourceDescriptorJoined: sourceJoined, nativeOwnersJoined: nativeJoined,
      enginesJoined: enginesJoined, observerJoined: observerJoined,
      sampleIntervalNanoseconds: Self.sampleInterval, rawByteLimit: Self.rawLimit,
      rawPrefixBytesWritten: bytesWritten, droppedSampleLines: dropped,
      phases: Phase.allCases.compactMap { summaries[$0] },
      errors: Array(errors.prefix(8)).map { String($0.prefix(4_096)) })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(summary)
    guard bytes.count < Self.terminalReserve else {
      throw PagedGiBControlFailure(description: "The fixed terminal summary exceeded its reserved extent.")
    }
    do {
      // The separate readable summary is pretty-printed. The append stream
      // remains JSONL through its last terminal record.
      let terminalLine = try JSONEncoder().encode(summary)
      guard terminalLine.count < Self.terminalReserve else {
        throw PagedGiBControlFailure(description: "The compact terminal line exceeded its reserved extent.")
      }
      try append(terminalLine)
      try file.synchronize()
      try file.close()
      closed = true
      try bytes.write(to: directory.appendingPathComponent("memory-summary.json"), options: .withoutOverwriting)
      return bytes
    } catch {
      let original = error
      do { try file.close() } catch {
        closed = true
        throw PagedGiBControlFailure(description: "Terminal diagnostics failure: \(original); close failure: \(error)")
      }
      closed = true
      throw original
    }
  }
  private func append(_ bytes: Data) throws {
    try file.write(contentsOf: bytes)
    try file.write(contentsOf: Data([10]))
    bytesWritten += bytes.count + 1
  }
}

/// At most sixteen real read/output capabilities in one actual Engine lifetime.
/// This test owner supplies no queue, storage writer, key, ACK or repair proof.
@MainActor private final class PagedGiBSQLReceivingOwner {
  let engine: PagedTextEngineAdapter
  let identity: PagedSQLPublicControlIdentity
  private var reads: [PagedTextRootLease] = []
  private let maintenance: PagedSQLNativeFixtureMaintenance
  init(engine: PagedTextEngineAdapter, identity: PagedSQLPublicControlIdentity) {
    self.engine = engine; self.identity = identity; maintenance = PagedSQLNativeFixtureMaintenance(engine: engine)
  }
  private func admitRead() throws {
    guard reads.count < 16 else { throw PagedGiBControlFailure(description: "Public GiB SQL output lifetime exceeds sixteen bounded readers.") }
  }
  func snapshot(_ publisher: PagedWorkspacePublisher) async throws -> PagedWorkspaceSnapshot {
    try admitRead()
    let output = try await engine.loadWorkspaceRetaining(publisher)
    reads.append(output.lease); return output.value
  }
  func history(_ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    try admitRead()
    let output = try await engine._publicSQLControlHistoryRetaining(identity: identity, record: record)
    reads.append(output.lease); return output.value
  }
  func workspace(_ publisher: PagedWorkspacePublisher) async throws -> WorkspaceState {
    try admitRead()
    let output = try await engine.loadWorkspaceCatalogRetaining(publisher)
    reads.append(output.lease); return output.value.state
  }
  func closeAfterActualNativeJoin(_ backend: PagedNativeStorageBackend,
    session: PagedNativeSession, registeredSessionID: UUID?, record: PagedDocumentRootRecord) async throws {
    _ = try session.windowForNativeInstallation()
    try await backend.detachJoinedController(sessionID: registeredSessionID,
      sequence: session.generation, record: record)
    for read in reads { try await engine.abandonJoinedRootOutput(read) }
    reads.removeAll()
    try await maintenance.drainAfterJoinedNativeCalls()
    try await engine.close()
  }
}

/// One failed isolated case retains the actual Engine/session/view/descriptor
/// and all receiving capabilities until its owning test process actually exits.
/// Reference retention is not a successful source or physical callback join.
@MainActor private final class PagedGiBRetainedFailureOwner {
  let scratch: URL
  let engine: PagedTextEngineAdapter?
  let session: PagedNativeSession?
  let view: PagedNativeTextView?
  let receiver: PagedGiBSQLReceivingOwner?
  let source: FileHandle?
  let failure: Error
  init(scratch: URL, engine: PagedTextEngineAdapter?, session: PagedNativeSession?,
    view: PagedNativeTextView?, receiver: PagedGiBSQLReceivingOwner?, source: FileHandle?, failure: Error) {
    self.scratch = scratch; self.engine = engine; self.session = session; self.view = view
    self.receiver = receiver; self.source = source; self.failure = failure
  }
}

/// One deliberately expensive, separately dispatched 1 GiB component control.
/// Authored source only until a worker qualifies the exact composed candidate.
@MainActor final class PagedNativeLargeFileTests: XCTestCase {
  private static var retainedFailure: PagedGiBRetainedFailureOwner?
  private struct RootWitness: Encodable, Sendable {
    let head: PagedWorkspaceHead
    let record: PagedDocumentRootRecord
    let nativeGeneration: UInt64
  }
  private struct CacheWitness: Encodable, Sendable {
    let chargedBytes: Int
    let entries: Int
    let pageReads: UInt64
    let readBytes: UInt64
    let pageWrites: UInt64
    init(_ stats: PagedTextCacheStats) {
      chargedBytes = stats.chargedBytes; entries = stats.entries
      pageReads = stats.pageReads; readBytes = stats.readBytes; pageWrites = stats.pageWrites
    }
  }
  private func require(_ admitted: Bool, _ explanation: String) throws {
    guard admitted else { throw PagedGiBControlFailure(description: explanation) }
  }
  private func verify(_ window: PagedTextWindow, edited: Bool,
    view: PagedNativeTextView? = nil) throws {
    try window.validate()
    let expected = try PagedGiBOracle.boundedBytes(at: window.byteStart,
      count: window.text.utf8.count, edited: edited)
    try require(Data(window.text.utf8) == expected, "A bounded native range differs from its exact public source oracle.")
    try require(window.text.utf8.count <= PagedWorkingWindow.targetBytes,
      "A sealed native projection exceeded 16 KiB.")
    try require(window.utf16Start == window.byteStart,
      "The public ASCII fixture acquired an inconsistent UTF16 origin.")
    if let view {
      try require(Data(view.boundedStorage.string.utf8) == expected,
        "Actual TextKit storage differs from its bounded source installation.")
      if let failure = view.boundedStorage.mutationFailure { throw failure }
      if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
    }
  }
  func testOneGiBEncryptedNativeImportEditRetainedUndoAndLazyReopen() async throws {
    guard ProcessInfo.processInfo.environment["BOOM_RUN_PUBLIC_1GIB_CONTROL"] == "1" else {
      throw BoomError.denied("The physical 1 GiB control requires its explicitly owned isolated dispatch; no fixture entered.")
    }
    guard Self.retainedFailure == nil else { throw BoomError.denied("A failed actual GiB owner still owns this process.") }
    _ = NSApplication.shared
    let run = UUID(), owner = UUID(), documentID = UUID(), storeID = UUID()
    let temporary = FileManager.default.temporaryDirectory
    let scratch = temporary.appendingPathComponent("public-paged-1gib-" + run.uuidString)
    let diagnostics = temporary.appendingPathComponent("public-paged-1gib-evidence-" + run.uuidString)
    let source = scratch.appendingPathComponent("physical-public-source.utf8")
    let vaultRoot = scratch.appendingPathComponent("encrypted-workspace")
    // Deliberately public fixed test key. No Keychain/session authorization.
    let key = SymmetricKey(data: Data(repeating: 0xA7, count: 32))
    let memory = try await Task.detached {
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      return try PagedGiBMemoryJournal(directory: diagnostics)
    }.value
    let observer = Task.detached(priority: .utility) {
      while !Task.isCancelled {
        try await memory.sample()
        do { try await Task.sleep(nanoseconds: PagedGiBMemoryJournal.sampleInterval) }
        catch { if Task.isCancelled { return }; throw error }
      }
    }
    var engine: PagedTextEngineAdapter?
    var session: PagedNativeSession?
    var view: PagedNativeTextView?
    var sourceHandle: FileHandle?
    var sourceCloseAttempted = false
    var receiver: PagedGiBSQLReceivingOwner?
    var pendingHistoryID: UUID?
    var bodyFailure: Error?
    var errors: [String] = []
    var fixtureJoined = false, sourceJoined = true, nativeJoined = true, enginesJoined = true, observerJoined = false
    var scratchRemoved = false
    do {
      try await memory.mark(.fixtureGeneration)
      let fixtureTask = Task.detached { try PagedGiBOracle.writePhysicalFixture(to: source) }
      let fixture: PagedGiBOracle.Fixture
      do {
        // A thrown task result is still an actual join; preserve that fact
        // separately from its successful fixture allocation/result.
        defer { fixtureJoined = true }
        fixture = try await withTaskCancellationHandler {
          try await fixtureTask.value
        } onCancel: { fixtureTask.cancel() }
      }
      try await memory.witness("physical-fixture-and-independent-stream-oracles", fixture)
      try await memory.mark(.encryptedImport)
      let vault = try await Task.detached { try Vault(root: vaultRoot, testKey: key) }.value
      let firstEngine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: .fresh(storeID: storeID))
      engine = firstEngine; enginesJoined = false
      let firstIdentity = try await firstEngine._publicSQLControlIdentity(expectedVault: vault, expectedStoreID: storeID)
      let firstReceiver = PagedGiBSQLReceivingOwner(engine: firstEngine, identity: firstIdentity)
      receiver = firstReceiver
      let publisher = try await firstEngine.makeWorkspacePublisher()
      let file = try await Task.detached { try FileHandle(forReadingFrom: source) }.value
      sourceHandle = file; sourceJoined = false
      let importedOutput = try await firstEngine.importUTF8Retaining(documentID: documentID, from: file)
      let imported = importedOutput.value
      sourceCloseAttempted = true
      try await Task.detached { try file.close() }.value
      sourceHandle = nil; sourceJoined = true
      try require(imported.revision.summary.bytes == PagedGiBOracle.bytes
        && imported.revision.summary.utf16 == PagedGiBOracle.bytes
        && imported.revision.summary.lfCount == PagedGiBOracle.bytes / 256,
        "The complete encrypted import lost its exact source extent or summaries.")
      try require(imported.wholeTextSha256 == fixture.originalSHA256,
        "The actual imported 1 GiB differs from the independently streamed physical fixture.")
      try await memory.witness("sealed-import-revision", imported.revision)

      try await memory.mark(.initialPublication)
      let recordOutput = try await firstEngine.initialNativeRecordRetaining(PagedDocumentDescriptor(id: documentID,
        title: "Public 1 GiB", revision: imported.revision))
      let record = recordOutput.value
      var state = WorkspaceState()
      state.documents = [DocumentIndex(id: documentID, title: record.document.title)]
      state.selectedDocument = documentID; state.writingExampleIDs = [documentID]
      state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .document, id: documentID),
        text: "public retained unsent input", attachments: [], authoredRole: nil)]
      let initialOutput = try await firstEngine.initializeWorkspaceRetaining(publisher, state: state, documents: [record])
      try await firstEngine.finishWorkspacePublication(initialOutput, publisher: publisher)
      let initial = initialOutput.value
      try await firstEngine.transferJoinedRootToHead(importedOutput.lease, publisher: publisher, expected: record)
      try await firstEngine.transferJoinedRootToHead(recordOutput.lease, publisher: publisher, expected: record)
      try await firstEngine.abandonJoinedRootOutput(initialOutput.lease)
      let backend = try await firstEngine.makeNativeStorage(publisher, expected: record)
      let firstWindow = try await backend.window(expected: imported.revision,
        utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
      let firstSession = try PagedNativeSession(window: firstWindow, rootRecord: record, storage: backend)
      session = firstSession; nativeJoined = false
      view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), session: firstSession)
      try verify(firstWindow, edited: false, view: view)
      try await memory.witness("initial-coherent-head", RootWitness(head: initial.head, record: record, nativeGeneration: 0))

      try await memory.mark(.nativeNavigation)
      let middle = PagedGiBOracle.bytes / 2
      let tail = PagedGiBOracle.bytes - UInt64(PagedWorkingWindow.targetBytes)
      for anchor in [UInt64(0), middle, tail] {
        let window = try await firstSession.navigate(toUTF16: anchor)
        try require(window.byteStart == anchor, "Native navigation changed an exact large-file anchor.")
        view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), session: firstSession)
        try verify(window, edited: false, view: view)
      }
      let middleWindow = try await firstSession.navigate(toUTF16: middle)
      view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), session: firstSession)
      try verify(middleWindow, edited: false, view: view)

      try await memory.mark(.nativeEdit)
      let editingView = try XCTUnwrap(view)
      editingView.insertText("EDIT", replacementRange: NSRange(location: 64, length: 1))
      if let failure = editingView.boundedStorage.mutationFailure { throw failure }
      if let failure = firstSession.persistenceFailure { throw failure }
      try require(firstSession.generation == 1, "The actual native accepted primitive did not advance exactly one sequence.")
      let editedRevision = try await firstSession.flush(through: firstSession.generation)
      try require(editedRevision != imported.revision,
        "The real native edit returned the old source root.")
      try require(editedRevision.summary.bytes == PagedGiBOracle.bytes + PagedGiBOracle.growth
        && editedRevision.summary.utf16 == PagedGiBOracle.bytes + PagedGiBOracle.growth,
        "The native edit did not preserve the 1 GiB source's exact changed extent.")
      // A grown working island can be 24 KiB. Recenter before checking the sealed
      // 16 KiB projection; stale prior text storage is never reused for a new arena.
      let editReadback = try await firstSession.navigate(toUTF16: middle)
      view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), session: firstSession)
      try verify(editReadback, edited: true, view: view)
      let editedSnapshot = try await firstReceiver.snapshot(publisher)
      let editedRecord = try XCTUnwrap(editedSnapshot.documents.first)
      try require(editedRecord.document.revision == editedRevision && editedRecord.historyGeneration == 1,
        "The coherent head did not publish the exact native source/history record.")
      try require(editedSnapshot.head.workspace == initial.head.workspace,
        "A native character commit re-encoded or replaced unrelated workspace metadata.")
      let editedHistory = try await firstReceiver.history(editedRecord)
      let group = try XCTUnwrap(editedHistory.undo.last)
      try require(editedHistory.current == editedRevision && group.revision == imported.revision,
        "Actual encrypted retained history lost the pre-edit 1 GiB root.")
      try await memory.witness("native-edit-coherent-head", RootWitness(head: editedSnapshot.head,
        record: editedRecord, nativeGeneration: firstSession.generation))

      try await memory.mark(.retainedUndo)
      let handle = PagedNativeHistoryHandle(documentID: documentID, groupID: group.groupID, direction: .undo)
      let undoPrefix = try firstSession.reservePrefix()
      let undoPrepared = try await firstSession.prepareHistoryMove(handle, prefix: undoPrefix)
      pendingHistoryID = undoPrepared.command.commandID
      try XCTUnwrap(view).installPreparedHistory(undoPrepared)
      let undo = try await firstSession.joinHistoryPublication(commandID: undoPrepared.command.commandID)
      pendingHistoryID = nil
      try require(undo.sealedRootRecord.document.revision == imported.revision
        && undo.sealedRootRecord.historyGeneration == 2 && firstSession.generation == 2,
        "Native retained-root Undo changed source identity or ordered history epoch.")
      try verify(undo.sealedWindow, edited: false, view: view)

      try await memory.mark(.retainedRedo)
      let redoPrefix = try firstSession.reservePrefix()
      let redoPrepared = try await firstSession.prepareHistoryMove(handle.inverse, prefix: redoPrefix)
      pendingHistoryID = redoPrepared.command.commandID
      try XCTUnwrap(view).installPreparedHistory(redoPrepared)
      let redo = try await firstSession.joinHistoryPublication(commandID: redoPrepared.command.commandID)
      pendingHistoryID = nil
      try require(redo.sealedRootRecord.document.revision == editedRevision
        && redo.sealedRootRecord.historyGeneration == 3 && firstSession.generation == 3,
        "Native retained-root Redo failed exact source/sequence/history admission.")
      try verify(redo.sealedWindow, edited: true, view: view)
      let saved = try await firstReceiver.snapshot(publisher)
      let savedRecord = try XCTUnwrap(saved.documents.first)
      try require(savedRecord == redo.sealedRootRecord, "The durable head differs from the actual Redo acknowledgement.")
      try require(!firstSession.hasPendingHistoryCommand && !firstSession.isProvisionalHistory,
        "The native history installation did not finish its owner.")
      _ = try await firstSession.flush(through: firstSession.generation)
      nativeJoined = true
      try await memory.witness("final-first-incarnation-head", RootWitness(head: saved.head,
        record: savedRecord, nativeGeneration: firstSession.generation))
      let firstStats = try await firstEngine.stats()
      try require(firstStats.chargedBytes <= 8 * 1_048_576 && firstStats.entries <= 512,
        "Encrypted large-file editing exceeded the engine's fixed cache bound.")
      try await memory.witness("first-incarnation-cache", CacheWitness(firstStats))

      try await memory.mark(.firstClose)
      try await firstReceiver.closeAfterActualNativeJoin(backend, session: firstSession,
        registeredSessionID: firstSession.sessionID, record: savedRecord)
      view = nil; session = nil; receiver = nil
      engine = nil; enginesJoined = true

      try await memory.mark(.lazyReopen)
      let reopenedVault = try await Task.detached { try Vault(root: vaultRoot, testKey: key) }.value
      let secondEngine = try await PagedTextEngineAdapter.create(vault: reopenedVault, ownerID: owner, sqliteOpening: .existing(storeID: storeID))
      engine = secondEngine; enginesJoined = false
      let secondIdentity = try await secondEngine._publicSQLControlIdentity(expectedVault: reopenedVault, expectedStoreID: storeID)
      let secondReceiver = PagedGiBSQLReceivingOwner(engine: secondEngine, identity: secondIdentity)
      receiver = secondReceiver
      let cold = try await secondEngine.stats()
      try require(cold.pageReads == 0 && cold.readBytes == 0 && cold.chargedBytes == 0,
        "The reopened engine was not a new cold source cache.")
      let reopenedPublisher = try await secondEngine.makeWorkspacePublisher()
      let reopened = try await secondReceiver.snapshot(reopenedPublisher)
      try require(reopened == saved, "Close/reopen changed the exact authenticated head, source or retained history record.")
      let restoredState = try await secondReceiver.workspace(reopenedPublisher)
      try require(restoredState.writingExampleIDs == [documentID]
        && restoredState.composerDrafts?.first?.text == "public retained unsent input",
        "Lazy reopen lost retained input or the ordered writing-example selection.")
      let restoredHistory = try await secondReceiver.history(savedRecord)
      try require(restoredHistory.current == editedRevision && restoredHistory.generation == 3
        && restoredHistory.undo.last?.revision == imported.revision && restoredHistory.redo.isEmpty,
        "Reopened encrypted history lost its exact retained pre-edit source.")
      let reopenedBackend = try await secondEngine.makeNativeStorage(reopenedPublisher, expected: savedRecord)
      let reopenedWindow = try await reopenedBackend.window(expected: editedRevision,
        utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
      let secondSession = try PagedNativeSession(window: reopenedWindow, rootRecord: savedRecord, storage: reopenedBackend)
      session = secondSession; nativeJoined = false
      let editedTail = editedRevision.summary.utf16 - UInt64(PagedWorkingWindow.targetBytes)
      for anchor in [UInt64(0), middle, editedTail] {
        let window = try await secondSession.navigate(toUTF16: anchor)
        view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), session: secondSession)
        try verify(window, edited: true, view: view)
      }
      let lazy = try await secondEngine.stats()
      try require(lazy.readBytes <= 4 * 1_048_576 && lazy.pageReads <= 128,
        "Lazy reopen/navigation traversed source beyond the explicitly bounded read-amplification envelope.")
      try require(lazy.chargedBytes <= 8 * 1_048_576 && lazy.entries <= 512,
        "Lazy reopen exceeded the fixed encrypted source cache.")
      try await memory.witness("cold-reopen-coherent-head", RootWitness(head: reopened.head,
        record: savedRecord, nativeGeneration: secondSession.generation))
      try await memory.witness("lazy-reopen-before-integrity-stream", CacheWitness(lazy))

      // Deliberately separate from both edit and lazy reopen: complete source
      // integrity is checked with the actual 64 KiB stepped encrypted stream.
      try await memory.mark(.reopenIntegrityStream)
      let fullDigest = try await secondEngine.wholeTextSha256(editedRevision)
      try require(fullDigest == fixture.editedSHA256,
        "The complete reopened encrypted source differs from the independently streamed edit oracle.")
      let afterIntegrity = try await secondReceiver.snapshot(reopenedPublisher)
      try require(afterIntegrity == saved, "Read-only integrity streaming changed the coherent source/head.")
      _ = try await secondSession.flush(through: secondSession.generation)
      try require(!secondSession.hasPendingHistoryCommand, "Reopened native owner retained an unresolved command.")
      nativeJoined = true
      try await memory.witness("reopened-source-integrity-sha256", fullDigest)

      try await memory.mark(.finalClose)
      // Read-only primitive navigation never binds this Backend's native session;
      // the actual registered sequence remains zero in this fresh incarnation.
      try await secondReceiver.closeAfterActualNativeJoin(reopenedBackend, session: secondSession,
        registeredSessionID: nil, record: savedRecord)
      view = nil; session = nil; receiver = nil
      engine = nil; enginesJoined = true
    } catch {
      bodyFailure = error; errors.append("Control failure: \(error)")
    }

    // Join existing work; never fabricate recovery, retry a publication or
    // delete a scratch tree that still has an unresolved owner/intent.
    if let file = sourceHandle, !sourceCloseAttempted {
      sourceCloseAttempted = true
      do { try await Task.detached { try file.close() }.value; sourceJoined = true; sourceHandle = nil }
      catch { errors.append("Source descriptor close: \(error)"); if bodyFailure == nil { bodyFailure = error } }
    }
    if let retained = session {
      if let pendingHistoryID {
        do { _ = try await retained.joinHistoryPublication(commandID: pendingHistoryID) }
        catch { errors.append("Retained history join: \(error)"); if bodyFailure == nil { bodyFailure = error } }
      }
      // Do not call flush on a failed dirty owner: it may begin a new source
      // publication. Its exact accepted input and entered producer remain held;
      // false nativeJoined is preserved unless the normal body actually joined.
      if !nativeJoined { errors.append("Native input/producer remains retained; no cleanup publication retry.") }
    }
    if let failure = bodyFailure {
      Self.retainedFailure = PagedGiBRetainedFailureOwner(scratch: scratch, engine: engine,
        session: session, view: view, receiver: receiver, source: sourceHandle, failure: failure)
      if engine != nil { errors.append("Exact Engine/source/receiving custody retained; no repeated maintenance/detach/close after failure.") }
    }
    observer.cancel()
    do { try await observer.value; observerJoined = true }
    catch { observerJoined = true; errors.append("Memory observer joined with failure: \(error)"); if bodyFailure == nil { bodyFailure = error } }
    do { try await memory.mark(.cleanup) }
    catch { errors.append("Final observation: \(error)"); if bodyFailure == nil { bodyFailure = error } }
    if bodyFailure == nil, fixtureJoined, sourceJoined, nativeJoined, enginesJoined, observerJoined {
      do {
        try await Task.detached { try FileManager.default.removeItem(at: scratch) }.value
        scratchRemoved = true
      } catch { errors.append("Joined scratch cleanup: \(error)"); bodyFailure = error }
    }
    let summary = try await memory.finish(outcome: bodyFailure == nil ? "passed" : "failed",
      scratch: scratch, scratchRemoved: scratchRemoved, fixtureJoined: fixtureJoined, sourceJoined: sourceJoined,
      nativeJoined: nativeJoined, enginesJoined: enginesJoined, observerJoined: observerJoined, errors: errors)
    let attachment = XCTAttachment(string: String(decoding: summary, as: UTF8.self))
    attachment.name = "Public 1 GiB memory and joined cleanup; evidence: " + diagnostics.path
    attachment.lifetime = .keepAlways
    add(attachment)
    if let bodyFailure { throw bodyFailure }
    try require(scratchRemoved, "Successful 1 GiB scratch cleanup did not follow all owner joins.")
  }
}

#endif
