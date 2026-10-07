import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// Public fixture only. Drives the production chat/voice/controller paths with
/// real MLX, without showing a window or accessing the user's Keychain.
@MainActor enum ConsultationControlSmoke {
  private struct Reply: Codable, Sendable {
    let message: ChatMessage
    let receipt: ConsultationReceipt
    let journal: GenerationCheckpoint
  }
  private struct Round: Codable, Sendable {
    let style: String
    let chatID: UUID
    let history: [ChatMessage]
    let instructions: String
    let question: ChatMessage
    let voices: [Voice]
    let replies: [Reply]
  }
  private struct Capture: Codable, Sendable {
    let initialVoices: [Voice]
    let editedVoices: [Voice]
    let rounds: [Round]
    let state: WorkspaceState
    let documents: [DocumentSnapshot]
  }
  private static let key = SymmetricKey(data: Data(repeating: 0x62, count: 32))
  private static let passphrase = "public consultation control fixture passphrase"

  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --consultation-control-smoke capture|verify|followups --evidence ABSOLUTE_DIRECTORY.")
      }
      return arguments[index + 1]
    }
    let action = try argument("--consultation-control-smoke"), path = try argument("--evidence")
    guard ["capture", "verify", "followups"].contains(action), path.hasPrefix("/") else {
      throw BoomError.invalid("Invalid consultation diagnostic action or path.")
    }
    let evidence = URL(fileURLWithPath: path)
    if action == "verify" { try await verify(evidence); return }
    let requestedPack: URL?
    if arguments.contains("--pack") {
      let packPath = try argument("--pack")
      guard packPath.hasPrefix("/") else { throw BoomError.invalid("Use an absolute consultation model path.") }
      requestedPack = URL(fileURLWithPath: packPath)
    } else { requestedPack = nil }
    guard !FileManager.default.fileExists(atPath: path), let pack = requestedPack ?? ModelPacks.cached(.consultation) else {
      throw BoomError.invalid("Use a new evidence directory and a cached consultation pack.")
    }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try await receipt("running", evidence: evidence)
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + .seconds(300))
    watchdog.setEventHandler {
      fputs("Consultation diagnostic exceeded its deadline; incomplete evidence retained.\n", stderr)
      exit(2)
    }
    watchdog.resume(); defer { watchdog.cancel() }
    do {
      if action == "followups" { try await followups(pack: pack, evidence: evidence, automatic: arguments.contains("--automatic-setup")) }
      else { try await capture(pack: pack, evidence: evidence, record: arguments.contains("--record-demonstration")) }
      try await receipt("captured", evidence: evidence)
    } catch {
      try await receipt("failed", evidence: evidence, failure: error.localizedDescription)
      throw error
    }
  }
  private static func store(_ evidence: URL) throws -> WorkspaceStore {
    try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"), testKey: key)
  }
  private static func followups(pack: URL, evidence: URL, automatic: Bool) async throws {
    let store = try store(evidence)
    let document = DocumentSnapshot(title: "Public follow-up fixture", text: "The harbor was quiet.")
    let chat = ChatRecord(attachedDocumentID: document.id)
    var state = WorkspaceState()
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.selectedDocument = document.id; state.chats = [chat]; state.selectedChat = chat.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: automatic)
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 900))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    // This unshown diagnostic receives no AppKit user events to close automatic
    // event groups. Exercise the editor's explicit transaction groups instead.
    model.undoManager(document.id).groupsByEvent = false
    if !automatic { model.loadPack(pack, purpose: .consultation) }
    try await finish(model, evidence: evidence, phase: "loading", recorder: nil)
    guard model.canInfer, !automatic || !model.layout.isAuthor || model.baseReady else {
      throw BoomError.invalid("Automatic setup did not prepare the appropriate models.")
    }
    guard !window.isVisible else { throw BoomError.invalid("Follow-up fixture became visible.") }
    model.mode = .edit
    for (index, replacement) in [("quiet", "bright"), ("bright", "hushed")].enumerated() {
      guard model.mode == .edit, let before = model.selectedDocument else {
        throw BoomError.invalid("Edit permission did not survive the preceding send.")
      }
      model.draft = "In the attached document, replace \(replacement.0) with \(replacement.1). Keep every other character unchanged. Return the actual edit patch."
      model.send()
      let phase = "edit-\(index + 1)"
      try await finish(model, evidence: evidence, phase: phase, recorder: nil)
      try await model.flush()
      let expected = before.text.replacingOccurrences(of: replacement.0, with: replacement.1)
      let persisted = try await store.load().get().1.first { $0.id == document.id }
      guard model.mode == .edit, model.selectedDocument?.text == expected, persisted?.text == expected,
        model.editor.map({ $0.string == expected }) ?? !model.layout.isAuthor,
        let message = model.selectedChat?.messages.last, message.state == .complete else {
        throw BoomError.invalid("The real follow-up failed to edit the exact document.")
      }
      let vault = store.vault
      let receipt = try await detachedWork { try vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id) }
      guard receipt.state == .complete, !receipt.tokenIDs.isEmpty,
        let journal = try await store.consultationCheckpoint(id: message.id, receipt: receipt),
        journal.progress.tokenIDs == receipt.tokenIDs,
        receipt.sources.contains(where: { $0.id == before.id && $0.digest == before.revision }) else {
        throw BoomError.invalid("The follow-up lost its captured revision, real token receipt or journal.")
      }
      try await write(receipt, to: evidence.appendingPathComponent(phase + "-receipt.json"))
      try await write(journal, to: evidence.appendingPathComponent(phase + "-journal.json"))
      try await write(persisted, to: evidence.appendingPathComponent(phase + "-document.json"))
    }
    guard model.state.proposals.count == 2, model.state.proposals.allSatisfy({ $0.status == "applied" }) else {
      throw BoomError.invalid("Expected two individually recorded applied edits.")
    }
    for text in ["The harbor was bright.", document.text] {
      model.undoManager(document.id).undo()
      try await model.flush()
      try await write(["expected": text, "observed": model.selectedDocument?.text ?? "", "editor": model.editor?.string ?? ""],
        to: evidence.appendingPathComponent("undo-" + Digest.sha256(text) + ".json"))
      guard model.selectedDocument?.text == text,
        try await store.load().get().1.first(where: { $0.id == document.id })?.text == text else {
        throw BoomError.invalid("Follow-up Undo did not restore exact document bytes.")
      }
    }
    try model.newChat(about: document.id)
    guard model.mode == .ask else { throw BoomError.invalid("A new chat inherited editing permission.") }
    try await model.shutdown()
    try await write(["status": "passed", "edits": "2", "permission_selected": "once",
      "undo": "two exact persisted reversals", "scope": "real MLX and mounted offscreen editor; no physical UI or Keychain requests"],
      to: evidence.appendingPathComponent("followups.json"))
  }
  private static func capture(pack: URL, evidence: URL, record: Bool) async throws {
    let admission = try await detachedWork { try ModelPacks.admission(pack, purpose: .consultation) }
    let manifest = try await detachedWork { try ModelPacks.evidenceManifest(admission, purpose: .consultation) }
    try await detachedWork { try manifest.write(to: evidence.appendingPathComponent("model-manifest.json"), options: .atomic) }
    let store = try store(evidence)
    let document = DocumentSnapshot(title: "Public decision notes",
      text: "I have until Friday to choose whether to accept a new project. I feel hurried, although nobody has asked for an answer today. I want to keep my own judgment and identify one small next step.")
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 900))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let recorder = record ? try NativeDemoRecorder(view: host, evidence: evidence) : nil
    defer { recorder?.cancel() }
    try await recorder?.checkpoint("Fresh consultation workspace")
    let reflective = try await createVoice(model, name: "Reflective Listener", slug: "reflective",
      instructions: "Offer a calm reflective question. Preserve the person's choice. Speak only as this voice and use fewer than sixty words.",
      example: VoiceExchange(user: "I am rushing into a decision.",
        assistant: "What changes if you give yourself a moment to notice the hesitation?"), recorder: recorder)
    let practical = try await createVoice(model, name: "Practical Guide", slug: "practical",
      instructions: "Offer one concrete next step. Preserve the person's choice. Speak only as this voice and use fewer than sixty words.",
      example: VoiceExchange(user: "I am rushing into a decision.",
        assistant: "Write down the real deadline and one question you can answer before then."), recorder: recorder)
    let initial = [reflective, practical]
    guard let exampleID = model.state.chats.first(where: { $0.id == reflective.id })?.messages.last?.id else {
      throw BoomError.invalid("The ordinary chat did not retain its authored example.")
    }
    try model.replaceChatMessage("What do you notice when you let the decision wait for a moment?",
      id: exampleID, chatID: reflective.id)
    try model.setChatInstructions("Offer a calm reflective question about the actual situation. Preserve the person's choice. Speak only as this voice and use fewer than sixty words.",
      mention: "reflective", chatID: reflective.id)
    model.editVoice(reflective); model.openChatInstructions(reflective.id)
    try await recorder?.checkpoint("Edited ordinary-chat instructions and example")
    model.showingChatInstructions = nil
    let edited = try initial.map { voice -> Voice in
      guard let current = model.chatVoice(voice.id) else { throw BoomError.invalid("A pinned voice disappeared.") }
      return current
    }
    guard edited[0].revision != reflective.revision,
      edited[0].examples[0].assistant != reflective.examples[0].assistant,
      model.state.voiceVersions.contains(reflective) else {
      throw BoomError.invalid("Editing an ordinary chat did not retain its earlier voice revision.")
    }
    try await model.flush()
    try await write(initial, to: evidence.appendingPathComponent("initial-voices.json"))
    try await write(edited, to: evidence.appendingPathComponent("edited-voices.json"))
    model.loadPack(pack, purpose: .consultation)
    try await finish(model, evidence: evidence, phase: "loading", recorder: recorder)
    try newConsultation(model, document: document)
    let separate = try await round(model, voices: edited, style: .separate,
      text: "I feel hurried about this project. What would you each suggest?", evidence: evidence, recorder: recorder)
    try await recorder?.checkpoint("Two separately attributed answers")
    try await render(model, name: "separate", evidence: evidence)

    // Later edits must not rewrite the speaker, instructions or examples in
    // either completed reply's captured voice revision.
    model.renameChat(reflective.id, to: "Attentive Listener")
    try model.setChatInstructions("Offer one gentle question that helps the person notice their own preference. Preserve their choice. Speak only as this voice and use fewer than sixty words.",
      mention: "listener", chatID: reflective.id)
    guard let renamed = model.chatVoice(reflective.id), renamed.name == "Attentive Listener",
      renamed.slug == "listener", renamed.revision != edited[0].revision,
      model.selectedChat?.messages == [separate.question] + separate.replies.map(\.message) else {
      throw BoomError.invalid("A later voice edit changed historical consultation attribution.")
    }
    try await recorder?.checkpoint("Renamed voice; historical speakers preserved")
    let discussed = try await round(model, voices: [renamed, edited[1]], style: .discuss,
      text: "Consider the same project together. What should I attend to before Friday?", evidence: evidence, recorder: recorder)
    try await recorder?.checkpoint("Discuss together")
    try await recorder?.finish()
    try await render(model, name: "discussion", evidence: evidence)
    guard model.documents == [document] else { throw BoomError.invalid("Read-only consultation changed the attached document.") }
    try await model.shutdown()
    let loaded = try await store.load().get()
    let captured = Capture(initialVoices: initial, editedVoices: edited,
      rounds: [separate, discussed], state: loaded.0, documents: loaded.1)
    try await write(captured, to: evidence.appendingPathComponent("capture.json"))
    try await store.exportBackup(passphrase: passphrase, to: evidence.appendingPathComponent("complete.bloombackup"))
    print("Named voices, ordinary-chat editing, separate answers and discussion passed with real MLX.")
  }
  private static func createVoice(_ model: WorkspaceModel, name: String, slug: String,
    instructions: String, example: VoiceExchange, recorder: NativeDemoRecorder?) async throws -> Voice {
    try model.newChat()
    guard let id = model.state.selectedChat else { throw BoomError.invalid("New chat did not become selected.") }
    model.renameChat(id, to: name)
    try model.setChatInstructions(instructions, mention: nil, chatID: id)
    model.openChatInstructions(id)
    try await recorder?.checkpoint(name + ": ordinary chat instructions")
    model.showingChatInstructions = nil
    model.authorChatMessage(.user); model.draft = example.user; model.send()
    try await recorder?.checkpoint(name + ": authored question")
    model.authorChatMessage(.assistant); model.draft = example.assistant; model.send()
    try await recorder?.checkpoint(name + ": authored answer")
    model.pinChat(id)
    try model.setChatInstructions(instructions, mention: slug, chatID: id)
    try await recorder?.checkpoint(name + ": pinned as @" + slug)
    guard let voice = model.chatVoice(id), voice.name == name, voice.slug == slug,
      voice.examples == [example] else { throw BoomError.invalid("Ordinary chat did not become the requested named voice.") }
    return voice
  }
  private static func newConsultation(_ model: WorkspaceModel, document: DocumentSnapshot) throws {
    try model.newChat(about: document.id)
    guard model.selectedChat?.attachedDocumentID == document.id else {
      throw BoomError.invalid("Consultation did not retain its explicit document attachment.")
    }
  }
  private static func round(_ model: WorkspaceModel, voices: [Voice], style: ConsultationStyle,
    text: String, evidence: URL, recorder: NativeDemoRecorder?) async throws -> Round {
    guard let before = model.selectedChat else { throw BoomError.invalid("Consultation chat disappeared.") }
    model.consultationStyle = style; model.mode = .ask; model.draft = ""
    for voice in voices {
      model.draft += "@" + String(voice.slug.prefix(2))
      guard model.voiceMatches.contains(where: { $0.id == voice.id }) else {
        throw BoomError.invalid("The @ completion did not find a named voice.")
      }
      model.insertVoice(voice)
      try await recorder?.checkpoint("Selected @" + voice.slug)
    }
    model.draft += text
    let request = model.draft
    try await recorder?.checkpoint("Captured question: " + style.rawValue)
    model.send()
    try await finish(model, evidence: evidence, phase: style == .separate ? "separate" : "discussion", recorder: recorder)
    guard let chat = model.selectedChat, chat.id == before.id,
      Array(chat.messages.prefix(before.messages.count)) == before.messages,
      chat.messages.count == before.messages.count + 3 else {
      throw BoomError.invalid("Consultation did not preserve history and finish two replies.")
    }
    let messages = Array(chat.messages.suffix(3)), vault = model.store.vault
    guard messages[0].text == request else { throw BoomError.invalid("The captured question changed.") }
    var replies: [Reply] = []
    for message in messages.dropFirst() {
      let receipt = try await detachedWork { try vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id) }
      guard let journal = try await model.store.consultationCheckpoint(id: message.id, receipt: receipt) else {
        throw BoomError.invalid("A completed reply had no generation journal.")
      }
      replies.append(Reply(message: message, receipt: receipt, journal: journal))
    }
    let round = Round(style: style.rawValue, chatID: chat.id, history: before.messages,
      instructions: before.instructions ?? "", question: messages[0], voices: voices, replies: replies)
    try verifyRound(round)
    try await write(round, to: evidence.appendingPathComponent(style == .separate ? "separate.json" : "discussion.json"))
    return round
  }
  private static func verifyRound(_ round: Round) throws {
    guard round.voices.count == 2, round.replies.count == 2,
      let style = ConsultationStyle(rawValue: round.style), round.question.role == .user,
      round.replies[0].receipt.operationID == round.replies[1].receipt.operationID else {
      throw BoomError.invalid("Invalid two-voice round.")
    }
    let routing = round.voices.map(\.slug)
    for index in round.replies.indices {
      let reply = round.replies[index], voice = round.voices[index]
      let history = round.history + (style == .discuss ? Array(round.replies.prefix(index)).map(\.message) : [])
      let expected = try ProductCore.prompt(voice: voice, history: history, instructions: round.instructions,
        context: round.question.context, request: round.question.text, routing: routing)
      guard reply.message.role == .assistant, reply.message.state == .complete, !reply.message.text.isEmpty,
        reply.message.speaker == voice.speaker, reply.receipt.voice == voice,
        reply.receipt.state == .complete, reply.receipt.failure == nil,
        reply.receipt.sources == round.question.sources, reply.message.sources == round.question.sources,
        reply.message.provider == reply.receipt.model,
        reply.journal.identity.requestDigest == Digest.sha256(expected.rawPrompt),
        reply.receipt.promptDigest == reply.journal.progress.promptDigest,
        try canonical(reply.receipt.plan) == canonical(expected),
        !reply.receipt.tokenIDs.isEmpty,
        reply.journal.identity.seed == reply.receipt.seed,
        reply.journal.progress.tokenIDs == reply.receipt.tokenIDs,
        reply.journal.progress.text == reply.message.text,
        reply.journal.stopReason == reply.receipt.stopReason,
        reply.journal.stopTokenID == reply.receipt.stopTokenID else {
        throw BoomError.invalid("A reply lost its captured voice, speaker, prompt, source or real-model token lineage.")
      }
    }
  }
  private static func finish(_ model: WorkspaceModel, evidence: URL, phase: String, recorder: NativeDemoRecorder?) async throws {
    do {
      let started = ContinuousClock().now
      while model.isBusy {
        guard started.duration(to: ContinuousClock().now) < .seconds(240) else {
          throw BoomError.unavailable("Consultation diagnostic timed out during " + phase)
        }
        try await write(model.selectedChat, to: evidence.appendingPathComponent(phase + "-latest.json"))
        try recorder?.frame(phase)
        try await Task.sleep(for: .milliseconds(100))
      }
      try await write(model.selectedChat, to: evidence.appendingPathComponent(phase + "-latest.json"))
      if let error = model.errorMessage ?? model.composerIssue { throw BoomError.invalid(error) }
    } catch {
      let failure = error
      model.cancel()
      // A failed qualification must join its live producer before disposing
      // the window/model or exiting. Retain every failed and cancelled attempt.
      try? await model.shutdown()
      throw failure
    }
  }
  private static func render(_ model: WorkspaceModel, name: String, evidence: URL) async throws {
    for dark in [false, true] {
      for width in [1440, 760] {
        model.fitPanes(to: CGFloat(width))
        let view = NSHostingView(rootView: WorkspaceView(model: model).environment(\.colorScheme, dark ? .dark : .light))
        let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: width, height: 900))
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BoomError.invalid("Native body render unavailable.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Native body PNG unavailable.") }
        let filename = "body-\(name)-\(width)-\(dark ? "dark" : "light").png"
        try await detachedWork { try png.write(to: evidence.appendingPathComponent(filename), options: .atomic) }
      }
    }
  }
  private static func verify(_ evidence: URL) async throws {
    let bytes = try AttachmentProcessor.readGranted(evidence.appendingPathComponent("capture.json"))
    let capture = try JSONDecoder().decode(Capture.self, from: bytes)
    let source = try store(evidence)
    try await verify(source, capture: capture)
    let reopened = try await WorkspaceModel(storeOverride: source, loadModels: false)
    guard reopened.state.voices == capture.state.voices, reopened.state.chats == capture.state.chats,
      reopened.documents == capture.documents else { throw BoomError.invalid("Native controller relaunch changed consultation records.") }
    try await reopened.shutdown()
    let restored = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("restored-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 0x63, count: 32)))
    _ = try await restored.restoreBackup(passphrase: passphrase, from: evidence.appendingPathComponent("complete.bloombackup"))
    try await verify(restored, capture: capture)
    try await receipt("passed", evidence: evidence)
    print("Separate-process relaunch and fresh-key backup restore preserved named voices, examples, speakers, replies and journals.")
  }
  private static func verify(_ store: WorkspaceStore, capture: Capture) async throws {
    let loaded = try await store.load().get()
    guard try canonical(loaded.0) == canonical(capture.state), loaded.1 == capture.documents,
      (capture.initialVoices + capture.editedVoices).allSatisfy({ capture.state.voiceVersions.contains($0) }) else {
      throw BoomError.invalid("Workspace, documents or immutable voice revisions changed across relaunch/restore.")
    }
    let vault = store.vault
    for round in capture.rounds {
      try verifyRound(round)
      guard let chat = loaded.0.chats.first(where: { $0.id == round.chatID }),
        ([round.question] + round.replies.map(\.message)).allSatisfy({ chat.messages.contains($0) }) else {
        throw BoomError.invalid("Historical questions, speakers or replies changed.")
      }
      for reply in round.replies {
        let saved = try await detachedWork { try vault.decode(ConsultationReceipt.self, kind: .receipt, id: reply.message.id) }
        guard try canonical(saved) == canonical(reply.receipt),
          let journal = try await store.consultationCheckpoint(id: reply.message.id, receipt: saved),
          try canonical(journal) == canonical(reply.journal) else {
          throw BoomError.invalid("Captured consultation receipt or journal changed.")
        }
      }
    }
  }
  private static func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  private static func write<T: Encodable>(_ value: T, to url: URL) async throws {
    let bytes = try canonical(value)
    try await detachedWork { try bytes.write(to: url, options: .atomic) }
  }
  private static func receipt(_ status: String, evidence: URL, failure: String? = nil) async throws {
    var result: [String: Any] = ["status": status, "executable": CommandLine.arguments[0],
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
      "interactive_ui_qualified": false, "real_keychain_qualified": false, "target_32_gb_qualified": false,
      "network_denial_must_be_verified_by_driver": true]
    if let failure { result["failure"] = failure }
    let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    let filename = status == "passed" ? "verification.json" : "diagnostic.json"
    try await detachedWork { try bytes.write(to: evidence.appendingPathComponent(filename), options: .atomic) }
  }
}
