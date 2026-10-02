import AppKit
import SwiftUI

@MainActor final class ChatTextView: NSTextView {
  var onSend: (() -> Void)?
  var onCancel: (() -> Void)?
  private let placeholderStorage = NSTextStorage()
  private let placeholderLayout = NSLayoutManager()
  private let placeholderContainer = NSTextContainer(size: .zero)

  func preparePlaceholder() {
    placeholderStorage.addLayoutManager(placeholderLayout)
    placeholderLayout.addTextContainer(placeholderContainer)
    placeholderStorage.setAttributedString(NSAttributedString(
      string: "Message",
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.placeholderTextColor,
      ]))
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

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.contains(.command) {
      onSend?()
      return
    }
    if event.keyCode == 53 {
      onCancel?()
      return
    }
    super.keyDown(with: event)
  }
}

struct ChatComposer: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let onSend: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
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
    view.minSize = NSSize(width: 0, height: 50)
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
    view.setAccessibilityLabel("Chat message; Command Return sends")
    view.setAccessibilityPlaceholderValue("Message")
    view.preparePlaceholder()
    view.string = text
    context.coordinator.view = view

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? ChatTextView else { return }
    context.coordinator.text = $text
    view.onSend = onSend
    view.onCancel = onCancel
    if view.string != text, !view.hasMarkedText() {
      view.string = text
      view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      view.needsDisplay = true
    }
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
    init(text: Binding<String>) { self.text = text }
    func textDidChange(_ notification: Notification) {
      guard let view else { return }
      text.wrappedValue = view.string
      view.needsDisplay = true
    }
  }
}
