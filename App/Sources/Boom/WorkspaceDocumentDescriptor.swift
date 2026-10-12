import BoomCore
import Foundation

/// Source metadata for the legacy bounded AEAD record. The exact plaintext
/// SHA is distinct from the legacy String decoder's revision and a paged tree.
struct LegacyWorkspaceDocumentDescriptor: Equatable, Identifiable, Sendable {
  let index: DocumentIndex
  let plaintextSha256: String
  let summary: PagedTextSummary
  var id: UUID { index.id }
  var title: String { index.title }
  static func == (left: Self, right: Self) -> Bool {
    left.id == right.id && left.title.utf8.elementsEqual(right.title.utf8)
      && left.plaintextSha256 == right.plaintextSha256 && left.summary == right.summary
  }

  /// Unicode's standard-library decoder validates exact UTF-8 without making
  /// a manuscript String. Only a <=2 MiB legacy record uses this admission.
  static func summary(of bytes: Data) throws -> PagedTextSummary {
    guard bytes.count <= 2_097_152 else { throw BoomError.budget("Markdown document exceeds 2 MiB.") }
    var input = bytes.makeIterator()
    var decoder = Unicode.UTF8()
    var utf16: UInt64 = 0, lines: UInt64 = 0
    while true {
      switch decoder.decode(&input) {
      case .scalarValue(let scalar):
        utf16 += scalar.value > 0xffff ? 2 : 1
        if scalar.value == 10 { lines += 1 }
      case .emptyInput:
        return PagedTextSummary(bytes: UInt64(bytes.count), utf16: utf16, lfCount: lines)
      case .error:
        throw BoomError.invalid("Document is not valid UTF-8; original bytes were retained.")
      }
    }
  }
}

/// Library/open identity has no synthesized `text` or string `revision`.
/// A paged source retains its whole document/history record, not just a root.
enum WorkspaceDocumentDescriptor: Equatable, Identifiable, Sendable {
  case legacy(LegacyWorkspaceDocumentDescriptor)
  case paged(PagedDocumentRootRecord)

  var id: UUID {
    switch self { case .legacy(let value): return value.id; case .paged(let value): return value.document.id }
  }
  var title: String {
    switch self { case .legacy(let value): return value.title; case .paged(let value): return value.document.title }
  }
  var summary: PagedTextSummary {
    switch self { case .legacy(let value): return value.summary; case .paged(let value): return value.document.revision.summary }
  }
}

/// One coherent, authenticated head + metadata payload + full record projection.
/// The engine returns this only inside an actual PagedTextCustodiedValue; this
/// value by itself does not grant native installation or model/edit authority.
/// It also does not replace ordinary media/voice/generation-recovery admission.
/// OPEN: WorkspaceState has a 128 MiB encoded compatibility envelope and is
/// not charged to the native root lease's payload envelope. This is a cold
/// metadata consumer proposal, not a scant/bounded decoded-catalog promise.
struct PagedWorkspaceDocumentCatalog: Sendable {
  let snapshot: PagedWorkspaceSnapshot
  let state: WorkspaceState
  var documents: [WorkspaceDocumentDescriptor] { snapshot.documents.map(WorkspaceDocumentDescriptor.paged) }
}

extension WorkspaceStore {
  /// The ordinary owner passes its one existing engine/publisher, selected by
  /// a separately authenticated durable format route. This API never guesses
  /// an owner, initializes missing heads, opens another engine or falls back
  /// to legacy files after paged admission fails.
  func loadPagedDocumentCatalog(engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher)
    async throws -> PagedTextCustodiedValue<PagedWorkspaceDocumentCatalog> {
    guard engine.belongs(to: vault), publisher.belongs(to: vault) else {
      throw BoomError.denied("Paged catalog belongs to another private Vault session.")
    }
    return try await engine.loadWorkspaceCatalogRetaining(publisher)
  }
}
