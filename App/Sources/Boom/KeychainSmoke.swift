import AppKit
import BoomCore
import CryptoKit
import Foundation
import Security

/// Real Security.framework calls, restricted to a disposable item. This never
/// accesses the production master key or qualifies authorization-dialog counts.
enum KeychainSmoke {
  private struct Fixture: Codable {
    let qualificationID: UUID
    let document: DocumentSnapshot
  }

  @MainActor static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --keychain-smoke create|reopen|failures|cleanup --qualification-id UUID --evidence NEW_ABSOLUTE_DIRECTORY.")
      }
      return arguments[index + 1]
    }
    let action = try argument("--keychain-smoke"), path = try argument("--evidence")
    guard ["create", "reopen", "failures", "cleanup"].contains(action), path.hasPrefix("/"),
      let id = UUID(uuidString: try argument("--qualification-id")),
      NSApp.activationPolicy() == .prohibited else {
      throw BoomError.invalid("Invalid isolated Keychain diagnostic arguments.")
    }
    try await Task.detached { try await perform(action, id: id, evidence: URL(fileURLWithPath: path)) }.value
  }

  private static func disableUI() throws {
    // Unlike kSecUseAuthenticationUIFail alone, this also covers the legacy
    // keychain used by the production item. The switch is process-local and
    // stays disabled for this diagnostic process's entire remaining lifetime.
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
      throw BoomError.unavailable("Could not disable diagnostic Keychain UI; no item was requested.")
    }
    var allowed: DarwinBoolean = true
    guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess, !allowed.boolValue else {
      throw BoomError.unavailable("Diagnostic Keychain UI suppression was not confirmed; no item was requested.")
    }
  }

  private static func selector(_ id: UUID) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: VaultSession.qualificationService(id),
     kSecAttrAccount as String: "workspace-master-key"]
  }
  private static func remove(_ id: UUID) throws {
    let status = SecItemDelete(selector(id) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw BoomError.unavailable("Disposable Keychain cleanup failed (\(status)); its UUID was retained.")
    }
  }
  private static func item(_ id: UUID) -> (OSStatus, Data?) {
    var query = selector(id), result: CFTypeRef?
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
  }
  private static func insert(_ bytes: Data, id: UUID) throws {
    var query = selector(id)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecValueData as String] = bytes
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw BoomError.unavailable("Disposable Keychain insertion failed (\(status)).") }
  }
  private static func rejected(_ operation: () throws -> Void) throws -> String {
    do { try operation() } catch { return error.localizedDescription }
    throw BoomError.invalid("The invalid-key operation unexpectedly succeeded.")
  }
  private static func inventory(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BoomError.invalid("Invalid public fixture inventory.") }
      result[file.lastPathComponent] = Digest.sha256(try Data(contentsOf: file))
    }
    return result
  }
  private static func consumers(_ root: URL, session: VaultSession) async throws -> [Vault] {
    try await withThrowingTaskGroup(of: Vault.self) { group in
      for _ in 0..<16 { group.addTask { try Vault(root: root, session: session) } }
      var result: [Vault] = []
      for try await vault in group { result.append(vault) }
      return result
    }
  }
  private static func requireStorageWorker() throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Keychain storage work reached the UI thread.") }
  }
  private static func perform(_ action: String, id: UUID, evidence: URL) async throws {
    try requireStorageWorker()
    guard !FileManager.default.fileExists(atPath: evidence.path) else {
      throw BoomError.invalid("Use fresh evidence and a background storage worker.")
    }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var receipt: [String: Any] = ["action": action, "qualification_id": id.uuidString,
      "service": VaultSession.qualificationService(id),
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "edition": Bundle.main.object(forInfoDictionaryKey: "BloomEdition") ?? "unavailable",
      "keychain_dialogs_qualified": false, "physical_denial_qualified": false]
    do {
      try disableUI()
      receipt["interaction_allowed"] = false
      let parent = evidence.deletingLastPathComponent(), root = parent.appendingPathComponent("workspace")
      let privateRoot = root.appendingPathComponent("Private"), fixtureURL = parent.appendingPathComponent("public-fixture.json")
      if action == "cleanup" {
        try remove(id)
        guard item(id).0 == errSecItemNotFound else { throw BoomError.invalid("Disposable item remains after cleanup.") }
        receipt["item_absent"] = true
      } else {
        let fixture: Fixture
        if action == "create" {
          guard !FileManager.default.fileExists(atPath: root.path), !FileManager.default.fileExists(atPath: fixtureURL.path),
            item(id).0 == errSecItemNotFound else { throw BoomError.invalid("Refuse to replace an existing fixture or Keychain item.") }
          fixture = Fixture(qualificationID: id, document: DocumentSnapshot(title: "Public Keychain fixture", text: "Public encrypted Keychain canary: Café 👩🏽‍💻\n"))
          try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .withoutOverwriting)
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } else {
          fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
          guard fixture.qualificationID == id else { throw BoomError.invalid("The fixture belongs to another disposable item.") }
        }
        if action == "failures" {
          let before = try inventory(privateRoot)
          var failures: [[String: Any]] = []
          for (name, bytes) in [("missing", Data()), ("wrong_length", Data(repeating: 0x27, count: 31))] {
            try remove(id)
            if !bytes.isEmpty { try insert(bytes, id: id) }
            let session = VaultSession(qualificationID: id)
            var messages: [String] = []
            for _ in 0..<16 { messages.append(try rejected { _ = try Vault(root: privateRoot, session: session) }) }
            guard session.lookupCount == 1, Set(messages).count == 1, try inventory(privateRoot) == before else {
              throw BoomError.invalid("A failed key request retried or changed ciphertext.")
            }
            let remaining = item(id)
            guard (bytes.isEmpty ? remaining.0 == errSecItemNotFound : remaining.0 == errSecSuccess && remaining.1 == bytes) else {
              throw BoomError.invalid("The failed session replaced its missing or malformed key.")
            }
            failures.append(["case": name, "consumers": 16, "session_lookups": session.lookupCount,
              "failure": messages[0], "ciphertext_unchanged": true, "replacement_key_created": false])
          }
          try remove(id)
          let wrong = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
          try insert(wrong, id: id)
          let session = VaultSession(qualificationID: id)
          let store = try WorkspaceStore(rootOverride: root, session: session)
          let failure = try rejected { _ = try store.vault.get(.document, id: fixture.document.id) }
          switch await store.load() {
          case .success: throw BoomError.invalid("A wrong key became empty or usable workspace state.")
          case .failure: break
          }
          guard session.lookupCount == 1, item(id).1 == wrong, try inventory(privateRoot) == before else {
            throw BoomError.invalid("Wrong-key recovery changed existing records or replaced the key.")
          }
          failures.append(["case": "wrong_key", "session_lookups": session.lookupCount,
            "failure": failure, "ciphertext_unchanged": true, "replacement_key_created": false, "empty_state_returned": false])
          receipt["failures"] = failures
        } else {
          let session = VaultSession(qualificationID: id)
          let vaults = try await consumers(privateRoot, session: session)
          let store = try WorkspaceStore(rootOverride: root, session: session)
          if action == "create" {
            var state = WorkspaceState()
            state.documents = [DocumentIndex(id: fixture.document.id, title: fixture.document.title)]
            state.selectedDocument = fixture.document.id
            try await store.save(state, documents: [fixture.document])
          }
          let before = try inventory(privateRoot)
          let restored = try await store.load().get()
          guard restored.1 == [fixture.document], session.lookupCount == 1,
            try vaults.allSatisfy({ try $0.get(.document, id: fixture.document.id) == Data(fixture.document.text.utf8) }),
            try inventory(privateRoot) == before else { throw BoomError.invalid("Real Keychain consumers or relaunch changed the public fixture.") }
          receipt["consumers"] = vaults.count; receipt["session_lookups"] = session.lookupCount
          receipt["ciphertext"] = before; receipt["document_revision"] = fixture.document.revision
          receipt["storage_worker_off_ui_thread"] = true
        }
      }
      guard VaultSession.shared.lookupCount == 0 else { throw BoomError.invalid("The diagnostic accessed the production vault session.") }
      receipt["production_session_lookups"] = 0; receipt["status"] = "passed"
    } catch {
      receipt["status"] = "failed"; receipt["failure"] = error.localizedDescription
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
      throw error
    }
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
  }
}
