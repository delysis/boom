import AppKit
import SwiftUI

func nativeEditEvent(_ event: String) {
  if CommandLine.arguments.contains("--native-check-workspace") {
    fputs("Native edit: \(event)\n", stderr)
  }
}

@MainActor final class ChatTextView: NSTextView {
  var onSend: (() -> Void)?
  var onCancel: (() -> Void)?
  var onAttachments: (([AttachmentInput]) -> Void)?
  var onFocus: (() -> Void)?
  var onContentHeight: ((CGFloat) -> Void)?
  private let placeholderStorage = NSTextStorage()
  private let placeholderLayout = NSLayoutManager()
  private let placeholderContainer = NSTextContainer(size: .zero)

  func preparePlaceholder(_ text: String) {
    placeholderStorage.addLayoutManager(placeholderLayout)
    placeholderLayout.addTextContainer(placeholderContainer)
    placeholderStorage.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.placeholderTextColor,
      ]))
  }
  override func layout() {
    super.layout()
    reportContentHeight()
  }
  func reportContentHeight() {
    guard let onContentHeight, let layoutManager, let textContainer else { return }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    let lastLine = layoutManager.extraLineFragmentRect
    onContentHeight(ceil(max(used.maxY, lastLine.maxY) + textContainerInset.height * 2))
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !hasMarkedText(), let textContainer else { return }
    // The placeholder uses the same text container dimensions and origin as
    // editable glyphs. No SwiftUI overlay or measured padding is involved.
    placeholderContainer.size = textContainer.size
    placeholderContainer.lineFragmentPadding = textContainer.lineFragmentPadding
    let glyphs = placeholderLayout.glyphRange(for: placeholderContainer)
    placeholderLayout.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocus?() }
    return accepted
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.contains(.command), !hasMarkedText() {
      onSend?()
      return
    }
    if event.keyCode == 53, !hasMarkedText() {
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
    guard isEditable, !hasMarkedText(), let value = value as? String, value != string else { return }
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
    view.font = NSFont.systemFont(ofSize: 14)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    view.defaultParagraphStyle = paragraph
    view.textColor = .labelColor
    view.textContainerInset = .zero
    view.drawsBackground = false
    view.isRichText = false
    view.allowsUndo = true
    view.isEditable = true
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.minSize = NSSize(width: 0, height: onContentHeight == nil ? 50 : 20)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.writingToolsBehavior = .none
    view.delegate = context.coordinator
    view.onSend = onSend
    view.onCancel = onCancel
    view.onAttachments = onAttachments
    view.onFocus = onFocus
    context.coordinator.onContentHeight = onContentHeight
    view.onContentHeight = { [weak coordinator = context.coordinator] height in coordinator?.measure(height) }
    view.registerForDraggedTypes([.fileURL, .png, .tiff])
    view.setAccessibilityLabel(accessibilityLabel)
    view.setAccessibilityPlaceholderValue(placeholder)
    view.preparePlaceholder(placeholder)
    view.string = text
    MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing)
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.view = view

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = view
    return ChatInputView(scroll: scroll, editing: showsEditingActions, target: context.coordinator)
  }

  func updateNSView(_ input: ChatInputView, context: Context) {
    guard let view = input.scroll.documentView as? ChatTextView else { return }
    context.coordinator.text = $text
    context.coordinator.lineSpacing = lineSpacing
    context.coordinator.onContentHeight = onContentHeight
    view.onSend = onSend
    view.onCancel = onCancel
    view.onAttachments = onAttachments
    view.onFocus = onFocus
    if view.string != text, !view.hasMarkedText() {
      view.string = text
      MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing)
      view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      view.needsDisplay = true
    }
    view.reportContentHeight()
    if focusRequest != context.coordinator.appliedFocusRequest {
      context.coordinator.appliedFocusRequest = focusRequest
      DispatchQueue.main.async { [weak view] in
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
      }
    }
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    weak var view: ChatTextView?
    var appliedFocusRequest = 0
    var lineSpacing: CGFloat = 0
    var onContentHeight: ((CGFloat) -> Void)?
    private var measuredHeight: CGFloat = -1
    init(text: Binding<String>) { self.text = text }
    func textDidChange(_ notification: Notification) {
      guard let view else { return }
      if !view.hasMarkedText() { MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 14), lineSpacing: lineSpacing) }
      text.wrappedValue = view.string
      view.needsDisplay = true
      view.reportContentHeight()
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
