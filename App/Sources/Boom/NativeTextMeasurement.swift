import AppKit

/// TextKit is the geometry authority for both reading and editing. A proposed
/// width belongs to this isolated layout; it cannot change displayed glyphs,
/// selections, marked text, scroll positions or Undo registration.
@MainActor final class NativeTextMeasurement {
  private let storage = NSTextStorage()
  private let layout = NSLayoutManager()
  private let container = NSTextContainer(size: .zero)
  private var measured: (width: CGFloat, padding: CGFloat, height: CGFloat)?
  init() {
    layout.addTextContainer(container); storage.addLayoutManager(layout)
  }
  func height(of source: NSAttributedString, width: CGFloat, insets: NSSize, fragmentPadding: CGFloat) -> CGFloat {
    guard width.isFinite, width > 0 else { return 18 + insets.height * 2 }
    if !storage.isEqual(to: source) {
      storage.setAttributedString(source); measured = nil
    }
    let contentWidth = max(1, width - insets.width * 2)
    if let measured, measured.width == contentWidth, measured.padding == fragmentPadding {
      return measured.height + insets.height * 2
    }
    container.lineFragmentPadding = fragmentPadding
    container.size = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    let height = ceil(max(18, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))
    measured = (contentWidth, fragmentPadding, height)
    return height + insets.height * 2
  }
}
