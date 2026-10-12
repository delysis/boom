import BoomCore
import CryptoKit
import Foundation

enum WorkspaceEntityKind: Int, Codable, Sendable {
  case chat = 1, message, messageVersion, voice, voiceVersion, draft, attachment
  case proposal, manuscriptOrigin, importedFolder, importedFile, candidate, recordingDraft, documentArchive
}

/// Existing domain fields, excluding explicitly externalized text. These are
/// storage metadata, never incomplete domain values returned to a model/UI.
private enum WorkspaceEntityMetadata: Codable, Sendable {
  case chat(ChatRecord), message(ChatMessage), voice(Voice), draft(ComposerDraft)
  case attachment(AttachmentRecord), proposal(WorkspaceProposalMetadata)
  case origin(ManuscriptOrigin), folder(ImportedFolder), file(ImportedFile)
  case candidate(UUID), recordingDraft([UUID]), documentArchive(WorkspaceDocumentArchiveMetadata)
}
private struct WorkspaceDocumentArchiveMetadata: Codable, Sendable {
  let original: WorkspaceImportedOriginal?
  let trashed: Bool
}
private struct WorkspaceProposalMetadata: Codable, Sendable {
  let id: UUID, chatID: UUID, messageID: UUID
  let document: DocumentIndex
  let capturedRevision: String
  let documents: [SourceReference], attachments: [SourceReference]
  let status: String
  let appliedRevision: String?
}

struct WorkspaceEntityBodyReference: Codable, Equatable, Sendable {
  enum Encoding: String, Codable, Sendable { case utf8, json }
  let objectID: UUID
  let encoding: Encoding
  let bytes: Int
  let digest: String
  var partCount: Int { max(1, bytes / 65_536 + (bytes % 65_536 == 0 ? 0 : 1)) }
  func validate() throws {
    guard objectID != WorkspaceEntityHeader.zero, bytes >= 0, bytes <= WorkspaceMetadataInput.maximumInputBytes,
      partCount <= 64, PagedWorkspaceObjectReference.isDigest(digest) else {
      throw BoomError.invalid("Invalid bounded metadata body reference.")
    }
  }
}

struct WorkspaceEntityHeader: Codable, Equatable, Sendable {
  static let maximumBytes = 16_384
  static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  let schema: UInt8
  let id: UUID // stable storage slot; logicalID preserves the original domain ID
  let kind: WorkspaceEntityKind
  let logicalID: UUID
  let parentID: UUID
  let ordinal: Int
  fileprivate let metadata: Data
  let bodies: [String: WorkspaceEntityBodyReference]
  let counts: [String: Int]

  func validate() throws {
    guard schema == 1, [id, logicalID, parentID].allSatisfy({ $0 != Self.zero }), ordinal >= 0,
      ordinal < Int(Int32.max), metadata.count <= 8_192, bodies.count <= 4,
      counts.count <= 2, counts.values.allSatisfy({ $0 >= 0 && $0 < Int(Int32.max) }) else {
      throw BoomError.budget("Metadata header identity or scalar envelope changed.")
    }
    for (field, body) in bodies {
      try body.validate()
      guard body.encoding == (["examples", "patch", "record"].contains(field) ? .json : .utf8) else { throw invalid() }
    }
    let value = try JSONDecoder().decode(WorkspaceEntityMetadata.self, from: metadata)
    let names = Set(bodies.keys)
    switch (kind, value) {
    case (.chat, .chat(let value)):
      guard value.id == logicalID, value.messages.isEmpty, value.instructions == nil,
        value.messageVersions == nil, counts.keys.allSatisfy({ ["messages", "versions"].contains($0) }),
        counts["messages"] != nil, names.isSubset(of: ["instructions"]) else { throw invalid() }
    case (.message, .message(let value)), (.messageVersion, .message(let value)):
      guard value.id == logicalID, value.text.isEmpty, value.context.isEmpty, value.failure == nil,
        counts.isEmpty, names == ["text", "context"] || names == ["text", "context", "failure"] else { throw invalid() }
    case (.voice, .voice(let value)), (.voiceVersion, .voice(let value)):
      guard value.id == logicalID, value.instructions.isEmpty, value.examples.isEmpty,
        counts.isEmpty, names == ["instructions", "examples"] else { throw invalid() }
    case (.draft, .draft(let value)):
      guard value.owner.id == logicalID, value.owner.id == parentID, value.text.isEmpty,
        value.attachments.count <= 8, Set(value.attachments).count == value.attachments.count,
        counts.isEmpty, names == ["text"] else { throw invalid() }
    case (.attachment, .attachment(let value)):
      guard value.id == logicalID, value.text.isEmpty, value.coverage.isEmpty, value.transform == nil,
        counts.isEmpty, names == ["text", "coverage"] || names == ["text", "coverage", "transform"] else { throw invalid() }
    case (.proposal, .proposal(let value)):
      guard value.id == logicalID, value.chatID == parentID, counts.isEmpty,
        names == ["documentText", "patch"] else { throw invalid() }
    case (.manuscriptOrigin, .origin(let value)):
      guard value.documentID == parentID, counts.isEmpty, names.isEmpty else { throw invalid() }
    case (.importedFolder, .folder(let value)):
      guard value.id == logicalID, counts.isEmpty, names.isEmpty else { throw invalid() }
    case (.importedFile, .file):
      guard logicalID == parentID, counts.isEmpty, names.isEmpty else { throw invalid() }
    case (.candidate, .candidate(let value)):
      guard value == logicalID, counts.isEmpty, names.isEmpty else { throw invalid() }
    case (.recordingDraft, .recordingDraft(let value)):
      guard logicalID == parentID, value.count <= 8, Set(value).count == value.count,
        counts.isEmpty, names.isEmpty else { throw invalid() }
    case (.documentArchive, .documentArchive(let value)):
      guard logicalID == parentID, ordinal == 0, counts.isEmpty,
        names == (value.trashed ? Set(["record"]) : Set<String>()), value.original != nil || value.trashed else { throw invalid() }
      try value.original?.validate(documentID: logicalID)
      if let record = bodies["record"], record.bytes > 8_192 || record.partCount != 1 { throw invalid() }
    default: throw invalid()
    }
    guard try JSONEncoder().encode(self).count <= Self.maximumBytes else {
      throw BoomError.budget("Authenticated metadata header exceeds16 KiB.")
    }
  }
  private func invalid() -> BoomError { .invalid("Metadata kind, domain identity or externalized field set changed.") }

  func validateLinks(documentExists: (UUID) throws -> Bool,
    entityExists: (WorkspaceEntityKind, UUID) throws -> Bool,
    entityCount: (WorkspaceEntityKind, UUID) throws -> Int) throws {
    try validate()
    let value = try JSONDecoder().decode(WorkspaceEntityMetadata.self, from: metadata)
    switch value {
    case .chat(let chat):
      if let id = chat.attachedDocumentID, try !documentExists(id) { throw invalid() }
      guard try entityCount(.message, chat.id) == counts["messages"],
        try entityCount(.messageVersion, chat.id) == (counts["versions"] ?? 0) else { throw invalid() }
    case .message(let message):
      guard try entityExists(.chat, parentID) else { throw invalid() }
      for id in message.directAttachments ?? [] { guard try entityExists(.attachment, id) else { throw invalid() } }
    case .draft(let draft):
      guard try (draft.owner.kind == .document ? documentExists(draft.owner.id) : entityExists(.chat, draft.owner.id)) else { throw invalid() }
      for id in draft.attachments { guard try entityExists(.attachment, id) else { throw invalid() } }
    case .proposal(let proposal):
      guard try entityExists(.chat, proposal.chatID),
        proposal.messageID != Self.zero, PagedWorkspaceObjectReference.isDigest(proposal.capturedRevision) else { throw invalid() }
    case .origin: guard try documentExists(logicalID) else { throw invalid() }
    case .file(let file):
      guard try documentExists(logicalID) else { throw invalid() }
      if let id = file.folderID, try !entityExists(.importedFolder, id) { throw invalid() }
    case .recordingDraft(let ids):
      guard try entityExists(.chat, logicalID) else { throw invalid() }
      for id in ids { guard try entityExists(.attachment, id) else { throw invalid() } }
    case .documentArchive(let value):
      try value.original?.validate(documentID: logicalID)
      if let folder = value.original?.folderID, try !entityExists(.importedFolder, folder) { throw invalid() }
    case .voice, .attachment, .folder, .candidate: break
    }
    // Historical SourceReferences, original digests, generation/proposal IDs
    // remain verbatim evidence. Header admission is not a model/GC/media grant;
    // their existing actual owning consumers still validate those authorities.
  }
  func archivedDocument(recordBytes: Data?) throws -> WorkspaceDocumentArchive {
    try validate()
    guard kind == .documentArchive,
      case .documentArchive(let value) = try JSONDecoder().decode(WorkspaceEntityMetadata.self, from: metadata) else { throw invalid() }
    let record: PagedDocumentRootRecord?
    if value.trashed {
      guard let reference = bodies["record"], let recordBytes,
        recordBytes.count == reference.bytes, Digest.sha256(recordBytes) == reference.digest else { throw invalid() }
      record = try JSONDecoder().decode(PagedDocumentRootRecord.self, from: recordBytes)
    } else { guard recordBytes == nil else { throw invalid() }; record = nil }
    let archive = WorkspaceDocumentArchive(original: value.original, retainedRecord: record)
    try archive.validate(documentID: logicalID); return archive
  }
  var chatIndex: DocumentIndex? {
    guard kind == .chat, let value = try? JSONDecoder().decode(WorkspaceEntityMetadata.self, from: metadata),
      case .chat(let chat) = value else { return nil }
    return DocumentIndex(id: chat.id, title: chat.title)
  }
  var draftOwner: ComposerOwner? {
    guard kind == .draft, let value = try? JSONDecoder().decode(WorkspaceEntityMetadata.self, from: metadata),
      case .draft(let draft) = value else { return nil }
    return draft.owner
  }
  func hydratedDraft(bytes: Data) throws -> ComposerDraft {
    try validate()
    guard kind == .draft, case .draft(let value) = try JSONDecoder().decode(WorkspaceEntityMetadata.self, from: metadata),
      let body = bodies["text"], body.encoding == .utf8, body.bytes <= 2_097_152,
      bytes.count == body.bytes, Digest.sha256(bytes) == body.digest,
      let text = String(data: bytes, encoding: .utf8), text.utf8.elementsEqual(bytes) else {
      throw BoomError.denied("Draft hydration differs from the actual owner-bound UTF8 body.")
    }
    return ComposerDraft(owner: value.owner, text: text, attachments: value.attachments, authoredRole: value.authoredRole)
  }
}

struct WorkspaceEntityReference: Codable, Equatable, Sendable {
  let id: UUID, objectID: UUID, logicalID: UUID, parentID: UUID
  let kind: WorkspaceEntityKind
  let ordinal: Int
  func validate() throws {
    guard [id, objectID, logicalID, parentID].allSatisfy({ $0 != WorkspaceEntityHeader.zero }),
      ordinal >= 0, ordinal < Int(Int32.max) else { throw BoomError.invalid("Entity pointer identity/order changed.") }
  }
}
struct WorkspaceEntityRead: Sendable {
  let head: PagedWorkspaceHead
  let reference: WorkspaceEntityReference
  let header: WorkspaceEntityHeader
}
struct WorkspaceEntityPage: Sendable {
  let head: PagedWorkspaceHead
  let entities: [WorkspaceEntityRead]
  let nextOrdinal: Int?
}
struct WorkspaceSettingsRead: Sendable {
  let head: PagedWorkspaceHead
  let settings: WorkspaceSettings
}
struct WorkspaceEntityRemoval: Sendable {
  let expected: WorkspaceEntityReference
}

/// The caller owns its immutable application value before writer admission.
/// Factories encode only bounded metadata on a utility worker. Body text is
/// kept verbatim and streamed; it is never included in a whole workspace encode.
struct WorkspaceEntityInput: Sendable {
  enum Body: Sendable { case text(String), json(Data)
    var bytes: Int { switch self { case .text(let value): value.utf8.count; case .json(let value): value.count } }
    var encoding: WorkspaceEntityBodyReference.Encoding { switch self { case .text: .utf8; case .json: .json } }
  }
  let id: UUID, kind: WorkspaceEntityKind, logicalID: UUID, parentID: UUID, ordinal: Int
  fileprivate let metadata: Data
  let bodies: [String: Body]
  let counts: [String: Int]
  let expected: WorkspaceEntityReference?
  let retainedBytes: Int
  private init(kind: WorkspaceEntityKind, logicalID: UUID, parentID: UUID, ordinal: Int,
    metadata: WorkspaceEntityMetadata, bodies: [String: Body] = [:], counts: [String: Int] = [:],
    expected: WorkspaceEntityReference? = nil) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Metadata input encoding belongs off Main.") }
    try Self.admitMetadataBeforeEncoding(metadata)
    let encoded = try JSONEncoder().encode(metadata)
    guard encoded.count <= 8_192, bodies.count <= 4 else { throw BoomError.budget("Entity metadata exceeds its header bound; original value retained.") }
    var charge = encoded.count + 2_048
    for body in bodies.values {
      guard body.bytes <= WorkspaceMetadataInput.maximumInputBytes - charge else { throw BoomError.budget("Metadata input exceeds the existing Root budget; original value retained.") }
      charge += body.bytes
    }
    self.id = expected?.id ?? UUID(); self.kind = kind; self.logicalID = logicalID
    self.parentID = parentID; self.ordinal = ordinal; self.metadata = encoded
    self.bodies = bodies; self.counts = counts; self.expected = expected; retainedBytes = charge
    if let expected {
      try expected.validate()
      guard expected.kind == kind, expected.logicalID == logicalID,
        expected.parentID == parentID, expected.ordinal == ordinal else { throw BoomError.stale("An entity update cannot silently change its identity/order.") }
    }
  }
  static func chat(_ value: ChatRecord, ordinal: Int, expected: WorkspaceEntityReference? = nil) throws -> Self {
    let metadata = ChatRecord(id: value.id, title: value.title, attachedDocumentID: value.attachedDocumentID)
    var counts = ["messages": value.messages.count]
    if let versions = value.messageVersions { counts["versions"] = versions.count }
    return try Self(kind: .chat, logicalID: value.id, parentID: Vault.workspaceID, ordinal: ordinal,
      metadata: .chat(metadata), bodies: value.instructions.map { ["instructions": .text($0)] } ?? [:], counts: counts, expected: expected)
  }
  static func message(_ value: ChatMessage, chatID: UUID, ordinal: Int, version: Bool = false,
    expected: WorkspaceEntityReference? = nil) throws -> Self {
    var metadata = value; metadata.text = ""; metadata.context = ""; metadata.failure = nil
    var bodies: [String: Body] = ["text": .text(value.text), "context": .text(value.context)]
    if let failure = value.failure { bodies["failure"] = .text(failure) }
    return try Self(kind: version ? .messageVersion : .message, logicalID: value.id, parentID: chatID,
      ordinal: ordinal, metadata: .message(metadata), bodies: bodies, expected: expected)
  }
  static func voice(_ value: Voice, ordinal: Int, version: Bool = false, expected: WorkspaceEntityReference? = nil) throws -> Self {
    guard !Thread.isMainThread, value.instructions.utf8.count <= WorkspaceMetadataInput.maximumInputBytes else { throw BoomError.budget("Voice preparation must be bounded and off Main.") }
    guard value.examples.count <= 64 else { throw BoomError.budget("Voice example count exceeds the bounded body codec; original value retained.") }
    try Self.admitJSONStrings(value.examples.flatMap { [$0.user, $0.assistant] }, fixedBytes: 64 * 64)
    guard try ProductCore.voice(value.draft).revision == value.revision else { throw BoomError.denied("Voice revision is not the actual canonical content.") }
    let metadata = Voice(id: value.id, slug: value.slug, name: value.name, instructions: "", examples: [], revision: value.revision)
    return try Self(kind: version ? .voiceVersion : .voice, logicalID: value.id, parentID: Vault.workspaceID,
      ordinal: ordinal, metadata: .voice(metadata), bodies: ["instructions": .text(value.instructions), "examples": .json(try JSONEncoder().encode(value.examples))], expected: expected)
  }
  static func draft(_ value: ComposerDraft, expected: WorkspaceEntityReference? = nil) throws -> Self {
    guard !Thread.isMainThread, value.text.utf8.count <= 2_097_152 else { throw BoomError.budget("The retained draft exceeds its existing2 MiB bound.") }
    let metadata = ComposerDraft(owner: value.owner, text: "", attachments: value.attachments, authoredRole: value.authoredRole)
    return try Self(kind: .draft, logicalID: value.owner.id, parentID: value.owner.id, ordinal: value.owner.kind == .document ? 0 : 1,
      metadata: .draft(metadata), bodies: ["text": .text(value.text)], expected: expected)
  }
  static func attachment(_ value: AttachmentRecord, ordinal: Int, expected: WorkspaceEntityReference? = nil) throws -> Self {
    let metadata = AttachmentRecord(id: value.id, name: value.name, rootDigest: value.rootDigest, text: "", coverage: "", transform: nil,
      isImage: value.isImage, awaitingTranscription: value.awaitingTranscription, awaitingPreparation: value.awaitingPreparation, presentation: value.presentation)
    var bodies: [String: Body] = ["text": .text(value.text), "coverage": .text(value.coverage)]
    if let transform = value.transform { bodies["transform"] = .text(transform) }
    return try Self(kind: .attachment, logicalID: value.id, parentID: Vault.workspaceID, ordinal: ordinal, metadata: .attachment(metadata), bodies: bodies, expected: expected)
  }
  static func proposal(_ value: StoredProposal, ordinal: Int, expected: WorkspaceEntityReference? = nil) throws -> Self {
    guard !Thread.isMainThread, value.document.text.utf8.count <= WorkspaceMetadataInput.maximumInputBytes,
      value.patch.replacements.count <= 64 else { throw BoomError.budget("Proposal replacement count exceeds the bounded body codec; original proposal retained.") }
    try Self.admitJSONStrings(value.patch.replacements.flatMap { [$0.old, $0.new] }, fixedBytes: 64 * 256 + 512)
    let metadata = WorkspaceProposalMetadata(id: value.id, chatID: value.chatID, messageID: value.messageID,
      document: DocumentIndex(id: value.document.id, title: value.document.title), capturedRevision: value.document.revision,
      documents: value.documents, attachments: value.attachments, status: value.status, appliedRevision: value.appliedRevision)
    return try Self(kind: .proposal, logicalID: value.id, parentID: value.chatID, ordinal: ordinal, metadata: .proposal(metadata),
      bodies: ["documentText": .text(value.document.text), "patch": .json(try JSONEncoder().encode(value.patch))], expected: expected)
  }
  static func origin(_ value: ManuscriptOrigin, documentID: UUID, expected: WorkspaceEntityReference? = nil) throws -> Self {
    try Self(kind: .manuscriptOrigin, logicalID: documentID, parentID: value.documentID, ordinal: 0, metadata: .origin(value), expected: expected)
  }
  static func folder(_ value: ImportedFolder, ordinal: Int, expected: WorkspaceEntityReference? = nil) throws -> Self {
    try Self(kind: .importedFolder, logicalID: value.id, parentID: Vault.workspaceID, ordinal: ordinal, metadata: .folder(value), expected: expected)
  }
  static func importedFile(_ value: ImportedFile, documentID: UUID, expected: WorkspaceEntityReference? = nil) throws -> Self {
    try Self(kind: .importedFile, logicalID: documentID, parentID: documentID, ordinal: 0, metadata: .file(value), expected: expected)
  }
  static func candidate(_ id: UUID, ordinal: Int) throws -> Self {
    try Self(kind: .candidate, logicalID: id, parentID: Vault.workspaceID, ordinal: ordinal, metadata: .candidate(id))
  }
  static func recordingDraft(_ ids: [UUID], chatID: UUID, expected: WorkspaceEntityReference? = nil) throws -> Self {
    try Self(kind: .recordingDraft, logicalID: chatID, parentID: chatID, ordinal: 0, metadata: .recordingDraft(ids), expected: expected)
  }
  static func documentArchive(_ value: WorkspaceDocumentArchive, documentID: UUID,
    expected: WorkspaceEntityReference?) throws -> Self {
    try value.validate(documentID: documentID)
    let bodies: [String: Body] = try value.retainedRecord.map { ["record": .json(try JSONEncoder().encode($0))] } ?? [:]
    return try Self(kind: .documentArchive, logicalID: documentID, parentID: documentID,
      ordinal: 0, metadata: .documentArchive(WorkspaceDocumentArchiveMetadata(original: value.original,
        trashed: value.retainedRecord != nil)), bodies: bodies, expected: expected)
  }
  private static func admitJSONStrings(_ strings: [String], fixedBytes: Int) throws {
    var charged = fixedBytes
    for string in strings {
      let bytes = string.utf8.count
      guard bytes <= (WorkspaceMetadataInput.maximumInputBytes - charged) / 6 else {
        throw BoomError.budget("Escaped JSON body would exceed its pre-encoding bound; original value retained.")
      }
      charged += bytes * 6
    }
  }
  /// Admit fixed-shape scalars and array counts BEFORE an encoder can allocate.
  /// The subsequent actual 8 KiB encoded check remains authoritative.
  private static func admitMetadataBeforeEncoding(_ value: WorkspaceEntityMetadata) throws {
    var strings: [String] = []
    func sources(_ values: [SourceReference]) throws {
      guard values.count <= 32 else { throw BoomError.budget("Entity source references exceed their bounded header.") }
      for value in values { strings += [value.title, value.digest, value.kind] }
    }
    switch value {
    case .chat(let value): strings = [value.title]
    case .message(let value):
      guard (value.directAttachments?.count ?? 0) <= 8, (value.consultationRouting?.count ?? 0) <= 32 else { throw BoomError.budget("Message scalar list exceeds its header bound.") }
      try sources(value.sources)
      strings += [value.provider ?? "", value.speaker?.name ?? "", value.speaker?.voiceRevision ?? ""]
      strings += value.consultationRouting ?? []
    case .voice(let value): strings = [value.slug, value.name, value.revision]
    case .draft(let value): guard value.attachments.count <= 8 else { throw BoomError.budget("Draft attachment references exceed8.") }
    case .attachment(let value): strings = [value.name, value.rootDigest]
    case .proposal(let value):
      try sources(value.documents); try sources(value.attachments)
      strings += [value.document.title, value.capturedRevision, value.status, value.appliedRevision ?? ""]
    case .origin(let value): strings = [value.revision]
    case .folder(let value): strings = [value.name]
    case .file(let value): strings = [value.path, value.originalDigest]
    case .documentArchive(let value):
      guard value.original != nil || value.trashed else { throw BoomError.invalid("Empty document archive.") }
      if let original = value.original { try original.validate(documentID: original.revision.documentID) }
      strings = [value.original?.path ?? ""]
    case .candidate: break
    case .recordingDraft(let value): guard value.count <= 8 else { throw BoomError.budget("Recording draft references exceed8.") }
    }
    var total = 0
    for string in strings {
      guard string.utf8.count <= 8_192 - total else { throw BoomError.budget("Metadata scalars exceed the pre-encoding header bound; original value retained.") }
      total += string.utf8.count
    }
  }
  func header(bodies: [String: WorkspaceEntityBodyReference]) throws -> WorkspaceEntityHeader {
    let value = WorkspaceEntityHeader(schema: 1, id: id, kind: kind, logicalID: logicalID, parentID: parentID,
      ordinal: ordinal, metadata: metadata, bodies: bodies, counts: counts)
    try value.validate(); return value
  }
}

struct WorkspaceMetadataInput: Sendable {
  static let maximumInputBytes = 3_145_728 // inside the existing4 MiB aggregate Root budget
  static let maximumEntities = 7
  let inputID = UUID()
  let settings: WorkspaceSettings?
  let entities: [WorkspaceEntityInput]
  let removals: [WorkspaceEntityRemoval]
  let initialDocuments: [PagedDocumentRootRecord]?
  let documentChanges: [WorkspaceDocumentMutation]
  var changedDocumentIDs: Set<UUID> { Set(initialDocuments?.map { $0.document.id } ?? documentChanges.map(\.documentID)) }
  var producerLeases: [PagedTextRootLease] { documentChanges.flatMap(\.producerLeases) }
  var outputReservationBytes: Int { changedDocumentIDs.isEmpty ? 32_768 : PagedTextWindow.maximumBytes }
  let retainedBytes: Int
  init(settings: WorkspaceSettings? = nil, entities: [WorkspaceEntityInput] = [],
    removals: [WorkspaceEntityRemoval] = [], initialDocuments: [PagedDocumentRootRecord]? = nil,
    documentChanges: [WorkspaceDocumentMutation] = []) throws {
    guard !Thread.isMainThread, entities.count <= Self.maximumEntities, removals.count <= Self.maximumEntities,
      Set(entities.map(\.id)).count == entities.count, Set(removals.map { $0.expected.id }).count == removals.count,
      Set(entities.map(\.id)).isDisjoint(with: removals.map { $0.expected.id }),
      (initialDocuments?.count ?? 0) <= Self.maximumEntities, documentChanges.count <= Self.maximumEntities,
      initialDocuments == nil || documentChanges.isEmpty,
      Set(documentChanges.map(\.documentID)).count == documentChanges.count,
      Set(documentChanges.flatMap(\.producerLeases).map(\.id)).count == documentChanges.flatMap(\.producerLeases).count,
      entities.allSatisfy({ $0.kind != .documentArchive }),
      settings != nil || !entities.isEmpty || !removals.isEmpty || !documentChanges.isEmpty else {
      throw BoomError.budget("Invalid bounded metadata input; original values retained.")
    }
    for removal in removals { try removal.expected.validate() }
    try settings?.admitScalars()
    let settingBytes = try settings.map { try JSONEncoder().encode($0).count } ?? 0
    guard settingBytes <= WorkspaceSettings.maximumEncodedBytes else { throw BoomError.budget("Settings exceed16 KiB.") }
    for record in initialDocuments ?? [] { try WorkspaceDocumentMutation.admitRecord(record) }
    // Exact before/after records, archive headers and bounded pointer/digest
    // scratch. This stays inside the same3 MiB input /4 MiB aggregate envelope.
    var charge = settingBytes + removals.count * 256
      + (initialDocuments?.count ?? documentChanges.count) * 32_768
      + (documentChanges.isEmpty ? 0 : 131_072)
    for entity in entities {
      guard entity.retainedBytes <= Self.maximumInputBytes - charge else { throw BoomError.budget("Metadata input exceeds its explicit retained buffer budget.") }
      charge += entity.retainedBytes
    }
    self.settings = settings; self.entities = entities; self.removals = removals
    guard charge <= Self.maximumInputBytes else { throw BoomError.budget("Document metadata exceeds the existing Root input budget.") }
    self.initialDocuments = initialDocuments; self.documentChanges = documentChanges; retainedBytes = charge
  }
}

struct WorkspaceMetadataChange: Codable, Equatable, Sendable {
  let before: WorkspaceEntityReference?
  let after: WorkspaceEntityReference?
}
struct WorkspaceMetadataPublication: Equatable, Sendable {
  let head: PagedWorkspaceHead
  let changes: [WorkspaceMetadataChange]
  let documents: [WorkspaceDocumentChange]
  init(head: PagedWorkspaceHead, changes: [WorkspaceMetadataChange], documents: [WorkspaceDocumentChange] = []) {
    self.head = head; self.changes = changes; self.documents = documents
  }
}

/// One utility/task-local cursor. Only the copied <=64 KiB chunk enters the
/// existing SQL executor; neither this cursor nor a transaction crosses queues.
struct WorkspaceEntityBodyCursor {
  private let text: String?
  private var iterator: String.UTF8View.Iterator?
  private var iteratorOffset = 0
  private var data: Data?
  private var offset = 0
  private let length: Int
  private let encoding: WorkspaceEntityBodyReference.Encoding
  private var emittedEmpty = false
  private var digest = SHA256()
  // Task-local synchronous cursor: utility preparation or one lexical SQL
  // body. It never crosses await and owns no queue/lock/producer/transaction.
  init(_ input: WorkspaceEntityInput.Body) {
    length = input.bytes; encoding = input.encoding
    switch input { case .text(let text): self.text = text; iterator = text.utf8.makeIterator(); data = nil
    case .json(let bytes): text = nil; iterator = nil; data = bytes }
  }
  mutating func next() -> Data? {
    if length == 0 {
      guard !emittedEmpty else { return nil }; emittedEmpty = true; return Data()
    }
    guard offset < length else { return nil }
    let count = min(65_536, length - offset)
    let chunk: Data
    if let data { chunk = data.subdata(in: offset..<(offset + count)) }
    else if let text {
      if let bytes = text.utf8.withContiguousStorageIfAvailable({ storage in
        precondition(storage.count == length, "Immutable input UTF8 extent changed.")
        return Data(bytes: storage.baseAddress!.advanced(by: offset), count: count)
      }) {
        chunk = bytes
      } else {
        // Bridged strings may lack contiguous UTF8. Keep one forward iterator
        // across every chunk; availability changes cannot replay earlier bytes.
        while iteratorOffset < offset {
          guard iterator?.next() != nil else { preconditionFailure("Immutable input UTF8 extent changed.") }
          iteratorOffset += 1
        }
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { raw in
          let buffer = raw.bindMemory(to: UInt8.self)
          for index in 0..<count {
            guard let byte = iterator?.next() else { preconditionFailure("Immutable input UTF8 extent changed.") }
            buffer[index] = byte
          }
        }
        iteratorOffset += count; chunk = bytes
      }
    } else {
      preconditionFailure("Immutable metadata body is absent.")
    }
    offset += count; digest.update(data: chunk); return chunk
  }
  mutating func finish(objectID: UUID) throws -> WorkspaceEntityBodyReference {
    guard offset == length, length != 0 || emittedEmpty else { throw BoomError.invalid("Metadata body producer has not joined its complete extent.") }
    let result = WorkspaceEntityBodyReference(objectID: objectID, encoding: encoding, bytes: length,
      digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
    try result.validate(); return result
  }
}

struct WorkspaceDocumentRead: Sendable {
  let head: PagedWorkspaceHead
  let record: PagedDocumentRootRecord
}
struct WorkspaceBoundedOpening: Sendable {
  let head: PagedWorkspaceHead
  let settings: WorkspaceSettings
  let documents: [WorkspaceDocumentDescriptor] // actual first bounded page
  let nextDocumentOrdinal: Int?
  let chats: [WorkspaceEntityRead] // header-only, no manufactured ChatRecord
  let nextChatOrdinal: Int?
  let selectedDocument: WorkspaceDocumentDescriptor?
}

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
extension WorkspaceMetadataInput {
  static func admitPublicFixture(_ state: WorkspaceState) throws -> Int {
    guard !Thread.isMainThread, state.schema == 1, state.documents.count <= maximumEntities else { throw BoomError.budget("Public conversion exceeds its small complete source envelope.") }
    _ = try PagedWorkspaceProjection.digest(state.documents)
    try state.validateRetainedInput()
    var count = state.chats.count + state.voices.count + state.voiceVersions.count + state.attachments.count
      + state.proposals.count + state.manuscriptOrigins.count + state.candidateIDs.count
      + (state.importedFolders?.count ?? 0) + (state.importedFiles?.count ?? 0)
      + (state.recordingDrafts?.count ?? 0) + (state.composerDrafts?.count ?? 0)
    guard count <= maximumEntities else { throw BoomError.budget("Complete public conversion exceeds seven records; original Vault unchanged.") }
    for chat in state.chats {
      guard chat.messages.count <= maximumEntities - count else { throw BoomError.budget("Complete public message conversion exceeds its fixture bound.") }
      count += chat.messages.count
      guard (chat.messageVersions?.count ?? 0) <= maximumEntities - count else { throw BoomError.budget("Complete public version conversion exceeds its fixture bound.") }
      count += chat.messageVersions?.count ?? 0
    }
    return count
  }
  /// Exact known-field public fixture conversion, not private migration.
  /// More than seven entity records is refused, never partly published.
  static func publicFixture(_ state: WorkspaceState,
    documents: [PagedDocumentRootRecord]) throws -> WorkspaceMetadataInput {
    let count = try admitPublicFixture(state)
    guard try PagedWorkspaceProjection.digest(state.documents)
      == PagedWorkspaceProjection.digest(documents.map { DocumentIndex(id: $0.document.id, title: $0.document.title) }) else {
      throw BoomError.denied("Public conversion lacks its real full document projection.")
    }
    var settings = WorkspaceSettings()
    settings.selectedDocument = state.selectedDocument; settings.selectedChat = state.selectedChat
    settings.showLibrary = state.showLibrary; settings.showDocument = state.showDocument; settings.showChat = state.showChat
    settings.autocomplete = state.autocomplete; settings.preferredModels = state.preferredModels ?? [:]
    settings.writingExampleIDs = state.writingExampleIDs ?? []; settings.theme = state.theme
    settings.presentOptionalCollections = [
      ("preferredModels", state.preferredModels != nil), ("importedFolders", state.importedFolders != nil),
      ("importedFiles", state.importedFiles != nil), ("recordingDrafts", state.recordingDrafts != nil),
      ("composerDrafts", state.composerDrafts != nil), ("writingExampleIDs", state.writingExampleIDs != nil),
    ].compactMap { $0.1 ? $0.0 : nil }
    var values: [WorkspaceEntityInput] = []
    for (ordinal, chat) in state.chats.enumerated() {
      values.append(try .chat(chat, ordinal: ordinal))
      for (index, message) in chat.messages.enumerated() { values.append(try .message(message, chatID: chat.id, ordinal: index)) }
      for (index, version) in (chat.messageVersions ?? []).enumerated() { values.append(try .message(version, chatID: chat.id, ordinal: index, version: true)) }
    }
    for (ordinal, voice) in state.voices.enumerated() { values.append(try .voice(voice, ordinal: ordinal)) }
    for (ordinal, voice) in state.voiceVersions.enumerated() { values.append(try .voice(voice, ordinal: ordinal, version: true)) }
    for (ordinal, value) in state.attachments.enumerated() { values.append(try .attachment(value, ordinal: ordinal)) }
    for (ordinal, value) in state.proposals.enumerated() { values.append(try .proposal(value, ordinal: ordinal)) }
    for (key, value) in state.manuscriptOrigins { values.append(try .origin(value, documentID: key)) }
    for (ordinal, value) in (state.importedFolders ?? []).enumerated() { values.append(try .folder(value, ordinal: ordinal)) }
    for (key, value) in state.importedFiles ?? [:] { values.append(try .importedFile(value, documentID: key)) }
    for (ordinal, id) in state.candidateIDs.enumerated() { values.append(try .candidate(id, ordinal: ordinal)) }
    for value in state.composerDrafts ?? [] { values.append(try .draft(value)) }
    for (chatID, ids) in state.recordingDrafts ?? [:] { values.append(try .recordingDraft(ids, chatID: chatID)) }
    guard values.count == count else { throw BoomError.invalid("Public conversion omitted a known workspace record.") }
    return try WorkspaceMetadataInput(settings: settings, entities: values, initialDocuments: documents)
  }
}
#endif
