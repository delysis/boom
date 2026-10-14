import AppKit
import BoomCore

@MainActor protocol NativeTextStylingGuard: AnyObject {
  var applyingExternal: Bool { get set }
}

struct MarkdownSpan: Decodable, Sendable {
  let kind: String
  let location: Int
  let length: Int
  let level: Int
}

@MainActor enum MarkdownStyle {
  static let body = NSFont.systemFont(ofSize: 15)
  private static let wikiPattern = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]{1,256})\]\]"#)
  private static let attachmentPattern = try? NSRegularExpression(pattern: #"\[Attachment: ((?:\\.|[^\\\]\n])+)\]\(boom-attachment:[0-9A-Fa-f-]{36}\)"#)
  private static let owned: Set<NSAttributedString.Key> = [
    .font, .foregroundColor, .paragraphStyle, .backgroundColor,
    .strikethroughStyle, .underlineStyle,
  ]
  struct WikiDisplay {
    let title: NSRange
    let hidden: [NSRange]
  }
  static func wikiDisplays(in source: String, excluding literalRanges: [NSRange] = [], hasMarker: Bool? = nil) -> [WikiDisplay] {
    guard let pattern = wikiPattern
    else { return [] }
    let text = source as NSString
    guard hasMarker ?? (text.range(of: "[[", options: .literal).location != NSNotFound) else { return [] }
    return pattern.matches(in: source, range: NSRange(location: 0, length: text.length))
      .compactMap { match in
        guard !literalRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
          return nil
        }
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
    let trace = PerformanceTrace.begin("Editor.Style")
    defer { PerformanceTrace.end("Editor.Style", trace) }
    guard let current = view.textStorage else { return }
    let source = current.string
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
    let text = source as NSString
    let full = NSRange(location: 0, length: text.length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    let base: [NSAttributedString.Key: Any] = [
      .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
    let spans: [MarkdownSpan]
    let projection: ProductCore.MarkupProjection?
    if let native = view as? NativeMediaTextView {
      let captured = native.markupProjection
      projection = captured
      spans = captured.markdown
    } else {
      projection = nil
      let trace = PerformanceTrace.begin("Editor.MarkdownParse")
      defer { PerformanceTrace.end("Editor.MarkdownParse", trace) }
      spans = (try? ProductCore.markdownSpans(source)) ?? []
    }
    let literalRanges = spans.filter { $0.kind == "code" || $0.kind == "literal" }
      .map { NSRange(location: $0.location, length: $0.length) }
    let wikis = wikiDisplays(in: source, excluding: literalRanges, hasMarker: projection?.hasWikiMarker)
    let hasAttachment = projection?.hasAttachmentMarker
      ?? (text.range(of: "[Attachment: ", options: .literal).location != NSNotFound)
    let attachments = hasAttachment ? (attachmentPattern?.matches(in: source, range: full) ?? []).filter { match in
      !literalRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
    } : []
    view.typingAttributes = base
    defer {
      (view as? NativeMediaTextView)?.inlineMedia.refresh()
      for match in attachments { view.setSpellingState(0, range: match.range) }
    }
    // Parsing remains authoritative, including code and reference syntax. A
    // plain result needs only an attribute diff, not a full attributed copy.
    if spans.isEmpty, wikis.isEmpty, attachments.isEmpty {
      synchronizePlain(base, into: current)
      return
    }
    let storage = NSMutableAttributedString(string: source)
    storage.setAttributes(base, range: full)
    defer { synchronize(storage, into: current) }
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
    for display in wikis {
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
    for match in attachments {
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
  }
  private static func synchronizePlain(_ expected: [NSAttributedString.Key: Any], into current: NSTextStorage) {
    let trace = PerformanceTrace.begin("Editor.StyleSynchronize")
    defer { PerformanceTrace.end("Editor.StyleSynchronize", trace) }
    var edits: [(NSRange, [NSAttributedString.Key: Any])] = []
    current.enumerateAttributes(in: NSRange(location: 0, length: current.length)) { existing, range, _ in
      let before = existing.filter { owned.contains($0.key) }
      guard !(before as NSDictionary).isEqual(expected as NSDictionary) else { return }
      var replacement = existing.filter { !owned.contains($0.key) }
      replacement.merge(expected) { _, value in value }
      edits.append((range, replacement))
    }
    guard !edits.isEmpty else { return }
    current.beginEditing()
    for (range, attributes) in edits { current.setAttributes(attributes, range: range) }
    current.endEditing()
  }
  private static func synchronize(_ desired: NSAttributedString, into current: NSTextStorage) {
    let trace = PerformanceTrace.begin("Editor.StyleSynchronize")
    defer { PerformanceTrace.end("Editor.StyleSynchronize", trace) }
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

