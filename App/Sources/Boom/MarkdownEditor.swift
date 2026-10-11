import AppKit
import BoomCore
import SwiftUI

@MainActor final class MarkdownTextView: NativeCompletionTextView, NSMenuDelegate, NativeTextStylingGuard {
  weak var owner: WorkspaceModel? { didSet { completionClient = owner } }
  var documentUndo: UndoManager?
  var applyingExternal = false
  private var documentTextVersion: UUID?
  private var displayedSourceVersion: UUID?
  func displays(_ document: DocumentSnapshot) -> Bool {
    documentID == document.id && documentTextVersion == document.textVersion
      && displayedSourceVersion == sourceVersion
  }
  /// Call only after assigning a captured model source or publishing a native
  /// edit to that model. Status updates need no manuscript read or comparison.
  func synchronized(with document: DocumentSnapshot) {
    guard documentID == document.id else { return }
    documentTextVersion = document.textVersion
    displayedSourceVersion = sourceVersion
  }
  override func setAccessibilityValue(_ value: Any?) {
    guard isEditable, !hasMarkedText(), let value = value as? String,
      !(string as NSString).isEqual(to: value) else { return }
    insertText(value, replacementRange: NSRange(location: 0, length: string.utf16.count))
  }
  private var searchRanges: [NSRange] = []
  private var searchIdentity: String?
  override func completionDisplayDidChange() {
    super.completionDisplayDidChange()
    if isVerticallyResizable, prepareTextLayout() { sizeToFit() }
    invalidateIntrinsicContentSize()
  }
  override func sizeToFit() {
    super.sizeToFit()
    if isVerticallyResizable, hasVisibleGhost, prepareTextLayout() {
      let height = max(minSize.height, completionDisplayHeight, frame.height)
      if height != frame.height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    let changed = frame.width != newSize.width
    super.setFrameSize(newSize)
    if let container = textContainer {
      let width = max(1, newSize.width - textContainerInset.width * 2)
      if container.size.width != width {
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
      }
    }
    if changed { invalidateIntrinsicContentSize() }
  }
  func highlightSearch(_ ranges: [NSRange], identity: String?) {
    guard let layout = layoutManager, let storage = textStorage else { return }
    let projected = ranges.filter { NSMaxRange($0) <= storage.length }
    // Status and generation publications also update this native view. An
    // empty search has no attribute work and must not request another paint.
    if searchRanges.isEmpty, projected.isEmpty {
      if identity == nil { searchIdentity = nil }
      return
    }
    for range in searchRanges where NSMaxRange(range) <= storage.length {
      layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
    searchRanges = projected
    for range in searchRanges {
      layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.22),
        forCharacterRange: range)
    }
    if searchIdentity != identity, let first = searchRanges.first { scrollRangeToVisible(first) }
    if identity == nil || !searchRanges.isEmpty { searchIdentity = identity }
    needsDisplay = true
  }
  private let placeholder = NativeTextPlaceholder("Prose")
  func preparePlaceholder() {
    setAccessibilityPlaceholderValue("Prose")
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if !hasVisibleGhost { placeholder.draw(in: self) }
  }
  override var undoManager: UndoManager? { documentUndo }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { owner?.noteInputFocus(.document) }
    return accepted
  }

  override func mouseDown(with event: NSEvent) {
    let previousSelection = selectedRange()
    super.mouseDown(with: event)
    // A click in an editor embedded in HSplitView can leave a SwiftUI sidebar
    // field as first responder. Ensure the insertion point owns subsequent keys.
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    // The selection/text delegates invalidate changed captures. Refocusing at
    // the same caret leaves the captured manuscript and continuation valid.
    if selectedRange() != previousSelection { endGhostBoundary() }
  }
  private func wrapSelection(_ marker: String, placeholder: String = "") {
    finishComposition()
    clearGhost()
    let source = string as NSString
    let selection = selectedRange()
    guard NSMaxRange(selection) <= source.length else { return }
    let chosen = source.substring(with: selection)
    let markerLength = (marker as NSString).length
    if selection.length > 0, chosen.hasPrefix(marker), chosen.hasSuffix(marker),
      selection.length >= markerLength * 2 {
      let inner = (chosen as NSString).substring(
        with: NSRange(location: markerLength, length: selection.length - markerLength * 2))
      insertText(inner, replacementRange: selection)
      setSelectedRange(NSRange(location: selection.location, length: (inner as NSString).length))
      return
    }
    if selection.length > 0, selection.location >= markerLength,
      NSMaxRange(selection) + markerLength <= source.length,
      source.substring(with: NSRange(
        location: selection.location - markerLength, length: markerLength)) == marker,
      source.substring(with: NSRange(
        location: NSMaxRange(selection), length: markerLength)) == marker {
      insertText(chosen, replacementRange: NSRange(
        location: selection.location - markerLength,
        length: selection.length + markerLength * 2))
      setSelectedRange(NSRange(
        location: selection.location - markerLength, length: selection.length))
      return
    }
    let content = chosen.isEmpty ? placeholder : chosen
    let replacement = marker + content + marker
    insertText(replacement, replacementRange: selection)
    setSelectedRange(NSRange(
      location: selection.location + markerLength,
      length: chosen.isEmpty ? (content as NSString).length : selection.length))
  }
  private func prefixLines(_ prefix: String) {
    finishComposition()
    clearGhost()
    let source = string as NSString
    let selection = selectedRange()
    guard selection.location <= source.length else { return }
    let lines = source.lineRange(for: selection)
    let original = source.substring(with: lines)
    let parts = original.components(separatedBy: "\n")
    let body = parts.enumerated().filter { !($0.offset == parts.count - 1 && $0.element.isEmpty) }
    let removing = !body.isEmpty && body.allSatisfy { $0.element.hasPrefix(prefix) }
    let changed = parts.enumerated().map { index, line in
      if index == parts.count - 1 && line.isEmpty { return line }
      return removing ? String(line.dropFirst(prefix.count)) : prefix + line
    }.joined(separator: "\n")
    insertText(changed, replacementRange: lines)
    setSelectedRange(NSRange(location: lines.location, length: (changed as NSString).length))
  }
  @objc func markdownBold(_ sender: Any?) { wrapSelection("**") }
  @objc func markdownItalic(_ sender: Any?) { wrapSelection("*") }
  @objc func markdownCode(_ sender: Any?) { wrapSelection("`", placeholder: "code") }
  @objc func markdownLink(_ sender: Any?) {
    finishComposition()
    clearGhost()
    let selection = selectedRange()
    let source = string as NSString
    guard NSMaxRange(selection) <= source.length else { return }
    let label = selection.length == 0 ? "link text" : source.substring(with: selection)
    insertText("[\(label)](url)", replacementRange: selection)
    setSelectedRange(NSRange(location: selection.location + 1, length: (label as NSString).length))
  }
  @objc func markdownHeading(_ sender: Any?) { prefixLines("## ") }
  @objc func markdownQuote(_ sender: Any?) { prefixLines("> ") }
  @objc func markdownList(_ sender: Any?) { prefixLines("- ") }
  @objc func attachDocumentFiles(_ sender: Any?) {
    guard let owner, let destination = attachmentDestination else { return }
    owner.chooseAttachmentFiles(to: destination)
  }
  private var attachmentDestination: AttachmentDestination? {
    owner?.documentAttachmentDestination(id: documentID, range: selectedRange())
  }
  private func attach(_ inputs: [AttachmentInput]) {
    guard let owner, let destination = attachmentDestination else { return }
    owner.attach(inputs, to: destination)
  }
  @objc private func exploreContinuations(_ sender: Any?) { owner?.exploreWriting() }
  @objc private func editWritingExamples(_ sender: Any?) { owner?.openWritingExamples() }
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(exploreContinuations(_:)) { return owner?.canExploreWriting == true }
    if item.action == #selector(editWritingExamples(_:)) { return owner?.isBusy == false }
    return super.validateUserInterfaceItem(item)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
    menu.allowsContextMenuPlugIns = false
    menu.delegate = self
    let explore = NSMenuItem(title: "Explore continuations", action: #selector(exploreContinuations(_:)), keyEquivalent: "")
    explore.target = self; menu.addItem(explore)
    let examples = NSMenuItem(title: "Writing examples…", action: #selector(editWritingExamples(_:)), keyEquivalent: "")
    examples.target = self; menu.addItem(examples)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
    menu.addItem(.separator())
    let format = NSMenu(title: "Format as Markdown")
    for (title, action) in [
      ("Bold", #selector(markdownBold(_:))), ("Italic", #selector(markdownItalic(_:))),
      ("Heading", #selector(markdownHeading(_:))), ("Bulleted List", #selector(markdownList(_:))),
      ("Quote", #selector(markdownQuote(_:))), ("Inline Code", #selector(markdownCode(_:))),
      ("Link", #selector(markdownLink(_:))),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      format.addItem(item)
    }
    let formatItem = NSMenuItem(title: "Format as Markdown", action: nil, keyEquivalent: "")
    formatItem.submenu = format
    menu.addItem(formatItem)
    menu.addItem(.separator())
    let attach = NSMenuItem(
      title: "Attach files to document…", action: #selector(attachDocumentFiles(_:)),
      keyEquivalent: "")
    attach.target = self
    menu.addItem(attach)
    return menu
  }
  func menuWillOpen(_ menu: NSMenu) {
    for item in menu.items where ["Writing Tools", "AutoFill", "Services"].contains(item.title) {
      menu.removeItem(item)
    }
  }
  func finishComposition() {
    guard hasMarkedText() else { return }
    inputContext?.discardMarkedText()
    unmarkText()
  }
  override func unmarkText() {
    super.unmarkText()
    guard !applyingExternal, !hasMarkedText() else { return }
    MarkdownStyle.apply(to: self)
    owner?.updateDocument(string, id: documentID, caret: selectedRange().location)
  }
  override func resignFirstResponder() -> Bool {
    finishComposition()
    owner?.invalidateGhost()
    return super.resignFirstResponder()
  }
  func replaceDocument(_ value: String, action: String, edits: [ValidatedEdit]? = nil) {
    // The controller locks user editing while publishing the disk transaction.
    // NSTextView's insertion/Undo path still needs an editable text view.
    let editable = isEditable
    isEditable = true
    defer { isEditable = editable }
    let selection = selectedRange()
    let manager = undoManager
    clearGhost()
    breakUndoCoalescing()
    manager?.beginUndoGrouping()
    var caret = selection.location
    if let edits {
      for edit in edits {
        if NSMaxRange(edit.range) <= selection.location { caret += edit.replacement.utf16.count - edit.range.length }
        else if edit.range.location < selection.location { caret = edit.range.location + edit.replacement.utf16.count }
        insertText(edit.replacement, replacementRange: edit.range)
      }
    } else { insertText(value, replacementRange: NSRange(location: 0, length: (string as NSString).length)) }
    manager?.setActionName(action)
    manager?.endUndoGrouping()
    breakUndoCoalescing()
    setSelectedRange(
      NSRange(location: max(0, min(caret, (value as NSString).length)), length: 0))
  }
  override func paste(_ sender: Any?) {
    if let inputs = AttachmentInput.read(.general) {
      attach(inputs)
      return
    }
    super.pasteAsPlainText(sender)
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if AttachmentInput.canRead(sender.draggingPasteboard) { return .copy }
    return super.draggingEntered(sender)
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let inputs = AttachmentInput.read(sender.draggingPasteboard) {
      let point = convert(sender.draggingLocation, from: nil)
      setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
      attach(inputs)
      return true
    }
    return super.performDragOperation(sender)
  }
}

/// The native text view owns scrolling and its actual document extent. SwiftUI
/// proposes a viewport, never a speculative full-manuscript layout.
@MainActor final class ManuscriptScrollView: NSScrollView {
  let editor: MarkdownTextView
  init(editor: MarkdownTextView) {
    self.editor = editor
    super.init(frame: .zero)
    borderType = .noBorder
    drawsBackground = false
    hasVerticalScroller = true
    autohidesScrollers = true
    documentView = editor
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    let viewport = contentView.bounds.size
    guard viewport.width.isFinite, viewport.width > 0, viewport.height.isFinite else { return }
    let inset = NSSize(width: 28 + max(0, viewport.width - WorkspaceGeometry.proseMaximumWidth) / 2,
      height: 28)
    let height = max(1, viewport.height)
    let changed = editor.frame.width != viewport.width || editor.textContainerInset != inset
      || editor.minSize.height != height
    guard changed else { return }
    editor.textContainerInset = inset
    editor.minSize = NSSize(width: 0, height: height)
    editor.setFrameSize(NSSize(width: viewport.width, height: max(height, editor.frame.height)))
    if editor.prepareTextLayout() { editor.sizeToFit() }
  }
}

struct MarkdownEditor: NSViewRepresentable {
  @ObservedObject var model: WorkspaceModel
  let documentID: UUID
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> ManuscriptScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    layout.allowsNonContiguousLayout = true
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    container.widthTracksTextView = false
    container.heightTracksTextView = false
    let text = MarkdownTextView(frame: .zero, textContainer: container)
    text.owner = model
    text.setMedia(model: model)
    text.documentID = documentID
    text.documentUndo = model.undoManager(documentID)
    text.delegate = context.coordinator
    text.isRichText = false
    text.importsGraphics = false
    text.allowsUndo = true
    text.isEditable = true
    text.isSelectable = true
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.minSize = NSSize(width: 0, height: 0)
    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.textContainerInset = NSSize(width: 28, height: 28)
    text.font = MarkdownStyle.body
    text.backgroundColor = BoomChrome.documentBackground
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.isAutomaticLinkDetectionEnabled = false
    text.writingToolsBehavior = .none
    text.isContinuousSpellCheckingEnabled = true
    text.usesFindBar = false
    text.usesFindPanel = false
    text.registerForDraggedTypes(AttachmentInput.draggingTypes + [.string])
    text.setAccessibilityLabel("Manuscript")
    text.preparePlaceholder()
    MarkdownStyle.apply(to: text)
    context.coordinator.view = text
    model.editor = text
    text.setMedia(model: model)
    text.isEditable = !model.editingLocked
    update(text)
    updateSearch(text)
    return ManuscriptScrollView(editor: text)
  }
  func updateNSView(_ viewport: ManuscriptScrollView, context: Context) {
    let text = viewport.editor
    let trace = PerformanceTrace.begin("Editor.Update")
    defer { PerformanceTrace.end("Editor.Update", trace) }
    model.editor = text
    text.setMedia(model: model)
    text.isEditable = !model.editingLocked
    update(text)
    updateSearch(text)
  }
  private func updateSearch(_ view: MarkdownTextView) {
    let trace = PerformanceTrace.begin("Editor.SearchUpdate")
    defer { PerformanceTrace.end("Editor.SearchUpdate", trace) }
    guard view.prepareTextLayout(), let document = model.selectedDocument,
      view.documentID == document.id else { return }
    let ranges: [NSRange]
    if let found = model.documentSearch[document.id], found.query == model.librarySearch,
      found.textVersion == document.textVersion, !view.hasMarkedText(), view.displays(document) {
      ranges = found.matches.ranges.map(\.native)
    } else { ranges = [] }
    view.highlightSearch(ranges, identity: model.librarySearch.isEmpty ? nil : document.id.uuidString + "\n" + model.librarySearch)
  }
  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView viewport: ManuscriptScrollView, context: Context
  ) -> CGSize? {
    guard let width = proposal.width, let height = proposal.height,
      width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
    return CGSize(width: width, height: height)
  }
  private func update(_ text: MarkdownTextView) {
    // A representable can carry a prior render's value during an AppKit edit.
    // AppKit publishes that edit through its delegate before another model
    // snapshot may replace it. Resolve the live document after that boundary.
    guard text.prepareTextLayout(), let document = model.selectedDocument else { return }
    // SwiftUI status/streaming updates must never overwrite in-flight marked text.
    if text.documentID == document.id, text.hasMarkedText() { return }
    if !text.displays(document) {
      text.applyingExternal = true
      defer { text.applyingExternal = false }
      let changedDocument = text.documentID != document.id
      text.clearGhost()
      text.endGhostBoundary()
      text.documentID = document.id
      text.documentUndo = model.undoManager(document.id)
      let selection = changedDocument ? NSRange(location: 0, length: 0) : text.selectedRange()
      text.string = document.text
      MarkdownStyle.apply(to: text)
      text.invalidateIntrinsicContentSize()
      text.setSelectedRange(
        NSRange(location: min(selection.location, (document.text as NSString).length), length: 0))
      text.synchronized(with: document)
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let model: WorkspaceModel
    weak var view: MarkdownTextView?
    init(model: WorkspaceModel) { self.model = model }
    func undoManager(for view: NSTextView) -> UndoManager? {
      (view as? MarkdownTextView)?.documentUndo
    }
    func textView(
      _ textView: NSTextView, shouldSetSpellingState value: Int,
      range affectedCharRange: NSRange
    ) -> Int {
      let text = textView.string as NSString
      guard affectedCharRange.location < text.length else { return value }
      let line = text.substring(with: text.lineRange(for: affectedCharRange))
      return line.contains("](boom-attachment:") ? 0 : value
    }
    func textDidChange(_ notification: Notification) {
      guard let view, !view.applyingExternal else { return }
      let trace = PerformanceTrace.begin("Editor.NativePublication")
      defer { PerformanceTrace.end("Editor.NativePublication", trace) }
      if !view.movingGhostBoundary { view.endGhostBoundary() }
      guard !view.hasMarkedText() else {
        model.invalidateGhost()
        return
      }
      MarkdownStyle.apply(to: view)
      let sourceTrace = PerformanceTrace.begin("Editor.SourceRead")
      let source = view.string
      PerformanceTrace.end("Editor.SourceRead", sourceTrace)
      model.updateDocument(source, id: view.documentID, caret: view.selectedRange().location)
      if let document = model.documents.first(where: { $0.id == view.documentID }) {
        view.synchronized(with: document)
      }
      view.invalidateIntrinsicContentSize()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view, !view.applyingExternal else { return }
      if !view.movingGhostBoundary { view.selectionChangedDuringGhost() }
      if view.selectedRange().length > 0 { model.invalidateGhost() }
      model.movedCaret(view.selectedRange().location, hasMarkedText: view.hasMarkedText())
    }
  }
}
