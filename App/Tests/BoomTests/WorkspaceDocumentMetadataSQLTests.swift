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
private struct DocumentMetadataSQLCleanupFailure: Error {
  let original: Error
  let cleanup: Error
}

@MainActor private final class DocumentMetadataSQLFixture {
  let root: URL
  let store: WorkspaceStore?
  let vault: Vault
  let ownerID = UUID(), storeID = UUID()
  var engine: PagedTextEngineAdapter?
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

@MainActor final class WorkspaceDocumentMetadataSQLTests: XCTestCase {
  private static var retained: DocumentMetadataSQLFixture?
  private static var retainedRoot: URL?
  private func fixture(_ name: String, faultNamespace: Bool = false,
    _ body: @MainActor (DocumentMetadataSQLFixture) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["BLOOM_DOCUMENT_METADATA_SQL_PUBLIC_CASE"] == name else {
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
    let held = DocumentMetadataSQLFixture(root: root, store: store, vault: vault); Self.retained = held
    do {
      try await body(held)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("A substantive assertion failed; originals/owners/files retained.") }
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
  private func emptySeed(_ held: DocumentMetadataSQLFixture) async throws -> PagedWorkspaceHead {
    try await held.open(.fresh(storeID: held.storeID))
    let engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
    let input = try await Task.detached { try WorkspaceMetadataInput(settings: WorkspaceSettings(), initialDocuments: []) }.value
    let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: nil)
    try held.keep(saved.lease)
    let head = try await engine.finishWorkspaceMetadataPublication(saved, publisher: publisher)
    try await held.release(saved.lease)
    return head
  }
  private func settings(_ held: DocumentMetadataSQLFixture) async throws -> WorkspaceSettingsRead {
    let value = try await XCTUnwrap(held.engine).loadWorkspaceSettingsRetaining(XCTUnwrap(held.publisher))
    try held.keep(value.lease)
    let read = value.value; try await held.release(value.lease); return read
  }

  private func imported(_ held: DocumentMetadataSQLFixture, text: String = "public e\u{301}🙂\n",
    title: String = "Initial") async throws -> WorkspaceDocumentMutation {
    let engine = try XCTUnwrap(held.engine), id = UUID(), root = held.root
    let file = try await Task.detached {
      let path = root.appendingPathComponent("source-" + id.uuidString + ".utf8")
      try Data(text.utf8).write(to: path, options: .withoutOverwriting)
      return try FileHandle(forReadingFrom: path)
    }.value
    held.file = file; held.fileCloseAttempted = false
    let imported = try await engine.importUTF8Retaining(documentID: id, from: file)
    try held.keep(imported.lease); try await held.closeFile()
    let initialized = try await engine.initialNativeRecordRetaining(PagedDocumentDescriptor(id: id,
      title: title, revision: imported.value.revision))
    try held.keep(initialized.lease)
    return try await Task.detached { try WorkspaceDocumentMutation.inserting(imported,
      initialized: initialized, path: "source-" + id.uuidString + ".utf8") }.value
  }
  private func receive(_ output: PagedTextCustodiedValue<WorkspaceMetadataPublication>,
    input: WorkspaceMetadataInput, held: DocumentMetadataSQLFixture) async throws -> PagedWorkspaceHead {
    let engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
    let head = try await engine.finishWorkspaceMetadataPublication(output, publisher: publisher)
    let repeated = try await engine.finishWorkspaceMetadataPublication(output, publisher: publisher)
    XCTAssertEqual(repeated, head)
    for lease in input.producerLeases {
      XCTAssertFalse(engine.custodySnapshot.items.contains { $0.id == lease.id })
      held.leases.removeAll { $0 == lease } // actual receiving transfer, not synthetic abandonment
    }
    try await held.release(output.lease); return head
  }
  private func archive(_ id: UUID, held: DocumentMetadataSQLFixture) async throws -> WorkspaceDocumentArchive {
    let engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
    let actual = try await engine.loadWorkspaceDocumentArchiveRetaining(publisher, documentID: id)
    try held.keep(actual.lease)
    let result = try XCTUnwrap(actual.value).archive
    try await held.release(actual.lease); return result
  }
  private func input(_ mutation: WorkspaceDocumentMutation, settings: WorkspaceSettings? = nil,
    entities: [WorkspaceEntityInput] = []) async throws -> WorkspaceMetadataInput {
    try await Task.detached { try WorkspaceMetadataInput(settings: settings, entities: entities, documentChanges: [mutation]) }.value
  }

  func testActualInsertPinsBothProducersUntilReceivingAndNativeRetirement() async throws {
    try await fixture("testActualInsertPinsBothProducersUntilReceivingAndNativeRetirement") { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held), record = try XCTUnwrap(mutation.after)
      var selected = WorkspaceSettings(); selected.selectedDocument = record.document.id
      let input = try await self.input(mutation, settings: selected)
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
      try held.keep(saved.lease); XCTAssertEqual(saved.value.documents.count, 1)
      for lease in mutation.producerLeases {
        XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == lease.id && $0.producerJoined })
        var refused = false
        do { try await engine.abandonJoinedRootOutput(lease) } catch { refused = true; try held.preserve(error) }
        XCTAssertTrue(refused)
      }
      var openingRefused = false
      do {
        let unexpected = try await engine.makeNativeStorage(publisher, expected: record)
        held.backend = unexpected; held.backendRecord = record
      } catch { openingRefused = true; try held.preserve(error) }
      XCTAssertTrue(openingRefused)
      let after = try await self.receive(saved, input: input, held: held)
      let original = try await self.archive(record.document.id, held: held)
      XCTAssertEqual(original.original, mutation.original); XCTAssertNil(original.retainedRecord)
      let backend = try await engine.makeNativeStorage(publisher, expected: record), session = UUID()
      held.backend = backend; held.backendRecord = record; held.backendSession = session
      let opening = try await backend.opening(sessionID: session)
      XCTAssertEqual(opening.record, record)
      let rename = try await Task.detached { try WorkspaceDocumentMutation.renaming(record, title: "Renamed") }.value
      let renameInput = try await self.input(rename)
      var liveRefused = false
      do {
        let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: renameInput, expectedHead: after)
        try held.keep(unexpected.lease)
      } catch { liveRefused = true; try held.preserve(error) }
      XCTAssertTrue(liveRefused)
      let unchanged = try await self.settings(held); XCTAssertEqual(unchanged.head, after)
      try await backend.detachJoinedController(sessionID: session, sequence: 0, record: record)
      held.backend = nil; held.backendSession = nil; held.backendRecord = nil
      let renamed = try await engine.publishWorkspaceMetadataRetaining(publisher, input: renameInput, expectedHead: after)
      try held.keep(renamed.lease); _ = try await self.receive(renamed, input: renameInput, held: held)
      let exact = try XCTUnwrap(renamed.value.documents.first?.after)
      XCTAssertTrue(exact.document.title.utf8.elementsEqual("Renamed".utf8))
      XCTAssertEqual(exact.document.revision, record.document.revision)
      XCTAssertEqual(exact.historyPage, record.historyPage); XCTAssertEqual(exact.historyGeneration, record.historyGeneration)
    }
  }

  func testRenameTrashKeepsOriginalDraftAndCapturedChatAcrossEncryptedReopen() async throws {
    try await fixture("testRenameTrashKeepsOriginalDraftAndCapturedChatAcrossEncryptedReopen") { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held, title: "e\u{301}"), record = try XCTUnwrap(mutation.after)
      let chat = ChatRecord(id: UUID(), title: "Captured", attachedDocumentID: record.document.id)
      let draft = ComposerDraft(owner: ComposerOwner(kind: .document, id: record.document.id), text: "retained unsent 🙂", attachments: [], authoredRole: .user)
      let entities = try await Task.detached { [try WorkspaceEntityInput.chat(chat, ordinal: 0), try WorkspaceEntityInput.draft(draft)] }.value
      var selected = WorkspaceSettings(); selected.selectedDocument = record.document.id; selected.selectedChat = chat.id
      selected.writingExampleIDs = [record.document.id]
      let input = try await self.input(mutation, settings: selected, entities: entities)
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
      try held.keep(saved.lease); let after = try await self.receive(saved, input: input, held: held)
      let rename = try await Task.detached { try WorkspaceDocumentMutation.renaming(record, title: "é") }.value
      let renameInput = try await self.input(rename)
      let renamed = try await engine.publishWorkspaceMetadataRetaining(publisher, input: renameInput, expectedHead: after)
      try held.keep(renamed.lease); let renamedHead = try await self.receive(renamed, input: renameInput, held: held)
      let renamedRecord = try XCTUnwrap(renamed.value.documents.first?.after)
      XCTAssertTrue(renamedRecord.document.title.utf8.elementsEqual("é".utf8))
      var removedSelection = selected; removedSelection.selectedDocument = nil; removedSelection.writingExampleIDs = []
      let trash = try await Task.detached { try WorkspaceDocumentMutation.trashing(renamedRecord) }.value
      let trashInput = try await self.input(trash, settings: removedSelection)
      let trashed = try await engine.publishWorkspaceMetadataRetaining(publisher, input: trashInput, expectedHead: renamedHead)
      try held.keep(trashed.lease); let head = try await self.receive(trashed, input: trashInput, held: held)
      let retained = try await self.archive(record.document.id, held: held)
      XCTAssertEqual(retained.original, mutation.original); XCTAssertEqual(retained.retainedRecord, renamedRecord)
      let catalog = try await engine.loadDocumentIndexPageRetaining(publisher, afterOrdinal: -1, expectedHead: head)
      try held.keep(catalog.lease); XCTAssertTrue(catalog.value.documents.isEmpty); try await held.release(catalog.lease)
      let chats = try await engine.loadWorkspaceEntityPageRetaining(publisher, kind: .chat, parentID: Vault.workspaceID)
      try held.keep(chats.lease); XCTAssertEqual(chats.value.entities.first?.header.chatIndex?.id, chat.id); try await held.release(chats.lease)
      let keptDraft = try await XCTUnwrap(held.store).loadPagedComposerDraft(draft.owner, engine: engine, publisher: publisher)
      XCTAssertEqual(keptDraft?.text, draft.text)
      try await held.closeSource(); try await held.open(.existing(storeID: held.storeID))
      let reopened = try await self.archive(record.document.id, held: held)
      XCTAssertEqual(reopened, retained)
      let opening = try await XCTUnwrap(held.store).loadPagedMetadataOpening(engine: XCTUnwrap(held.engine), publisher: XCTUnwrap(held.publisher))
      XCTAssertTrue(opening.documents.isEmpty); XCTAssertNil(opening.selectedDocument); XCTAssertEqual(opening.head, head)
      XCTAssertEqual(opening.chats.first?.header.chatIndex?.id, chat.id)
    }
  }

  func testStaleFullHeadDoesNotRebaseOrChangeTitleAndConnectionRemainsUsable() async throws {
    try await fixture("testStaleFullHeadDoesNotRebaseOrChangeTitleAndConnectionRemainsUsable") { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held), record = try XCTUnwrap(mutation.after)
      let seed = try await self.input(mutation)
      let inserted = try await engine.publishWorkspaceMetadataRetaining(publisher, input: seed, expectedHead: before)
      try held.keep(inserted.lease); let current = try await self.receive(inserted, input: seed, held: held)
      var changed = WorkspaceSettings(); changed.showLibrary = false
      let changedSettings = changed
      let settingsInput = try await Task.detached { try WorkspaceMetadataInput(settings: changedSettings) }.value
      let metadata = try await engine.publishWorkspaceMetadataRetaining(publisher, input: settingsInput, expectedHead: current)
      try held.keep(metadata.lease); let actualBefore = try await self.receive(metadata, input: settingsInput, held: held)
      let rename = try await Task.detached { try WorkspaceDocumentMutation.renaming(record, title: "Later") }.value
      let input = try await self.input(rename)
      var refused: PagedTextCustodyFailure?
      do { let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: current); try held.keep(unexpected.lease) }
      catch let failure as PagedTextCustodyFailure { refused = failure; try held.keep(failure.lease); try held.preserve(failure.original) }
      let failure = try XCTUnwrap(refused)
      let resolved = try await engine.resolveSQLiteOutputRetaining(failure.lease, publisher: publisher)
      guard case .before(let execution) = resolved.value else { throw BoomError.invalid("Stale full-head input was not checked BEFORE.") }
      XCTAssertEqual(execution.beforeHead, actualBefore)
      let original = try await engine.cancelResolvedWorkspaceBefore(failure.lease, publisher: publisher, execution: execution)
      XCTAssertNotNil(original)
      held.leases.removeAll { $0 == failure.lease }
      let read = try await engine.loadWorkspaceDocumentRetaining(publisher, documentID: record.document.id, expectedHead: actualBefore)
      try held.keep(read.lease); XCTAssertEqual(read.value.record, record); try await held.release(read.lease)
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: actualBefore)
      try held.keep(saved.lease); _ = try await self.receive(saved, input: input, held: held)
    }
  }

  func testCopiedImportChecksumCannotReplaceActualProducerAndEmptySourceIsSupported() async throws {
    try await fixture("testCopiedImportChecksumCannotReplaceActualProducerAndEmptySourceIsSupported") { held in
      let head = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held, text: "", title: "Empty")
      let real = try XCTUnwrap(mutation.imported), initial = try XCTUnwrap(mutation.initialized)
      XCTAssertEqual(real.value.revision.summary.bytes, 0); XCTAssertNil(real.value.revision.root)
      XCTAssertEqual(real.value.wholeTextSha256, Digest.sha256(Data()))
      let forged = PagedTextCustodiedValue(value: PagedTextImportedRevision(revision: real.value.revision,
        wholeTextSha256: String(repeating: "0", count: 64)), lease: real.lease)
      let fake = try await Task.detached { try WorkspaceDocumentMutation.inserting(forged, initialized: initial, path: "empty") }.value
      let input = try await self.input(fake)
      var refused = false
      do { let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: head); try held.keep(unexpected.lease) }
      catch { refused = true; try held.preserve(error) }
      XCTAssertTrue(refused)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == real.lease.id })
      let actualInput = try await self.input(mutation), store = try XCTUnwrap(held.store)
      let output = try await store.savePagedDocumentChangesRetaining([mutation], engine: engine, publisher: publisher, expectedHead: head)
      try held.keep(output.lease)
      let received = try await store.finishPagedMetadataPublication(output, engine: engine, publisher: publisher)
      held.leases.removeAll { $0 == output.lease || actualInput.producerLeases.contains($0) }
      XCTAssertEqual(received, output.value.head)
      XCTAssertTrue(engine.custodySnapshot.items.isEmpty)
    }
  }

  func testInitialUnselectedHistoryCorruptionRefusesReceivingUntilActualRestore() async throws {
    try await fixture("testInitialUnselectedHistoryCorruptionRefusesReceivingUntilActualRestore", faultNamespace: true) { held in
      try await held.open(.fresh(storeID: held.storeID))
      let engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held), record = try XCTUnwrap(mutation.after)
      let input = try await Task.detached { try WorkspaceMetadataInput(settings: WorkspaceSettings(), initialDocuments: [record]) }.value
      let output = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: nil)
      try held.keep(output.lease); XCTAssertEqual(output.value.documents.first?.after, record)
      let witness = try await engine._publicSQLControlCiphertextWitnessRetaining(identity: XCTUnwrap(held.identity), record: record, target: .historyManifest)
      try held.keep(witness.lease)
      let corrupted = try await engine._publicSQLControlCorruptRetaining(identity: XCTUnwrap(held.identity), witness: witness.value)
      try held.keep(corrupted.lease)
      var refused = false
      do { _ = try await engine.finishWorkspaceMetadataPublication(output, publisher: publisher) }
      catch { refused = true; try held.preserve(error) }
      XCTAssertTrue(refused)
      XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == output.lease.id && $0.sqlReceivingJoined == false })
      let restored = try await engine._publicSQLControlRestoreRetaining(identity: XCTUnwrap(held.identity), witness: witness.value)
      try held.keep(restored.lease)
      _ = try await self.receive(output, input: input, held: held)
      try await held.release(restored.lease); try await held.release(corrupted.lease); try await held.release(witness.lease)
      for lease in mutation.producerLeases {
        try await engine.transferJoinedRootToHead(lease, publisher: publisher, expected: record)
        held.leases.removeAll { $0 == lease }
      }
    }
  }

  func testActualInsertCommitNameFailureKeepsBothInputsThroughCheckpointAndReceiving() async throws {
    try await fixture("testActualInsertCommitNameFailureKeepsBothInputsThroughCheckpointAndReceiving", faultNamespace: true) { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held), input = try await self.input(mutation)
      try await engine._publicSQLControlArmCommitFault(identity: XCTUnwrap(held.identity), fault: .moveDatabaseName)
      var refused: PagedTextCustodyFailure?
      do { let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before); try held.keep(unexpected.lease) }
      catch let failure as PagedTextCustodyFailure { refused = failure; try held.keep(failure.lease); try held.preserve(failure.original) }
      let failure = try XCTUnwrap(refused)
      for lease in input.producerLeases { XCTAssertTrue(engine.custodySnapshot.items.contains { $0.id == lease.id }) }
      try await engine._publicSQLControlRestoreDatabaseName(identity: XCTUnwrap(held.identity))
      let actual = try await engine.resolveSQLiteOutputRetaining(failure.lease, publisher: publisher)
      guard case .metadata(let publication) = actual.value else { throw BoomError.invalid("Genuine checkpoint did not preserve the original insert output.") }
      XCTAssertEqual(publication.documents.first?.after, mutation.after)
      let fenced = try await engine.nativeSQLMaintenanceSnapshot()
      XCTAssertEqual(fenced.storage.failedOperationID, input.inputID); XCTAssertEqual(fenced.storage.lastCheckpoint?.code, 0)
      let output = PagedTextCustodiedValue(value: publication, lease: actual.lease)
      _ = try await self.receive(output, input: input, held: held)
      let released = try await engine.nativeSQLMaintenanceSnapshot(); XCTAssertNil(released.storage.failedOperationID)
      let original = try await self.archive(mutation.documentID, held: held); XCTAssertEqual(original.original, mutation.original)
    }
  }

  func testStaleFullRecordCannotRenameNewerNativeHistoryAtCurrentHead() async throws {
    try await fixture("testStaleFullRecordCannotRenameNewerNativeHistoryAtCurrentHead") { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held), original = try XCTUnwrap(mutation.after), seed = try await self.input(mutation)
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: seed, expectedHead: before)
      try held.keep(saved.lease); _ = try await self.receive(saved, input: seed, held: held)
      let backend = try await engine.makeNativeStorage(publisher, expected: original), session = UUID()
      held.backend = backend; held.backendRecord = original; held.backendSession = session
      let opening = try await backend.opening(sessionID: session)
      var working = try PagedWorkingWindow(window: opening.window, rootRecord: opening.record, sessionID: session)
      let selection = try working.selection(NSRange(location: 0, length: 0))
      XCTAssertTrue(try working.replace(NSRange(location: 0, length: 0), with: "later🙂", groupID: UUID(), beforeSelection: selection))
      let batch = try XCTUnwrap(working.takeCommitBatch()), ack = try await backend.commit(batch)
      held.backendRecord = ack.sealedRootRecord; held.backendSequence = ack.lastSequence
      try working.acknowledge(ack); try await backend.finishCommitInstallation(ack)
      try await backend.detachJoinedController(sessionID: session, sequence: ack.lastSequence, record: ack.sealedRootRecord)
      held.backend = nil; held.backendRecord = nil; held.backendSession = nil; held.backendSequence = 0
      let current = try await self.settings(held)
      let stale = try await Task.detached { try WorkspaceDocumentMutation.renaming(original, title: "Must refuse") }.value
      let input = try await self.input(stale)
      var refused: PagedTextCustodyFailure?
      do { let unexpected = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: current.head); try held.keep(unexpected.lease) }
      catch let failure as PagedTextCustodyFailure { refused = failure; try held.keep(failure.lease); try held.preserve(failure.original) }
      let failure = try XCTUnwrap(refused), resolved = try await engine.resolveSQLiteOutputRetaining(failure.lease, publisher: publisher)
      guard case .before(let actual) = resolved.value else { throw BoomError.invalid("Stale complete record did not retain its actual rollback.") }
      _ = try await engine.cancelResolvedWorkspaceBefore(failure.lease, publisher: publisher, execution: actual)
      held.leases.removeAll { $0 == failure.lease }
      let unchanged = try await engine.loadWorkspaceDocumentRetaining(publisher, documentID: original.document.id, expectedHead: current.head)
      try held.keep(unchanged.lease); XCTAssertEqual(unchanged.value.record, ack.sealedRootRecord); try await held.release(unchanged.lease)
      let rename = try await Task.detached { try WorkspaceDocumentMutation.renaming(ack.sealedRootRecord, title: "Current") }.value
      let correct = try await self.input(rename)
      let renamed = try await engine.publishWorkspaceMetadataRetaining(publisher, input: correct, expectedHead: current.head)
      try held.keep(renamed.lease); _ = try await self.receive(renamed, input: correct, held: held)
      let record = try XCTUnwrap(renamed.value.documents.first?.after)
      XCTAssertEqual(record.historyPage, ack.sealedRootRecord.historyPage)
      XCTAssertEqual(record.historyGeneration, ack.sealedRootRecord.historyGeneration)
      let reopened = try await engine.makeNativeStorage(publisher, expected: record), nextSession = UUID()
      held.backend = reopened; held.backendRecord = record; held.backendSession = nextSession
      let canonical = try await reopened.opening(sessionID: nextSession)
      XCTAssertEqual(canonical.history.undo.count, 1)
      XCTAssertEqual(canonical.history.undo.first?.revision, original.document.revision)
    }
  }

  func testDocumentInputBoundsRefuseBeforePublicationAndKeepActualProducers() async throws {
    try await fixture("testDocumentInputBoundsRefuseBeforePublicationAndKeepActualProducers") { held in
      let before = try await self.emptySeed(held), engine = try XCTUnwrap(held.engine), publisher = try XCTUnwrap(held.publisher)
      let mutation = try await self.imported(held), record = try XCTUnwrap(mutation.after)
      let refused = try await Task.detached { () -> [Bool] in
        var rejected: [Bool] = []
        do { _ = try WorkspaceMetadataInput(documentChanges: [mutation, mutation]); rejected.append(false) } catch { rejected.append(true) }
        do { _ = try WorkspaceMetadataInput(settings: WorkspaceSettings(), initialDocuments: Array(repeating: record, count: 8)); rejected.append(false) } catch { rejected.append(true) }
        do { _ = try WorkspaceDocumentMutation.renaming(record, title: String(repeating: "x", count: 1_025)); rejected.append(false) } catch { rejected.append(true) }
        return rejected
      }.value
      XCTAssertEqual(refused, [true, true, true])
      XCTAssertTrue(mutation.producerLeases.allSatisfy { lease in engine.custodySnapshot.items.contains { $0.id == lease.id } })
      let input = try await self.input(mutation)
      let saved = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: before)
      try held.keep(saved.lease); _ = try await self.receive(saved, input: input, held: held)
    }
  }

  func testStreamingProjectionMatchesCanonicalEscapedUnicodeArray() async throws {
    try await fixture("testStreamingProjectionMatchesCanonicalEscapedUnicodeArray") { held in
      _ = try await self.emptySeed(held)
      let values = [DocumentIndex(id: UUID(), title: "e\u{301}🙂\"\n/"), DocumentIndex(id: UUID(), title: "é")]
      let encoded = try await Task.detached { () throws -> (String, String) in
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (Digest.sha256(try encoder.encode(values)), try PagedWorkspaceProjection.digest(values))
      }.value
      XCTAssertEqual(encoded.0, encoded.1)
      let empty = try await Task.detached { try PagedWorkspaceProjection.digest([]) }.value
      XCTAssertEqual(empty, Digest.sha256(Data("[]".utf8)))
    }
  }
}
#endif
