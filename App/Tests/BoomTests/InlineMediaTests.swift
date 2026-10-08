import AppKit
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class InlineMediaTests: XCTestCase {
  @MainActor private func model() async throws -> WorkspaceModel {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-inline-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root,
      testKey: SymmetricKey(size: .bits256)), loadModels: false)
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
    guard let document = model.selectedDocument else { throw XCTSkip("No manuscript in chat edition.") }
    model.updateDocument("Before 👩‍💻\nAfter", id: document.id, caret: 0)
    let destination = try XCTUnwrap(model.documentAttachmentDestination(id: document.id,
      range: NSRange(location: "Before 👩‍💻\n".utf16.count, length: 0)))
    let bytes = try Self.image()
    model.attach([.bytes(name: "Public café.png", data: bytes)], to: destination)
    try await finish(model)
    let saved = try XCTUnwrap(model.selectedDocument), record = try XCTUnwrap(model.state.attachments.first)
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
    view.documentUndo?.undo(); XCTAssertEqual(view.string, saved.text)
    let span = try XCTUnwrap(view.inlineMedia.spans.first)
    view.setSelectedRange(NSRange(location: span.location, length: 0))
    view.setSelectedRange(NSRange(location: span.location + 6, length: 0))
    XCTAssertEqual(view.selectedRange().location, NSMaxRange(span.range))
    view.deleteBackward(nil)
    XCTAssertEqual(view.string, "Before 👩‍💻\n\nAfter", "A pasted image deletes as one object, not one hidden bracket.")
    view.documentUndo?.undo()
    XCTAssertEqual(view.string, saved.text)
    let reopened = try await model.store.load().get()
    XCTAssertEqual(reopened.1.first(where: { $0.id == saved.id }), saved)
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
    AttachmentInput.write(.bytes(name: retained.name, data: original), to: board)
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
    let reopened = try await model.store.load().get().0
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
}
