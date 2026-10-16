import AVFoundation
import BoomCore
import Darwin
import Foundation
import XCTest
@testable import Boom

final class BlessengerTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func store(_ root: URL) throws -> WorkspaceStore {
    try WorkspaceStore(rootOverride: root, privateSession: BlessengerKeySession { _ in Data(repeating: 0x41, count: 32) })
  }
  private var fixtureCatalog: BlessengerCatalog {
    BlessengerCatalog(sourceRevision: "owned-unit-fixture", sourceSHA256: "owned-unit-fixture", entries: [])
  }
  private func turn(_ draft: BlessengerDraft, profile: BlessengerProfile = BlessengerProfile(), history: ChatRecord? = nil) throws -> BlessengerPreparedTurn {
    let id = UUID()
    let plan = try ProductCore.prompt(voice: nil, history: history?.messages ?? [], instructions: "", context: "",
      request: draft.text, routing: [])
    let receipt = ConsultationReceipt(operationID: UUID(), seed: 7, state: .pending, model: "component-fixture-not-inference",
      voice: nil, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [],
      stopReason: "pending", elapsedSeconds: 0, generationPolicy: nil, attemptID: UUID(), responseID: id)
    return BlessengerPreparedTurn(chatID: history?.id ?? UUID(), draft: draft, history: history, contacts: [],
      profile: profile, sourceDigests: [], context: "", responseIDs: [id], receipts: [receipt], voices: [nil], outputLimit: profile.maximumTokens)
  }
  func testNativeDraftTransferIsAtomicAndCannotRepeat() async throws {
    let root = try root(), store = try store(root)
    let initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil), old = draft.version
    draft.text = "  Exact case\r\n🪷 e\u{301}  "; draft.version = UUID()
    let saved = try await store.blessengerSaveDraft(draft, expectedVersion: old)
    let prepared = try turn(draft, profile: saved.blessenger!.defaultProfile)
    let admitted = try await store.blessengerAdmit(prepared)
    XCTAssertEqual(admitted.chats.count, 1)
    XCTAssertEqual(Array(admitted.chats[0].messages[0].text.utf8), Array(draft.text.utf8))
    XCTAssertEqual(admitted.chats[0].messages[1].state, .pending)
    XCTAssertTrue(admitted.blessenger!.draft(for: nil).text.isEmpty)
    do { _ = try await store.blessengerAdmit(prepared); XCTFail("Repeated admission succeeded") } catch {}
    let final = try await store.blessengerSnapshot()
    XCTAssertEqual(final.chats.count, 1)
    let ciphertext = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    XCTAssertNil(ciphertext.range(of: Data(draft.text.utf8)))
    try await store.releaseExclusiveWorkspace()
  }
  func testInterveningDraftAndProfileEditsRefuseWithoutCreatingChat() async throws {
    let store = try store(root()), initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil)
    let old = draft.version; draft.version = UUID(); draft.text = "Initial question"
    let first = try await store.blessengerSaveDraft(draft, expectedVersion: old)
    let captured = try turn(draft, profile: first.blessenger!.defaultProfile)
    let beforeTyping = draft.version; draft.version = UUID(); draft.text += " and more typing"
    _ = try await store.blessengerSaveDraft(draft, expectedVersion: beforeTyping)
    do { _ = try await store.blessengerAdmit(captured); XCTFail("Stale draft admitted") } catch {}
    let current = try await store.blessengerSnapshot()
    XCTAssertTrue(current.chats.isEmpty); XCTAssertEqual(current.blessenger!.draft(for: nil).text, draft.text)
    let capturedProfile = try turn(draft, profile: current.blessenger!.defaultProfile)
    _ = try await store.blessengerTransaction { _, product in product.defaultProfile.id = UUID() }
    do { _ = try await store.blessengerAdmit(capturedProfile); XCTFail("Stale profile admitted") } catch {}
    let final = try await store.blessengerSnapshot()
    XCTAssertTrue(final.chats.isEmpty)
    try await store.releaseExclusiveWorkspace()
  }
  func testFirstCallerTurnDoesNotConsumeTypedDraft() async throws {
    let store = try store(root()), initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil), prior = draft.version
    draft.version = UUID(); draft.text = "Unsent typed note must remain"
    let state = try await store.blessengerSaveDraft(draft, expectedVersion: prior)
    let route = try await store.blessengerBeginCall(selection: nil, expectedDraftVersion: draft.version)
    let original = try BlessengerWave.encode([Float](repeating: 0.1, count: 1600), rate: 16000)
    let imported = try AttachmentProcessor.inspect(name: "Caller fixture.wav", data: original), record = imported.record
    let caller = try await store.blessengerCallerTurn(imported, callID: route.id, epoch: 1, flag: CancellationFlag())
    XCTAssertEqual(caller.snapshot.chats.count, state.chats.count + 1, "The authored caller input must already be durable before prefill.")
    XCTAssertEqual(caller.snapshot.chats.last?.messages.last?.id, caller.inputMessageID)
    var prepared = try turn(caller.draft, profile: route.profile, history: caller.snapshot.chats.first { $0.id == caller.conversationID })
    prepared.caller = caller; prepared.previousQuestionID = caller.inputMessageID
    let admitted = try await store.blessengerAdmit(prepared)
    XCTAssertEqual(admitted.blessenger!.draft(for: nil), draft)
    XCTAssertEqual(admitted.chats.count, state.chats.count + 1)
    XCTAssertEqual(admitted.chats[0].messages[0].directAttachments, [record.id])
    await store.blessengerEndCall(route.id)
    do { _ = try await store.blessengerCallerTurn(imported, callID: route.id, epoch: 2, flag: CancellationFlag()); XCTFail("Ended call admitted audio") } catch {}
    try await store.releaseExclusiveWorkspace()
  }
  func testExclusiveWorkspacePrecedesAnotherCredentialRead() async throws {
    let root = try root(), first = try store(root)
    let counter = ReadCounter()
    XCTAssertThrowsError(try WorkspaceStore(rootOverride: root, privateSession: BlessengerKeySession { _ in
      counter.increment(); return Data(repeating: 0x41, count: 32)
    }))
    XCTAssertEqual(counter.value, 0)
    try await first.releaseExclusiveWorkspace()
  }
  func testCredentialFailureIsCachedAndNeverCreatesPlaintext() throws {
    let counter = ReadCounter()
    let session = BlessengerKeySession { _ in counter.increment(); throw BoomError.denied("Owned denial fixture") }
    XCTAssertThrowsError(try session.cipher(existingRecords: true))
    XCTAssertThrowsError(try session.cipher(existingRecords: false))
    XCTAssertEqual(counter.value, 1)
  }
  func testSealedKVRangeReadChargesEveryAuthenticationTag() throws {
    let file = try root().appendingPathComponent("owned-kv")
    let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, mode_t(0o600))
    XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }
    defer { _ = Darwin.close(fd) }
    let source = Data((0..<150_001).map { UInt8(truncatingIfNeeded: $0 * 37) })
    let cipher = try RecordCipher(key: Data(repeating: 9, count: 32))
    let writer = SealedBlockWriter(fd: fd, total: UInt64(source.count), binding: "owned-file", cipher: cipher) { _ in }
    try source.withUnsafeBytes { bytes in
      try writer.append(bytes.baseAddress!, count: 50_000)
      try writer.append(bytes.baseAddress!.advanced(by: 50_000), count: bytes.count - 50_000)
    }
    try writer.finish()
    XCTAssertEqual(writer.physical, UInt64(source.count + 3 * RecordCipher.overhead))
    for range in [0..<1, 65530..<65550, 130000..<150001, 0..<150001] {
      let recovered = try SealedBlockWriter.read(fd, start: UInt64(range.lowerBound), count: range.count,
        total: UInt64(source.count), binding: "owned-file", cipher: cipher)
      XCTAssertEqual(recovered, source.subdata(in: range))
    }
    XCTAssertThrowsError(try SealedBlockWriter.read(fd, start: 0, count: 1,
      total: UInt64(source.count), binding: "other-file", cipher: cipher))
    var corrupt: UInt8 = 0
    XCTAssertEqual(pread(fd, &corrupt, 1, 50), 1); corrupt ^= 1; XCTAssertEqual(pwrite(fd, &corrupt, 1, 50), 1)
    XCTAssertThrowsError(try SealedBlockWriter.read(fd, start: 0, count: 1,
      total: UInt64(source.count), binding: "owned-file", cipher: cipher))
  }
  func testCallerInputSurvivesPreparationFailureAndReopen() async throws {
    let directory = try root(), first = try store(directory)
    let initial = try await first.openBlessenger(catalog: fixtureCatalog)
    XCTAssertFalse(initial.autocomplete, "Input completion is opt-in.")
    let call = try await first.blessengerBeginCall(selection: nil, expectedDraftVersion: initial.blessenger!.draft(for: nil).version)
    let bytes = try BlessengerWave.encode([Float](repeating: 0.1, count: 3200), rate: 16000)
    let imported = try AttachmentProcessor.inspect(name: "Caller.wav", data: bytes)
    let turn = try await first.blessengerCallerTurn(imported, callID: call.id, epoch: 1, flag: CancellationFlag())
    // Deliberately do not admit a model response: this is the failed-prefill boundary.
    await first.blessengerEndCall(call.id); try await first.releaseExclusiveWorkspace()
    let second = try store(directory)
    let restored = try await second.openBlessenger(catalog: fixtureCatalog)
    let message = try XCTUnwrap(restored.chats.first?.messages.first)
    XCTAssertEqual(message.id, turn.inputMessageID)
    XCTAssertEqual(message.directAttachments, [imported.record.id])
    XCTAssertEqual(try second.vault.get(.attachment, id: imported.record.id, limit: 67_108_864), bytes)
    XCTAssertEqual(restored.chats.first?.messages.count, 1)
    XCTAssertTrue(restored.blessenger!.attempts.isEmpty)
    try await second.releaseExclusiveWorkspace()
  }
  func testCallKeepsCapturedSpeechWhenGlobalSettingsChange() async throws {
    let store = try store(root()), initial = try await store.openBlessenger(catalog: fixtureCatalog)
    let call = try await store.blessengerBeginCall(selection: nil, expectedDraftVersion: initial.blessenger!.draft(for: nil).version)
    _ = try await store.blessengerTransaction { _, product in product.defaultSpeech.provider = .apple }
    let imported = try AttachmentProcessor.inspect(name: "Caller.wav",
      data: BlessengerWave.encode([Float](repeating: 0.1, count: 3200), rate: 16000))
    let turn = try await store.blessengerCallerTurn(imported, callID: call.id, epoch: 1, flag: CancellationFlag())
    XCTAssertEqual(turn.speech, call.speech)
    XCTAssertNotEqual(turn.speech?.provider, turn.snapshot.blessenger!.defaultSpeech.provider)
    await store.blessengerEndCall(call.id); try await store.releaseExclusiveWorkspace()
  }
  func testReplayAddsOneResponseWithoutDuplicatingQuestionOrTakingDraft() async throws {
    let store = try store(root()), initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil), prior = draft.version
    draft.text = "Exact question"; draft.version = UUID()
    let saved = try await store.blessengerSaveDraft(draft, expectedVersion: prior)
    let first = try turn(draft, profile: saved.blessenger!.defaultProfile)
    _ = try await store.blessengerAdmit(first)
    var receipt = first.receipts[0]; receipt.state = .failed; receipt.stopReason = "owned-fixture"
    _ = try await store.blessengerFinish(receipt, messageID: first.responseIDs[0], text: "")
    let fork = try await store.blessengerTransaction { state, product in
      let source = state.chats[0]
      let branch = try source.branch(at: source.messages[0].id, includeMessage: true)
      state.chats.append(branch); state.selectedChat = branch.id
      product.addresses[branch.id] = product.addresses[source.id]
      var unsent = BlessengerDraft(id: branch.id); unsent.text = "Do not consume this draft"
      product.drafts.append(unsent)
    }.0
    let branch = try XCTUnwrap(fork.chats.last), question = try XCTUnwrap(branch.messages.last)
    var submitted = BlessengerDraft(id: branch.id); submitted.text = question.text
    var repeatTurn = try turn(submitted, profile: fork.blessenger!.addresses[branch.id]!.profile, history: branch)
    repeatTurn.previousQuestionID = question.id
    let admitted = try await store.blessengerAdmit(repeatTurn)
    let current = try XCTUnwrap(admitted.chats.last)
    XCTAssertEqual(current.messages.filter { $0.role == .user }.count, 1)
    XCTAssertEqual(current.messages.first?.id, question.id)
    XCTAssertEqual(admitted.blessenger!.draft(for: branch.id), fork.blessenger!.draft(for: branch.id))
    try await store.releaseExclusiveWorkspace()
  }
  func testSpeechFlushesShortAnswersAndRejectsRewrittenPrefix() throws {
    let short = try BlessengerPolicy.speech("Yes.", cursor: BlessengerSpeechCursor(), finished: true)
    XCTAssertEqual(short.fragments.map(\.text), ["Yes."])
    let partial = try BlessengerPolicy.speech("One two three fou", cursor: BlessengerSpeechCursor(), finished: false)
    XCTAssertTrue(partial.fragments.isEmpty)
    let first = try BlessengerPolicy.speech("One two three four ", cursor: partial.cursor, finished: false)
    XCTAssertEqual(first.fragments.map(\.text), ["One two three four"])
    XCTAssertThrowsError(try BlessengerPolicy.speech("Changed two three four ", cursor: first.cursor, finished: true))
    let rest = try BlessengerPolicy.speech("One two three four and five.", cursor: first.cursor, finished: true)
    XCTAssertEqual(rest.fragments.map(\.text), ["and five."])
  }
  func testWaveRoundTripAndHonestTraceOverflow() throws {
    let samples: [Float] = [0, -0.75, 0.3, 1]
    let wave = try BlessengerWave.encode(samples, rate: 24000), decoded = try BlessengerWave.decode(wave)
    XCTAssertEqual(decoded.samples.map(\.bitPattern), samples.map(\.bitPattern)); XCTAssertEqual(decoded.rate, 24000)
    var bad = wave; bad[32] = 2
    XCTAssertThrowsError(try BlessengerWave.decode(bad))
    XCTAssertThrowsError(try BlessengerWave.encode([.nan], rate: 24000))
    let trace = BlessengerTrace()
    for i in 0..<513 { trace.record("stage.\(i)", at: Double(i)) }
    XCTAssertEqual(trace.snapshot().events.count, 512); XCTAssertTrue(trace.snapshot().incomplete)
  }
  func testCaptureRejectsAClassificationAfterNewVoicedInput() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
    let capture = try BlessengerCaptureBuffer(source: format)
    func packet(_ amplitude: Float) throws {
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
      buffer.frameLength = 480
      for i in 0..<480 { buffer.floatChannelData![0][i] = amplitude }
      capture.append(buffer, at: AVAudioTime(sampleTime: 0, atRate: 16000))
    }
    for _ in 0..<8 { try packet(0.1) }
    for _ in 0..<8 { try packet(0) }
    let pause = capture.drain().compactMap { event -> UInt64? in if case .pause(let frame, _) = event { return frame }; return nil }.last
    let frame = try XCTUnwrap(pause)
    XCTAssertTrue(capture.isPaused(through: frame))
    XCTAssertFalse(try capture.semanticWindow(through: frame).isEmpty)
    try packet(0.1)
    XCTAssertFalse(capture.isPaused(through: frame))
    XCTAssertThrowsError(try capture.clip(through: frame, ended: 1, decision: "semantic"))
    capture.stop()
  }

  func testPrivateBackupAuthenticatesCopiedStageAndRestoresExactDraftAndAudio() async throws {
    let parent = try root(), original = parent.appendingPathComponent("original")
    let source = try store(original), initial = try await source.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil)
    let previous = draft.version; draft.text = "  Private case\r\n🪷 e\u{301}  "; draft.version = UUID()
    let saved = try await source.blessengerSaveDraft(draft, expectedVersion: previous)
    let bytes = try BlessengerWave.encode([Float](repeating: 0.1, count: 1600), rate: 16000)
    let imported = try AttachmentProcessor.inspect(name: "Authored voice note.wav", data: bytes)
    let attached = try await source.blessengerImport(imported, draftID: draft.id,
      expectedVersion: saved.blessenger!.draft(for: nil).version)
    let destination = parent.appendingPathComponent("backup")
    try await source.exportBlessengerBackup(to: destination, flag: CancellationFlag())
    let ciphertext = try Data(contentsOf: destination.appendingPathComponent("workspace.json"))
    XCTAssertNil(ciphertext.range(of: Data(draft.text.utf8)))
    let recovered = parent.appendingPathComponent("restored")
    try await source.restoreBlessengerBackup(from: destination, to: recovered, flag: CancellationFlag())
    let reopened = try store(recovered), restored = try await reopened.openBlessenger(catalog: fixtureCatalog)
    XCTAssertEqual(restored.blessenger!.draft(for: nil), attached.blessenger!.draft(for: nil))
    XCTAssertEqual(try reopened.vault.get(.attachment, id: imported.record.id, limit: 67_108_864), bytes)
    try await reopened.releaseExclusiveWorkspace(); try await source.releaseExclusiveWorkspace()
  }

  func testPrivateBackupRefusesCorruptOrWrongKeyBeforeDestinationPublication() async throws {
    let parent = try root(), source = try store(parent.appendingPathComponent("source"))
    _ = try await source.openBlessenger(catalog: fixtureCatalog)
    let archive = parent.appendingPathComponent("backup")
    try await source.exportBlessengerBackup(to: archive, flag: CancellationFlag())
    let wrong = try WorkspaceStore(rootOverride: parent.appendingPathComponent("wrong-key"),
      privateSession: BlessengerKeySession { _ in Data(repeating: 0x52, count: 32) })
    let refused = parent.appendingPathComponent("refused")
    do { try await wrong.restoreBlessengerBackup(from: archive, to: refused, flag: CancellationFlag()); XCTFail("Wrong key accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    var corrupt = try Data(contentsOf: archive.appendingPathComponent("workspace.json")); corrupt[corrupt.count - 1] ^= 1
    try corrupt.write(to: archive.appendingPathComponent("workspace.json"))
    do { try await source.restoreBlessengerBackup(from: archive, to: refused, flag: CancellationFlag()); XCTFail("Corrupt archive accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    let existing = parent.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
    let sentinel = existing.appendingPathComponent("author.txt"); try Data("Keep my bytes".utf8).write(to: sentinel)
    do { try await source.restoreBlessengerBackup(from: archive, to: existing, flag: CancellationFlag()); XCTFail("Existing data overwritten") } catch {}
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "Keep my bytes")
    try await wrong.releaseExclusiveWorkspace(); try await source.releaseExclusiveWorkspace()
  }

  func testMuteRetiresQueuedCaptureEventsAndShortResumptionRefreshesPause() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
    let capture = try BlessengerCaptureBuffer(source: format)
    func packet(_ value: Float) throws {
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)); buffer.frameLength = 480
      for i in 0..<480 { buffer.floatChannelData![0][i] = value }
      capture.append(buffer, at: AVAudioTime(sampleTime: 0, atRate: 16000))
    }
    for _ in 0..<8 { try packet(0.1) }
    capture.mute(true); capture.mute(false)
    XCTAssertTrue(capture.drain().isEmpty, "Pre-mute speech must never replay as new caller input.")
    for _ in 0..<8 { try packet(0.1) }
    for _ in 0..<8 { try packet(0) }
    let first = try XCTUnwrap(capture.drain().compactMap { event -> UInt64? in
      if case .pause(let frame, _) = event { return frame }; return nil
    }.last)
    try packet(0.1) // Not enough voiced packets for a second Speech event.
    for _ in 0..<8 { try packet(0) }
    let second = try XCTUnwrap(capture.drain().compactMap { event -> UInt64? in
      if case .pause(let frame, _) = event { return frame }; return nil
    }.last)
    XCTAssertGreaterThan(second, first)
    XCTAssertFalse(capture.isPaused(through: first)); XCTAssertTrue(capture.isPaused(through: second))
    capture.stop()
  }

}
private final class ReadCounter: @unchecked Sendable {
  private let lock = NSLock(); private var count = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  func increment() { lock.lock(); count += 1; lock.unlock() }
}
