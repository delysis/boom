import AppKit
import BoomCore
import Foundation

/// The responder chain requests an operation. Only the command owner invokes
/// Foundation after the real source preparation and native projection stage.
@MainActor private final class PagedNativeGatedUndoManager: UndoManager {
  var requestHistory: ((PagedNativeHistoryHandle.Direction) -> Void)?
  private var advancing = false
  override func undo() { requestHistory?(.undo) }
  override func redo() { requestHistory?(.redo) }
  override func undoNestedGroup() { requestHistory?(.undo) }
  func advance(_ direction: PagedNativeHistoryHandle.Direction) {
    precondition(!advancing && groupingLevel == 0)
    advancing = true
    defer { advancing = false }
    // Foundation undo() dynamically invokes undoNestedGroup(). Enter the
    // superclass group operation directly so notification reentry into any
    // public Undo method still queues a request through the owner.
    switch direction { case .undo: super.undoNestedGroup(); case .redo: super.redo() }
  }
}

/// One actual Foundation entry, carried by its own action user-info. This is
/// not a second independently advanced history stack or a string snapshot.
@MainActor private final class PagedNativeUndoEntry: NSObject {
  let ownerID: UUID
  let entryID = UUID()
  let ordinal: UInt64
  let handle: PagedNativeHistoryHandle
  let actionName: String
  let nativeReceipt: PagedNativeGroupClosureReceipt?
  var canonical: PagedRootHistoryEntry?
  var canonicalRecord: PagedDocumentRootRecord?
  var canonicalIndex: Int?
  var openingInverse: PagedNativeUndoEntry?
  init(ownerID: UUID, ordinal: UInt64, handle: PagedNativeHistoryHandle, actionName: String,
    nativeReceipt: PagedNativeGroupClosureReceipt?, canonical: PagedRootHistoryEntry?,
    canonicalRecord: PagedDocumentRootRecord?, canonicalIndex: Int?) {
    self.ownerID = ownerID; self.ordinal = ordinal; self.handle = handle; self.actionName = actionName
    self.nativeReceipt = nativeReceipt; self.canonical = canonical
    self.canonicalRecord = canonicalRecord; self.canonicalIndex = canonicalIndex
  }
}

enum PagedNativeReceivingChoice: Sendable, Equatable {
  case cancelUnpreparedHistoryKeepingInput
  case completeJoinedHistoryReceiving
}

/// One exact Main-owned receiving observation. It grants no source/root pin,
/// callback drain, source retry or authority to pop a different SDK target.
@MainActor final class PagedNativeReceivingDispositionTicket {
  let id = UUID()
  let choice: PagedNativeReceivingChoice
  fileprivate weak var owner: PagedNativeUndoOwner?
  fileprivate let ownerID: UUID
  fileprivate let checkpoint: PagedNativeReceivingCheckpoint
  fileprivate let lease: PagedNativeReplayInputLease
  fileprivate let prefix: PagedNativePrefixReservation
  fileprivate let direction: PagedNativeHistoryHandle.Direction
  fileprivate var target: AnyObject?
  fileprivate let failureSerial: UInt64
  fileprivate let queueCount: Int
  fileprivate let queuedDirections: Int
  fileprivate let queuedRawKeys: Int
  fileprivate let rawKeyBytes: Int
  fileprivate var consumed = false
  fileprivate init(owner: PagedNativeUndoOwner, choice: PagedNativeReceivingChoice,
    checkpoint: PagedNativeReceivingCheckpoint, lease: PagedNativeReplayInputLease,
    prefix: PagedNativePrefixReservation, direction: PagedNativeHistoryHandle.Direction,
    target: AnyObject?, failureSerial: UInt64, queueCount: Int, queuedDirections: Int,
    queuedRawKeys: Int, rawKeyBytes: Int) {
    self.owner = owner; ownerID = owner.input.ownerID; self.choice = choice
    self.checkpoint = checkpoint; self.lease = lease; self.prefix = prefix
    self.direction = direction; self.target = target; self.failureSerial = failureSerial
    self.queueCount = queueCount; self.queuedDirections = queuedDirections
    self.queuedRawKeys = queuedRawKeys; self.rawKeyBytes = rawKeyBytes
  }
}

/// Receiving metadata changed, with original input still owned. This is not
/// a seal, replay, worker/root release or physical-close receipt.
struct PagedNativeReceivingDispositionReceipt: Sendable {
  let ticketID: UUID
  let ownerID: UUID
  let choice: PagedNativeReceivingChoice
  let checkpoint: PagedNativeReceivingCheckpoint
  let prefix: PagedNativePrefixReservation
  let disposedUnpreparedCommandID: UUID?
  let queuedRawKeyCount: Int
  let receivingOwnerRemainsBlocked: Bool
}

@MainActor final class PagedNativeUndoOwner {
  private enum Phase: Equatable { case idle, hydrating, reconciling, preparing, advancing, publishing, blocked, closed }
  private struct RawKey {
    let event: NSEvent
    let originalLease: PagedNativeReplayInputLease
    var replayLease: PagedNativeReplayInputLease
    let window: NSWindow
    let chargedBytes: Int
  }
  private enum QueuedInput {
    case history(PagedNativeHistoryHandle.Direction)
    case rawKey(RawKey)
  }
  static let maximumQueuedEntries = 64
  static let maximumQueuedCommands = 64
  static let maximumQueuedRawKeys = 64
  static let maximumRawKeyBytes = 262_144
  static let maximumKeyUTF16 = 256
  private static let entryKey = UndoManager.UserInfoKey(rawValue: "bloom.paged.native-entry.v1")

  let input: PagedNativeInputOwner
  private let gatedManager = PagedNativeGatedUndoManager()
  private var phase = Phase.idle
  private var nextOrdinal: UInt64 = 0
  // Actual SDK targets only: no revision is chosen from these mirrors.
  private var undoEntries: [PagedNativeUndoEntry] = []
  private var redoEntries: [PagedNativeUndoEntry] = []
  private var canonicalHistory: PagedNativeCanonicalHistoryProjection?
  private var hydrationExpected: PagedNativeUndoEntry?
  private var resolvedExpectedEntry: PagedNativeUndoEntry?
  private var resolvedOriginalEntryID: UUID?
  private var queue: [QueuedInput] = []
  private var queuedDirections = 0
  private(set) var queuedRawKeyCount = 0
  private var rawKeyBytes = 0
  private var replayingRawKeys = false
  private var replayInsertionCount = 0
  private var registeringGroup = false
  private var expectedEntry: PagedNativeUndoEntry?
  private var inverseEntry: PagedNativeUndoEntry?
  private var adoptingSource: (() -> Void)?
  private var commandTask: Task<Void, Never>?
  private var navigationTask: Task<PagedTextWindow, Error>?
  private(set) var isNavigating = false
  private var groupSubscription: PagedNativeGroupSubscription?
  private(set) var retainedPrefix: PagedNativePrefixReservation?
  private(set) var retainedPreparation: PagedNativePreparedHistoryMove?
  private(set) var retainedStage: PagedNativeHistoryInstallationTicket?
  private(set) var firstFailure: Error?
  private struct InstalledHistoryStamp {
    let history: PagedNativeReceivingHistoryIdentity
    let latestRecord: PagedDocumentRootRecord
    let latestSequence: UInt64
  }
  private var lastInstalledHistoryStamp: InstalledHistoryStamp?
  private var receivingTransition = false
  private var receivingTicket: PagedNativeReceivingDispositionTicket?
  private var receivingFailureSerial: UInt64 = 0
  private var receivingFailureSerialExhausted = false
  /// Preserve the first independent receiving failure beside the original.
  /// Later observations still advance the serial; no unbounded error journal.
  private(set) var independentReceivingFailure: Error?
  private(set) var lastReceivingDisposition: PagedNativeReceivingDispositionReceipt?
  private(set) var unretainedRawKeyCount: UInt64 = 0
  private(set) var unretainedCommandCount: UInt64 = 0
  private(set) var unregisteredGroup: PagedNativeGroupClosureReceipt?
  var didFail: ((Error) -> Void)?
  var mountView: ((PagedNativeTextView, PagedNativeTextView) throws -> Void)?

  var manager: UndoManager { gatedManager }
  var hasPendingCommand: Bool {
    (phase != .idle && phase != .closed) || commandTask != nil || !queue.isEmpty
      || receivingTransition || receivingTicket != nil || isNavigating || navigationTask != nil
  }

  init(input: PagedNativeInputOwner) throws {
    guard input.commandOwner == nil else {
      throw BoomError.denied("This native session already has its command and group owner.")
    }
    self.input = input
    queue.reserveCapacity(Self.maximumQueuedEntries)
    gatedManager.groupsByEvent = false
    gatedManager.levelsOfUndo = PagedRootHistory.maximumEntries
    undoEntries.reserveCapacity(PagedRootHistory.maximumEntries)
    redoEntries.reserveCapacity(PagedRootHistory.maximumEntries)
    let needsCanonical = input.session.canonicalOpening != nil
    let seal: ((PagedNativeGroupSubscription, PagedNativeCanonicalSeal) throws -> Void)? = needsCanonical
      ? { [weak self] subscription, receipt in
          guard let self else { throw BoomError.stale("Canonical source lost its actual Foundation receiver.") }
          try self.reconcileCanonicalSeal(receipt, subscription: subscription)
        } : nil
    groupSubscription = try input.session.registerNativeGroupSubscription(ownerID: input.ownerID,
      onCanonicalSeal: seal,
      onCanonicalInstalled: { [weak self] subscription in
        guard let self, subscription === self.groupSubscription else { return }
        self.inputCommandDidClose()
      }, onClose: { [weak self] subscription, receipt in
        self?.registerClosedGroup(receipt, subscription: subscription)
      })
    gatedManager.requestHistory = { [weak self] direction in self?.request(direction) }
    input.commandOwner = self
    if let opening = input.session.canonicalOpening {
      try hydrateCanonicalOpening(opening)
    }
  }

  /// A non-durable native receipt names the real effective group. Preparation
  /// later asks the authenticated backend whether that group is retained.
  private func registerClosedGroup(_ receipt: PagedNativeGroupClosureReceipt,
    subscription: PagedNativeGroupSubscription) {
    guard phase != .closed else { return }
    guard receipt.hasEffectiveSourceChange else { return }
    registeringGroup = true
    defer { registeringGroup = false }
    do {
      // Delivery is already inside the session's notification scope. Compare
      // its exact owned token here; the quiescent detach preflight cannot run.
      guard subscription === groupSubscription, subscription.ownerID == input.ownerID,
        receipt.sessionID == input.session.sessionID,
        receipt.arenaID == input.activeIdentity?.arenaID,
        receipt.lastSequence == input.session.generation,
        phase != .advancing, phase != .blocked, gatedManager.groupingLevel == 0 else {
        throw BoomError.stale("A native group closure has another source or command owner.")
      }
      let entry = try makeEntry(PagedNativeHistoryHandle(documentID: input.session.sourceBaseRevision.documentID,
        groupID: receipt.effectiveGroupID, direction: .undo), actionName: "Edit", nativeReceipt: receipt)
      gatedManager.beginUndoGrouping()
      register(entry)
      gatedManager.endUndoGrouping()
    } catch {
      if unregisteredGroup == nil { unregisteredGroup = receipt }
      fail(error)
    }
  }

  private func makeEntry(_ handle: PagedNativeHistoryHandle, actionName: String,
    nativeReceipt: PagedNativeGroupClosureReceipt? = nil, canonical: PagedRootHistoryEntry? = nil,
    record: PagedDocumentRootRecord? = nil, index: Int? = nil) throws -> PagedNativeUndoEntry {
    let next = nextOrdinal.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Native history entry identity is exhausted.") }
    nextOrdinal = next.partialValue
    return PagedNativeUndoEntry(ownerID: input.ownerID, ordinal: nextOrdinal,
      handle: handle, actionName: actionName, nativeReceipt: nativeReceipt,
      canonical: canonical, canonicalRecord: record, canonicalIndex: index)
  }

  private func register(_ entry: PagedNativeUndoEntry) {
    if gatedManager.isUndoing { redoEntries.append(entry) }
    else {
      undoEntries.append(entry)
      if !gatedManager.isRedoing { redoEntries.removeAll(keepingCapacity: true) }
      if undoEntries.count > PagedRootHistory.maximumEntries {
        undoEntries.removeFirst(undoEntries.count - PagedRootHistory.maximumEntries)
      }
    }
    gatedManager.registerUndo(withTarget: entry) { [weak self] target in self?.consumeFoundationEntry(target) }
    gatedManager.setActionName(entry.actionName)
    gatedManager.setActionUserInfoValue(entry, forKey: Self.entryKey)
  }

  private func top(_ direction: PagedNativeHistoryHandle.Direction) throws -> PagedNativeUndoEntry? {
    let available = direction == .undo ? gatedManager.undoCount > 0 : gatedManager.redoCount > 0
    guard available else { return nil }
    let value = direction == .undo
      ? gatedManager.undoActionUserInfoValue(forKey: Self.entryKey)
      : gatedManager.redoActionUserInfoValue(forKey: Self.entryKey)
    guard let entry = value as? PagedNativeUndoEntry, entry.ownerID == input.ownerID,
      entry.handle.documentID == input.session.sourceBaseRevision.documentID,
      entry.handle.direction == direction else {
      throw BoomError.stale("The Foundation history entry lacks its native source owner.")
    }
    return entry
  }

  private func foundationProjectionIsExact() -> Bool {
    guard gatedManager.groupingLevel == 0,
      Int(exactly: gatedManager.undoCount) == undoEntries.count,
      Int(exactly: gatedManager.redoCount) == redoEntries.count else { return false }
    if let last = undoEntries.last {
      guard (gatedManager.undoActionUserInfoValue(forKey: Self.entryKey) as? PagedNativeUndoEntry) === last else { return false }
    }
    if let last = redoEntries.last {
      guard (gatedManager.redoActionUserInfoValue(forKey: Self.entryKey) as? PagedNativeUndoEntry) === last else { return false }
    }
    return true
  }

  private func hydrateCanonicalOpening(_ opening: PagedNativeCanonicalOpening) throws {
    guard input.canonicalActivationPending, let subscription = groupSubscription,
      opening.history.undo.count + opening.history.redo.count <= PagedRootHistory.maximumEntries,
      undoEntries.isEmpty, redoEntries.isEmpty, phase == .idle else {
      throw BoomError.stale("Canonical Foundation hydration requires the unexposed staged physical client.")
    }
    // All identities/targets are allocated before SDK operations start.
    // <=100 actual slots plus <=100 temporary synthetic inverse targets.
    var registration: [PagedNativeUndoEntry] = []
    var metadataPops: [PagedNativeUndoEntry] = []
    registration.reserveCapacity(PagedRootHistory.maximumEntries)
    metadataPops.reserveCapacity(PagedRootHistory.maximumEntries)
    for (index, canonical) in opening.history.undo.enumerated() {
      registration.append(try makeEntry(PagedNativeHistoryHandle(documentID: opening.record.document.id,
        groupID: canonical.groupID, direction: .undo), actionName: "Edit", canonical: canonical,
        record: opening.record, index: index))
    }
    for index in opening.history.redo.indices.reversed() {
      let canonical = opening.history.redo[index]
      let synthetic = try makeEntry(PagedNativeHistoryHandle(documentID: opening.record.document.id,
        groupID: canonical.groupID, direction: .undo), actionName: "Edit")
      synthetic.openingInverse = try makeEntry(synthetic.handle.inverse, actionName: "Edit",
        canonical: canonical, record: opening.record, index: index)
      registration.append(synthetic)
      metadataPops.append(synthetic)
    }
    try input.session.withCanonicalOpening(subscription, ownerID: input.ownerID) { [self] in
      phase = .hydrating
      for entry in registration {
        gatedManager.beginUndoGrouping(); register(entry); gatedManager.endUndoGrouping()
      }
      // Register every ordinary Undo first. No normal registration may follow
      // these real SDK inverse operations: it would clear the restored Redo.
      for entry in metadataPops.reversed() {
        hydrationExpected = entry
        gatedManager.advance(.undo)
        hydrationExpected = nil
      }
      precondition(foundationProjectionIsExact(), "Exclusive Foundation opening lost its actual SDK targets.")
      canonicalHistory = opening.history
      input.completeCanonicalOpening(commandOwner: self)
    }
    phase = .idle
    // Public requests from real notifications remain queued. The graph is
    // still unexposed; its actual mounted/focused command will pump them.
  }

  private func node(_ entry: PagedNativeUndoEntry) -> PagedNativeFoundationNode {
    PagedNativeFoundationNode(id: entry.entryID, nativeOwnerID: entry.ownerID,
      direction: entry.handle.direction, canonical: entry.canonical,
      canonicalRecord: entry.canonicalRecord, canonicalIndex: entry.canonicalIndex,
      nativeReceipt: entry.nativeReceipt)
  }

  private func receivingStamp(after receipt: PagedNativeCanonicalSeal,
    incoming: PagedNativeCanonicalHistoryProjection) throws -> InstalledHistoryStamp? {
    switch receipt {
    case .history(let acknowledgement):
      guard let prepared = retainedPreparation else {
        throw BoomError.stale("Receiving history metadata lacks its actual retained command.")
      }
      let identity = try PagedNativeReceivingHistoryIdentity(prepared: prepared, acknowledgement: acknowledgement)
      return InstalledHistoryStamp(history: identity, latestRecord: incoming.record,
        latestSequence: incoming.scope.coveredSequence)
    case .native:
      guard let prior = lastInstalledHistoryStamp else { return nil }
      let next = prior.latestSequence.addingReportingOverflow(1)
      guard !next.overflow, incoming.beforeRecord == prior.latestRecord,
        incoming.producer.engineIncarnation == prior.history.engineIncarnation,
        case .nativeBatch(_, _, let first, _) = incoming.scope, first == next.partialValue else {
        throw BoomError.stale("A receiving history finish lost its exact later native source chain.")
      }
      return InstalledHistoryStamp(history: prior.history, latestRecord: incoming.record,
        latestSequence: incoming.scope.coveredSequence)
    }
  }

  private func reconcileCanonicalSeal(_ receipt: PagedNativeCanonicalSeal,
    subscription: PagedNativeGroupSubscription) throws {
    // This synchronous work follows an awaited commit. Do not assign a later
    // input event to that acknowledgement or include storage waiting as CPU work.
    let trace = PerformanceTrace.begin("Editor.ManagedHistoryReconcile")
    defer { PerformanceTrace.end("Editor.ManagedHistoryReconcile", trace) }
    guard subscription === groupSubscription, subscription.ownerID == input.ownerID,
      subscription.sessionID == input.session.sessionID,
      let incoming = receipt.projection, let previous = canonicalHistory,
      phase != .closed, phase != .advancing, phase != .hydrating else {
      throw BoomError.stale("Canonical metadata lacks its actual owned Foundation subscription.")
    }
    // A lost metadata completion response does not replay SDK removals or
    // source publication. Later accepted native targets remain actual targets.
    if incoming.hasSamePublishedMetadata(as: previous) {
      guard foundationProjectionIsExact() else { throw BoomError.stale("Previously joined Foundation metadata no longer matches its actual SDK manager.") }
      return
    }
    let priorPhase = phase
    phase = .reconciling
    defer { if phase == .reconciling { phase = priorPhase } }
    do {
      guard foundationProjectionIsExact() else { throw BoomError.stale("Foundation target custody differs before canonical metadata reconciliation.") }
      let nextReceivingStamp = try receivingStamp(after: receipt, incoming: incoming)
      let plan = try PagedNativeFoundationReconciliationPlan(previous: previous, incoming: incoming,
        actualUndo: undoEntries.map(node), actualRedo: redoEntries.map(node), nativeOwnerID: input.ownerID)
      let oldEntries = undoEntries + redoEntries
      let byID = Dictionary(uniqueKeysWithValues: oldEntries.map { ($0.entryID, $0) })
      func actual(_ desired: PagedNativeFoundationReconciliationPlan.Desired) throws -> PagedNativeUndoEntry {
        if let id = desired.existingID, let entry = byID[id] { return entry }
        guard let canonical = desired.canonical, let index = desired.canonicalIndex,
          let record = desired.canonicalRecord else { throw BoomError.invalid("New Foundation metadata target lacks its full canonical slot.") }
        return try makeEntry(PagedNativeHistoryHandle(documentID: record.document.id,
          groupID: canonical.groupID, direction: desired.direction), actionName: "Edit",
          canonical: canonical, record: record, index: index)
      }
      // Preallocate before removeAllActions or per-target disposal can reenter.
      let nextUndo = try plan.undo.map(actual), nextRedo = try plan.redo.map(actual)
      if let selected = expectedEntry, selected.handle.direction == .undo,
        let disposition = plan.dispositions.first(where: { $0.originalNodeID == selected.entryID }),
        let index = disposition.canonicalIndex,
        let position = plan.undo.firstIndex(where: { $0.nativeReceipt == nil && $0.canonicalIndex == index }) {
        resolvedExpectedEntry = nextUndo[position]; resolvedOriginalEntryID = selected.entryID
      }
      switch plan.mutation {
      case .pruneOnly:
        for id in plan.retiredIDs { gatedManager.removeAllActions(withTarget: byID[id]!) }
        undoEntries = nextUndo; redoEntries = nextRedo
      case .rebuildUndoOnly:
        precondition(nextRedo.isEmpty)
        gatedManager.removeAllActions()
        undoEntries.removeAll(keepingCapacity: true); redoEntries.removeAll(keepingCapacity: true)
        for entry in nextUndo {
          gatedManager.beginUndoGrouping(); register(entry); gatedManager.endUndoGrouping()
        }
      }
      for (entry, desired) in zip(nextUndo + nextRedo, plan.undo + plan.redo) {
        entry.canonical = desired.canonical; entry.canonicalRecord = desired.canonicalRecord
        entry.canonicalIndex = desired.canonicalIndex
      }
      canonicalHistory = incoming
      guard foundationProjectionIsExact() else { throw BoomError.stale("Canonical metadata did not join the actual Foundation target projection.") }
      lastInstalledHistoryStamp = nextReceivingStamp
    } catch { fail(error); throw error }
  }

  /// One bounded recenter on this SAME input/session/Foundation owner. Normal
  /// typing/IME keeps its old client while actual storage waits. A queued
  /// history request makes adoption stale and then pumps on that old source.
  func navigate(toUTF16 anchor: UInt64,
    selectingUTF16 requested: PagedNativeNavigationSelection? = nil) async throws -> PagedTextWindow {
    try requireCommandQuiescence()
    try requireNavigationClient()
    isNavigating = true
    defer { navigationTask = nil; isNavigating = false; pump() }
    let observed = try input.observeSelection()
    let selection = try requested ?? input.session.navigationSelection(observed.range)
    let task = Task<PagedTextWindow, Error> { [self] in
      try await navigateAdmitted(toUTF16: anchor, selection: selection, observed: observed,
        roundGeneratedAnchor: false, deferredInput: false)
    }
    navigationTask = task
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private func requireNavigationClient() throws {
    guard !isNavigating, navigationTask == nil, input.commandOwner === self,
      let view = input.activeView, view.inputCommandIsClosed, !view.hasMarkedText(),
      input.firstRefusal == nil, mountView != nil else {
      throw BoomError.stale("Navigation requires this quiescent physical input and its actual mount owner.")
    }
  }
  private func requireNavigationQueue(_ observed: PagedNativeSelectionObservation,
    deferredInput: Bool) throws {
    guard phase == .idle, !receivingTransition, receivingTicket == nil,
      firstFailure == nil, input.commandOwner === self else {
      throw BoomError.stale("A later actual history/input owner invalidated navigation before mounting.")
    }
    if !deferredInput {
      guard commandTask == nil, queue.isEmpty else { throw BoomError.stale("Later native input invalidated this navigation.") }
    } else {
      // These events were not interpreted or inserted in the old arena. They
      // remain in their original order on THIS actual bounded command owner.
      for item in queue {
        if case .rawKey(let key) = item {
          guard key.originalLease == observed.inputLease, key.replayLease == observed.inputLease else {
            throw BoomError.stale("A deferred navigation key belongs to another actual physical source.")
          }
        }
      }
    }
  }
  private func navigateAdmitted(toUTF16 anchor: UInt64, selection: PagedNativeNavigationSelection,
    observed: PagedNativeSelectionObservation, roundGeneratedAnchor: Bool,
    deferredInput: Bool, recordedFailure: (() -> Void)? = nil) async throws -> PagedTextWindow {
    guard observed.inputLease.isFirstResponder, observed.inputLease.isKeyWindow, let mount = mountView else {
      throw BoomError.stale("Navigation requires its actual focused physical client.")
    }
    if !roundGeneratedAnchor,
      let reused = try input.reuseJoinedNavigationWindow(toUTF16: anchor, selection: selection, observedSelection: observed) {
      try requireNavigationQueue(observed, deferredInput: deferredInput)
      return reused
    }
    let ticket = try await input.session.prepareNavigationInstallation(owner: input,
      toUTF16: anchor, selection: selection, affinity: observed.affinity,
      roundGeneratedAnchor: roundGeneratedAnchor)
    do {
      try Task.checkCancellation()
      guard isNavigating else { throw BoomError.stale("The exact navigation owner retired before mounting.") }
      try requireNavigationQueue(observed, deferredInput: deferredInput)
      try input.stageNavigation(ticket, observedSelection: observed)
      try Task.checkCancellation()
      let window = try input.withStagedNavigationInstallation(ticket, mounted: mount)
      guard input.lastReplayTransition != nil, let active = input.activeView,
        active.inputBinding?.identity.arenaID == input.session.arenaID,
        active.selectedRange() == ticket.localSelection, active.selectionAffinity == ticket.selectionAffinity,
        input.firstRefusal == nil, active.boundedStorage.mutationFailure == nil else {
        throw BoomError.stale("The adopted navigation did not retain its actual mount/focus/selection owner.")
      }
      if deferredInput { try transferRawInputAfterMount() }
      return window
    } catch {
      let original = error
      if ticket.isAwaitingAdoption {
        do { try input.cancelNavigationStage(ticket) }
        catch { throw PagedNativeNavigationOwnerFailure(original: original, cleanup: error) }
      } else if ticket.wasConsumed {
        fail(original); recordedFailure?() // concrete propagation, not Error equality
      }
      throw original
    }
  }

  /// A native boundary key is retained BEFORE any Task/first yield. Only the
  /// existing focus-preserving source mount can move its replay lease. This
  /// method returns true even on refusal, with the original key owned if its
  /// admission succeeded; a refused oversized key remains the existing open
  /// unretained-input boundary and never pretends to be retained.
  func recenterBeforeRawKey(_ event: NSEvent, from view: PagedNativeTextView,
    toUTF16 anchor: UInt64) -> Bool {
    guard !replayingRawKeys else { return false }
    var retained = false
    do {
      try requireCommandQuiescence(); try requireNavigationClient()
      let observed = try input.observeSelection()
      let selection = try input.session.navigationSelection(observed.range)
      try retainRawKey(event, from: view); retained = true
      beginOwnedNavigation(toUTF16: anchor, selection: selection, observed: observed)
    } catch {
      if retained { fail(error) }
      else { refuseDocumentKey(event, from: view, original: error) }
    }
    return true
  }
  /// An actual receiving refusal keeps the original event on this existing
  /// queue. It does not turn a failed presentation into navigation to zero.
  func refuseDocumentKey(_ event: NSEvent, from view: PagedNativeTextView, original: Error) {
    do { try retainRawKey(event, from: view); fail(original) }
    catch {
      if unretainedRawKeyCount < UInt64.max { unretainedRawKeyCount += 1 }
      fail(PagedNativeNavigationOwnerFailure(original: original, cleanup: error))
    }
  }

  /// Selection/caret movement is the same source operation as recentering;
  /// no second timeline or direct Root/NSRange retarget exists.
  func requestDocumentNavigation(toUTF16 anchor: UInt64,
    selectingUTF16 selection: PagedNativeNavigationSelection,
    expected: PagedNativeDocumentCoordinates) throws {
    try requireCommandQuiescence(); try requireNavigationClient()
    let current = try input.session.documentCoordinates()
    guard current.record == expected.record, current.sessionID == expected.sessionID,
      current.arenaID == expected.arenaID, current.generation == expected.generation,
      current.windowID == expected.windowID else {
      throw BoomError.stale("Document selection has another exact source arena or generation.")
    }
    let observed = try input.observeSelection()
    beginOwnedNavigation(toUTF16: anchor, selection: selection, observed: observed)
  }
  private func beginOwnedNavigation(toUTF16 anchor: UInt64, selection: PagedNativeNavigationSelection,
    observed: PagedNativeSelectionObservation) {
    precondition(!isNavigating && navigationTask == nil && commandTask == nil)
    isNavigating = true // synchronous input fence, before spawning the worker
    let startingFailureSerial = receivingFailureSerial
    var ownFailureRecorded = false
    let worker = Task<PagedTextWindow, Error> { [self] in
      try await navigateAdmitted(toUTF16: anchor, selection: selection, observed: observed,
        roundGeneratedAnchor: true, deferredInput: true,
        recordedFailure: { ownFailureRecorded = true })
    }
    navigationTask = worker
    // Reuse the existing owner task slot. Close/join waits for the ACTUAL
    // navigation result before this slot drops or the ordered queue resumes.
    commandTask = Task { [self] in
      do { _ = try await worker.value }
      catch {
        // Canonical reconciliation may already record this exact propagation
        // chain before rethrowing. A genuinely newer failure keeps its serial
        // and original payload; this observer never clears or relatches it.
        if !ownFailureRecorded, !receivingFailureSerialExhausted,
          receivingFailureSerial == startingFailureSerial { fail(error) }
      }
      navigationTask = nil; isNavigating = false; commandTask = nil
      pump()
    }
  }

  func request(_ direction: PagedNativeHistoryHandle.Direction) {
    guard phase != .closed else { return }
    guard queue.count < Self.maximumQueuedEntries, queuedDirections < Self.maximumQueuedCommands else {
      if unretainedCommandCount < UInt64.max { unretainedCommandCount += 1 }
      fail(BoomError.budget("Native history requests require owner resolution before accepting more input."))
      return
    }
    if replayingRawKeys {
      // The direction was interpreted from the head raw event. Keep it ahead
      // of later already-received keys, rather than appending it behind them.
      queue.insert(.history(direction), at: 1 + replayInsertionCount)
      replayInsertionCount += 1
    } else { queue.append(.history(direction)) }
    queuedDirections += 1
    pump()
  }

  /// Called after the complete AppKit command and its source transaction have
  /// closed. An Undo during marked input waits for actual unmark; it never
  /// fabricates unmark/discardMarkedText or opens a Foundation group over await.
  func inputCommandDidClose() { if phase != .closed { pump() } }

  private func pump() {
    guard phase == .idle, commandTask == nil, !isNavigating, navigationTask == nil, !queue.isEmpty, !replayingRawKeys,
      !registeringGroup, !receivingTransition,
      let activeView = input.activeView, activeView.inputCommandIsClosed, !activeView.hasMarkedText(),
      !input.session.hasPendingHistoryCommand, input.firstRefusal == nil else { return }
    let pumpFailureSerial = receivingFailureSerial
    do {
      if case .rawKey = queue[0] {
        try replayOriginalKeys()
        guard !queue.isEmpty else { return }
      }
      phase = .preparing // includes SDK checkpoint/top queries and group closure reentry
      _ = try input.session.closeNativeGroup()
      guard case .history(let direction) = queue[0] else {
        throw BoomError.invalid("Native input replay did not complete its head event.")
      }
      guard let entry = try top(direction) else { phase = .idle; queue.removeFirst(); queuedDirections -= 1; pump(); return }
      // Fence later raw/command requests before native preflight and prefix
      // reservation can emit synchronous framework notifications.
      phase = .preparing
      let selection = try input.observeSelection()
      guard selection.inputLease.isFirstResponder else {
        throw BoomError.stale("Native history preparation requires its actual focused input client.")
      }
      // Allocate/check the inverse before advancing the manager too.
      let inverse = try makeEntry(entry.handle.inverse, actionName: entry.actionName)
      expectedEntry = entry; inverseEntry = inverse
      let prefix = try input.session.reservePrefix()
      retainedPrefix = prefix
      lastInstalledHistoryStamp = nil
      let commandFailureSerial = receivingFailureSerial
      commandTask = Task { [self] in
        defer { commandTask = nil; if phase == .idle { pump() } }
        do {
          var selectedEntry = entry
          var selected: PagedNativeSealedHistorySelection?
          if canonicalHistory != nil {
            let sealed = try await input.session.flush(prefix)
            guard let current = canonicalHistory, current.record == sealed.rootRecord,
              current.scope.coveredSequence == prefix.generation,
              try input.inputLease(for: input.activeView) == selection.inputLease else {
              throw BoomError.stale("Canonical selection lost its joined prefix or original physical focus lease.")
            }
            let actual = try top(direction)
            if actual !== entry {
              guard resolvedOriginalEntryID == entry.entryID, actual === resolvedExpectedEntry else {
                throw BoomError.stale("The same Foundation intent did not survive exact prefix coalescence.")
              }
              selectedEntry = resolvedExpectedEntry!
            }
            selected = try current.selection(direction)
            guard selectedEntry.canonicalRecord == current.record,
              selectedEntry.canonicalIndex == selected?.index,
              selectedEntry.canonical == selected?.entry else {
              throw BoomError.stale("The actual Foundation top differs from its exact canonical record/direction/slot.")
            }
            expectedEntry = selectedEntry
          }
          let prepared = try await input.session.prepareHistoryMove(selectedEntry.handle, prefix: prefix,
            canonicalSelection: selected)
          retainedPreparation = prepared
          guard try top(direction) === selectedEntry,
            try input.inputLease(for: input.activeView) == selection.inputLease else {
            throw BoomError.stale("The Foundation target or original physical focus changed while source was prepared.")
          }
          if let candidate = prepared.canonicalHistory {
            let opposite: PagedNativeHistoryHandle.Direction = direction == .undo ? .redo : .undo
            let canonicalInverse = try candidate.selection(opposite)
            inverseEntry = try makeEntry(selectedEntry.handle.inverse, actionName: selectedEntry.actionName,
              canonical: canonicalInverse.entry, record: canonicalInverse.record, index: canonicalInverse.index)
          } else if canonicalHistory != nil { throw BoomError.invalid("Real canonical preparation omitted inverse metadata.") }
          let ticket = try input.stage(prepared, observedSelection: selection)
          retainedStage = ticket
          phase = .advancing
          let admission = try input.withStagedInstallation(ticket,
            advancingFoundation: { [self] adopt in
              withoutActuallyEscaping(adopt) { temporaryAdopt in
                adoptingSource = temporaryAdopt
                gatedManager.advance(direction)
                adoptingSource = nil
              }
            }, mounted: { [self] old, new in try mountView?(old, new) })
          retainedStage = nil
          queue.removeFirst(); queuedDirections -= 1
          expectedEntry = nil; inverseEntry = nil; resolvedExpectedEntry = nil; resolvedOriginalEntryID = nil
          phase = .publishing
          try transferRawInputAfterMount()
          // These are original un-interpreted events. Replay can now edit the
          // new provisional arena while its real publication ACK is pending.
          try replayOriginalKeys()
          _ = try await input.session.joinHistoryPublication(commandID: admission.commandID)
          // A later actual group/hook failure was already reported by its
          // owner. Preserve its receiving state without recording it twice.
          guard firstFailure == nil else { phase = .blocked; return }
          retainedPreparation = nil; retainedPrefix = nil; lastInstalledHistoryStamp = nil
          phase = .idle
        } catch {
          // An owned canonical hook or independent native callback may have
          // reported this call chain already. Source persistence/history
          // errors are retained by Session and independently bar disposition.
          // Never compare Errors or relatch propagation as a new failure.
          if !receivingFailureSerialExhausted, receivingFailureSerial == commandFailureSerial { fail(error) }
          else { phase = .blocked }
        }
      }
    } catch {
      if !receivingFailureSerialExhausted, receivingFailureSerial == pumpFailureSerial { fail(error) }
      else { phase = .blocked }
    }
  }

  private func consumeFoundationEntry(_ entry: PagedNativeUndoEntry) {
    if phase == .hydrating {
      precondition(hydrationExpected === entry && gatedManager.isUndoing && entry.openingInverse != nil)
      precondition(undoEntries.last === entry)
      _ = undoEntries.removeLast()
      register(entry.openingInverse!)
      return
    }
    precondition(phase == .advancing && expectedEntry === entry && adoptingSource != nil && inverseEntry != nil,
      "Only the exact prepared Foundation handler may consume its staged source.")
    precondition(entry.handle.direction == .undo ? gatedManager.isUndoing : gatedManager.isRedoing)
    if entry.handle.direction == .undo { precondition(undoEntries.last === entry); _ = undoEntries.removeLast() }
    else { precondition(redoEntries.last === entry); _ = redoEntries.removeLast() }
    adoptingSource!()
    register(inverseEntry!)
  }

  /// Return true only when this owner consumed or retained the raw event.
  /// No NSRange, insertText or interpreted command is redirected to a new view.
  func interceptRawKey(_ event: NSEvent, from view: PagedNativeTextView) -> Bool {
    guard phase != .closed else { return true }
    // IME input still needed to close the composition remains on its original
    // client. A waiting Undo cannot prevent the actual unmark it waits for.
    if phase == .idle, commandTask == nil, view.hasMarkedText() { return false }
    guard !replayingRawKeys,
      isNavigating || phase == .preparing || phase == .reconciling || phase == .hydrating
        || phase == .advancing || phase == .blocked || !queue.isEmpty else { return false }
    do { try retainRawKey(event, from: view) }
    catch {
      if unretainedRawKeyCount < UInt64.max { unretainedRawKeyCount += 1 }
      fail(error)
    }
    return true
  }
  private func retainRawKey(_ event: NSEvent, from view: PagedNativeTextView) throws {
      guard event.type == .keyDown, view === input.activeView,
        let window = view.window, window.firstResponder === view else {
        throw BoomError.stale("A deferred key belongs to another native focus owner.")
      }
      let characters = event.characters ?? "", ignored = event.charactersIgnoringModifiers ?? ""
      guard characters.utf16.count <= Self.maximumKeyUTF16, ignored.utf16.count <= Self.maximumKeyUTF16 else {
        throw BoomError.budget("An oversized native key requires its stream owner.")
      }
      let charge = characters.utf8.count + ignored.utf8.count + 512
      guard queue.count < Self.maximumQueuedEntries, queuedRawKeyCount < Self.maximumQueuedRawKeys,
        charge <= Self.maximumRawKeyBytes - rawKeyBytes else {
        throw BoomError.budget("Deferred native input exceeds its bounded custody queue.")
      }
      let lease = try input.inputLease(for: view)
      queue.append(.rawKey(RawKey(event: event, originalLease: lease, replayLease: lease,
        window: window, chargedBytes: charge)))
      queuedRawKeyCount += 1
      rawKeyBytes += charge
  }

  private func transferRawInputAfterMount() throws {
    guard phase != .closed else { return }
    guard queuedRawKeyCount > 0 else { return }
    guard let transition = input.lastReplayTransition else {
      throw BoomError.stale("Deferred native keys have no actual focus-preserving mount receipt.")
    }
    // The queue stays bounded. Only this owner's actual synchronous mount can
    // update replay custody; original event and original source identity stay.
    // Validate the complete bounded queue before changing any replay lease.
    for item in queue {
      if case .rawKey(let key) = item { _ = try transition.rebase(key.replayLease) }
    }
    for index in queue.indices {
      if case .rawKey(var key) = queue[index] {
        key.replayLease = try transition.rebase(key.replayLease)
        queue[index] = .rawKey(key)
      }
    }
  }

  private func replayOriginalKeys() throws {
    guard phase != .closed else { return }
    replayingRawKeys = true
    defer { replayingRawKeys = false; replayInsertionCount = 0 }
    while let first = queue.first, case .rawKey(let next) = first {
      replayInsertionCount = 0
      guard let view = input.activeView else {
        throw BoomError.stale("Deferred native input lost its physical client.")
      }
      guard next.window === view.window, next.window.firstResponder === view,
        next.replayLease == (try input.inputLease(for: view)) else {
        throw BoomError.stale("Native focus or keyboard source changed before deferred input replay.")
      }
      view.keyDown(with: next.event)
      guard input.firstRefusal == nil, view.inputBinding?.firstRefusal == nil else {
        throw BoomError.stale("The replayed native event was refused by its new source owner.")
      }
      // Remove only after the actual native command completed without refusal.
      queue.removeFirst(); queuedRawKeyCount -= 1; rawKeyBytes -= next.chargedBytes
      if phase == .blocked { throw firstFailure ?? BoomError.stale("A native replay command lost its source owner.") }
    }
  }

  private func fail(_ error: Error) {
    guard phase != .closed else { return }
    let next = receivingFailureSerial.addingReportingOverflow(1)
    if next.overflow { receivingFailureSerialExhausted = true }
    else { receivingFailureSerial = next.partialValue }
    if firstFailure == nil { firstFailure = error }
    else if independentReceivingFailure == nil { independentReceivingFailure = error }
    phase = .blocked
    didFail?(error)
  }

  private struct ReceivingObservation {
    let checkpoint: PagedNativeReceivingCheckpoint
    let lease: PagedNativeReplayInputLease
    let prefix: PagedNativePrefixReservation
    let direction: PagedNativeHistoryHandle.Direction
    let target: AnyObject?
    let queueCount: Int
    let queuedDirections: Int
    let queuedRawKeys: Int
    let rawKeyBytes: Int
  }

  private func sameReceivingTarget(_ left: AnyObject?, _ right: AnyObject?) -> Bool {
    switch (left, right) {
    case (.none, .none): return true
    case (.some(let left), .some(let right)): return left === right
    default: return false
    }
  }

  private func receivingObservation(_ choice: PagedNativeReceivingChoice,
    within ticket: PagedNativeReceivingDispositionTicket? = nil) throws -> ReceivingObservation {
    let ownsScope: Bool
    if let ticket { ownsScope = receivingTicket === ticket && ticket.owner === self }
    else { ownsScope = receivingTicket == nil }
    guard receivingTransition, ownsScope,
      phase == .blocked, commandTask == nil, firstFailure != nil,
      independentReceivingFailure == nil, !receivingFailureSerialExhausted,
      !registeringGroup, !replayingRawKeys, replayInsertionCount == 0,
      adoptingSource == nil, hydrationExpected == nil, retainedStage == nil,
      unregisteredGroup == nil, unretainedRawKeyCount == 0, unretainedCommandCount == 0,
      gatedManager.groupingLevel == 0, !gatedManager.isUndoing, !gatedManager.isRedoing,
      input.commandOwner === self, let prefix = retainedPrefix, let current = canonicalHistory,
      let view = input.activeView, let binding = view.inputBinding,
      binding.owner === input, binding.state == .active, input.firstRefusal == nil,
      binding.firstRefusal == nil, view.boundedStorage.mutationFailure == nil,
      view.inputCommandIsClosed, !view.hasMarkedText() else {
      throw BoomError.stale("Receiving disposition cannot clear independent input, source, SDK or command failure.")
    }
    let startingSerial = receivingFailureSerial
    let preparation = retainedPreparation
    let direction: PagedNativeHistoryHandle.Direction
    let target: AnyObject?
    switch choice {
    case .cancelUnpreparedHistoryKeepingInput:
      guard preparation == nil, let selected = expectedEntry,
        case .history(let head)? = queue.first, head == selected.handle.direction else {
        throw BoomError.stale("Receiving cancellation requires the exact still-unprepared head intent.")
      }
      direction = head; target = selected
    case .completeJoinedHistoryReceiving:
      guard let preparation, expectedEntry == nil, inverseEntry == nil,
        resolvedExpectedEntry == nil, resolvedOriginalEntryID == nil else {
        throw BoomError.stale("Receiving completion requires the already-consumed actual history target.")
      }
      direction = preparation.command.handle.direction
      target = try top(preparation.command.handle.inverse.direction)
    }
    let lease = try input.inputLease(for: view)
    guard lease.isFirstResponder, lease.isKeyWindow,
      lease.identity.ownerID == input.ownerID, lease.identity.sessionID == input.session.sessionID,
      lease.identity.arenaID == input.session.arenaID,
      queuedDirections + queuedRawKeyCount == queue.count,
      foundationProjectionIsExact() else {
      throw BoomError.stale("Receiving disposition lost its actual physical focus or Foundation targets.")
    }
    // Original event objects stay in this existing bounded queue. Only an
    // already-admitted actual mount may have changed their replay lease.
    for item in queue {
      if case .rawKey(let key) = item {
        guard key.window === view.window, key.event.type == .keyDown, key.replayLease == lease else {
          throw BoomError.stale("Receiving disposition cannot rebase an original raw event.")
        }
      }
    }
    let checkpoint = try input.session.receivingDispositionCheckpoint(
      prefix: choice == .cancelUnpreparedHistoryKeepingInput ? prefix : nil,
      completedHistory: choice == .completeJoinedHistoryReceiving ? preparation : nil)
    guard current.record == checkpoint.record, current.scope.coveredSequence == checkpoint.sealedGeneration,
      current.producer.engineIncarnation == checkpoint.engineIncarnation,
      let actual = input.session.canonicalHistory,
      current == actual || current.hasSamePublishedMetadata(as: actual) else {
      throw BoomError.stale("Receiving metadata differs from the actual current Session seal.")
    }
    if choice == .cancelUnpreparedHistoryKeepingInput {
      if let handle = checkpoint.unpreparedHandle {
        guard let selected = expectedEntry, handle == selected.handle else {
          throw BoomError.stale("Receiving cancellation names another refused Session intent.")
        }
      }
    } else {
      guard let stamp = lastInstalledHistoryStamp, let completed = checkpoint.completedHistory,
        stamp.history == completed, stamp.latestRecord == checkpoint.record,
        stamp.latestSequence == checkpoint.sealedGeneration,
        stamp.history.engineIncarnation == checkpoint.engineIncarnation else {
        throw BoomError.stale("Receiving completion lacks its exact installed history and later native ACK chain.")
      }
    }
    // SDK/physical queries above may reenter. Scalar/identity guards and the
    // real Session producer observation are repeated after all those queries.
    guard phase == .blocked, commandTask == nil, receivingFailureSerial == startingSerial,
      independentReceivingFailure == nil, firstFailure != nil,
      input.commandOwner === self, view === input.activeView, binding === view.inputBinding,
      binding.identity == lease.identity, binding.state == .active,
      input.firstRefusal == nil, binding.firstRefusal == nil,
      view.boundedStorage.mutationFailure == nil, view.inputCommandIsClosed,
      !registeringGroup, !replayingRawKeys, adoptingSource == nil,
      hydrationExpected == nil, retainedStage == nil,
      retainedPrefix == prefix, retainedPreparation == preparation,
      unregisteredGroup == nil, unretainedRawKeyCount == 0, unretainedCommandCount == 0,
      checkpoint == (try input.session.receivingDispositionCheckpoint(
        prefix: choice == .cancelUnpreparedHistoryKeepingInput ? prefix : nil,
        completedHistory: choice == .completeJoinedHistoryReceiving ? preparation : nil)) else {
      throw BoomError.stale("Receiving observation changed during actual physical or SDK admission.")
    }
    return ReceivingObservation(checkpoint: checkpoint, lease: lease, prefix: prefix,
      direction: direction, target: target, queueCount: queue.count, queuedDirections: queuedDirections,
      queuedRawKeys: queuedRawKeyCount, rawKeyBytes: rawKeyBytes)
  }

  func prepareReceivingDisposition(_ choice: PagedNativeReceivingChoice)
    throws -> PagedNativeReceivingDispositionTicket {
    guard receivingTicket == nil, !receivingTransition else {
      throw BoomError.stale("This receiving owner already has its one disposition observation.")
    }
    // Fence the actual Main observation interval BEFORE SDK/focus queries.
    // Reentrant prepare/apply/discard cannot replace this one admitted token.
    receivingTransition = true
    defer { receivingTransition = false }
    let observed = try receivingObservation(choice)
    let ticket = PagedNativeReceivingDispositionTicket(owner: self, choice: choice,
      checkpoint: observed.checkpoint, lease: observed.lease, prefix: observed.prefix,
      direction: observed.direction, target: observed.target, failureSerial: receivingFailureSerial,
      queueCount: observed.queueCount, queuedDirections: observed.queuedDirections,
      queuedRawKeys: observed.queuedRawKeys, rawKeyBytes: observed.rawKeyBytes)
    receivingTicket = ticket
    return ticket
  }

  /// Dispose ONLY observation metadata. Source intent/prefix/input/failure and
  /// all worker custody are unchanged; the old token can never apply later.
  func discardReceivingDispositionTicket(_ ticket: PagedNativeReceivingDispositionTicket) throws {
    guard !receivingTransition, receivingTicket === ticket, ticket.owner === self,
      ticket.ownerID == input.ownerID, !ticket.consumed else {
      throw BoomError.stale("Another receiving ticket owns this observation metadata.")
    }
    receivingTransition = true
    defer { receivingTransition = false }
    ticket.consumed = true; ticket.target = nil; ticket.owner = nil; receivingTicket = nil
  }

  private func requireReceivingTicket(_ ticket: PagedNativeReceivingDispositionTicket,
    observation: ReceivingObservation) throws {
    guard receivingTicket === ticket, ticket.owner === self, !ticket.consumed,
      ticket.ownerID == input.ownerID, !receivingFailureSerialExhausted,
      ticket.failureSerial == receivingFailureSerial,
      ticket.checkpoint == observation.checkpoint, ticket.lease == observation.lease,
      ticket.prefix == observation.prefix, ticket.direction == observation.direction,
      sameReceivingTarget(ticket.target, observation.target),
      ticket.queueCount == observation.queueCount, ticket.queuedDirections == observation.queuedDirections,
      ticket.queuedRawKeys == observation.queuedRawKeys, ticket.rawKeyBytes == observation.rawKeyBytes else {
      throw BoomError.stale("The receiving ticket is foreign, consumed or superseded by actual source/input/failure.")
    }
  }

  /// Explicit receiving disposition only. No raw event is interpreted here;
  /// the caller resumes the existing inputCommandDidClose lane separately.
  /// Actual cancellation may schedule already-admitted bytes through the
  /// Session's normal worker. This receipt never claims that later seal joined.
  func applyReceivingDisposition(_ ticket: PagedNativeReceivingDispositionTicket)
    async throws -> PagedNativeReceivingDispositionReceipt {
    guard !receivingTransition, receivingTicket === ticket, ticket.owner === self, !ticket.consumed else {
      throw BoomError.stale("Another receiving transition owns this exact ticket.")
    }
    receivingTransition = true
    defer { receivingTransition = false }
    let observation = try receivingObservation(ticket.choice, within: ticket)
    try requireReceivingTicket(ticket, observation: observation)
    var disposedCommandID: UUID?
    switch ticket.choice {
    case .cancelUnpreparedHistoryKeepingInput:
      if let commandID = observation.checkpoint.unpreparedCommandID {
        let actual = try input.session.resolveUnpreparedHistory(.explicitlyAbandoned)
        // No await or physical/SDK query separated the exact preflight from
        // this trusted Session operation. All fallible source checks precede
        // its release; bookkeeping must now consume this same intent once.
        precondition(actual.commandID == commandID && actual.prefix.reservation == ticket.prefix
          && actual.prefix.rootRecord == ticket.checkpoint.record)
        disposedCommandID = commandID
      } else { try input.session.releasePrefix(ticket.prefix) }
      precondition(!queue.isEmpty)
      if case .history(let direction) = queue[0] { precondition(direction == ticket.direction) }
      else { preconditionFailure("The blocked receiving cancellation lost its exact queue head.") }
      queue.removeFirst(); queuedDirections -= 1
    case .completeJoinedHistoryReceiving:
      guard let prepared = retainedPreparation else { throw BoomError.stale("The exact receiving preparation is no longer retained.") }
      let acknowledgement = try await input.session.joinHistoryPublication(commandID: prepared.command.commandID)
      let current = try receivingObservation(ticket.choice, within: ticket)
      try requireReceivingTicket(ticket, observation: current)
      let joined = try PagedNativeReceivingHistoryIdentity(prepared: prepared, acknowledgement: acknowledgement)
      guard joined == ticket.checkpoint.completedHistory else {
        throw BoomError.stale("A different actual Session history finish cannot clear this receiving intent.")
      }
      // That request was consumed before publication. Its present raw/key or
      // later history queue head is untouched; the old prefix was consumed.
    }
    retainedPrefix = nil; retainedPreparation = nil; lastInstalledHistoryStamp = nil
    expectedEntry = nil; inverseEntry = nil; resolvedExpectedEntry = nil; resolvedOriginalEntryID = nil
    ticket.consumed = true; ticket.target = nil; ticket.owner = nil; receivingTicket = nil
    // A synchronous release/disposal can report a NEW failure. Cancellation
    // still happened once, but that failure keeps the owner blocked. Clearing
    // the original Error may itself reenter; every actual fail advances serial.
    if receivingFailureSerial == ticket.failureSerial, independentReceivingFailure == nil,
      input.firstRefusal == nil, input.session.persistenceFailure == nil,
      input.session.historyFailure == nil, input.session.pendingCommitInstallation == nil,
      unregisteredGroup == nil, unretainedRawKeyCount == 0, unretainedCommandCount == 0 {
      firstFailure = nil
      if receivingFailureSerial == ticket.failureSerial, firstFailure == nil,
        independentReceivingFailure == nil { phase = .idle }
    }
    if firstFailure != nil || independentReceivingFailure != nil { phase = .blocked }
    let receipt = PagedNativeReceivingDispositionReceipt(ticketID: ticket.id, ownerID: input.ownerID,
      choice: ticket.choice, checkpoint: ticket.checkpoint, prefix: ticket.prefix,
      disposedUnpreparedCommandID: disposedCommandID, queuedRawKeyCount: queuedRawKeyCount,
      receivingOwnerRemainsBlocked: phase != .idle)
    lastReceivingDisposition = receipt
    return receipt
  }

  /// Await the command task which this owner actually entered. A queued
  /// request waiting on IME, a failure or newer command is still unresolved;
  /// returning from an await alone never declares the owner ready to close.
  func joinPendingCommand() async throws {
    var originalTaskRefusal: Error?
    // A real navigation observer may pump a queued Undo/raw event into the
    // SAME task slot when it joins. Follow those actual entered successors,
    // with the existing queue bound; never poll or use elapsed time as a join.
    for _ in 0..<(Self.maximumQueuedEntries + 2) {
      if navigationTask == nil, commandTask == nil { break }
      if let task = navigationTask {
        if case .failure(let error) = await task.result, originalTaskRefusal == nil { originalTaskRefusal = error }
      }
      if let task = commandTask { await task.value }
    }
    if let firstFailure { throw firstFailure }
    if navigationTask != nil || commandTask != nil {
      let bound = BoomError.budget("New native requests kept the actual command lane active beyond its bounded join.")
      if let originalTaskRefusal { throw PagedNativeNavigationOwnerFailure(original: originalTaskRefusal, cleanup: bound) }
      throw bound
    }
    if let originalTaskRefusal { throw originalTaskRefusal }
    if phase == .closed { try requireJoinedClose(); return }
    try requireCommandQuiescence()
  }

  private func requireCommandQuiescence() throws {
    guard phase == .idle, commandTask == nil, !isNavigating, navigationTask == nil, queue.isEmpty,
      queuedDirections == 0, queuedRawKeyCount == 0, rawKeyBytes == 0,
      !replayingRawKeys, replayInsertionCount == 0,
      !registeringGroup, !receivingTransition, receivingTicket == nil,
      expectedEntry == nil, inverseEntry == nil, adoptingSource == nil,
      hydrationExpected == nil, resolvedExpectedEntry == nil, resolvedOriginalEntryID == nil,
      retainedPrefix == nil, retainedPreparation == nil, retainedStage == nil,
      unregisteredGroup == nil, firstFailure == nil, independentReceivingFailure == nil,
      unretainedRawKeyCount == 0, unretainedCommandCount == 0,
      gatedManager.groupingLevel == 0, !gatedManager.isUndoing, !gatedManager.isRedoing else {
      throw BoomError.stale("The native command owner still retains input or a history operation.")
    }
  }

  /// Close only the actual joined physical/input owner. Backend worker/root
  /// custody remains a separate close; no callback drain is manufactured.
  func closeInput() throws {
    if phase == .closed { try requireJoinedClose(); return }
    try requireCommandQuiescence()
    guard input.commandOwner === self, let subscription = groupSubscription else {
      throw BoomError.denied("Another command owner owns this native input subscription.")
    }
    let ticket = try input.prepareInputRetirement(commandOwner: self)
    // Native preflight queries may synchronously reenter Cocoa. Recheck the
    // command state before the session admits the exact detach scope.
    try requireCommandQuiescence()
    try input.session.detachNativeGroupSubscription(subscription, ownerID: input.ownerID) { [self] in
      phase = .closed
      gatedManager.requestHistory = nil
      input.consumeInputRetirement(ticket, commandOwner: self)
    }
    groupSubscription = nil
    // Foundation notifications and captured action disposal can reenter, but
    // all public history methods and the old physical input are now inert.
    gatedManager.removeAllActions()
    undoEntries.removeAll(); redoEntries.removeAll(); canonicalHistory = nil
    lastInstalledHistoryStamp = nil; lastReceivingDisposition = nil
    mountView = nil; didFail = nil
    try requireJoinedClose()
  }

  func requireJoinedClose() throws {
    guard phase == .closed, groupSubscription == nil, gatedManager.requestHistory == nil,
      commandTask == nil, navigationTask == nil, !isNavigating, queue.isEmpty, queuedDirections == 0, queuedRawKeyCount == 0,
      rawKeyBytes == 0, !replayingRawKeys, expectedEntry == nil, inverseEntry == nil,
      !registeringGroup, !receivingTransition, receivingTicket == nil, adoptingSource == nil,
      hydrationExpected == nil, resolvedExpectedEntry == nil, resolvedOriginalEntryID == nil,
      undoEntries.isEmpty, redoEntries.isEmpty, canonicalHistory == nil,
      retainedPrefix == nil, retainedPreparation == nil, retainedStage == nil,
      unregisteredGroup == nil, firstFailure == nil, independentReceivingFailure == nil,
      unretainedRawKeyCount == 0, unretainedCommandCount == 0 else {
      throw BoomError.stale("The native command owner has not completed its physical retirement.")
    }
    try input.requireJoinedClose()
  }
}

private struct PagedNativeNavigationOwnerFailure: Error {
  let original: Error
  let cleanup: Error
}
