import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// Explicit public fixtures only. No window is shown and no real Keychain item is used.
@MainActor enum WorkspaceImportSmoke {
  private struct Original: Codable { let id: UUID; let bytes: Data }
  private struct Fixture: Codable { let documents: [DocumentSnapshot]; let originals: [Original] }
  private static let key = SymmetricKey(data: Data(repeating: 0x5a, count: 32))
  private static let passphrase = "public import restore fixture passphrase"
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --workspace-import-smoke capture|verify --evidence ABSOLUTE_DIRECTORY.")
      }
      return arguments[index + 1]
    }
    let action = try argument("--workspace-import-smoke"), path = try argument("--evidence")
    guard ["capture", "verify"].contains(action), path.hasPrefix("/") else { throw BoomError.invalid("Invalid import diagnostic action or path.") }
    let evidence = URL(fileURLWithPath: path)
    if action == "capture" {
      guard !FileManager.default.fileExists(atPath: path) else { throw BoomError.invalid("Use a new diagnostic directory.") }
      try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try await capture(evidence)
    } else { try await verify(evidence) }
  }
  private static func store(_ evidence: URL) throws -> WorkspaceStore {
    try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"), testKey: key)
  }
  private static func capture(_ evidence: URL) async throws {
    let source = evidence.appendingPathComponent("chosen-public-files")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let urls = [source.appendingPathComponent("Café.md"), source.appendingPathComponent("Empty.txt")]
    let bytes = [Data("\u{feff}# A public fixture\r\nCafé 👩‍💻\npublic-import-original-canary".utf8), Data()]
    for (url, data) in zip(urls, bytes) { try data.write(to: url) }
    let store = try store(evidence), model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    try await model.importDocuments(urls, flag: CancellationFlag())
    let imported = model.documents.filter { model.state.importedFiles?[$0.id] != nil }
    guard imported.count == 2, let first = imported.first else { throw BoomError.invalid("Native import did not retain both selected files.") }
    model.updateDocument("# After import\n\nThe manuscript can change while its exact original stays private. Café 👩‍💻\n", id: first.id, caret: 0)
    try await model.flush()
    let fixture = Fixture(documents: model.documents, originals: zip(imported, bytes).map { Original(id: $0.0.id, bytes: $0.1) })
    try write(fixture, to: evidence.appendingPathComponent("fixture.json"))
    if model.layout.isAuthor {
      for dark in [true, false] {
        for width in [1440, 760] { try await render(model, width: width, dark: dark, evidence: evidence) }
      }
    }
    try await model.shutdown()
    try await store.exportBackup(passphrase: passphrase, to: evidence.appendingPathComponent("complete.bloombackup"))
    for (url, original) in zip(urls, bytes) {
      guard try Data(contentsOf: url) == original else { throw BoomError.invalid("Import wrote back to a chosen source file.") }
    }
    // Relaunch must rely on encrypted originals, independently of these source files.
    try FileManager.default.removeItem(at: source)
    try outcome("captured", evidence: evidence, extra: ["source_files_unchanged_before_removal": true])
    print("Native selected-file import captured; source files remained unchanged.")
  }
  private static func verify(_ evidence: URL) async throws {
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: evidence.appendingPathComponent("fixture.json")))
    let store = try store(evidence)
    let (state, documents) = try await store.load().get()
    guard documents == fixture.documents else { throw BoomError.invalid("Imported manuscript bytes changed across process relaunch.") }
    for original in fixture.originals {
      guard state.importedFiles?[original.id]?.originalDigest == Digest.sha256(original.bytes),
        state.importedFiles?[original.id]?.folderID == nil,
        try store.vault.get(.attachment, id: original.id) == original.bytes else {
        throw BoomError.invalid("Imported originals or their captured identities changed.")
      }
    }
    let restored = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("restored-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 0x5b, count: 32)))
    let (_, restoredDocuments) = try await restored.restoreBackup(passphrase: passphrase,
      from: evidence.appendingPathComponent("complete.bloombackup"))
    guard restoredDocuments == fixture.documents else { throw BoomError.invalid("Complete backup lost manuscript bytes.") }
    for original in fixture.originals {
      guard try restored.vault.get(.attachment, id: original.id) == original.bytes else {
        throw BoomError.invalid("Complete backup lost an imported original.")
      }
    }
    let occupied = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("occupied-workspace"), testKey: key)
    try await occupied.save(WorkspaceState(), documents: [])
    try occupied.vault.put(Data("Public unindexed original.".utf8), kind: .attachment, id: UUID())
    let before = try privateHashes(occupied.vault)
    var rejected = false
    do { _ = try await occupied.restoreBackup(passphrase: passphrase, from: evidence.appendingPathComponent("complete.bloombackup")) }
    catch { rejected = true }
    guard rejected, try privateHashes(occupied.vault) == before else { throw BoomError.invalid("Restore discarded an unindexed private record.") }
    try outcome("passed", evidence: evidence, extra: ["originals_and_manuscripts_exact_after_process_relaunch": true,
      "passphrase_backup_restore_exact": true, "unindexed_record_rejected_without_changes": true])
    print("Native import, process relaunch, complete restore, and occupied-target rejection passed.")
  }
  private static func render(_ model: WorkspaceModel, width: Int, dark: Bool, evidence: URL) async throws {
    model.fitPanes(to: CGFloat(width))
    let view = NSHostingView(rootView: WorkspaceView(model: model).environment(\.colorScheme, dark ? .dark : .light))
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = view
    try await Task.sleep(nanoseconds: 150_000_000)
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BoomError.invalid("Native body render was unavailable.") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Native body render could not be encoded.") }
    try png.write(to: evidence.appendingPathComponent("body-\(width)-\(dark ? "dark" : "light").png"), options: .atomic)
  }
  private static func privateHashes(_ vault: Vault) throws -> [String: String] {
    try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: vault.root, includingPropertiesForKeys: nil)
      .map { ($0.lastPathComponent, try Digest.sha256(Data(contentsOf: $0))) })
  }
  private static func outcome(_ status: String, evidence: URL, extra: [String: Any]) throws {
    var result: [String: Any] = ["status": status, "executable": CommandLine.arguments[0],
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "real_keychain_qualified": false, "interactive_ui_qualified": false,
      "offscreen_body_render_only": true, "model_inference_qualified": false]
    for (key, value) in extra { result[key] = value }
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent(status == "captured" ? "capture.json" : "verification.json"), options: .atomic)
  }
  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }
}
