import BoomCore
import CryptoKit
import Foundation
import Security

struct BackupRecord: Codable, Sendable {
  let kind: String
  let id: UUID
  let bytes: Data
}
struct BackupArchive: Codable, Sendable {
  let schema: Int
  let records: [BackupRecord]
}

/// Independently encrypted portable backup; no Keychain lookup or item.
enum WorkspaceBackup {
  private static let magic = Data("BLOOM-BACKUP-1\n".utf8)
  static let limit = 2_147_483_648
  private static func key(_ passphrase: String, salt: Data) throws -> SymmetricKey {
    let bytes: [UInt8] = try ProductCore.call(["op": "backup_key", "passphrase": passphrase,
      "salt": Array(salt)])
    return SymmetricKey(data: Data(bytes))
  }
  static func export(vault: Vault, passphrase: String, to target: URL) throws {
    let records = try FileManager.default.contentsOfDirectory(at: vault.root,
      includingPropertiesForKeys: nil).filter { $0.pathExtension == "sealed" }.map { file -> BackupRecord in
      let stem = file.deletingPathExtension().lastPathComponent
      guard let dash = stem.firstIndex(of: "-"),
        let kind = Vault.Kind(rawValue: String(stem[..<dash])),
        let id = UUID(uuidString: String(stem[stem.index(after: dash)...])) else {
        throw BoomError.invalid("Unknown private record; backup aborted without omitting it.")
      }
      return BackupRecord(kind: kind.rawValue, id: id,
        bytes: try vault.get(kind, id: id, limit: 1_100_000_000))
    }
    guard records.contains(where: { $0.kind == "workspace" && $0.id == Vault.workspaceID }) else {
      throw BoomError.invalid("The workspace index is missing.")
    }
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let data = try encoder.encode(BackupArchive(schema: 1, records: records))
    guard data.count <= limit else { throw BoomError.budget("Backup exceeds 2 GiB.") }
    var salt = Data(count: 16)
    let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    guard status == errSecSuccess else { throw BoomError.unavailable("Could not create backup salt.") }
    let header = magic + salt
    let box = try AES.GCM.seal(data, using: key(passphrase, salt: salt), authenticating: header)
    guard let combined = box.combined else { throw BoomError.invalid("Could not seal backup.") }
    try (header + combined).write(to: target, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }
  static func restore(from source: URL, passphrase: String, into vault: Vault) throws {
    guard try FileManager.default.contentsOfDirectory(atPath: vault.root.path).isEmpty else {
      throw BoomError.denied("Restore requires a fresh empty workspace.")
    }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= limit + 128 else { throw BoomError.invalid("Invalid backup file.") }
    let bytes = try Data(contentsOf: source)
    let headerCount = magic.count + 16
    guard bytes.count > headerCount + 28, bytes.starts(with: magic) else { throw BoomError.invalid("Unsupported backup format.") }
    let header = Data(bytes.prefix(headerCount)), salt = Data(header.suffix(16))
    let decrypted = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes.dropFirst(headerCount))),
      using: key(passphrase, salt: salt), authenticating: header)
    let archive = try PropertyListDecoder().decode(BackupArchive.self, from: decrypted)
    guard archive.schema == 1, archive.records.count <= 100_000,
      Set(archive.records.map { $0.kind + "/" + $0.id.uuidString }).count == archive.records.count,
      archive.records.contains(where: { $0.kind == "workspace" && $0.id == Vault.workspaceID }),
      archive.records.allSatisfy({ Vault.Kind(rawValue: $0.kind) != nil }) else {
      throw BoomError.invalid("Backup identities are invalid.")
    }
    // Admission happens in an owned sibling directory. A failure never replaces
    // an existing workspace or leaves a partially admitted one.
    let stageURL = vault.root.deletingLastPathComponent().appendingPathComponent(".restore-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stageURL) }
    let stage = try vault.sibling(at: stageURL)
    for record in archive.records { try stage.put(record.bytes, kind: Vault.Kind(rawValue: record.kind)!, id: record.id) }
    let state = try stage.decode(WorkspaceState.self, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit)
    guard state.schema == 1 else { throw BoomError.invalid("Unsupported workspace in backup.") }
    for document in state.documents {
      let data = try stage.get(.document, id: document.id, limit: 2_097_152)
      guard String(data: data, encoding: .utf8) != nil else { throw BoomError.invalid("Invalid document in backup.") }
    }
    for voice in state.voices + state.voiceVersions {
      guard try ProductCore.voice(voice.draft).revision == voice.revision else { throw BoomError.invalid("Invalid voice revision in backup.") }
    }
    try FileManager.default.removeItem(at: vault.root)
    try FileManager.default.moveItem(at: stageURL, to: vault.root)
  }
}

extension WorkspaceStore {
  func exportBackup(passphrase: String, to url: URL) throws {
    try WorkspaceBackup.export(vault: vault, passphrase: passphrase, to: url)
  }
  func restoreBackup(passphrase: String, from url: URL) throws -> (WorkspaceState, [DocumentSnapshot]) {
    let current = try load().get()
    guard current.1.allSatisfy({ $0.text.isEmpty && $0.title == "Untitled" }),
      current.0.chats.allSatisfy({ $0.messages.isEmpty && ($0.instructions ?? "").isEmpty }), current.0.voices.isEmpty,
      current.0.voiceVersions.isEmpty, current.0.attachments.isEmpty,
      current.0.candidateIDs.isEmpty, current.0.proposals.isEmpty,
      (current.0.importedFolders ?? []).isEmpty, (current.0.importedFiles ?? [:]).isEmpty else {
      throw BoomError.denied("Restore into a fresh workspace. This workspace already contains authored data and was retained.")
    }
    let stageURL = root.appendingPathComponent(".backup-admission-" + UUID().uuidString)
    let stage = try vault.sibling(at: stageURL)
    defer { try? FileManager.default.removeItem(at: stageURL) }
    try WorkspaceBackup.restore(from: url, passphrase: passphrase, into: stage)
    let retained = root.appendingPathComponent(".empty-workspace-" + UUID().uuidString)
    try FileManager.default.moveItem(at: vault.root, to: retained)
    do { try FileManager.default.moveItem(at: stageURL, to: vault.root) }
    catch { try FileManager.default.moveItem(at: retained, to: vault.root); throw error }
    do {
      let restored = try load().get()
      try FileManager.default.removeItem(at: retained)
      return restored
    } catch {
      try FileManager.default.moveItem(at: vault.root, to: stageURL)
      try FileManager.default.moveItem(at: retained, to: vault.root)
      throw error
    }
  }
}
