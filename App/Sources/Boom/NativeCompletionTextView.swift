import AppKit
import BoomCore

/// Every editable prose surface uses this client contract and native display.
/// Suggestions never enter canonical storage until explicit acceptance.
@MainActor protocol NativeCompletionClient: AnyObject {
  var completionDocument: DocumentSnapshot? { get }
  var ghostStamp: GhostStamp? { get }
  var hasCompletionChoices: Bool { get }
  func takeGhost(documentID: UUID, caret: Int) -> String?
  func takeGhostChunk(documentID: UUID, caret: Int) -> CompletionSegment?
  func resumeGhost(_ text: String, documentID: UUID, caret: Int, sources: [SourceReference])
  func ghostSourcesRemainCurrent(_ sources: [SourceReference], manuscriptID: UUID) -> Bool
  func navigateGhost(_ direction: Int)
  func invalidateGhost()
}

extension WorkspaceModel: NativeCompletionClient {
  var completionDocument: DocumentSnapshot? { selectedDocument }
  var hasCompletionChoices: Bool { showingCandidates }
}

@MainActor class NativeCompletionTextView: NativeMediaTextView {
  weak var completionClient: (any NativeCompletionClient)?
  var documentID = UUID()
  private var displayStorage: NSTextStorage?
  private var displayLayout: NSLayoutManager?
  private var displayContainer: NSTextContainer?
  private var visibleStamp: GhostStamp?
  private var displayGhostLength = 0
  var hasVisibleGhost: Bool { visibleStamp != nil }
  private struct AcceptedStep {
    let documentID: UUID
    let revision: String
    let caret: Int
    let accepted: String
    let previous: String
    let sources: [SourceReference]
  }
  private var acceptedSteps: [AcceptedStep] = []
  var hasGhostBoundary: Bool { canReverseGhostBoundary }
  private(set) var movingGhostBoundary = false
  func endGhostBoundary() { acceptedSteps.removeAll() }
  func selectionChangedDuringGhost() { if !canReverseGhostBoundary { endGhostBoundary() } }
  private var canReverseGhostBoundary: Bool {
    guard let step = acceptedSteps.last else { return false }
    return step.documentID == documentID && completionClient?.completionDocument?.revision == step.revision
      && selectedRange() == NSRange(location: step.caret, length: 0)
      && completionClient?.ghostSourcesRemainCurrent(step.sources, manuscriptID: documentID) == true
  }
  func clearGhost() {
    guard displayStorage != nil || visibleStamp != nil || displayGhostLength != 0 else { return }
    displayStorage = nil
    displayLayout = nil
    displayContainer = nil
    visibleStamp = nil
    displayGhostLength = 0
    needsDisplay = true
    completionDisplayDidChange()
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
      completionDisplayDidChange()
      return
    }
    // A separate DISPLAY layout contains the ghost. Canonical textStorage,
    // accessibility value, clipboard, autosave and undo never contain it.
    let copy = NSMutableAttributedString(attributedString: storage)
    let attributes = ghostAttributes()
    copy.insert(NSAttributedString(string: completion, attributes: attributes), at: location)
    let display = NSTextStorage(attributedString: copy)
    let layout = NSLayoutManager()
    layout.delegate = inlineMedia.layout
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
    completionDisplayDidChange()
  }
  override var mediaPresentation: (NSLayoutManager, NSTextContainer)? {
    if let displayLayout, let displayContainer { return (displayLayout, displayContainer) }
    return super.mediaPresentation
  }
  override func mediaChanged() {
    let stamp = visibleStamp
    let completion = displayStorage.flatMap { storage -> String? in
      guard let stamp, stamp.caretUTF16 + displayGhostLength <= storage.length else { return nil }
      return (storage.string as NSString).substring(with: NSRange(location: stamp.caretUTF16, length: displayGhostLength))
    }
    clearGhost(); super.mediaChanged()
    if let completion, let stamp { showGhost(completion, stamp: stamp) }
  }
  func completionDisplayDidChange() { inlineMedia.positionViews() }
  var completionDisplayHeight: CGFloat {
    guard let layout = displayLayout, let container = displayContainer else { return 0 }
    container.size = textContainer?.size ?? container.size
    layout.ensureLayout(for: container)
    return layout.usedRect(for: container).maxY + textContainerInset.height * 2
  }
  private func ghostAttributes() -> [NSAttributedString.Key: Any] {
    var attributes = typingAttributes
    attributes[.font] = font ?? MarkdownStyle.body
    attributes[.foregroundColor] = NSColor.tertiaryLabelColor
    return attributes
  }
  override func draw(_ dirtyRect: NSRect) {
    guard prepareTextLayout() else { return }
    guard let layout = displayLayout, let container = displayContainer, let stamp = visibleStamp,
      stamp.documentID == documentID, selectedRange().length == 0,
      stamp.caretUTF16 == selectedRange().location, !hasMarkedText()
    else {
      super.draw(dirtyRect)
      return
    }
    inlineMedia.positionViews()
    if drawsBackground { backgroundColor.setFill(); dirtyRect.fill() }
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
  @discardableResult func acceptNextGhostWord() -> Bool {
    guard !hasMarkedText(), selectedRange().length == 0 else { return false }
    let position = selectedRange().location
    guard let segment = completionClient?.takeGhostChunk(documentID: documentID, caret: position), !segment.accepted.isEmpty else { return false }
    movingGhostBoundary = true
    defer { movingGhostBoundary = false }
    insertText(segment.accepted, replacementRange: selectedRange())
    if let document = completionClient?.completionDocument {
      acceptedSteps.append(AcceptedStep(documentID: documentID, revision: document.revision,
        caret: selectedRange().location, accepted: segment.accepted, previous: segment.whole, sources: segment.sources))
    }
    // Only this synchronous, validated word insertion advances the mutable
    // manuscript reference. Example references and the saved recipe stay fixed.
    let document = completionClient?.completionDocument
    let advanced = segment.sources.map { source in
      guard let document, source.id == documentID, source.kind == "document" else { return source }
      return SourceReference(id: source.id, title: source.title, digest: document.revision, kind: source.kind)
    }
    completionClient?.resumeGhost(segment.remaining, documentID: documentID, caret: selectedRange().location, sources: advanced)
    return true
  }
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.shift, .control, .command, .option])
    if modifiers == [.option], !hasMarkedText(), selectedRange().length == 0 {
      switch event.keyCode {
      case 124: // Option-Right: accept the next word of the visible completion.
        if acceptNextGhostWord() { return }
        if canReverseGhostBoundary { return }
      case 123: // Option-Left: reverse only the last completion acceptance.
        if canReverseGhostBoundary, let step = acceptedSteps.last {
          let length = (step.accepted as NSString).length
          let range = NSRange(location: step.caret - length, length: length)
          let source = string as NSString
          if range.location >= 0, NSMaxRange(range) <= source.length,
            source.substring(with: range) == step.accepted {
            acceptedSteps.removeLast()
            movingGhostBoundary = true
            defer { movingGhostBoundary = false }
            insertText("", replacementRange: range)
            completionClient?.resumeGhost(step.previous, documentID: documentID,
              caret: selectedRange().location, sources: step.sources)
            return
          }
        }
        if completionClient?.ghostStamp != nil { return }
      case 125, 126: // Option-Down/Up: completion candidates, never caret movement.
        completionClient?.navigateGhost(event.keyCode == 125 ? 1 : -1)
        return
      default: break
      }
    }
    if event.keyCode == 48, selectedRange().length == 0, !hasMarkedText(),
      event.modifierFlags.intersection([.shift, .control, .command, .option]).isEmpty,
      let completion = completionClient?.takeGhost(documentID: documentID, caret: selectedRange().location)
    {
      endGhostBoundary()
      let manager = undoManager
      manager?.beginUndoGrouping()
      insertText(completion, replacementRange: selectedRange())
      manager?.setActionName("Accept completion")
      manager?.endUndoGrouping()
      return
    }
    if event.keyCode == 53, modifiers.isEmpty, !hasMarkedText(),
      completionClient?.ghostStamp != nil || completionClient?.hasCompletionChoices == true {
      completionClient?.invalidateGhost()
      endGhostBoundary()
      return
    }
    super.keyDown(with: event)
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    endGhostBoundary()
    completionClient?.invalidateGhost()
    clearGhost()
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
  }
}
