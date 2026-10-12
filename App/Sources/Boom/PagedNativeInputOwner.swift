import AppKit
import BoomCore
import Foundation
import Synchronization

/// The physical installation window is stable through ordinary storage ACKs.
/// A new sealed-window UUID is not an instruction to rebind an input client.
struct PagedNativeInputIdentity: Equatable {
  let ownerID: UUID
  let sessionID: UUID
  let clientID: UUID
  let arenaID: UUID
  let installationWindowID: UUID
}

struct PagedNativeSelectionObservation: Equatable {
  let identity: PagedNativeInputIdentity
  let inputLease: PagedNativeReplayInputLease
  let generation: UInt64
  let selectionEpoch: UInt64
  let range: NSRange
  let affinity: NSSelectionAffinity
}

/// Original key events have no interpreted range. Their replay still requires
/// the same physical focus and keyboard epoch, or this owner's exact mount.
struct PagedNativeReplayInputLease: Equatable {
  let identity: PagedNativeInputIdentity
  let focusEpoch: UInt64
  let keyboardEpoch: UInt64
  let keyboardID: String?
  let windowID: ObjectIdentifier?
  let isFirstResponder: Bool
  let isKeyWindow: Bool
}

struct PagedNativeReplayInputTransition {
  fileprivate let source: PagedNativeReplayInputLease
  fileprivate let target: PagedNativeReplayInputLease
  fileprivate init(source: PagedNativeReplayInputLease, target: PagedNativeReplayInputLease) {
    self.source = source; self.target = target
  }
  func rebase(_ lease: PagedNativeReplayInputLease) throws -> PagedNativeReplayInputLease {
    guard lease == source else {
      throw BoomError.stale("Deferred native input has another physical source lease.")
    }
    return target
  }
}

/// A preflight for this exact physical graph. The command owner consumes it
/// synchronously inside the Session's hook-retirement fence, before any
/// framework deactivation or callback disposal. It is not a producer join.
@MainActor final class PagedNativeInputRetirementTicket {
  fileprivate weak var owner: PagedNativeInputOwner?
  fileprivate weak var commandOwner: PagedNativeUndoOwner?
  fileprivate let view: PagedNativeTextView
  fileprivate let identity: PagedNativeInputIdentity
  fileprivate let generation: UInt64
  fileprivate let arenaID: UUID
  fileprivate var consumed = false

  fileprivate init(owner: PagedNativeInputOwner, commandOwner: PagedNativeUndoOwner?,
    view: PagedNativeTextView, identity: PagedNativeInputIdentity) {
    self.owner = owner; self.commandOwner = commandOwner
    self.view = view; self.identity = identity
    generation = owner.session.generation; arenaID = owner.session.arenaID
  }
}

/// Notification delivery advances a fixed scalar synchronously even when its
/// producer is not Main. An A/B/A source switch cannot hide behind equality
/// of the final keyboard name. No notification payload or source text stays.
private final class PagedNativeInputEpoch: Sendable {
  private let counter = Mutex<UInt64>(0)
  func advance() { counter.withLock { if $0 < UInt64.max { $0 += 1 } } }
  func read() throws -> UInt64 {
    try counter.withLock {
      guard $0 < UInt64.max else { throw BoomError.budget("Native input epoch is exhausted.") }
      return $0
    }
  }
}

private final class PagedNativeInputObservers {
  let tokens: [NSObjectProtocol]
  init(focus: PagedNativeInputEpoch, keyboard: PagedNativeInputEpoch) {
    let center = NotificationCenter.default
    tokens = [
      center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
        object: nil, queue: nil) { _ in keyboard.advance() },
      center.addObserver(forName: NSWindow.didBecomeKeyNotification,
        object: nil, queue: nil) { _ in focus.advance() },
      center.addObserver(forName: NSWindow.didResignKeyNotification,
        object: nil, queue: nil) { _ in focus.advance() }
    ]
  }
  deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// One binding is constructed for one physical NSTextView. It is never
/// retargeted to another arena. AppKit callbacks carry the view's binding,
/// rather than acquiring the owner's current storage at callback time.
@MainActor final class PagedNativeInputBinding {
  enum State: Equatable { case staged, active, retired }
  let identity: PagedNativeInputIdentity
  weak var owner: PagedNativeInputOwner?
  private(set) var state: State = .staged
  private(set) var selectionEpoch: UInt64 = 0
  private(set) var commandDepth = 0
  private(set) var firstRefusal: Error?

  fileprivate init(identity: PagedNativeInputIdentity) { self.identity = identity }

  func admitsInput(in session: PagedNativeSession, requiresCommand: Bool = false) throws {
    guard state == .active, let owner, owner.activeIdentity == identity,
      session.sessionID == identity.sessionID, session.arenaID == identity.arenaID else {
      throw BoomError.stale("This input client still belongs to its earlier source window.")
    }
    guard !owner.isAdopting, owner.firstRefusal == nil, !requiresCommand || commandDepth > 0 else {
      throw BoomError.stale("This input callback has no admitted source command.")
    }
  }

  func beginCommand(in session: PagedNativeSession) throws {
    try admitsInput(in: session)
    guard commandDepth < 32 else { throw BoomError.budget("Native input command nesting exceeds its bound.") }
    commandDepth += 1
  }

  func endCommand() {
    precondition(commandDepth > 0)
    commandDepth -= 1
  }

  func requireSelectionCapacity() throws {
    guard selectionEpoch < UInt64.max else { throw BoomError.budget("Native selection identity is exhausted.") }
  }

  func recordSelectionChange() {
    precondition(selectionEpoch < UInt64.max)
    selectionEpoch += 1
  }

  func recordRefusal(_ error: Error) {
    guard state != .retired else { return }
    if firstRefusal == nil { firstRefusal = error }
    owner?.recordRefusal(error, binding: self)
  }

  fileprivate func activate() { precondition(state == .staged); state = .active }
  fileprivate func retire() {
    precondition(commandDepth == 0)
    state = .retired
    // Preserve the weak edge for the owner's existing mount/focus accounting.
    // Text, commands and refusal delivery still require active admission.
  }
}

/// Physical clients for the staged-installation component. The ordinary
/// product factory does not construct this owner yet. Keep one active view
/// and at most one staged view; old contexts own only inert, weak-target
/// clients. Normal reference lifetime handles their physical reclamation.
/// Actual source/history tasks remain owned by the session and backend.
@MainActor final class PagedNativeInputOwner {
  private struct PhysicalClient {
    let view: PagedNativeTextView
    let context: NSTextInputContext?
  }
  private enum StageTicket {
    case history(PagedNativeHistoryInstallationTicket)
    case navigation(PagedNativeNavigationInstallationTicket)
  }
  private struct StagedClient {
    let ticket: StageTicket
    let client: PhysicalClient
    let sourceSelection: PagedNativeSelectionObservation
    let sourceKeyboardID: String?
    let sourceWindow: NSWindow?
  }

  let ownerID = UUID()
  let session: PagedNativeSession
  weak var commandOwner: PagedNativeUndoOwner?
  private(set) var activeView: PagedNativeTextView!
  private var activeContext: NSTextInputContext?
  private var stagedClient: StagedClient?
  private let focusEpoch = PagedNativeInputEpoch()
  private let keyboardEpoch = PagedNativeInputEpoch()
  private var observers: PagedNativeInputObservers?
  private(set) var isAdopting = false
  private(set) var canonicalActivationPending = false
  private(set) var lastReplayTransition: PagedNativeReplayInputTransition?
  private(set) var firstRefusal: Error?
  private(set) var refusedClientIDs: Set<UUID> = []
  // Presentation hooks belong to this existing physical owner. Retired clients
  // never reacquire them through a current-view lookup.
  private var documentKey: ((NSEvent, PagedNativeTextView) -> Bool)?
  private var documentCommand: ((Selector, PagedNativeSelectionObservation) throws -> Void)?

  func installDocumentNavigation(key: @escaping (NSEvent, PagedNativeTextView) -> Bool,
    command: @escaping (Selector, PagedNativeSelectionObservation) throws -> Void) throws {
    guard documentKey == nil, documentCommand == nil, activeView != nil,
      !isAdopting, firstRefusal == nil else {
      throw BoomError.stale("The physical input already has its document navigation consumer.")
    }
    documentKey = key; documentCommand = command
  }
  func interceptDocumentKey(_ event: NSEvent, from view: PagedNativeTextView) -> Bool {
    guard activeView === view, view.inputBinding?.state == .active,
      view.inputBinding?.identity == activeIdentity else { return false }
    return documentKey?(event, view) ?? false
  }
  func handlesDocumentCommand(_ selector: Selector) -> Bool {
    documentCommand != nil && (selector == NSSelectorFromString("moveToBeginningOfDocument:")
      || selector == NSSelectorFromString("moveToEndOfDocument:")
      || selector == NSSelectorFromString("moveToBeginningOfDocumentAndModifySelection:")
      || selector == NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")
      || selector == NSSelectorFromString("selectAll:"))
  }
  func dispatchDocumentCommand(_ selector: Selector,
    observed: PagedNativeSelectionObservation) throws {
    guard handlesDocumentCommand(selector), let documentCommand,
      try observeSelection() == observed, activeView.inputCommandIsClosed,
      !activeView.hasMarkedText() else {
      throw BoomError.stale("Document movement lost its actual source command or physical selection.")
    }
    try documentCommand(selector, observed)
  }

  var activeIdentity: PagedNativeInputIdentity? { activeView?.inputBinding?.identity }
  var retainedClientCount: Int { (activeView == nil ? 0 : 1) + (stagedClient == nil ? 0 : 1) }
  var hasStagedClient: Bool { stagedClient != nil }

  init(frame: NSRect, session: PagedNativeSession) throws {
    self.session = session
    try session.registerManagedArenaOwner(self)
    do {
      let window = try session.windowForNativeInstallation()
      let binding = makeBinding(arenaID: session.arenaID, windowID: window.windowID)
      let view = try PagedNativeTextView(frame: frame, session: session,
        inputBinding: binding, stagedTicket: nil, canonicalOpening: session.canonicalOpening)
      activeView = view
      binding.owner = self
      canonicalActivationPending = session.canonicalOpening != nil
      if !canonicalActivationPending { binding.activate() }
      // The view owns its context; the context owns its immutable weak-target
      // client through an association. No context can retain this view graph.
      activeContext = view.inputContext
      observers = PagedNativeInputObservers(focus: focusEpoch, keyboard: keyboardEpoch)
    } catch {
      session.retireManagedArenaOwner(self)
      throw error
    }
  }

  /// The command owner calls this inside Session.withCanonicalOpening after actual
  /// Foundation hydration. No AppKit queries/yields occur after activation.
  func completeCanonicalOpening(commandOwner: PagedNativeUndoOwner) {
    precondition(canonicalActivationPending && self.commandOwner === commandOwner)
    precondition(activeView?.inputBinding?.state == .staged && activeView?.inputBinding?.owner === self)
    precondition(activeIdentity?.sessionID == session.sessionID && activeIdentity?.arenaID == session.arenaID)
    precondition(session.generation == 0 && session.canonicalOpening != nil)
    activeView.inputBinding!.activate()
    canonicalActivationPending = false
  }

  private func makeBinding(arenaID: UUID, windowID: UUID) -> PagedNativeInputBinding {
    PagedNativeInputBinding(identity: PagedNativeInputIdentity(ownerID: ownerID,
      sessionID: session.sessionID, clientID: UUID(), arenaID: arenaID,
      installationWindowID: windowID))
  }

  func observeSelection() throws -> PagedNativeSelectionObservation {
    guard let activeView, let binding = activeView.inputBinding else {
      throw BoomError.stale("The native input owner has no active physical client.")
    }
    try binding.admitsInput(in: session)
    guard activeView.selectedRanges.count == 1 else {
      throw BoomError.unavailable("Multiple native selections require their own bounded owner.")
    }
    return PagedNativeSelectionObservation(identity: binding.identity,
      inputLease: try physicalInputLease(for: activeView),
      generation: session.generation, selectionEpoch: binding.selectionEpoch,
      range: activeView.selectedRange(), affinity: activeView.selectionAffinity)
  }

  func inputLease(for view: PagedNativeTextView) throws -> PagedNativeReplayInputLease {
    guard view === activeView, let binding = view.inputBinding else {
      throw BoomError.stale("A native input lease requires its active physical client.")
    }
    try binding.admitsInput(in: session)
    return try physicalInputLease(for: view)
  }

  private func physicalInputLease(for view: PagedNativeTextView) throws -> PagedNativeReplayInputLease {
    guard let identity = view.inputBinding?.identity, identity.ownerID == ownerID else {
      throw BoomError.stale("This physical input client belongs to another owner.")
    }
    let window = view.window
    return PagedNativeReplayInputLease(identity: identity,
      focusEpoch: try focusEpoch.read(), keyboardEpoch: try keyboardEpoch.read(),
      keyboardID: view.inputContext?.selectedKeyboardInputSource,
      windowID: window.map(ObjectIdentifier.init),
      isFirstResponder: window?.firstResponder === view, isKeyWindow: window?.isKeyWindow ?? false)
  }

  func recordFocusTransition(from view: PagedNativeTextView) {
    guard let binding = view.inputBinding, binding.owner === self,
      binding.identity == activeIdentity || isAdopting else { return }
    focusEpoch.advance()
  }

  /// No storage request, source move, stage, context or mount is needed when
  /// this joined projection already has the exact target extent. Any changed
  /// range uses the SAME native client with actual selection/epoch admission.
  func reuseJoinedNavigationWindow(toUTF16 anchor: UInt64, selection: PagedNativeNavigationSelection,
    observedSelection observed: PagedNativeSelectionObservation) throws -> PagedTextWindow? {
    try requirePhysicalStageSource(observed)
    guard let cached = try session.joinedNavigationWindow(owner: self, toUTF16: anchor, selection: selection) else { return nil }
    let view = activeView!
    let changesRange = cached.localSelection != observed.range
    let epoch = observed.selectionEpoch.addingReportingOverflow(changesRange ? 1 : 0)
    guard !epoch.overflow else { throw BoomError.budget("Joined native selection identity is exhausted.") }
    if changesRange {
      view.setSelectedRange(cached.localSelection, affinity: observed.affinity, stillSelecting: false)
    }
    let after = try observeSelection()
    guard activeView === view, after.identity == observed.identity, after.generation == observed.generation,
      after.inputLease == observed.inputLease, after.selectionEpoch == epoch.partialValue,
      after.range == cached.localSelection, after.affinity == observed.affinity,
      firstRefusal == nil, view.boundedStorage.mutationFailure == nil,
      let joined = try session.joinedNavigationWindow(owner: self, toUTF16: anchor, selection: selection),
      joined.window.windowID == cached.window.windowID, joined.localSelection == cached.localSelection else {
      throw BoomError.stale("The exact joined native range/input/source changed during selection reuse.")
    }
    return cached.window
  }

  /// History and ordinary recentering share one bounded physical stage. The
  /// old client remains active until the lexical source consumer really moves.
  func stage(_ prepared: PagedNativePreparedHistoryMove,
    observedSelection: PagedNativeSelectionObservation) throws -> PagedNativeHistoryInstallationTicket {
    try requirePhysicalStageSource(observedSelection)
    let ticket = try session.stageHistoryInstallation(prepared)
    try constructStage(.history(ticket), observedSelection: observedSelection)
    return ticket
  }
  func stageNavigation(_ ticket: PagedNativeNavigationInstallationTicket,
    observedSelection: PagedNativeSelectionObservation) throws {
    try requirePhysicalStageSource(observedSelection)
    try constructStage(.navigation(ticket), observedSelection: observedSelection)
  }
  private func requirePhysicalStageSource(_ observed: PagedNativeSelectionObservation) throws {
    guard !isAdopting, stagedClient == nil, let activeView,
      activeView.inputCommandIsClosed, !activeView.hasMarkedText(), firstRefusal == nil,
      try observeSelection() == observed else {
      throw BoomError.stale("Native source, selection or physical input changed before construction.")
    }
  }
  private func constructStage(_ ticket: StageTicket,
    observedSelection: PagedNativeSelectionObservation) throws {
    do {
      let window: PagedTextWindow, arena: UUID
      let history: PagedNativeHistoryInstallationTicket?
      let navigation: PagedNativeNavigationInstallationTicket?
      switch ticket {
      case .history(let value):
        window = try session.windowForStagedNativeInstallation(value); arena = value.provisionalArenaID
        history = value; navigation = nil
      case .navigation(let value):
        window = try session.windowForStagedNavigationInstallation(value); arena = value.provisionalArenaID
        history = nil; navigation = value
      }
      let binding = makeBinding(arenaID: arena, windowID: window.windowID)
      let view = try PagedNativeTextView(frame: activeView.frame, session: session,
        inputBinding: binding, stagedTicket: history, stagedNavigationTicket: navigation)
      binding.owner = self
      let keyboardID = activeContext?.selectedKeyboardInputSource, sourceWindow = activeView.window
      stagedClient = StagedClient(ticket: ticket, client: PhysicalClient(view: view, context: nil),
        sourceSelection: observedSelection, sourceKeyboardID: keyboardID, sourceWindow: sourceWindow)
      let context = view.inputContext
      stagedClient = StagedClient(ticket: ticket, client: PhysicalClient(view: view, context: context),
        sourceSelection: observedSelection, sourceKeyboardID: keyboardID, sourceWindow: sourceWindow)
    } catch {
      let original = error
      // Navigation's real outer owner performs its one cleanup attempt. A
      // second implicit cancellation here would hide a refused stage cleanup.
      if case .navigation = ticket { throw original }
      do { try cancelSourceStage(ticket); retireConstructedStage() }
      catch { throw PagedNativeNavigationCleanupFailure(original: original, cleanup: error) }
      throw original
    }
  }
  private func requireAdoptionSource(_ stage: StagedClient) throws {
    guard !isAdopting, activeView != nil, stage.sourceSelection == (try observeSelection()),
      stage.sourceKeyboardID == activeContext?.selectedKeyboardInputSource,
      stage.sourceWindow === activeView.window, activeView.inputCommandIsClosed,
      !activeView.hasMarkedText(), firstRefusal == nil else {
      throw BoomError.stale("The staged client no longer owns the exact source selection/focus/keyboard.")
    }
  }
  private func adopt(_ stage: StagedClient,
    mounted: (PagedNativeTextView, PagedNativeTextView) throws -> Void) -> Error? {
    precondition(isAdopting && stagedClient != nil)
    let oldView = activeView!
    let ownsSourceFocus = (try? physicalInputLease(for: oldView)) == stage.sourceSelection.inputLease
    oldView.inputBinding?.retire()
    oldView.retirePhysicalInputClient() // permanent old proxy is inert BEFORE framework reentrancy
    activeView = stage.client.view; activeContext = stage.client.context
    activeView.inputBinding?.activate(); stagedClient = nil
    do { try mounted(oldView, activeView) }
    catch {
      // The source and Foundation move already happened. Keep the actual
      // physical refusal on this binding and never grant raw-key replay.
      activeView.inputBinding?.recordRefusal(error)
      return error
    }
    if ownsSourceFocus, let target = try? physicalInputLease(for: activeView) {
      let source = stage.sourceSelection.inputLease
      if source.keyboardEpoch == target.keyboardEpoch, source.keyboardID == target.keyboardID,
        source.windowID == target.windowID, source.isFirstResponder, target.isFirstResponder,
        source.isKeyWindow == target.isKeyWindow {
        lastReplayTransition = PagedNativeReplayInputTransition(source: source, target: target)
      }
    }
    return nil
  }
  func withStagedInstallation(_ ticket: PagedNativeHistoryInstallationTicket,
    advancingFoundation: (() -> Void) -> Void,
    mounted: @escaping (PagedNativeTextView, PagedNativeTextView) throws -> Void) throws -> PagedNativeHistoryAdmission {
    guard let stage = stagedClient, case .history(let value) = stage.ticket, value === ticket else {
      throw BoomError.stale("Another stage kind owns this physical client.")
    }
    try requireAdoptionSource(stage)
    isAdopting = true; lastReplayTransition = nil
    defer { isAdopting = false }
    var mountFailure: Error?
    let admission = try session.withStagedHistoryInstallation(ticket) { consumer in
      advancingFoundation { [self] in
        _ = consumer.consume { _, arenaID, _ in
          precondition(arenaID == stage.client.view.inputBinding?.identity.arenaID)
          mountFailure = adopt(stage, mounted: mounted)
        }
      }
    }
    // Foundation's synchronous handler cannot throw. Propagate its actual
    // mount failure after that scope closes, preserving its consumed source.
    if let mountFailure { throw mountFailure }
    return admission
  }
  func withStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket,
    mounted: (PagedNativeTextView, PagedNativeTextView) throws -> Void) throws -> PagedTextWindow {
    guard let stage = stagedClient, case .navigation(let value) = stage.ticket, value === ticket else {
      throw BoomError.stale("Another source stage owns this physical navigation.")
    }
    try requireAdoptionSource(stage)
    isAdopting = true; lastReplayTransition = nil
    defer { isAdopting = false }
    var mountFailure: Error?
    let window = try session.withStagedNavigationInstallation(ticket) { _, arena, _ in
      precondition(arena == stage.client.view.inputBinding?.identity.arenaID)
      mountFailure = adopt(stage, mounted: mounted)
    }
    if let mountFailure { throw mountFailure }
    return window
  }
  private func cancelSourceStage(_ ticket: StageTicket) throws {
    switch ticket {
    case .history(let value): try session.cancelStagedHistoryInstallation(value)
    case .navigation(let value): try session.cancelStagedNavigationInstallation(value)
    }
  }
  private func retireConstructedStage() {
    guard let stage = stagedClient else { return }
    stage.client.view.inputBinding?.retire(); stage.client.view.retirePhysicalInputClient()
    stagedClient = nil
  }
  func cancelStage(_ ticket: PagedNativeHistoryInstallationTicket) throws {
    guard let stage = stagedClient, case .history(let value) = stage.ticket,
      value === ticket, !isAdopting else { throw BoomError.stale("Another command owns this staged client.") }
    try cancelSourceStage(stage.ticket); retireConstructedStage()
  }
  func cancelNavigationStage(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    guard !isAdopting else { throw BoomError.stale("Navigation is already in its source adoption scope.") }
    if let stage = stagedClient {
      guard case .navigation(let value) = stage.ticket, value === ticket else {
        throw BoomError.stale("Another physical stage owns this navigation reservation.")
      }
      try cancelSourceStage(stage.ticket); retireConstructedStage()
    } else { try session.cancelStagedNavigationInstallation(ticket) }
  }

  fileprivate func recordRefusal(_ error: Error, binding: PagedNativeInputBinding) {
    guard binding.state == .active, binding.identity == activeIdentity,
      firstRefusal == nil else { return }
    firstRefusal = error
    // One first refusal blocks later active admission. This diagnostic set is
    // bounded by one refusal, independent of lifetime installation count.
    refusedClientIDs.insert(binding.identity.clientID)
  }

  /// All fallible checks precede physical retirement. The Session performs
  /// its own full join/token preflight before entering the nonthrowing fence.
  func prepareInputRetirement(commandOwner expectedOwner: PagedNativeUndoOwner?)
    throws -> PagedNativeInputRetirementTicket {
    guard !isAdopting, stagedClient == nil, firstRefusal == nil,
      commandOwner === expectedOwner, let view = activeView,
      let binding = view.inputBinding, binding.state == .active,
      binding.identity == activeIdentity,
      view.inputCommandIsClosed, !view.hasMarkedText() else {
      throw BoomError.stale("Native input or its command owner still requires an explicit disposition.")
    }
    _ = try session.windowForNativeInstallation()
    guard commandOwner === expectedOwner, activeView === view, binding.state == .active,
      binding.identity.ownerID == ownerID, binding.identity.sessionID == session.sessionID,
      firstRefusal == nil else {
      throw BoomError.stale("Physical input ownership changed during retirement preflight.")
    }
    // Managed navigation always adopts the physical and source arena together.
    // Retirement disables this exact binding; it never retargets an old client.
    return PagedNativeInputRetirementTicket(owner: self, commandOwner: expectedOwner,
      view: view, identity: binding.identity)
  }

  /// Call only in the joined synchronous retirement interval. The original
  /// binding/proxy are disabled before deactivate or ARC can reenter AppKit.
  func consumeInputRetirement(_ ticket: PagedNativeInputRetirementTicket,
    commandOwner expectedOwner: PagedNativeUndoOwner?) {
    precondition(ticket.owner === self && !ticket.consumed && ticket.view === activeView,
      "Physical retirement must consume its exact preflight once.")
    precondition(commandOwner === expectedOwner && ticket.commandOwner === expectedOwner
      && ticket.identity == activeIdentity && ticket.generation == session.generation
      && ticket.arenaID == session.arenaID && !isAdopting && stagedClient == nil && firstRefusal == nil,
      "A reentrant source change invalidated physical retirement.")
    ticket.consumed = true
    let view = ticket.view
    view.inputBinding?.retire()
    documentKey = nil; documentCommand = nil
    commandOwner = nil
    view.retirePhysicalInputClient()
    activeContext = nil; activeView = nil
    session.retireManagedArenaOwner(self)
    lastReplayTransition = nil
    observers = nil
  }

  /// Hookless component retirement; an attached command owner supplies its
  /// own exact Session subscription fence and must use its closeInput route.
  /// Neither route releases the backend's document or root custody.
  func retireInputForClose() throws {
    if activeView == nil { try requireJoinedClose(); return }
    let ticket = try prepareInputRetirement(commandOwner: nil)
    consumeInputRetirement(ticket, commandOwner: nil)
  }

  /// Physical reference retirement is not a callback-drain or source-custody
  /// receipt. The backend's joined controller/engine shutdown is separate.
  func requireJoinedClose() throws {
    guard activeView == nil, activeContext == nil, stagedClient == nil,
      !isAdopting, commandOwner == nil, firstRefusal == nil else {
      throw BoomError.stale("Native physical input is still installed or retains an unresolved refusal.")
    }
    _ = try session.windowForNativeInstallation()
  }
}

/// Preserve the original construction/stale refusal if explicit stage cleanup
/// also refuses. Neither error clears source intent, physical input or custody.
private struct PagedNativeNavigationCleanupFailure: Error {
  let original: Error
  let cleanup: Error
}
