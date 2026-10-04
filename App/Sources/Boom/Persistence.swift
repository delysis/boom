import AppKit
import CryptoKit
import Foundation
import BoomCore
import Security

struct DocumentIndex: Codable {
  let id: UUID
  var title: String
}
struct AttachmentRecord: Codable, Identifiable, Equatable {
  let id: UUID
  let name: String
  let rootDigest: String
  var text: String
  var coverage: String
  var transform: String?
  var isImage: Bool? = nil
  var digest: String { Digest.sha256(rootDigest + "\n" + text + "\n" + (transform ?? "original")) }
  var reference: SourceReference {
    SourceReference(id: id, title: name, digest: digest, kind: "attachment")
  }
}
struct DocumentEditJournal: Codable {
  let schema: Int
  let proposalID: UUID
  let documentID: UUID
  let beforeRevision: String
  let afterRevision: String
  let phase: String
}
struct WorkspaceState: Codable {
  var schema = 1
  var documents: [DocumentIndex] = []
  var chats: [ChatRecord] = []
  var personas: [Persona] = []
  var attachments: [AttachmentRecord] = []
  var proposals: [StoredProposal] = []
  var selectedDocument: UUID?
  var selectedChat: UUID?
  var installedModel: String?
  var showLibrary = true
  var showDocument = true
  var showChat = true
  var autocomplete = true
  var theme = "system"
}

/// One current format. Decryption/schema failure NEVER becomes an empty workspace.
final class Vault: @unchecked Sendable {
  enum Kind: String { case workspace, attachment, receipt, personaCache, followCache, editJournal }
  static let followCacheID = UUID(uuidString: "D735A2F6-5EA7-48AF-B578-E994A32F6E7A")!
  static let workspaceLimit = 134_217_728
  static let workspaceID = UUID(uuidString: "726B3A82-2EB1-493B-9D8E-F17C7A6E4B8A")!
  let root: URL
  private let key: SymmetricKey
  private let lock = NSLock()
  init(root: URL, testKey: SymmetricKey? = nil) throws {
    self.root = root
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Self.requireDirectory(root)
    if let testKey {
      key = testKey
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.delysis.Boom.v1",
      kSecAttrAccount as String: "workspace-key", kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 {
      key = SymmetricKey(data: data)
      return
    }
    guard status == errSecItemNotFound else {
      throw BoomError.unavailable(
        "Keychain access failed (\(status)). Existing files are untouched.")
    }
    let sealed =
      (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      .contains { $0.pathExtension == "sealed" }
    guard !sealed else {
      throw BoomError.unavailable(
        "The encryption key is missing but private data exists. Restore the original Keychain key; no replacement key was created."
      )
    }
    let newKey = SymmetricKey(size: .bits256)
    let data = newKey.withUnsafeBytes { Data($0) }
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.delysis.Boom.v1",
      kSecAttrAccount as String: "workspace-key",
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data,
    ]
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw BoomError.unavailable("Could not create the Keychain key (\(added)).")
    }
    key = newKey
  }
  private static func requireDirectory(_ url: URL) throws {
    let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard v.isDirectory == true, v.isSymbolicLink != true else {
      throw BoomError.invalid("Private storage is not a real directory.")
    }
  }
  private func url(_ kind: Kind, _ id: UUID) -> URL {
    root.appendingPathComponent(kind.rawValue + "-" + id.uuidString + ".sealed")
  }
  private func aad(_ kind: Kind, _ id: UUID) -> Data {
    Data("boom/v1/\(kind.rawValue)/\(id.uuidString)".utf8)
  }
  func exists(_ kind: Kind, _ id: UUID) -> Bool {
    FileManager.default.fileExists(atPath: url(kind, id).path)
  }
  func put(_ data: Data, kind: Kind, id: UUID) throws {
    guard data.count <= (kind == .workspace ? Self.workspaceLimit : 1_100_000_000) else {
      throw BoomError.budget("Private record exceeds the 1.1 GB bound.")
    }
    lock.lock()
    defer { lock.unlock() }
    let encrypted = try AES.GCM.seal(data, using: key, authenticating: aad(kind, id))
    guard let combined = encrypted.combined else {
      throw BoomError.invalid("Could not encode the authenticated record.")
    }
    let target = url(kind, id)
    if FileManager.default.fileExists(atPath: target.path) {
      let v = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard v.isSymbolicLink != true else {
        throw BoomError.invalid("Refusing a symlink in private storage.")
      }
    }
    try combined.write(to: target, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }
  func get(_ kind: Kind, id: UUID, limit: Int = 16_777_216) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let target = url(kind, id)
    let v = try target.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize,
      size <= limit + 64
    else { throw BoomError.invalid("Private record has an unsafe type or size.") }
    let sealed = try Data(contentsOf: target, options: .mappedIfSafe)
    return try AES.GCM.open(
      AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad(kind, id))
  }
  func encode<T: Encodable>(_ value: T, kind: Kind, id: UUID) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try put(encoder.encode(value), kind: kind, id: id)
  }
  func decode<T: Decodable>(_ type: T.Type, kind: Kind, id: UUID, limit: Int = 16_777_216) throws
    -> T
  {
    try PropertyListDecoder().decode(type, from: get(kind, id: id, limit: limit))
  }
  /// Delete is called only for an explicit user deletion, never on a cache miss.
  func remove(_ kind: Kind, id: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    let target = url(kind, id)
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
  }
}

@MainActor final class WorkspaceStore {
  let root: URL
  let documentsURL: URL
  let modelsURL: URL
  let vault: Vault
  private var diskRevisions: [UUID: String] = [:]
  init() throws {
    #if BOOM_UI_TEST
    let path = ProcessInfo.processInfo.environment["BOOM_UI_TEST_ROOT"]
      ?? "/tmp/boom-ui-test-root"
    guard path.hasPrefix("/") else { throw BoomError.invalid("UI test root must be absolute.") }
    root = URL(fileURLWithPath: path).standardizedFileURL
    #else
    // Keep the existing workspace path when the app's public name changes.
    root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Boom", isDirectory: true)
    #endif
    documentsURL = root.appendingPathComponent("Documents", isDirectory: true)
    modelsURL = root.appendingPathComponent("Models", isDirectory: true)
    for u in [root, documentsURL, modelsURL] {
      try FileManager.default.createDirectory(
        at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let values = try u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw BoomError.invalid("Workspace directory is a symlink or not a directory.")
      }
    }
    #if BOOM_UI_TEST
    vault = try Vault(
      root: root.appendingPathComponent("Private", isDirectory: true),
      testKey: SymmetricKey(data: Data(repeating: 0x42, count: 32)))
    #else
    vault = try Vault(root: root.appendingPathComponent("Private", isDirectory: true))
    #endif
  }
  func load() -> Result<(WorkspaceState, [DocumentSnapshot]), Error> {
    Result {
      var state: WorkspaceState
      if vault.exists(.workspace, Vault.workspaceID) {
        state = try vault.decode(
          WorkspaceState.self, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit)
      } else {
        let existingDocuments = try FileManager.default.contentsOfDirectory(
          at: documentsURL, includingPropertiesForKeys: nil
        ).contains { $0.pathExtension == "md" }
        let existingPrivate = try FileManager.default.contentsOfDirectory(
          at: vault.root, includingPropertiesForKeys: nil
        ).contains { $0.pathExtension == "sealed" }
        guard !existingDocuments, !existingPrivate else {
          throw BoomError.invalid(
            "The workspace index is missing while local data exists. Existing files were retained; no empty replacement workspace was created."
          )
        }
        state = WorkspaceState()
      }
      guard state.schema == 1 else {
        throw BoomError.invalid("Unknown workspace schema. Existing data was retained.")
      }
      guard Set(state.documents.map(\.id)).count == state.documents.count,
        Set(state.chats.map(\.id)).count == state.chats.count,
        Set(state.personas.map(\.slug)).count == state.personas.count
      else { throw BoomError.invalid("Duplicate identities in workspace index.") }
      var documents: [DocumentSnapshot] = []
      var missing = Set<UUID>()
      for item in state.documents {
        guard FileManager.default.fileExists(atPath: documentURL(item.id).path) else {
          missing.insert(item.id)
          continue
        }
        let text = try readDocument(item.id)
        diskRevisions[item.id] = Digest.sha256(text)
        documents.append(DocumentSnapshot(id: item.id, title: item.title, text: text))
      }
      if !missing.isEmpty {
        // The bytes are already gone. Drop only stale library pointers; chat
        // snapshots and edit journals remain intact for provenance/recovery.
        state.documents.removeAll { missing.contains($0.id) }
        if state.selectedDocument.map(missing.contains) == true {
          state.selectedDocument = documents.first?.id
        }
        for index in state.chats.indices {
          if state.chats[index].attachedDocumentID.map(missing.contains) == true {
            state.chats[index].attachedDocumentID = nil
          }
        }
      }
      for index in state.proposals.indices where state.proposals[index].status == "pending" {
        let proposal = state.proposals[index]
        guard vault.exists(.editJournal, proposal.id) else { continue }
        let journal = try vault.decode(
          DocumentEditJournal.self, kind: .editJournal, id: proposal.id)
        guard journal.schema == 1, journal.proposalID == proposal.id,
          journal.documentID == proposal.document.id,
          journal.beforeRevision == proposal.document.revision,
          ["prepared", "file_written"].contains(journal.phase)
        else { throw BoomError.invalid("Unknown or inconsistent edit journal; evidence retained.") }
        if let actual = documents.first(where: { $0.id == journal.documentID }),
          actual.revision == journal.afterRevision
        {
          state.proposals[index].status = "recovered content present"
        } else if journal.phase == "file_written"
          || documents.first(where: { $0.id == journal.documentID })?.revision
            != journal.beforeRevision
        {
          state.proposals[index].status = "recovery needs review"
        }
      }
      if !missing.isEmpty { try persist(state) }
      return (state, documents)
    }
  }
  func documentURL(_ id: UUID) -> URL { documentsURL.appendingPathComponent(id.uuidString + ".md") }
  func readDocument(_ id: UUID) throws -> String {
    let u = documentURL(id)
    let v = try u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 2_097_152
    else { throw BoomError.invalid("Document is not a bounded regular UTF-8 file.") }
    let data = try Data(contentsOf: u)
    guard let text = String(data: data, encoding: .utf8) else {
      throw BoomError.invalid("Document is not valid UTF-8; original bytes were retained.")
    }
    return text
  }
  func checkDisk(_ id: UUID) throws {
    guard let expected = diskRevisions[id] else { return }
    guard FileManager.default.fileExists(atPath: documentURL(id).path) else {
      throw BoomError.unavailable(
        "This document's Markdown file was removed outside Bloom. The open text is still in memory; copy it before closing the window.")
    }
    guard Digest.sha256(try readDocument(id)) == expected else {
      throw BoomError.stale(
        "Document was edited outside Bloom. Export your current buffer before reloading it.")
    }
  }
  func saveDocument(_ document: DocumentSnapshot) throws {
    guard document.text.utf8.count <= 2_097_152 else {
      throw BoomError.budget("Markdown document exceeds 2 MiB.")
    }
    let u = documentURL(document.id)
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var failure: Error?
    coordinator.coordinate(writingItemAt: u, options: .forReplacing, error: &coordinationError) {
      target in
      do {
        try self.checkDisk(document.id)
        // New IDs cannot overwrite an unindexed existing file.
        if self.diskRevisions[document.id] == nil,
          FileManager.default.fileExists(atPath: target.path)
        {
          throw BoomError.stale("New document UUID collides with an existing file.")
        }
        try Data(document.text.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        self.diskRevisions[document.id] = document.revision
      } catch { failure = error }
    }
    if let failure { throw failure }
    if let coordinationError { throw coordinationError }
  }
  func trashDocument(_ id: UUID) throws {
    guard FileManager.default.fileExists(atPath: documentURL(id).path) else {
      diskRevisions.removeValue(forKey: id)
      return
    }
    try checkDisk(id)
    try FileManager.default.trashItem(at: documentURL(id), resultingItemURL: nil)
    diskRevisions.removeValue(forKey: id)
  }
  func persist(_ state: WorkspaceState) throws {
    try vault.encode(state, kind: .workspace, id: Vault.workspaceID)
  }
}
