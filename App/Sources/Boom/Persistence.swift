import AppKit
import CryptoKit
import Darwin
import Foundation
import BoomCore
import Security

struct DocumentIndex: Codable, Equatable, Sendable {
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
  var awaitingPreparation: Bool? = nil
  var presentation: AttachmentKind? = nil
  var kind: AttachmentKind { presentation ?? (isImage == true ? .image : !text.isEmpty ? .document : AttachmentKind(name: name)) }
  var needsPreparation: Bool { awaitingTranscription == true || awaitingPreparation == true }
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
struct ComposerOwner: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable { case chat, document }
  let kind: Kind
  let id: UUID
}
struct ComposerDraft: Codable, Sendable {
  let owner: ComposerOwner
  let text: String
  let attachments: [UUID]
  let authoredRole: Role?
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
  var composerDrafts: [ComposerDraft]? = nil
  var writingExampleIDs: [UUID]? = nil
  var theme = "system"

  func validateRetainedInput() throws {
    let documents = Set(documents.map(\.id)), chats = Set(chats.map(\.id))
    let attachments = Set(attachments.map(\.id))
    let examples = writingExampleIDs ?? []
    guard examples.count <= 32, Set(examples).count == examples.count,
      examples.allSatisfy(documents.contains) else {
      throw BoomError.invalid("Writing example selection is inconsistent; encrypted records retained.")
    }
    var owners = Set<ComposerOwner>()
    for draft in composerDrafts ?? [] {
      guard owners.insert(draft.owner).inserted,
        (draft.owner.kind == .chat ? chats : documents).contains(draft.owner.id),
        draft.attachments.count <= 8, Set(draft.attachments).count == draft.attachments.count,
        draft.attachments.allSatisfy(attachments.contains) else {
        throw BoomError.invalid("Unsent message ownership is inconsistent; encrypted records retained.")
      }
      guard draft.text.utf8.count <= 2_097_152 else {
        throw BoomError.budget("Unsent text exceeds 2 MiB. Shorten it or copy it to a document before closing.")
      }
    }
  }
}

/// One current format. Decryption/schema failure NEVER becomes an empty workspace.
final class Vault: @unchecked Sendable {
  enum Kind: String, Sendable { case workspace, document, attachment, receipt, candidate, editJournal, saveJournal, generationJournal, workspaceIdentity }
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
    let trace = PerformanceTrace.begin("Storage.Put")
    defer { PerformanceTrace.end("Storage.Put", trace) }
    guard data.count <= ([Kind.workspace, .saveJournal].contains(kind) ? Self.workspaceLimit : 1_100_000_000) else {
      throw BoomError.budget("Private record exceeds its bound.")
    }
    let lockTrace = PerformanceTrace.begin("Storage.LockWait")
    lock.lock()
    PerformanceTrace.end("Storage.LockWait", lockTrace)
    defer { lock.unlock() }
    let encrypted = try {
      let trace = PerformanceTrace.begin("Storage.Encrypt")
      defer { PerformanceTrace.end("Storage.Encrypt", trace) }
      return try AES.GCM.seal(data, using: key, authenticating: aad(kind, id))
    }()
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
    let writeTrace = PerformanceTrace.begin("Storage.AtomicWrite")
    defer { PerformanceTrace.end("Storage.AtomicWrite", writeTrace) }
    try combined.write(to: target, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }
  func get(_ kind: Kind, id: UUID, limit: Int = 16_777_216) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let target = url(kind, id)
    let bound = limit.addingReportingOverflow(64)
    guard limit >= 0, !bound.overflow else { throw BoomError.invalid("Invalid private read bound.") }
    let ciphertext = try RegularFile(target, limit: Int64(bound.partialValue)).data()
    let data = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
      using: key, authenticating: aad(kind, id))
    guard data.count <= limit else { throw BoomError.budget("Private record exceeds its read bound.") }
    return data
  }
  /// A one-time, bounded bootstrap under the existing Vault key. Creation
  /// refuses replacement; both file and parent are synchronized before SQL
  /// may create any content. A partial creation remains an explicit failure.
  func createWorkspaceIdentity(_ data: Data) throws {
    guard !Thread.isMainThread, data.count <= 512 else {
      throw BoomError.invalid("Workspace identity creation must be bounded and off Main.")
    }
    lock.lock(); defer { lock.unlock() }
    let box = try AES.GCM.seal(data, using: key, authenticating: aad(.workspaceIdentity, Self.workspaceID))
    guard let bytes = box.combined else { throw BoomError.invalid("Could not encode workspace identity.") }
    let target = url(.workspaceIdentity, Self.workspaceID)
    let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw BoomError.unavailable("Workspace identity already exists or could not be created; records retained.") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var closeAttempted = false
    do {
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      closeAttempted = true
      try handle.close()
    } catch {
      let original = error
      if !closeAttempted {
        do { try handle.close() }
        catch { throw BoomError.unavailable("Workspace identity write failed: \(original.localizedDescription). Close also failed: \(error.localizedDescription)") }
      }
      throw original
    }
    try synchronizeWorkspaceIdentity()
  }
  /// A valid bootstrap left before SQL creation may be resumed only after
  /// synchronizing its existing file and namespace again. No record is rewritten.
  func synchronizeWorkspaceIdentity() throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Workspace identity sync must run off Main.") }
    for (target, directory) in [(url(.workspaceIdentity, Self.workspaceID), false), (root, true)] {
      let descriptor = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
      guard descriptor >= 0 else { throw BoomError.unavailable("Workspace identity could not be synchronized; records retained.") }
      var info = stat()
      let admitted = fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
      let syncCode = admitted ? fsync(descriptor) : -1, syncErrno = errno
      let closeCode = Darwin.close(descriptor), closeErrno = errno
      guard admitted, syncCode == 0, closeCode == 0 else {
        throw BoomError.unavailable("Workspace identity did not join: sync \(syncCode)/\(syncErrno), close \(closeCode)/\(closeErrno); records retained.")
      }
    }
  }
  // New SQL object format; shipped private Vault and backup crypto bytes
  // stay unchanged. No new key owner, actor, cipher or plaintext store.
  func sealPagedSQLiteObject(_ bytes: Data, binding: PagedSQLiteBinding) throws -> Data {
    guard !Thread.isMainThread, bytes.count == binding.plaintextBytes else {
      throw BoomError.invalid("SQLite encryption must match its admitted bounded object.")
    }
    let box = try AES.GCM.seal(bytes, using: key, authenticating: binding.authenticatedData)
    guard let combined = box.combined, combined.count == bytes.count + 28 else {
      throw BoomError.invalid("Could not encode the bounded SQLite object.")
    }
    return combined
  }
  func openPagedSQLiteObject(_ ciphertext: Data, binding: PagedSQLiteBinding) throws -> Data {
    guard !Thread.isMainThread, ciphertext.count == binding.plaintextBytes + 28 else {
      throw BoomError.invalid("SQLite ciphertext differs from its admitted object extent.")
    }
    let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
      using: key, authenticating: binding.authenticatedData)
    guard bytes.count == binding.plaintextBytes else { throw BoomError.invalid("SQLite plaintext length changed.") }
    return bytes
  }
  func encode<T: Encodable>(_ value: T, kind: Kind, id: UUID) throws {
    let trace = PerformanceTrace.begin("Storage.Encode")
    defer { PerformanceTrace.end("Storage.Encode", trace) }
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
  private var admittedLegacyDocuments: [UUID: LegacyWorkspaceDocumentDescriptor] = [:]
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
      try loadLegacyWorkspace { item, bytes in
        guard let text = String(data: bytes, encoding: .utf8) else {
          throw BoomError.invalid("Document is not valid UTF-8; original bytes were retained.")
        }
        let document = DocumentSnapshot(id: item.id, title: item.title, text: text)
        return (document, document.revision, nil)
      }
    }
  }

  /// Ordinary library/open can consume this catalog without retaining every
  /// live manuscript String. Historical recovery/proposal evidence keeps its
  /// existing format. Legacy AEAD/UTF-8 admission remains complete and bounded;
  /// paged workspaces use the separate engine/publisher catalog route below.
  func loadDocumentCatalog() -> Result<(WorkspaceState, [WorkspaceDocumentDescriptor]), Error> {
    Result {
      try loadLegacyWorkspace { item, bytes in
        let legacy = LegacyWorkspaceDocumentDescriptor(index: item,
          plaintextSha256: Digest.sha256(bytes), summary: try LegacyWorkspaceDocumentDescriptor.summary(of: bytes))
        return (WorkspaceDocumentDescriptor.legacy(legacy), nil, legacy)
      }
    }
  }

  private func loadLegacyWorkspace<Capture>(
    capture: (DocumentIndex, Data) throws
      -> (value: Capture, legacyTextRevision: String?, catalogDescriptor: LegacyWorkspaceDocumentDescriptor?)
  ) throws -> (WorkspaceState, [Capture]) {
    admittedLegacyDocuments.removeAll()
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
    try state.validateRetainedInput()
    try vault.validateInventory(state, hasIndex: hasIndex)
    for voice in state.voices + state.voiceVersions {
      guard try ProductCore.voice(voice.draft).revision == voice.revision else {
        throw BoomError.invalid("Voice revision changed; encrypted record retained.")
      }
    }
    var documents: [Capture] = []
    var loadedIDs = Set<UUID>(), loadedTextRevisions: [UUID: String] = [:]
    var admittedCatalog: [UUID: LegacyWorkspaceDocumentDescriptor] = [:]
    for item in state.documents {
      guard FileManager.default.fileExists(atPath: documentURL(item.id).path) else {
        throw BoomError.invalid("An indexed encrypted document is missing. Workspace retained.")
      }
      let captured = try autoreleasepool {
        let bytes = try readLegacyDocumentBytes(item.id)
        let captured = try capture(item, bytes)
        // Raw AEAD plaintext identity cannot silently replace the revision of
        // the existing String decoder. Open/snapshot still uses that decoder.
        if let descriptor = captured.catalogDescriptor {
          admittedCatalog[item.id] = descriptor
        }
        if let revision = captured.legacyTextRevision {
          diskRevisions[item.id] = revision; loadedTextRevisions[item.id] = revision
        }
        return captured.value
      }
      loadedIDs.insert(item.id)
      documents.append(captured)
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
      let actualRevision: String?
      if !loadedIDs.contains(journal.documentID) { actualRevision = nil }
      else if let captured = loadedTextRevisions[journal.documentID] { actualRevision = captured }
      else {
        // Historical legacy recovery is an explicit bounded text consumer.
        // Preserve its exact decoder/revision semantics; do not fake a SHA.
        actualRevision = Digest.sha256(try readDocument(journal.documentID))
      }
      if actualRevision == journal.afterRevision {
        state.proposals[index].status = "recovered content present"
      } else if journal.phase == "file_written" || actualRevision != journal.beforeRevision {
        state.proposals[index].status = "recovery needs review"
      }
    }
    try recoverGenerations(&state)
    admittedLegacyDocuments = admittedCatalog
    return (state, documents)
  }
  /// Selection/draft-only publication does not change document admission.
  /// Source writes still invalidate their own descriptor. Titles use exact
  /// bytes; duplicate metadata refuses any retained admission without a trap.
  private func retainLegacyCatalog(matching documents: [DocumentIndex]) {
    var titles: [UUID: String] = [:]
    for document in documents {
      guard titles.updateValue(document.title, forKey: document.id) == nil else {
        admittedLegacyDocuments.removeAll(); return
      }
    }
    admittedLegacyDocuments = admittedLegacyDocuments.filter { entry in
      guard let title = titles[entry.key] else { return false }
      return title.utf8.elementsEqual(entry.value.title.utf8)
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
  private func readLegacyDocumentBytes(_ id: UUID) throws -> Data {
    let u = documentURL(id)
    let v = try u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 2_097_152 + 64
    else { throw BoomError.invalid("Document is not a bounded regular UTF-8 file.") }
    return try vault.get(.document, id: id, limit: 2_097_152)
  }
  func readDocument(_ id: UUID) throws -> String {
    let data = try readLegacyDocumentBytes(id)
    guard let text = String(data: data, encoding: .utf8) else {
      throw BoomError.invalid("Document is not valid UTF-8; original bytes were retained.")
    }
    return text
  }
  /// A selected legacy source is materialized only by this explicit bounded
  /// request, against the descriptor actually admitted during catalog load.
  func readDocument(_ descriptor: LegacyWorkspaceDocumentDescriptor) throws -> DocumentSnapshot {
    guard admittedLegacyDocuments[descriptor.id] == descriptor else {
      throw BoomError.stale("Legacy document capture no longer matches its admitted catalog.")
    }
    let bytes = try readLegacyDocumentBytes(descriptor.id)
    guard Digest.sha256(bytes) == descriptor.plaintextSha256,
      try LegacyWorkspaceDocumentDescriptor.summary(of: bytes) == descriptor.summary,
      let text = String(data: bytes, encoding: .utf8) else {
      throw BoomError.stale("Legacy document changed after catalog admission; encrypted records retained.")
    }
    let document = DocumentSnapshot(id: descriptor.id, title: descriptor.title, text: text)
    diskRevisions[descriptor.id] = document.revision
    return document
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
    try Self.validateDocumentSize(document)
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
        self.admittedLegacyDocuments.removeValue(forKey: document.id)
      } catch { failure = error }
    }
    if let failure { throw failure }
    if let coordinationError { throw coordinationError }
  }
  func trashDocument(_ id: UUID) throws {
    guard FileManager.default.fileExists(atPath: documentURL(id).path) else {
      diskRevisions.removeValue(forKey: id)
      admittedLegacyDocuments.removeValue(forKey: id)
      return
    }
    try checkDisk(id)
    try FileManager.default.trashItem(at: documentURL(id), resultingItemURL: nil)
    diskRevisions.removeValue(forKey: id)
    admittedLegacyDocuments.removeValue(forKey: id)
  }
  func persist(_ state: WorkspaceState) throws {
    try state.validateRetainedInput()
    try vault.encode(state, kind: .workspace, id: Vault.workspaceID)
    retainLegacyCatalog(matching: state.documents)
  }
  struct SaveJournal: Codable {
    let schema: Int
    let state: WorkspaceState
    let documents: [DocumentSnapshot]
    let before: [UUID: String]
  }
  private static func validateDocumentSize(_ document: DocumentSnapshot) throws {
    guard document.text.utf8.count <= 2_097_152 else {
      throw BoomError.budget("Markdown document exceeds 2 MiB.")
    }
  }
  private func recoverSave() throws {
    guard vault.exists(.saveJournal, Vault.workspaceID) else { return }
    let journal = try vault.decode(SaveJournal.self, kind: .saveJournal, id: Vault.workspaceID, limit: Vault.workspaceLimit)
    guard journal.schema == 1, journal.state.schema == 1,
      Set(journal.documents.map(\.id)).count == journal.documents.count,
      Set(journal.state.documents.map(\.id)).count == journal.state.documents.count,
      journal.documents.allSatisfy({ doc in journal.state.documents.contains { $0.id == doc.id } }) else {
      throw BoomError.invalid("Invalid save journal; existing records retained.")
    }
    try journal.state.validateRetainedInput()
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    guard try encoder.encode(journal.state).count <= Vault.workspaceLimit else {
      throw BoomError.budget("Workspace index exceeds 128 MiB; save journal retained.")
    }
    // Validate every record before repairing any of them.
    for document in journal.documents {
      try Self.validateDocumentSize(document)
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
    let trace = PerformanceTrace.begin("Storage.Save")
    defer { PerformanceTrace.end("Storage.Save", trace) }
    try recoverSave()
    guard state.schema == 1, Set(documents.map(\.id)).count == documents.count,
      Set(state.documents.map(\.id)).count == state.documents.count,
      documents.allSatisfy({ document in state.documents.contains { $0.id == document.id } }) else {
      throw BoomError.invalid("Invalid save identities; existing records retained.")
    }
    try state.validateRetainedInput()
    for document in documents {
      try Self.validateDocumentSize(document)
      try checkDisk(document.id)
    }
    let journal = SaveJournal(schema: 1, state: state, documents: documents, before: diskRevisions)
    // The complete transaction must fit the same bounds used by reopening.
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let indexBytes = try encoder.encode(state), journalBytes = try encoder.encode(journal)
    guard indexBytes.count <= Vault.workspaceLimit, journalBytes.count <= Vault.workspaceLimit else {
      throw BoomError.budget("Workspace save exceeds 128 MiB. Existing records were retained.")
    }
    try vault.put(journalBytes, kind: .saveJournal, id: Vault.workspaceID)
    for document in documents { try saveDocument(document) }
    try vault.put(indexBytes, kind: .workspace, id: Vault.workspaceID)
    retainLegacyCatalog(matching: state.documents)
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
    let beforeCatalog = admittedLegacyDocuments
    diskRevisions.removeAll()
    admittedLegacyDocuments.removeAll()
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
      admittedLegacyDocuments = beforeCatalog
      discardStage = true
      throw error
    }
  }
}

extension WorkspaceStore {
  /// Separate bounded opening. A page and settings are actual values, never a
  /// synthesized empty WorkspaceState; the ordinary Model must port explicitly.
  func loadPagedMetadataOpening(engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher) async throws -> WorkspaceBoundedOpening {
    try admitMetadataOwners(engine, publisher: publisher)
    let settings = try await engine.loadWorkspaceSettingsRetaining(publisher)
    let settingsValue = settings.value
    try await finishMetadataRead(settings.lease, engine: engine)
    let documents = try await engine.loadDocumentIndexPageRetaining(publisher, expectedHead: settingsValue.head)
    let documentValue = documents.value
    try await finishMetadataRead(documents.lease, engine: engine)
    let chats = try await engine.loadWorkspaceEntityPageRetaining(publisher, kind: .chat,
      parentID: Vault.workspaceID, expectedHead: settingsValue.head)
    let chatValue = chats.value
    try await finishMetadataRead(chats.lease, engine: engine)
    var selected: WorkspaceDocumentDescriptor?
    if let id = settingsValue.settings.selectedDocument {
      let document = try await engine.loadWorkspaceDocumentRetaining(publisher, documentID: id, expectedHead: settingsValue.head)
      selected = .paged(document.value.record)
      try await finishMetadataRead(document.lease, engine: engine)
    }
    return WorkspaceBoundedOpening(head: settingsValue.head, settings: settingsValue.settings,
      documents: documentValue.records.map(WorkspaceDocumentDescriptor.paged), nextDocumentOrdinal: documentValue.nextOrdinal,
      chats: chatValue.entities, nextChatOrdinal: chatValue.nextOrdinal, selectedDocument: selected)
  }
  /// Hydrates ONE actual selected input owner under its existing2 MiB UI
  /// envelope. Header + at most one64 KiB Root window are held at a time.
  /// The resulting active draft is receiver-owned memory, not a Root window or
  /// all-owner metadata-memory qualification. Model must check its focus/input
  /// epoch before adopting this asynchronous result.
  func loadPagedComposerDraft(_ owner: ComposerOwner, engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher) async throws -> ComposerDraft? {
    try admitMetadataOwners(engine, publisher: publisher)
    let capture = try await engine.loadWorkspaceDraftRetaining(publisher, owner: owner)
    var headerReleaseAttempted = false
    do {
      guard let value = capture.value else { headerReleaseAttempted = true; try await finishMetadataRead(capture.lease, engine: engine); return nil }
      guard value.header.draftOwner == owner, let body = value.header.bodies["text"], body.encoding == .utf8,
        body.bytes <= 2_097_152 else { throw BoomError.denied("Selected draft differs from its actual bounded owner/body.") }
      var bytes = Data(); bytes.reserveCapacity(body.bytes)
      for part in 0..<body.partCount {
        let window = try await engine.loadWorkspaceEntityBodyPartRetaining(publisher,
          reference: value.reference, field: "text", part: part)
        bytes.append(window.value)
        do { try await engine.abandonJoinedRootOutput(window.lease) }
        catch { throw PagedTextCustodyFailure(original: error, lease: window.lease) }
      }
      let draft = try value.header.hydratedDraft(bytes: bytes)
      headerReleaseAttempted = true
      try await finishMetadataRead(capture.lease, engine: engine)
      return draft
    } catch {
      let original = error
      if headerReleaseAttempted { throw original }
      headerReleaseAttempted = true
      do { try await finishMetadataRead(capture.lease, engine: engine) }
      catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: capture.lease) }
      throw original
    }
  }
  func savePagedSettingsRetaining(_ settings: WorkspaceSettings,
    engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher,
    expectedHead: PagedWorkspaceHead) async throws -> PagedTextCustodiedValue<WorkspaceMetadataPublication> {
    try admitMetadataOwners(engine, publisher: publisher)
    let input = try WorkspaceMetadataInput(settings: settings)
    return try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: expectedHead)
  }
  func savePagedComposerDraftRetaining(_ draft: ComposerDraft,
    expected: WorkspaceEntityReference?, engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher, expectedHead: PagedWorkspaceHead) async throws -> PagedTextCustodiedValue<WorkspaceMetadataPublication> {
    try admitMetadataOwners(engine, publisher: publisher)
    let entity = try WorkspaceEntityInput.draft(draft, expected: expected)
    let input = try WorkspaceMetadataInput(entities: [entity])
    return try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: expectedHead)
  }
  /// Same immutable metadata input, SQL executor and final transaction. The
  /// selected native graph must actually close/detach before rename or trash.
  /// No legacy whole-state save, file trash, body decode or silent retry occurs.
  func savePagedDocumentChangesRetaining(_ changes: [WorkspaceDocumentMutation],
    settings: WorkspaceSettings? = nil, entities: [WorkspaceEntityInput] = [],
    removals: [WorkspaceEntityRemoval] = [], engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher, expectedHead: PagedWorkspaceHead)
    async throws -> PagedTextCustodiedValue<WorkspaceMetadataPublication> {
    try admitMetadataOwners(engine, publisher: publisher)
    let input = try WorkspaceMetadataInput(settings: settings, entities: entities,
      removals: removals, documentChanges: changes)
    return try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: expectedHead)
  }
  /// Normal owning-store receiving, then actual explicit output disposal.
  /// Caller retains the carrier on any refusal; no source/native ACK is made.
  func finishPagedMetadataPublication(_ output: PagedTextCustodiedValue<WorkspaceMetadataPublication>,
    engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher) async throws -> PagedWorkspaceHead {
    try admitMetadataOwners(engine, publisher: publisher)
    let head = try await engine.finishWorkspaceMetadataPublication(output, publisher: publisher)
    do { try await engine.abandonJoinedRootOutput(output.lease) }
    catch { throw PagedTextCustodyFailure(original: error, lease: output.lease) }
    return head
  }
  private func finishMetadataRead(_ lease: PagedTextRootLease, engine: PagedTextEngineAdapter) async throws {
    do { try await engine.abandonJoinedRootOutput(lease) }
    catch { throw PagedTextCustodyFailure(original: error, lease: lease) }
  }
  private func admitMetadataOwners(_ engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher) throws {
    guard engine.belongs(to: vault), publisher.belongs(to: vault) else { throw BoomError.denied("Metadata belongs to another actual WorkspaceStore Vault owner.") }
  }
}

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
/// One immutable caller-owned public source value, not a lease, durable ACK,
/// key owner or migration authority. The existing validator admitted the actual
/// legacy directory BEFORE the new SQL subdirectory exists.
struct PublicWorkspaceMetadataSource: Sendable {
  fileprivate let vault: Vault
  fileprivate let plaintextSHA256: String
  fileprivate let state: WorkspaceState
  fileprivate let legacyNames: Set<String>
}
extension WorkspaceStore {
  func publicFixtureMetadataSource(plaintextSHA256: String) throws -> PublicWorkspaceMetadataSource {
    guard !Thread.isMainThread, root.lastPathComponent.hasPrefix("bloom-metadata-public-"),
      UUID(uuidString: String(root.lastPathComponent.dropFirst("bloom-metadata-public-".count))) != nil,
      PagedWorkspaceObjectReference.isDigest(plaintextSHA256) else { throw BoomError.denied("Conversion is limited to the exact disposable public fixture namespace.") }
    let names = try publicFixtureLegacyNames()
    guard names.count <= 64 else { throw BoomError.budget("Public conversion source inventory exceeds64 fixed names.") }
    let original = try vault.get(.workspace, id: Vault.workspaceID, limit: 1_048_576)
    guard Digest.sha256(original) == plaintextSHA256 else { throw BoomError.denied("Authenticated public source differs from its exact captured SHA.") }
    let state = try PropertyListDecoder().decode(WorkspaceState.self, from: original)
    _ = try WorkspaceMetadataInput.admitPublicFixture(state)
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let roundTrip = try encoder.encode(state)
    guard roundTrip.count <= 1_048_576,
      let before = try PropertyListSerialization.propertyList(from: original, options: [], format: nil) as? NSDictionary,
      let after = try PropertyListSerialization.propertyList(from: roundTrip, options: [], format: nil) as? NSDictionary,
      before.isEqual(after) else {
      throw BoomError.invalid("Unknown/changed compatibility fields cannot be dropped during conversion; original retained.")
    }
    // Never filter/relax the shipped inventory validator to accept a SQL dir.
    try vault.validateInventory(state, hasIndex: true)
    try ProductCore.validateOriginals(state)
    for (id, file) in state.importedFiles ?? [:] {
      guard vault.exists(.attachment, id),
        try Digest.sha256(vault.get(.attachment, id: id, limit: 2_097_152)) == file.originalDigest else {
        throw BoomError.invalid("Public imported original is missing or changed; original encrypted fixture retained.")
      }
    }
    return PublicWorkspaceMetadataSource(vault: vault, plaintextSHA256: plaintextSHA256,
      state: state, legacyNames: names)
  }
  func publicFixtureMetadataInput(_ source: PublicWorkspaceMetadataSource,
    engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher,
    documents: [PagedDocumentRootRecord]) async throws -> WorkspaceMetadataInput {
    try admitMetadataOwners(engine, publisher: publisher)
    guard source.vault === vault, try publicFixtureLegacyNames() == source.legacyNames.union(["paged-sqlite-v3"]),
      try Digest.sha256(vault.get(.workspace, id: Vault.workspaceID, limit: 1_048_576)) == source.plaintextSHA256 else {
      throw BoomError.stale("The same public conversion source/namespace changed after authenticated preparation.")
    }
    let input = try WorkspaceMetadataInput.publicFixture(source.state, documents: documents)
    // Compare each actual imported tree against the authenticated shipped
    // document, one legacy <=2 MiB value and one <=64 KiB window at a time.
    // A matching id/title projection or caller-supplied digest cannot prove
    // that the text itself was converted without loss.
    guard documents.count <= WorkspaceMetadataInput.maximumEntities else { throw BoomError.budget("Public document conversion exceeds its small complete fixture envelope.") }
    for record in documents {
      let originalDocument = try readLegacyDocumentBytes(record.document.id)
      guard record.document.revision.summary.bytes == UInt64(originalDocument.count) else { throw BoomError.denied("Public converted source extent differs from the original authenticated document.") }
      var offset = 0
      while offset < originalDocument.count {
        let captured = try await engine.windowRetaining(record.document.revision,
          byteStart: UInt64(offset), maximumBytes: 65_536)
        let count = captured.value.text.utf8.count
        let matches = captured.value.byteStart == UInt64(offset) && count > 0
          && count <= originalDocument.count - offset
          && captured.value.text.utf8.elementsEqual(originalDocument[offset..<(offset + count)])
        // Always join disposal of the actual returned read before refusing a
        // comparison; do not strand a producer merely because bytes differ.
        do { try await engine.abandonJoinedRootOutput(captured.lease) }
        catch { throw PagedTextCustodyFailure(original: error, lease: captured.lease) }
        guard matches else { throw BoomError.denied("Public converted source differs from the original authenticated UTF8 bytes.") }
        offset += count
      }
      guard Digest.sha256(try readLegacyDocumentBytes(record.document.id)) == Digest.sha256(originalDocument) else { throw BoomError.stale("Original public source changed while its actual imported windows joined.") }
    }
    guard try publicFixtureLegacyNames() == source.legacyNames.union(["paged-sqlite-v3"]),
      try Digest.sha256(vault.get(.workspace, id: Vault.workspaceID, limit: 1_048_576)) == source.plaintextSHA256 else {
      throw BoomError.stale("Public conversion source changed while its actual tree reads joined.")
    }
    return input
  }
  private func publicFixtureLegacyNames() throws -> Set<String> {
    let names = Set(try FileManager.default.contentsOfDirectory(at: vault.root,
      includingPropertiesForKeys: nil).map(\.lastPathComponent))
    for name in names {
      guard !["editJournal-", "saveJournal-", "generationJournal-"].contains(where: { name.hasPrefix($0) }) else {
        throw BoomError.unavailable("Public conversion requires the original journal owner to join first.")
      }
    }
    return names
  }
}
#endif
