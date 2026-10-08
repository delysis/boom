import AppKit
import AVFoundation
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class RecordedClipTests: XCTestCase {
  private func clip() throws -> Data {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
    buffer.frameLength = buffer.frameCapacity
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    for i in 0..<32_000 { channel[i] = Float(sin(Double(i) * 0.1)) * 0.5 }
    return try RecordedClip.wav(buffer)
  }
  func testRecordedClipHasRealPlayablePCMAndPreservesSampleCount() async throws {
    let bytes = try clip()
    XCTAssertEqual(bytes.count, 44 + 32_000 * 2)
    let reader = try await MemoryMedia(bytes: bytes).audioReader()
    let decoded = try XCTUnwrap(reader.next(flag: CancellationFlag()))
    XCTAssertEqual(decoded.frameLength, 32_000)
    XCTAssertEqual(decoded.format.sampleRate, 16_000)
    XCTAssertEqual(decoded.floatChannelData![0][50], Float(sin(5.0)) * 0.5, accuracy: 0.001)
    XCTAssertNil(try reader.next(flag: CancellationFlag()))
  }
  @MainActor func testRecordingAttachesEncryptedOriginalWithoutTranscribingSendingOrOpeningSetup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-recording-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.draft = "Keep these words."
    let bytes = try clip()
    try await model.attachRecordedAudio(bytes, chatID: model.state.selectedChat, documentID: model.state.selectedDocument)
    let id = try XCTUnwrap(model.pendingAttachments.first)
    let record = try XCTUnwrap(model.state.attachments.first { $0.id == id })
    XCTAssertEqual(record.awaitingTranscription, true); XCTAssertEqual(record.text, "")
    XCTAssertEqual(model.draft, "Keep these words."); XCTAssertFalse(model.showingModels)
    XCTAssertTrue(model.selectedChat?.messages.isEmpty == true)
    XCTAssertEqual(try store.vault.get(.attachment, id: id), bytes)
    let sealed = try Data(contentsOf: store.vault.recordURL(.attachment, id))
    XCTAssertNil(sealed.range(of: bytes))
    try await model.shutdown()
    let loaded = try await store.load().get().0
    XCTAssertEqual(loaded.attachments.first { $0.id == id }, record)
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(reopened.pendingAttachments, [id])
    XCTAssertTrue(reopened.selectedChat?.messages.isEmpty == true)
    try await reopened.shutdown()
  }
  @MainActor func testRecordingCannotMoveToAnotherConversationDuringCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-recording-scope-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256)), loadModels: false)
    let capturedChat = model.state.selectedChat
    try model.newChat()
    do {
      try await model.attachRecordedAudio(clip(), chatID: capturedChat, documentID: model.state.selectedDocument)
      XCTFail("Recording changed conversations.")
    } catch { XCTAssertTrue(model.pendingAttachments.isEmpty); XCTAssertTrue(model.state.attachments.isEmpty) }
    try await model.shutdown()
  }
}
