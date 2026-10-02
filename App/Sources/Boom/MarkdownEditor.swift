import AppKit
import BoomCore
import SwiftUI

@MainActor final class MarkdownTextView: NSTextView, NSMenuDelegate {
  weak var owner: WorkspaceModel?
  var documentID = UUID()
  var documentUndo: UndoManager?
  var applyingExternal = false
  private var displayStorage: NSTextStorage?
  private var displayLayout: NSLayoutManager?
  private var displayContainer: NSTextContainer?
  private var visibleStamp: GhostStamp?
  private var displayGhostLength = 0
  override var undoManager: UndoManager? { documentUndo }
  override var acceptsFirstResponder: Bool { true }

  func clearGhost() {
    displayStorage = nil
    displayLayout = nil
    displayContainer = nil
    visibleStamp = nil
    displayGhostLength = 0
    needsDisplay = true
  }
  func showGhost(_ completion: String, stamp: GhostStamp) {
    guard selectedRange().length == 0, !hasMarkedText(), stamp.documentID == documentID,
      window?.isKeyWindow == true, window?.firstResponder === self, NSApp.isActive,
      let storage = textStorage
    else {
      clearGhost()
      return
    }
    let location = selectedRange().location
    guard location >= 0, location <= storage.length else {
      clearGhost()
      return
    }
    if visibleStamp == stamp, let displayStorage {
      displayStorage.beginEditing()
      displayStorage.replaceCharacters(
        in: NSRange(location: location, length: displayGhostLength), with: completion)
      displayStorage.setAttributes(
        ghostAttributes(),
        range: NSRange(location: location, length: (completion as NSString).length))
      displayStorage.endEditing()
      displayGhostLength = (completion as NSString).length
      needsDisplay = true
      return
    }
    // A separate DISPLAY layout contains the ghost. Canonical textStorage,
    // accessibility value, clipboard, autosave and undo never contain it.
    let copy = NSMutableAttributedString(attributedString: storage)
    let attributes = ghostAttributes()
    copy.insert(NSAttributedString(string: completion, attributes: attributes), at: location)
    let display = NSTextStorage(attributedString: copy)
    let layout = NSLayoutManager()
    let container = NSTextContainer(
      size: textContainer?.size ?? NSSize(width: bounds.width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 5
    layout.allowsNonContiguousLayout = true
    display.addLayoutManager(layout)
    layout.addTextContainer(container)
    displayStorage = display
    displayLayout = layout
    displayContainer = container
    visibleStamp = stamp
    displayGhostLength = (completion as NSString).length
    needsDisplay = true
  }
  private func ghostAttributes() -> [NSAttributedString.Key: Any] {
    var attributes = typingAttributes
    attributes[.font] = font ?? MarkdownStyle.body
    attributes[.foregroundColor] = NSColor.tertiaryLabelColor
    return attributes
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let layout = displayLayout, let container = displayContainer, let stamp = visibleStamp,
      stamp.documentID == documentID, selectedRange().length == 0,
      stamp.caretUTF16 == selectedRange().location, !hasMarkedText()
    else {
      super.draw(dirtyRect)
      return
    }
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
    container.size = textContainer?.size ?? container.size
    let origin = textContainerOrigin
    let glyphs = layout.glyphRange(
      forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
    layout.drawBackground(forGlyphRange: glyphs, at: origin)
    layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
    if let window, window.isKeyWindow {
      let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
      let local = convert(window.convertFromScreen(screen), from: nil)
      NSColor.labelColor.setFill()
      NSRect(x: local.minX, y: local.minY, width: 1, height: local.height).fill()
    }
  }
  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    // A click in an editor embedded in HSplitView can leave a SwiftUI sidebar
    // field as first responder. Ensure the insertion point owns subsequent keys.
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    owner?.invalidateGhost()
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48, selectedRange().length == 0, !hasMarkedText(),
      event.modifierFlags.intersection([.shift, .control, .command, .option]).isEmpty,
      let completion = owner?.takeGhost(documentID: documentID, caret: selectedRange().location)
    {
      let manager = undoManager
      manager?.beginUndoGrouping()
      insertText(completion, replacementRange: selectedRange())
      manager?.setActionName("Accept completion")
      manager?.endUndoGrouping()
      return
    }
    if event.keyCode == 53 {
      owner?.invalidateGhost()
      return
    }
    if event.keyCode == 49, event.modifierFlags.contains(.control) {
      owner?.invalidateGhost()
      owner?.scheduleCompletion()
      return
    }
    super.keyDown(with: event)
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
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
    menu.allowsContextMenuPlugIns = false
    menu.delegate = self
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
    return menu
  }
  func menuWillOpen(_ menu: NSMenu) {
    for item in menu.items where ["Writing Tools", "AutoFill", "Services"].contains(item.title) {
      menu.removeItem(item)
    }
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    owner?.invalidateGhost()
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
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
  func replaceDocument(_ value: String, action: String) {
    let selection = selectedRange()
    let manager = undoManager
    clearGhost()
    manager?.beginUndoGrouping()
    insertText(value, replacementRange: NSRange(location: 0, length: (string as NSString).length))
    manager?.setActionName(action)
    manager?.endUndoGrouping()
    setSelectedRange(
      NSRange(location: min(selection.location, (value as NSString).length), length: 0))
  }
  override func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      owner?.attachFiles(urls)
      return
    }
    if let data = pasteboard.data(forType: .png) {
      owner?.attachPasted(data, name: "Pasted image.png")
      return
    }
    if let data = pasteboard.data(forType: .tiff) {
      owner?.attachPasted(data, name: "Pasted image.tiff")
      return
    }
    super.pasteAsPlainText(sender)
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil { return .copy }
    return super.draggingEntered(sender)
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      owner?.attachFiles(urls)
      return true
    }
    return super.performDragOperation(sender)
  }
}

@MainActor final class MarkdownScrollView: NSScrollView {
  override func layout() {
    super.layout()
    guard let text = documentView as? MarkdownTextView else { return }
    let viewport = contentView.bounds.size
    if text.minSize.height != viewport.height {
      text.minSize = NSSize(width: 0, height: viewport.height)
    }
    if text.frame.height < viewport.height {
      text.setFrameSize(NSSize(width: viewport.width, height: viewport.height))
    }
  }
}

@MainActor enum MarkdownStyle {
  static let body = NSFont.systemFont(ofSize: 15)
  static func apply(to view: NSTextView) {
    guard let storage = view.textStorage else { return }
    let manager = view.undoManager
    let registered = view.undoManager?.isUndoRegistrationEnabled == true
    let native = view as? MarkdownTextView
    let previous = native?.applyingExternal ?? false
    native?.applyingExternal = true
    if registered { manager?.disableUndoRegistration() }
    defer {
      native?.applyingExternal = previous
      if registered { manager?.enableUndoRegistration() }
    }
    let text = storage.string as NSString
    let full = NSRange(location: 0, length: text.length)
    storage.beginEditing()
    defer { storage.endEditing() }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    storage.setAttributes(
      [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
    func matches(_ pattern: String, _ action: (NSTextCheckingResult) -> Void) {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
      for result in regex.matches(in: storage.string, range: full) { action(result) }
    }
    matches(#"(?m)^(#{1,6})[ \t]+.+$"#) { match in
      let level = match.range(at: 1).length
      storage.addAttribute(
        .font,
        value: NSFont.systemFont(ofSize: level == 1 ? 24 : level == 2 ? 20 : 17, weight: .semibold),
        range: match.range)
      storage.addAttribute(
        .foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range(at: 1))
    }
    matches(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#) {
      storage.addAttribute(
        .font, value: NSFont.systemFont(ofSize: 15, weight: .semibold), range: $0.range)
    }
    matches(#"(?<!\*)\*(?!\*)[^*\n]+\*(?!\*)|(?<!_)_(?!_)[^_\n]+_(?!_)"#) {
      storage.addAttribute(
        .font,
        value: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask), range: $0.range)
    }
    matches(#"`[^`\n]+`"#) {
      storage.addAttributes(
        [
          .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
          .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08),
        ], range: $0.range)
    }
    matches(#"\[\[[^\[\]\n]+\]\]"#) {
      storage.addAttribute(
        .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: $0.range)
    }
    matches(#"(?m)^\s*(?:[-*+] |\d+\. |>[ \t]?).*$"#) { match in
      let length = min(2, match.range.length)
      storage.addAttribute(
        .foregroundColor, value: NSColor.secondaryLabelColor,
        range: NSRange(location: match.range.location, length: length))
    }
    matches(#"(?ms)^```[^\n]*\n.*?(?:^```[ \t]*$|\z)"#) {
      storage.addAttributes(
        [
          .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
          .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.06),
        ], range: $0.range)
    }
    view.typingAttributes = [
      .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
  }
}

struct MarkdownEditor: NSViewRepresentable {
  @ObservedObject var model: WorkspaceModel
  let document: DocumentSnapshot
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    let text = MarkdownTextView(frame: .zero, textContainer: container)
    text.owner = model
    text.documentID = document.id
    text.documentUndo = model.undoManager(document.id)
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
    text.textContainerInset = NSSize(width: 20, height: 18)
    text.font = MarkdownStyle.body
    text.backgroundColor = NSColor.textBackgroundColor
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.isAutomaticLinkDetectionEnabled = false
    text.writingToolsBehavior = .none
    text.isContinuousSpellCheckingEnabled = true
    text.usesFindBar = true
    text.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, NSPasteboard.PasteboardType.string])
    text.setAccessibilityLabel("Markdown document")
    let scroll = MarkdownScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.documentView = text
    scroll.findBarPosition = .aboveContent
    context.coordinator.view = text
    model.editor = text
    update(text, document: document)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? MarkdownTextView else { return }
    model.editor = text
    update(text, document: document)
  }
  private func update(_ text: MarkdownTextView, document: DocumentSnapshot) {
    // SwiftUI status/streaming updates must never overwrite in-flight marked text.
    if text.documentID == document.id, text.hasMarkedText() { return }
    if text.documentID != document.id || text.string != document.text {
      text.applyingExternal = true
      defer { text.applyingExternal = false }
      let changedDocument = text.documentID != document.id
      text.clearGhost()
      text.documentID = document.id
      text.documentUndo = model.undoManager(document.id)
      let selection = changedDocument ? NSRange(location: 0, length: 0) : text.selectedRange()
      text.string = document.text
      MarkdownStyle.apply(to: text)
      text.setSelectedRange(
        NSRange(location: min(selection.location, (document.text as NSString).length), length: 0))
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let model: WorkspaceModel
    weak var view: MarkdownTextView?
    init(model: WorkspaceModel) { self.model = model }
    func undoManager(for view: NSTextView) -> UndoManager? {
      (view as? MarkdownTextView)?.documentUndo
    }
    func textDidChange(_ notification: Notification) {
      guard let view, !view.applyingExternal else { return }
      guard !view.hasMarkedText() else {
        model.invalidateGhost()
        return
      }
      MarkdownStyle.apply(to: view)
      model.updateDocument(view.string, id: view.documentID, caret: view.selectedRange().location)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view, !view.applyingExternal else { return }
      if view.selectedRange().length > 0 { model.invalidateGhost() }
      model.movedCaret(view.selectedRange().location, hasMarkedText: view.hasMarkedText())
    }
  }
}

extension WorkspaceModel {
  func attachPasted(_ data: Data, name: String) {
    guard !isBusy, pendingAttachments.count < 8 else { return }
    work("Inspecting pasted attachment…") { [weak self] flag in
      guard let self else { return }
      let imported = try await detachedWork(priority: .utility) {
        try AttachmentProcessor.inspect(name: name, data: data)
      }
      try flag.check()
      try self.store.vault.put(data, kind: .attachment, id: imported.record.id)
      try self.store.vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
      self.state.attachments.append(imported.record)
      self.pendingAttachments.append(imported.record.id)
      self.status = "Pasted attachment inspected locally"
    }
  }
}
