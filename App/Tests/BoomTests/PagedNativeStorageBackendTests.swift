import AppKit
import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// SOURCE ONLY: real SQL bindings, isolated refusal case and shared maintenance
// barrier are not executable qualification without an exact reviewed candidate.

/// A scheduling seam around the real backend, never a synthetic durable ack.
/// Every result below comes from the Rust engine and coherent encrypted owner.
private actor PagedRealNativeControlRoute: PagedNativeCommitInstallationStorage {
  struct JoinedPrefix: Sendable { let sessionID: UUID; let sequence: UInt64; let record: PagedDocumentRootRecord }
  private(set) var latestJoinedPrefix: JoinedPrefix?
  private var activeFinishes = 0
  private var activeWindows = 0
  private var admissionClosed = false
  struct Trace: Sendable {
    let sessionID: UUID
    let firstSequence: UInt64
    let lastSequence: UInt64
    let groupIDs: [UUID]
  }
  private let backend: PagedNativeStorageBackend
  private(set) var traces: [Trace] = []
  private var holdCommit = false
  private var heldBatch: PagedNativeCommitBatch?
  private var commitRelease: CheckedContinuation<Void, Never>?
  private var commitWaiter: (id: UUID, continuation: CheckedContinuation<PagedNativeCommitBatch, Error>)?
  private var activeCommits = 0
  private var commitJoin: CheckedContinuation<Void, Never>?
  private var heldAnchors = Set<UInt64>()
  private var windows: [UInt64: (PagedTextWindow, CheckedContinuation<PagedTextWindow, Never>)] = [:]
  private var windowFailures: [UInt64: Error] = [:]
  private var windowWaiters: [UInt64: CheckedContinuation<Void, Error>] = [:]

  init(_ backend: PagedNativeStorageBackend) { self.backend = backend }
  func holdNextCommit() {
    precondition(commitRelease == nil && !holdCommit)
    heldBatch = nil; holdCommit = true
  }
  func waitForHeldCommit() async throws -> PagedNativeCommitBatch {
    try Task.checkCancellation()
    if let heldBatch { return heldBatch }
    let id = UUID()
    let batch: PagedNativeCommitBatch = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        precondition(commitWaiter == nil)
        commitWaiter = (id, continuation)
      }
    } onCancel: {
      Task { await self.cancelCommitWaiter(id) }
    }
    try Task.checkCancellation()
    return batch
  }
  private func cancelCommitWaiter(_ id: UUID) {
    guard let waiter = commitWaiter, waiter.id == id else { return }
    commitWaiter = nil; waiter.continuation.resume(throwing: CancellationError())
  }
  func releaseCommit() {
    let release = commitRelease; commitRelease = nil; release?.resume()
  }
  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    guard !admissionClosed, activeCommits + activeFinishes + activeWindows < 8, traces.count < 128 else { throw BoomError.budget("Actual public backend route is closing or exceeds its call evidence bound.") }
    activeCommits += 1
    defer {
      activeCommits -= 1
      if activeCommits + activeFinishes + activeWindows == 0 {
        let join = commitJoin; commitJoin = nil; join?.resume()
      }
    }
    if holdCommit {
      holdCommit = false
      await withCheckedContinuation { continuation in
        heldBatch = batch; commitRelease = continuation
        let waiter = commitWaiter; commitWaiter = nil; waiter?.continuation.resume(returning: batch)
      }
    }
    let acknowledgement = try await backend.commit(batch)
    latestJoinedPrefix = JoinedPrefix(sessionID: acknowledgement.sessionID, sequence: acknowledgement.lastSequence, record: acknowledgement.sealedRootRecord)
    traces.append(Trace(sessionID: batch.sessionID, firstSequence: batch.firstSequence,
      lastSequence: batch.lastSequence, groupIDs: batch.groupCheckpoints.map(\.groupID)))
    return acknowledgement
  }
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    guard !admissionClosed, activeCommits + activeFinishes + activeWindows < 8 else { throw BoomError.stale("Actual public completion route is joining.") }
    activeFinishes += 1
    defer {
      activeFinishes -= 1
      if activeCommits + activeFinishes + activeWindows == 0 {
        let joined = commitJoin; commitJoin = nil; joined?.resume()
      }
    }
    try await backend.finishCommitInstallation(acknowledgement)
  }
  func closeAdmissionAfterRelease() async {
    releaseAll()
    await joinCommits()
    admissionClosed = true
  }
  func holdWindows(at anchors: [UInt64]) {
    precondition(anchors.count <= 2 && windows.isEmpty && windowWaiters.isEmpty)
    heldAnchors = Set(anchors); windowFailures.removeAll()
  }
  func waitForHeldWindow(at anchor: UInt64) async throws {
    if windows[anchor] != nil { return }
    if let error = windowFailures[anchor] { throw error }
    try await withCheckedThrowingContinuation { windowWaiters[anchor] = $0 }
  }
  func releaseWindow(at anchor: UInt64) {
    if let (window, continuation) = windows.removeValue(forKey: anchor) {
      continuation.resume(returning: window)
    }
  }
  func releaseAll() {
    holdCommit = false; heldBatch = nil
    let waiter = commitWaiter; commitWaiter = nil
    waiter?.continuation.resume(throwing: CancellationError())
    releaseCommit()
    for (window, continuation) in windows.values { continuation.resume(returning: window) }
    windows.removeAll(); heldAnchors.removeAll()
    for waiter in windowWaiters.values { waiter.resume(throwing: CancellationError()) }
    windowWaiters.removeAll()
  }
  func joinCommits() async {
    guard activeCommits + activeFinishes + activeWindows > 0 else { return }
    await withCheckedContinuation {
      precondition(commitJoin == nil)
      commitJoin = $0
    }
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64,
    maximumBytes: Int) async throws -> PagedTextWindow {
    guard !admissionClosed, activeCommits + activeFinishes + activeWindows < 8 else { throw BoomError.stale("Actual public window route is joining.") }
    activeWindows += 1
    defer {
      activeWindows -= 1
      if activeCommits + activeFinishes + activeWindows == 0 {
        let joined = commitJoin; commitJoin = nil; joined?.resume()
      }
    }
    let result: PagedTextWindow
    do { result = try await backend.window(expected: expected, utf16Anchor: utf16Anchor, maximumBytes: maximumBytes) }
    catch {
      windowFailures[utf16Anchor] = error
      let waiter = windowWaiters.removeValue(forKey: utf16Anchor); waiter?.resume(throwing: error)
      throw error
    }
    guard heldAnchors.contains(utf16Anchor) else { return result }
    return await withCheckedContinuation { continuation in
      precondition(windows[utf16Anchor] == nil && windows.count < 2)
      windows[utf16Anchor] = (result, continuation)
      let waiter = windowWaiters.removeValue(forKey: utf16Anchor); waiter?.resume()
    }
  }
}

private struct PagedRealNativeFixture: Sendable {
  let root: URL
  let key: SymmetricKey
  let owner: UUID
  let storeID: UUID
  let outputs: PagedRealNativeFixtureOutputs
  let vault: Vault
  let engine: PagedTextEngineAdapter
  let publisher: PagedWorkspacePublisher
  let records: [PagedDocumentRootRecord]
  let snapshot: PagedWorkspaceSnapshot
}
private struct PagedRealNativeSaved: Sendable {
  let root: URL
  let key: SymmetricKey
  let owner: UUID
  let storeID: UUID
  let snapshot: PagedWorkspaceSnapshot
}

/// Real receiver for the fixture's already joined Engine outputs/controllers.
/// It has no ACK factory, validator, storage queue or uncertain-commit repair.
@MainActor private final class PagedRealNativeFixtureOutputs {
  let root: URL
  let engine: PagedTextEngineAdapter
  let identity: PagedSQLPublicControlIdentity
  private var reads: [PagedTextRootLease] = []
  private var controllers: [(join: @MainActor () async -> Void, detach: @MainActor () async throws -> Void)] = []
  private(set) var formerForeignPublishers: [PagedWorkspacePublisher] = []
  private var formerForeignRoots: [URL] = []
  private let maintenance: PagedSQLNativeFixtureMaintenance
  private(set) var terminalSnapshot: PagedTextSQLMaintenanceSnapshot?

  init(root: URL, engine: PagedTextEngineAdapter, identity: PagedSQLPublicControlIdentity) {
    self.root = root; self.engine = engine; self.identity = identity
    maintenance = PagedSQLNativeFixtureMaintenance(engine: engine)
  }
  func admitRead() throws {
    guard reads.count < 32 else { throw BoomError.budget("Public backend read custody exceeds its unchanged bound.") }
  }
  func retain(_ lease: PagedTextRootLease) { reads.append(lease) }
  func retainController(join: @escaping @MainActor () async -> Void,
    detach: @escaping @MainActor () async throws -> Void) throws {
    guard controllers.count < 4 else { throw BoomError.budget("Public backend controller ownership exceeds four real routes.") }
    controllers.append((join, detach))
  }
  func retainFormerForeign(_ publishers: [(root: URL, publisher: PagedWorkspacePublisher)]) throws {
    guard formerForeignPublishers.isEmpty, publishers.count <= 2 else { throw BoomError.budget("Former public publisher witnesses exceed their two-lifetime admission.") }
    formerForeignPublishers = publishers.map(\.publisher)
    formerForeignRoots = publishers.map(\.root)
  }
  func joinFailedCalls() async { for controller in controllers { await controller.join() } }
  func closeJoined() async throws {
    await joinFailedCalls()
    for controller in controllers { try await controller.detach() }
    for read in reads { try await engine.abandonJoinedRootOutput(read) }
    reads.removeAll()
    try await maintenance.drainAfterJoinedNativeCalls()
    try await engine.close()
  }
  func retainExpectedNativeRefusal() async throws {
    await joinFailedCalls()
    let actual = engine.custodySnapshot
    guard actual.jobs == 0 else { throw BoomError.stale("Terminal native refusal still owns an actual source job.") }
    terminalSnapshot = try await engine.nativeSQLMaintenanceSnapshot()
    // Read only: accepted native input/controller/root custody remains held.
    // No detach, maintenance, receipt disposition or Engine close is attempted.
  }
  func removeSuccessfullyClosedForeignFiles() async throws {
    for root in formerForeignRoots {
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
    }
  }
}

/// Authored integration controls: public inputs/test keys only, no installed
/// app or performance acceptance. The controlled waits retain bounded real
/// results; they never replace the engine, ciphertext, history or publisher.
@MainActor final class PagedNativeStorageBackendTests: XCTestCase {
  private struct Controller {
    let session: PagedNativeSession
    let route: PagedRealNativeControlRoute
  }
  private enum FailureKind { case stale, denied }
  private var observedRefusals: [Error] = []

  private static var retainedRoot: URL?
  private static var retainedOpening: PagedTextEngineAdapter?
  private static var retainedOutputs: PagedRealNativeFixtureOutputs?
  private static var retainedFormerRoots: [URL] = []
  private static var retainedFormerPublishers: [(root: URL, publisher: PagedWorkspacePublisher)] = []
  private static let terminalCase = "testRealFullRecordCASRefusesStaleHistoryEvenWhenSourceRootIsUnchanged"

  private func scratchRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("public-native-backend-" + UUID().uuidString)
  }
  private func admitFreshControl(_ root: URL) throws {
    guard Self.retainedRoot == nil, Self.retainedOpening == nil, Self.retainedOutputs == nil else {
      throw BoomError.denied("A prior failed native SQL fixture still owns this process.")
    }
    Self.retainedRoot = root
    print("Public backend SQL fixture: \(root.path)")
  }
  private func using<T: Sendable>(_ fixture: PagedRealNativeFixture, terminal: Bool = false,
    _ body: @MainActor (PagedRealNativeFixture) async throws -> T) async throws -> T {
    let failures = testRun?.failureCount ?? 0
    Self.retainedOutputs = fixture.outputs
    do {
      let result = try await body(fixture)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Public backend SQL assertions failed.") }
      if terminal {
        try await fixture.outputs.retainExpectedNativeRefusal()
        print("Public expected stale native input remains owned until the nominated disposable process exits: \(fixture.root.path)")
        return result
      }
      try await fixture.outputs.closeJoined()
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Public backend actual joins recorded failed assertions.") }
      try await fixture.outputs.removeSuccessfullyClosedForeignFiles()
      Self.retainedOutputs = nil; Self.retainedOpening = nil; Self.retainedRoot = nil; Self.retainedFormerPublishers.removeAll(); Self.retainedFormerRoots.removeAll()
      return result
    } catch {
      let original = error
      await fixture.outputs.joinFailedCalls()
      XCTFail("Public backend SQL/native failure and its exact owners retained at \(fixture.root.path): \(original)")
      throw original
    }
  }
  private func withWorkspace<T: Sendable>(_ source: [String], terminalCase: String? = nil,
    formerForeignPublishers: Bool = false,
    _ body: @MainActor (PagedRealNativeFixture) async throws -> T) async throws -> T {
    if let terminalCase {
      guard terminalCase == Self.terminalCase,
        ProcessInfo.processInfo.environment["BLOOM_PAGED_BACKEND_ISOLATED_CASE"] == terminalCase else {
        throw BoomError.denied("Stale accepted native input requires its exact disposable process; no fixture entered.")
      }
    }
    let root = scratchRoot(); try admitFreshControl(root)
    let key = SymmetricKey(data: Data(repeating: 0x73, count: 32)), owner = UUID(), storeID = UUID()
    // Rust has one Engine slot per process. These genuine publisher objects
    // are created and their actual Engines CLOSED before the primary opens.
    // They test former-incarnation rejection, not live concurrent authority.
    var former: [(root: URL, publisher: PagedWorkspacePublisher)] = []
    if formerForeignPublishers {
      for index in 0..<2 {
        let foreignRoot = scratchRoot(), foreignOwner = index == 0 ? UUID() : owner
        Self.retainedFormerRoots.append(foreignRoot)
        print("Public former publisher fixture: \(foreignRoot.path)")
        let foreignEngine = try await Task.detached {
          let vault = try Vault(root: foreignRoot, testKey: key)
          return try await PagedTextEngineAdapter.create(vault: vault, ownerID: foreignOwner,
            sqliteOpening: .fresh(storeID: UUID()))
        }.value
        Self.retainedOpening = foreignEngine
        let publisher = try await foreignEngine.makeWorkspacePublisher()
        Self.retainedFormerPublishers.append((foreignRoot, publisher))
        try await foreignEngine.close() // Actual Rust/SQL close joins before next factory entry.
        former.append((foreignRoot, publisher))
        Self.retainedOpening = nil
      }
    }
    let opened = try await Task.detached {
      let vault = try Vault(root: root, testKey: key)
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: .fresh(storeID: storeID))
      return (key: key, owner: owner, storeID: storeID, vault: vault, engine: engine)
    }.value
    Self.retainedOpening = opened.engine
    let identity = try await opened.engine._publicSQLControlIdentity(expectedVault: opened.vault, expectedStoreID: opened.storeID)
    let outputs = PagedRealNativeFixtureOutputs(root: root, engine: opened.engine, identity: identity)
    Self.retainedOutputs = outputs
    try outputs.retainFormerForeign(former)
    let prepared = try await Task.detached {
      let engine = opened.engine, publisher = try await engine.makeWorkspacePublisher()
      var records: [PagedDocumentRootRecord] = []
      var writers: [(source: PagedTextRootLease, record: PagedTextRootLease)] = []
      guard source.count <= 2 else { throw BoomError.budget("Public backend workspace allows two bounded documents.") }
      for (index, text) in source.enumerated() {
        let id = UUID(), input = root.appendingPathComponent("public-source-\(index).utf8")
        try Data(text.utf8).write(to: input, options: .withoutOverwriting)
        let handle = try FileHandle(forReadingFrom: input)
        let imported: PagedTextCustodiedValue<PagedTextImportedRevision>
        do { imported = try await engine.importUTF8Retaining(documentID: id, from: handle) }
        catch {
          let original = error
          do { try handle.close() } catch { XCTFail("Public input close also failed: \(error)") }
          throw original
        }
        do { try handle.close() } catch { throw PagedTextCustodyFailure(original: error, lease: imported.lease) }
        let initial = try await engine.initialNativeRecordRetaining(PagedDocumentDescriptor(id: id,
          title: "Public \(index)", revision: imported.value.revision))
        records.append(initial.value); writers.append((imported.lease, initial.lease))
      }
      var state = WorkspaceState()
      state.documents = records.map { DocumentIndex(id: $0.document.id, title: $0.document.title) }
      state.selectedDocument = records.first?.document.id
      state.writingExampleIDs = records.reversed().map { $0.document.id }
      if let first = records.first {
        state.composerDrafts = [ComposerDraft(owner: ComposerOwner(kind: .document, id: first.document.id),
          text: "public retained unsent input", attachments: [], authoredRole: nil)]
      }
      let snapshot = try await engine.initializeWorkspaceRetaining(publisher, state: state, documents: records)
      try await engine.finishWorkspacePublication(snapshot, publisher: publisher)
      for (index, writer) in writers.enumerated() {
        try await engine.transferJoinedRootToHead(writer.source, publisher: publisher, expected: records[index])
        try await engine.transferJoinedRootToHead(writer.record, publisher: publisher, expected: records[index])
      }
      try await engine.abandonJoinedRootOutput(snapshot.lease)
      return (publisher: publisher, records: records, snapshot: snapshot.value)
    }.value
    let fixture = PagedRealNativeFixture(root: root, key: opened.key, owner: opened.owner,
      storeID: opened.storeID, outputs: outputs, vault: opened.vault, engine: opened.engine,
      publisher: prepared.publisher, records: prepared.records, snapshot: prepared.snapshot)
    let result = try await using(fixture, terminal: terminalCase != nil, body)
    // Saved values nominate a real later reopen of this exact already-closed
    // store. Every other successful body has finished consuming its files.
    if terminalCase == nil, !(result is PagedRealNativeSaved) {
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
    }
    return result
  }
  private func withReopened<T: Sendable>(_ saved: PagedRealNativeSaved,
    _ body: @MainActor (PagedRealNativeFixture) async throws -> T) async throws -> T {
    try admitFreshControl(saved.root)
    let vault = try await Task.detached { try Vault(root: saved.root, testKey: saved.key) }.value
    let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: saved.owner, sqliteOpening: .existing(storeID: saved.storeID))
    Self.retainedOpening = engine
    let identity = try await engine._publicSQLControlIdentity(expectedVault: vault, expectedStoreID: saved.storeID)
    let outputs = PagedRealNativeFixtureOutputs(root: saved.root, engine: engine, identity: identity)
    Self.retainedOutputs = outputs
    let publisher = try await engine.makeWorkspacePublisher()
    try outputs.admitRead()
    let loaded = try await engine.loadWorkspaceRetaining(publisher); outputs.retain(loaded.lease)
    XCTAssertEqual(loaded.value, saved.snapshot)
    let fixture = PagedRealNativeFixture(root: saved.root, key: saved.key, owner: saved.owner,
      storeID: saved.storeID, outputs: outputs, vault: vault, engine: engine,
      publisher: publisher, records: loaded.value.documents, snapshot: loaded.value)
    let result = try await using(fixture, body)
    let root = saved.root
    try await Task.detached { try FileManager.default.removeItem(at: root) }.value
    return result
  }
  private func controller(_ fixture: PagedRealNativeFixture, document: Int = 0) async throws -> Controller {
    let record = fixture.records[document]
    let backend = try await fixture.engine.makeNativeStorage(fixture.publisher, expected: record)
    let route = PagedRealNativeControlRoute(backend)
    let window = try await route.window(expected: record.document.revision,
      utf16Anchor: 0, maximumBytes: PagedWorkingWindow.targetBytes)
    let session = try PagedNativeSession(window: window, rootRecord: record, storage: route)
    try fixture.outputs.retainController(join: { await route.closeAdmissionAfterRelease() }, detach: {
      _ = try session.windowForNativeInstallation()
      let actual = await route.latestJoinedPrefix
      try await backend.detachJoinedController(sessionID: actual?.sessionID,
        sequence: actual?.sequence ?? 0, record: actual?.record ?? record)
    })
    return Controller(session: session, route: route)
  }
  private func usingHeldCommit(_ owner: Controller, endComposition: @MainActor () -> Void = {},
    _ body: @MainActor () async throws -> Void) async throws {
    await owner.route.holdNextCommit()
    let failure: Error?
    do { try await body(); failure = nil } catch { failure = error }
    // Cleanup owns the gates even when a primitive is refused before capture.
    // Closing composition permits the exact latest session task to join.
    endComposition()
    await owner.route.releaseAll()
    let joinFailure: Error?
    do { _ = try await owner.session.flush(through: owner.session.generation); joinFailure = nil }
    catch { joinFailure = error }
    await owner.route.joinCommits()
    if let failure {
      if let joinFailure { XCTFail("Held-session cleanup flush refused: \(joinFailure)") }
      throw failure
    }
    if let joinFailure { throw joinFailure }
  }
  private func requireAcceptedMutation(_ storage: PagedNativeTextStorage, session: PagedNativeSession) throws {
    if let failure = storage.mutationFailure { throw failure }
    if let failure = session.persistenceFailure { throw failure }
  }
  private func snapshot(_ fixture: PagedRealNativeFixture) async throws -> PagedWorkspaceSnapshot {
    try fixture.outputs.admitRead()
    let output = try await fixture.engine.loadWorkspaceRetaining(fixture.publisher)
    fixture.outputs.retain(output.lease); return output.value
  }
  private func readWorkspaceState(_ fixture: PagedRealNativeFixture) async throws -> WorkspaceState {
    try fixture.outputs.admitRead()
    let output = try await fixture.engine.loadWorkspaceCatalogRetaining(fixture.publisher)
    fixture.outputs.retain(output.lease); return output.value.state
  }
  private func history(_ fixture: PagedRealNativeFixture, _ record: PagedDocumentRootRecord) async throws -> PagedRootHistory {
    try fixture.outputs.admitRead()
    let output = try await fixture.engine._publicSQLControlHistoryRetaining(identity: fixture.outputs.identity, record: record)
    fixture.outputs.retain(output.lease); return output.value
  }
  private func readBytes(_ fixture: PagedRealNativeFixture, _ revision: PagedTextRevision) async throws -> Data {
    try fixture.outputs.admitRead()
    let output = try await fixture.engine.windowRetaining(revision, byteStart: 0, maximumBytes: 65_536)
    fixture.outputs.retain(output.lease)
    XCTAssertEqual(UInt64(output.value.text.utf8.count), revision.summary.bytes)
    return Data(output.value.text.utf8)
  }
  private func foreignPublisher(_ fixture: PagedRealNativeFixture, foreignOwner: Bool) throws -> PagedWorkspacePublisher {
    let publishers = fixture.outputs.formerForeignPublishers
    guard publishers.count == 2 else { throw BoomError.invalid("Actual prior public publisher lifetimes were not nominated.") }
    let publisher = publishers[foreignOwner ? 0 : 1]
    guard foreignOwner ? publisher.ownerID != fixture.owner : publisher.ownerID == fixture.owner else {
      throw BoomError.invalid("Former publisher identity boundary changed.")
    }
    return publisher
  }
  private func expectFailure(_ message: String, expected: FailureKind = .stale,
    _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail(message) }
    catch {
      guard observedRefusals.count < 32 else { XCTFail("Original backend refusal evidence exceeds its fixed bound."); return }
      observedRefusals.append(error)
      switch (pagedSQLUnderlyingRefusal(error) as? BoomError, expected) {
      case (.some(.stale(_)), .stale), (.some(.denied(_)), .denied): break
      default: XCTFail("Unexpected refusal for \(message): \(error)")
      }
    }
  }
  private func saved(_ fixture: PagedRealNativeFixture, _ snapshot: PagedWorkspaceSnapshot) -> PagedRealNativeSaved {
    PagedRealNativeSaved(root: fixture.root, key: fixture.key, owner: fixture.owner, storeID: fixture.storeID, snapshot: snapshot)
  }

  func testRealNativeEditFlushEncryptedReadbackReopenPreservesUnrelatedDocument() async throws {
    let initial = "é public 👩‍💻 source", changed = "e\u{301} public 👩‍💻 source"
    let unrelated = "public unrelated document\r\n🌿", changedOther = "Public unrelated document\r\n🌿"
    let checkpoint = try await withWorkspace([initial, unrelated]) { fixture in
      let owner = try await controller(fixture)
      // This controller captured A before the independent B seal. Its later
      // full-record CAS must preserve B's real nonempty source/history update.
      let other = try await controller(fixture, document: 1)
      let otherStorage = try PagedNativeTextStorage(session: other.session)
      otherStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "P")
      _ = try await other.session.flush(through: 1)
      let afterOther = try await snapshot(fixture)
      let otherRecord = afterOther.documents[1]
      XCTAssertNotEqual(otherRecord, fixture.records[1])
      let storage = try PagedNativeTextStorage(session: owner.session)
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "e\u{301}")
      let revision = try await owner.session.flush(through: owner.session.generation)
      XCTAssertNil(storage.mutationFailure); XCTAssertEqual(Data(storage.string.utf8), Data(changed.utf8))
      let actual = try await snapshot(fixture)
      let record = try XCTUnwrap(actual.documents.first)
      XCTAssertEqual(record.document.revision, revision)
      XCTAssertEqual(actual.documents[1], otherRecord)
      XCTAssertEqual(actual.head.generation, afterOther.head.generation + 1)
      XCTAssertEqual(actual.head.workspace, fixture.snapshot.head.workspace)
      let currentBytes = try await readBytes(fixture, revision)
      let otherBytes = try await readBytes(fixture, actual.documents[1].document.revision)
      XCTAssertEqual(currentBytes, Data(changed.utf8)); XCTAssertEqual(otherBytes, Data(changedOther.utf8))
      let retained = try await history(fixture, record)
      XCTAssertEqual(retained.current, revision); XCTAssertEqual(retained.undo.count, 1)
      return saved(fixture, actual)
    }
    try await withReopened(checkpoint) { fixture in
      let bytes = try await readBytes(fixture, fixture.records[0].document.revision)
      let otherBytes = try await readBytes(fixture, fixture.records[1].document.revision)
      XCTAssertEqual(bytes, Data(changed.utf8)); XCTAssertEqual(otherBytes, Data(changedOther.utf8))
      let workspace = try await readWorkspaceState(fixture)
      XCTAssertEqual(workspace.writingExampleIDs, fixture.records.reversed().map { $0.document.id })
      XCTAssertEqual(workspace.composerDrafts?.first?.text, "public retained unsent input")
      let retained = try await history(fixture, fixture.records[0])
      let originalBytes = try await readBytes(fixture, try XCTUnwrap(retained.undo.first).revision)
      XCTAssertEqual(originalBytes, Data(initial.utf8))
    }
  }

  private func assertWholeIslandDeletionBefore(_ scalar: String) async throws {
    let initial = String(repeating: "a", count: PagedWorkingWindow.targetBytes) + scalar + " suffix"
    let checkpoint = try await withWorkspace([initial]) { fixture in
      let owner = try await controller(fixture)
      let storage = try PagedNativeTextStorage(session: owner.session)
      XCTAssertEqual(storage.string.utf8.count, 16_384)
      storage.replaceCharacters(in: NSRange(location: 0, length: 16_384), with: "")
      let revision = try await owner.session.flush(through: owner.session.generation)
      XCTAssertNil(storage.mutationFailure); XCTAssertEqual(storage.string, "")
      XCTAssertEqual(try owner.session.windowForNativeInstallation().text, "")
      let actual = try await snapshot(fixture)
      XCTAssertEqual(actual.documents[0].document.revision, revision)
      let bytes = try await readBytes(fixture, revision)
      XCTAssertEqual(bytes, Data((scalar + " suffix").utf8))
      let retained = try await history(fixture, actual.documents[0])
      XCTAssertEqual(retained.currentCursor, PagedSealedCursor(byteOffset: 0, utf16Offset: 0))
      return saved(fixture, actual)
    }
    try await withReopened(checkpoint) { fixture in
      let bytes = try await readBytes(fixture, fixture.records[0].document.revision)
      XCTAssertEqual(bytes, Data((scalar + " suffix").utf8))
    }
  }
  func testWhole16KiBIslandDeletionAcknowledgesEmptyBeforeFourByteScalar() async throws {
    try await assertWholeIslandDeletionBefore("🙂")
  }
  func testWhole16KiBIslandDeletionAcknowledgesEmptyBeforeTwoByteScalar() async throws {
    try await assertWholeIslandDeletionBefore("é")
  }

  func testRecenterRejectsOldNativeStorageAndIMEThenSealsMonotonicSequence() async throws {
    let initial = String(repeating: "0", count: 16_384) + String(repeating: "1", count: 16_384)
      + String(repeating: "2", count: 16_384)
    try await withWorkspace([initial]) { fixture in
      let owner = try await controller(fixture)
      let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240), session: owner.session)
      view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "A")
      _ = try await owner.session.flush(through: 1)
      let originalArena = owner.session.arenaID, originalBacking = Data(view.string.utf8)
      let moved = try await owner.session.navigate(toUTF16: 16_384)
      XCTAssertEqual(moved.utf16Start, 16_384); XCTAssertEqual(owner.session.generation, 1)
      XCTAssertNotEqual(owner.session.arenaID, originalArena)
      view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "wrong")
      XCTAssertNotNil(view.boundedStorage.mutationFailure)
      XCTAssertEqual(Data(view.string.utf8), originalBacking); XCTAssertEqual(owner.session.generation, 1)
      XCTAssertFalse(view.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: "wrong"))
      view.setMarkedText("e\u{301}", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
      XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(owner.session.isPinned)
      XCTAssertEqual(Data(view.string.utf8), originalBacking); XCTAssertEqual(owner.session.generation, 1)
      let fresh = try PagedNativeTextStorage(session: owner.session)
      fresh.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
      let revision = try await owner.session.flush(through: 2)
      XCTAssertNil(fresh.mutationFailure); XCTAssertEqual(owner.session.generation, 2)
      let trace = await owner.route.traces
      XCTAssertEqual(trace.map(\.firstSequence), [1, 2]); XCTAssertEqual(trace.map(\.lastSequence), [1, 2])
      XCTAssertTrue(trace.allSatisfy { $0.sessionID == owner.session.sessionID })
      let bytes = try await readBytes(fixture, revision)
      let expected = "A" + String(repeating: "0", count: 16_383) + "Z"
        + String(repeating: "1", count: 16_383) + String(repeating: "2", count: 16_384)
      XCTAssertEqual(bytes, Data(expected.utf8))
    }
  }

  func testClosedNoNetChangeGroupsRetainExactIntermediateEncryptedUndoRoots() async throws {
    let initial = "é public retained source"
    try await withWorkspace([initial]) { fixture in
      let owner = try await controller(fixture)
      let storage = try PagedNativeTextStorage(session: owner.session)
      storage.beginEditing()
      storage.beginNativeGroup(); storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "e\u{301}")
      storage.beginNativeGroup(); storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
      storage.endEditing()
      let revision = try await owner.session.flush(through: 2)
      let actual = try await snapshot(fixture)
      let retained = try await history(fixture, actual.documents[0])
      XCTAssertEqual(retained.current, revision); XCTAssertEqual(retained.undo.count, 2)
      let first = try XCTUnwrap(retained.undo.first), last = try XCTUnwrap(retained.undo.last)
      XCTAssertNotEqual(first.groupID, last.groupID)
      let firstBytes = try await readBytes(fixture, first.revision)
      let lastBytes = try await readBytes(fixture, last.revision)
      let current = try await readBytes(fixture, revision)
      XCTAssertEqual(firstBytes, Data(initial.utf8))
      XCTAssertEqual(lastBytes, Data("e\u{301} public retained source".utf8))
      XCTAssertEqual(current, Data(initial.utf8))
    }
  }

  func testRealFullRecordCASRefusesStaleHistoryEvenWhenSourceRootIsUnchanged() async throws {
    try await withWorkspace(["é public unchanged root"], terminalCase: Self.terminalCase) { fixture in
      let first = try await controller(fixture), stale = try await controller(fixture)
      let accepted = try PagedNativeTextStorage(session: first.session)
      accepted.beginEditing()
      accepted.replaceCharacters(in: NSRange(location: 0, length: 1), with: "e\u{301}")
      accepted.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
      accepted.endEditing()
      let revision = try await first.session.flush(through: 2)
      XCTAssertEqual(revision, fixture.records[0].document.revision)
      let after = try await snapshot(fixture)
      XCTAssertGreaterThan(after.documents[0].historyGeneration, fixture.records[0].historyGeneration)
      XCTAssertNotEqual(after.documents[0].historyPage, fixture.records[0].historyPage)
      let rejected = try PagedNativeTextStorage(session: stale.session)
      rejected.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
      await expectFailure("An unchanged source root bypassed the full history-record CAS") {
        _ = try await stale.session.flush(through: 1)
      }
      XCTAssertNotNil(stale.session.persistenceFailure)
      let stillCurrent = try await snapshot(fixture)
      XCTAssertEqual(stillCurrent, after)
      let bytes = try await readBytes(fixture, revision)
      XCTAssertEqual(bytes, Data("é public unchanged root".utf8))
    }
  }

  /// Real regression for a read-only BEGIN/full-record mismatch: source root
  /// stays identical while history advances, and the same Store must accept a
  /// later true source COMMIT. No refused native client/controller is discarded.
  func testReadOnlyFullRecordRejectionKeepsActualStoreWritableAndJoinedClosePossible() async throws {
    try await withWorkspace(["é public unchanged root"]) { fixture in
      let owner = try await controller(fixture)
      let storage = try PagedNativeTextStorage(session: owner.session)
      storage.beginEditing()
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "e\u{301}")
      storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
      storage.endEditing()
      _ = try await owner.session.flush(through: 2)
      let before = try await snapshot(fixture), statsBefore = try await fixture.engine.stats()
      XCTAssertEqual(before.documents[0].document.revision, fixture.records[0].document.revision)
      XCTAssertNotEqual(before.documents[0], fixture.records[0])
      // A generic component CAS has no accepted native input to erase. The
      // isolated stale-native case separately retains its real ordered batch.
      await expectFailure("Read-only transaction accepted a stale full source/history record") {
        _ = try await fixture.engine._publicSQLControlPublishDocumentRetaining(identity: fixture.outputs.identity,
          publisher: fixture.publisher, after: fixture.records[0], expected: fixture.records[0])
      }
      let after = try await snapshot(fixture), statsAfter = try await fixture.engine.stats()
      XCTAssertEqual(after, before); XCTAssertEqual(statsAfter.pageWrites, statsBefore.pageWrites)
      XCTAssertEqual(fixture.engine.custodySnapshot.jobs, 0)
      let maintenance = try await fixture.engine.nativeSQLMaintenanceSnapshot()
      XCTAssertNil(maintenance.storage.failedOperationID)
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "ç")
      let revision = try await owner.session.flush(through: 3)
      let final = try await snapshot(fixture)
      XCTAssertEqual(final.documents[0].document.revision, revision)
      XCTAssertEqual(final.head.generation, before.head.generation + 1)
      let bytes = try await readBytes(fixture, revision)
      XCTAssertEqual(bytes, Data("ç public unchanged root".utf8))
      // withWorkspace now requires real refined finish, exact detach, scheduled
      // maintenance join and actual Rust/SQL close before successful disposal.
    }
  }

  func testRealBackendRejectsForeignOwnerAndVaultWithoutChangingCoherentHead() async throws {
    try await withWorkspace(["public foreign-route boundary"], formerForeignPublishers: true) { fixture in
      let foreignOwner = try foreignPublisher(fixture, foreignOwner: true)
      let foreignVault = try foreignPublisher(fixture, foreignOwner: false)
      await expectFailure("Foreign publisher owner was admitted to the real backend", expected: .denied) {
        _ = try await fixture.engine.makeNativeStorage(foreignOwner, expected: fixture.records[0])
      }
      await expectFailure("Another Vault session was admitted to the real backend", expected: .denied) {
        _ = try await fixture.engine.makeNativeStorage(foreignVault, expected: fixture.records[0])
      }
      let actual = try await snapshot(fixture)
      XCTAssertEqual(actual, fixture.snapshot)
      let bytes = try await readBytes(fixture, actual.documents[0].document.revision)
      XCTAssertEqual(bytes, Data("public foreign-route boundary".utf8))
    }
  }

  func testLatestNavigationWinsUsingHeldRealEncryptedWindows() async throws {
    let initial = String(repeating: "0", count: 16_384) + String(repeating: "1", count: 16_384)
      + String(repeating: "2", count: 16_384)
    try await withWorkspace([initial]) { fixture in
      let owner = try await controller(fixture)
      await owner.route.holdWindows(at: [0, 16_384])
      let earlier = Task { try await owner.session.navigate(toUTF16: 0) }
      let later: Task<PagedTextWindow, Error>
      do {
        try await owner.route.waitForHeldWindow(at: 0)
        later = Task { try await owner.session.navigate(toUTF16: 16_384) }
      } catch {
        earlier.cancel(); await owner.route.releaseAll(); _ = await earlier.result; throw error
      }
      do {
        try await owner.route.waitForHeldWindow(at: 16_384)
        await owner.route.releaseWindow(at: 16_384)
        let winner = try await later.value
        XCTAssertEqual(winner.utf16Start, 16_384); XCTAssertEqual(Data(winner.text.utf8), Data(String(repeating: "1", count: 16_384).utf8))
        await owner.route.releaseWindow(at: 0)
        await expectFailure("The older navigation overwrote the winning native island") { _ = try await earlier.value }
        XCTAssertEqual(try owner.session.windowForNativeInstallation().windowID, winner.windowID)
        XCTAssertEqual(owner.session.generation, 0)
      } catch {
        earlier.cancel(); later.cancel(); await owner.route.releaseAll()
        _ = await earlier.result; _ = await later.result; throw error
      }
    }
  }

  func testCancelledWinningNavigationKeepsOriginalNativeStorageUsable() async throws {
    let initial = String(repeating: "0", count: 16_384) + String(repeating: "1", count: 16_384)
      + String(repeating: "2", count: 16_384)
    try await withWorkspace([initial]) { fixture in
      let owner = try await controller(fixture)
      let storage = try PagedNativeTextStorage(session: owner.session), arena = owner.session.arenaID
      await owner.route.holdWindows(at: [8_192, 16_384])
      let earlier = Task { try await owner.session.navigate(toUTF16: 8_192) }
      let winning: Task<PagedTextWindow, Error>
      do {
        try await owner.route.waitForHeldWindow(at: 8_192)
        winning = Task { try await owner.session.navigate(toUTF16: 16_384) }
      } catch {
        earlier.cancel(); await owner.route.releaseAll(); _ = await earlier.result; throw error
      }
      do {
        try await owner.route.waitForHeldWindow(at: 16_384)
        winning.cancel(); await owner.route.releaseWindow(at: 16_384)
        do { _ = try await winning.value; XCTFail("Canceled navigation installed its loaded window") }
        catch { XCTAssertTrue(error is CancellationError) }
        await owner.route.releaseWindow(at: 8_192)
        await expectFailure("An older request replaced the island after the winning request was canceled") { _ = try await earlier.value }
        XCTAssertEqual(owner.session.arenaID, arena); XCTAssertEqual(owner.session.generation, 0)
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "A")
        let revision = try await owner.session.flush(through: 1)
        XCTAssertNil(storage.mutationFailure)
        let bytes = try await readBytes(fixture, revision)
        XCTAssertEqual(bytes, Data(("A" + String(initial.dropFirst())).utf8))
      } catch {
        earlier.cancel(); winning.cancel(); await owner.route.releaseAll()
        _ = await earlier.result; _ = await winning.result; throw error
      }
    }
  }

  func testAlreadyCancelledInitializationLeavesNoHeadAndJoinsEngineClose() async throws {
    let root = scratchRoot(); try admitFreshControl(root)
    let opened = try await Task.detached {
      let vault = try Vault(root: root, testKey: SymmetricKey(data: Data(repeating: 0x73, count: 32)))
      let owner = UUID(), storeID = UUID()
      let engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: .fresh(storeID: storeID))
      return (vault: vault, storeID: storeID, engine: engine)
    }.value
    Self.retainedOpening = opened.engine
    let identity = try await opened.engine._publicSQLControlIdentity(expectedVault: opened.vault, expectedStoreID: opened.storeID)
    let outputs = PagedRealNativeFixtureOutputs(root: root, engine: opened.engine, identity: identity)
    Self.retainedOutputs = outputs
    let failures = testRun?.failureCount ?? 0
    do {
      let publisher = try await opened.engine.makeWorkspacePublisher()
      let token = PagedTextCancellation(); token.cancel()
      do {
        _ = try await opened.engine.initializeWorkspaceRetaining(publisher, state: WorkspaceState(), documents: [], cancellation: token)
        XCTFail("Already canceled initialization published a head")
      } catch { XCTAssertTrue(error is CancellationError) }
      try outputs.admitRead()
      let absent = try await opened.engine._publicSQLControlHeadPointerRetaining(identity: identity)
      outputs.retain(absent.lease)
      XCTAssertNil(absent.value) // Actual observed pointer absence, not a durability/not-published capability.
      try outputs.admitRead()
      let fresh = try await opened.engine.initializeWorkspaceRetaining(publisher, state: WorkspaceState(), documents: [])
      outputs.retain(fresh.lease)
      try await opened.engine.finishWorkspacePublication(fresh, publisher: publisher)
      XCTAssertEqual(fresh.value.head.generation, 0); XCTAssertTrue(fresh.value.documents.isEmpty)
      guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Pre-cancelled SQL initialization assertions failed.") }
      try await outputs.closeJoined()
      Self.retainedOutputs = nil; Self.retainedOpening = nil; Self.retainedRoot = nil; Self.retainedFormerPublishers.removeAll(); Self.retainedFormerRoots.removeAll()
      try await Task.detached { try FileManager.default.removeItem(at: root) }.value
    } catch {
      let original = error
      await outputs.joinFailedCalls()
      XCTFail("Cancelled SQL initialization failure and exact opening retained at \(root.path): \(original)")
      throw original
    }
  }

  func testHeldRealCommitPreservesOrdinaryIMEOrdinaryGroupBoundaries() async throws {
    try await withWorkspace(["start"]) { fixture in
      let owner = try await controller(fixture)
      let view = try PagedNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240), session: owner.session)
      var inputFailure: Error?
      view.didRejectInput = { inputFailure = $0 }
      try await usingHeldCommit(owner, endComposition: {
        if owner.session.isPinned { view.unmarkText() }
      }) {
        view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "A")
        try requireAcceptedMutation(view.boundedStorage, session: owner.session)
        let first = try await owner.route.waitForHeldCommit()
        XCTAssertEqual(first.firstSequence, 1); XCTAssertEqual(first.lastSequence, 1)
        view.boundedStorage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "B")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("e\u{301}", selectedRange: NSRange(location: 2, length: 0),
          replacementRange: NSRange(location: 2, length: 0))
        if let inputFailure { throw inputFailure }
        try requireAcceptedMutation(view.boundedStorage, session: owner.session)
        XCTAssertTrue(view.hasMarkedText()); XCTAssertTrue(owner.session.isPinned)
        view.unmarkText()
        if let inputFailure { throw inputFailure }
        XCTAssertFalse(view.hasMarkedText()); XCTAssertFalse(owner.session.isPinned)
        view.boundedStorage.replaceCharacters(in: NSRange(location: view.string.utf16.count, length: 0), with: "!")
        try requireAcceptedMutation(view.boundedStorage, session: owner.session)
        let target = owner.session.generation
        await owner.route.releaseCommit()
        let revision = try await owner.session.flush(through: target)
        XCTAssertNil(view.boundedStorage.mutationFailure)
        let trace = await owner.route.traces
        XCTAssertEqual(trace.count, 2)
        let queued = try XCTUnwrap(trace.last)
        XCTAssertEqual(queued.firstSequence, 2); XCTAssertEqual(queued.lastSequence, target)
        XCTAssertEqual(queued.groupIDs.count, 3); XCTAssertEqual(Set(queued.groupIDs).count, 3)
        let currentBytes = try await readBytes(fixture, revision)
        XCTAssertEqual(currentBytes, Data("ABe\u{301}art!".utf8))
        let actual = try await snapshot(fixture)
        let retained = try await history(fixture, actual.documents[0])
        XCTAssertEqual(retained.undo.count, 3)
        var points: [Data] = []
        for entry in retained.undo { points.append(try await readBytes(fixture, entry.revision)) }
        XCTAssertEqual(points, [Data("start".utf8), Data("ABart".utf8), Data("ABe\u{301}art".utf8)])
      }
    }
  }

  func testIdenticalNativePrimitivesDoNotAdvanceGenerationOrDiscardPersistedUndo() async throws {
    try await withWorkspace(["a public prior Undo"]) { fixture in
      let owner = try await controller(fixture)
      let storage = try PagedNativeTextStorage(session: owner.session)
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
      _ = try await owner.session.flush(through: 1)
      let before = try await snapshot(fixture)
      let prior = try await history(fixture, before.documents[0])
      XCTAssertEqual(prior.undo.count, 1)
      for _ in 0..<105 {
        storage.beginNativeGroup(); storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
      }
      XCTAssertEqual(owner.session.generation, 1); XCTAssertNil(storage.mutationFailure)
      let revision = try await owner.session.flush(through: 1)
      XCTAssertEqual(revision, before.documents[0].document.revision)
      let after = try await snapshot(fixture)
      let retained = try await history(fixture, after.documents[0])
      XCTAssertEqual(after, before); XCTAssertEqual(retained, prior)
      let trace = await owner.route.traces
      XCTAssertEqual(trace.count, 1)
    }
  }

  func testClosedNetZeroOverflowPreservesPriorUndoAndAdvancesExactFullRecordEpoch() async throws {
    try await withWorkspace(["a public prior Undo"]) { fixture in
      let owner = try await controller(fixture)
      let storage = try PagedNativeTextStorage(session: owner.session)
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
      let original = try await owner.session.flush(through: 1)
      let before = try await snapshot(fixture)
      let prior = try await history(fixture, before.documents[0])
      XCTAssertEqual(prior.undo.count, 1)
      try await usingHeldCommit(owner) {
        storage.beginNativeGroup(); storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "c")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
        storage.endEditing()
        try requireAcceptedMutation(storage, session: owner.session)
        let held = try await owner.route.waitForHeldCommit()
        XCTAssertEqual(held.firstSequence, 2); XCTAssertEqual(held.lastSequence, 3)
        for _ in 0..<105 {
          storage.beginNativeGroup(); storage.beginEditing()
          storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "c")
          storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
          storage.endEditing()
          try requireAcceptedMutation(storage, session: owner.session)
        }
        XCTAssertEqual(owner.session.generation, 213)
        await owner.route.releaseCommit()
        let revision = try await owner.session.flush(through: 213)
        XCTAssertEqual(revision, original); XCTAssertNil(storage.mutationFailure)
        let after = try await snapshot(fixture)
        let retained = try await history(fixture, after.documents[0])
        XCTAssertEqual(retained.undo, prior.undo); XCTAssertEqual(retained.redo, prior.redo)
        XCTAssertEqual(retained.current, prior.current)
        XCTAssertGreaterThan(retained.generation, prior.generation)
        XCTAssertNotEqual(after.documents[0].historyPage, before.documents[0].historyPage)
        XCTAssertEqual(after.documents[0].document.revision, before.documents[0].document.revision)
        await expectFailure("An earlier full record survived genuine accepted net-zero groups") {
          _ = try await fixture.engine.makeNativeStorage(fixture.publisher, expected: before.documents[0])
        }
        let trace = await owner.route.traces
        XCTAssertEqual(trace.map(\.firstSequence), [1, 2, 4])
        XCTAssertEqual(trace.map(\.lastSequence), [1, 3, 213])
        let bytes = try await readBytes(fixture, revision)
        XCTAssertEqual(bytes, Data("b public prior Undo".utf8))
      }
    }
  }
}

#endif
