import AppKit
import SwiftUI

func nativeEditEvent(_ event: String) {
  if CommandLine.arguments.contains("--native-check-workspace") {
    fputs("Native edit: \(event)\n", stderr)
  }
}

@MainActor final class ChatTextView: NativeCompletionTextView {
  var onSend: (() -> Void)?
  var onCancel: (() -> Void)?
  var onAttachments: (([AttachmentInput]) -> Void)?
  var onFocus: (() -> Void)?
  var onContentHeight: ((CGFloat) -> Void)?
  var minimumContentHeight: CGFloat = 50
  private let placeholder = NativeTextPlaceholder("Message")

  func preparePlaceholder(_ text: String) {
    placeholder.text = text
  }
  override func layout() {
    super.layout()
    reportContentHeight()
  }
  func reportContentHeight() {
    guard prepareTextLayout() else { return }
    guard let layoutManager, let textContainer else { return }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    let lastLine = layoutManager.extraLineFragmentRect
    // AppKit raises minSize to the viewport size. That is a floor for the
    // scrolling document, not a content measurement: publishing it prevents
    // a grown composer from shrinking after its text is cleared.
    let height = ceil(max(minimumContentHeight,
      max(max(used.maxY, lastLine.maxY) + textContainerInset.height * 2, completionDisplayHeight)))
    let documentHeight = max(height, enclosingScrollView?.contentSize.height ?? 0)
    if abs(frame.height - documentHeight) > 0.5 {
      setFrameSize(NSSize(width: frame.width, height: documentHeight))
    }
    onContentHeight?(height)
  }
  override func completionDisplayDidChange() { super.completionDisplayDidChange(); reportContentHeight() }
  override func mediaChanged() { super.mediaChanged(); reportContentHeight() }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if !hasVisibleGhost { placeholder.draw(in: self) }
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocus?() }
    if accepted { (completionClient as? TextInputCompletion)?.refresh() }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    completionClient?.invalidateGhost(); endGhostBoundary()
    return super.resignFirstResponder()
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    guard isEditable else { return }
    super.insertText(insertString, replacementRange: replacementRange)
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard isEditable else { return }
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.contains(.command), !hasMarkedText() {
      onSend?()
      return
    }
    if event.keyCode == 53, !hasMarkedText() {
      if hasVisibleGhost { completionClient?.invalidateGhost(); endGhostBoundary(); return }
      onCancel?()
      return
    }
    super.keyDown(with: event)
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Handle the active editor before the menu bar sees Command-Return.
    // Otherwise the writing command can consume a chat send or inline save.
    if window?.firstResponder === self, event.keyCode == 36,
      event.modifierFlags.contains(.command), !hasMarkedText() {
      onSend?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
  override func paste(_ sender: Any?) {
    if let onAttachments, let inputs = AttachmentInput.read(.general) {
      onAttachments(inputs)
      return
    }
    super.pasteAsPlainText(sender)
  }
  override func setAccessibilityValue(_ value: Any?) {
    guard isEditable, !hasMarkedText(), let value = value as? String,
      !(string as NSString).isEqual(to: value) else { return }
    // Accessibility edits must take the same change/Undo path as typing, so
    // the displayed text and the bound draft cannot silently diverge.
    insertText(value, replacementRange: NSRange(location: 0, length: (string as NSString).length))
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    onAttachments != nil && AttachmentInput.canRead(sender.draggingPasteboard)
      ? .copy : super.draggingEntered(sender)
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let onAttachments, let inputs = AttachmentInput.read(sender.draggingPasteboard) {
      onAttachments(inputs)
      return true
    }
    return super.performDragOperation(sender)
  }
}

/// AppKit owns the editor and its action hit regions as one native view.
/// One constraint system places the actions below the bounded text scroll view.
@MainActor final class ChatInputView: NSView {
  let scroll: NSScrollView
  let cancelButton: NSButton?
  let saveButton: NSButton?
  private let coordinator: ChatComposer.Coordinator
  init(scroll: NSScrollView, editing: Bool, target: ChatComposer.Coordinator) {
    self.scroll = scroll
    coordinator = target
    func icon(_ symbol: String, label: String, action: Selector) -> NSButton {
      let button = NSButton(title: "", target: nil, action: action)
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
      button.isBordered = false
      button.bezelStyle = .accessoryBarAction
      button.contentTintColor = .secondaryLabelColor
      button.toolTip = label
      button.setAccessibilityLabel(label)
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24),
        button.heightAnchor.constraint(equalToConstant: 24)])
      return button
    }
    cancelButton = editing ? icon("xmark", label: "Discard changes", action: #selector(discardEdit(_:))) : nil
    saveButton = editing ? icon("checkmark", label: "Save changes", action: #selector(commitEdit(_:))) : nil
    super.init(frame: .zero)
    cancelButton?.target = self
    saveButton?.target = self
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor)])
    if let cancelButton, let saveButton {
      let actions = NSStackView(views: [cancelButton, saveButton])
      actions.orientation = .horizontal
      actions.spacing = 4
      actions.translatesAutoresizingMaskIntoConstraints = false
      addSubview(actions)
      NSLayoutConstraint.activate([actions.trailingAnchor.constraint(equalTo: trailingAnchor),
        actions.bottomAnchor.constraint(equalTo: bottomAnchor),
        scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8)])
    } else {
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }
  }
  @objc private func commitEdit(_ sender: NSButton) {
    nativeEditEvent("save icon invoked")
    (scroll.documentView as? ChatTextView)?.onSend?()
  }
  @objc private func discardEdit(_ sender: NSButton) {
    nativeEditEvent("discard icon invoked")
    (scroll.documentView as? ChatTextView)?.onCancel?()
  }
  required init?(coder: NSCoder) { return nil }
}

struct ChatComposer: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  @Binding var text: String
  let focusRequest: Int
  let onSend: () -> Void
  let onCancel: () -> Void
  var onAttachments: (([AttachmentInput]) -> Void)? = nil
  var onFocus: () -> Void = {}
  var placeholder = "Message"
  var accessibilityLabel = "Chat message; Command Return sends"
  var lineSpacing: CGFloat = 0
  var onContentHeight: ((CGFloat) -> Void)? = nil
  var showsEditingActions = false
  var completionModel: WorkspaceModel? = nil
  var completionTarget: TextInputTarget? = nil
  var textVersion: UUID? = nil
  var currentTextVersion: (() -> UUID)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> ChatInputView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0

    let view = ChatTextView(frame: .zero, textContainer: container)
    view.setMedia(model: completionModel)
    view.font = NSFont.systemFont(ofSize: 14)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    view.defaultParagraphStyle = paragraph
    view.textColor = .labelColor
    view.textContainerInset = .zero
    view.drawsBackground = false
    view.isRichText = false
    view.allowsUndo = true
    view.isEditable = isEnabled
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.minimumContentHeight = onContentHeight == nil ? 50 : 20
    view.minSize = NSSize(width: 0, height: view.minimumContentHeight)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.writingToolsBehavior = .none
    view.delegate = context.coordinator
    view.onSend = isEnabled ? onSend : nil
    view.onCancel = isEnabled ? onCancel : nil
    view.onAttachments = isEnabled ? onAttachments : nil
    view.onFocus = isEnabled ? onFocus : nil
    context.coordinator.onContentHeight = onContentHeight
    view.onContentHeight = { [weak coordinator = context.coordinator] height in coordinator?.measure(height) }
    view.registerForDraggedTypes(AttachmentInput.draggingTypes)
    view.setAccessibilityLabel(accessibilityLabel)
    view.setAccessibilityPlaceholderValue(placeholder)
    view.preparePlaceholder(placeholder)
    view.string = text
    MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing)
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.view = view
    context.coordinator.currentTextVersion = currentTextVersion
    context.coordinator.acknowledge(text, version: currentTextVersion?() ?? textVersion)
    configureCompletion(view, coordinator: context.coordinator)

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = view
    let input = ChatInputView(scroll: scroll, editing: showsEditingActions, target: context.coordinator)
    input.saveButton?.isEnabled = isEnabled
    input.cancelButton?.isEnabled = isEnabled
    return input
  }

  func updateNSView(_ input: ChatInputView, context: Context) {
    guard let view = input.scroll.documentView as? ChatTextView else { return }
    view.isEditable = isEnabled
    input.saveButton?.isEnabled = isEnabled
    input.cancelButton?.isEnabled = isEnabled
    view.setMedia(model: completionModel)
    context.coordinator.text = $text
    context.coordinator.currentTextVersion = currentTextVersion
    let styleChanged = context.coordinator.lineSpacing != lineSpacing
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.onContentHeight = onContentHeight
    view.onSend = isEnabled ? onSend : nil
    view.onCancel = isEnabled ? onCancel : nil
    view.onAttachments = isEnabled ? onAttachments : nil
    view.onFocus = isEnabled ? onFocus : nil
    let source = context.coordinator.text.wrappedValue
    let version = currentTextVersion?() ?? textVersion
    if !view.nativeEditInProgress, !view.hasMarkedText() {
      if !context.coordinator.displays(source, version: version) {
        view.endGhostBoundary(); context.coordinator.completion?.invalidateGhost()
        view.string = source
        MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.needsDisplay = true
      } else if styleChanged {
        MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing)
      }
      context.coordinator.acknowledge(source, version: version)
    }
    view.reportContentHeight()
    configureCompletion(view, coordinator: context.coordinator)
    context.coordinator.completion?.refresh()
    if isEnabled, focusRequest != context.coordinator.appliedFocusRequest {
      context.coordinator.appliedFocusRequest = focusRequest
      let request = focusRequest
      DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
        guard let view, view.isEditable, coordinator?.appliedFocusRequest == request,
          let window = view.window else { return }
        window.makeFirstResponder(view)
      }
    }
  }

  private func configureCompletion(_ view: ChatTextView, coordinator: Coordinator) {
    if isEnabled, let completionModel, let completionTarget {
      if coordinator.completion?.model !== completionModel {
        coordinator.completion?.invalidateGhost()
        coordinator.completion = TextInputCompletion(model: completionModel, target: completionTarget)
      }
      coordinator.completionTarget = completionTarget
      coordinator.completion?.view = view
      view.completionClient = coordinator.completion
      if let completion = coordinator.completion { view.documentID = completion.id }
      coordinator.updateCompletion()
    } else {
      coordinator.completion?.invalidateGhost(); coordinator.completion = nil
      view.completionClient = nil
    }
  }
  static func dismantleNSView(_ input: ChatInputView, coordinator: Coordinator) {
    coordinator.completion?.invalidateGhost()
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    weak var view: ChatTextView?
    var appliedFocusRequest = 0
    var lineSpacing: CGFloat = 0
    var onContentHeight: ((CGFloat) -> Void)?
    var completion: TextInputCompletion?
    var completionTarget: TextInputTarget?
    var currentTextVersion: (() -> UUID)?
    private var measuredHeight: CGFloat = -1
    private var acknowledgedText: String?
    private var acknowledgedTextVersion: UUID?
    private var acknowledgedNativeVersion: UUID?
    init(text: Binding<String>) { self.text = text }
    func acknowledge(_ source: String, version: UUID?) {
      acknowledgedText = source; acknowledgedTextVersion = version
      acknowledgedNativeVersion = view?.sourceVersion
    }
    func displays(_ source: String, version: UUID?) -> Bool {
      guard let view, acknowledgedNativeVersion == view.sourceVersion else { return false }
      if let version { return acknowledgedTextVersion == version }
      // Generic bindings have no external change identity. Compare their last
      // acknowledged immutable value exactly, never the live native buffer or
      // canonical String equality. Versioned status updates skip this boundary.
      guard let acknowledgedText else { return false }
      return (acknowledgedText as NSString).isEqual(to: source)
    }
    func textDidChange(_ notification: Notification) {
      guard let view, view.isEditable else { return }
      if !view.movingGhostBoundary { view.endGhostBoundary() }
      if !view.hasMarkedText() { MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing) }
      let source = view.string
      text.wrappedValue = source
      acknowledge(source, version: currentTextVersion?())
      view.needsDisplay = true
      view.reportContentHeight()
      updateCompletion()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view else { return }
      if !view.movingGhostBoundary { view.selectionChangedDuringGhost() }
      updateCompletion()
    }
    func updateCompletion() {
      guard let view, let completionTarget else { return }
      completion?.update(selection: view.selectedRange(),
        marked: view.hasMarkedText(), target: completionTarget)
    }
    func measure(_ height: CGFloat) {
      guard height != measuredHeight else { return }
      measuredHeight = height
      // Layout can run during SwiftUI updates. Publish only the latest measured
      // height after that update, so typing and width changes remain native.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.measuredHeight == height else { return }
        self.onContentHeight?(height)
      }
    }
  }
}
