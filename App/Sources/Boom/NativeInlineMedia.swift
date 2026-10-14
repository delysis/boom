import AppKit
import AVKit
import PDFKit
import BoomCore

private extension NSAttributedString.Key {
  static let mediaItem = Self("BloomInlineMedia")
  static let mediaStart = Self("BloomInlineMediaStart")
}

struct InlineMediaSpan: Decodable, Sendable, Equatable {
  let id: UUID
  let location: Int
  let length: Int
  var range: NSRange { NSRange(location: location, length: length) }
}

/// Lightweight source metadata plus a visible thumbnail/native file consumer.
/// Originals are never resident Data in a display item.
@MainActor final class InlineMediaItem: NSObject {
  let record: AttachmentRecord
  let file: NativeInlineMediaFile?
  let image: CGImage?
  let pdf: PDFDocument?
  let asset: AVURLAsset?
  let imageGeometry: NSSize?
  let failure: String?
  private var documentMeasurement: (width: CGFloat, height: CGFloat)?
  fileprivate weak var documentReader: NativeReadingTextView?
  var kind: AttachmentKind { record.kind }
  var isReady: Bool { image != nil || file != nil || kind == .document || kind == .unavailable }
  var hasResidentPresentation: Bool { image != nil || file != nil }
  init(_ record: AttachmentRecord, file: NativeInlineMediaFile? = nil,
    image: CGImage? = nil, pdf: PDFDocument? = nil, asset: AVURLAsset? = nil,
    imageGeometry: NSSize? = nil, failure: String? = nil) {
    self.record = record; self.file = file; self.image = image; self.pdf = pdf; self.asset = asset
    self.imageGeometry = imageGeometry; self.failure = failure
    super.init()
  }
  nonisolated static func imageSize(geometry: NSSize?, available: CGFloat) -> NSSize {
    let width = max(1, available)
    let ratio = geometry.map { $0.width / $0.height } ?? 1.5
    let w = min(width, geometry?.width ?? width, 640 * ratio)
    return NSSize(width: w, height: w / ratio)
  }
  func size(available: CGFloat) -> NSSize {
    let width = max(1, available)
    switch kind {
    case .image: return Self.imageSize(geometry: imageGeometry, available: width)
    case .audio: return NSSize(width: min(width, 560), height: 44)
    case .video: return NSSize(width: min(width, 680), height: min(width, 680) * 9 / 16)
    case .pdf: return NSSize(width: width, height: 360)
    case .document:
      if documentMeasurement?.width != width, let documentReader {
        documentMeasurement = (width, documentReader.boundedAttachmentHeight(at: width, maximum: 480))
      }
      // An unseen document has no reader or parse/layout work. Its actual
      // visible host resolves this placeholder, then invalidates its glyph.
      if let measured = documentMeasurement, measured.width == width {
        return NSSize(width: width, height: measured.height)
      }
      return NSSize(width: width, height: 24)
    case .unavailable: return NSSize(width: 24, height: 24)
    }
  }
}

/// One source-preserving glyph projection for readers, manuscripts and chat
/// editors. TextKit reserves the media's space; SwiftUI never sizes its row
/// independently. Null glyphs conceal reference syntax without changing a
/// single source position, revision, selection mapping or Undo operation.
@MainActor final class InlineMediaLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
  // The live projection writes this beside its attribute transaction. An
  // isolated measurement reconciles it when copying attributed runs. Unknown
  // storage stays conservative until then; ordinary text skips glyph scans.
  fileprivate var hasMedia = true
  func invalidateMediaPresence() { hasMedia = true }
  func reconcileMediaPresence(in storage: NSAttributedString) {
    var present = false
    storage.enumerateAttribute(.mediaItem, in: NSRange(location: 0, length: storage.length),
      options: .longestEffectiveRangeNotRequired) { value, _, stop in
      if value != nil { present = true; stop.pointee = true }
    }
    hasMedia = present
  }
  func layoutManager(_ manager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes indexes: UnsafePointer<Int>,
    font: NSFont, forGlyphRange range: NSRange) -> Int {
    // The no-media return has no scan or allocation. Avoid flooding the
    // diagnostic ring with two phase records for this constant-time branch.
    guard hasMedia, let storage = manager.textStorage else { return 0 }
    // Existing diagnostic stage: low bit is media presence, remaining bits
    // are glyph count. No text or attributed-buffer copies enter the trace.
    let event = UInt64(clamping: range.length) << 1 | (hasMedia ? 1 : 0)
    let trace = PerformanceTrace.begin("Editor.MediaLayout", event: event)
    defer { PerformanceTrace.end("Editor.MediaLayout", trace) }
    // Glyph batches usually share one attribute run. Reuse that run for both
    // directions of character indexes, including reordered/bidirectional glyphs.
    // Unknown media presence remains conservative without a lookup per glyph.
    var mediaRange = NSRange(location: NSNotFound, length: 0)
    var mediaPresent = false
    func hasMediaAttribute(at character: Int) -> Bool {
      guard character >= 0, character < storage.length else { return false }
      if !NSLocationInRange(character, mediaRange) {
        mediaPresent = storage.attribute(.mediaItem, at: character, effectiveRange: &mediaRange) != nil
      }
      return mediaPresent
    }
    guard let first = (0..<range.length).first(where: { hasMediaAttribute(at: indexes[$0]) }) else { return 0 }
    var generated = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
    var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
    for i in first..<range.length where indexes[i] >= 0 && indexes[i] < storage.length {
      if hasMediaAttribute(at: indexes[i]) {
        generated[i] = 0
        properties[i] = storage.attribute(.mediaStart, at: indexes[i], effectiveRange: nil) != nil ? .controlCharacter : .null
      }
    }
    manager.setGlyphs(generated, properties: properties, characterIndexes: indexes, font: font, forGlyphRange: range)
    return range.length
  }
  func layoutManager(_ manager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
    hasMedia && manager.textStorage?.attribute(.mediaStart, at: index, effectiveRange: nil) != nil ? .whitespace : action
  }
  func layoutManager(_ manager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
    for container: NSTextContainer, proposedLineFragment rect: NSRect, glyphPosition: NSPoint,
    characterIndex index: Int) -> NSRect {
    guard hasMedia, let item = manager.textStorage?.attribute(.mediaItem, at: index, effectiveRange: nil) as? InlineMediaItem else { return .zero }
    let size = item.size(available: container.size.width - container.lineFragmentPadding * 2)
    return NSRect(origin: .zero, size: size)
  }
  func layoutManager(_ manager: NSLayoutManager, shouldSetLineFragmentRect line: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>, baselineOffset baseline: UnsafeMutablePointer<CGFloat>,
    in container: NSTextContainer, forGlyphRange glyphs: NSRange) -> Bool {
    guard hasMedia, let storage = manager.textStorage else { return false }
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
  /// Optional component observers retain only monotonic timing. Ordinary views
  /// leave these nil; they neither change scheduling nor retain authored text.
  var deferredLayoutObservation: ((ContinuousClock.Instant, ContinuousClock.Instant, ContinuousClock.Instant) -> Void)?
  var drawObservation: ((ContinuousClock.Instant, ContinuousClock.Instant) -> Void)?
  private weak var observedSource: NSTextStorage?
  private weak var observedMediaClip: NSClipView?
  private var characterVersion = UUID()
  private var cachedMarkup: (version: UUID, value: ProductCore.MarkupProjection)?
  /// Partial source cannot establish remote Markdown fences or definitions.
  /// Such views keep literal source visible until its parse context is known.
  var hasCompleteMarkupContext: Bool { true }
  /// Character edits invalidate source consumers; display attributes do not.
  /// Rebinding a text container also starts a new source identity.
  var sourceVersion: UUID {
    if observedSource !== textStorage {
      NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
      observedSource = textStorage
      characterVersion = UUID()
      cachedMarkup = nil
      if let storage = textStorage {
        NotificationCenter.default.addObserver(self, selector: #selector(sourceDidEdit(_:)),
          name: NSTextStorage.didProcessEditingNotification, object: storage)
      }
    }
    return characterVersion
  }
  /// One projection belongs to the exact native character version. Attribute
  /// updates may reuse its small span arrays; no source buffer is cached.
  var markupProjection: ProductCore.MarkupProjection {
    guard hasCompleteMarkupContext else {
      return ProductCore.MarkupProjection(markdown: [], media: [],
        hasWikiMarker: false, hasAttachmentMarker: false)
    }
    let version = sourceVersion
    let pendingCharacters = textStorage?.editedMask.contains(.editedCharacters) == true
    if !pendingCharacters, let cachedMarkup, cachedMarkup.version == version { return cachedMarkup.value }
    let value = ProductCore.markupProjection(textStorage?.string ?? "")
    // An open storage transaction can contain new characters before its
    // didProcessEditing notification advances sourceVersion.
    cachedMarkup = pendingCharacters ? nil : (version, value)
    return value
  }
  @objc private func sourceDidEdit(_ notification: Notification) {
    guard let storage = notification.object as? NSTextStorage, storage === observedSource,
      storage.editedMask.contains(.editedCharacters) else { return }
    characterVersion = UUID()
    cachedMarkup = nil
  }
  /// New proved display context does not change any character/source epoch.
  func derivedMarkupDidChange() {
    cachedMarkup = nil
    inlineMedia.invalidateMarkup()
  }
  deinit { NotificationCenter.default.removeObserver(self) }
  private var deferredLayout = false
  private var nativeEditDepth = 0
  var nativeEditInProgress: Bool { nativeEditDepth > 0 }
  var mediaRefreshIsDeferred: Bool { nativeEditInProgress || hasMarkedText() }
  fileprivate func deferMediaProjection() { deferTextLayout() }
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
    let wait = PerformanceTrace.begin("Editor.DeferredLayoutWait")
    let observer = deferredLayoutObservation
    let scheduled = observer.map { _ in ContinuousClock().now }
    DispatchQueue.main.async { [weak self] in
      PerformanceTrace.end("Editor.DeferredLayoutWait", wait)
      guard let self else { return }
      let started = observer.map { _ in ContinuousClock().now }
      let trace = PerformanceTrace.begin("Editor.DeferredLayout")
      defer { PerformanceTrace.end("Editor.DeferredLayout", trace) }
      self.deferredLayout = false
      self.inlineMedia.resumeDeferredRefresh()
      self.invalidateIntrinsicContentSize()
      self.needsLayout = true; self.needsDisplay = true
      if let observer, let scheduled, let started {
        observer(scheduled, started, ContinuousClock().now)
      }
    }
  }
  override func insertText(_ value: Any, replacementRange: NSRange) {
    let trace = PerformanceTrace.begin("Editor.InsertText")
    defer { PerformanceTrace.end("Editor.InsertText", trace) }
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
    inlineMedia.layout.reconcileMediaPresence(in: storage)
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
  override func unmarkText() {
    super.unmarkText()
    if !hasMarkedText() {
      inlineMedia.resumeDeferredRefresh()
      if inlineMedia.deferredRefresh { deferTextLayout() }
    }
  }
  override func copy(_ sender: Any?) {
    if inlineMedia.copyOriginal(selectedRange(), cutting: false) { return }
    super.copy(sender)
  }
  override func cut(_ sender: Any?) {
    if isEditable, inlineMedia.copyOriginal(selectedRange(), cutting: true) { return }
    super.cut(sender)
  }
  override func layout() {
    guard prepareTextLayout() else { return }
    super.layout(); inlineMedia.positionViews()
  }
  override func draw(_ dirtyRect: NSRect) {
    let trace = PerformanceTrace.begin("Editor.Draw")
    defer { PerformanceTrace.end("Editor.Draw", trace) }
    let observer = drawObservation
    let started = observer.map { _ in ContinuousClock().now }
    defer { if let observer, let started { observer(started, ContinuousClock().now) } }
    guard prepareTextLayout() else { return }
    inlineMedia.positionViews(); super.draw(dirtyRect)
  }
  private func observeMediaClip() {
    let clip = enclosingScrollView?.contentView
    guard observedMediaClip !== clip else { return }
    if let observedMediaClip {
      NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedMediaClip)
    }
    observedMediaClip = clip
    if let clip {
      clip.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(self, selector: #selector(mediaClipDidScroll(_:)),
        name: NSView.boundsDidChangeNotification, object: clip)
    }
  }
  @objc private func mediaClipDidScroll(_ notification: Notification) {
    guard let clip = notification.object as? NSClipView, clip === observedMediaClip else { return }
    inlineMedia.viewportDidChange()
  }
  override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeMediaClip() }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow(); observeMediaClip()
    if window == nil { inlineMedia.stop() }
    else { inlineMedia.configure(model: inlineMedia.model) }
  }
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
  var attachmentRemoval: (() -> Void)?
  let layout = InlineMediaLayout()
  private(set) var spans: [InlineMediaSpan] = []
  private var items: [UUID: InlineMediaItem] = [:]
  private var hosts: [String: InlineMediaHost] = [:]
  let disposal = NativeInlineMediaDisposal()
  private var loadTask: Task<Void, Never>?
  private var loadID: UUID?
  private var loadingPreviewID: UUID?
  private var pendingCopy: OriginalCopy?
  private var visibleIDs = Set<UUID>()
  private var visibleOrder: [UUID] = []
  private var positioning = false
  private var covered = false
  private var stopped = false
  private var parsedSourceVersion: UUID?
  private(set) var lastFailure: Error?
  private(set) var cleanupFailure: NativeInlineMediaFileCleanupFailure?
  fileprivate var deferredRefresh = false

  private struct OriginalCopy {
    let intent: ClipboardIntent
    let record: AttachmentRecord
    let file: NativeInlineMediaFile?
    let storage: NSTextStorage
    let version: UUID
    let selection: NSRange
    let cutting: Bool
  }
  private enum Work {
    case preview(AttachmentRecord, CGFloat, CGFloat)
    case original(OriginalCopy)
  }
  func configure(model: WorkspaceModel?) {
    if self.model !== model { stop() }
    self.model = model
    stopped = false
    refresh()
  }
  func invalidateMarkup() { parsedSourceVersion = nil }
  private func deferRefresh(on view: NativeMediaTextView) {
    deferredRefresh = true
    if !view.hasMarkedText() { view.deferMediaProjection() }
  }
  func resumeDeferredRefresh() {
    guard deferredRefresh, let view, !view.mediaRefreshIsDeferred,
      view.textStorage?.editedMask.isEmpty != false else { return }
    let hadMedia = !spans.isEmpty || !hosts.isEmpty
    refresh()
    if hadMedia || !spans.isEmpty { view.mediaChanged() }
  }
  /// Joins real entered workers, including cancellation, then already-enqueued
  /// file disposal. This never revokes files still owned by another surface.
  @discardableResult func joinPendingLoads() async -> NativeInlineMediaFileCleanupFailure? {
    while let loadTask { await loadTask.value }
    let joinedCleanup = await disposal.joinQueued()
    if cleanupFailure == nil, let cleanup = joinedCleanup {
      cleanupFailure = cleanup
      if let original = lastFailure { lastFailure = NativeInlineMediaCleanupFailure(original: original, cleanup: cleanup) }
      else { lastFailure = cleanup }
      // This is a disposable preview failure, not a source/persistence latch.
      model?.status = cleanup.localizedDescription
      PerformanceTrace.event("Editor.SourceRead")
    }
    return cleanupFailure
  }
  func adoptReadyDisplayItems(from other: NativeInlineMedia, ids: [UUID]) {
    guard model === other.model else { return }
    let wanted = Set(ids)
    for (id, item) in other.items where wanted.contains(id) {
      // Geometry is lightweight and must transfer even when pixels were
      // evicted. An actual ready file/image remains shared, never copied.
      items[id] = item
    }
  }
  func refresh() {
    let trace = PerformanceTrace.begin("Editor.MediaRefresh")
    defer { PerformanceTrace.end("Editor.MediaRefresh", trace) }
    guard let view, let storage = view.textStorage, !stopped else { return }
    guard !view.mediaRefreshIsDeferred else { deferRefresh(on: view); return }
    deferredRefresh = false
    let version = view.sourceVersion
    let pendingCharacters = storage.editedMask.contains(.editedCharacters)
    if pendingCharacters || parsedSourceVersion != version {
      spans = view.markupProjection.media
      parsedSourceVersion = pendingCharacters ? nil : version
    }
    let ids = Set(spans.map(\.id))
    for id in Array(items.keys) where !ids.contains(id) { items.removeValue(forKey: id) }
    // Ordinary text must not scan the workspace's unrelated attachments.
    if ids.isEmpty { project(); return }
    for record in model?.state.attachments ?? [] where ids.contains(record.id) {
      if items[record.id]?.record != record { items[record.id] = InlineMediaItem(record) }
    }
    project()
  }
  private func retireHost(_ key: String) {
    guard let host = hosts.removeValue(forKey: key) else { return }
    host.stopPlayback(); host.removeFromSuperview()
  }
  private func pump() {
    guard !stopped, loadTask == nil, let view, view.window != nil, let vault = model?.store.vault else { return }
    let work: Work
    if let copy = pendingCopy {
      pendingCopy = nil
      guard copy.intent.isCurrent else { pump(); return }
      work = .original(copy)
    }
    else {
      guard !covered, !view.isHiddenOrHasHiddenAncestor else { return }
      guard let item = visibleOrder.compactMap({ items[$0] })
        .first(where: { !$0.isReady && $0.failure == nil }) else { return }
      let width = max(1, (view.textContainer?.size.width ?? view.bounds.width)
        - (view.textContainer?.lineFragmentPadding ?? 0) * 2)
      work = .preview(item.record, width, view.window?.backingScaleFactor ?? 1)
    }
    let job = UUID()
    loadID = job
    if case .preview(let record, _, _) = work { loadingPreviewID = record.id }
    else { loadingPreviewID = nil }
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.loadID == job {
          self.loadTask = nil; self.loadID = nil; self.loadingPreviewID = nil
          self.pump()
        }
      }
      do {
        switch work {
        case .preview(let record, let width, let scale):
          let disposal = self.disposal
          let ready = try await detachedWork {
            try NativeInlineMediaPrepared.load(record: record, vault: vault,
              availableWidth: width, scale: scale, disposal: disposal)
          }
          guard !Task.isCancelled, !self.stopped, self.visibleIDs.contains(record.id),
            self.items[record.id]?.record == record else { return }
          self.items[record.id] = InlineMediaItem(record, file: ready.file, image: ready.image,
            pdf: ready.pdf, asset: ready.asset, imageGeometry: ready.imageGeometry)
          self.refresh(); self.view?.mediaChanged()
        case .original(let copy):
          let record = copy.record, file = copy.file
          let prepared = try await detachedWork { try autoreleasepool {
            try Task.checkCancellation()
            let bytes: Data
            if let file { bytes = try file.verifiedBytes(for: record) }
            else { bytes = try vault.get(.attachment, id: record.id, limit: 67_108_864) }
            guard Digest.sha256(bytes) == record.rootDigest else {
              throw BoomError.stale("The requested original does not match its attachment record.")
            }
            guard let prepared = AttachmentInput.prepareWrite(.bytes(name: record.name, data: bytes)) else {
              throw BoomError.invalid("The original could not be prepared for copying.")
            }
            try Task.checkCancellation()
            return prepared
          } }
          guard !Task.isCancelled, !self.stopped, copy.intent.isCurrent, let view = self.view,
            view.textStorage === copy.storage, view.sourceVersion == copy.version,
            view.selectedRange() == copy.selection, !view.hasMarkedText(), !view.nativeEditInProgress,
            !copy.storage.editedMask.contains(.editedCharacters),
            let current = self.item(for: copy.selection)?.record,
            current.id == record.id, current.rootDigest == record.rootDigest,
            self.model?.state.attachments.contains(where: { $0.id == record.id && $0.rootDigest == record.rootDigest }) == true else { return }
          guard AttachmentInput.write(prepared, to: .general) else {
            throw BoomError.unavailable("The original clipboard representation could not be published.")
          }
          if copy.cutting {
            // This dynamic native entry establishes its normal current input
            // scope. No source range is removed before original publication.
            guard copy.intent.isLatest, view.isEditable, view.textStorage === copy.storage,
              view.sourceVersion == copy.version, view.selectedRange() == copy.selection else { return }
            view.insertText("", replacementRange: copy.selection)
          }
        }
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, !self.stopped else { return }
        if case .original(let copy) = work, !copy.intent.isLatest { return }
        self.lastFailure = error
        if case .original = work {
          self.model?.status = error.localizedDescription
          PerformanceTrace.event("Editor.ManagedAdmission")
        }
        if case .preview(let record, _, _) = work, self.items[record.id]?.record == record {
          let geometry = self.items[record.id]?.imageGeometry
          self.items[record.id] = InlineMediaItem(record, imageGeometry: geometry, failure: error.localizedDescription)
          self.refresh(); self.view?.mediaChanged()
        }
      }
    }
  }
  @discardableResult func copyOriginal(_ selection: NSRange, cutting: Bool) -> Bool {
    guard !stopped, let view, let storage = view.textStorage, let item = item(for: selection),
      model?.store.vault != nil else { return false }
    let intent = ClipboardIntent.begin()
    pendingCopy = OriginalCopy(intent: intent, record: item.record, file: item.file, storage: storage,
      version: view.sourceVersion, selection: selection, cutting: cutting)
    // A second clipboard intent supersedes only the previous clipboard work.
    // A canceled entered producer still holds the one slot until its join.
    loadTask?.cancel()
    pump()
    return true
  }
  private func item(for selection: NSRange) -> InlineMediaItem? {
    guard let storage = view?.textStorage, currentRanges.contains(selection),
      selection.location >= 0, selection.location < storage.length else { return nil }
    return storage.attribute(.mediaItem, at: selection.location, effectiveRange: nil) as? InlineMediaItem
  }
  func project() {
    let trace = PerformanceTrace.begin("Editor.MediaProject")
    defer { PerformanceTrace.end("Editor.MediaProject", trace) }
    guard let view, let storage = view.textStorage else { return }
    guard !view.mediaRefreshIsDeferred else { deferRefresh(on: view); return }
    // A record's byte digest does not admit old character coordinates. Only
    // refresh on this exact current source may assign media attributes.
    guard parsedSourceVersion == view.sourceVersion,
      !storage.editedMask.contains(.editedCharacters) else { deferRefresh(on: view); return }
    let desired = spans.compactMap { span -> (NSRange, InlineMediaItem)? in
      guard NSMaxRange(span.range) <= storage.length, let item = items[span.id] else { return nil }
      return (span.range, item)
    }
    var existing: [(NSRange, InlineMediaItem)] = []
    storage.enumerateAttribute(.mediaItem, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if let item = value as? InlineMediaItem { existing.append((range, item)) }
    }
    if existing.count == desired.count && zip(existing, desired).allSatisfy({ $0.0 == $1.0 && $0.1 === $1.1 }) {
      layout.hasMedia = !existing.isEmpty
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
    // Publish before endEditing can ask the delegate to regenerate glyphs.
    layout.hasMedia = !desired.isEmpty
    storage.endEditing()
    positionViews()
  }
  func setCovered(_ value: Bool) {
    guard covered != value else { return }
    covered = value
    positionViews()
  }
  func viewportDidChange() {
    guard let view, !stopped else { return }
    // Most readonly rows are offscreen and have never loaded anything. A
    // clip notification must not ask TextKit to lay those rows out.
    if hosts.isEmpty && loadTask == nil && (covered || view.isHiddenOrHasHiddenAncestor || view.visibleRect.isEmpty) { return }
    positionViews()
  }
  func positionViews() {
    let trace = PerformanceTrace.begin("Editor.MediaLayout")
    defer { PerformanceTrace.end("Editor.MediaLayout", trace) }
    guard !positioning, !stopped, let view else { return }
    // No attachment projection has no media geometry or preview work.
    guard !spans.isEmpty || !hosts.isEmpty else { return }
    guard !view.mediaRefreshIsDeferred else { deferRefresh(on: view); return }
    guard let (manager, container) = view.mediaPresentation, let storage = manager.textStorage else { return }
    guard view.prepareTextLayout(), parsedSourceVersion == view.sourceVersion,
      !storage.editedMask.contains(.editedCharacters) else { deferredRefresh = true; return }
    positioning = true
    defer { positioning = false; pump() }
    let visible: NSRect = covered || view.window == nil || view.isHiddenOrHasHiddenAncestor ? .zero
      : view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
    var visibleCharacters = NSRange(location: 0, length: 0)
    if !visible.isEmpty {
      manager.ensureLayout(forBoundingRect: visible, in: container)
      let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
      visibleCharacters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      // A tall control glyph can begin before the returned clipped character
      // interval. Extend only its actual effective media run, not a text halo.
      if visibleCharacters.location < storage.length {
        var run = NSRange()
        if storage.attribute(.mediaItem, at: visibleCharacters.location, effectiveRange: &run) != nil {
          visibleCharacters = NSUnionRange(visibleCharacters, run)
        }
      }
    }
    var counts: [UUID: Int] = [:], retained = Set<String>(), wanted = Set<UUID>(), order: [UUID] = []
    for span in spans where span.location >= 0 && span.length > 0 && NSMaxRange(span.range) <= storage.length {
      guard let item = storage.attribute(.mediaItem, at: span.location, effectiveRange: nil) as? InlineMediaItem else { continue }
      let occurrence = counts[span.id, default: 0]; counts[span.id] = occurrence + 1
      let key = span.id.uuidString + ":" + String(occurrence)
      let isVisible = NSIntersectionRange(span.range, visibleCharacters).length > 0
      let playing = hosts[key]?.isPlaying == true
      guard isVisible || playing else { continue }
      retained.insert(key)
      if isVisible, wanted.insert(span.id).inserted { order.append(span.id) }
      let host: InlineMediaHost
      if let existing = hosts[key], existing.item === item { host = existing }
      else {
        retireHost(key)
        host = InlineMediaHost(item: item, owner: view)
        hosts[key] = host; view.addSubview(host)
        if item.kind == .document {
          // First visibility supplied its real reader. Reflow the actual
          // marker with finite measured geometry instead of the placeholder.
          _ = item.size(available: container.size.width - container.lineFragmentPadding * 2)
          manager.invalidateLayout(forCharacterRange: span.range, actualCharacterRange: nil)
          view.mediaChanged()
        }
      }
      host.sourceRange = span.range
      if isVisible {
        let glyph = manager.glyphIndexForCharacter(at: span.location)
        guard glyph < manager.numberOfGlyphs else { continue }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = manager.location(forGlyphAt: glyph)
        let size = item.size(available: container.size.width - container.lineFragmentPadding * 2)
        host.frame = NSRect(x: view.textContainerOrigin.x + line.minX + position.x,
          y: view.textContainerOrigin.y + line.minY + 6, width: size.width, height: size.height)
      }
    }
    if let loadingPreviewID, !wanted.contains(loadingPreviewID) { loadTask?.cancel() }
    // A new visible intent may retry a prior preview failure without a timer
    // or an ordinary-input failure latch. No retry loop while it stays visible.
    var retry = false
    for id in wanted.subtracting(visibleIDs) {
      if let item = items[id], item.failure != nil {
        items[id] = InlineMediaItem(item.record, imageGeometry: item.imageGeometry)
        retry = true
      }
    }
    visibleIDs = wanted; visibleOrder = order
    for key in Array(hosts.keys) where !retained.contains(key) { retireHost(key) }
    let playingIDs = Set(hosts.values.filter(\.isPlaying).map { $0.item.record.id })
    var evicted = false
    for id in Array(items.keys) {
      guard let item = items[id], item.hasResidentPresentation,
        !wanted.contains(id), !playingIDs.contains(id) else { continue }
      // Attributes retain only this lightweight replacement. Pixel eviction
      // never changes known image geometry or source coordinates.
      items[id] = InlineMediaItem(item.record, imageGeometry: item.imageGeometry, failure: item.failure)
      evicted = true
    }
    if evicted || retry { project() }
  }
  var currentRanges: [NSRange] {
    guard let storage = view?.textStorage else { return [] }
    var result: [NSRange] = []
    storage.enumerateAttribute(.mediaItem, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if value != nil { result.append(range) }
    }
    return result
  }
  func stop() {
    stopped = true; covered = false; deferredRefresh = false; pendingCopy = nil
    visibleIDs.removeAll(); visibleOrder.removeAll()
    // Retain the actual canceled handle until the entered worker finishes.
    loadTask?.cancel()
    for key in Array(hosts.keys) { retireHost(key) }
    items.removeAll()
    if let view, !view.mediaRefreshIsDeferred,
      view.textStorage?.editedMask.contains(.editedCharacters) != true { project() }
  }
}

@MainActor final class InlineMediaHost: NSView {
  let item: InlineMediaItem
  weak var owner: NativeMediaTextView?
  var sourceRange: NSRange?
  private var content: NSView?
  private var player: AVPlayer?
  var isPlaying: Bool {
    guard let player else { return false }
    return player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }
  func stopPlayback() {
    player?.pause(); player?.replaceCurrentItem(with: nil)
    (content as? AVPlayerView)?.player = nil
    player = nil
  }
  override var isFlipped: Bool { true }
  init(item: InlineMediaItem, owner: NativeMediaTextView) {
    self.item = item; self.owner = owner
    super.init(frame: .zero)
    toolTip = item.failure ?? item.record.name
    setAccessibilityLabel(item.record.name)
    if let image = item.image, item.kind == .image {
      let imageView = NSImageView(); imageView.image = NSImage(cgImage: image, size: .zero)
      imageView.imageScaling = .scaleProportionallyUpOrDown; content = imageView
    } else if let asset = item.asset, let file = item.file, item.kind == .audio || item.kind == .video {
      let nativeItem = AVPlayerItem(asset: asset)
      file.retainForLifetime(of: nativeItem)
      let player = AVPlayer(playerItem: nativeItem), native = AVPlayerView()
      native.controlsStyle = .inline; native.videoGravity = .resizeAspect; native.player = player
      self.player = player; content = native
    } else if let pdf = item.pdf {
      let native = PDFView(); native.document = pdf
      native.autoScales = true; native.displayMode = .singlePageContinuous
      content = native
    } else if item.kind == .document {
      let scroll = NativeTextScrollView(attachmentViewport: true)
      scroll.reader.setSource(item.record.text)
      item.documentReader = scroll.reader
      content = scroll
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
  private struct MenuSource {
    let ownerID: ObjectIdentifier
    let storageID: ObjectIdentifier
    let version: UUID
    let range: NSRange
  }
  private var liveSource: (owner: NativeMediaTextView, storage: NSTextStorage, range: NSRange)? {
    guard let owner, superview === owner, let range = sourceRange, let storage = owner.textStorage,
      range.location >= 0, range.location < storage.length, range.length > 0,
      range.length <= storage.length - range.location,
      owner.inlineMedia.spans.contains(where: { $0.id == item.record.id && $0.range == range }),
      (storage.attribute(.mediaItem, at: range.location, effectiveRange: nil) as? InlineMediaItem) === item,
      (storage.attribute(.mediaItem, at: NSMaxRange(range) - 1, effectiveRange: nil) as? InlineMediaItem) === item else { return nil }
    return (owner, storage, range)
  }
  private func menuOwner(_ sender: Any?) -> NativeMediaTextView? {
    guard let entry = sender as? NSMenuItem, let captured = entry.representedObject as? MenuSource,
      let source = liveSource, ObjectIdentifier(source.owner) == captured.ownerID,
      ObjectIdentifier(source.storage) == captured.storageID, source.owner.sourceVersion == captured.version,
      source.range == captured.range, source.owner.selectedRange() == captured.range else { return nil }
    return source.owner
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard let source = liveSource else { return }
    source.owner.window?.makeFirstResponder(source.owner)
    source.owner.setSelectedRange(source.range)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let source = liveSource else { return nil }
    mouseDown(with: event)
    let captured = MenuSource(ownerID: ObjectIdentifier(source.owner),
      storageID: ObjectIdentifier(source.storage), version: source.owner.sourceVersion, range: source.range)
    let menu = NSMenu()
    var actions = [("Copy", #selector(copyReference(_:))), ("Export original…", #selector(exportOriginal(_:)))]
    if owner?.isEditable == true { actions.insert(("Cut", #selector(cutReference(_:))), at: 1) }
    if owner?.inlineMedia.attachmentRemoval != nil { actions.append(("Remove", #selector(removeReference(_:)))) }
    for (title, action) in actions {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self; entry.representedObject = captured; menu.addItem(entry)
    }
    return menu
  }
  @objc private func removeReference(_ sender: Any?) {
    guard let owner = menuOwner(sender), owner.inlineMedia.model?.state.attachments.contains(item.record) == true else { return }
    owner.inlineMedia.attachmentRemoval?()
  }
  @objc private func copyReference(_ sender: Any?) { menuOwner(sender)?.copy(sender) }
  @objc private func cutReference(_ sender: Any?) {
    guard let owner = menuOwner(sender), owner.isEditable else { return }
    owner.cut(sender)
  }
  @objc private func exportOriginal(_ sender: Any?) {
    guard let owner = menuOwner(sender), let model = owner.inlineMedia.model else { return }
    let record = item.record, file = item.file, vault = model.store.vault
    let panel = NSSavePanel(); panel.nameFieldStringValue = record.name
    guard panel.runModal() == .OK, let url = panel.url,
      menuOwner(sender) === owner, model.state.attachments.contains(record) else { return }
    model.exportFile(to: url) {
      let bytes: Data
      if let file { bytes = try file.verifiedBytes(for: record) }
      else { bytes = try vault.get(.attachment, id: record.id, limit: 67_108_864) }
      guard Digest.sha256(bytes) == record.rootDigest else {
        throw BoomError.stale("The exported original no longer matches its captured record.")
      }
      return bytes
    }
  }
}
