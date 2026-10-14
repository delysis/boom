import AppKit
import BoomCore
import Foundation

/// Foundation owns the chronological stack. This same owner prepares its
/// bounded native projection before entering the synchronous SDK invocation.
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
    switch direction { case .undo: super.undoNestedGroup(); case .redo: super.redo() }
  }
}

/// One actual SDK target. Its compact display seed owns text and exact source
/// origins, never a second scalar table or complete manuscript. The real SDK
/// inverse captures the live opposite state before advancement.
@MainActor private final class PagedNativeUndoEntry: NSObject {
  let ownerID: UUID
  let entryID = UUID()
  let ordinal: UInt64
  let groupID: UUID
  let direction: PagedNativeHistoryHandle.Direction
  let actionName: String
  let snapshot: PagedNativeLogicalSnapshot
  let cursor: PagedNativeLogicalCursor
  let seed: PagedNativeLogicalWindowSeed?
  var firstSequence: UInt64?
  var lastSequence: UInt64?
  var lastSourceID: UUID?
  var openingInverse: PagedNativeUndoEntry?
  init(ownerID: UUID, ordinal: UInt64, groupID: UUID,
    direction: PagedNativeHistoryHandle.Direction, actionName: String,
    snapshot: PagedNativeLogicalSnapshot, cursor: PagedNativeLogicalCursor,
    seed: PagedNativeLogicalWindowSeed?) {
    self.ownerID = ownerID; self.ordinal = ordinal; self.groupID = groupID
    self.direction = direction; self.actionName = actionName
    self.snapshot = snapshot; self.cursor = cursor; self.seed = seed
  }
}

@MainActor final class PagedNativeUndoOwner {
  private enum Phase: Equatable { case idle, hydrating, preparing, readingColdHistory, readingBoundary, advancing, closed }
  private struct RawKey {
    let event: NSEvent
    let originalLease: PagedNativeReplayInputLease
    var replayLease: PagedNativeReplayInputLease
    let window: NSWindow
    let chargedBytes: Int
  }
  private struct HistoryRequest {
    let id = UUID()
    let direction: PagedNativeHistoryHandle.Direction
  }
  private enum QueuedInput {
    case history(HistoryRequest)
    case rawKey(RawKey)
    case sourceCommand(SourceCommand)
  }
  private enum SourceAction {
    case documentCommand(Selector)
    case replacement(Data, String, UUID)
    case linePrefix(String)
    case wrapping(String, String, Bool, String)
    case pointerSelection(PointerSelection)
  }
  /// One real pointer intent in the existing chronological input queue. The
  /// display may paint it immediately; only its ordered delivery changes Input.
  private final class PointerSelection {
    let id = UUID()
    let original: PagedNativeLogicalSnapshot
    var source: PagedNativeLogicalSnapshot
    var selection: PagedNativeNavigationSelection
    let extending: Bool
    var complete = false
    var failure: Error?
    private var terminal: (@MainActor (UUID) -> Void)?
    init(source: PagedNativeLogicalSnapshot, selection: PagedNativeNavigationSelection, extending: Bool,
      installed: @escaping @MainActor (UUID) -> Void) {
      original = source; self.source = source; self.selection = selection; self.extending = extending; terminal = installed
    }
    func settle() {
      let delivered = terminal; terminal = nil
      delivered?(id)
    }
  }
  private struct SourceCommand {
    let action: SourceAction
    var replayLease: PagedNativeReplayInputLease
    let window: NSWindow
    let chargedBytes: Int
  }
  static let maximumQueuedCommands = 64
  static let maximumRawKeyBytes = 262_144
  static let maximumQueuedRawKeys = maximumRawKeyBytes / 512
  static let maximumQueuedEntries = maximumQueuedRawKeys + maximumQueuedCommands + 32
  static let maximumKeyUTF16 = 256
  private static let maximumReplayBurst = 4
  private static let entryKey = UndoManager.UserInfoKey(rawValue: "bloom.paged.native-entry.v1")

  let input: PagedNativeInputOwner
  private let gatedManager = PagedNativeGatedUndoManager()
  private var phase = Phase.idle
  private var nextOrdinal: UInt64 = 0
  // References to actual SDK targets, not a separately advanced history stack.
  private var undoEntries: [PagedNativeUndoEntry] = []
  private var redoEntries: [PagedNativeUndoEntry] = []
  private var activeGroup: UUID?
  private var expectedEntry: PagedNativeUndoEntry?
  private var inverseEntry: PagedNativeUndoEntry?
  private var hydrationExpected: PagedNativeUndoEntry?
  private var historyAtCommandClose: PagedNativeHistoryHandle.Direction?
  private var adoptingSource: (() -> Void)?
  private var registeringGroup = false
  private var groupSubscription: PagedNativeGroupSubscription?
  private var queue: [QueuedInput] = []
  // Superseded original events remain bounded diagnostics; they are never
  // reinterpreted at a newer caret and never fence later ordinary input.
  private var refusedInput: [QueuedInput] = []
  private var refusedInputBytes = 0
  private var refusedDirections = 0
  private(set) var refusedInputFailure: Error?
  var retainedRefusedInputCount: Int { refusedInput.count }
  var retainedInputBytes: Int { rawKeyBytes + refusedInputBytes }
  private var relatedReadObservation: PagedNativeSelectionObservation?
  private var replayObservation: PagedNativeSelectionObservation?
  private var capturedEditObservation: PagedNativeSelectionObservation?
  private var queuedDirections = 0
  private var queuedPointerCount = 0
  private(set) var queuedRawKeyCount = 0
  private var rawKeyBytes = 0
  private var replayingRawKeys = false
  private var replayInsertionCount = 0
  private var currentRawKeyAwaitingSource = false
  private var commandTask: Task<Void, Error>?
  private var navigationTask: Task<PagedNativeLogicalWindow, Error>?
  private var capturedEditTask: Task<PagedNativeLogicalSnapshot, Error>?
  private var lastCommandRefusal: Error?
  private var capturedActionName: String?
  private(set) var isNavigating = false
  private(set) var firstFailure: Error?
  private(set) var unregisteredGroup: PagedNativeGroupClosureReceipt?
  private(set) var unretainedRawKeyCount: UInt64 = 0
  private(set) var unretainedCommandCount: UInt64 = 0
  var didFail: ((Error) -> Void)?
  var mountView: ((PagedNativeTextView, PagedNativeTextView) throws -> Void)?

  var manager: UndoManager { gatedManager }
  var hasPendingCommand: Bool {
    // A pure preload, agent preparation or clipboard export must not prevent
    // contained clicks or resident recentering. Their real tasks still join
    // before close; only a related source transition owns ordered key input.
    (phase != .idle && phase != .closed) || !queue.isEmpty || isNavigating || historyAtCommandClose != nil
  }

  init(input: PagedNativeInputOwner) throws {
    guard input.commandOwner == nil else {
      throw BoomError.denied("This native session already has its Foundation owner.")
    }
    self.input = input
    gatedManager.groupsByEvent = false
    gatedManager.levelsOfUndo = PagedRootHistory.maximumEntries
    undoEntries.reserveCapacity(PagedRootHistory.maximumEntries)
    redoEntries.reserveCapacity(PagedRootHistory.maximumEntries)
    queue.reserveCapacity(Self.maximumQueuedCommands)
    groupSubscription = try input.session.registerNativeGroupSubscription(ownerID: input.ownerID,
      onClose: { [weak self] subscription, receipt in
        self?.registerClosedGroup(receipt, subscription: subscription)
      })
    gatedManager.requestHistory = { [weak self] direction in self?.request(direction) }
    input.commandOwner = self
    if input.session.canonicalOpening != nil { try hydrateOpening() }
    guard let subscription = groupSubscription else { throw BoomError.invalid("The actual Foundation subscription is missing.") }
    try input.session.setLogicalHistoryCapture(subscription, ownerID: input.ownerID) { [weak self] in
      guard let self else { throw BoomError.stale("The native saver lost its actual Foundation owner.") }
      return try self.captureLogicalHistory()
    }
    try input.session.setPointerSpliceObservation(subscription, ownerID: input.ownerID,
      needed: { [weak self] in (self?.queuedPointerCount ?? 0) > 0 },
      observe: { [weak self] before, after, start, removed, inserted in
        self?.mapQueuedPointers(before: before, after: after, start: start, removed: removed, inserted: inserted)
      })
  }

  private func validate(_ snapshot: PagedNativeLogicalSnapshot,
    cursor: PagedNativeLogicalCursor) throws {
    guard snapshot.sessionID == input.session.sessionID,
      snapshot.engineIncarnation == input.session.engineIncarnation,
      snapshot.sourceRevision.ownerID == input.session.sourceBaseRevision.ownerID,
      snapshot.sourceRevision.documentID == input.session.sourceBaseRevision.documentID,
      cursor.byteOffset <= snapshot.summary.bytes, cursor.utf16Offset <= snapshot.summary.utf16,
      cursor.selectionLengthUTF16 <= snapshot.summary.utf16 - cursor.utf16Offset else {
      throw BoomError.stale("The logical history target belongs to another native source.")
    }
  }

  private func makeEntry(snapshot: PagedNativeLogicalSnapshot, cursor: PagedNativeLogicalCursor,
    seed: PagedNativeLogicalWindowSeed?, groupID: UUID,
    direction: PagedNativeHistoryHandle.Direction, actionName: String) throws -> PagedNativeUndoEntry {
    try validate(snapshot, cursor: cursor)
    let next = nextOrdinal.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Native history identity is exhausted.") }
    nextOrdinal = next.partialValue
    return PagedNativeUndoEntry(ownerID: input.ownerID, ordinal: nextOrdinal, groupID: groupID,
      direction: direction, actionName: actionName, snapshot: snapshot, cursor: cursor, seed: seed)
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

  private func foundationProjectionIsExact() -> Bool {
    guard gatedManager.groupingLevel == 0,
      undoEntries.count + redoEntries.count <= PagedRootHistory.maximumEntries,
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

  private func top(_ direction: PagedNativeHistoryHandle.Direction) throws -> PagedNativeUndoEntry? {
    guard foundationProjectionIsExact() else {
      throw BoomError.stale("The actual Foundation targets differ from their native owner.")
    }
    guard direction == .undo ? gatedManager.canUndo : gatedManager.canRedo else { return nil }
    let value = direction == .undo ? gatedManager.undoActionUserInfoValue(forKey: Self.entryKey)
      : gatedManager.redoActionUserInfoValue(forKey: Self.entryKey)
    guard let entry = value as? PagedNativeUndoEntry, entry.ownerID == input.ownerID,
      entry.direction == direction else {
      throw BoomError.stale("The actual Foundation top is not this native history target.")
    }
    try validate(entry.snapshot, cursor: entry.cursor)
    return entry
  }

  private func registerClosedGroup(_ receipt: PagedNativeGroupClosureReceipt,
    subscription: PagedNativeGroupSubscription) {
    guard phase != .closed, receipt.hasEffectiveSourceChange else { return }
    registeringGroup = true
    defer { registeringGroup = false }
    do {
      guard subscription === groupSubscription, subscription.ownerID == input.ownerID,
        receipt.sessionID == input.session.sessionID, receipt.arenaID == input.session.arenaID,
        receipt.lastSequence == input.session.generation, phase != .advancing,
        phase != .hydrating, foundationProjectionIsExact(),
        receipt.snapshot.isSame(try input.session.captureLogicalState().source) else {
        throw BoomError.stale("A native group closure differs from its actual logical source.")
      }
      try validate(receipt.beforeSnapshot, cursor: receipt.beforeCursor)
      try validate(receipt.snapshot, cursor: receipt.cursor)
      if activeGroup == receipt.effectiveGroupID, let previous = undoEntries.last,
        previous.groupID == receipt.effectiveGroupID, previous.direction == .undo,
        let covered = previous.lastSequence, covered < receipt.lastSequence,
        previous.lastSourceID == receipt.beforeSnapshot.rootID
          || previous.snapshot.isSame(receipt.beforeSnapshot) {
        // Continued typing keeps the first before-state in its actual SDK slot.
        previous.lastSequence = receipt.lastSequence
        previous.lastSourceID = receipt.snapshot.rootID
        return
      }
      let entry = try makeEntry(snapshot: receipt.beforeSnapshot, cursor: receipt.beforeCursor,
        seed: receipt.beforeSeed, groupID: receipt.effectiveGroupID, direction: .undo,
        actionName: capturedActionName ?? "Edit")
      entry.firstSequence = receipt.firstSequence; entry.lastSequence = receipt.lastSequence
      entry.lastSourceID = receipt.snapshot.rootID
      gatedManager.beginUndoGrouping(); register(entry); gatedManager.endUndoGrouping()
      activeGroup = receipt.effectiveGroupID
      guard foundationProjectionIsExact() else {
        throw BoomError.stale("The logical group did not join its actual Foundation slot.")
      }
    } catch {
      if unregisteredGroup == nil { unregisteredGroup = receipt }
      failAcceptedSource(error)
    }
  }

  /// A DTO of actual SDK targets for the existing asynchronous saver. A storage
  /// ACK never installs it back into Foundation or replaces the live arena.
  func captureLogicalHistory() throws -> PagedNativeLogicalHistoryProjection {
    guard phase != .closed, phase != .advancing, phase != .hydrating,
      expectedEntry == nil, inverseEntry == nil, adoptingSource == nil,
      foundationProjectionIsExact(), unregisteredGroup == nil else {
      throw BoomError.stale("Saving cannot capture a half-advanced Foundation invocation.")
    }
    let source = try input.session.captureLogicalState()
    let cursor = try input.session.currentLogicalCursor(for: input.currentDocumentSelection())
    try validate(source.source, cursor: cursor)
    return PagedNativeLogicalHistoryProjection(snapshot: source.source, cursor: cursor,
      undo: undoEntries.map { PagedNativeLogicalHistoryEntry(snapshot: $0.snapshot, cursor: $0.cursor, groupID: $0.groupID) },
      redo: redoEntries.map { PagedNativeLogicalHistoryEntry(snapshot: $0.snapshot, cursor: $0.cursor, groupID: $0.groupID) },
      activeGroup: activeGroup, generation: source.generation)
  }

  private func hydrateOpening() throws {
    guard input.canonicalActivationPending, let subscription = groupSubscription,
      undoEntries.isEmpty, redoEntries.isEmpty, phase == .idle else {
      throw BoomError.stale("Opening history requires its unexposed native client.")
    }
    let opening = try input.session.logicalOpeningHistory()
    guard opening.undo.count + opening.redo.count <= PagedRootHistory.maximumEntries else {
      throw BoomError.budget("Opening history exceeds its native bound.")
    }
    var registration: [PagedNativeUndoEntry] = []
    var inversePops: [PagedNativeUndoEntry] = []
    registration.reserveCapacity(PagedRootHistory.maximumEntries)
    inversePops.reserveCapacity(PagedRootHistory.maximumEntries)
    for target in opening.undo {
      registration.append(try makeEntry(snapshot: target.snapshot, cursor: target.cursor,
        seed: nil, groupID: target.groupID, direction: .undo, actionName: "Edit"))
    }
    for target in opening.redo.reversed() {
      let entry = try makeEntry(snapshot: opening.snapshot, cursor: opening.cursor,
        seed: nil, groupID: target.groupID, direction: .undo, actionName: "Edit")
      entry.openingInverse = try makeEntry(snapshot: target.snapshot, cursor: target.cursor,
        seed: nil, groupID: target.groupID, direction: .redo, actionName: "Edit")
      registration.append(entry); inversePops.append(entry)
    }
    try input.session.withCanonicalOpening(subscription, ownerID: input.ownerID) { [self] in
      phase = .hydrating
      for entry in registration {
        gatedManager.beginUndoGrouping(); register(entry); gatedManager.endUndoGrouping()
      }
      for entry in inversePops.reversed() {
        hydrationExpected = entry; gatedManager.advance(.undo); hydrationExpected = nil
        entry.openingInverse = nil
      }
      precondition(foundationProjectionIsExact(), "Opening history lost its actual SDK targets.")
      activeGroup = opening.activeGroup
      input.completeCanonicalOpening(commandOwner: self)
    }
    phase = .idle
    try input.setDocumentSelection(selection(opening.cursor))
  }

  private func selection(_ cursor: PagedNativeLogicalCursor) -> PagedNativeNavigationSelection {
    PagedNativeNavigationSelection(utf16Offset: cursor.utf16Offset,
      utf16Length: cursor.selectionLengthUTF16, focusAtEnd: cursor.focusAtEnd, affinity: cursor.affinity)
  }

  private func inverse(for entry: PagedNativeUndoEntry) throws -> PagedNativeUndoEntry {
    let source = try input.session.captureLogicalState()
    let cursor = try input.session.currentLogicalCursor(for: input.currentDocumentSelection())
    let focus = cursor.selection.focusUTF16
    let window = input.session.logicalWindow
    let seed = focus >= window.start.utf16 && focus - window.start.utf16 <= window.summary.utf16
      ? try window.makeSeed(localFocusUTF16: Int(focus - window.start.utf16)) : nil
    return try makeEntry(snapshot: source.source, cursor: cursor,
      seed: seed, groupID: entry.groupID,
      direction: entry.direction == .undo ? .redo : .undo, actionName: entry.actionName)
  }

  private func advance(_ entry: PagedNativeUndoEntry,
    ticket: PagedNativeNavigationInstallationTicket,
    observed: PagedNativeSelectionObservation) throws {
    guard try top(entry.direction) === entry, try input.observeSelection() == observed,
      let mount = mountView else {
      throw BoomError.stale("Prepared logical Undo lost its actual SDK or physical target.")
    }
    let opposite = try inverse(for: entry)
    try input.stageNavigation(ticket, observedSelection: observed)
    expectedEntry = entry; inverseEntry = opposite; phase = .advancing
    defer { expectedEntry = nil; inverseEntry = nil; adoptingSource = nil }
    _ = try input.withStagedNavigationInstallation(ticket,
      advancingFoundation: { [self] adopt in
        withoutActuallyEscaping(adopt) { temporaryAdopt in
          adoptingSource = temporaryAdopt; gatedManager.advance(entry.direction); adoptingSource = nil
        }
      }, mounted: mount)
    expectedEntry = nil; inverseEntry = nil; adoptingSource = nil
    activeGroup = nil; phase = .idle
    guard foundationProjectionIsExact() else {
      throw BoomError.stale("Logical Undo did not join its real synchronous SDK inverse.")
    }
    // Capture saving only AFTER the complete source and SDK inverse invocation.
    input.session.requestCommit()
  }

  private func consumeFoundationEntry(_ entry: PagedNativeUndoEntry) {
    if phase == .hydrating {
      precondition(hydrationExpected === entry && gatedManager.isUndoing && entry.openingInverse != nil)
      precondition(undoEntries.last === entry)
      _ = undoEntries.removeLast(); register(entry.openingInverse!)
      return
    }
    precondition(phase == .advancing && expectedEntry === entry && inverseEntry != nil && adoptingSource != nil,
      "Only the preadmitted SDK handler may consume this physical source.")
    precondition(entry.direction == .undo ? gatedManager.isUndoing : gatedManager.isRedoing)
    if entry.direction == .undo { precondition(undoEntries.last === entry); _ = undoEntries.removeLast() }
    else { precondition(redoEntries.last === entry); _ = redoEntries.removeLast() }
    adoptingSource!()
    register(inverseEntry!)
    activeGroup = nil
  }

  func request(_ direction: PagedNativeHistoryHandle.Direction) {
    guard phase != .closed else { return }
    if phase == .idle, queue.isEmpty, !replayingRawKeys,
      let view = input.activeView, !view.inputCommandIsClosed {
      // The current Cocoa command must close before an SDK pop. This one
      // synchronous selector carries no raw payload or cold-read escrow.
      guard historyAtCommandClose == nil else {
        reportRefusal(BoomError.stale("This outer native command already owns its history selector."))
        return
      }
      historyAtCommandClose = direction
      return
    }
    // Bounded diagnostic custody is not an input permission. A resident SDK
    // target needs neither a queue slot nor the canceled reader's task slot.
    do { if try restoreResidentHistory(direction) { return } }
    catch {
      if firstFailure == nil { reportRefusal(error) }
      lastCommandRefusal = error
      return
    }
    guard queue.count + refusedInput.count < Self.maximumQueuedEntries,
      queuedDirections + refusedDirections < Self.maximumQueuedCommands else {
      if unretainedCommandCount < UInt64.max { unretainedCommandCount += 1 }
      reportRefusal(BoomError.budget("The bounded native history request queue is full."))
      return
    }
    let request = HistoryRequest(direction: direction)
    if replayingRawKeys {
      queue.insert(.history(request), at: 1 + replayInsertionCount); replayInsertionCount += 1
    }
    else { queue.append(.history(request)) }
    queuedDirections += 1
    pump()
  }

  private func restoreResidentHistory(_ direction: PagedNativeHistoryHandle.Direction) throws -> Bool {
    guard phase == .idle, queue.isEmpty, !replayingRawKeys, !registeringGroup,
      firstFailure == nil, let view = input.activeView,
      view.inputCommandIsClosed, !view.hasMarkedText() else { return false }
    _ = try input.session.closeNativeGroup()
    guard let entry = try top(direction) else { return true }
    guard let seed = entry.seed, seed.containsFocusUTF16(entry.cursor.selection.focusUTF16) else { return false }
    let observed = try input.observeSelection()
    guard observed.inputLease.isFirstResponder, observed.inputLease.isKeyWindow else {
      throw BoomError.stale("Undo requires its actual focused document client.")
    }
    let ticket = try input.session.prepareResidentLogicalRestore(entry.snapshot,
      seed: seed, selection: entry.cursor, owner: input)
    do { try advance(entry, ticket: ticket, observed: observed) }
    catch {
      let original = error
      if ticket.isAwaitingAdoption {
        do { try input.cancelNavigationStage(ticket) }
        catch { throw PagedNativeNavigationOwnerFailure(original: original, cleanup: error) }
      } else if ticket.wasConsumed { failAcceptedSource(original) }
      if phase == .advancing { phase = .idle }
      throw original
    }
    return true
  }

  func inputCommandDidClose() {
    guard phase != .closed, input.activeView?.inputCommandIsClosed == true else { return }
    if let direction = historyAtCommandClose {
      historyAtCommandClose = nil; request(direction)
    }
    pump()
  }

  private func consumeHistoryHead(_ request: HistoryRequest) {
    precondition(!queue.isEmpty)
    guard case .history(let head) = queue[0], head.id == request.id else {
      preconditionFailure("The logical history operation lost its original chronological request.")
    }
    queue.removeFirst(); queuedDirections -= 1
  }

  private func pump() {
    guard phase == .idle, !registeringGroup, !replayingRawKeys,
      firstFailure == nil,
      let view = input.activeView, view.inputCommandIsClosed, !view.hasMarkedText() else { return }
    do {
      if queue.isEmpty { try finishOrderedInput(); return }
      // Native mouse tracking also defers queued keys until the button is up.
      // Keep this bounded display gesture responsive without changing the
      // actual selection or canceling its preceding entered navigation read.
      if queuedPointerCount > 0, queue.contains(where: { if case .sourceCommand(let command) = $0,
        case .pointerSelection(let pointer) = command.action { return !pointer.complete }; return false }) { return }
      if case .rawKey? = queue.first {
        try replayOriginalKeys()
        if case .rawKey? = queue.first { resumeQueuedInput(); return }
      }
      if case .sourceCommand(let command)? = queue.first {
        // Preserve its original position until the actual preparation task
        // leaves its one slot; never dispose queued input as an unrelated
        // task-capacity refusal.
        guard commandTask == nil, capturedEditTask == nil, navigationTask == nil else { return }
        guard command.window === view.window, command.window.firstResponder === view,
          command.replayLease == (try input.inputLease(for: view)) else {
          throw BoomError.stale("Ordered document input no longer owns its actual focus or source.")
        }
        replayingRawKeys = true; replayInsertionCount = 0
        defer { replayingRawKeys = false; replayInsertionCount = 0 }
        switch command.action {
        case .documentCommand(let selector): try input.performQueuedDocumentCommand(selector)
        case .replacement(let bytes, let name, let groupID):
          try requestDocumentReplacement(input.currentDocumentSelection(), replacement: bytes,
            actionName: name, groupID: groupID)
        case .linePrefix(let prefix): try requestLinePrefix(prefix, from: view)
        case .wrapping(let prefix, let suffix, let toggles, let name):
          try requestDocumentWrapping(input.currentDocumentSelection(), prefix: prefix,
            suffix: suffix, toggles: toggles, actionName: name)
        case .pointerSelection(let pointer): try deliverPointer(pointer)
        }
        removeSourceCommandHead(command)
        if phase == .idle {
          try finishOrderedInput(after: command.replayLease)
          resumeQueuedInput()
        }
        return
      }
      guard case .history(let request)? = queue.first else { return }
      let direction = request.direction
      phase = .preparing
      _ = try input.session.closeNativeGroup()
      guard let entry = try top(direction) else {
        phase = .idle; consumeHistoryHead(request); pump(); return
      }
      let observed = try input.observeSelection()
      guard observed.inputLease.isFirstResponder, observed.inputLease.isKeyWindow else {
        throw BoomError.stale("Undo requires its actual focused document client.")
      }
      if let seed = entry.seed, seed.containsFocusUTF16(entry.cursor.selection.focusUTF16) {
        let ticket = try input.session.prepareResidentLogicalRestore(entry.snapshot,
          seed: seed, selection: entry.cursor, owner: input)
        do { try advance(entry, ticket: ticket, observed: observed) }
        catch {
          let original = error
          if ticket.isAwaitingAdoption {
            do { try input.cancelNavigationStage(ticket) }
            catch { throw PagedNativeNavigationOwnerFailure(original: original, cleanup: error) }
          } else if ticket.wasConsumed { failAcceptedSource(original) }
          throw original
        }
        consumeHistoryHead(request)
        try transferRawInputAfterMount()
        resumeQueuedInput()
        return
      }
      // Only cold history needs asynchronous preparation. Normal resident
      // Undo above completes in this event, independently of the saver.
      guard commandTask == nil, navigationTask == nil else { phase = .idle; return }
      let read = try input.session.captureLogicalRead()
      phase = .readingColdHistory; relatedReadObservation = observed
      let task = Task<Void, Error> { [self] in
        var prepared: PagedNativeNavigationInstallationTicket?
        var consumed = false
        defer {
          commandTask = nil
          if relatedReadObservation == observed { relatedReadObservation = nil }
          if phase == .readingColdHistory { phase = .idle }
          if phase != .closed { pump() }
        }
        do {
          let ticket = try await input.session.prepareLogicalRestore(entry.snapshot,
            seed: nil, selection: entry.cursor, owner: input)
          prepared = ticket
          try Task.checkCancellation()
          try input.session.admitLogicalRead(read)
          guard try top(direction) === entry, try input.observeSelection() == observed,
            phase == .readingColdHistory else {
            throw BoomError.stale("Cold Undo no longer owns its original source, request or physical focus.")
          }
          try advance(entry, ticket: ticket, observed: observed)
          consumed = true
          consumeHistoryHead(request)
          relatedReadObservation = nil
          try transferRawInputAfterMount()
          try replayOriginalKeys()
        } catch {
          let original = error
          if let prepared, prepared.isAwaitingAdoption {
            do { try input.cancelNavigationStage(prepared) }
            catch {
              let retained = PagedNativeNavigationOwnerFailure(original: original, cleanup: error)
              failAcceptedSource(retained); throw retained
            }
          }
          if prepared?.wasConsumed == true || consumed {
            failAcceptedSource(original)
          } else {
            // The failed read did not pop Foundation or alter source. Complete
            // this request as a refusal, then deliver its retained later keys
            // on the original client, never on a guessed history root.
            if case .history(let head)? = queue.first, head.id == request.id { consumeHistoryHead(request) }
            phase = .idle
            reportRefusal(original)
            if relatedReadObservation != observed {
              // Selection ingress already canceled this exact read and
              // preserved its old events. New input owns its newer caret.
            } else if input.session.isCurrent(read), (try? input.observeSelection()) == observed {
              replayObservation = observed
              do { try replayOriginalKeys() }
              catch {
                if input.firstRefusal != nil || input.activeView?.boundedStorage.mutationFailure != nil {
                  failAcceptedSource(PagedNativeNavigationOwnerFailure(original: original, cleanup: error))
                } else { preserveUnreplayableInput(error) }
              }
            } else { preserveUnreplayableInput(original) }
          }
          if lastCommandRefusal == nil { lastCommandRefusal = original }
          throw original
        }
      }
      commandTask = task
    } catch {
      let original = error
      if phase != .closed { phase = .idle }
      if case .history(let request)? = queue.first { consumeHistoryHead(request) }
      else if case .sourceCommand(let command)? = queue.first {
        removeSourceCommandHead(command, refusing: true)
      }
      if firstFailure == nil { reportRefusal(original) }
      else { didFail?(original) }
      if case .rawKey? = queue.first, firstFailure == nil { preserveUnreplayableInput(original) }
      lastCommandRefusal = original
    }
  }

  /// Only genuinely related cold-history/character/boundary reads retain raw
  /// keys. A saver or agent operation never intercepts ordinary native input.
  func interceptRawKey(_ event: NSEvent, from view: PagedNativeTextView) -> Bool {
    guard phase != .closed else { return true }
    inputSelectionDidChange()
    guard !replayingRawKeys,
      phase == .readingColdHistory || phase == .readingBoundary || !queue.isEmpty else { return false }
    do { try retainRawKey(event, from: view) }
    catch {
      if unretainedRawKeyCount < UInt64.max { unretainedRawKeyCount += 1 }
      // This original event was not retained. Cancel only the unadopted
      // related read, preserve its earlier queue, and let the actual current
      // native client receive this event once.
      relatedReadObservation = nil
      commandTask?.cancel(); navigationTask?.cancel()
      if capturedEditObservation != nil { capturedEditTask?.cancel(); capturedEditObservation = nil }
      phase = .idle; isNavigating = false
      preserveUnreplayableInput(error)
      lastCommandRefusal = error
      reportRefusal(error)
      return false
    }
    return true
  }

  private func retainRawKey(_ event: NSEvent, from view: PagedNativeTextView) throws {
    guard event.type == .keyDown, view === input.activeView,
      let window = view.window, window.firstResponder === view else {
      throw BoomError.stale("A retained cold-history key belongs to another native focus.")
    }
    let text = event.characters ?? "", ignored = event.charactersIgnoringModifiers ?? ""
    guard text.utf16.count <= Self.maximumKeyUTF16, ignored.utf16.count <= Self.maximumKeyUTF16 else {
      throw BoomError.budget("This original key exceeds its bounded cold-history custody.")
    }
    let charge = text.utf8.count + ignored.utf8.count + 512
    guard queue.count + refusedInput.count < Self.maximumQueuedEntries,
      queuedRawKeyCount + refusedInput.filter({ if case .rawKey = $0 { return true }; return false }).count < Self.maximumQueuedRawKeys,
      charge <= Self.maximumRawKeyBytes - retainedInputBytes else {
      throw BoomError.budget("Cold-history input custody is full; the original event was not retained.")
    }
    let lease = try input.inputLease(for: view)
    if replayObservation == nil { replayObservation = try input.observeSelection() }
    queue.append(.rawKey(RawKey(event: event, originalLease: lease, replayLease: lease,
      window: window, chargedBytes: charge)))
    queuedRawKeyCount += 1; rawKeyBytes += charge
  }

  private func transferRawInputAfterMount() throws {
    guard queue.contains(where: { if case .history = $0 { return false }; return true }) else { return }
    guard let transition = input.lastReplayTransition else {
      throw BoomError.stale("Original cold-history keys have no actual focus-preserving mount.")
    }
    for item in queue {
      if case .rawKey(let key) = item { _ = try transition.rebase(key.replayLease) }
      else if case .sourceCommand(let command) = item { _ = try transition.rebase(command.replayLease) }
    }
    for index in queue.indices {
      if case .rawKey(var key) = queue[index] {
        key.replayLease = try transition.rebase(key.replayLease); queue[index] = .rawKey(key)
      } else if case .sourceCommand(var command) = queue[index] {
        command.replayLease = try transition.rebase(command.replayLease); queue[index] = .sourceCommand(command)
      }
    }
    replayObservation = try input.observeSelection()
  }

  /// Only a just-delivered chronological command/key supplies this lease.
  /// Its real mount rebases later input; a neutral command must retain exact
  /// physical focus/keyboard ownership before advancing selection observation.
  private func finishOrderedInput(after delivered: PagedNativeReplayInputLease? = nil) throws {
    if let delivered, !queue.isEmpty {
      if input.activeIdentity != delivered.identity {
        try transferRawInputAfterMount()
      } else {
        guard let view = input.activeView, try input.inputLease(for: view) == delivered else {
          throw BoomError.stale("Delivered ordered input lost its original physical focus or keyboard.")
        }
      }
      replayObservation = try input.observeSelection()
    } else if queue.isEmpty { replayObservation = nil }
    // The final replay closes before trimming. An entered reader/task or IME
    // still owns its join; ordinary file saving is unrelated to this local trim.
    guard phase == .idle, queue.isEmpty, commandTask == nil,
      navigationTask == nil, capturedEditTask == nil, !input.session.isPinned,
      input.session.activeNavigationOperationCount == 0 else { return }
    try input.recenterResidentWindowIfNeeded()
  }

  /// Existing selection/focus ingress may call this after its real epoch
  /// advances. Cancellation retains the entered Task until its read joins.
  func inputSelectionDidChange() {
    guard !replayingRawKeys, phase == .idle || phase == .readingColdHistory || phase == .readingBoundary else { return }
    if let capturedEditObservation, (try? input.observeSelection()) != capturedEditObservation {
      // A later real edit/selection makes an unadopted agent/formatting target
      // obsolete. Stop its actual reader instead of occupying that lane.
      capturedEditTask?.cancel(); self.capturedEditObservation = nil
    }
    let expected = relatedReadObservation ?? (!queue.isEmpty ? replayObservation : nil)
    guard let expected, (try? input.observeSelection()) != expected else { return }
    let error = BoomError.stale("Selection or focus superseded its original bounded source read.")
    relatedReadObservation = nil
    commandTask?.cancel(); navigationTask?.cancel()
    phase = .idle; isNavigating = false
    preserveUnreplayableInput(error)
    lastCommandRefusal = error
    reportRefusal(error)
  }

  private func preserveUnreplayableInput(_ error: Error) {
    guard !queue.isEmpty else { return }
    precondition(queue.count + refusedInput.count <= Self.maximumQueuedEntries &&
      retainedInputBytes <= Self.maximumRawKeyBytes)
    if refusedInputFailure == nil { refusedInputFailure = error }
    if queuedPointerCount > 0 {
      for item in queue {
        if case .sourceCommand(let command) = item, case .pointerSelection(let pointer) = command.action {
          pointer.settle()
        }
      }
    }
    refusedInput.append(contentsOf: queue)
    refusedInputBytes += rawKeyBytes; refusedDirections += queuedDirections
    queue.removeAll(keepingCapacity: true)
    rawKeyBytes = 0; queuedRawKeyCount = 0; queuedDirections = 0; queuedPointerCount = 0
    replayObservation = nil
    PerformanceTrace.event("Editor.ManagedAdmission")
  }

  private func replayOriginalKeys() throws {
    guard phase == .idle, firstFailure == nil else { return }
    replayingRawKeys = true
    defer { replayingRawKeys = false; replayInsertionCount = 0; currentRawKeyAwaitingSource = false }
    var delivered = 0
    while delivered < Self.maximumReplayBurst, case .rawKey(let key)? = queue.first {
      replayInsertionCount = 0; currentRawKeyAwaitingSource = false
      guard let view = input.activeView, key.window === view.window,
        key.window.firstResponder === view, key.replayLease == (try input.inputLease(for: view)) else {
        throw BoomError.stale("Original cold-history input lost its actual focus or keyboard source.")
      }
      if let replayObservation, try input.observeSelection() != replayObservation {
        throw BoomError.stale("Original cold-read input lost its exact selection epoch before replay.")
      }
      let generation = input.session.generation
      let epoch = view.inputBinding?.selectionEpoch
      let previous = view.didRejectInput
      var refusal: Error?
      view.didRejectInput = { error in if refusal == nil { refusal = error }; previous?(error) }
      view.keyDown(with: key.event)
      view.didRejectInput = previous
      if let refusal, input.session.generation == generation,
        view.inputBinding?.selectionEpoch == epoch, replayInsertionCount == 0,
        !currentRawKeyAwaitingSource, navigationTask == nil, capturedEditTask == nil {
        throw refusal
      }
      if let error = view.boundedStorage.mutationFailure { throw error }
      if currentRawKeyAwaitingSource { return }
      queue.removeFirst(); queuedRawKeyCount -= 1; rawKeyBytes -= key.chargedBytes
      if phase == .idle { try finishOrderedInput(after: key.replayLease) }
      else { replayObservation = try input.observeSelection() }
      delivered += 1
      if hasPendingCommand && (navigationTask != nil || capturedEditTask != nil) { return }
    }
    if queue.isEmpty { replayObservation = nil }
  }

  private func resumeQueuedInput() {
    guard commandTask == nil, phase == .idle, !queue.isEmpty else { return }
    commandTask = Task { [self] in
      await Task.yield()
      commandTask = nil; pump()
    }
  }

  /// Preloading a different bounded projection never waits for publication.
  /// Later local typing may invalidate this read; it stays on its real source.
  func navigate(toUTF16 anchor: UInt64,
    selectingUTF16 requested: PagedNativeNavigationSelection? = nil) async throws -> PagedNativeLogicalWindow {
    try requireCommandQuiescence()
    try requireNavigationClient()
    let observed = try input.observeSelection()
    let original = try input.currentDocumentSelection()
    let selected = requested ?? original
    if let reused = try input.reuseJoinedNavigationWindow(toUTF16: anchor,
      selection: selected, observedSelection: observed) { return reused }
    let read = try input.session.captureLogicalRead()
    let related = selected != original
    isNavigating = related
    relatedReadObservation = observed
    if related { phase = .readingBoundary }
    let task = Task<PagedNativeLogicalWindow, Error> { [self] in
      defer {
        navigationTask = nil; isNavigating = false
        if relatedReadObservation == observed { relatedReadObservation = nil }
        if phase == .preparing || (related && phase == .readingBoundary) { phase = .idle }
        pump()
      }
      do {
        let ticket = try await input.session.prepareNavigationInstallation(
          owner: input, toUTF16: anchor, selectingUTF16: selected)
        if related { phase = .preparing }
        let installed = try installPrepared(ticket, captured: read, observed: observed)
        if related {
          relatedReadObservation = nil; phase = .idle
          try transferRawInputAfterMount()
        }
        return installed
      } catch {
        if relatedReadObservation == observed,
          (!input.session.isCurrent(read) || (try? input.observeSelection()) != observed) {
          preserveUnreplayableInput(error)
        }
        if lastCommandRefusal == nil { lastCommandRefusal = error }
        throw error
      }
    }
    navigationTask = task
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private func installPrepared(_ ticket: PagedNativeNavigationInstallationTicket,
    captured: PagedNativeLogicalReadSnapshot, observed: PagedNativeSelectionObservation)
    throws -> PagedNativeLogicalWindow {
    do {
      try Task.checkCancellation()
      try input.session.admitLogicalRead(captured)
      guard input.commandOwner === self, firstFailure == nil,
        phase != .closed, try input.observeSelection() == observed, let mount = mountView else {
        throw BoomError.stale("The prepared logical projection lost its original physical receiver.")
      }
      try input.stageNavigation(ticket, observedSelection: observed)
      return try input.withStagedNavigationInstallation(ticket, mounted: mount)
    } catch {
      let original = error
      if ticket.isAwaitingAdoption {
        do { try input.cancelNavigationStage(ticket) }
        catch {
          let retained = PagedNativeNavigationOwnerFailure(original: original, cleanup: error)
          failAcceptedSource(retained); throw retained
        }
      } else if ticket.wasConsumed { failAcceptedSource(original) }
      throw original
    }
  }

  private func requireNavigationClient() throws {
    guard input.commandOwner === self, let view = input.activeView,
      view.inputCommandIsClosed, !view.hasMarkedText(), input.firstRefusal == nil,
      mountView != nil else {
      throw BoomError.stale("The logical command requires its actual quiescent native client.")
    }
  }

  func requestDocumentNavigation(toUTF16 anchor: UInt64,
    selectingUTF16 selected: PagedNativeNavigationSelection,
    expected: PagedNativeDocumentCoordinates) throws {
    try requireCommandQuiescence(); try requireNavigationClient()
    let current = try input.session.documentCoordinates()
    guard current.sessionID == expected.sessionID, current.arenaID == expected.arenaID,
      current.generation == expected.generation, current.windowID == expected.windowID else {
      throw BoomError.stale("Document navigation has another logical arena or generation.")
    }
    let observed = try input.observeSelection(), read = try input.session.captureLogicalRead()
    beginNavigation(captured: read, observed: observed) { [self] in
      try await input.session.prepareNavigationInstallation(
        owner: input, toUTF16: anchor, selectingUTF16: selected)
    }
  }

  private func beginNavigation(captured: PagedNativeLogicalReadSnapshot,
    observed: PagedNativeSelectionObservation,
    installed onInstalled: (@MainActor (PagedNativeLogicalWindow) -> Void)? = nil,
    settled onSettled: (@MainActor () -> Void)? = nil,
    preparing: @escaping @MainActor () async throws -> PagedNativeNavigationInstallationTicket) {
    precondition(navigationTask == nil, "An entered navigation task must be retained through its real join.")
    isNavigating = true; phase = .readingBoundary; relatedReadObservation = observed
    navigationTask = Task { [self] in
      defer {
        navigationTask = nil; isNavigating = false
        if relatedReadObservation == observed { relatedReadObservation = nil }
        if phase == .readingBoundary || phase == .preparing { phase = .idle }
        onSettled?()
        pump()
      }
      do {
        let ticket = try await preparing()
        phase = .preparing
        let installed = try installPrepared(ticket, captured: captured, observed: observed)
        onInstalled?(installed)
        relatedReadObservation = nil; phase = .idle
        try transferRawInputAfterMount()
        return installed
      }
      catch {
        if relatedReadObservation == observed,
          (!input.session.isCurrent(captured) || (try? input.observeSelection()) != observed) {
          preserveUnreplayableInput(error)
        }
        if lastCommandRefusal == nil { lastCommandRefusal = error }
        if firstFailure == nil { reportRefusal(error) }
        throw error
      }
    }
  }

  // First truthful chronology slice: source-neutral navigation followed by
  // ordinary native text/selection keys. Formatting/history need their actual
  // inverse/point transforms, and retain their existing pending behavior.
  var canOrderPointerAfterNavigation: Bool {
    guard phase == .readingBoundary, navigationTask != nil,
      commandTask == nil, capturedEditTask == nil, queuedPointerCount == 0 else { return false }
    return queue.allSatisfy {
      guard case .rawKey(let key) = $0 else { return false }
      // Shift-Tab may move physical focus; preserve the predecessor pending
      // behavior until that chronological focus transition is explicitly owned.
      return key.event.keyCode != 48 && key.event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }
  }
  func beginOrderedDocumentPointer(_ read: PagedNativeLogicalReadSnapshot,
    selection: PagedNativeNavigationSelection, extending: Bool, from view: PagedNativeTextView,
    installed: @escaping @MainActor (UUID) -> Void) throws -> UUID {
    guard canOrderPointerAfterNavigation, input.session.isCurrent(read),
      selection.utf16Offset <= read.source.summary.utf16,
      selection.utf16Length <= read.source.summary.utf16 - selection.utf16Offset else {
      throw BoomError.stale("The pointer has no exact source-neutral chronological navigation.")
    }
    let pointer = PointerSelection(source: read.source, selection: selection, extending: extending, installed: installed)
    try enqueueSourceCommand(.pointerSelection(pointer), from: view, chargedBytes: 512)
    queuedPointerCount += 1
    return pointer.id
  }
  func updateOrderedDocumentPointer(_ id: UUID, source: PagedNativeLogicalSnapshot,
    selection: PagedNativeNavigationSelection, completing: Bool) throws {
    guard let pointer = queue.compactMap({ item -> PointerSelection? in
      if case .sourceCommand(let command) = item, case .pointerSelection(let pointer) = command.action,
        pointer.id == id { return pointer }; return nil
    }).first, !pointer.complete, pointer.original.isSame(source), pointer.source.isSame(source),
      selection.utf16Offset <= source.summary.utf16,
      selection.utf16Length <= source.summary.utf16 - selection.utf16Offset else {
      throw BoomError.stale("The pointer release lost its exact captured source intent.")
    }
    pointer.selection = selection; pointer.complete = completing
    if completing { pump() }
  }
  /// An explicit join/close ends tracking at its last admitted real point.
  /// The original navigation, earlier keys, pointer and later keys then settle
  /// in order; no missing mouseup or new source/focus authority is required.
  private func completeOrderedPointerGestures() {
    guard queuedPointerCount > 0 else { return }
    for item in queue {
      if case .sourceCommand(let command) = item, case .pointerSelection(let pointer) = command.action {
        pointer.complete = true
      }
    }
  }
  private func removeSourceCommandHead(_ command: SourceCommand, refusing: Bool = false) {
    if case .pointerSelection(let pointer) = command.action {
      queuedPointerCount -= 1
      if refusing { pointer.settle() }
    }
    queue.removeFirst(); rawKeyBytes -= command.chargedBytes
  }
  private func mapQueuedPointers(before: PagedNativeLogicalSnapshot, after: PagedNativeLogicalSnapshot,
    start: UInt64, removed: UInt64, inserted: UInt64) {
    guard queuedPointerCount > 0 else { return }
    for item in queue {
      guard case .sourceCommand(let command) = item, case .pointerSelection(let pointer) = command.action,
        pointer.failure == nil else { continue }
      do {
        let retained = before.summary.utf16.subtractingReportingOverflow(removed)
        let extent = retained.partialValue.addingReportingOverflow(inserted)
        guard pointer.complete, pointer.source.isSame(before), start <= before.summary.utf16,
          removed <= before.summary.utf16 - start, !retained.overflow, !extent.overflow,
          after.summary.utf16 == extent.partialValue else {
          throw BoomError.stale("A queued pointer has no exact accepted source splice.")
        }
        let old = pointer.selection, end = start + removed
        func map(_ point: UInt64, afterInsertion: Bool) -> UInt64 {
          if point < start { return point }
          if point > end { return point - removed + inserted }
          if removed > 0, point == end { return start + inserted }
          return start + (afterInsertion ? inserted : 0)
        }
        // Endpoint insertion gravity is separate from visual affinity and
        // actual focus direction. A collapsed clicked caret follows insertion.
        let collapsed = old.utf16Length == 0
        let anchor = map(old.anchorUTF16, afterInsertion: collapsed || old.focusAtEnd)
        let focus = map(old.focusUTF16, afterInsertion: collapsed || !old.focusAtEnd)
        pointer.selection = PagedNativeNavigationSelection(utf16Offset: min(anchor, focus),
          utf16Length: max(anchor, focus) - min(anchor, focus), focusAtEnd: focus >= anchor,
          affinity: old.affinity)
        pointer.source = after
      } catch { pointer.failure = error }
    }
  }
  private func deliverPointer(_ pointer: PointerSelection) throws {
    if let failure = pointer.failure { throw failure }
    let read = try input.session.captureLogicalState(), observed = try input.observeSelection()
    guard pointer.complete, pointer.source.isSame(read.source) else {
      throw BoomError.stale("The ordered pointer lost its actual mapped logical source.")
    }
    let window = input.session.logicalWindow, focus = pointer.selection.focusUTF16
    let selected: PagedNativeNavigationSelection
    if pointer.extending {
      // Shift uses the actual preceding chronological selection anchor, not
      // the old caret still painted while that navigation was reading.
      let anchor = try input.currentDocumentSelection().anchorUTF16
      selected = PagedNativeNavigationSelection(utf16Offset: min(anchor, focus),
        utf16Length: max(anchor, focus) - min(anchor, focus), focusAtEnd: focus >= anchor,
        affinity: pointer.selection.affinity)
    } else { selected = pointer.selection }
    if focus >= window.start.utf16, focus - window.start.utf16 <= window.summary.utf16 {
      _ = try window.position(localUTF16: Int(focus - window.start.utf16))
      try input.setDocumentSelection(selected); pointer.settle()
      return
    }
    beginNavigation(captured: read, observed: observed,
      installed: { _ in pointer.settle() }, settled: { pointer.settle() }) { [self] in
      try await input.session.prepareNavigationInstallation(owner: input,
        toUTF16: focus > 4096 ? focus - 4096 : 0, selectingUTF16: selected)
    }
  }

  private var shouldQueueSourceCommand: Bool {
    !replayingRawKeys && (phase == .readingColdHistory || phase == .readingBoundary
      || commandTask != nil || navigationTask != nil || !queue.isEmpty)
  }
  private func enqueueSourceCommand(_ action: SourceAction, from view: PagedNativeTextView?,
    chargedBytes: Int) throws {
    guard phase != .closed, let view, view === input.activeView,
      let window = view.window, window.firstResponder === view,
      queue.count + refusedInput.count < Self.maximumQueuedEntries, chargedBytes >= 512,
      chargedBytes <= Self.maximumRawKeyBytes - retainedInputBytes else {
      throw BoomError.budget("The bounded related-read queue cannot retain this document command.")
    }
    let item = QueuedInput.sourceCommand(SourceCommand(action: action,
      replayLease: try input.inputLease(for: view), window: window, chargedBytes: chargedBytes))
    if replayObservation == nil { replayObservation = try input.observeSelection() }
    if replayingRawKeys { queue.insert(item, at: 1 + replayInsertionCount); replayInsertionCount += 1 }
    else { queue.append(item) }
    rawKeyBytes += chargedBytes
    pump()
  }

  private var dispatchingRecenteredKey = false
  func recenterBeforeRawKey(_ event: NSEvent, from view: PagedNativeTextView,
    toUTF16 anchor: UInt64) -> Bool {
    guard !dispatchingRecenteredKey, view === input.activeView else { return false }
    do {
      try requireCommandQuiescence(); try requireNavigationClient()
      let observed = try input.observeSelection(), read = try input.session.captureLogicalState()
      let coordinates = try input.session.documentCoordinates(), selected = try input.currentDocumentSelection()
      guard selected.focusUTF16 >= coordinates.utf16Start,
        selected.focusUTF16 - coordinates.utf16Start <= UInt64(coordinates.localUTF16) else {
        throw BoomError.stale("The original boundary key lacks its resident logical focus.")
      }
      let ticket = try input.session.prepareResidentRecenter(
        localFocusUTF16: Int(selected.focusUTF16 - coordinates.utf16Start), owner: input)
      _ = try installPrepared(ticket, captured: read, observed: observed)
      guard let target = input.activeView else { throw BoomError.stale("Resident recenter lost its native receiver.") }
      dispatchingRecenteredKey = true
      defer { dispatchingRecenteredKey = false }
      target.keyDown(with: event)
    } catch { reportRefusal(error) }
    return true
  }

  func refuseDocumentKey(_ event: NSEvent, from view: PagedNativeTextView, original: Error) {
    // No primitive accepted this event. Preserve the bounded diagnostic and
    // leave later ordinary input live rather than latch an unrelated saver.
    reportRefusal(original)
  }

  func applyCapturedEdits(expected: PagedDocumentRootRecord, edits: [PagedTextLocalEdit],
    actionName: String) async throws -> PagedDocumentRootRecord {
    let captured = try input.session.admitCapturedRecord(expected)
    guard edits.count <= PagedCapturedEditInput.maximumEdits else {
      throw BoomError.budget("Explicit edit count exceeds its bounded capture.")
    }
    var previous = expected.document.revision.summary.bytes, charge = 0
    for edit in edits {
      guard edit.revision == expected.document.revision, edit.byteStart <= edit.byteEnd,
        edit.byteEnd <= previous, edit.byteEnd - edit.byteStart == UInt64(edit.oldBytes.count),
        edit.oldBytes.count <= PagedCapturedEditInput.maximumInputBytes - charge else {
        throw BoomError.stale("Agent edits are not exact descending ranges of their actual captured source.")
      }
      charge += edit.oldBytes.count
      guard edit.newBytes.count <= PagedCapturedEditInput.maximumInputBytes - charge else {
        throw BoomError.budget("Agent replacement bytes exceed their bounded capture.")
      }
      charge += edit.newBytes.count; previous = edit.byteStart
    }
    let changed = edits.filter { $0.oldBytes != $0.newBytes }
    guard !changed.isEmpty else { return expected }
    var installedGeneration: UInt64?
    _ = try await beginLogicalEdit(actionName: actionName, captured: captured,
      onInstalled: { [self] in installedGeneration = input.session.generation }) { [self] in
      try await input.session.prepareLogicalEdits(expected: captured, edits: changed,
        afterSelection: nil, owner: input)
    }.value
    guard let generation = installedGeneration else {
      throw BoomError.invalid("The explicit edit did not join its actual logical installation.")
    }
    // Only this explicit agent caller awaits persistence for its returned
    // file record. Native typing, selection and Undo remain independently live.
    return try await input.session.flushRecord(through: generation)
  }

  func replaceDocumentSelection(_ selected: PagedNativeNavigationSelection,
    with replacement: Data, actionName: String) async throws -> PagedNativeLogicalSnapshot {
    if let resident = try performResidentReplacement(selected, replacement: replacement, actionName: actionName) {
      return resident
    }
    return try await beginLogicalEdit(actionName: actionName) { [self] in
      try await input.session.prepareLogicalReplacement(selection: selected, replacement: replacement, owner: input)
    }.value
  }

  func requestDocumentReplacement(_ selected: PagedNativeNavigationSelection,
    replacement: Data, actionName: String, groupID requestedGroup: UUID? = nil) throws {
    guard replacement.count <= PagedCapturedEditInput.maximumInputBytes else {
      throw BoomError.budget("Document replacement needs its existing streamed input route.")
    }
    let groupID = requestedGroup ?? input.activeView?.typedCharacterCommandGroupID ?? UUID()
    if shouldQueueSourceCommand {
      try enqueueSourceCommand(.replacement(replacement, actionName, groupID), from: input.activeView,
        chargedBytes: replacement.count + actionName.utf8.count + 512)
      return
    }
    if try performResidentReplacement(selected, replacement: replacement,
      actionName: actionName, groupID: groupID) != nil { return }
    _ = try beginLogicalEdit(actionName: actionName, reportFailure: true, related: true) { [self] in
      try await input.session.prepareLogicalReplacement(selection: selected,
        replacement: replacement, owner: input, groupID: groupID)
    }
  }

  private func performResidentReplacement(_ selected: PagedNativeNavigationSelection,
    replacement: Data, actionName: String, groupID: UUID = UUID()) throws -> PagedNativeLogicalSnapshot? {
    guard replacement.count <= PagedCapturedEditInput.maximumInputBytes else {
      throw BoomError.budget("Document replacement needs its existing streamed input route.")
    }
    try requireLocalCommand()
    let read = try input.session.captureLogicalState(), observed = try input.observeSelection()
    guard selected.utf16Offset <= read.source.summary.utf16,
      selected.utf16Length <= read.source.summary.utf16 - selected.utf16Offset else {
      throw BoomError.stale("The document replacement has another logical selection.")
    }
    guard selected.utf16Length != 0 || !replacement.isEmpty else { return read.source }
    guard let ticket = try input.session.prepareLogicalReplacementIfResident(
      selection: selected, replacement: replacement, owner: input, groupID: groupID) else { return nil }
    if !ticket.sourceChanged, ticket.window.windowID == input.session.logicalWindow.windowID {
      // Exact source-neutral replacement keeps its real client and SDK stack.
      try input.cancelNavigationStage(ticket)
      if let selection = ticket.documentSelection { try input.setDocumentSelection(selection) }
      return read.source
    }
    let previousName = capturedActionName
    capturedActionName = actionName
    defer { capturedActionName = previousName }
    _ = try installPrepared(ticket, captured: read, observed: observed)
    input.notifyNativeState(from: input.activeView, edited: true)
    input.session.requestCommit()
    return try input.session.captureLogicalState().source
  }

  func requestLinePrefix(_ prefix: String, from view: PagedNativeTextView) throws {
    guard view === input.activeView, !prefix.isEmpty, prefix.utf8.count <= 256,
      !prefix.unicodeScalars.contains(where: { [0x0A, 0x0D, 0x85, 0x2028, 0x2029].contains($0.value) }) else {
      throw BoomError.invalid("The paragraph marker is not a bounded single-line prefix.")
    }
    if shouldQueueSourceCommand {
      try enqueueSourceCommand(.linePrefix(prefix), from: view, chargedBytes: prefix.utf8.count + 512)
      return
    }
    let selected = try input.currentDocumentSelection()
    _ = try beginLogicalEdit(actionName: "Format", reportFailure: true, related: replayingRawKeys) { [self] in
      try await input.session.prepareLogicalLinePrefix(selection: selected, prefix: prefix, owner: input)
    }
  }

  func requestDocumentWrapping(_ selected: PagedNativeNavigationSelection,
    prefix: String, suffix: String, toggles: Bool, actionName: String) throws {
    guard !prefix.isEmpty, !suffix.isEmpty, prefix.utf8.count <= 64,
      suffix.utf8.count <= 64, selected.utf16Length > 0 else {
      throw BoomError.budget("Document delimiters exceed their bounded formatting command.")
    }
    if shouldQueueSourceCommand {
      try enqueueSourceCommand(.wrapping(prefix, suffix, toggles, actionName), from: input.activeView,
        chargedBytes: prefix.utf8.count + suffix.utf8.count + actionName.utf8.count + 512)
      return
    }
    _ = try beginLogicalEdit(actionName: actionName, reportFailure: true, related: replayingRawKeys) { [self] in
      try await input.session.prepareLogicalWrapping(selection: selected,
        prefix: prefix, suffix: suffix, toggles: toggles, owner: input)
    }
  }

  /// A logical capture describes accepted dirty text honestly. Copy releases
  /// its UI command after the actual immutable capture/publication preparation;
  /// Cut mutates only after that callback reports real clipboard publication.
  @discardableResult
  func requestDocumentClipboard(_ selected: PagedNativeNavigationSelection, cutting: Bool,
    prepare: @escaping @MainActor (PagedNativeLogicalReadSnapshot) async throws -> Void)
    throws -> Task<PagedNativeLogicalSnapshot, Error> {
    try requireLocalCommand()
    let read = try input.session.captureLogicalRead(), observed = try input.observeSelection()
    if !cutting {
      guard capturedEditTask == nil else { throw BoomError.stale("An existing clipboard capture still owns this task slot.") }
      let task = Task<PagedNativeLogicalSnapshot, Error> { [self] in
        defer { capturedEditTask = nil; pump() }
        do { try await prepare(read); return read.source }
        catch { lastCommandRefusal = error; reportRefusal(error); throw error }
      }
      capturedEditTask = task
      return task
    }
    return try beginLogicalEdit(actionName: "Cut", reportFailure: true, captured: read,
      observed: observed) { [self] in
        try await prepare(read)
        try Task.checkCancellation()
        try input.session.admitLogicalRead(read)
        return try await input.session.prepareLogicalReplacement(selection: selected, replacement: Data(), owner: input)
      }
  }

  /// Keep the real imported tree output until logical installation consumes
  /// it. A source-inert refusal disposes that actual output once; adoption must
  /// transfer its root custody before returning, independently of later saves.
  @discardableResult
  func requestDocumentImportedReplacement(_ selected: PagedNativeNavigationSelection,
    importing: @escaping @MainActor (PagedNativeLogicalReadSnapshot) async throws -> PagedTextCustodiedValue<PagedTextImportedRevision>,
    discard: @escaping @MainActor (PagedTextRootLease) async throws -> Void)
    throws -> Task<PagedNativeLogicalSnapshot, Error> {
    let read = try input.session.captureLogicalRead()
    var imported: PagedTextCustodiedValue<PagedTextImportedRevision>?
    return try beginLogicalEdit(actionName: "Paste", reportFailure: true, captured: read,
      discardUnadopted: {
        if let imported { try await discard(imported.lease) }
      }) { [self] in
        let value = try await importing(read)
        imported = value
        try Task.checkCancellation()
        try input.session.admitLogicalRead(read)
        return try await input.session.prepareLogicalImportedReplacement(selection: selected,
          imported: value, owner: input)
      }
  }

  private func beginLogicalEdit(actionName: String, reportFailure: Bool = false,
    related: Bool = false,
    captured requested: PagedNativeLogicalReadSnapshot? = nil,
    observed requestedObservation: PagedNativeSelectionObservation? = nil,
    discardUnadopted: (@MainActor () async throws -> Void)? = nil,
    onInstalled: (@MainActor () throws -> Void)? = nil,
    preparing: @escaping @MainActor () async throws -> PagedNativeNavigationInstallationTicket)
    throws -> Task<PagedNativeLogicalSnapshot, Error> {
    try requireLocalCommand()
    guard capturedEditTask == nil else {
      throw BoomError.stale("An existing logical command still owns its bounded preparation task.")
    }
    let read = try requested ?? input.session.captureLogicalRead()
    try input.session.admitLogicalRead(read)
    let observed = try requestedObservation ?? input.observeSelection()
    capturedEditObservation = observed
    if related { phase = .readingBoundary; relatedReadObservation = observed }
    let task = Task<PagedNativeLogicalSnapshot, Error> { [self] in
      var ticket: PagedNativeNavigationInstallationTicket?
      defer {
        capturedEditTask = nil
        if capturedEditObservation == observed { capturedEditObservation = nil }
        if relatedReadObservation == observed { relatedReadObservation = nil }
        if phase == .preparing || (related && phase == .readingBoundary) { phase = .idle }
        pump()
      }
      do {
        try Task.checkCancellation()
        let candidate = try await preparing()
        ticket = candidate
        capturedActionName = actionName
        defer { capturedActionName = nil }
        phase = .preparing
        _ = try installPrepared(candidate, captured: read, observed: observed)
        capturedEditObservation = nil
        phase = .idle
        if related {
          relatedReadObservation = nil; phase = .idle
          try transferRawInputAfterMount()
        }
        try onInstalled?()
        input.notifyNativeState(from: input.activeView, edited: true)
        input.session.requestCommit()
        return try input.session.captureLogicalState().source
      } catch {
        let original = error
        if ticket?.wasConsumed != true, let discardUnadopted {
          do { try await discardUnadopted() }
          catch {
            let retained = PagedNativeNavigationOwnerFailure(original: original, cleanup: error)
            failAcceptedSource(retained); throw retained
          }
        }
        if related, relatedReadObservation == observed,
          (!input.session.isCurrent(read) || (try? input.observeSelection()) != observed) {
          preserveUnreplayableInput(original)
        }
        if lastCommandRefusal == nil { lastCommandRefusal = original }
        if reportFailure, firstFailure == nil { reportRefusal(original) }
        throw original
      }
    }
    capturedEditTask = task
    return task
  }

  func replaceSelectionBeforeRawKey(_ event: NSEvent, from view: PagedNativeTextView,
    selection selected: PagedNativeNavigationSelection) throws {
    guard event.type == .keyDown, view === input.activeView,
      (event.characters ?? "").utf16.count <= Self.maximumKeyUTF16,
      (event.charactersIgnoringModifiers ?? "").utf16.count <= Self.maximumKeyUTF16 else {
      throw BoomError.budget("Selected-source input exceeds its original native event bound.")
    }
    let observed = try input.observeSelection()
    if try performResidentReplacement(selected, replacement: Data(), actionName: "Edit") != nil {
      if let activeGroup { input.continueNextInputGroup(activeGroup) }
      guard let target = input.activeView, let transfer = input.lastReplayTransition else {
        throw BoomError.stale("Selected-source input lost its actual focus-preserving mount.")
      }
      _ = try transfer.rebase(observed.inputLease)
      target.keyDown(with: event)
      return
    }
    let read = try input.session.captureLogicalRead()
    let retainedHead = replayingRawKeys
    if retainedHead { currentRawKeyAwaitingSource = true }
    _ = try beginLogicalEdit(actionName: "Edit", reportFailure: true, related: true, captured: read,
      observed: observed, onInstalled: { [self] in
        if let activeGroup { input.continueNextInputGroup(activeGroup) }
        if retainedHead { return } // the original queued head is still owned
        guard let target = input.activeView, let transfer = input.lastReplayTransition else {
          throw BoomError.stale("Prepared selected-source input lost its actual receiver.")
        }
        _ = try transfer.rebase(observed.inputLease)
        target.keyDown(with: event)
      }) { [self] in
        try await input.session.prepareLogicalReplacement(selection: selected, replacement: Data(), owner: input)
      }
  }

  func requestDocumentCommand(_ selector: Selector, from view: PagedNativeTextView) throws {
    guard view === input.activeView else { return }
    if shouldQueueSourceCommand {
      try enqueueSourceCommand(.documentCommand(selector), from: view, chargedBytes: 512)
      return
    }
    try requireLocalCommand()
    guard navigationTask == nil else { throw BoomError.stale("An earlier actual boundary navigation still owns its read.") }
    try input.performQueuedDocumentCommand(selector)
  }

  func requestGraphemeMovement(forward: Bool, extending: Bool,
    selection selected: PagedNativeNavigationSelection, nativeTargetUTF16: UInt64? = nil,
    resultAffinity: PagedSelectionAffinity? = nil) throws {
    try requireLocalCommand()
    guard navigationTask == nil else {
      throw BoomError.stale("An earlier actual character navigation still owns its read.")
    }
    let read = try input.session.captureLogicalRead(), observed = try input.observeSelection()
    beginNavigation(captured: read, observed: observed) { [self] in
      let target: UInt64
      if let nativeTargetUTF16 {
        target = try await input.session.logicalGraphemeBoundary(read,
          atNativeUTF16: nativeTargetUTF16, forward: forward).utf16
      } else if !extending, selected.utf16Length > 0 {
        target = forward ? selected.utf16Offset + selected.utf16Length : selected.utf16Offset
      } else {
        target = try await input.session.logicalGraphemeBoundary(read,
          atUTF16: selected.focusUTF16, forward: forward).utf16
      }
      try input.session.admitLogicalRead(read)
      let next = movedSelection(selected, target: target, extending: extending,
        affinity: resultAffinity ?? selected.affinity)
      return try await input.session.prepareNavigationInstallation(
        owner: input, toUTF16: target > 4096 ? target - 4096 : 0, selectingUTF16: next)
    }
  }

  private func movedSelection(_ original: PagedNativeNavigationSelection, target: UInt64,
    extending: Bool, affinity: PagedSelectionAffinity) -> PagedNativeNavigationSelection {
    if !extending { return PagedNativeNavigationSelection(utf16Offset: target, utf16Length: 0, affinity: affinity) }
    let anchor = original.anchorUTF16
    return PagedNativeNavigationSelection(utf16Offset: min(anchor, target),
      utf16Length: max(anchor, target) - min(anchor, target), focusAtEnd: target >= anchor, affinity: affinity)
  }

  func requestGraphemeDeletion(forward: Bool, selection selected: PagedNativeNavigationSelection) throws {
    let read = try input.session.captureLogicalRead()
    let groupID = input.activeView?.typedCharacterCommandGroupID ?? UUID()
    _ = try beginLogicalEdit(actionName: "Delete", reportFailure: true, related: true, captured: read) { [self] in
      let target = try await input.session.logicalGraphemeBoundary(read,
        atUTF16: selected.focusUTF16, forward: forward).utf16
      try input.session.admitLogicalRead(read)
      let range = PagedNativeNavigationSelection(utf16Offset: min(target, selected.focusUTF16),
        utf16Length: max(target, selected.focusUTF16) - min(target, selected.focusUTF16))
      return try await input.session.prepareLogicalReplacement(selection: range,
        replacement: Data(), owner: input, groupID: groupID)
    }
  }

  func requestParagraphCommand(_ command: PagedNativeParagraphCommand) throws {
    try requireLocalCommand()
    let selected = try input.currentDocumentSelection(), read = try input.session.captureLogicalRead()
    if command.deletes {
      let groupID = input.activeView?.typedCharacterCommandGroupID ?? UUID()
      _ = try beginLogicalEdit(actionName: "Delete", reportFailure: true, related: true, captured: read) { [self] in
        let range: PagedNativeNavigationSelection
        if selected.utf16Length > 0 { range = selected }
        else {
          let target = try await paragraphEndpoint(command, captured: read, atUTF16: selected.focusUTF16)
          range = PagedNativeNavigationSelection(utf16Offset: min(target, selected.focusUTF16),
            utf16Length: max(target, selected.focusUTF16) - min(target, selected.focusUTF16),
            focusAtEnd: selected.focusAtEnd, affinity: selected.affinity)
        }
        try input.session.admitLogicalRead(read)
        return try await input.session.prepareLogicalReplacement(selection: range,
          replacement: Data(), owner: input, groupID: groupID)
      }
      return
    }
    guard navigationTask == nil else { throw BoomError.stale("An earlier paragraph navigation still owns its actual read.") }
    let observed = try input.observeSelection()
    beginNavigation(captured: read, observed: observed) { [self] in
      let target = try await paragraphEndpoint(command, captured: read, atUTF16: selected.focusUTF16)
      try input.session.admitLogicalRead(read)
      let next = movedSelection(selected, target: target, extending: command.extends, affinity: selected.affinity)
      return try await input.session.prepareNavigationInstallation(
        owner: input, toUTF16: target > 4096 ? target - 4096 : 0, selectingUTF16: next)
    }
  }

  private func paragraphEndpoint(_ command: PagedNativeParagraphCommand,
    captured: PagedNativeLogicalReadSnapshot, atUTF16 offset: UInt64) async throws -> UInt64 {
    let bounds = try await input.session.logicalParagraphBounds(captured, atUTF16: offset, includeLineEndings: true)
    switch command {
    case .beginning, .beginningSelecting, .deleteBeginning: return bounds.start.utf16
    case .end, .endSelecting: return bounds.contentEnd.utf16
    case .deleteEnd: return offset < bounds.contentEnd.utf16 ? bounds.contentEnd.utf16 : bounds.end.utf16
    case .forwardSelecting:
      if offset < bounds.contentEnd.utf16 { return bounds.contentEnd.utf16 }
      if bounds.end.utf16 < captured.source.summary.utf16 {
        return try await input.session.logicalParagraphBounds(captured,
          atUTF16: bounds.end.utf16, includeLineEndings: true).contentEnd.utf16
      }
      return bounds.end.utf16
    case .backwardSelecting:
      if offset > bounds.start.utf16 || bounds.start.utf16 == 0 { return bounds.start.utf16 }
      let prior = try await input.session.logicalGraphemeBoundary(captured,
        atUTF16: bounds.start.utf16, forward: false)
      return try await input.session.logicalParagraphBounds(captured,
        atUTF16: prior.utf16, includeLineEndings: true).start.utf16
    }
  }

  /// Left/Right are visual commands. Probe this actual Cocoa layout, restore
  /// its owned selection before any yield, then validate the observed target
  /// against the full source on the existing navigation lane.
  func requestVisualGraphemeMovement(_ selector: Selector) throws {
    try requireLocalCommand()
    let command = NSStringFromSelector(selector)
    guard ["moveLeft:", "moveRight:", "moveLeftAndModifySelection:", "moveRightAndModifySelection:"].contains(command) else {
      throw BoomError.invalid("A visual character command requires its actual native selector.")
    }
    let extending = command.contains("AndModifySelection")
    let (original, native) = try probeNativeVisualMovement(selector, extending: extending)
    try requireLocalCommand()
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
    let captured = try input.session.captureLogicalState()
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
      try input.session.admitLogicalRead(captured)
      let current = try input.session.documentCoordinates(), actual = try input.observeSelection()
      guard input.activeView === view, current.sessionID == source.sessionID,
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

  private func requireLocalCommand() throws {
    guard phase == .idle, input.commandOwner === self, firstFailure == nil,
      expectedEntry == nil, inverseEntry == nil, adoptingSource == nil, !registeringGroup else {
      throw BoomError.stale("A synchronous logical source transition still owns the native command.")
    }
    try requireNavigationClient()
  }

  private func requireCommandQuiescence() throws {
    try requireLocalCommand()
    guard commandTask == nil, navigationTask == nil, capturedEditTask == nil,
      queue.isEmpty, queuedDirections == 0, queuedRawKeyCount == 0, rawKeyBytes == 0,
      !replayingRawKeys, !isNavigating, !dispatchingRecenteredKey,
      historyAtCommandClose == nil, unregisteredGroup == nil, gatedManager.groupingLevel == 0,
      !gatedManager.isUndoing, !gatedManager.isRedoing else {
      throw BoomError.stale("An actual logical command or original input still requires its real join.")
    }
  }

  func joinPendingCommand() async throws {
    completeOrderedPointerGestures()
    pump()
    var original: Error?
    for _ in 0..<(Self.maximumQueuedEntries + 2) {
      if commandTask == nil, navigationTask == nil, capturedEditTask == nil { break }
      if let task = commandTask, case .failure(let error) = await task.result, original == nil { original = error }
      if let task = navigationTask, case .failure(let error) = await task.result, original == nil { original = error }
      if let task = capturedEditTask, case .failure(let error) = await task.result, original == nil { original = error }
    }
    if let firstFailure { throw firstFailure }
    if commandTask != nil || navigationTask != nil || capturedEditTask != nil {
      let bound = BoomError.budget("New actual native commands kept this bounded join active.")
      if let original { throw PagedNativeNavigationOwnerFailure(original: original, cleanup: bound) }
      throw bound
    }
    if let original {
      // All owned tasks above joined. This call consumes their nonfatal
      // delivery outcome once; retained diagnostic events/error survive.
      lastCommandRefusal = nil
      throw original
    }
    if let lastCommandRefusal {
      self.lastCommandRefusal = nil
      throw lastCommandRefusal
    }
    if phase == .closed { try requireJoinedClose(); return }
    try requireCommandQuiescence()
  }

  func closeInput() throws {
    if phase == .closed { try requireJoinedClose(); return }
    try requireCommandQuiescence()
    guard let subscription = groupSubscription, input.commandOwner === self else {
      throw BoomError.stale("The logical native graph has another Foundation subscription.")
    }
    let ticket = try input.prepareInputRetirement(commandOwner: self)
    try requireCommandQuiescence()
    try input.session.detachNativeGroupSubscription(subscription, ownerID: input.ownerID) { [self] in
      phase = .closed; gatedManager.requestHistory = nil
      input.consumeInputRetirement(ticket, commandOwner: self)
    }
    groupSubscription = nil
    gatedManager.removeAllActions()
    undoEntries.removeAll(); redoEntries.removeAll(); activeGroup = nil
    lastCommandRefusal = nil; mountView = nil; didFail = nil
    relatedReadObservation = nil; replayObservation = nil; capturedEditObservation = nil
    try requireJoinedClose()
  }

  func requireJoinedClose() throws {
    guard phase == .closed, groupSubscription == nil, gatedManager.requestHistory == nil,
      commandTask == nil, navigationTask == nil, capturedEditTask == nil,
      !isNavigating, queue.isEmpty, queuedDirections == 0, queuedRawKeyCount == 0,
      rawKeyBytes == 0, !replayingRawKeys, !registeringGroup, !dispatchingRecenteredKey,
      expectedEntry == nil, inverseEntry == nil, adoptingSource == nil, hydrationExpected == nil,
      historyAtCommandClose == nil,
      undoEntries.isEmpty, redoEntries.isEmpty, firstFailure == nil, unregisteredGroup == nil else {
      throw BoomError.stale("The actual logical input/Foundation lifetime has not joined its retirement.")
    }
    try input.requireJoinedClose()
  }

  private func failAcceptedSource(_ error: Error) {
    guard phase != .closed else { return }
    if firstFailure == nil { firstFailure = error }
    didFail?(error)
  }
  private func reportRefusal(_ error: Error) {
    PerformanceTrace.event("Editor.ManagedAdmission")
    didFail?(error)
  }
}

private struct PagedNativeNavigationOwnerFailure: Error {
  let original: Error
  let cleanup: Error
}
