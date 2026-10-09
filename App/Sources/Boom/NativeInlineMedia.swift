import AppKit
import BoomCore
import SwiftUI

private extension NSAttributedString.Key {
  static let mediaItem = Self("BloomInlineMedia")
  static let mediaStart = Self("BloomInlineMediaStart")
}

struct InlineMediaSpan: Decodable {
  let id: UUID
  let location: Int
  let length: Int
  var range: NSRange { NSRange(location: location, length: length) }
}

/// Immutable display data. Encrypted originals stay in the vault; thumbnails
/// and playable bytes exist only while a surface owns their presentation.
@MainActor final class InlineMediaItem: NSObject {
  let record: AttachmentRecord
  let bytes: Data?
  let image: CGImage?
  let failure: String?
  private let prose = NativeReadingTextView(frame: .zero)
  private let measurement = NativeTextMeasurement()
  var kind: AttachmentKind { record.kind }
  init(_ record: AttachmentRecord, bytes: Data? = nil, image: CGImage? = nil, failure: String? = nil) {
    self.record = record; self.bytes = bytes; self.image = image; self.failure = failure
    super.init()
    if kind == .document { prose.setSource(record.text) }
  }
  func size(available: CGFloat) -> NSSize {
    let width = max(1, available)
    switch kind {
    case .image:
      let ratio = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
      let w = min(width, image.map { CGFloat($0.width) } ?? width, 640 * ratio)
      return NSSize(width: w, height: w / ratio)
    case .audio: return NSSize(width: min(width, 560), height: 44)
    case .video: return NSSize(width: min(width, 680), height: min(width, 680) * 9 / 16)
    case .pdf: return NSSize(width: width, height: 360)
    case .document:
      let height = prose.textStorage.map { measurement.height(of: $0, width: width, insets: .zero, fragmentPadding: 0) } ?? 24
      return NSSize(width: width, height: min(480, max(24, height)))
    case .unavailable: return NSSize(width: 24, height: 24)
    }
  }
}

/// One source-preserving glyph projection for readers, manuscripts and chat
/// editors. TextKit reserves the media's space; SwiftUI never sizes its row
/// independently. Null glyphs conceal reference syntax without changing a
/// single source position, revision, selection mapping or Undo operation.
@MainActor final class InlineMediaLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
  func layoutManager(_ manager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes indexes: UnsafePointer<Int>,
    font: NSFont, forGlyphRange range: NSRange) -> Int {
    guard let storage = manager.textStorage else { return 0 }
    var generated = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
    var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
    var changed = false
    for i in 0..<range.length where indexes[i] < storage.length {
      if storage.attribute(.mediaItem, at: indexes[i], effectiveRange: nil) != nil {
        generated[i] = 0
        properties[i] = storage.attribute(.mediaStart, at: indexes[i], effectiveRange: nil) != nil ? .controlCharacter : .null
        changed = true
      }
    }
    guard changed else { return 0 }
    manager.setGlyphs(generated, properties: properties, characterIndexes: indexes, font: font, forGlyphRange: range)
    return range.length
  }
  func layoutManager(_ manager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
    manager.textStorage?.attribute(.mediaStart, at: index, effectiveRange: nil) != nil ? .whitespace : action
  }
  func layoutManager(_ manager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
    for container: NSTextContainer, proposedLineFragment rect: NSRect, glyphPosition: NSPoint,
    characterIndex index: Int) -> NSRect {
    guard let item = manager.textStorage?.attribute(.mediaItem, at: index, effectiveRange: nil) as? InlineMediaItem else { return .zero }
    let size = item.size(available: container.size.width - container.lineFragmentPadding * 2)
    return NSRect(origin: .zero, size: size)
  }
  func layoutManager(_ manager: NSLayoutManager, shouldSetLineFragmentRect line: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>, baselineOffset baseline: UnsafeMutablePointer<CGFloat>,
    in container: NSTextContainer, forGlyphRange glyphs: NSRange) -> Bool {
    guard let storage = manager.textStorage else { return false }
    let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    var height: CGFloat = 0
    storage.enumerateAttribute(.mediaStart, in: characters) { value, range, _ in
      if value != nil, let item = storage.attribute(.mediaItem, at: range.location, effectiveRange: nil) as? InlineMediaItem {
        height = max(height, item.size(available: container.size.width - container.lineFragmentPadding * 2).height + 12)
      }
    }
    guard height > 0 else { return false }
    line.pointee.size.height = max(line.pointee.height, height)
    used.pointee.size.height = max(used.pointee.height, height)
    baseline.pointee = max(baseline.pointee, height - 6)
    return true
  }
}

@MainActor class NativeMediaTextView: NSTextView {
  let inlineMedia = NativeInlineMedia()
  private var deferredLayout = false
  private var nativeEditDepth = 0
  var nativeEditInProgress: Bool { nativeEditDepth > 0 }
  /// TextKit has not applied accumulated character edits to its glyph graph
  /// until the storage transaction closes. Never force that graph from an
  /// editing delegate, media projection, or a speculative resize callback.
  func prepareTextLayout() -> Bool {
    guard !nativeEditInProgress, let storage = textStorage, storage.editedMask.isEmpty else {
      deferTextLayout()
      return false
    }
    return true
  }
  private func deferTextLayout() {
    guard !deferredLayout else { return }
    deferredLayout = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.deferredLayout = false
      self.invalidateIntrinsicContentSize()
      self.needsLayout = true; self.needsDisplay = true
    }
  }
  override func insertText(_ value: Any, replacementRange: NSRange) {
    nativeEditDepth += 1
    defer { nativeEditDepth -= 1; deferTextLayout() }
    super.insertText(value, replacementRange: replacementRange)
  }
  var mediaPresentation: (NSLayoutManager, NSTextContainer)? {
    guard let layoutManager, let textContainer else { return nil }; return (layoutManager, textContainer)
  }
  override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
    let container = textContainer ?? NSTextContainer(size: NSSize(width: max(1, frame.width), height: .greatestFiniteMagnitude))
    let manager = container.layoutManager ?? NSLayoutManager()
    let storage = manager.textStorage ?? NSTextStorage()
    if container.layoutManager == nil { manager.addTextContainer(container) }
    if manager.textStorage == nil { storage.addLayoutManager(manager) }
    super.init(frame: frame, textContainer: container)
    inlineMedia.view = self; layoutManager?.delegate = inlineMedia.layout
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func setMedia(model: WorkspaceModel?) { inlineMedia.configure(model: model) }
  func mediaChanged() {
    invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true
  }
  override func didChangeText() {
    nativeEditDepth += 1
    defer { nativeEditDepth -= 1; deferTextLayout() }
    super.didChangeText(); if !hasMarkedText() { inlineMedia.refresh() }
  }
  override func copy(_ sender: Any?) {
    if let payload = inlineMedia.selectedOriginal(selectedRange()) {
      AttachmentInput.write(payload, to: .general); return
    }
    super.copy(sender)
  }
  override func cut(_ sender: Any?) {
    if isEditable, inlineMedia.selectedOriginal(selectedRange()) != nil { copy(sender); insertText("", replacementRange: selectedRange()); return }
    super.cut(sender)
  }
  override func layout() {
    guard prepareTextLayout() else { return }
    super.layout(); inlineMedia.positionViews()
  }
  override func draw(_ dirtyRect: NSRect) {
    guard prepareTextLayout() else { return }
    inlineMedia.positionViews(); super.draw(dirtyRect)
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { inlineMedia.stop() } else { inlineMedia.refresh() } }
  override func setSelectedRange(_ range: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
    var selection = range
    for range in inlineMedia.currentRanges where range.location < NSMaxRange(selection) && NSMaxRange(range) > selection.location {
      if selection.length == 0 {
        selection.location = selection.location < selectedRange().location ? range.location : NSMaxRange(range)
      } else { selection = NSUnionRange(selection, range) }
    }
    super.setSelectedRange(selection, affinity: affinity, stillSelecting: stillSelecting)
  }
  override func deleteBackward(_ sender: Any?) {
    if selectedRange().length == 0, let range = inlineMedia.currentRanges.first(where: { NSMaxRange($0) == selectedRange().location }) {
      setSelectedRange(range)
    }
    super.deleteBackward(sender)
  }
  override func deleteForward(_ sender: Any?) {
    if selectedRange().length == 0, let range = inlineMedia.currentRanges.first(where: { $0.location == selectedRange().location }) { setSelectedRange(range) }
    super.deleteForward(sender)
  }
}

@MainActor final class NativeInlineMedia {
  weak var view: NativeMediaTextView?
  weak var model: WorkspaceModel?
  let layout = InlineMediaLayout()
  private(set) var spans: [InlineMediaSpan] = []
  private var items: [UUID: InlineMediaItem] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var hosts: [String: InlineMediaHost] = [:]
  private var source: String?
  func configure(model: WorkspaceModel?) {
    if self.model !== model { stop() }
    self.model = model
    refresh()
  }
  func refresh() {
    guard let view, let storage = view.textStorage else { return }
    if source != storage.string {
      source = storage.string
      spans = (try? ProductCore.call(["op": "media_spans", "text": storage.string])) ?? []
    }
    let records = model?.state.attachments ?? []
    let ids = Set(spans.map(\.id))
    for id in Array(items.keys) where !ids.contains(id) { tasks.removeValue(forKey: id)?.cancel(); items.removeValue(forKey: id) }
    for record in records where ids.contains(record.id) {
      if items[record.id]?.record != record {
        tasks.removeValue(forKey: record.id)?.cancel(); items[record.id] = InlineMediaItem(record)
      }
      if items[record.id]?.bytes == nil && items[record.id]?.failure == nil && tasks[record.id] == nil, let vault = model?.store.vault {
        tasks[record.id] = Task { [weak self] in
          do {
            let loaded = try await detachedWork {
              let data = try vault.get(.attachment, id: record.id, limit: 67_108_864)
              guard Digest.sha256(data) == record.rootDigest else { throw BoomError.invalid("Attachment original changed.") }
              return (data, record.kind == .image ? NativeMedia.thumbnail(data, maximum: 1600) : nil)
            }
            guard let self, !Task.isCancelled, self.items[record.id]?.record.rootDigest == record.rootDigest else { return }
            self.items[record.id] = InlineMediaItem(record, bytes: loaded.0, image: loaded.1)
            self.tasks.removeValue(forKey: record.id); self.project(); self.view?.mediaChanged()
          } catch {
            guard let self, !Task.isCancelled else { return }
            self.items[record.id] = InlineMediaItem(record, failure: error.localizedDescription)
            self.tasks.removeValue(forKey: record.id); self.project(); self.view?.mediaChanged()
          }
        }
      }
    }
    project()
  }
  func project() {
    guard let view, let storage = view.textStorage else { return }
    let desired = spans.compactMap { span -> (NSRange, InlineMediaItem)? in
      guard NSMaxRange(span.range) <= storage.length, let item = items[span.id] else { return nil }
      return (span.range, item)
    }
    var existing: [(NSRange, InlineMediaItem)] = []
    storage.enumerateAttribute(.mediaItem, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if let item = value as? InlineMediaItem { existing.append((range, item)) }
    }
    if existing.count == desired.count && zip(existing, desired).allSatisfy({ $0.0 == $1.0 && $0.1 === $1.1 }) {
      positionViews(); return
    }
    let registered = view.undoManager?.isUndoRegistrationEnabled == true
    if registered { view.undoManager?.disableUndoRegistration() }
    defer { if registered { view.undoManager?.enableUndoRegistration() } }
    storage.beginEditing()
    storage.removeAttribute(.mediaItem, range: NSRange(location: 0, length: storage.length))
    storage.removeAttribute(.mediaStart, range: NSRange(location: 0, length: storage.length))
    for span in spans where NSMaxRange(span.range) <= storage.length {
      guard let item = items[span.id] else { continue }
      storage.addAttribute(.mediaItem, value: item, range: span.range)
      storage.addAttribute(.mediaStart, value: true, range: NSRange(location: span.location, length: 1))
    }
    storage.endEditing()
    positionViews()
  }
  func positionViews() {
    if spans.isEmpty {
      for host in hosts.values { host.removeFromSuperview() }
      hosts.removeAll()
      return
    }
    guard let view, let (manager, container) = view.mediaPresentation, let storage = manager.textStorage else { return }
    guard view.prepareTextLayout() else { return }
    manager.ensureLayout(for: container)
    var counts: [UUID: Int] = [:], retained = Set<String>()
    storage.enumerateAttribute(.mediaStart, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      guard value != nil, let item = storage.attribute(.mediaItem, at: range.location, effectiveRange: nil) as? InlineMediaItem else { return }
      let occurrence = counts[item.record.id, default: 0]; counts[item.record.id] = occurrence + 1
      let key = item.record.id.uuidString + ":" + String(occurrence)
      retained.insert(key)
      let host: InlineMediaHost
      if let existing = hosts[key], existing.item === item { host = existing }
      else {
        hosts.removeValue(forKey: key)?.removeFromSuperview()
        host = InlineMediaHost(item: item, owner: view)
        hosts[key] = host; view.addSubview(host)
      }
      host.sourceRange = spans.filter { $0.id == item.record.id }.dropFirst(occurrence).first?.range
      let glyph = manager.glyphIndexForCharacter(at: range.location)
      let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let position = manager.location(forGlyphAt: glyph)
      let size = item.size(available: container.size.width - container.lineFragmentPadding * 2)
      host.frame = NSRect(x: view.textContainerOrigin.x + line.minX + position.x,
        y: view.textContainerOrigin.y + line.minY + 6, width: size.width, height: size.height)
    }
    for key in Array(hosts.keys) where !retained.contains(key) { hosts.removeValue(forKey: key)?.removeFromSuperview() }
  }
  // Native insertion updates attributes before didChangeText publishes the
  // new source. Selection must use those live ranges, never a parsed snapshot.
  var currentRanges: [NSRange] {
    guard let storage = view?.textStorage else { return [] }
    var result: [NSRange] = []
    storage.enumerateAttribute(.mediaItem, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if value != nil { result.append(range) }
    }
    return result
  }
  func selectedOriginal(_ selection: NSRange) -> AttachmentInput? {
    guard let storage = view?.textStorage, currentRanges.contains(selection), selection.location < storage.length,
      let item = storage.attribute(.mediaItem, at: selection.location, effectiveRange: nil) as? InlineMediaItem, let bytes = item.bytes else { return nil }
    return .bytes(name: item.record.name, data: bytes)
  }
  func stop() {
    for task in tasks.values { task.cancel() }; tasks.removeAll()
    for host in hosts.values { host.removeFromSuperview() }; hosts.removeAll(); items.removeAll()
  }
}

@MainActor final class InlineMediaHost: NSView {
  let item: InlineMediaItem
  weak var owner: NativeMediaTextView?
  var sourceRange: NSRange?
  private var content: NSView?
  override var isFlipped: Bool { true }
  init(item: InlineMediaItem, owner: NativeMediaTextView) {
    self.item = item; self.owner = owner
    super.init(frame: .zero)
    toolTip = item.failure ?? item.record.name
    setAccessibilityLabel(item.record.name)
    if let image = item.image, item.kind == .image {
      let imageView = NSImageView(); imageView.image = NSImage(cgImage: image, size: .zero)
      imageView.imageScaling = .scaleProportionallyUpOrDown; content = imageView
    } else if let bytes = item.bytes {
      content = NSHostingView(rootView: AttachmentMediaView(name: item.record.name, bytes: bytes,
        presentation: item.kind, text: item.record.text, maximumTextHeight: 480))
    } else {
      let symbol = NSImageView(); symbol.image = NSImage(systemSymbolName: item.failure == nil ? item.kind.symbol : "exclamationmark.triangle", accessibilityDescription: item.record.name)
      content = symbol
    }
    if let content { addSubview(content) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() { super.layout(); content?.frame = bounds }
  override func hitTest(_ point: NSPoint) -> NSView? {
    if item.kind == .image { return bounds.contains(convert(point, from: superview)) ? self : nil }
    return super.hitTest(point)
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    if let owner, let sourceRange { owner.window?.makeFirstResponder(owner); owner.setSelectedRange(sourceRange) }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    mouseDown(with: event)
    let menu = NSMenu()
    var actions = [("Copy", #selector(copyReference(_:))), ("Export original…", #selector(exportOriginal(_:)))]
    if owner?.isEditable == true { actions.insert(("Cut", #selector(cutReference(_:))), at: 1) }
    for (title, action) in actions {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
    }
    return menu
  }
  @objc private func copyReference(_ sender: Any?) { owner?.copy(sender) }
  @objc private func cutReference(_ sender: Any?) { if owner?.isEditable == true { owner?.cut(sender) } }
  @objc private func exportOriginal(_ sender: Any?) {
    guard let bytes = item.bytes, let model = owner?.inlineMedia.model else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = item.record.name
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportFile(to: url) { bytes }
  }
}
