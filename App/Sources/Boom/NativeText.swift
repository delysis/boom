import AppKit
import BoomCore
import SwiftUI

/// An empty editor creates its placeholder's TextKit graph on first draw.
/// Ordinary nonempty mounts allocate no second graph; later prompt updates
/// reuse the same graph without rewiring it.
@MainActor final class NativeTextPlaceholder {
  @MainActor private final class Graph {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    init() { storage.addLayoutManager(layout); layout.addTextContainer(container) }
  }
  var text: String
  private lazy var graph = Graph()
  init(_ text: String) { self.text = text }
  func draw(in view: NSTextView) {
    guard !text.isEmpty, view.textStorage?.length == 0,
      !view.hasMarkedText(), let source = view.textContainer else { return }
    let storage = graph.storage, layout = graph.layout, container = graph.container
    var attributes = view.typingAttributes
    attributes[.font] = view.font ?? NSFont.systemFont(ofSize: 14)
    attributes[.foregroundColor] = NSColor.placeholderTextColor
    storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    container.size = source.size; container.lineFragmentPadding = source.lineFragmentPadding
    layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: view.textContainerOrigin)
  }
}

private func readingText(for message: ChatMessage) -> String {
  if message.state == .pending { return message.text.isEmpty ? "…" : message.text }
  if message.text.isEmpty, let failure = message.failure { return failure }
  return message.text
}
private func readingText(for candidate: WritingCandidate) -> String {
  guard candidate.text.isEmpty else { return candidate.text }
  switch candidate.state {
  case .pending: return "Writing a continuation…"
  case .cancelled: return "Stopped before any prose was produced."
  default: return "The model ended this continuation before producing prose."
  }
}

/// One sizing contract for selectable Markdown inside a SwiftUI row. SwiftUI
/// owns the frame; AppKit lays out glyphs at that frame's width. Measurement
/// never changes the live container, including during speculative proposals.
struct NativeText: NSViewRepresentable {
  enum Presentation { case markdown, literal, removed, added }
  let text: String
  private var readingVersion: UUID?
  var presentation = Presentation.markdown
  var pointSize: CGFloat = 14
  var selectable = true
  var mediaModel: WorkspaceModel? = nil

  init(text: String, presentation: Presentation = .markdown, pointSize: CGFloat = 14,
    selectable: Bool = true, mediaModel: WorkspaceModel? = nil) {
    self.text = text; readingVersion = nil
    self.presentation = presentation; self.pointSize = pointSize
    self.selectable = selectable; self.mediaModel = mediaModel
  }
  init(message: ChatMessage, presentation: Presentation = .markdown, pointSize: CGFloat = 14,
    selectable: Bool = true, mediaModel: WorkspaceModel? = nil) {
    self.init(text: readingText(for: message), presentation: presentation, pointSize: pointSize,
      selectable: selectable, mediaModel: mediaModel)
    readingVersion = message.readingVersion
  }
  init(candidate: WritingCandidate, presentation: Presentation = .markdown, pointSize: CGFloat = 14,
    selectable: Bool = true, mediaModel: WorkspaceModel? = nil) {
    self.init(text: readingText(for: candidate), presentation: presentation, pointSize: pointSize,
      selectable: selectable, mediaModel: mediaModel)
    readingVersion = candidate.readingVersion
  }
  func makeNSView(context: Context) -> NativeReadingTextView { NativeReadingTextView(frame: .zero) }
  func updateNSView(_ view: NativeReadingTextView, context: Context) {
    view.isSelectable = selectable; view.setMedia(model: mediaModel)
    view.setSource(text, readingVersion: readingVersion, presentation: presentation, pointSize: pointSize)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NativeReadingTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    return NSSize(width: width, height: view.contentHeight(at: width))
  }
}

/// A bounded viewport for attachment prose, using the same reader and isolated
/// TextKit measurement as ordinary chat rows. Short text has no blank reserve;
/// long text remains scrollable without growing the bubble beyond its limit.
struct NativeScrollableText: NSViewRepresentable {
  let text: String
  var maximumHeight: CGFloat = 220
  static func height(of text: String, width: CGFloat, maximum: CGFloat = 220) -> CGFloat {
    let reader = NativeReadingTextView(frame: .zero)
    reader.setSource(text)
    return min(maximum, reader.contentHeight(at: width))
  }
  func makeNSView(context: Context) -> NativeTextScrollView { NativeTextScrollView() }
  func updateNSView(_ view: NativeTextScrollView, context: Context) {
    view.reader.setSource(text); view.needsLayout = true; view.invalidateIntrinsicContentSize()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NativeTextScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    return CGSize(width: width, height: min(maximumHeight, view.reader.contentHeight(at: width)))
  }
}

final class NativeTextScrollView: NSScrollView {
  let reader = NativeReadingTextView(frame: .zero)
  private let attachmentViewport: Bool
  init(attachmentViewport: Bool = false) {
    self.attachmentViewport = attachmentViewport
    super.init(frame: .zero)
    drawsBackground = false; borderType = .noBorder
    hasVerticalScroller = true; autohidesScrollers = true
    if attachmentViewport {
      reader.isAttachmentViewport = true
      reader.isVerticallyResizable = true
      reader.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
      reader.autoresizingMask = [.width]
      reader.textContainer?.widthTracksTextView = true
      reader.layoutManager?.allowsNonContiguousLayout = true
    }
    documentView = reader
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    let width = max(1, contentView.bounds.width)
    if attachmentViewport {
      // NSTextView retains its complete source and native vertical resizing.
      // A card resize must not call the isolated whole-document measurement.
      reader.setFrameSize(NSSize(width: width, height: max(reader.frame.height, contentView.bounds.height)))
    } else {
      reader.setFrameSize(NSSize(width: width, height: reader.contentHeight(at: width)))
    }
  }
}

final class NativeReadingTextView: NativeMediaTextView {
  private let displayStorage: NSTextStorage
  private let displayLayout: NSLayoutManager
  private lazy var measurement = NativeTextMeasurement()
  fileprivate var isAttachmentViewport = false
  private var presentation = NativeText.Presentation.markdown
  private var pointSize: CGFloat = 14
  private var acknowledgedSource: String?
  private var acknowledgedSourceVersion: UUID?
  private var acknowledgedReadingVersion: UUID?

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
    setSource(source, readingVersion: nil, presentation: presentation, pointSize: pointSize)
  }
  func setSource(_ message: ChatMessage, presentation: NativeText.Presentation = .markdown, pointSize: CGFloat = 14) {
    setSource(readingText(for: message), readingVersion: message.readingVersion,
      presentation: presentation, pointSize: pointSize)
  }
  func setSource(_ candidate: WritingCandidate, presentation: NativeText.Presentation = .markdown, pointSize: CGFloat = 14) {
    setSource(readingText(for: candidate), readingVersion: candidate.readingVersion,
      presentation: presentation, pointSize: pointSize)
  }
  /// Only this file can pair a String with a reading identity. Typed entry points
  /// derive both from their owner; arbitrary String callers retain exact equality.
  fileprivate func setSource(_ source: String, readingVersion: UUID?,
    presentation: NativeText.Presentation, pointSize: CGFloat) {
    let sourceChanged: Bool
    if let readingVersion {
      sourceChanged = acknowledgedSourceVersion != sourceVersion
        || acknowledgedReadingVersion != readingVersion
    } else {
      sourceChanged = acknowledgedSourceVersion != sourceVersion
        || (acknowledgedSource.map { !($0 as NSString).isEqual(to: source) } ?? true)
    }
    guard sourceChanged || self.presentation != presentation || self.pointSize != pointSize else {
      acknowledgedReadingVersion = readingVersion
      return
    }
    self.presentation = presentation; self.pointSize = pointSize
    if sourceChanged { string = source; acknowledgedSource = source }
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
    acknowledgedSourceVersion = sourceVersion
    acknowledgedReadingVersion = readingVersion
    // Representables may be measured before updateNSView supplies their text.
    // Invalidate that initial empty measurement as well as subsequent edits.
    invalidateIntrinsicContentSize()
  }
  func contentHeight(at width: CGFloat) -> CGFloat {
    guard let textStorage else { return 18 }
    return measurement.height(of: textStorage, width: width, insets: .zero, fragmentPadding: 0)
  }

  /// The actual visible reader is also its geometry authority. Lay out only
  /// the finite top rectangle; no attributed snapshot or second graph exists.
  /// A still-unlaid suffix proves that this card needs its bounded scroller.
  func boundedAttachmentHeight(at width: CGFloat, maximum: CGFloat) -> CGFloat {
    guard width.isFinite, width > 0, maximum.isFinite, maximum > 0,
      let storage = textStorage, let layout = layoutManager, let container = textContainer else { return 24 }
    setFrameSize(NSSize(width: width, height: max(frame.height, maximum)))
    let viewport = NSRect(x: 0, y: 0, width: width, height: maximum)
    layout.ensureLayout(forBoundingRect: viewport, in: container)
    guard layout.firstUnlaidCharacterIndex >= storage.length else { return maximum }
    // All source is already laid. Read ALL laid glyph geometry, not just
    // glyphs intersecting the top rectangle: a previously scrolled long
    // document without a final newline must still retain its capped card.
    // usedRect neither generates glyphs nor requests additional layout.
    let used = layout.usedRect(for: container)
    let extra = layout.extraLineFragmentTextContainer === container ? layout.extraLineFragmentRect.maxY : 0
    let height = min(maximum, max(24, ceil(max(used.maxY, extra))))
    // Short content has no extra scrollable blank reserve. Long native text
    // may keep an already expanded frame; it is never truncated to this cap.
    if height < maximum { setFrameSize(NSSize(width: width, height: height)) }
    return height
  }
  override var intrinsicContentSize: NSSize {
    if isAttachmentViewport {
      return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    return NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(at: bounds.width))
  }
  override func setFrameSize(_ newSize: NSSize) {
    let changed = frame.width != newSize.width
    super.setFrameSize(newSize)
    textContainer?.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    if changed { invalidateIntrinsicContentSize() }
  }
}
