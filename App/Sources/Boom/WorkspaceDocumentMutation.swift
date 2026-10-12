import BoomCore
import Foundation

/// Exact immutable original, separate from later document revisions and from
/// the shipped attachment-original format. Path/folder are retained labels,
/// not filesystem authority. Engine admission checks the real import output.
struct WorkspaceImportedOriginal: Codable, Equatable, Sendable {
  let revision: PagedTextRevision
  let wholeTextSHA256: String
  let path: String
  let folderID: UUID?
  static func == (left: Self, right: Self) -> Bool {
    left.revision == right.revision && left.wholeTextSHA256 == right.wholeTextSHA256
      && left.path.utf8.elementsEqual(right.path.utf8) && left.folderID == right.folderID
  }
  func validate(documentID: UUID) throws {
    try revision.validate()
    guard revision.documentID == documentID, PagedWorkspaceObjectReference.isDigest(wholeTextSHA256),
      path.utf8.count <= 1_024, folderID != WorkspaceEntityHeader.zero else {
      throw BoomError.invalid("Imported original has another identity or an oversized provenance label.")
    }
  }
}
/// One encrypted metadata header. Active imports retain original only; trash
/// also retains its last full record. No immutable source/history row is deleted.
struct WorkspaceDocumentArchive: Codable, Equatable, Sendable {
  let original: WorkspaceImportedOriginal?
  let retainedRecord: PagedDocumentRootRecord?
  func validate(documentID: UUID) throws {
    guard original != nil || retainedRecord != nil else { throw BoomError.invalid("Empty document archive.") }
    try original?.validate(documentID: documentID)
    if let retainedRecord {
      try WorkspaceDocumentMutation.admitRecord(retainedRecord)
      guard retainedRecord.document.id == documentID,
        original == nil || original?.revision.ownerID == retainedRecord.document.revision.ownerID else {
        throw BoomError.denied("Trashed source/history record changed owner.")
      }
    }
  }
}

/// The original import and initial-history carriers remain caller-owned until
/// the SAME metadata receiving join transfers them into the authenticated head.
/// A copied scalar revision or digest cannot replace either producer lease.
struct WorkspaceDocumentMutation: Sendable {
  enum Kind: String, Codable, Sendable { case initial, insert, rename, trash }
  let kind: Kind
  let before: PagedDocumentRootRecord?
  let after: PagedDocumentRootRecord?
  let imported: PagedTextCustodiedValue<PagedTextImportedRevision>?
  let initialized: PagedTextCustodiedValue<PagedDocumentRootRecord>?
  let original: WorkspaceImportedOriginal?
  var documentID: UUID { (before ?? after)!.document.id }
  var producerLeases: [PagedTextRootLease] { [imported?.lease, initialized?.lease].compactMap { $0 } }
  private init(kind: Kind, before: PagedDocumentRootRecord?, after: PagedDocumentRootRecord?,
    imported: PagedTextCustodiedValue<PagedTextImportedRevision>? = nil,
    initialized: PagedTextCustodiedValue<PagedDocumentRootRecord>? = nil,
    original: WorkspaceImportedOriginal? = nil) throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Document metadata admission belongs off Main.") }
    if let before { try Self.admitRecord(before) }; if let after { try Self.admitRecord(after) }
    self.kind = kind; self.before = before; self.after = after
    self.imported = imported; self.initialized = initialized; self.original = original
  }
  static func inserting(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    initialized: PagedTextCustodiedValue<PagedDocumentRootRecord>, path: String,
    folderID: UUID? = nil) throws -> Self {
    let original = WorkspaceImportedOriginal(revision: imported.value.revision,
      wholeTextSHA256: imported.value.wholeTextSha256, path: path, folderID: folderID)
    let record = initialized.value; try original.validate(documentID: record.document.id)
    guard record.document.revision == imported.value.revision, record.historyGeneration == 0,
      imported.lease != initialized.lease else { throw BoomError.denied("Insert lacks its two exact actual import/history outputs.") }
    return try Self(kind: .insert, before: nil, after: record,
      imported: imported, initialized: initialized, original: original)
  }
  static func renaming(_ expected: PagedDocumentRootRecord, title: String) throws -> Self {
    guard title.utf8.count <= 1_024 else { throw BoomError.budget("Document title exceeds its existing bound.") }
    let after = PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: expected.document.id,
      title: title, revision: expected.document.revision), historyPage: expected.historyPage,
      historyGeneration: expected.historyGeneration)
    return try Self(kind: .rename, before: expected, after: after)
  }
  static func trashing(_ expected: PagedDocumentRootRecord) throws -> Self {
    try Self(kind: .trash, before: expected, after: nil)
  }
  static func admitRecord(_ value: PagedDocumentRootRecord) throws {
    try value.validate()
    guard try JSONEncoder().encode(value).count <= 8_192 else {
      throw BoomError.budget("Document metadata witness exceeds its admitted8 KiB record.")
    }
  }
  func matches(_ change: WorkspaceDocumentChange) -> Bool {
    kind == change.kind && before == change.before && after == change.after
      && (kind != .insert || change.original == original)
  }
}

/// Both normal receiving and genuine checkpoint AFTER authenticate these exact
/// records and archive pointers, even when settings.selectedDocument is nil.
struct WorkspaceDocumentChange: Codable, Equatable, Sendable {
  let kind: WorkspaceDocumentMutation.Kind
  let before: PagedDocumentRootRecord?
  let after: PagedDocumentRootRecord?
  let archiveBefore: WorkspaceEntityReference?
  let archiveAfter: WorkspaceEntityReference?
  let original: WorkspaceImportedOriginal?
  var documentID: UUID { (before ?? after)!.document.id }
  func validate() throws {
    if let before { try WorkspaceDocumentMutation.admitRecord(before) }
    if let after { try WorkspaceDocumentMutation.admitRecord(after) }
    try archiveBefore?.validate(); try archiveAfter?.validate()
    guard before != nil || after != nil, before == nil || after == nil || before?.document.id == after?.document.id else {
      throw BoomError.invalid("Empty or cross-document metadata witness.")
    }
    try original?.validate(documentID: documentID)
    for reference in [archiveBefore, archiveAfter].compactMap({ $0 }) {
      guard reference.kind == .documentArchive, reference.logicalID == documentID,
        reference.parentID == documentID, reference.ordinal == 0 else { throw BoomError.denied("Archive witness has another document.") }
    }
    switch kind {
    case .initial: guard before == nil, after != nil, archiveBefore == nil, archiveAfter == nil, original == nil else { throw invalid() }
    case .insert: guard before == nil, after != nil, archiveBefore == nil, archiveAfter != nil, original?.revision == after?.document.revision else { throw invalid() }
    case .rename:
      guard let before, let after, before.document.revision == after.document.revision,
        before.historyPage == after.historyPage, before.historyGeneration == after.historyGeneration,
        archiveBefore == archiveAfter else { throw invalid() }
    case .trash: guard before != nil, after == nil, archiveAfter != nil else { throw invalid() }
    }
  }
  private func invalid() -> BoomError { .invalid("Document change does not preserve its exact source/history contract.") }
}

/// Authenticated bounded metadata, not a native opening or a model source grant.
struct WorkspaceDocumentArchiveRead: Sendable {
  let head: PagedWorkspaceHead
  let reference: WorkspaceEntityReference
  let archive: WorkspaceDocumentArchive
}
