import AppKit
import SwiftUI

/// One sizing contract for selectable Markdown inside a SwiftUI row. SwiftUI
/// owns the frame; AppKit lays out glyphs at that frame's width. Measurement
/// never changes the live container, including during speculative proposals.
struct NativeText: NSViewRepresentable {
  enum Presentation { case markdown, literal, removed, added }
  let text: String
  var presentation = Presentation.markdown
  var pointSize: CGFloat = 14
  var selectable = true
  func makeNSView(context: Context) -> NativeReadingTextView { NativeReadingTextView(frame: .zero) }
  func updateNSView(_ view: NativeReadingTextView, context: Context) { view.isSelectable = selectable; view.setSource(text, presentation: presentation, pointSize: pointSize) }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NativeReadingTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    return NSSize(width: width, height: view.contentHeight(at: width))
  }
}

final class NativeReadingTextView: NSTextView {
  private let displayStorage: NSTextStorage
  private let displayLayout: NSLayoutManager
  private let measurement = NativeTextMeasurement()
  private var presentation = NativeText.Presentation.markdown
  private var pointSize: CGFloat = 14

  override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
    let container = textContainer ?? NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
    let layout = container.layoutManager ?? NSLayoutManager()
    let storage = layout.textStorage ?? NSTextStorage()
    if container.layoutManager == nil { layout.addTextContainer(container) }
    if layout.textStorage == nil { storage.addLayoutManager(layout) }
    displayStorage = storage; displayLayout = layout
    super.init(frame: frame, textContainer: container)
    isEditable = false; isSelectable = true; isRichText = false
    drawsBackground = false; textContainerInset = .zero
    container.lineFragmentPadding = 0
    isHorizontallyResizable = false; isVerticallyResizable = false
    container.widthTracksTextView = false
    container.heightTracksTextView = false
    writingToolsBehavior = .none
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setSource(_ source: String, presentation: NativeText.Presentation = .markdown, pointSize: CGFloat = 14) {
    guard string != source || self.presentation != presentation || self.pointSize != pointSize else { return }
    self.presentation = presentation; self.pointSize = pointSize
    string = source
    if presentation == .markdown {
      MarkdownStyle.apply(to: self, bodyFont: NSFont.systemFont(ofSize: pointSize), lineSpacing: 3, reading: true)
    } else {
      let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
      var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular),
        .foregroundColor: presentation == .removed ? NSColor.secondaryLabelColor : NSColor.labelColor,
        .paragraphStyle: paragraph,
      ]
      if presentation == .removed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: source.utf16.count))
    }
    // Representables may be measured before updateNSView supplies their text.
    // Invalidate that initial empty measurement as well as subsequent edits.
    invalidateIntrinsicContentSize()
  }
  func contentHeight(at width: CGFloat) -> CGFloat {
    guard let textStorage else { return 18 }
    return measurement.height(of: textStorage, width: width, insets: .zero, fragmentPadding: 0)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(at: bounds.width))
  }
  override func setFrameSize(_ newSize: NSSize) {
    let changed = frame.width != newSize.width
    super.setFrameSize(newSize)
    textContainer?.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    if changed { invalidateIntrinsicContentSize() }
  }
}
