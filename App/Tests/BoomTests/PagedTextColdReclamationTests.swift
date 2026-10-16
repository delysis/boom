import BoomCore
import Darwin
import Foundation
import XCTest
@testable import Boom

final class PagedTextColdReclamationTests: XCTestCase {
  private struct Fixture: Sendable {
    let root: URL, store: WorkspaceStore, owner: UUID, storeID: UUID, document: UUID, trash: UUID
    let record: PagedDocumentRootRecord, history: PagedRootHistory, revisions: [PagedTextRevision]
    let proposal: BoundedDocumentCapture, recipe: BoundedDocumentCapture
    var state: WorkspaceState
  }
  private func queued<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in queue.async { continuation.resume(with: Result { try body() }) } }
  }
  private func importSource(_ engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher,
    root: URL, document: UUID, text: Data) async throws -> PagedDocumentRootRecord {
    let url = root.appendingPathComponent("public-import-" + document.uuidString)
    try text.write(to: url)
    let source = try FileHandle(forReadingFrom: url)
    let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
    do { imported = try await engine.importUTF8Retaining(documentID: document, from: source); try source.close() }
    catch { try? source.close(); throw error }
    let initialized = try await engine.initialNativeRecordRetaining(PagedDocumentDescriptor(id: document, title: "Public", revision: imported.value.revision))
    let installed = try await engine.publishInitialDocumentRetaining(publisher, imported: imported, initialized: initialized)
    try FileManager.default.removeItem(at: url)
    return installed
  }
  private func fixture(deadGrowth: Bool = true, manyHistory: Bool = false) async throws -> Fixture {
    // A failed case leaves this public scratch root and its real owner intact.
    // Successful callers remove it only after actual engine close and flock release.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-cold-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root); try await store.acquireExclusiveWorkspace()
    let identity = try await store.storageIdentity(), id = UUID(), trash = UUID()
    let engine = try await PagedTextEngineAdapter.create(root: store.root, ownerID: identity.ownerID, storeID: identity.storeID)
    let publisher = try await engine.makeWorkspacePublisher()
    let first = try await importSource(engine, publisher: publisher, root: root, document: id,
      text: Data(repeating: 0x61, count: 2_228_224))
    _ = try await importSource(engine, publisher: publisher, root: root, document: trash, text: Data("retained unindexed trash".utf8))
    var revisions = [first.document.revision], windows: [PagedTextWindow] = []
    var codes = Array(UInt8(0x62)...UInt8(0x66))
    if manyHistory { codes.append(contentsOf: (0..<100).map { UInt8(0x67 + $0 % 19) }) }
    for code in codes {
      let before = try await engine.windowRetaining(revisions.last!, byteStart: 0, maximumBytes: 1024)
      let edit = PagedTextLocalEdit(revision: before.value.revision, windowID: before.value.windowID,
        byteStart: 0, byteEnd: 1, oldBytes: Data(before.value.text.utf8.prefix(1)), newBytes: Data([code]))
      let after = try await engine.spliceRetaining(edit)
      revisions.append(after.value)
      try await engine.abandonJoinedRootOutput(before.lease)
      try await engine.abandonJoinedRootOutput(after.lease)
    }
    for revision in [revisions[4], revisions[5]] {
      let read = try await engine.windowRetaining(revision, byteStart: 0, maximumBytes: 1024)
      windows.append(read.value); try await engine.abandonJoinedRootOutput(read.lease)
    }
    let originalDigest = try await engine.wholeTextSha256(revisions[3])
    try await engine.close()
    let queue = DispatchQueue(label: "public-cold-history-preparation")
    let savedRevisions = revisions, savedWindows = windows
    let result = try await queued(queue) { () throws -> (PagedDocumentRootRecord, PagedRootHistory, BoundedDocumentCapture, BoundedDocumentCapture) in
      let files = try PagedTextFileStore(root: store.root, ownerID: identity.ownerID, storeID: identity.storeID, queue: queue)
      let pages = try files.documentPages(id), historyStore = try PagedRootHistoryStore(pages: pages)
      let cursor = PagedSealedCursor(byteOffset: 0, utf16Offset: 0)
      // Materialize the exact saved projection directly. Foundation owns
      // history movement; the persistence value has no second Undo machine.
      let last = manyHistory ? savedRevisions.count - 1 : 2
      let firstRetained = max(0, last - PagedRootHistory.maximumEntries)
      let undo = (firstRetained..<(last - 1)).map {
        PagedRootHistoryEntry(revision: savedRevisions[$0], cursor: cursor, groupID: UUID())
      }
      let history = try PagedRootHistory(materializedCurrent: savedRevisions[last - 1], cursor: cursor,
        undo: undo, redo: [PagedRootHistoryEntry(revision: savedRevisions[last], cursor: cursor, groupID: UUID())],
        activeGroup: nil, generation: UInt64(last + 1))
      let current = try historyStore.writeNew(history, document: PagedDocumentDescriptor(id: id, title: "Public", revision: history.current))
      try files.publishDocument(current, expected: first)
      func captured(_ revision: PagedTextRevision, _ window: PagedTextWindow) throws -> BoundedDocumentCapture {
        let h = try PagedRootHistory(revision: revision, cursor: cursor)
        let record = try historyStore.writeNew(h, document: PagedDocumentDescriptor(id: id, title: "Public", revision: revision))
        return try BoundedDocumentCapture(record: record, window: window, title: "Public")
      }
      let proposal = try captured(savedRevisions[4], savedWindows[0])
      let recipe = try captured(savedRevisions[5], savedWindows[1])
      if deadGrowth {
        let chunk = Data(repeating: 0x7a, count: 65_536)
        for _ in 0..<1040 { _ = try files.appendPage(documentID: id, kind: .text, bytes: chunk) }
      }
      try files.synchronizeDocument(current); try files.close()
      return (current, history, proposal, recipe)
    }
    let prompt = try ProductCore.writingPrompt(result.3.modelSnapshot, caret: 0, examples: [], retaining: Int.max)
    let recipe = CompletionRecipe(document: result.3.modelSnapshot, caretUTF16: 0, sources: [], prompt: prompt.prompt,
      promptDigest: prompt.digest, omittedPrefixCharacters: 0, model: "public-cold-source-fixture", profile: .standard,
      settings: try ProductCore.sampling(.standard), maxTokens: 64, generationPolicy: nil, capture: result.3)
    let candidate = CandidateBundle(id: UUID(), recipe: recipe, origin: nil, candidates: [], selected: 0)
    try store.vault.encode(candidate, kind: .candidate, id: candidate.id)
    var state = WorkspaceState(); state.documents = [DocumentIndex(id: id, title: "Public")]
    state.archivedDocuments = [DocumentIndex(id: trash, title: "Trash")]; state.selectedDocument = id
    state.importedFiles = [id: ImportedFile(folderID: nil, path: "public.txt", originalDigest: originalDigest, originalRevision: revisions[3])]
    let snapshot = result.2.modelSnapshot
    state.proposals = [StoredProposal(id: UUID(), chatID: UUID(), messageID: UUID(),
      patch: DocumentPatch(documentID: id, revision: snapshot.revision, replacements: []), document: snapshot,
      capture: result.2, documents: [], attachments: [], status: "pending")]
    // Intentionally unindexed: all saved recipes, not just candidateIDs, pin roots.
    state.candidateIDs = []
    try await store.saveState(state)
    return Fixture(root: store.root, store: store, owner: identity.ownerID, storeID: identity.storeID,
      document: id, trash: trash, record: result.0, history: result.1, revisions: revisions,
      proposal: result.2, recipe: result.3, state: state)
  }
  private func opened(_ fixture: Fixture) async throws -> (PagedTextEngineAdapter, PagedWorkspacePublisher) {
    let engine = try await PagedTextEngineAdapter.create(root: fixture.root, ownerID: fixture.owner, storeID: fixture.storeID)
    return (engine, try await engine.makeWorkspacePublisher())
  }
  private func cleanup(_ fixture: Fixture, engine: PagedTextEngineAdapter) async throws {
    try await engine.close(); try await fixture.store.releaseExclusiveWorkspace()
    try FileManager.default.removeItem(at: fixture.root)
  }

  func testRealColdSweepPreservesCurrentUndoRedoOriginalProposalUnindexedRecipeAndTrash() async throws {
    let f = try await fixture(), (engine, publisher) = try await opened(f)
    let logical = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("documents/" + f.document.uuidString.lowercased() + "/pages").path)[.size] as? NSNumber
    let result = try await engine.reclaimColdWorkspace(state: try await f.store.loadState())
    XCTAssertNil(result.skippedReason); XCTAssertEqual(result.eligibleDocuments, 1)
    XCTAssertGreaterThan(result.punchedBytes, 60 * 1024 * 1024)
    XCTAssertLessThan(result.allocatedAfter, result.allocatedBefore)
    let sameLogical = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("documents/" + f.document.uuidString.lowercased() + "/pages").path)[.size] as? NSNumber
    XCTAssertEqual(sameLogical, logical)
    let history = try await engine.rootHistoryRetaining(publisher, expected: f.record)
    XCTAssertEqual(history.value, f.history); try await engine.abandonJoinedRootOutput(history.lease)
    for (index, revision) in f.revisions.enumerated() {
      let read = try await engine.windowRetaining(revision, byteStart: 0, maximumBytes: 1024)
      XCTAssertEqual(read.value.text.utf8.first, UInt8(0x61 + index))
      XCTAssertEqual(read.value.text.utf8.count, 1024); try await engine.abandonJoinedRootOutput(read.lease)
    }
    let trash = try await engine.currentDocumentRecordRetaining(publisher, documentID: f.trash)
    let text = try await engine.windowRetaining(trash.value.document.revision, byteStart: 0, maximumBytes: 1024)
    XCTAssertEqual(text.value.text, "retained unindexed trash")
    try await engine.abandonJoinedRootOutput(text.lease); try await engine.abandonJoinedRootOutput(trash.lease)
    try await engine.close()
    let queue = DispatchQueue(label: "public-cold-capture-reopen")
    try await queued(queue) {
      let files = try PagedTextFileStore(root: f.root, ownerID: f.owner, storeID: f.storeID, queue: queue)
      let history = try PagedRootHistoryStore(pages: try files.documentPages(f.document))
      XCTAssertEqual(try history.load(f.proposal.record).current, f.revisions[4])
      XCTAssertEqual(try history.load(f.recipe.record).current, f.revisions[5]); try files.close()
    }
    XCTAssertEqual(engine.custodySnapshot.jobs, 0); XCTAssertTrue(engine.custodySnapshot.items.isEmpty)
    try await f.store.releaseExclusiveWorkspace(); try FileManager.default.removeItem(at: f.root)
  }
  func testCorruptPersistedOriginalRefDisablesAllPunchingAndRetainsOriginalSource() async throws {
    var f = try await fixture(), revision = f.revisions[3]
    let documentID = f.document
    let node = try XCTUnwrap(f.record.document.revision.root)
    let bad = PagedTextTreeRef(page: PagedTextPageRef(locator: node.page.locator, digest: String(repeating: "0", count: 64)), summary: node.summary, height: node.height)
    revision = PagedTextRevision(schema: revision.schema, ownerID: revision.ownerID, documentID: revision.documentID, root: bad)
    f.state.importedFiles?[documentID]?.originalRevision = revision
    try await f.store.saveState(f.state)
    let (engine, publisher) = try await opened(f)
    let result = try await engine.reclaimColdWorkspace(state: try await f.store.loadState())
    XCTAssertNotNil(result.skippedReason); XCTAssertEqual(result.punchedBytes, 0)
    XCTAssertEqual(result.allocatedBefore, result.allocatedAfter)
    // Same already-marked current index offset/digest, but incompatible summary.
    // Children authentication must still run before a visited-bit shortcut.
    let summary = PagedTextSummary(bytes: node.summary.bytes + 1, utf16: node.summary.utf16 + 1, lfCount: node.summary.lfCount)
    let inconsistent = PagedTextTreeRef(page: node.page, summary: summary, height: node.height)
    f.state.importedFiles?[documentID]?.originalRevision = PagedTextRevision(schema: revision.schema,
      ownerID: revision.ownerID, documentID: revision.documentID, root: inconsistent)
    try await f.store.saveState(f.state)
    let second = try await engine.reclaimColdWorkspace(state: try await f.store.loadState())
    XCTAssertNotNil(second.skippedReason); XCTAssertEqual(second.punchedBytes, 0)
    XCTAssertEqual(second.allocatedBefore, second.allocatedAfter)
    let read = try await engine.windowRetaining(f.record.document.revision, byteStart: 0, maximumBytes: 4)
    XCTAssertEqual(read.value.text, "baaa"); try await engine.abandonJoinedRootOutput(read.lease)
    let record = try await engine.currentDocumentRecordRetaining(publisher, documentID: f.document)
    XCTAssertEqual(record.value, f.record); try await engine.abandonJoinedRootOutput(record.lease)
    try await cleanup(f, engine: engine)
  }
  func testOneHundredRealUndoRootsShareIndexTraversalAndRetainEveryProtectedSource() async throws {
    let f = try await fixture(manyHistory: true), (engine, publisher) = try await opened(f)
    XCTAssertEqual(f.history.undo.count + f.history.redo.count, 100)
    let result = try await engine.reclaimColdWorkspace(state: try await f.store.loadState())
    XCTAssertNil(result.skippedReason); XCTAssertGreaterThan(result.duplicateIndexNodes, 90)
    XCTAssertLessThan(result.expandedIndexNodes, 400)
    let history = try await engine.rootHistoryRetaining(publisher, expected: f.record)
    XCTAssertEqual(history.value, f.history); try await engine.abandonJoinedRootOutput(history.lease)
    for entry in f.history.undo + f.history.redo {
      let window = try await engine.windowRetaining(entry.revision, byteStart: 0, maximumBytes: 4)
      XCTAssertEqual(window.value.revision, entry.revision); XCTAssertEqual(window.value.text.utf8.count, 4)
      try await engine.abandonJoinedRootOutput(window.lease)
    }
    for capture in [f.proposal, f.recipe] {
      let window = try await engine.windowRetaining(capture.window.revision, byteStart: 0, maximumBytes: 1024)
      XCTAssertEqual(window.value.text, capture.window.text); try await engine.abandonJoinedRootOutput(window.lease)
    }
    try await cleanup(f, engine: engine)
  }
  func testFreshSourceSkipsTraversalAndPrecancelledColdWorkJoinsBeforeDestruction() async throws {
    let f = try await fixture(deadGrowth: false), (engine, _) = try await opened(f)
    let abandoned = f.root.appendingPathComponent(".reclaim-" + UUID().uuidString, isDirectory: true)
    let cache = abandoned.appendingPathComponent("ranges", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let leftover = cache.appendingPathComponent(UUID().uuidString + ".visited")
    XCTAssertTrue(FileManager.default.createFile(atPath: leftover.path, contents: Data([1]), attributes: [.posixPermissions: 0o600]))
    let before = try await engine.fileStatistics()
    let result = try await engine.reclaimColdWorkspace(state: f.state)
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    let after = try await engine.fileStatistics()
    XCTAssertEqual(result.eligibleDocuments, 0); XCTAssertEqual(result.punchedBytes, 0)
    XCTAssertEqual(before.pageReads, after.pageReads, "No index/history/source traversal on an ungrown file")
    let cancelled = PagedTextCancellation(); cancelled.cancel()
    do { _ = try await engine.reclaimColdWorkspace(state: f.state, cancellation: cancelled); XCTFail("Cancelled cold work entered") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(engine.custodySnapshot.closing); XCTAssertEqual(engine.custodySnapshot.jobs, 0)
    try await cleanup(f, engine: engine)
  }
  func testAnActualLiveReadLeaseRefusesColdAdmissionWithoutDiscardingTheReader() async throws {
    let f = try await fixture(deadGrowth: false), (engine, _) = try await opened(f)
    let read = try await engine.windowRetaining(f.record.document.revision, byteStart: 0, maximumBytes: 4)
    do { _ = try await engine.reclaimColdWorkspace(state: f.state); XCTFail("Live source admitted cold sweep") } catch {}
    XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == read.lease.id })
    XCTAssertEqual(read.value.text, "baaa"); XCTAssertFalse(engine.custodySnapshot.closing)
    try await engine.abandonJoinedRootOutput(read.lease); try await cleanup(f, engine: engine)
  }
  func testSuspiciousCrashScratchSymlinkIsRetainedBeforeAnySourceMutation() async throws {
    let f = try await fixture(deadGrowth: false), (engine, _) = try await opened(f)
    let old = f.root.appendingPathComponent(".reclaim-" + UUID().uuidString, isDirectory: true)
    let cache = old.appendingPathComponent("ranges", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let link = cache.appendingPathComponent(UUID().uuidString + ".ranges")
    let source = f.root.appendingPathComponent("documents/" + f.document.uuidString.lowercased() + "/pages")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let result = try await engine.reclaimColdWorkspace(state: f.state)
    XCTAssertNotNil(result.skippedReason); XCTAssertEqual(result.punchedBytes, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path)); XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), source.path)
    let read = try await engine.windowRetaining(f.record.document.revision, byteStart: 0, maximumBytes: 4)
    XCTAssertEqual(read.value.text, "baaa"); try await engine.abandonJoinedRootOutput(read.lease)
    try await cleanup(f, engine: engine)
  }
  func testInvalidLaterRangeRefusesBeforeAnyPunchAndRetainsPageBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-range-preflight-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let page = root.appendingPathComponent("pages"), ranges = root.appendingPathComponent("ranges")
    let original = Data(repeating: 0x61, count: 16_384)
    try original.write(to: page)
    var live = Data()
    for value in [UInt64(4096), 8192, 12_288, 20_000] {
      for shift in stride(from: 0, through: 56, by: 8) { live.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    try live.write(to: ranges)
    let file = try FileHandle(forUpdating: page), reader = try FileHandle(forReadingFrom: ranges)
    defer { try? reader.close(); try? file.close() }
    var calls = 0
    XCTAssertThrowsError(try PagedTextColdReclamation.punchGaps(file: file, ranges: reader, bytes: 16_384,
      blockBytes: 4096, cancellation: PagedTextCancellation(), punch: { _, offset, length in
        calls += 1
        try file.seek(toOffset: offset)
        try file.write(contentsOf: Data(repeating: 0, count: Int(length)))
        return true
      }))
    XCTAssertEqual(calls, 0, "The later invalid extent must be admitted before any destructive call.")
    XCTAssertEqual(try Data(contentsOf: page), original)
  }

  func testUnsupportedPunchBoundarySkipsWithoutMutatingTheRealFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-unsupported-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let page = root.appendingPathComponent("pages"), ranges = root.appendingPathComponent("ranges")
    let original = Data(repeating: 0x61, count: 16_384); try original.write(to: page)
    var live = Data()
    for value in [UInt64(4096), UInt64(8192)] { for shift in stride(from: 0, through: 56, by: 8) { live.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    try live.write(to: ranges)
    let file = try FileHandle(forUpdating: page), reader = try FileHandle(forReadingFrom: ranges)
    var calls = 0
    // Simulated ENOTSUP at the actual syscall boundary; this does NOT qualify
    // an unsupported filesystem or substitute for the real APFS control above.
    let result = try PagedTextColdReclamation.punchGaps(file: file, ranges: reader, bytes: 16_384,
      blockBytes: 4096, cancellation: PagedTextCancellation(), punch: { fd, offset, length in
        XCTAssertEqual(fd, file.fileDescriptor); XCTAssertEqual(offset, 0); XCTAssertEqual(length, 4096)
        calls += 1; return false
      })
    XCTAssertFalse(result.supported); XCTAssertEqual(result.bytes, 0); XCTAssertEqual(calls, 1)
    try reader.close(); try file.close()
    XCTAssertEqual(try Data(contentsOf: page), original)
    try FileManager.default.removeItem(at: root)
  }
}
