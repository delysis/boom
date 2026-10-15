import AppKit
import BoomCore
import Foundation
import Synchronization

extension PagedSelectionAffinity {
  init(native: NSSelectionAffinity) throws {
    switch native {
    case .upstream: self = .upstream
    case .downstream: self = .downstream
    @unknown default: throw BoomError.invalid("Unknown native selection affinity.")
    }
  }
  var native: NSSelectionAffinity { self == .upstream ? .upstream : .downstream }
}

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

struct PagedNativeStateObservation {
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
  let caretUTF16: UInt64
  let selectionLength: UInt64
  let hasMarkedText: Bool
}

/// Original key events have no interpreted range. New ingress requires actual
/// focus; accepted delivery retains exact document/source/keyboard authority
/// through this owner's real mounts, independently of later focus moves.
struct PagedNativeReplayInputLease: Equatable {
  let identity: PagedNativeInputIdentity
  let focusEpoch: UInt64
  let keyboardEpoch: UInt64
  let keyboardID: String?
  let windowID: ObjectIdentifier?
  let isFirstResponder: Bool
  let isKeyWindow: Bool
}

extension PagedNativeReplayInputLease {
  func hasSameSourceAndKeyboard(as other: Self) -> Bool {
    identity == other.identity && keyboardEpoch == other.keyboardEpoch
      && keyboardID == other.keyboardID && windowID == other.windowID
  }
}
extension PagedNativeSelectionObservation {
  func hasSameSourceSelectionAndKeyboard(as other: Self) -> Bool {
    identity == other.identity && generation == other.generation && selectionEpoch == other.selectionEpoch
      && range == other.range && affinity == other.affinity
      && inputLease.hasSameSourceAndKeyboard(as: other.inputLease)
  }
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
  /// Only the queue's previously admitted event may use this source-only
  /// mount edge. Focus changes revoke new ingress, never accepted writing.
  func rebaseAccepted(_ lease: PagedNativeReplayInputLease) throws -> PagedNativeReplayInputLease {
    guard lease.hasSameSourceAndKeyboard(as: source) else {
      throw BoomError.stale("Admitted native input has another actual source mount.")
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

/// One binding belongs to one installed source arena and never retargets.
/// A stable view rotates bindings while its document input context remains
/// current. Retired storage keeps its retired binding; it never retargets.
@MainActor final class PagedNativeInputBinding {
  enum State: Equatable { case staged, active, retired }
  let identity: PagedNativeInputIdentity
  weak var owner: PagedNativeInputOwner?
  private(set) var state: State = .staged
  private(set) var selectionEpoch: UInt64 = 0
  private(set) var commandDepth = 0
  private(set) var firstRefusal: Error?

  fileprivate init(identity: PagedNativeInputIdentity) { self.identity = identity }

  func admitsInput(in session: PagedNativeSession) throws {
    guard state == .active, let owner, owner.activeIdentity == identity,
      session.sessionID == identity.sessionID, session.arenaID == identity.arenaID else {
      throw BoomError.stale("This input client still belongs to its earlier source window.")
    }
    // A failed file/mount/command remains owned by its actual receiver. It
    // does not prohibit characters in this still-current consistent source.
    // An accepted source/backing mismatch is different: never type against
    // that inconsistent TextKit projection until it is actually rebuilt.
    guard !owner.isAdopting, owner.activeView?.boundedStorage.mutationFailure == nil else {
      throw BoomError.stale("The physical editor has an unresolved source projection.")
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

/// Physical clients for the file-backed editor. Keep one stable active view
/// and at most one staged projection. The same document input context survives
/// projection rotation and becomes inert only when its owner actually retires.
/// Actual source/history tasks remain owned by the session and backend.
@MainActor final class PagedNativeInputOwner {
  private struct StagedClient {
    let ticket: PagedNativeNavigationInstallationTicket
    let binding: PagedNativeInputBinding
    let storage: PagedNativeTextStorage
    let context: NSTextInputContext
    let sourceStorage: PagedNativeTextStorage
    let sourceManager: NSLayoutManager
    let sourceContainer: NSTextContainer
    let sourceSelection: PagedNativeSelectionObservation
    let sourceKeyboardID: String?
    let sourceWindow: NSWindow?
  }

  let ownerID = UUID()
  let session: PagedNativeSession
  weak var commandOwner: PagedNativeUndoOwner?
  private(set) var activeView: PagedNativeTextView!
  private var activeContext: NSTextInputContext?
  private var acceptedInputDeliveryDepth = 0
  private var documentContextCallbackDepth = 0
  var isDeliveringAcceptedInput: Bool { acceptedInputDeliveryDepth > 0 }
  var isDocumentContextCallback: Bool { documentContextCallbackDepth > 0 }
  var documentContext: NSTextInputContext? { activeContext }
  var needsContextSpliceObservation: Bool {
    (activeContext?.client as? PagedNativeTextInputClient)?.needsSpliceObservation == true
  }
  func mapDocumentContext(before: PagedNativeLogicalSnapshot, after: PagedNativeLogicalSnapshot,
    start: UInt64, removed: UInt64, inserted: UInt64) {
    (activeContext?.client as? PagedNativeTextInputClient)?.mapPendingSelection(
      before: before, after: after, start: start, removed: removed, inserted: inserted)
  }
  func withDocumentContextCallback(_ operation: () -> Void) {
    guard let view = activeView, view.inputBinding?.state == .active,
      !isAdopting, firstRefusal == nil, view.boundedStorage.mutationFailure == nil,
      documentContextCallbackDepth < 32 else { PerformanceTrace.event("Editor.ManagedAdmission"); return }
    documentContextCallbackDepth += 1
    defer { documentContextCallbackDepth -= 1 }
    operation()
  }

  /// Exact source/keyboard admission still precedes this lexical delivery.
  /// The original ingress proved a real focused key; no makeFirstResponder or
  /// context activation is performed here after an ordinary focus move.
  func withAcceptedInputDelivery(_ original: PagedNativeReplayInputLease,
    expected: PagedNativeReplayInputLease, operation: () -> Void) throws {
    guard original.identity.ownerID == ownerID, original.identity.sessionID == session.sessionID,
      original.isFirstResponder, original.isKeyWindow, let view = activeView,
      let binding = view.inputBinding, expected.identity == binding.identity,
      try inputLease(for: view).hasSameSourceAndKeyboard(as: expected),
      acceptedInputDeliveryDepth < 32 else {
      throw BoomError.stale("Already admitted native input lost its document, source or keyboard.")
    }
    try binding.admitsInput(in: session)
    acceptedInputDeliveryDepth += 1
    defer { acceptedInputDeliveryDepth -= 1 }
    operation()
  }
  private var stagedClient: StagedClient?
  private let focusEpoch = PagedNativeInputEpoch()
  private let keyboardEpoch = PagedNativeInputEpoch()
  private var observers: PagedNativeInputObservers?
  private(set) var isAdopting = false
  private(set) var canonicalActivationPending = false
  private(set) var lastReplayTransition: PagedNativeReplayInputTransition?
  private(set) var firstRefusal: Error?
  private(set) var refusedClientIDs: Set<UUID> = []
  private weak var completionClient: (any NativeCompletionClient)?
  private var documentSelection: PagedNativeNavigationSelection?
  private var documentSelectionGeneration: UInt64?
  private var projectingDocumentSelection = false
  private var mouseSelectionAnchor: (identity: PagedNativeInputIdentity, generation: UInt64,
    absolute: UInt64, projected: UInt64)?
  private var nextInputGroupID: UUID?
  func continueNextInputGroup(_ id: UUID) { nextInputGroupID = id }
  func takeNextInputGroupID() -> UUID? {
    defer { nextInputGroupID = nil }
    return nextInputGroupID
  }

  struct TypingIntent {
    enum Kind { case insertion, backwardDeletion, forwardDeletion }
    let kind: Kind
    let startsNewGroup: Bool
    let endsGroup: Bool
  }
  private struct TypingGroup {
    let id: UUID
    let kind: TypingIntent.Kind
    var generation: UInt64
    var caretUTF16: UInt64
    var lastInput: ContinuousClock.Instant
    var ended: Bool
  }
  private var typingGroup: TypingGroup?

  static func typingIntent(for event: NSEvent) -> TypingIntent? {
    guard event.type == .keyDown,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
    if event.keyCode == 51 { return TypingIntent(kind: .backwardDeletion, startsNewGroup: false, endsGroup: false) }
    if event.keyCode == 117 { return TypingIntent(kind: .forwardDeletion, startsNewGroup: false, endsGroup: false) }
    guard ![48, 53, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) else { return nil }
    guard let characters = event.characters, !characters.isEmpty,
      characters.utf16.count <= PagedNativeUndoOwner.maximumKeyUTF16,
      !characters.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
      return nil
    }
    let newline = characters.contains("\n") || characters.contains("\r")
    let whitespace = characters.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    return TypingIntent(kind: .insertion, startsNewGroup: newline, endsGroup: whitespace)
  }

  /// Group adjacent typing/deletion by the real document caret, irrespective
  /// of a physical window recenter or a disk seal. Paste and menu commands
  /// have no typing intent and therefore remain separate transactions.
  func nativeInputGroupID(intent: TypingIntent?) -> UUID {
    let continuation = takeNextInputGroupID()
    guard let intent, let selection = try? currentDocumentSelection() else {
      typingGroup = nil
      return continuation ?? UUID()
    }
    let now = ContinuousClock.now
    let previous = typingGroup
    let canContinue = previous.map {
      !intent.startsNewGroup && !$0.ended && $0.kind == intent.kind
        && $0.generation == session.generation && $0.caretUTF16 == selection.utf16Offset
        && selection.utf16Length == 0 && $0.lastInput.duration(to: now) <= .milliseconds(750)
    } ?? false
    let previousID = canContinue ? previous?.id : nil
    let id = continuation ?? previousID ?? UUID()
    typingGroup = TypingGroup(id: id, kind: intent.kind, generation: session.generation,
      caretUTF16: selection.utf16Offset, lastInput: now, ended: intent.endsGroup)
    return id
  }
  var onNativeEdit: ((PagedNativeStateObservation) -> Void)?
  var onNativeSelection: ((PagedNativeStateObservation) -> Void)?

  func installCompletionClient(_ client: (any NativeCompletionClient)?) {
    completionClient = client
    let model = client as? WorkspaceModel
    activeView?.completionClient = client
    activeView?.owner = model
    activeView?.setMedia(model: model)
    activeView?.didRejectInput = { _ in PerformanceTrace.event("Editor.ManagedAdmission") }
  }

  /// Read only the explicitly owned selection. Session's native-coordinate
  /// fallback must not call currentDocumentSelection() and recurse into itself.
  var currentOwnedDocumentSelection: PagedNativeNavigationSelection? {
    documentSelectionGeneration == session.generation ? documentSelection : nil
  }
  func currentDocumentSelection() throws -> PagedNativeNavigationSelection {
    if let selection = currentOwnedDocumentSelection { return selection }
    let selection = try session.navigationSelection(activeView.selectedRange())
    // A normalized NSRange supplies no independent anchor. Preserve the
    // observed visual affinity without manufacturing direction from it.
    return PagedNativeNavigationSelection(utf16Offset: selection.utf16Offset,
      utf16Length: selection.utf16Length, focusAtEnd: selection.focusAtEnd,
      affinity: try PagedSelectionAffinity(native: activeView.selectionAffinity))
  }

  /// A caret supplies its own anchor. A nonempty native range needs the
  /// actual owned anchor; visual affinity cannot manufacture that endpoint.
  func selectionForVisualMovement() throws -> PagedNativeNavigationSelection {
    if let documentSelection, documentSelectionGeneration == session.generation { return documentSelection }
    guard activeView.selectedRange().length == 0 else {
      throw BoomError.unavailable("Visual movement requires the actual selection anchor.")
    }
    return try currentDocumentSelection()
  }

  func userSelectionDidChange(from view: PagedNativeTextView,
    previousRange: NSRange?, previousGeneration: UInt64) {
    guard view === activeView, !isAdopting, !projectingDocumentSelection else { return }
    defer {
      session.retainSelectionEndpointProofs(for: currentOwnedDocumentSelection)
      commandOwner?.inputSelectionDidChange()
    }
    var previous = documentSelectionGeneration == session.generation ? documentSelection : nil
    documentSelection = nil; documentSelectionGeneration = nil
    do {
      if previous == nil, previousGeneration == session.generation,
        let previousRange, previousRange.length == 0 {
        // A real prior caret supplies its anchor even without a logical
        // selection cache. Admit it in this exact still-current source.
        previous = try session.navigationSelection(previousRange)
      }
      let next = try session.navigationSelection(view.selectedRange())
      let affinity = try PagedSelectionAffinity(native: view.selectionAffinity)
      let end = next.utf16Offset + next.utf16Length
      let focusAtEnd: Bool
      if let anchor = mouseSelectionAnchor, anchor.identity == activeIdentity,
        anchor.generation == session.generation,
        anchor.projected == next.utf16Offset || anchor.projected == end {
        // Cocoa tracks the actual clipped anchor. Restore only that proven
        // endpoint to the original global Shift anchor; affinity is separate.
        let focus = anchor.projected == next.utf16Offset ? end : next.utf16Offset
        documentSelection = PagedNativeNavigationSelection(utf16Offset: min(anchor.absolute, focus),
          utf16Length: max(anchor.absolute, focus) - min(anchor.absolute, focus),
          focusAtEnd: focus >= anchor.absolute, affinity: affinity)
        documentSelectionGeneration = session.generation
        if view.inputCommandIsClosed { typingGroup = nil; nextInputGroupID = nil }
        return
      } else if next.utf16Length == 0 { focusAtEnd = false }
      else if let previous, previous.anchorUTF16 == next.utf16Offset { focusAtEnd = true }
      else if let previous, previous.anchorUTF16 == end { focusAtEnd = false }
      else {
        // Both endpoints changed without an owned anchor (for example a
        // direct AppKit range assignment). Keep this ingress unproven.
        if view.inputCommandIsClosed { typingGroup = nil; nextInputGroupID = nil }
        return
      }
      documentSelection = PagedNativeNavigationSelection(utf16Offset: next.utf16Offset,
        utf16Length: next.utf16Length, focusAtEnd: focusAtEnd, affinity: affinity)
      documentSelectionGeneration = session.generation
    } catch { PerformanceTrace.event("Editor.ManagedAdmission") }
    if view.inputCommandIsClosed { typingGroup = nil; nextInputGroupID = nil }
  }

  /// A native Shift mouse gesture may have an anchor outside its bounded
  /// projection. Seed Cocoa's real local caret and keep the original endpoint
  /// only during this synchronous tracking call, never across a source rebind.
  func withDocumentMouseSelection(anchorUTF16: UInt64, operation: () -> Void) throws {
    guard mouseSelectionAnchor == nil, let view = activeView, let binding = view.inputBinding,
      view.inputCommandIsClosed, !view.hasMarkedText() else {
      throw BoomError.stale("The native mouse gesture has another selection or composition scope.")
    }
    try binding.admitsInput(in: session)
    let coordinates = try session.documentCoordinates()
    guard anchorUTF16 <= coordinates.projectedUTF16 else {
      throw BoomError.stale("The mouse anchor exceeds its actual logical source.")
    }
    let end = coordinates.utf16Start + UInt64(coordinates.localUTF16)
    let projected = min(end, max(coordinates.utf16Start, anchorUTF16))
    let local = Int(projected - coordinates.utf16Start)
    _ = try session.nativeSelection(NSRange(location: local, length: 0))
    mouseSelectionAnchor = (binding.identity, session.generation, anchorUTF16, projected)
    defer { mouseSelectionAnchor = nil }
    projectingDocumentSelection = true
    view.setSelectedRange(NSRange(location: local, length: 0),
      affinity: view.selectionAffinity, stillSelecting: false)
    projectingDocumentSelection = false
    operation()
  }

  /// A document range is two scalar coordinates. Cocoa paints only the
  /// intersection with its bounded island; neither selection nor Undo copies
  /// the selected source bytes into memory.
  func setDocumentSelection(_ selection: PagedNativeNavigationSelection, mouseDown: NSEvent? = nil,
    observedWindow: PagedNativeLogicalWindow? = nil) throws {
    let coordinates = try session.documentCoordinates()
    guard selection.utf16Offset <= coordinates.projectedUTF16,
      selection.utf16Length <= coordinates.projectedUTF16 - selection.utf16Offset,
      let view = activeView, let binding = view.inputBinding, binding.state == .active else {
      throw BoomError.stale("Document selection falls outside the actual projected source.")
    }
    let changesLogicalSelection = try currentDocumentSelection() != selection
    if let mouseDown {
      guard mouseDown.type == .leftMouseDown, let window = view.window,
        mouseDown.windowNumber == window.windowNumber, window.isKeyWindow,
        window.firstResponder === view else {
        throw BoomError.stale("The mouse selection has another actual native window or responder.")
      }
    }
    let recordsSelectionIngress = changesLogicalSelection || mouseDown != nil
    if recordsSelectionIngress { try binding.requireSelectionCapacity() }
    let beforeEpoch = binding.selectionEpoch
    let windowEnd = coordinates.utf16Start + UInt64(coordinates.localUTF16)
    let selectionEnd = selection.utf16Offset + selection.utf16Length
    let start = min(windowEnd, max(coordinates.utf16Start, selection.utf16Offset))
    let end = min(windowEnd, max(start, selectionEnd))
    let local = NSRange(location: Int(start - coordinates.utf16Start), length: Int(end - start))
    projectingDocumentSelection = true
    defer { projectingDocumentSelection = false }
    documentSelection = selection
    documentSelectionGeneration = session.generation
    view.endGhostBoundary(); view.clearGhost()
    view.setSelectedRange(local, affinity: selection.affinity.native, stillSelecting: false)
    // A distant logical endpoint may change while Cocoa paints the identical
    // island range. It still invalidates pending input/navigation observations.
    if recordsSelectionIngress, binding.selectionEpoch == beforeEpoch { binding.recordSelectionChange() }
    session.retainSelectionEndpointProofs(for: selection, observedWindow: observedWindow)
    notifyNativeState(from: view, edited: false)
  }

  func notifyNativeState(from view: PagedNativeTextView, edited: Bool) {
    guard view === activeView, !isAdopting, !canonicalActivationPending,
      view.inputBinding?.state == .active else { return }
    commandOwner?.inputSelectionDidChange()
    do {
      let coordinates = try session.documentCoordinates(), range = view.selectedRange()
      guard range.location >= 0, range.location != NSNotFound, range.length >= 0 else {
        throw BoomError.invalid("Invalid native selection.")
      }
      let caret = coordinates.utf16Start.addingReportingOverflow(UInt64(range.location))
      guard !caret.overflow else { throw BoomError.budget("Native caret exceeds document coordinates.") }
      if documentSelectionGeneration != session.generation {
        documentSelection = nil; documentSelectionGeneration = nil
      }
      let observation = PagedNativeStateObservation(sessionID: session.sessionID, arenaID: session.arenaID,
        generation: session.generation, caretUTF16: documentSelection?.focusUTF16 ?? caret.partialValue,
        selectionLength: documentSelection?.utf16Length ?? UInt64(range.length), hasMarkedText: view.hasMarkedText())
      if edited, var group = typingGroup {
        group.generation = session.generation; group.caretUTF16 = observation.caretUTF16
        group.ended = group.ended || observation.selectionLength > 0 || observation.hasMarkedText
        typingGroup = group
      } else if let group = typingGroup,
        group.generation != session.generation || group.caretUTF16 != observation.caretUTF16 || observation.selectionLength > 0 {
        typingGroup = nil; nextInputGroupID = nil
      }
      if edited { onNativeEdit?(observation) } else { onNativeSelection?(observation) }
    } catch { PerformanceTrace.event("Editor.ManagedAdmission") }
  }
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
    let partialDocument: Bool
    if let coordinates = try? session.documentCoordinates() {
      partialDocument = coordinates.utf16Start != 0
        || UInt64(coordinates.localUTF16) != coordinates.projectedUTF16
    } else { partialDocument = false }
    let selectedBeyondWindow = (documentSelection?.utf16Length ?? 0) > UInt64(activeView?.selectedRange().length ?? 0)
    // Replacing an exact local scalar selection needs no source read or
    // grapheme context, including a selection reaching this island's edge.
    let localSelectionCommand = !selectedBeyondWindow && (activeView?.selectedRange().length ?? 0) > 0
      && ["deleteBackward:", "deleteForward:", "delete:", "moveForward:", "moveBackward:"].contains(NSStringFromSelector(selector))
    let characterCommand = partialDocument && !localSelectionCommand
      && activeView?.hasContainedCharacterCommand(selector) != true
      && ["moveForward:", "moveBackward:", "moveLeft:", "moveRight:",
      "moveForwardAndModifySelection:", "moveBackwardAndModifySelection:",
      "moveLeftAndModifySelection:", "moveRightAndModifySelection:", "deleteBackward:", "deleteForward:"].contains(NSStringFromSelector(selector))
    let collapsingSelection = selectedBeyondWindow && (selector == NSSelectorFromString("moveForward:")
      || selector == NSSelectorFromString("moveBackward:") || selector == NSSelectorFromString("moveLeft:")
      || selector == NSSelectorFromString("moveRight:"))
    return documentCommand != nil && (PagedNativeParagraphCommand(selector) != nil || characterCommand || collapsingSelection || selector == NSSelectorFromString("moveToBeginningOfDocument:")
      || selector == NSSelectorFromString("moveToEndOfDocument:")
      || selector == NSSelectorFromString("moveToBeginningOfDocumentAndModifySelection:")
      || selector == NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")
      || selector == NSSelectorFromString("selectAll:")
      || selectedBeyondWindow && (selector == NSSelectorFromString("deleteBackward:")
        || selector == NSSelectorFromString("deleteForward:") || selector == NSSelectorFromString("delete:")))
  }
  func dispatchDocumentCommand(_ selector: Selector,
    observed: PagedNativeSelectionObservation) throws {
    guard handlesDocumentCommand(selector), let documentCommand,
      try observeSelection() == observed, activeView.inputCommandIsClosed,
      !activeView.hasMarkedText() else {
      throw BoomError.stale("Document movement lost its actual source command or physical selection.")
    }
    if let commandOwner { try commandOwner.requestDocumentCommand(selector, from: activeView) }
    else { try documentCommand(selector, observed) }
  }

  /// Only the existing command queue calls this after its original physical
  /// lease/window check. Selection follows all earlier admitted input.
  func performQueuedDocumentCommand(_ selector: Selector) throws {
    guard let documentCommand else {
      throw BoomError.stale("The queued document command lost its actual presentation consumer.")
    }
    if handlesDocumentCommand(selector) { try documentCommand(selector, observeSelection()) }
    else {
      // Earlier ordered edits may make the whole source fit this island.
      // This same authorized client then performs the contained native command.
      try activeView.performContainedDocumentCommand(selector)
    }
  }

  var activeIdentity: PagedNativeInputIdentity? { activeView?.inputBinding?.identity }
  var retainedClientCount: Int { (activeView == nil ? 0 : 1) + (stagedClient == nil ? 0 : 1) }
  var hasStagedClient: Bool { stagedClient != nil }

  init(frame: NSRect, session: PagedNativeSession) throws {
    self.session = session
    try session.registerManagedArenaOwner(self)
    do {
      let window = session.logicalWindow
      let binding = makeBinding(arenaID: session.arenaID, windowID: window.windowID)
      let view = try PagedNativeTextView(frame: frame, session: session,
        inputBinding: binding, canonicalOpening: session.canonicalOpening)
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
    if !isAdopting { commandOwner?.inputSelectionDidChange() }
  }

  /// No storage request, source move, stage, context or mount is needed when
  /// this resident projection already has the exact target extent. Any changed
  /// range uses the SAME native client with actual selection/epoch admission.
  func reuseJoinedNavigationWindow(toUTF16 anchor: UInt64, selection: PagedNativeNavigationSelection,
    observedSelection observed: PagedNativeSelectionObservation) throws -> PagedNativeLogicalWindow? {
    try requirePhysicalStageSource(observed)
    let window = session.logicalWindow
    let end = window.start.utf16.addingReportingOverflow(window.summary.utf16)
    guard !end.overflow, anchor >= window.start.utf16, anchor <= end.partialValue,
      selection.focusUTF16 >= window.start.utf16, selection.focusUTF16 <= end.partialValue else { return nil }
    let localSelection = try window.localRange(for: selection)
    let view = activeView!
    let currentSelection = try currentDocumentSelection()
    let changesSelection = localSelection != observed.range || selection != currentSelection
    let epoch = observed.selectionEpoch.addingReportingOverflow(changesSelection ? 1 : 0)
    guard !epoch.overflow else { throw BoomError.budget("Joined native selection identity is exhausted.") }
    if changesSelection { try setDocumentSelection(selection) }
    let after = try observeSelection()
    guard activeView === view, after.identity == observed.identity, after.generation == observed.generation,
      after.inputLease == observed.inputLease, after.selectionEpoch == epoch.partialValue,
      after.range == localSelection, after.affinity == selection.affinity.native,
      firstRefusal == nil, view.boundedStorage.mutationFailure == nil,
      session.logicalWindow.windowID == window.windowID,
      try session.logicalWindow.localRange(for: selection) == localSelection else {
      throw BoomError.stale("The exact joined native range/input/source changed during selection reuse.")
    }
    return window
  }

  /// Navigation and logical Undo share one bounded physical installation.
  func stageNavigation(_ ticket: PagedNativeNavigationInstallationTicket,
    observedSelection: PagedNativeSelectionObservation) throws {
    try requirePhysicalStageSource(observedSelection)
    try constructStage(ticket, observedSelection: observedSelection)
  }
  private func requirePhysicalStageSource(_ observed: PagedNativeSelectionObservation) throws {
    guard !isAdopting, stagedClient == nil, let activeView,
      activeView.inputCommandIsClosed, !activeView.hasMarkedText(), firstRefusal == nil,
      try observeSelection() == observed else {
      throw BoomError.stale("Native source, selection or physical input changed before construction.")
    }
  }
  private func constructStage(_ ticket: PagedNativeNavigationInstallationTicket,
    observedSelection: PagedNativeSelectionObservation) throws {
    let trace = PerformanceTrace.begin("Editor.Update", event: 6)
    defer { PerformanceTrace.end("Editor.Update", trace) }
    let window = try session.windowForStagedNavigationInstallation(ticket)
    let binding = makeBinding(arenaID: ticket.provisionalArenaID, windowID: window.windowID)
    guard let view = activeView, let manager = view.layoutManager, let container = view.textContainer,
      manager.textStorage === view.boundedStorage, container.textView === view,
      !view.boundedStorage.hasOpenCharacterTransaction,
      manager.textContainers.count == 1, manager.textContainers.first === container,
      view.boundedStorage.layoutManagers.count == 1,
      view.boundedStorage.layoutManagers.first === manager else {
      throw BoomError.stale("Native installation lost its exact current TextKit graph.")
    }
    let storage = try PagedNativeTextStorage(session: session,
      attributes: [.font: MarkdownStyle.body], inputBinding: binding, stagedNavigationTicket: ticket)
    view.prepareProjectionCallbacks(storage)
    binding.owner = self
    guard let context = activeContext, context === view.inputContext,
      let client = context.client as? PagedNativeTextInputClient,
      client.identity.ownerID == ownerID, client.identity.sessionID == session.sessionID,
      !client.isRetired else { throw BoomError.stale("The staged projection lost its document input context.") }
    let keyboardID = context.selectedKeyboardInputSource, sourceWindow = view.window
    stagedClient = StagedClient(ticket: ticket, binding: binding, storage: storage,
      context: context, sourceStorage: view.boundedStorage,
      sourceManager: manager, sourceContainer: container, sourceSelection: observedSelection,
      sourceKeyboardID: keyboardID, sourceWindow: sourceWindow)
  }
  private func requireAdoptionSource(_ stage: StagedClient) throws {
    guard !isAdopting, activeView != nil, stage.sourceSelection == (try observeSelection()),
      stage.sourceKeyboardID == activeContext?.selectedKeyboardInputSource,
      stage.sourceWindow === activeView.window, activeView.inputCommandIsClosed,
      !activeView.hasMarkedText(), firstRefusal == nil,
      stage.sourceStorage === activeView.boundedStorage,
      stage.sourceManager === activeView.layoutManager, stage.sourceContainer === activeView.textContainer,
      stage.sourceManager.textStorage === stage.sourceStorage, stage.sourceContainer.textView === activeView,
      !stage.sourceStorage.hasOpenCharacterTransaction,
      stage.sourceManager.textContainers.count == 1,
      stage.sourceStorage.layoutManagers.count == 1,
      stage.binding.state == .staged, stage.binding.owner === self,
      stage.binding.identity.arenaID == stage.ticket.provisionalArenaID,
      stage.context === activeContext, stage.context === activeView.inputContext,
      (stage.context.client as? PagedNativeTextInputClient)?.identity.ownerID == ownerID,
      (stage.context.client as? PagedNativeTextInputClient)?.identity.sessionID == session.sessionID,
      (stage.context.client as? PagedNativeTextInputClient)?.isRetired == false else {
      throw BoomError.stale("The staged client no longer owns the exact source selection/focus/keyboard.")
    }
  }
  private func adopt(_ stage: StagedClient,
    mounted: (PagedNativeTextView, PagedNativeTextView) throws -> Void) -> Error? {
    precondition(isAdopting && stagedClient != nil)
    let trace = PerformanceTrace.begin("Editor.Update", event: 7)
    defer { PerformanceTrace.end("Editor.Update", trace) }
    let oldView = activeView!
    let source = stage.sourceSelection.inputLease
    let ownsSourceFocus = (try? physicalInputLease(for: oldView)) == source
    oldView.inputBinding?.retire()
    // Retire only the arena projection. The document input context must not
    // deactivate/discard opaque dead-key or IME state during this rotation.
    oldView.installPreparedProjection(storage: stage.storage, binding: stage.binding,
      manager: stage.sourceManager,
      container: stage.sourceContainer, selection: stage.ticket.localSelection,
      affinity: stage.ticket.selectionAffinity)
    stage.binding.activate(); stagedClient = nil
    do {
      try mounted(oldView, activeView)
      if ownsSourceFocus, source.isFirstResponder {
        // Retirement may change AppKit's responder relationship. The exact
        // staged source lease was validated before that synchronous boundary.
        guard let window = stage.sourceWindow, activeView.window === window,
          window.isKeyWindow == source.isKeyWindow else {
          throw BoomError.stale("The managed mount changed its captured native window.")
        }
        if window.firstResponder !== activeView {
          guard window.makeFirstResponder(activeView) else {
            throw BoomError.unavailable("The managed mount could not restore its captured native focus.")
          }
        }
        // The same document context remains active; no repeated activation
        // or transient-coordinate notification occurs inside adoption.
        guard activeView.window === window, window.firstResponder === activeView else {
          throw BoomError.unavailable("The managed mount did not retain its captured native focus.")
        }
      }
    }
    catch {
      // The source and Foundation move already happened. Keep the actual
      // physical refusal on this binding and never grant raw-key replay.
      activeView.inputBinding?.recordRefusal(error)
      return error
    }
    if ownsSourceFocus, let target = try? physicalInputLease(for: activeView) {
      if source.keyboardEpoch == target.keyboardEpoch, source.keyboardID == target.keyboardID,
        source.windowID == target.windowID,
        source.isFirstResponder == target.isFirstResponder, source.isKeyWindow == target.isKeyWindow {
        lastReplayTransition = PagedNativeReplayInputTransition(source: source, target: target)
      }
    }
    return nil
  }
  func withStagedNavigationInstallation(_ ticket: PagedNativeNavigationInstallationTicket,
    advancingFoundation: ((() -> Void) -> Void)? = nil,
    mounted: @escaping (PagedNativeTextView, PagedNativeTextView) throws -> Void) throws -> PagedNativeLogicalWindow {
    guard let stage = stagedClient, stage.ticket === ticket else {
      throw BoomError.stale("Another source stage owns this physical navigation.")
    }
    try requireAdoptionSource(stage)
    isAdopting = true; lastReplayTransition = nil
    defer {
      isAdopting = false
      if ticket.wasConsumed, let selection = ticket.documentSelection {
        do { try setDocumentSelection(selection) }
        catch { activeView?.inputBinding?.recordRefusal(error) }
      } else if ticket.wasConsumed {
        documentSelection = nil; documentSelectionGeneration = nil
      }
      if let activeView { notifyNativeState(from: activeView, edited: false) }
      // Only the fully installed source/selection/geometry is visible to the
      // input method. Never notify it of an intermediate staged projection.
      if ticket.wasConsumed { activeContext?.invalidateCharacterCoordinates() }
    }
    var mountFailure: Error?
    // Session admits the complete source move before Foundation can pop its
    // entry. Its lexical consumer performs only the prepared nonfallible move.
    let window = try session.withStagedNavigationInstallation(ticket, consuming: { consume in
      if let advancingFoundation { advancingFoundation(consume) } else { consume() }
    }, installing: { _, arena, _ in
      precondition(arena == stage.binding.identity.arenaID)
      mountFailure = adopt(stage, mounted: mounted)
    })
    if let mountFailure { throw mountFailure }
    return window
  }
  private func cancelSourceStage(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    try session.cancelStagedNavigationInstallation(ticket)
  }
  private func retireConstructedStage() {
    guard let stage = stagedClient else { return }
    stage.binding.retire() // a cancelled projection never retires the document context
    stagedClient = nil
  }
  func cancelNavigationStage(_ ticket: PagedNativeNavigationInstallationTicket) throws {
    guard !isAdopting else { throw BoomError.stale("Navigation is already in its source adoption scope.") }
    if let stage = stagedClient {
      guard stage.ticket === ticket else {
        throw BoomError.stale("Another physical stage owns this navigation reservation.")
      }
      try cancelSourceStage(stage.ticket); retireConstructedStage()
    } else { try session.cancelStagedNavigationInstallation(ticket) }
  }

  /// Spend the existing resident reserve before recentering; a full 16KiB
  /// display must not recreate its native client for every additional key.
  func recenterResidentWindowIfNeeded() throws {
    guard let view = activeView, view.inputCommandIsClosed, !view.hasMarkedText(),
      session.logicalWindow.summary.bytes > UInt64(PagedWorkingWindow.hardBytes),
      !isAdopting, stagedClient == nil,
      let commands = commandOwner, !commands.hasPendingCommand, let mount = commands.mountView else { return }
    let selection = try currentDocumentSelection()
    let start = session.logicalWindow.start.utf16
    guard selection.focusUTF16 >= start,
      let localFocus = Int(exactly: selection.focusUTF16 - start) else {
      throw BoomError.invalid("The resident logical focus is outside its actual window.")
    }
    let observed = try observeSelection()
    let ticket = try session.prepareResidentRecenter(localFocusUTF16: localFocus, owner: self)
    do {
      try stageNavigation(ticket, observedSelection: observed)
      _ = try withStagedNavigationInstallation(ticket, mounted: mount)
    } catch {
      let original = error
      if !ticket.wasConsumed {
        do { try cancelNavigationStage(ticket) }
        catch { throw PagedNativeNavigationCleanupFailure(original: original, cleanup: error) }
      }
      throw original
    }
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
      acceptedInputDeliveryDepth == 0, documentContextCallbackDepth == 0,
      (activeContext?.client as? PagedNativeTextInputClient)?.isInterpretingNativeEvent != true,
      commandOwner === expectedOwner, let view = activeView,
      let binding = view.inputBinding, binding.state == .active,
      binding.identity == activeIdentity,
      view.inputCommandIsClosed, !view.hasMarkedText() else {
      throw BoomError.stale("Native input or its command owner still requires an explicit disposition.")
    }
    guard commandOwner === expectedOwner, activeView === view, binding.state == .active,
      binding.identity.ownerID == ownerID, binding.identity.sessionID == session.sessionID,
      binding.identity.arenaID == session.arenaID, firstRefusal == nil else {
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
    view.retireDocumentInputContext()
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
      !isAdopting, acceptedInputDeliveryDepth == 0, documentContextCallbackDepth == 0,
      commandOwner == nil, firstRefusal == nil else {
      throw BoomError.stale("Native physical input is still installed or retains an unresolved refusal.")
    }
  }
}

/// Preserve the original construction/stale refusal if explicit stage cleanup
/// also refuses. Neither error clears source intent, physical input or custody.
struct PagedNativeNavigationCleanupFailure: Error {
  let original: Error
  let cleanup: Error
}
