import Darwin
import Foundation
import BoomCore

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
  var originalRevision: PagedTextRevision? = nil
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
  var archivedDocuments: [DocumentIndex]? = nil
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
    let retainedDocuments = documents.union((archivedDocuments ?? []).map(\.id))
    let attachments = Set(attachments.map(\.id))
    let examples = writingExampleIDs ?? []
    guard examples.count <= 32, Set(examples).count == examples.count,
      examples.allSatisfy(documents.contains) else {
      throw BoomError.invalid("Writing example selection is inconsistent; files retained.")
    }
    var owners = Set<ComposerOwner>()
    for draft in composerDrafts ?? [] {
      guard owners.insert(draft.owner).inserted,
        (draft.owner.kind == .chat ? chats : retainedDocuments).contains(draft.owner.id),
        draft.attachments.count <= 8, Set(draft.attachments).count == draft.attachments.count,
        draft.attachments.allSatisfy(attachments.contains) else {
        throw BoomError.invalid("Unsent message ownership is inconsistent; files retained.")
      }
      guard draft.text.utf8.count <= 2_097_152 else {
        throw BoomError.budget("Unsent text exceeds 2 MiB. Shorten it or copy it to a document before closing.")
      }
    }
  }
}

private struct WorkspaceRecordCleanupFailure: LocalizedError {
  let original: Error
  let cleanup: Error
  let path: URL
  var errorDescription: String? {
    "\(original.localizedDescription) Record cleanup at \(path.path): \(cleanup.localizedDescription)"
  }
}

/// Ordinary owner-only category files. Structured decode failure never becomes
/// an empty workspace. Large document pages belong to the bounded source engine.
final class Vault: @unchecked Sendable {
  enum Kind: String, Sendable { case workspace, attachment, receipt, candidate, editJournal, generationJournal, workspaceIdentity }
  static let workspaceLimit = 134_217_728
  static let workspaceID = UUID(uuidString: "726B3A82-2EB1-493B-9D8E-F17C7A6E4B8A")!
  let root: URL
  private let lock = NSLock()
  /// Called only inside the existing Engine writer job. All category and
  /// workspace JSON writers use this same lock; no await occurs while held.
  func captureBackupSource(cancellation: CancellationFlag, temporaryParent: URL? = nil) throws -> WorkspaceBackup.CapturedDirectory {
    precondition(!Thread.isMainThread)
    lock.lock(); defer { lock.unlock() }
    return try WorkspaceBackup.captureForExport(root: root.deletingLastPathComponent(), cancellation: cancellation, temporaryParent: temporaryParent)
  }
  init(root: URL) throws {
    guard root.isFileURL else { throw BoomError.invalid("Workspace storage must be a local directory.") }
    let selected = root.standardizedFileURL
    var existing = stat()
    if lstat(selected.path, &existing) == 0 {
      guard existing.st_mode & S_IFMT == S_IFDIR else {
        throw BoomError.invalid("Workspace storage is not a real directory.")
      }
    } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    self.root = selected.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let values = try self.root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw BoomError.invalid("Workspace storage is not a real directory.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
  }
  func recordURL(_ kind: Kind, _ id: UUID) -> URL {
    switch kind {
    case .workspace: root.deletingLastPathComponent().appendingPathComponent("workspace.json")
    case .workspaceIdentity: root.deletingLastPathComponent().appendingPathComponent("identity.json")
    default: root.appendingPathComponent(kind.rawValue + "-" + id.uuidString + ".record")
    }
  }
  private func admit(_ kind: Kind, _ id: UUID) throws {
    guard ![Kind.workspace, .workspaceIdentity].contains(kind) || id == Self.workspaceID else {
      throw BoomError.invalid("Workspace metadata must use its single fixed identity.")
    }
  }
  func exists(_ kind: Kind, _ id: UUID) -> Bool {
    guard ![Kind.workspace, .workspaceIdentity].contains(kind) || id == Self.workspaceID else { return false }
    var info = stat()
    return lstat(recordURL(kind, id).path, &info) == 0
  }
  func put(_ data: Data, kind: Kind, id: UUID) throws {
    try admit(kind, id)
    let trace = PerformanceTrace.begin("Storage.Put")
    defer { PerformanceTrace.end("Storage.Put", trace) }
    guard data.count <= (kind == .workspace ? Self.workspaceLimit : 1_100_000_000) else {
      throw BoomError.budget("Workspace record exceeds its bound.")
    }
    let lockTrace = PerformanceTrace.begin("Storage.LockWait")
    lock.lock(); PerformanceTrace.end("Storage.LockWait", lockTrace)
    defer { lock.unlock() }
    let target = recordURL(kind, id)
    var existing = stat()
    if lstat(target.path, &existing) == 0 {
      guard existing.st_mode & S_IFMT == S_IFREG else {
        throw BoomError.invalid("Refusing a nonregular workspace record.")
      }
    } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let stage = target.deletingLastPathComponent().appendingPathComponent(".record-" + UUID().uuidString)
    let descriptor = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var closeAttempted = false, published = false
    let writeTrace = PerformanceTrace.begin("Storage.AtomicWrite")
    defer { PerformanceTrace.end("Storage.AtomicWrite", writeTrace) }
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      closeAttempted = true
      try handle.close()
      guard Darwin.rename(stage.path, target.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      published = true
      let parent = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      let synchronized = fsync(parent), syncError = errno
      let closed = Darwin.close(parent), closeError = errno
      guard synchronized == 0, closed == 0 else {
        throw BoomError.unavailable("Workspace publication failed: sync \(synchronized)/\(syncError), close \(closed)/\(closeError).")
      }
    } catch {
      var failure = error
      if !closeAttempted {
        do { closeAttempted = true; try handle.close() }
        catch { failure = WorkspaceRecordCleanupFailure(original: failure, cleanup: error, path: stage) }
      }
      // Only this unpublished, exclusively created temporary record is disposable.
      // A post-rename sync failure keeps the actual published target untouched.
      if !published {
        do { try FileManager.default.removeItem(at: stage) }
        catch { failure = WorkspaceRecordCleanupFailure(original: failure, cleanup: error, path: stage) }
      }
      throw failure
    }
  }
  func get(_ kind: Kind, id: UUID, limit: Int = 16_777_216) throws -> Data {
    try admit(kind, id)
    guard limit >= 0 else { throw BoomError.invalid("Invalid workspace read bound.") }
    lock.lock(); defer { lock.unlock() }
    return try RegularFile(recordURL(kind, id), limit: Int64(limit)).data()
  }
  func encode<T: Encodable>(_ value: T, kind: Kind, id: UUID) throws {
    let trace = PerformanceTrace.begin("Storage.Encode")
    defer { PerformanceTrace.end("Storage.Encode", trace) }
    let data: Data
    if [Kind.workspace, .workspaceIdentity].contains(kind) {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(value)
    } else {
      let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
      data = try encoder.encode(value)
    }
    try put(data, kind: kind, id: id)
  }
  func decode<T: Decodable>(_ type: T.Type, kind: Kind, id: UUID, limit: Int = 16_777_216) throws -> T {
    let data = try get(kind, id: id, limit: limit)
    if [Kind.workspace, .workspaceIdentity].contains(kind) { return try JSONDecoder().decode(type, from: data) }
    return try PropertyListDecoder().decode(type, from: data)
  }
  func remove(_ kind: Kind, id: UUID) throws {
    try admit(kind, id)
    lock.lock(); defer { lock.unlock() }
    let target = recordURL(kind, id)
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
  }
}

actor WorkspaceStore {
  nonisolated let root: URL
  nonisolated let vault: Vault
  private var workspaceLock: Int32?
  init(rootOverride: URL? = nil) throws {
    #if BOOM_UI_TEST
    let path = ProcessInfo.processInfo.environment["BOOM_UI_TEST_ROOT"] ?? "/tmp/boom-ui-test-root"
    guard path.hasPrefix("/") else { throw BoomError.invalid("UI test root must be absolute.") }
    let selected = URL(fileURLWithPath: path)
    #else
    let selected = try rootOverride ?? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Bloom", isDirectory: true)
    #endif
    let normalized = selected.standardizedFileURL
    var existing = stat()
    if lstat(normalized.path, &existing) == 0 {
      guard existing.st_mode & S_IFMT == S_IFDIR else { throw BoomError.invalid("Workspace root is not a real directory.") }
    } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    root = normalized.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    vault = try Vault(root: root.appendingPathComponent("Objects", isDirectory: true))
  }
  deinit { if let descriptor = workspaceLock { _ = Darwin.close(descriptor) } }
  func acquireExclusiveWorkspace() throws {
    guard workspaceLock == nil else { return }
    let path = root.appendingPathComponent(".workspace-lock")
    let descriptor = Darwin.open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let failure = errno; _ = Darwin.close(descriptor)
      throw BoomError.unavailable("The workspace is already open or its lock is unavailable (\(failure)).")
    }
    workspaceLock = descriptor
  }
  /// The caller releases only after its actual source engine has closed.
  func releaseExclusiveWorkspace() throws {
    guard let descriptor = workspaceLock else { return }
    workspaceLock = nil // A failed close is not retried against a possibly recycled descriptor.
    let unlocked = flock(descriptor, LOCK_UN), unlockError = errno
    let closed = Darwin.close(descriptor), closeError = errno
    guard unlocked == 0, closed == 0 else {
      throw BoomError.unavailable("Workspace lock close failed: unlock \(unlocked)/\(unlockError), close \(closed)/\(closeError).")
    }
  }
  func storageIdentity() throws -> (ownerID: UUID, storeID: UUID) {
    let value = try WorkspaceStorageIdentity.loadOrCreate(at: root.appendingPathComponent("identity.json"))
    return (value.ownerID, value.storeID)
  }
  func loadState() throws -> WorkspaceState {
    var existing = stat()
    if lstat(vault.recordURL(.workspace, Vault.workspaceID).path, &existing) != 0 {
      if errno == ENOENT { return WorkspaceState() }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var state = try vault.decode(WorkspaceState.self, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit)
    try validateState(state)
    try recoverGenerations(&state)
    return state
  }
  func saveState(_ state: WorkspaceState) throws {
    try validateState(state)
    try vault.encode(state, kind: .workspace, id: Vault.workspaceID)
  }
  private func validateState(_ state: WorkspaceState) throws {
    guard state.schema == 1,
      Set((state.documents + (state.archivedDocuments ?? [])).map(\.id)).count
        == state.documents.count + (state.archivedDocuments ?? []).count,
      Set(state.chats.map(\.id)).count == state.chats.count,
      Set(state.voices.map(\.id)).count == state.voices.count,
      Set(state.voices.map(\.slug)).count == state.voices.count else {
      throw BoomError.invalid("Workspace metadata contains inconsistent identities; files retained.")
    }
    try state.validateRetainedInput()
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
    if changed || !bundles.isEmpty || !receipts.isEmpty { try saveState(state) }
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
  func attachment(_ id: UUID) throws -> Data {
    try vault.get(.attachment, id: id, limit: 67_108_864)
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

}

extension WorkspaceStore {
  /// Model joins and quiesces source/metadata writers before entering this copy.
  func exportBackup(to url: URL) throws { try WorkspaceBackup.export(root: root, to: url) }
  /// Restore runs only on a closed, fresh target; normal startup reopens it afterward.
  func restoreBackup(from url: URL) throws {
    guard workspaceLock == nil else { throw BoomError.denied("Close the workspace before restoring its files.") }
    try WorkspaceBackup.restore(from: url, into: root)
  }
}
