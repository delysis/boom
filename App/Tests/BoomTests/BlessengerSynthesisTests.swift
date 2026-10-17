import BoomCore
import Foundation
import XCTest
@testable import Boom

/// Store tests use explicit generated-result fixtures, not real-model evidence.
final class BlessengerSynthesisTests: XCTestCase {
  private let provider = "component-fixture-not-inference"
  private func replies() -> ChatRecord {
    ChatRecord(title: "Captured case", messages: [
      ChatMessage(role: .user, text: "  Exact question\r\n🪷 e\u{301}  "),
      ChatMessage(role: .assistant, text: "First independent view.", provider: provider,
        speaker: Speaker(name: "First", voiceID: UUID(), voiceRevision: String(repeating: "a", count: 64))),
      ChatMessage(role: .assistant, text: "Second, contrasting view.", provider: provider,
        speaker: Speaker(name: "Second", voiceID: UUID(), voiceRevision: String(repeating: "b", count: 64)))])
  }
  func testSynthesisCapturesExactRepliesInConversationOrder() throws {
    let chat = replies(), source = try BlessengerSynthesis(chat: chat,
      responseIDs: Array(chat.messages.dropFirst().map(\.id).reversed()))
    XCTAssertEqual(source.replies.map(\.id), Array(chat.messages.dropFirst().map(\.id)))
    XCTAssertEqual(Array(source.question.text.utf8), Array(chat.messages[0].text.utf8))
    XCTAssertEqual(source.sources.map(\.kind), Array(repeating: BlessengerSources.consultation, count: 2))
    let plan = try source.plan()
    XCTAssertTrue(plan.rawPrompt.contains("Synthesize the independent consultations"))
    XCTAssertTrue(plan.rawPrompt.contains("First independent view."))
    XCTAssertTrue(plan.rawPrompt.contains("Second, contrasting view."))
    XCTAssertTrue(plan.rawPrompt.contains("Exact question"))
  }
  func testSynthesisRejectsInventedIncompleteSameSpeakerAndOldRoundSources() throws {
    let chat = replies(), ids = Array(chat.messages.dropFirst().map(\.id))
    XCTAssertThrowsError(try BlessengerSynthesis(chat: chat, responseIDs: [ids[0]]))
    XCTAssertThrowsError(try BlessengerSynthesis(chat: chat, responseIDs: [ids[0], ids[0]]))
    XCTAssertThrowsError(try BlessengerSynthesis(chat: chat, responseIDs: [ids[0], UUID()]))
    for state in [MessageState.pending, .failed, .cancelled] {
      var changed = chat; changed.messages[1].state = state
      XCTAssertThrowsError(try BlessengerSynthesis(chat: changed, responseIDs: ids))
    }
    var authored = chat; authored.messages[1].authoredByUser = true
    XCTAssertThrowsError(try BlessengerSynthesis(chat: authored, responseIDs: ids))
    var sameSpeaker = chat; sameSpeaker.messages[2].speaker = sameSpeaker.messages[1].speaker
    XCTAssertThrowsError(try BlessengerSynthesis(chat: sameSpeaker, responseIDs: ids))
    var nextRound = chat; nextRound.messages.append(ChatMessage(role: .user, text: "A different question"))
    XCTAssertThrowsError(try BlessengerSynthesis(chat: nextRound, responseIDs: ids))
  }
  func testDerivedCitationRejectsEditedContentButIgnoresFeedback() throws {
    var message = replies().messages[1]
    let source = try BlessengerSources.response(message)
    message.feedback = .helpful
    XCTAssertEqual(try BlessengerSources.response(message), source)
    message.text += " changed"
    XCTAssertNotEqual(try BlessengerSources.response(message), source)
    let chat = replies(), synthesis = try BlessengerSynthesis(chat: chat, responseIDs: Array(chat.messages.dropFirst().map(\.id)))
    var state = WorkspaceState(); state.chats = [chat]
    try synthesis.revalidate(in: state)
    state.chats[0].messages[1].text += " changed"
    XCTAssertThrowsError(try synthesis.revalidate(in: state))
  }
  func testRetainedSynthesisCitationsCannotPointForwardOrLoseTheirSource() throws {
    var chat = replies()
    let sources = try chat.messages.dropFirst().map(BlessengerSources.response)
    let result = ChatMessage(role: .assistant, text: "A synthesis", sources: sources,
      provider: provider, speaker: Speaker(name: "Synthesis"))
    chat.messages.append(result)
    try BlessengerSources.validateDerivations(in: chat)
    var changed = chat; changed.messages.swapAt(1, 3)
    XCTAssertThrowsError(try BlessengerSources.validateDerivations(in: changed))
    changed = chat; changed.messages.remove(at: 1)
    XCTAssertThrowsError(try BlessengerSources.validateDerivations(in: changed))
    changed = chat; changed.messages[1].text = "Not the cited text"
    XCTAssertThrowsError(try BlessengerSources.validateDerivations(in: changed))
    changed = chat; changed.messages.append(changed.messages[1])
    XCTAssertThrowsError(try BlessengerSources.validateDerivations(in: changed))
  }

  private func store() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-synthesis-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return try WorkspaceStore(rootOverride: root,
      privateSession: BlessengerKeySession { _ in Data(repeating: 0x41, count: 32) })
  }
  private func fixture(_ store: WorkspaceStore) async throws -> (WorkspaceState, BlessengerSynthesis, BlessengerPreparedTurn) {
    _ = try await store.openBlessenger(catalog: BlessengerCatalog(sourceRevision: "fixture", sourceSHA256: "fixture", entries: []))
    var chat = replies(), voices: [Voice] = []
    for index in 1...2 {
      let voice = try ProductCore.voice(VoiceDraft(id: chat.messages[index].speaker!.voiceID!,
        slug: "consultant-\(index)", name: chat.messages[index].speaker!.name, instructions: "Independent fixture consultant."))
      voices.append(voice); chat.messages[index].speaker = voice.speaker
      let plan = try ProductCore.prompt(voice: voice, history: [], instructions: "", context: "",
        request: chat.messages[0].text, routing: [])
      let record = ConsultationReceipt(operationID: UUID(), seed: 7, state: .complete,
        model: provider, voice: voice, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt),
        tokenIDs: [], stopReason: "owned-fixture", elapsedSeconds: 0, generationPolicy: nil, attemptID: UUID(), responseID: chat.messages[index].id)
      try store.vault.encode(record, kind: .receipt, id: chat.messages[index].id)
      try store.vault.encode(record, kind: .receipt, id: record.attemptID!)
    }
    let captured = chat, capturedVoices = voices
    let profile = try BlessengerProfile().resolvingModel(path: "/fixture/model", identity: provider)
    let state = try await store.blessengerTransaction { state, product in
      for voice in capturedVoices {
        state.chats.append(ChatRecord(id: voice.id, title: voice.name, instructions: voice.instructions))
        state.voices.append(voice)
      }
      state.chats.append(captured); state.selectedChat = captured.id
      product.addresses[captured.id] = BlessengerAddress(recipients: capturedVoices.map { BlessengerContact($0) }, profile: profile)
      var local = BlessengerDraft(id: captured.id); local.text = "Do not consume the conversation draft."
      product.drafts.append(local)
      product.drafts[0].text = "Keep New Message intact, too."
    }.0
    let synthesis = try BlessengerSynthesis(chat: captured, responseIDs: Array(captured.messages.dropFirst().map(\.id)))
    let plan = try synthesis.plan(), id = UUID(), flag = CancellationFlag()
    let receipt = ConsultationReceipt(operationID: flag.operationID, seed: 8, state: .pending,
      model: provider, voice: nil, plan: plan, sources: synthesis.sources,
      promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [], stopReason: "pending", elapsedSeconds: 0,
      generationPolicy: nil, attemptID: UUID(), responseID: id)
    var action = BlessengerDraft(id: captured.id); action.text = "Synthesize selected replies"
    let turn = BlessengerPreparedTurn(chatID: captured.id, draft: action, history: captured, contacts: [],
      profile: profile, sourceDigests: synthesis.sources, context: try synthesis.context(),
      responseIDs: [id], receipts: [receipt], voices: [nil], outputLimit: profile.maximumTokens,
      resolvedProfile: profile, synthesis: synthesis)
    return (state, synthesis, turn)
  }
  func testSynthesisAdmissionAddsOnlyOneAttributedResponseAndPreservesBothDrafts() async throws {
    let store = try store(), (before, source, turn) = try await fixture(store)
    let admitted = try await store.blessengerAdmit(turn)
    let chat = try XCTUnwrap(admitted.chats.first { $0.id == source.chat.id })
    XCTAssertEqual(chat.messages.count, source.chat.messages.count + 1)
    XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
    XCTAssertEqual(chat.messages.last?.speaker, Speaker(name: "Synthesis"))
    XCTAssertEqual(chat.messages.last?.sources, source.sources)
    XCTAssertEqual(admitted.blessenger!.drafts, before.blessenger!.drafts)
    XCTAssertEqual(admitted.voices, before.voices)
    do { _ = try await store.blessengerAdmit(turn); XCTFail("Duplicate synthesis admitted") } catch {}
    var completed = turn.receipts[0]; completed.state = .complete; completed.stopReason = "owned-fixture"
    let final = try await store.blessengerFinish(completed, messageID: turn.responseIDs[0], text: "A deliberately attributed synthesis.")
    XCTAssertEqual(final.chats.first { $0.id == source.chat.id }?.messages.last?.state, .complete)
    XCTAssertEqual(final.blessenger!.drafts, before.blessenger!.drafts)
    try final.blessenger!.validate(in: final)
    try await store.releaseExclusiveWorkspace()
  }
  func testSynthesisMissingReceiptRefusesBeforeAdmissionAndCitationChangeRefusesSuccess() async throws {
    let store = try store(), (before, source, turn) = try await fixture(store)
    let record = try store.vault.get(.receipt, id: source.replies[0].id)
    try store.vault.remove(.receipt, id: source.replies[0].id)
    do { _ = try await store.blessengerAdmit(turn); XCTFail("A generated-looking source without receipt was admitted") } catch {}
    let untouched = try await store.blessengerSnapshot()
    XCTAssertEqual(untouched.chats, before.chats)
    try store.vault.put(record, kind: .receipt, id: source.replies[0].id)
    _ = try await store.blessengerAdmit(turn)
    var completed = turn.receipts[0]; completed.state = .complete
    // sources is deliberately immutable; construct a hostile decoded record.
    let encoded = try JSONEncoder().encode(completed)
    var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    altered["sources"] = []
    completed = try JSONDecoder().decode(ConsultationReceipt.self,
      from: JSONSerialization.data(withJSONObject: altered))
    do { _ = try await store.blessengerFinish(completed, messageID: turn.responseIDs[0], text: "Forged source set")
      XCTFail("Changed citation authority was accepted") } catch {}
    completed = turn.receipts[0]; completed.state = .failed; completed.failure = "Fixture cancellation"
    let settled = try await store.blessengerFinish(completed, messageID: turn.responseIDs[0], text: "")
    XCTAssertTrue(settled.blessenger!.attempts.isEmpty)
    XCTAssertEqual(settled.blessenger!.drafts, before.blessenger!.drafts)
    try await store.releaseExclusiveWorkspace()
  }
}
