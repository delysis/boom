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
  private var editingDepth = 0
  private var characterGateOpen = false
  @MainActor var hasOpenCharacterTransaction: Bool { characterGateOpen }
  private var nativeGroupID = UUID()
  fileprivate var performanceEvent: UInt64 = 0
  private(set) var mutationFailure: Error?
  var didRejectMutation: (@MainActor (Error) -> Void)?
  var nativeSelection: (@MainActor () throws -> PagedWorkingSelection?)?

  @MainActor init(session: PagedNativeSession, attributes: [NSAttributedString.Key: Any] = [:],
    inputBinding: PagedNativeInputBinding? = nil,
    stagedNavigationTicket: PagedNativeNavigationInstallationTicket? = nil) throws {
    let window: PagedNativeLogicalWindow
    if let stagedNavigationTicket {
      guard inputBinding != nil else { throw BoomError.invalid("Staged navigation requires its physical owner.") }
      window = try session.windowForStagedNavigationInstallation(stagedNavigationTicket)
    } else { window = session.logicalWindow }
    self.session = session
    self.inputBinding = inputBinding
    arenaID = stagedNavigationTicket?.provisionalArenaID ?? session.arenaID
    if let identity = inputBinding?.identity {
      guard identity.sessionID == session.sessionID, identity.arenaID == arenaID,
        identity.installationWindowID == window.windowID else {
        throw BoomError.stale("A native text window cannot borrow another physical client's identity.")
      }
    }
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
    // Staged and retired projections never receive character edits. Late
    // framework callbacks on them cannot affect the current editor.
    guard MainActor.assumeIsolated({ inputBinding == nil || inputBinding?.state == .active }) else { return }
    let beforeGeneration = MainActor.assumeIsolated { session.generation }
    do {
      // Scalar and reserve admission precede both source and Cocoa mutation.
      do {
        let trace = PerformanceTrace.begin("Editor.ManagedAdmission", event: performanceEvent)
        defer { PerformanceTrace.end("Editor.ManagedAdmission", trace) }
        // The live storage primitive is the edit boundary. View command
        // scopes supply grouping and selection, not permission to type.
        try MainActor.assumeIsolated { try admits(range, replacement: replacement) }
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
      if MainActor.assumeIsolated({ session.generation != beforeGeneration }) {
        // The source accepted characters before this failure. Retain the
        // inconsistent projection; a later callback cannot erase it.
        if mutationFailure == nil { mutationFailure = error }
        MainActor.assumeIsolated { inputBinding?.recordRefusal(error); didRejectMutation?(error) }
      } else {
        // Admission precedes both source and backing mutation. A malformed
        // or obsolete callback leaves the current editor usable.
        PerformanceTrace.event("Editor.ManagedAdmission")
      }
    }
  }

  /// The native command owner closes a group at the same boundary it gives to
  /// UndoManager. IME has its independently pinned single composition group.
  @MainActor func beginNativeGroup(intent: PagedNativeInputOwner.TypingIntent? = nil) {
    nativeGroupID = inputBinding?.owner?.nativeInputGroupID(intent: intent) ?? UUID()
  }
  @MainActor var currentNativeGroupID: UUID { nativeGroupID }

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

/// Native text input supplies marked-text mutations to the same primitive;
/// the native command owner publishes and installs file-backed history.
@MainActor final class PagedNativeTextView: MarkdownTextView {
  let session: PagedNativeSession
  private(set) var boundedStorage: PagedNativeTextStorage
  private(set) var inputBinding: PagedNativeInputBinding?
  private var inputCommandDepth = 0
  private var performanceInputActive = false
  private(set) var performanceEvent: UInt64 = 0
  private var commandSelection: PagedWorkingSelection?
  private var pendingDocumentCommand: (selector: Selector, observation: PagedNativeSelectionObservation)?
  private var pendingDocumentReplacement: (selection: PagedNativeNavigationSelection, bytes: Data)?
  private var pendingDocumentClipboard: Bool?
  private var pendingDocumentTextPaste: PagedClipboardTextFile?
  private var pendingDocumentWrapping: (selection: PagedNativeNavigationSelection, prefix: String, suffix: String, toggles: Bool, name: String)?
  private var typingIntent: PagedNativeInputOwner.TypingIntent?
  private var selectionMutationDepth = 0
  private var constructingView = true
  private var managedInputClient: PagedNativeTextInputClient?
  override var hasCompleteMarkupContext: Bool {
    guard let coordinates = try? session.documentCoordinates() else { return false }
    return coordinates.utf16Start == 0
      && UInt64(coordinates.localUTF16) == coordinates.projectedUTF16
  }
  override var completionCaretUTF16: Int {
    let range = selectedRange()
    guard range.location >= 0, range.location != NSNotFound,
      let coordinates = try? session.documentCoordinates() else { return NSNotFound }
    let absolute = coordinates.utf16Start.addingReportingOverflow(UInt64(range.location))
    guard !absolute.overflow, let caret = Int(exactly: absolute.partialValue) else { return NSNotFound }
    return caret
  }
  private var managedInputContext: NSTextInputContext?
  private var constructingInputContext = false
  var didRejectInput: ((Error) -> Void)?
  override var undoManager: UndoManager? {
    // TextKit asks for a manager while coalescing character input even with
    // allowsUndo disabled. Our manually grouped root manager belongs to the
    // responder/menu path, not automatic string Undo inside this scope.
    guard inputCommandDepth == 0, !boundedStorage.hasOpenCharacterTransaction else { return nil }
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
    stagedNavigationTicket: PagedNativeNavigationInstallationTicket? = nil,
    canonicalOpening: PagedNativeCanonicalOpening? = nil) throws {
    // Existing Update stage, events 1...5 identify constructor substeps.
    let construction = PerformanceTrace.begin("Editor.Update", event: 1)
    defer { PerformanceTrace.end("Editor.Update", construction) }
    if let canonicalOpening {
      guard stagedNavigationTicket == nil, canonicalOpening.sessionID == session.sessionID,
        session.canonicalOpening?.record == canonicalOpening.record else {
        throw BoomError.stale("Canonical physical construction has another unopened source owner.")
      }
    }
    self.session = session
    self.inputBinding = inputBinding
    managedInputClient = inputBinding.map { PagedNativeTextInputClient(identity: $0.identity) }
    let storageTrace = PerformanceTrace.begin("Editor.Update", event: 2)
    let storage = try PagedNativeTextStorage(session: session,
      attributes: [.font: MarkdownStyle.body],
      inputBinding: inputBinding, stagedNavigationTicket: stagedNavigationTicket)
    boundedStorage = storage
    PerformanceTrace.end("Editor.Update", storageTrace)
    let graphTrace = PerformanceTrace.begin("Editor.Update", event: 3)
    let manager = NSLayoutManager()
    manager.allowsNonContiguousLayout = true
    let container = NSTextContainer(size: NSSize(width: max(1, frame.width), height: max(1, frame.height)))
    container.widthTracksTextView = true; container.heightTracksTextView = false
    storage.addLayoutManager(manager); manager.addTextContainer(container)
    super.init(frame: frame, textContainer: container)
    PerformanceTrace.end("Editor.Update", graphTrace)
    documentID = session.logicalWindow.snapshot.sourceRevision.documentID
    isEditable = true; isSelectable = true; isRichText = false
    // Canonical Undo uses registered root/group handles. TextKit must not also
    // retain old source strings or add a competing automatic Undo stack.
    allowsUndo = false
    drawsBackground = false; writingToolsBehavior = .none
    isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false; isAutomaticSpellingCorrectionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    let checkingTrace = PerformanceTrace.begin("Editor.Update", event: 4)
    isContinuousSpellCheckingEnabled = true
    PerformanceTrace.end("Editor.Update", checkingTrace)
    importsGraphics = false
    isHorizontallyResizable = false; isVerticallyResizable = false
    textContainerInset = NSSize(width: 16, height: 16)
    prepareProjectionCallbacks(storage)
    let selectionTrace = PerformanceTrace.begin("Editor.Update", event: 5)
    if let stagedNavigationTicket {
      super.setSelectedRange(stagedNavigationTicket.localSelection, affinity: stagedNavigationTicket.selectionAffinity, stillSelecting: false)
    } else if let canonicalOpening {
      super.setSelectedRange(NSRange(location: canonicalOpening.localCaretUTF16, length: 0),
        affinity: .downstream, stillSelecting: false)
    }
    PerformanceTrace.end("Editor.Update", selectionTrace)
    managedInputClient?.bindOnce(to: self)
    constructingView = false
    MarkdownStyle.apply(to: self)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func prepareProjectionCallbacks(_ storage: PagedNativeTextStorage) {
    storage.didRejectMutation = { [weak self, weak storage] error in
      guard let self, let storage, self.boundedStorage === storage else { return }
      // This callback is emitted only AFTER an accepted source mutation.
      // Ordinary rejected input uses didRejectInput's diagnostic route.
      if let model = self.owner { model.report(error) }
      else { self.didRejectInput?(error) }
    }
    storage.nativeSelection = { [weak self, weak storage] in
      guard let self, let storage, self.boundedStorage === storage else {
        throw BoomError.stale("The native selection storage has retired.")
      }
      if let commandSelection = self.commandSelection {
        // Cocoa can remove and reinsert marked text within one command. Only
        // the first accepted primitive uses the command's before-selection;
        // later primitives use Session's current source cursor while Cocoa
        // is still updating its own selection.
        return commandSelection.generation == self.session.generation ? commandSelection : nil
      }
      return try self.session.nativeSelection(self.selectedRange())
    }
  }

  /// Source/SDK admission and prepared projection allocation preceded consume.
  /// The physical view and TextKit graph stay; old storage/binding never retarget.
  func installPreparedProjection(storage: PagedNativeTextStorage,
    binding: PagedNativeInputBinding, client: PagedNativeTextInputClient,
    context: NSTextInputContext, manager: NSLayoutManager, container: NSTextContainer,
    selection: NSRange, affinity: NSSelectionAffinity) {
    precondition(inputBinding?.state == .retired && inputCommandIsClosed
      && !boundedStorage.hasOpenCharacterTransaction && client.isAwaitingBind)
    precondition(manager === layoutManager && container === textContainer
      && manager.textStorage === boundedStorage && container.textView === self)
    constructingView = true
    defer { constructingView = false }
    clearGhost(); endGhostBoundary()
    boundedStorage = storage; inputBinding = binding
    managedInputClient = client; managedInputContext = context
    manager.replaceTextStorage(storage)
    precondition(manager.textStorage === storage && container.textView === self)
    client.bindOnce(to: self)
    super.setSelectedRange(selection, affinity: affinity, stillSelecting: false)
    MarkdownStyle.apply(to: self)
    inlineMedia.layout.reconcileMediaPresence(in: storage)
  }

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
      session.beginComposition(groupID: boundedStorage.currentNativeGroupID)
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
    let text = (string as? String) ?? (string as? NSAttributedString)?.string
    if let owner = inputBinding?.owner, let text, !hasMarkedText() {
      do {
        let global = try owner.currentDocumentSelection()
        let local = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let selectionSpansWindows = global.utf16Length > UInt64(selectedRange().length)
        let coordinates = try session.documentCoordinates()
        let exceedsWindow = text.utf8.count > PagedWorkingWindow.hardBytes - coordinates.localBytes
        if (selectionSpansWindows && local == selectedRange()) || exceedsWindow {
          guard text.utf8.count <= PagedCapturedEditInput.maximumInputBytes, pendingDocumentReplacement == nil else {
            throw BoomError.budget("This paste needs streamed file import.")
          }
          let selected = selectionSpansWindows ? global : try session.navigationSelection(local)
          inputCommand { pendingDocumentReplacement = (selected, Data(text.utf8)) }
          return
        }
      } catch { didRejectInput?(error); return }
    }
    inputCommand { super.insertText(string, replacementRange: replacementRange) }
  }

  override func compositionDidCommit() { MarkdownStyle.apply(to: self) }

  override func wrapSelection(_ marker: String, placeholder: String = "") {
    do {
      if let owner = inputBinding?.owner,
        let selection = try documentSelectionOutsideWindow(owner) {
        finishComposition(); clearGhost()
        try requestWrapping(selection, prefix: marker, suffix: marker, toggles: true, name: "Format")
        return
      }
      super.wrapSelection(marker, placeholder: placeholder)
    } catch { didRejectInput?(error) }
  }

  override func markdownLink(_ sender: Any?) {
    do {
      if let owner = inputBinding?.owner,
        let selection = try documentSelectionOutsideWindow(owner) {
        finishComposition(); clearGhost()
        try requestWrapping(selection, prefix: "[", suffix: "](url)", toggles: false, name: "Link")
        return
      }
      super.markdownLink(sender)
    } catch { didRejectInput?(error) }
  }

  /// ASCII with observed neighbors supplies a complete local grapheme
  /// boundary. Other cases use the full-source continuation, never a guessed
  /// fixed overlap. The common arrow/backspace path stays entirely native.
  func hasContainedASCIICharacterCommand(_ selector: Selector) -> Bool {
    let range = selectedRange(), text = boundedStorage.string as NSString
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
      range.location <= text.length, range.length <= text.length - range.location else { return false }
    if range.length > 0 { return range.location > 0 && NSMaxRange(range) < text.length }
    let command = NSStringFromSelector(selector)
    let forward = command.hasPrefix("moveForward") || command.hasPrefix("moveRight") || command == "deleteForward:"
    let at = range.location
    let lower = forward ? at - 1 : at - 2
    let upper = forward ? at + 2 : at + 1
    guard lower >= 0, upper <= text.length else { return false }
    for index in lower..<upper {
      let unit = text.character(at: index)
      guard unit < 128, unit != 13 else { return false }
    }
    return true
  }

  override func prefixLines(_ prefix: String) {
    if let binding = inputBinding, binding.state != .active { return }
    guard let commands = inputBinding?.owner?.commandOwner else { super.prefixLines(prefix); return }
    finishComposition(); clearGhost()
    // Queue now, including an interpreted menu selector inside keyDown. Pump
    // waits for the existing lexical input scope and any earlier source task.
    do { try commands.requestLinePrefix(prefix, from: self) }
    catch { didRejectInput?(error) }
  }

  override func copy(_ sender: Any?) {
    do {
      if let inputOwner = inputBinding?.owner, try documentSelectionOutsideWindow(inputOwner) != nil {
        try requestClipboard(cutting: false)
        return
      }
      super.copy(sender)
    } catch { didRejectInput?(error) }
  }

  override func cut(_ sender: Any?) {
    do {
      if let inputOwner = inputBinding?.owner, try documentSelectionOutsideWindow(inputOwner) != nil {
        try requestClipboard(cutting: true)
        return
      }
      inputCommand { super.cut(sender) }
    } catch { didRejectInput?(error) }
  }

  override func paste(_ sender: Any?) {
    do {
      if let source = try PagedClipboardTextFile.read(.general) {
        try requestTextFilePaste(source); return
      }
    } catch { didRejectInput?(error); return }
    inputCommand { super.paste(sender) }
  }

  override func pasteAsPlainText(_ sender: Any?) {
    do {
      if let source = try PagedClipboardTextFile.read(.general, explicitlyPlainText: true) {
        try requestTextFilePaste(source); return
      }
    } catch { didRejectInput?(error); return }
    inputCommand { super.pasteAsPlainText(sender) }
  }

  private func requestTextFilePaste(_ source: PagedClipboardTextFile) throws {
    guard let owner else { throw BoomError.stale("Text paste lost its document workspace.") }
    if inputCommandDepth > 0 {
      guard pendingDocumentTextPaste == nil else { throw BoomError.stale("Text paste already owns this native command.") }
      pendingDocumentTextPaste = source
    } else { _ = try owner.pasteDocumentTextFile(source, from: self) }
  }

  private func requestClipboard(cutting: Bool) throws {
    guard let owner else { throw BoomError.stale("Clipboard action lost its document workspace.") }
    if inputCommandDepth > 0 {
      guard pendingDocumentClipboard == nil else { throw BoomError.stale("A clipboard action already owns this native command.") }
      pendingDocumentClipboard = cutting
    } else { owner.copyDocumentSelection(from: self, cutting: cutting) }
  }

  private func documentSelectionOutsideWindow(_ owner: PagedNativeInputOwner)
    throws -> PagedNativeNavigationSelection? {
    let selection = try owner.currentDocumentSelection()
    let coordinates = try session.documentCoordinates()
    guard selection.utf16Offset <= coordinates.projectedUTF16,
      selection.utf16Length <= coordinates.projectedUTF16 - selection.utf16Offset else {
      throw BoomError.stale("Formatting has another document selection.")
    }
    let end = selection.utf16Offset + selection.utf16Length
    let windowEnd = coordinates.utf16Start + UInt64(coordinates.localUTF16)
    return selection.utf16Offset < coordinates.utf16Start || end > windowEnd ? selection : nil
  }

  private func requestWrapping(_ selection: PagedNativeNavigationSelection, prefix: String,
    suffix: String, toggles: Bool, name: String) throws {
    if inputCommandDepth > 0 {
      guard pendingDocumentWrapping == nil else { throw BoomError.stale("Formatting already owns this native command.") }
      pendingDocumentWrapping = (selection, prefix, suffix, toggles, name)
    } else {
      guard let commands = inputBinding?.owner?.commandOwner else {
        throw BoomError.stale("Formatting lost its native command owner.")
      }
      try commands.requestDocumentWrapping(selection, prefix: prefix, suffix: suffix,
        toggles: toggles, actionName: name)
    }
  }

  // Menu actions are sent to these Objective-C selectors directly; they need
  // not pass through the text key interpreter's doCommand(by:) route.
  @objc(undo:) func undoCanonicalHistory(_ sender: Any?) { requestCanonicalHistory(.undo) }
  @objc(redo:) func redoCanonicalHistory(_ sender: Any?) { requestCanonicalHistory(.redo) }

  override func selectAll(_ sender: Any?) {
    // Menu key equivalents reach selectAll: directly, while the key
    // interpreter reaches doCommand(by:). Both must select the logical
    // document rather than only the currently mounted editing window.
    if inputBinding != nil {
      guard admitsCommandDispatch() else { return }
      let selector = NSSelectorFromString("selectAll:")
      if inputBinding?.owner?.handlesDocumentCommand(selector) == true {
        doCommand(by: selector)
        return
      }
    }
    super.selectAll(sender)
  }

  private func requestCanonicalHistory(_ direction: PagedNativeHistoryHandle.Direction) {
    let trace = beginInputTiming()
    defer { endInputTiming(trace) }
    guard let binding = inputBinding, binding.state == .active,
      let owner = binding.owner, owner.activeView === self,
      let commands = owner.commandOwner, admitsCommandDispatch() else { return }
    commands.request(direction)
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(undoCanonicalHistory(_:)) || item.action == #selector(redoCanonicalHistory(_:)) {
      guard let binding = inputBinding, binding.state == .active,
        let owner = binding.owner, owner.activeView === self,
        let commands = owner.commandOwner else { return false }
      return item.action == #selector(undoCanonicalHistory(_:)) ? commands.manager.canUndo : commands.manager.canRedo
    }
    if item.action == #selector(markdownHeading(_:)) || item.action == #selector(markdownQuote(_:))
      || item.action == #selector(markdownList(_:)) {
      return isEditable && inputBinding?.state != .retired
    }
    return super.validateUserInterfaceItem(item)
  }

  override func didChangeText() {
    super.didChangeText()
    if !hasMarkedText(), !applyingExternal { MarkdownStyle.apply(to: self) }
  }
  var typedCharacterCommandGroupID: UUID? {
    guard let typingIntent, typingIntent.kind == .backwardDeletion || typingIntent.kind == .forwardDeletion else { return nil }
    return boundedStorage.currentNativeGroupID
  }

  override func keyDown(with event: NSEvent) {
    let trace = beginInputTiming()
    defer { endInputTiming(trace) }
    guard admitsCommandDispatch() else { return }
    if inputBinding?.owner?.commandOwner?.interceptRawKey(event, from: self) == true { return }
    if inputBinding?.owner?.interceptDocumentKey(event, from: self) == true { return }
    let previousIntent = typingIntent
    typingIntent = PagedNativeInputOwner.typingIntent(for: event)
    defer { typingIntent = previousIntent }
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
    inputCommand {
      // NSTextView's interpreter dynamically calls selectAll:. Its explicit
      // superclass action avoids reentering our logical-document menu route.
      if selector == NSSelectorFromString("selectAll:") { super.selectAll(nil) }
      else { super.doCommand(by: selector) }
    }
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
      let beforeGeneration = session.generation
      let beforeAffinity = selectionAffinity
      selectionMutationDepth += 1
      operation()
      selectionMutationDepth -= 1
      if outermost, before != selectedRange() || beforeAffinity != selectionAffinity {
        inputBinding.recordSelectionChange()
        inputBinding.owner?.userSelectionDidChange(from: self,
          previousRange: before, previousGeneration: beforeGeneration)
        if inputCommandDepth == 0 {
          inputBinding.owner?.notifyNativeState(from: self, edited: false)
        }
      }
    } catch { rejectInput(error) }
  }

  private func rejectInput(_ error: Error) {
    guard inputBinding?.state != .retired else { return }
    // Dispatch/selection refusal has not changed document characters. Keep
    // this observation separate from an accepted mutation or failed mount.
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
    let beforeGeneration = session.generation
    var bindingOpened = false
    do {
      try boundedStorage.admitsCurrentArena()
      if let inputBinding {
        try inputBinding.beginCommand(in: session); bindingOpened = true
      }
      if inputCommandDepth == 0 { commandSelection = try session.nativeSelection(selectedRange()) }
      try session.nativeCharacterTransactionWillBegin()
      if inputBinding != nil, inputCommandDepth == 0, !session.isPinned { boundedStorage.beginNativeGroup(intent: typingIntent) }
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
      session.nativeCharacterTransactionDidClose(
        capturingSelectionFrom: inputCommandDepth == 0 && inputBinding != nil ? self : nil)
      if bindingOpened { inputBinding?.endCommand() }
      if inputCommandDepth == 0 {
        if let wrapping = pendingDocumentWrapping {
          pendingDocumentWrapping = nil
          do { try requestWrapping(wrapping.selection, prefix: wrapping.prefix, suffix: wrapping.suffix,
            toggles: wrapping.toggles, name: wrapping.name) }
          catch { didRejectInput?(error) }
        }
        if let cutting = pendingDocumentClipboard {
          pendingDocumentClipboard = nil
          do { try requestClipboard(cutting: cutting) }
          catch { didRejectInput?(error) }
        }
        if let source = pendingDocumentTextPaste {
          pendingDocumentTextPaste = nil
          do { try requestTextFilePaste(source) }
          catch { didRejectInput?(error) }
        }
        if let pending = pendingDocumentReplacement {
          pendingDocumentReplacement = nil
          do {
            guard let commands = inputBinding?.owner?.commandOwner else {
              throw BoomError.stale("Document replacement lost its actual command owner.")
            }
            try commands.requestDocumentReplacement(pending.selection, replacement: pending.bytes, actionName: "Edit")
          } catch { didRejectInput?(error) }
        }
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
            // The receiver refused this captured selector. Reinstalling it
            // would redispatch an obsolete selection on every later key.
            rejectInput(error)
          }
        }
        let edited = session.generation != beforeGeneration
        if edited { clearGhost() }
        inputBinding?.owner?.notifyNativeState(from: self, edited: edited)
        inputBinding?.owner?.commandOwner?.inputCommandDidClose()
        if inputBinding?.owner?.activeView === self {
          do { try inputBinding?.owner?.recenterResidentWindowIfNeeded() }
          catch { didRejectInput?(error) }
        }
      }
    }
    operation()
  }
}
