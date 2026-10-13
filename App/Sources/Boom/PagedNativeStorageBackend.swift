import BoomCore
import Foundation

/// One registered native controller's storage route. The existing process
/// engine owns its queue/cache/providers and atomic complete document roots. This actor retains small identities and
/// at most one unpublished 16KiB history island while a command is unresolved.
actor PagedNativeStorageBackend: PagedNativeHistorySessionStorage, PagedNativeCommitInstallationStorage, PagedNativeFileDurabilityStorage, PagedNativeDocumentNavigationStorage, PagedNativeCapturedEditingStorage {
  private enum HistoryPhase {
    case prepared
    case inputConflict(PagedNativeHistoryInputObservation)
    case admitted(PagedNativeHistoryAdmission)
    case verifiedNotPublished(PagedNativeHistoryAdmission, UUID)
    case published(PagedNativeHistoryAdmission, PagedNativeHistoryAcknowledgement)
  }
  private struct PendingHistory {
    let prepared: PagedNativePreparedHistoryMove
    let custody: PagedTextRootLease
    var phase: HistoryPhase
  }
  /// One exact still-current completion, not a retained-source cache. The
  /// preparation window is not copied into this stamp. ACK keeps one bounded
  /// island and its actual metadata projection under the controller's existing
  /// 24KiB + two-projection reservation. Old roots are identity fields, not pins.
  private struct JoinedHistoryCompletion {
    let controllerID: UUID
    let engineIncarnation: UUID
    let routeID: UUID
    let preparationID: UUID
    let command: PagedNativeHistoryMoveCommand
    let candidateRecord: PagedDocumentRootRecord
    let candidateProducer: PagedTextRootLease?
    let cursor: PagedSealedCursor
    let localCaretUTF16: Int
    let windowBytes: Int
    let admission: PagedNativeHistoryAdmission
    let acknowledgement: PagedNativeHistoryAcknowledgement

    init(controller: PagedTextRootLease, prepared: PagedNativePreparedHistoryMove,
      admission: PagedNativeHistoryAdmission, acknowledgement: PagedNativeHistoryAcknowledgement) {
      controllerID = controller.id; engineIncarnation = controller.engineIncarnation
      routeID = prepared.routeID; preparationID = prepared.preparationID; command = prepared.command
      candidateRecord = prepared.candidateRecord; candidateProducer = prepared.canonicalHistory?.producer
      cursor = prepared.cursor; localCaretUTF16 = prepared.localCaretUTF16; windowBytes = prepared.windowBytes
      self.admission = admission; self.acknowledgement = acknowledgement
    }
    func matches(_ prepared: PagedNativePreparedHistoryMove) -> Bool {
      let window = prepared.window, sealed = acknowledgement.sealedWindow
      guard routeID == prepared.routeID, preparationID == prepared.preparationID, command == prepared.command,
        candidateRecord == prepared.candidateRecord, cursor == prepared.cursor,
        localCaretUTF16 == prepared.localCaretUTF16, windowBytes == prepared.windowBytes,
        window.windowID == sealed.windowID, window.revision == sealed.revision,
        window.byteStart == sealed.byteStart, window.utf16Start == sealed.utf16Start, window.lfStart == sealed.lfStart,
        window.text.utf8.elementsEqual(sealed.text.utf8) else { return false }
      switch (prepared.canonicalHistory, acknowledgement.canonicalHistory) {
      case (nil, nil): return candidateProducer == nil // inactive primitive controls only
      case (.some(let candidate), .some(let published)):
        return candidate.producer == candidateProducer
          && candidate.record == published.record && candidate.beforeRecord == published.beforeRecord
          && candidate.currentCursor == published.currentCursor && candidate.undo == published.undo
          && candidate.redo == published.redo && candidate.activeGroup == published.activeGroup
          && candidate.undoFromBefore == published.undoFromBefore && candidate.redoFromBefore == published.redoFromBefore
          && candidate.resolutions == published.resolutions
          && candidate.producer.ownerID == published.producer.ownerID
          && candidate.producer.engineIncarnation == published.producer.engineIncarnation
          && candidate.scope == .historyCandidate(sessionID: command.sessionID, routeID: routeID,
            commandID: command.commandID, expected: command.expectedSequence)
      default: return false
      }
    }
  }
  private var lastJoinedHistoryCompletion: JoinedHistoryCompletion?

  private let engine: PagedTextEngineAdapter
  private let publisher: PagedWorkspacePublisher
  private let routeID: UUID
  private let controllerCustody: PagedTextRootLease
  private var sealedRecord: PagedDocumentRootRecord
  private var sessionID: UUID?
  private var lastSequence: UInt64 = 0
  private var pendingCommitInstallationID: UUID?
  private var pendingCapturedResult: PagedCapturedEditResult?
  private var committing = false
  private var pendingHistory: PendingHistory?
  private var unresolvedOutput: PagedTextRootLease?
  private var commitBeforeVerification: (batchID: UUID, verificationID: UUID, custody: PagedTextRootLease)?
  private var detaching = false
  private var detached = false
  private var detachInFlight = false
  private var activeWindows = 0
  private var openingAttempted = false
  private var openingInFlight = false
  private var canonicalEnabled = false

  /// The engine factory admits this exact record against the validated
  /// current head before returning the native route. Not a model-tool factory.
  init(engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher,
    admittedRecord: PagedDocumentRootRecord, routeID: UUID, controllerCustody: PagedTextRootLease) {
    self.engine = engine; self.publisher = publisher; sealedRecord = admittedRecord
    self.routeID = routeID; self.controllerCustody = controllerCustody
  }

  /// Exactly one fresh session enters this existing controller. Bind before
  /// any yield; retain/transfer real outputs before returning the opening.
  func opening(sessionID requested: UUID) async throws -> PagedNativeCanonicalOpening {
    try admitLifetime()
    guard !openingAttempted, sessionID == nil, lastSequence == 0, !committing,
      activeWindows == 0, pendingHistory == nil, pendingCommitInstallationID == nil, pendingCapturedResult == nil,
      requested != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
      throw BoomError.stale("Canonical opening cannot reuse a native controller or unfinished operation.")
    }
    openingAttempted = true; openingInFlight = true; sessionID = requested
    defer { openingInFlight = false }
    try engine.bindNativeOpeningCustody(controllerCustody, sessionID: requested, record: sealedRecord)
    let output: PagedTextCustodiedValue<PagedNativeCanonicalOpening>
    do { output = try await engine.nativeCanonicalOpeningRetaining(publisher: publisher, expected: sealedRecord, sessionID: requested) }
    catch { preserveFailure(error); throw error }
    do {
      try output.value.history.admit(record: sealedRecord, sessionID: requested,
        engineIncarnation: engine.custodyIncarnation,
        scope: .opening(sessionID: requested, windowID: output.value.window.windowID))
      try engine.installNativeCustody(output.lease, controller: controllerCustody,
        expected: sealedRecord, record: sealedRecord)
    } catch { unresolvedOutput = output.lease; throw PagedTextCustodyFailure(original: error, lease: output.lease) }
    canonicalEnabled = true
    return output.value
  }

  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    try admitOrdinaryOperation()
    guard !committing, batch.expectedRootRecord == sealedRecord,
      sessionID == nil || sessionID == batch.sessionID else {
      throw BoomError.stale("Native storage has another controller or captured root/history record.")
    }
    let next = lastSequence.addingReportingOverflow(1)
    guard !next.overflow, batch.firstSequence == next.partialValue else {
      throw BoomError.stale("Native storage batch has a sequence gap.")
    }
    committing = true
    defer { committing = false }
    try await engine.confirmNativeInputCustody(controllerCustody, sessionID: batch.sessionID,
      sequence: lastSequence, record: sealedRecord, publisher: publisher)
    pendingCommitInstallationID = nil; lastJoinedHistoryCompletion = nil
    sessionID = batch.sessionID
    let result: PagedTextCustodiedValue<PagedNativeCommitAcknowledgement>
    do { result = try await engine.commitNativeRetaining(batch, publisher: publisher) }
    catch { preserveFailure(error); throw error }
    let acknowledgement = result.value
    do {
      guard let canonical = acknowledgement.canonicalHistory else { throw BoomError.invalid("Real native worker ACK omitted canonical metadata.") }
      try canonical.admit(record: acknowledgement.sealedRootRecord, sessionID: batch.sessionID,
        engineIncarnation: engine.custodyIncarnation,
        scope: .nativeBatch(sessionID: batch.sessionID, batchID: batch.batchID, first: batch.firstSequence, last: batch.lastSequence))

      try engine.installNativeCustody(result.lease, controller: controllerCustody,
        expected: sealedRecord, record: acknowledgement.sealedRootRecord)
    } catch {
      unresolvedOutput = result.lease
      throw PagedTextCustodyFailure(original: error, lease: result.lease)
    }
    sealedRecord = acknowledgement.sealedRootRecord; lastSequence = acknowledgement.lastSequence
    pendingCommitInstallationID = acknowledgement.batchID
    return acknowledgement
  }

  func commitCapturedEdits(expected: PagedDocumentRootRecord, edits: [PagedTextLocalEdit],
    sessionID: UUID, commandID: UUID, groupID: UUID, sequence: UInt64,
    beforeCursor: PagedSealedCursor, afterSelection: PagedNativeNavigationSelection? = nil) async throws -> PagedCapturedEditResult {
    try await commitCaptured(PagedCapturedEditInput(expected: expected, operation: .edits(edits),
      sessionID: sessionID, commandID: commandID, groupID: groupID, sequence: sequence,
      beforeCursor: beforeCursor, afterSelection: afterSelection))
  }
  func commitUserReplacement(expected: PagedDocumentRootRecord, selection: PagedNativeNavigationSelection,
    replacement: Data, sessionID: UUID, commandID: UUID, groupID: UUID, sequence: UInt64,
    beforeCursor: PagedSealedCursor) async throws -> PagedCapturedEditResult {
    try await commitCaptured(PagedCapturedEditInput(expected: expected, operation: .replacement(selection, replacement),
      sessionID: sessionID, commandID: commandID, groupID: groupID, sequence: sequence, beforeCursor: beforeCursor))
  }
  func commitLinePrefix(expected: PagedDocumentRootRecord, selection: PagedNativeNavigationSelection,
    prefix: String, sessionID: UUID, commandID: UUID, groupID: UUID, sequence: UInt64,
    beforeCursor: PagedSealedCursor) async throws -> PagedCapturedEditResult {
    try await commitCaptured(PagedCapturedEditInput(expected: expected, operation: .linePrefix(selection, prefix),
      sessionID: sessionID, commandID: commandID, groupID: groupID, sequence: sequence, beforeCursor: beforeCursor))
  }
  private func commitCaptured(_ input: PagedCapturedEditInput) async throws -> PagedCapturedEditResult {
    try admitLifetime()
    let next = lastSequence.addingReportingOverflow(1)
    guard !committing, pendingHistory == nil, pendingCommitInstallationID == nil, pendingCapturedResult == nil,
      activeWindows == 0, input.expected == sealedRecord, input.sessionID == sessionID,
      !next.overflow, input.sequence == next.partialValue else {
      throw BoomError.stale("Captured edit has another pending command, controller, sequence or full source.")
    }
    _ = try input.inputCharge()
    committing = true
    defer { committing = false }
    let output: PagedTextCustodiedValue<PagedCapturedEditResult>
    do { output = try await engine.commitCapturedEditRetaining(input, publisher: publisher) }
    catch { preserveFailure(error); throw error }
    do {
      try output.value.canonicalHistory.admit(record: output.value.record, sessionID: input.sessionID,
        engineIncarnation: engine.custodyIncarnation,
        scope: .capturedEdit(sessionID: input.sessionID, commandID: input.commandID, sequence: input.sequence))
      try engine.installNativeCustody(output.lease, controller: controllerCustody,
        expected: input.expected, record: output.value.record)
    } catch { unresolvedOutput = output.lease; throw PagedTextCustodyFailure(original: error, lease: output.lease) }
    sealedRecord = output.value.record; lastSequence = input.sequence
    lastJoinedHistoryCompletion = nil; pendingCapturedResult = output.value
    return output.value
  }
  func finishCapturedEditInstallation(_ result: PagedCapturedEditResult) async throws {
    try admitLifetime()
    guard !committing, pendingHistory == nil, pendingCommitInstallationID == nil,
      sessionID == result.sessionID, lastSequence == result.sequence, sealedRecord == result.record,
      pendingCapturedResult == nil || pendingCapturedResult == result else {
      throw BoomError.stale("Captured edit finish has another actual controller output.")
    }
    committing = true
    defer { committing = false }
    try await engine.finishCapturedEditCustody(controllerCustody, result: result, publisher: publisher)
    pendingCapturedResult = nil
  }

  func graphemeBoundary(expected: PagedTextRevision, utf16Offset: UInt64, forward: Bool) async throws -> PagedTextSummary {
    try admitOrdinaryOperation()
    guard !committing, activeWindows < 2, expected == sealedRecord.document.revision else {
      throw BoomError.stale("Grapheme movement has another pending or sealed source.")
    }
    activeWindows += 1
    defer { activeWindows -= 1 }
    let record = sealedRecord
    let result: PagedTextSummary
    do { result = try await engine.graphemeBoundary(expected, utf16Offset: utf16Offset, forward: forward) }
    catch { preserveFailure(error); throw error }
    try admitOrdinaryOperation()
    guard !committing, sealedRecord == record else { throw BoomError.stale("Grapheme source changed while seeking.") }
    return result
  }

  func paragraphBounds(expected: PagedTextRevision, utf16Offset: UInt64,
    includeLineEndings: Bool = true) async throws -> PagedTextParagraphBounds {
    try admitOrdinaryOperation()
    guard !committing, activeWindows < 2, expected == sealedRecord.document.revision else {
      throw BoomError.stale("Paragraph movement has another pending or sealed source.")
    }
    activeWindows += 1
    defer { activeWindows -= 1 }
    let record = sealedRecord
    let result = try await engine.paragraphBounds(expected, utf16Offset: utf16Offset,
      includeLineEndings: includeLineEndings)
    try admitOrdinaryOperation()
    guard !committing, sealedRecord == record else { throw BoomError.stale("Paragraph source changed while seeking.") }
    return result
  }

  func documentPosition(expected: PagedTextRevision, utf16Offset: UInt64,
    forward: Bool) async throws -> PagedTextSummary {
    try admitOrdinaryOperation()
    guard !committing, activeWindows < 2, expected == sealedRecord.document.revision else {
      throw BoomError.stale("Navigation position has another pending or sealed source.")
    }
    activeWindows += 1
    defer { activeWindows -= 1 }
    let record = sealedRecord
    let position = try await engine.nativeNavigationPosition(publisher: publisher, expected: record,
      utf16Offset: utf16Offset, forward: forward)
    try admitOrdinaryOperation()
    guard !committing, sealedRecord == record else { throw BoomError.stale("Navigation source changed while positioning.") }
    return position
  }

  func window(expected: PagedTextRevision, utf16Anchor: UInt64,
    maximumBytes: Int) async throws -> PagedTextWindow {
    try admitOrdinaryOperation()
    guard !committing, activeWindows < 2, expected == sealedRecord.document.revision else {
      throw BoomError.stale("Native navigation has another pending or sealed source.")
    }
    activeWindows += 1
    defer { activeWindows -= 1 }
    let captured = sealedRecord
    let result: PagedTextCustodiedValue<PagedTextWindow>
    do {
      result = try await engine.nativeWindowRetaining(publisher: publisher, expected: captured,
        utf16Anchor: utf16Anchor, maximumBytes: maximumBytes)
    } catch { preserveFailure(error); throw error }
    do {
      try admitOrdinaryOperation()
      guard !committing, sealedRecord == captured else {
        throw BoomError.stale("Native source/history changed while navigation loaded.")
      }
      try engine.installNativeCustody(result.lease, controller: controllerCustody, expected: captured, record: captured)
      return result.value
    } catch {
      // A fully returned read was never installed in a native arena. This is
      // an explicit joined consumer disposition, not abandonment of a writer
      // or provisional history intent. Keep it if cleanup itself fails.
      do { try await engine.abandonJoinedRootOutput(result.lease) }
      catch { unresolvedOutput = result.lease; throw PagedTextCustodyFailure(original: error, lease: result.lease) }
      throw error
    }
  }

  /// The command captures an already joined input prefix. It does not reserve
  /// G+1 yet; input admitted during preparation must be explicitly reported
  /// and retained by the native owner before its old-arena commit is pumped.
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove {
    try admitLifetime()
    guard pendingCapturedResult == nil else { throw BoomError.unavailable("Captured source has not joined its physical installation.") }
    if let pendingHistory { throw PagedNativeHistoryCommandConflict.pendingCommand(pendingHistory.prepared.command.commandID) }
    try command.validate()
    if canonicalEnabled, command.canonicalSelection == nil {
      throw BoomError.stale("Canonical native command requires its exact validated record/direction/slot selection.")
    }
    guard !committing, command.expectedRootRecord == sealedRecord,
      command.expectedSequence == lastSequence, sessionID == nil || sessionID == command.sessionID else {
      throw BoomError.stale("History preparation has another controller, sealed sequence or complete root record.")
    }
    committing = true
    defer { committing = false }
    try await engine.confirmNativeInputCustody(controllerCustody, sessionID: command.sessionID,
      sequence: lastSequence, record: sealedRecord, publisher: publisher)
    pendingCommitInstallationID = nil; lastJoinedHistoryCompletion = nil
    sessionID = command.sessionID
    let result: PagedTextCustodiedValue<PagedNativePreparedHistoryMove>
    do { result = try await engine.prepareNativeHistoryMoveRetaining(command, routeID: routeID, publisher: publisher) }
    catch { preserveFailure(error); throw error }
    // The worker entry already owns both roots AND the prepared immutable
    // window. This actor adoption neither allocates nor establishes first pins.
    pendingHistory = PendingHistory(prepared: result.value, custody: result.lease, phase: .prepared)
    return result.value
  }

  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    let pending = try requirePending(prepared)
    guard case .prepared = pending.phase else { throw conflict(for: pending) }
    try admission.validate(for: prepared)
    try admitHistoryPublication(prepared)
    // From here failure is uncertain until validated inspection. Never
    // release the intent/pins, restore old characters, or repeat automatically.
    try engine.admitPreparedCustody(pending.custody, prepared: prepared)
    pendingHistory?.phase = .admitted(admission)
    return try await publishAdmittedHistory(prepared, admission: admission)
  }

  /// Allows already admitted old-arena input to reach storage without losing
  /// the still-pending Undo intent. The prepared command can no longer publish.
  func noteHistoryInputConflict(_ prepared: PagedNativePreparedHistoryMove,
    observation: PagedNativeHistoryInputObservation) throws -> PagedNativeHistoryInputConflictReceipt {
    let pending = try requirePending(prepared)
    guard !committing else { throw conflict(for: pending) }
    switch pending.phase {
    case .prepared, .inputConflict: break
    default: throw conflict(for: pending)
    }
    try observation.validate(for: prepared)
    pendingHistory?.phase = .inputConflict(observation)
    return PagedNativeHistoryInputConflictReceipt(prepared: prepared, observation: observation)
  }

  /// Native owner policy must decide a conflicting unadmitted intent. Transfer
  /// enters the receiving owner's exact intent/pin ledger before this call;
  /// an ordinary typing event is never authorization to abandon Undo.
  func resolveUnadmittedHistory(_ prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) throws -> PagedNativeHistoryIntentDispositionReceipt {
    let pending = try requirePending(prepared)
    guard !committing else { throw conflict(for: pending) }
    switch pending.phase {
    case .prepared, .inputConflict: break
    default: throw conflict(for: pending)
    }
    try engine.resolvePreparedCustody(pending.custody, prepared: prepared, disposition: disposition)
    pendingHistory = nil
    return PagedNativeHistoryIntentDispositionReceipt(prepared: prepared, disposition: disposition)
  }

  /// Diagnostics project the actual same-engine custody entry. The process
  /// ledger is not a durable GC catalog and never authorizes page deletion.
  func historyReachability() -> PagedNativeHistoryReachability? {
    guard let pending = pendingHistory else { return nil }
    let phase: PagedNativeHistoryReachability.Phase
    switch pending.phase {
    case .prepared: phase = .prepared
    case .inputConflict: phase = .inputConflict
    case .admitted: phase = .admitted
    case .verifiedNotPublished: phase = .verifiedNotPublished
    case .published: phase = .published
    }
    return PagedNativeHistoryReachability(routeID: routeID,
      commandID: pending.prepared.command.commandID, preparationID: pending.prepared.preparationID,
      phase: phase, before: pending.prepared.command.expectedRootRecord,
      candidate: pending.prepared.candidateRecord)
  }

  /// Explicit same-owner durability repair, separate from read-only
  /// inspection. The original pending intent/lease survives every refusal.
  func repairHistoryDurability(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    let pending = try requirePending(prepared)
    guard !committing else { throw conflict(for: pending) }
    let admission: PagedNativeHistoryAdmission
    switch pending.phase {
    case .admitted(let captured): admission = captured
    default: throw conflict(for: pending)
    }
    committing = true; defer { committing = false }
    let result: PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection>
    do {
      result = try await engine.repairFailedNativeHistoryPublicationRetaining(prepared,
        admission: admission, custody: pending.custody, publisher: publisher)
    } catch {
      // The same receiver lease already owns this re-entered producer. Never
      // absorb it into itself or release its exact original error/roots.
      if let failure = error as? PagedTextCustodyFailure, failure.lease == pending.custody { throw failure }
      throw preserveHistoryFailure(error, pending: pending)
    }
    guard result.lease == pending.custody else { unresolvedOutput = result.lease; throw BoomError.stale("History repair returned another actual producer.") }
    switch result.value {
    case .published(let acknowledgement):
      sealedRecord = acknowledgement.sealedRootRecord; lastSequence = acknowledgement.admittedSequence
      pendingHistory?.phase = .published(admission, acknowledgement)
      return .published(acknowledgement) // installed finish still outstanding
    case .notPublished:
      let verification = UUID()
      pendingHistory?.phase = .verifiedNotPublished(admission, verification)
      return .verifiedNotPublished(verificationID: verification)
    case .conflict(let current): return .conflict(current)
    }
  }
  private func admitFailedCommit(_ batch: PagedNativeCommitBatch) throws -> PagedTextRootLease {
    guard !detached, !detaching, !openingInFlight, !committing,
      pendingCommitInstallationID == nil, let custody = unresolvedOutput,
      sessionID == batch.sessionID, sealedRecord == batch.expectedRootRecord,
      lastSequence < UInt64.max, batch.firstSequence == lastSequence + 1 else { throw BoomError.stale("Recovery has another exact failed source/sequence owner.") }
    if let pendingHistory, case .inputConflict = pendingHistory.phase {} else if pendingHistory != nil { throw BoomError.stale("An admitted history intent owns this recovery lane.") }
    try engine.admitRetainedNativeInput(custody, batch: batch)
    return custody
  }
  func inspectCommitRecovery(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitRecovery {
    if pendingCommitInstallationID == batch.batchID {
      try admitOrdinaryOperation()
      guard !committing, sessionID == batch.sessionID, lastSequence == batch.lastSequence else { throw BoomError.stale("Lost ACK has another actual pending controller sequence.") }
      committing = true; defer { committing = false }
      let acknowledgement = try await engine.inspectInstalledNativeCommit(controllerCustody,
        batch: batch, publisher: publisher)
      guard sealedRecord == acknowledgement.sealedRootRecord else { throw BoomError.stale("Lost ACK no longer names the actual AFTER controller record.") }
      commitBeforeVerification = nil
      return .published(acknowledgement)
    }
    let custody = try admitFailedCommit(batch)
    committing = true; defer { committing = false }
    let result = try await engine.inspectFailedNativeCommitRetaining(batch, custody: custody, publisher: publisher)
    guard result.lease == custody else { unresolvedOutput = result.lease; throw BoomError.stale("Outcome inspection returned another actual retained producer.") }
    switch result.value {
    case .native(let ack): commitBeforeVerification = nil; return .published(ack)
    case .before:
      let verificationID: UUID
      if let prior = commitBeforeVerification, prior.batchID == batch.batchID, prior.custody == custody { verificationID = prior.verificationID }
      else { verificationID = UUID(); commitBeforeVerification = (batch.batchID, verificationID, custody) }
      return .knownUnpublished(verificationID: verificationID)
    default: throw BoomError.stale("Ordinary input resolved another receiving purpose.")
    }
  }
  func repairCommitDurability(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    let result = try await inspectCommitRecovery(batch)
    switch result {
    case .published(let ack):
      if pendingCommitInstallationID == batch.batchID {
        guard sessionID == batch.sessionID, lastSequence == ack.lastSequence,
          sealedRecord == ack.sealedRootRecord else { throw BoomError.stale("The borrowed original ACK was superseded.") }
        return ack // already in this controller; Main still must acknowledge + finish
      }
      let custody = try admitFailedCommit(batch)
      return try installRecoveredCommit(ack, custody: custody, batch: batch)
    case .knownUnpublished(let verificationID): throw PagedNativeCommitKnownUnpublished(batchID: batch.batchID, verificationID: verificationID)
    }
  }
  func retryVerifiedCommit(_ batch: PagedNativeCommitBatch, verificationID: UUID) async throws -> PagedNativeCommitAcknowledgement {
    let custody = try admitFailedCommit(batch)
    guard let prior = commitBeforeVerification, prior.batchID == batch.batchID,
      prior.custody == custody, prior.verificationID == verificationID else { throw BoomError.stale("Explicit retry has another actual BEFORE intent.") }
    commitBeforeVerification = nil // exactly one admission, consumed before await
    committing = true; defer { committing = false }
    let result = try await engine.retryNativeCommitBeforeRetaining(custody, publisher: publisher)
    guard result.lease == custody else { unresolvedOutput = result.lease; throw BoomError.stale("Retry returned another actual producer.") }
    return try installRecoveredCommit(result.value, custody: custody, batch: batch)
  }
  private func installRecoveredCommit(_ acknowledgement: PagedNativeCommitAcknowledgement,
    custody: PagedTextRootLease, batch: PagedNativeCommitBatch) throws -> PagedNativeCommitAcknowledgement {
    guard let canonical = acknowledgement.canonicalHistory,
      unresolvedOutput == custody, sessionID == batch.sessionID, sealedRecord == batch.expectedRootRecord,
      acknowledgement.batchID == batch.batchID, acknowledgement.lastSequence == batch.lastSequence else { throw BoomError.stale("Actual output omitted its original source/prefix producer.") }
    try canonical.admit(record: acknowledgement.sealedRootRecord, sessionID: batch.sessionID,
      engineIncarnation: engine.custodyIncarnation, scope: .nativeBatch(sessionID: batch.sessionID,
        batchID: batch.batchID, first: batch.firstSequence, last: batch.lastSequence))
    try engine.installNativeCustody(custody, controller: controllerCustody, expected: sealedRecord, record: acknowledgement.sealedRootRecord)
    sealedRecord = acknowledgement.sealedRootRecord; lastSequence = acknowledgement.lastSequence
    pendingCommitInstallationID = acknowledgement.batchID; unresolvedOutput = nil; commitBeforeVerification = nil
    return acknowledgement // Main still must consume ACK and join real finish
  }

  /// Inspection joins any the actual file publication first. An exact before
  /// record issues a single explicit completion permit, never a blind retry.
  func inspectHistoryRecovery(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    if let joined = try currentJoinedHistoryCompletion(prepared) { return .published(joined.acknowledgement) }
    let pending = try requirePending(prepared)
    guard !committing else { throw conflict(for: pending) }
    let admission: PagedNativeHistoryAdmission
    switch pending.phase {
    case .admitted(let captured), .verifiedNotPublished(let captured, _): admission = captured
    case .published(_, let acknowledgement): return .published(acknowledgement)
    default: throw conflict(for: pending)
    }
    committing = true
    defer { committing = false }
    let result: PagedTextCustodiedValue<PagedNativeHistoryPublicationInspection>
    do { result = try await engine.inspectNativeHistoryPublicationRetaining(prepared, admission: admission, publisher: publisher) }
    catch { throw preserveHistoryFailure(error, pending: pending) }
    try absorbHistoryOutput(result.lease, pending: pending)
    switch result.value {
    case .published(let acknowledgement):
      sealedRecord = acknowledgement.sealedRootRecord; lastSequence = acknowledgement.admittedSequence
      pendingHistory?.phase = .published(admission, acknowledgement)
      return .published(acknowledgement)
    case .notPublished:
      try engine.verifyPreparedCustodyBefore(pending.custody, prepared: prepared)
      let verification = UUID()
      pendingHistory?.phase = .verifiedNotPublished(admission, verification)
      return .verifiedNotPublished(verificationID: verification)
    case .conflict(let current):
      pendingHistory?.phase = .admitted(admission)
      return .conflict(current)
    }
  }

  /// Deliberate completion of an already admitted command, after validated
  /// before-record inspection. Same-document changes still lose its full CAS.
  func completeVerifiedHistory(_ prepared: PagedNativePreparedHistoryMove,
    verificationID: UUID) async throws -> PagedNativeHistoryAcknowledgement {
    let pending = try requirePending(prepared)
    guard case .verifiedNotPublished(let admission, let verification) = pending.phase,
      verification == verificationID else { throw conflict(for: pending) }
    try admitHistoryPublication(prepared)
    try engine.admitPreparedCustody(pending.custody, prepared: prepared)
    pendingHistory?.phase = .admitted(admission)
    return try await publishAdmittedHistory(prepared, admission: admission)
  }

  /// Main calls only after its exact provisional arena has consumed the
  /// durable acknowledgement while retaining every later accepted character.
  /// Releasing pins does not install text and never deletes file bytes.
  func finishHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws {
    if let joined = try currentJoinedHistoryCompletion(prepared) {
      guard joined.admission == admission else { throw BoomError.stale("Joined history finish has another exact admitted command.") }
      return // actual prior finish receipt; no retired lease access or storage replay
    }
    let pending = try requirePending(prepared)
    guard !committing, case .published(let captured, let acknowledgement) = pending.phase,
      admission == captured, acknowledgement.admittedSequence == lastSequence,
      acknowledgement.sealedRootRecord == sealedRecord else { throw conflict(for: pending) }
    let completed = JoinedHistoryCompletion(controller: controllerCustody, prepared: prepared,
      admission: admission, acknowledgement: acknowledgement)
    committing = true
    defer { committing = false }
    try await engine.finishNativeHistoryCustody(pending.custody, controller: controllerCustody,
      prepared: prepared, admission: admission, record: sealedRecord, publisher: publisher)
    // Set only after real registry transfer AND exact file receiving admission. No
    // fallible operation or await separates that completion from this receipt.
    lastJoinedHistoryCompletion = completed; pendingHistory = nil
  }

  private func currentJoinedHistoryCompletion(_ prepared: PagedNativePreparedHistoryMove) throws -> JoinedHistoryCompletion? {
    try admitLifetime()
    guard pendingHistory == nil, let joined = lastJoinedHistoryCompletion else { return nil }
    guard !committing, pendingCommitInstallationID == nil,
      joined.controllerID == controllerCustody.id, joined.engineIncarnation == engine.custodyIncarnation,
      sessionID == joined.command.sessionID, lastSequence == joined.admission.admittedSequence,
      sealedRecord == joined.candidateRecord, joined.matches(prepared) else {
      throw BoomError.stale("A superseded or foreign command cannot use a joined history completion.")
    }
    return joined
  }

  private func requirePending(_ prepared: PagedNativePreparedHistoryMove) throws -> PendingHistory {
    try admitLifetime()
    guard prepared.routeID == routeID, let pending = pendingHistory, pending.prepared == prepared else {
      throw BoomError.stale("History preparation belongs to another route or resolved command.")
    }
    return pending
  }
  private func admitOrdinaryOperation() throws {
    try admitLifetime()
    guard pendingCapturedResult == nil else { throw BoomError.unavailable("Captured source has not joined its physical installation.") }
    guard let pending = pendingHistory else { return }
    if case .inputConflict = pending.phase { return }
    throw conflict(for: pending)
  }
  private func conflict(for pending: PendingHistory) -> PagedNativeHistoryCommandConflict {
    switch pending.phase {
    case .prepared: return .pendingCommand(pending.prepared.command.commandID)
    case .inputConflict(let observation): return .interveningInput(pending.prepared.command.commandID, observation)
    case .admitted, .verifiedNotPublished, .published:
      return .publicationUnresolved(pending.prepared.command.commandID)
    }
  }
  private func admitHistoryPublication(_ prepared: PagedNativePreparedHistoryMove) throws {
    guard !committing, sessionID == prepared.command.sessionID,
      lastSequence == prepared.command.expectedSequence, sealedRecord == prepared.command.expectedRootRecord else {
      throw BoomError.stale("Admitted history has another controller, sequence or complete sealed record.")
    }
  }
  private func publishAdmittedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    committing = true
    defer { committing = false }
    let pending = try requirePending(prepared)
    let result: PagedTextCustodiedValue<PagedNativeHistoryAcknowledgement>
    do { result = try await engine.commitNativeHistoryMoveRetaining(prepared, admission: admission, publisher: publisher) }
    catch { throw preserveHistoryFailure(error, pending: pending) }
    try absorbHistoryOutput(result.lease, pending: pending)
    let acknowledgement = result.value
    sealedRecord = acknowledgement.sealedRootRecord; lastSequence = acknowledgement.admittedSequence
    pendingHistory?.phase = .published(admission, acknowledgement)
    return acknowledgement
  }
  private func preserveFailure(_ error: Error) {
    if let failure = error as? PagedTextCustodyFailure { unresolvedOutput = failure.lease }
  }
  private func preserveHistoryFailure(_ error: Error, pending: PendingHistory) -> Error {
    guard let failure = error as? PagedTextCustodyFailure else {
      return PagedTextCustodyFailure(original: error, lease: pending.custody)
    }
    do {
      try engine.absorbJoinedCustody(failure.lease, into: pending.custody)
      // Error custody points to the receiving lease which is actually still
      // registered after the producer's joined transfer, not its retired ID.
      return PagedTextCustodyFailure(original: failure.original, lease: pending.custody)
    }
    catch {
      unresolvedOutput = failure.lease
      return PagedTextCustodyHandoffFailure(original: failure.original, handoff: error, lease: failure.lease)
    }
  }
  private func absorbHistoryOutput(_ lease: PagedTextRootLease, pending: PendingHistory) throws {
    do { try engine.absorbJoinedCustody(lease, into: pending.custody) }
    catch { unresolvedOutput = lease; throw PagedTextCustodyFailure(original: error, lease: lease) }
  }
  private func admitLifetime() throws {
    guard !detached, !detaching, unresolvedOutput == nil, !openingInFlight,
      !openingAttempted || canonicalEnabled else {
      throw BoomError.unavailable("Native owner is detached or retains an unresolved root output.")
    }
  }
  func unresolvedRootOutput() -> PagedTextRootLease? { unresolvedOutput }
  /// Root-owned Main integration must call after its actual working window
  /// consumes this exact ACK. It is metadata-only; a later exact full-record /
  /// sequence command also confirms consumption. Navigation alone never does.
  /// An explicit repeated completion is idempotent for this still-current
  /// exact ACK. It never republishes source/history. Its existing-executor
  /// receiving await keeps this actor fenced; a superseded/different ACK is stale.
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    // Ordinary typing may seal while its retained Undo intent is input-conflicted.
    // The existing phase admission preserves that exact prepared custody and
    // still refuses prepared/admitted/published history. Finishing consumes only
    // the actual ordinary ACK; it neither resolves nor rebases the Undo intent.
    try admitOrdinaryOperation()
    guard !committing, sessionID == acknowledgement.sessionID,
      lastSequence == acknowledgement.lastSequence, sealedRecord == acknowledgement.sealedRootRecord else {
      throw BoomError.stale("Native ACK installation has another controller, sequence or current record.")
    }
    committing = true
    defer { committing = false }
    try await engine.finishNativeCommitCustody(controllerCustody, acknowledgement: acknowledgement, publisher: publisher)
    pendingCommitInstallationID = nil
  }

  /// The caller must first join every UI input/flush/navigation task. This
  /// explicit shutdown freezes further route admission before its await, then
  /// transfers the exact current record to a real validated coherent head.
  /// No automatic deinit release, guessed success or ordinary-app hook yet.
  func detachJoinedController(sessionID expectedSession: UUID?, sequence: UInt64,
    record: PagedDocumentRootRecord) async throws {
    guard !detached, !detachInFlight, !committing, activeWindows == 0,
      pendingHistory == nil, unresolvedOutput == nil, pendingCommitInstallationID == nil, pendingCapturedResult == nil,
      sessionID == expectedSession, lastSequence == sequence, sealedRecord == record else {
      throw BoomError.stale("Native detach has another controller, joined sequence or unresolved command/output.")
    }
    detaching = true; detachInFlight = true
    defer { detachInFlight = false }
    // A failed transfer retains the exact engine and its source output.
    // The owner may explicitly retry this same shutdown, never resume input.
    try await engine.transferJoinedRootToHead(controllerCustody, publisher: publisher, expected: record)
    lastJoinedHistoryCompletion = nil
    detached = true; detaching = false
  }
}
