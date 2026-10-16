import AppKit
import BoomCore
import Darwin
import Foundation

/// The archive is the existing complete encrypted workspace, not a second data
/// schema. A copied staging directory is authenticated before it is published.
enum BlessengerArchive {
  static func validate(_ directory: URL, using vault: Vault, flag: CancellationFlag) throws {
    try flag.check()
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw BoomError.invalid("The backup is not a real directory.")
    }
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    guard names.isSubset(of: [".workspace-lock", "Objects", "identity.json", "workspace.json"]),
      names.isSuperset(of: ["Objects", "identity.json", "workspace.json"]) else {
      throw BoomError.invalid("The backup contains unknown or missing workspace files. Nothing was restored.")
    }
    let objects = directory.appendingPathComponent("Objects", isDirectory: true)
    guard lstat(objects.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw BoomError.invalid("The backup object directory is unsafe.")
    }
    let state = try JSONDecoder().decode(WorkspaceState.self,
      from: vault.readProtectedArchiveRecord(directory, kind: .workspace, id: Vault.workspaceID, limit: Vault.workspaceLimit))
    let identity = try JSONDecoder().decode(WorkspaceStorageIdentity.self,
      from: vault.readProtectedArchiveRecord(directory, kind: .workspaceIdentity, id: Vault.workspaceID, limit: 512))
    try identity.admit()
    guard state.schema == 1, state.documents.isEmpty, state.archivedDocuments?.isEmpty ?? true,
      state.candidateIDs.isEmpty, Set(state.chats.map(\.id)).count == state.chats.count,
      Set(state.attachments.map(\.id)).count == state.attachments.count,
      Set(state.voices.map(\.id)).count == state.voices.count,
      Set(state.voices.map(\.slug)).count == state.voices.count, let product = state.blessenger else {
      throw BoomError.invalid("This is not a consistent current-format Blessenger backup.")
    }
    try state.validateRetainedInput(); try product.validate(in: state)
    for voice in state.voices + state.voiceVersions {
      try flag.check()
      guard try ProductCore.voice(voice.draft).revision == voice.revision else {
        throw BoomError.invalid("A captured Contact revision in the backup is inconsistent.")
      }
    }
    for chat in state.chats {
      guard Set(chat.messages.map(\.id)).count == chat.messages.count else {
        throw BoomError.invalid("A backed-up conversation has duplicate message identities.")
      }
    }
    let kinds: [Vault.Kind] = [.attachment, .receipt, .candidate, .editJournal, .generationJournal]
    var retained = Set<UUID>(), receipts = Set<UUID>()
    // One bounded plaintext record at a time; orphans are authenticated and
    // copied too. A backup never deletes evidence to manufacture consistency.
    for name in try FileManager.default.contentsOfDirectory(atPath: objects.path) {
      try flag.check()
      try autoreleasepool {
        guard let kind = kinds.first(where: { name.hasPrefix($0.rawValue + "-") }), name.hasSuffix(".record"),
          let id = UUID(uuidString: String(name.dropFirst(kind.rawValue.count + 1).dropLast(7))),
          name == kind.rawValue + "-" + id.uuidString + ".record" else {
          throw BoomError.invalid("The backup contains an unknown private record.")
        }
        let bytes = try vault.readProtectedArchiveRecord(directory, kind: kind, id: id, limit: 67_108_864)
        if kind == .receipt { receipts.insert(id) }
        if kind == .attachment {
          retained.insert(id)
          if let record = state.attachments.first(where: { $0.id == id }) {
            guard Digest.sha256(bytes) == record.rootDigest else { throw BoomError.invalid("A backed-up original failed its digest check.") }
          }
        }
      }
    }
    guard state.attachments.allSatisfy({ retained.contains($0.id) && receipts.contains($0.id) }) else {
      throw BoomError.invalid("The backup is missing an indexed original. Nothing was restored.")
    }
    var inspected = Set<UUID>()
    for message in state.chats.flatMap({ $0.messages + ($0.messageVersions ?? []) })
      where message.role == .assistant && message.provider != nil && message.authoredByUser != true {
      guard inspected.insert(message.id).inserted else { continue }
      try flag.check()
      let bytes = try vault.readProtectedArchiveRecord(directory, kind: .receipt, id: message.id, limit: 16_777_216)
      let receipt = try PropertyListDecoder().decode(ConsultationReceipt.self, from: bytes)
      guard receipt.responseID == message.id, receipt.model == message.provider, let attemptID = receipt.attemptID,
        receipt.voice.map({ $0.speaker == message.speaker }) ?? (message.speaker?.voiceID == nil) else {
        throw BoomError.invalid("A retained reply lost its captured model, Contact, or attempt provenance.")
      }
      let attemptBytes = try vault.readProtectedArchiveRecord(directory, kind: .receipt, id: attemptID, limit: 16_777_216)
      let original = try PropertyListDecoder().decode(ConsultationReceipt.self, from: attemptBytes)
      // A backup may intersect checkpoint/final publication. The two records
      // can have different progress, but never different captured authority.
      guard original.attemptID == attemptID, original.responseID == message.id,
        original.operationID == receipt.operationID, original.seed == receipt.seed,
        original.model == receipt.model, original.voice == receipt.voice,
        try BlessengerPolicy.exactDigest(original.plan) == BlessengerPolicy.exactDigest(receipt.plan),
        original.generationPolicy == receipt.generationPolicy else {
        throw BoomError.invalid("The retained response and attempt disagree about captured authority.")
      }
      if let attempt = product.attempts[message.id] {
        guard receipt.attemptID == attempt.identity.attemptID, receipt.operationID == attempt.identity.operationID,
          receipt.model == attempt.identity.model, receipt.seed == attempt.identity.seed,
          Digest.sha256(receipt.plan.rawPrompt) == attempt.identity.requestDigest else {
          throw BoomError.invalid("The backup lost an in-flight response's provenance.")
        }
      }
      if let audio = product.audio[message.id] {
        guard audio.textDigest == Digest.sha256(message.text), audio.attemptID == attemptID,
          product.spokenResponses?[message.id] == audio.voice else {
          throw BoomError.invalid("Recorded speech does not belong to its retained response.")
        }
        let pcm = try BlessengerWave.decode(vault.readProtectedArchiveRecord(directory, kind: .attachment,
          id: audio.attachmentID, limit: 67_108_864))
        guard pcm.samples.count == audio.frames, pcm.rate == audio.sampleRate else {
          throw BoomError.invalid("The retained audio and its replay geometry disagree.")
        }
      }
    }
  }
}

extension WorkspaceStore {
  func exportBlessengerBackup(to destination: URL, flag: CancellationFlag) async throws {
    guard let state = blessengerRuntime, state.blessenger != nil, vault.isProtected else {
      throw BoomError.denied("Only an open private Blessenger workspace can be backed up.")
    }
    try state.blessenger!.validate(in: state)
    _ = try storageIdentity()
    let vault = vault
    // Category writes are atomic and share the vault lock. The snapshot therefore
    // contains one committed index plus all its records, even during generation.
    let capture = try await detachedWork { try vault.captureBackupSource(cancellation: flag) }
    try await detachedWork {
      try WorkspaceBackup.export(capture, to: destination, cancellation: flag) { stage in
        try BlessengerArchive.validate(stage, using: vault, flag: flag)
      }
    }
  }
  func restoreBlessengerBackup(from source: URL, to destination: URL, flag: CancellationFlag) async throws {
    guard vault.isProtected else { throw BoomError.denied("The private backup key is not available.") }
    let vault = vault
    try await detachedWork {
      try flag.check()
      try WorkspaceBackup.restore(from: source, into: destination) { stage in
        try flag.check(); try BlessengerArchive.validate(stage, using: vault, flag: flag)
      }
    }
  }
}

extension BlessengerModel {
  func backupWorkspace(restoring: Bool) {
    guard !navigating, !loading, !preparing, active.isEmpty, !isCalling, !callStarting, noteState == .idle else { return }
    let source: URL?
    if restoring {
      let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
      panel.message = "Choose the encrypted Blessenger backup. Its original Keychain key must still be available."
      guard panel.runModal() == .OK, let chosen = panel.url else { return }; source = chosen
    } else { source = nil }
    let panel = NSSavePanel(); panel.canCreateDirectories = true
    panel.nameFieldStringValue = restoring ? "Blessenger-restored" : "Blessenger-backup"
    panel.message = restoring
      ? "Restore into a new folder. Neither the current workspace nor the backup will be overwritten."
      : "Includes all private conversations, drafts, Contacts, audio, originals and receipts. The Keychain key is not exported; keep the original key."
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    launch {
      try await self.flushDraft()
      let flag = CancellationFlag()
      let sourceScope = source?.startAccessingSecurityScopedResource() ?? false
      let targetScope = destination.startAccessingSecurityScopedResource()
      defer {
        if sourceScope { source?.stopAccessingSecurityScopedResource() }
        if targetScope { destination.stopAccessingSecurityScopedResource() }
      }
      try await withTaskCancellationHandler {
        if let source { try await self.store.restoreBlessengerBackup(from: source, to: destination, flag: flag) }
        else { try await self.store.exportBlessengerBackup(to: destination, flag: flag) }
      } onCancel: { flag.cancel() }
      NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
  }
}
