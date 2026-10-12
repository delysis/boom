import BoomCore
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY, UNPARSED, UNCOMPILED, UNRUN. Actual SQL outcomes replace
// the retired file-journal format; every original case remains nominated.
@MainActor private final class PagedSQLPublisherFixture {
  let root: URL, key: SymmetricKey, ownerID: UUID, storeID: UUID
  let vault: Vault, engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher
  let identity: PagedSQLPublicControlIdentity
  private var outputs: [(lease: PagedTextRootLease, value: Any)] = []
  private var originalRefusals: [Error] = []
  private(set) var lastFailedMetadata: PagedTextCustodyFailure?
  private(set) var terminalConflict: (PagedTextRootLease, PagedSQLiteExecution)?
  private var source: FileHandle?
  private var corruption: PagedTextCustodiedValue<PagedSQLPublicWorkspaceCiphertextWitness>?
  private var preparedCorruption: PagedTextCustodiedValue<PagedSQLPublicPreparedPartCiphertextWitness>?
  private let maintenance: PagedSQLNativeFixtureMaintenance
  private(set) var closeReturned = false

  init(root: URL, key: SymmetricKey, ownerID: UUID, storeID: UUID, vault: Vault,
    engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher, identity: PagedSQLPublicControlIdentity) {
    self.root = root; self.key = key; self.ownerID = ownerID; self.storeID = storeID
    self.vault = vault; self.engine = engine; self.publisher = publisher; self.identity = identity
    maintenance = PagedSQLNativeFixtureMaintenance(engine: engine)
  }
  /// Strongly receive each actual value/lease BEFORE caller observation can
  /// fail. Bounded public metadata only; values do not mint a storage ACK.
  func own<T: Sendable>(_ action: () async throws -> PagedTextCustodiedValue<T>) async throws -> PagedTextCustodiedValue<T> {
    guard !closeReturned, outputs.count < 32 else { throw BoomError.budget("Public Publisher receiver exceeds32 actual outputs or is closed.") }
    do {
      let result = try await action()
      if let index = outputs.firstIndex(where: { $0.lease == result.lease }) { outputs[index] = (result.lease, result.value) }
      else { outputs.append((result.lease, result.value)) }
      return result
    } catch {
      let original = error
      if let failure = original as? PagedTextCustodyFailure, !outputs.contains(where: { $0.lease == failure.lease }) {
        guard failure.lease.ownerID == ownerID, failure.lease.engineIncarnation == engine.custodyIncarnation else { throw original }
        outputs.append((failure.lease, original))
        lastFailedMetadata = failure
      }
      guard originalRefusals.count < 16 else { throw original }
      originalRefusals.append(original); throw original
    }
  }
  func release(_ lease: PagedTextRootLease) async throws {
    guard outputs.contains(where: { $0.lease == lease }) else { throw BoomError.denied("Public Publisher does not own this actual output.") }
    try await engine.abandonJoinedRootOutput(lease)
    outputs.removeAll { $0.lease == lease }
  }
  func transfer(_ lease: PagedTextRootLease, record: PagedDocumentRootRecord) async throws {
    guard outputs.contains(where: { $0.lease == lease }) else { throw BoomError.denied("Published source lacks its actual producing owner.") }
    try await engine.transferJoinedRootToHead(lease, publisher: publisher, expected: record)
    outputs.removeAll { $0.lease == lease }
  }
  func document(_ title: String) async throws -> PagedTextCustodiedValue<PagedDocumentRootRecord> {
    guard source == nil else { throw BoomError.stale("A public source descriptor remains owned.") }
    let root = root
    let file = try await Task.detached {
      let path = root.appendingPathComponent("public-empty-source-" + UUID().uuidString)
      try Data().write(to: path, options: .withoutOverwriting)
      return try FileHandle(forReadingFrom: path)
    }.value
    source = file // caller descriptor ownership precedes the actual bulk import
    let documentID = UUID()
    let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
    do { imported = try await own { try await engine.importUTF8Retaining(documentID: documentID, from: file) } }
    catch {
      let original = error
      do { try await Task.detached { try file.close() }.value; source = nil }
      catch { throw PublicPublisherFileFailure(original: original, closeError: error, handle: file) }
      throw original
    }
    do { try await Task.detached { try file.close() }.value; source = nil }
    catch { throw PublicPublisherFileFailure(original: error, closeError: error, handle: file) }
    let descriptor = PagedDocumentDescriptor(id: documentID, title: title, revision: imported.value.revision)
    let result = try await own { try await engine.initialNativeRecordRetaining(descriptor) }
    try engine.absorbJoinedCustody(imported.lease, into: result.lease)
    outputs.removeAll { $0.lease == imported.lease }
    return result // real empty Rust root + actual encrypted history, never a synthetic page
  }
  func advanced(_ record: PagedDocumentRootRecord) async throws -> PagedTextCustodiedValue<PagedDocumentRootRecord> {
    let loaded = try await own { try await engine._publicSQLControlHistoryRetaining(identity: identity, record: record) }
    var history = loaded.value
    let authoredCursor = history.currentCursor
    // Pure explicit metadata cursor; this is no physical input selection claim.
    try history.record(record.document.revision, cursor: authoredCursor, beforeCursor: authoredCursor, groupID: UUID())
    let result = try await own { try await engine._publicSQLControlWriteHistoryRetaining(identity: identity, history: history, document: record.document) }
    try await release(loaded.lease)
    return result
  }
  func state(_ records: [PagedDocumentRootRecord], theme: String = "dark") -> WorkspaceState {
    var state = WorkspaceState()
    state.documents = records.map { DocumentIndex(id: $0.document.id, title: $0.document.title) }
    state.theme = theme; state.selectedDocument = records.first?.document.id
    state.writingExampleIDs = records.reversed().map { $0.document.id }
    if let first = records.first {
      state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .document, id: first.document.id),
        text: "public unsent cafe\u{301}", attachments: [], authoredRole: nil)]
    }
    return state
  }
  func prepare(_ state: WorkspaceState) async throws -> PagedTextCustodiedValue<PagedSQLPublicPreparedWorkspace> {
    try await own { try await engine._publicSQLControlPrepareWorkspaceRetaining(identity: identity, publisher: publisher, state: state) }
  }
  func initialize(_ prepared: PagedSQLPublicPreparedWorkspace, records: [PagedDocumentRootRecord],
    control: PagedSQLPublicInitialPublicationControl = .ordinary, finish: Bool = true)
    async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspacePublication> {
    let output = try await own { try await engine._publicSQLControlPublishPreparedWorkspaceRetaining(identity: identity,
      publisher: publisher, prepared: prepared, documents: records, expectedHead: nil, initialControl: control) }
    if finish { try await finishMetadata(output) }
    return output
  }
  func metadata(_ prepared: PagedSQLPublicPreparedWorkspace, records: [PagedDocumentRootRecord],
    expectedHead: PagedWorkspaceHead) async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspacePublication> {
    let output = try await own { try await engine._publicSQLControlPublishPreparedWorkspaceRetaining(identity: identity,
      publisher: publisher, prepared: prepared, documents: records, expectedHead: expectedHead) }
    try await finishMetadata(output); return output
  }
  func finishMetadata(_ output: PagedTextCustodiedValue<PagedSQLPublicWorkspacePublication>) async throws {
    guard outputs.contains(where: { $0.lease == output.lease }) else { throw BoomError.denied("Actual metadata output is not in this receiver.") }
    do { try await engine.finishWorkspacePublication(PagedTextCustodiedValue(value: output.value.snapshot, lease: output.lease), publisher: publisher) }
    catch { originalRefusals.append(error); throw error }
  }
  func resolved(_ failure: PagedTextCustodyFailure) async throws -> PagedTextCustodiedValue<PagedTextEngineAdapter.SQLResolvedOutput> {
    try await own { try await engine.resolveSQLiteOutputRetaining(failure.lease, publisher: publisher) }
  }
  func cancelBefore(_ failure: PagedTextCustodyFailure) async throws -> PagedSQLiteExecution {
    let result = try await resolved(failure)
    guard case .before(let execution) = result.value else { throw BoomError.invalid("Actual metadata did not resolve BEFORE.") }
    let original = try await engine.cancelResolvedWorkspaceBefore(result.lease, publisher: publisher, execution: execution)
    XCTAssertNotNil(original)
    outputs.removeAll { $0.lease == result.lease }
    return execution
  }
  func forgetConsumed(_ lease: PagedTextRootLease) { outputs.removeAll { $0.lease == lease } }
  func publish(_ after: PagedDocumentRootRecord, expected: PagedDocumentRootRecord)
    async throws -> PagedTextCustodiedValue<PagedSQLPublicDocumentPublication> {
    let output = try await own { try await engine._publicSQLControlPublishDocumentRetaining(identity: identity,
      publisher: publisher, after: after, expected: expected) }
    // These are component metadata consumers, not native input. The actual
    // full-record head admission joins their use without fabricating an ACK.
    try await transfer(output.lease, record: output.value.publication.record)
    return output
  }
  func snapshot() async throws -> PagedWorkspaceSnapshot {
    try await own { try await engine.loadWorkspaceRetaining(publisher) }.value
  }
  func catalog() async throws -> PagedWorkspaceDocumentCatalog {
    try await own { try await engine.loadWorkspaceCatalogRetaining(publisher) }.value
  }
  func pointer() async throws -> UUID? {
    try await own { try await engine._publicSQLControlHeadPointerRetaining(identity: identity) }.value
  }
  func witness(head: PagedWorkspaceHead, record: PagedDocumentRootRecord?, target: PagedSQLPublicWorkspaceCiphertextTarget)
    async throws -> PagedTextCustodiedValue<PagedSQLPublicWorkspaceCiphertextWitness> {
    try await own { try await engine._publicSQLControlWorkspaceCiphertextWitnessRetaining(identity: identity,
      publisher: publisher, head: head, record: record, target: target) }
  }
  func corrupt(_ original: PagedTextCustodiedValue<PagedSQLPublicWorkspaceCiphertextWitness>) async throws {
    guard corruption == nil, preparedCorruption == nil else { throw BoomError.stale("An original public mutation remains owned.") }
    corruption = original // original output, not just a copied witness value
    let changed = try await own { try await engine._publicSQLControlCorruptWorkspaceCiphertextRetaining(identity: identity, witness: original.value) }
    XCTAssertEqual(changed.value.witnessID, original.value.id); XCTAssertFalse(changed.value.restored)
  }
  func restore(_ original: PagedTextCustodiedValue<PagedSQLPublicWorkspaceCiphertextWitness>, head: PagedWorkspaceHead) async throws {
    guard corruption?.value === original.value, corruption?.lease == original.lease else { throw BoomError.stale("Restoration lost the exact original producing output.") }
    let result = try await own { try await engine._publicSQLControlRestoreWorkspaceCiphertextRetaining(identity: identity, witness: original.value, expectedHead: head) }
    XCTAssertEqual(result.value.witnessID, original.value.id); XCTAssertEqual(result.value.observedHead, head); XCTAssertTrue(result.value.restored)
    corruption = nil // only after the actual original-byte restore returned
  }
  func corruptPrepared(_ original: PagedTextCustodiedValue<PagedSQLPublicPreparedPartCiphertextWitness>) async throws {
    guard preparedCorruption == nil, corruption == nil else { throw BoomError.stale("A public mutation already remains owned.") }
    preparedCorruption = original
    let result = try await own { try await engine._publicSQLControlCorruptPreparedPartRetaining(identity: identity, witness: original.value) }
    XCTAssertEqual(result.value.witnessID, original.value.id); XCTAssertFalse(result.value.restored)
  }
  func restorePrepared(_ original: PagedTextCustodiedValue<PagedSQLPublicPreparedPartCiphertextWitness>) async throws {
    guard preparedCorruption?.value === original.value, preparedCorruption?.lease == original.lease else { throw BoomError.stale("Prepared restoration lost its exact original producing output.") }
    let result = try await own { try await engine._publicSQLControlRestorePreparedPartRetaining(identity: identity, witness: original.value) }
    XCTAssertEqual(result.value.witnessID, original.value.id); XCTAssertTrue(result.value.restored)
    preparedCorruption = nil
  }
  func retainTerminalConflict(operation: PagedTextRootLease, execution: PagedSQLiteExecution) throws {
    guard execution.outcome == .resolved(.before), engine.custodySnapshot.jobs == 0,
      engine.custodySnapshot.items.contains(where: { $0.id == operation.id }), terminalConflict == nil else {
      throw BoomError.stale("Original metadata conflict/source join is absent.")
    }
    terminalConflict = (operation, execution)
  }
  func close() async throws {
    guard !closeReturned, source == nil, corruption == nil, preparedCorruption == nil,
      terminalConflict == nil else { throw BoomError.unavailable("Public descriptors/mutations/conflict remain owned.") }
    try await maintenance.drainAfterJoinedNativeCalls()
    guard engine.custodySnapshot.jobs == 0 else { throw BoomError.stale("Actual SQL producers remain owned.") }
    for item in outputs { try await release(item.lease) }
    try await engine.close(); closeReturned = true // literal returned close, never inferred absence
    outputs.removeAll(); originalRefusals.removeAll()
  }
}
private struct PublicPublisherFileFailure: Error {
  let original: Error, closeError: Error
  let handle: FileHandle
}

@MainActor final class PagedWorkspacePublisherTests: XCTestCase {
  private static var retainedSetupFailure: PagedTextSetupCustodyFailure?
  private static var retainedRoot: URL?
  private static var retainedOpening: PagedTextEngineAdapter?
  private static var retainedFixture: PagedSQLPublisherFixture?
  private static var retainedClosedFixtures: [PagedSQLPublisherFixture] = []
  private static var originalFailure: Error?
  private func open(root: URL, key: SymmetricKey, ownerID: UUID, storeID: UUID,
    opening: PagedSQLiteStore.Opening) async throws -> PagedSQLPublisherFixture {
    if let earlier = Self.retainedFixture {
      guard earlier.closeReturned, Self.retainedClosedFixtures.count < 2 else { throw BoomError.stale("Actual prior Engine must close before another singleton lifetime.") }
      Self.retainedClosedFixtures.append(earlier)
    }
    let vault = try await Task.detached { try Vault(root: root, testKey: key) }.value
    let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: ownerID, sqliteOpening: opening)
    Self.retainedOpening = engine // before Publisher or exact identity can refuse
    let publisher = try await engine.makeWorkspacePublisher()
    let identity = try await engine._publicSQLControlIdentity(expectedVault: vault, expectedStoreID: storeID)
    let fixture = PagedSQLPublisherFixture(root: root, key: key, ownerID: ownerID, storeID: storeID,
      vault: vault, engine: engine, publisher: publisher, identity: identity)
    Self.retainedFixture = fixture; return fixture
  }
  private func withFixture(terminalCase: String? = nil,
    _ body: (PagedSQLPublisherFixture) async throws -> Void) async throws {
    if let terminalCase {
      guard terminalCase == "testBeforeAndAfterHeadRecoveryAndExactWholeHeadConflictRetention",
        ProcessInfo.processInfo.environment["BLOOM_PAGED_SQL_PUBLISHER_CASE"] == terminalCase else {
        throw BoomError.denied("Nominate the exact public whole-head terminal conflict before fixture opening.")
      }
    }
    guard Self.retainedRoot == nil, Self.retainedOpening == nil, Self.retainedFixture == nil,
      Self.retainedSetupFailure == nil, Self.retainedClosedFixtures.isEmpty, Self.originalFailure == nil else { throw BoomError.denied("An earlier failed public Publisher still owns this process.") }
    let failures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-paged-publisher-" + UUID().uuidString)
    let key = SymmetricKey(data: Data(repeating: 0x7b, count: 32)), ownerID = UUID(), storeID = UUID()
    Self.retainedRoot = root; print("Public real SQL Publisher fixture: \(root.path)")
    do {
      let fixture = try await open(root: root, key: key, ownerID: ownerID, storeID: storeID, opening: .fresh(storeID: storeID))
      try await body(fixture)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Public Publisher assertions failed; original evidence remains owned.") }
      if let conflict = fixture.terminalConflict {
        guard terminalCase == "testBeforeAndAfterHeadRecoveryAndExactWholeHeadConflictRetention",
          fixture.engine.custodySnapshot.jobs == 0,
          fixture.engine.custodySnapshot.items.contains(where: { $0.id == conflict.0.id }), !fixture.closeReturned else {
          throw BoomError.stale("Nominate the exact retained-terminal whole-head conflict; no passing close.")
        }
        print("RETAINED_TERMINAL actual metadata BEFORE/caller state after later head advance; no Engine close or scratch deletion.")
        return
      }
      guard terminalCase == nil else { throw BoomError.invalid("The exact nominated terminal conflict lost its actual retained outcome.") }
      if let current = Self.retainedFixture, !current.closeReturned { try await current.close() }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      Self.retainedFixture = nil; Self.retainedOpening = nil; Self.retainedClosedFixtures.removeAll(); Self.retainedRoot = nil
    } catch {
      if Self.originalFailure == nil { Self.originalFailure = error }
      XCTFail("Actual public Publisher failure retained at \(root.path): \(error)")
      throw error // no cleanup/publication/maintenance retry or evidence deletion
    }
  }
  private func refusal(_ action: () async throws -> Void, accepts: (Error) -> Bool) async throws -> Error {
    do { try await action() } catch {
      let original = error
      guard accepts(pagedSQLUnderlyingRefusal(original)) else { throw original }
      return original // original retained by the actual receiver, never rewritten
    }
    XCTFail("Real SQL Publisher admitted an expected-refused operation.")
    throw BoomError.invalid("Expected actual Publisher refusal.")
  }

  func testCoherentRoundTripReopenAndRetainedWorkspaceInput() async throws {
    try await withFixture { f in
      let a = try await f.document("Public Cafe\u{301}"), b = try await f.document("Public Lantern")
      let records = [a.value, b.value], state = f.state(records)
      let prepared = try await f.prepare(state), first = try await f.initialize(prepared.value, records: records)
      XCTAssertEqual(first.value.snapshot.documents, records)
      XCTAssertEqual(first.value.snapshot.head.workspace, prepared.value.reference)
      try await f.transfer(a.lease, record: a.value); try await f.transfer(b.lease, record: b.value)
      let saved = first.value.snapshot
      try await f.close()
      let reopened = try await self.open(root: f.root, key: f.key, ownerID: f.ownerID,
        storeID: f.storeID, opening: .existing(storeID: f.storeID))
      let actual = try await reopened.catalog()
      XCTAssertEqual(actual.snapshot, saved)
      XCTAssertEqual(actual.state.documents, state.documents); XCTAssertEqual(actual.state.writingExampleIDs, state.writingExampleIDs)
      XCTAssertEqual(actual.state.composerDrafts?.first?.text, "public unsent cafe\u{301}")
      XCTAssertEqual(actual.state.composerDrafts?.first?.owner, state.composerDrafts?.first?.owner)
      XCTAssertEqual(actual.state.theme, "dark")
      XCTAssertFalse(reopened.vault.exists(.workspace, Vault.workspaceID))
      XCTAssertFalse(reopened.vault.exists(.saveJournal, Vault.workspaceID))
      let root = f.root
      let oldCatalogExists = await Task.detached { FileManager.default.fileExists(atPath: root.appendingPathComponent("paged-text-v1/catalog.sealed").path) }.value
      XCTAssertFalse(oldCatalogExists)
    }
  }

  func testNativeFullRecordCASPreservesUnrelatedHeadUpdatesAndReusesPayload() async throws {
    try await withFixture { f in
      let a = try await f.document("Public A"), b = try await f.document("Public B")
      let initialPrepared = try await f.prepare(f.state([a.value, b.value]))
      let initial = try await f.initialize(initialPrepared.value, records: [a.value, b.value])
      let prepared = try await f.prepare(f.state([a.value, b.value], theme: "light"))
      let metadata = try await f.metadata(prepared.value, records: [a.value, b.value], expectedHead: initial.value.snapshot.head)
      let preserved = try await f.snapshot(); XCTAssertEqual(preserved.documents, [a.value, b.value])
      let newB = try await f.advanced(b.value)
      _ = try await f.publish(newB.value, expected: b.value)
      let newA = try await f.advanced(a.value)
      let after = try await f.publish(newA.value, expected: a.value)
      XCTAssertEqual(after.value.validatedRecords, 1)
      XCTAssertEqual(after.value.publication.head.workspace, metadata.value.snapshot.head.workspace)
      let current = try await f.catalog()
      XCTAssertEqual(current.snapshot.documents, [newA.value, newB.value]); XCTAssertEqual(current.state.theme, "light")
      XCTAssertEqual(a.value.document.revision, newA.value.document.revision)
      let twice = try await f.advanced(newA.value)
      _ = try await self.refusal({ _ = try await f.publish(twice.value, expected: a.value) }, accepts: { if case BoomError.stale = $0 { return true }; return false })
      let unchanged = try await f.snapshot(); XCTAssertEqual(unchanged, current.snapshot)
    }
  }

  func testOrdinaryTextCommitDoesNotOpenOrHashLargeWorkspacePayload() async throws {
    try await withFixture { f in
      let record = try await f.document("Public")
      var state = f.state([record.value]); let draft = try XCTUnwrap(state.composerDrafts?.first)
      state.composerDrafts?[0] = ComposerDraft(owner: draft.owner,
        text: String(repeating: "public bounded metadata ", count: 20_000), attachments: draft.attachments, authoredRole: draft.authoredRole)
      let prepared = try await f.prepare(state), initial = try await f.initialize(prepared.value, records: [record.value])
      XCTAssertGreaterThan(initial.value.snapshot.head.workspace.partCount, 1)
      let witness = try await f.witness(head: initial.value.snapshot.head, record: record.value, target: .workspacePart(0))
      let originalDigest = witness.value.ciphertextSHA256
      try await f.corrupt(witness)
      let next = try await f.advanced(record.value), after = try await f.publish(next.value, expected: record.value)
      XCTAssertEqual(after.value.publication.head.workspace, initial.value.snapshot.head.workspace)
      XCTAssertEqual(after.value.validatedRecords, 1)
      _ = try await self.refusal({ _ = try await f.snapshot() }, accepts: { if case CryptoKitError.authenticationFailure = $0 { return true }; return false })
      try await f.restore(witness, head: after.value.publication.head)
      XCTAssertEqual(witness.value.ciphertextSHA256, originalDigest)
      let actual = try await f.catalog(); XCTAssertEqual(actual.snapshot.head, after.value.publication.head)
      XCTAssertEqual(actual.snapshot.documents, [next.value]); XCTAssertEqual(actual.state.composerDrafts?.first?.text, state.composerDrafts?.first?.text)
    }
  }

  func testExplicitWorkspaceCASAndProjectionMismatchCannotOverwriteASeal() async throws {
    try await withFixture { f in
      let record = try await f.document("Public"), preparedInitial = try await f.prepare(f.state([record.value]))
      let initial = try await f.initialize(preparedInitial.value, records: [record.value])
      let prepared = try await f.prepare(f.state([record.value], theme: "light")), next = try await f.advanced(record.value)
      let sealed = try await f.publish(next.value, expected: record.value)
      let before = try await f.snapshot(), pointer = try await f.pointer()
      let staleMetadata = try await self.refusal({ _ = try await f.metadata(prepared.value, records: [record.value], expectedHead: initial.value.snapshot.head) }, accepts: { if case BoomError.stale = $0 { return true }; return false })
      _ = try await f.cancelBefore(try XCTUnwrap(staleMetadata as? PagedTextCustodyFailure))
      let renamed = PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: next.value.document.id,
        title: "Different title", revision: next.value.document.revision), historyPage: next.value.historyPage,
        historyGeneration: next.value.historyGeneration)
      let mismatched = try await self.refusal({ _ = try await f.metadata(prepared.value, records: [renamed], expectedHead: sealed.value.publication.head) }, accepts: { if case BoomError.invalid = $0 { return true }; return false })
      _ = try await f.cancelBefore(try XCTUnwrap(mismatched as? PagedTextCustodyFailure))
      let after = try await f.snapshot(), actualPointer = try await f.pointer()
      XCTAssertEqual(after, before); XCTAssertEqual(actualPointer, pointer)
      XCTAssertEqual(f.engine.custodySnapshot.jobs, 0)
    }
  }

  func testBeforeAndAfterHeadRecoveryAndExactWholeHeadConflictRetention() async throws {
    try await withFixture(terminalCase: "testBeforeAndAfterHeadRecoveryAndExactWholeHeadConflictRetention") { f in
      let record = try await f.document("Public")
      let first = try await f.initialize(try await f.prepare(f.state([record.value])).value, records: [record.value])
      let before = first.value.snapshot
      let prepared = try await f.prepare(f.state([record.value], theme: "light"))
      try await f.engine._publicSQLControlArmCommitFault(identity: f.identity, fault: .veto)
      let refused = try await self.refusal({ _ = try await f.metadata(prepared.value, records: [record.value], expectedHead: before.head) }, accepts: { _ in true })
      let failure = try XCTUnwrap(refused as? PagedTextCustodyFailure)
      let resolved = try await f.resolved(failure)
      guard case .before(let execution) = resolved.value else { throw BoomError.invalid("Actual veto did not resolve full BEFORE.") }
      XCTAssertEqual(execution.beforeHead, before.head); XCTAssertTrue(execution.commitEntered); XCTAssertNotNil(execution.original)
      let unchanged = try await f.snapshot(); XCTAssertEqual(unchanged, before)
      // Wrong operation/scope cannot consume the actual failed metadata owner.
      _ = try await self.refusal({ _ = try await f.engine.cancelResolvedWorkspaceBefore(first.lease, publisher: f.publisher, execution: execution) }, accepts: { if case BoomError.stale = $0 { return true }; if case BoomError.denied = $0 { return true }; return false })
      // A later actual head advance invalidates that exact old full-BEFORE
      // scope. Its operation/original caller input remain retained until an
      // explicit receiving disposition; the fixture must not claim close.
      let afterPrepared = try await f.prepare(f.state([record.value], theme: "latest"))
      try await f.engine._publicSQLControlArmCommitFault(identity: f.identity, fault: .moveDatabaseName)
      let afterError = try await self.refusal({ _ = try await f.metadata(afterPrepared.value, records: [record.value], expectedHead: before.head) }, accepts: { _ in true })
      let afterFailure = try XCTUnwrap(afterError as? PagedTextCustodyFailure)
      try await f.engine._publicSQLControlRestoreDatabaseName(identity: f.identity)
      let afterResolution = try await f.resolved(afterFailure)
      guard case .workspace(let after) = afterResolution.value else { throw BoomError.invalid("Actual whole-workspace SQL outcome did not resolve AFTER.") }
      XCTAssertEqual(afterResolution.lease, afterFailure.lease)
      XCTAssertEqual(after.head.workspace, afterPrepared.value.reference)
      XCTAssertEqual(after.documents, before.documents)
      try await f.engine.finishWorkspacePublication(PagedTextCustodiedValue(value: after, lease: afterResolution.lease), publisher: f.publisher)
      XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == afterFailure.lease.id && $0.sqlReceivingJoined == true })
      let heldCount = f.engine.custodySnapshot.items.count
      _ = try await self.refusal({ _ = try await f.engine.cancelResolvedWorkspaceBefore(failure.lease, publisher: f.publisher, execution: execution) }, accepts: { if case BoomError.stale = $0 { return true }; return false })
      XCTAssertEqual(f.engine.custodySnapshot.items.count, heldCount)
      let latest = try await f.snapshot(); XCTAssertEqual(latest, after)
      XCTAssertGreaterThan(latest.head.generation, before.head.generation)
      XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == failure.lease.id && $0.sqlOperationID == execution.identity.operationID })
      try f.retainTerminalConflict(operation: failure.lease, execution: execution)
    }
  }
  func testRecoveryValidatesWorkspaceCatalogAndHistoryBeforeAnyRepair() async throws {
    try await withFixture { f in
      let record = try await f.document("Public")
      let prepared = try await f.prepare(f.state([record.value]))
      let output = try await f.initialize(prepared.value, records: [record.value], finish: false)
      let snapshot = output.value.snapshot
      // Receiving the SAME normal success remains blocked by every real
      // encrypted target component. Pointer reads never grant receiving.
      for target in [PagedSQLPublicWorkspaceCiphertextTarget.workspacePart(0), .documentRecord] {
        let witness = try await f.witness(head: snapshot.head, record: record.value, target: target)
        try await f.corrupt(witness)
        _ = try await self.refusal({ try await f.finishMetadata(output) }, accepts: { if case CryptoKitError.authenticationFailure = $0 { return true }; return false })
        let pointer1 = try await f.pointer()
        XCTAssertEqual(pointer1, snapshot.head.headID)
        XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == output.lease.id && $0.sqlReceivingJoined == false })
        try await f.restore(witness, head: snapshot.head)
      }
      let history = try await f.own { try await f.engine._publicSQLControlCiphertextWitnessRetaining(identity: f.identity, record: record.value, target: .historyManifest) }
      _ = try await f.own { try await f.engine._publicSQLControlCorruptRetaining(identity: f.identity, witness: history.value) }
      _ = try await self.refusal({ try await f.finishMetadata(output) }, accepts: { if case CryptoKitError.authenticationFailure = $0 { return true }; return false })
      let pointer2 = try await f.pointer()
      XCTAssertEqual(pointer2, snapshot.head.headID)
      XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == output.lease.id && $0.sqlReceivingJoined == false })
      _ = try await f.own { try await f.engine._publicSQLControlRestoreRetaining(identity: f.identity, witness: history.value) }
      try await f.finishMetadata(output)
      let actual = try await f.snapshot(); XCTAssertEqual(actual, snapshot)
      XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == output.lease.id && $0.sqlReceivingJoined == true })
    }
  }
  func testFreshInitializationRejectsMissingCorruptAndOldPrototypeMetadata() async throws {
    try await withFixture { f in
      _ = try await self.refusal({ _ = try await f.snapshot() }, accepts: { if case BoomError.invalid = $0 { return true }; if case BoomError.unavailable = $0 { return true }; return false })
      let pointer3 = try await f.pointer()
      XCTAssertNil(pointer3) // missing SQL head never initializes an empty workspace
      let first = try await f.initialize(try await f.prepare(WorkspaceState()).value, records: [])
      _ = try await self.refusal({ _ = try await f.initialize(try await f.prepare(WorkspaceState()).value, records: []) }, accepts: { if case BoomError.stale = $0 { return true }; return false })
      // The second explicit initial attempt is truly unpublished, with actual
      // nonempty BEFORE. Dispose only it; the successful head stays intact.
      let last = f.lastFailedMetadata
      _ = try await f.cancelBefore(try XCTUnwrap(last))
      let saved = try await f.snapshot(); XCTAssertEqual(saved, first.value.snapshot)
      try await f.close()
      let path = f.root.appendingPathComponent("paged-sqlite-v3/store.sqlite")
      let original = try await Task.detached { try RegularFile(path, limit: 1_048_576).data() }.value
      try await Task.detached {
        try original.write(to: f.root.appendingPathComponent("original-public-sqlite.encrypted"), options: .withoutOverwriting)
        try Data("public obsolete/corrupt non-SQL prototype".utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      }.value
      let openingRefusal = try await self.refusal({
        let unexpected = try await self.open(root: f.root, key: f.key, ownerID: f.ownerID, storeID: f.storeID, opening: .existing(storeID: f.storeID))
        Self.retainedFixture = unexpected
        throw BoomError.invalid("A corrupt public SQL file unexpectedly opened.")
      }, accepts: { _ in true })
      if let unjoined = openingRefusal as? PagedTextSetupCustodyFailure {
        Self.retainedSetupFailure = unjoined; throw unjoined
      }
      guard Self.retainedFixture === f else { throw openingRefusal } // no overwrite while any unexpected connection is owned
      let preserved = try await Task.detached { try RegularFile(path, limit: 1_048_576).data() }.value
      XCTAssertEqual(preserved, Data("public obsolete/corrupt non-SQL prototype".utf8))
      try await Task.detached {
        try original.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      }.value
      let reopened = try await self.open(root: f.root, key: f.key, ownerID: f.ownerID, storeID: f.storeID, opening: .existing(storeID: f.storeID))
      let restored = try await reopened.snapshot(); XCTAssertEqual(restored, saved)
    }
  }
  func testNewAEADBindsUUIDPurposeOwnerAndExtentAndPreservesOldAAD() async throws {
    try await withFixture { f in
      let vault = f.vault, ownerID = f.ownerID, storeID = f.storeID
      let object = UUID(), document = Vault.workspaceID, plaintext = Data("public immutable payload".utf8)
      let binding = try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: document,
        objectID: object, role: .workspace, part: 0, plaintextBytes: plaintext.count)
      let ciphertext = try vault.sealPagedSQLiteObject(plaintext, binding: binding)
      let wrong = try [
        PagedSQLiteBinding(ownerID: UUID(), storeID: storeID, documentID: document, objectID: object, role: .workspace, part: 0, plaintextBytes: plaintext.count),
        PagedSQLiteBinding(ownerID: ownerID, storeID: UUID(), documentID: document, objectID: object, role: .workspace, part: 0, plaintextBytes: plaintext.count),
        PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: UUID(), objectID: object, role: .workspace, part: 0, plaintextBytes: plaintext.count),
        PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: document, objectID: UUID(), role: .workspace, part: 0, plaintextBytes: plaintext.count),
        PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: document, objectID: object, role: .documentRecord, part: 0, plaintextBytes: plaintext.count),
        PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: document, objectID: object, role: .workspace, part: 1, plaintextBytes: plaintext.count),
        PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: document, objectID: object, role: .workspace, part: 0, plaintextBytes: plaintext.count + 1)
      ]
      for altered in wrong { XCTAssertThrowsError(try vault.openPagedSQLiteObject(ciphertext, binding: altered)) }
      XCTAssertEqual(try vault.openPagedSQLiteObject(ciphertext, binding: binding), plaintext)
      XCTAssertThrowsError(try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: document,
        objectID: object, role: .workspace, part: 2_048, plaintextBytes: plaintext.count))
      XCTAssertThrowsError(try PagedWorkspaceObjectReference(objectID: object, plaintextBytes: 0,
        digest: Digest.sha256(plaintext), documentProjectionDigest: Digest.sha256(plaintext)).validate(ownerID: ownerID))
      // Shipped Vault persistence is preserved. Old unactivated paged-catalog
      // AAD vectors remain archived and do not become SQL compatibility code.
      let retainedState = WorkspaceState()
      let decoded = try await Task.detached {
        try vault.encode(retainedState, kind: .workspace, id: Vault.workspaceID)
        return try vault.decode(WorkspaceState.self, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit)
      }.value
      XCTAssertEqual(decoded.schema, retainedState.schema); XCTAssertEqual(decoded.documents, retainedState.documents)
    }
  }

  func testLegacyWholeSourceProposalCannotEnterWorkspacePayload() async throws {
    try await withFixture { f in
      let captured = DocumentSnapshot(title: "Public captured source", text: "public captured manuscript")
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: captured.id, title: captured.title)]
      state.proposals = [StoredProposal(id: UUID(), chatID: UUID(), messageID: UUID(),
        patch: DocumentPatch(documentID: captured.id, revision: captured.revision, replacements: []),
        document: captured, documents: [], attachments: [], status: "pending")]
      let vault = f.vault, legacyState = state
      let retained = try await Task.detached {
        try vault.encode(legacyState, kind: .workspace, id: Vault.workspaceID)
        return try Data(contentsOf: vault.recordURL(.workspace, Vault.workspaceID))
      }.value
      let before = try await f.engine.nativeSQLMaintenanceSnapshot()
      _ = try await self.refusal({ _ = try await f.prepare(state) }, accepts: { if case BoomError.unavailable = $0 { return true }; return false })
      let actual = try await Task.detached { try Data(contentsOf: vault.recordURL(.workspace, Vault.workspaceID)) }.value
      let after = try await f.engine.nativeSQLMaintenanceSnapshot(), pointer = try await f.pointer()
      XCTAssertEqual(actual, retained); XCTAssertEqual(after.storage.failedOperationID, before.storage.failedOperationID)
      XCTAssertNil(pointer); XCTAssertEqual(f.engine.custodySnapshot.jobs, 0)
    }
  }

  func testCanonicallyEquivalentTitleChangeStillInvalidatesExpectedRecord() async throws {
    try await withFixture { f in
      let original = try await f.document("Cafe\u{301}"), firstPrepared = try await f.prepare(f.state([original.value]))
      let initial = try await f.initialize(firstPrepared.value, records: [original.value])
      let renamed = PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: original.value.document.id,
        title: "Caf\u{e9}", revision: original.value.document.revision), historyPage: original.value.historyPage,
        historyGeneration: original.value.historyGeneration)
      XCTAssertEqual(original.value.document.title, renamed.document.title)
      XCTAssertFalse(original.value.document.title.utf8.elementsEqual(renamed.document.title.utf8))
      let prepared = try await f.prepare(f.state([renamed]))
      XCTAssertNotEqual(prepared.value.reference.documentProjectionDigest, initial.value.snapshot.head.workspace.documentProjectionDigest)
      let metadata = try await f.metadata(prepared.value, records: [renamed], expectedHead: initial.value.snapshot.head)
      let stale = try await f.advanced(original.value)
      _ = try await self.refusal({ _ = try await f.publish(stale.value, expected: original.value) }, accepts: { if case BoomError.stale = $0 { return true }; return false })
      let actual = try await f.snapshot(); XCTAssertEqual(actual, metadata.value.snapshot)
    }
  }

  func testSynchronizationFailureCannotWriteHeadOrJournal() async throws {
    try await withFixture { f in
      let record = try await f.document("Public")
      let before = try await f.initialize(try await f.prepare(f.state([record.value])).value, records: [record.value])
      let prepared = try await f.prepare(f.state([record.value], theme: "light"))
      try await f.engine._publicSQLControlArmCommitFault(identity: f.identity, fault: .veto)
      let refused = try await self.refusal({ _ = try await f.metadata(prepared.value, records: [record.value], expectedHead: before.value.snapshot.head) }, accepts: { _ in true })
      let failure = try XCTUnwrap(refused as? PagedTextCustodyFailure)
      let execution = try await f.cancelBefore(failure)
      XCTAssertTrue(execution.commitEntered); XCTAssertNotNil(execution.original)
      XCTAssertEqual(execution.outcome, .resolved(.before))
      XCTAssertEqual(execution.checkpoint?.code, 0)
      let actual = try await f.snapshot(); XCTAssertEqual(actual, before.value.snapshot)
      let pointer4 = try await f.pointer()
      XCTAssertEqual(pointer4, before.value.snapshot.head.headID)
      XCTAssertFalse(f.engine.custodySnapshot.items.contains { $0.id == failure.lease.id })
      _ = try await self.refusal({ _ = try await f.engine.cancelResolvedWorkspaceBefore(failure.lease, publisher: f.publisher, execution: execution) }, accepts: { if case BoomError.denied = $0 { return true }; return false })
      let final = try await f.snapshot(); XCTAssertEqual(final, actual)
    }
  }
  func testInitializationCancellationAfterCatalogPreparationCannotBeginJournal() async throws {
    try await withFixture { f in
      let record = try await f.document("Public cancellation"), prepared = try await f.prepare(f.state([record.value]))
      let before = try await f.own { try await f.engine._publicSQLControlPreparedPartDigestRetaining(identity: f.identity,
        publisher: f.publisher, prepared: prepared.value, part: 0) }
      let cancelled = try await self.refusal({ _ = try await f.initialize(prepared.value, records: [record.value], control: .cancelAfterRecordValidation) }, accepts: { $0 is CancellationError })
      _ = try await f.cancelBefore(try XCTUnwrap(cancelled as? PagedTextCustodyFailure))
      let evidence = try await f.engine._publicSQLControlPreparedWorkspaceEvidence(identity: f.identity, prepared: prepared.value)
      XCTAssertEqual(evidence.attempts, 1); XCTAssertEqual(evidence.validatedRecords, 1); XCTAssertEqual(evidence.publicationChecks, 1)
      XCTAssertNotNil(evidence.operationID)
      let pointer = try await f.pointer(); XCTAssertNil(pointer)
      let retained = try await f.own { try await f.engine._publicSQLControlPreparedPartDigestRetaining(identity: f.identity,
        publisher: f.publisher, prepared: prepared.value, part: 0) }
      XCTAssertEqual(retained.value, before.value)
      let actual = try await f.initialize(prepared.value, records: [record.value]) // explicit new publication, never implicit retry
      XCTAssertEqual(actual.value.snapshot.documents, [record.value]); XCTAssertEqual(actual.value.snapshot.head.workspace, prepared.value.reference)
      let loaded = try await f.snapshot(); XCTAssertEqual(loaded, actual.value.snapshot)
    }
  }

  func testPreparedPayloadReplacementAndForeignVaultCannotPublish() async throws {
    try await withFixture { f in
      let prepared = try await f.prepare(WorkspaceState())
      let digest = try await f.own { try await f.engine._publicSQLControlPreparedPartDigestRetaining(identity: f.identity,
        publisher: f.publisher, prepared: prepared.value, part: 0) }
      let deniedKey = try await self.refusal({ _ = try await f.own { try await f.engine._publicSQLControlRestagePreparedPartRetaining(identity: f.identity,
        publisher: f.publisher, prepared: prepared.value, part: 0) } }, accepts: { $0 is PagedSQLPublicImmutableKeyRefusal })
      let actualKey = try XCTUnwrap(pagedSQLUnderlyingRefusal(deniedKey) as? PagedSQLPublicImmutableKeyRefusal)
      XCTAssertEqual(actualKey.objectID, prepared.value.reference.objectID); XCTAssertEqual(actualKey.part, 0)
      XCTAssertEqual(actualKey.extendedCode, 1_555) // SQLITE_CONSTRAINT_PRIMARYKEY from the real step
      let afterKey = try await f.own { try await f.engine._publicSQLControlPreparedPartDigestRetaining(identity: f.identity,
        publisher: f.publisher, prepared: prepared.value, part: 0) }
      XCTAssertEqual(afterKey.value, digest.value)
      let original = try await f.own { try await f.engine._publicSQLControlPreparedPartWitnessRetaining(identity: f.identity,
        publisher: f.publisher, prepared: prepared.value, part: 0) }
      let originalCiphertext = original.value.ciphertextSHA256
      try await f.corruptPrepared(original)
      let corruptedPreparation = try await self.refusal({ _ = try await f.initialize(prepared.value, records: []) }, accepts: { if case CryptoKitError.authenticationFailure = $0 { return true }; return false })
      _ = try await f.cancelBefore(try XCTUnwrap(corruptedPreparation as? PagedTextCustodyFailure))
      let absent = try await f.pointer(); XCTAssertNil(absent)
      // This genuinely authenticates changed staged input after preparation;
      // the PK refusal above is a separate immutability oracle, no substitute.
      try await f.restorePrepared(original); XCTAssertEqual(original.value.ciphertextSHA256, originalCiphertext)
      let actual = try await f.initialize(prepared.value, records: [])
      let saved = actual.value.snapshot, foreignPrepared = prepared.value
      try await f.close()
      let reopened = try await self.open(root: f.root, key: f.key, ownerID: f.ownerID,
        storeID: f.storeID, opening: .existing(storeID: f.storeID))
      _ = try await self.refusal({ _ = try await reopened.initialize(foreignPrepared, records: []) }, accepts: { if case BoomError.denied = $0 { return true }; return false })
      let unchanged = try await reopened.snapshot(); XCTAssertEqual(unchanged, saved)
    }
  }

  func testExplicitInitialJournalRecoveryAndMetadataBounds() async throws {
    try await withFixture { f in
      let prepared = try await f.prepare(WorkspaceState())
      try await f.engine._publicSQLControlArmCommitFault(identity: f.identity, fault: .moveDatabaseName)
      let original = try await self.refusal({ _ = try await f.initialize(prepared.value, records: []) }, accepts: { _ in true })
      let failure = try XCTUnwrap(original as? PagedTextCustodyFailure)
      let blocked = try await f.engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNotNil(blocked.storage.failedOperationID)
      try await f.engine._publicSQLControlRestoreDatabaseName(identity: f.identity)
      let resolved = try await f.resolved(failure)
      guard case .workspace(let actual) = resolved.value else { throw BoomError.invalid("Actual namespace repair did not resolve initial AFTER.") }
      XCTAssertEqual(resolved.lease, failure.lease); XCTAssertEqual(actual.head.workspace, prepared.value.reference)
      XCTAssertEqual(actual.head.generation, 0); XCTAssertTrue(actual.documents.isEmpty)
      XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == failure.lease.id && $0.sqlReceivingJoined == false })
      try await f.engine.finishWorkspacePublication(PagedTextCustodiedValue(value: actual, lease: resolved.lease), publisher: f.publisher)
      XCTAssertTrue(f.engine.custodySnapshot.items.contains { $0.id == failure.lease.id && $0.sqlReceivingJoined == true })
      let loaded = try await f.snapshot(); XCTAssertEqual(loaded, actual)
      XCTAssertThrowsError(try PagedWorkspaceProjection.digest((0..<1_025).map { _ in DocumentIndex(id: UUID(), title: "Public") }))
      XCTAssertThrowsError(try PagedWorkspaceObjectReference(objectID: UUID(), plaintextBytes: Vault.workspaceLimit + 1,
        digest: String(repeating: "0", count: 64), documentProjectionDigest: String(repeating: "0", count: 64)).validate(ownerID: f.ownerID))
      XCTAssertEqual(Vault.workspaceLimit, 128 * 1_024 * 1_024)
      let joined = try await f.engine.nativeSQLMaintenanceSnapshot(); XCTAssertNil(joined.storage.failedOperationID)
    }
  }
  func testBoundedAdmissionValidatesOnlyRequestedRecordAndRefusesStaleFullRecord() async throws {
    try await withFixture { f in
      let a = try await f.document("Public A"), b = try await f.document("Public B")
      let prepared = try await f.prepare(f.state([a.value, b.value])), initial = try await f.initialize(prepared.value, records: [a.value, b.value])
      let original = try await f.witness(head: initial.value.snapshot.head, record: a.value, target: .workspacePart(0))
      try await f.corrupt(original)
      let admitted = try await f.own { try await f.engine._publicSQLControlAdmitCurrentRecordRetaining(identity: f.identity, publisher: f.publisher, expected: a.value) }
      XCTAssertEqual(admitted.value.record, a.value); XCTAssertEqual(admitted.value.validatedRecords, 1)
      let next = try await f.advanced(a.value), after = try await f.publish(next.value, expected: a.value)
      _ = try await self.refusal({ _ = try await f.own { try await f.engine._publicSQLControlAdmitCurrentRecordRetaining(identity: f.identity,
        publisher: f.publisher, expected: a.value) } }, accepts: { if case BoomError.stale = $0 { return true }; return false })
      _ = try await self.refusal({ _ = try await f.snapshot() }, accepts: { if case CryptoKitError.authenticationFailure = $0 { return true }; return false })
      try await f.restore(original, head: after.value.publication.head)
      let current = try await f.own { try await f.engine._publicSQLControlAdmitCurrentRecordRetaining(identity: f.identity, publisher: f.publisher, expected: next.value) }
      XCTAssertEqual(current.value.record, next.value); XCTAssertEqual(current.value.validatedRecords, 1)
      let loaded = try await f.snapshot(); XCTAssertEqual(loaded.documents, [next.value, b.value])
    }
  }

}
#endif
