import AppKit
import BoomCore
import Foundation

/// Implementation belongs to the existing storage executor. commit must admit
/// the complete captured root record (including history), apply exact ordered
/// deltas to a private candidate, and atomically seal source/history/workspace
/// metadata. An adapter that separately saves these values does not implement
/// this contract. Each returned ack has validated bounded bytes off MainActor.
/// If deltas were compacted, groupCheckpoints/historyBaseline retain the exact
/// last 100 native group states: mint their bounded candidate roots on the
/// worker before sealing history. Never pretend a net replacement alone can
/// reconstruct those intermediate Undo points.
protocol PagedNativeSessionStorage: Sendable {
  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement
  func window(expected: PagedTextRevision, utf16Anchor: UInt64,
    maximumBytes: Int) async throws -> PagedTextWindow
}

/// Refined real-root custody seam. A prototype storage has no implicit or
/// fabricated completion receipt. An actual backend retains both the source
/// and sealed roots until Main consumes its exact acknowledgement and this
/// join transfers the controller's custody to that sealed source base.
protocol PagedNativeCommitInstallationStorage: PagedNativeSessionStorage {
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws
}

protocol PagedNativeHistorySessionStorage: PagedNativeSessionStorage {
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove
  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement
  func noteHistoryInputConflict(_ prepared: PagedNativePreparedHistoryMove,
    observation: PagedNativeHistoryInputObservation) async throws -> PagedNativeHistoryInputConflictReceipt
  func resolveUnadmittedHistory(_ prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) async throws -> PagedNativeHistoryIntentDispositionReceipt
  func inspectHistoryRecovery(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery
  func completeVerifiedHistory(_ prepared: PagedNativePreparedHistoryMove,
    verificationID: UUID) async throws -> PagedNativeHistoryAcknowledgement
  func finishHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws
}

/// File storage routes explicitly opt in. Prototype histories receive no fabricated
/// default repair/ACK. Main owns only the existing command/commit task lane.
protocol PagedNativeFileDurabilityStorage: PagedNativeHistorySessionStorage, PagedNativeCommitInstallationStorage {
  func repairHistoryDurability(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery
  func repairCommitDurability(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement
  func inspectCommitRecovery(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitRecovery
  func retryVerifiedCommit(_ batch: PagedNativeCommitBatch, verificationID: UUID) async throws -> PagedNativeCommitAcknowledgement
}
enum PagedNativeCommitRecovery: Sendable {
  case published(PagedNativeCommitAcknowledgement)
  case knownUnpublished(verificationID: UUID)
}
/// A real successful BEFORE disposition, not another storage failure. The
/// native owner retains its original error/input and chooses explicit retry.
struct PagedNativeCommitKnownUnpublished: Error {
  let batchID: UUID
  let verificationID: UUID
}


/// One exact session-owned native group receiver. This is callback custody,
/// not a source/worker completion or physical input-method drain receipt. Only
/// the session can create, invoke or detach it. A detached token keeps neither
/// its receiver nor its session alive and can never acquire a later hook.
@MainActor final class PagedNativeGroupSubscription {
  let ownerID: UUID
  let sessionID: UUID
  fileprivate weak var session: PagedNativeSession?
  fileprivate var receiver: ((PagedNativeGroupSubscription, PagedNativeGroupClosureReceipt) -> Void)?
  fileprivate var sealReceiver: ((PagedNativeGroupSubscription, PagedNativeCanonicalSeal) throws -> Void)?
  fileprivate var installedReceiver: ((PagedNativeGroupSubscription) -> Void)?

  fileprivate init(ownerID: UUID, session: PagedNativeSession,
    receiver: @escaping (PagedNativeGroupSubscription, PagedNativeGroupClosureReceipt) -> Void,
    sealReceiver: ((PagedNativeGroupSubscription, PagedNativeCanonicalSeal) throws -> Void)?,
    installedReceiver: ((PagedNativeGroupSubscription) -> Void)?) {
    self.ownerID = ownerID; sessionID = session.sessionID
    self.session = session; self.receiver = receiver
    self.sealReceiver = sealReceiver; self.installedReceiver = installedReceiver
  }
  fileprivate func detach() { receiver = nil; sealReceiver = nil; installedReceiver = nil; session = nil }
}

struct PagedNativeUnpreparedHistoryDispositionReceipt: Sendable {
  let commandID: UUID
  let handle: PagedNativeHistoryHandle
  let prefix: PagedNativeSealedPrefix
  let disposition: PagedNativeHistoryIntentDisposition
}

/// One source-only reservation for a retained-root installation. It does not
/// advance UndoManager or publish a root. Its backing is released on explicit
/// cancellation or consumption; the session retains the prepared intent and
/// worker custody until its separate publication/disposition actually joins.
@MainActor final class PagedNativeHistoryInstallationTicket {
  fileprivate enum State: Equatable { case staged, cancelled, consumed }
  let admission: PagedNativeHistoryAdmission
  let localCaretUTF16: Int
  let documentSelection: PagedNativeNavigationSelection
  var sessionID: UUID { admission.sessionID }
  var provisionalArenaID: UUID { admission.provisionalArenaID }
  var commandID: UUID { admission.commandID }
  var preparationID: UUID { admission.preparationID }
  var window: PagedTextWindow {
    precondition(state == .staged && prepared != nil, "Only an unconsumed staged ticket has constructor backing.")
    return prepared!.window
  }
  fileprivate weak var owner: PagedNativeSession?
  fileprivate var state = State.staged
  fileprivate var prepared: PagedNativePreparedHistoryMove?
  fileprivate var candidate: PagedWorkingWindow?
  fileprivate var route: (any PagedNativeHistorySessionStorage)?

  fileprivate init(owner: PagedNativeSession, prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, candidate: PagedWorkingWindow,
    route: any PagedNativeHistorySessionStorage) {
    self.owner = owner; self.prepared = prepared; self.admission = admission
    localCaretUTF16 = prepared.localCaretUTF16; self.candidate = candidate; self.route = route
    documentSelection = PagedNativeNavigationSelection(utf16Offset: prepared.cursor.utf16Offset,
      utf16Length: prepared.cursor.selectionLengthUTF16, focusAtEnd: prepared.cursor.focusAtEnd,
      affinity: prepared.cursor.affinity)
  }
  fileprivate func releaseBacking() { prepared = nil; candidate = nil; route = nil }
}

/// A lexical, single-use source consumer. The command owner enters its scope
/// before Foundation advances the manager, and consumes from the synchronous
/// Undo/Redo handler. No fallible admission, scalar work or worker launch runs
/// after that advancement. Escaped, repeated or unconsumed use is an owner
/// programming error, never an asynchronous repair of the manager's stack.
@MainActor final class PagedNativeHistorySourceConsumer {
  fileprivate struct Publication {
    let prepared: PagedNativePreparedHistoryMove
    let admission: PagedNativeHistoryAdmission
    let route: any PagedNativeHistorySessionStorage
  }
  fileprivate let ticket: PagedNativeHistoryInstallationTicket
  fileprivate weak var owner: PagedNativeSession?
  fileprivate var active = true
  fileprivate var publication: Publication?
  fileprivate init(owner: PagedNativeSession, ticket: PagedNativeHistoryInstallationTicket) {
    self.owner = owner; self.ticket = ticket
  }
  @discardableResult
  func consume(installing: (PagedTextWindow, UUID, Int) -> Void) -> PagedNativeHistoryAdmission {
    guard let owner else { preconditionFailure("A source consumer lost its exclusive session owner.") }
    return owner.consumeStagedHistory(self, installing: installing)
  }
}

/// Explicit global UTF-16 coordinates for navigation on the SAME captured
/// source. This is no authority to replay an interpreted old-arena input range.
struct PagedNativeNavigationSelection: Sendable, Equatable {
  let utf16Offset: UInt64
  let utf16Length: UInt64
  let focusAtEnd: Bool
  let affinity: PagedSelectionAffinity
  init(utf16Offset: UInt64, utf16Length: UInt64, focusAtEnd: Bool = false,
    affinity: PagedSelectionAffinity = .downstream) {
    self.utf16Offset = utf16Offset; self.utf16Length = utf16Length; self.focusAtEnd = focusAtEnd
    self.affinity = affinity
  }
  var focusUTF16: UInt64 { focusAtEnd ? utf16Offset + utf16Length : utf16Offset }
  var anchorUTF16: UInt64 { focusAtEnd ? utf16Offset : utf16Offset + utf16Length }
}

/// One bounded projection prepared without changing the active working arena.
/// Cancellation releases only this joined window, never accepted input/history.
@MainActor final class PagedNativeNavigationInstallationTicket {
  fileprivate enum State: Equatable { case staged, cancelled, consumed }
  let operationID: UUID
  let sessionID: UUID
  let sourceArenaID: UUID
  let sourceGeneration: UInt64
  let provisionalArenaID: UUID
  let localSelection: NSRange
  let selectionAffinity: NSSelectionAffinity
  let documentSelection: PagedNativeNavigationSelection?
  fileprivate let sourceWindowID: UUID
  fileprivate let sourceRecord: PagedDocumentRootRecord
  fileprivate weak var owner: PagedNativeSession?
  fileprivate weak var inputOwner: PagedNativeInputOwner?
  fileprivate var state = State.staged
  fileprivate var candidate: PagedWorkingWindow?
  fileprivate let capturedEdit: PagedCapturedEditResult?
  var isAwaitingAdoption: Bool { state == .staged }
  var wasConsumed: Bool { state == .consumed }
  var window: PagedTextWindow {
    precondition(state == .staged && candidate != nil)
    return candidate!.sealedWindow
  }
  fileprivate init(owner: PagedNativeSession, inputOwner: PagedNativeInputOwner,
    candidate: PagedWorkingWindow, sourceArenaID: UUID, sourceWindowID: UUID,
    localSelection: NSRange, selectionAffinity: NSSelectionAffinity,
    sourceGeneration: UInt64? = nil, sourceRecord: PagedDocumentRootRecord? = nil,
    capturedEdit: PagedCapturedEditResult? = nil,
    documentSelection: PagedNativeNavigationSelection? = nil) {
    operationID = UUID(); self.owner = owner; self.inputOwner = inputOwner
    self.candidate = candidate; self.sourceArenaID = sourceArenaID
    self.sourceWindowID = sourceWindowID; self.localSelection = localSelection
    self.selectionAffinity = selectionAffinity
    sessionID = candidate.sessionID; self.sourceGeneration = sourceGeneration ?? candidate.generation
    provisionalArenaID = candidate.arenaID; self.sourceRecord = sourceRecord ?? candidate.sealedRootRecord
    self.capturedEdit = capturedEdit
    self.documentSelection = documentSelection
  }
  fileprivate func releaseBacking() { candidate = nil; inputOwner = nil }
}

/// Small identity of an ACTUAL joined history installation. This is neither
/// a root lease nor an ACK factory; no source window/bytes are retained here.
struct PagedNativeReceivingHistoryIdentity: Sendable, Equatable {
  let routeID: UUID
  let preparationID: UUID
  let command: PagedNativeHistoryMoveCommand
  let afterRecord: PagedDocumentRootRecord
  let provisionalArenaID: UUID
  let preparedWindowID: UUID
  let admittedSequence: UInt64
  let cursor: PagedSealedCursor
  let engineIncarnation: UUID

  init(prepared: PagedNativePreparedHistoryMove,
    acknowledgement: PagedNativeHistoryAcknowledgement) throws {
    let command = prepared.command
    guard let metadata = acknowledgement.canonicalHistory,
      acknowledgement.commandID == command.commandID,
      acknowledgement.preparationID == prepared.preparationID,
      acknowledgement.sessionID == command.sessionID,
      acknowledgement.sourceArenaID == command.sourceArenaID,
      acknowledgement.sourceWindowID == command.sourceWindowID,
      acknowledgement.preparedWindowID == prepared.window.windowID,
      acknowledgement.expectedSequence == command.expectedSequence,
      acknowledgement.admittedSequence == (try command.nextSequence()),
      acknowledgement.expectedRootRecord == command.expectedRootRecord,
      acknowledgement.sealedRootRecord == prepared.candidateRecord,
      acknowledgement.cursor == prepared.cursor,
      acknowledgement.localCaretUTF16 == prepared.localCaretUTF16,
      acknowledgement.sealedBytes == prepared.windowBytes,
      metadata.record == prepared.candidateRecord,
      metadata.beforeRecord == command.expectedRootRecord,
      metadata.scope == .historyPublished(sessionID: command.sessionID, routeID: prepared.routeID,
        commandID: command.commandID, preparationID: prepared.preparationID,
        expected: command.expectedSequence, admitted: acknowledgement.admittedSequence) else {
      throw BoomError.stale("Receiving completion has another actual history installation.")
    }
    routeID = prepared.routeID; preparationID = prepared.preparationID
    self.command = command; afterRecord = acknowledgement.sealedRootRecord
    provisionalArenaID = acknowledgement.provisionalArenaID
    preparedWindowID = acknowledgement.preparedWindowID
    admittedSequence = acknowledgement.admittedSequence; cursor = acknowledgement.cursor
    engineIncarnation = metadata.producer.engineIncarnation
  }
}

/// Synchronous observation of real entered producers and the current source.
/// Values alone grant neither storage authentication nor input/worker custody.
struct PagedNativeReceivingCheckpoint: Sendable, Equatable {
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
  let sealedGeneration: UInt64
  /// Existing Session failure serial, even after its exact storage recovery.
  /// An older receiving observation cannot erase that intervening failure.
  let sourceFailureSerial: UInt64
  let record: PagedDocumentRootRecord
  let engineIncarnation: UUID
  let unpreparedCommandID: UUID?
  let unpreparedHandle: PagedNativeHistoryHandle?
  let completedHistory: PagedNativeReceivingHistoryIdentity?
}

/// Controller only. The actual NSTextStorage mutation must call replace for
/// its exact range; textDidChange must not re-read/publish a whole String.
/// The working arena remains usable while the storage acknowledgement waits.
@MainActor final class PagedNativeSession {
  private struct HistoryIntent {
    let commandID: UUID
    let handle: PagedNativeHistoryHandle
    let prefix: PagedNativePrefixReservation
    var prepared: PagedNativePreparedHistoryMove?
    var conflict: PagedNativeHistoryInputConflictReceipt?
    var admission: PagedNativeHistoryAdmission?
    var acknowledgement: PagedNativeHistoryAcknowledgement?
  }
  private var working: PagedWorkingWindow
  private let storage: any PagedNativeSessionStorage
  private var commitTask: Task<PagedNativeCommitAcknowledgement?, Never>?
  /// The newest logical request may be invalidated while an earlier producer
  /// is still awaiting its actual storage result. Track those lifetimes
  /// separately; cancellation/invalidation alone never joins a producer.
  static let maximumNavigationOperations = 8
  private var navigationID: UUID?
  private var navigationOperations: Set<UUID> = []
  private var characterTransactionDepth = 0
  private var historyIntent: HistoryIntent?
  private var historyTask: Task<PagedNativeHistoryAcknowledgement?, Never>?
  private var preparingHistory = false
  private var preparingIntent = false
  private var notifyingHistoryConflict = false
  private var resolvingHistory = false
  private var inspectingHistory = false
  private var installingHistory = false
  private var stagedInstallation: PagedNativeHistoryInstallationTicket?
  private var stagedNavigation: PagedNativeNavigationInstallationTicket?
  private var adoptingNavigation = false
  private var capturedEditCommandID: UUID?
  private var capturedEditExpectedRecord: PagedDocumentRootRecord?
  private var capturedEditResult: PagedCapturedEditResult?
  private weak var managedArenaOwner: PagedNativeInputOwner?
  private var adoptingHistory = false
  private var notifyingNativeGroup = false
  private var nativeSealNotificationDepth = 0
  private var nativeGroupSubscription: PagedNativeGroupSubscription?
  private var nativeGroupHookTransition = false
  private var notifyingCanonicalHistory = false
  private(set) var canonicalOpening: PagedNativeCanonicalOpening?
  private(set) var canonicalHistory: PagedNativeCanonicalHistoryProjection?
  private var lastHistoryAcknowledgement: PagedNativeHistoryAcknowledgement?
  /// A real ACK already consumed by Main whose refined custody completion has
  /// not joined. Preserve this identity across refusal/lost completion reply;
  /// neither a detached view nor a failure observer may relabel it as success.
  private(set) var pendingCommitInstallation: PagedNativeCommitAcknowledgement?
  private(set) var lastDurabilityRepairOriginalFailure: Error?
  private var failedCommitDurabilityBatchID: UUID?
  private var failedCommitDurabilityFailureSerial: UInt64?
  private var verifiedCommitBefore: (batchID: UUID, verificationID: UUID, serial: UInt64)?
  private var inspectingCommitRecovery = false
  private var failedHistoryDurabilityFailureSerial: UInt64?
  private(set) var lastCommitInstallationFailure: Error?
  private var commitInstallationFailureBatchID: UUID?
  private var commitInstallationFailureSerial: UInt64?
  private(set) var historyFailure: Error?
  private(set) var persistenceFailure: Error?
  private var persistenceFailureSerial: UInt64 = 0
  private var persistenceFailureSerialExhausted = false
  var didSeal: ((PagedTextWindow) -> Void)?
  var didFail: ((Error) -> Void)?
  /// Prototype-only receiver. It never represents, replaces or detaches an
  /// owned subscription. Owned delivery takes precedence; this value is left
  /// untouched when that exact owned subscription is detached.
  var didCloseNativeGroup: ((PagedNativeGroupClosureReceipt) -> Void)?

  init(window: PagedTextWindow, rootRecord: PagedDocumentRootRecord,
    storage: any PagedNativeSessionStorage) throws {
    working = try PagedWorkingWindow(window: window, rootRecord: rootRecord); self.storage = storage
  }
  init(opening: PagedNativeCanonicalOpening, storage: any PagedNativeSessionStorage) throws {
    guard storage is any PagedNativeCommitInstallationStorage,
      storage is any PagedNativeHistorySessionStorage else {
      throw BoomError.denied("Canonical native opening requires its actual refined installation owner.")
    }
    try opening.history.admit(record: opening.record, sessionID: opening.sessionID,
      engineIncarnation: opening.history.producer.engineIncarnation,
      scope: .opening(sessionID: opening.sessionID, windowID: opening.window.windowID))
    working = try PagedWorkingWindow(window: opening.window, rootRecord: opening.record, sessionID: opening.sessionID)
    self.storage = storage; canonicalOpening = opening; canonicalHistory = opening.history
  }
  var sessionID: UUID { working.sessionID }
  var arenaID: UUID { working.arenaID }
  var generation: UInt64 { working.generation }
  var isPinned: Bool { working.isPinned }
  var compositionGroupID: UUID? { working.compositionGroup }
  var localUTF16Count: Int { working.localUTF16Count }
  var needsRecentering: Bool { working.needsRecentering }
  var sealedRevision: PagedTextRevision { working.sealedWindow.revision }
  var sourceBaseRevision: PagedTextRevision { working.sourceBaseRevision }
  var hasPendingHistoryCommand: Bool { historyIntent != nil }
  var isProvisionalHistory: Bool { working.hasProvisionalHistory }
  var activeNavigationOperationCount: Int { navigationOperations.count }

  /// Read-only scrolling needs stable physical bytes, not a durable ACK or a
  /// joined writer. IME and retained unrelated source failures can coexist.
  func captureScrollSnapshot() throws -> PagedNativeScrollSnapshot {
    guard characterTransactionDepth == 0, canonicalOpening == nil,
      stagedInstallation == nil, stagedNavigation == nil, !adoptingNavigation,
      !adoptingHistory, !installingHistory else {
      throw BoomError.stale("Native display is installing a different physical source.")
    }
    return try working.captureScrollSnapshot()
  }
  func isCurrent(_ snapshot: PagedNativeScrollSnapshot) -> Bool {
    snapshot.sessionID == working.sessionID && snapshot.arenaID == working.arenaID
      && snapshot.generation == working.generation && canonicalOpening == nil
      && stagedInstallation == nil && stagedNavigation == nil && !adoptingNavigation
      && !adoptingHistory && !installingHistory && characterTransactionDepth == 0
  }

  private var coordinateWindow: (id: UUID, utf16: Int)?
  /// Pure bounded presentation metadata. It never labels unsealed input with
  /// a sealed source digest or advances the immutable Root summary/history.
  func documentCoordinates() throws -> PagedNativeDocumentCoordinates {
    let window = working.projectionWindow, record = working.sealedRootRecord
    if coordinateWindow?.id != window.windowID {
      coordinateWindow = (window.windowID, window.text.utf16.count)
    }
    guard let original = coordinateWindow?.utf16,
      UInt64(original) <= window.revision.summary.utf16 else {
      throw BoomError.invalid("Native projected extent differs from its actual bounded window.")
    }
    let outside = window.revision.summary.utf16 - UInt64(original)
    let projected = outside.addingReportingOverflow(UInt64(working.localUTF16Count))
    guard !projected.overflow else { throw BoomError.budget("Native projected document extent overflowed.") }
    return PagedNativeDocumentCoordinates(record: record, sessionID: sessionID, arenaID: arenaID,
      generation: generation, windowID: window.windowID, utf16Start: window.utf16Start,
      localUTF16: working.localUTF16Count, projectedUTF16: projected.partialValue, localBytes: working.bytes.count)
  }

  /// Every synchronous/async source-transition entry shares this fence. Stage
  /// construction, Foundation notifications and group-receipt callbacks may
  /// reenter Main, but none may invalidate an already staged source candidate.
  private var sourceTransitionIsFenced: Bool {
    stagedInstallation != nil || stagedNavigation != nil || adoptingNavigation
      || adoptingHistory || installingHistory || notifyingNativeGroup
      || nativeGroupHookTransition || notifyingCanonicalHistory || capturedEditCommandID != nil
  }
  private func requireSourceTransition(allowCanonicalOpening: Bool = false) throws {
    guard !sourceTransitionIsFenced, allowCanonicalOpening || canonicalOpening == nil else {
      throw BoomError.stale("A staged source owner, native group notification or hook transition reserves this transition.")
    }
  }

  /// Only a fresh or completely joined session can install its sealed window.
  /// Pending native characters must remain in their existing text storage.
  func windowForNativeInstallation() throws -> PagedTextWindow {
    try requireSourceTransition(allowCanonicalOpening: true)
    guard !working.hasUnsealedChanges, !working.isPinned, working.reservedPrefix == nil,
      historyIntent == nil, commitTask == nil, historyTask == nil, pendingCommitInstallation == nil,
      !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory,
      !inspectingHistory, !inspectingCommitRecovery, nativeSealNotificationDepth == 0, navigationOperations.isEmpty,
      persistenceFailure == nil, historyFailure == nil, characterTransactionDepth == 0 else {
      throw BoomError.stale("Native input, notifications or an unjoined source producer pin the existing physical client.")
    }
    return working.sealedWindow
  }

  /// One actual physical owner prevents the prototype navigation route from
  /// rotating a live immutable binding behind its owning input graph.
  func registerManagedArenaOwner(_ owner: PagedNativeInputOwner) throws {
    _ = try windowForNativeInstallation()
    guard managedArenaOwner == nil, owner.session === self else {
      throw BoomError.denied("This native session already has its physical arena owner.")
    }
    managedArenaOwner = owner
  }
  func retireManagedArenaOwner(_ owner: PagedNativeInputOwner) {
    precondition(managedArenaOwner === owner && owner.session === self
      && stagedNavigation == nil && !adoptingNavigation)
    managedArenaOwner = nil
  }

  /// Capture actual local selection coordinates while they still belong to
  /// this source, before yielding to flush/window. Later input invalidates it.
  func navigationSelection(_ range: NSRange) throws -> PagedNativeNavigationSelection {
    // Coordinates observe the installed working arena. A pending file/history
    // acknowledgment cannot make its already installed selection unreadable.
    _ = try working.selection(range)
    let offset = working.sealedWindow.utf16Start.addingReportingOverflow(UInt64(range.location))
    guard !offset.overflow else { throw BoomError.budget("Native global selection overflows its coordinate bound.") }
    return PagedNativeNavigationSelection(utf16Offset: offset.partialValue, utf16Length: UInt64(range.length))
  }

  /// Receiving-only admission permits retained later characters. Physical
  /// installation would require those characters to seal first; this method
  /// instead proves all currently ENTERED producers/notifications have joined.
  /// It does not read storage, copy a text island, hash bytes or release pins.
  func receivingDispositionCheckpoint(prefix: PagedNativePrefixReservation?,
    completedHistory prepared: PagedNativePreparedHistoryMove?) throws -> PagedNativeReceivingCheckpoint {
    try requireSourceTransition()
    guard commitTask == nil, historyTask == nil, working.inFlight == nil,
      pendingCommitInstallation == nil, !preparingIntent, !preparingHistory,
      !notifyingHistoryConflict, !resolvingHistory, !inspectingHistory, !inspectingCommitRecovery,
      nativeSealNotificationDepth == 0, navigationOperations.isEmpty,
      characterTransactionDepth == 0, !working.isPinned, !working.hasProvisionalHistory,
      persistenceFailure == nil, !persistenceFailureSerialExhausted,
      let metadata = canonicalHistory, metadata.record == working.sealedRootRecord,
      metadata.scope.sessionID == sessionID,
      metadata.scope.coveredSequence == working.sealedGeneration else {
      throw BoomError.stale("Receiving disposition still has an entered producer, unjoined ACK or independent source failure.")
    }
    var unpreparedCommandID: UUID?
    var unpreparedHandle: PagedNativeHistoryHandle?
    var completed: PagedNativeReceivingHistoryIdentity?
    if let prefix {
      guard prepared == nil else { throw BoomError.invalid("Receiving disposition cannot cancel and complete the same history intent.") }
      let sealed = try working.sealedPrefix(prefix)
      guard sealed.rootRecord == metadata.record else { throw BoomError.stale("Receiving cancellation has another full joined prefix.") }
      if let intent = historyIntent {
        guard intent.prefix == prefix, intent.prepared == nil, intent.admission == nil,
          intent.acknowledgement == nil, historyFailure != nil else {
          throw BoomError.stale("An admitted or uncertain history candidate cannot be cancelled by receiving disposition.")
        }
        unpreparedCommandID = intent.commandID; unpreparedHandle = intent.handle
      } else if historyFailure != nil {
        throw BoomError.stale("An independent history failure cannot be cleared by receiving cancellation.")
      }
    } else if let prepared {
      guard historyIntent == nil, historyFailure == nil, working.reservedPrefix == nil,
        let acknowledgement = lastHistoryAcknowledgement else {
        throw BoomError.stale("Receiving completion requires the actual already-joined Session finish.")
      }
      let identity = try PagedNativeReceivingHistoryIdentity(prepared: prepared, acknowledgement: acknowledgement)
      completed = identity
      guard identity.admittedSequence <= working.sealedGeneration,
        identity.provisionalArenaID == working.arenaID else {
        throw BoomError.stale("A replaced source arena or superseded command cannot use an old history finish.")
      }
    } else {
      throw BoomError.invalid("Receiving disposition requires an exact prefix or joined history identity.")
    }
    return PagedNativeReceivingCheckpoint(sessionID: sessionID, arenaID: arenaID,
      generation: generation, sealedGeneration: working.sealedGeneration,
      sourceFailureSerial: persistenceFailureSerial, record: metadata.record,
      engineIncarnation: metadata.producer.engineIncarnation,
      unpreparedCommandID: unpreparedCommandID, unpreparedHandle: unpreparedHandle,
      completedHistory: completed)
  }

  /// Register once while the real source owner is quiescent. The caller owns
  /// its native command/input identity; the token binds that identity to this
  /// exact session object. A prototype callback must be removed explicitly
  /// before installing an owned receiver, never mistaken for that receiver.
  func registerNativeGroupSubscription(ownerID: UUID,
    onCanonicalSeal: ((PagedNativeGroupSubscription, PagedNativeCanonicalSeal) throws -> Void)? = nil,
    onCanonicalInstalled: ((PagedNativeGroupSubscription) -> Void)? = nil,
    onClose: @escaping (PagedNativeGroupSubscription, PagedNativeGroupClosureReceipt) -> Void)
    throws -> PagedNativeGroupSubscription {
    _ = try windowForNativeInstallation()
    guard nativeGroupSubscription == nil, didCloseNativeGroup == nil,
      canonicalHistory == nil || onCanonicalSeal != nil else {
      throw BoomError.denied("This session already has a native group receiver.")
    }
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard ownerID != zero else { throw BoomError.invalid("A native group receiver requires its command-owner identity.") }
    nativeGroupHookTransition = true
    defer { nativeGroupHookTransition = false }
    let subscription = PagedNativeGroupSubscription(ownerID: ownerID, session: self, receiver: onClose,
      sealReceiver: onCanonicalSeal, installedReceiver: onCanonicalInstalled)
    nativeGroupSubscription = subscription
    return subscription
  }

  /// This quiescent preflight is for ownership transfer/retirement, not for
  /// calling from the receiver itself. Delivery supplies the exact token so
  /// its owner can compare object identity inside the notification scope.
  func requireNativeGroupSubscription(_ subscription: PagedNativeGroupSubscription,
    ownerID: UUID) throws {
    guard nativeGroupSubscription === subscription, subscription.session === self,
      subscription.ownerID == ownerID, subscription.sessionID == sessionID,
      subscription.receiver != nil else {
      throw BoomError.denied("Another native group subscription or detached token owns this hook.")
    }
    _ = try windowForNativeInstallation()
  }

  /// Complete all fallible source/token admission before entering the real
  /// synchronous retirement scope. The owner retires its exact physical
  /// client before releasing captured callback objects can reenter AppKit.
  /// That body must consume its already-preflighted opaque input ticket;
  /// it must not perform another joined admission from inside this fence.
  /// A foreign/stale token never invokes the body or changes any hook.
  func detachNativeGroupSubscription(_ subscription: PagedNativeGroupSubscription,
    ownerID: UUID, retiringClient: () -> Void = {}) throws {
    try requireNativeGroupSubscription(subscription, ownerID: ownerID)
    // Releasing a closure can synchronously destroy captured objects. Keep
    // that real hook mutation in the shared source fence until disposal ends.
    nativeGroupHookTransition = true
    defer { nativeGroupHookTransition = false }
    retiringClient()
    // No further fallible check follows physical retirement. The exact token
    // and source were admitted before the owner entered this lexical scope.
    subscription.detach()
    nativeGroupSubscription = nil
  }

  /// The fresh canonical physical client stays staged through this complete
  /// Main lexical hydration interval. All fallible checks precede SDK mutation.
  func withCanonicalOpening(_ subscription: PagedNativeGroupSubscription,
    ownerID: UUID, completing: () -> Void) throws {
    try requireNativeGroupSubscription(subscription, ownerID: ownerID)
    guard let opening = canonicalOpening, canonicalHistory == opening.history,
      opening.sessionID == sessionID, working.generation == 0,
      working.sealedRootRecord == opening.record, subscription.sealReceiver != nil else {
      throw BoomError.stale("Canonical physical opening is not this fresh joined source owner.")
    }
    nativeGroupHookTransition = true
    defer { nativeGroupHookTransition = false }
    completing()
    canonicalOpening = nil
  }

  private func installCanonicalHistory(_ receipt: PagedNativeCanonicalSeal) throws {
    guard let current = canonicalHistory else { return } // inactive primitive controls only
    guard let incoming = receipt.projection, let subscription = nativeGroupSubscription,
      subscription.session === self, subscription.sessionID == sessionID,
      let receiver = subscription.sealReceiver,
      incoming.record == working.sealedRootRecord,
      incoming.scope.coveredSequence == working.sealedGeneration,
      incoming.producer.ownerID == current.producer.ownerID,
      incoming.producer.engineIncarnation == current.producer.engineIncarnation,
      incoming.scope.sessionID == sessionID,
      incoming.hasSamePublishedMetadata(as: current) || incoming.beforeRecord == current.record else {
      throw BoomError.stale("Published native ACK lacks its actual canonical metadata owner and prefix.")
    }
    switch receipt {
    case .capturedEdit(let result):
      guard incoming.scope == .capturedEdit(sessionID: result.sessionID,
        commandID: result.commandID, sequence: result.sequence),
        incoming.beforeRecord == result.beforeRecord, incoming.record == result.record else {
        throw BoomError.stale("Captured edit history differs from its published source.")
      }
    case .native(let ack):
      guard case .nativeBatch(let session, let batch, _, let last) = incoming.scope,
        session == ack.sessionID, batch == ack.batchID, last == ack.lastSequence,
        incoming.beforeRecord == ack.expectedRootRecord, incoming.record == ack.sealedRootRecord else {
        throw BoomError.stale("Canonical ordinary metadata differs from its retained ACK identity.")
      }
    case .history(let ack):
      guard case .historyPublished(let session, _, let command, let preparation, let expected, let admitted) = incoming.scope,
        session == ack.sessionID, command == ack.commandID, preparation == ack.preparationID,
        expected == ack.expectedSequence, admitted == ack.admittedSequence,
        incoming.beforeRecord == ack.expectedRootRecord, incoming.record == ack.sealedRootRecord else {
        throw BoomError.stale("Canonical history metadata differs from its retained publication ACK.")
      }
    }
    notifyingCanonicalHistory = true
    defer { notifyingCanonicalHistory = false }
    try receiver(subscription, receipt)
    canonicalHistory = incoming
  }

  func canReplace(_ range: NSRange, with replacement: String) throws {
    try requireSourceTransition()
    let selection = try working.selection(range)
    let removed = try working.localBytes(for: selection).count
    guard replacement.utf8.count <= PagedWorkingWindow.hardBytes - (working.bytes.count - removed) else {
      throw BoomError.budget("Native replacement requires the bounded stream/recenter route.")
    }
  }

  func nativeSelection(_ range: NSRange) throws -> PagedWorkingSelection {
    if let owner = managedArenaOwner, owner.activeView?.selectedRange() == range {
      let selection = try owner.currentDocumentSelection()
      return try working.selection(range, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
    }
    return try working.selection(range)
  }
  func nativeLocalBytes(_ range: NSRange) throws -> Range<Int> {
    return try working.localBytes(for: working.selection(range))
  }

  @discardableResult
  func beginComposition(groupID: UUID? = nil) -> Bool {
    guard !sourceTransitionIsFenced, canonicalOpening == nil else { return false }
    working.beginComposition(groupID: groupID)
    return true
  }
  @discardableResult
  func endComposition() -> Bool {
    guard !sourceTransitionIsFenced, canonicalOpening == nil else { return false }
    working.endComposition()
    if characterTransactionDepth == 0 {
      emitGroupClosure(working.closeNativeGroup())
      requestCommit()
    }
    return true
  }
  /// The actual accepted-character primitive opens this gate before any
  /// mutation can reenter observers. Attribute-only transactions do not.
  func nativeCharacterTransactionWillBegin() throws {
    try requireSourceTransition()
    guard characterTransactionDepth < 32 else { throw BoomError.budget("Native character transaction nesting exceeds its bound.") }
    characterTransactionDepth += 1
  }
  @discardableResult
  func replace(_ range: NSRange, with replacement: String, groupID: UUID,
    beforeSelection: PagedWorkingSelection? = nil) throws -> Bool {
    try requireSourceTransition()
    guard characterTransactionDepth > 0 else { throw BoomError.denied("Native mutation has no captured character transaction.") }
    let result = try working.replaceReportingClosure(range, with: replacement, groupID: groupID,
      beforeSelection: beforeSelection)
    emitGroupClosure(result.closedGroup)
    return result.accepted
  }
  /// Call after the character transaction closes. IME commits are explicitly
  /// unmarked before pumping; attribute-only updates do not enqueue mutations.
  @discardableResult
  func nativeCharacterTransactionDidClose(capturingSelectionFrom view: PagedNativeTextView? = nil) -> Bool {
    guard !sourceTransitionIsFenced, canonicalOpening == nil else { return false }
    guard characterTransactionDepth > 0 else {
      fail(BoomError.invalid("Native character transaction close is unmatched.")); return false
    }
    characterTransactionDepth -= 1
    if characterTransactionDepth == 0 {
      if working.hasOpenNativeGroup, let view {
        do {
          guard let owner = managedArenaOwner, owner.activeView === view,
            view.session === self, view.inputBinding?.owner === owner,
            view.inputBinding?.state == .active else {
            throw BoomError.stale("Native after-selection belongs to another physical source.")
          }
          // AppKit has returned from the outer view operation. Capture before
          // close/requestCommit synchronously freezes the actual worker batch.
          try working.captureNativeAfterSelection(nativeSelection(view.selectedRange()))
        } catch { fail(error); return false }
      }
      if !working.isPinned { emitGroupClosure(working.closeNativeGroup()) }
      requestCommit()
    }
    return true
  }

  /// An explicit idle boundary has no worker side effect. The actual outer
  /// character/IME close also reports this before pumping publication.
  @discardableResult
  func closeNativeGroup() throws -> PagedNativeGroupClosureReceipt? {
    try requireSourceTransition()
    guard characterTransactionDepth == 0, !working.isPinned else {
      throw BoomError.stale("An open character or marked-text transaction still owns its native group.")
    }
    let receipt = working.closeNativeGroup()
    emitGroupClosure(receipt)
    return receipt
  }

  private func emitGroupClosure(_ receipt: PagedNativeGroupClosureReceipt?) {
    guard let receipt else { return }
    precondition(!notifyingNativeGroup, "Native group closure cannot reenter its source owner.")
    notifyingNativeGroup = true
    defer { notifyingNativeGroup = false }
    if let subscription = nativeGroupSubscription {
      precondition(subscription.session === self && subscription.sessionID == sessionID
        && subscription.receiver != nil, "The owned native group receiver lost its exact session.")
      subscription.receiver?(subscription, receipt)
    } else {
      didCloseNativeGroup?(receipt)
    }
  }

  /// Ordinary commit clears its task slot before notifying. The real lexical
  /// callback scope still excludes physical retirement/hook transfer, without
  /// preventing the existing native character path from accepting later input.
  private func emitNativeSeal(_ window: PagedTextWindow) {
    // Preserve legitimate later native input, including a nested AppKit event
    // scope. A depth records every actual lexical notification; an inner
    // return cannot clear the outer callback's retirement exclusion.
    nativeSealNotificationDepth += 1
    defer { nativeSealNotificationDepth -= 1 }
    if let subscription = nativeGroupSubscription { subscription.installedReceiver?(subscription) }
    didSeal?(window)
  }

  func requestCommit() {
    guard !sourceTransitionIsFenced, canonicalOpening == nil, commitTask == nil, historyTask == nil, !preparingHistory,
      pendingCommitInstallation == nil,
      persistenceFailure == nil, characterTransactionDepth == 0 else { return }
    let batch: PagedNativeCommitBatch
    do {
      let result = try working.takeCommitBatchReportingClosure()
      emitGroupClosure(result.closedGroup)
      guard let pending = result.batch else { return }
      batch = pending
    } catch { fail(error); return }
    let storage = storage
    let startingFailureSerial = persistenceFailureSerial
    // The task owns exactly one bounded batch. Keep the session alive until
    // commit joins, so a detached view does not abandon an uncertain publish.
    commitTask = Task { [self, storage] in
      do {
        let acknowledgement = try await storage.commit(batch)
        try working.acknowledge(acknowledgement)
        if let route = storage as? any PagedNativeCommitInstallationStorage {
          pendingCommitInstallation = acknowledgement
          commitInstallationFailureBatchID = nil; commitInstallationFailureSerial = nil
          try installCanonicalHistory(.native(acknowledgement))
          try await route.finishCommitInstallation(acknowledgement)
          pendingCommitInstallation = nil
        }
        commitTask = nil
        emitNativeSeal(acknowledgement.sealedWindow)
        requestCommit()
        return acknowledgement
      } catch {
        commitTask = nil
        if let pendingCommitInstallation, pendingCommitInstallation.batchID == batch.batchID {
          lastCommitInstallationFailure = error
          commitInstallationFailureBatchID = batch.batchID
          // An independent native failure can arrive while commit/finish is
          // awaiting. Preserve it; record the original completion refusal in
          // its separate bounded slot rather than overwriting its ownership.
          if !persistenceFailureSerialExhausted, persistenceFailureSerial == startingFailureSerial {
            commitInstallationFailureSerial = fail(error)
          }
        } else {
          lastDurabilityRepairOriginalFailure = error
          failedCommitDurabilityBatchID = batch.batchID
          if !persistenceFailureSerialExhausted, persistenceFailureSerial == startingFailureSerial {
            failedCommitDurabilityFailureSerial = fail(error)
          } else {
            // Preserve a real newer callback failure and the actual source
            // error separately. No Error equality or silent replacement.
            failedCommitDurabilityFailureSerial = nil
          }
        }
        return nil
      }
    }
  }

  /// Explicit source-owner recovery of a failed ordinary COMMIT's actual
  /// after-result. Later accepted characters remain in WorkingWindow; neither
  /// a new failure nor raw receiving-owner input is cleared by this call.
  func repairCommitDurability() async throws -> PagedNativeCommitAcknowledgement {
    try await completeFailedCommit(verificationID: nil)
  }
  func completeVerifiedCommit(verificationID: UUID) async throws -> PagedNativeCommitAcknowledgement {
    try await completeFailedCommit(verificationID: verificationID)
  }
  func inspectCommitRecovery() async throws -> PagedNativeCommitRecovery {
    try requireSourceTransition()
    guard !inspectingCommitRecovery, commitTask == nil, historyTask == nil, pendingCommitInstallation == nil,
      !preparingHistory, !inspectingHistory, characterTransactionDepth == 0, !working.isPinned,
      let batch = working.failedBatchRetained, persistenceFailure != nil,
      !persistenceFailureSerialExhausted, failedCommitDurabilityBatchID == batch.batchID,
      failedCommitDurabilityFailureSerial == persistenceFailureSerial,
      let route = storage as? any PagedNativeFileDurabilityStorage else { throw BoomError.stale("No actual failed input can enter outcome inspection.") }
    let serial = persistenceFailureSerial
    verifiedCommitBefore = nil // a prior exact permit cannot survive a new refused inspection
    inspectingCommitRecovery = true; defer { inspectingCommitRecovery = false }
    let result: PagedNativeCommitRecovery
    do { result = try await route.inspectCommitRecovery(batch) }
    catch {
      // This direct entered call has no outer task catch recording the same
      // error. A later callback already advancing the serial stays separate.
      if !persistenceFailureSerialExhausted, serial == persistenceFailureSerial {
        failedCommitDurabilityFailureSerial = fail(error)
      }
      throw error
    }
    guard !persistenceFailureSerialExhausted, serial == persistenceFailureSerial,
      working.failedBatchRetained?.batchID == batch.batchID else { throw BoomError.stale("A newer source/input failure or producer invalidated this inspection.") }
    if case .knownUnpublished(let verificationID) = result {
      verifiedCommitBefore = (batch.batchID, verificationID, serial)
    } else { verifiedCommitBefore = nil }
    return result // AFTER is still retained; explicit repair performs its actual installation
  }
  private func completeFailedCommit(verificationID: UUID?) async throws -> PagedNativeCommitAcknowledgement {
    try requireSourceTransition()
    guard commitTask == nil, pendingCommitInstallation == nil, historyTask == nil,
      !preparingHistory, !inspectingHistory, !inspectingCommitRecovery, characterTransactionDepth == 0, !working.isPinned,
      let batch = working.failedBatchRetained, let original = persistenceFailure,
      !persistenceFailureSerialExhausted, failedCommitDurabilityBatchID == batch.batchID,
      failedCommitDurabilityFailureSerial == persistenceFailureSerial,
      let route = storage as? any PagedNativeFileDurabilityStorage else {
      throw BoomError.stale("No actual failed file batch can enter durability receiving.")
    }
    let serial = persistenceFailureSerial
    if let verificationID {
      guard let verified = verifiedCommitBefore, verified.batchID == batch.batchID,
        verified.verificationID == verificationID, verified.serial == serial else { throw BoomError.stale("Explicit native retry has another exact BEFORE/failure scope.") }
      verifiedCommitBefore = nil // one explicit admission, consumed before yield
    }
    lastDurabilityRepairOriginalFailure = original
    let completion = Task<PagedNativeCommitAcknowledgement?, Never> { [self, route] in
      do {
        let acknowledgement: PagedNativeCommitAcknowledgement
        if let verificationID { acknowledgement = try await route.retryVerifiedCommit(batch, verificationID: verificationID) }
        else { acknowledgement = try await route.repairCommitDurability(batch) }
        try working.acknowledge(acknowledgement)
        pendingCommitInstallation = acknowledgement
        try installCanonicalHistory(.native(acknowledgement))
        try await route.finishCommitInstallation(acknowledgement)
        pendingCommitInstallation = nil
        if !persistenceFailureSerialExhausted, persistenceFailureSerial == serial { persistenceFailure = nil }
        failedCommitDurabilityBatchID = nil; failedCommitDurabilityFailureSerial = nil; verifiedCommitBefore = nil
        commitTask = nil
        emitNativeSeal(acknowledgement.sealedWindow); requestCommit()
        return acknowledgement
      } catch {
        commitTask = nil
        if let before = error as? PagedNativeCommitKnownUnpublished,
          before.batchID == batch.batchID, !persistenceFailureSerialExhausted, serial == persistenceFailureSerial {
          verifiedCommitBefore = (batch.batchID, before.verificationID, serial)
          return nil
        }
        if let pendingCommitInstallation, pendingCommitInstallation.batchID == batch.batchID {
          lastCommitInstallationFailure = error; commitInstallationFailureBatchID = batch.batchID
          if !persistenceFailureSerialExhausted, persistenceFailureSerial == serial { commitInstallationFailureSerial = fail(error) }
        } else if !persistenceFailureSerialExhausted, persistenceFailureSerial == serial {
          failedCommitDurabilityFailureSerial = fail(error)
        }
        return nil
      }
    }
    commitTask = completion
    guard let acknowledgement = await completion.value else {
      if let persistenceFailure { throw persistenceFailure }
      throw BoomError.unavailable("The actual ordinary durability/installation task did not join.")
    }
    return acknowledgement
  }

  /// Explicitly complete only the retained metadata custody join after Main
  /// already consumed a real ACK. The refined backend must admit the exact
  /// same receipt/current record; this never replays source writes or applies
  /// working.acknowledge a second time. Refusal preserves the ACK and error.
  func completePendingCommitInstallation() async throws -> PagedNativeCommitAcknowledgement {
    try requireSourceTransition()
    guard commitTask == nil, historyTask == nil,
      !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory,
      !inspectingHistory, persistenceFailure != nil,
      !persistenceFailureSerialExhausted,
      let acknowledgement = pendingCommitInstallation,
      commitInstallationFailureBatchID == acknowledgement.batchID,
      let route = storage as? any PagedNativeCommitInstallationStorage else {
      throw BoomError.stale("No joined failed native ACK installation can complete its retained custody.")
    }
    // A preparation can have refused while joining this very prefix. Its raw
    // intent must remain retained until the exact ACK custody joins; releasing
    // it merely to enter this completion API would discard that intent.
    if let intent = historyIntent {
      guard intent.prepared == nil, intent.admission == nil, historyFailure != nil,
        intent.prefix.sessionID == acknowledgement.sessionID,
        intent.prefix.arenaID == working.arenaID,
        intent.prefix.generation == acknowledgement.lastSequence,
        working.sealedRootRecord == acknowledgement.sealedRootRecord else {
        throw BoomError.stale("Another native history intent owns this ACK custody completion.")
      }
    }
    let completingFailureSerial = commitInstallationFailureSerial
    let completion = Task<PagedNativeCommitAcknowledgement?, Never> { [self, route] in
      do {
        try installCanonicalHistory(.native(acknowledgement))
        try await route.finishCommitInstallation(acknowledgement)
        pendingCommitInstallation = nil
        if let completingFailureSerial, !persistenceFailureSerialExhausted,
          persistenceFailureSerial == completingFailureSerial {
          persistenceFailure = nil
        }
        commitInstallationFailureBatchID = nil; commitInstallationFailureSerial = nil
        commitTask = nil
        emitNativeSeal(acknowledgement.sealedWindow)
        requestCommit()
        return Optional(acknowledgement)
      } catch {
        commitTask = nil
        lastCommitInstallationFailure = error
        // A refused explicit finish changes only its own primary failure. An
        // unrelated newer failure keeps both its error and serial ownership.
        if let completingFailureSerial, !persistenceFailureSerialExhausted,
          persistenceFailureSerial == completingFailureSerial {
          commitInstallationFailureSerial = fail(error)
        }
        return nil
      }
    }
    commitTask = completion
    guard let completed = await completion.value else {
      if let persistenceFailure { throw persistenceFailure }
      throw BoomError.unavailable("The retained native ACK installation did not join.")
    }
    return completed
  }

  /// Capture before yielding to any worker. One earlier in-flight batch, this
  /// exact prefix, and the bounded later queue retain separate ownership.
  func reservePrefix() throws -> PagedNativePrefixReservation {
    try requireSourceTransition()
    guard characterTransactionDepth == 0, historyIntent == nil,
      persistenceFailure == nil else { throw BoomError.stale("Native input cannot reserve another command prefix.") }
    let result = try working.reservePrefixReportingClosure()
    let reservation = result.reservation
    navigationID = nil
    emitGroupClosure(result.closedGroup)
    requestCommit()
    return reservation
  }

  func flush(_ reservation: PagedNativePrefixReservation) async throws -> PagedNativeSealedPrefix {
    try requireSourceTransition()
    guard working.reservedPrefix == reservation else { throw BoomError.stale("Another native owner holds this prefix.") }
    if let persistenceFailure { throw persistenceFailure }
    while working.sealedGeneration < reservation.generation {
      if let persistenceFailure { throw persistenceFailure }
      requestCommit()
      guard let pending = commitTask, let acknowledgement = await pending.value else {
        if let persistenceFailure { throw persistenceFailure }
        throw BoomError.unavailable("The reserved native prefix did not join.")
      }
      guard acknowledgement.lastSequence <= reservation.generation else {
        throw BoomError.invalid("Later input was included in the reserved native prefix.")
      }
    }
    // Main may already have consumed the source ACK while the refined root
    // custody completion is awaiting its real join. An exact prefix includes
    // that owner completion; sealedGeneration alone is not a task join.
    if let pendingCommitInstallation, pendingCommitInstallation.lastSequence == reservation.generation {
      guard let pending = commitTask else {
        throw BoomError.unavailable("The reserved native ACK custody completion still needs its explicit join.")
      }
      guard let acknowledgement = await pending.value else {
        if let persistenceFailure { throw persistenceFailure }
        throw BoomError.unavailable("The reserved native ACK custody installation did not join.")
      }
      guard acknowledgement.batchID == pendingCommitInstallation.batchID else {
        throw BoomError.stale("Another native ACK custody installation joined this prefix.")
      }
    }
    return try working.sealedPrefix(reservation)
  }

  func releasePrefix(_ reservation: PagedNativePrefixReservation) throws {
    try requireSourceTransition()
    guard historyIntent == nil, pendingCommitInstallation == nil else {
      throw BoomError.stale("A retained native history intent or unjoined ACK custody still owns this prefix.")
    }
    try working.releasePrefix(reservation)
    requestCommit()
  }

  /// The native command owner must fence later input intents before reserving
  /// its prefix. Already accepted old-arena input is retained as a conflict;
  /// it is never replayed on a different retained root or silently abandoned.
  func prepareHistoryMove(_ handle: PagedNativeHistoryHandle,
    prefix: PagedNativePrefixReservation,
    canonicalSelection: PagedNativeSealedHistorySelection? = nil) async throws -> PagedNativePreparedHistoryMove {
    try requireSourceTransition()
    guard historyIntent == nil, let route = storage as? any PagedNativeHistorySessionStorage,
      working.reservedPrefix == prefix, characterTransactionDepth == 0 else {
      throw BoomError.stale("Native history has another owner, transaction or retained intent.")
    }
    if canonicalHistory != nil, canonicalSelection == nil {
      throw BoomError.stale("Canonical command must select its exact slot after the reserved prefix joined.")
    }
    let commandID = UUID()
    preparingIntent = true
    defer { preparingIntent = false }
    lastHistoryAcknowledgement = nil
    historyIntent = HistoryIntent(commandID: commandID, handle: handle, prefix: prefix)
    do {
      let captured = try await flush(prefix)
      guard commitTask == nil else { throw BoomError.stale("The exact native prefix has not finished its owner callback.") }
      preparingHistory = true
      defer { preparingHistory = false }
      let command = PagedNativeHistoryMoveCommand(sessionID: sessionID, commandID: commandID,
        sourceArenaID: prefix.arenaID, sourceWindowID: captured.window.windowID,
        expectedSequence: prefix.generation, expectedRootRecord: captured.rootRecord, handle: handle,
        canonicalSelection: canonicalSelection)
      let prepared = try await route.prepareHistoryMove(command)
      historyIntent?.prepared = prepared
      if working.generation != prefix.generation || working.arenaID != prefix.arenaID || working.isPinned {
        let observation = PagedNativeHistoryInputObservation(sessionID: sessionID, arenaID: arenaID,
          generation: generation, compositionPinned: isPinned)
        historyIntent?.conflict = try await route.noteHistoryInputConflict(prepared, observation: observation)
      }
      return prepared
    } catch {
      historyFailure = error
      throw error
    }
  }

  /// The separate immutable-arena view is built from this ticket before the
  /// command owner enters Foundation. No manager operation belongs here.
  func stageHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove)
    throws -> PagedNativeHistoryInstallationTicket {
    try requireSourceTransition()
    guard let intent = historyIntent, intent.prepared == prepared,
      intent.commandID == prepared.command.commandID, intent.conflict == nil,
      intent.admission == nil, !preparingIntent, !preparingHistory, !notifyingHistoryConflict,
      !resolvingHistory, !inspectingHistory, historyTask == nil, commitTask == nil,
      nativeSealNotificationDepth == 0, navigationOperations.isEmpty,
      historyFailure == nil, persistenceFailure == nil, characterTransactionDepth == 0,
      !working.isPinned, let route = storage as? any PagedNativeHistorySessionStorage else {
      throw BoomError.stale("Native history is not ready to stage its exact source installation.")
    }
    let command = prepared.command
    let admission = PagedNativeHistoryAdmission(commandID: command.commandID,
      preparationID: prepared.preparationID, sessionID: sessionID, sourceArenaID: arenaID,
      provisionalArenaID: UUID(), sourceWindowID: command.sourceWindowID,
      preparedWindowID: prepared.window.windowID, expectedSequence: command.expectedSequence,
      admittedSequence: try command.nextSequence(), expectedRootRecord: command.expectedRootRecord)
    let candidate = try working.stagingProvisionalHistory(prepared, admission: admission)
    let ticket = PagedNativeHistoryInstallationTicket(owner: self, prepared: prepared,
      admission: admission, candidate: candidate, route: route)
    navigationID = nil
    stagedInstallation = ticket
    return ticket
  }

  /// A constructor verifies exact ticket ownership before allocating its new
  /// text view. Rechecking authority after Foundation pops would be too late.
  func windowForStagedNativeInstallation(_ ticket: PagedNativeHistoryInstallationTicket)
    throws -> PagedTextWindow {
    try requireStagedTicket(ticket)
    return ticket.window
  }

  private func requireStagedTicket(_ ticket: PagedNativeHistoryInstallationTicket) throws {
    guard stagedInstallation === ticket, ticket.owner === self, ticket.state == .staged,
      ticket.prepared != nil, ticket.candidate != nil, ticket.route != nil,
      !adoptingHistory, !installingHistory, !notifyingNativeGroup else {
      throw BoomError.stale("Another owner, expired ticket or adoption scope owns this native source.")
    }
  }

  /// Cancellation before manager advancement releases only the staged native
  /// projection. The prepared command, exact prefix and backend custody stay
  /// retained for fresh staging or an explicit joined intent disposition.
  func cancelStagedHistoryInstallation(_ ticket: PagedNativeHistoryInstallationTicket) throws {
    try requireStagedTicket(ticket)
    ticket.state = .cancelled; ticket.releaseBacking()
    stagedInstallation = nil
  }

  /// Enter before UndoManager.undo/redo, including will/did notifications. The
  /// synchronous handler must consume exactly once and register its inverse
  /// within this scope. Worker launch is deferred until Foundation returns.
  @discardableResult
  func withStagedHistoryInstallation(_ ticket: PagedNativeHistoryInstallationTicket,
    adopting: (PagedNativeHistorySourceConsumer) -> Void) throws -> PagedNativeHistoryAdmission {
    try requireStagedTicket(ticket)
    adoptingHistory = true
    let consumer = PagedNativeHistorySourceConsumer(owner: self, ticket: ticket)
    adopting(consumer)
    precondition(consumer.publication != nil && ticket.state == .consumed,
      "The synchronous native command owner must consume its source exactly once.")
    let publication = consumer.publication!
    consumer.active = false; consumer.publication = nil
    adoptingHistory = false; stagedInstallation = nil
    launchHistoryPublication(publication.prepared, admission: publication.admission,
      route: publication.route)
    return publication.admission
  }

  /// This is the exclusive source move, not another admission path. All its
  /// state and scalar work were prepared before the owner advanced Foundation.
  fileprivate func consumeStagedHistory(_ consumer: PagedNativeHistorySourceConsumer,
    installing: (PagedTextWindow, UUID, Int) -> Void) -> PagedNativeHistoryAdmission {
    let ticket = consumer.ticket
    precondition(adoptingHistory && !installingHistory && !notifyingNativeGroup,
      "A native source consumer is valid only in its exclusive adoption scope.")
    precondition(consumer.active && consumer.owner === self && consumer.publication == nil
      && stagedInstallation === ticket && ticket.owner === self && ticket.state == .staged,
      "A native source consumer may move only its exact unconsumed ticket.")
    // Optional unwraps are the opaque ticket's lifetime invariant, not repeated
    // source authority, root-record, text or sequence admission after the pop.
    let prepared = ticket.prepared!, candidate = ticket.candidate!, route = ticket.route!
    let admission = ticket.admission
    ticket.state = .consumed
    consumer.publication = .init(prepared: prepared, admission: admission, route: route)
    ticket.releaseBacking()
    working = candidate
    historyIntent!.admission = admission
    installingHistory = true
    installing(prepared.window, admission.provisionalArenaID, prepared.localCaretUTF16)
    installingHistory = false
    return admission
  }

  /// Prototype callers share the same source primitive, but do not thereby
  /// own the ordinary UndoManager/input timeline. Its activation is separate.
  @discardableResult
  func installPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    installing: (PagedTextWindow, UUID, Int) -> Void) throws -> PagedNativeHistoryAdmission {
    let ticket = try stageHistoryInstallation(prepared)
    return try withStagedHistoryInstallation(ticket) { consumer in
      consumer.consume(installing: installing)
    }
  }

  /// An input callback that already entered the old arena remains there. Its
  /// exact observation and the Undo intent stay retained for owner resolution.
  func retainHistoryInputConflict() async throws -> PagedNativeHistoryInputConflictReceipt {
    try requireSourceTransition()
    guard !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory,
      let intent = historyIntent, let prepared = intent.prepared,
      intent.admission == nil, let route = storage as? any PagedNativeHistorySessionStorage else {
      throw BoomError.stale("No unadmitted native history preparation owns this conflict.")
    }
    let observation = PagedNativeHistoryInputObservation(sessionID: sessionID, arenaID: arenaID,
      generation: generation, compositionPinned: isPinned)
    notifyingHistoryConflict = true
    defer { notifyingHistoryConflict = false }
    let receipt = try await route.noteHistoryInputConflict(prepared, observation: observation)
    guard historyIntent?.commandID == intent.commandID,
      historyIntent?.prepared?.preparationID == prepared.preparationID,
      historyIntent?.admission == nil else { throw BoomError.stale("Another native intent owns this conflict result.") }
    historyIntent?.conflict = receipt
    return receipt
  }

  /// A refused worker preparation did not publish or return a candidate. Its
  /// raw intent still needs an explicit disposition, after the captured input
  /// has actually joined. A failed/uncertain source batch cannot be released.
  func resolveUnpreparedHistory(_ disposition: PagedNativeHistoryIntentDisposition)
    throws -> PagedNativeUnpreparedHistoryDispositionReceipt {
    try requireSourceTransition()
    guard !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory,
      historyTask == nil, commitTask == nil, pendingCommitInstallation == nil,
      persistenceFailure == nil, let intent = historyIntent, intent.prepared == nil,
      intent.admission == nil, historyFailure != nil else {
      throw BoomError.stale("No joined refused native preparation can transfer its raw intent.")
    }
    if case .transferredToRetainedOwner(let receiptID) = disposition,
      receiptID == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) {
      throw BoomError.invalid("Native raw-intent transfer has no receiving-owner receipt.")
    }
    let prefix = try working.sealedPrefix(intent.prefix)
    let receipt = PagedNativeUnpreparedHistoryDispositionReceipt(commandID: intent.commandID,
      handle: intent.handle, prefix: prefix, disposition: disposition)
    try working.releasePrefix(intent.prefix)
    historyIntent = nil; historyFailure = nil
    requestCommit()
    return receipt
  }

  /// The command owner supplies an explicit disposition. A transfer requires
  /// its receiving ledger to retain this intent and both root records before
  /// calling; typing, detach or cancellation never invokes abandonment.
  func resolveUnadmittedHistory(_ disposition: PagedNativeHistoryIntentDisposition)
    async throws -> PagedNativeHistoryIntentDispositionReceipt {
    try requireSourceTransition()
    guard !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory,
      historyTask == nil, let intent = historyIntent,
      let prepared = intent.prepared, intent.admission == nil,
      let route = storage as? any PagedNativeHistorySessionStorage else {
      throw BoomError.stale("No joined unadmitted native intent can transfer custody.")
    }
    resolvingHistory = true
    defer { resolvingHistory = false }
    let receipt = try await route.resolveUnadmittedHistory(prepared, disposition: disposition)
    try working.releasePrefix(intent.prefix)
    historyIntent = nil; historyFailure = nil
    requestCommit()
    return receipt
  }

  /// The accepted publication owns the session until its worker and native
  /// seal both join. An observer cannot cancel it or discard later characters.
  private func startHistoryPublication(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, verificationID: UUID? = nil) {
    guard historyTask == nil, let route = storage as? any PagedNativeHistorySessionStorage else {
      fail(BoomError.invalid("The admitted native history command lost its publication owner.")); return
    }
    launchHistoryPublication(prepared, admission: admission, route: route, verificationID: verificationID)
  }

  private func launchHistoryPublication(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission, route: any PagedNativeHistorySessionStorage,
    verificationID: UUID? = nil) {
    precondition(historyTask == nil && !adoptingHistory && !installingHistory,
      "The admitted native history publication has one joined launch owner.")
    let startingFailureSerial = persistenceFailureSerial
    historyTask = Task { [self, route] in
      do {
        let acknowledgement: PagedNativeHistoryAcknowledgement
        if let verificationID {
          acknowledgement = try await route.completeVerifiedHistory(prepared, verificationID: verificationID)
        } else {
          acknowledgement = try await route.commitPreparedHistory(prepared, admission: admission)
        }
        try await consumeHistoryAcknowledgement(acknowledgement, prepared: prepared, admission: admission,
          route: route, clearingFailureSerial: startingFailureSerial)
        historyTask = nil
        requestCommit()
        return acknowledgement
      } catch {
        historyTask = nil; historyFailure = error
        if !persistenceFailureSerialExhausted, persistenceFailureSerial == startingFailureSerial {
          failedHistoryDurabilityFailureSerial = fail(error)
        } else {
          // A real input/canonical/SDK failure already changed this call chain.
          // Keep it and the separate history error; propagation is not a new
          // failure and cannot mint a ticket that clears the earlier owner.
          failedHistoryDurabilityFailureSerial = nil
        }
        return nil
      }
    }
  }

  private func consumeHistoryAcknowledgement(_ acknowledgement: PagedNativeHistoryAcknowledgement,
    prepared: PagedNativePreparedHistoryMove, admission: PagedNativeHistoryAdmission,
    route: any PagedNativeHistorySessionStorage, clearingFailureSerial: UInt64) async throws {
    if historyIntent?.acknowledgement == nil {
      try working.acknowledgeHistory(acknowledgement)
      historyIntent?.acknowledgement = acknowledgement
    } else {
      guard historyIntent?.acknowledgement?.preparationID == acknowledgement.preparationID,
        working.sealedRootRecord == acknowledgement.sealedRootRecord,
        working.sealedGeneration == acknowledgement.admittedSequence else {
        throw BoomError.stale("History recovery has another installed native source base.")
      }
    }
    try installCanonicalHistory(.history(acknowledgement))
    try await route.finishHistoryInstallation(prepared, admission: admission)
    lastHistoryAcknowledgement = acknowledgement
    historyIntent = nil; historyFailure = nil; failedHistoryDurabilityFailureSerial = nil
    if !persistenceFailureSerialExhausted, persistenceFailureSerial == clearingFailureSerial {
      persistenceFailure = nil
    }
    emitNativeSeal(acknowledgement.sealedWindow)
  }

  func joinHistoryPublication(commandID: UUID) async throws -> PagedNativeHistoryAcknowledgement {
    if let lastHistoryAcknowledgement, lastHistoryAcknowledgement.commandID == commandID {
      return lastHistoryAcknowledgement
    }
    guard historyIntent?.commandID == commandID, let task = historyTask,
      let acknowledgement = await task.value else {
      if let historyFailure { throw historyFailure }
      throw BoomError.unavailable("No accepted native history publication is pending.")
    }
    guard acknowledgement.commandID == commandID else { throw BoomError.stale("Another native command joined.") }
    return acknowledgement
  }

  /// Inspection classifies a retained publication; this method never retries.
  func inspectHistoryRecovery() async throws -> PagedNativeHistoryRecovery {
    try requireSourceTransition()
    guard historyTask == nil, !inspectingHistory, let intent = historyIntent, let prepared = intent.prepared,
      intent.admission != nil, let route = storage as? any PagedNativeHistorySessionStorage else {
      throw BoomError.stale("No joined admitted native history intent needs inspection.")
    }
    inspectingHistory = true
    defer { inspectingHistory = false }
    return try await route.inspectHistoryRecovery(prepared)
  }

  /// Explicit disk repair on the retained command's real storage owner. It
  /// returns a durable classification; existing acceptRecoveredHistory / exact
  /// verified completion still performs the actual native installation.
  func repairHistoryDurability() async throws -> PagedNativeHistoryRecovery {
    try requireSourceTransition()
    guard historyTask == nil, !inspectingHistory, let intent = historyIntent,
      let prepared = intent.prepared, intent.admission != nil, historyFailure != nil,
      !persistenceFailureSerialExhausted, failedHistoryDurabilityFailureSerial == persistenceFailureSerial,
      let route = storage as? any PagedNativeFileDurabilityStorage else {
      throw BoomError.stale("No joined admitted file history intent owns durability repair.")
    }
    lastDurabilityRepairOriginalFailure = historyFailure
    inspectingHistory = true; defer { inspectingHistory = false }
    return try await route.repairHistoryDurability(prepared)
  }

  /// Explicit owner completion consumes an authenticated single-use permit.
  func completeVerifiedHistory(_ verificationID: UUID) throws {
    try requireSourceTransition()
    guard historyTask == nil, !inspectingHistory, let intent = historyIntent, let prepared = intent.prepared,
      let admission = intent.admission, !persistenceFailureSerialExhausted,
      (historyFailure == nil && persistenceFailure == nil)
        || (historyFailure != nil && failedHistoryDurabilityFailureSerial != nil
          && failedHistoryDurabilityFailureSerial == persistenceFailureSerial) else {
      throw BoomError.stale("No exact current failed history intent can be completed while another failure owns source custody.")
    }
    startHistoryPublication(prepared, admission: admission, verificationID: verificationID)
  }

  /// Consume an inspected durable result without publishing the command a
  /// second time. The same validation/installation join retains later input.
  func acceptRecoveredHistory(_ acknowledgement: PagedNativeHistoryAcknowledgement) throws {
    try requireSourceTransition()
    guard historyTask == nil, !inspectingHistory, let intent = historyIntent, let prepared = intent.prepared,
      let admission = intent.admission, acknowledgement.commandID == intent.commandID,
      !persistenceFailureSerialExhausted,
      (historyFailure == nil && persistenceFailure == nil)
        || (historyFailure != nil && failedHistoryDurabilityFailureSerial != nil
          && failedHistoryDurabilityFailureSerial == persistenceFailureSerial),
      acknowledgement.preparationID == prepared.preparationID,
      let route = storage as? any PagedNativeHistorySessionStorage else {
      throw BoomError.stale("Recovered native history belongs to another retained command.")
    }
    let startingFailureSerial = persistenceFailureSerial
    historyTask = Task { [self, route] in
      do {
        try await consumeHistoryAcknowledgement(acknowledgement, prepared: prepared, admission: admission,
          route: route, clearingFailureSerial: startingFailureSerial)
        historyTask = nil; requestCommit()
        return acknowledgement
      } catch {
        historyTask = nil; historyFailure = error
        if !persistenceFailureSerialExhausted, persistenceFailureSerial == startingFailureSerial {
          failedHistoryDurabilityFailureSerial = fail(error)
        } else { failedHistoryDurabilityFailureSerial = nil }
        return nil
      }
    }
  }

  /// Captures through a known native generation; later typing may proceed and
  /// remains explicitly unsealed. A caller cannot relabel that later text with
  /// the earlier captured root. No sleep, semaphore or disk call runs on Main.
  func flush(through generation: UInt64) async throws -> PagedTextRevision {
    try requireSourceTransition()
    guard generation <= working.generation, !working.isPinned, characterTransactionDepth == 0 else {
      throw BoomError.stale("Composition pins this native capture.")
    }
    guard historyIntent == nil, working.reservedPrefix == nil else {
      throw BoomError.stale("Use the exact reserved-prefix or accepted-history owner to capture this source.")
    }
    while true {
      if let persistenceFailure { throw persistenceFailure }
      if working.sealedGeneration == generation {
        if let pendingCommitInstallation, pendingCommitInstallation.lastSequence == generation,
          let pending = commitTask {
          guard let acknowledgement = await pending.value else {
            if let persistenceFailure { throw persistenceFailure }
            throw BoomError.unavailable("The captured native ACK custody installation did not join.")
          }
          guard acknowledgement.batchID == pendingCommitInstallation.batchID else {
            throw BoomError.stale("Another native ACK custody installation joined this capture.")
          }
          return acknowledgement.sealedWindow.revision
        }
        return working.sealedWindow.revision
      }
      guard working.sealedGeneration < generation else {
        throw BoomError.stale("The captured native generation has already been superseded.")
      }
      requestCommit()
      guard let pending = commitTask else {
        throw BoomError.unavailable("The native edit queue cannot complete its captured generation.")
      }
      guard let acknowledgement = await pending.value else {
        if let persistenceFailure { throw persistenceFailure }
        throw BoomError.unavailable("The native edit queue did not seal its captured generation.")
      }
      // Return this task's immutable result, even if later native input or a
      // later seal arrived before this waiter resumed. Compaction may seal a
      // range of generations; it cannot invent a root for its interior.
      if acknowledgement.lastSequence == generation { return acknowledgement.sealedWindow.revision }
      guard acknowledgement.lastSequence < generation else {
        throw BoomError.stale("The captured native generation was coalesced into a later seal.")
      }
    }
  }

  /// Prototype-only projection. A managed owner must stage and mount its
  /// newly bound view; it cannot rotate the old physical input client in place.
  func navigate(toUTF16 anchor: UInt64) async throws -> PagedTextWindow {
    guard managedArenaOwner == nil else {
      throw BoomError.denied("Managed navigation requires its actual input/Undo installation owner.")
    }
    working = try await navigationCandidate(toUTF16: anchor)
    return working.sealedWindow
  }

  /// Reuse only the ACTUAL joined projection of this exact requested window.
  /// A shortened nonterminal island is not proof that a fresh target window
  /// would have the same extent. Cached Data/scalar metadata avoids text scans.
  func joinedNavigationWindow(owner: PagedNativeInputOwner, toUTF16 anchor: UInt64,
    selection: PagedNativeNavigationSelection) throws -> (window: PagedTextWindow, localSelection: NSRange)? {
    try requireSourceTransition()
    guard managedArenaOwner === owner, owner.session === self else {
      throw BoomError.denied("Joined navigation requires this actual physical owner.")
    }
    guard !working.hasUnsealedChanges, working.inFlight == nil, !working.isPinned,
      !working.hasProvisionalHistory, working.reservedPrefix == nil, historyIntent == nil,
      commitTask == nil, historyTask == nil, pendingCommitInstallation == nil,
      !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory,
      !inspectingHistory, !inspectingCommitRecovery, nativeSealNotificationDepth == 0, navigationOperations.isEmpty,
      characterTransactionDepth == 0, persistenceFailure == nil, historyFailure == nil,
      working.bytes.count <= PagedWorkingWindow.targetBytes else { return nil }
    let window = working.sealedWindow
    guard window.utf16Start == anchor, window.revision == working.sealedRootRecord.document.revision else { return nil }
    let byteEnd = window.byteStart.addingReportingOverflow(UInt64(working.bytes.count))
    let utf16End = window.utf16Start.addingReportingOverflow(UInt64(working.localUTF16Count))
    guard !byteEnd.overflow, !utf16End.overflow,
      byteEnd.partialValue <= window.revision.summary.bytes,
      utf16End.partialValue <= window.revision.summary.utf16 else { return nil }
    let reachesEOF = byteEnd.partialValue == window.revision.summary.bytes
      && utf16End.partialValue == window.revision.summary.utf16
    guard reachesEOF || working.bytes.count == PagedWorkingWindow.targetBytes else { return nil }
    guard let metadata = canonicalHistory, metadata.record == working.sealedRootRecord,
      metadata.scope.sessionID == sessionID,
      metadata.scope.coveredSequence == working.sealedGeneration else { return nil }
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    guard !end.overflow, selection.utf16Offset >= window.utf16Start,
      end.partialValue <= utf16End.partialValue,
      let location = Int(exactly: selection.utf16Offset - window.utf16Start),
      let length = Int(exactly: selection.utf16Length) else { return nil }
    let local = NSRange(location: location, length: length)
    _ = try working.selection(local) // actual scalar table, before a native selection setter
    return (window, local)
  }

  /// Real flush/window calls join with old working and physical view intact.
  /// Only the joined, unchanged source receives the one staged reservation.
  func prepareNavigationInstallation(owner: PagedNativeInputOwner, toUTF16 anchor: UInt64,
    selection: PagedNativeNavigationSelection,
    roundGeneratedAnchor: Bool = false) async throws -> PagedNativeNavigationInstallationTicket {
    guard managedArenaOwner === owner, owner.session === self else {
      throw BoomError.denied("Navigation has another actual physical owner.")
    }
    let candidate = try await navigationCandidate(toUTF16: anchor, roundGeneratedAnchor: roundGeneratedAnchor)
    guard managedArenaOwner === owner, navigationOperations.isEmpty,
      nativeSealNotificationDepth == 0, !preparingIntent, !preparingHistory,
      !notifyingHistoryConflict, !resolvingHistory, !inspectingHistory, !inspectingCommitRecovery else {
      throw BoomError.stale("Physical navigation ownership or an actual notification/producer changed while loading.")
    }
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    let extent = candidate.sealedWindow.utf16Start.addingReportingOverflow(UInt64(candidate.localUTF16Count))
    guard !end.overflow, !extent.overflow,
      end.partialValue <= candidate.sealedWindow.revision.summary.utf16,
      selection.focusUTF16 >= candidate.sealedWindow.utf16Start,
      selection.focusUTF16 <= extent.partialValue else {
      throw BoomError.stale("Requested selection focus is outside its actual bounded navigation window.")
    }
    let start = max(selection.utf16Offset, candidate.sealedWindow.utf16Start)
    let finish = min(end.partialValue, extent.partialValue)
    let location = Int(start - candidate.sealedWindow.utf16Start), length = Int(max(start, finish) - start)
    let local = NSRange(location: location, length: length)
    _ = try candidate.selection(local) // scalar boundaries, before any physical/source adoption
    let ticket = PagedNativeNavigationInstallationTicket(owner: self, inputOwner: owner,
      candidate: candidate, sourceArenaID: working.arenaID, sourceWindowID: working.sealedWindow.windowID,
      localSelection: local, selectionAffinity: selection.affinity.native, documentSelection: selection)
    stagedNavigation = ticket
    return ticket
  }

  func windowForStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket) throws -> PagedTextWindow {
    try requireStagedNavigation(ticket); return ticket.window
  }

  /// Explicit edits use the same session, physical input queue and immutable
  /// history as typing. Only a joined source prefix can enter the file writer.
  func beginCapturedEdit(expected: PagedDocumentRootRecord, commandID: UUID)
    throws -> any PagedNativeCapturedEditingStorage {
    _ = try windowForNativeInstallation()
    guard working.sealedRootRecord == expected, capturedEditCommandID == nil,
      let route = storage as? any PagedNativeCapturedEditingStorage else {
      throw BoomError.stale("The explicit edit no longer names this joined source.")
    }
    capturedEditCommandID = commandID; capturedEditExpectedRecord = expected
    return route
  }

  func preparePublishedEditInstallation(_ result: PagedCapturedEditResult,
    owner: PagedNativeInputOwner) throws -> PagedNativeNavigationInstallationTicket {
    let next = working.generation.addingReportingOverflow(1)
    guard managedArenaOwner === owner, owner.session === self,
      capturedEditCommandID == result.commandID,
      capturedEditExpectedRecord == result.beforeRecord,
      working.sealedRootRecord == result.beforeRecord,
      working.generation == working.sealedGeneration,
      result.sessionID == sessionID, !next.overflow, result.sequence == next.partialValue,
      stagedNavigation == nil, stagedInstallation == nil, !working.isPinned,
      characterTransactionDepth == 0, commitTask == nil, historyTask == nil,
      pendingCommitInstallation == nil, historyIntent == nil, working.reservedPrefix == nil,
      let currentHistory = canonicalHistory,
      persistenceFailure == nil, historyFailure == nil else {
      throw BoomError.stale("Published edit lost its exact sealed native source.")
    }
    try result.canonicalHistory.admit(record: result.record, sessionID: sessionID,
      engineIncarnation: currentHistory.producer.engineIncarnation,
      scope: .capturedEdit(sessionID: sessionID, commandID: result.commandID, sequence: result.sequence))
    let candidate = try PagedWorkingWindow(window: result.window, rootRecord: result.record,
      sessionID: sessionID, generation: result.sequence)
    let selection = PagedNativeNavigationSelection(utf16Offset: result.cursor.utf16Offset,
      utf16Length: result.cursor.selectionLengthUTF16, focusAtEnd: result.cursor.focusAtEnd,
      affinity: result.cursor.affinity)
    guard result.localCaretUTF16 >= 0, result.localCaretUTF16 <= candidate.localUTF16Count,
      selection.utf16Offset <= result.record.document.revision.summary.utf16,
      selection.utf16Length <= result.record.document.revision.summary.utf16 - selection.utf16Offset else {
      throw BoomError.invalid("Published edit selection exceeds its actual source.")
    }
    let windowStart = candidate.sealedWindow.utf16Start
    let windowEnd = windowStart + UInt64(candidate.localUTF16Count)
    let start = min(windowEnd, max(windowStart, selection.utf16Offset))
    let finish = min(windowEnd, max(start, selection.utf16Offset + selection.utf16Length))
    let local = NSRange(location: Int(start - windowStart), length: Int(finish - start))
    _ = try candidate.selection(local)
    let ticket = PagedNativeNavigationInstallationTicket(owner: self, inputOwner: owner,
      candidate: candidate, sourceArenaID: arenaID, sourceWindowID: working.sealedWindow.windowID,
      localSelection: local, selectionAffinity: selection.affinity.native, sourceGeneration: generation,
      sourceRecord: working.sealedRootRecord, capturedEdit: result, documentSelection: selection)
    capturedEditResult = result; stagedNavigation = ticket
    return ticket
  }

  func finishCapturedEditInstallation(_ result: PagedCapturedEditResult) async throws {
    guard capturedEditCommandID == result.commandID,
      capturedEditResult?.record == result.record,
      working.sealedRootRecord == result.record, generation == result.sequence,
      canonicalHistory?.record == result.record,
      let route = storage as? any PagedNativeCapturedEditingStorage else {
      throw BoomError.stale("The explicit edit has another receiving source.")
    }
    try await route.finishCapturedEditInstallation(result)
    capturedEditCommandID = nil; capturedEditExpectedRecord = nil; capturedEditResult = nil
    emitNativeSeal(result.window)
  }

  func recordCapturedEditFailure(_ error: Error) { fail(error) }

  func completeUnchangedCapturedEdit(_ result: PagedCapturedEditUnchanged) throws {
    guard capturedEditCommandID == result.commandID,
      capturedEditExpectedRecord == result.record, working.sealedRootRecord == result.record,
      capturedEditResult == nil, stagedNavigation == nil else {
      throw BoomError.stale("Neutral editing has another source or an entered publication.")
    }
    capturedEditCommandID = nil; capturedEditExpectedRecord = nil
  }

  func sealedParagraphBounds(atUTF16 offset: UInt64,
    includeLineEndings: Bool = false) async throws -> PagedTextParagraphBounds {
    try Task.checkCancellation(); try requireSourceTransition()
    guard working.generation == working.sealedGeneration, !working.isPinned,
      let route = storage as? any PagedNativeDocumentNavigationStorage else {
      throw BoomError.stale("Paragraph movement requires its joined source.")
    }
    let record = working.sealedRootRecord, arena = arenaID, sequence = generation
    let result = try await route.paragraphBounds(expected: record.document.revision,
      utf16Offset: offset, includeLineEndings: includeLineEndings)
    try Task.checkCancellation(); try requireSourceTransition()
    guard working.sealedRootRecord == record, arenaID == arena, generation == sequence,
      working.generation == working.sealedGeneration, !working.isPinned else {
      throw BoomError.stale("Paragraph movement changed its source while seeking.")
    }
    try result.validate(in: record.document.revision, originUTF16: offset)
    return result
  }

  func sealedGraphemeBoundary(atUTF16 offset: UInt64, forward: Bool) async throws -> UInt64 {
    try requireSourceTransition()
    guard working.generation == working.sealedGeneration, !working.isPinned,
      let route = storage as? any PagedNativeDocumentNavigationStorage else {
      throw BoomError.stale("Grapheme movement requires its joined source.")
    }
    let record = working.sealedRootRecord, arena = arenaID, sequence = generation
    let result = try await route.graphemeBoundary(expected: record.document.revision,
      utf16Offset: offset, forward: forward)
    guard working.sealedRootRecord == record, arenaID == arena, generation == sequence else {
      throw BoomError.stale("Grapheme movement changed its source while seeking.")
    }
    return result.utf16
  }

  /// Cocoa can jump over several logical positions in a bidi run. Preserve
  /// that observed target, rounding only a fragment of a full-source cluster.
  func sealedGraphemeBoundary(atNativeUTF16 target: UInt64, forward: Bool) async throws -> UInt64 {
    try Task.checkCancellation(); try requireSourceTransition()
    guard working.generation == working.sealedGeneration, !working.isPinned,
      let route = storage as? any PagedNativeDocumentNavigationStorage else {
      throw BoomError.stale("Visual movement requires its joined source.")
    }
    let record = working.sealedRootRecord, arena = arenaID, sequence = generation
    let extent = record.document.revision.summary.utf16
    guard target <= extent else { throw BoomError.stale("Native visual target exceeds its full source.") }
    if target == 0 || target == extent { return target }
    // Start just inside the cluster on the observed approach side. Position
    // rounds a possible surrogate midpoint; the source seek resolves the
    // entire cluster rather than trusting the native window's truncated edge.
    let point = try await route.documentPosition(expected: record.document.revision,
      utf16Offset: forward ? target - 1 : target + 1, forward: !forward)
    try Task.checkCancellation(); try requireSourceTransition()
    guard working.sealedRootRecord == record, arenaID == arena, generation == sequence,
      working.generation == working.sealedGeneration, !working.isPinned else {
      throw BoomError.stale("Visual movement changed source while positioning its target.")
    }
    let result = try await route.graphemeBoundary(expected: record.document.revision,
      utf16Offset: point.utf16, forward: forward)
    try Task.checkCancellation(); try requireSourceTransition()
    guard working.sealedRootRecord == record, arenaID == arena, generation == sequence,
      working.generation == working.sealedGeneration, !working.isPinned,
      result.utf16 <= extent, (forward ? result.utf16 >= target : result.utf16 <= target) else {
      throw BoomError.stale("Visual movement returned another source or grapheme target.")
    }
    return result.utf16
  }

  func sealedCursor(for selection: PagedNativeNavigationSelection) async throws -> PagedSealedCursor {
    try requireSourceTransition()
    guard working.generation == working.sealedGeneration, !working.isPinned,
      selection.utf16Offset <= working.sealedRootRecord.document.revision.summary.utf16,
      selection.utf16Length <= working.sealedRootRecord.document.revision.summary.utf16 - selection.utf16Offset,
      let route = storage as? any PagedNativeDocumentNavigationStorage else {
      throw BoomError.stale("Selection has another sealed source.")
    }
    let record = working.sealedRootRecord, arena = arenaID, sequence = generation
    let point = try await route.documentPosition(expected: record.document.revision,
      utf16Offset: selection.utf16Offset, forward: false)
    guard working.sealedRootRecord == record, arenaID == arena, generation == sequence,
      point.utf16 == selection.utf16Offset else {
      throw BoomError.stale("Selection changed while its exact byte coordinate loaded.")
    }
    return PagedSealedCursor(byteOffset: point.bytes, utf16Offset: point.utf16,
      selectionLengthUTF16: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
  }

  /// Small endpoint reads for formatting; this never adopts a new native
  /// window or converts the selected document to a resident String.
  func sealedTextWindow(atUTF16 offset: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    try requireSourceTransition()
    guard working.generation == working.sealedGeneration, !working.isPinned,
      offset <= working.sealedRootRecord.document.revision.summary.utf16,
      maximumBytes >= 4, maximumBytes <= 64 else {
      throw BoomError.stale("Delimiter reading requires its joined bounded source.")
    }
    let record = working.sealedRootRecord, arena = arenaID, sequence = generation
    let window = try await storage.window(expected: record.document.revision,
      utf16Anchor: offset, maximumBytes: maximumBytes)
    guard working.sealedRootRecord == record, arenaID == arena, generation == sequence,
      window.revision == record.document.revision, window.utf16Start == offset else {
      throw BoomError.stale("Delimiter reading returned another document source.")
    }
    return window
  }
  private func requireStagedNavigation(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    guard stagedNavigation === ticket, ticket.owner === self, ticket.state == .staged,
      let owner = ticket.inputOwner, managedArenaOwner === owner, owner.session === self,
      ticket.candidate != nil, !adoptingNavigation,
      ticket.sessionID == sessionID, ticket.sourceArenaID == arenaID,
      ticket.sourceGeneration == generation, working.sealedGeneration == generation,
      ticket.sourceWindowID == working.sealedWindow.windowID, ticket.sourceRecord == working.sealedRootRecord,
      !working.isPinned, characterTransactionDepth == 0, commitTask == nil, historyTask == nil,
      nativeSealNotificationDepth == 0, navigationOperations.isEmpty,
      !preparingIntent, !preparingHistory, !notifyingHistoryConflict, !resolvingHistory, !inspectingHistory, !inspectingCommitRecovery,
      pendingCommitInstallation == nil, historyIntent == nil, working.reservedPrefix == nil,
      persistenceFailure == nil, historyFailure == nil else {
      throw BoomError.stale("Navigation ticket has another, changed or unjoined source owner.")
    }
  }
  func cancelStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    // Discard only this already-joined candidate. Source failures/characters
    // remain owned independently; cleanup does not require adoption authority.
    guard stagedNavigation === ticket, ticket.owner === self, ticket.state == .staged,
      let owner = ticket.inputOwner, managedArenaOwner === owner, owner.session === self,
      ticket.candidate != nil, !adoptingNavigation else {
      throw BoomError.stale("Another ticket/physical owner or consumed adoption owns this navigation candidate.")
    }
    ticket.state = .cancelled; ticket.releaseBacking(); stagedNavigation = nil
  }

  /// Exclusive synchronous adoption of an already prepared source/projection.
  /// No await, publication, history registration or fallible source admission
  /// follows the move. Canonical metadata and the actual subscription survive.
  func withStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket,
    installing: (PagedTextWindow, UUID, NSRange) -> Void) throws -> PagedTextWindow {
    try requireStagedNavigation(ticket)
    let candidate = ticket.candidate!, window = candidate.sealedWindow
    adoptingNavigation = true
    ticket.state = .consumed; ticket.releaseBacking()
    working = candidate
    installing(window, ticket.provisionalArenaID, ticket.localSelection)
    stagedNavigation = nil; adoptingNavigation = false
    if let result = ticket.capturedEdit { try installCanonicalHistory(.capturedEdit(result)) }
    return window
  }

  private func navigationCandidate(toUTF16 anchor: UInt64,
    roundGeneratedAnchor: Bool = false) async throws -> PagedWorkingWindow {
    try requireSourceTransition()
    try Task.checkCancellation()
    guard !working.isPinned, historyIntent == nil, working.reservedPrefix == nil,
      characterTransactionDepth == 0, nativeSealNotificationDepth == 0 else {
      throw BoomError.stale("Composition, a native command or an actual seal notification pins navigation.")
    }
    guard navigationOperations.count < Self.maximumNavigationOperations else {
      throw BoomError.budget("The native navigation producer bound is full; existing requests remain owned until joined.")
    }
    let navigation = UUID()
    guard navigationOperations.insert(navigation).inserted else {
      throw BoomError.invalid("A native navigation operation reused its live identity.")
    }
    navigationID = navigation
    defer {
      precondition(navigationOperations.remove(navigation) != nil,
        "Only an entered navigation producer may finish its own lifetime.")
      if navigationID == navigation { navigationID = nil }
    }
    let session = working.sessionID, generation = working.generation, arena = working.arenaID
    let revision = try await flush(through: generation)
    try Task.checkCancellation()
    guard !sourceTransitionIsFenced, navigationID == navigation, working.sessionID == session, working.arenaID == arena,
      working.generation == generation, !working.isPinned, working.reservedPrefix == nil,
      historyIntent == nil, characterTransactionDepth == 0, pendingCommitInstallation == nil else {
      throw BoomError.stale("Native characters changed while navigation joined.")
    }
    let record = working.sealedRootRecord
    let actualAnchor: UInt64
    if roundGeneratedAnchor {
      guard let route = storage as? any PagedNativeDocumentNavigationStorage else {
        throw BoomError.denied("This prototype route has no real global position owner.")
      }
      let position = try await route.documentPosition(expected: revision, utf16Offset: anchor, forward: false)
      try Task.checkCancellation()
      guard !sourceTransitionIsFenced, navigationID == navigation, working.sessionID == session,
        working.arenaID == arena, working.generation == generation, working.sealedRootRecord == record,
        !working.isPinned, working.reservedPrefix == nil, historyIntent == nil,
        characterTransactionDepth == 0, pendingCommitInstallation == nil else {
        throw BoomError.stale("Native source changed while its bounded global position joined.")
      }
      actualAnchor = position.utf16
    } else { actualAnchor = anchor }
    let window = try await storage.window(expected: revision, utf16Anchor: actualAnchor,
      maximumBytes: PagedWorkingWindow.targetBytes)
    try Task.checkCancellation()
    guard !sourceTransitionIsFenced, navigationID == navigation, working.sessionID == session, working.arenaID == arena,
      working.generation == generation, working.sealedRootRecord == record,
      working.sealedWindow.revision == revision, !working.isPinned, working.reservedPrefix == nil,
      historyIntent == nil, characterTransactionDepth == 0, pendingCommitInstallation == nil,
      commitTask == nil, historyTask == nil, persistenceFailure == nil, historyFailure == nil else {
      throw BoomError.stale("Native characters changed while navigation loaded.")
    }
    try window.validate()
    guard window.revision == revision else { throw BoomError.stale("Navigation loaded another source revision.") }
    return try PagedWorkingWindow(window: window, rootRecord: record, sessionID: session, generation: generation)
  }
  @discardableResult
  private func fail(_ error: Error) -> UInt64? {
    // Preserve the exact failed batch, or already-consumed ACK awaiting its
    // refined custody join, plus later local characters. An async observer
    // never clears this overlay or blindly republishes the captured record.
    persistenceFailure = error
    let next = persistenceFailureSerial.addingReportingOverflow(1)
    if next.overflow { persistenceFailureSerialExhausted = true }
    else { persistenceFailureSerial = next.partialValue }
    let recordedSerial = persistenceFailureSerialExhausted ? nil : persistenceFailureSerial
    didFail?(error)
    return recordedSerial
  }
}

struct PagedNativeHistoryHandle: Sendable, Equatable {
  enum Direction: Sendable, Equatable { case undo, redo }
  let documentID: UUID
  let groupID: UUID
  let direction: Direction
  var inverse: PagedNativeHistoryHandle {
    PagedNativeHistoryHandle(documentID: documentID, groupID: groupID,
      direction: direction == .undo ? .redo : .undo)
  }
}

/// The command/UI owner; the storage session serializes execution with native
/// edit groups and proves that a registered group is the current history step.
/// Handles are not arbitrary retained Revision values or model edit grants.
@MainActor final class PagedNativeUndoRegistration {
  let manager: UndoManager
  private let enqueue: (PagedNativeHistoryHandle) -> Void
  init(manager: UndoManager, enqueue: @escaping (PagedNativeHistoryHandle) -> Void) {
    self.manager = manager; self.enqueue = enqueue
    manager.levelsOfUndo = 100
  }
  func register(_ handle: PagedNativeHistoryHandle, actionName: String) {
    manager.registerUndo(withTarget: self) { owner in
      // This synchronous inverse registration happens while UndoManager is
      // actually undoing/redoing. Deferring it until an async ack is wrong.
      owner.register(handle.inverse, actionName: actionName)
      owner.enqueue(handle)
    }
    manager.setActionName(actionName)
  }
}
