import BoomCore
import Foundation

/// One file controller. It saves captured logical snapshots and never owns
/// the live native timeline, Foundation stack or a publication-gated arena.
actor PagedNativeStorageBackend: PagedNativeLogicalSessionStorage {
  nonisolated let engineIncarnation: UUID
  private let engine: PagedTextEngineAdapter
  private let publisher: PagedWorkspacePublisher
  private let routeID: UUID
  private let controllerCustody: PagedTextRootLease
  private var record: PagedDocumentRootRecord
  private var sessionID: UUID?
  private var lastSequence: UInt64 = 0
  private var publishing = false
  private var activeReads = 0
  private var openingAttempted = false
  private var openingInFlight = false
  private var detaching = false
  private var detached = false
  private var detachInFlight = false
  private var unresolvedOutput: PagedTextRootLease?
  private var retainedPublication: PagedNativeLogicalPublication?
  private var pendingAcknowledgement: PagedNativeCommitAcknowledgement?

  init(engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher,
    admittedRecord: PagedDocumentRootRecord, routeID: UUID, controllerCustody: PagedTextRootLease) {
    self.engine = engine; self.publisher = publisher; record = admittedRecord
    self.routeID = routeID; self.controllerCustody = controllerCustody
    engineIncarnation = engine.custodyIncarnation
  }
  private func admitLifetime() throws {
    guard !detached, !detaching else { throw BoomError.stale("Native file controller is closing.") }
  }
  func opening(sessionID requested: UUID) async throws -> PagedNativeCanonicalOpening {
    try admitLifetime()
    guard !openingAttempted, sessionID == nil, !publishing, activeReads == 0 else {
      throw BoomError.stale("Native controller opening is already owned.")
    }
    openingAttempted = true; openingInFlight = true; sessionID = requested
    defer { openingInFlight = false }
    try engine.bindNativeOpeningCustody(controllerCustody, sessionID: requested, record: record)
    let output = try await engine.nativeCanonicalOpeningRetaining(publisher: publisher, expected: record, sessionID: requested)
    do {
      try output.value.history.admit(record: record, sessionID: requested, engineIncarnation: engineIncarnation,
        scope: .opening(sessionID: requested, windowID: output.value.window.windowID))
      try engine.installNativeCustody(output.lease, controller: controllerCustody, expected: record, record: record)
    } catch { unresolvedOutput = output.lease; throw PagedTextCustodyFailure(original: error, lease: output.lease) }
    return output.value
  }
  func logicalWindow(_ snapshot: PagedNativeLogicalSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int, cancellation: CancellationFlag) async throws -> PagedNativeLogicalWindow {
    try admitLifetime()
    guard snapshot.sessionID == sessionID, snapshot.engineIncarnation == engineIncarnation,
      snapshot.sourceRevision.documentID == record.document.id else { throw BoomError.stale("Logical window belongs to another native controller.") }
    activeReads += 1; defer { activeReads -= 1 }
    // Reentrant actor read deliberately has no publishing/pending ACK test.
    return try await engine.logicalWindow(snapshot, utf16Anchor: utf16Anchor,
      maximumBytes: maximumBytes, cancellation: cancellation)
  }
  private func admitRead(_ snapshot: PagedNativeLogicalSnapshot) throws {
    try admitLifetime()
    guard snapshot.sessionID == sessionID, snapshot.engineIncarnation == engineIncarnation,
      snapshot.sourceRevision.documentID == record.document.id else { throw BoomError.stale("Logical reader has another actual native controller.") }
  }
  func logicalPosition(_ snapshot: PagedNativeLogicalSnapshot, utf16Offset: UInt64,
    rounding: UInt8, cancellation: CancellationFlag) async throws -> PagedTextSummary {
    try admitRead(snapshot); activeReads += 1; defer { activeReads -= 1 }
    return try await engine.logicalPosition(snapshot, utf16Offset: utf16Offset,
      rounding: rounding, cancellation: cancellation)
  }
  func logicalReplacement(_ snapshot: PagedNativeLogicalSnapshot, selection: PagedNativeNavigationSelection,
    replacement: Data, cancellation: CancellationFlag) async throws -> PagedNativeLogicalEdit {
    try admitRead(snapshot); activeReads += 1; defer { activeReads -= 1 }
    return try await engine.logicalReplacement(snapshot, selection: selection,
      replacement: replacement, cancellation: cancellation)
  }
  func logicalCommand(_ snapshot: PagedNativeLogicalSnapshot, command: PagedNativeLogicalCommand,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalCommandResult {
    try admitRead(snapshot); activeReads += 1; defer { activeReads -= 1 }
    return try await engine.logicalCommand(snapshot, command: command, cancellation: cancellation)
  }
  nonisolated func prepareImportedSourceTransfer(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    sessionID: UUID) throws -> () -> Void {
    try engine.prepareLogicalImportedSourceTransfer(imported, controller: controllerCustody, sessionID: sessionID)
  }
  func publishLogical(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    try admitLifetime()
    guard !publishing, unresolvedOutput == nil, pendingAcknowledgement == nil, retainedPublication == nil,
      publication.sessionID == sessionID, publication.expectedRecord == record,
      lastSequence < UInt64.max, publication.firstSequence == lastSequence + 1,
      publication.generation >= publication.firstSequence else { throw BoomError.stale("Logical save has another captured file prefix.") }
    publishing = true; retainedPublication = publication
    defer { publishing = false }
    let output: PagedTextCustodiedValue<PagedNativeCommitAcknowledgement>
    do { output = try await engine.publishLogicalRetaining(publication, publisher: publisher) }
    catch {
      if let retained = error as? PagedTextCustodyFailure { unresolvedOutput = retained.lease }
      else if let retained = error as? PagedTextCustodyHandoffFailure { unresolvedOutput = retained.lease }
      throw error
    }
    return try install(output)
  }
  private func install(_ output: PagedTextCustodiedValue<PagedNativeCommitAcknowledgement>) throws -> PagedNativeCommitAcknowledgement {
    let ack = output.value
    guard let publication = retainedPublication, ack.sessionID == sessionID,
      ack.batchID == publication.publicationID, ack.lastSequence == publication.generation,
      ack.expectedRootRecord == publication.expectedRecord else {
      unresolvedOutput = output.lease; throw PagedTextCustodyFailure(original: BoomError.invalid("File save returned another captured logical output."), lease: output.lease)
    }
    do { try engine.installNativeCustody(output.lease, controller: controllerCustody, expected: record, record: ack.sealedRootRecord) }
    catch { unresolvedOutput = output.lease; throw PagedTextCustodyFailure(original: error, lease: output.lease) }
    record = ack.sealedRootRecord; lastSequence = ack.lastSequence
    pendingAcknowledgement = ack; unresolvedOutput = nil
    return ack
  }
  func finishLogicalPublication(_ ack: PagedNativeCommitAcknowledgement) async throws {
    try admitLifetime()
    guard !publishing, ack.sessionID == sessionID, ack.lastSequence == lastSequence,
      ack.sealedRootRecord == record else { throw BoomError.stale("File receiving has another saved prefix.") }
    if let pendingAcknowledgement {
      guard pendingAcknowledgement.batchID == ack.batchID,
        pendingAcknowledgement.expectedRootRecord == ack.expectedRootRecord else {
        throw BoomError.stale("Another actual file output awaits its receiving join.")
      }
    }
    try await engine.finishNativeCommitCustody(controllerCustody, acknowledgement: ack, publisher: publisher)
    pendingAcknowledgement = nil; retainedPublication = nil
  }
  /// Explicit same-operation retry/receive. Native input remains live while
  /// this awaits. Known AFTER borrows the original output; known BEFORE alone
  /// permits retry of the SAME snapshot, never current later native content.
  func resumeLogicalPublication(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    try admitLifetime()
    guard !publishing, let retained = retainedPublication,
      retained.publicationID == publication.publicationID,
      retained.expectedRecord == publication.expectedRecord,
      retained.history.snapshot.isSame(publication.history.snapshot) else {
      throw BoomError.stale("Failed save was superseded by another actual publication.")
    }
    publishing = true; defer { publishing = false }
    if let pending = pendingAcknowledgement {
      guard let exact = try await engine.inspectLogicalPublication(publication, custody: controllerCustody, publisher: publisher),
        exact.batchID == pending.batchID else { throw BoomError.stale("Lost callback no longer names its original output.") }
      return exact
    }
    guard let lease = unresolvedOutput else { throw BoomError.stale("Failed save has no retained actual producer to resolve.") }
    if let ack = try await engine.inspectLogicalPublication(publication, custody: lease, publisher: publisher) {
      return try install(PagedTextCustodiedValue(value: ack, lease: lease))
    }
    return try install(await engine.retryLogicalBeforeRetaining(publication, custody: lease, publisher: publisher))
  }
  func detachJoinedController(sessionID expectedSession: UUID?, sequence: UInt64,
    record expectedRecord: PagedDocumentRootRecord) async throws {
    guard !detached, !detachInFlight, !publishing, !openingInFlight, activeReads == 0, unresolvedOutput == nil,
      retainedPublication == nil, pendingAcknowledgement == nil,
      sessionID == expectedSession, lastSequence == sequence, record == expectedRecord else {
      throw BoomError.stale("Actual source/save/read receiving has not joined before close.")
    }
    detaching = true; detachInFlight = true
    defer { detachInFlight = false }
    // No owner/input can resume after a refused actual close. Resource error
    // and the exact controller remain reachable for explicit repeated close.
    try await engine.transferJoinedRootToHead(controllerCustody, publisher: publisher, expected: expectedRecord)
    detached = true
  }
}
