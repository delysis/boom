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
  @objc private func sourceDidEdit(_ notification: Notification) { needsSnapshot = true }
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
