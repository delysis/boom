import AppKit
import BoomCore
import CryptoKit
import Darwin
import Foundation

/// Explicit public-fixture diagnostic. Uses the real WorkspaceModel send and
/// Explore paths, with no visible window and no Keychain acceptance claim.
@MainActor enum GenerationRecoverySmoke {
  private struct Fixture: Codable {
    let purpose: ModelPurpose
    let document: DocumentSnapshot
    let chatID: UUID
  }
  private struct Marker: Codable {
    let checkpoint: GenerationCheckpoint
    let fixture: Fixture
  }
  // Only this isolated diagnostic uses a public, reproducible fixture key.
  private static let key = SymmetricKey(data: Data(repeating: 0x58, count: 32))
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --generation-recovery-smoke write|recover|cancel --purpose consultation|writing --evidence NEW_ABSOLUTE_DIRECTORY.")
      }
      return arguments[index + 1]
    }
    let action = try argument("--generation-recovery-smoke")
    guard ["write", "recover", "cancel"].contains(action),
      let purpose = ModelPurpose(rawValue: try argument("--purpose")) else {
      throw BoomError.invalid("Unknown recovery diagnostic action or model purpose.")
    }
    let path = try argument("--evidence")
    guard path.hasPrefix("/") else { throw BoomError.invalid("Use an absolute diagnostic directory.") }
    let evidence = URL(fileURLWithPath: path), root = evidence.appendingPathComponent("encrypted-workspace")
    if action == "recover" {
      try await recover(evidence: evidence, root: root, purpose: purpose)
      return
    }
    guard !FileManager.default.fileExists(atPath: evidence.path),
      let pack = ModelPacks.cached(purpose) else {
      throw BoomError.invalid("Use a fresh diagnostic directory and an installed or cached public model.")
    }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let store = try WorkspaceStore(rootOverride: root, testKey: key)
    let document = DocumentSnapshot(title: "Public recovery manuscript",
      text: "The harbor lighthouse was built from stone that the masons brought from the hills. Every morning, the keeper climbed the spiral stair and looked across the water. On the morning the ferry failed to arrive, ")
    let voices = try [
      VoiceDraft(slug: "observer", name: "Observer", instructions: "Describe concrete details. Answer independently as Observer."),
      VoiceDraft(slug: "skeptic", name: "Skeptic", instructions: "Consider another explanation. Answer independently as Skeptic.")
    ].map { try ProductCore.voice($0) }
    let chat = ChatRecord(title: "Public recovery consultation")
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]
    state.selectedDocument = document.id; state.chats = [chat]; state.selectedChat = chat.id
    state.voices = voices; state.voiceVersions = voices
    try await store.save(state, documents: [document])
    let fixture = Fixture(purpose: purpose, document: document, chatID: chat.id)
    try write(fixture, to: evidence.appendingPathComponent("fixture.json"))
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.loadPack(pack, purpose: purpose)
    let started = ContinuousClock().now
    while model.isBusy {
      guard started.duration(to: ContinuousClock().now) < .seconds(180) else { throw BoomError.unavailable("Model loading timed out.") }
      try await Task.sleep(for: .milliseconds(50))
    }
    if let error = model.errorMessage { throw BoomError.unavailable(error) }
    let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    defer { _ = editor }
    if purpose == .consultation {
      model.draft = "@observer @skeptic Describe a harbor at dawn in twenty numbered observations. Write several sentences for each observation."
      model.send()
    } else {
      guard model.layout.isAuthor else { throw BoomError.unavailable("Use the author edition for writing recovery.") }
      editor.documentID = document.id; editor.string = document.text
      editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
      model.editor = editor; model.movedCaret(document.text.utf16.count, hasMarkedText: false)
      model.exploreWriting()
    }
    var markerWritten = false
    while model.isBusy {
      guard started.duration(to: ContinuousClock().now) < .seconds(240) else { throw BoomError.unavailable("Generation recovery diagnostic timed out.") }
      if !markerWritten, let checkpoint = try await currentCheckpoint(model, purpose: purpose),
        checkpoint.progress.tokenIDs.count >= 8, checkpoint.stopReason == nil {
        try write(Marker(checkpoint: checkpoint, fixture: fixture), to: evidence.appendingPathComponent("kill-ready.json"))
        markerWritten = true
        if action == "cancel" {
          let began = ContinuousClock().now
          model.cancel()
          try await model.shutdown()
          let duration = began.duration(to: ContinuousClock().now).components
          let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
          try JSONSerialization.data(withJSONObject: ["seconds": seconds,
            "two_second_target_met_on_this_host": seconds <= 2,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "target_32_gb_machine_qualified": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("cancellation.json"), options: .atomic)
          try await recover(evidence: evidence, root: root, purpose: purpose, graceful: true)
          return
        }
        // Freeze only this explicit fixture process at its live checkpoint.
        // The external driver then delivers SIGKILL. Fast continuations cannot
        // finish before the driver observes the marker.
        raise(SIGSTOP)
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    try await model.shutdown()
    throw BoomError.invalid(markerWritten ? "The driver did not kill the process during decoding." : "No eligible live checkpoint was observed; attempt retained.")
  }
  private static func currentCheckpoint(_ model: WorkspaceModel, purpose: ModelPurpose) async throws -> GenerationCheckpoint? {
    if purpose == .writing {
      guard let bundle = model.candidates, let candidate = bundle.candidates.last, candidate.state == .pending else { return nil }
      return try await model.store.writingCheckpoint(bundle: bundle, candidate: candidate)
    }
    guard let message = model.selectedChat?.messages.first(where: { $0.role == .assistant && $0.state == .pending }),
      model.store.vault.exists(.receipt, message.id) else { return nil }
    let vault = model.store.vault
    let receipt = try await detachedWork { try vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id) }
    return try await model.store.consultationCheckpoint(id: message.id, receipt: receipt)
  }
  private static func recover(evidence: URL, root: URL, purpose: ModelPurpose, graceful: Bool = false) async throws {
    let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: evidence.appendingPathComponent("kill-ready.json")))
    guard marker.fixture.purpose == purpose else { throw BoomError.invalid("Recovery fixture purpose changed.") }
    let store = try WorkspaceStore(rootOverride: root, testKey: key), id = marker.checkpoint.identity.attemptID
    let latest = try await store.generationCheckpoint(identity: marker.checkpoint.identity)
    guard let latest, latest.stopReason == (graceful ? "cancelled" : nil),
      latest.progress.tokenIDs.starts(with: marker.checkpoint.progress.tokenIDs) else {
      throw BoomError.invalid("The process did not stop during the captured generation.")
    }
    let (state, documents) = try await store.load().get()
    guard documents.first(where: { $0.id == marker.fixture.document.id })?.text == marker.fixture.document.text else {
      throw BoomError.invalid("Interrupted output entered or changed the manuscript.")
    }
    if purpose == .writing {
      let bundle = try store.vault.decode(CandidateBundle.self, kind: .candidate, id: latest.identity.recordID)
      guard let candidate = bundle.candidates.first(where: { $0.id == id }),
        candidate.state == .cancelled, candidate.text == latest.progress.text,
        candidate.tokenIDs == latest.progress.tokenIDs, candidate.seed == latest.identity.seed,
        bundle.recipe.promptDigest == latest.identity.requestDigest else {
        throw BoomError.invalid("Writing checkpoint was not recovered exactly.")
      }
    } else {
      let receipt = try store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: id)
      guard let chat = state.chats.first(where: { $0.id == marker.fixture.chatID }),
        let message = chat.messages.first(where: { $0.id == id }),
        message.state == .cancelled, message.text == latest.progress.text,
        message.speaker == receipt.voice?.speaker, receipt.state == .cancelled,
        receipt.tokenIDs == latest.progress.tokenIDs, receipt.seed == latest.identity.seed,
        chat.messages.filter({ $0.role == .assistant }).allSatisfy({ $0.state == .cancelled }) else {
        throw BoomError.invalid("Consultation checkpoint or unstarted participant was not recovered exactly.")
      }
    }
    // Validate idempotent relaunch and an independent passphrase backup of the
    // recovered records. No user data or actual Keychain item participates.
    _ = try await store.load().get()
    let backup = evidence.appendingPathComponent("recovered.bloombackup")
    try await store.exportBackup(passphrase: "public recovery fixture passphrase", to: backup)
    let restored = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("restored-workspace"),
      testKey: SymmetricKey(size: .bits256))
    let (restoredState, restoredDocuments) = try await restored.restoreBackup(passphrase: "public recovery fixture passphrase", from: backup)
    guard restoredDocuments.map(\.text) == documents.map(\.text),
      restoredState.chats.map(\.messages) == state.chats.map(\.messages),
      try restored.vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: id).progress.tokenIDs == latest.progress.tokenIDs else {
      throw BoomError.invalid("The recovered backup omitted captured records.")
    }
    try write(latest, to: evidence.appendingPathComponent("recovered-checkpoint.json"))
    try JSONSerialization.data(withJSONObject: ["status": "passed", "purpose": purpose.rawValue,
      "interruption": graceful ? "native_cancel" : "sigkill",
      "token_count": latest.progress.tokenIDs.count, "native_model_pipeline": true,
      "manuscript_unchanged": true, "captured_output_restored_exactly": true,
      "passphrase_backup_restore": true, "real_keychain_qualified": false,
      "interactive_ui_qualified": false, "runtime_revision": ModelPacks.runtimeRevision], options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent("recovery.json"), options: .atomic)
    print("Real-model interrupted \(purpose.rawValue) recovered exactly.")
  }
  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }
}
