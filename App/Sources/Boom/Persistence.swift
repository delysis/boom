import AppKit
import CryptoKit
import Foundation
import BoomCore
import Security

struct DocumentIndex: Codable, Sendable {
  let id: UUID
  var title: String
}
struct ImportedFolder: Codable, Identifiable, Sendable {
  let id: UUID
  let name: String
}
struct ImportedFile: Codable, Sendable {
  let folderID: UUID?
  let path: String
  let originalDigest: String
}
struct AttachmentRecord: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let rootDigest: String
  var text: String
  var coverage: String
  var transform: String?
  var isImage: Bool? = nil
  var awaitingTranscription: Bool? = nil
  var digest: String { Digest.sha256(rootDigest + "\n" + text + "\n" + (transform ?? "original")) }
  var reference: SourceReference {
    SourceReference(id: id, title: name, digest: digest, kind: "attachment")
  }
}
struct DocumentEditJournal: Codable, Sendable {
  let schema: Int
  let proposalID: UUID
  let documentID: UUID
  let beforeRevision: String
  let afterRevision: String
  let phase: String
  var capturedRevision: String? = nil
}
struct VaultInventoryEntry: Encodable, Sendable {
  let name: String
  let regular: Bool
  let digest: String?
  let bytes: Int?
}
struct WorkspaceState: Codable, Sendable {
  var schema = 1
  var documents: [DocumentIndex] = []
  var chats: [ChatRecord] = []
  var voices: [Voice] = []
  var voiceVersions: [Voice] = []
  var candidateIDs: [UUID] = []
  var manuscriptOrigins: [UUID: ManuscriptOrigin] = [:]
  var importedFolders: [ImportedFolder]? = nil
  var importedFiles: [UUID: ImportedFile]? = nil
  var attachments: [AttachmentRecord] = []
  var proposals: [StoredProposal] = []
  var selectedDocument: UUID?
  var selectedChat: UUID?
  var showLibrary = true
  var showDocument = true
  var showChat = true
  var autocomplete = true
  var preferredModels: [String: String]? = nil
  var recordingDrafts: [UUID: [UUID]]? = nil
  var theme = "system"
}

/// One current format. Decryption/schema failure NEVER becomes an empty workspace.
final class Vault: @unchecked Sendable {
  enum Kind: String, Sendable { case workspace, document, attachment, receipt, candidate, editJournal, saveJournal, generationJournal }
  static let workspaceLimit = 134_217_728
  static let workspaceID = UUID(uuidString: "726B3A82-2EB1-493B-9D8E-F17C7A6E4B8A")!
  let root: URL
  private let key: SymmetricKey
  private let lock = NSLock()
  init(root: URL, testKey: SymmetricKey? = nil, session: VaultSession = .shared) throws {
    self.root = root
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Self.requireDirectory(root)
    if let testKey {
      key = testKey
      return
    }
    key = try session.unlock(existingRecords: !FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil).isEmpty)
  }
  private static func requireDirectory(_ url: URL) throws {
    let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard v.isDirectory == true, v.isSymbolicLink != true else {
      throw BoomError.invalid("Private storage is not a real directory.")
    }
  }
  func sibling(at root: URL) throws -> Vault { try Vault(root: root, testKey: key) }
  func recordURL(_ kind: Kind, _ id: UUID) -> URL {
    root.appendingPathComponent(kind.rawValue + "-" + id.uuidString + ".sealed")
  }
  private func url(_ kind: Kind, _ id: UUID) -> URL { recordURL(kind, id) }
  private func aad(_ kind: Kind, _ id: UUID) -> Data {
    Data("bloom/v1/\(kind.rawValue)/\(id.uuidString)".utf8)
  }
  func exists(_ kind: Kind, _ id: UUID) -> Bool {
    FileManager.default.fileExists(atPath: url(kind, id).path)
  }
  func put(_ data: Data, kind: Kind, id: UUID) throws {
    guard data.count <= (kind == .workspace ? Self.workspaceLimit : 1_100_000_000) else {
      throw BoomError.budget("Private record exceeds its bound.")
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
    let v = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize,
      size <= limit + 64 else { throw BoomError.invalid("Private record has an unsafe type or size.") }
    return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: target)),
      using: key, authenticating: aad(kind, id))
  }
  func encode<T: Encodable>(_ value: T, kind: Kind, id: UUID) throws {
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    try put(encoder.encode(value), kind: kind, id: id)
  }
  func decode<T: Decodable>(_ type: T.Type, kind: Kind, id: UUID, limit: Int = 16_777_216) throws -> T {
    try PropertyListDecoder().decode(type, from: get(kind, id: id, limit: limit))
  }
  func remove(_ kind: Kind, id: UUID) throws {
    lock.lock(); defer { lock.unlock() }
    let target = url(kind, id)
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
  }
  func validateInventory(_ state: WorkspaceState, hasIndex: Bool) throws {
    let ids = Set(state.attachments.map(\.id) + Array((state.importedFiles ?? [:]).keys))
    var originals: [String: (String, Int)] = [:]
    for id in ids where exists(.attachment, id) {
      let bytes = try get(.attachment, id: id, limit: 67_108_864)
      originals[recordURL(.attachment, id).lastPathComponent] = (Digest.sha256(bytes), bytes.count)
    }
    let entries = try FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).map { file in
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      let original = originals[file.lastPathComponent]
      return VaultInventoryEntry(name: file.lastPathComponent, regular: values.isRegularFile == true && values.isSymbolicLink != true,
        digest: original?.0, bytes: original?.1)
    }
    try ProductCore.validateInventory(state, entries: entries, hasIndex: hasIndex)
  }
}

/// One Keychain result for the process, including failures. Initialization of
/// another consumer can never cause an authorization retry or a replacement key.
final class VaultSession: @unchecked Sendable {
  static let shared = VaultSession()
  private let lock = NSLock()
  private var result: Result<SymmetricKey, Error>?
  private var lookups = 0
  private let loader: (@Sendable (Bool) throws -> SymmetricKey)?
  private let service: String
  init(loader: (@Sendable (Bool) throws -> SymmetricKey)? = nil, qualificationID: UUID? = nil) {
    self.loader = loader
    service = qualificationID.map(Self.qualificationService) ?? "com.delysis.Bloom"
  }
  // A diagnostic can address only its disposable UUID namespace. Ordinary
  // launches retain the same production item and process-owned session.
  static func qualificationService(_ id: UUID) -> String {
    "com.delysis.Bloom.qualification." + id.uuidString
  }
  var lookupCount: Int { lock.lock(); defer { lock.unlock() }; return lookups }
  func unlock(existingRecords: Bool) throws -> SymmetricKey {
    lock.lock(); defer { lock.unlock() }
    if let result { return try result.get() }
    lookups += 1
    let outcome = Result { try loader?(existingRecords) ?? readOrCreate(existingRecords: existingRecords) }
    result = outcome
    return try outcome.get()
  }
  private func readOrCreate(existingRecords: Bool) throws -> SymmetricKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "workspace-master-key", kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
      guard let data = result as? Data, data.count == 32 else {
        throw BoomError.invalid("The Keychain master key has an incompatible format. Existing data and the key were retained.")
      }
      return SymmetricKey(data: data)
    }
    guard status == errSecItemNotFound else {
      throw BoomError.unavailable(
        "Keychain access failed (\(status)). Existing files are untouched.")
    }
    guard !existingRecords else {
      throw BoomError.unavailable(
        "The encryption key is missing but private data exists. Restore the original Keychain key; no replacement key was created."
      )
    }
    let newKey = SymmetricKey(size: .bits256)
    let data = newKey.withUnsafeBytes { Data($0) }
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "workspace-master-key",
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: data,
    ]
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw BoomError.unavailable("Could not create the Keychain key (\(added)).")
    }
    return newKey
  }
}

actor WorkspaceStore {
  nonisolated let root: URL
  nonisolated let vault: Vault
  private var diskRevisions: [UUID: String] = [:]
  init(rootOverride: URL? = nil, testKey: SymmetricKey? = nil, session: VaultSession = .shared) throws {
    #if BOOM_UI_TEST
    let path = ProcessInfo.processInfo.environment["BOOM_UI_TEST_ROOT"]
      ?? "/tmp/boom-ui-test-root"
    guard path.hasPrefix("/") else { throw BoomError.invalid("UI test root must be absolute.") }
    root = URL(fileURLWithPath: path).standardizedFileURL
    #else
    root = try rootOverride ?? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Bloom", isDirectory: true)
    #endif
    for u in [root] {
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
    vault = try Vault(root: root.appendingPathComponent("Private", isDirectory: true), testKey: testKey, session: session)
    #endif
  }
  func load() -> Result<(WorkspaceState, [DocumentSnapshot]), Error> {
    Result {
      try recoverSave()
      var state: WorkspaceState
      let hasIndex = vault.exists(.workspace, Vault.workspaceID)
      if hasIndex {
        state = try vault.decode(
          WorkspaceState.self, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit)
      } else {
        state = WorkspaceState()
      }
      guard state.schema == 1 else {
        throw BoomError.invalid("Unknown workspace schema. Existing data was retained.")
      }
      guard Set(state.chats.map(\.id)).count == state.chats.count,
        Set(state.voices.map(\.slug)).count == state.voices.count,
        Set(state.voices.map(\.id)).count == state.voices.count
      else { throw BoomError.invalid("Duplicate identities in workspace index.") }
      try vault.validateInventory(state, hasIndex: hasIndex)
      for voice in state.voices + state.voiceVersions {
        guard try ProductCore.voice(voice.draft).revision == voice.revision else {
          throw BoomError.invalid("Voice revision changed; encrypted record retained.")
        }
      }
      var documents: [DocumentSnapshot] = []
      for item in state.documents {
        guard FileManager.default.fileExists(atPath: documentURL(item.id).path) else {
          throw BoomError.invalid("An indexed encrypted document is missing. Workspace retained.")
        }
        let text = try readDocument(item.id)
        diskRevisions[item.id] = Digest.sha256(text)
        documents.append(DocumentSnapshot(id: item.id, title: item.title, text: text))
      }
      try ProductCore.validateOriginals(state)
      let files = state.importedFiles ?? [:]
      for (id, file) in files {
        guard vault.exists(.attachment, id),
          try Digest.sha256(vault.get(.attachment, id: id, limit: 2_097_152)) == file.originalDigest else {
          throw BoomError.invalid("An imported original is missing or changed; encrypted records retained.")
        }
      }
      for index in state.proposals.indices where state.proposals[index].status == "pending" {
        let proposal = state.proposals[index]
        guard vault.exists(.editJournal, proposal.id) else { continue }
        let journal = try vault.decode(
          DocumentEditJournal.self, kind: .editJournal, id: proposal.id)
        guard journal.schema == 1, journal.proposalID == proposal.id,
          journal.documentID == proposal.document.id,
          (journal.capturedRevision ?? journal.beforeRevision) == proposal.document.revision,
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
      try recoverGenerations(&state)
      return (state, documents)
    }
  }
  nonisolated func documentURL(_ id: UUID) -> URL { vault.recordURL(.document, id) }
  func retainImportedOriginals(_ files: [FolderImport.File], flag: CancellationFlag) throws {
    // Check the complete capture before admitting any originals. Fresh document
    // identities may never replace an existing original or manuscript.
    for file in files {
      try flag.check()
      guard !vault.exists(.attachment, file.id), !vault.exists(.document, file.id) else {
        throw BoomError.stale("An imported document identity already exists; its records were retained.")
      }
    }
    for file in files { try flag.check(); try vault.put(file.original, kind: .attachment, id: file.id) }
  }
  private func recoverGenerations(_ state: inout WorkspaceState) throws {
    var bundles: [CandidateBundle] = [], receipts: [(UUID, ConsultationReceipt)] = []
    var changed = false
    // Validate all captured records before finishing any interrupted attempt.
    for id in state.candidateIDs {
      var bundle = try readCandidate(id)
      var interrupted = false
      for index in bundle.candidates.indices {
        if let execution = bundle.candidates[index].batch {
          try ProductCore.validateWritingBatch(execution, seed: bundle.candidates[index].seed)
        }
        let journal = try writingCheckpoint(bundle: bundle, candidate: bundle.candidates[index])
        guard bundle.candidates[index].state == .pending else { continue }
        bundle.candidates[index].finishInterrupted(journal)
        interrupted = true
      }
      if interrupted { bundles.append(bundle) }
    }
    for c in state.chats.indices {
      for m in state.chats[c].messages.indices where state.chats[c].messages[m].role == .assistant {
        let message = state.chats[c].messages[m]
        if message.state == .pending {
          state.chats[c].messages[m].state = .cancelled
          state.chats[c].messages[m].failure = "The app closed before this answer was stored as complete."
          changed = true
        }
        guard vault.exists(.receipt, message.id) else {
          guard !vault.exists(.generationJournal, message.id) else {
            throw BoomError.invalid("A captured response receipt is missing; checkpoint retained.")
          }
          continue
        }
        var receipt = try vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id)
        let journal = try consultationCheckpoint(id: message.id, receipt: receipt)
        if message.state == .pending, let journal, journal.identity.kind == .consultation {
          state.chats[c].messages[m].text = journal.progress.text
        }
        if receipt.state == .pending {
          if let journal { receipt.retain(journal) }
          receipt.state = .cancelled; receipt.failure = "The app closed before this attempt completed."
          receipt.stopReason = "interrupted"
          receipts.append((message.id, receipt))
        }
      }
    }
    for bundle in bundles { try vault.encode(bundle, kind: .candidate, id: bundle.id) }
    for (id, receipt) in receipts {
      if let attemptID = receipt.attemptID { try vault.encode(receipt, kind: .receipt, id: attemptID) }
      try vault.encode(receipt, kind: .receipt, id: id)
    }
    if changed || !bundles.isEmpty || !receipts.isEmpty { try persist(state) }
  }
  func latestCandidate(for documentID: UUID, ids: [UUID]) throws -> CandidateBundle? {
    guard let latest = try candidateHistory(for: documentID, ids: ids).latest else { return nil }
    return try readCandidate(latest)
  }
  func readCandidate(_ id: UUID) throws -> CandidateBundle {
    let bundle = try vault.decode(CandidateBundle.self, kind: .candidate, id: id)
    guard bundle.id == id, Set(bundle.candidates.map(\.id)).count == bundle.candidates.count,
      bundle.candidates.isEmpty ? bundle.selected == 0 : bundle.candidates.indices.contains(bundle.selected)
    else { throw BoomError.invalid("Inconsistent continuation record; existing bytes retained.") }
    try ProductCore.validateWritingRecipe(bundle.recipe)
    let _ = try ProductCore.writingHistory(documentID: bundle.recipe.document.id, entries: [
      WritingHistoryEntry(id: bundle.id, documentId: bundle.recipe.document.id,
        maxTokens: bundle.recipe.maxTokens, candidates: bundle.candidates.count)
    ])
    return bundle
  }
  func candidateHistory(for documentID: UUID, ids: [UUID]) throws -> SavedWritingHistory {
    var entries: [WritingHistoryEntry] = [], previews: [UUID: String] = [:]
    for id in ids {
      let value = try autoreleasepool { () throws -> (WritingHistoryEntry, String) in
        let bundle = try readCandidate(id)
        let prose = bundle.candidates.indices.contains(bundle.selected) ? bundle.candidates[bundle.selected].text : ""
        let preview = prose.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? "No prose retained"
        return (WritingHistoryEntry(id: id, documentId: bundle.recipe.document.id,
          maxTokens: bundle.recipe.maxTokens, candidates: bundle.candidates.count), preview)
      }
      entries.append(value.0); previews[id] = value.1
    }
    let plan = try ProductCore.writingHistory(documentID: documentID, entries: entries)
    return SavedWritingHistory(explorations: plan.explorations.map { SavedExploration(id: $0,
      preview: previews[$0] ?? "No prose retained") }, latest: plan.latest)
  }
  func readDocument(_ id: UUID) throws -> String {
    let u = documentURL(id)
    let v = try u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 2_097_152 + 64
    else { throw BoomError.invalid("Document is not a bounded regular UTF-8 file.") }
    let data = try vault.get(.document, id: id, limit: 2_097_152)
    guard let text = String(data: data, encoding: .utf8) else {
      throw BoomError.invalid("Document is not valid UTF-8; original bytes were retained.")
    }
    return text
  }
  func checkDisk(_ id: UUID) throws {
    guard let expected = diskRevisions[id] else { return }
    guard FileManager.default.fileExists(atPath: documentURL(id).path) else {
      throw BoomError.unavailable("The encrypted document is missing. Export the open text before closing.")
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
        try vault.put(Data(document.text.utf8), kind: .document, id: document.id)
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
  struct SaveJournal: Codable {
    let schema: Int
    let state: WorkspaceState
    let documents: [DocumentSnapshot]
    let before: [UUID: String]
  }
  private func recoverSave() throws {
    guard vault.exists(.saveJournal, Vault.workspaceID) else { return }
    let journal = try vault.decode(SaveJournal.self, kind: .saveJournal, id: Vault.workspaceID, limit: Vault.workspaceLimit)
    guard journal.schema == 1, journal.state.schema == 1,
      Set(journal.documents.map(\.id)).count == journal.documents.count,
      journal.documents.allSatisfy({ doc in journal.state.documents.contains { $0.id == doc.id } }) else {
      throw BoomError.invalid("Invalid save journal; existing records retained.")
    }
    // Validate every record before repairing any of them.
    for document in journal.documents {
      let actual = vault.exists(.document, document.id) ? Digest.sha256(try readDocument(document.id)) : nil
      guard actual == journal.before[document.id] || actual == document.revision else {
        throw BoomError.stale("An interrupted save conflicts with a document; journal retained.")
      }
    }
    for document in journal.documents {
      try vault.put(Data(document.text.utf8), kind: .document, id: document.id)
      diskRevisions[document.id] = document.revision
    }
    try persist(journal.state)
    try vault.remove(.saveJournal, id: Vault.workspaceID)
  }
  func save(_ state: WorkspaceState, documents: [DocumentSnapshot]) throws {
    try recoverSave()
    for document in documents { try checkDisk(document.id) }
    let journal = SaveJournal(schema: 1, state: state, documents: documents, before: diskRevisions)
    try vault.encode(journal, kind: .saveJournal, id: Vault.workspaceID)
    for document in documents { try saveDocument(document) }
    try persist(state)
    try vault.remove(.saveJournal, id: Vault.workspaceID)
  }
}

extension WorkspaceStore {
  func exportBackup(passphrase: String, to url: URL) throws {
    try WorkspaceBackup.export(vault: vault, passphrase: passphrase, to: url)
  }
  func restoreBackup(passphrase: String, from url: URL) throws -> (WorkspaceState, [DocumentSnapshot]) {
    // Inspect without load(): recovery may write journals or finish interrupted
    // responses, which is inappropriate before rejecting an occupied target.
    let hasIndex = vault.exists(.workspace, Vault.workspaceID)
    let current = try hasIndex ? vault.decode(WorkspaceState.self, kind: .workspace,
      id: Vault.workspaceID, limit: Vault.workspaceLimit) : WorkspaceState()
    let documents = try current.documents.map {
      DocumentSnapshot(id: $0.id, title: $0.title, text: try readDocument($0.id))
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: vault.root.path)
    try ProductCore.admitRestore(current, documents: documents, entries: entries, hasIndex: hasIndex)
    let stageURL = root.appendingPathComponent(".backup-admission-" + UUID().uuidString)
    let stage = try vault.sibling(at: stageURL)
    var discardStage = true
    defer { if discardStage { try? FileManager.default.removeItem(at: stageURL) } }
    try WorkspaceBackup.restore(from: url, passphrase: passphrase, into: stage)
    try AtomicDirectoryReplacement.exchange(stageURL, vault.root)
    // The stage now holds the previous workspace. Retain it if rollback fails.
    discardStage = false
    let beforeRevisions = diskRevisions
    diskRevisions.removeAll()
    do {
      let restored = try load().get()
      discardStage = true
      return restored
    } catch {
      do { try AtomicDirectoryReplacement.exchange(stageURL, vault.root) }
      catch {
        throw BoomError.unavailable("Restore rollback failed. Both encrypted directories were retained: \(error.localizedDescription)")
      }
      diskRevisions = beforeRevisions
      discardStage = true
      throw error
    }
  }
}
