import AppKit
import BoomCore
import SwiftUI

@MainActor final class MarkdownTextView: NSTextView, NSMenuDelegate {
  weak var owner: WorkspaceModel?
  var documentID = UUID()
  var documentUndo: UndoManager?
  var applyingExternal = false
  override func setAccessibilityValue(_ value: Any?) {
    guard isEditable, !hasMarkedText(), let value = value as? String, value != string else { return }
    insertText(value, replacementRange: NSRange(location: 0, length: string.utf16.count))
  }
  private var displayStorage: NSTextStorage?
  private var displayLayout: NSLayoutManager?
  private var displayContainer: NSTextContainer?
  private var searchRanges: [NSRange] = []
  private var searchIdentity: String?
  func manuscriptSize(width: CGFloat, minimumHeight: CGFloat) -> CGSize? {
    guard width > 0, let storage = textStorage, let container = textContainer,
      let layout = layoutManager else { return nil }
    let target = NSSize(width: max(1, width - textContainerInset.width * 2),
      height: CGFloat.greatestFiniteMagnitude)
    if container.size != target { container.size = target }
    layout.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))
    layout.ensureLayout(for: container)
    return CGSize(width: width,
      height: max(layout.usedRect(for: container).height + textContainerInset.height * 2, minimumHeight))
  }
  func highlightSearch(_ ranges: [NSRange], identity: String?) {
    guard let layout = layoutManager, let storage = textStorage else { return }
    for range in searchRanges where NSMaxRange(range) <= storage.length {
      layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
    searchRanges = ranges.filter { NSMaxRange($0) <= storage.length }
    for range in searchRanges {
      layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.22),
        forCharacterRange: range)
    }
    if searchIdentity != identity, let first = searchRanges.first { scrollRangeToVisible(first) }
    if identity == nil || !searchRanges.isEmpty { searchIdentity = identity }
    needsDisplay = true
  }
  private var visibleStamp: GhostStamp?
  private var displayGhostLength = 0
  private let placeholderStorage = NSTextStorage()
  private let placeholderLayout = NSLayoutManager()
  private let placeholderContainer = NSTextContainer(size: .zero)
  func preparePlaceholder() {
    placeholderStorage.addLayoutManager(placeholderLayout)
    placeholderLayout.addTextContainer(placeholderContainer)
    setAccessibilityPlaceholderValue("Begin writing…")
  }
  private func drawPlaceholder() {
    guard string.isEmpty, !hasMarkedText(), let textContainer else { return }
    var attributes = typingAttributes
    attributes[.font] = font ?? MarkdownStyle.body
    attributes[.foregroundColor] = NSColor.placeholderTextColor
    placeholderStorage.setAttributedString(NSAttributedString(string: "Begin writing…", attributes: attributes))
    placeholderContainer.size = textContainer.size
    placeholderContainer.lineFragmentPadding = textContainer.lineFragmentPadding
    placeholderLayout.drawGlyphs(forGlyphRange: placeholderLayout.glyphRange(for: placeholderContainer), at: textContainerOrigin)
  }
  private struct AcceptedStep {
    let documentID: UUID
    let revision: String
    let caret: Int
    let accepted: String
    let previous: String
    let sources: [SourceReference]
  }
  private var acceptedSteps: [AcceptedStep] = []
  override var undoManager: UndoManager? { documentUndo }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { owner?.noteInputFocus(.document) }
    return accepted
  }

  func clearGhost() {
    guard displayStorage != nil || visibleStamp != nil || displayGhostLength != 0 else { return }
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
      drawPlaceholder()
      return
    }
    BoomChrome.paperBackground.setFill()
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
    acceptedSteps.removeAll()
  }
  @discardableResult func acceptNextGhostWord() -> Bool {
    guard !hasMarkedText(), selectedRange().length == 0 else { return false }
    let position = selectedRange().location
    guard let segment = owner?.takeGhostChunk(documentID: documentID, caret: position), !segment.accepted.isEmpty else { return false }
    insertText(segment.accepted, replacementRange: selectedRange())
    if let document = owner?.selectedDocument {
      acceptedSteps.append(AcceptedStep(documentID: documentID, revision: document.revision,
        caret: selectedRange().location, accepted: segment.accepted, previous: segment.whole, sources: segment.sources))
    }
    owner?.resumeGhost(segment.remaining, documentID: documentID, caret: selectedRange().location, sources: segment.sources)
    return true
  }
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.shift, .control, .command, .option])
    if modifiers == [.option], !hasMarkedText(), selectedRange().length == 0 {
      switch event.keyCode {
      case 124: // Option-Right: accept the next word of the visible completion.
        if acceptNextGhostWord() { return }
      case 123: // Option-Left: reverse only the last completion acceptance.
        if let step = acceptedSteps.last, step.documentID == documentID,
          owner?.selectedDocument?.revision == step.revision,
          selectedRange().location == step.caret {
          let length = (step.accepted as NSString).length
          let range = NSRange(location: step.caret - length, length: length)
          let source = string as NSString
          if range.location >= 0, NSMaxRange(range) <= source.length,
            source.substring(with: range) == step.accepted {
            acceptedSteps.removeLast()
            insertText("", replacementRange: range)
            owner?.resumeGhost(step.previous, documentID: documentID,
              caret: selectedRange().location, sources: step.sources)
            return
          }
        }
        if owner?.ghostStamp != nil { return }
      case 125, 126: // Option-Down/Up: completion candidates, never caret movement.
        owner?.navigateGhost(event.keyCode == 125 ? 1 : -1)
        return
      default: break
      }
    }
    acceptedSteps.removeAll()
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
      attach(inputs)
      return true
    }
    return super.performDragOperation(sender)
  }
}

private struct MarkdownSpan: Decodable {
  let kind: String
  let location: Int
  let length: Int
  let level: Int
}

@MainActor enum MarkdownStyle {
  static let body = NSFont.systemFont(ofSize: 15)
  struct WikiDisplay {
    let title: NSRange
    let hidden: [NSRange]
  }
  static func wikiDisplays(in source: String) -> [WikiDisplay] {
    guard let pattern = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]{1,256})\]\]"#)
    else { return [] }
    let text = source as NSString
    return pattern.matches(in: source, range: NSRange(location: 0, length: text.length))
      .compactMap { match in
        let body = text.substring(with: match.range(at: 1))
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else {
          return nil
        }
        if parts.count == 2, UUID(uuidString: String(parts[1])) == nil { return nil }
        let title = NSRange(location: match.range.location + 2,
          length: (String(parts[0]) as NSString).length)
        return WikiDisplay(title: title, hidden: [
          NSRange(location: match.range.location, length: 2),
          NSRange(location: NSMaxRange(title), length: NSMaxRange(match.range) - NSMaxRange(title)),
        ])
      }
  }
  static func apply(to view: NSTextView, bodyFont: NSFont? = nil, lineSpacing: CGFloat = 4, reading: Bool = false) {
    guard let current = view.textStorage else { return }
    // Compute the same projection without invalidating the live text layout.
    // Most inserted prose already has its correct native typing attributes.
    let storage = NSMutableAttributedString(string: current.string)
    let bodyFont = bodyFont ?? body
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
    var attachmentRanges: [NSRange] = []
    defer {
      synchronize(storage, into: current)
      for range in attachmentRanges { view.setSpellingState(0, range: range) }
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    storage.setAttributes(
      [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
    func matches(_ pattern: String, _ action: (NSTextCheckingResult) -> Void) {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
      for result in regex.matches(in: storage.string, range: full) { action(result) }
    }
    let spans: [MarkdownSpan] = (try? ProductCore.call(["op": "markdown_spans", "text": storage.string])) ?? []
    for span in spans where span.kind != "syntax" {
      let range = NSRange(location: span.location, length: span.length)
      guard NSMaxRange(range) <= text.length else { continue }
      switch span.kind {
      case "heading":
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize:
          span.level == 1 ? bodyFont.pointSize * 1.6 : span.level == 2 ? bodyFont.pointSize * 1.35 : bodyFont.pointSize * 1.15,
          weight: .semibold), range: range)
      case "strong", "emphasis":
        let trait: NSFontTraitMask = span.kind == "strong" ? .boldFontMask : .italicFontMask
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
          storage.addAttribute(.font, value: NSFontManager.shared.convert(value as? NSFont ?? bodyFont,
            toHaveTrait: trait), range: run)
        }
      case "strike": storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
      case "code", "table":
        storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular),
          .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.06)], range: range)
      case "quote":
        let quote = paragraph.mutableCopy() as! NSMutableParagraphStyle
        quote.headIndent = 12; quote.firstLineHeadIndent = 12
        storage.addAttributes([.paragraphStyle: quote, .foregroundColor: NSColor.secondaryLabelColor], range: range)
      case "link": storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
      default: break
      }
    }
    for span in spans where span.kind == "syntax" {
      let range = NSRange(location: span.location, length: span.length)
      guard NSMaxRange(range) <= text.length else { continue }
      if reading {
        storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: range)
      } else { storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range) }
    }
    for display in wikiDisplays(in: storage.string) {
      for range in display.hidden {
        storage.addAttributes([
          .font: NSFont.systemFont(ofSize: 0.1),
          .foregroundColor: NSColor.clear,
        ], range: range)
      }
      storage.addAttributes([
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.controlAccentColor,
        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.09),
      ], range: display.title)
    }
    // Keep Markdown as the editable, portable source of truth while rendering
    // local attachment references as file names. The UUID and punctuation
    // retain their character positions for selection, undo and autosave.
    matches(#"\[Attachment: ((?:\\.|[^\\\]\n])+)\]\(boom-attachment:[0-9A-Fa-f-]{36}\)"#) { match in
      attachmentRanges.append(match.range)
      storage.addAttributes([
        .font: NSFont.systemFont(ofSize: 1),
        .foregroundColor: NSColor.clear,
      ], range: match.range)
      storage.addAttributes([
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ], range: match.range(at: 1))
    }
    view.typingAttributes = [
      .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
  }
  private static func synchronize(_ desired: NSAttributedString, into current: NSTextStorage) {
    let owned: Set<NSAttributedString.Key> = [
      .font, .foregroundColor, .paragraphStyle, .backgroundColor,
      .strikethroughStyle, .underlineStyle,
    ]
    var edits: [(NSRange, [NSAttributedString.Key: Any])] = []
    desired.enumerateAttributes(in: NSRange(location: 0, length: desired.length)) { expected, range, _ in
      var position = range.location
      while position < NSMaxRange(range) {
        var effective = NSRange()
        let existing = current.attributes(at: position, effectiveRange: &effective)
        let intersection = NSIntersectionRange(range, effective)
        let before = existing.filter { owned.contains($0.key) }
        if !(before as NSDictionary).isEqual(expected as NSDictionary) {
          var replacement = existing.filter { !owned.contains($0.key) }
          replacement.merge(expected) { _, value in value }
          edits.append((intersection, replacement))
        }
        position = NSMaxRange(intersection)
      }
    }
    guard !edits.isEmpty else { return }
    current.beginEditing()
    for (range, attributes) in edits { current.setAttributes(attributes, range: range) }
    current.endEditing()
  }
}

struct MarkdownEditor: NSViewRepresentable {
  @ObservedObject var model: WorkspaceModel
  let document: DocumentSnapshot
  let minimumHeight: CGFloat
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> MarkdownTextView {
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
    text.textContainerInset = NSSize(width: 28, height: 28)
    text.font = MarkdownStyle.body
    text.backgroundColor = BoomChrome.paperBackground
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.isAutomaticLinkDetectionEnabled = false
    text.writingToolsBehavior = .none
    text.isContinuousSpellCheckingEnabled = true
    text.usesFindBar = true
    text.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    text.setAccessibilityLabel("Manuscript")
    text.preparePlaceholder()
    MarkdownStyle.apply(to: text)
    context.coordinator.view = text
    model.editor = text
    text.isEditable = !model.editingLocked
    update(text, document: document)
    updateSearch(text)
    return text
  }
  func updateNSView(_ text: MarkdownTextView, context: Context) {
    model.editor = text
    text.isEditable = !model.editingLocked
    update(text, document: document)
    updateSearch(text)
  }
  private func updateSearch(_ view: MarkdownTextView) {
    let found = model.documentSearch[document.id]
    let valid = !view.hasMarkedText() && view.string == document.text && found?.revision == document.revision
      && found?.query == model.librarySearch
    let ranges = valid ? found?.matches.ranges.map(\.native) ?? [] : []
    view.highlightSearch(ranges, identity: model.librarySearch.isEmpty ? nil : document.id.uuidString + "\n" + model.librarySearch)
  }
  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView text: MarkdownTextView, context: Context
  ) -> CGSize? {
    guard let width = proposal.width else { return nil }
    return text.manuscriptSize(width: width, minimumHeight: minimumHeight)
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
      guard !view.hasMarkedText() else {
        model.invalidateGhost()
        return
      }
      MarkdownStyle.apply(to: view)
      model.updateDocument(view.string, id: view.documentID, caret: view.selectedRange().location)
      view.invalidateIntrinsicContentSize()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view, !view.applyingExternal else { return }
      if view.selectedRange().length > 0 { model.invalidateGhost() }
      model.movedCaret(view.selectedRange().location, hasMarkedText: view.hasMarkedText())
    }
  }
}
