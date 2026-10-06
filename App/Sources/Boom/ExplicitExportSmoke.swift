import AppKit
import BoomCore
import CryptoKit
import Foundation

/// Explicit public fixture. No model generation, Keychain item, shown window,
/// save panel or desktop interaction is part of this backend export check.
@MainActor enum ExplicitExportSmoke {
  static func run(arguments: [String]) async throws {
    guard arguments.filter({ $0 == "--evidence" }).count == 1,
      let index = arguments.firstIndex(of: "--evidence"), index + 1 < arguments.count,
      arguments[index + 1].hasPrefix("/"), NSApp.activationPolicy() == .prohibited else {
      throw BoomError.invalid("Use --explicit-export-smoke --evidence NEW_ABSOLUTE_DIRECTORY.")
    }
    let evidence = URL(fileURLWithPath: arguments[index + 1])
    guard !FileManager.default.fileExists(atPath: evidence.path) else { throw BoomError.invalid("Export evidence already exists.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let chosen = evidence.appendingPathComponent("explicit-exports")
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
    let key = SymmetricKey(data: Data(repeating: 0x6f, count: 32))
    let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"), testKey: key)
    let text = "\u{feff}Public export privacy canary Café 👩🏽‍💻\r\nCaptured manuscript bytes.\n"
    let document = DocumentSnapshot(title: "Public export manuscript", text: text)
    let original = Data(text.utf8)
    try await detachedWork { try store.vault.put(original, kind: .attachment, id: document.id) }
    let chat = ChatRecord(title: "Public export voice", messages: [
      ChatMessage(role: .user, text: "Public export question canary: let me pause.", authoredByUser: true),
      ChatMessage(role: .assistant, text: "Public export answer canary: keep your own judgment.", authoredByUser: true)
    ], instructions: "Public export instruction canary: preserve the person's choices.")
    let voice = try ProductCore.pinnedVoice(chat, slug: "export-fixture", occupied: [])
    var state = WorkspaceState(); state.autocomplete = false
    state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
    state.chats = [chat]; state.selectedChat = chat.id; state.voices = [voice]; state.voiceVersions = [voice]
    state.importedFiles = [document.id: ImportedFile(folderID: nil, path: "Public.md", originalDigest: Digest.sha256(original))]
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    // Occupy the ordinary foreground slot. Exports must remain independent,
    // and shutdown must join their writes as well as the cancelled foreground.
    model.work("Public export foreground fixture") { flag in
      while true { try flag.check(); try await Task.sleep(for: .milliseconds(10)) }
    }
    model.exportFile(to: chosen.appendingPathComponent("document.md")) {
      guard !Thread.isMainThread else { throw BoomError.invalid("Export ran on the UI thread.") }
      Thread.sleep(forTimeInterval: 0.05) // Public fixture delays the older request.
      return Data("Public older captured export must not overwrite the later request.".utf8)
    }
    model.exportFile(to: chosen.appendingPathComponent("document.md")) {
      guard !Thread.isMainThread else { throw BoomError.invalid("Export serialization ran on the UI thread.") }
      return Data(document.text.utf8)
    }
    model.exportFile(to: chosen.appendingPathComponent("voice.json")) {
      guard !Thread.isMainThread else { throw BoomError.invalid("Voice serialization ran on the UI thread.") }
      return try JSONEncoder().encode(voice)
    }
    model.exportFile(to: chosen.appendingPathComponent("original.bin")) {
      guard !Thread.isMainThread else { throw BoomError.invalid("Original export ran on the UI thread.") }
      return original
    }
    let rejected = chosen.appendingPathComponent("cancelled.md")
    let cancelled = Task { try await ExplicitFileExport.write(to: rejected) { original } }
    cancelled.cancel()
    do { try await cancelled.value; throw BoomError.invalid("Cancelled export was published.") }
    catch is CancellationError {}
    guard model.isBusy else { throw BoomError.invalid("Export displaced the foreground operation.") }
    model.updateDocument("Public export later-edit canary: this stays in the encrypted manuscript.", id: document.id, caret: 0)
    try await model.shutdown()
    if let error = model.errorMessage { throw BoomError.invalid(error) }
    guard !FileManager.default.fileExists(atPath: rejected.path),
      try Data(contentsOf: chosen.appendingPathComponent("document.md")) == original,
      try Data(contentsOf: chosen.appendingPathComponent("original.bin")) == original,
      try JSONDecoder().decode(Voice.self, from: Data(contentsOf: chosen.appendingPathComponent("voice.json"))) == voice else {
      throw BoomError.invalid("Explicit exports changed their captured bytes or revision.")
    }
    let reopened = try WorkspaceStore(rootOverride: store.root, testKey: key)
    let (loaded, documents) = try await reopened.load().get()
    guard loaded.chats == state.chats, loaded.voices == state.voices,
      documents.first?.text == "Public export later-edit canary: this stays in the encrypted manuscript.",
      try reopened.vault.get(.attachment, id: document.id) == original else {
      throw BoomError.invalid("Export changed the encrypted workspace or original.")
    }
    let passphrase = "public explicit export fixture passphrase"
    try await reopened.exportBackup(passphrase: passphrase, to: evidence.appendingPathComponent("complete.bloombackup"))
    let restored = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("restored-workspace"), testKey: SymmetricKey(size: .bits256))
    let (restoredState, restoredDocuments) = try await restored.restoreBackup(passphrase: passphrase, from: evidence.appendingPathComponent("complete.bloombackup"))
    guard restoredDocuments == documents, restoredState.chats == loaded.chats, restoredState.voices == loaded.voices,
      try restored.vault.get(.attachment, id: document.id) == original else {
      throw BoomError.invalid("Explicit export backup restore changed the private records.")
    }
    guard VaultSession.shared.lookupCount == 0 else { throw BoomError.invalid("The public export fixture requested a Keychain key.") }
    let files = try FileManager.default.contentsOfDirectory(at: chosen, includingPropertiesForKeys: nil)
    var exports: [[String: Any]] = []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let bytes = try Data(contentsOf: file)
      exports.append(["name": file.lastPathComponent, "bytes": bytes.count, "sha256": Digest.sha256(bytes)])
    }
    let receipt: [String: Any] = ["status": "passed", "exports": exports,
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "worker_serialization_off_ui_thread": true, "foreground_slot_preserved": true,
      "captured_bytes_preserved": true, "shutdown_joined_exports": true, "cancelled_export_absent": true,
      "same_destination_request_order_preserved": true,
      "encrypted_relaunch_and_backup_restore": true, "real_keychain_qualified": false,
      "keychain_lookups": VaultSession.shared.lookupCount,
      "physical_interaction_qualified": false, "save_panel_interaction_qualified": false,
      "model_generation_qualified": false, "os_cache_audit_qualified": false]
    let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    try await detachedWork { try bytes.write(to: evidence.appendingPathComponent("verification.json"), options: .atomic) }
    print("Captured explicit exports, background serialization, encrypted relaunch and backup restore passed.")
  }
}
