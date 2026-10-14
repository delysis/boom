import BoomCore
import Foundation
import Synchronization

enum PagedTextRootClaim: Sendable, Equatable {
  case source(PagedTextRevision), record(PagedDocumentRootRecord), writerDocument(UUID), workspace
}
struct PagedTextRootLease: Sendable, Equatable {
  let ownerID: UUID
  let engineIncarnation: UUID
  let id: UUID
  fileprivate init(ownerID: UUID, engineIncarnation: UUID, id: UUID) {
    self.ownerID = ownerID; self.engineIncarnation = engineIncarnation; self.id = id
  }
}
struct PagedTextCustodiedValue<Value: Sendable>: Sendable { let value: Value; let lease: PagedTextRootLease }
struct PagedTextCustodyFailure: Error, LocalizedError {
  let original: Error
  let lease: PagedTextRootLease
  var errorDescription: String? { original.localizedDescription }
}
struct PagedTextCustodyHandoffFailure: Error, LocalizedError {
  let original: Error
  let handoff: Error
  let lease: PagedTextRootLease
  var errorDescription: String? { "\(original.localizedDescription) \(handoff.localizedDescription)" }
}

/// Only process-local entered work and native receiving state. Files contain
/// immutable pages and ordinary roots, never this registry or operation receipts.
final class PagedTextRootCustody: @unchecked Sendable {
  static let maximumEntries = 64
  static let maximumJobs = 16
  static let maximumControllers = 8
  static let maximumClaims = 4
  static let maximumPayloadBytes = 4_194_304
  static let maximumNativeMetadataBytes = 2 * PagedNativeCanonicalHistoryProjection.chargedBytes
  enum Purpose: Sendable, Equatable {
    case operation(UUID), controller(UUID)
    case nativeBatch(sessionID: UUID, batchID: UUID, first: UInt64, last: UInt64)
  }
  enum Phase: Sendable, Equatable { case admitted, running, output, liveController, unresolved }
  struct Item: Sendable {
    let id: UUID; let purpose: Purpose; let phase: Phase; let claims: [PagedTextRootClaim]
    let payloadReservation: Int; let producerJoined: Bool; let writesAttempted: Bool
    let publicationAttempted: Bool; let bulkActive: Bool; let bulkOperationID: UUID?
    let controllerSessionID: UUID?; let controllerSequence: UInt64; let pendingBatchID: UUID?
    let outputInFlightWitness: Int?
  }
  struct Snapshot: Sendable {
    let ownerID: UUID; let engineIncarnation: UUID; let closing: Bool; let jobs: Int
    let reservedPayloadBytes: Int; let metadataEnvelopeBytes: Int; let items: [Item]
  }
  private struct Entry {
    var purpose: Purpose; var phase: Phase = .admitted; var claims: [PagedTextRootClaim]
    var reservation: Int; var isJob = true; var joined = false; var wrote = false; var published = false
    var publicationComplete = false; var bulk: UUID?; var witness: Int?
    var logicalInput: PagedNativeLogicalPublication?; var acknowledgement: PagedNativeCommitAcknowledgement?
    var session: UUID?; var sequence: UInt64 = 0; var current: PagedDocumentRootRecord?; var pendingBatch: UUID?
    var error: Error?
  }
  private struct State {
    var entries: [UUID: Entry] = [:]
    var closing = false
    var engine: PagedTextEngineAdapter?
  }
  let ownerID: UUID
  let engineIncarnation = UUID()
  private let state = Mutex(State())
  init(ownerID: UUID) { self.ownerID = ownerID }
  var snapshot: Snapshot {
    state.withLock { s in Snapshot(ownerID: ownerID, engineIncarnation: engineIncarnation,
      closing: s.closing, jobs: s.entries.values.filter(\.isJob).count,
      reservedPayloadBytes: s.entries.values.reduce(0) { $0 + $1.reservation },
      metadataEnvelopeBytes: s.entries.count * 1024,
      items: s.entries.map { id, e in Item(id: id, purpose: e.purpose, phase: e.phase,
        claims: e.claims, payloadReservation: e.reservation, producerJoined: e.joined,
        writesAttempted: e.wrote, publicationAttempted: e.published, bulkActive: e.bulk != nil,
        bulkOperationID: e.bulk, controllerSessionID: e.session, controllerSequence: e.sequence,
        pendingBatchID: e.pendingBatch, outputInFlightWitness: e.witness) }) }
  }
  func reserve(engine: PagedTextEngineAdapter, purpose: Purpose, claims: [PagedTextRootClaim],
    payloadBytes: Int = 0, metadataBytes: Int = 0, logicalInput: PagedNativeLogicalPublication? = nil) throws -> PagedTextRootLease {
    try validate(claims)
    guard payloadBytes >= 0, payloadBytes <= Self.maximumPayloadBytes, metadataBytes >= 0,
      metadataBytes <= Self.maximumNativeMetadataBytes, engine.ownerID == ownerID,
      engine.custodyIncarnation == engineIncarnation else { throw BoomError.invalid("Invalid source job reservation.") }
    let charge = payloadBytes + metadataBytes
    if let logicalInput {
      guard purpose == .nativeBatch(sessionID: logicalInput.sessionID, batchID: logicalInput.publicationID,
          first: logicalInput.firstSequence, last: logicalInput.generation),
        claims.contains(.record(logicalInput.expectedRecord)),
        logicalInput.history.snapshot.engineIncarnation == engineIncarnation,
        logicalInput.window.snapshot.isSame(logicalInput.history.snapshot) else {
        throw BoomError.invalid("Logical publication escaped its same native owner.")
      }
      // Snapshots share resident insertion blocks with their actual SDK owner;
      // no duplicate serialized input/archive is retained on the worker.
      try logicalInput.history.validate()
    }
    return try state.withLock { s in
      guard !s.closing, s.entries.count < Self.maximumEntries,
        s.entries.values.filter(\.isJob).count < Self.maximumJobs,
        charge <= Self.maximumPayloadBytes - s.entries.values.reduce(0, { $0 + $1.reservation }) else {
        throw BoomError.unavailable("Source work is closing or exceeds its bounded memory.")
      }
      let lease = mint(); s.entries[lease.id] = Entry(purpose: purpose, claims: claims, reservation: charge, logicalInput: logicalInput)
      s.engine = engine; return lease
    }
  }
  func start(_ lease: PagedTextRootLease) throws {
    try update(lease) { e in guard e.isJob, e.phase == .admitted else { throw BoomError.stale("Source job already entered.") }; e.phase = .running }
  }
  func willWrite(_ lease: PagedTextRootLease, documentID: UUID) throws {
    try update(lease) { e in guard e.isJob, e.phase == .running, e.claims.contains(.writerDocument(documentID)) else { throw BoomError.denied("Page write has no admitted source job.") }; e.wrote = true }
  }
  func willPublish(_ lease: PagedTextRootLease) throws { try update(lease) { e in guard e.isJob, e.phase == .running else { throw BoomError.stale("Publication lost its entered job.") }; e.published = true } }
  func willBeginBulk(_ lease: PagedTextRootLease) throws { try update(lease) { e in guard e.isJob, e.bulk == nil else { throw BoomError.stale("Source stream already entered.") } } }
  func beganBulk(_ lease: PagedTextRootLease, operationID: UUID) throws { try update(lease) { $0.bulk = operationID } }
  func joinedBulk(_ lease: PagedTextRootLease, operationID: UUID) throws {
    try update(lease) { e in
      guard e.bulk == operationID else { throw BoomError.stale("Source stream token changed.") }
      e.bulk = nil
      if e.phase == .unresolved, !e.published, case .operation = e.purpose {
        // Real Rust abort has joined. An unpublished generic stream can now
        // receive explicit abandonment; its original error remains recorded.
        e.joined = true; e.phase = .output
      }
    }
  }
  func unresolvedBulk(_ lease: PagedTextRootLease) throws -> UUID { try state.withLock { s in guard let id = try require(lease, s).bulk else { throw BoomError.stale("No retained source stream.") }; return id } }
  func candidate(_ lease: PagedTextRootLease, claims: [PagedTextRootClaim]) throws { try validate(claims); try update(lease) { $0.claims = claims } }
  func stageNative(_ lease: PagedTextRootLease, acknowledgement: PagedNativeCommitAcknowledgement) throws { try update(lease) { $0.acknowledgement = acknowledgement } }
  func publicationCompleted(_ lease: PagedTextRootLease) throws { try update(lease) { $0.publicationComplete = true } }
  func finishOutput(_ lease: PagedTextRootLease, claims: [PagedTextRootClaim], payloadBytes: Int,
    inFlightWitness: Int, nativeAcknowledgement: PagedNativeCommitAcknowledgement? = nil) throws {
    try validate(claims)
    try update(lease) { e in
      guard e.isJob, e.phase == .running, e.bulk == nil, payloadBytes <= e.reservation,
        inFlightWitness > 0 else { throw BoomError.invalid("Source output escaped its real producer.") }
      e.claims = claims; e.joined = true; e.isJob = false; e.witness = inFlightWitness
      e.phase = .output
      if let nativeAcknowledgement { e.acknowledgement = nativeAcknowledgement }
    }
  }
  func finishRead(_ lease: PagedTextRootLease) throws {
    try state.withLock { s in let e = try require(lease, s); guard e.isJob, !e.wrote, !e.published, e.bulk == nil else { throw BoomError.invalid("A writer cannot finish as a read.") }; remove(lease.id, &s) }
  }
  @discardableResult func joinedFailure(_ lease: PagedTextRootLease, error: Error) throws -> Bool {
    try state.withLock { s in var e = try require(lease, s)
      if !e.published && e.bulk == nil, case .operation = e.purpose { remove(lease.id, &s); return false }
      e.isJob = false; e.joined = e.bulk == nil; e.phase = .unresolved; if e.error == nil { e.error = error }; s.entries[lease.id] = e; return true
    }
  }
  func makeController(from output: PagedTextRootLease, routeID: UUID, record: PagedDocumentRootRecord) throws -> PagedTextRootLease {
    try state.withLock { s in var e = try require(output, s)
      guard e.joined, !e.isJob, e.claims.contains(.record(record)), s.entries.values.filter({ if case .controller = $0.purpose { return true }; return false }).count < Self.maximumControllers else { throw BoomError.stale("Native opening lost its actual root output.") }
      e.purpose = .controller(routeID); e.phase = .liveController; e.current = record
      e.reservation = PagedWorkingWindow.hardBytes + Self.maximumNativeMetadataBytes; s.entries[output.id] = e; return output
    }
  }
  func bindNativeOpening(_ controller: PagedTextRootLease, sessionID: UUID, record: PagedDocumentRootRecord) throws { try update(controller) { e in guard e.current == record, e.session == nil else { throw BoomError.stale("Native controller already opened.") }; e.session = sessionID } }
  func installControllerOutput(_ output: PagedTextRootLease, into controller: PagedTextRootLease,
    expected: PagedDocumentRootRecord, record: PagedDocumentRootRecord) throws {
    try state.withLock { s in var c = try require(controller, s); let e = try require(output, s)
      guard output != controller, c.current == expected, c.pendingBatch == nil, e.joined, !e.isJob,
        e.claims.contains(.record(record)), e.error == nil || (e.phase == .output && e.publicationComplete) else { throw BoomError.stale("Native output cannot replace this controller.") }
      c.reservation = max(c.reservation, e.reservation)
      c.current = record; c.claims = [.record(expected), .record(record)]; c.acknowledgement = e.acknowledgement
      c.logicalInput = e.logicalInput; c.error = e.error
      c.publicationComplete = e.publicationComplete
      if let ack = e.acknowledgement { c.session = ack.sessionID; c.sequence = ack.lastSequence; c.pendingBatch = ack.batchID }
      s.entries[controller.id] = c; remove(output.id, &s)
    }
  }
  func finishNativeCommit(_ controller: PagedTextRootLease, acknowledgement: PagedNativeCommitAcknowledgement) throws {
    try update(controller) { e in guard e.current == acknowledgement.sealedRootRecord, e.session == acknowledgement.sessionID,
      e.sequence == acknowledgement.lastSequence, let saved = e.acknowledgement, same(saved, acknowledgement),
      e.publicationComplete else { throw BoomError.stale("Native installation has another actual output.") }
      e.pendingBatch = nil; e.logicalInput = nil; e.error = nil; e.claims = [.record(acknowledgement.sealedRootRecord)]
      e.reservation = PagedWorkingWindow.hardBytes + Self.maximumNativeMetadataBytes
    }
  }
  func logicalFailure(_ lease: PagedTextRootLease, publication: PagedNativeLogicalPublication)
    throws -> (acknowledgement: PagedNativeCommitAcknowledgement?, completed: Bool) {
    try state.withLock { s in
      let e = try require(lease, s)
      guard e.joined, !e.isJob, let input = e.logicalInput,
        input.sessionID == publication.sessionID, input.publicationID == publication.publicationID,
        input.firstSequence == publication.firstSequence, input.generation == publication.generation,
        input.expectedRecord == publication.expectedRecord,
        input.history.snapshot.isSame(publication.history.snapshot) else {
        throw BoomError.stale("Failed save belongs to another captured logical source.")
      }
      return (e.acknowledgement, e.publicationComplete)
    }
  }
  func retryLogical(_ lease: PagedTextRootLease, publication: PagedNativeLogicalPublication) throws {
    _ = try logicalFailure(lease, publication: publication)
    try update(lease) { e in
      guard !e.publicationComplete else { throw BoomError.stale("A published logical snapshot cannot replay.") }
      e.isJob = true; e.joined = false; e.phase = .admitted; e.acknowledgement = nil
    }
  }
  func recoverLogicalOutput(_ lease: PagedTextRootLease) throws { try update(lease) { e in guard e.joined, !e.isJob, e.acknowledgement != nil else { throw BoomError.stale("No original output to receive.") }; e.publicationComplete = true; e.phase = .output } }
  func adoptUnclaimed(_ id: UUID) throws -> PagedTextRootLease { let lease = mint(id); _ = try state.withLock { try require(lease, $0) }; return lease }
  func claims(_ lease: PagedTextRootLease) throws -> [PagedTextRootClaim] { try state.withLock { try require(lease, $0).claims } }
  func admitJoinedSource(_ lease: PagedTextRootLease, revision: PagedTextRevision) throws {
    try state.withLock { try admitJoinedSource(lease, revision: revision, state: $0) }
  }
  private func admitJoinedSource(_ lease: PagedTextRootLease, revision: PagedTextRevision, state: State) throws {
    let e = try require(lease, state)
    guard case .operation = e.purpose, e.joined, !e.isJob, e.bulk == nil,
      e.error == nil, e.phase == .output, e.pendingBatch == nil,
      e.claims.contains(.source(revision)), e.claims.contains(.writerDocument(revision.documentID)) else {
      throw BoomError.stale("Streamed editing requires its actual joined immutable source output.")
    }
  }
  func prepareImportedSourceTransfer(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    controller: PagedTextRootLease, sessionID: UUID) throws -> () -> Void {
    try state.withLock { s in
      try admitJoinedSource(imported.lease, revision: imported.value.revision, state: s)
      let c = try require(controller, s)
      guard case .controller = c.purpose, c.joined, !c.isJob, c.session == sessionID,
        c.current?.document.id == imported.value.revision.documentID else {
        throw BoomError.stale("Imported source has another actual live native receiver.")
      }
    }
    // The exact one-use output is held by the prepared ticket. Actual source
    // adoption is synchronous; controller close is excluded by that ticket.
    // File spans remain pinned by that SAME document controller, and cold GC
    // cannot run while this editor or any capture is live.
    return { [self] in
      state.withLock { s in
        let c = s.entries[controller.id], e = s.entries[imported.lease.id]
        precondition(c?.session == sessionID && c?.current?.document.id == imported.value.revision.documentID)
        precondition(e?.joined == true && e?.isJob == false && e?.claims.contains(.source(imported.value.revision)) == true)
        remove(imported.lease.id, &s)
      }
    }
  }
  func abandonJoined(_ lease: PagedTextRootLease) throws {
    try state.withLock { s in let e = try require(lease, s); guard e.joined, !e.isJob, e.bulk == nil,
      e.phase != .unresolved, e.pendingBatch == nil else { throw BoomError.stale("Unresolved input/output cannot be released.") }
      if case .controller = e.purpose { throw BoomError.denied("Native controller must join its close.") }; remove(lease.id, &s)
    }
  }
  func transferJoinedToHead(_ lease: PagedTextRootLease, record: PagedDocumentRootRecord) throws {
    try state.withLock { s in let e = try require(lease, s); guard e.joined, !e.isJob, e.bulk == nil,
      e.phase != .unresolved, e.pendingBatch == nil,
      e.claims.contains(.record(record)) || e.claims.contains(.source(record.document.revision)) else { throw BoomError.stale("Source close did not join its published root.") }; remove(lease.id, &s) }
  }
  /// The initial cold host has not exposed a reader, capture or native owner.
  /// One existing job fences all new source admission until its actual join.
  func reserveColdMaintenance(engine: PagedTextEngineAdapter) throws -> PagedTextRootLease {
    try state.withLock { s in
      guard !s.closing, s.entries.isEmpty, engine.ownerID == ownerID,
        engine.custodyIncarnation == engineIncarnation else {
        throw BoomError.unavailable("Cold reclamation requires an unexposed source owner.")
      }
      let lease = mint()
      s.entries[lease.id] = Entry(purpose: .operation(lease.id), claims: [.workspace], reservation: 3_145_728)
      s.engine = engine; s.closing = true
      return lease
    }
  }
  func finishColdMaintenance(_ lease: PagedTextRootLease) throws {
    try state.withLock { s in
      let entry = try require(lease, s)
      guard s.closing, s.entries.count == 1, entry.purpose == .operation(lease.id),
        entry.claims == [.workspace], entry.isJob, entry.bulk == nil,
        entry.phase == .running || entry.phase == .admitted else {
        throw BoomError.stale("Cold reclamation lost its exact joined job.")
      }
      remove(lease.id, &s); s.closing = false
    }
  }
  func beginCloseIfEmpty() throws {
    try state.withLock { s in guard s.entries.isEmpty else { throw BoomError.unavailable("Source input or output has not joined.") }; s.closing = true }
  }
  func requireEmptyForClose() throws { try state.withLock { s in guard s.entries.isEmpty else { throw BoomError.unavailable("Source input or output has not joined.") } } }
  private func validate(_ claims: [PagedTextRootClaim]) throws {
    guard !claims.isEmpty, claims.count <= Self.maximumClaims else { throw BoomError.budget("Source job claim bound exceeded.") }
    for c in claims { switch c { case .source(let r): try r.validate(); guard r.ownerID == ownerID else { throw BoomError.denied("Foreign source.") }
      case .record(let r): try r.validate(); guard r.document.revision.ownerID == ownerID else { throw BoomError.denied("Foreign source history.") }
      case .writerDocument, .workspace: break } }
  }
  private func require(_ lease: PagedTextRootLease, _ s: State) throws -> Entry {
    guard lease.ownerID == ownerID, lease.engineIncarnation == engineIncarnation, let e = s.entries[lease.id] else { throw BoomError.stale("Source lifetime belongs to another engine or completed output.") }; return e
  }
  private func update(_ lease: PagedTextRootLease, _ body: (inout Entry) throws -> Void) throws { try state.withLock { s in var e = try require(lease, s); try body(&e); s.entries[lease.id] = e } }
  private func remove(_ id: UUID, _ s: inout State) { s.entries.removeValue(forKey: id); if s.entries.isEmpty { s.engine = nil } }
  private func mint(_ id: UUID = UUID()) -> PagedTextRootLease { PagedTextRootLease(ownerID: ownerID, engineIncarnation: engineIncarnation, id: id) }
  private func same(_ a: PagedNativeCommitAcknowledgement, _ b: PagedNativeCommitAcknowledgement) -> Bool {
    a.sessionID == b.sessionID && a.batchID == b.batchID && a.lastSequence == b.lastSequence
      && a.expectedRootRecord == b.expectedRootRecord && a.sealedRootRecord == b.sealedRootRecord
      && a.sealedWindow.windowID == b.sealedWindow.windowID && a.canonicalHistory == b.canonicalHistory
  }
}
