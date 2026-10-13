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
struct PagedNativeRetainedHistoryIntent: Sendable {
  let prepared: PagedNativePreparedHistoryMove
  let lease: PagedTextRootLease
  var receiptID: UUID { lease.id }
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
    case capturedEdit(sessionID: UUID, commandID: UUID, sequence: UInt64)
    case nativePreparation(routeID: UUID, commandID: UUID)
    case nativePublication(routeID: UUID, preparationID: UUID)
    case retainedHistory(routeID: UUID, preparationID: UUID)
  }
  enum Phase: Sendable, Equatable { case admitted, running, output, liveController, preparedHistory, retainedHistory, unresolved }
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
  struct NativeFailure: Sendable {
    let batch: PagedNativeCommitBatch
    let acknowledgement: PagedNativeCommitAcknowledgement?
    let publicationComplete: Bool
  }
  private struct Entry {
    var purpose: Purpose; var phase: Phase = .admitted; var claims: [PagedTextRootClaim]
    var reservation: Int; var isJob = true; var joined = false; var wrote = false; var published = false
    var publicationComplete = false; var bulk: UUID?; var witness: Int?
    var input: PagedNativeCommitBatch?; var acknowledgement: PagedNativeCommitAcknowledgement?
    var capturedInput: PagedCapturedEditInput?; var capturedResult: PagedCapturedEditResult?
    var preparation: PagedNativePreparedHistoryMove?; var historyAcknowledgement: PagedNativeHistoryAcknowledgement?
    var historyAdmitted = false; var verifiedBefore = false
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
    payloadBytes: Int = 0, metadataBytes: Int = 0, nativeInput: PagedNativeCommitBatch? = nil,
    capturedInput: PagedCapturedEditInput? = nil) throws -> PagedTextRootLease {
    try validate(claims)
    guard payloadBytes >= 0, payloadBytes <= PagedTextWindow.maximumBytes, metadataBytes >= 0,
      metadataBytes <= Self.maximumNativeMetadataBytes, engine.ownerID == ownerID,
      engine.custodyIncarnation == engineIncarnation else { throw BoomError.invalid("Invalid source job reservation.") }
    var charge = payloadBytes + metadataBytes
    func chargeBuffer(_ bytes: Int) throws {
      let next = charge.addingReportingOverflow(bytes)
      guard bytes >= 0, !next.overflow, next.partialValue <= Self.maximumPayloadBytes else {
        throw BoomError.budget("Entered source buffers exceed their fixed memory bound.")
      }
      charge = next.partialValue
    }
    if let input = nativeInput {
      guard input.deltas.count <= PagedWorkingWindow.maximumQueuedDeltas,
        input.groupCheckpoints.count <= PagedRootHistory.maximumEntries,
        input.expected.text.utf8.count <= PagedWorkingWindow.hardBytes,
        input.afterBytes.count <= PagedWorkingWindow.hardBytes else { throw BoomError.budget("Native input exceeds its fixed source arena.") }
      try chargeBuffer(input.expected.text.utf8.count + input.afterBytes.count)
      for delta in input.deltas { try chargeBuffer(delta.chargedBytes) }
      for checkpoint in input.groupCheckpoints {
        guard checkpoint.afterBytes.count <= PagedWorkingWindow.hardBytes else { throw BoomError.budget("Native checkpoint exceeds its fixed island.") }
        try chargeBuffer(checkpoint.afterBytes.count + 128)
      }
      if let baseline = input.historyBaseline {
        guard baseline.afterBytes.count <= PagedWorkingWindow.hardBytes else { throw BoomError.budget("Native baseline exceeds its fixed island.") }
        try chargeBuffer(baseline.afterBytes.count + 128)
      }
    }
    if let capturedInput {
      guard nativeInput == nil,
        purpose == .capturedEdit(sessionID: capturedInput.sessionID, commandID: capturedInput.commandID, sequence: capturedInput.sequence),
        claims.contains(.record(capturedInput.expected)) else { throw BoomError.invalid("Captured input has another entered source job.") }
      try chargeBuffer(capturedInput.inputCharge())
    }
    return try state.withLock { s in
      guard !s.closing, s.entries.count < Self.maximumEntries,
        s.entries.values.filter(\.isJob).count < Self.maximumJobs,
        charge <= Self.maximumPayloadBytes - s.entries.values.reduce(0, { $0 + $1.reservation }) else {
        throw BoomError.unavailable("Source work is closing or exceeds its bounded memory.")
      }
      let lease = mint(); s.entries[lease.id] = Entry(purpose: purpose, claims: claims, reservation: charge, input: nativeInput, capturedInput: capturedInput)
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
  func stageCaptured(_ lease: PagedTextRootLease, result: PagedCapturedEditResult) throws {
    try update(lease) { e in
      guard let input = e.capturedInput, input.expected == result.beforeRecord, input.sessionID == result.sessionID,
        input.commandID == result.commandID, input.groupID == result.groupID, input.sequence == result.sequence else {
        throw BoomError.stale("Captured result has another exact entered command.")
      }
      e.capturedResult = result
    }
  }
  func stageHistory(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove, acknowledgement: PagedNativeHistoryAcknowledgement) throws { try update(lease) { $0.preparation = prepared; $0.historyAcknowledgement = acknowledgement } }
  func publicationCompleted(_ lease: PagedTextRootLease) throws { try update(lease) { $0.publicationComplete = true } }
  func finishOutput(_ lease: PagedTextRootLease, claims: [PagedTextRootClaim], payloadBytes: Int,
    inFlightWitness: Int, preparation: PagedNativePreparedHistoryMove? = nil,
    nativeAcknowledgement: PagedNativeCommitAcknowledgement? = nil) throws {
    try validate(claims)
    try update(lease) { e in
      guard e.isJob, e.phase == .running, e.bulk == nil, payloadBytes <= e.reservation,
        inFlightWitness > 0 else { throw BoomError.invalid("Source output escaped its real producer.") }
      e.claims = claims; e.joined = true; e.isJob = false; e.witness = inFlightWitness
      e.phase = preparation == nil ? .output : .preparedHistory
      if let preparation { e.preparation = preparation; e.published = false }
      if let nativeAcknowledgement { e.acknowledgement = nativeAcknowledgement }
    }
  }
  func finishRead(_ lease: PagedTextRootLease) throws {
    try state.withLock { s in let e = try require(lease, s); guard e.isJob, !e.wrote, !e.published, e.bulk == nil else { throw BoomError.invalid("A writer cannot finish as a read.") }; remove(lease.id, &s) }
  }
  @discardableResult func joinedFailure(_ lease: PagedTextRootLease, error: Error) throws -> Bool {
    try state.withLock { s in var e = try require(lease, s)
      if let neutral = error as? PagedCapturedEditUnchanged, let input = e.capturedInput,
        neutral.commandID == input.commandID, neutral.record == input.expected,
        !e.wrote, !e.published, e.bulk == nil {
        remove(lease.id, &s); return false
      }
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
      c.input = e.input; c.capturedInput = e.capturedInput; c.capturedResult = e.capturedResult
      c.publicationComplete = e.publicationComplete
      if let ack = e.acknowledgement { c.session = ack.sessionID; c.sequence = ack.lastSequence; c.pendingBatch = ack.batchID }
      if let captured = e.capturedResult {
        let next = c.sequence.addingReportingOverflow(1)
        guard !next.overflow, c.session == captured.sessionID, captured.sequence == next.partialValue,
          captured.beforeRecord == expected, captured.record == record, e.publicationComplete else {
          throw BoomError.stale("Captured output has another installed controller sequence or source.")
        }
        c.sequence = captured.sequence; c.pendingBatch = captured.commandID
      }
      s.entries[controller.id] = c; remove(output.id, &s)
    }
  }
  func confirmNativeInput(_ controller: PagedTextRootLease, sessionID: UUID, sequence: UInt64, record: PagedDocumentRootRecord) throws {
    try update(controller) { e in guard e.current == record, e.session == sessionID, e.sequence == sequence,
      e.pendingBatch == nil else { throw BoomError.stale("Native source/sequence is not fully installed.") }; e.input = nil; e.acknowledgement = nil; e.capturedInput = nil; e.capturedResult = nil; e.claims = [.record(record)]
      e.reservation = PagedWorkingWindow.hardBytes + Self.maximumNativeMetadataBytes }
  }
  func finishNativeCommit(_ controller: PagedTextRootLease, acknowledgement: PagedNativeCommitAcknowledgement) throws {
    try update(controller) { e in guard e.current == acknowledgement.sealedRootRecord, e.session == acknowledgement.sessionID,
      e.sequence == acknowledgement.lastSequence, let saved = e.acknowledgement, same(saved, acknowledgement),
      e.publicationComplete else { throw BoomError.stale("Native installation has another actual output.") }
      e.pendingBatch = nil; e.input = nil; e.claims = [.record(acknowledgement.sealedRootRecord)]
      e.reservation = PagedWorkingWindow.hardBytes + Self.maximumNativeMetadataBytes
    }
  }
  func finishCapturedInstallation(_ controller: PagedTextRootLease, result: PagedCapturedEditResult) throws {
    try update(controller) { e in
      guard e.current == result.record, e.session == result.sessionID, e.sequence == result.sequence,
        let saved = e.capturedResult, saved == result, saved.window.text.utf8.elementsEqual(result.window.text.utf8),
        e.pendingBatch == nil || e.pendingBatch == result.commandID, e.publicationComplete else {
        throw BoomError.stale("Captured installation has another actual output.")
      }
      e.pendingBatch = nil; e.capturedInput = nil; e.claims = [.record(result.record)]
      e.reservation = PagedWorkingWindow.hardBytes + Self.maximumNativeMetadataBytes
    }
  }
  func borrowNativeAcknowledgement(_ controller: PagedTextRootLease, batch: PagedNativeCommitBatch) throws -> PagedNativeCommitAcknowledgement {
    try state.withLock { s in let e = try require(controller, s)
      guard e.pendingBatch == batch.batchID, e.session == batch.sessionID, e.sequence == batch.lastSequence,
        e.input?.batchID == batch.batchID, let ack = e.acknowledgement, e.publicationComplete,
        ack.expectedRootRecord == batch.expectedRootRecord, ack.sealedWindow.text.utf8.elementsEqual(batch.afterBytes) else { throw BoomError.stale("Lost output no longer belongs to this admitted batch.") }; return ack }
  }
  func nativeFailure(_ lease: PagedTextRootLease, batch: PagedNativeCommitBatch) throws -> NativeFailure {
    try state.withLock { s in let e = try require(lease, s); guard e.joined, !e.isJob, e.input?.batchID == batch.batchID,
      e.input?.sessionID == batch.sessionID, e.input?.expectedRootRecord == batch.expectedRootRecord,
      e.input?.firstSequence == batch.firstSequence, e.input?.lastSequence == batch.lastSequence else { throw BoomError.stale("Failed input has another real producer.") }
      return NativeFailure(batch: e.input!, acknowledgement: e.acknowledgement, publicationComplete: e.publicationComplete) }
  }
  func admitActualNativeInput(_ lease: PagedTextRootLease, batch: PagedNativeCommitBatch) throws { _ = try nativeFailure(lease, batch: batch) }
  func recoverNativeOutput(_ lease: PagedTextRootLease) throws { try update(lease) { e in guard e.joined, !e.isJob, e.acknowledgement != nil else { throw BoomError.stale("No original output to receive.") }; e.publicationComplete = true; e.phase = .output } }
  func retryNative(_ lease: PagedTextRootLease) throws -> PagedNativeCommitBatch {
    try state.withLock { s in var e = try require(lease, s); guard e.joined, !e.isJob, let input = e.input,
      !e.publicationComplete else { throw BoomError.stale("Published input cannot replay.") }; e.isJob = true; e.joined = false; e.phase = .admitted; e.acknowledgement = nil; s.entries[lease.id] = e; return input }
  }
  func retainHistory(_ prepared: PagedNativePreparedHistoryMove, engine: PagedTextEngineAdapter) throws -> PagedNativeRetainedHistoryIntent {
    let lease = try reserve(engine: engine, purpose: .retainedHistory(routeID: prepared.routeID, preparationID: prepared.preparationID),
      claims: [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord)],
      payloadBytes: prepared.windowBytes, metadataBytes: Self.maximumNativeMetadataBytes)
    try update(lease) { $0.isJob = false; $0.joined = true; $0.phase = .retainedHistory; $0.preparation = prepared }
    return PagedNativeRetainedHistoryIntent(prepared: prepared, lease: lease)
  }
  func resolvePrepared(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove, disposition: PagedNativeHistoryIntentDisposition) throws {
    try state.withLock { s in let e = try require(lease, s); guard e.joined, e.preparation == prepared, !e.historyAdmitted else { throw BoomError.stale("Admitted history cannot be abandoned.") }
      if case .transferredToRetainedOwner(let id) = disposition { guard s.entries[id]?.preparation == prepared, id != lease.id else { throw BoomError.stale("History receiving owner is absent.") } }
      remove(lease.id, &s)
    }
  }
  func admitHistoryPublication(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws { try update(lease) { e in guard e.joined, e.preparation == prepared, !e.historyAdmitted || e.verifiedBefore else { throw BoomError.stale("History command already admitted.") }; e.historyAdmitted = true; e.verifiedBefore = false } }
  func verifiedHistoryBefore(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws { try update(lease) { e in guard e.preparation == prepared, e.joined else { throw BoomError.stale("History inspection lost its intent.") }; e.verifiedBefore = true; e.historyAdmitted = false } }
  func absorbJoined(_ output: PagedTextRootLease, into receiver: PagedTextRootLease) throws {
    try state.withLock { s in let e = try require(output, s); var r = try require(receiver, s)
      guard output != receiver, e.joined, !e.isJob, r.joined, !r.isJob else { throw BoomError.stale("Unjoined output cannot transfer.") }
      guard e.claims.allSatisfy({ r.claims.contains($0) || { if case .writerDocument = $0 { return true }; if case .workspace = $0 { return true }; return false }($0) }) else { throw BoomError.stale("History transfer has another source.") }
      if let ack = e.historyAcknowledgement { r.historyAcknowledgement = ack; r.publicationComplete = e.publicationComplete }
      if r.error == nil { r.error = e.error }; s.entries[receiver.id] = r; remove(output.id, &s)
    }
  }
  func historyOutput(for prepared: PagedNativePreparedHistoryMove) throws -> (lease: PagedTextRootLease, acknowledgement: PagedNativeHistoryAcknowledgement?, completed: Bool) {
    try state.withLock { s in
      let candidates = s.entries.filter { $0.value.joined && !$0.value.isJob && $0.value.preparation == prepared }
      guard let found = candidates.first(where: { $0.value.historyAcknowledgement != nil })
        ?? candidates.first(where: { $0.value.historyAdmitted }) else { throw BoomError.stale("History publication has no retained actual intent.") }
      return (mint(found.key), found.value.historyAcknowledgement, found.value.publicationComplete)
    }
  }
  func historyOutput(_ lease: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove) throws -> (PagedNativeHistoryAcknowledgement?, Bool) {
    try state.withLock { s in let e = try require(lease, s); guard e.joined, e.preparation == prepared else { throw BoomError.stale("History output lost its preparation.") }; return (e.historyAcknowledgement, e.publicationComplete) }
  }
  func recoverHistoryOutput(_ lease: PagedTextRootLease) throws { try update(lease) { $0.publicationComplete = true; $0.phase = .preparedHistory } }
  func finishHistoryInstallation(_ lease: PagedTextRootLease, controller: PagedTextRootLease,
    prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission, record: PagedDocumentRootRecord) throws {
    try admission.validate(for: prepared)
    try state.withLock { s in let e = try require(lease, s); var c = try require(controller, s)
      guard e.joined, e.preparation == prepared, e.publicationComplete,
        e.historyAcknowledgement?.sealedRootRecord == record, e.historyAcknowledgement?.admittedSequence == admission.admittedSequence,
        c.current == prepared.command.expectedRootRecord, c.session == admission.sessionID,
        c.sequence == admission.expectedSequence, c.pendingBatch == nil else { throw BoomError.stale("History installation lost its real output/controller.") }
      c.current = record; c.sequence = admission.admittedSequence; c.claims = [.record(record)]
      c.acknowledgement = nil; c.input = nil; s.entries[controller.id] = c; remove(lease.id, &s)
    }
  }
  func adoptUnclaimed(_ id: UUID) throws -> PagedTextRootLease { let lease = mint(id); _ = try state.withLock { try require(lease, $0) }; return lease }
  func claims(_ lease: PagedTextRootLease) throws -> [PagedTextRootClaim] { try state.withLock { try require(lease, $0).claims } }
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
