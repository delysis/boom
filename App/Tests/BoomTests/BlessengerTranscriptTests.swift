import BoomCore
import Foundation
import XCTest
@testable import Boom

final class BlessengerTranscriptTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, WorkspaceState, AttachmentRecord, URL) {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-transcript-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: parent) }
    let store = try WorkspaceStore(rootOverride: parent.appendingPathComponent("source"),
      privateSession: BlessengerKeySession { _ in Data(repeating: 0x56, count: 32) })
    let before = try await store.openBlessenger(catalog: .init(sourceRevision: "fixture", sourceSHA256: "fixture", entries: []))
    let bytes = try BlessengerWave.encode([Float](repeating: 0, count: 16000), rate: 16000)
    let item = try AttachmentProcessor.inspect(name: "Voice note.wav", data: bytes)
    let state = try await store.blessengerImport(item, draftID: BlessengerDraft.unsentID,
      expectedVersion: before.blessenger!.draft(for: nil).version)
    return (store, state, item.record, parent)
  }
  func testEditedTranscriptIsExactImmutableSeparateAndNeverAutomaticallySent() async throws {
    let (store, before, original, _) = try await fixture()
    let bytes = try store.vault.get(.attachment, id: original.id)
    let text = "  Speech 🪶 and cafe\u{301}.\r\nSecond line.  "
    let (saved, version) = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
      text: text, coverage: "Partial recognition; check original", origin: .onDevice, flag: CancellationFlag())
    XCTAssertEqual(saved.blessenger!.draft(for: nil), before.blessenger!.draft(for: nil))
    XCTAssertEqual(saved.chats, before.chats)
    XCTAssertEqual(saved.attachments.first { $0.id == original.id }, original)
    XCTAssertEqual(try store.vault.get(.attachment, id: original.id), bytes)
    XCTAssertEqual(try store.vault.get(.attachment, id: version.id), Data(text.utf8))
    let index = try Data(contentsOf: store.root.appendingPathComponent("workspace.json"))
    XCTAssertNil(index.range(of: Data(text.utf8)))
    let d = saved.blessenger!.draft(for: nil)
    let attached = try await store.blessengerAttachTranscript(version, draftID: d.id, expectedVersion: d.version)
    XCTAssertEqual(attached.blessenger!.draft(for: nil).attachments, [original.id, version.id])
    XCTAssertTrue(attached.chats.isEmpty)
    XCTAssertEqual(attached.blessenger!.draft(for: nil).text, d.text)
    try await store.releaseExclusiveWorkspace()
  }
  func testStaleTranscriptEditorCannotOverwriteNewerVersionAndOldVersionRemainsReadable() async throws {
    let (store, _, original, _) = try await fixture()
    let (_, first) = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
      text: "First", coverage: "Partial", origin: .onDevice, flag: CancellationFlag())
    let (secondState, second) = try await store.blessengerSaveTranscript(original: original, expectedLatest: first.id,
      text: "Corrected", coverage: "Human checked", origin: .edited, flag: CancellationFlag())
    do {
      _ = try await store.blessengerSaveTranscript(original: original, expectedLatest: first.id,
        text: "Stale", coverage: "Unknown", origin: .edited, flag: CancellationFlag())
      XCTFail("Stale editor overwrote newer transcript")
    } catch {}
    let after = try await store.blessengerSnapshot()
    XCTAssertEqual(after.blessenger!.generation, secondState.blessenger!.generation)
    XCTAssertEqual(after.blessenger!.transcripts?[original.id]?.map(\.id), [first.id, second.id])
    XCTAssertEqual(second.previousID, first.id)
    XCTAssertEqual(try store.vault.get(.attachment, id: first.id), Data("First".utf8))
    try await store.releaseExclusiveWorkspace()
  }
  func testTranscriptAttachRejectsChangedDraftWithoutReplacingAuthorBytes() async throws {
    let (store, _, original, _) = try await fixture()
    let (saved, version) = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
      text: "Retained transcript", coverage: "Manual", origin: .manual, flag: CancellationFlag())
    let prior = saved.blessenger!.draft(for: nil)
    var edited = prior; edited.text = "More author typing"; edited.version = UUID()
    _ = try await store.blessengerSaveDraft(edited, expectedVersion: prior.version)
    do {
      _ = try await store.blessengerAttachTranscript(version, draftID: prior.id, expectedVersion: prior.version)
      XCTFail("Stale attachment changed a new draft")
    } catch {}
    let final = try await store.blessengerSnapshot()
    XCTAssertEqual(final.blessenger!.draft(for: nil), edited)
    try await store.releaseExclusiveWorkspace()
  }
  func testCancelledOrInvalidTranscriptSaveLeavesOriginalAndIndexIntact() async throws {
    let (store, before, original, _) = try await fixture()
    let cancelled = CancellationFlag(); cancelled.cancel()
    do {
      _ = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
        text: "Cancelled", coverage: "Manual", origin: .manual, flag: cancelled)
      XCTFail("Cancelled save committed")
    } catch is CancellationError {} catch { XCTFail("Wrong cancellation: \(error)") }
    for text in ["", "\0", String(repeating: "x", count: 262145)] {
      do {
        _ = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
          text: text, coverage: "Manual", origin: .manual, flag: CancellationFlag())
        XCTFail("Invalid transcript committed")
      } catch {}
    }
    let after = try await store.blessengerSnapshot()
    XCTAssertEqual(after.blessenger!.generation, before.blessenger!.generation)
    XCTAssertEqual(after.attachments, before.attachments)
    try await store.releaseExclusiveWorkspace()
  }
  func testEncryptedBackupIncludesEveryTranscriptVersionAndItsOriginal() async throws {
    let (store, _, original, parent) = try await fixture()
    let (_, first) = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
      text: "First", coverage: "Partial", origin: .onDevice, flag: CancellationFlag())
    let (_, second) = try await store.blessengerSaveTranscript(original: original, expectedLatest: first.id,
      text: "Second 🪷", coverage: "Edited", origin: .edited, flag: CancellationFlag())
    let backup = parent.appendingPathComponent("backup"), restored = parent.appendingPathComponent("restored")
    try await store.exportBlessengerBackup(to: backup, flag: CancellationFlag())
    try await store.restoreBlessengerBackup(from: backup, to: restored, flag: CancellationFlag())
    let copy = try WorkspaceStore(rootOverride: restored, privateSession: BlessengerKeySession { _ in Data(repeating: 0x56, count: 32) })
    let reopened = try await copy.openBlessenger(catalog: .init(sourceRevision: "fixture", sourceSHA256: "fixture", entries: []))
    XCTAssertEqual(reopened.blessenger!.transcripts?[original.id]?.map(\.id), [first.id, second.id])
    XCTAssertEqual(try copy.vault.get(.attachment, id: first.id), Data("First".utf8))
    XCTAssertEqual(try copy.vault.get(.attachment, id: second.id), Data("Second 🪷".utf8))
    XCTAssertEqual(try copy.vault.get(.attachment, id: original.id), try store.vault.get(.attachment, id: original.id))
    try await copy.releaseExclusiveWorkspace(); try await store.releaseExclusiveWorkspace()
  }
  func testBrokenTranscriptLineageIsRejectedWithoutRepairingAwayEvidence() async throws {
    let (store, _, original, _) = try await fixture()
    let (saved, version) = try await store.blessengerSaveTranscript(original: original, expectedLatest: nil,
      text: "Manual", coverage: "Check wording", origin: .manual, flag: CancellationFlag())
    var product = saved.blessenger!
    product.transcripts?[original.id] = [version, version]
    XCTAssertThrowsError(try product.validateTranscripts(in: saved))
    var missing = saved; missing.attachments.removeAll { $0.id == original.id }
    XCTAssertThrowsError(try saved.blessenger!.validateTranscripts(in: missing))
    try await store.releaseExclusiveWorkspace()
  }
}
