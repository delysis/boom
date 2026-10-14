import AppKit
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
    for _ in 0..<100 where !view.subviews.contains(where: { ($0 as? InlineMediaHost)?.item.bytes != nil }) { try await Task.sleep(for: .milliseconds(10)) }
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
          .first(where: { $0.item.record.id == record.id && $0.item.bytes != nil })
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
      _ = target.perform(action, with: entry)
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
      precondition(Self.failedDisplayCopyControls.count < 4)
      Self.failedDisplayCopyControls.append((model, window, error))
      throw error
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
