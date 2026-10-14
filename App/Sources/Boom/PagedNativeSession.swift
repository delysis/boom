import AppKit
import BoomCore
import Foundation

struct PagedNativeNavigationSelection: Sendable, Equatable {
  let utf16Offset: UInt64
  let utf16Length: UInt64
  let focusAtEnd: Bool
  let affinity: PagedSelectionAffinity
  init(utf16Offset: UInt64, utf16Length: UInt64, focusAtEnd: Bool = false,
    affinity: PagedSelectionAffinity = .downstream) {
    self.utf16Offset = utf16Offset; self.utf16Length = utf16Length
    self.focusAtEnd = focusAtEnd; self.affinity = affinity
  }
  // Every consuming entry checks the sum before accessing these endpoints.
  var focusUTF16: UInt64 { focusAtEnd ? utf16Offset + utf16Length : utf16Offset }
  var anchorUTF16: UInt64 { focusAtEnd ? utf16Offset : utf16Offset + utf16Length }
}

@MainActor final class PagedNativeGroupSubscription {
  let ownerID: UUID
  let sessionID: UUID
  fileprivate weak var session: PagedNativeSession?
  fileprivate var receiver: ((PagedNativeGroupSubscription, PagedNativeGroupClosureReceipt) -> Void)?
  fileprivate var historyCapture: (() throws -> PagedNativeLogicalHistoryProjection)?
  fileprivate init(ownerID: UUID, session: PagedNativeSession,
    receiver: @escaping (PagedNativeGroupSubscription, PagedNativeGroupClosureReceipt) -> Void,
    historyCapture: (() throws -> PagedNativeLogicalHistoryProjection)?) {
    self.ownerID = ownerID; sessionID = session.sessionID; self.session = session
    self.receiver = receiver; self.historyCapture = historyCapture
  }
  fileprivate func detach() { receiver = nil; historyCapture = nil; session = nil }
}

/// One resident candidate, completely prepared before Foundation may pop an
/// entry. The lexical consumer has no file read, allocation or admission.
@MainActor final class PagedNativeNavigationInstallationTicket {
  fileprivate enum State { case staged, cancelled, consumed }
  fileprivate enum Kind { case navigation, restore, edit(PagedNativeGroupClosureReceipt) }
  let operationID = UUID()
  let sessionID: UUID
  let sourceArenaID: UUID
  let sourceGeneration: UInt64
  let provisionalArenaID: UUID
  let localSelection: NSRange
  let selectionAffinity: NSSelectionAffinity
  let documentSelection: PagedNativeNavigationSelection?
  let sourceChanged: Bool
  fileprivate weak var owner: PagedNativeSession?
  fileprivate weak var inputOwner: PagedNativeInputOwner?
  fileprivate let before: PagedNativeLogicalSnapshot
  fileprivate let cursor: PagedNativeLogicalCursor
  fileprivate let kind: Kind
  fileprivate var candidate: PagedNativeLogicalWindow?
  fileprivate var sourceTransfer: (() -> Void)?
  fileprivate var state = State.staged
  var isAwaitingAdoption: Bool { state == .staged }
  var wasConsumed: Bool { state == .consumed }
  var window: PagedNativeLogicalWindow {
    precondition(state == .staged && candidate != nil); return candidate!
  }
  fileprivate init(owner: PagedNativeSession, inputOwner: PagedNativeInputOwner,
    window: PagedNativeLogicalWindow, selection: PagedNativeNavigationSelection,
    cursor: PagedNativeLogicalCursor, before: PagedNativeLogicalSnapshot, kind: Kind,
    provisionalArenaID: UUID) throws {
    sessionID = owner.sessionID; sourceArenaID = owner.arenaID; sourceGeneration = owner.generation
    self.provisionalArenaID = provisionalArenaID
    self.owner = owner; self.inputOwner = inputOwner; candidate = window
    self.before = before; self.cursor = cursor; self.kind = kind; documentSelection = selection
    localSelection = try window.localRange(for: selection)
    selectionAffinity = selection.affinity == .upstream ? .upstream : .downstream
    sourceChanged = !window.snapshot.isSame(before)
  }
  fileprivate func releaseBacking() { candidate = nil; inputOwner = nil; sourceTransfer = nil }
}

/// Native input, Foundation history and asynchronous file saving have separate
/// jobs on the SAME source. Only the logical source advances native content.
@MainActor final class PagedNativeSession {
  nonisolated static let maximumNavigationOperations = 8
  let engineIncarnation: UUID
  private let storage: any PagedNativeLogicalSessionStorage
  private let source: PagedNativeLogicalSource
  private var working: PagedWorkingWindow
  private weak var managedArenaOwner: PagedNativeInputOwner?
  private var subscription: PagedNativeGroupSubscription?
  private var stage: PagedNativeNavigationInstallationTicket?
  private var adopting = false
  private var hookTransition = false
  private var notifyingGroup = false
  private var characterDepth = 0
  private var navigationOperations: Set<UUID> = []
  private var openingHistory: PagedNativeLogicalHistoryProjection?
  private(set) var canonicalOpening: PagedNativeCanonicalOpening?
  private(set) var sealedRootRecord: PagedDocumentRootRecord
  private(set) var sealedRevision: PagedTextRevision
  private(set) var sealedGeneration: UInt64 = 0
  private var sealedSnapshot: PagedNativeLogicalSnapshot
  private var commitTask: Task<PagedNativeCommitAcknowledgement?, Never>?
  private var saveDelay: Task<Void, Never>?
  private var expeditingSave = false
  private var publication: PagedNativeLogicalPublication?
  private(set) var pendingCommitInstallation: PagedNativeCommitAcknowledgement?
  private(set) var persistenceFailure: Error?
  private var persistenceFailureSerial: UInt64 = 0
  private var failedPublicationSerial: UInt64?
  private var failureSerialExhausted = false
  var didFail: ((Error) -> Void)?
  var didSeal: ((PagedTextWindow) -> Void)?
  var didCloseNativeGroup: ((PagedNativeGroupClosureReceipt) -> Void)?

  init(opening: PagedNativeCanonicalOpening, storage: any PagedNativeLogicalSessionStorage) throws {
    self.storage = storage; engineIncarnation = storage.engineIncarnation
    guard opening.history.producer.engineIncarnation == engineIncarnation,
      opening.history.record == opening.record, opening.window.revision == opening.record.document.revision else {
      throw BoomError.invalid("Logical opening lost its actual file source/history owner.")
    }
    let source = try PagedNativeLogicalSource(revision: opening.window.revision,
      sessionID: opening.sessionID, engineIncarnation: engineIncarnation)
    let window = try source.openingWindow(opening.window)
    self.source = source; sealedSnapshot = window.snapshot
    sealedRootRecord = opening.record; sealedRevision = opening.record.document.revision
    canonicalOpening = opening
    working = try PagedWorkingWindow(window: window, cursor: PagedNativeLogicalCursor(opening.history.currentCursor))
    func entry(_ entry: PagedRootHistoryEntry) throws -> PagedNativeLogicalHistoryEntry {
      let owner = try PagedNativeLogicalSource(revision: entry.revision,
        sessionID: opening.sessionID, engineIncarnation: storage.engineIncarnation)
      return try PagedNativeLogicalHistoryEntry(snapshot: owner.capture(),
        cursor: PagedNativeLogicalCursor(entry.cursor), groupID: entry.groupID)
    }
    openingHistory = try PagedNativeLogicalHistoryProjection(snapshot: window.snapshot,
      cursor: PagedNativeLogicalCursor(opening.history.currentCursor),
      undo: opening.history.undo.map(entry), redo: opening.history.redo.map(entry),
      activeGroup: opening.history.activeGroup, generation: 0)
  }
  var sessionID: UUID { working.sessionID }
  var arenaID: UUID { working.arenaID }
  var generation: UInt64 { working.generation }
  var logicalWindow: PagedNativeLogicalWindow { working.logicalWindow }
  var currentLogicalCursor: PagedNativeLogicalCursor { working.currentCursor }
  var sourceBaseRevision: PagedTextRevision { logicalWindow.snapshot.sourceRevision }
  var isPinned: Bool { working.isPinned }
  var compositionGroupID: UUID? { working.compositionGroup }
  var localUTF16Count: Int { working.localUTF16Count }
  var needsRecentering: Bool { working.needsRecentering }
  var hasPendingHistoryCommand: Bool { false } // SDK owner owns its actual command
  var isProvisionalHistory: Bool { false }
  var activeNavigationOperationCount: Int { navigationOperations.count }

  /// Cheap native/SDK capture. It neither freezes a tail nor starts a reader.
  func captureLogicalState() throws -> PagedNativeLogicalReadSnapshot {
    PagedNativeLogicalReadSnapshot(source: try source.capture(), sessionID: sessionID,
      arenaID: arenaID, generation: generation)
  }
  func captureLogicalRead() throws -> PagedNativeLogicalReadSnapshot {
    // Freeze/detach ONLY at an actual handoff. Undo capture below is cheaper.
    let snapshot = try source.capture(forPublication: true)
    return PagedNativeLogicalReadSnapshot(source: snapshot, sessionID: sessionID,
      arenaID: arenaID, generation: generation)
  }
  func isCurrent(_ captured: PagedNativeLogicalReadSnapshot) -> Bool {
    captured.sessionID == sessionID && captured.arenaID == arenaID && captured.generation == generation
      && captured.source.isSame(logicalWindow.snapshot) && !adopting
  }
  func admitLogicalRead(_ captured: PagedNativeLogicalReadSnapshot) throws {
    guard isCurrent(captured) else { throw BoomError.stale("Logical read belongs to an earlier native source.") }
  }
  func admitCapturedRecord(_ expected: PagedDocumentRootRecord) throws -> PagedNativeLogicalReadSnapshot {
    guard expected == sealedRootRecord, logicalWindow.snapshot.isSame(sealedSnapshot) else {
      throw BoomError.stale("Agent ranges belong to a different saved source; native input remains retained.")
    }
    return try captureLogicalRead()
  }
  func logicalOpeningHistory() throws -> PagedNativeLogicalHistoryProjection {
    guard let openingHistory, canonicalOpening != nil else { throw BoomError.stale("Logical history opening was already consumed.") }
    return openingHistory
  }
  func currentLogicalCursor(for selection: PagedNativeNavigationSelection) throws -> PagedNativeLogicalCursor {
    let summary = logicalWindow.snapshot.summary
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    guard !end.overflow, end.partialValue <= summary.utf16 else { throw BoomError.invalid("Selection is outside the logical source.") }
    let point: PagedTextSummary
    if selection.utf16Offset == 0 { point = PagedTextSummary(bytes: 0, utf16: 0, lfCount: 0) }
    else if selection.utf16Offset == summary.utf16 { point = summary }
    else if selection.utf16Offset >= logicalWindow.start.utf16,
      selection.utf16Offset - logicalWindow.start.utf16 <= logicalWindow.summary.utf16 {
      point = try logicalWindow.position(localUTF16: Int(selection.utf16Offset - logicalWindow.start.utf16))
    } else if selection.utf16Offset == working.currentCursor.utf16Offset {
      point = PagedTextSummary(bytes: working.currentCursor.byteOffset, utf16: selection.utf16Offset, lfCount: 0)
    } else { throw BoomError.stale("A distant selection endpoint requires its actual independent read proof.") }
    return PagedNativeLogicalCursor(byteOffset: point.bytes, utf16Offset: point.utf16,
      selectionLengthUTF16: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
  }
  func documentCoordinates() throws -> PagedNativeDocumentCoordinates {
    PagedNativeDocumentCoordinates(record: sealedRootRecord, sessionID: sessionID, arenaID: arenaID,
      generation: generation, windowID: logicalWindow.windowID, utf16Start: logicalWindow.start.utf16,
      localUTF16: localUTF16Count, projectedUTF16: logicalWindow.snapshot.summary.utf16,
      localBytes: Int(logicalWindow.summary.bytes))
  }
  func nativeSelection(_ range: NSRange) throws -> PagedWorkingSelection {
    if let owner = managedArenaOwner, owner.activeView?.selectedRange() == range,
      let actual = owner.currentOwnedDocumentSelection {
      return try working.selection(range, focusAtEnd: actual.focusAtEnd, affinity: actual.affinity)
    }
    let affinity = try managedArenaOwner?.activeView.map { try PagedSelectionAffinity(native: $0.selectionAffinity) } ?? .downstream
    return try working.selection(range, affinity: affinity)
  }
  func navigationSelection(_ range: NSRange) throws -> PagedNativeNavigationSelection {
    try working.cursor(for: nativeSelection(range)).selection
  }
  func nativeLocalBytes(_ range: NSRange) throws -> Range<Int> { try logicalWindow.localBytes(for: range) }
  func canReplace(_ range: NSRange, with replacement: String) throws {
    _ = try logicalWindow.localBytes(for: range)
    // No resulting-window or pending-save guard. Native oversized paste is
    // intercepted into the streamed domain path BEFORE calling this primitive.
    guard replacement.utf8.count <= PagedTextWindow.maximumBytes else {
      throw BoomError.invalid("Oversized native input must use the streamed replacement route.")
    }
  }
  func nativeCharacterTransactionWillBegin() throws {
    guard !adopting, !hookTransition, characterDepth < 32 else {
      throw BoomError.invalid("A physical source install cannot reenter a character primitive.")
    }
    characterDepth += 1
  }
  @discardableResult func replace(_ range: NSRange, with replacement: String, groupID: UUID,
    beforeSelection: PagedWorkingSelection? = nil) throws -> Bool {
    guard !adopting, characterDepth > 0 else { throw BoomError.invalid("Native source primitive has no character transaction.") }
    if working.requiresGroupClose(groupID) { emit(try working.closeNativeGroup(source: source)) }
    let cursor = try beforeSelection.map { try working.cursor(for: $0) } ?? working.currentCursor
    return try working.replace(range, with: replacement, groupID: groupID, beforeCursor: cursor, source: source)
  }
  @discardableResult func beginComposition(groupID: UUID? = nil) -> Bool {
    guard !adopting, !hookTransition else { return false }; working.beginComposition(groupID: groupID); return true
  }
  @discardableResult func endComposition() -> Bool {
    guard !adopting, !hookTransition else { return false }; working.endComposition()
    if characterDepth == 0 { do { emit(try working.closeNativeGroup(source: source)); requestCommit() } catch { fail(error) } }
    return true
  }
  @discardableResult func nativeCharacterTransactionDidClose(capturingSelectionFrom view: PagedNativeTextView? = nil) -> Bool {
    guard characterDepth > 0, !adopting else { return false }
    characterDepth -= 1
    guard characterDepth == 0 else { return true }
    do {
      if let view, let owner = managedArenaOwner, owner.activeView === view {
        try working.captureNativeAfterSelection(currentLogicalCursor(for: owner.currentDocumentSelection()))
      }
      if !working.isPinned { emit(try working.closeNativeGroup(source: source)) }
      requestCommit(); return true
    } catch { fail(error); return false }
  }
  @discardableResult func closeNativeGroup() throws -> PagedNativeGroupClosureReceipt? {
    guard characterDepth == 0, !working.isPinned, !adopting else { throw BoomError.stale("An actual native character/composition operation still owns the group.") }
    let receipt = try working.closeNativeGroup(source: source); emit(receipt); return receipt
  }
  private func emit(_ receipt: PagedNativeGroupClosureReceipt?) {
    guard let receipt else { return }
    notifyingGroup = true; defer { notifyingGroup = false }
    if let subscription { subscription.receiver?(subscription, receipt) }
    else { didCloseNativeGroup?(receipt) }
  }

  private func requirePhysicalQuiescence(requireSaved: Bool) throws {
    guard characterDepth == 0, !isPinned, !adopting, stage == nil, !hookTransition,
      !notifyingGroup, navigationOperations.isEmpty else {
      throw BoomError.stale("An actual native projection operation has not joined.")
    }
    if requireSaved {
      guard commitTask == nil, publication == nil, pendingCommitInstallation == nil,
        persistenceFailure == nil, sealedGeneration == generation else {
        throw BoomError.stale("Unsaved native source remains owned by this editor.")
      }
    }
  }
  func registerManagedArenaOwner(_ owner: PagedNativeInputOwner) throws {
    try requirePhysicalQuiescence(requireSaved: false)
    guard managedArenaOwner == nil, owner.session === self else { throw BoomError.denied("This native source already has its physical owner.") }
    managedArenaOwner = owner
  }
  func retireManagedArenaOwner(_ owner: PagedNativeInputOwner) { if managedArenaOwner === owner { managedArenaOwner = nil } }
  func registerNativeGroupSubscription(ownerID: UUID,
    onClose: @escaping (PagedNativeGroupSubscription, PagedNativeGroupClosureReceipt) -> Void,
    captureLogicalHistory: (() throws -> PagedNativeLogicalHistoryProjection)? = nil) throws -> PagedNativeGroupSubscription {
    try requirePhysicalQuiescence(requireSaved: false)
    guard subscription == nil, didCloseNativeGroup == nil else { throw BoomError.denied("Another native history owner holds this source.") }
    hookTransition = true; defer { hookTransition = false }
    let token = PagedNativeGroupSubscription(ownerID: ownerID, session: self, receiver: onClose, historyCapture: captureLogicalHistory)
    subscription = token; return token
  }
  func setLogicalHistoryCapture(_ token: PagedNativeGroupSubscription, ownerID: UUID,
    capture: @escaping () throws -> PagedNativeLogicalHistoryProjection) throws {
    try requireToken(token, ownerID: ownerID)
    guard !hookTransition, !notifyingGroup else { throw BoomError.stale("Actual native history hook is being delivered.") }
    token.historyCapture = capture
  }
  private func requireToken(_ token: PagedNativeGroupSubscription, ownerID: UUID) throws {
    guard subscription === token, token.session === self, token.ownerID == ownerID,
      token.sessionID == sessionID, token.receiver != nil else { throw BoomError.denied("Native hook belongs to another exact owner.") }
  }
  func requireNativeGroupSubscription(_ token: PagedNativeGroupSubscription, ownerID: UUID) throws {
    try requireToken(token, ownerID: ownerID); try requirePhysicalQuiescence(requireSaved: true)
  }
  func detachNativeGroupSubscription(_ token: PagedNativeGroupSubscription,
    ownerID: UUID, retiringClient: () -> Void = {}) throws {
    try requireNativeGroupSubscription(token, ownerID: ownerID)
    hookTransition = true; defer { hookTransition = false }
    retiringClient(); token.detach(); subscription = nil
  }
  func withCanonicalOpening(_ token: PagedNativeGroupSubscription, ownerID: UUID, completing: () -> Void) throws {
    try requireToken(token, ownerID: ownerID)
    guard canonicalOpening != nil, openingHistory != nil, generation == 0,
      !hookTransition, characterDepth == 0 else { throw BoomError.stale("Logical opening has already been exposed.") }
    hookTransition = true; defer { hookTransition = false }
    completing(); canonicalOpening = nil; openingHistory = nil
  }

  private func prepare(window: PagedNativeLogicalWindow, selection: PagedNativeNavigationSelection,
    cursor: PagedNativeLogicalCursor, before: PagedNativeLogicalSnapshot,
    kind: PagedNativeNavigationInstallationTicket.Kind, owner: PagedNativeInputOwner,
    provisionalArenaID: UUID = UUID()) throws -> PagedNativeNavigationInstallationTicket {
    guard stage == nil, !adopting, !hookTransition, characterDepth == 0, !isPinned,
      managedArenaOwner === owner, owner.session === self, owner.activeIdentity?.arenaID == arenaID,
      window.snapshot.sessionID == sessionID, window.snapshot.engineIncarnation == engineIncarnation,
      before.isSame(logicalWindow.snapshot) else { throw BoomError.stale("Prepared native projection has an earlier physical source.") }
    _ = try closeNativeGroup()
    guard before.isSame(logicalWindow.snapshot) else { throw BoomError.stale("Native group closure changed the prepared root.") }
    try cursor.validate(in: window.snapshot)
    let ticket = try PagedNativeNavigationInstallationTicket(owner: self, inputOwner: owner,
      window: window, selection: selection, cursor: cursor, before: before, kind: kind,
      provisionalArenaID: provisionalArenaID)
    stage = ticket; return ticket
  }
  func prepareLogicalWindowInstallation(_ window: PagedNativeLogicalWindow,
    selectingUTF16 selection: PagedNativeNavigationSelection, owner: PagedNativeInputOwner) throws -> PagedNativeNavigationInstallationTicket {
    guard window.snapshot.isSame(logicalWindow.snapshot) else { throw BoomError.stale("Displayed logical window is no longer current.") }
    let cursor = try cursor(selection, in: window)
    return try prepare(window: window, selection: selection, cursor: cursor,
      before: logicalWindow.snapshot, kind: .navigation, owner: owner)
  }
  private func cursor(_ selection: PagedNativeNavigationSelection, in window: PagedNativeLogicalWindow) throws -> PagedNativeLogicalCursor {
    if selection.utf16Offset >= window.start.utf16,
      selection.utf16Offset - window.start.utf16 <= window.summary.utf16 {
      let point = try window.position(localUTF16: Int(selection.utf16Offset - window.start.utf16))
      let cursor = PagedNativeLogicalCursor(byteOffset: point.bytes, utf16Offset: point.utf16,
        selectionLengthUTF16: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
      try cursor.validate(in: window.snapshot); return cursor
    }
    return try currentLogicalCursor(for: selection)
  }
  func prepareResidentRecenter(localFocusUTF16: Int, owner: PagedNativeInputOwner) throws -> PagedNativeNavigationInstallationTicket {
    guard needsRecentering else { throw BoomError.stale("Resident source does not require trimming.") }
    let window = try logicalWindow.trimmed(localFocusUTF16: localFocusUTF16)
    return try prepare(window: window, selection: working.currentCursor.selection, cursor: working.currentCursor,
      before: logicalWindow.snapshot, kind: .navigation, owner: owner)
  }
  func prepareResidentLogicalRestore(_ target: PagedNativeLogicalSnapshot, seed: PagedNativeLogicalWindowSeed,
    selection: PagedNativeLogicalCursor, owner: PagedNativeInputOwner) throws -> PagedNativeNavigationInstallationTicket {
    guard seed.snapshot.isSame(target), seed.containsFocusUTF16(selection.selection.focusUTF16), target.sessionID == sessionID,
      target.engineIncarnation == engineIncarnation else { throw BoomError.stale("Undo seed has another exact retained source.") }
    let window = try seed.preparedWindow()
    return try prepare(window: window, selection: selection.selection, cursor: selection,
      before: logicalWindow.snapshot, kind: .restore, owner: owner)
  }
  func prepareLogicalRestore(_ target: PagedNativeLogicalSnapshot, seed: PagedNativeLogicalWindowSeed?,
    selection: PagedNativeLogicalCursor, owner: PagedNativeInputOwner) async throws -> PagedNativeNavigationInstallationTicket {
    if let seed, seed.containsFocusUTF16(selection.selection.focusUTF16) {
      return try prepareResidentLogicalRestore(target, seed: seed, selection: selection, owner: owner)
    }
    let read = try captureLogicalRead()
    let operation = try beginNavigation(); defer { navigationOperations.remove(operation) }
    let cancellation = CancellationFlag()
    let window = try await withTaskCancellationHandler {
      let actual = try await readCursor(selection.selection, snapshot: target, cancellation: cancellation)
      guard actual == selection else { throw BoomError.invalid("Cold Undo cursor differs from its actual retained source.") }
      return try await storage.logicalWindow(target, utf16Anchor: selection.selection.focusUTF16,
        maximumBytes: PagedWorkingWindow.targetBytes, cancellation: cancellation)
    } onCancel: { cancellation.cancel() }
    try admitLogicalRead(read)
    return try prepare(window: window, selection: selection.selection, cursor: selection,
      before: read.source, kind: .restore, owner: owner)
  }
  private func readCursor(_ selection: PagedNativeNavigationSelection, snapshot: PagedNativeLogicalSnapshot,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalCursor {
    let end = selection.utf16Offset.addingReportingOverflow(selection.utf16Length)
    guard !end.overflow, end.partialValue <= snapshot.summary.utf16 else { throw BoomError.invalid("Selection exceeds its exact logical source.") }
    let lower = try await storage.logicalPosition(snapshot, utf16Offset: selection.utf16Offset, rounding: 0, cancellation: cancellation)
    if selection.utf16Length != 0 {
      _ = try await storage.logicalPosition(snapshot, utf16Offset: end.partialValue, rounding: 0, cancellation: cancellation)
    }
    return PagedNativeLogicalCursor(byteOffset: lower.bytes, utf16Offset: lower.utf16,
      selectionLengthUTF16: selection.utf16Length, focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
  }
  private func beginNavigation() throws -> UUID {
    guard navigationOperations.count < Self.maximumNavigationOperations else { throw BoomError.unavailable("Native reader admission is full; entered reads must join.") }
    let id = UUID(); navigationOperations.insert(id); return id
  }
  func prepareNavigationInstallation(owner: PagedNativeInputOwner, toUTF16 anchor: UInt64,
    selectingUTF16 selection: PagedNativeNavigationSelection, roundGeneratedAnchor: Bool = false) async throws -> PagedNativeNavigationInstallationTicket {
    _ = try closeNativeGroup()
    let read = try captureLogicalRead()
    let operation = try beginNavigation(); defer { navigationOperations.remove(operation) }
    let cancellation = CancellationFlag()
    let result = try await withTaskCancellationHandler {
      let actualAnchor = try await storage.logicalPosition(read.source, utf16Offset: anchor,
        rounding: roundGeneratedAnchor ? 2 : 0, cancellation: cancellation)
      // Explicit user/agent selections are never rounded. Generated collapsed
      // anchors follow only their already requested scalar normalization.
      let actualSelection = roundGeneratedAnchor && selection.utf16Length == 0 && selection.utf16Offset == anchor
        ? PagedNativeNavigationSelection(utf16Offset: actualAnchor.utf16, utf16Length: 0,
            focusAtEnd: selection.focusAtEnd, affinity: selection.affinity) : selection
      let cursor = try await readCursor(actualSelection, snapshot: read.source, cancellation: cancellation)
      let window = try await storage.logicalWindow(read.source, utf16Anchor: actualSelection.focusUTF16,
        maximumBytes: PagedWorkingWindow.targetBytes, cancellation: cancellation)
      return (window, cursor)
    } onCancel: { cancellation.cancel() }
    try admitLogicalRead(read)
    return try prepare(window: result.0, selection: result.1.selection, cursor: result.1,
      before: read.source, kind: .navigation, owner: owner)
  }
  func windowForStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket) throws -> PagedNativeLogicalWindow {
    try requireStage(ticket); return ticket.window
  }
  private func requireStage(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    guard stage === ticket, ticket.owner === self, ticket.isAwaitingAdoption,
      ticket.sessionID == sessionID, ticket.sourceArenaID == arenaID, ticket.sourceGeneration == generation,
      ticket.before.isSame(logicalWindow.snapshot), ticket.inputOwner === managedArenaOwner,
      ticket.inputOwner?.activeIdentity?.arenaID == arenaID, !adopting, !hookTransition,
      characterDepth == 0, !isPinned, ticket.candidate != nil else {
      throw BoomError.stale("Staged native window was superseded before physical consumption.")
    }
  }
  func cancelStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    guard stage === ticket, ticket.owner === self, ticket.isAwaitingAdoption, !adopting else {
      throw BoomError.stale("Another native installation owns cancellation.")
    }
    ticket.state = .cancelled; ticket.releaseBacking(); stage = nil
  }
  func withStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket,
    consuming: ((() -> Void) -> Void),
    installing: (PagedNativeLogicalWindow, UUID, NSRange) -> Void) throws -> PagedNativeLogicalWindow {
    try requireStage(ticket)
    let window = ticket.window
    let next: UInt64
    switch ticket.kind {
    case .navigation: next = generation
    case .restore, .edit:
      let checked = generation.addingReportingOverflow(1)
      guard !checked.overflow else { throw BoomError.budget("Logical source generation is exhausted.") }
      next = checked.partialValue
    }
    // All fallible source admission, seed/scalar allocation and arithmetic
    // are complete. Only this synchronous lexical consumer can now adopt.
    adopting = true
    defer { adopting = false }
    var consumed = false
    withoutActuallyEscaping(installing) { temporaryInstalling in
      consuming {
        precondition(!consumed)
        consumed = true
        if !window.snapshot.isSame(ticket.before) { source.installPrepared(window.snapshot) }
        working.installPrepared(window: window, arenaID: ticket.provisionalArenaID,
          generation: next, cursor: ticket.cursor)
        ticket.state = .consumed; stage = nil
        ticket.sourceTransfer?(); ticket.sourceTransfer = nil
        temporaryInstalling(window, ticket.provisionalArenaID, ticket.localSelection)
      }
    }
    precondition(consumed, "Actual Foundation target must consume its prepared source")
    ticket.releaseBacking()
    if case .edit(let receipt) = ticket.kind { emit(receipt) }
    return window
  }
  func prepareLogicalReplacementIfResident(selection: PagedNativeNavigationSelection, replacement: Data,
    owner: PagedNativeInputOwner, groupID: UUID = UUID()) throws -> PagedNativeNavigationInstallationTicket? {
    guard let text = String(data: replacement, encoding: .utf8) else { throw BoomError.invalid("Replacement is not UTF8.") }
    _ = try closeNativeGroup()
    let before = logicalWindow
    guard let candidate = try source.prepareResidentReplacement(in: before, selection: selection, replacement: text) else { return nil }
    let beforeCursor = try currentLogicalCursor(for: owner.currentDocumentSelection())
    let afterCursor = PagedNativeLogicalCursor(byteOffset: candidate.cursor.bytes, utf16Offset: candidate.cursor.utf16)
    guard candidate.changed else {
      return try prepare(window: before, selection: afterCursor.selection, cursor: afterCursor,
        before: before.snapshot, kind: .navigation, owner: owner)
    }
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Logical generation is exhausted.") }
    let installedArena = UUID()
    let actualBeforeFocus = beforeCursor.selection.focusUTF16
    let beforeSeed = actualBeforeFocus >= before.start.utf16 && actualBeforeFocus - before.start.utf16 <= before.summary.utf16
      ? try before.makeSeed(localFocusUTF16: Int(actualBeforeFocus - before.start.utf16)) : nil
    let receipt = try PagedNativeGroupClosureReceipt(sessionID: sessionID, arenaID: installedArena,
      effectiveGroupID: groupID, firstSequence: next.partialValue, lastSequence: next.partialValue,
      localCaretUTF16: Int(candidate.cursor.utf16 - candidate.window.start.utf16), hasEffectiveSourceChange: true,
      beforeSnapshot: before.snapshot, snapshot: candidate.window.snapshot, beforeCursor: beforeCursor, cursor: afterCursor,
      beforeSeed: beforeSeed,
      seed: candidate.window.makeSeed(localFocusUTF16: Int(candidate.cursor.utf16 - candidate.window.start.utf16)))
    return try prepare(window: candidate.window, selection: afterCursor.selection, cursor: afterCursor,
      before: before.snapshot, kind: .edit(receipt), owner: owner, provisionalArenaID: installedArena)
  }

  private func prepareEdit(_ candidate: PagedNativeLogicalEdit, read: PagedNativeLogicalReadSnapshot,
    beforeCursor: PagedNativeLogicalCursor, afterSelection: PagedNativeNavigationSelection? = nil,
    owner: PagedNativeInputOwner, groupID: UUID) throws -> PagedNativeNavigationInstallationTicket {
    try admitLogicalRead(read)
    let selected = afterSelection ?? candidate.selection
    let afterCursor = PagedNativeLogicalCursor(byteOffset: candidate.cursor.bytes, utf16Offset: candidate.cursor.utf16,
      selectionLengthUTF16: selected?.utf16Length ?? 0,
      focusAtEnd: selected?.focusAtEnd ?? false, affinity: selected?.affinity ?? .downstream)
    guard selected == nil || selected?.utf16Offset == candidate.cursor.utf16 else {
      throw BoomError.invalid("Prepared edit has another actual after-selection endpoint.")
    }
    if !candidate.changed {
      return try prepare(window: candidate.window, selection: afterCursor.selection, cursor: afterCursor,
        before: read.source, kind: .navigation, owner: owner)
    }
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("Logical generation is exhausted.") }
    let installedArena = UUID(), before = logicalWindow
    let beforeFocus = beforeCursor.selection.focusUTF16, afterFocus = afterCursor.selection.focusUTF16
    let beforeSeed = beforeFocus >= before.start.utf16 && beforeFocus - before.start.utf16 <= before.summary.utf16
      ? try before.makeSeed(localFocusUTF16: Int(beforeFocus - before.start.utf16)) : nil
    let afterSeed = afterFocus >= candidate.window.start.utf16 && afterFocus - candidate.window.start.utf16 <= candidate.window.summary.utf16
      ? try candidate.window.makeSeed(localFocusUTF16: Int(afterFocus - candidate.window.start.utf16)) : nil
    let receipt = PagedNativeGroupClosureReceipt(sessionID: sessionID, arenaID: installedArena,
      effectiveGroupID: groupID, firstSequence: next.partialValue, lastSequence: next.partialValue,
      localCaretUTF16: Int(afterFocus - candidate.window.start.utf16), hasEffectiveSourceChange: true,
      beforeSnapshot: read.source, snapshot: candidate.window.snapshot, beforeCursor: beforeCursor, cursor: afterCursor,
      beforeSeed: beforeSeed, seed: afterSeed)
    return try prepare(window: candidate.window, selection: afterCursor.selection, cursor: afterCursor,
      before: read.source, kind: .edit(receipt), owner: owner, provisionalArenaID: installedArena)
  }
  func prepareLogicalReplacement(selection: PagedNativeNavigationSelection, replacement: Data,
    owner: PagedNativeInputOwner, groupID: UUID = UUID()) async throws -> PagedNativeNavigationInstallationTicket {
    _ = try closeNativeGroup()
    let read = try captureLogicalRead()
    let beforeCursor = try currentLogicalCursor(for: owner.currentDocumentSelection())
    let operation = try beginNavigation(); defer { navigationOperations.remove(operation) }
    let cancellation = CancellationFlag()
    let candidate = try await withTaskCancellationHandler {
      try await storage.logicalReplacement(read.source, selection: selection, replacement: replacement, cancellation: cancellation)
    } onCancel: { cancellation.cancel() }
    return try prepareEdit(candidate, read: read, beforeCursor: beforeCursor, owner: owner, groupID: groupID)
  }

  func requireJoinedNativeClose() throws { try requirePhysicalQuiescence(requireSaved: true) }
  private func readCommand(_ captured: PagedNativeLogicalReadSnapshot,
    request: PagedNativeLogicalCommand) async throws -> PagedNativeLogicalCommandResult {
    try admitLogicalRead(captured)
    let operation = try beginNavigation(); defer { navigationOperations.remove(operation) }
    let cancellation = CancellationFlag()
    let value = try await withTaskCancellationHandler {
      try await storage.logicalCommand(captured.source, command: request, cancellation: cancellation)
    } onCancel: { cancellation.cancel() }
    try admitLogicalRead(captured); return value
  }
  func logicalGraphemeBoundary(_ captured: PagedNativeLogicalReadSnapshot, atUTF16 offset: UInt64,
    forward: Bool) async throws -> PagedTextSummary {
    guard case .point(let result) = try await readCommand(captured, request: .grapheme(offset, forward)),
      result.utf16 <= captured.source.summary.utf16 else { throw BoomError.invalid("Logical grapheme seek returned another result.") }
    return result
  }
  /// Preserve Cocoa's observed bidi target; normalize only an incomplete
  /// grapheme at that actual target, approaching from the observed side.
  func logicalGraphemeBoundary(_ captured: PagedNativeLogicalReadSnapshot, atNativeUTF16 target: UInt64,
    forward: Bool) async throws -> PagedTextSummary {
    try admitLogicalRead(captured)
    let extent = captured.source.summary.utf16
    guard target <= extent else { throw BoomError.invalid("Native target exceeds its logical source.") }
    if target == 0 { return PagedTextSummary(bytes: 0, utf16: 0, lfCount: 0) }
    if target == extent { return captured.source.summary }
    let cancellation = CancellationFlag()
    let point = try await withTaskCancellationHandler {
      try await storage.logicalPosition(captured.source, utf16Offset: forward ? target - 1 : target + 1,
        rounding: forward ? 1 : 2, cancellation: cancellation)
    } onCancel: { cancellation.cancel() }
    let result = try await logicalGraphemeBoundary(captured, atUTF16: point.utf16, forward: forward)
    guard forward ? result.utf16 >= target : result.utf16 <= target else { throw BoomError.invalid("Native target lost its actual cluster.") }
    return result
  }
  func logicalParagraphBounds(_ captured: PagedNativeLogicalReadSnapshot, atUTF16 offset: UInt64,
    includeLineEndings: Bool = true) async throws -> PagedTextParagraphBounds {
    guard case .paragraph(let bounds) = try await readCommand(captured, request: .paragraph(offset, includeLineEndings)) else {
      throw BoomError.invalid("Logical paragraph seek returned another result.")
    }
    let summary = captured.source.summary
    guard bounds.start.bytes <= bounds.contentEnd.bytes, bounds.contentEnd.bytes <= bounds.end.bytes,
      bounds.start.utf16 <= offset, offset <= bounds.end.utf16, bounds.end.utf16 <= summary.utf16,
      bounds.start.utf16 <= bounds.contentEnd.utf16, bounds.contentEnd.utf16 <= bounds.end.utf16,
      bounds.end.bytes <= summary.bytes, bounds.end.lfCount <= summary.lfCount,
      bounds.start.lfCount <= bounds.contentEnd.lfCount, bounds.contentEnd.lfCount <= bounds.end.lfCount,
      bounds.terminated == (bounds.contentEnd.bytes < bounds.end.bytes),
      !bounds.lfTerminated || bounds.end.lfCount - bounds.contentEnd.lfCount == 1 else {
      throw BoomError.invalid("Logical paragraph lost its actual source coordinates.")
    }
    return bounds
  }
  private func prepareLogicalCommand(_ request: PagedNativeLogicalCommand, owner: PagedNativeInputOwner,
    expected: PagedNativeLogicalReadSnapshot? = nil, groupID: UUID = UUID()) async throws -> PagedNativeNavigationInstallationTicket {
    _ = try closeNativeGroup()
    let read = try captureLogicalRead()
    if let expected { try admitLogicalRead(expected) }
    let beforeCursor = try currentLogicalCursor(for: owner.currentDocumentSelection())
    guard case .edit(let candidate) = try await readCommand(read, request: request) else {
      throw BoomError.invalid("Logical command returned no prepared source.")
    }
    let ticket = try prepareEdit(candidate, read: read, beforeCursor: beforeCursor, owner: owner, groupID: groupID)
    if case .imported(_, let imported) = request {
      do { ticket.sourceTransfer = try storage.prepareImportedSourceTransfer(imported, sessionID: sessionID) }
      catch { try cancelStagedNavigationInstallation(ticket); throw error }
    }
    return ticket
  }
  func prepareLogicalEdits(expected: PagedNativeLogicalReadSnapshot, edits: [PagedTextLocalEdit],
    afterSelection: PagedNativeNavigationSelection?, owner: PagedNativeInputOwner) async throws -> PagedNativeNavigationInstallationTicket {
    try await prepareLogicalCommand(.edits(edits, afterSelection), owner: owner, expected: expected)
  }
  func prepareLogicalLinePrefix(selection: PagedNativeNavigationSelection, prefix: String,
    owner: PagedNativeInputOwner) async throws -> PagedNativeNavigationInstallationTicket {
    try await prepareLogicalCommand(.linePrefix(selection, prefix), owner: owner)
  }
  func prepareLogicalWrapping(selection: PagedNativeNavigationSelection, prefix: String, suffix: String,
    toggles: Bool, owner: PagedNativeInputOwner) async throws -> PagedNativeNavigationInstallationTicket {
    try await prepareLogicalCommand(.wrapping(selection, prefix, suffix, toggles), owner: owner)
  }
  func prepareLogicalImportedReplacement(selection: PagedNativeNavigationSelection,
    imported: PagedTextCustodiedValue<PagedTextImportedRevision>, owner: PagedNativeInputOwner) async throws -> PagedNativeNavigationInstallationTicket {
    try await prepareLogicalCommand(.imported(selection, imported), owner: owner)
  }

  /// Saver capture takes the actual SDK projection only outside its lexical
  /// advance/notification scope. No duplicate Undo stack exists in Session.
  private func capturePublication() throws -> PagedNativeLogicalPublication {
    _ = try closeNativeGroup()
    guard let subscription, let capture = subscription.historyCapture else {
      throw BoomError.invalid("Native saver requires its actual Foundation projection.")
    }
    let history = try capture()
    try history.validate()
    guard history.snapshot.isSame(logicalWindow.snapshot), history.generation == generation,
      history.snapshot.sessionID == sessionID else { throw BoomError.stale("Foundation source capture differs from the native head.") }
    _ = try source.capture(forPublication: true)
    let first = sealedGeneration.addingReportingOverflow(1)
    guard !first.overflow, first.partialValue <= generation else { throw BoomError.invalid("Native save has no accepted source prefix.") }
    // The publication window is only a bounded byte readback hint. It is
    // NEVER a cursor/selection seed; actual global cursor comes from the SDK
    // projection and is independently verified against the materialized root.
    let localFocus = managedArenaOwner?.activeView?.selectedRange().location ?? 0
    let capturedWindow = try logicalWindow.trimmed(localFocusUTF16: localFocus, maximumBytes: PagedWorkingWindow.hardBytes)
    return PagedNativeLogicalPublication(publicationID: UUID(), sessionID: sessionID,
      firstSequence: first.partialValue, generation: generation, expectedRecord: sealedRootRecord,
      history: history, window: capturedWindow)
  }
  func requestCommit() {
    guard commitTask == nil, persistenceFailure == nil, generation > sealedGeneration,
      characterDepth == 0, !isPinned, !adopting, !notifyingGroup, !hookTransition, canonicalOpening == nil else { return }
    commitTask = Task { [self] in
      var latest: PagedNativeCommitAcknowledgement?
      var attempting: PagedNativeLogicalPublication?
      var startingSerial = persistenceFailureSerial
      defer {
        commitTask = nil; saveDelay = nil
        // One captured snapshot per Task. A continuous stream of later keys
        // cannot prevent a caller's already saved prefix from joining.
        requestCommit()
      }
      do {
        if generation > sealedGeneration {
          if !expeditingSave {
            let delay = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 75_000_000) }
            saveDelay = delay; await delay.value; saveDelay = nil
          }
          guard characterDepth == 0, !isPinned, !adopting, !notifyingGroup, !hookTransition else { return latest }
          let captured = try capturePublication()
          publication = captured
          attempting = captured; startingSerial = persistenceFailureSerial
          let ack = try await storage.publishLogical(captured)
          // Same captured output advances ONLY the durable checkpoint. Later
          // typing/Undo/navigation keep their logical head/arena/window.
          guard ack.sessionID == sessionID, ack.batchID == captured.publicationID,
            ack.lastSequence == captured.generation, ack.expectedRootRecord == captured.expectedRecord else {
            throw BoomError.invalid("Logical saver returned another actual captured prefix.")
          }
          pendingCommitInstallation = ack
          try await storage.finishLogicalPublication(ack)
          sealedRootRecord = ack.sealedRootRecord; sealedRevision = ack.sealedWindow.revision
          sealedGeneration = captured.generation; sealedSnapshot = captured.history.snapshot
          pendingCommitInstallation = nil; publication = nil; latest = ack
          if persistenceFailureSerial == startingSerial && !failureSerialExhausted {
            persistenceFailure = nil; failedPublicationSerial = nil
          }
          didSeal?(ack.sealedWindow)
        }
        return latest
      } catch {
        if let attempting { failPublication(error, publication: attempting, startingSerial: startingSerial) }
        else { fail(error) }
        return nil
      }
    }
  }
  func flushRecord(through requested: UInt64) async throws -> PagedDocumentRootRecord {
    guard requested <= generation else { throw BoomError.stale("Save cannot capture a future native generation.") }
    expeditingSave = true; saveDelay?.cancel()
    defer { expeditingSave = false }
    while sealedGeneration < requested || pendingCommitInstallation != nil {
      if let persistenceFailure { throw persistenceFailure }
      requestCommit()
      guard let task = commitTask else { throw BoomError.stale("An actual native composition/source operation has not closed for saving.") }
      _ = await task.value
    }
    if let persistenceFailure { throw persistenceFailure }
    return sealedRootRecord
  }
  func flush(through generation: UInt64) async throws -> PagedTextRevision {
    try await flushRecord(through: generation).document.revision
  }
  /// A user-requested Save can explicitly receive/retry the original failed
  /// snapshot. Native text/Undo/read operations never call or await this.
  var failedSaveIdentity: UUID? {
    guard commitTask == nil, persistenceFailure != nil, !failureSerialExhausted,
      failedPublicationSerial == persistenceFailureSerial else { return nil }
    return publication?.publicationID
  }
  func retryFailedSave(expectedIdentity: UUID) async throws -> PagedDocumentRootRecord {
    guard failedSaveIdentity == expectedIdentity, let captured = publication else {
      throw BoomError.stale("No joined original native save awaits an explicit retry.")
    }
    let serial = persistenceFailureSerial
    let task = Task<PagedNativeCommitAcknowledgement?, Never> { [self] in
      defer { commitTask = nil }
      do {
        let ack: PagedNativeCommitAcknowledgement
        if let pendingCommitInstallation { ack = pendingCommitInstallation }
        else { ack = try await storage.resumeLogicalPublication(captured) }
        guard ack.sessionID == sessionID, ack.batchID == captured.publicationID,
          ack.lastSequence == captured.generation, ack.expectedRootRecord == captured.expectedRecord else {
          throw BoomError.stale("Save retry returned another original snapshot.")
        }
        pendingCommitInstallation = ack
        try await storage.finishLogicalPublication(ack)
        sealedRootRecord = ack.sealedRootRecord; sealedRevision = ack.sealedWindow.revision
        sealedGeneration = captured.generation; sealedSnapshot = captured.history.snapshot
        pendingCommitInstallation = nil; publication = nil
        if !failureSerialExhausted, persistenceFailureSerial == serial {
          persistenceFailure = nil; failedPublicationSerial = nil
        }
        didSeal?(ack.sealedWindow); return ack
      } catch { failPublication(error, publication: captured, startingSerial: serial); return nil }
    }
    commitTask = task
    guard await task.value != nil else { throw persistenceFailure! }
    if let persistenceFailure { throw persistenceFailure }
    requestCommit()
    return sealedRootRecord
  }
  func joinPendingSave() async { _ = await commitTask?.value }
  private func failPublication(_ error: Error, publication failed: PagedNativeLogicalPublication,
    startingSerial: UInt64) {
    let ownedFailure = persistenceFailureSerial == startingSerial &&
      (persistenceFailure == nil || failedPublicationSerial == startingSerial)
    fail(error)
    if ownedFailure, !failureSerialExhausted, publication?.publicationID == failed.publicationID {
      failedPublicationSerial = persistenceFailureSerial
    }
  }
  private func fail(_ error: Error) {
    failedPublicationSerial = nil
    let next = persistenceFailureSerial.addingReportingOverflow(1)
    if next.overflow { failureSerialExhausted = true } else { persistenceFailureSerial = next.partialValue }
    if persistenceFailure == nil { persistenceFailure = error }
    didFail?(error)
  }
}

struct PagedNativeHistoryHandle: Sendable, Equatable {
  enum Direction: Sendable { case undo, redo }
  let documentID: UUID
  let groupID: UUID
  let direction: Direction
  var inverse: Self { Self(documentID: documentID, groupID: groupID, direction: direction == .undo ? .redo : .undo) }
}
