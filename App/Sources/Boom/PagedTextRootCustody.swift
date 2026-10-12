import BoomCore
import Foundation
import Synchronization

/// Process-local reachability, not a new key authority or a durable GC catalog.
/// A record pins its encrypted history manifest and the graph authenticated by
/// that manifest. Writer/workspace barriers conservatively pin unpublished
/// pages and an unresolved coherent journal without indexing every page.
enum PagedTextRootClaim: Sendable, Equatable {
  case source(PagedTextRevision)
  case record(PagedDocumentRootRecord)
  case writerDocument(UUID)
  case workspace
}

/// Only this file can mint a capability. UUIDs copied from diagnostics, decoded
/// metadata, another engine incarnation or a receiving owner's local dictionary
/// are not leases. Releasing a capability never deletes encrypted bytes.
struct PagedTextRootLease: Sendable, Equatable {
  let ownerID: UUID
  let engineIncarnation: UUID
  let id: UUID
  fileprivate init(ownerID: UUID, engineIncarnation: UUID, id: UUID) {
    self.ownerID = ownerID; self.engineIncarnation = engineIncarnation; self.id = id
  }
}

struct PagedTextCustodiedValue<Value: Sendable>: Sendable {
  let value: Value
  let lease: PagedTextRootLease
}

/// Carries the original error and the already joined, retained writer/output.
/// Observer cancellation alone can neither abandon this lease nor prove that
/// a head publication did not happen.
struct PagedTextCustodyFailure: Error, LocalizedError {
  let original: Error
  let lease: PagedTextRootLease
  var errorDescription: String? {
    "\(original.localizedDescription) Root custody remains unresolved (\(lease.id))."
  }
}
struct PagedTextCustodyHandoffFailure: Error, LocalizedError {
  let original: Error
  let handoff: Error
  let lease: PagedTextRootLease
  var errorDescription: String? {
    "\(original.localizedDescription) Custody handoff failed: \(handoff.localizedDescription). Root \(lease.id) retained."
  }
}

/// This receipt is minted only after the actual same-engine receiving entry
/// contains both records AND the immutable command/window. It is not durable
/// evidence/proposal storage; that migration remains a separate dependency.
struct PagedNativeRetainedHistoryIntent: Sendable {
  let prepared: PagedNativePreparedHistoryMove
  let lease: PagedTextRootLease
  var receiptID: UUID { lease.id }
}

/// One bounded ledger belongs to the existing adapter. Non-IO reservation is
/// synchronous before the first await; source work and output publication use
/// the existing serialized executor. No second executor, page cache or Vault.
final class PagedTextRootCustody: @unchecked Sendable {
  static let maximumEntries = 64
  static let maximumJobs = 16
  static let maximumControllers = 8
  static let maximumClaims = 4
  static let metadataBytesPerEntry = 16_384 // fixed upper envelope, not encoded source
  static let maximumPayloadBytes = 4_194_304
  /// Window plus up to two bounded canonical projections (before/candidate).
  /// All entries still share the existing 4 MiB aggregate admission ceiling.
  static let maximumNativeMetadataBytes = 2 * PagedNativeCanonicalHistoryProjection.chargedBytes

  enum Purpose: Sendable, Equatable {
    case operation(UUID)
    case controller(UUID)
    case nativeBatch(sessionID: UUID, batchID: UUID, first: UInt64, last: UInt64)
    case nativePreparation(routeID: UUID, commandID: UUID)
    case nativePublication(routeID: UUID, preparationID: UUID)
    case retainedHistory(routeID: UUID, preparationID: UUID)
  }
  enum Phase: Sendable, Equatable {
    case admitted, running, output, liveController, preparedHistory, retainedHistory, unresolved
  }
  struct Item: Sendable {
    let id: UUID
    let purpose: Purpose
    let phase: Phase
    let claims: [PagedTextRootClaim]
    let payloadReservation: Int
    let producerJoined: Bool
    let writesAttempted: Bool
    let publicationAttempted: Bool
    let bulkActive: Bool
    let bulkOperationID: UUID?
    let controllerSessionID: UUID?
    let controllerSequence: UInt64
    let pendingBatchID: UUID?
    let sqlOperationID: UUID?
    let sqlReceivingJoined: Bool?
    /// Witness taken inside the real executor body, before it decrements its
    /// in-flight counters. Not a callback or a synthetic acknowledgement.
    let outputInFlightWitness: Int?
  }
  struct Snapshot: Sendable {
    let ownerID: UUID
    let engineIncarnation: UUID
    let closing: Bool
    let jobs: Int
    let reservedPayloadBytes: Int
    let metadataEnvelopeBytes: Int
    let items: [Item]
  }
  /// A bounded identity receipt from the actual worker-produced ACK. It keeps
  /// no text/window payload and is not a graph claim after installation. One
  /// last receipt permits an exact lost-finish-reply join at the same prefix.
  private struct NativeCommitReceipt: Sendable, Equatable {
    let sessionID: UUID
    let batchID: UUID
    let firstSequence: UInt64
    let lastSequence: UInt64
    let before: PagedDocumentRootRecord
    let after: PagedDocumentRootRecord
    let windowID: UUID
    let byteStart: UInt64
    let utf16Start: UInt64
    let lfStart: UInt64
    let sealedBytes: Int
    let canonicalHistory: PagedNativeCanonicalHistoryProjection?
    init(_ acknowledgement: PagedNativeCommitAcknowledgement, firstSequence: UInt64) {
      sessionID = acknowledgement.sessionID; batchID = acknowledgement.batchID
      self.firstSequence = firstSequence // actual admitted Root purpose, never guessed from last
      lastSequence = acknowledgement.lastSequence; before = acknowledgement.expectedRootRecord
      after = acknowledgement.sealedRootRecord; windowID = acknowledgement.sealedWindow.windowID
      byteStart = acknowledgement.sealedWindow.byteStart; utf16Start = acknowledgement.sealedWindow.utf16Start
      lfStart = acknowledgement.sealedWindow.lfStart; sealedBytes = acknowledgement.sealedBytes
      canonicalHistory = acknowledgement.canonicalHistory
    }
  }
  /// Refines the existing joined publication proof. No text, window or
  /// canonical projection is cached; this uses the same bounded Entry.
  private struct SQLiteHistoryPublication: Sendable {
    let store: PagedSQLiteNativeReceivingIdentity
    let receiving: PagedNativeReceivingHistoryIdentity
    let admission: PagedNativeHistoryAdmission
    let localCaretUTF16: Int
    let sealedBytes: Int
    var preparationID: UUID { receiving.preparationID }
    init(prepared: PagedNativePreparedHistoryMove,
      acknowledgement: PagedNativeHistoryAcknowledgement,
      store: PagedSQLiteNativeReceivingIdentity) throws {
      self.store = store
      receiving = try PagedNativeReceivingHistoryIdentity(prepared: prepared, acknowledgement: acknowledgement)
      admission = PagedNativeHistoryAdmission(commandID: acknowledgement.commandID,
        preparationID: acknowledgement.preparationID, sessionID: acknowledgement.sessionID,
        sourceArenaID: acknowledgement.sourceArenaID, provisionalArenaID: acknowledgement.provisionalArenaID,
        sourceWindowID: acknowledgement.sourceWindowID, preparedWindowID: acknowledgement.preparedWindowID,
        expectedSequence: acknowledgement.expectedSequence, admittedSequence: acknowledgement.admittedSequence,
        expectedRootRecord: acknowledgement.expectedRootRecord)
      try admission.validate(for: prepared)
      localCaretUTF16 = acknowledgement.localCaretUTF16; sealedBytes = acknowledgement.sealedBytes
    }
    func matches(_ prepared: PagedNativePreparedHistoryMove,
      admission: PagedNativeHistoryAdmission, store: PagedSQLiteNativeReceivingIdentity) -> Bool {
      self.store == store && self.admission == admission
        && receiving.engineIncarnation == store.engineIncarnation
        && receiving.routeID == prepared.routeID && receiving.preparationID == prepared.preparationID
        && receiving.command == prepared.command && receiving.afterRecord == prepared.candidateRecord
        && receiving.cursor == prepared.cursor && receiving.preparedWindowID == prepared.window.windowID
        && localCaretUTF16 == prepared.localCaretUTF16 && sealedBytes == prepared.windowBytes
    }
  }
  enum SQLIntent: Sendable {
    case producer
    case setup
    case native(PagedNativeCommitBatch)
    case history(PagedNativePreparedHistoryMove, PagedNativeHistoryAdmission)
    case workspace(PreparedPagedWorkspace, [PagedDocumentRootRecord], expectedHead: PagedWorkspaceHead?)
    case metadata(WorkspaceMetadataInput, PreparedWorkspaceMetadata, expectedHead: PagedWorkspaceHead?)
  }
  enum SQLOutput: Sendable {
    case native(PagedNativeCommitAcknowledgement)
    case history(PagedNativeHistoryAcknowledgement)
    case workspace(PagedWorkspaceSnapshot)
    case metadata(WorkspaceMetadataPublication)
  }
  /// The sole live SQL outcome on this existing entry. Input/output share their
  /// immutable buffers with the admitted caller; no serialization or SQL mirror.
  struct SQLState: Sendable {
    let operation: PagedSQLiteOperationIdentity
    let intent: SQLIntent
    let producer: PagedTextRootLease
    var execution: PagedSQLiteExecution?
    var output: SQLOutput?
    var receivingJoined = false
    var engineJoined = false // actual C/cache work, never autocommit or a callback-drain flag
    var retryAdmitted = false
    var firstFailure: Error?
  }
  private struct Entry {
    let purpose: Purpose
    var phase: Phase
    var claims: [PagedTextRootClaim]
    let payloadReservation: Int
    var producerJoined = false
    var writesAttempted = false
    var publicationAttempted = false
    var outputInFlightWitness: Int?
    var preparation: PagedNativePreparedHistoryMove?
    var bulkActive = false
    var bulkOperationID: UUID?
    var headTransferActive = false
    var controllerSessionID: UUID?
    var controllerSequence: UInt64 = 0
    var verifiedHistoryBefore: UUID?
    var verifiedHistoryPublished: SQLiteHistoryPublication?
    var currentControllerRecord: PagedDocumentRootRecord?
    var pendingBatchID: UUID?
    var nativeCommit: NativeCommitReceipt?
    var lastInstalledCommit: NativeCommitReceipt?
    var sql: SQLState?
    var inputReservation = 0
    var nativeInput: PagedNativeCommitBatch?
    var metadataInput: WorkspaceMetadataInput?
    var importedOriginal: PagedTextImportedRevision?
    var lastHistoryReceiving: SQLiteHistoryPublication?
    var isJob: Bool
  }
  private struct State {
    var entries: [UUID: Entry] = [:]
    var jobs = 0
    var controllers = 0
    var reservedPayloadBytes = 0
    var closing = false
    // Deliberate bounded custody: dropping a caller must not deinit/close the
    // engine while unresolved roots survive. Exact explicit joined resolution
    // releases this SAME instance when the last entry is removed.
    var retainedEngine: PagedTextEngineAdapter?
  }
  let ownerID: UUID
  let engineIncarnation = UUID()
  private let state = Mutex(State())

  init(ownerID: UUID) { self.ownerID = ownerID }
  var snapshot: Snapshot {
    state.withLock { value in
      Snapshot(ownerID: ownerID, engineIncarnation: engineIncarnation, closing: value.closing,
        jobs: value.jobs, reservedPayloadBytes: value.reservedPayloadBytes,
        metadataEnvelopeBytes: value.entries.count * Self.metadataBytesPerEntry,
        items: value.entries.map { key, entry in
          Item(id: key, purpose: entry.purpose, phase: entry.phase, claims: entry.claims,
            payloadReservation: entry.payloadReservation, producerJoined: entry.producerJoined,
            writesAttempted: entry.writesAttempted, publicationAttempted: entry.publicationAttempted,
            bulkActive: entry.bulkActive, bulkOperationID: entry.bulkOperationID,
            controllerSessionID: entry.controllerSessionID, controllerSequence: entry.controllerSequence,
            pendingBatchID: entry.pendingBatchID,
            sqlOperationID: entry.sql?.operation.operationID,
            sqlReceivingJoined: entry.sql?.receivingJoined,
            outputInFlightWitness: entry.outputInFlightWitness)
        })
    }
  }

  func reserve(engine: PagedTextEngineAdapter, purpose: Purpose,
    claims: [PagedTextRootClaim], payloadBytes: Int = 0, metadataBytes: Int = 0,
    nativeInput: PagedNativeCommitBatch? = nil, workspaceDocuments: [PagedDocumentRootRecord]? = nil,
    metadataInput: WorkspaceMetadataInput? = nil) throws -> PagedTextRootLease {
    try validate(claims)
    guard engine.ownerID == ownerID, engine.custodyIncarnation == engineIncarnation else {
      throw BoomError.denied("Root admission has another engine incarnation.")
    }
    guard payloadBytes >= 0, payloadBytes <= PagedTextWindow.maximumBytes,
      metadataBytes >= 0, metadataBytes <= Self.maximumNativeMetadataBytes else {
      throw BoomError.budget("Root job exceeds its bounded window/metadata reservation.")
    }
    let totalBytes = payloadBytes + metadataBytes
    guard [nativeInput != nil, workspaceDocuments != nil, metadataInput != nil].filter({ $0 }).count <= 1 else { throw BoomError.invalid("Root input cannot combine unrelated ordinary text/metadata owners.") }
    let inputBytes: Int
    if let metadataInput {
      guard purpose == .operation(metadataInput.inputID) else { throw BoomError.stale("Metadata Root purpose differs from its single immutable input.") }
      let records = try metadataInput.initialDocuments.map(Self.workspaceInputCharge) ?? 0
      guard metadataInput.retainedBytes >= 0, metadataInput.retainedBytes <= WorkspaceMetadataInput.maximumInputBytes,
        records <= Self.maximumPayloadBytes - metadataInput.retainedBytes else { throw BoomError.budget("Metadata plus actual input records exceed Root's existing aggregate.") }
      inputBytes = records + metadataInput.retainedBytes
    } else { inputBytes = try (nativeInput.map(Self.nativeInputCharge) ?? workspaceDocuments.map(Self.workspaceInputCharge) ?? 0) }
    if let nativeInput {
      guard purpose == .nativeBatch(sessionID: nativeInput.sessionID, batchID: nativeInput.batchID,
        first: nativeInput.firstSequence, last: nativeInput.lastSequence) else { throw BoomError.stale("Root input has another admitted native purpose.") }
    }
    return try state.withLock { value in
      guard !value.closing, value.jobs < Self.maximumJobs else {
        throw BoomError.unavailable("Root custody is closing or has too many admitted jobs.")
      }
      try admitEntry(value, payloadBytes: totalBytes + inputBytes)
      if let metadataInput { try admitMetadataDocuments(metadataInput, in: value) }
      if case .controller = purpose {
        for entry in value.entries.values where entry.sql?.receivingJoined != true {
          guard entry.metadataInput?.changedDocumentIDs.isDisjoint(with: claims.compactMap { claim in
            if case .record(let record) = claim { return record.document.id }; return nil
          }) != false else { throw BoomError.unavailable("A document metadata producer has not joined its actual receiving owner.") }
        }
        guard value.controllers < Self.maximumControllers else {
          throw BoomError.unavailable("Root custody has reached its native-controller bound.")
        }
        value.controllers += 1
      }
      let lease = mint()
      value.entries[lease.id] = Entry(purpose: purpose, phase: .admitted,
        claims: claims, payloadReservation: totalBytes, inputReservation: inputBytes, nativeInput: nativeInput, metadataInput: metadataInput, isJob: true)
      value.jobs += 1; value.reservedPayloadBytes += totalBytes + inputBytes; value.retainedEngine = engine
      return lease
    }
  }
  /// The close caller already joined bulk admission and all preceding executor
  /// work. This is the SAME workspace metadata job, admitted only from an empty
  /// closing ledger before any receipt transaction/checkpoint can begin. A
  /// failure uses joinedFailure and retains this exact Engine for repair.
  func reserveClosingMaintenance(engine: PagedTextEngineAdapter) throws -> PagedTextRootLease {
    guard engine.ownerID == ownerID, engine.custodyIncarnation == engineIncarnation else {
      throw BoomError.denied("Closing maintenance has another actual engine incarnation.")
    }
    return try state.withLock { value in
      guard value.closing, value.entries.isEmpty, value.jobs == 0, value.controllers == 0 else {
        throw BoomError.unavailable("Closing maintenance cannot replace a live or unresolved root owner.")
      }
      try admitEntry(value, payloadBytes: 0)
      let lease = mint()
      value.entries[lease.id] = Entry(purpose: .operation(UUID()), phase: .admitted,
        claims: [.workspace], payloadReservation: 0, isJob: true)
      value.jobs = 1; value.retainedEngine = engine
      return lease
    }
  }
  func start(_ lease: PagedTextRootLease) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .admitted, !entry.producerJoined else {
        throw BoomError.stale("Root job has already started or joined.")
      }
      entry.phase = .running; value.entries[lease.id] = entry
    }
  }
  func willWrite(_ lease: PagedTextRootLease, documentID: UUID) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running,
        entry.claims.contains(.writerDocument(documentID)) else {
        throw BoomError.denied("Page mutation has no pre-admitted document writer custody.")
      }
      entry.writesAttempted = true; value.entries[lease.id] = entry
    }
  }
  func willPublish(_ lease: PagedTextRootLease) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, entry.claims.contains(.workspace) else {
        throw BoomError.denied("Workspace publication has no pre-admitted journal custody.")
      }
      entry.publicationAttempted = true; value.entries[lease.id] = entry
    }
  }
  func willWriteWorkspace(_ lease: PagedTextRootLease) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, entry.claims.contains(.workspace) else {
        throw BoomError.denied("Workspace preparation has no pre-admitted metadata custody.")
      }
      entry.writesAttempted = true; value.entries[lease.id] = entry
    }
  }
  func willBeginBulk(_ lease: PagedTextRootLease) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, !entry.bulkActive else {
        throw BoomError.stale("Bulk operation has another or unjoined custody owner.")
      }
      entry.bulkActive = true; value.entries[lease.id] = entry
    }
  }
  func beganBulk(_ lease: PagedTextRootLease, operationID: UUID) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.bulkActive, entry.bulkOperationID == nil else { throw BoomError.stale("Bulk custody already has an operation identity.") }
      entry.bulkOperationID = operationID; value.entries[lease.id] = entry
    }
  }
  func joinedBulk(_ lease: PagedTextRootLease, operationID: UUID) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.bulkActive, entry.bulkOperationID == operationID else { throw BoomError.stale("Bulk join has another exact operation identity.") }
      entry.bulkActive = false; value.entries[lease.id] = entry
    }
  }
  func unresolvedBulk(_ lease: PagedTextRootLease) throws -> UUID {
    try state.withLock { value in
      let entry = try require(lease, in: value)
      guard entry.phase == .unresolved, entry.bulkActive, let id = entry.bulkOperationID else {
        throw BoomError.unavailable("Uncertain bulk admission has no known exact operation to join.")
      }
      return id
    }
  }
  /// Install exact candidate reachability before the coherent publisher can
  /// write its journal. Admission was reserved before any page mutation.
  func candidate(_ lease: PagedTextRootLease, claims: [PagedTextRootClaim]) throws {
    try validate(claims)
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running else { throw BoomError.stale("Candidate has no running producer.") }
      entry.claims = claims; value.entries[lease.id] = entry
    }
  }
  func finishOutput(_ lease: PagedTextRootLease, claims: [PagedTextRootClaim], payloadBytes: Int,
    inFlightWitness: Int, preparation: PagedNativePreparedHistoryMove? = nil,
    historyBeforeProof: UUID? = nil, importedOriginal: PagedTextImportedRevision? = nil,
    nativeAcknowledgement: PagedNativeCommitAcknowledgement? = nil,
    nativeHistoryPublication: (prepared: PagedNativePreparedHistoryMove,
      acknowledgement: PagedNativeHistoryAcknowledgement,
      store: PagedSQLiteNativeReceivingIdentity, committedOperationID: UUID?)? = nil) throws {
    try validate(claims)
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, !entry.producerJoined, !entry.bulkActive,
        entry.sql == nil || entry.sql?.engineJoined == true,
        payloadBytes >= 0, payloadBytes <= entry.payloadReservation, inFlightWitness > 0 else {
        throw BoomError.invalid("Root output exceeds admission or was returned after producer accounting ended.")
      }
      entry.claims = claims
      if let importedOriginal {
        guard PagedWorkspaceObjectReference.isDigest(importedOriginal.wholeTextSha256),
          claims.contains(.source(importedOriginal.revision)),
          claims.contains(.writerDocument(importedOriginal.revision.documentID)) else {
          throw BoomError.denied("Actual import provenance lost its source/writer output.")
        }
        entry.importedOriginal = importedOriginal // only import_finish supplies this real result
      }
      if let preparation { entry.preparation = preparation }
      entry.verifiedHistoryBefore = historyBeforeProof
      entry.verifiedHistoryPublished = nil
      if let acknowledgement = nativeAcknowledgement {
        guard case .nativeBatch(let sessionID, let batchID, let first, let last) = entry.purpose else {
          throw BoomError.invalid("Native output has no actual admitted first/last sequence purpose.")
        }
        let receipt = NativeCommitReceipt(acknowledgement, firstSequence: first)
        guard
          receipt.sessionID == sessionID, receipt.batchID == batchID, receipt.lastSequence == last,
          acknowledgement.canonicalHistory == nil || acknowledgement.canonicalHistory?.scope
            == .nativeBatch(sessionID: sessionID, batchID: batchID, first: first, last: last),
          claims.contains(.record(receipt.before)), claims.contains(.record(receipt.after)),
          receipt.sealedBytes + (acknowledgement.canonicalHistory == nil ? 0 : PagedNativeCanonicalHistoryProjection.chargedBytes) == payloadBytes else {
          throw BoomError.invalid("Native output has another actual worker ACK identity.")
        }
        entry.nativeCommit = receipt
      }
      if let publication = nativeHistoryPublication {
        try publication.store.admit(ownerID: ownerID, engineIncarnation: engineIncarnation)
        let prepared = publication.prepared, acknowledgement = publication.acknowledgement
        let receipt = try SQLiteHistoryPublication(prepared: prepared,
          acknowledgement: acknowledgement, store: publication.store)
        guard acknowledgement.canonicalHistory?.producer == (entry.sql?.producer ?? lease),
          claims.contains(.record(prepared.command.expectedRootRecord)),
          claims.contains(.record(prepared.candidateRecord)),
          payloadBytes == acknowledgement.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes else {
          throw BoomError.invalid("SQL history output lost its actual bounded producer, records or command.")
        }
        if let committedOperationID = publication.committedOperationID {
          // Engine supplies this only AFTER this actual SQL write returned
          // COMMIT success and namespace admission. Inspection cannot mint it.
          guard entry.publicationAttempted, entry.sql?.execution?.selectedAfter == true,
            case .some(.history(let original, let admission)) = entry.sql?.intent,
            original == prepared, admission == receipt.admission,
            committedOperationID == prepared.preparationID else {
            throw BoomError.denied("Actual history success has another admitted operation/intent.")
          }
          entry.verifiedHistoryPublished = receipt
        } else {
          // A new read-only inspection producer may inherit only a live,
          // already joined known-success proof, never mere visible SQL rows.
          guard case .operation = entry.purpose,
            let original = matchingSQLiteHistory(in: value, prepared: prepared,
              admission: receipt.admission, store: publication.store) else {
            throw BoomError.denied("History inspection has no exact joined successful SQL publication.")
          }
          entry.verifiedHistoryPublished = original
        }
      }
      // A successful preparation finished any admission/recovery work and did
      // not admit this command's publication. Future admission marks it anew.
      if preparation != nil {
        entry.publicationAttempted = false
        entry.sql = nil
      }
      entry.phase = preparation == nil ? .output : .preparedHistory
      entry.producerJoined = true; entry.isJob = false; entry.outputInFlightWitness = inFlightWitness
      value.jobs -= 1; value.entries[lease.id] = entry
    }
  }
  /// A read-only operation has no root-bearing return value. It releases only
  /// after its C request/stream owner joins. Used INSIDE the real queue body.
  func finishRead(_ lease: PagedTextRootLease) throws {
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      let entry = try require(lease, in: value)
      guard entry.isJob, !entry.writesAttempted, !entry.publicationAttempted, !entry.bulkActive else {
        throw BoomError.invalid("A mutating root job cannot finish as an unretained read.")
      }
      return remove(lease.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }
  func beganSQLiteOperation(_ lease: PagedTextRootLease, operation: PagedSQLiteOperationIdentity,
    intent: SQLIntent = .producer) throws {
    try operation.store.admit(ownerID: ownerID, engineIncarnation: engineIncarnation)
    if case .native(let input) = intent { try admitActualNativeInput(lease, batch: input) }
    if case .metadata(let input, let prepared, _) = intent {
      let retained = try state.withLock { try require(lease, in: $0).metadataInput }
      guard retained?.inputID == input.inputID, prepared.inputID == input.inputID else { throw BoomError.stale("SQL metadata input is not its actual pre-yield Root owner.") }
    }
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, !entry.producerJoined else { throw BoomError.stale("SQL has no actual running producer.") }
      if let previous = entry.sql {
        // Bulk staging may replace an already joined candidate quantum. It
        // may never overwrite an unresolved or unreceived head publication.
        guard (previous.execution?.outcome == .committed && previous.execution?.publication == nil && previous.output == nil)
          || (previous.operation == operation && previous.execution?.selectedBefore == true && previous.retryAdmitted) else {
          throw BoomError.stale("The previous live SQL outcome still owns this entry.")
        }
      }
      if case .native(let input) = intent {
        guard entry.nativeInput?.batchID == input.batchID else { throw BoomError.stale("SQL input is not the actual retained ordered batch.") }
        entry.nativeInput = nil // intent now owns those SAME immutable buffers
      }
      if case .metadata = intent { entry.metadataInput = nil } // SAME buffers now held by sql.intent
      let firstFailure = entry.sql?.firstFailure
      entry.sql = SQLState(operation: operation, intent: intent, producer: lease, firstFailure: firstFailure)
      value.entries[lease.id] = entry
    }
  }
  /// Store calls this while the real executor body still owns the entry. All
  /// authority/capacity admission preceded BEGIN; recording actual success is
  /// infallible and cannot lose a COMMIT to a late allocation/check exception.
  func finishedSQLiteExecution(_ lease: PagedTextRootLease, execution: PagedSQLiteExecution, engineJoined: Bool = true) {
    state.withLock { value in
      precondition(lease.ownerID == ownerID && lease.engineIncarnation == engineIncarnation)
      guard var entry = value.entries[lease.id], var sql = entry.sql else { preconditionFailure("Actual SQL result lost its admitted Root owner.") }
      precondition(entry.isJob && entry.phase == .running && sql.operation == execution.identity)
      sql.execution = execution; sql.engineJoined = engineJoined; sql.retryAdmitted = false
      if sql.firstFailure == nil { sql.firstFailure = execution.original }
      entry.sql = sql; value.entries[lease.id] = entry
    }
  }
  func joinedSQLiteEngine(_ lease: PagedTextRootLease) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, entry.sql?.execution != nil else { throw BoomError.stale("Actual C/cache join lost its retained SQL operation.") }
      entry.sql?.engineJoined = true; value.entries[lease.id] = entry
    }
  }
  func stageSQLNativeOutput(_ lease: PagedTextRootLease, output: SQLOutput) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, var sql = entry.sql, sql.output == nil else { throw BoomError.stale("Staged output lost its actual SQL producer.") }
      switch (sql.intent, output) {
      case (.native(let batch), .native(let ack)):
        guard ack.sessionID == batch.sessionID, ack.batchID == batch.batchID,
          ack.lastSequence == batch.lastSequence, ack.expectedRootRecord == batch.expectedRootRecord,
          ack.canonicalHistory?.producer == sql.producer,
          ack.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes <= entry.payloadReservation else { throw BoomError.stale("Actual native candidate exceeds its admitted input/output.") }
      case (.history(let prepared, let admission), .history(let ack)):
        try admission.validate(for: prepared)
        guard ack.preparationID == prepared.preparationID, ack.sealedRootRecord == prepared.candidateRecord,
          ack.canonicalHistory?.producer == sql.producer,
          ack.sealedBytes + PagedNativeCanonicalHistoryProjection.chargedBytes <= entry.payloadReservation else { throw BoomError.stale("Actual history candidate differs from its prepared command.") }
      case (.workspace(_, let documents, _), .workspace(let snapshot)):
        guard snapshot.documents == documents else { throw BoomError.stale("Actual workspace candidate changed its immutable record inventory.") }
      case (.metadata(let input, let prepared, _), .metadata(let result)):
        guard input.inputID == prepared.inputID, result.head.workspace.hasSameSettingsPayload(as: prepared.settings),
          metadataDocumentOutputMatches(input, result: result),
          result.changes == (zip(input.entities, prepared.entities).map({ WorkspaceMetadataChange(before: $0.0.expected, after: $0.1) })
            + input.removals.map({ WorkspaceMetadataChange(before: $0.expected, after: nil) })) else { throw BoomError.stale("Metadata candidate differs from its actual typed prepared input.") }
      default: throw BoomError.denied("SQL output has another actual admitted intent.")
      }
      sql.output = output; entry.sql = sql; value.entries[lease.id] = entry
    }
  }
  func beginSQLResolution(_ lease: PagedTextRootLease) throws -> SQLState {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard !metadataHoldsProducer(lease.id, in: value), entry.producerJoined, !entry.isJob, !entry.bulkActive, !entry.headTransferActive,
        entry.phase == .unresolved || entry.phase == .output || entry.phase == .preparedHistory,
        let sql = entry.sql, sql.execution != nil, value.jobs < Self.maximumJobs else { throw BoomError.stale("Resolution cannot replace an unjoined producer or another outcome.") }
      entry.isJob = true; entry.producerJoined = false; entry.phase = .admitted
      value.jobs += 1; value.entries[lease.id] = entry; return sql
    }
  }
  func sqlState(_ lease: PagedTextRootLease) throws -> SQLState? {
    try state.withLock { try require(lease, in: $0).sql }
  }
  func finishSQLBefore(_ lease: PagedTextRootLease, execution: PagedSQLiteExecution,
    inFlightWitness: Int) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, !entry.bulkActive,
        entry.sql?.operation == execution.identity, entry.sql?.engineJoined == true,
        execution.selectedBefore, inFlightWitness > 0 else { throw BoomError.stale("Known BEFORE lost its actual joined producer.") }
      entry.sql?.execution = execution; entry.sql?.output = nil
      entry.producerJoined = true; entry.isJob = false; entry.phase = .unresolved
      if case .some(.history(let prepared, _)) = entry.sql?.intent {
        entry.verifiedHistoryBefore = prepared.preparationID
        entry.publicationAttempted = false; entry.phase = .preparedHistory
      }
      value.jobs -= 1; value.entries[lease.id] = entry
    }
  }
  func cancelResolvedWorkspaceBefore(_ lease: PagedTextRootLease,
    execution: PagedSQLiteExecution) throws -> Error? {
    let retained = try state.withLock { value -> (PagedTextEngineAdapter?, Error?) in
      let entry = try require(lease, in: value)
      guard case .operation = entry.purpose, entry.phase == .unresolved,
        entry.producerJoined, !entry.isJob, !entry.bulkActive,
        let sql = entry.sql,
        sql.execution === execution, sql.operation == execution.identity,
        sql.engineJoined, !sql.retryAdmitted, !sql.receivingJoined,
        execution.outcome == .resolved(.before), sql.output == nil else {
        throw BoomError.stale("Metadata cancellation lost its exact resolved BEFORE/producer scope.")
      }
      switch sql.intent { case .workspace, .metadata: break
      default: throw BoomError.stale("Cancellation cannot consume another actual Root intent.") }
      let original = sql.firstFailure ?? execution.original
      return (remove(lease.id, from: &value), original)
    }
    withExtendedLifetime(retained.0) {}
    return retained.1
  }
  /// Explicitly admit a single retry of the SAME known-unpublished intent. The
  /// caller rechecks the full source/head CAS, sequence and failure serial.
  /// Accepted prefix/later input stay retained; unknown outcomes never enter.
  func admitSQLBeforeRetry(_ lease: PagedTextRootLease) throws -> SQLState {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.producerJoined, !entry.isJob, !entry.bulkActive,
        let sql = entry.sql, sql.execution?.selectedBefore == true,
        value.jobs < Self.maximumJobs else { throw BoomError.stale("Explicit retry has no exact known-unpublished producer.") }
      entry.sql?.retryAdmitted = true; entry.verifiedHistoryBefore = nil
      if case .native(let input) = sql.intent { entry.nativeInput = input }
      if case .metadata(let input, _, _) = sql.intent { entry.metadataInput = input }
      entry.isJob = true; entry.producerJoined = false; entry.phase = .admitted
      value.jobs += 1; value.entries[lease.id] = entry; return sql
    }
  }
  func hasJoinedSQLiteRollback(_ prepared: PagedNativePreparedHistoryMove,
    store: PagedSQLiteNativeReceivingIdentity) throws -> Bool {
    try store.admit(ownerID: ownerID, engineIncarnation: engineIncarnation)
    return state.withLock { value in
      value.entries.values.contains { entry in
        entry.producerJoined && !entry.isJob && !entry.bulkActive && entry.preparation == prepared
          && entry.sql?.operation == PagedSQLiteOperationIdentity(store: store, operationID: prepared.preparationID)
          && entry.sql?.execution?.selectedBefore == true && entry.sql?.engineJoined == true
          && entry.claims.contains(.record(prepared.command.expectedRootRecord))
          && entry.claims.contains(.record(prepared.candidateRecord))
      }
    }
  }
  func finishSQLProducerDisposition(_ lease: PagedTextRootLease, execution: PagedSQLiteExecution,
    inFlightWitness: Int) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.isJob, entry.phase == .running, !entry.bulkActive,
        entry.sql?.operation == execution.identity, execution.outcome != .unknown,
        execution.publication == nil, entry.preparation == nil, inFlightWitness > 0 else { throw BoomError.stale("Producer disposition cannot consume a real published/native output.") }
      switch entry.sql?.intent { case .some(.producer), .some(.setup): break; default: throw BoomError.denied("Actual consumer must receive this retained output.") }
      entry.sql?.execution = execution; entry.sql?.receivingJoined = true
      entry.isJob = false; entry.producerJoined = true; entry.phase = .output
      entry.outputInFlightWitness = inFlightWitness
      value.jobs -= 1; value.entries[lease.id] = entry
    }
  }
  func finishJoinedSetupClose(_ lease: PagedTextRootLease, inFlightWitness: Int) throws {
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      let entry = try require(lease, in: value)
      guard case .operation = entry.purpose, entry.isJob, entry.phase == .running,
        entry.preparation == nil, !entry.bulkActive, entry.claims == [.workspace], inFlightWitness > 0 else { throw BoomError.stale("Physical setup cleanup lost its original owner.") }
      return remove(lease.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }

  /// Covers both errors inside a producer and queue admission/cancellation
  /// before that body starts. Written pages or an attempted journal stay pinned.
  func joinedFailure(_ lease: PagedTextRootLease) throws -> Bool {
    var retained: PagedTextEngineAdapter?
    let preserved = try state.withLock { value -> Bool in
      guard value.entries[lease.id] != nil else { return false }
      var entry = try require(lease, in: value)
      let enteredNative: Bool
      switch entry.purpose { case .nativeBatch, .nativePublication: enteredNative = entry.sql != nil; default: enteredNative = false }
      // Generic checked rollback joins actual cache/bulk work without a root
      // return. Accepted native/history input retains the SAME outcome even
      // when early full-record CAS rejected before write/publication flags.
      if case .operation = entry.purpose, entry.sql?.execution?.selectedBefore == true, entry.sql?.engineJoined == true,
        !entry.bulkActive, entry.preparation == nil {
        switch entry.sql?.intent {
        case .some(.producer): retained = remove(lease.id, from: &value); return false
        default: break
        }
      }
      if !enteredNative, entry.sql == nil, !entry.writesAttempted && !entry.publicationAttempted && !entry.bulkActive {
        retained = remove(lease.id, from: &value); return false
      }
      if entry.isJob && !entry.bulkActive { value.jobs -= 1; entry.isJob = false }
      entry.producerJoined = !entry.bulkActive; entry.phase = .unresolved; value.entries[lease.id] = entry
      return true
    }
    withExtendedLifetime(retained) {}
    return preserved
  }

  func makeController(from output: PagedTextRootLease, routeID: UUID,
    record: PagedDocumentRootRecord) throws -> PagedTextRootLease {
    try validate([.record(record)])
    try state.withLock { value in
      var entry = try require(output, in: value)
      guard entry.producerJoined, entry.phase == .output, entry.claims == [.record(record)],
        entry.purpose == .controller(routeID) else {
        throw BoomError.unavailable("Native owner output is unjoined, mismatched or the controller bound is full.")
      }
      // The output reservation becomes the live controller; no extra entry or
      // first pin is allocated in an actor callback.
      entry = Entry(purpose: .controller(routeID), phase: .liveController,
        claims: [.record(record)], payloadReservation: entry.payloadReservation,
        producerJoined: true, outputInFlightWitness: entry.outputInFlightWitness,
        currentControllerRecord: record, isJob: false)
      value.entries[output.id] = entry
    }
    return output
  }
  func installControllerOutput(_ output: PagedTextRootLease, into controller: PagedTextRootLease,
    expected: PagedDocumentRootRecord, record: PagedDocumentRootRecord) throws {
    try validate([.record(record)])
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      var receiver = try require(controller, in: value)
      let producer = try require(output, in: value)
      guard producer.payloadReservation <= receiver.payloadReservation, receiver.inputReservation == 0,
        case .controller = receiver.purpose, receiver.phase == .liveController,
        receiver.currentControllerRecord == expected, receiver.sql == nil, producer.producerJoined,
        producer.phase == .output, producer.claims.contains(.record(record)) else {
        throw BoomError.stale("Native output cannot transfer to this exact live controller record.")
      }
      switch producer.purpose {
      case .nativeBatch(let sessionID, let batchID, let first, let last):
        let next = receiver.controllerSequence.addingReportingOverflow(1)
        guard !next.overflow, first == next.partialValue, last >= first, receiver.pendingBatchID == nil,
          receiver.controllerSessionID == nil || receiver.controllerSessionID == sessionID,
          let receipt = producer.nativeCommit, receipt.before == expected, receipt.after == record else {
          throw BoomError.stale("Native output custody has another controller or admitted sequence.")
        }
        receiver.controllerSessionID = sessionID; receiver.controllerSequence = last
        receiver.pendingBatchID = batchID; receiver.currentControllerRecord = record
        receiver.lastHistoryReceiving = nil
        receiver.nativeCommit = receipt; receiver.lastInstalledCommit = nil
        receiver.sql = producer.sql
        receiver.inputReservation = producer.inputReservation
        receiver.nativeInput = producer.nativeInput
        value.reservedPayloadBytes += producer.inputReservation
        // The storage actor is not the native ACK consumer. A compacted batch
        // can evict its before-source from Undo; hold both exact records and
        // all writer outputs until actual installation/next-input confirmation.
        receiver.claims = producer.claims
      case .operation:
        guard record == expected else { throw BoomError.denied("A navigation output cannot advance a controller root.") }
      default: throw BoomError.denied("This producer is not a native batch or navigation output.")
      }
      value.entries[controller.id] = receiver
      return remove(output.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }
  /// Fresh canonical opening binds its exact Session before the first await.
  /// It cannot confirm/drop a pending ACK or reuse an already opened owner.
  func bindNativeOpening(_ controller: PagedTextRootLease, sessionID: UUID,
    record: PagedDocumentRootRecord) throws {
    try state.withLock { value in
      var entry = try require(controller, in: value)
      guard case .controller = entry.purpose, entry.phase == .liveController,
        entry.controllerSessionID == nil, entry.controllerSequence == 0,
        entry.pendingBatchID == nil, entry.sql == nil, entry.currentControllerRecord == record else {
        throw BoomError.stale("Canonical opening has another already bound native controller.")
      }
      entry.controllerSessionID = sessionID
      value.entries[controller.id] = entry
    }
  }
  @discardableResult
  func confirmNativeInput(_ controller: PagedTextRootLease, sessionID: UUID,
    sequence: UInt64, record: PagedDocumentRootRecord) throws -> PagedSQLiteExecution? {
    try state.withLock { value in
      var entry = try require(controller, in: value)
      guard case .controller = entry.purpose, entry.phase == .liveController,
        entry.currentControllerRecord == record, entry.controllerSequence == sequence,
        entry.controllerSessionID == nil || entry.controllerSessionID == sessionID else { throw BoomError.stale("Native input does not confirm this exact controller prefix.") }
      if entry.pendingBatchID != nil {
        guard let receipt = entry.nativeCommit else { throw BoomError.invalid("Actual pending ACK lost its identity.") }
        entry.pendingBatchID = nil; entry.lastInstalledCommit = receipt; entry.nativeCommit = nil
        entry.sql?.receivingJoined = true
      }
      value.entries[controller.id] = entry
      return entry.sql?.execution
    }
  }
  @discardableResult
  func finishNativeCommit(_ controller: PagedTextRootLease,
    acknowledgement: PagedNativeCommitAcknowledgement) throws -> PagedSQLiteExecution? {
    try state.withLock { value in
      var entry = try require(controller, in: value)
      guard let actual = entry.nativeCommit ?? entry.lastInstalledCommit else { throw BoomError.stale("Native finish has no actual admitted batch receipt.") }
      let receipt = NativeCommitReceipt(acknowledgement, firstSequence: actual.firstSequence)
      guard case .controller = entry.purpose, entry.phase == .liveController,
        entry.controllerSessionID == receipt.sessionID, entry.controllerSequence == receipt.lastSequence,
        entry.currentControllerRecord == receipt.after, receipt == actual else { throw BoomError.stale("Native finish has another actual ACK/source/sequence.") }
      if let sql = entry.sql {
        guard sql.execution?.selectedAfter == true,
          sql.operation.operationID == receipt.batchID,
          sql.execution?.publication?.beforeRecord == receipt.before,
          sql.execution?.publication?.afterRecord == receipt.after else { throw BoomError.stale("Actual native receiving has an unresolved or foreign SQL outcome.") }
      }
      entry.pendingBatchID = nil; entry.nativeCommit = nil; entry.lastInstalledCommit = receipt
      entry.sql?.receivingJoined = true; value.entries[controller.id] = entry
      return entry.sql?.execution
    }
  }
  /// A reply may be lost AFTER the actual backend transferred the original
  /// output to its controller. Borrow that SAME ACK/input; never re-create or
  /// install a producer, and keep both records until Main's actual finish.
  func borrowNativeAcknowledgement(_ controller: PagedTextRootLease,
    batch: PagedNativeCommitBatch, store: PagedSQLiteNativeReceivingIdentity)
    throws -> (acknowledgement: PagedNativeCommitAcknowledgement, execution: PagedSQLiteExecution) {
    try store.admit(ownerID: ownerID, engineIncarnation: engineIncarnation)
    try admitActualNativeInput(controller, batch: batch) // bounded comparison outside the mutex
    return try state.withLock { value in
      let entry = try require(controller, in: value)
      guard case .controller = entry.purpose, entry.phase == .liveController,
        entry.producerJoined, !entry.isJob, !entry.bulkActive, !entry.headTransferActive,
        entry.pendingBatchID == batch.batchID, entry.controllerSessionID == batch.sessionID,
        entry.controllerSequence == batch.lastSequence, let sql = entry.sql,
        sql.engineJoined, !sql.receivingJoined,
        sql.operation == PagedSQLiteOperationIdentity(store: store, operationID: batch.batchID),
        case .native = sql.intent, case .some(.native(let acknowledgement)) = sql.output,
        let execution = sql.execution, execution.selectedAfter,
        execution.publication?.beforeRecord == batch.expectedRootRecord,
        execution.publication?.afterRecord == acknowledgement.sealedRootRecord,
        entry.currentControllerRecord == acknowledgement.sealedRootRecord,
        acknowledgement.sessionID == batch.sessionID, acknowledgement.batchID == batch.batchID,
        acknowledgement.lastSequence == batch.lastSequence, acknowledgement.expectedRootRecord == batch.expectedRootRecord,
        acknowledgement.canonicalHistory?.producer == sql.producer,
        entry.nativeCommit == NativeCommitReceipt(acknowledgement, firstSequence: batch.firstSequence),
        entry.claims.contains(.record(batch.expectedRootRecord)),
        entry.claims.contains(.record(acknowledgement.sealedRootRecord)) else {
        throw BoomError.stale("The controller does not retain this exact original unreceived ACK/input.")
      }
      return (acknowledgement, execution)
    }
  }

  /// Called immediately after Store's real same-executor physical fence release.
  /// Both records/input/output remain pinned until this exact receiving join.
  func finishSQLReceiving(_ lease: PagedTextRootLease, execution: PagedSQLiteExecution) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard let sql = entry.sql, sql.execution === execution, sql.receivingJoined,
        execution.outcome != .unknown, !entry.isJob, entry.producerJoined else { throw BoomError.stale("SQL receiving has another actual joined outcome.") }
      switch sql.intent {
      case .workspace, .metadata: return // same retained exact finish; caller explicitly releases
      default: break
      }
      value.reservedPayloadBytes -= entry.inputReservation
      entry.inputReservation = 0; entry.nativeInput = nil; entry.sql = nil
      if let record = entry.currentControllerRecord { entry.claims = [.record(record)] }
      value.entries[lease.id] = entry
    }
  }

  func retainHistory(_ prepared: PagedNativePreparedHistoryMove,
    engine: PagedTextEngineAdapter) throws -> PagedNativeRetainedHistoryIntent {
    let claims: [PagedTextRootClaim] = [.record(prepared.command.expectedRootRecord),
      .record(prepared.candidateRecord), .writerDocument(prepared.command.handle.documentID)]
    try validate(claims)
    guard engine.ownerID == ownerID, engine.custodyIncarnation == engineIncarnation else {
      throw BoomError.denied("History recipient has another engine incarnation.")
    }
    return try state.withLock { value in
      guard value.entries.values.contains(where: { $0.preparation == prepared && $0.producerJoined
        && ($0.phase == .preparedHistory || $0.phase == .retainedHistory) }) else {
        throw BoomError.denied("Receiving history owner has no exact joined preparation in this engine.")
      }
      let metadataBytes = prepared.canonicalHistory == nil ? 0 : Self.maximumNativeMetadataBytes
      let reservation = prepared.windowBytes + metadataBytes
      try admitEntry(value, payloadBytes: reservation)
      let lease = mint()
      value.entries[lease.id] = Entry(purpose: .retainedHistory(routeID: prepared.routeID,
        preparationID: prepared.preparationID), phase: .retainedHistory, claims: claims,
        payloadReservation: reservation, producerJoined: true,
        preparation: prepared, isJob: false)
      value.reservedPayloadBytes += reservation; value.retainedEngine = engine
      return PagedNativeRetainedHistoryIntent(prepared: prepared, lease: lease)
    }
  }
  func resolvePrepared(_ source: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) throws {
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      let entry = try require(source, in: value)
      guard entry.producerJoined, entry.preparation == prepared, !entry.publicationAttempted else {
        throw BoomError.stale("An admitted or unjoined history producer cannot release its intent.")
      }
      switch disposition {
      case .explicitlyAbandoned: break
      case .transferredToRetainedOwner(let receiptID):
        guard receiptID != source.id, let receiver = value.entries[receiptID],
          receiver.phase == .retainedHistory, receiver.producerJoined,
          receiver.preparation == prepared,
          receiver.claims.contains(.record(prepared.command.expectedRootRecord)),
          receiver.claims.contains(.record(prepared.candidateRecord)) else {
          throw BoomError.denied("History transfer has no actual same-engine receiving custody receipt.")
        }
      }
      return remove(source.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }
  func admitHistoryPublication(_ lease: PagedTextRootLease,
    prepared: PagedNativePreparedHistoryMove) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.producerJoined, entry.preparation == prepared else {
        throw BoomError.stale("History publication has no exact prepared custody.")
      }
      // Pre-admitted slot four is the journal barrier. No new entry/capacity
      // admission can fail after Main provisionally installs this command.
      entry.claims = [.record(prepared.command.expectedRootRecord), .record(prepared.candidateRecord),
        .writerDocument(prepared.command.handle.documentID), .workspace]
      entry.publicationAttempted = true; entry.phase = .unresolved
      entry.verifiedHistoryBefore = nil; entry.verifiedHistoryPublished = nil
      if let sql = entry.sql {
        guard sql.execution?.selectedBefore == true else { throw BoomError.stale("An unresolved live SQL outcome cannot be overwritten by history retry.") }
        entry.sql?.retryAdmitted = true // retain original until the next real publication output transfers
      }
      value.entries[lease.id] = entry
    }
  }
  func verifiedHistoryBefore(_ lease: PagedTextRootLease,
    prepared: PagedNativePreparedHistoryMove) throws {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.producerJoined, entry.preparation == prepared,
        entry.verifiedHistoryBefore == prepared.preparationID else {
        throw BoomError.stale("History inspection has another pending custody record.")
      }
      entry.publicationAttempted = false; entry.phase = .preparedHistory; entry.verifiedHistoryBefore = nil
      value.entries[lease.id] = entry
    }
  }
  /// The receiving entry ALREADY owns all graph claims before a joined producer
  /// is removed. Used to merge exceptional publication outputs into the same
  /// pending command, not a new actor/key/cache or guessed success path.
  func absorbJoined(_ output: PagedTextRootLease, into receiverLease: PagedTextRootLease) throws {
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      var receiver = try require(receiverLease, in: value)
      let producer = try require(output, in: value)
      guard output.id != receiverLease.id, producer.producerJoined, receiver.producerJoined,
        producer.claims.allSatisfy({ receiver.claims.contains($0) }),
        producer.payloadReservation <= receiver.payloadReservation else {
        throw BoomError.stale("Joined producer cannot transfer its graph or bounded payload to this receiver.")
      }
      if let sql = producer.sql {
        guard receiver.sql == nil || receiver.sql?.operation == sql.operation,
          receiver.preparation?.preparationID == sql.operation.operationID else { throw BoomError.stale("SQL transfer has another actual prepared receiver.") }
        var transferred = sql
        if receiver.sql?.firstFailure != nil { transferred.firstFailure = receiver.sql?.firstFailure }
        receiver.sql = transferred
      }
      receiver.writesAttempted = receiver.writesAttempted || producer.writesAttempted
      receiver.publicationAttempted = receiver.publicationAttempted || producer.publicationAttempted
      if let proof = producer.verifiedHistoryBefore {
        guard receiver.preparation?.preparationID == proof else { throw BoomError.denied("History before proof has another preparation.") }
        receiver.verifiedHistoryBefore = proof
      }
      if let proof = producer.verifiedHistoryPublished {
        guard let prepared = receiver.preparation, prepared.preparationID == proof.preparationID else {
          throw BoomError.denied("History publication proof has another preparation.")
        }
        guard proof.matches(prepared, admission: proof.admission, store: proof.store) else {
          throw BoomError.denied("Joined SQL publication has another exact receiving intent.")
        }
        receiver.verifiedHistoryPublished = proof
      }
      value.entries[receiverLease.id] = receiver
      return remove(output.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }
  /// Known success is the originating same-connection SQL COMMIT join, not
  /// durability inferred from an authenticated row. Search is bounded by the
  /// existing Entry cap and returns no new lease or independently cached state.
  func hasJoinedSQLiteHistoryPublication(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, store: PagedSQLiteNativeReceivingIdentity) throws -> Bool {
    try store.admit(ownerID: ownerID, engineIncarnation: engineIncarnation)
    try admission.validate(for: prepared)
    return state.withLock { matchingSQLiteHistory(in: $0, prepared: prepared, admission: admission, store: store) != nil }
  }
  private func matchingSQLiteHistory(in value: State, prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, store: PagedSQLiteNativeReceivingIdentity) -> SQLiteHistoryPublication? {
    for entry in value.entries.values {
      guard entry.producerJoined, !entry.isJob, entry.publicationAttempted,
        let receipt = entry.verifiedHistoryPublished, receipt.preparationID == prepared.preparationID,
        entry.claims.contains(.record(prepared.command.expectedRootRecord)),
        entry.claims.contains(.record(prepared.candidateRecord)),
        receipt.matches(prepared, admission: admission, store: store) else { continue }
      return receipt
    }
    return nil
  }
  @discardableResult
  func finishHistoryInstallation(_ preparedLease: PagedTextRootLease, controller: PagedTextRootLease,
    prepared: PagedNativePreparedHistoryMove, record: PagedDocumentRootRecord,
    receiving: (store: PagedSQLiteNativeReceivingIdentity, admission: PagedNativeHistoryAdmission))
    throws -> PagedSQLiteExecution? {
    try receiving.store.admit(ownerID: ownerID, engineIncarnation: engineIncarnation)
    try receiving.admission.validate(for: prepared)
    let result = try state.withLock { value -> (PagedTextEngineAdapter?, PagedSQLiteExecution?) in
      var receiver = try require(controller, in: value)
      guard case .controller(let routeID) = receiver.purpose, receiver.phase == .liveController,
        record == prepared.candidateRecord else { throw BoomError.stale("History receiving has another controller/candidate.") }
      if let prior = receiver.lastHistoryReceiving,
        prior.matches(prepared, admission: receiving.admission, store: receiving.store),
        receiver.currentControllerRecord == record,
        receiver.controllerSequence == receiving.admission.admittedSequence {
        return (nil, receiver.sql?.execution) // exact same-current actual finish, not a retired lease lookup
      }
      let producer = try require(preparedLease, in: value)
      guard producer.producerJoined, producer.preparation == prepared, producer.publicationAttempted,
        producer.verifiedHistoryPublished?.preparationID == prepared.preparationID,
        receiver.sql == nil, receiver.claims == [.record(prepared.command.expectedRootRecord)],
        receiver.currentControllerRecord == prepared.command.expectedRootRecord, receiver.pendingBatchID == nil,
        receiver.controllerSequence == prepared.command.expectedSequence,
        receiver.controllerSessionID == nil || receiver.controllerSessionID == prepared.command.sessionID else {
        throw BoomError.stale("History installation has another exact prepared/source/prefix owner.")
      }
      guard routeID == prepared.routeID,
        producer.verifiedHistoryPublished?.matches(prepared, admission: receiving.admission, store: receiving.store) == true,
        let sql = producer.sql, let execution = sql.execution, execution.selectedAfter else {
        throw BoomError.denied("History finish has no actual successful joined SQL outcome.")
      }
      receiver.controllerSessionID = prepared.command.sessionID
      receiver.controllerSequence = try prepared.command.nextSequence()
      receiver.currentControllerRecord = record; receiver.nativeCommit = nil; receiver.lastInstalledCommit = nil
      receiver.lastHistoryReceiving = producer.verifiedHistoryPublished
      receiver.sql = sql; receiver.sql?.receivingJoined = true
      receiver.claims = [.record(prepared.command.expectedRootRecord), .record(record)]
      value.entries[controller.id] = receiver
      return (remove(preparedLease.id, from: &value), execution)
    }
    withExtendedLifetime(result.0) {}; return result.1
  }
  /// The real metadata receiver invokes this after accepting the exact normal
  /// snapshot. Repeating the still-retained finish is idempotent; caller then
  /// explicitly releases the received output via abandonJoined.
  func finishWorkspaceReceiving(_ lease: PagedTextRootLease, snapshot: PagedWorkspaceSnapshot) throws -> PagedSQLiteExecution {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.producerJoined, !entry.isJob, entry.phase == .output,
        var sql = entry.sql, let execution = sql.execution, execution.selectedAfter,
        case .workspace(let prepared, let records, _) = sql.intent,
        case .workspace(let actual) = sql.output,
        actual == snapshot, records == snapshot.documents, prepared.reference == snapshot.head.workspace,
        execution.publication?.afterHead == snapshot.head else { throw BoomError.stale("Metadata receiving has another actual normal output.") }
      sql.receivingJoined = true; entry.sql = sql; value.entries[lease.id] = entry; return execution
    }
  }

  func finishMetadataReceiving(_ lease: PagedTextRootLease,
    publication: WorkspaceMetadataPublication) throws -> PagedSQLiteExecution {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard entry.producerJoined, !entry.isJob, entry.phase == .output,
        var sql = entry.sql, let execution = sql.execution, execution.selectedAfter,
        case .metadata(let input, let prepared, _) = sql.intent,
        case .metadata(let actual) = sql.output,
        actual == publication, input.inputID == prepared.inputID,
        publication.head.workspace.hasSameSettingsPayload(as: prepared.settings),
        metadataDocumentOutputMatches(input, result: publication),
        execution.publication?.afterHead == publication.head,
        execution.publication?.metadataChanges == publication.changes,
        execution.publication?.documentChanges == publication.documents else {
        throw BoomError.stale("Metadata receiver has another actual input/COMMIT/output.")
      }
      if sql.receivingJoined { return execution }
      try admitMetadataDocuments(input, in: value)
      // Engine has just authenticated every active/archive full record on the
      // same queue. Transfer both genuine insert producers only after that
      // receiving join; no caller may release them during the metadata await.
      for producer in input.producerLeases { _ = remove(producer.id, from: &value) }
      sql.receivingJoined = true; entry.sql = sql; value.entries[lease.id] = entry; return execution
    }
  }

  func admitMetadataDocumentInputs(_ lease: PagedTextRootLease) throws {
    try state.withLock { value in
      guard let input = try require(lease, in: value).metadataInput else { throw BoomError.stale("Document input lost its pre-yield Root owner.") }
      try admitMetadataDocuments(input, in: value)
    }
  }
  private func metadataDocumentOutputMatches(_ input: WorkspaceMetadataInput,
    result: WorkspaceMetadataPublication) -> Bool {
    if let records = input.initialDocuments {
      return result.documents.count == records.count && zip(records, result.documents).allSatisfy {
        $0.1.kind == .initial && $0.1.before == nil && $0.1.after == $0.0
          && $0.1.archiveBefore == nil && $0.1.archiveAfter == nil && $0.1.original == nil
      }
    }
    return result.documents.count == input.documentChanges.count
      && zip(input.documentChanges, result.documents).allSatisfy { $0.0.matches($0.1) }
  }
  private func admitMetadataDocuments(_ input: WorkspaceMetadataInput, in value: State) throws {
    for entry in value.entries.values {
      if case .controller = entry.purpose {
        for claim in entry.claims {
          if case .record(let record) = claim, input.changedDocumentIDs.contains(record.document.id) {
            throw BoomError.unavailable("Rename/trash/insert require actual native controller retirement first.")
          }
        }
      }
      if let other = entry.metadataInput, other.inputID != input.inputID,
        entry.sql?.receivingJoined != true {
        throw BoomError.unavailable("An earlier actual metadata input still owns receiving.")
      }
    }
    for mutation in input.documentChanges where mutation.kind == .insert {
      guard let imported = mutation.imported, let initialized = mutation.initialized, let original = mutation.original else {
        throw BoomError.denied("Insert has no actual import/history pair.")
      }
      let source = try require(imported.lease, in: value), history = try require(initialized.lease, in: value)
      guard source.phase == .output, history.phase == .output, source.producerJoined, history.producerJoined,
        !source.isJob, !history.isJob, !source.bulkActive, !history.bulkActive,
        !source.headTransferActive, !history.headTransferActive, source.preparation == nil, history.preparation == nil,
        source.sql == nil || (source.sql?.execution?.selectedAfter == true && source.sql?.execution?.publication == nil),
        history.sql == nil || (history.sql?.execution?.selectedAfter == true && history.sql?.execution?.publication == nil),
        source.importedOriginal?.revision == imported.value.revision,
        source.importedOriginal?.wholeTextSha256 == imported.value.wholeTextSha256,
        original.revision == imported.value.revision, original.wholeTextSHA256 == imported.value.wholeTextSha256,
        initialized.value == mutation.after, source.claims.contains(.source(original.revision)),
        history.claims.contains(.record(initialized.value)) else {
        throw BoomError.denied("Insert values are not their actual joined import/history producer outputs.")
      }
    }
  }
  private func metadataHoldsProducer(_ id: UUID, in value: State) -> Bool {
    value.entries.values.contains { entry in
      entry.sql?.receivingJoined != true && entry.metadataInput?.producerLeases.contains(where: { $0.id == id }) == true
    }
  }

  func adoptUnclaimed(_ id: UUID) throws -> PagedTextRootLease {
    try state.withLock { value in
      guard let entry = value.entries[id], entry.producerJoined,
        entry.phase == .output || entry.phase == .unresolved else {
        throw BoomError.denied("Diagnostic ID has no actual joined unclaimed output.")
      }
      return mint(id: id)
    }
  }
  func claims(_ lease: PagedTextRootLease) throws -> [PagedTextRootClaim] {
    try state.withLock { try require(lease, in: $0).claims }
  }
  func abandonJoined(_ lease: PagedTextRootLease) throws {
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      let entry = try require(lease, in: value)
      guard !metadataHoldsProducer(lease.id, in: value), entry.producerJoined, !entry.isJob, !entry.bulkActive,
        (!entry.publicationAttempted || entry.phase == .output),
        entry.phase != .liveController, entry.preparation == nil,
        entry.sql == nil || entry.sql?.receivingJoined == true || (entry.sql?.execution?.publication == nil && (entry.sql?.execution?.outcome == .committed || entry.sql?.execution?.outcome == .resolved(.checkpoint))) else {
        throw BoomError.denied("Joined abandonment cannot drop a live controller or unresolved publication/intent.")
      }
      return remove(lease.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }
  /// Called only on the adapter queue AFTER real publisher current-record
  /// validation. Caller expressly joins its use; the authoritative head now
  /// owns the published record. This never authorizes deletion of old pages.
  func transferJoinedToHead(_ lease: PagedTextRootLease, record: PagedDocumentRootRecord) throws {
    let retained = try state.withLock { value -> PagedTextEngineAdapter? in
      let entry = try require(lease, in: value)
      guard !metadataHoldsProducer(lease.id, in: value), entry.producerJoined, entry.preparation == nil,
        entry.headTransferActive,
        entry.claims.contains(.record(record)) || entry.claims.contains(.source(record.document.revision)) else {
        throw BoomError.denied("Joined head transfer has another or unresolved root record.")
      }
      return remove(lease.id, from: &value)
    }
    withExtendedLifetime(retained) {}
  }
  /// Closing-owner cleanup has no new capacity reservation. Extend this
  /// already held exact lease before any possible journal recovery; an error
  /// retains the workspace barrier and permits only another explicit transfer.
  func beginHeadTransfer(_ lease: PagedTextRootLease, record: PagedDocumentRootRecord) throws {
    try validate([.record(record)])
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard !metadataHoldsProducer(lease.id, in: value), entry.producerJoined, entry.preparation == nil,
        entry.phase == .output || entry.phase == .liveController || entry.headTransferActive,
        entry.claims.contains(.record(record)) || entry.claims.contains(.source(record.document.revision)) else {
        throw BoomError.denied("Head cleanup cannot admit unresolved source publication or another leased record.")
      }
      if case .controller = entry.purpose, entry.pendingBatchID != nil || entry.sql != nil {
        throw BoomError.stale("Native shutdown must join actual ACK installation before releasing its source root.")
      }
      if !entry.claims.contains(.workspace) {
        guard entry.claims.count < Self.maximumClaims else { throw BoomError.budget("Head transfer has no reserved barrier slot.") }
        entry.claims.append(.workspace)
      }
      entry.headTransferActive = true; entry.publicationAttempted = true; entry.phase = .unresolved
      value.entries[lease.id] = entry
    }
  }
  func beginClose() { state.withLock { $0.closing = true } }
  func requireEmptyForClose() throws {
    try state.withLock { value in
      guard value.entries.isEmpty, value.jobs == 0, value.controllers == 0 else {
        throw BoomError.unavailable("Paged close retains live owners or unresolved outputs; join and resolve exact custody first.")
      }
    }
  }

  private static func workspaceInputCharge(_ records: [PagedDocumentRootRecord]) throws -> Int {
    guard records.count <= PagedWorkspaceProjection.maximumDocuments else { throw BoomError.budget("Workspace input exceeds its catalog count.") }
    var charge = 0
    for record in records {
      try record.validate()
      let next = charge.addingReportingOverflow(2_048 + record.document.title.utf8.count)
      guard !next.overflow, next.partialValue <= Self.maximumPayloadBytes else { throw BoomError.budget("Actual metadata input exceeds Root's shared byte budget.") }
      charge = next.partialValue
    }
    return charge
  }
  private static func sameNativeInput(_ lhs: PagedNativeCommitBatch, _ rhs: PagedNativeCommitBatch) -> Bool {
    guard lhs.sessionID == rhs.sessionID, lhs.batchID == rhs.batchID,
      lhs.firstSequence == rhs.firstSequence, lhs.lastSequence == rhs.lastSequence,
      lhs.expectedRootRecord == rhs.expectedRootRecord, lhs.expected.windowID == rhs.expected.windowID,
      lhs.expected.revision == rhs.expected.revision, lhs.expected.byteStart == rhs.expected.byteStart,
      lhs.expected.utf16Start == rhs.expected.utf16Start, lhs.expected.lfStart == rhs.expected.lfStart,
      lhs.expected.text.utf8.elementsEqual(rhs.expected.text.utf8), lhs.afterBytes == rhs.afterBytes,
      lhs.finalCaretUTF16 == rhs.finalCaretUTF16, lhs.deltas.count == rhs.deltas.count,
      lhs.groupCheckpoints.count == rhs.groupCheckpoints.count else { return false }
    for (a, b) in zip(lhs.deltas, rhs.deltas) {
      guard a.firstSequence == b.firstSequence, a.lastSequence == b.lastSequence,
        a.localByteStart == b.localByteStart, a.groupID == b.groupID,
        a.oldBytes == b.oldBytes, a.newBytes == b.newBytes else { return false }
    }
    func same(_ a: PagedNativeGroupCheckpoint, _ b: PagedNativeGroupCheckpoint) -> Bool {
      a.groupID == b.groupID && a.firstSequence == b.firstSequence && a.lastSequence == b.lastSequence
        && a.beforeCursor == b.beforeCursor && a.afterBytes == b.afterBytes && a.caretUTF16 == b.caretUTF16
    }
    guard zip(lhs.groupCheckpoints, rhs.groupCheckpoints).allSatisfy({ same($0.0, $0.1) }) else { return false }
    switch (lhs.historyBaseline, rhs.historyBaseline) {
    case (nil, nil): return true
    case (.some(let a), .some(let b)): return same(a, b)
    default: return false
    }
  }
  /// Immutable input copy leaves the mutex before any bounded byte comparison.
  func admitActualNativeInput(_ lease: PagedTextRootLease, batch: PagedNativeCommitBatch) throws {
    let captured = try state.withLock { value -> PagedNativeCommitBatch in
      let entry = try require(lease, in: value)
      if case .some(.native(let captured)) = entry.sql?.intent { return captured }
      guard let captured = entry.nativeInput else { throw BoomError.stale("No actual retained ordered input exists.") }; return captured
    }
    guard Self.sameNativeInput(captured, batch) else { throw BoomError.stale("Native recovery supplied another actual ordered input.") }
  }
  func beginSetupResolution(_ lease: PagedTextRootLease) throws -> SQLState? {
    try state.withLock { value in
      var entry = try require(lease, in: value)
      guard case .operation = entry.purpose, entry.claims == [.workspace], entry.phase == .unresolved,
        entry.producerJoined, !entry.isJob, !entry.bulkActive, value.jobs < Self.maximumJobs else { throw BoomError.stale("Setup resources have another actual producer.") }
      if let sql = entry.sql { guard case .setup = sql.intent else { throw BoomError.denied("Physical setup cleanup cannot consume source publication.") } }
      entry.isJob = true; entry.producerJoined = false; entry.phase = .admitted
      value.jobs += 1; value.entries[lease.id] = entry; return entry.sql
    }
  }
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  func hasActualCommittedCandidate(operationID: UUID, store: PagedSQLiteNativeReceivingIdentity,
    beforeRecord: PagedDocumentRootRecord?) -> Bool {
    state.withLock { value in value.entries.values.contains { entry in
      entry.producerJoined && !entry.isJob && entry.sql?.operation == PagedSQLiteOperationIdentity(store: store, operationID: operationID)
        && entry.sql?.execution?.outcome == .committed && entry.sql?.execution?.publication == nil
        && entry.sql?.execution?.beforeRecord == beforeRecord
    } }
  }
#endif

  private static func nativeInputCharge(_ batch: PagedNativeCommitBatch) throws -> Int {
    guard batch.expected.text.utf8.count <= PagedWorkingWindow.hardBytes,
      batch.afterBytes.count <= PagedWorkingWindow.hardBytes,
      !batch.deltas.isEmpty, batch.deltas.count <= PagedWorkingWindow.maximumQueuedDeltas,
      batch.groupCheckpoints.count <= PagedRootHistory.maximumEntries else { throw BoomError.budget("Native retry input exceeds its existing bounded capture.") }
    var charge = batch.expected.text.utf8.count + batch.afterBytes.count + 512
    var deltaBytes = 0, groupBytes = 0
    for delta in batch.deltas {
      guard delta.oldBytes.count <= PagedWorkingWindow.hardBytes, delta.newBytes.count <= PagedWorkingWindow.hardBytes else { throw BoomError.budget("Native primitive exceeds its existing fixed arena.") }
      let sum = deltaBytes.addingReportingOverflow(delta.chargedBytes)
      guard !sum.overflow, sum.partialValue <= PagedWorkingWindow.maximumQueuedBytes else { throw BoomError.budget("Native ordered delta custody exceeds its actual queue envelope.") }
      deltaBytes = sum.partialValue
    }
    for checkpoint in batch.groupCheckpoints + (batch.historyBaseline.map { [$0] } ?? []) {
      guard checkpoint.afterBytes.count <= PagedWorkingWindow.hardBytes else { throw BoomError.budget("Native checkpoint custody exceeds its island envelope.") }
      let sum = groupBytes.addingReportingOverflow(checkpoint.afterBytes.count + 128)
      guard !sum.overflow, sum.partialValue <= PagedWorkingWindow.maximumResidentGroupBytes else { throw BoomError.budget("Native checkpoint custody exceeds its fixed aggregate envelope.") }
      groupBytes = sum.partialValue
    }
    for bytes in [deltaBytes, groupBytes] {
      let sum = charge.addingReportingOverflow(bytes)
      guard !sum.overflow, sum.partialValue <= Self.maximumPayloadBytes else { throw BoomError.budget("Native retained input exceeds Root's actual shared budget.") }
      charge = sum.partialValue
    }
    return charge
  }

  private func validate(_ claims: [PagedTextRootClaim]) throws {
    guard !claims.isEmpty, claims.count <= Self.maximumClaims else {
      throw BoomError.budget("Root custody exceeds its fixed graph-claim bound.")
    }
    for claim in claims {
      switch claim {
      case .source(let revision):
        try revision.validate()
        guard revision.ownerID == ownerID else { throw BoomError.denied("Root custody has another owner.") }
      case .record(let record):
        try record.validate()
        guard record.document.revision.ownerID == ownerID else { throw BoomError.denied("History custody has another owner.") }
      case .writerDocument(let id):
        guard id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
          throw BoomError.invalid("Writer custody has an empty document.")
        }
      case .workspace: break
      }
    }
  }
  private func require(_ lease: PagedTextRootLease, in value: State) throws -> Entry {
    guard lease.ownerID == ownerID, lease.engineIncarnation == engineIncarnation,
      let entry = value.entries[lease.id] else {
      throw BoomError.denied("Root lease belongs to another owner, engine incarnation or resolved output.")
    }
    return entry
  }
  private func admitEntry(_ value: State, payloadBytes: Int) throws {
    guard value.entries.count < Self.maximumEntries, payloadBytes >= 0,
      payloadBytes <= Self.maximumPayloadBytes - value.reservedPayloadBytes else {
      throw BoomError.budget("Root custody has reached its bounded entry or payload envelope.")
    }
  }
  private func mint(id: UUID = UUID()) -> PagedTextRootLease {
    PagedTextRootLease(ownerID: ownerID, engineIncarnation: engineIncarnation, id: id)
  }
  private func remove(_ id: UUID, from value: inout State) -> PagedTextEngineAdapter? {
    guard let entry = value.entries.removeValue(forKey: id) else { return nil }
    if entry.isJob { value.jobs -= 1 }
    if case .controller = entry.purpose { value.controllers -= 1 }
    value.reservedPayloadBytes -= entry.payloadReservation + entry.inputReservation
    if value.entries.isEmpty {
      let retained = value.retainedEngine; value.retainedEngine = nil; return retained
    }
    return nil
  }
}
