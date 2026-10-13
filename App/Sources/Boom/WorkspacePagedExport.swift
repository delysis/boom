import BoomCore
import Foundation

extension WorkspaceStore {
  /// Export the actual full record captured by the native caller. Later edits
  /// can proceed while <=64 KiB steps write this immutable source. The same
  /// Root keeps the admitted record until the caller's system file publication
  /// joins; neither the editable island nor a legacy snapshot stands for it.
  func exportPagedDocument(_ record: PagedDocumentRootRecord,
    expectedHead: PagedWorkspaceHead, engine: PagedTextEngineAdapter,
    publisher: PagedWorkspacePublisher, to url: URL,
    cancellation: PagedTextCancellation = PagedTextCancellation()) async throws -> URL {
    guard engine.belongs(to: vault), publisher.belongs(to: vault),
      record.document.revision.ownerID == engine.ownerID else {
      throw BoomError.denied("Export belongs to another document or private storage owner.")
    }
    try record.validate()
    let target = url.standardizedFileURL.resolvingSymlinksInPath()
    let workspace = root.standardizedFileURL.resolvingSymlinksInPath()
    guard url.isFileURL, target != workspace,
      !target.path.hasPrefix(workspace.path + "/") else {
      throw BoomError.denied("An export destination cannot replace private workspace records.")
    }
    let capture = try await engine.loadWorkspaceDocumentRetaining(publisher,
      documentID: record.document.id, expectedHead: expectedHead)
    var releaseAttempted = false
    var published: URL?
    do {
      guard capture.value.record == record else {
        throw BoomError.stale("The selected document changed before export capture.")
      }
      let destination = try await ExplicitFileExport.write(to: url, checkCancellation: {
        if cancellation.isCancelled { throw CancellationError() }
      }, stream: { file in
        try await engine.export(record.document.revision, to: file, cancellation: cancellation)
      })
      published = destination
      releaseAttempted = true
      try await engine.abandonJoinedRootOutput(capture.lease)
      return destination
    } catch {
      let original = error
      if releaseAttempted {
        throw PagedDocumentExportReceivingFailure(original: original, publishedURL: published,
          lease: capture.lease)
      }
      releaseAttempted = true
      do { try await engine.abandonJoinedRootOutput(capture.lease) }
      catch {
        throw PagedDocumentExportReceivingFailure(original: PagedTextCustodyHandoffFailure(
          original: original, handoff: error, lease: capture.lease), publishedURL: published,
          lease: capture.lease)
      }
      throw original
    }
  }
}

struct PagedDocumentExportReceivingFailure: Error, LocalizedError {
  let original: Error
  let publishedURL: URL?
  let lease: PagedTextRootLease
  var errorDescription: String? {
    var description = original.localizedDescription
    if let publishedURL { description += " Export was published at \(publishedURL.path)." }
    return description + " Document capture \(lease.id) remains owned."
  }
}
