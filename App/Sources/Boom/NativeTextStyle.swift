import AppKit
import BoomCore

@MainActor protocol NativeTextStylingGuard: AnyObject {
  var applyingExternal: Bool { get set }
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
    let native = view as? any NativeTextStylingGuard
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
      (view as? NativeMediaTextView)?.inlineMedia.refresh()
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

