import AppKit
import AVFoundation
import BoomCore
import PDFKit
import XCTest
@testable import Boom

final class BlessengerMediaReviewTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, AttachmentRecord, BlessengerDraft) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-review-" + UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, privateSession: BlessengerKeySession { _ in Data(repeating: 0x57, count: 32) })
    let initial = try await store.openBlessenger(catalog: .init(sourceRevision: "fixture", sourceSHA256: "fixture", entries: []))
    let item = try AttachmentProcessor.inspect(name: "Voice note.wav",
      data: BlessengerWave.encode([Float](repeating: 0, count: 16000), rate: 16000))
    let state = try await store.blessengerImport(item, draftID: BlessengerDraft.unsentID,
      expectedVersion: initial.blessenger!.draft(for: nil).version)
    return (store, item.record, state.blessenger!.draft(for: nil))
  }
  @MainActor func testPrivateAudioReviewNegotiatesActualPlaybackWithoutAutoplayOrFiles() async throws {
    _ = NSApplication.shared
    let (store, original, draft) = try await fixture()
    let before = try FileManager.default.contentsOfDirectory(atPath: store.vault.root.path).sorted()
    let review = BlessengerMediaReview(original: original, destination: draft, insertion: nil)
    review.load(store: store)
    for _ in 0..<400 where review.loading { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(review.loading)
    XCTAssertNil(review.issue)
    let player = try XCTUnwrap(review.player)
    XCTAssertEqual(player.currentItem?.status, .readyToPlay)
    XCTAssertEqual(player.rate, 0, "Opening an original must never start playback")
    let asset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
    XCTAssertEqual(asset.url.scheme, "bloom-media")
    XCTAssertFalse(asset.url.isFileURL)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.vault.root.path).sorted(), before)
    await review.close()
    XCTAssertNil(review.player)
    XCTAssertNil(player.currentItem, "The actual player item must be detached before review ownership is released")
    XCTAssertEqual(player.rate, 0)
    try await store.releaseExclusiveWorkspace()
  }
  @MainActor func testClosingPendingReviewJoinsBeforeAnyLateCapabilityCanAppear() async throws {
    _ = NSApplication.shared
    let (store, original, draft) = try await fixture()
    let review = BlessengerMediaReview(original: original, destination: draft, insertion: nil)
    review.load(store: store)
    await review.close()
    XCTAssertFalse(review.loading)
    XCTAssertNil(review.player)
    XCTAssertFalse(review.canTranscribe)
    review.load(store: store)
    await Task.yield()
    XCTAssertNil(review.player)
    XCTAssertFalse(review.loading)
    try await store.releaseExclusiveWorkspace()
  }
  @MainActor func testTranscriptEditingDoesNotMutateOriginalAndSaveIsExplicit() async throws {
    let (store, original, draft) = try await fixture()
    let review = BlessengerMediaReview(original: original, destination: draft, insertion: nil)
    review.load(store: store)
    for _ in 0..<400 where review.loading { try await Task.sleep(for: .milliseconds(20)) }
    review.edit("  Reviewed cafe\u{301}.\r\n")
    XCTAssertTrue(review.dirty)
    let beforeSave = try await store.blessengerSnapshot()
    XCTAssertNil(beforeSave.blessenger?.transcripts)
    let (saved, version) = try await review.save(store: store)
    XCTAssertFalse(review.dirty)
    XCTAssertEqual(saved.blessenger!.draft(for: nil), draft)
    XCTAssertEqual(saved.attachments.first { $0.id == original.id }, original)
    XCTAssertEqual(try store.vault.get(.attachment, id: version.id), Data(review.transcript.utf8))
    let (same, repeated) = try await review.save(store: store)
    XCTAssertEqual(repeated.id, version.id, "Reusing a saved snapshot must not create duplicate versions")
    XCTAssertEqual(same.blessenger!.generation, saved.blessenger!.generation)
    await review.close(); try await store.releaseExclusiveWorkspace()
  }
  @MainActor func testNativeTranscriptInsertionUsesCapturedCaretAndUndoWithoutSending() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let view = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
    view.isRichText = false; view.isEditable = true; view.allowsUndo = true
    window.contentView = view; window.makeFirstResponder(view)
    var draft = BlessengerDraft(id: .init()); draft.text = "Before  after"
    view.string = draft.text; view.setSelectedRange(NSRange(location: 7, length: 0))
    var sends = 0; view.onSend = { sends += 1 }
    let insertion = try XCTUnwrap(BlessengerTranscriptInsertion(view: view, draft: draft))
    try insertion.insert("cafe\u{301}", current: draft)
    XCTAssertEqual(Array(view.string.utf8), Array("Before cafe\u{301} after".utf8))
    XCTAssertEqual(sends, 0)
    let undo = try XCTUnwrap(view.undoManager)
    XCTAssertTrue(undo.canUndo)
    undo.undo()
    XCTAssertEqual(Array(view.string.utf8), Array(draft.text.utf8))
    undo.redo()
    XCTAssertEqual(Array(view.string.utf8), Array("Before cafe\u{301} after".utf8))
  }
  @MainActor func testNativeTranscriptInsertionRefusesReplacementDraftCaretAndIME() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let view = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
    view.isEditable = true; window.contentView = view
    var draft = BlessengerDraft(id: .init()); draft.text = "Exact"
    view.string = draft.text; view.setSelectedRange(NSRange(location: 5, length: 0))
    let insertion = try XCTUnwrap(BlessengerTranscriptInsertion(view: view, draft: draft))
    var replacement = draft; replacement.version = UUID()
    XCTAssertThrowsError(try insertion.insert(" text", current: replacement))
    view.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertThrowsError(try insertion.insert(" text", current: draft))
    XCTAssertEqual(view.string, draft.text)
    view.setSelectedRange(NSRange(location: 5, length: 0))
    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertThrowsError(try insertion.insert(" text", current: draft))
  }
  @MainActor func testPDFPreviewRefusesURLAndRemoteActions() {
    _ = NSApplication.shared
    let view = BlessengerReadOnlyPDFView(frame: .zero)
    // The read-only view has no authority to launch these actions even without
    // a document. These calls exercise its override and both delegate routes.
    view.perform(PDFActionURL(url: URL(string: "https://example.invalid/private")!))
    view.pdfViewWillClick(onLink: view, with: URL(fileURLWithPath: "/ungranted-file"))
    XCTAssertNil(view.document)
    XCTAssertNil(view.currentDestination)
  }
  @MainActor func testTranscriptReplacementHasOneUndoAndRefusedInsertionAddsNone() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let view = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
    view.isRichText = false; view.isEditable = true; view.allowsUndo = true
    window.contentView = view; window.makeFirstResponder(view)
    var draft = BlessengerDraft(id: .init()); draft.text = "Prefix 🪶 suffix"
    view.string = draft.text; view.setSelectedRange(NSRange(location: 7, length: 2))
    let insertion = try XCTUnwrap(BlessengerTranscriptInsertion(view: view, draft: draft))
    let undo = try XCTUnwrap(view.undoManager); undo.removeAllActions()
    view.maximumUTF8Bytes = 1
    XCTAssertThrowsError(try insertion.insert("cafe\u{301}", current: draft))
    XCTAssertFalse(undo.canUndo, "Pure failed validation must not register a native edit")
    XCTAssertEqual(Array(view.string.utf8), Array(draft.text.utf8))
    view.maximumUTF8Bytes = 2_097_152
    try insertion.insert("cafe\u{301}", current: draft)
    XCTAssertEqual(Array(view.string.utf8), Array("Prefix cafe\u{301} suffix".utf8))
    undo.undo()
    XCTAssertEqual(Array(view.string.utf8), Array(draft.text.utf8))
    XCTAssertFalse(undo.canUndo, "A single transcript replacement must not leave a second undo")
    undo.redo()
    XCTAssertEqual(Array(view.string.utf8), Array("Prefix cafe\u{301} suffix".utf8))
  }
  @MainActor func testPrivateVideoReviewKeepsOriginalTrackAndNeverAutoplays() async throws {
    _ = NSApplication.shared
    let (store, _, draft) = try await fixture()
    let url = try XCTUnwrap(Bundle.module.url(forResource: "scene-speech", withExtension: "mp4", subdirectory: "Fixtures/Storyboard"))
    let bytes = try Data(contentsOf: url)
    let imported = try AttachmentProcessor.inspect(name: "Consultation video.mp4", data: bytes)
    let state = try await store.blessengerImport(imported, draftID: draft.id, expectedVersion: draft.version)
    let review = BlessengerMediaReview(original: imported.record, destination: state.blessenger!.draft(for: nil), insertion: nil)
    review.load(store: store)
    for _ in 0..<400 where review.loading { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNil(review.issue)
    let player = try XCTUnwrap(review.player), item = try XCTUnwrap(player.currentItem)
    XCTAssertEqual(item.status, .readyToPlay); XCTAssertEqual(player.rate, 0)
    let audio = try await item.asset.loadTracks(withMediaType: .audio)
    let video = try await item.asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(audio.count, 1); XCTAssertEqual(video.count, 1)
    XCTAssertTrue(review.canTranscribe)
    XCTAssertEqual(try store.vault.get(.attachment, id: imported.record.id), bytes)
    await review.close()
    XCTAssertNil(player.currentItem)
    try await store.releaseExclusiveWorkspace()
  }
  @MainActor func testPDFReviewIncludesAllOriginalPagesBeyondModelRasterLimit() async throws {
    _ = NSApplication.shared
    let (store, _, draft) = try await fixture()
    let document = PDFDocument()
    let image = NSImage(size: NSSize(width: 60, height: 80), flipped: false) { bounds in
      NSColor.white.setFill(); NSBezierPath(rect: bounds).fill(); return true
    }
    for i in 0..<9 { document.insert(try XCTUnwrap(PDFPage(image: image)), at: i) }
    let bytes = try XCTUnwrap(document.dataRepresentation())
    let imported = try AttachmentProcessor.inspect(name: "Nine original pages.pdf", data: bytes)
    let state = try await store.blessengerImport(imported, draftID: draft.id, expectedVersion: draft.version)
    let review = BlessengerMediaReview(original: imported.record, destination: state.blessenger!.draft(for: nil), insertion: nil)
    review.load(store: store)
    for _ in 0..<400 where review.loading { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNil(review.issue); XCTAssertEqual(review.pdf?.pageCount, 9)
    XCTAssertNil(review.player); XCTAssertFalse(review.hasTranscriptEditor)
    XCTAssertEqual(try store.vault.get(.attachment, id: imported.record.id), bytes)
    await review.close(); XCTAssertNil(review.pdf)
    try await store.releaseExclusiveWorkspace()
  }

}
