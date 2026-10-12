import BoomCore
import Foundation

/// Immutable imported original. Editing the manuscript uses copy-on-write
/// roots; this exact original root must remain in durable metadata and GC's
/// traced roots independently of the later manuscript/history root.
struct PagedImportedOriginalReference: Codable, Equatable, Sendable {
  let revision: PagedTextRevision
  let wholeTextSha256: String
  func validate(ownerID: UUID, documentID: UUID) throws {
    try revision.validate()
    guard revision.ownerID == ownerID, revision.documentID == documentID,
      PagedWorkspaceObjectReference.isDigest(wholeTextSha256) else {
      throw BoomError.invalid("Imported original has another source owner or digest.")
    }
  }
}

/// Joined import output, still unpublished. No original, manuscript or library
/// row is accepted by returning this object. Main must retain its actual lease
/// through history initialization + original/reference metadata + coherent
/// head publication, or preserve an explicit failure disposition.
struct StagedPagedWorkspaceDocumentImport: Sendable {
  let document: PagedDocumentDescriptor
  let original: PagedImportedOriginalReference
  let custody: PagedTextRootLease
}

extension WorkspaceStore {
  /// The caller owns the selected regular FileHandle and scope. The engine
  /// duplicates it and transfers <=64 KiB at a time; no whole Data/String or
  /// plaintext staging file exists. This API grants no import-policy authority:
  /// ordinary use still requires the new Rust metadata/bulk admission plus
  /// original-root persistence. The current small-file policy remains intact.
  func stagePagedDocumentImport(engine: PagedTextEngineAdapter, documentID: UUID,
    title: String, from file: FileHandle, cancellation: PagedTextCancellation)
    async throws -> StagedPagedWorkspaceDocumentImport {
    guard engine.belongs(to: vault) else { throw BoomError.denied("Import belongs to another private Vault session.") }
    guard title.utf8.count <= 1_024 else { throw BoomError.budget("Paged document title exceeds its bound.") }
    let output = try await engine.importUTF8Retaining(documentID: documentID, from: file,
      cancellation: cancellation)
    do {
      let document = PagedDocumentDescriptor(id: documentID, title: title, revision: output.value.revision)
      try document.validate()
      let original = PagedImportedOriginalReference(revision: output.value.revision,
        wholeTextSha256: output.value.wholeTextSha256)
      try original.validate(ownerID: engine.ownerID, documentID: documentID)
      return StagedPagedWorkspaceDocumentImport(document: document, original: original, custody: output.lease)
    } catch {
      // Validation after an actual joined producer cannot drop its root or
      // return success. The receiving owner gets the real same-engine lease.
      throw PagedTextCustodyFailure(original: error, lease: output.lease)
    }
  }
}
