import BoomCore
import CryptoKit
import Darwin
import Foundation
import Security

/// Native filesystem operation only. Rust owns restore admission. Both vault
/// directories keep a name throughout publication and rollback; no move fallback.
enum AtomicDirectoryReplacement {
  static func exchange(_ first: URL, _ second: URL) throws {
    let parent = first.deletingLastPathComponent()
    guard first != second, parent == second.deletingLastPathComponent() else {
      throw BoomError.invalid("Private replacement requires distinct sibling directories.")
    }
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    for name in [first.lastPathComponent, second.lastPathComponent] {
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw BoomError.invalid("Private replacement requires real directories.")
      }
    }
    guard renameatx_np(fd, first.lastPathComponent, fd, second.lastPathComponent,
      UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

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
    try AtomicDirectoryReplacement.exchange(stageURL, vault.root)
  }
}
