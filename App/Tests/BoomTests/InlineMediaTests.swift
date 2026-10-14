import AppKit
import AVFoundation
import BoomCore
import XCTest
@testable import Boom

final class InlineMediaTests: XCTestCase {
  @MainActor private static var failedDisplayCopyControls: [(WorkspaceModel, NSWindow, Error)] = []
  @MainActor private func model() async throws -> WorkspaceModel {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-inline-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
  }
  @MainActor static func image(_ color: NSColor = .systemRed) throws -> Data {
    let image = NSImage(size: NSSize(width: 720, height: 420))
    image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 720, height: 420).fill()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 70, width: 280, height: 280)).fill(); image.unlockFocus()
    let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
  @MainActor private func finish(_ model: WorkspaceModel) async throws {
    for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
    try await model.flush()
  }
  @MainActor func testMediaBelongsAtPasteLocationWithOneLayoutAcrossWidthsAndEncryptedReload() async throws {
    let model = try await model()
    let documentID = try XCTUnwrap(model.selectedDocumentID, "This actual Author component requires its selected document.")
    try await NativeCheckEvidence.replacePublicDocument(model, text: "Before 👩‍💻\nAfter", id: documentID, caret: 0)
    let insertion = NSRange(location: "Before 👩‍💻\n".utf16.count, length: 0)
    let editor = try XCTUnwrap(model.pagedInput?.activeView)
    editor.setSelectedRange(insertion)
    XCTAssertEqual(editor.selectedRange(), insertion)
    let destination = try XCTUnwrap(model.documentAttachmentDestination(id: documentID, range: insertion))
    let bytes = try Self.image()
    model.attach([.bytes(name: "Public café.png", data: bytes)], to: destination)
    try await finish(model)
    let capture = try await model.captureDocument(documentID)
    let saved = try XCTUnwrap(capture.completeSnapshot), record = try XCTUnwrap(model.state.attachments.first)
    XCTAssertTrue(saved.text.hasPrefix("Before 👩‍💻\n[Attachment:")); XCTAssertTrue(saved.text.hasSuffix("\nAfter"))
    XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), bytes)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 800, height: 900))
    window.isReleasedWhenClosed = false; defer { window.close() }
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
    view.isRichText = false; view.allowsUndo = true; view.documentUndo = UndoManager()
    window.contentView = view; view.string = saved.text; view.setMedia(model: model); MarkdownStyle.apply(to: view)
    for _ in 0..<100 where !view.subviews.contains(where: { ($0 as? InlineMediaHost)?.item.isReady == true }) { try await Task.sleep(for: .milliseconds(10)) }
    let media = try XCTUnwrap(view.subviews.compactMap { $0 as? InlineMediaHost }.first)
    let layout = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
    let measurement = NativeTextMeasurement()
    for width: CGFloat in [700, 300, 470, 700] {
      view.setFrameSize(NSSize(width: width, height: 900)); view.inlineMedia.positionViews()
      layout.ensureLayout(for: container)
      let after = (saved.text as NSString).range(of: "After")
      let glyphs = layout.glyphRange(forCharacterRange: after, actualCharacterRange: nil)
      let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
      XCTAssertGreaterThanOrEqual(rect.minY, media.frame.maxY)
      XCTAssertLessThanOrEqual(media.frame.maxX, width + 1)
      XCTAssertEqual(view.string, saved.text)
      let before = media.frame
      let height = measurement.height(of: try XCTUnwrap(view.textStorage), width: width, insets: view.textContainerInset,
        fragmentPadding: container.lineFragmentPadding)
      XCTAssertGreaterThanOrEqual(height, rect.maxY)
      XCTAssertEqual(media.frame, before, "Speculative measurement cannot move live media.")
    }
    let typingPosition = try XCTUnwrap(view.inlineMedia.spans.first).location
    view.setSelectedRange(NSRange(location: typingPosition, length: 0))
    view.insertText("Typed ", replacementRange: view.selectedRange())
    XCTAssertEqual(view.selectedRange().location, typingPosition + "Typed ".utf16.count,
      "Typing before media must not jump to its far edge using stale parsed offsets.")
    XCTAssertEqual(view.string, (saved.text as NSString).replacingCharacters(in: NSRange(location: typingPosition, length: 0), with: "Typed "))
    try XCTUnwrap(view.documentUndo).undo(); XCTAssertEqual(view.string, saved.text)
    let span = try XCTUnwrap(view.inlineMedia.spans.first)
    view.setSelectedRange(NSRange(location: span.location, length: 0))
    view.setSelectedRange(NSRange(location: span.location + 6, length: 0))
    XCTAssertEqual(view.selectedRange().location, NSMaxRange(span.range))
    view.deleteBackward(nil)
    XCTAssertEqual(view.string, "Before 👩‍💻\n\nAfter", "A pasted image deletes as one object, not one hidden bracket.")
    try XCTUnwrap(view.documentUndo).undo()
    XCTAssertEqual(view.string, saved.text)
    let reopened = try await NativeCheckEvidence.readPublicDocuments(model: model)
    XCTAssertEqual(reopened.first(where: { $0.id == saved.id }), saved)
    try await model.shutdown()
  }
  @MainActor func testAudioAndVideoPasteAreImmediatelyPlayableOriginalsWithoutRecognitionOrModelSetup() async throws {
    let model = try await model()
    if model.selectedChat == nil { try model.newChat() }
    model.draft = "Preserve my words."
    for filename in ["local-audio.m4a", "local-video.mp4"] {
      let url = try XCTUnwrap(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
      let bytes = try Data(contentsOf: url)
      model.attachToCurrentChat([.bytes(name: filename, data: bytes)])
      try await finish(model)
      let record = try XCTUnwrap(model.state.attachments.last)
      XCTAssertTrue(record.needsPreparation); XCTAssertTrue(record.text.isEmpty)
      XCTAssertEqual(record.coverage, "Original media available locally")
      XCTAssertEqual(model.draft, "Preserve my words."); XCTAssertFalse(model.showingModels)
      XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), bytes)
      XCTAssertTrue(model.selectedChat?.messages.isEmpty == true)
      _ = try MemoryMedia(bytes: bytes)
    }
    let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    let retained = try XCTUnwrap(model.state.attachments.last)
    let original = try model.store.vault.get(.attachment, id: retained.id)
    XCTAssertTrue(AttachmentInput.write(.bytes(name: retained.name, data: original), to: board))
    guard case .bytes(let name, let copied)? = AttachmentInput.read(board)?.first else { return XCTFail("Copied media lost its original.") }
    XCTAssertEqual(name, retained.name); XCTAssertEqual(copied, original)
    board.clearContents()
    XCTAssertEqual(model.pendingAttachments.count, 2)
    let captured = model.pendingAttachments
    model.authorChatMessage(.user); model.send()
    let authored = try XCTUnwrap(model.selectedChat?.messages.last)
    XCTAssertEqual(authored.directAttachments, captured); XCTAssertTrue(model.pendingAttachments.isEmpty)
    try model.replaceChatMessage("Edited words.", id: authored.id, chatID: try XCTUnwrap(model.selectedChat).id)
    XCTAssertEqual(model.selectedChat?.messages.last?.directAttachments, captured)
    try await model.flush()
    let reopened = try await model.store.loadState()
    XCTAssertEqual(reopened.chats.first(where: { $0.id == model.state.selectedChat })?.messages.last?.directAttachments, captured)
    try await model.shutdown()
  }
  @MainActor func testWritingInputCapturesOnlyMediaBeforeCaretAndUsesOriginalAudioWaveform() async throws {
    let model = try await model()
    if model.selectedChat == nil { try model.newChat() }
    model.attachToCurrentChat([.bytes(name: "public.png", data: try Self.image())]); try await finish(model)
    let image = try XCTUnwrap(model.state.attachments.first)
    let url = try XCTUnwrap(Bundle.module.url(forResource: "local-audio.m4a", withExtension: nil, subdirectory: "Fixtures"))
    model.attachToCurrentChat([.bytes(name: "public.m4a", data: try Data(contentsOf: url))]); try await finish(model)
    let audio = try XCTUnwrap(model.state.attachments.last)
    let prefix = "🙂\n[Attachment: image](boom-attachment:\(image.id))\nLabel:"
    let after = "\n[Attachment: audio](boom-attachment:\(audio.id))"
    let document = DocumentSnapshot(title: "Public", text: prefix + after)
    let authored = try ProductCore.authoredPrefix(document, caret: prefix.utf16.count)
    let admitted = try await model.writingMedia(in: authored, flag: CancellationFlag())
    XCTAssertEqual(admitted.map { $0.reference.id }, [image.id])
    let payload = try await model.writingMedia(in: after, flag: CancellationFlag())
    XCTAssertEqual(payload.count, 1); XCTAssertEqual(payload[0].reference.kind, "audio")
    XCTAssertGreaterThan(payload[0].samples.count, 18_000); XCTAssertTrue(payload[0].samples.allSatisfy(\.isFinite))
    let compiled = try RawWritingInput.compiled("<bos>" + prefix, media: admitted.map(\.reference))
    XCTAssertEqual(compiled.prompt, "<bos>🙂\n<|image|>\nLabel:")
    XCTAssertEqual(compiled.media.map(\.id), [image.id])
    try await model.shutdown()
  }

  @MainActor func testActualReadonlyAttachmentMenuCopiesDisplayedOriginalInsteadOfDifferentNativeSelection() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-display-copy-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 800, height: 600))
    window.isReleasedWhenClosed = false
    do {
      let viewport = try XCTUnwrap(model.pagedViewport)
      window.contentView = viewport
      try await PagedNativeFixtureApplication.focus(try XCTUnwrap(model.pagedInput?.activeView), in: window)
      if model.selectedChat == nil { try model.newChat() }
      let original = try Self.image()
      model.attachToCurrentChat([.bytes(name: "public-display.png", data: original)])
      try await finish(model)
      let record = try XCTUnwrap(model.state.attachments.last)
      let documentID = try XCTUnwrap(model.selectedDocumentID)
      let source = "Different native words.\n[Attachment: public-display.png](boom-attachment:\(record.id))\nAfter 🙂."
      try await NativeCheckEvidence.replacePublicDocument(model, text: source, id: documentID, caret: 0)
      let native = try XCTUnwrap(model.pagedInput?.activeView)
      try await PagedNativeFixtureApplication.focus(native, in: window)
      native.setSelectedRange(NSRange(location: 0, length: "Different".utf16.count))
      let nativeSelection = native.selectedRange()
      let session = try XCTUnwrap(model.pagedSession)
      let generation = session.generation, arena = session.arenaID
      let logical = try session.captureLogicalState().source

      try viewport.requestScroll(toUTF16: 0)
      try await viewport.joinPresentation()
      await viewport.joinMarkup()
      XCTAssertNil(viewport.markupFailure)
      let display = try XCTUnwrap(viewport.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NativeMediaTextView }
        .first(where: { $0 !== native && !$0.acceptsFirstResponder }))
      // Use the existing media component's real model/Vault load. No synthetic
      // glyph/item/bytes are installed and the read surface remains unfocused.
      display.setMedia(model: model)
      var host: InlineMediaHost?
      for _ in 0..<500 {
        host = display.subviews.compactMap { $0 as? InlineMediaHost }
          .first(where: { $0.item.record.id == record.id && $0.item.isReady })
        if host != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let media = try XCTUnwrap(host, "The actual readonly source did not load its verified original.")
      let range = try XCTUnwrap(media.sourceRange)
      let point = media.convert(NSPoint(x: 2, y: 2), to: nil)
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      let menu = try XCTUnwrap(media.menu(for: event))
      let entry = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy" }))
      let target = try XCTUnwrap(entry.target as? NSObject), action = try XCTUnwrap(entry.action)
      XCTAssertEqual(display.selectedRange(), range)
      XCTAssertEqual(native.selectedRange(), nativeSelection)
      XCTAssertTrue(window.firstResponder === native)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("retained-original-while-copy-prepares", forType: .string)
      _ = target.perform(action, with: entry)
      XCTAssertEqual(NSPasteboard.general.string(forType: .string), "retained-original-while-copy-prepares")
      await display.inlineMedia.joinPendingLoads()
      XCTAssertNil(display.inlineMedia.lastFailure)
      guard case .bytes(let name, let copied)? = AttachmentInput.read(.general)?.first else {
        throw BoomError.invalid("Readonly media Copy forwarded unrelated native text instead of its original.")
      }
      XCTAssertEqual(name, record.name); XCTAssertEqual(copied, original)
      XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), original)
      XCTAssertEqual(native.selectedRange(), nativeSelection)
      XCTAssertEqual(session.generation, generation); XCTAssertEqual(session.arenaID, arena)
      XCTAssertEqual(try session.captureLogicalState().source.rootID, logical.rootID)

      // The original menu is source/version/range bound. A different local
      // selection, then changed readonly characters, cannot reuse that entry.
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString("retained-copy-sentinel", forType: .string)
      display.setSelectedRange(NSRange(location: 0, length: 0))
      _ = target.perform(action, with: entry)
      XCTAssertEqual(NSPasteboard.general.string(forType: .string), "retained-copy-sentinel")
      display.setSelectedRange(range)
      display.string = "Changed display only."
      _ = target.perform(action, with: entry)
      XCTAssertEqual(NSPasteboard.general.string(forType: .string), "retained-copy-sentinel")
      XCTAssertEqual(native.selectedRange(), nativeSelection)
      let unchanged = try await model.captureDocument(documentID)
      XCTAssertEqual(unchanged.completeSnapshot?.text, source)
      XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), original)
      NSPasteboard.general.clearContents()
      try await model.shutdown(); window.close()
      try FileManager.default.removeItem(at: root)
    } catch {
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, error))
      throw error
    }
  }

  @MainActor func testActualCollapsedAttachmentCutRemovesWholeMarkerAndResponderUndoRestoresSourceAndSelection() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-collapsed-media-cut-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 800, height: 600))
    window.isReleasedWhenClosed = false
    do {
      let viewport = try XCTUnwrap(model.pagedViewport)
      window.contentView = viewport
      try await PagedNativeFixtureApplication.focus(try XCTUnwrap(model.pagedInput?.activeView), in: window)
      if model.selectedChat == nil { try model.newChat() }
      let original = try Self.image()
      model.attachToCurrentChat([.bytes(name: "public-collapsed.png", data: original)])
      try await finish(model)
      let record = try XCTUnwrap(model.state.attachments.last)
      let documentID = try XCTUnwrap(model.selectedDocumentID)
      let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
      let session = try XCTUnwrap(model.pagedSession)
      for marker in ["[asset][]", "![asset][]"] {
        let prefix = "Before e\u{301}🙂\n"
        let tail = "\nAfter\n\n[asset]: boom-attachment:\(record.id.uuidString)\n"
        let source = prefix + marker + tail, deleted = prefix + tail
        try await NativeCheckEvidence.replacePublicDocument(model, text: source, id: documentID, caret: 0)
        let view = try XCTUnwrap(input.activeView)
        try await PagedNativeFixtureApplication.focus(view, in: window)
        await viewport.joinMarkup()
        XCTAssertNil(viewport.markupFailure)
        view.setMedia(model: model); MarkdownStyle.apply(to: view)
        await view.inlineMedia.joinPendingLoads()
        let range = (source as NSString).range(of: marker)
        XCTAssertEqual(view.inlineMedia.currentRanges, [range],
          "\(marker): native media attributes must cover both collapsed brackets, not just the short parser event.")
        view.setSelectedRange(range, affinity: .upstream, stillSelecting: false)
        XCTAssertEqual(view.selectedRange(), range)
        let beforeSelection = try input.currentDocumentSelection()
        let beforeSource = try session.captureLogicalState().source
        XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(window.firstResponder === view)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("retained-before-original-publication", forType: .string)
        view.cut(nil)
        XCTAssertEqual(Data(view.string.utf8), Data(source.utf8),
          "Cut must retain its complete source until the actual original is published.")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "retained-before-original-publication")
        await view.inlineMedia.joinPendingLoads()
        XCTAssertNil(view.inlineMedia.lastFailure)
        XCTAssertEqual(Data(view.string.utf8), Data(deleted.utf8),
          "\(marker): actual native Cut must remove the entire marker and retain its definition and Unicode neighbors.")
        guard case .bytes(let name, let copied)? = AttachmentInput.read(.general)?.first else {
          throw BoomError.invalid("Actual collapsed attachment Cut lost its original pasteboard representation.")
        }
        XCTAssertEqual(name, record.name); XCTAssertEqual(copied, original)
        XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), original)
        try await commands.joinPendingCommand()
        let cutSource = try session.captureLogicalState().source
        let cutCapture = try await model.captureDocument(documentID)
        XCTAssertEqual(cutCapture.completeSnapshot?.text, deleted)
        XCTAssertTrue(commands.manager.canUndo)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"),
          to: try XCTUnwrap(window.firstResponder), from: nil))
        try await commands.joinPendingCommand()
        XCTAssertTrue(try session.captureLogicalState().source.isSame(beforeSource))
        XCTAssertEqual(try input.currentDocumentSelection(), beforeSelection)
        XCTAssertTrue(window.firstResponder === input.activeView)
        let undone = try await model.captureDocument(documentID)
        XCTAssertEqual(Data(try XCTUnwrap(undone.completeSnapshot).text.utf8), Data(source.utf8))
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("redo:"),
          to: try XCTUnwrap(window.firstResponder), from: nil))
        try await commands.joinPendingCommand()
        XCTAssertTrue(try session.captureLogicalState().source.isSame(cutSource))
        let redone = try await model.captureDocument(documentID)
        XCTAssertEqual(Data(try XCTUnwrap(redone.completeSnapshot).text.utf8), Data(deleted.utf8))
        XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), original)
        XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      }
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Actual collapsed media source/Cut/Undo assertions failed; the native graph is retained.")
      }
      NSPasteboard.general.clearContents()
      try await model.shutdown(); window.close()
      try FileManager.default.removeItem(at: root)
    } catch {
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, error))
      throw error
    }
  }

  @MainActor func testActualViewportEvictsOffscreenImagesPreservesGeometryAndCopiesOriginalOnDemand() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-lazy-media-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 620, height: 280))
    window.isReleasedWhenClosed = false
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 6000))
    do {
      if model.selectedChat == nil { try model.newChat() }
      var originals: [UUID: Data] = [:], records: [AttachmentRecord] = []
      for (index, color) in [NSColor.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemYellow].enumerated() {
        let bytes = try Self.image(color)
        model.attachToCurrentChat([.bytes(name: "visible-\(index).png", data: bytes)])
        try await finish(model)
        let record = try XCTUnwrap(model.state.attachments.last)
        records.append(record); originals[record.id] = bytes
      }
      let source = records.map { "[Attachment: \($0.name)](boom-attachment:\($0.id))\n\n" }.joined()
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
      scroll.hasVerticalScroller = true; scroll.documentView = view; window.contentView = scroll
      view.isRichText = false; view.string = source
      view.textContainer?.widthTracksTextView = false
      view.textContainer?.size = NSSize(width: 580, height: .greatestFiniteMagnitude)
      view.setMedia(model: model); MarkdownStyle.apply(to: view)
      view.inlineMedia.positionViews(); await view.inlineMedia.joinPendingLoads()
      XCTAssertNil(view.inlineMedia.lastFailure)
      let spans = view.inlineMedia.spans
      XCTAssertEqual(spans.count, records.count)
      let key = NSAttributedString.Key("BloomInlineMedia")
      @MainActor func item(_ index: Int) throws -> InlineMediaItem {
        try XCTUnwrap(view.textStorage?.attribute(key, at: spans[index].location, effectiveRange: nil) as? InlineMediaItem)
      }
      XCTAssertNotNil(try item(0).image); XCTAssertNil(try item(0).file)
      XCTAssertNil(try item(records.count - 1).image); XCTAssertNil(try item(records.count - 1).file)
      XCTAssertLessThan(view.subviews.compactMap { $0 as? InlineMediaHost }.count, records.count,
        "Only actual visible media occurrences create native hosts.")
      let geometry = try XCTUnwrap(try item(0).imageGeometry), version = view.sourceVersion
      let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
      let lastGlyph = manager.glyphIndexForCharacter(at: try XCTUnwrap(spans.last).location)
      let lastLine = manager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: lastLine.minY + view.textContainerOrigin.y))
      scroll.reflectScrolledClipView(scroll.contentView)
      view.inlineMedia.viewportDidChange(); await view.inlineMedia.joinPendingLoads()
      XCTAssertNil(view.inlineMedia.lastFailure)
      XCTAssertNil(try item(0).image); XCTAssertNil(try item(0).file)
      XCTAssertEqual(try item(0).imageGeometry, geometry)
      XCTAssertNotNil(try item(records.count - 1).image)
      XCTAssertEqual(view.sourceVersion, version); XCTAssertEqual(view.string, source)
      // Copying an offscreen original does not load or retain its thumbnail.
      view.setSelectedRange(spans[0].range)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: lastLine.minY + view.textContainerOrigin.y))
      view.inlineMedia.viewportDidChange()
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString("previous-original", forType: .string)
      view.copy(nil)
      XCTAssertEqual(NSPasteboard.general.string(forType: .string), "previous-original")
      await view.inlineMedia.joinPendingLoads()
      guard case .bytes(let name, let copied)? = AttachmentInput.read(.general)?.first else {
        throw BoomError.invalid("The real offscreen Copy did not publish its original.")
      }
      XCTAssertEqual(name, records[0].name); XCTAssertEqual(copied, originals[records[0].id])
      XCTAssertNil(try item(0).image); XCTAssertNil(try item(0).file)
      XCTAssertEqual(try model.store.vault.get(.attachment, id: records[0].id), originals[records[0].id])
      scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
      view.inlineMedia.viewportDidChange(); await view.inlineMedia.joinPendingLoads()
      XCTAssertNotNil(try item(0).image); XCTAssertEqual(try item(0).imageGeometry, geometry)
      XCTAssertEqual(view.sourceVersion, version); XCTAssertEqual(view.string, source)
      withExtendedLifetime(container) {}
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Actual viewport/original assertions failed; the native graph is retained.")
      }
      view.inlineMedia.stop(); await view.inlineMedia.joinPendingLoads()
      XCTAssertNil(view.inlineMedia.lastFailure)
      NSPasteboard.general.clearContents()
      try await model.shutdown(); window.close(); try FileManager.default.removeItem(at: root)
    } catch {
      view.inlineMedia.stop(); await view.inlineMedia.joinPendingLoads()
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, error)); throw error
    }
  }

  @MainActor func testActualMediaCopyLatestIntentWinsAcrossSurfacesAndStaleSourcePreservesClipboard() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-media-copy-order-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 620, height: 700))
    window.isReleasedWhenClosed = false
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 700))
    let a = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 330))
    let b = MarkdownTextView(frame: NSRect(x: 0, y: 350, width: 600, height: 330))
    do {
      if model.selectedChat == nil { try model.newChat() }
      let red = try Self.image(.systemRed), blue = try Self.image(.systemBlue)
      model.attachToCurrentChat([.bytes(name: "first.png", data: red)]); try await finish(model)
      let first = try XCTUnwrap(model.state.attachments.last)
      model.attachToCurrentChat([.bytes(name: "latest.png", data: blue)]); try await finish(model)
      let latest = try XCTUnwrap(model.state.attachments.last)
      parent.addSubview(a); parent.addSubview(b); window.contentView = parent
      for (view, record) in [(a, first), (b, latest)] {
        view.isRichText = false; view.isEditable = true; view.allowsUndo = true; view.documentUndo = UndoManager()
        view.string = "[Attachment: \(record.name)](boom-attachment:\(record.id))"
        view.setMedia(model: model); MarkdownStyle.apply(to: view)
        view.setSelectedRange(try XCTUnwrap(view.inlineMedia.spans.first).range)
      }
      await a.inlineMedia.joinPendingLoads(); await b.inlineMedia.joinPendingLoads()
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString("previous-copy", forType: .string)
      a.copy(nil); b.copy(nil)
      XCTAssertEqual(NSPasteboard.general.string(forType: .string), "previous-copy")
      await a.inlineMedia.joinPendingLoads(); await b.inlineMedia.joinPendingLoads()
      XCTAssertNil(a.inlineMedia.lastFailure); XCTAssertNil(b.inlineMedia.lastFailure)
      guard case .bytes(let name, let copied)? = AttachmentInput.read(.general)?.first else {
        throw BoomError.invalid("The latest actual media Copy did not publish.")
      }
      XCTAssertEqual(name, latest.name); XCTAssertEqual(copied, blue)
      let before = a.string
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString("keep-on-stale-source", forType: .string)
      a.copy(nil)
      a.setSelectedRange(NSRange(location: a.string.utf16.count, length: 0))
      a.insertText("Z", replacementRange: a.selectedRange())
      XCTAssertEqual(a.string, before + "Z", "Ordinary typing never waits for Copy preparation.")
      await a.inlineMedia.joinPendingLoads()
      XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep-on-stale-source")
      try XCTUnwrap(a.documentUndo).undo(); XCTAssertEqual(a.string, before)
      XCTAssertEqual(try model.store.vault.get(.attachment, id: first.id), red)
      XCTAssertEqual(try model.store.vault.get(.attachment, id: latest.id), blue)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Actual clipboard/source assertions failed; the native graph is retained.")
      }
      a.inlineMedia.stop(); b.inlineMedia.stop()
      await a.inlineMedia.joinPendingLoads(); await b.inlineMedia.joinPendingLoads()
      NSPasteboard.general.clearContents()
      try await model.shutdown(); window.close(); try FileManager.default.removeItem(at: root)
    } catch {
      a.inlineMedia.stop(); b.inlineMedia.stop()
      await a.inlineMedia.joinPendingLoads(); await b.inlineMedia.joinPendingLoads()
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, error)); throw error
    }
  }

  @MainActor func testActualFileBackedNativeAssetKeepsVerifiedCloneAfterVaultReplacementAndReleasesOwnedFile() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-media-file-lifetime-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 620, height: 400))
    window.isReleasedWhenClosed = false
    var captured: NativeInlineMediaPrepared?
    var escapedAsset: AVURLAsset?
    var restoreOriginal: (Vault, UUID, Data)?
    let disposal = NativeInlineMediaDisposal()
    do {
      if model.selectedChat == nil { try model.newChat() }
      let url = try XCTUnwrap(Bundle.module.url(forResource: "local-audio.m4a", withExtension: nil, subdirectory: "Fixtures"))
      let original = try Data(contentsOf: url)
      model.attachToCurrentChat([.bytes(name: "misleading-original.bin", data: original)]); try await finish(model)
      let record = try XCTUnwrap(model.state.attachments.last), vault = model.store.vault
      captured = try await detachedWork {
        try NativeInlineMediaPrepared.load(record: record, vault: vault, availableWidth: 600, scale: 1, disposal: disposal)
      }
      let cloneURL = try XCTUnwrap(captured?.file?.url)
      weak var fileOwner = captured?.file
      escapedAsset = try XCTUnwrap(captured?.asset)
      XCTAssertEqual(escapedAsset?.url, cloneURL)
      var player: AVPlayer? = AVPlayer(playerItem: AVPlayerItem(asset: try XCTUnwrap(escapedAsset)))
      for _ in 0..<500 where player?.currentItem?.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertEqual(player?.currentItem?.status, .readyToPlay,
        player?.currentItem?.error?.localizedDescription ?? "Native file playback was not ready.")
      autoreleasepool { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
      // Replace the REAL canonical record atomically. The captured clone and
      // its admitted digest still denote the original, not the new pathname.
      let replacement = Data("different canonical record".utf8)
      restoreOriginal = (vault, record.id, original)
      try await detachedWork { try vault.put(replacement, kind: .attachment, id: record.id) }
      var isolationFailure: Error?
      do {
        let preserved = try await detachedWork {
          try RegularFile(cloneURL, limit: 67_108_864, allowEmpty: false).data()
        }
        XCTAssertEqual(preserved, original)
        XCTAssertEqual(try vault.get(.attachment, id: record.id), replacement)
      } catch { isolationFailure = error }
      // Restore through the same actual publication before any exit/reopen.
      try await detachedWork { try vault.put(original, kind: .attachment, id: record.id) }
      restoreOriginal = nil
      if let isolationFailure { throw isolationFailure }
      captured = nil
      XCTAssertNotNil(fileOwner, "The actual escaped AVURLAsset owns the file after its presentation retires.")
      XCTAssertTrue(FileManager.default.fileExists(atPath: cloneURL.path))
      autoreleasepool { escapedAsset = nil }
      let cleanup = await disposal.joinQueued()
      XCTAssertNil(cleanup)
      // AVFoundation may still retain an actual native object. A join must
      // never revoke that ownership merely to make a file-count oracle pass.
      if fileOwner != nil { XCTAssertTrue(FileManager.default.fileExists(atPath: cloneURL.path)) }
      else { XCTAssertFalse(FileManager.default.fileExists(atPath: cloneURL.path)) }
      var direct: NativeInlineMediaFile? = try await detachedWork {
        try NativeInlineMediaFile.clone(record: record, vault: vault, disposal: disposal)
      }
      let releasedURL = try XCTUnwrap(direct?.url)
      weak var directOwner = direct
      autoreleasepool { direct = nil }
      XCTAssertNil(directOwner)
      let directCleanup = await disposal.joinQueued()
      XCTAssertNil(directCleanup)
      XCTAssertFalse(FileManager.default.fileExists(atPath: releasedURL.path),
        "The real worker must finish deleting its last-owner disposable file.")
      XCTAssertEqual(try vault.get(.attachment, id: record.id), original)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Actual native file ownership assertions failed; the native graph is retained.")
      }
      try await model.shutdown(); window.close(); try FileManager.default.removeItem(at: root)
    } catch {
      var failure = error
      if let (vault, id, original) = restoreOriginal {
        do { try await detachedWork { try vault.put(original, kind: .attachment, id: id) } }
        catch { failure = NativeInlineMediaCleanupFailure(original: failure, cleanup: error) }
      }
      captured = nil; escapedAsset = nil
      if let cleanup = await disposal.joinQueued() {
        failure = NativeInlineMediaCleanupFailure(original: failure, cleanup: cleanup)
      }
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, failure)); throw failure
    }
  }

  @MainActor func testActualInlineDocumentCardsKeepNaturalShortHeightAndCompleteLongMarkdownReading() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-document-card-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 620, height: 240))
    window.isReleasedWhenClosed = false
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 10000))
    do {
      if model.selectedChat == nil { try model.newChat() }
      let short = "# Short 🙂\n"
      let long = String(repeating: "Body e\u{301}🙂 **strong** prose.\n", count: 6000) + "ACTUAL_DOCUMENT_END_CANARY"
      var records: [AttachmentRecord] = []
      for (name, text) in [("short.md", short), ("long.md", long)] {
        model.attachToCurrentChat([.bytes(name: name, data: Data(text.utf8))]); try await finish(model)
        let record = try XCTUnwrap(model.state.attachments.last)
        XCTAssertEqual(record.kind, .document)
        XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), Data(text.utf8))
        records.append(record)
      }
      let source = "[Attachment: short](boom-attachment:\(records[0].id))\n"
        + String(repeating: "Intervening source.\n", count: 300)
        + "[Attachment: long](boom-attachment:\(records[1].id))"
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 240))
      scroll.hasVerticalScroller = true; scroll.documentView = view; window.contentView = scroll
      view.string = source; view.setMedia(model: model); MarkdownStyle.apply(to: view)
      view.inlineMedia.positionViews(); await view.inlineMedia.joinPendingLoads()
      let spans = view.inlineMedia.spans
      XCTAssertEqual(spans.count, 2)
      let shortHost = try XCTUnwrap(view.subviews.compactMap { $0 as? InlineMediaHost }
        .first(where: { $0.item.record.id == records[0].id }))
      XCTAssertGreaterThanOrEqual(shortHost.frame.height, 24); XCTAssertLessThan(shortHost.frame.height, 80)
      let shortScroll = try XCTUnwrap(shortHost.subviews.compactMap { $0 as? NativeTextScrollView }.first)
      XCTAssertEqual(shortScroll.reader.string, records[0].text)
      XCTAssertFalse(view.subviews.compactMap { $0 as? InlineMediaHost }.contains(where: { $0.item.record.id == records[1].id }),
        "The distant document must not own a reader just to answer its control-glyph geometry.")
      let manager = try XCTUnwrap(view.layoutManager)
      let glyph = manager.glyphIndexForCharacter(at: spans[1].location)
      let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y))
      view.inlineMedia.viewportDidChange()
      let longHost = try XCTUnwrap(view.subviews.compactMap { $0 as? InlineMediaHost }
        .first(where: { $0.item.record.id == records[1].id }))
      let longScroll = try XCTUnwrap(longHost.subviews.compactMap { $0 as? NativeTextScrollView }.first)
      XCTAssertEqual(longHost.frame.height, 480)
      XCTAssertEqual(longScroll.reader.string, records[1].text)
      XCTAssertTrue(longScroll.reader.string.contains("ACTUAL_DOCUMENT_END_CANARY"))
      for width: CGFloat in [600, 240, 420, 600] {
        longHost.setFrameSize(NSSize(width: width, height: 480)); longHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(longHost.item.size(available: width).height, 480)
        XCTAssertEqual(longScroll.reader.string, records[1].text)
      }
      let end = (longScroll.reader.string as NSString).range(of: "ACTUAL_DOCUMENT_END_CANARY")
      XCTAssertNotEqual(end.location, NSNotFound)
      longScroll.reader.setSelectedRange(end); longScroll.reader.scrollRangeToVisible(end)
      longScroll.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(longScroll.contentView.bounds.minY, 0, "All extracted text remains reachable in its real native scroller.")
      XCTAssertEqual((longScroll.reader.string as NSString).substring(with: longScroll.reader.selectedRange()), "ACTUAL_DOCUMENT_END_CANARY")
      XCTAssertFalse(longScroll.reader.string.hasSuffix("\n"))
      let readingLayout = try XCTUnwrap(longScroll.reader.layoutManager)
      let readingContainer = try XCTUnwrap(longScroll.reader.textContainer)
      // This explicit fixture action fully lays the long reader. It covers
      // the already-complete branch, not merely a still-unlaid suffix. Call
      // the real helper directly so the item's width cache cannot mask it.
      readingLayout.ensureLayout(for: readingContainer)
      XCTAssertGreaterThanOrEqual(readingLayout.firstUnlaidCharacterIndex(), longScroll.reader.string.utf16.count)
      XCTAssertGreaterThan(readingLayout.usedRect(for: readingContainer).maxY, 480)
      let revisitedHeight = longScroll.reader.boundedAttachmentHeight(at: longScroll.reader.frame.width, maximum: 480)
      XCTAssertEqual(revisitedHeight, 480,
        "A fully laid long no-final-newline reader cannot become a short card on revisit.")
      longScroll.reader.scrollRangeToVisible(end)
      XCTAssertEqual(longScroll.reader.string, records[1].text)
      let storage = try XCTUnwrap(longScroll.reader.textStorage)
      let strong = (longScroll.reader.string as NSString).range(of: "strong")
      let font = try XCTUnwrap(storage.attribute(.font, at: strong.location, effectiveRange: nil) as? NSFont)
      XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "The complete extraction keeps its existing Markdown presentation.")
      XCTAssertEqual(view.string, source)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Actual document geometry/reading assertions failed; graph retained.")
      }
      view.inlineMedia.stop(); await view.inlineMedia.joinPendingLoads()
      try await model.shutdown(); window.close(); try FileManager.default.removeItem(at: root)
    } catch {
      view.inlineMedia.stop(); await view.inlineMedia.joinPendingLoads()
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, error)); throw error
    }
  }

  @MainActor func testActualPreviewCleanupIdentityFailureReportsOwnedPathAndCloseDoesNotRefuseNativeTyping() async throws {
    try PagedNativeFixtureApplication.bootstrap()
    let failures = testRun?.failureCount ?? 0
    let root = try PagedNativeFixtureApplication.scratchRoot(prefix: "public-media-cleanup-")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 80, y: 80, width: 620, height: 400))
    window.isReleasedWhenClosed = false
    var file: NativeInlineMediaFile?
    do {
      let viewport = try XCTUnwrap(model.pagedViewport), input = try XCTUnwrap(model.pagedInput)
      window.contentView = viewport
      let native = try XCTUnwrap(input.activeView)
      try await PagedNativeFixtureApplication.focus(native, in: window)
      if model.selectedChat == nil { try model.newChat() }
      let original = try Self.image()
      model.attachToCurrentChat([.bytes(name: "cleanup-original.png", data: original)]); try await finish(model)
      let record = try XCTUnwrap(model.state.attachments.last), vault = model.store.vault
      let owner = native.inlineMedia, disposal = owner.disposal
      file = try await detachedWork { try NativeInlineMediaFile.clone(record: record, vault: vault, disposal: disposal) }
      let originalURL = try XCTUnwrap(file?.url), directory = originalURL.deletingLastPathComponent()
      let moved = directory.deletingLastPathComponent().appendingPathComponent("retained-media-control-" + UUID().uuidString)
      // The original inode still exists, so the newly created path cannot be
      // that captured directory. The real deletion worker must refuse it.
      try await detachedWork {
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      file = nil
      try await viewport.closePresentation()
      let failure = try XCTUnwrap(owner.cleanupFailure)
      XCTAssertEqual(failure.ownedDirectory, directory)
      XCTAssertTrue(failure.original is BoomError)
      XCTAssertTrue(model.status.contains(directory.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(originalURL.lastPathComponent).path))
      XCTAssertEqual(try vault.get(.attachment, id: record.id), original)
      XCTAssertNil(input.firstRefusal); XCTAssertNil(model.pagedCommands?.firstFailure)
      let before = native.string
      native.setSelectedRange(NSRange(location: 0, length: 0)); native.insertText("Z", replacementRange: native.selectedRange())
      XCTAssertEqual(native.string, "Z" + before, "A disposable preview refusal cannot turn the live source read-only.")
      XCTAssertNil(input.firstRefusal); XCTAssertNil(model.pagedCommands?.firstFailure)
      guard (testRun?.failureCount ?? 0) == failures else {
        throw BoomError.invalid("Actual media cleanup/typing assertions failed; paths and graph retained.")
      }
      // Only the two exact paths this control created/moved are cleaned here;
      // production deliberately left both identities untouched.
      try await detachedWork { try FileManager.default.removeItem(at: directory); try FileManager.default.removeItem(at: moved) }
      try await model.shutdown(); window.close(); try FileManager.default.removeItem(at: root)
    } catch {
      file = nil
      if let owner = model.pagedInput?.activeView?.inlineMedia { await owner.joinPendingLoads() }
      precondition(Self.failedDisplayCopyControls.count < 8)
      Self.failedDisplayCopyControls.append((model, window, error)); throw error
    }
  }

  @MainActor func testOriginalPNGCopyPublishesExactHeaderTypeDespiteMisleadingFilename() throws {
    _ = NSApplication.shared
    let bytes = try Self.image()
    let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { board.clearContents() }
    XCTAssertTrue(AttachmentInput.write(.bytes(name: "public-original.bin", data: bytes), to: board))
    XCTAssertEqual(board.data(forType: .png), bytes, "The original image representation must remain byte-exact, rather than an eagerly encoded TIFF.")
    guard case .bytes(let name, let original)? = AttachmentInput.read(board)?.first,
      case .bytes(_, let image)? = AttachmentInput.readImage(board) else {
      return XCTFail("The actual native pasteboard lost the original Bloom or PNG representation.")
    }
    XCTAssertEqual(name, "public-original.bin"); XCTAssertEqual(original, bytes); XCTAssertEqual(image, bytes)
  }
}
