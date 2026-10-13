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
  private var scrollProjection: PagedTextCustodiedValue<PagedTextWindow>?
  private var scrollRecord: PagedDocumentRootRecord?
  private var scrollCoordinates: PagedWindowCoordinates?
  private var scrollTask: Task<Void, Never>?
  private var requestedScroll: (id: UUID, anchor: UInt64)?
  private var displayRequest = UUID()
  private var scrollSurface: PagedScrollSurface?
  private var scrollText: PagedScrollTextView?
  private var showingScroll = false
  private var closingPresentation = false
  private var disposalFailure: Error?
  private var presentationClosed = false
  private(set) var presentationFailure: Error?
  var visibleScrollWindow: PagedTextWindow? { showingScroll ? scrollProjection?.value : nil }
  var retainedScrollOutputCount: Int { scrollProjection == nil ? 0 : 1 }
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
    guard let input = managedInput, old !== new, textView === old, documentView === old,
      input.activeView === new, old.inputBinding?.owner === input,
      old.inputBinding?.state == .retired, new.inputBinding?.owner === input,
      new.inputBinding?.state == .active, new.inputBinding?.identity == input.activeIdentity,
      new.inputBinding?.identity.arenaID == input.session.arenaID,
      window === old.window else {
      throw BoomError.stale("The viewport replacement has another managed source or host.")
    }
    let sourceWindow = old.window
    let ownsFocus = sourceWindow?.firstResponder === old
    textView = new; self.sourceWindow = nil; coordinates = nil; preview = nil
    documentView = new
    configureManagedLayout(new)
    observeStorage()
    revealEditableWindow()
    guard documentView === new, new.window === sourceWindow else {
      throw BoomError.stale("The managed view did not join its original physical host.")
    }
    if ownsFocus {
      guard let sourceWindow, sourceWindow.makeFirstResponder(new), sourceWindow.firstResponder === new else {
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
      publisher.ownerID == input.session.sealedRevision.ownerID else {
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
  }

  private func configureManagedLayout(_ view: PagedNativeTextView) {
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
      start = projection.value.utf16Start; local = visibleUTF16(in: view, surface: surface)
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
        let start = showingScroll ? (scrollProjection?.value.utf16Start ?? coordinates.utf16Start) : coordinates.utf16Start
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
      let start = showingScroll ? (scrollProjection?.value.utf16Start ?? position.utf16Start) : position.utf16Start
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
      !closingPresentation, !presentationClosed, presentationFailure == nil,
      input.firstRefusal == nil, input.activeView?.inputCommandIsClosed == true,
      !input.session.isPinned else {
      throw BoomError.stale("A composition, source refusal or closing viewport owns its existing window.")
    }
    let extent = try input.session.documentCoordinates().projectedUTF16
    displayRequest = UUID()
    requestedScroll = (displayRequest, min(requested, extent))
    startScrollTask()
  }
  private func startScrollTask() {
    guard scrollTask == nil, let input = managedInput, let engine = navigationEngine,
      let publisher = navigationPublisher, presentationFailure == nil else { return }
    scrollTask = Task { [self] in
      defer { scrollTask = nil }
      do {
        while true {
          if let old = scrollProjection, !showingScroll || requestedScroll != nil {
            hideScrollSurface()
            // Keep the actual carrier until the actual output release joins.
            do { try await engine.abandonJoinedRootOutput(old.lease) }
            catch { disposalFailure = error; throw error }
            scrollProjection = nil; scrollRecord = nil; scrollCoordinates = nil
          }
          guard let request = requestedScroll else { break }
          requestedScroll = nil
          let before = try input.session.documentCoordinates()
          _ = try await input.session.flush(through: before.generation)
          let captured = try input.session.documentCoordinates()
          if captured.generation != before.generation || captured.arenaID != before.arenaID
            || captured.sessionID != before.sessionID {
            // This read-only request was superseded by actual input. It never
            // owned that newer input or an output; return to the editable
            // source without relatching a harmless presentation conflict.
            hideScrollSurface(); continue
          }
          guard input.firstRefusal == nil else { throw BoomError.stale("Native input refused during scroll capture.") }
          let output = try await engine.nativeScrollWindowRetaining(publisher: publisher,
            expected: captured.record, utf16Anchor: min(request.anchor, captured.record.document.revision.summary.utf16))
          scrollProjection = output; scrollRecord = captured.record // custody before any delivery checks
          let current = try input.session.documentCoordinates()
          if displayRequest != request.id || current.record != captured.record || current.generation != captured.generation {
            hideScrollSurface()
            continue // the actual returned lease is joined/released at loop head
          }
          try showScrollSurface(output.value)
          if requestedScroll == nil { break }
        }
      } catch { failPresentation(error) }
    }
  }
  private func showScrollSurface(_ window: PagedTextWindow) throws {
    try window.validate()
    if scrollSurface == nil {
      let storage = NSTextStorage(), manager = NSLayoutManager()
      manager.allowsNonContiguousLayout = true
      let container = NSTextContainer(size: NSSize(width: max(1, contentSize.width), height: CGFloat.greatestFiniteMagnitude))
      storage.addLayoutManager(manager); manager.addTextContainer(container)
      let view = PagedScrollTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
      view.isEditable = false; view.isSelectable = false; view.isRichText = false
      view.drawsBackground = true; view.backgroundColor = textView.backgroundColor
      view.font = textView.font ?? NSFont.systemFont(ofSize: 17); view.textContainerInset = textView.textContainerInset
      view.isVerticallyResizable = true; view.isHorizontallyResizable = false
      view.autoresizingMask = [.width]
      view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      container.widthTracksTextView = true; container.heightTracksTextView = false
      view.writingToolsBehavior = .none
      view.clicked = { [weak self] point in self?.selectScrollPoint(point) }
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
    scrollCoordinates = try PagedWindowCoordinates(window: window)
    view.string = window.text; view.sizeToFit()
    surface.contentView.scroll(to: .zero); surface.isHidden = false; showingScroll = true
    try updateDocumentScroller()
  }
  private func selectScrollPoint(_ point: NSPoint) {
    do {
      guard let view = scrollText, let manager = view.layoutManager, let container = view.textContainer else {
        throw BoomError.stale("The visible source window has no bounded native layout.")
      }
      let glyph = manager.glyphIndex(for: NSPoint(x: point.x - view.textContainerOrigin.x,
        y: point.y - view.textContainerOrigin.y), in: container)
      let local = manager.numberOfGlyphs == 0 ? 0 : manager.characterIndexForGlyph(at: min(glyph, manager.numberOfGlyphs - 1))
      try selectVisibleUTF16(local)
    } catch { failPresentation(error) }
  }
  /// The accessibility/mouse consumer names a real scalar in this currently
  /// displayed window. It cannot authorize an earlier root or a half surrogate.
  func selectVisibleUTF16(_ local: Int) throws {
    guard let input = managedInput, showingScroll, let output = scrollProjection,
      let expected = scrollRecord, let index = scrollCoordinates, let owner = input.commandOwner else {
      throw BoomError.stale("The scroll projection has no current editable consumer.")
    }
    let current = try input.session.documentCoordinates()
    guard current.record == expected else { throw BoomError.stale("The visible projection has an earlier document revision.") }
    _ = try index.absoluteByteRange(for: NSRange(location: local, length: 0))
    let absolute = output.value.utf16Start.addingReportingOverflow(UInt64(local))
    guard !absolute.overflow else { throw BoomError.budget("Scroll selection coordinate overflowed.") }
    let anchor = absolute.partialValue > 4096 ? absolute.partialValue - 4096 : 0
    // The read surface never becomes a keyboard client. An explicit selection
    // acquires the actual editable client before navigation captures its lease.
    guard let view = input.activeView, textView === view,
      let window = view.window, self.window === window, window.isKeyWindow,
      window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.stale("The visible selection could not focus its actual editable client.")
    }
    try owner.requestDocumentNavigation(toUTF16: anchor,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: absolute.partialValue, utf16Length: 0), expected: current)
    revealEditableWindow()
  }
  private func moveDocument(_ selector: Selector, observed: PagedNativeSelectionObservation) throws {
    guard let input = managedInput, let owner = input.commandOwner,
      try input.observeSelection() == observed else {
      throw BoomError.stale("Document movement lost its current physical source consumer.")
    }
    let current = try input.session.documentCoordinates()
    let beginning = selector == NSSelectorFromString("moveToBeginningOfDocument:")
      || selector == NSSelectorFromString("moveToBeginningOfDocumentAndModifySelection:")
    let ending = selector == NSSelectorFromString("moveToEndOfDocument:")
      || selector == NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")
    let end = current.utf16Start.addingReportingOverflow(UInt64(current.localUTF16))
    guard !end.overflow else { throw BoomError.budget("Document command extent overflowed.") }
    let whole = current.utf16Start == 0 && end.partialValue == current.projectedUTF16
    if whole || beginning && current.utf16Start == 0 || ending && end.partialValue == current.projectedUTF16 {
      // A short whole document or an already-present true document endpoint
      // uses native selection directly, with no storage job/physical swap.
      try input.activeView.performContainedDocumentCommand(selector)
      revealEditableWindow(); return
    }
    guard selector == NSSelectorFromString("moveToBeginningOfDocument:")
      || selector == NSSelectorFromString("moveToEndOfDocument:") else {
      throw BoomError.unavailable("A cross-window selection requires the still-unactivated global range-edit route; this island is not the whole document.")
    }
    let target: UInt64 = beginning ? 0 : current.projectedUTF16
    let anchor = target > 4096 ? target - 4096 : 0
    try owner.requestDocumentNavigation(toUTF16: anchor,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: target, utf16Length: 0), expected: current)
    revealEditableWindow()
  }
  private func interceptBoundaryKey(_ event: NSEvent, view: PagedNativeTextView) -> Bool {
    guard let input = managedInput, view === input.activeView else { return false }
    revealEditableWindow()
    do {
      let current = try input.session.documentCoordinates()
      let selected = try input.session.navigationSelection(view.selectedRange())
      let bytes = try input.session.nativeLocalBytes(view.selectedRange())
      let nearLeading = bytes.lowerBound < 1024 && current.utf16Start > 0
      let end = current.utf16Start.addingReportingOverflow(UInt64(current.localUTF16))
      let nearTrailing = current.localBytes - bytes.upperBound < 1024
        && !end.overflow && end.partialValue < current.projectedUTF16
      guard !input.session.isPinned, view.inputCommandIsClosed,
        input.session.needsRecentering || nearLeading || nearTrailing else { return false }
      let anchor = selected.utf16Offset > 4096 ? selected.utf16Offset - 4096 : 0
      guard let owner = input.commandOwner else { throw BoomError.stale("Boundary typing has no existing native command owner.") }
      return owner.recenterBeforeRawKey(event, from: view, toUTF16: anchor)
    } catch {
      // The actual command owner retains/refuses this original key through its
      // existing bounded event lane. A presentation error never grants input.
      if let owner = input.commandOwner { owner.refuseDocumentKey(event, from: view, original: error); return true }
      failPresentation(error); return true
    }
  }
  private func hideScrollSurface() { showingScroll = false; scrollSurface?.isHidden = true }
  private func revealEditableWindow() {
    displayRequest = UUID(); requestedScroll = nil
    hideScrollSurface()
    if scrollProjection != nil { startScrollTask() }
  }
  private func failPresentation(_ error: Error) {
    if presentationFailure == nil { presentationFailure = error }
    requestedScroll = nil
    didRejectPresentation?(error)
  }
  /// Waits for this actual entered read/release task, never a timer or guessed
  /// cancellation join. A displayed projection still owns its real output.
  func joinPresentation() async throws {
    if let task = scrollTask { await task.value }
    if let presentationFailure { throw presentationFailure }
  }
  /// The Model joins this before physical retirement/backend detach. A failed
  /// output disposal retains the exact carrier and Engine on this same view.
  func closePresentation() async throws {
    guard !closingPresentation else { throw BoomError.stale("The viewport already has its actual close caller.") }
    if presentationClosed { return }
    closingPresentation = true
    defer { closingPresentation = false }
    displayRequest = UUID(); requestedScroll = nil; hideScrollSurface()
    if let task = scrollTask { await task.value }
    if let disposalFailure { throw disposalFailure }
    if let output = scrollProjection, let engine = navigationEngine {
      do { try await engine.abandonJoinedRootOutput(output.lease) }
      catch { disposalFailure = error; failPresentation(error); throw error }
      scrollProjection = nil; scrollRecord = nil; scrollCoordinates = nil
    }
    presentationClosed = true
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
  }
  @objc private func storageChanged(_ notification: Notification) {
    guard let storage = notification.object as? NSTextStorage, storage === observedStorage,
      storage.editedMask.contains(.editedCharacters) else { return }
    characterVersion = UUID()
    if managedInput != nil { revealEditableWindow() }
  }
}

/// Physical read-only presentation never becomes the keyboard source. Its
/// mouse point is interpreted only against its retained immutable window.
@MainActor private final class PagedScrollTextView: NSTextView {
  var clicked: ((NSPoint) -> Void)?
  override var acceptsFirstResponder: Bool { false }
  override func mouseDown(with event: NSEvent) { clicked?(convert(event.locationInWindow, from: nil)) }
}
@MainActor private final class PagedScrollSurface: NSScrollView {
  var scrolled: ((NSEvent) -> Void)?
  override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); scrolled?(event) }
}
