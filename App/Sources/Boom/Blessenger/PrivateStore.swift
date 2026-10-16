import BoomCore
import Foundation
import Security

/// One cached credential outcome per process; a failed lookup is not retried by
/// a new consumer. Workspace exclusion is acquired before calling this owner.
final class BlessengerKeySession: @unchecked Sendable {
  static let shared = BlessengerKeySession()
  private let lock = NSLock()
  private var outcome: Result<RecordCipher, Error>?
  private let load: @Sendable (Bool) throws -> Data

  init(load: @escaping @Sendable (Bool) throws -> Data = BlessengerKeySession.keychain) { self.load = load }
  func cipher(existingRecords: Bool) throws -> RecordCipher {
    lock.lock(); defer { lock.unlock() }
    if let outcome { return try outcome.get() }
    let result = Result { try RecordCipher(key: load(existingRecords)) }
    outcome = result
    return try result.get()
  }
  private static func keychain(existing: Bool) throws -> Data {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.delysis.blessenger.vault",
      kSecAttrAccount as String: "master-key-v1", kSecAttrSynchronizable as String: false]
    func read() throws -> Data? {
      var selected = query
      selected[kSecReturnData as String] = true; selected[kSecMatchLimit as String] = kSecMatchLimitOne
      var value: CFTypeRef?
      let status = SecItemCopyMatching(selected as CFDictionary, &value)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = value as? Data, data.count == 32 else {
        throw BoomError.denied("The private workspace key could not be read (Keychain \(status)). Existing data was retained.")
      }
      return data
    }
    if let key = try read() { return key }
    guard !existing else { throw BoomError.denied("The key for this private workspace is missing. No replacement key was created.") }
    var bytes = Data(count: 32)
    let generated = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard generated == errSecSuccess else { throw BoomError.unavailable("Secure key generation failed.") }
    var insert = query
    insert[kSecValueData as String] = bytes
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(insert as CFDictionary, nil)
    if status == errSecSuccess { return bytes }
    if status == errSecDuplicateItem, let winner = try read() { return winner }
    throw BoomError.denied("The private workspace key could not be created (Keychain \(status)).")
  }
}

enum BlessengerInventory {
  static func hasRecords(_ root: URL) throws -> Bool {
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    if names.contains(where: { ![".workspace-lock", "Objects"].contains($0) }) { return true }
    let objects = root.appendingPathComponent("Objects", isDirectory: true)
    if FileManager.default.fileExists(atPath: objects.path) {
      return try !FileManager.default.contentsOfDirectory(atPath: objects.path).isEmpty
    }
    return false
  }
  /// Unknown private bytes cannot be silently interpreted as a fresh workspace.
  static func validate(_ store: WorkspaceStore, fresh: Bool) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
    guard names.allSatisfy({ [".workspace-lock", "Objects", "identity.json", "workspace.json"].contains($0) }) else {
      throw BoomError.invalid("Unrecognized private workspace files require review; nothing was removed.")
    }
    let objects = try FileManager.default.contentsOfDirectory(atPath: store.vault.root.path)
    guard !fresh || objects.isEmpty else {
      throw BoomError.invalid("Private records exist without their workspace index. They were not replaced with empty state.")
    }
    let kinds = ["attachment", "receipt", "candidate", "editJournal", "generationJournal"]
    for name in objects {
      guard let kind = kinds.first(where: { name.hasPrefix($0 + "-") }), name.hasSuffix(".record"),
        UUID(uuidString: String(name.dropFirst(kind.count + 1).dropLast(7))) != nil else {
        throw BoomError.invalid("Unrecognized or unfinished private record \(name) requires review.")
      }
      _ = try RegularFile(store.vault.root.appendingPathComponent(name), limit: 1_100_000_036)
    }
  }
}
