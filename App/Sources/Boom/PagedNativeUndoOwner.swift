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
  private enum SourceAction {
    case linePrefix(String)
    case documentCommand(Selector)
    case replacement(Data, String)
  }
  private struct SourceCommand {
    let action: SourceAction
    let originalLease: PagedNativeReplayInputLease
    var replayLease: PagedNativeReplayInputLease
    let window: NSWindow
    let chargedBytes: Int
  }
  private enum QueuedInput {
    case sourceCommand(SourceCommand)
    case history(PagedNativeHistoryHandle.Direction)
    case rawKey(RawKey)
  }
  static let maximumQueuedCommands = 64
  static let maximumRawKeyBytes = 262_144
  // The byte envelope, rather than an unrelated 64-keystroke cutoff, bounds
  // original event memory. Every event/source command is charged at least 512.
  static let maximumQueuedRawKeys = maximumRawKeyBytes / 512
  static let maximumQueuedEntries = maximumQueuedRawKeys + maximumQueuedCommands + 32
  private static let maximumReplayBurst = 4
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
  private var currentRawKeyAwaitingSource = false
  private var registeringGroup = false
  private var expectedEntry: PagedNativeUndoEntry?
  private var inverseEntry: PagedNativeUndoEntry?
  private var adoptingSource: (() -> Void)?
  private var commandTask: Task<Void, Never>?
  private var navigationTask: Task<PagedTextWindow, Error>?
  private var capturedEditTask: Task<PagedDocumentRootRecord, Error>?
  private var capturedActionName: String?
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
      || receivingTransition || receivingTicket != nil || isNavigating || navigationTask != nil || capturedEditTask != nil
  }

  init(input: PagedNativeInputOwner) throws {
    guard input.commandOwner == nil else {
      throw BoomError.denied("This native session already has its command and group owner.")
    }
    self.input = input
    queue.reserveCapacity(Self.maximumQueuedCommands)
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
    try input.setDocumentSelection(PagedNativeNavigationSelection(
      utf16Offset: opening.history.currentCursor.utf16Offset,
      utf16Length: opening.history.currentCursor.selectionLengthUTF16,
      focusAtEnd: opening.history.currentCursor.focusAtEnd, affinity: opening.history.currentCursor.affinity))
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
    case .capturedEdit: return nil
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
          groupID: canonical.groupID, direction: desired.direction), actionName: capturedActionName ?? "Edit",
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
    let observed = try input.observeSelection()
    let currentSelection = try input.currentDocumentSelection()
    let selection = requested ?? currentSelection
    // Loading another projection of the SAME selection need not defer
    // contained input. Session rejects its candidate if source/input changes.
    // An actual new caret/selection keeps the existing ordered command fence.
    isNavigating = selection != currentSelection
    defer { navigationTask = nil; isNavigating = false; pump() }
    let task = Task<PagedTextWindow, Error> { [self] in
      try await navigateAdmitted(toUTF16: anchor, selection: selection, observed: observed,
        roundGeneratedAnchor: false, deferredInput: false)
    }
    navigationTask = task
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  func applyCapturedEdits(expected: PagedDocumentRootRecord, edits: [PagedTextLocalEdit],
    actionName: String) async throws -> PagedDocumentRootRecord {
    guard edits.count <= PagedCapturedEditInput.maximumEdits else {
      throw BoomError.budget("Explicit edit count exceeds its bounded source capture.")
    }
    var inputBytes = 0
    for edit in edits {
      guard edit.oldBytes.count <= PagedCapturedEditInput.maximumInputBytes - inputBytes else {
        throw BoomError.budget("Explicit old bytes exceed their capture bound.")
      }
      inputBytes += edit.oldBytes.count
      guard edit.newBytes.count <= PagedCapturedEditInput.maximumInputBytes - inputBytes else {
        throw BoomError.budget("Explicit new bytes exceed their capture bound.")
      }
      inputBytes += edit.newBytes.count
    }
    let changed = edits.filter { $0.oldBytes != $0.newBytes }
    guard !changed.isEmpty else {
      guard try input.session.documentCoordinates().record == expected else {
        throw BoomError.stale("Neutral edits no longer name the current source.")
      }
      return expected
    }
    guard changed.count <= PagedCapturedEditInput.maximumEdits else {
      throw BoomError.budget("Explicit edit count exceeds its bounded source capture.")
    }
    var previousStart = expected.document.revision.summary.bytes
    var charged = 0
    for edit in changed {
      guard edit.revision == expected.document.revision,
        edit.byteStart <= edit.byteEnd, edit.byteEnd <= previousStart,
        edit.byteEnd - edit.byteStart == UInt64(edit.oldBytes.count),
        edit.oldBytes.count <= PagedCapturedEditInput.maximumInputBytes - charged else {
        throw BoomError.stale("Explicit edits are not ordered exact ranges of the captured source.")
      }
      charged += edit.oldBytes.count
      guard edit.newBytes.count <= PagedCapturedEditInput.maximumInputBytes - charged else {
        throw BoomError.budget("Explicit replacement bytes exceed their capture bound.")
      }
      charged += edit.newBytes.count; previousStart = edit.byteStart
    }
    return try await beginCapturedEdit(expected: expected, operation: .edits(changed), actionName: actionName).value
  }

  func replaceDocumentSelection(_ selection: PagedNativeNavigationSelection,
    with replacement: Data, actionName: String) async throws -> PagedDocumentRootRecord {
    let coordinates = try input.session.documentCoordinates()
    guard selection.utf16Offset <= coordinates.projectedUTF16,
      selection.utf16Length <= coordinates.projectedUTF16 - selection.utf16Offset,
      replacement.count <= PagedCapturedEditInput.maximumInputBytes else {
      throw BoomError.budget("Explicit document replacement exceeds its range or buffer bound.")
    }
    if selection.utf16Length == 0, replacement.isEmpty { return coordinates.record }
    // An explicit source selection must first join any local typing. Its root
    // is captured after that join; the original selection remains owned here.
    return try await beginCapturedEdit(expected: nil, operation: .replacement(selection, replacement), actionName: actionName).value
  }

  /// Fence the actual key command synchronously before returning to AppKit.
  /// Later keys join the existing bounded event queue while disk work runs.
  func requestDocumentReplacement(_ selection: PagedNativeNavigationSelection,
    replacement: Data, actionName: String) throws {
    guard replacement.count <= PagedCapturedEditInput.maximumInputBytes else {
      throw BoomError.budget("Document replacement needs its streamed import route.")
    }
    guard let view = input.activeView else { return }
    // Ordinary input selects its ordered current range at delivery. Explicit
    // captured/agent edits above still require their supplied source record.
    try enqueueSourceCommand(.replacement(replacement, actionName), from: view,
      chargedBytes: replacement.count + actionName.utf8.count + 512)
  }

  /// Menu requests use the existing ordered input lane. Their selection is
  /// observed only after earlier keys and source commands have joined.
  func requestLinePrefix(_ prefix: String, from view: PagedNativeTextView) throws {
    guard !prefix.isEmpty, prefix.utf8.count <= 256,
      !prefix.unicodeScalars.contains(where: { [0x0A, 0x0D, 0x85, 0x2028, 0x2029].contains($0.value) }) else {
      throw BoomError.invalid("The line prefix is not a bounded single-line marker.")
    }
    try enqueueSourceCommand(.linePrefix(prefix), from: view, chargedBytes: prefix.utf8.count + 512)
  }

  private func enqueueSourceCommand(_ action: SourceAction, from view: PagedNativeTextView,
    chargedBytes: Int) throws {
    guard phase != .closed, view === input.activeView,
      view.inputBinding?.state == .active else { return }
    let consumedHeadCharge: Int
    if replayingRawKeys, let head = queue.first {
      switch head {
      case .rawKey(let key): consumedHeadCharge = key.chargedBytes
      case .sourceCommand(let command): consumedHeadCharge = command.chargedBytes
      case .history: consumedHeadCharge = 0
      }
    } else { consumedHeadCharge = 0 }
    // The source command replaces the interpreted head. Reserve against the
    // post-delivery byte charge, while retaining that head until real dispatch
    // completes. This bounded lexical overlap is at most one source buffer.
    guard let window = view.window, window.firstResponder === view,
      queue.count < Self.maximumQueuedEntries,
      chargedBytes >= 512, consumedHeadCharge <= rawKeyBytes,
      chargedBytes <= Self.maximumRawKeyBytes - (rawKeyBytes - consumedHeadCharge) else {
      throw BoomError.budget("The existing native input queue cannot retain this source command.")
    }
    let lease = try input.inputLease(for: view)
    let request = QueuedInput.sourceCommand(SourceCommand(action: action, originalLease: lease,
      replayLease: lease, window: window, chargedBytes: chargedBytes))
    if replayingRawKeys {
      queue.insert(request, at: 1 + replayInsertionCount); replayInsertionCount += 1
    } else { queue.append(request) }
    rawKeyBytes += chargedBytes
    pump()
  }

  /// Formatting changes only its small delimiters. The selected source stays
  /// in the file-backed tree, even when it spans the complete document.
  func requestDocumentWrapping(_ selection: PagedNativeNavigationSelection,
    prefix: String, suffix: String, toggles: Bool, actionName: String) throws {
    let opening = Data(prefix.utf8), closing = Data(suffix.utf8)
    guard !opening.isEmpty, !closing.isEmpty, opening.count <= 64, closing.count <= 64,
      selection.utf16Length > 0 else {
      throw BoomError.budget("Document delimiters exceed their bounded formatting command.")
    }
    let openingUnits = UInt64(prefix.utf16.count), closingUnits = UInt64(suffix.utf16.count)
    _ = try beginCapturedEdit(expected: nil, actionName: actionName, reportFailure: true,
      preparingOperation: { [self] record in
        let total = record.document.revision.summary.utf16
        guard selection.utf16Offset <= total,
          selection.utf16Length <= total - selection.utf16Offset else {
          throw BoomError.stale("Formatting has another document selection.")
        }
        let start = selection.utf16Offset, end = start + selection.utf16Length
        var leftStart = start, leftEnd = start, rightStart = end, rightEnd = end
        var leftOld = Data(), rightOld = Data(), leftNew = opening, rightNew = closing
        let insertedStart = start.addingReportingOverflow(openingUnits)
        guard !insertedStart.overflow else { throw BoomError.budget("Formatting exhausts document coordinates.") }
        var after = PagedNativeNavigationSelection(utf16Offset: insertedStart.partialValue,
          utf16Length: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
        if toggles {
          func matches(_ marker: Data, at offset: UInt64) async throws -> Bool {
            let window = try await input.session.sealedTextWindow(atUTF16: offset,
              maximumBytes: max(4, marker.count))
            return window.text.utf8.prefix(marker.count).elementsEqual(marker)
          }
          if selection.utf16Length >= openingUnits + closingUnits,
            try await matches(opening, at: start),
            try await matches(closing, at: end - closingUnits) {
            leftEnd = start + openingUnits; rightStart = end - closingUnits
            leftOld = opening; rightOld = closing; leftNew = Data(); rightNew = Data()
            after = PagedNativeNavigationSelection(utf16Offset: start,
              utf16Length: selection.utf16Length - openingUnits - closingUnits,
              focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
          } else if start >= openingUnits, closingUnits <= total - end,
            try await matches(opening, at: start - openingUnits),
            try await matches(closing, at: end) {
            leftStart = start - openingUnits; rightEnd = end + closingUnits
            leftOld = opening; rightOld = closing; leftNew = Data(); rightNew = Data()
            after = PagedNativeNavigationSelection(utf16Offset: start - openingUnits,
              utf16Length: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
          }
        }
        let windowID = try input.session.windowForNativeInstallation().windowID
        func edit(_ low: UInt64, _ high: UInt64, _ old: Data, _ new: Data) async throws -> PagedTextLocalEdit {
          let a = try await input.session.sealedCursor(for: PagedNativeNavigationSelection(utf16Offset: low, utf16Length: 0))
          let b = low == high ? a : try await input.session.sealedCursor(for: PagedNativeNavigationSelection(utf16Offset: high, utf16Length: 0))
          return PagedTextLocalEdit(revision: record.document.revision, windowID: windowID,
            byteStart: a.byteOffset, byteEnd: b.byteOffset, oldBytes: old, newBytes: new)
        }
        let right = try await edit(rightStart, rightEnd, rightOld, rightNew)
        let left = try await edit(leftStart, leftEnd, leftOld, leftNew)
        return (.edits([right, left]), after)
      })
  }

  /// Clipboard preparation shares the actual command fence and immutable
  /// source capture. A Cut enters the writer only after publication succeeds.
  @discardableResult
  func requestDocumentClipboard(_ selection: PagedNativeNavigationSelection, cutting: Bool,
    prepare: @escaping @MainActor (PagedDocumentRootRecord) async throws -> Void)
    throws -> Task<PagedDocumentRootRecord, Error> {
    try beginCapturedEdit(expected: nil, actionName: cutting ? "Cut" : "Copy",
      reportFailure: true, sourceOnly: !cutting,
      preparingOperation: { record in
        try await prepare(record)
        return (.replacement(selection, Data()), nil)
      })
  }

  /// The existing command task owns the real imported tree until its physical
  /// receiving join. Cancellation before writer admission explicitly releases
  /// that output; a failed publication keeps both original source leases.
  @discardableResult
  func requestDocumentImportedReplacement(_ selection: PagedNativeNavigationSelection,
    importing: @escaping @MainActor (PagedDocumentRootRecord) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision>,
    discard: @escaping @MainActor (PagedTextRootLease) async throws -> Void)
    throws -> Task<PagedDocumentRootRecord, Error> {
    try beginCapturedEdit(expected: nil, actionName: "Paste", reportFailure: true,
      preparingOperation: { record in
        let imported = try await importing(record)
        return (.importedReplacement(selection, imported), nil)
      }, discardPreparedOperation: { operation in
        if case .importedReplacement(_, let imported) = operation { try await discard(imported.lease) }
      })
  }

  func replaceSelectionBeforeRawKey(_ event: NSEvent, from view: PagedNativeTextView,
    selection: PagedNativeNavigationSelection) throws {
    guard event.type == .keyDown, view === input.activeView,
      (event.characters ?? "").utf16.count <= Self.maximumKeyUTF16,
      (event.charactersIgnoringModifiers ?? "").utf16.count <= Self.maximumKeyUTF16 else {
      throw BoomError.budget("Selected-source input exceeds its native event bound.")
    }
    if !replayingRawKeys {
      // Own the original event before a captured writer can start. The real
      // queue interprets this head at its ordered selection, with no duplicate
      // event appended after later input if the deletion needs a new window.
      try retainRawKey(event, from: view)
      pump()
      return
    }
    guard let first = queue.first, case .rawKey(let head) = first, head.event === event else {
      throw BoomError.stale("Selected-source replay lost its original queue head.")
    }
    _ = try beginCapturedEdit(expected: nil, operation: .replacement(selection, Data()),
      actionName: "Edit", reportFailure: true, continueTyping: true)
    currentRawKeyAwaitingSource = true
  }

  private func beginCapturedEdit(expected: PagedDocumentRootRecord?,
    operation: PagedCapturedEditInput.Operation? = nil, actionName: String, reportFailure: Bool = false,
    continueTyping: Bool = false, sourceOnly: Bool = false, groupID capturedGroup: UUID? = nil,
    preparingOperation: (@MainActor (PagedDocumentRootRecord) async throws ->
      (PagedCapturedEditInput.Operation, PagedNativeNavigationSelection?))? = nil,
    discardPreparedOperation: (@MainActor (PagedCapturedEditInput.Operation) async throws -> Void)? = nil)
    throws -> Task<PagedDocumentRootRecord, Error> {
    guard (operation == nil) != (preparingOperation == nil) else {
      throw BoomError.invalid("Explicit editing requires exactly one operation source.")
    }
    try requireCommandQuiescence(allowDeferredInput: replayingRawKeys)
    try requireNavigationClient()
    guard let view = input.activeView, let window = view.window, window.isKeyWindow,
      window.firstResponder === view || window.makeFirstResponder(view) else {
      throw BoomError.stale("Explicit editing requires its actual native document window.")
    }
    let observed = try input.observeSelection()
    let selection = try input.currentDocumentSelection()
    let editGroup = capturedGroup ?? UUID()
    phase = .preparing; capturedActionName = actionName
    let prefix: PagedNativePrefixReservation
    do { prefix = try input.session.reservePrefix() }
    catch { phase = .idle; capturedActionName = nil; throw error }
    let task = Task<PagedDocumentRootRecord, Error> { [self] in
      let startingFailureSerial = receivingFailureSerial
      var reservation: PagedNativePrefixReservation? = prefix
      var writerEntered = false
      var preparedOperation: PagedCapturedEditInput.Operation?
      defer {
        capturedEditTask = nil; capturedActionName = nil
        if phase == .idle { pump() }
      }
      do {
        let sealed = try await input.session.flush(prefix)
        guard try input.observeSelection() == observed, firstFailure == nil,
          expected == nil || sealed.rootRecord == expected else {
          throw BoomError.stale("The explicit edit source changed before its file transaction.")
        }
        try input.session.releasePrefix(prefix); reservation = nil
        let beforeCursor = try await input.session.sealedCursor(for: selection)
        let prepared: (PagedCapturedEditInput.Operation, PagedNativeNavigationSelection?)
        if let preparingOperation { prepared = try await preparingOperation(sealed.rootRecord) }
        else if let operation { prepared = (operation, nil) }
        else { throw BoomError.invalid("Explicit editing lost its operation.") }
        preparedOperation = prepared.0
        try Task.checkCancellation()
        guard try input.observeSelection() == observed, firstFailure == nil else {
          throw BoomError.stale("The native selection changed before explicit editing.")
        }
        if sourceOnly {
          phase = .idle
          try replayOriginalKeys()
          return sealed.rootRecord
        }
        let commandID = UUID(), groupID = editGroup, next = prefix.generation.addingReportingOverflow(1)
        guard !next.overflow else { throw BoomError.budget("Native source sequence is exhausted.") }
        let route = try input.session.beginCapturedEdit(expected: sealed.rootRecord, commandID: commandID)
        writerEntered = true
        let result: PagedCapturedEditResult
        switch prepared.0 {
        case .edits(let edits):
          result = try await route.commitCapturedEdits(expected: sealed.rootRecord, edits: edits,
            sessionID: input.session.sessionID, commandID: commandID, groupID: groupID,
            sequence: next.partialValue, beforeCursor: beforeCursor, afterSelection: prepared.1)
        case .replacement(let range, let bytes):
          result = try await route.commitUserReplacement(expected: sealed.rootRecord, selection: range,
            replacement: bytes, sessionID: input.session.sessionID, commandID: commandID,
            groupID: groupID, sequence: next.partialValue, beforeCursor: beforeCursor)
        case .importedReplacement(let range, let imported):
          result = try await route.commitImportedReplacement(expected: sealed.rootRecord, selection: range,
            imported: imported, sessionID: input.session.sessionID, commandID: commandID,
            groupID: groupID, sequence: next.partialValue, beforeCursor: beforeCursor)
        case .linePrefix(let range, let prefix):
          result = try await route.commitLinePrefix(expected: sealed.rootRecord, selection: range,
            prefix: prefix, sessionID: input.session.sessionID, commandID: commandID,
            groupID: groupID, sequence: next.partialValue, beforeCursor: beforeCursor)
        }
        guard try input.observeSelection() == observed, let mount = mountView else {
          throw BoomError.stale("Published editing lost its original physical input receiver.")
        }
        let ticket = try input.session.preparePublishedEditInstallation(result, owner: input)
        try input.stageNavigation(ticket, observedSelection: observed)
        _ = try input.withStagedNavigationInstallation(ticket, mounted: mount)
        try await input.session.finishCapturedEditInstallation(result)
        try transferRawInputAfterMount()
        phase = .idle
        if continueTyping { input.continueNextInputGroup(groupID) }
        input.notifyNativeState(from: input.activeView, edited: true)
        try replayOriginalKeys()
        return result.record
      } catch {
        let original = error
        if let reservation {
          do { try input.session.releasePrefix(reservation) }
          catch { fail(PagedNativeNavigationOwnerFailure(original: original, cleanup: error)); throw original }
        }
        if !writerEntered || original is PagedCapturedEditUnchanged,
          let preparedOperation, let discardPreparedOperation {
          do { try await discardPreparedOperation(preparedOperation) }
          catch {
            let retained = PagedNativeNavigationOwnerFailure(original: original, cleanup: error)
            fail(retained); throw retained
          }
        }
        if let unchanged = original as? PagedCapturedEditUnchanged {
          try input.session.completeUnchangedCapturedEdit(unchanged)
          phase = .idle
          try replayOriginalKeys()
          return unchanged.record
        }
        if writerEntered {
          if !receivingFailureSerialExhausted, receivingFailureSerial == startingFailureSerial {
            input.session.recordCapturedEditFailure(original); fail(original)
          } else { phase = .blocked }
        } else {
          phase = firstFailure == nil ? .idle : .blocked
          do { try replayOriginalKeys() } catch { fail(error) }
          if reportFailure { didFail?(original) }
        }
        throw original
      }
    }
    capturedEditTask = task
    return task
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
      // Original events remain unchanged and ordered. Their current replay
      // leases may already have passed through this owner's earlier actual
      // mount; validate that current lease, not the original retired client.
      for item in queue {
        if case .rawKey(let key) = item {
          guard key.replayLease == observed.inputLease else {
            throw BoomError.stale("A deferred navigation key belongs to another actual physical source.")
          }
        } else if case .sourceCommand(let command) = item {
          guard command.replayLease == observed.inputLease else {
            throw BoomError.stale("Deferred source input belongs to another actual physical source.")
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
      toUTF16: anchor, selection: selection,
      roundGeneratedAnchor: roundGeneratedAnchor)
    do {
      try Task.checkCancellation()
      guard isNavigating || (!deferredInput && navigationTask != nil) else {
        throw BoomError.stale("The exact navigation owner retired before mounting.")
      }
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
    var retained = false
    do {
      try requireCommandQuiescence(allowDeferredInput: replayingRawKeys); try requireNavigationClient()
      let observed = try input.observeSelection()
      let selection = try input.currentDocumentSelection()
      if replayingRawKeys {
        guard let first = queue.first, case .rawKey(let head) = first, head.event === event else {
          throw BoomError.stale("Recenter does not own the original replay head.")
        }
        // Keep this exact key at the head until its actual source mount. A
        // recenter is not delivery, and appending it would reorder later keys.
        currentRawKeyAwaitingSource = true
      } else { try retainRawKey(event, from: view) }
      retained = true
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
    do {
      if replayingRawKeys {
        guard let first = queue.first, case .rawKey(let head) = first, head.event === event else {
          throw BoomError.stale("The refused document key is not this original replay head.")
        }
        currentRawKeyAwaitingSource = true
      } else { try retainRawKey(event, from: view) }
      fail(original)
    } catch {
      if unretainedRawKeyCount < UInt64.max { unretainedRawKeyCount += 1 }
      fail(PagedNativeNavigationOwnerFailure(original: original, cleanup: error))
    }
  }

  /// Selection/caret movement is the same source operation as recentering;
  /// no second timeline or direct Root/NSRange retarget exists.
  func requestDocumentNavigation(toUTF16 anchor: UInt64,
    selectingUTF16 selection: PagedNativeNavigationSelection,
    expected: PagedNativeDocumentCoordinates) throws {
    try requireCommandQuiescence(allowDeferredInput: replayingRawKeys); try requireNavigationClient()
    let current = try input.session.documentCoordinates()
    guard current.record == expected.record, current.sessionID == expected.sessionID,
      current.arenaID == expected.arenaID, current.generation == expected.generation,
      current.windowID == expected.windowID else {
      throw BoomError.stale("Document selection has another exact source arena or generation.")
    }
    let observed = try input.observeSelection()
    beginOwnedNavigation(toUTF16: anchor, selection: selection, observed: observed)
  }
  /// Resolve a character boundary against the sealed full source, retaining
  /// later keys on the existing navigation queue until the window is adopted.
  func requestGraphemeMovement(forward: Bool, extending: Bool,
    selection: PagedNativeNavigationSelection, nativeTargetUTF16: UInt64? = nil,
    resultAffinity: PagedSelectionAffinity? = nil) throws {
    try requireCommandQuiescence(allowDeferredInput: replayingRawKeys); try requireNavigationClient()
    let observed = try input.observeSelection()
    let prefix = try input.session.reservePrefix()
    beginOwnedNavigation(toUTF16: selection.focusUTF16, selection: selection, observed: observed) { [self] in
      var held = true
      do {
        _ = try await input.session.flush(prefix)
        guard try input.observeSelection() == observed else {
          throw BoomError.stale("Character movement lost its original selection.")
        }
        try input.session.releasePrefix(prefix); held = false
        let target: UInt64
        if let nativeTargetUTF16 {
          target = try await input.session.sealedGraphemeBoundary(atNativeUTF16: nativeTargetUTF16, forward: forward)
        } else if !extending, selection.utf16Length > 0 {
          target = forward ? selection.utf16Offset + selection.utf16Length : selection.utf16Offset
        } else {
          target = try await input.session.sealedGraphemeBoundary(atUTF16: selection.focusUTF16, forward: forward)
        }
        try Task.checkCancellation()
        guard try input.observeSelection() == observed else {
          throw BoomError.stale("Character movement changed while its boundary loaded.")
        }
        if extending {
          let anchor = selection.anchorUTF16
          return PagedNativeNavigationSelection(utf16Offset: min(anchor, target),
            utf16Length: max(anchor, target) - min(anchor, target), focusAtEnd: target >= anchor,
            affinity: resultAffinity ?? selection.affinity)
        }
        return PagedNativeNavigationSelection(utf16Offset: target, utf16Length: 0,
          affinity: resultAffinity ?? selection.affinity)
      } catch {
        let original = error
        if held {
          do { try input.session.releasePrefix(prefix) }
          catch { throw PagedNativeNavigationOwnerFailure(original: original, cleanup: error) }
        }
        throw original
      }
    }
  }

  func requestDocumentCommand(_ selector: Selector, from view: PagedNativeTextView) throws {
    try enqueueSourceCommand(.documentCommand(selector), from: view, chargedBytes: 512)
  }

  func requestParagraphCommand(_ command: PagedNativeParagraphCommand) throws {
    let selection = try input.currentDocumentSelection()
    if command.deletes {
      _ = try beginCapturedEdit(expected: nil, actionName: "Delete", reportFailure: true,
        groupID: input.activeView?.typedCharacterCommandGroupID,
        preparingOperation: { [self] _ in
          if selection.utf16Length > 0 { return (.replacement(selection, Data()), nil) }
          let target = try await paragraphEndpoint(command, atUTF16: selection.focusUTF16)
          let start = min(target, selection.focusUTF16), end = max(target, selection.focusUTF16)
          return (.replacement(PagedNativeNavigationSelection(utf16Offset: start,
            utf16Length: end - start, focusAtEnd: selection.focusAtEnd,
            affinity: selection.affinity), Data()), nil)
        })
      return
    }
    try requireCommandQuiescence(allowDeferredInput: replayingRawKeys); try requireNavigationClient()
    let observed = try input.observeSelection(), prefix = try input.session.reservePrefix()
    beginOwnedNavigation(toUTF16: selection.focusUTF16, selection: selection, observed: observed) { [self] in
      var held = true
      do {
        _ = try await input.session.flush(prefix)
        guard try input.observeSelection() == observed else {
          throw BoomError.stale("Paragraph movement lost its original selection.")
        }
        try input.session.releasePrefix(prefix); held = false
        let target = try await paragraphEndpoint(command, atUTF16: selection.focusUTF16)
        try Task.checkCancellation()
        guard try input.observeSelection() == observed else {
          throw BoomError.stale("Paragraph movement changed while its source bounds loaded.")
        }
        if command.extends {
          let fixed = selection.anchorUTF16
          return PagedNativeNavigationSelection(utf16Offset: min(fixed, target),
            utf16Length: max(fixed, target) - min(fixed, target), focusAtEnd: target >= fixed,
            affinity: selection.affinity)
        }
        return PagedNativeNavigationSelection(utf16Offset: target, utf16Length: 0,
          affinity: selection.affinity)
      } catch {
        let original = error
        if held {
          do { try input.session.releasePrefix(prefix) }
          catch { throw PagedNativeNavigationOwnerFailure(original: original, cleanup: error) }
        }
        throw original
      }
    }
  }

  private func paragraphEndpoint(_ command: PagedNativeParagraphCommand,
    atUTF16 offset: UInt64) async throws -> UInt64 {
    let bounds = try await input.session.sealedParagraphBounds(atUTF16: offset)
    switch command {
    case .beginning, .beginningSelecting, .deleteBeginning: return bounds.start.utf16
    case .end, .endSelecting: return bounds.contentEnd.utf16
    case .deleteEnd: return offset < bounds.contentEnd.utf16 ? bounds.contentEnd.utf16 : bounds.end.utf16
    case .forwardSelecting:
      if offset < bounds.contentEnd.utf16 { return bounds.contentEnd.utf16 }
      if bounds.end.utf16 < input.session.sealedRevision.summary.utf16 {
        return try await input.session.sealedParagraphBounds(atUTF16: bounds.end.utf16).contentEnd.utf16
      }
      return bounds.end.utf16
    case .backwardSelecting:
      if offset > bounds.start.utf16 || bounds.start.utf16 == 0 { return bounds.start.utf16 }
      let previous = try await input.session.sealedGraphemeBoundary(atUTF16: bounds.start.utf16, forward: false)
      return try await input.session.sealedParagraphBounds(atUTF16: previous).start.utf16
    }
  }

  /// Left/Right are visual commands. Probe this actual Cocoa layout, restore
  /// its owned selection before any yield, then validate the observed target
  /// against the full source on the existing navigation lane.
  func requestVisualGraphemeMovement(_ selector: Selector) throws {
    try requireCommandQuiescence(allowDeferredInput: replayingRawKeys); try requireNavigationClient()
    let command = NSStringFromSelector(selector)
    guard ["moveLeft:", "moveRight:", "moveLeftAndModifySelection:", "moveRightAndModifySelection:"].contains(command) else {
      throw BoomError.invalid("A visual character command requires its actual native selector.")
    }
    let extending = command.contains("AndModifySelection")
    let (original, native) = try probeNativeVisualMovement(selector, extending: extending)
    try requireCommandQuiescence(allowDeferredInput: replayingRawKeys); try requireNavigationClient()
    guard try input.selectionForVisualMovement() == original else {
      throw BoomError.stale("Visual movement lost its restored selection before source capture.")
    }
    if native.focusUTF16 == original.focusUTF16,
      extending || original.utf16Length == 0 {
      // A native affinity-only movement or true endpoint no-op needs no
      // source read, mount, or history entry.
      if native != original { try input.setDocumentSelection(native) }
      return
    }
    let forward: Bool
    if !extending, original.utf16Length > 0 {
      // Native collapse picked this exact endpoint; neither the arrow name
      // nor its visual affinity identifies the logical direction.
      forward = native.focusUTF16 == original.utf16Offset + original.utf16Length
    } else { forward = native.focusUTF16 > original.focusUTF16 }
    try requestGraphemeMovement(forward: forward, extending: extending, selection: original,
      nativeTargetUTF16: native.focusUTF16, resultAffinity: native.affinity)
  }

  private func probeNativeVisualMovement(_ selector: Selector, extending: Bool) throws
    -> (PagedNativeNavigationSelection, PagedNativeNavigationSelection) {
    let view = input.activeView!
    // Use the existing key/command fence during synchronous AppKit reentry.
    // No Task, owner, receipt or source/history edit is created by this probe.
    isNavigating = true
    defer { isNavigating = false }
    let source = try input.session.documentCoordinates()
    let original = try input.selectionForVisualMovement(), observed = try input.observeSelection()
    let windowEnd = source.utf16Start + UInt64(source.localUTF16)
    let selectionEnd = original.utf16Offset + original.utf16Length
    let lower = min(windowEnd, max(source.utf16Start, original.utf16Offset))
    let upper = min(windowEnd, max(lower, selectionEnd))
    let painted = NSRange(location: Int(lower - source.utf16Start), length: Int(upper - lower))
    let extendsBeyondWindow = original.utf16Offset < source.utf16Start || selectionEnd > windowEnd
    guard observed.inputLease.isFirstResponder, observed.inputLease.isKeyWindow,
      observed.range == painted,
      !extending || !extendsBeyondWindow || (original.focusUTF16 >= source.utf16Start && original.focusUTF16 <= windowEnd) else {
      throw BoomError.unavailable("Visual extension requires its actual focused source window.")
    }
    func admitProjection() throws {
      let current = try input.session.documentCoordinates(), actual = try input.observeSelection()
      guard input.activeView === view, current.record == source.record, current.sessionID == source.sessionID,
        current.arenaID == source.arenaID, current.generation == source.generation, current.windowID == source.windowID,
        current.utf16Start == source.utf16Start, current.localUTF16 == source.localUTF16,
        current.projectedUTF16 == source.projectedUTF16, current.localBytes == source.localBytes,
        actual.identity == observed.identity, actual.inputLease == observed.inputLease,
        input.firstRefusal == nil, view.inputBinding?.firstRefusal == nil,
        view.boundedStorage.mutationFailure == nil, !view.hasMarkedText(), view.inputCommandIsClosed else {
        throw BoomError.stale("Cocoa visual movement changed its actual source or physical consumer.")
      }
    }
    func restore() throws {
      try admitProjection()
      try input.setDocumentSelection(original)
      try admitProjection()
      let restored = try input.observeSelection()
      guard try input.selectionForVisualMovement() == original,
        restored.range == observed.range, restored.affinity == observed.affinity else {
        throw BoomError.stale("Cocoa visual movement did not restore its original owned selection.")
      }
    }
    var entered = false, restored = false
    do {
      try admitProjection()
      guard phase == .idle, (queue.isEmpty || replayingRawKeys), firstFailure == nil else {
        throw BoomError.stale("Later native input preceded the visual probe.")
      }
      entered = true
      if extending, extendsBeyondWindow {
        // AppKit cannot own the distant anchor. Seed the actual local focus,
        // execute its unmodified visual arrow, and keep the global anchor here.
        try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: original.focusUTF16,
          utf16Length: 0, affinity: original.affinity))
        try admitProjection()
        let command = NSStringFromSelector(selector)
        try view.performContainedDocumentCommand(NSSelectorFromString(command.hasPrefix("moveLeft") ? "moveLeft:" : "moveRight:"))
      } else { try view.performContainedDocumentCommand(selector) }
      try admitProjection()
      let observedTarget = try input.selectionForVisualMovement()
      guard observedTarget.utf16Offset >= source.utf16Start,
        observedTarget.utf16Offset + observedTarget.utf16Length <= windowEnd else {
        throw BoomError.stale("Cocoa visual movement did not preserve its actual target or anchor.")
      }
      let native: PagedNativeNavigationSelection
      if extending, extendsBeyondWindow {
        guard observedTarget.utf16Length == 0 else { throw BoomError.stale("A visual focus probe did not return its actual caret.") }
        let fixed = original.anchorUTF16, target = observedTarget.focusUTF16
        native = PagedNativeNavigationSelection(utf16Offset: min(fixed, target),
          utf16Length: max(fixed, target) - min(fixed, target), focusAtEnd: target >= fixed,
          affinity: observedTarget.affinity)
      } else if !extending, extendsBeyondWindow {
        // Selection collapse chooses a real endpoint of the painted
        // intersection. Map that observed choice to the owned full range.
        guard painted.length > 0, observedTarget.utf16Length == 0,
          observedTarget.focusUTF16 == lower || observedTarget.focusUTF16 == upper else {
          throw BoomError.unavailable("Cocoa did not establish a visual selection-collapse endpoint.")
        }
        let target = observedTarget.focusUTF16 == lower ? original.utf16Offset : selectionEnd
        native = PagedNativeNavigationSelection(utf16Offset: target, utf16Length: 0,
          affinity: observedTarget.affinity)
      } else { native = observedTarget }
      guard (extending ? native.anchorUTF16 == original.anchorUTF16 : native.utf16Length == 0) else {
        throw BoomError.stale("Visual movement lost its owned original anchor.")
      }
      if !extending, original.utf16Length > 0 {
        guard native.focusUTF16 == original.utf16Offset || native.focusUTF16 == selectionEnd else {
          throw BoomError.unavailable("Cocoa did not establish a complete selection-collapse endpoint.")
        }
      }
      if native.focusUTF16 == original.focusUTF16, native.utf16Offset == original.utf16Offset,
        native.utf16Length == original.utf16Length, native.affinity == original.affinity,
        (native.focusUTF16 == source.utf16Start && source.utf16Start > 0)
          || (native.focusUTF16 == windowEnd && windowEnd < source.projectedUTF16) {
        throw BoomError.unavailable("The projected edge has no observed native visual target beyond this window.")
      }
      try restore(); restored = true
      return (original, native)
    } catch {
      let originalError = error
      if entered, !restored {
        do { try restore() }
        catch { throw PagedNativeNavigationOwnerFailure(original: originalError, cleanup: error) }
      }
      throw originalError
    }
  }

  func requestGraphemeDeletion(forward: Bool, selection: PagedNativeNavigationSelection) throws {
    _ = try beginCapturedEdit(expected: nil, actionName: "Delete", reportFailure: true,
      groupID: input.activeView?.typedCharacterCommandGroupID,
      preparingOperation: { [self] _ in
        let target = try await input.session.sealedGraphemeBoundary(atUTF16: selection.focusUTF16, forward: forward)
        let range = PagedNativeNavigationSelection(utf16Offset: min(target, selection.focusUTF16),
          utf16Length: max(target, selection.focusUTF16) - min(target, selection.focusUTF16))
        return (.replacement(range, Data()), nil)
      })
  }

  private func beginOwnedNavigation(toUTF16 anchor: UInt64, selection: PagedNativeNavigationSelection,
    observed: PagedNativeSelectionObservation,
    resolvingSelection: (@MainActor () async throws -> PagedNativeNavigationSelection)? = nil) {
    precondition(!isNavigating && navigationTask == nil && commandTask == nil)
    isNavigating = true // synchronous input fence, before spawning the worker
    let startingFailureSerial = receivingFailureSerial
    var ownFailureRecorded = false
    let worker = Task<PagedTextWindow, Error> { [self] in
      let resolved = try await resolvingSelection?() ?? selection
      if resolvingSelection != nil,
        let reused = try input.reuseJoinedNavigationWindow(toUTF16: input.session.documentCoordinates().utf16Start,
          selection: resolved, observedSelection: observed) {
        try requireNavigationQueue(observed, deferredInput: true)
        return reused
      }
      let resolvedAnchor = resolvingSelection == nil ? anchor : (resolved.focusUTF16 > 4096 ? resolved.focusUTF16 - 4096 : 0)
      return try await navigateAdmitted(toUTF16: resolvedAnchor, selection: resolved, observed: observed,
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
      if !replayingRawKeys, unretainedCommandCount < UInt64.max { unretainedCommandCount += 1 }
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

  private func resumeQueuedInput() {
    guard phase == .idle, commandTask == nil, capturedEditTask == nil,
      !isNavigating, navigationTask == nil, !queue.isEmpty else { return }
    // Keep this existing task slot joinable while yielding between bounded
    // replay bursts. No timer or awaited task is substituted for delivery.
    commandTask = Task { [self] in
      await Task.yield()
      commandTask = nil
      pump()
    }
  }

  private func pump() {
    guard phase == .idle, commandTask == nil, !isNavigating, navigationTask == nil, !queue.isEmpty, !replayingRawKeys,
      !registeringGroup, !receivingTransition,
      let activeView = input.activeView, activeView.inputCommandIsClosed, !activeView.hasMarkedText(),
      !input.session.hasPendingHistoryCommand, input.firstRefusal == nil else { return }
    let pumpFailureSerial = receivingFailureSerial
    do {
      if case .rawKey = queue[0] {
        try replayOriginalKeys()
        guard !queue.isEmpty, phase == .idle, capturedEditTask == nil,
          !isNavigating, navigationTask == nil else { return }
        if case .rawKey = queue[0] { resumeQueuedInput(); return }
      }
      if case .sourceCommand(let command) = queue[0] {
        guard let view = input.activeView, command.window === view.window,
          command.window.firstResponder === view,
          command.replayLease == (try input.inputLease(for: view)) else {
          throw BoomError.stale("Deferred source input lost its original physical focus.")
        }
        // Reuse the actual lexical replay scope; later queue entries stay
        // owned until this source command's real publication/installation.
        replayingRawKeys = true
        defer {
          replayingRawKeys = false; replayInsertionCount = 0
          if phase == .idle, commandTask == nil, capturedEditTask == nil, !isNavigating { resumeQueuedInput() }
        }
        let selection = try input.currentDocumentSelection()
        switch command.action {
        case .linePrefix(let prefix):
          _ = try beginCapturedEdit(expected: nil, operation: .linePrefix(selection, prefix),
            actionName: "Format", reportFailure: true)
        case .documentCommand(let selector):
          try input.performQueuedDocumentCommand(selector)
        case .replacement(let bytes, let name):
          _ = try beginCapturedEdit(expected: nil, operation: .replacement(selection, bytes),
            actionName: name, reportFailure: true)
        }
        queue.removeFirst(); rawKeyBytes -= command.chargedBytes
        return
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
    let waitsForSource: Bool
    do { waitsForSource = try (phase == .publishing && keyNeedsJoinedSource(event, from: view)) }
    catch { PerformanceTrace.event("Editor.ManagedAdmission"); return false }
    guard !replayingRawKeys,
      waitsForSource || isNavigating || phase == .preparing || phase == .reconciling || phase == .hydrating
        || phase == .advancing || !queue.isEmpty else { return false }
    var retained = false
    let failureSerial = receivingFailureSerial
    do {
      try retainRawKey(event, from: view); retained = true
      if phase == .publishing { try replayOriginalKeys() }
    } catch {
      if !retained, unretainedRawKeyCount < UInt64.max { unretainedRawKeyCount += 1 }
      if !receivingFailureSerialExhausted, receivingFailureSerial == failureSerial { fail(error) }
      else { phase = .blocked }
    }
    return true
  }
  private func keyNeedsJoinedSource(_ event: NSEvent, from view: PagedNativeTextView) throws -> Bool {
    // Selectors are interpreted by AppKit and enter the same source-command
    // queue if needed. Only a literal insertion that needs a different source
    // window must wait before interpretation; display-edge proximity is not
    // character admission and cannot make ordinary typing await a disk ACK.
    let text = event.characters ?? ""
    let excluded: Bool
    switch event.keyCode {
    case 48, 53, 115, 116, 119, 121, 123, 124, 125, 126: excluded = true
    default: excluded = false
    }
    let inserting = !excluded
      && event.modifierFlags.intersection([.command, .control]).isEmpty
      && (!text.isEmpty && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        || event.keyCode == 36 || event.keyCode == 76)
    guard inserting else { return false }
    let selected = try input.currentDocumentSelection()
    if selected.utf16Length > UInt64(view.selectedRange().length) { return true }
    let replacement = event.keyCode == 36 || event.keyCode == 76 ? "\n" : text
    do { try input.session.canReplace(view.selectedRange(), with: replacement); return false }
    catch {
      if case BoomError.budget = error { return true }
      // A stale/malformed source callback belongs to its actual native
      // primitive, not a new permanent command/input refusal.
      PerformanceTrace.event("Editor.ManagedAdmission")
      return false
    }
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
    guard queue.contains(where: { if case .history = $0 { return false }; return true }) else { return }
    guard let transition = input.lastReplayTransition else {
      throw BoomError.stale("Deferred native keys have no actual focus-preserving mount receipt.")
    }
    // The queue stays bounded. Only this owner's actual synchronous mount can
    // update replay custody; original event and original source identity stay.
    // Validate the complete bounded queue before changing any replay lease.
    for item in queue {
      if case .rawKey(let key) = item { _ = try transition.rebase(key.replayLease) }
      else if case .sourceCommand(let command) = item { _ = try transition.rebase(command.replayLease) }
    }
    for index in queue.indices {
      if case .rawKey(var key) = queue[index] {
        key.replayLease = try transition.rebase(key.replayLease)
        queue[index] = .rawKey(key)
      } else if case .sourceCommand(var command) = queue[index] {
        command.replayLease = try transition.rebase(command.replayLease)
        queue[index] = .sourceCommand(command)
      }
    }
  }

  private func replayOriginalKeys() throws {
    guard phase != .closed else { return }
    replayingRawKeys = true
    defer { replayingRawKeys = false; replayInsertionCount = 0; currentRawKeyAwaitingSource = false }
    var delivered = 0
    while delivered < Self.maximumReplayBurst,
      let first = queue.first, case .rawKey(let next) = first {
      replayInsertionCount = 0; currentRawKeyAwaitingSource = false
      guard let view = input.activeView else {
        throw BoomError.stale("Deferred native input lost its physical client.")
      }
      guard next.window === view.window, next.window.firstResponder === view,
        next.replayLease == (try input.inputLease(for: view)) else {
        throw BoomError.stale("Native focus or keyboard source changed before deferred input replay.")
      }
      if phase == .publishing, try keyNeedsJoinedSource(next.event, from: view) { return }
      let beforeGeneration = input.session.generation
      let beforeSelectionEpoch = view.inputBinding?.selectionEpoch
      let originalRefusal = view.didRejectInput
      var dispatchRefusal: Error?
      view.didRejectInput = { error in
        if dispatchRefusal == nil { dispatchRefusal = error }
        originalRefusal?(error)
      }
      view.keyDown(with: next.event)
      view.didRejectInput = originalRefusal
      if let dispatchRefusal, input.session.generation == beforeGeneration,
        view.inputBinding?.selectionEpoch == beforeSelectionEpoch,
        replayInsertionCount == 0, !currentRawKeyAwaitingSource {
        // No primitive or interpreted successor consumed this event. Retain
        // it at its exact position; nil historical latches are not delivery.
        throw dispatchRefusal
      }
      if let mutation = view.boundedStorage.mutationFailure { throw mutation }
      if phase == .blocked, input.session.generation == beforeGeneration,
        view.inputBinding?.selectionEpoch == beforeSelectionEpoch,
        replayInsertionCount == 0, !currentRawKeyAwaitingSource {
        throw firstFailure ?? BoomError.stale("The original input has no completed native receiver.")
      }
      if currentRawKeyAwaitingSource { return }
      // Only the completed primitive/command or its retained ordered successor
      // owns delivery. A new structural task may require the same original key.
      queue.removeFirst(); queuedRawKeyCount -= 1; rawKeyBytes -= next.chargedBytes
      delivered += 1
      if phase == .blocked { throw firstFailure ?? BoomError.stale("A native replay command lost its source owner.") }
      if (phase != .idle && phase != .publishing) || isNavigating || capturedEditTask != nil { return }
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
      queuedDirections + queuedRawKeyCount + queue.reduce(0, { count, item in
        if case .sourceCommand = item { return count + 1 }; return count
      }) == queue.count,
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
      } else if case .sourceCommand(let command) = item {
        guard command.window === view.window, command.replayLease == lease else {
          throw BoomError.stale("Receiving disposition cannot redirect the retained source input.")
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
      if navigationTask == nil, commandTask == nil, capturedEditTask == nil { break }
      if let task = navigationTask {
        if case .failure(let error) = await task.result, originalTaskRefusal == nil { originalTaskRefusal = error }
      }
      if let task = commandTask { await task.value }
      if let task = capturedEditTask {
        if case .failure(let error) = await task.result, originalTaskRefusal == nil { originalTaskRefusal = error }
      }
    }
    if let firstFailure { throw firstFailure }
    if navigationTask != nil || commandTask != nil || capturedEditTask != nil {
      let bound = BoomError.budget("New native requests kept the actual command lane active beyond its bounded join.")
      if let originalTaskRefusal { throw PagedNativeNavigationOwnerFailure(original: originalTaskRefusal, cleanup: bound) }
      throw bound
    }
    if let originalTaskRefusal { throw originalTaskRefusal }
    if phase == .closed { try requireJoinedClose(); return }
    try requireCommandQuiescence()
  }

  private func requireCommandQuiescence(allowDeferredInput: Bool = false) throws {
    let orderedReplay = allowDeferredInput && replayingRawKeys
    guard phase == .idle, commandTask == nil, capturedEditTask == nil, !isNavigating, navigationTask == nil,
      orderedReplay || (queue.isEmpty && queuedDirections == 0 && queuedRawKeyCount == 0 && rawKeyBytes == 0),
      orderedReplay || (!replayingRawKeys && replayInsertionCount == 0),
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
