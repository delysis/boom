import AppKit
import BoomCore
import CryptoKit
import XCTest
import UniformTypeIdentifiers
@testable import Boom

struct AttachmentFixture: Decodable {
  let name: String
  let kind: AttachmentKind
  let needle: String?
}
final class AttachmentFixtureTests: XCTestCase {
  @MainActor func testEmptyEditorsDrawBeforeAndAfterRepeatedPromptConfiguration() throws {
    _ = NSApplication.shared
    for view in [MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120)),
      ChatTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))] as [NativeCompletionTextView] {
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 240, height: 120))
      window.isReleasedWhenClosed = false; window.contentView = view
      defer { window.close() }
      for pass in 0..<3 {
        if pass > 0 {
          (view as? MarkdownTextView)?.preparePlaceholder()
          (view as? ChatTextView)?.preparePlaceholder("Message")
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(view.string, "")
      }
    }
  }
  @MainActor func testTextAttachmentsFitShortContentAndScrollLongContentAcrossWidths() {
    let short = "A short attachment."
    XCTAssertLessThan(NativeScrollableText.height(of: short, width: 300), 50)
    let long = String(repeating: "A longer attachment with words that wrap.\n", count: 40)
    XCTAssertEqual(NativeScrollableText.height(of: long, width: 300), 220)
    let viewport = NativeTextScrollView()
    viewport.reader.setSource(long)
    viewport.reader.setSelectedRange(NSRange(location: 2, length: 4))
    for width: CGFloat in [300, 140, 420, 300] {
      viewport.setFrameSize(NSSize(width: width, height: 220)); viewport.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(viewport.reader.frame.height, viewport.contentView.bounds.height)
      XCTAssertEqual(viewport.reader.frame.height, viewport.reader.contentHeight(at: viewport.contentView.bounds.width))
      XCTAssertEqual(viewport.reader.selectedRange(), NSRange(location: 2, length: 4))
      XCTAssertEqual(viewport.reader.string, long)
    }
    viewport.reader.setSource(short); viewport.needsLayout = true; viewport.layoutSubtreeIfNeeded()
    XCTAssertLessThan(viewport.reader.frame.height, 50)
  }
  @MainActor func testExternalMediaRepresentationsAndOrdinaryTextUseTheSharedDecoder() throws {
    let directory = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/Attachments")).deletingLastPathComponent()
    let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.clearContents() }
    for name in ["picture.jpg", "picture.heic", "picture.avif", "text.pdf", "tone.wav", "tone.aiff", "tone.flac", "tone.mp3", "tone.m4a", "tone.ogg", "tone.opus", "tone.caf", "video.mp4", "video.mov"] {
      let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
      let type = try XCTUnwrap(UTType(filenameExtension: (name as NSString).pathExtension))
      board.clearContents(); board.setData(bytes, forType: .init(type.identifier))
      XCTAssertTrue(AttachmentInput.canRead(board), name)
      guard case .bytes(_, let decoded)? = AttachmentInput.read(board)?.first else { return XCTFail(name) }
      XCTAssertEqual(decoded, bytes, name)
    }
    board.clearContents(); board.setString("Ordinary prose", forType: .string)
    XCTAssertFalse(AttachmentInput.canRead(board)); XCTAssertNil(AttachmentInput.read(board))
    XCTAssertTrue(AttachmentInput.draggingTypes.contains(.init(UTType.image.identifier)))
    XCTAssertTrue(AttachmentInput.draggingTypes.contains(.init(UTType.audio.identifier)))
    XCTAssertTrue(AttachmentInput.draggingTypes.contains(.init(UTType.movie.identifier)))
    XCTAssertTrue(AttachmentInput.draggingTypes.contains(.init(UTType.pdf.identifier)))
    let file = NSPasteboardItem(); file.setString(directory.appendingPathComponent("plain.txt").absoluteString, forType: .fileURL)
    let jpeg = NSPasteboardItem(); let jpegBytes = try Data(contentsOf: directory.appendingPathComponent("picture.jpg")); jpeg.setData(jpegBytes, forType: .init(UTType.jpeg.identifier))
    let wave = NSPasteboardItem(); let waveBytes = try Data(contentsOf: directory.appendingPathComponent("tone.wav")); wave.setData(waveBytes, forType: .init(UTType.wav.identifier))
    board.clearContents(); XCTAssertTrue(board.writeObjects([file, jpeg, wave]))
    let mixed = try XCTUnwrap(AttachmentInput.read(board)); XCTAssertEqual(mixed.count, 3)
    guard case .file = mixed[0], case .bytes(_, let j) = mixed[1], case .bytes(_, let w) = mixed[2] else { return XCTFail("Mixed drop changed its order/types") }
    XCTAssertEqual(j, jpegBytes); XCTAssertEqual(w, waveBytes)
  }
  @MainActor func testEveryFixtureThroughNativeDropsAndClipboardRoundTripWithEncryptedReload() async throws {
    _ = NSApplication.shared
    let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/Attachments")).deletingLastPathComponent()
    let rows = try JSONDecoder().decode([AttachmentFixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-attachments-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256)), loadModels: false)
    model.state.autocomplete = false
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 800, height: 900))
    window.isReleasedWhenClosed = false; defer { window.close() }
    let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 850))
    editor.owner = model; editor.isRichText = false; editor.allowsUndo = true; editor.documentUndo = UndoManager()
    window.contentView = editor
    let composer = ChatTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
    composer.onAttachments = { model.attachToCurrentChat($0) }
    let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.clearContents() }
    func finish() async throws {
      for _ in 0..<300 where model.isBusy { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage); try await model.flush()
    }
    for row in rows {
      let file = fixtures.appendingPathComponent(row.name), bytes = try Data(contentsOf: file)
      board.clearContents(); XCTAssertTrue(board.writeObjects([file as NSURL]), row.name)
      XCTAssertTrue(AttachmentInput.canRead(board), row.name)
      if let document = model.selectedDocument {
        let source = "Before 🪶\n\nAfter"
        model.updateDocument(source, id: document.id, caret: 0)
        editor.documentID = document.id; editor.string = source; editor.setMedia(model: model); MarkdownStyle.apply(to: editor)
        let offset = "Before 🪶\n\n".utf16.count
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: offset), line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = layout.location(forGlyphAt: glyph)
        let point = editor.convert(NSPoint(x: editor.textContainerOrigin.x + line.minX + position.x + 0.1,
          y: editor.textContainerOrigin.y + line.midY), to: nil)
        let drop = AttachmentDropFixture(board: board, point: point, window: window)
        XCTAssertEqual(editor.draggingEntered(drop), .copy, row.name); XCTAssertTrue(editor.performDragOperation(drop), row.name)
        try await finish()
        let saved = try XCTUnwrap(model.selectedDocument)
        XCTAssertTrue(saved.text.hasPrefix("Before 🪶\n\n[Attachment:"), row.name + " " + saved.text)
        XCTAssertTrue(saved.text.hasSuffix("\nAfter"), row.name)
        XCTAssertTrue(model.pendingAttachments.isEmpty, row.name)
        editor.string = saved.text; MarkdownStyle.apply(to: editor)
        for _ in 0..<200 where !editor.subviews.compactMap({ $0 as? InlineMediaHost }).contains(where: { $0.item.bytes != nil }) { try await Task.sleep(for: .milliseconds(10)) }
        let host = try XCTUnwrap(editor.subviews.compactMap { $0 as? InlineMediaHost }.first, row.name)
        for width: CGFloat in [600, 200, 420, 600] {
          editor.setFrameSize(NSSize(width: width, height: 850)); editor.inlineMedia.positionViews()
          let glyphs = layout.glyphRange(forCharacterRange: (saved.text as NSString).range(of: "After"), actualCharacterRange: nil)
          let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
          XCTAssertGreaterThanOrEqual(rect.minY, host.frame.maxY, row.name)
          XCTAssertLessThanOrEqual(host.frame.maxX, width + 1, row.name)
        }
        let span = try XCTUnwrap(editor.inlineMedia.spans.first)
        editor.setSelectedRange(span.range)
        let original = try XCTUnwrap(editor.inlineMedia.selectedOriginal(editor.selectedRange()), row.name)
        AttachmentInput.write(original, to: board)
        guard case .bytes(_, let copied)? = AttachmentInput.read(board)?.first else { return XCTFail(row.name + " clipboard original missing") }
        XCTAssertEqual(copied, bytes, row.name)
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "Before 🪶\n\n\nAfter", row.name)
        editor.documentUndo?.undo(); XCTAssertEqual(editor.string, saved.text, row.name)
      }
      try model.newChat()
      board.clearContents(); XCTAssertTrue(board.writeObjects([file as NSURL]))
      let drop = AttachmentDropFixture(board: board, point: .zero, window: nil)
      XCTAssertEqual(composer.draggingEntered(drop), .copy, row.name); XCTAssertTrue(composer.performDragOperation(drop), row.name)
      try await finish()
      let record = try XCTUnwrap(model.state.attachments.last)
      let unsupported = ["video.mkv", "video.webm", "video.avi"].contains(row.name)
      XCTAssertEqual(record.kind, unsupported ? .unavailable : row.kind, row.name + " " + record.coverage)
      if let needle = row.needle { XCTAssertTrue(record.text.contains(needle), row.name + " " + record.coverage) }
      XCTAssertEqual(try model.store.vault.get(.attachment, id: record.id), bytes, row.name)
      if [.audio, .video].contains(record.kind) {
        let source = try MemoryMedia(bytes: bytes)
        let player = try await source.readyPlayer(flag: CancellationFlag())
        XCTAssertEqual(player.currentItem?.status, .readyToPlay, row.name)
        player.pause(); withExtendedLifetime(source) {}
      }
      if record.kind == .unavailable {
        do { _ = try await model.writingMedia(in: "[Attachment: opaque](boom-attachment:\(record.id))", flag: CancellationFlag()); XCTFail("Opaque input silently entered writing: " + row.name) }
        catch {}
      }
      XCTAssertEqual(model.pendingAttachments, [record.id], row.name)
      model.draft = "Public question"; model.authorChatMessage(.user); model.send(); try await finish()
      XCTAssertEqual(model.selectedChat?.messages.last?.directAttachments, [record.id], row.name)
      XCTAssertTrue(model.pendingAttachments.isEmpty, row.name)
    }
    let reopened = try await model.store.load().get().0
    XCTAssertEqual(reopened.attachments, model.state.attachments)
    XCTAssertEqual(reopened.chats.map(\.messages), model.state.chats.map(\.messages))
    try await model.shutdown()
  }
}
