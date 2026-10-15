import AppKit
import BoomCore
import Foundation

/// Bounded presentation for either an immutable preview or the existing managed
/// native editor. A managed host never installs text or derives edit authority
/// from the preview's cached coordinates.
@MainActor final class PagedDocumentViewport: NSScrollView {
  private(set) var textView: NSTextView
  private let managedInput: PagedNativeInputOwner?
  private var sourceWindow: PagedTextWindow?
  private var coordinates: PagedWindowCoordinates?
  private var preview: (importID: UUID, windowID: UUID, ownerID: UUID, documentID: UUID)?
  private weak var observedStorage: NSTextStorage?
  private var characterVersion = UUID()
  private var acknowledgedCharacterVersion: UUID?
  private var navigationEngine: PagedTextEngineAdapter?
  private var navigationPublisher: PagedWorkspacePublisher?
  private var scrollProjection: PagedNativeLogicalWindow?
  private var scrollSnapshot: PagedNativeLogicalReadSnapshot?
  private var scrollTask: Task<Void, Never>?
  private var scrollReadCancellation: CancellationFlag?
  private struct MarkupRequest: Sendable {
    let window: PagedNativeLogicalWindow
    let source: PagedNativeLogicalReadSnapshot
    let view: NativeMediaTextView
    let version: UUID
  }
  private var requestedMarkup: MarkupRequest?
  private var markupTask: Task<Void, Never>?
  private var markupCancellation: CancellationFlag?
  private var activeMarkupRequest: MarkupRequest?
  private var deliveredMarkup: PagedNativeMarkupProjection?
  private var markupScheduled = false
  private(set) var markupFailure: Error?
  private var requestedScroll: (id: UUID, anchor: UInt64)?
  private var displayRequest = UUID()
  private var scrollSurface: PagedScrollSurface?
  private var scrollText: PagedScrollTextView?
  private var showingScroll = false
  private var closingPresentation = false
  private var presentationClosed = false
  private struct MouseSelectionGesture {
    let source: PagedNativeLogicalReadSnapshot
    let anchor: UInt64
    let affinity: PagedSelectionAffinity
    var event: NSEvent
  }
  private var mouseSelectionGesture: MouseSelectionGesture?
  private struct OrderedMousePointer {
    let id: UUID
    let source: PagedNativeLogicalSnapshot
    let output: PagedNativeLogicalWindow
    let anchor: UInt64
    let affinity: PagedSelectionAffinity
    var selection: PagedNativeNavigationSelection
    var released = false
  }
  private var orderedMousePointer: OrderedMousePointer?
  private var mouseAutoscrollTimer: Timer?
  private var handedOffMouseDown: NSEvent?
  private(set) var presentationFailure: Error?
  var visibleScrollWindow: PagedNativeLogicalWindow? { showingScroll ? scrollProjection : nil }
  var visibleScrollMarkup: ProductCore.MarkupProjection? { showingScroll ? scrollText?.markupProjection : nil }
  var residentScrollWindowCount: Int { scrollProjection == nil ? 0 : 1 }
  var isMouseAutoscrolling: Bool { mouseAutoscrollTimer?.isValid == true }
  var hasPendingPresentationRead: Bool { scrollTask != nil }
  var didRejectPresentation: ((Error) -> Void)?

  override init(frame: NSRect) {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    manager.allowsNonContiguousLayout = true
    let container = NSTextContainer(size: NSSize(width: max(1, frame.width), height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(manager); manager.addTextContainer(container)
    textView = NSTextView(frame: NSRect(origin: .zero, size: frame.size), textContainer: container)
    managedInput = nil
    super.init(frame: frame)
    textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
    textView.drawsBackground = false; textView.font = NSFont.systemFont(ofSize: 17)
    textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 16, height: 16)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    container.widthTracksTextView = true; container.heightTracksTextView = false
    textView.writingToolsBehavior = .none
    configureScrollView()
    observeStorage()
  }
  init(frame: NSRect, input: PagedNativeInputOwner) throws {
    guard let view = input.activeView, let binding = view.inputBinding,
      binding.owner === input, binding.state == .active,
      binding.identity == input.activeIdentity,
      binding.identity.arenaID == input.session.arenaID,
      view.inputCommandIsClosed, !view.hasMarkedText(), input.firstRefusal == nil else {
      throw BoomError.stale("The viewport has no active managed native client.")
    }
    textView = view; managedInput = input
    super.init(frame: frame)
    configureScrollView()
    configureManagedLayout(view)
    observeStorage()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { NotificationCenter.default.removeObserver(self) }

  private func configureScrollView() {
    drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = false
    documentView = textView
  }

  /// The existing InputOwner calls this only after consuming its real source
  /// installation. Reuse leaves this host and its actual view unchanged.
  func mountManagedView(from old: PagedNativeTextView, to new: PagedNativeTextView) throws {
    guard let input = managedInput, textView === old, documentView === old,
      input.activeView === new, new.inputBinding?.owner === input,
      new.inputBinding?.state == .active, new.inputBinding?.identity == input.activeIdentity,
      new.inputBinding?.identity.arenaID == input.session.arenaID,
      window === old.window else {
      throw BoomError.stale("The viewport replacement has another managed source or host.")
    }
    if old === new {
      // Only the existing lexical installation can change this stable view's
      // projection. InputOwner already retired the actual old binding/storage.
      guard input.isAdopting else { throw BoomError.stale("A stable view rebind has no source installation.") }
    } else {
      guard old.inputBinding?.owner === input, old.inputBinding?.state == .retired else {
        throw BoomError.stale("A replaced physical view has not retired its original source.")
      }
    }
    let sourceWindow = old.window
    let ownsFocus = sourceWindow?.firstResponder === old
    textView = new; self.sourceWindow = nil; coordinates = nil; preview = nil
    if documentView !== new { documentView = new }
    // The actual source install is about to expose this native surface. Keep
    // ready display pixels/geometry through the exact-window transfer below.
    new.inlineMedia.setCovered(false)
    if let display = scrollText, let projection = display.currentDerivedMarkup(for: input.session.logicalWindow) {
      // The existing ticket installed this EXACT already-visible source
      // window. Reuse its proved arrays and ready immutable media metrics
      // before sizing/hit checks; no reader/save/parse await occurs at mount.
      guard new.installDerivedMarkup(projection, for: input.session.logicalWindow,
        sourceVersion: new.sourceVersion, readyDisplay: display.inlineMedia) else {
        throw BoomError.stale("The adopted native window did not receive its exact displayed Markdown context.")
      }
    }
    configureManagedLayout(new)
    observeStorage()
    revealEditableWindow()
    guard documentView === new, new.window === sourceWindow else {
      throw BoomError.stale("The managed view did not join its original physical host.")
    }
    if ownsFocus {
      guard let sourceWindow else { throw BoomError.unavailable("The managed view lost its original native window.") }
      if sourceWindow.firstResponder !== new {
        guard sourceWindow.makeFirstResponder(new) else {
          throw BoomError.unavailable("The managed view could not retain its original native focus.")
        }
      }
      guard sourceWindow.firstResponder === new else {
        throw BoomError.unavailable("The managed view did not retain its original native focus.")
      }
    }
  }

  /// The normal graph supplies its EXISTING Engine/Publisher. One visible
  /// immutable window may be held beside its caret island; there is no second
  /// source cache, storage executor, root authority or virtual document String.
  func enableDocumentNavigation(engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher) throws {
    guard let input = managedInput, navigationEngine == nil, navigationPublisher == nil,
      !presentationClosed, engine.ownerID == publisher.ownerID,
      publisher.ownerID == input.session.logicalWindow.snapshot.sourceRevision.ownerID else {
      throw BoomError.denied("Document navigation requires its existing exact storage/input owners.")
    }
    try input.installDocumentNavigation(key: { [weak self] event, view in
      self?.interceptBoundaryKey(event, view: view) ?? false
    }, command: { [weak self] selector, observed in
      guard let self else { throw BoomError.stale("The document viewport has retired.") }
      try self.moveDocument(selector, observed: observed)
    })
    navigationEngine = engine; navigationPublisher = publisher
    verticalScroller?.target = self; verticalScroller?.action = #selector(scrollDocument(_:))
    try updateDocumentScroller()
    requestMarkup()
  }

  /// Source notification precedes the actual outer Cocoa close. Capture on
  /// its following Main turn, never inside a character/adoption primitive.
  /// New keys coalesce only derived requests; native edits are never queued.
  private func requestMarkup() {
    guard !markupScheduled, !closingPresentation, !presentationClosed else { return }
    markupScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.markupScheduled = false
      guard !self.closingPresentation, !self.presentationClosed,
        let input = self.managedInput, self.navigationEngine != nil,
        let native = input.activeView, native.inputCommandIsClosed,
        !native.boundedStorage.hasOpenCharacterTransaction else { return }
      do {
        let captured = try input.session.captureLogicalState()
        let window: PagedNativeLogicalWindow
        let view: NativeMediaTextView
        if self.showingScroll, let visible = self.scrollProjection, let scroll = self.scrollText {
          window = visible; view = scroll
        } else { window = input.session.logicalWindow; view = native }
        guard window.snapshot.isSame(captured.source) else { return }
        if let active = self.activeMarkupRequest, active.window.snapshot.rootID != window.snapshot.rootID {
          // Stop obsolete-source indexing at its next bounded step. Its proved
          // prefix already resides in the same two-slot convergence memo.
          self.markupCancellation?.cancel()
        }
        self.requestedMarkup = MarkupRequest(window: window, source: captured, view: view, version: view.sourceVersion)
        self.startMarkupTask()
      } catch { self.markupFailure = error }
    }
  }
  private func startMarkupTask() {
    guard markupTask == nil, let engine = navigationEngine, let input = managedInput else { return }
    markupTask = Task { [self] in
      defer { markupTask = nil; markupCancellation = nil; activeMarkupRequest = nil }
      while let request = requestedMarkup, !Task.isCancelled, !closingPresentation, !presentationClosed {
        requestedMarkup = nil
        let cancellation = CancellationFlag()
        markupCancellation = cancellation
        activeMarkupRequest = request
        do {
          // Pending requests retain cheap logical handles only. Seal the one
          // current tail only when this worker actually accepts its handoff,
          // never for every notification while an older index is running.
          guard input.session.isCurrent(request.source) else { continue }
          let frozen = try input.session.captureLogicalRead()
          guard frozen.source.isSame(request.window.snapshot) else { continue }
          let projection = try await engine.logicalMarkup(request.window, cancellation: cancellation,
            latestWindow: { [weak self] in self?.latestMarkupWindow() }) { [weak self] mode, value in
            guard let self, let actual = self.activeMarkupRequest else { return }
            self.receiveMarkupMode(value, mode: mode, request: actual)
          }
          if let actual = activeMarkupRequest { applyMarkup(projection, request: actual) }
        } catch is CancellationError {
          // Intentional cancellation has no new display failure. An ordinary
          // error may also cancel its sibling, but remains the primary error.
        } catch {
          let current = activeMarkupRequest ?? request
          if !Task.isCancelled, !closingPresentation, !presentationClosed,
            input.session.isCurrent(current.source) {
            markupFailure = error
          }
        }
      }
    }
  }
  /// Main only: accept one latest target of the SAME source. The producer's
  /// next joined quantum rebinds its derived query and retains its builder.
  private func latestMarkupWindow() -> PagedNativeLogicalWindow? {
    guard !closingPresentation, !presentationClosed, let input = managedInput,
      let active = activeMarkupRequest else { markupCancellation?.cancel(); return nil }
    if let requested = requestedMarkup {
      guard requested.window.snapshot.isSame(active.window.snapshot) else {
        markupCancellation?.cancel(); return nil
      }
      guard input.session.isCurrent(requested.source) else { requestedMarkup = nil; return active.window }
      do {
        let frozen = try input.session.captureLogicalRead()
        guard frozen.source.isSame(requested.window.snapshot) else { markupCancellation?.cancel(); return nil }
        activeMarkupRequest = requested; requestedMarkup = nil
        return requested.window
      } catch {
        markupFailure = error; markupCancellation?.cancel(); return nil
      }
    }
    guard input.session.isCurrent(active.source) else { markupCancellation?.cancel(); return nil }
    return active.window
  }
  private func receiveMarkupMode(_ value: PagedNativeMarkupProjection.Mode, mode: UInt8, request: MarkupRequest) {
    guard value.matches(request.window), mode <= 1 else { return }
    let prior = deliveredMarkup.flatMap { $0.matches(request.window) ? $0 : nil }
    let literal = PagedNativeMarkupProjection.Mode.literal(request.window)
    let projection = PagedNativeMarkupProjection(style: mode == 0 ? value : (prior?.style ?? literal),
      media: mode == 1 ? value : (prior?.media ?? literal))
    applyMarkup(projection, request: request)
  }
  private func applyMarkup(_ projection: PagedNativeMarkupProjection, request: MarkupRequest) {
    guard !Task.isCancelled, !closingPresentation, !presentationClosed, let input = managedInput,
      input.session.isCurrent(request.source), request.view.sourceVersion == request.version,
      projection.matches(request.window) else { return }
    markupFailure = nil
    if let native = request.view as? PagedNativeTextView, native === input.activeView {
      if native.installDerivedMarkup(projection, for: request.window, sourceVersion: request.version) {
        deliveredMarkup = projection
      }
    } else if let scroll = request.view as? PagedScrollTextView, scroll === scrollText,
      showingScroll, scrollProjection?.windowID == request.window.windowID {
      if scroll.installDerivedMarkup(projection, for: request.window, sourceVersion: request.version) {
        scroll.sizeToFit()
      }
      deliveredMarkup = projection
    }
  }
  /// Explicit component/display admission only. Ordinary scrolling joins its
  /// independent copied window and never waits for a cold annotation scan.
  func joinMarkup() async {
    if markupScheduled {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    if let task = markupTask { await task.value }
  }

  private func configureManagedLayout(_ view: PagedNativeTextView) {
    view.documentViewport = self
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.size = NSSize(width: max(1, contentSize.width), height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.setFrameSize(NSSize(width: max(1, contentSize.width), height: max(1, contentSize.height)))
    // This is the real bounded island. It never represents the whole document's
    // pixel height, and resizing it cannot request document-sized layout.
    view.sizeToFit()
  }
  override func layout() {
    let trace = managedInput == nil ? nil : PerformanceTrace.begin("Editor.ManagedLayout",
      event: (textView as? PagedNativeTextView)?.performanceEvent ?? 0)
    defer { PerformanceTrace.end("Editor.ManagedLayout", trace) }
    super.layout()
    scrollSurface?.frame = contentView.frame
    guard managedInput != nil else { return }
    if textView.frame.width != contentSize.width { textView.setFrameSize(NSSize(width: max(1, contentSize.width), height: textView.frame.height)) }
    if navigationEngine != nil {
      verticalScroller?.target = self; verticalScroller?.action = #selector(scrollDocument(_:))
      do { try updateDocumentScroller() } catch { failPresentation(error) }
    }
  }
  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    guard navigationEngine != nil else { return }
    do { try updateDocumentScroller() } catch { failPresentation(error) }
  }
  override func scrollWheel(with event: NSEvent) {
    guard navigationEngine != nil else { super.scrollWheel(with: event); return }
    if showingScroll, let scrollSurface {
      scrollSurface.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
      didScrollLocally(event, surface: self, view: textView)
    }
  }
  private func visibleUTF16(in view: NSTextView, surface: NSScrollView, atBottom: Bool = false) -> Int {
    guard let manager = view.layoutManager, let container = view.textContainer,
      manager.numberOfGlyphs > 0 else { return 0 }
    let point = NSPoint(x: max(0, surface.contentView.bounds.minX - view.textContainerOrigin.x),
      y: max(0, (atBottom ? surface.contentView.bounds.maxY : surface.contentView.bounds.minY) - view.textContainerOrigin.y))
    let glyph = manager.glyphIndex(for: point, in: container)
    return min(view.textStorage?.length ?? 0, manager.characterIndexForGlyph(at: min(glyph, manager.numberOfGlyphs - 1)))
  }
  private func updateDocumentScroller() throws {
    guard let input = managedInput, let scroller = verticalScroller,
      input.activeView?.inputCommandIsClosed == true else { return }
    let position = try input.session.documentCoordinates()
    let start: UInt64
    let local: Int
    if showingScroll, let projection = scrollProjection, let surface = scrollSurface, let view = scrollText {
      start = projection.start.utf16; local = visibleUTF16(in: view, surface: surface)
    } else { start = position.utf16Start; local = visibleUTF16(in: textView, surface: self) }
    let top = start.addingReportingOverflow(UInt64(local))
    guard !top.overflow else { throw BoomError.budget("Document scroll coordinate overflowed.") }
    let total = position.projectedUTF16
    scroller.doubleValue = total == 0 ? 0 : min(1, Double(top.partialValue) / Double(total))
    // Source progress has no invented document pixel geometry. The knob uses
    // this actual bounded island's share of UTF16 source extent.
    let units = showingScroll ? (scrollText?.textStorage?.length ?? 0) : position.localUTF16
    scroller.knobProportion = total == 0 ? 1 : min(1, CGFloat(Double(units) / Double(total)))
    scroller.isEnabled = total > UInt64(units)
  }
  @objc private func scrollDocument(_ sender: NSScroller) {
    guard let input = managedInput else { return }
    do {
      let coordinates = try input.session.documentCoordinates()
      let total = coordinates.projectedUTF16
      if sender.hitPart == .incrementPage || sender.hitPart == .decrementPage {
        let surface: NSScrollView
        let view: NSTextView
        if showingScroll, let projectedSurface = scrollSurface, let projectedView = scrollText {
          surface = projectedSurface; view = projectedView
        } else { surface = self; view = textView }
        let start = showingScroll ? (scrollProjection?.start.utf16 ?? coordinates.utf16Start) : coordinates.utf16Start
        let local = visibleUTF16(in: view, surface: surface)
        let step = UInt64(max(1, visibleUTF16(in: view, surface: surface, atBottom: true) - local))
        let top = start.addingReportingOverflow(UInt64(local))
        guard !top.overflow else { throw BoomError.budget("Document scroll coordinate overflowed.") }
        if sender.hitPart == .decrementPage { try requestScroll(toUTF16: top.partialValue > step ? top.partialValue - step : 0) }
        else {
          let next = top.partialValue.addingReportingOverflow(step)
          guard !next.overflow else { throw BoomError.budget("Document page coordinate overflowed.") }
          try requestScroll(toUTF16: min(total, next.partialValue))
        }
        return
      }
      let fraction = max(0, min(1, sender.doubleValue))
      // Double is used only for user scrollbar positioning. Tree admission
      // below returns the actual integer scalar coordinate; it is not a source
      // identity or exact aggregate calculation.
      let approximation = Double(total) * fraction
      let requested = fraction == 1 || approximation >= Double(UInt64.max) ? total : min(total, UInt64(approximation))
      try requestScroll(toUTF16: requested)
    } catch { failPresentation(error) }
  }
  private func didScrollLocally(_ event: NSEvent, surface: NSScrollView, view: NSTextView) {
    do {
      try updateDocumentScroller()
      guard let input = managedInput, event.scrollingDeltaY != 0 else { return }
      let position = try input.session.documentCoordinates()
      let start = showingScroll ? (scrollProjection?.start.utf16 ?? position.utf16Start) : position.utf16Start
      let bottom = max(0, view.frame.height - surface.contentSize.height)
      let atTop = surface.contentView.bounds.minY <= 0
      let atBottom = surface.contentView.bounds.minY >= bottom
      let visibleTop = visibleUTF16(in: view, surface: surface)
      let step = UInt64(max(1, visibleUTF16(in: view, surface: surface, atBottom: true) - visibleTop))
      if event.scrollingDeltaY > 0, atTop, start > 0 {
        try requestScroll(toUTF16: start > step ? start - step : 0)
      } else if event.scrollingDeltaY < 0, atBottom {
        let top = start.addingReportingOverflow(UInt64(visibleTop))
        guard !top.overflow else { throw BoomError.budget("Visible source coordinate overflowed.") }
        let next = top.partialValue.addingReportingOverflow(step)
        guard !next.overflow, next.partialValue < position.projectedUTF16 else { return }
        try requestScroll(toUTF16: next.partialValue)
      }
    } catch { failPresentation(error) }
  }
  func requestScroll(toUTF16 requested: UInt64) throws {
    guard let input = managedInput, navigationEngine != nil, navigationPublisher != nil,
      !closingPresentation, !presentationClosed,
      input.activeView?.inputCommandIsClosed == true else {
      throw BoomError.stale("The viewport is closing or its native character transaction is still open.")
    }
    let extent = try input.session.documentCoordinates().projectedUTF16
    presentationFailure = nil
    displayRequest = UUID()
    requestedScroll = (displayRequest, min(requested, extent))
    scrollReadCancellation?.cancel()
    startScrollTask()
  }
  private func startScrollTask() {
    guard scrollTask == nil, let input = managedInput, navigationEngine != nil else { return }
    scrollTask = Task { [self] in
      defer { scrollTask = nil; scrollReadCancellation = nil }
      while true {
        // Keep the current bounded reading window painted while its successor
        // is read. Revealing the unrelated caret island here causes a visible
        // jump on every window boundary. Input/rebind explicitly hides this
        // surface; only that path releases its projection before a new read.
        if scrollProjection != nil, !showingScroll {
          scrollProjection = nil; scrollSnapshot = nil
        }
        guard let request = requestedScroll else { break }
        requestedScroll = nil
        var captured: PagedNativeLogicalReadSnapshot?
        do {
          let snapshot = try mouseSelectionGesture?.source ?? input.session.captureLogicalRead()
          captured = snapshot
          let trace = PerformanceTrace.begin("Editor.SourceRead")
          let output: PagedNativeLogicalWindow
          do {
            let cancellation = CancellationFlag()
            scrollReadCancellation = cancellation
            defer { scrollReadCancellation = nil }
            defer { PerformanceTrace.end("Editor.SourceRead", trace) }
            output = try await input.session.readLogicalPresentation(snapshot, utf16Anchor: request.anchor,
              maximumBytes: PagedWorkingWindow.targetBytes, cancellation: cancellation)
          }
          // Saving an identical generation does not change the displayed text.
          // Actual later input or a different arena supersedes this read.
          guard displayRequest == request.id, input.session.isCurrent(snapshot) else { continue }
          scrollProjection = output; scrollSnapshot = snapshot
          try showScrollSurface(output, anchor: request.anchor)
          if let gesture = mouseSelectionGesture {
            try updateMouseSelection(gesture.event)
          }
        } catch {
          // An obsolete read cannot disable newer scrolling or native input.
          guard displayRequest == request.id, captured.map({ input.session.isCurrent($0) }) != false else { continue }
          hideScrollSurface()
          scrollProjection = nil; scrollSnapshot = nil
          failPresentation(error)
        }
      }
    }
  }
  private func showScrollSurface(_ window: PagedNativeLogicalWindow, anchor: UInt64) throws {
    guard window.summary.bytes <= UInt64(PagedWorkingWindow.targetBytes) else {
      throw BoomError.budget("The logical scroll window exceeds its display bound.")
    }
    if scrollSurface == nil {
      let storage = NSTextStorage(), manager = NSLayoutManager()
      manager.allowsNonContiguousLayout = true
      let container = NSTextContainer(size: NSSize(width: max(1, contentSize.width), height: CGFloat.greatestFiniteMagnitude))
      storage.addLayoutManager(manager); manager.addTextContainer(container)
      let view = PagedScrollTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
      view.isEditable = false; view.isSelectable = true; view.isRichText = false
      view.drawsBackground = true; view.backgroundColor = textView.backgroundColor
      view.font = textView.font ?? NSFont.systemFont(ofSize: 17); view.textContainerInset = textView.textContainerInset
      view.isVerticallyResizable = true; view.isHorizontallyResizable = false
      view.autoresizingMask = [.width]
      view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      container.widthTracksTextView = true; container.heightTracksTextView = false
      view.writingToolsBehavior = .none
      view.clicked = { [weak self] event in self?.selectScrollPoint(event) }
      view.dragged = { [weak self] event in
        guard let self else { return }
        if orderedMousePointer != nil { updateOrderedMousePointer(event, released: false) }
        else { managedInput?.activeView?.mouseDragged(with: event) }
      }
      view.lifted = { [weak self] event in
        guard let self else { return }
        if orderedMousePointer != nil { updateOrderedMousePointer(event, released: true) }
        else { managedInput?.activeView?.mouseUp(with: event) }
      }
      view.copied = { [weak self] sender in self?.managedInput?.activeView?.copy(sender) }
      let surface = PagedScrollSurface(frame: contentView.frame)
      surface.drawsBackground = false; surface.hasVerticalScroller = false; surface.hasHorizontalScroller = false
      surface.documentView = view
      surface.scrolled = { [weak self, weak view, weak surface] event in
        if let self, let view, let surface { self.didScrollLocally(event, surface: surface, view: view) }
      }
      addSubview(surface, positioned: .above, relativeTo: contentView)
      scrollSurface = surface; scrollText = view
    }
    guard let surface = scrollSurface, let view = scrollText else { throw BoomError.unavailable("Bounded scroll surface could not be constructed.") }
    view.completeMarkupContext = window.start.utf16 == 0 && window.summary.utf16 == window.snapshot.summary.utf16
    view.string = window.text
    view.setMedia(model: (textView as? NativeMediaTextView)?.inlineMedia.model)
    view.setFrameSize(NSSize(width: max(1, contentSize.width), height: max(1, contentSize.height)))
    // Share the editor's bounded paragraph metrics and wrapping. A partial
    // source remains explicitly partial; it is never parsed as a full file.
    MarkdownStyle.apply(to: view)
    view.sizeToFit()
    surface.contentView.scroll(to: .zero); surface.isHidden = false; showingScroll = true
    (textView as? NativeMediaTextView)?.inlineMedia.setCovered(true)
    view.inlineMedia.viewportDidChange()
    if !window.text.isEmpty {
      guard anchor >= window.start.utf16, anchor - window.start.utf16 <= window.summary.utf16,
        let manager = view.layoutManager, let container = view.textContainer else {
        throw BoomError.stale("Scrolling lost its actual displayed source anchor.")
      }
      var local = Int(anchor - window.start.utf16)
      // A scrollbar fraction may name the low half of a surrogate pair.
      // Floor only that generated coordinate in the already-read window;
      // explicit source endpoints still require their exact scalar proof.
      let units = window.text as NSString
      if local > 0, local < units.length,
        (0xDC00...0xDFFF).contains(units.character(at: local)),
        (0xD800...0xDBFF).contains(units.character(at: local - 1)) {
        local -= 1
      }
      _ = try window.position(localUTF16: local)
      manager.ensureLayout(for: container)
      let glyph = manager.glyphIndexForCharacter(at: min(local, max(0, view.string.utf16.count - 1)))
      let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let origin = NSPoint(x: 0, y: max(0, rect.minY + view.textContainerOrigin.y))
      surface.contentView.scroll(to: surface.contentView.constrainBoundsRect(
        NSRect(origin: origin, size: surface.contentView.bounds.size)).origin)
      surface.reflectScrolledClipView(surface.contentView)
    }
    try updateDocumentScroller()
    requestMarkup()
  }
  private func selectScrollPoint(_ event: NSEvent) {
    do {
      guard let display = scrollText, let surface = scrollSurface,
        let input = managedInput, let native = input.activeView, let window = self.window,
        event.type == .leftMouseDown, event.windowNumber == window.windowNumber,
        display.window === window, native.window === window,
        display.layoutManager != nil, display.textContainer != nil else {
        throw BoomError.stale("The visible source window has no bounded native layout.")
      }
      if input.commandOwner?.hasPendingCommand == true {
        try beginOrderedMousePointer(event, display: display, input: input, native: native)
        return
      }
      let extending = event.modifierFlags.contains(.shift)
      let anchor: UInt64?
      if extending { anchor = try input.currentDocumentSelection().anchorUTF16 }
      else { anchor = nil }
      let local = display.characterIndexForInsertion(at: display.convert(event.locationInWindow, from: nil))
      let origin = surface.contentView.bounds.origin
      try selectVisibleUTF16(local, extending: extending, installingDisplay: true, mouseDown: event)
      // Mount exactly the window that supplied the hit, with its real clip
      // origin. No synthetic event or source authority comes from pixel identity.
      contentView.scroll(to: contentView.constrainBoundsRect(
        NSRect(origin: origin, size: contentView.bounds.size)).origin)
      reflectScrolledClipView(contentView)
      guard input.activeView === native, textView === native,
        native.characterIndexForInsertion(at: native.convert(event.locationInWindow, from: nil)) == local,
        window.isKeyWindow, window.firstResponder === native else {
        throw BoomError.stale("The native mouse handoff did not preserve its displayed source geometry.")
      }
      handedOffMouseDown = event
      defer { handedOffMouseDown = nil }
      let coordinates = try input.session.documentCoordinates()
      let usesNativeTracking = event.clickCount != 1 || !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        || coordinates.utf16Start == 0 && UInt64(coordinates.localUTF16) == coordinates.projectedUTF16
      if let anchor, usesNativeTracking {
        try input.withDocumentMouseSelection(anchorUTF16: anchor) { native.mouseDown(with: event) }
      } else { native.mouseDown(with: event) }
    } catch { failPresentation(error) }
  }
  /// Paint the captured intent only on its immutable display while earlier
  /// navigation/keys keep the actual Input selection and their exact leases.
  private func beginOrderedMousePointer(_ event: NSEvent, display: NSTextView,
    input: PagedNativeInputOwner, native: PagedNativeTextView) throws {
    guard orderedMousePointer == nil, event.clickCount == 1,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let owner = input.commandOwner, owner.canOrderPointerAfterNavigation,
      let read = scrollSnapshot, let output = scrollProjection, input.session.isCurrent(read),
      output.snapshot.isSame(read.source), let window = native.window, window.isKeyWindow,
      window.firstResponder === native else {
      throw BoomError.stale("The pointer has no ordered source-neutral navigation consumer.")
    }
    let local = display.characterIndexForInsertion(at: display.convert(event.locationInWindow, from: nil))
    let focus = try output.position(localUTF16: local).utf16
    let original = try input.currentDocumentSelection()
    let anchor = event.modifierFlags.contains(.shift) ? original.anchorUTF16 : focus
    let selected = PagedNativeNavigationSelection(utf16Offset: min(anchor, focus),
      utf16Length: max(anchor, focus) - min(anchor, focus), focusAtEnd: focus >= anchor,
      affinity: original.affinity)
    let id = try owner.beginOrderedDocumentPointer(read, selection: selected,
      extending: event.modifierFlags.contains(.shift), mouseDown: event, from: native) { [weak self] id in
      guard let self, orderedMousePointer?.id == id else { return }
      orderedMousePointer = nil
      revealEditableWindow()
      if let selection = try? input.currentDocumentSelection(),
        selection.focusUTF16 >= input.session.logicalWindow.start.utf16,
        let local = Int(exactly: selection.focusUTF16 - input.session.logicalWindow.start.utf16),
        local >= 0, local <= input.session.logicalWindow.text.utf16.count {
        input.activeView?.scrollRangeToVisible(NSRange(location: local, length: 0))
      }
    }
    orderedMousePointer = OrderedMousePointer(id: id, source: read.source, output: output,
      anchor: anchor, affinity: selected.affinity, selection: selected)
    paintOrderedMousePointer(selected, output: output, display: display)
  }
  private func paintOrderedMousePointer(_ selected: PagedNativeNavigationSelection,
    output: PagedNativeLogicalWindow, display: NSTextView) {
    let end = output.start.utf16 + output.summary.utf16
    let lower = min(end, max(output.start.utf16, selected.utf16Offset))
    let upper = min(end, max(lower, selected.utf16Offset + selected.utf16Length))
    display.setSelectedRange(NSRange(location: Int(lower - output.start.utf16), length: Int(upper - lower)))
  }
  func continueOrderedDocumentMouseSelection(_ event: NSEvent, in view: PagedNativeTextView,
    released: Bool) -> Bool {
    guard orderedMousePointer?.released == false, managedInput?.activeView === view else { return false }
    updateOrderedMousePointer(event, released: released); return true
  }
  private func updateOrderedMousePointer(_ event: NSEvent, released: Bool) {
    do {
      guard var pointer = orderedMousePointer, !pointer.released,
        event.type == (released ? .leftMouseUp : .leftMouseDragged),
        let display = scrollText, showingScroll, let input = managedInput,
        let window = self.window, event.windowNumber == window.windowNumber,
        window.isKeyWindow, window.firstResponder === input.activeView,
        input.session.logicalWindow.snapshot.isSame(pointer.source) else {
        throw BoomError.stale("The ordered pointer left its captured source or physical focus.")
      }
      let local = display.characterIndexForInsertion(at: display.convert(event.locationInWindow, from: nil))
      let focus = try pointer.output.position(localUTF16: local).utf16
      let selection = PagedNativeNavigationSelection(utf16Offset: min(pointer.anchor, focus),
        utf16Length: max(pointer.anchor, focus) - min(pointer.anchor, focus), focusAtEnd: focus >= pointer.anchor,
        affinity: pointer.affinity)
      pointer.selection = selection; pointer.released = released; orderedMousePointer = pointer
      paintOrderedMousePointer(selection, output: pointer.output, display: display)
      guard let owner = input.commandOwner else { throw BoomError.stale("Ordered pointer lost its actual input owner.") }
      try owner.updateOrderedDocumentPointer(pointer.id, source: pointer.source, selection: selection,
        completing: released)
    } catch { failPresentation(error) }
  }

  /// The accessibility/mouse consumer names a real scalar in this currently
  /// displayed window. It cannot authorize an earlier root or a half surrogate.
  func selectVisibleUTF16(_ local: Int, extending: Bool = false) throws {
    try selectVisibleUTF16(local, extending: extending, installingDisplay: false, mouseDown: nil)
  }
  private func selectVisibleUTF16(_ local: Int, extending: Bool, installingDisplay: Bool, mouseDown: NSEvent?) throws {
    guard let input = managedInput, showingScroll, let output = scrollProjection,
      let snapshot = scrollSnapshot, let owner = input.commandOwner else {
      throw BoomError.stale("The scroll projection has no current editable consumer.")
    }
    let current = try input.session.documentCoordinates()
    guard input.session.isCurrent(snapshot) else { throw BoomError.stale("The visible projection has an earlier native edit generation.") }
    _ = try output.position(localUTF16: local)
    let absolute = output.start.utf16.addingReportingOverflow(UInt64(local))
    guard !absolute.overflow else { throw BoomError.budget("Scroll selection coordinate overflowed.") }
    let anchor = absolute.partialValue > 4096 ? absolute.partialValue - 4096 : 0
    // The read surface never becomes a keyboard client. An explicit selection
    // acquires the actual editable client before navigation captures its lease.
    guard let view = input.activeView, textView === view,
      let window = view.window, self.window === window, window.isKeyWindow,
      window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.stale("The visible selection could not focus its actual editable client.")
    }
    let selection: PagedNativeNavigationSelection
    if extending {
      let original = try input.currentDocumentSelection(), fixed = original.anchorUTF16
      selection = PagedNativeNavigationSelection(utf16Offset: min(fixed, absolute.partialValue),
        utf16Length: max(fixed, absolute.partialValue) - min(fixed, absolute.partialValue),
        focusAtEnd: absolute.partialValue >= fixed, affinity: original.affinity)
    } else { selection = PagedNativeNavigationSelection(utf16Offset: absolute.partialValue, utf16Length: 0) }
    if mouseDown != nil {
      // This exact display/source hit is a real new pointer intent. Existing
      // selection ingress cancels a superseded cold command; its task/events
      // keep their old authority and join independently of this installation.
      try input.setDocumentSelection(selection, mouseDown: mouseDown, observedWindow: output)
    }
    let nativeEnd = current.utf16Start.addingReportingOverflow(UInt64(current.localUTF16))
    if !installingDisplay, !nativeEnd.overflow, !owner.hasPendingCommand, input.session.isCurrent(snapshot),
      selection.focusUTF16 >= current.utf16Start, selection.focusUTF16 <= nativeEnd.partialValue,
      let focus = Int(exactly: selection.focusUTF16 - current.utf16Start) {
      // The copied display and this dirty native island name the SAME exact
      // source generation. Selection is not a new window or a durable grant.
      // Keep an outside Shift anchor; only its actual focus must be mounted.
      _ = try input.session.nativeSelection(NSRange(location: focus, length: 0))
      try input.setDocumentSelection(selection, observedWindow: output)
      revealEditableWindow()
      view.scrollRangeToVisible(NSRange(location: focus, length: 0))
      return
    }
    if !owner.hasPendingCommand, input.session.isCurrent(snapshot) {
      // This is the exact logical window already displayed, not authority
      // reconstructed from pixels or a saved file record. Adopt without I/O.
      try installDisplayedWindow(output, selecting: selection, input: input)
    } else {
      try owner.requestDocumentNavigation(toUTF16: anchor, selectingUTF16: selection, expected: current)
    }
    revealEditableWindow()
  }

  private func installDisplayedWindow(_ output: PagedNativeLogicalWindow,
    selecting selection: PagedNativeNavigationSelection, input: PagedNativeInputOwner) throws {
    let observed = try input.observeSelection()
    let ticket = try input.session.prepareLogicalWindowInstallation(output,
      selectingUTF16: selection, owner: input)
    do {
      try input.stageNavigation(ticket, observedSelection: observed)
      _ = try input.withStagedNavigationInstallation(ticket) { [self] old, new in
        try mountManagedView(from: old, to: new)
      }
    } catch {
      let original = error
      if !ticket.wasConsumed {
        do { try input.cancelNavigationStage(ticket) }
        catch { throw PagedNativeNavigationCleanupFailure(original: original, cleanup: error) }
      }
      throw original
    }
  }

  /// A partial document has one global range on the existing InputOwner.
  /// Actual responder events drive this bounded presentation gesture; Cocoa
  /// keeps its ordinary whole-document and multiclick tracking behavior.
  func beginDocumentMouseSelection(_ event: NSEvent, in view: PagedNativeTextView) -> Bool {
    guard event.type == .leftMouseDown, event.clickCount == 1,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let input = managedInput, input.activeView === view, textView === view,
      input.commandOwner?.hasPendingCommand == false,
      let coordinates = try? input.session.documentCoordinates(),
      coordinates.utf16Start != 0 || UInt64(coordinates.localUTF16) != coordinates.projectedUTF16 else { return false }
    do {
      guard let window = self.window, view.window === window,
        event.windowNumber == window.windowNumber, window.isKeyWindow,
        window.makeFirstResponder(view), window.firstResponder === view,
        view.inputCommandIsClosed, !view.hasMarkedText(), !input.isAdopting else {
        throw BoomError.stale("The document mouse gesture has another native source or focus.")
      }
      stopMouseSelection()
      let original = try input.currentDocumentSelection()
      let local = view.characterIndexForInsertion(at: view.convert(event.locationInWindow, from: nil))
      let focus = try input.session.logicalWindow.position(localUTF16: local).utf16
      let anchor = event.modifierFlags.contains(.shift) ? original.anchorUTF16 : focus
      let selection = PagedNativeNavigationSelection(utf16Offset: min(anchor, focus),
        utf16Length: max(anchor, focus) - min(anchor, focus), focusAtEnd: focus > anchor,
        affinity: original.affinity)
      try input.setDocumentSelection(selection, mouseDown: handedOffMouseDown === event ? nil : event)
      mouseSelectionGesture = MouseSelectionGesture(source: try input.session.captureLogicalRead(),
        anchor: anchor, affinity: selection.affinity, event: event)
    } catch { stopMouseSelection(); failPresentation(error) }
    return true
  }

  func continueDocumentMouseSelection(_ event: NSEvent, in view: PagedNativeTextView) -> Bool {
    guard mouseSelectionGesture != nil else { return false }
    do {
      guard event.type == .leftMouseDragged, managedInput?.activeView === view,
        event.windowNumber == self.window?.windowNumber else {
        throw BoomError.stale("The document drag belongs to another physical event source.")
      }
      mouseSelectionGesture?.event = event
      try advanceMouseSelection(event)
      let (_, display, _) = try mousePresentation()
      let outside = !display.visibleRect.contains(display.convert(event.locationInWindow, from: nil))
      if outside, mouseAutoscrollTimer == nil {
        let timer = Timer(timeInterval: 0.05, target: self,
          selector: #selector(scrollMouseSelection(_:)), userInfo: nil, repeats: true)
        mouseAutoscrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
      } else if !outside {
        mouseAutoscrollTimer?.invalidate(); mouseAutoscrollTimer = nil
      }
    } catch { stopMouseSelection(); failPresentation(error) }
    return true
  }

  func endDocumentMouseSelection(_ event: NSEvent, in view: PagedNativeTextView) -> Bool {
    guard let gesture = mouseSelectionGesture else { return false }
    defer { stopMouseSelection() }
    do {
      guard event.type == .leftMouseUp, let input = managedInput, input.activeView === view,
        event.windowNumber == self.window?.windowNumber, input.session.isCurrent(gesture.source) else {
        throw BoomError.stale("The document mouse release superseded its original logical source.")
      }
      try updateMouseSelection(event)
      displayRequest = UUID(); requestedScroll = nil
      scrollReadCancellation?.cancel()
      if showingScroll, let output = scrollProjection, let surface = scrollSurface {
        let origin = surface.contentView.bounds.origin
        let selection = try input.currentDocumentSelection()
        guard selection.focusUTF16 >= output.start.utf16,
          selection.focusUTF16 - output.start.utf16 <= output.summary.utf16 else {
          throw BoomError.stale("Mouse release lost its actual displayed selection focus.")
        }
        try installDisplayedWindow(output, selecting: selection, input: input)
        contentView.scroll(to: contentView.constrainBoundsRect(
          NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
      }
    } catch { failPresentation(error) }
    return true
  }

  @objc private func scrollMouseSelection(_ timer: Timer) {
    guard mouseAutoscrollTimer === timer, let gesture = mouseSelectionGesture else { return }
    do { try advanceMouseSelection(gesture.event) }
    catch { stopMouseSelection(); failPresentation(error) }
  }
  private func stopMouseSelection() {
    mouseAutoscrollTimer?.invalidate(); mouseAutoscrollTimer = nil
    if mouseSelectionGesture != nil {
      displayRequest = UUID(); requestedScroll = nil
      scrollReadCancellation?.cancel()
    }
    mouseSelectionGesture = nil
  }

  private func mousePresentation() throws -> (NSScrollView, NSTextView, PagedNativeLogicalWindow) {
    guard let gesture = mouseSelectionGesture, let input = managedInput,
      input.session.isCurrent(gesture.source), let native = input.activeView,
      let window = self.window, window.isKeyWindow, window.firstResponder === native,
      native.inputCommandIsClosed, !native.hasMarkedText(), !input.isAdopting,
      input.commandOwner?.hasPendingCommand == false,
      !closingPresentation, !presentationClosed else {
      throw BoomError.stale("The mouse gesture no longer owns its original logical source and native focus.")
    }
    if showingScroll, let surface = scrollSurface, let display = scrollText,
      let output = scrollProjection, output.snapshot.isSame(gesture.source.source) {
      return (surface, display, output)
    }
    return (self, native, input.session.logicalWindow)
  }
  private func updateMouseSelection(_ event: NSEvent) throws {
    let (surface, display, output) = try mousePresentation()
    guard let input = managedInput, let gesture = mouseSelectionGesture else { return }
    let visible = display.visibleRect, raw = display.convert(event.locationInWindow, from: nil)
    let point = NSPoint(x: min(max(raw.x, visible.minX), max(visible.minX, visible.maxX - 0.5)),
      y: min(max(raw.y, visible.minY), max(visible.minY, visible.maxY - 0.5)))
    let local = display.characterIndexForInsertion(at: point)
    let focus = try output.position(localUTF16: local).utf16
    let selection = PagedNativeNavigationSelection(utf16Offset: min(gesture.anchor, focus),
      utf16Length: max(gesture.anchor, focus) - min(gesture.anchor, focus),
      focusAtEnd: focus > gesture.anchor, affinity: gesture.affinity)
    if try input.currentDocumentSelection() != selection {
      try input.setDocumentSelection(selection, observedWindow: output)
    }
    if surface !== self {
      let start = min(output.start.utf16 + output.summary.utf16, max(output.start.utf16, selection.utf16Offset))
      let end = min(output.start.utf16 + output.summary.utf16, max(start, selection.utf16Offset + selection.utf16Length))
      let painted = NSRange(location: Int(start - output.start.utf16), length: Int(end - start))
      if display.selectedRange() != painted { display.setSelectedRange(painted) }
    }
  }
  private func advanceMouseSelection(_ event: NSEvent) throws {
    let (surface, display, output) = try mousePresentation()
    let point = display.convert(event.locationInWindow, from: nil)
    if !display.visibleRect.contains(point) {
      if let native = display as? PagedNativeTextView { _ = native.autoscrollDocumentMouseSelection(event) }
      else { _ = display.autoscroll(with: event) }
    }
    try updateMouseSelection(event)
    // One existing read task only. Retaining the latest pointer never
    // invalidates every in-flight read or allocates a document-sized view.
    guard scrollTask == nil, requestedScroll == nil else { return }
    let visible = display.visibleRect
    let bottom = max(0, display.frame.height - surface.contentSize.height)
    let top = output.start.utf16 + UInt64(visibleUTF16(in: display, surface: surface))
    let span = UInt64(max(1, visibleUTF16(in: display, surface: surface, atBottom: true)
      - visibleUTF16(in: display, surface: surface)))
    if point.y < visible.minY, surface.contentView.bounds.minY <= 0, output.start.utf16 > 0 {
      try requestScroll(toUTF16: top > span ? top - span : 0)
    } else if point.y >= visible.maxY, surface.contentView.bounds.minY >= bottom,
      top < output.snapshot.summary.utf16 {
      let next = top.addingReportingOverflow(span)
      guard !next.overflow, next.partialValue < output.snapshot.summary.utf16 else { return }
      try requestScroll(toUTF16: next.partialValue)
    }
  }
  private func moveDocument(_ selector: Selector, observed: PagedNativeSelectionObservation) throws {
    guard let input = managedInput, let owner = input.commandOwner,
      try input.observeSelection() == observed else {
      throw BoomError.stale("Document movement lost its current physical source consumer.")
    }
    let current = try input.session.documentCoordinates()
    let command = NSStringFromSelector(selector)
    if let paragraph = PagedNativeParagraphCommand(selector) {
      try owner.requestParagraphCommand(paragraph)
      revealEditableWindow(); return
    }
    if ["moveForward:", "moveBackward:", "moveLeft:", "moveRight:",
      "moveForwardAndModifySelection:", "moveBackwardAndModifySelection:",
      "moveLeftAndModifySelection:", "moveRightAndModifySelection:"].contains(command) {
      if command.hasPrefix("moveLeft") || command.hasPrefix("moveRight") {
        try owner.requestVisualGraphemeMovement(selector)
      } else {
        try owner.requestGraphemeMovement(forward: command.hasPrefix("moveForward"),
          extending: command.contains("AndModifySelection"), selection: input.currentDocumentSelection())
      }
      revealEditableWindow(); return
    }
    if selector == NSSelectorFromString("deleteBackward:") || selector == NSSelectorFromString("deleteForward:")
      || selector == NSSelectorFromString("delete:") {
      let selection = try input.currentDocumentSelection()
      if selection.utf16Length > 0 {
        try owner.requestDocumentReplacement(selection, replacement: Data(), actionName: "Delete")
      } else if command != "delete:" {
        try owner.requestGraphemeDeletion(forward: command == "deleteForward:", selection: selection)
      }
      revealEditableWindow(); return
    }
    let beginning = selector == NSSelectorFromString("moveToBeginningOfDocument:")
      || selector == NSSelectorFromString("moveToBeginningOfDocumentAndModifySelection:")
    let ending = selector == NSSelectorFromString("moveToEndOfDocument:")
      || selector == NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")
    let end = current.utf16Start.addingReportingOverflow(UInt64(current.localUTF16))
    guard !end.overflow else { throw BoomError.budget("Document command extent overflowed.") }
    let whole = current.utf16Start == 0 && end.partialValue == current.projectedUTF16
    if selector == NSSelectorFromString("selectAll:"), !whole {
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 0,
        utf16Length: current.projectedUTF16, focusAtEnd: true))
      revealEditableWindow(); return
    }
    let extending = selector == NSSelectorFromString("moveToBeginningOfDocumentAndModifySelection:")
      || selector == NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")
    if whole || !extending && (beginning && current.utf16Start == 0 || ending && end.partialValue == current.projectedUTF16) {
      // A short whole document or an already-present true document endpoint
      // uses native selection directly, with no storage job/physical swap.
      try input.activeView.performContainedDocumentCommand(selector)
      revealEditableWindow(); return
    }
    let target: UInt64 = beginning ? 0 : current.projectedUTF16
    let selected: PagedNativeNavigationSelection
    if extending {
      let original = try input.currentDocumentSelection(), anchor = original.anchorUTF16
      selected = PagedNativeNavigationSelection(utf16Offset: min(anchor, target),
        utf16Length: max(anchor, target) - min(anchor, target), focusAtEnd: target >= anchor)
    } else { selected = PagedNativeNavigationSelection(utf16Offset: target, utf16Length: 0) }
    let anchor = target > 4096 ? target - 4096 : 0
    try owner.requestDocumentNavigation(toUTF16: anchor,
      selectingUTF16: selected, expected: current)
    revealEditableWindow()
  }
  private func interceptBoundaryKey(_ event: NSEvent, view: PagedNativeTextView) -> Bool {
    guard let input = managedInput, view === input.activeView else { return false }
    revealEditableWindow()
    do {
      let current = try input.session.documentCoordinates()
      let selected = try input.currentDocumentSelection()
      let excluded = [48, 53, 115, 116, 119, 121, 123, 124, 125, 126]
      let text = event.characters ?? ""
      let inserting = !excluded.contains(Int(event.keyCode))
        && event.modifierFlags.intersection([.command, .control]).isEmpty
        && (!text.isEmpty && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
          || event.keyCode == 36 || event.keyCode == 76)
      if inserting, selected.utf16Length > UInt64(view.selectedRange().length) {
        guard let owner = input.commandOwner else { throw BoomError.stale("Selected input lost its native command owner.") }
        try owner.replaceSelectionBeforeRawKey(event, from: view, selection: selected)
        return true
      }
      // Movement/deletion/clipboard commands have their existing native or
      // full-source consumer. Near a display edge is not permission to delay
      // a character replacement that still fits the actual bounded island.
      guard inserting else { return false }
      let replacement = event.keyCode == 36 || event.keyCode == 76 ? "\n" : text
      do { try input.session.canReplace(view.selectedRange(), with: replacement); return false }
      catch {
        // Only actual reserve exhaustion needs this recenter path. Any other
        // refusal belongs to the real native primitive and its diagnostics.
        guard case BoomError.budget = error else { return false }
      }
      let bytes = try input.session.nativeLocalBytes(view.selectedRange())
      let nearLeading = bytes.lowerBound < 1024 && current.utf16Start > 0
      let end = current.utf16Start.addingReportingOverflow(UInt64(current.localUTF16))
      let nearTrailing = current.localBytes - bytes.upperBound < 1024
        && !end.overflow && end.partialValue < current.projectedUTF16
      guard !input.session.isPinned, view.inputCommandIsClosed,
        input.session.needsRecentering || nearLeading || nearTrailing else { return false }
      let anchor = selected.focusUTF16 > 4096 ? selected.focusUTF16 - 4096 : 0
      guard let owner = input.commandOwner else { throw BoomError.stale("Boundary typing has no existing native command owner.") }
      return owner.recenterBeforeRawKey(event, from: view, toUTF16: anchor)
    } catch {
      // The actual command owner retains/refuses this original key through its
      // existing bounded event lane. A presentation error never grants input.
      if let owner = input.commandOwner { owner.refuseDocumentKey(event, from: view, original: error); return true }
      failPresentation(error); return true
    }
  }
  private func hideScrollSurface() {
    showingScroll = false; scrollSurface?.isHidden = true
    (textView as? NativeMediaTextView)?.inlineMedia.setCovered(false)
    scrollText?.inlineMedia.viewportDidChange()
  }
  private func revealEditableWindow() {
    // A queued pointer is painted against its frozen source until its actual
    // chronological selection/window is delivered. Earlier mounts do not
    // erase that presentation or manufacture a newer source hit.
    guard orderedMousePointer == nil else { return }
    displayRequest = UUID(); requestedScroll = nil
    scrollReadCancellation?.cancel()
    hideScrollSurface()
    if scrollProjection != nil { startScrollTask() }
  }
  private func failPresentation(_ error: Error) {
    if presentationFailure == nil { presentationFailure = error }
    requestedScroll = nil
    didRejectPresentation?(error)
  }
  /// Waits for the actual entered read task, never a timer or guessed
  /// cancellation join. The displayed projection owns only its bounded text.
  func joinPresentation() async throws {
    if let task = scrollTask { await task.value }
    if let presentationFailure { throw presentationFailure }
  }
  /// The Model joins the actual read before backend detach. Copied display
  /// text has no pending source publication or output disposal to wait for.
  func closePresentation() async throws {
    guard !closingPresentation else { throw BoomError.stale("The viewport already has its actual close caller.") }
    if presentationClosed { return }
    closingPresentation = true
    defer { closingPresentation = false }
    // The SAME owner settles its latest captured pointer and all original
    // keyboard intent in order before the physical host can retire.
    if orderedMousePointer != nil, let owner = managedInput?.commandOwner {
      try await owner.joinPendingCommand()
    }
    stopMouseSelection()
    let nativeMedia = (textView as? NativeMediaTextView)?.inlineMedia
    let scrollMedia = scrollText?.inlineMedia
    nativeMedia?.stop(); scrollMedia?.stop()
    displayRequest = UUID(); requestedScroll = nil; hideScrollSurface()
    scrollReadCancellation?.cancel()
    requestedMarkup = nil; markupCancellation?.cancel(); markupTask?.cancel()
    if let task = scrollTask { await task.value }
    if let task = markupTask { await task.value }
    if let nativeMedia, let cleanup = await nativeMedia.joinPendingLoads() {
      didRejectPresentation?(cleanup)
    }
    if let scrollMedia, let cleanup = await scrollMedia.joinPendingLoads() {
      didRejectPresentation?(cleanup)
    }
    // Cleanup diagnostics preserve their owned URL and status; they do not
    // refuse a coherent source close or poison the next editing admission.
    scrollProjection = nil; scrollSnapshot = nil
    deliveredMarkup = nil
    presentationClosed = true
    if let native = textView as? PagedNativeTextView, native.documentViewport === self { native.documentViewport = nil }
    scrollSurface?.removeFromSuperview(); scrollSurface = nil; scrollText = nil
    didRejectPresentation = nil
  }

  func show(_ captured: PagedTextWindow, selection: Range<UInt64>? = nil) throws {
    try requirePreview()
    observeStorage()
    try requireClosedCharacters()
    // Captured window IDs belong to immutable engine output. Status/caret
    // refreshes reuse its coordinates without scanning/comparing source bytes.
    if sourceWindow?.windowID == captured.windowID, sourceWindow?.revision == captured.revision,
      acknowledgedCharacterVersion == characterVersion {
      if let selection, let coordinates { textView.setSelectedRange(try coordinates.localRange(forAbsoluteBytes: selection)) }
      return
    }
    let index = try PagedWindowCoordinates(window: captured)
    let projected = try selection.map { try index.localRange(forAbsoluteBytes: $0) }
    textView.string = captured.text
    textView.isEditable = false
    textView.sizeToFit()
    sourceWindow = captured; coordinates = index; preview = nil
    acknowledgedCharacterVersion = characterVersion
    if let projected { textView.setSelectedRange(projected) }
  }
  func showImport(_ captured: PagedTextImportPreview) throws {
    try requirePreview()
    observeStorage()
    try requireClosedCharacters()
    if let preview, preview.importID == captured.importID, preview.ownerID == captured.ownerID,
      preview.documentID == captured.documentID, preview.windowID == captured.windowID,
      acknowledgedCharacterVersion == characterVersion { return }
    try captured.validate()
    textView.string = captured.text; textView.isEditable = false
    textView.sizeToFit()
    sourceWindow = nil; coordinates = nil
    preview = (captured.importID, captured.windowID, captured.ownerID, captured.documentID)
    acknowledgedCharacterVersion = characterVersion
  }
  func selectedGlobalBytes() throws -> Range<UInt64> {
    try requireCapturedCharacters()
    guard let coordinates else { throw BoomError.denied("Partial import has no complete document selection authority.") }
    return try coordinates.absoluteByteRange(for: textView.selectedRange())
  }
  func captureEdit(in range: NSRange, replacement: String) throws -> PagedTextLocalEdit {
    try requireCapturedCharacters()
    guard let coordinates else { throw BoomError.denied("Partial import is not an editable document revision.") }
    return try coordinates.edit(in: range, replacement: replacement)
  }
  private func requireCapturedCharacters() throws {
    try requirePreview()
    observeStorage()
    try requireClosedCharacters()
    guard acknowledgedCharacterVersion == characterVersion else {
      throw BoomError.stale("Native characters changed outside their captured window.")
    }
  }
  private func requirePreview() throws {
    guard managedInput == nil else {
      throw BoomError.denied("Managed native text and selection belong to their existing storage session.")
    }
  }
  private func requireClosedCharacters() throws {
    guard !textView.hasMarkedText(), textView.textStorage?.editedMask.contains(.editedCharacters) != true else {
      throw BoomError.stale("A native composition or character transaction pins its current window.")
    }
  }
  private func observeStorage() {
    guard observedStorage !== textView.textStorage else { return }
    NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
    observedStorage = textView.textStorage
    characterVersion = UUID()
    if let storage = observedStorage {
      NotificationCenter.default.addObserver(self, selector: #selector(storageChanged(_:)),
        name: NSTextStorage.didProcessEditingNotification, object: storage)
    }
    requestMarkup()
  }
  @objc private func storageChanged(_ notification: Notification) {
    guard let storage = notification.object as? NSTextStorage, storage === observedStorage,
      storage.editedMask.contains(.editedCharacters) else { return }
    characterVersion = UUID()
    if managedInput != nil { revealEditableWindow() }
    requestMarkup()
  }
}

/// Physical read-only presentation never becomes the keyboard source. Its
/// mouse point is interpreted only against its retained immutable window.
@MainActor private final class PagedScrollTextView: MarkdownTextView {
  private var derivedMarkup: (version: UUID, windowID: UUID, value: PagedNativeMarkupProjection)?
  var completeMarkupContext = false
  override var hasCompleteMarkupContext: Bool { completeMarkupContext }
  override var markupProjection: ProductCore.MarkupProjection {
    if let derivedMarkup, derivedMarkup.version == sourceVersion {
      return derivedMarkup.value.value
    }
    return ProductCore.MarkupProjection(markdown: [], media: [], hasWikiMarker: false, hasAttachmentMarker: false)
  }
  @discardableResult func installDerivedMarkup(_ projection: PagedNativeMarkupProjection, for window: PagedNativeLogicalWindow,
    sourceVersion: UUID) -> Bool {
    guard self.sourceVersion == sourceVersion, projection.matches(window) else { return false }
    let unchanged = derivedMarkup.map {
      $0.version == sourceVersion && $0.windowID == window.windowID
        && $0.value.matches(window) && $0.value.hasSameDisplay(as: projection)
    } == true
    derivedMarkup = (sourceVersion, window.windowID, projection)
    if unchanged { return false }
    derivedMarkupDidChange()
    MarkdownStyle.apply(to: self)
    mediaChanged()
    return true
  }
  func currentDerivedMarkup(for window: PagedNativeLogicalWindow) -> PagedNativeMarkupProjection? {
    guard let derivedMarkup, derivedMarkup.version == sourceVersion,
      derivedMarkup.windowID == window.windowID, derivedMarkup.value.matches(window) else { return nil }
    return derivedMarkup.value
  }
  var clicked: ((NSEvent) -> Void)?
  var dragged: ((NSEvent) -> Void)?
  var lifted: ((NSEvent) -> Void)?
  var copied: ((Any?) -> Void)?
  override var acceptsFirstResponder: Bool { false }
  override func mouseDown(with event: NSEvent) {
    clicked?(event)
  }
  override func mouseDragged(with event: NSEvent) { dragged?(event) }
  override func mouseUp(with event: NSEvent) { lifted?(event) }
  override func copy(_ sender: Any?) {
    // The media menu already validated this display's exact storage, version,
    // range and item. Copy its original (or literal unavailable reference)
    // before considering the independent editable document selection.
    if inlineMedia.currentRanges.contains(selectedRange()) { super.copy(sender); return }
    copied?(sender)
  }
}
@MainActor private final class PagedScrollSurface: NSScrollView {
  var scrolled: ((NSEvent) -> Void)?
  override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); scrolled?(event) }
}
