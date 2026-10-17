import BoomCore
import Foundation
import XCTest
@testable import Boom

final class BlessengerContextTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, WorkspaceState, [ChatMessage], UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-context-" + UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, privateSession: BlessengerKeySession { _ in Data(repeating: 0x56, count: 32) })
    _ = try await store.openBlessenger(catalog: .init(sourceRevision: "fixture", sourceSHA256: "fixture", entries: []))
    let bytes = try BlessengerWave.encode([Float](repeating: 0.025, count: 640), rate: 16000)
    var records: [AttachmentRecord] = [], history: [ChatMessage] = []
    for n in 0..<101 {
      let item = try AttachmentProcessor.inspect(name: "Original \(n).wav", data: bytes)
      try store.vault.put(bytes, kind: .attachment, id: item.record.id)
      try store.vault.put(item.receipt, kind: .receipt, id: item.record.id)
      records.append(item.record)
      if n < 100 {
        history.append(ChatMessage(role: .user, text: "Question \(n)", sources: [item.record.reference], directAttachments: [item.record.id]))
        history.append(ChatMessage(role: .assistant, text: "Answer \(n)", sources: [item.record.reference]))
      }
    }
    let captured = records
    let state = try await store.blessengerTransaction { state, _ in state.attachments = captured }.0
    // Authenticated but wrong old original: reading it as a selected payload
    // would fail identity validation. It must not be decoded for this turn.
    try store.vault.put(Data("wrong old bytes".utf8), kind: .attachment, id: records[0].id)
    return (store, state, history, records[100].id)
  }
  func testLongHistorySelectsWholeUnitsBeforeReadingAnyExcludedOriginal() async throws {
    let (store, state, history, current) = try await fixture()
    let capture = try await BlessengerContext.prepare(history: history, current: [current], text: "Next",
      state: state, store: store, supportsRawAudio: true, flag: CancellationFlag())
    XCTAssertEqual(capture.window.omittedUnits, 93)
    XCTAssertEqual(capture.window.omittedMessages, 186)
    XCTAssertEqual(capture.history.map(\.id), Array(history.suffix(14)).map(\.id))
    XCTAssertEqual(capture.payloads.count, 8)
    XCTAssertEqual(capture.prior.occurrences.count, 7)
    XCTAssertEqual(capture.current.payloads.map { $0.reference.id }, [current])
    XCTAssertFalse(capture.window.sourceIds.contains(history[0].directAttachments![0]))
    XCTAssertEqual(capture.history.filter { $0.role == .user }.count, 7)
    try await store.releaseExclusiveWorkspace()
  }
  func testTokenFitSlidesOnlyCompleteQuestionAndAllRepliesAndNeverRewritesCurrent() async throws {
    let (store, state, history, current) = try await fixture()
    let request = "  Preserve exact 🪶 e\u{301} question.\r\n"
    let capture = try await BlessengerContext.prepare(history: history, current: [current], text: request,
      state: state, store: store, supportsRawAudio: true, flag: CancellationFlag())
    var attempts = 0
    let result = try await BlessengerContext.selectFitting(capture, flag: CancellationFlag()) { candidate in
      attempts += 1
      guard candidate.history.count <= 4 else { throw BoomError.budget("Deterministic context capacity") }
      return try ProductCore.consultationRound(voices: [nil], history: candidate.history, instructions: "Instructions",
        context: candidate.current.context, request: request, routing: [], promptContract: .referenceHistoryV2,
        historyMedia: candidate.prior.occurrences, currentMedia: [current])
    }
    XCTAssertEqual(result.capture.history.map(\.id), Array(history.suffix(4)).map(\.id))
    XCTAssertEqual(result.capture.window.omittedUnits, 98)
    XCTAssertEqual(result.capture.window.reason, "model_context_budget")
    XCTAssertEqual(result.capture.payloads.count, 3)
    XCTAssertLessThanOrEqual(attempts, 6)
    XCTAssertTrue(result.plans[0].messages.last!.content.contains(request))
    XCTAssertEqual(result.plans[0].placedMediaIDs, Set(result.capture.payloads.map { $0.reference.id }))
    try await store.releaseExclusiveWorkspace()
  }
  func testAliasesRetainChronologyButTransitiveReceiptCitationsAreNotAttachments() async throws {
    let (store, state, _, current) = try await fixture()
    let excluded = state.attachments[0].reference
    let history = (0..<20).flatMap { n -> [ChatMessage] in
      [ChatMessage(role: .user, text: "Q\(n)", sources: [excluded], directAttachments: [current]),
       ChatMessage(role: .assistant, text: "A\(n)", sources: [excluded])]
    }
    let capture = try await BlessengerContext.prepare(history: history, current: [current], text: "Next",
      state: state, store: store, supportsRawAudio: true, flag: CancellationFlag())
    XCTAssertEqual(capture.history.count, 30)
    XCTAssertEqual(capture.window.mediaOccurrences, 16)
    XCTAssertEqual(capture.payloads.count, 1)
    XCTAssertEqual(capture.window.sourceIds, [current])
    let plan = try ProductCore.consultationRound(voices: [nil], history: capture.history, instructions: "", context: "",
      request: "Next", routing: [], promptContract: .referenceHistoryV2,
      historyMedia: capture.prior.occurrences, currentMedia: [current])[0]
    let expanded = try RawWritingInput.expandChatMedia(plan, media: capture.payloads)
    XCTAssertEqual(expanded.media.map { $0.reference.id }, Array(repeating: current, count: 16))
    try await store.releaseExclusiveWorkspace()
  }
  func testMandatoryCurrentCorruptionAndCancelledPreparationDoNotBecomeOmissions() async throws {
    let (store, state, history, current) = try await fixture()
    try store.vault.put(Data("changed current".utf8), kind: .attachment, id: current)
    do {
      _ = try await BlessengerContext.prepare(history: history, current: [current], text: "Next", state: state,
        store: store, supportsRawAudio: true, flag: CancellationFlag())
      XCTFail("Corrupt current original was omitted or admitted")
    } catch {}
    let flag = CancellationFlag(); flag.cancel()
    do {
      _ = try await BlessengerContext.prepare(history: history, current: [], text: "Next", state: state,
        store: store, supportsRawAudio: true, flag: flag)
      XCTFail("Cancelled work decoded historical audio")
    } catch is CancellationError {} catch { XCTFail("Unexpected cancellation failure: \(error)") }
    let final = try await store.blessengerSnapshot()
    XCTAssertEqual(final.chats.count, 0)
    try await store.releaseExclusiveWorkspace()
  }
  func testRepliesRemainWithTheirQuestionAndMalformedHistoryIsRejected() throws {
    let user = ChatMessage(role: .user, text: "Question"), first = ChatMessage(role: .assistant, text: "First")
    let second = ChatMessage(role: .assistant, text: "Second"), next = ChatMessage(role: .user, text: "Next")
    let units = try BlessengerContext.units([user, first, second, next])
    XCTAssertEqual(units.map(\.messages), [[user.id, first.id, second.id], [next.id]])
    XCTAssertThrowsError(try BlessengerContext.units([user, first, user]))
  }
}
