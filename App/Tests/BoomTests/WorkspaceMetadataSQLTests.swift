import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
#if BOOM_UI_TEST
#error("Bounded metadata controls require their own disposable WorkspaceStore/SQL roots, not a BOOM_UI_TEST root override.")
#endif
// SOURCE ONLY / UNPARSED / UNCOMPILED / UNRUN. Nominate one exact case in a
// fresh process. These are SQL/native component controls, not physical input,
// ordinary product opening, migration, latency or memory acceptance.
private struct MetadataSQLCleanupFailure: Error {
  let original: Error
  let cleanup: Error
}

@MainActor private final class MetadataSQLFixture {
  let root: URL
  let store: WorkspaceStore?
  let vault: Vault
  let ownerID = UUID(), storeID = UUID()
  var engine: PagedTextEngineAdapter?
  // One actual retired source owner, still holding its unresolved input/outcome.
  // This retained-terminal case must never delete its public scratch evidence.
  var retiredEngine: PagedTextEngineAdapter?
  var publisher: PagedWorkspacePublisher?
  var identity: PagedSQLPublicControlIdentity?
  var source: PublicWorkspaceMetadataSource?
  var backend: PagedNativeStorageBackend?
  var backendSession: UUID?
  var backendSequence: UInt64 = 0
  var backendRecord: PagedDocumentRootRecord?
  var file: FileHandle?
  var fileCloseAttempted = false
  var leases: [PagedTextRootLease] = []
  var originals: [Error] = []
  var closed = false
  init(root: URL, store: WorkspaceStore?, vault: Vault) {
    self.root = root; self.store = store; self.vault = vault
  }
  func keep(_ lease: PagedTextRootLease) throws {
    guard !leases.contains(lease), leases.count < 16 else { throw BoomError.budget("Public fixture output ownership exceeded16 entries.") }
    leases.append(lease)
  }
  func preserve(_ error: Error) throws {
    guard originals.count < 8 else { throw BoomError.budget("Public original-error evidence exceeded8 entries.") }
    originals.append(error)
    print("Original public metadata refusal: \(error)")
  }
  func release(_ lease: PagedTextRootLease) async throws {
    guard leases.contains(lease), let engine else { throw BoomError.stale("Public output lacks its actual same-engine owner.") }
    try await engine.abandonJoinedRootOutput(lease)
    leases.removeAll { $0 == lease }
  }
  func closeFile() async throws {
    guard let file, !fileCloseAttempted else { throw BoomError.stale("Public descriptor close already attempted or absent.") }
    fileCloseAttempted = true
    try await Task.detached { try file.close() }.value
    self.file = nil
  }
  func open(_ opening: PagedSQLiteStore.Opening) async throws {
    guard engine == nil else { throw BoomError.stale("A real Rust singleton/SQL connection remains owned.") }
    do {
      let actual = try await PagedTextEngineAdapter.create(vault: vault, ownerID: ownerID, sqliteOpening: opening)
      engine = actual; closed = false
      identity = try await actual._publicSQLControlIdentity(expectedVault: vault, expectedStoreID: storeID)
      publisher = try await actual.makeWorkspacePublisher()
    } catch let failure as PagedTextSetupCustodyFailure {
      engine = failure.engine; try preserve(failure.original); throw failure
    }
  }
  func closeSource() async throws {
    guard file == nil, leases.isEmpty, let engine else { throw BoomError.stale("Public descriptors or actual returned outputs remain owned.") }
    if let backend {
      guard let record = backendRecord else { throw BoomError.stale("Actual controller lacks its current full record.") }
      try await backend.detachJoinedController(sessionID: backendSession, sequence: backendSequence, record: record)
      self.backend = nil; backendSession = nil; backendRecord = nil; backendSequence = 0
    }
    let maintenance = try await engine.joinScheduledWALMaintenance()
    if let failure = maintenance.failure { throw failure }
    guard engine.custodySnapshot.items.isEmpty else { throw BoomError.stale("Actual source/receiving producers remain unjoined.") }
    try await engine.close()
    self.engine = nil; publisher = nil; identity = nil; closed = true
  }
}

@MainActor final class WorkspaceMetadataSQLTests: XCTestCase {
  private static var retained: MetadataSQLFixture?
  private static var retainedRoot: URL?
  private func fixture(_ name: String, faultNamespace: Bool = false,
    _ body: @MainActor (MetadataSQLFixture) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["BLOOM_METADATA_SQL_PUBLIC_CASE"] == name else {
      throw BoomError.denied("Nominate this exact bounded metadata SQL case; no skips or implicit execution.")
    }
    guard Self.retained == nil, Self.retainedRoot == nil else { throw BoomError.denied("An earlier actual public owner remains retained.") }
    let failures = testRun?.failureCount ?? 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-metadata-public-" + UUID().uuidString)
    Self.retainedRoot = root
    print("Actual public bounded metadata fixture: \(root.path)")
    let store: WorkspaceStore?, vault: Vault
    if faultNamespace {
      // Keep the existing real fault guard unchanged. These two cases use its
      // exact public SQL Vault namespace and exercise Engine receiving only.
      store = nil
      vault = try await Task.detached {
        try Vault(root: root.appendingPathComponent("public-sql-durability-" + UUID().uuidString),
          testKey: SymmetricKey(data: Data(repeating: 0x6d, count: 32)))
      }.value
    } else {
      let actual = try await Task.detached {
        try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(data: Data(repeating: 0x6d, count: 32)))
      }.value
      store = actual; vault = actual.vault
    }
    let held = MetadataSQLFixture(root: root, store: store, vault: vault); Self.retained = held
    do {
      try await body(held)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("A substantive assertion failed; originals/owners/files retained.") }
      if let retired = held.retiredEngine {
        let retained = retired.custodySnapshot
        guard held.engine == nil, held.closed, held.file == nil, held.backend == nil,
          !held.leases.isEmpty, !held.originals.isEmpty, retained.closing, retained.jobs == 0,
          retained.items.allSatisfy({ $0.producerJoined && !$0.bulkActive }),
          retained.items.contains(where: { $0.phase == .unresolved && $0.sqlReceivingJoined == false }) else {
          throw BoomError.stale("The actual failed owner/input or joined cold close was lost.")
        }
        print("Retained terminal metadata owner/input/original at \(root.path); physical SQL/Rust resources retired and separate cold owner closed. No old receiving ACK or scratch deletion.")
        return
      }
      try await held.closeSource()
      guard held.closed else { throw BoomError.stale("Actual source close did not join.") }
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
      Self.retained = nil; Self.retainedRoot = nil
    } catch {
      // No failed-fixture deletion, guessed detach, Engine close or retry.
      // Exact original owners/leases/descriptors remain strongly held.
      try held.preserve(error)
      XCTFail("Public metadata failure retained at \(root.path): \(error)")
      throw error
    }
  }
  private func emptySeed(_ held: MetadataSQLFixture) async throws -> PagedWorkspaceHead {
    try await held.open(.fresh(storeID: held.storeID))
    let engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
    let input = try await Task.detached { try WorkspaceMetadataInput(settings: WorkspaceSettings(), initialDocuments: []) }.value
    let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: nil)
    try held.keep(saved.lease)
    let head = try await engine.finishWorkspaceMetadataPublication(saved, publisher: publisher)
    try await held.release(saved.lease)
    return head
  }
  private func settings(_ held: MetadataSQLFixture) async throws -> WorkspaceSettingsRead {
    let value = try await XCTUnwrap(held.engine).loadWorkspaceSettingsRetaining(XCTUnwrap(held.publisher))
    try held.keep(value.lease)
    let read = value.value; try await held.release(value.lease); return read
  }

  func testPublicConversionLazyDraftNativeReuseAndEncryptedReopen() async throws {
    try await fixture("testPublicConversionLazyDraftNativeReuseAndEncryptedReopen") { held in
      let store = try XCTUnwrap(held.store)
      let documentID = UUID(), chatID = UUID()
      let sourceText = "p e\u{301}🙂\n"
      let draftText = String(repeating: "public e\u{301}🙂 draft\n", count: 4_000)
      let owner = ComposerOwner(kind: .document, id: documentID)
      let draft = ComposerDraft(owner: owner, text: draftText, attachments: [], authoredRole: .user)
      var chat = ChatRecord(id: chatID, title: "Public 🙂", messages: [ChatMessage(role: .user, text: "public current", context: "captured context")], attachedDocumentID: documentID)
      chat.messageVersions = [ChatMessage(role: .user, text: "public prior version", context: "prior context")]
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: documentID, title: "Public source")]
      state.chats = [chat]; state.selectedDocument = documentID; state.selectedChat = chatID
      state.preferredModels = [:]; state.importedFolders = []; state.writingExampleIDs = [documentID]
      state.composerDrafts = [draft]
      let vault = held.vault, oldState = state
      let originalSHA = try await Task.detached {
        try vault.encode(oldState, kind: .workspace, id: Vault.workspaceID)
        try vault.put(Data(sourceText.utf8), kind: .document, id: documentID)
        return Digest.sha256(try vault.get(.workspace, id: Vault.workspaceID, limit: 1_048_576))
      }.value
      // Shipped inventory remains strict. Preparation precedes SQL opening.
      let prepared = try await store.publicFixtureMetadataSource(plaintextSHA256: originalSHA)
      held.source = prepared
      try await held.open(.fresh(storeID: held.storeID))
      let engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let path = held.root.appendingPathComponent("owned-source.utf8")
      let file = try await Task.detached {
        try Data(sourceText.utf8).write(to: path, options: .withoutOverwriting)
        return try FileHandle(forReadingFrom: path)
      }.value
      held.file = file
      let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
      do { imported = try await engine.importUTF8Retaining(documentID: documentID, from: file) }
      catch {
        let original = error
        do { try await held.closeFile() }
        catch { throw MetadataSQLCleanupFailure(original: original, cleanup: error) }
        throw original
      }
      try held.keep(imported.lease)
      try await held.closeFile()
      XCTAssertEqual(imported.value.wholeTextSha256, Digest.sha256(sourceText))
      let descriptor = PagedDocumentDescriptor(id: documentID, title: "Public source", revision: imported.value.revision)
      let initial = try await engine.initialNativeRecordRetaining(descriptor); try held.keep(initial.lease)
      let input = try await store.publicFixtureMetadataInput(prepared, engine: engine, publisher: publisher, documents: [initial.value])
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: nil)
      try held.keep(saved.lease)
      XCTAssertEqual(saved.value.head.workspace.layout, .settings)
      XCTAssertLessThanOrEqual(saved.value.head.workspace.plaintextBytes, 16_384)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == saved.lease.id && $0.sqlReceivingJoined == false && $0.producerJoined })
      let originalHead = try await engine.finishWorkspaceMetadataPublication(saved, publisher: publisher)
      try await held.release(saved.lease)
      try await engine.transferJoinedRootToHead(imported.lease, publisher: publisher, expected: initial.value)
      held.leases.removeAll { $0 == imported.lease }
      try await engine.transferJoinedRootToHead(initial.lease, publisher: publisher, expected: initial.value)
      held.leases.removeAll { $0 == initial.lease }
      let opening = try await store.loadPagedMetadataOpening(engine: engine, publisher: publisher)
      XCTAssertEqual(opening.head, originalHead); XCTAssertEqual(opening.documents.map(\.id), [documentID])
      XCTAssertEqual(opening.chats.compactMap { $0.header.chatIndex?.id }, [chatID])
      XCTAssertEqual(opening.chats.first?.header.counts["messages"], 1)
      XCTAssertEqual(opening.chats.first?.header.counts["versions"], 1)
      XCTAssertEqual(Set(opening.settings.presentOptionalCollections), ["preferredModels", "importedFolders", "composerDrafts", "writingExampleIDs"])
      XCTAssertNil(opening.nextDocumentOrdinal); XCTAssertNil(opening.nextChatOrdinal)
      let hydratedValue = try await store.loadPagedComposerDraft(owner, engine: engine, publisher: publisher)
      let hydrated = try XCTUnwrap(hydratedValue)
      XCTAssertEqual(hydrated.owner, owner); XCTAssertTrue(hydrated.text.utf8.elementsEqual(draftText.utf8))
      let header = try await engine.loadWorkspaceDraftRetaining(publisher, owner: owner); try held.keep(header.lease)
      let expectedDraft = try XCTUnwrap(header.value?.reference)
      XCTAssertGreaterThan(try XCTUnwrap(header.value?.header.bodies["text"]?.partCount), 1)
      try await held.release(header.lease)
      let nextDraft = ComposerDraft(owner: owner, text: draftText + "later🙂", attachments: [], authoredRole: .user)
      let pending = try await store.savePagedComposerDraftRetaining(nextDraft, expected: expectedDraft, engine: engine, publisher: publisher, expectedHead: originalHead)
      try held.keep(pending.lease)
      // A real canonical native worker seal may advance the source head before
      // metadata receiving. It reuses settings and never decodes WorkspaceState.
      let backend = try await engine.makeNativeStorage(publisher, expected: initial.value)
      held.backend = backend; held.backendRecord = initial.value
      let sessionID = UUID(); held.backendSession = sessionID
      let native = try await backend.opening(sessionID: sessionID)
      var working = try PagedWorkingWindow(window: native.window, rootRecord: native.record, sessionID: sessionID)
      let selection = try working.selection(NSRange(location: 0, length: 0))
      XCTAssertTrue(try working.replace(NSRange(location: 0, length: 1), with: "q", groupID: UUID(), beforeSelection: selection))
      let batch = try XCTUnwrap(working.takeCommitBatch())
      let acknowledgement = try await backend.commit(batch)
      held.backendSequence = acknowledgement.lastSequence; held.backendRecord = acknowledgement.sealedRootRecord
      try working.acknowledge(acknowledgement)
      try await backend.finishCommitInstallation(acknowledgement)
      let receivingHead = try await engine.finishWorkspaceMetadataPublication(pending, publisher: publisher)
      XCTAssertEqual(receivingHead.generation, pending.value.head.generation + 1)
      XCTAssertEqual(receivingHead.workspace, pending.value.head.workspace)
      let repeatedHead = try await engine.finishWorkspaceMetadataPublication(pending, publisher: publisher)
      XCTAssertEqual(repeatedHead, receivingHead)
      try await held.release(pending.lease)
      let nativeRecord = acknowledgement.sealedRootRecord
      try await held.closeSource()
      try await held.open(.existing(storeID: held.storeID))
      let reopenedEngine = try XCTUnwrap(held.engine), reopenedPublisher = try XCTUnwrap(held.publisher)
      let reopened = try await store.loadPagedMetadataOpening(engine: reopenedEngine, publisher: reopenedPublisher)
      XCTAssertEqual(reopened.head, receivingHead); XCTAssertEqual(reopened.settings.writingExampleIDs, [documentID])
      let reopenedDraftValue = try await store.loadPagedComposerDraft(owner, engine: reopenedEngine, publisher: reopenedPublisher)
      let reopenedDraft = try XCTUnwrap(reopenedDraftValue)
      XCTAssertTrue(reopenedDraft.text.utf8.elementsEqual(nextDraft.text.utf8))
      let reread = try await reopenedEngine.windowRetaining(nativeRecord.document.revision, byteStart: 0, maximumBytes: 65_536)
      try held.keep(reread.lease); XCTAssertTrue(reread.value.text.utf8.elementsEqual("q e\u{301}🙂\n".utf8))
      try await held.release(reread.lease)
      let oldSHA = try await Task.detached { Digest.sha256(try vault.get(.workspace, id: Vault.workspaceID, limit: 1_048_576)) }.value
      XCTAssertEqual(oldSHA, originalSHA) // conversion never overwrote legacy evidence
    }
  }

  func testVetoAndStaleHeadCancelOnlyActualBeforeThenConnectionRemainsWritable() async throws {
    try await fixture("testVetoAndStaleHeadCancelOnlyActualBeforeThenConnectionRemainsWritable", faultNamespace: true) { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      var value = WorkspaceSettings(); value.showLibrary = false
      let changed = value
      let input = try await Task.detached { try WorkspaceMetadataInput(settings: changed) }.value
      try await engine._publicSQLControlArmCommitFault(identity: XCTUnwrap(held.identity), fault: .veto)
      var veto: PagedTextCustodyFailure?
      do {
        let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
        try held.keep(unexpected.lease)
      } catch let actual as PagedTextCustodyFailure { veto = actual; try held.keep(actual.lease); try held.preserve(actual.original) }
      let failure = try XCTUnwrap(veto)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == failure.lease.id && $0.sqlReceivingJoined == false })
      let resolved = try await engine.resolveSQLiteOutputRetaining(failure.lease, publisher: publisher)
      guard case .before(let outcome) = resolved.value else { throw BoomError.invalid("Real veto did not select actual BEFORE.") }
      XCTAssertTrue(outcome.selectedBefore); XCTAssertNotNil(outcome.original)
      let original = try await engine.cancelResolvedWorkspaceBefore(failure.lease, publisher: publisher, execution: outcome)
      XCTAssertNotNil(original); held.leases.removeAll { $0 == failure.lease }
      let afterVeto = try await self.settings(held)
      XCTAssertEqual(afterVeto.head, before); XCTAssertTrue(afterVeto.settings.showLibrary)
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
      try held.keep(saved.lease)
      let after = try await engine.finishWorkspaceMetadataPublication(saved, publisher: publisher); try await held.release(saved.lease)
      var stale: PagedTextCustodyFailure?
      do {
        let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
        try held.keep(unexpected.lease)
      } catch let actual as PagedTextCustodyFailure { stale = actual; try held.keep(actual.lease); try held.preserve(actual.original) }
      let rejected = try XCTUnwrap(stale)
      let inspected = try await engine.resolveSQLiteOutputRetaining(rejected.lease, publisher: publisher)
      guard case .before(let actualBefore) = inspected.value else { throw BoomError.invalid("Stale request did not preserve its checked nonpublication.") }
      // This actual captured BEFORE is the newer current head, not requested
      // obsolete input. Cancellation cannot silently rebase/retry publication.
      XCTAssertEqual(actualBefore.beforeHead, after)
      _ = try await engine.cancelResolvedWorkspaceBefore(rejected.lease, publisher: publisher, execution: actualBefore)
      held.leases.removeAll { $0 == rejected.lease }
      let still = try await self.settings(held)
      XCTAssertEqual(still.head, after); XCTAssertFalse(still.settings.showLibrary)
      var later = still.settings; later.showChat = false
      let laterSettings = later
      let laterInput = try await Task.detached { try WorkspaceMetadataInput(settings: laterSettings) }.value
      let writable = try await engine.publishWorkspaceMetadataRetaining(publisher, input: laterInput, expectedHead: after)
      try held.keep(writable.lease)
      let final = try await engine.finishWorkspaceMetadataPublication(writable, publisher: publisher); try await held.release(writable.lease)
      XCTAssertEqual(final.generation, after.generation + 1)
      let maintenance = try await engine.joinScheduledWALMaintenance(); XCTAssertNil(maintenance.storage.failedOperationID)
    }
  }

  func testActualNameFailureRetainsUnresolvedOwnerAndColdReopenAuthenticatesCommittedSettings() async throws {
    try await fixture("testActualNameFailureRetainsUnresolvedOwnerAndColdReopenAuthenticatesCommittedSettings", faultNamespace: true) { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let oldConnection = (try await engine.nativeSQLMaintenanceSnapshot()).storage.identity
      var changed = WorkspaceSettings(); changed.autocomplete = false; changed.showChat = false
      changed.theme = "dark"; changed.preferredModels = ["writing": "public-model"]
      changed.presentOptionalCollections = ["preferredModels", "composerDrafts"]
      let settingsValue = changed
      let input = try await Task.detached { try WorkspaceMetadataInput(settings: settingsValue) }.value
      try await engine._publicSQLControlArmCommitFault(identity: XCTUnwrap(held.identity), fault: .moveDatabaseName)
      var refused: PagedTextCustodyFailure?
      do {
        let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
        try held.keep(unexpected.lease)
      } catch let actual as PagedTextCustodyFailure { refused = actual; try held.keep(actual.lease); try held.preserve(actual.original) }
      let failure = try XCTUnwrap(refused)
      let failedSnapshot = engine.custodySnapshot
      let failedItem = try XCTUnwrap(failedSnapshot.items.first { $0.id == failure.lease.id })
      XCTAssertEqual(failedItem.phase, .unresolved); XCTAssertEqual(failedItem.sqlOperationID, input.inputID)
      XCTAssertTrue(failedItem.producerJoined); XCTAssertFalse(failedItem.bulkActive)
      XCTAssertEqual(failedItem.sqlReceivingJoined, false); XCTAssertEqual(failedSnapshot.jobs, 0)
      // Restore only the same scratch name/inode. Apple VNODE has no documented
      // same-live-connection reset; do not inspect/retry/checkpoint old outcome.
      try await engine._publicSQLControlRestoreDatabaseName(identity: XCTUnwrap(held.identity))
      do {
        try await engine.close()
        throw BoomError.invalid("Normal close discarded the actual unresolved input/outcome.")
      } catch BoomError.unavailable { } // The unchanged normal close guard.
      try await engine.retireFailedSourceResources()
      held.retiredEngine = engine // Preserve actual owner, lease, original and scratch.
      held.engine = nil; held.publisher = nil; held.identity = nil
      // A NEW authoritative connection/engine, never a scalar rebind or old ACK.
      try await held.open(.existing(storeID: held.storeID))
      let cold = try XCTUnwrap(held.engine)
      let coldConnection = (try await cold.nativeSQLMaintenanceSnapshot()).storage.identity
      XCTAssertEqual(coldConnection.ownerID, oldConnection.ownerID)
      XCTAssertEqual(coldConnection.storeID, oldConnection.storeID)
      XCTAssertNotEqual(coldConnection.engineIncarnation, oldConnection.engineIncarnation)
      XCTAssertNotEqual(coldConnection.connectionIncarnation, oldConnection.connectionIncarnation)
      let loaded = try await self.settings(held)
      XCTAssertEqual(loaded.head.ownerID, before.ownerID); XCTAssertEqual(loaded.head.storeID, before.storeID)
      XCTAssertEqual(loaded.head.generation, before.generation + 1)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      XCTAssertEqual(try encoder.encode(loaded.settings), try encoder.encode(settingsValue))
      let after = engine.custodySnapshot
      let stillFailed = try XCTUnwrap(after.items.first { $0.id == failure.lease.id })
      XCTAssertTrue(after.closing); XCTAssertEqual(after.jobs, 0)
      XCTAssertEqual(after.items.map(\.id), failedSnapshot.items.map(\.id))
      XCTAssertEqual(after.reservedPayloadBytes, failedSnapshot.reservedPayloadBytes)
      XCTAssertEqual(after.metadataEnvelopeBytes, failedSnapshot.metadataEnvelopeBytes)
      XCTAssertEqual(stillFailed.phase, failedItem.phase); XCTAssertEqual(stillFailed.claims, failedItem.claims)
      XCTAssertEqual(stillFailed.payloadReservation, failedItem.payloadReservation)
      XCTAssertEqual(stillFailed.sqlOperationID, failedItem.sqlOperationID)
      XCTAssertEqual(stillFailed.sqlReceivingJoined, false)
      XCTAssertTrue(held.leases.contains(failure.lease)); XCTAssertEqual(held.originals.count, 1)
      do {
        try await cold.abandonJoinedRootOutput(failure.lease)
        throw BoomError.invalid("Fresh cold authority consumed another engine's unresolved lease.")
      } catch BoomError.denied { }
      // The cold read output actually joined independently. Close ONLY its real
      // empty owner; the old receiving intent and failed evidence remain held.
      XCTAssertTrue(cold.custodySnapshot.items.isEmpty)
      let maintenance = try await cold.joinScheduledWALMaintenance()
      if let failure = maintenance.failure { throw failure }
      try await cold.close()
      held.engine = nil; held.publisher = nil; held.identity = nil; held.closed = true
    }
  }
}
#endif
