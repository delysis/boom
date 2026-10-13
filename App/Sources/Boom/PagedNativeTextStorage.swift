import AppKit
import BoomCore
import Foundation

/// TextKit owns only this bounded island. The accepted character primitive
/// records exact deltas before it notifies layout or style observers. Storage,
/// hashing and publication are never waited for here.
final class PagedNativeTextStorage: NSTextStorage {
  private let backing: NSMutableAttributedString
  private let session: PagedNativeSession
  let inputBinding: PagedNativeInputBinding?
  // Only the standalone primitive controls use the in-place prototype. A
  // managed physical client instead has an immutable binding for its arena.
  private var arenaID: UUID
  private let installationAttributes: [NSAttributedString.Key: Any]
  private var editingDepth = 0
  private var characterGateOpen = false
  private var nativeGroupID = UUID()
  fileprivate var performanceEvent: UInt64 = 0
  private(set) var mutationFailure: Error?
  var didRejectMutation: (@MainActor (Error) -> Void)?
  var nativeSelection: (@MainActor () throws -> PagedWorkingSelection)?

  @MainActor init(session: PagedNativeSession, attributes: [NSAttributedString.Key: Any] = [:],
    inputBinding: PagedNativeInputBinding? = nil,
    stagedTicket: PagedNativeHistoryInstallationTicket? = nil,
    stagedNavigationTicket: PagedNativeNavigationInstallationTicket? = nil) throws {
    guard stagedTicket == nil || stagedNavigationTicket == nil else {
      throw BoomError.invalid("A native projection has exactly one staged installation owner.")
    }
    let window: PagedTextWindow
    if let stagedNavigationTicket {
      guard inputBinding != nil else { throw BoomError.invalid("Staged navigation requires its physical owner.") }
      window = try session.windowForStagedNavigationInstallation(stagedNavigationTicket)
    } else if let stagedTicket {
      guard inputBinding != nil else { throw BoomError.invalid("A staged text window requires its physical input owner.") }
      window = try session.windowForStagedNativeInstallation(stagedTicket)
    } else { window = try session.windowForNativeInstallation() }
    self.session = session
    self.inputBinding = inputBinding
    arenaID = stagedNavigationTicket?.provisionalArenaID ?? stagedTicket?.provisionalArenaID ?? session.arenaID
    if let identity = inputBinding?.identity {
      guard identity.sessionID == session.sessionID, identity.arenaID == arenaID,
        identity.installationWindowID == window.windowID else {
        throw BoomError.stale("A native text window cannot borrow another physical client's identity.")
      }
    }
    installationAttributes = attributes
    backing = NSMutableAttributedString(string: window.text, attributes: attributes)
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  required init?(pasteboardPropertyList: Any, ofType: NSPasteboard.PasteboardType) {
    // Pasteboard construction has no owner-bound native session.
    return nil
  }

  override var string: String {
    precondition(Thread.isMainThread)
    return backing.string
  }
  override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
    precondition(Thread.isMainThread)
    return backing.attributes(at: location, effectiveRange: range)
  }
  override func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
    precondition(Thread.isMainThread)
    guard MainActor.assumeIsolated({ inputBinding?.state != .retired }) else { return }
    backing.setAttributes(attributes, range: range)
    edited(.editedAttributes, range: range, changeInLength: 0)
  }
  override func beginEditing() {
    precondition(Thread.isMainThread)
    editingDepth += 1
    super.beginEditing()
  }
  override func endEditing() {
    precondition(Thread.isMainThread && editingDepth > 0)
    // TextKit processes its edited-characters notification before the source
    // gate closes. Reentrant attribute work cannot seal a partial transaction.
    super.endEditing()
    editingDepth -= 1
    if editingDepth == 0, characterGateOpen {
      characterGateOpen = false
      MainActor.assumeIsolated { session.nativeCharacterTransactionDidClose() }
    }
  }
  override func replaceCharacters(in range: NSRange, with replacement: String) {
    precondition(Thread.isMainThread)
    guard MainActor.assumeIsolated({ inputBinding?.state != .retired }) else { return }
    do {
      // Scalar and reserve admission precede both source and Cocoa mutation.
      do {
        let trace = PerformanceTrace.begin("Editor.ManagedAdmission", event: performanceEvent)
        defer { PerformanceTrace.end("Editor.ManagedAdmission", trace) }
        try MainActor.assumeIsolated { try admits(range, replacement: replacement) }
        try MainActor.assumeIsolated { try inputBinding?.admitsInput(in: session, requiresCommand: true) }
      }
      let ownsTransaction = editingDepth == 0
      if ownsTransaction { beginEditing() }
      defer { if ownsTransaction { endEditing() } }
      if !characterGateOpen {
        try MainActor.assumeIsolated { try session.nativeCharacterTransactionWillBegin() }
        characterGateOpen = true
      }
      let accepted: Bool
      do {
        let trace = PerformanceTrace.begin("Editor.ManagedSourceMutation", event: performanceEvent)
        defer { PerformanceTrace.end("Editor.ManagedSourceMutation", trace) }
        accepted = try MainActor.assumeIsolated {
          try session.replace(range, with: replacement, groupID: nativeGroupID,
            beforeSelection: nativeSelection?())
        }
      }
      guard accepted else { return }
      let insertedUnits = replacement.utf16.count
      do {
        let trace = PerformanceTrace.begin("Editor.ManagedBackingMutation", event: performanceEvent)
        defer { PerformanceTrace.end("Editor.ManagedBackingMutation", trace) }
        backing.replaceCharacters(in: range, with: replacement)
      }
      do {
        let trace = PerformanceTrace.begin("Editor.ManagedTextKitNotification", event: performanceEvent)
        defer { PerformanceTrace.end("Editor.ManagedTextKitNotification", trace) }
        edited(.editedCharacters, range: range, changeInLength: insertedUnits - range.length)
      }
    } catch {
      mutationFailure = error
      MainActor.assumeIsolated { inputBinding?.recordRefusal(error); didRejectMutation?(error) }
    }
  }

  /// The native command owner closes a group at the same boundary it gives to
  /// UndoManager. IME has its independently pinned single composition group.
  @MainActor func beginNativeGroup() { nativeGroupID = UUID() }

  /// Source installation is a bounded projection change, not a user text
  /// replacement. Its admitted command reserves the sequence before TextKit
  /// observes the new arena, and ordinary primitives then continue in it.
  @MainActor @discardableResult
  func installPreparedHistory(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeHistoryAdmission {
    guard inputBinding == nil else {
      throw BoomError.denied("Managed input clients install a separately constructed source window.")
    }
    try admitsCurrentArena()
    guard editingDepth == 0, !characterGateOpen, mutationFailure == nil else {
      throw BoomError.stale("Native text storage is still processing an earlier character transaction.")
    }
    let attributed = NSAttributedString(string: prepared.window.text, attributes: installationAttributes)
    return try session.installPreparedHistory(prepared) { [self] _, nextArena, _ in
      let oldLength = backing.length
      beginEditing()
      arenaID = nextArena; nativeGroupID = UUID()
      backing.setAttributedString(attributed)
      edited(.editedCharacters, range: NSRange(location: 0, length: oldLength),
        changeInLength: backing.length - oldLength)
      endEditing()
    }
  }
  @MainActor func admitsCurrentArena() throws {
    if let inputBinding { try inputBinding.admitsInput(in: session) }
    guard session.arenaID == arenaID else {
      throw BoomError.stale("This native text storage belongs to an earlier editing window.")
    }
  }
  @MainActor func admits(_ range: NSRange, replacement: String) throws {
    try admitsCurrentArena()
    try session.canReplace(range, with: replacement)
  }
}

/// Native text input supplies marked-text mutations to the same primitive.
/// The ordinary app route remains disabled until coherent save/history and
/// floating navigation are supplied by the session's real storage owner.
@MainActor final class PagedNativeTextView: NSTextView {
  let session: PagedNativeSession
  let boundedStorage: PagedNativeTextStorage
  let inputBinding: PagedNativeInputBinding?
  private var inputCommandDepth = 0
  private var performanceInputActive = false
  private(set) var performanceEvent: UInt64 = 0
  private var commandSelection: PagedWorkingSelection?
  private var pendingDocumentCommand: (selector: Selector, observation: PagedNativeSelectionObservation)?
  private var selectionMutationDepth = 0
  private var constructingView = true
  private let managedInputClient: PagedNativeTextInputClient?
  private var managedInputContext: NSTextInputContext?
  private var constructingInputContext = false
  var didRejectInput: ((Error) -> Void)?
  override var undoManager: UndoManager? {
    guard let inputBinding else { return super.undoManager }
    guard inputBinding.state == .active else { return nil }
    return inputBinding.owner?.commandOwner?.manager
  }
  override var inputContext: NSTextInputContext? {
    guard let managedInputClient else { return super.inputContext }
    guard !constructingView, !constructingInputContext, !managedInputClient.isRetired else { return nil }
    if let managedInputContext { return managedInputContext }
    constructingInputContext = true
    defer { constructingInputContext = false }
    let context = managedInputClient.makeContext()
    managedInputContext = context
    return context
  }
  var inputCommandIsClosed: Bool {
    inputCommandDepth == 0 && selectionMutationDepth == 0 && (inputBinding?.commandDepth ?? 0) == 0
  }

  init(frame: NSRect, session: PagedNativeSession,
    inputBinding: PagedNativeInputBinding? = nil,
    stagedTicket: PagedNativeHistoryInstallationTicket? = nil,
    stagedNavigationTicket: PagedNativeNavigationInstallationTicket? = nil,
    canonicalOpening: PagedNativeCanonicalOpening? = nil) throws {
    if let canonicalOpening {
      guard stagedTicket == nil, stagedNavigationTicket == nil, canonicalOpening.sessionID == session.sessionID,
        session.canonicalOpening?.record == canonicalOpening.record,
        session.canonicalOpening?.window.windowID == canonicalOpening.window.windowID else {
        throw BoomError.stale("Canonical physical construction has another unopened source owner.")
      }
    }
    self.session = session
    self.inputBinding = inputBinding
    managedInputClient = inputBinding.map { PagedNativeTextInputClient(identity: $0.identity) }
    let storage = try PagedNativeTextStorage(session: session,
      attributes: [.font: NSFont.systemFont(ofSize: 17)],
      inputBinding: inputBinding, stagedTicket: stagedTicket, stagedNavigationTicket: stagedNavigationTicket)
    boundedStorage = storage
    let manager = NSLayoutManager()
    manager.allowsNonContiguousLayout = true
    let container = NSTextContainer(size: NSSize(width: max(1, frame.width), height: max(1, frame.height)))
    container.widthTracksTextView = true; container.heightTracksTextView = false
    storage.addLayoutManager(manager); manager.addTextContainer(container)
    super.init(frame: frame, textContainer: container)
    isEditable = true; isSelectable = true; isRichText = false
    // Canonical Undo uses registered root/group handles. TextKit must not also
    // retain old source strings or add a competing automatic Undo stack.
    allowsUndo = false
    drawsBackground = false; writingToolsBehavior = .none
    isHorizontallyResizable = false; isVerticallyResizable = false
    textContainerInset = NSSize(width: 16, height: 16)
    storage.didRejectMutation = { [weak self] error in self?.didRejectInput?(error) }
    storage.nativeSelection = { [weak self] in
      guard let self else { throw BoomError.stale("The native selection owner has retired.") }
      if let commandSelection = self.commandSelection { return commandSelection }
      return try self.session.nativeSelection(self.selectedRange())
    }
    if let stagedNavigationTicket {
      super.setSelectedRange(stagedNavigationTicket.localSelection, affinity: stagedNavigationTicket.selectionAffinity, stillSelecting: false)
    } else if let stagedTicket {
      // Initial selection is part of the constructed projection, not a
      // callback authorized to select another source arena.
      super.setSelectedRange(NSRange(location: stagedTicket.localCaretUTF16, length: 0),
        affinity: .downstream, stillSelecting: false)
    } else if let canonicalOpening {
      super.setSelectedRange(NSRange(location: canonicalOpening.localCaretUTF16, length: 0),
        affinity: .downstream, stillSelecting: false)
    }
    managedInputClient?.bindOnce(to: self)
    constructingView = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Only the immutable binding's owner may retire a managed physical client.
  /// Deactivation controls input-source activation; it is not a callback join.
  /// The association is deliberately left intact for any retained context.
  func retirePhysicalInputClient() {
    precondition(inputBinding?.state == .retired && inputCommandIsClosed)
    managedInputClient?.retire()
    let context = managedInputContext
    managedInputContext = nil
    context?.deactivate()
  }

  override func becomeFirstResponder() -> Bool {
    if let binding = inputBinding, binding.state != .active { return false }
    let accepted = super.becomeFirstResponder()
    if accepted { inputBinding?.owner?.recordFocusTransition(from: self) }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { inputBinding?.owner?.recordFocusTransition(from: self) }
    return accepted
  }

  @discardableResult
  func installPreparedHistory(_ prepared: PagedNativePreparedHistoryMove) throws -> PagedNativeHistoryAdmission {
    guard inputCommandDepth == 0, !hasMarkedText() else {
      throw BoomError.stale("An active native input command pins its current source island.")
    }
    let admission = try boundedStorage.installPreparedHistory(prepared)
    setSelectedRange(NSRange(location: prepared.localCaretUTF16, length: 0))
    return admission
  }

  override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
    guard inputBinding?.state != .retired else { return false }
    do {
      try boundedStorage.admitsCurrentArena()
      if let replacementString { try boundedStorage.admits(affectedCharRange, replacement: replacementString) }
    } catch {
      rejectInput(error); return false
    }
    return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    inputCommand {
      session.beginComposition()
      super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
  }
  override func unmarkText() {
    inputCommand {
      super.unmarkText()
    }
  }
  override func insertText(_ string: Any, replacementRange: NSRange) {
    // AppKit may unmark and replace through several primitives in this call.
    // Keep the whole command gated so interim marked bytes cannot be sealed.
    inputCommand { super.insertText(string, replacementRange: replacementRange) }
  }
  override func keyDown(with event: NSEvent) {
    let trace = beginInputTiming()
    defer { endInputTiming(trace) }
    guard admitsCommandDispatch() else { return }
    if inputBinding?.owner?.commandOwner?.interceptRawKey(event, from: self) == true { return }
    if inputBinding?.owner?.interceptDocumentKey(event, from: self) == true { return }
    inputCommand { super.keyDown(with: event) }
  }
  override func doCommand(by selector: Selector) {
    let trace = beginInputTiming()
    defer { endInputTiming(trace) }
    guard admitsCommandDispatch() else { return }
    if let owner = inputBinding?.owner?.commandOwner {
      if selector == NSSelectorFromString("undo:") { owner.request(.undo); return }
      if selector == NSSelectorFromString("redo:") { owner.request(.redo); return }
    }
    if let owner = inputBinding?.owner, owner.handlesDocumentCommand(selector) {
      do {
        let observed = try owner.observeSelection()
        if inputCommandDepth > 0 {
          guard pendingDocumentCommand == nil else {
            throw BoomError.stale("One native key command already owns its document movement.")
          }
          // The surrounding keyDown must first close its real character and
          // group scopes. This value contains no text and never overwrites an
          // earlier command. Source/selection are checked again on delivery.
          pendingDocumentCommand = (selector, observed)
        } else { try owner.dispatchDocumentCommand(selector, observed: observed) }
      } catch { rejectInput(error) }
      return
    }
    inputCommand { super.doCommand(by: selector) }
  }
  /// Only the actual owning viewport may forward a document selector whose
  /// requested endpoint/entire range is contained in this physical island.
  /// This helper bypasses only our selector routing, never input/source gates.
  func performContainedDocumentCommand(_ selector: Selector) throws {
    guard let owner = inputBinding?.owner, owner.activeView === self,
      inputCommandIsClosed, !hasMarkedText() else {
      throw BoomError.stale("Contained document movement has another native source command.")
    }
    try boundedStorage.admitsCurrentArena()
    inputCommand { super.doCommand(by: selector) }
    guard inputBinding?.firstRefusal == nil, boundedStorage.mutationFailure == nil else {
      throw BoomError.stale("Contained native movement was refused by its actual input source.")
    }
  }
  override func setSelectedRange(_ charRange: NSRange) {
    selectionChange(ranges: [NSValue(range: charRange)]) { super.setSelectedRange(charRange) }
  }
  override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
    selectionChange(ranges: [NSValue(range: charRange)]) {
      super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
    }
  }
  override var selectedRanges: [NSValue] {
    get { super.selectedRanges }
    set { selectionChange(ranges: newValue) { super.selectedRanges = newValue } }
  }
  override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
    selectionChange(ranges: ranges) {
      super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }
  }

  private func selectionChange(ranges: [NSValue], operation: () -> Void) {
    guard inputBinding?.state != .retired else { return }
    guard let inputBinding, !constructingView else { operation(); return }
    do {
      try inputBinding.admitsInput(in: session)
      guard ranges.count == 1 else {
        throw BoomError.unavailable("Multiple native selections require their own bounded owner.")
      }
      let range = ranges[0].rangeValue
      let end = range.location.addingReportingOverflow(range.length)
      guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
        !end.overflow, end.partialValue <= boundedStorage.length else {
        throw BoomError.stale("A native selection falls outside its bounded source window.")
      }
      guard selectionMutationDepth < 32 else {
        throw BoomError.budget("Native selection callback nesting exceeds its bound.")
      }
      let outermost = selectionMutationDepth == 0
      if outermost { try inputBinding.requireSelectionCapacity() }
      let before = outermost ? selectedRange() : nil
      let beforeAffinity = selectionAffinity
      selectionMutationDepth += 1
      operation()
      selectionMutationDepth -= 1
      if outermost, before != selectedRange() || beforeAffinity != selectionAffinity {
        inputBinding.recordSelectionChange()
      }
    } catch { rejectInput(error) }
  }

  private func rejectInput(_ error: Error) {
    guard inputBinding?.state != .retired else { return }
    inputBinding?.recordRefusal(error)
    if inputBinding == nil || inputBinding?.state == .active { didRejectInput?(error) }
  }

  private func admitsCommandDispatch() -> Bool {
    guard inputBinding?.state != .retired else { return false }
    do { try inputBinding?.admitsInput(in: session); return true }
    catch { rejectInput(error); return false }
  }

  // keyDown can call doCommand/insertText/IME primitives. Only its outer
  // synchronous scope owns a span; nested calls retain that observation ID.
  private func beginInputTiming() -> PerformanceTrace.Span? {
    guard !performanceInputActive, inputBinding?.state != .retired else { return nil }
    let event = PerformanceTrace.nextEditorEvent()
    guard event != 0, let trace = PerformanceTrace.begin("Editor.ManagedInput", event: event) else { return nil }
    performanceInputActive = true
    performanceEvent = event; boundedStorage.performanceEvent = event
    return trace
  }
  private func endInputTiming(_ trace: PerformanceTrace.Span?) {
    guard let trace else { return }
    PerformanceTrace.end("Editor.ManagedInput", trace)
    performanceInputActive = false
  }
  override func draw(_ dirtyRect: NSRect) {
    let trace = PerformanceTrace.begin("Editor.ManagedDraw", event: performanceEvent)
    defer { PerformanceTrace.end("Editor.ManagedDraw", trace) }
    super.draw(dirtyRect)
  }

  private func inputCommand(_ operation: () -> Void) {
    guard inputBinding?.state != .retired else { return }
    let trace = beginInputTiming()
    defer { endInputTiming(trace) }
    var bindingOpened = false
    do {
      try boundedStorage.admitsCurrentArena()
      if let inputBinding {
        try inputBinding.beginCommand(in: session); bindingOpened = true
      }
      if inputCommandDepth == 0 { commandSelection = try session.nativeSelection(selectedRange()) }
      try session.nativeCharacterTransactionWillBegin()
      if inputBinding != nil, inputCommandDepth == 0, !session.isPinned { boundedStorage.beginNativeGroup() }
    }
    catch {
      if inputCommandDepth == 0 { commandSelection = nil }
      if bindingOpened { inputBinding?.endCommand() }
      rejectInput(error); return
    }
    inputCommandDepth += 1
    defer {
      inputCommandDepth -= 1
      if inputCommandDepth == 0 { commandSelection = nil }
      if inputCommandDepth == 0, session.isPinned, !hasMarkedText() {
        // Nested unmark/insert primitives still belong to this composition.
        // A later ordinary command must not reuse its pre-composition UUID.
        session.endComposition()
        boundedStorage.beginNativeGroup()
      }
      session.nativeCharacterTransactionDidClose()
      if bindingOpened { inputBinding?.endCommand() }
      if inputCommandDepth == 0 {
        if let pending = pendingDocumentCommand {
          // Move this value to the actual lexical receiver before a contained
          // native command opens/closes its own scope. It cannot recursively
          // redispatch the still-installed pending selector on that close.
          pendingDocumentCommand = nil
          do {
            guard let owner = inputBinding?.owner else {
              throw BoomError.stale("Document command lost its physical owner.")
            }
            try owner.dispatchDocumentCommand(pending.selector, observed: pending.observation)
          } catch {
            if pendingDocumentCommand == nil { pendingDocumentCommand = pending }
            rejectInput(error)
          }
        }
        inputBinding?.owner?.commandOwner?.inputCommandDidClose()
      }
    }
    operation()
  }
}
