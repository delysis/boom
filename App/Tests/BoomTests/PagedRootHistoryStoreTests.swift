import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
/// Actual system-SQLite/provider controls. Synthetic UInt64.max references are
/// confined to the pure codec width check; they never enter the real engine.
@MainActor private final class SQLHistoryFixture {
  let root: URL, ownerID: UUID, documentID: UUID, storeID: UUID
  let key = SymmetricKey(data: Data(repeating: 0x71, count: 32))
  var vault: Vault?
  var engine: PagedTextEngineAdapter?
  var identity: PagedSQLPublicControlIdentity?
  var file: FileHandle?
  var originalErrors: [Error] = []
  private var leases: [PagedTextRootLease] = []
  init(root: URL) { self.root = root; ownerID = UUID(); documentID = UUID(); storeID = UUID() }
  func receive<T: Sendable>(_ output: PagedTextCustodiedValue<T>) throws -> T {
    guard leases.count < 32 else { throw PagedTextCustodyFailure(original: BoomError.budget("History fixture already owns 32 actual outputs."), lease: output.lease) }
    leases.append(output.lease); return output.value
  }
  func release(_ lease: PagedTextRootLease) async throws {
    guard leases.contains(lease), let engine else { throw BoomError.denied("History output belongs to another receiver.") }
    try await engine.abandonJoinedRootOutput(lease); leases.removeAll { $0 == lease }
  }
  func open(existing: Bool = false) async throws {
    let root = root, key = key
    let actualVault = try await Task.detached { try Vault(root: root, testKey: key) }.value
    vault = actualVault
    let actual = try await PagedTextEngineAdapter.create(vault: actualVault, ownerID: ownerID,
      sqliteOpening: existing ? .existing(storeID: storeID) : .fresh(storeID: storeID))
    engine = actual
    identity = try await actual._publicSQLControlIdentity(expectedVault: actualVault, expectedStoreID: storeID)
  }
  func history(count: Int = 2) async throws -> PagedRootHistory {
    let engine = try XCTUnwrap(engine), root = root
    let source = try await Task.detached {
      let path = root.appendingPathComponent("public-history-source-" + UUID().uuidString)
      try Data("a public cafe\u{301}🙂\n".utf8).write(to: path, options: .withoutOverwriting)
      return try FileHandle(forReadingFrom: path)
    }.value
    file = source
    let imported = try await engine.importUTF8Retaining(documentID: documentID, from: source)
    var revision = try receive(imported).revision
    try await Task.detached { try source.close() }.value; file = nil
    let cursor = PagedSealedCursor(byteOffset: 0, utf16Offset: 0)
    var result = try PagedRootHistory(revision: revision, cursor: cursor)
    var retained = imported.lease
    // At most two source outputs plus one bounded window are held at a time.
    for index in 0..<count {
      let read = try await engine.windowRetaining(revision, byteStart: 0, maximumBytes: 64)
      let window = try receive(read)
      let edit = try PagedWindowCoordinates(window: window).edit(in: NSRange(location: 0, length: 1), replacement: index.isMultiple(of: 2) ? "b" : "a")
      let next = try await engine.spliceRetaining(edit)
      revision = try receive(next)
      try result.record(revision, cursor: cursor, beforeCursor: cursor, groupID: UUID())
      try await release(read.lease); try await release(retained)
      retained = next.lease
    }
    return result
  }
  func document(_ revision: PagedTextRevision) -> PagedDocumentDescriptor {
    PagedDocumentDescriptor(id: documentID, title: "Public bounded history", revision: revision)
  }
  func write(_ history: PagedRootHistory, document: PagedDocumentDescriptor? = nil) async throws -> PagedDocumentRootRecord {
    let output = try await engine!._publicSQLControlWriteHistoryRetaining(identity: identity!, history: history,
      document: document ?? self.document(history.current))
    return try receive(output)
  }
  func load(_ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    let output = try await engine!._publicSQLControlHistoryComponentLoadRetaining(identity: identity!, record: record)
    let history = try receive(output); try await release(output.lease); return history
  }
  func witness(_ record: PagedDocumentRootRecord, target: PagedSQLPublicPageTarget = .historyManifest)
    async throws -> PagedTextCustodiedValue<PagedSQLPublicCiphertextWitness> {
    let output = try await engine!._publicSQLControlCiphertextWitnessRetaining(identity: identity!, record: record, target: target)
    _ = try receive(output); return output
  }
  func bytes(_ witness: PagedSQLPublicCiphertextWitness) async throws -> Data {
    let output = try await engine!._publicSQLControlHistoryBytesRetaining(identity: identity!, witness: witness)
    let bytes = try receive(output); try await release(output.lease); return bytes
  }
  func manifest(_ record: PagedDocumentRootRecord) async throws -> Data {
    let original = try await witness(record)
    let bytes = try await self.bytes(original.value)
    try await release(original.lease); return bytes
  }
  func replacingManifest(_ record: PagedDocumentRootRecord,
    edit: (inout [String: Any]) throws -> Void) async throws -> PagedDocumentRootRecord {
    let original = try await witness(record)
    let originalBytes = try await bytes(original.value)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
    try edit(&object)
    let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let appended = try await engine!._publicSQLControlAppendHistoryMetadataRetaining(identity: identity!,
      witness: original.value, kind: .manifest, bytes: changed)
    let page = try receive(appended).page
    try await release(original.lease)
    return PagedDocumentRootRecord(document: record.document, historyPage: page, historyGeneration: record.historyGeneration)
  }
  func close() async throws {
    guard file == nil, let engine else { throw BoomError.stale("Actual history descriptor/opening remains owned.") }
    for lease in leases { try await engine.abandonJoinedRootOutput(lease) }; leases.removeAll()
    let joined = try await engine.joinScheduledWALMaintenance()
    if let error = joined.failure { throw error }
    guard engine.custodySnapshot.jobs == 0 else { throw BoomError.stale("Actual history producer has not joined.") }
    try await engine.close(); self.engine = nil; identity = nil
  }
}

@MainActor final class PagedRootHistoryStoreTests: XCTestCase {
  private static var retained: SQLHistoryFixture?
  private func fixture(_ body: (SQLHistoryFixture) async throws -> Void) async throws {
    guard Self.retained == nil else { throw BoomError.stale("An earlier actual history failure remains owned by this process.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-sql-history-" + UUID().uuidString)
    let held = SQLHistoryFixture(root: root); Self.retained = held
    let failures = testRun?.failureCount ?? 0
    print("Actual encrypted history fixture: \(root.path)")
    do {
      try await held.open(); try await body(held)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual history assertion failed; retain originals.") }
      try await held.close()
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      Self.retained = nil
    } catch {
      held.originalErrors.append(error)
      XCTFail("Actual encrypted history failure preserved at \(root.path): \(error)"); throw error
    }
  }
  private func refuses(_ body: () async throws -> Void, inspect: (Error) -> Void = { _ in }) async throws {
    do { try await body() }
    catch { inspect(pagedSQLUnderlyingRefusal(error)); return }
    XCTFail("Real history candidate unexpectedly passed admission.")
    throw BoomError.invalid("Expected real history refusal.")
  }
  func testAuthenticatedRoundTripReturnsCompleteRecordAndReopensWithoutHistoryCache() async throws {
    try await fixture { f in
      let empty = PagedTextRevision(schema: 1, ownerID: f.ownerID, documentID: f.documentID, root: nil)
      let initial = try PagedRootHistory(revision: empty, cursor: PagedSealedCursor(byteOffset: 0, utf16Offset: 0))
      let initialRecord = try await f.write(initial)
      let initialRead = try await f.load(initialRecord); XCTAssertEqual(initialRead, initial)
      let history = try await f.history(), document = f.document(history.current)
      let record = try await f.write(history)
      XCTAssertEqual(record.document, document); XCTAssertEqual(record.historyGeneration, history.generation)
      let bytes = try await f.manifest(record)
      let manifest = try JSONDecoder().decode(PagedRootHistoryManifest.self, from: bytes)
      XCTAssertLessThanOrEqual(manifest.segments.count, 4)
      let restored = try await f.load(record); XCTAssertEqual(restored, history)
      let encrypted = try await f.witness(record)
      XCTAssertGreaterThan(encrypted.value.ciphertextBytes, bytes.count)
      XCTAssertNotEqual(encrypted.value.ciphertextSHA256, Digest.sha256(bytes))
      try await f.close(); try await f.open(existing: true)
      let reopened = try await f.load(record); XCTAssertEqual(reopened, history)
    }
  }
  func testEveryHundredWideRootIsRetainedAcrossSealingUndoAndRedo() async throws {
    try await fixture { f in
      // Width is a codec property, explicitly separate from source-tree truth.
      func wide(_ ordinal: UInt64) -> PagedTextRevision {
        let page = PagedTextPageRef(locator: PagedTextPageLocator(storeID: f.storeID, recordID: UUID(), ciphertextBytes: 16_412),
          digest: Digest.sha256(Data("public pure-codec width \(ordinal)".utf8)))
        return PagedTextRevision(schema: 1, ownerID: f.ownerID, documentID: f.documentID,
          root: PagedTextTreeRef(page: page, summary: PagedTextSummary(bytes: UInt64.max, utf16: UInt64.max, lfCount: UInt64.max), height: 12))
      }
      let wideCursor = PagedSealedCursor(byteOffset: UInt64.max, utf16Offset: UInt64.max)
      var codecOnly = try PagedRootHistory(revision: wide(0), cursor: wideCursor)
      for ordinal in 1...100 { try codecOnly.record(wide(UInt64(ordinal)), cursor: wideCursor, beforeCursor: wideCursor, groupID: UUID()) }
      let wideBytes = try codecOnly.encoded(expected: codecOnly.current)
      XCTAssertLessThanOrEqual(wideBytes.count, PagedRootHistory.maximumEncodedBytes)
      XCTAssertGreaterThan(wideBytes.count, 3 * PagedRootHistoryStore.segmentBytes)
      XCTAssertEqual(try JSONDecoder().decode(PagedRootHistory.self, from: wideBytes), codecOnly)
      let original = try await f.history(count: 100)
      XCTAssertEqual(original.undo.count, 100)
      let record = try await f.write(original), bytes = try await f.manifest(record)
      let manifest = try JSONDecoder().decode(PagedRootHistoryManifest.self, from: bytes)
      let encoded = try original.encoded(expected: original.current)
      XCTAssertEqual(manifest.segments.count, (encoded.count + 16_383) / 16_384)
      XCTAssertLessThanOrEqual(manifest.segments.count, 4)
      var restored = try await f.load(record); XCTAssertEqual(restored, original)
      for _ in 0..<50 { _ = try restored.stepUndo(expected: restored.current) }
      XCTAssertEqual(restored.undo.count, 50); XCTAssertEqual(restored.redo.count, 50)
      let middle = try await f.write(restored), middleRead = try await f.load(middle)
      XCTAssertEqual(middleRead, restored)
      for _ in 0..<50 { _ = try restored.stepUndo(expected: restored.current) }
      XCTAssertEqual(restored.current, try XCTUnwrap(original.undo.first).revision); XCTAssertEqual(restored.redo.count, 100)
      for _ in 0..<100 { _ = try restored.stepRedo(expected: restored.current) }
      XCTAssertEqual(restored.current, original.current); XCTAssertEqual(restored.undo.count, 100); XCTAssertTrue(restored.redo.isEmpty)
    }
  }
  func testAuthenticatedManifestRejectsOwnerDocumentGenerationPurposeAndDigestChanges() async throws {
    try await fixture { f in
      let history = try await f.history(), record = try await f.write(history)
      let loaded = try await f.load(record); XCTAssertEqual(loaded, history)
      let changes: [(String, Any)] = [("ownerID", UUID().uuidString), ("documentID", UUID().uuidString),
        ("generation", history.generation + 1), ("schema", 2), ("purpose", "bloom/unrelated-index/v1"), ("digest", String(repeating: "0", count: 64))]
      for (key, value) in changes {
        let altered = try await f.replacingManifest(record) { $0[key] = value }
        try await self.refuses { _ = try await f.load(altered) }
      }
      let stale = PagedDocumentRootRecord(document: record.document, historyPage: record.historyPage, historyGeneration: record.historyGeneration + 1)
      try await self.refuses { _ = try await f.load(stale) }
    }
  }
  func testPageDigestsAreCheckedIndependentlyOfValidProviderAEAD() async throws {
    try await fixture { f in
      let history = try await f.history(), record = try await f.write(history)
      let bad = PagedTextPageRef(locator: record.historyPage.locator, digest: String(repeating: "0", count: 64))
      try await self.refuses { _ = try await f.load(PagedDocumentRootRecord(document: record.document, historyPage: bad, historyGeneration: record.historyGeneration)) }
      let altered = try await f.replacingManifest(record) { object in
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        segments[0]["digest"] = String(repeating: "0", count: 64); object["segments"] = segments
      }
      try await self.refuses { _ = try await f.load(altered) }
    }
  }
  func testValidShortSegmentAndFifthSegmentCannotChangeDeclaredHistoryCoverage() async throws {
    try await fixture { f in
      let history = try await f.history(count: 100), record = try await f.write(history)
      let manifest = try JSONDecoder().decode(PagedRootHistoryManifest.self, from: try await f.manifest(record))
      let witness = try await f.witness(record, target: .historySegment(0)), first = try await f.bytes(witness.value)
      let appended = try await f.engine!._publicSQLControlAppendHistoryMetadataRetaining(identity: f.identity!, witness: witness.value,
        kind: .segment, bytes: Data(first.dropLast()))
      let short = try f.receive(appended).page
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(short)) as? [String: Any])
      let shortened = try await f.replacingManifest(record) { value in
        var segments = try XCTUnwrap(value["segments"] as? [[String: Any]]); segments[0] = object; value["segments"] = segments
      }
      try await self.refuses({ _ = try await f.load(shortened) }, inspect: { error in
        guard case BoomError.invalid(let message) = error else { return XCTFail("Expected exact history extent refusal.") }
        XCTAssertTrue(message.contains("extent"))
      })
      let fifth = try await f.replacingManifest(record) { value in
        let segment = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest.segments[0]))
        value["segments"] = Array(repeating: segment, count: 5)
      }
      try await self.refuses { _ = try await f.load(fifth) }
    }
  }
  func testCurrentRootMismatchRefusesWritesAndAuthenticatedHistoryLoad() async throws {
    try await fixture { f in
      let history = try await f.history(), stats = try await f.engine!.stats()
      let other = PagedTextRevision(schema: 1, ownerID: f.ownerID, documentID: f.documentID, root: nil)
      let wrong = f.document(other)
      try await self.refuses { _ = try await f.write(history, document: wrong) }
      let unchanged = try await f.engine!.stats(); XCTAssertEqual(unchanged.pageWrites, stats.pageWrites)
      let record = try await f.write(history)
      try await self.refuses { _ = try await f.load(PagedDocumentRootRecord(document: wrong, historyPage: record.historyPage, historyGeneration: record.historyGeneration)) }
      for revision in [PagedTextRevision(schema: 1, ownerID: UUID(), documentID: f.documentID, root: history.current.root),
        PagedTextRevision(schema: 1, ownerID: f.ownerID, documentID: UUID(), root: history.current.root)] {
        let foreign = PagedDocumentDescriptor(id: revision.documentID, title: "Public foreign identity", revision: revision)
        try await self.refuses { _ = try await f.write(history, document: foreign) }
        try await self.refuses { _ = try await f.load(PagedDocumentRootRecord(document: foreign, historyPage: record.historyPage, historyGeneration: record.historyGeneration)) }
      }
    }
  }
  func testSameRootGenerationCannotUseThePreviousHistoryManifest() async throws {
    try await fixture { f in
      var history = try await f.history(count: 0)
      let before = try await f.write(history)
      let cursor = history.currentCursor
      try history.record(history.current, cursor: cursor, beforeCursor: cursor, groupID: UUID())
      XCTAssertTrue(history.undo.isEmpty)
      let after = try await f.write(history)
      XCTAssertEqual(before.document, after.document); XCTAssertGreaterThan(after.historyGeneration, before.historyGeneration)
      XCTAssertNotEqual(before, after)
      let actual = try await f.load(after); XCTAssertEqual(actual, history)
      try await self.refuses { _ = try await f.load(PagedDocumentRootRecord(document: after.document, historyPage: before.historyPage, historyGeneration: after.historyGeneration)) }
    }
  }
  func testCiphertextTamperCannotRestoreHistory() async throws {
    try await fixture { f in
      let history = try await f.history(), record = try await f.write(history)
      let witness = try await f.witness(record)
      let corrupted = try await f.engine!._publicSQLControlCorruptRetaining(identity: f.identity!, witness: witness.value)
      _ = try f.receive(corrupted)
      try await self.refuses({ _ = try await f.load(record) }, inspect: { XCTAssertTrue($0 is CryptoKitError) })
      // Restore only this exact known-successful public mutation while both
      // original producers remain retained; not an unknown-COMMIT disposition.
      let restored = try await f.engine!._publicSQLControlRestoreRetaining(identity: f.identity!, witness: witness.value)
      _ = try f.receive(restored)
      let recovered = try await f.load(record); XCTAssertEqual(recovered, history)
    }
  }
}
#endif
