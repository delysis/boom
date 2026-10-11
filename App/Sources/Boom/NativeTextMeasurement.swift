import AppKit

/// TextKit is the geometry authority for both reading and editing. A proposed
/// width belongs to this isolated layout; it cannot change displayed glyphs,
/// selections, marked text, scroll positions or Undo registration.
@MainActor final class NativeTextMeasurement: NSObject {
  private let mediaLayout = InlineMediaLayout()
  private let storage = NSTextStorage()
  private let layout: NSLayoutManager
  private let container = NSTextContainer(size: .zero)
  private weak var source: NSTextStorage?
  private var needsSnapshot = true
  private var measured: [(width: CGFloat, padding: CGFloat, height: CGFloat)] = []
  init(layout: NSLayoutManager = NSLayoutManager()) {
    self.layout = layout
    super.init()
    layout.delegate = mediaLayout
    layout.addTextContainer(container); storage.addLayoutManager(layout)
  }
  deinit { NotificationCenter.default.removeObserver(self) }
  @objc private func sourceDidEdit(_ notification: Notification) {
    guard let source = notification.object as? NSTextStorage, self.source === source,
      !needsSnapshot else { return }
    let edited = source.editedRange, delta = source.changeInLength
    let expected = storage.length.addingReportingOverflow(delta)
    guard !expected.overflow, expected.partialValue == source.length,
      edited.location <= source.length, edited.length <= source.length - edited.location else {
      needsSnapshot = true; return
    }
    // Native attribute fixing can cover the surrounding paragraph. Carry it
    // with the character edit while keeping other paragraphs' glyphs valid.
    let range = (source.string as NSString).paragraphRange(for: edited)
    let oldLength = range.length.subtractingReportingOverflow(delta)
    guard !oldLength.overflow, oldLength.partialValue >= 0,
      range.location <= storage.length, oldLength.partialValue <= storage.length - range.location else {
      needsSnapshot = true; return
    }
    let previous = NSRange(location: range.location, length: oldLength.partialValue)
    let replacement = source.attributedSubstring(from: range)
    if previous.length == replacement.length,
      storage.attributedSubstring(from: previous).isEqual(to: replacement) { return }
    storage.replaceCharacters(in: previous, with: replacement)
    measured.removeAll(keepingCapacity: true)
  }
  func height(of source: NSTextStorage, width: CGFloat, insets: NSSize, fragmentPadding: CGFloat) -> CGFloat {
    guard width.isFinite, width > 0 else { return 18 + insets.height * 2 }
    if self.source !== source {
      NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
      self.source = source
      NotificationCenter.default.addObserver(self, selector: #selector(sourceDidEdit(_:)),
        name: NSTextStorage.didProcessEditingNotification, object: source)
      needsSnapshot = true
    }
    // SwiftUI can propose several widths for one unchanged storage. Compare
    // the attributed snapshot once after edits, not once per proposal. An open
    // storage transaction can change again before its notification arrives.
    if needsSnapshot || !source.editedMask.isEmpty {
      needsSnapshot = !source.editedMask.isEmpty
      if !storage.isEqual(to: source) {
        storage.setAttributedString(source); measured.removeAll(keepingCapacity: true)
      }
    }
    let contentWidth = max(1, width - insets.width * 2)
    if let cached = measured.first(where: { $0.width == contentWidth && $0.padding == fragmentPadding }) {
      return cached.height + insets.height * 2
    }
    container.lineFragmentPadding = fragmentPadding
    container.size = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    let height = ceil(max(18, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))
    // Bound speculative resize proposals without retaining extra glyph graphs.
    if measured.count == 8 { measured.removeFirst() }
    measured.append((contentWidth, fragmentPadding, height))
    return height + insets.height * 2
  }
}
