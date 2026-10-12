import BoomCore
import CryptoKit
import Foundation

/// This intermediate still retains the existing <=128 MiB encoded payload.
/// Chunked SQL rows do NOT qualify decoded/encoded metadata memory. Ordinary
/// activation remains blocked on a separately bounded receiving/encoding path.
struct EncodedPagedWorkspace: Sendable {
  fileprivate let bytes: Data
  fileprivate let reference: PagedWorkspaceObjectReference
  fileprivate let documents: [DocumentIndex]
  fileprivate let vault: Vault
  fileprivate let ownerID: UUID
  var partCount: Int { reference.partCount }
  var plaintextBytes: Int { reference.plaintextBytes }
}
struct PreparedPagedWorkspace: Sendable {
  let reference: PagedWorkspaceObjectReference
  let documents: [DocumentIndex]
  let ownerID: UUID
  fileprivate let vault: Vault
  fileprivate let storeID: UUID
}
/// Same Vault, executor and SQL connection as the page provider. Publication
/// changes row pointers in its caller's existing write transaction; no file
/// journal, lock, rename, catalog rewrite or external sync remains on this route.
final class PagedWorkspacePublisher: @unchecked Sendable {
  let ownerID: UUID
  fileprivate let store: PagedSQLiteStore
  private let vault: Vault
  init(store: PagedSQLiteStore, vault: Vault) throws {
    try store.requireQueue()
    guard store.belongs(to: vault) else { throw BoomError.denied("Publisher has another Vault key owner.") }
    self.store = store; self.vault = vault; ownerID = store.ownerID
  }
  func belongs(to vault: Vault) -> Bool { self.vault === vault }
  func belongs(to store: PagedSQLiteStore) -> Bool { self.store === store }

  /// Pure utility-worker encoding. It never touches the SQL connection. The
  /// existing compatibility allocation gap is retained explicitly, not hidden.
  func encodeWorkspace(_ state: WorkspaceState) throws -> EncodedPagedWorkspace {
    guard !Thread.isMainThread else { throw BoomError.invalid("Workspace encoding must run off Main.") }
    try PagedWorkspaceProjection.validate(state)
    let id = UUID(), object = PagedWorkspacePayloadObject(ownerID: ownerID, objectID: id, state: state)
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let bytes = try encoder.encode(object)
    let reference = PagedWorkspaceObjectReference(objectID: id, plaintextBytes: bytes.count,
      digest: Digest.sha256(bytes), documentProjectionDigest: try PagedWorkspaceProjection.digest(state.documents))
    try reference.validate(ownerID: ownerID)
    return EncodedPagedWorkspace(bytes: bytes, reference: reference, documents: state.documents, vault: vault, ownerID: ownerID)
  }
  /// One <=64 KiB chunk per existing background executor quantum. The host
  /// commits each candidate quantum before yielding; no SQL tx crosses await.
  func stageWorkspacePart(_ encoded: EncodedPagedWorkspace, part: Int) throws {
    try admit(encoded)
    guard store.hasTransaction, part >= 0, part < encoded.partCount else { throw BoomError.invalid("Invalid workspace staging quantum.") }
    let start = part * 65_536, end = min(encoded.bytes.count, start + 65_536)
    let bytes = encoded.bytes.subdata(in: start..<end)
    try store.insert(bytes, objectID: encoded.reference.objectID, documentID: Vault.workspaceID, role: .workspace, part: part)
    guard try store.read(objectID: encoded.reference.objectID, documentID: Vault.workspaceID,
      role: .workspace, maximumBytes: 65_536, part: part) == bytes else {
      throw BoomError.invalid("Workspace chunk authenticated readback changed.")
    }
  }
  func finishWorkspacePreparation(_ encoded: EncodedPagedWorkspace) throws -> PreparedPagedWorkspace {
    try admit(encoded)
    guard !store.hasTransaction else { throw BoomError.invalid("Workspace preparation must join its last SQL quantum.") }
    // Admission consumes actual authenticated row reads, bounded per row. The
    // full compatibility payload is already retained by this explicit operation.
    for part in 0..<encoded.partCount {
      let start = part * 65_536, end = min(encoded.bytes.count, start + 65_536)
      guard try store.read(objectID: encoded.reference.objectID, documentID: Vault.workspaceID,
        role: .workspace, maximumBytes: end - start, part: part).elementsEqual(encoded.bytes[start..<end]) else {
        throw BoomError.invalid("Prepared immutable workspace chunk changed.")
      }
    }
    return PreparedPagedWorkspace(reference: encoded.reference, documents: encoded.documents,
      ownerID: ownerID, vault: vault, storeID: store.storeID)
  }
  func initialize(_ prepared: PreparedPagedWorkspace, documents: [PagedDocumentRootRecord],
    validateRecord: (PagedDocumentRootRecord) throws -> Void,
    beforePublication: () throws -> Void = {}) throws -> PagedWorkspaceSnapshot {
    try requireTransaction(); try admit(prepared)
    guard try store.headID() == nil, try store.documentIDs().isEmpty, try !store.hasEntityInventory() else { throw BoomError.stale("SQLite workspace is not fresh; records retained.") }
    try match(documents, workspace: prepared.reference)
    var pointers: [(UUID, UUID)] = []
    for record in documents { try validateRecord(record); pointers.append((record.document.id, try writeRecord(record))) }
    let head = PagedWorkspaceHead(ownerID: ownerID, storeID: store.storeID, generation: 0, workspace: prepared.reference)
    try beforePublication(); try writeHead(head); try store.replaceInventory(pointers); try store.replaceHead(objectID: head.headID, expected: nil)
    _ = try store.recordPublication(before: nil, after: head, beforeRecord: nil, afterRecord: nil)
    return PagedWorkspaceSnapshot(head: head, documents: documents)
  }
  /// Cold load is the only path materializing the complete <=1024-entry catalog.
  func load(validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceSnapshot {
    let snapshot = try store.withReadSnapshot { try self.loadSnapshot(validateRecord: validateRecord) }
    _ = try readPayload(snapshot.head.workspace); return snapshot
  }
  func loadCatalogAndWorkspace(validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceDocumentCatalog {
    let snapshot = try store.withReadSnapshot { try self.loadSnapshot(validateRecord: validateRecord) }
    return PagedWorkspaceDocumentCatalog(snapshot: snapshot, state: try readPayload(snapshot.head.workspace))
  }
  /// Authenticates only the requested document records and head. The deferred
  /// workspace payload is NOT decoded or represented by an empty WorkspaceState.
  /// This value is a library page, not complete ordinary-workspace admission.
  func documentIndexPage(afterOrdinal: Int, expectedHead: PagedWorkspaceHead?,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedDocumentIndexPage {
    guard afterOrdinal == -1 || expectedHead != nil else {
      throw BoomError.stale("A continued document-index page must retain its exact first head.")
    }
    return try store.withReadSnapshot {
      let head = try readHead()
      if let expectedHead, head != expectedHead {
        throw BoomError.stale("The document-index page belongs to a newer head.")
      }
      let pointers = try store.documentIDs(afterOrdinal: afterOrdinal,
        maximumRecords: PagedDocumentIndexPage.maximumRecords + 1)
      var records: [PagedDocumentRootRecord] = []
      records.reserveCapacity(PagedDocumentIndexPage.maximumRecords)
      var charged = 4_096 // already enforced by the authenticated head reader
      for pointer in pointers.prefix(PagedDocumentIndexPage.maximumRecords) {
        let read = try store.authenticatedRecord(pointer.documentID, objectID: pointer.objectID)
        guard read.encodedBytes <= PagedDocumentIndexPage.maximumPayloadBytes - charged else {
          throw BoomError.budget("Document-index page exceeds its receiving reservation.")
        }
        try validateRecord(read.record)
        charged += read.encodedBytes; records.append(read.record)
      }
      let hasLater = pointers.count > PagedDocumentIndexPage.maximumRecords
      let next = hasLater ? pointers[PagedDocumentIndexPage.maximumRecords - 1].ordinal : nil
      return PagedDocumentIndexPage(head: head, records: records,
        nextOrdinal: next, chargedBytes: charged)
    }
  }
  func admitSnapshot(_ expected: PagedWorkspaceSnapshot,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws {
    try store.withReadSnapshot {
      guard try self.loadSnapshot(validateRecord: validateRecord) == expected else { throw BoomError.stale("Actual metadata receiver has another full current head/catalog.") }
    }
  }
  /// Only a newly published metadata consumer uses this bounded streaming
  /// admission. Shared/native record admission never reopens unchanged payload.
  func admitPublishedWorkspacePayload(_ head: PagedWorkspaceHead) throws {
    try head.validate(ownerID: ownerID)
    guard head.storeID == store.storeID else { throw BoomError.denied("Published metadata belongs to another actual store.") }
    try store.withReadSnapshot { try self.authenticatePreparedParts(head.workspace) }
  }
  func loadWorkspace(_ head: PagedWorkspaceHead) throws -> WorkspaceState {
    try head.validate(ownerID: ownerID)
    guard head.storeID == store.storeID else { throw BoomError.denied("Historical head has another store.") }
    return try readPayload(head.workspace)
  }
  func admitCurrentRecord(_ expected: PagedDocumentRootRecord,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws {
    try store.withReadSnapshot {
      try expected.validate(); _ = try readHead()
      guard try readRecord(expected.document.id)?.record == expected else { throw BoomError.stale("Full document/history record changed.") }
      try validateRecord(expected)
    }
  }
  func publishDocument(_ after: PagedDocumentRootRecord, expected: PagedDocumentRootRecord,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceDocumentPublication {
    try requireTransaction(); try after.validate(); try expected.validate()
    let beforeHead = try readHead()
    guard let before = try readRecord(after.document.id), before.record == expected,
      after.document.id == expected.document.id,
      after.document.title.utf8.elementsEqual(expected.document.title.utf8),
      after.historyGeneration > expected.historyGeneration else { throw BoomError.stale("Native SQL publication has another full record or epoch.") }
    try validateRecord(after)
    let object = try writeRecord(after), head = try nextHead(beforeHead, workspace: beforeHead.workspace)
    try writeHead(head); try store.replaceRecord(documentID: after.document.id, objectID: object, expected: before.objectID)
    try store.replaceHead(objectID: head.headID, expected: beforeHead.headID)
    let publication = try store.recordPublication(before: beforeHead, after: head, beforeRecord: expected, afterRecord: after)
    guard let operationID = store.transactionOperationID else { throw BoomError.invalid("Actual publication lost its transaction owner.") }
    return PagedWorkspaceDocumentPublication(head: head, record: after, operationID: operationID, publication: publication)
  }
  /// Create/remove/title/metadata changes require the complete expected head.
  /// This explicit inventory operation never runs on each native character seal.
  func publishWorkspace(_ prepared: PreparedPagedWorkspace, documents: [PagedDocumentRootRecord],
    expectedHead: PagedWorkspaceHead, validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceSnapshot {
    try requireTransaction(); try admit(prepared)
    let before = try loadSnapshot(validateRecord: validateRecord)
    guard before.head == expectedHead, before.head.workspace.layout == .workspaceState,
      try !store.hasEntityInventory() else { throw BoomError.stale("Whole workspace compatibility cannot replace row-scoped ordinary metadata.") }
    try match(documents, workspace: prepared.reference)
    let prior = Dictionary(uniqueKeysWithValues: before.documents.map { ($0.document.id, $0) })
    var pointers: [(UUID, UUID)] = []
    for record in documents {
      try monotonic(record, before: prior[record.document.id]); try validateRecord(record)
      if let current = try readRecord(record.document.id), current.record == record { pointers.append((record.document.id, current.objectID)) }
      else { pointers.append((record.document.id, try writeRecord(record))) }
    }
    let head = try nextHead(before.head, workspace: prepared.reference)
    try writeHead(head); try store.replaceInventory(pointers); try store.replaceHead(objectID: head.headID, expected: before.head.headID)
    _ = try store.recordPublication(before: before.head, after: head, beforeRecord: nil, afterRecord: nil)
    return PagedWorkspaceSnapshot(head: head, documents: documents)
  }
  /// Authenticate the actual authority selected by a retained live execution.
  /// Rows alone never grant durability. Store.resolve performs any required
  /// sync, and the actual receiving owner still has to join its normal output.
  func selectedAuthority(_ execution: PagedSQLiteExecution,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedSQLiteExecution.Selection {
    guard execution.identity.store == store.nativeReceivingIdentity else { throw BoomError.denied("Outcome belongs to another actual SQL connection.") }
    if let publication = execution.publication {
      // A real known outcome tolerates unrelated metadata/other-document
      // updates. Only this complete target record is the native CAS authority.
      // An unknown COMMIT still requires exact whole BEFORE/AFTER head below.
      if execution.selectedBefore, let before = publication.beforeRecord {
        _ = try readHead()
        guard try readRecord(before.document.id)?.record == before else { throw BoomError.stale("Known BEFORE target record changed.") }
        try validateRecord(before); return .before
      }
      if execution.selectedAfter, let after = publication.afterRecord {
        _ = try readHead()
        guard try readRecord(after.document.id)?.record == after else { throw BoomError.stale("Known AFTER target record changed.") }
        try validateRecord(after); return .after
      }
      // Equal observations cannot distinguish unknown COMMIT and must never
      // construct a native ACK. Normal publishers allocate a new head/epoch.
      guard publication.beforeHead != publication.afterHead,
        publication.beforeRecord == nil || publication.beforeRecord != publication.afterRecord else {
        throw BoomError.stale("Unknown equal SQL authorities cannot identify a publication.")
      }
      let current = try store.headID()
      if let changes = publication.metadataChanges {
        if execution.selectedAfter {
          _ = try admitMetadataPublication(WorkspaceMetadataPublication(head: publication.afterHead, changes: changes, documents: publication.documentChanges ?? []), validateRecord: validateRecord); return .after
        }
        if current == publication.afterHead.headID {
          guard try readHead() == publication.afterHead else { throw BoomError.denied("Metadata AFTER head identity changed.") }
          _ = try readSettings(publication.afterHead); try admitMetadataChanges(changes, after: true)
          try admitDocumentChanges(publication.documentChanges ?? [], after: true, validateRecord: validateRecord); return .after
        }
        if let before = publication.beforeHead {
          guard current == before.headID, try readHead() == before else { throw BoomError.stale("Metadata has neither exact BEFORE nor AFTER.") }
          _ = try readSettings(before); try admitMetadataChanges(changes, after: false)
          try admitDocumentChanges(publication.documentChanges ?? [], after: false, validateRecord: validateRecord)
        } else {
          guard current == nil, try store.documentIDs().isEmpty, try !store.hasEntityInventory() else { throw BoomError.stale("Initial metadata no longer has its actual absent BEFORE.") }
        }
        return .before
      }
      if current == publication.afterHead.headID {
        guard try readHead() == publication.afterHead else { throw BoomError.denied("Selected AFTER head differs from its authenticated immutable object.") }
        if let record = publication.afterRecord {
          guard try readRecord(record.document.id)?.record == record else { throw BoomError.stale("Selected AFTER full record differs from its actual publication.") }
          try validateRecord(record)
        } else { _ = try loadSnapshot(validateRecord: validateRecord); _ = try authenticateWorkspaceAuthority(publication.afterHead) }
        return .after
      }
      if let before = publication.beforeHead {
        guard current == before.headID, try readHead() == before else { throw BoomError.stale("SQL has neither exact BEFORE nor AFTER head.") }
        if let record = publication.beforeRecord {
          guard try readRecord(record.document.id)?.record == record else { throw BoomError.stale("Selected BEFORE full record differs from captured authority.") }
          try validateRecord(record)
        } else { _ = try loadSnapshot(validateRecord: validateRecord); _ = try authenticateWorkspaceAuthority(before) }
      } else {
        guard current == nil, try store.documentIDs().isEmpty else { throw BoomError.stale("Initial publication has neither absent BEFORE nor exact AFTER inventory.") }
      }
      return .before
    }
    if execution.selectedBefore, let before = execution.beforeRecord {
      _ = try readHead()
      guard try readRecord(before.document.id)?.record == before else { throw BoomError.stale("Known unpublished target record changed.") }
      try validateRecord(before); return .before
    }
    guard execution.beforeAdmitted else { throw BoomError.stale("Actual operation never authenticated its source authority.") }
    if let before = execution.beforeHead {
      guard try readHead() == before else { throw BoomError.stale("Candidate producer has another current head.") }
      if let record = execution.beforeRecord {
        guard try readRecord(record.document.id)?.record == record else { throw BoomError.stale("Candidate producer has another actual captured full record.") }
        try validateRecord(record)
      } else { _ = try loadSnapshot(validateRecord: validateRecord); _ = try authenticateWorkspaceAuthority(before) }
    } else { guard try store.headID() == nil, try store.documentIDs().isEmpty else { throw BoomError.stale("Actual absent authority changed.") } }
    // This is a candidate-only producer disposition, never an inferred root
    // output or proof that those unused candidate rows committed. They remain.
    return execution.selectedBefore ? .before : .candidates
  }
  private func loadSnapshot(validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceSnapshot {
    let head = try readHead(); var records: [PagedDocumentRootRecord] = []; var charged = 0
    for (document, object) in try store.documentIDs() {
      let record = try readRecord(document, objectID: object)
      charged += record.encodedBytes
      guard charged <= 1_048_576 else { throw BoomError.budget("Cold SQL catalog exceeds its existing metadata byte bound.") }
      try validateRecord(record.record); records.append(record.record)
    }
    try match(records, workspace: head.workspace); return PagedWorkspaceSnapshot(head: head, documents: records)
  }
  private func readHead() throws -> PagedWorkspaceHead {
    guard let head = try store.authenticatedCurrentHead() else { throw BoomError.unavailable("SQLite head is absent; no empty fallback.") }
    return head
  }
  private func readRecord(_ documentID: UUID) throws -> (objectID: UUID, record: PagedDocumentRootRecord, encodedBytes: Int)? {
    guard let id = try store.recordID(documentID: documentID) else { return nil }
    return try readRecord(documentID, objectID: id)
  }
  private func readRecord(_ documentID: UUID, objectID: UUID) throws -> (objectID: UUID, record: PagedDocumentRootRecord, encodedBytes: Int) {
    try store.authenticatedRecord(documentID, objectID: objectID)
  }
  private func writeRecord(_ record: PagedDocumentRootRecord) throws -> UUID {
    try record.validate(); let id = UUID(), bytes = try JSONEncoder().encode(record)
    guard bytes.count <= 16_384 else { throw BoomError.budget("Immutable full record exceeds its fixed row bound.") }
    try store.insert(bytes, objectID: id, documentID: record.document.id, role: .documentRecord); return id
  }
  private func writeHead(_ head: PagedWorkspaceHead) throws {
    try head.validate(ownerID: ownerID); let bytes = try JSONEncoder().encode(head)
    guard bytes.count <= 4_096 else { throw BoomError.budget("SQL head exceeds its bounded object extent.") }
    try store.insert(bytes, objectID: head.headID, documentID: Vault.workspaceID, role: .head)
  }
  private func readPayload(_ reference: PagedWorkspaceObjectReference) throws -> WorkspaceState {
    try store.requireSourceAdmission(); try reference.validate(ownerID: ownerID)
    guard reference.layout == .workspaceState else { throw BoomError.denied("A settings-backed workspace has no whole WorkspaceState fallback.") }
    // Existing large compatibility decode remains an explicit consumer gap.
    var bytes = Data(); bytes.reserveCapacity(reference.plaintextBytes)
    for part in 0..<reference.partCount {
      let count = min(65_536, reference.plaintextBytes - bytes.count)
      let chunk = try store.read(objectID: reference.objectID, documentID: Vault.workspaceID,
        role: .workspace, maximumBytes: count, part: part)
      guard chunk.count == count else { throw BoomError.invalid("SQL workspace chunk extent changed.") }; bytes.append(chunk)
    }
    guard Digest.sha256(bytes) == reference.digest else { throw BoomError.invalid("SQL workspace payload digest changed.") }
    let object = try PropertyListDecoder().decode(PagedWorkspacePayloadObject.self, from: bytes)
    try object.validate(ownerID: ownerID, reference: reference); try store.requireSourceAdmission(); return object.state
  }
  private func admit(_ encoded: EncodedPagedWorkspace) throws {
    try store.requireQueue()
    guard encoded.vault === vault, encoded.ownerID == ownerID, encoded.bytes.count == encoded.reference.plaintextBytes else {
      throw BoomError.denied("Workspace encoding has another actual Vault/input owner.")
    }
    try encoded.reference.validate(ownerID: ownerID)
  }
  private func admit(_ prepared: PreparedPagedWorkspace) throws {
    try store.requireQueue()
    guard prepared.vault === vault, prepared.ownerID == ownerID, prepared.storeID == store.storeID else {
      throw BoomError.denied("Prepared workspace has another database incarnation.")
    }
    try prepared.reference.validate(ownerID: ownerID)
    // Preparation yielded between committed chunk quanta and publication.
    // Authenticate that exact immutable input again while this real outer
    // write transaction excludes replacement; do not decode/assemble it.
    try requireTransaction()
    try authenticatePreparedParts(prepared.reference)
  }
  private func authenticatePreparedParts(_ reference: PagedWorkspaceObjectReference) throws {
    try store.requireQueue(); try reference.validate(ownerID: ownerID)
    var digest = SHA256(), observedBytes = 0
    for part in 0..<reference.partCount {
      let remaining = reference.plaintextBytes - observedBytes
      let expected = min(65_536, remaining)
      guard expected > 0, observedBytes == part * 65_536 else {
        throw BoomError.invalid("Prepared SQL workspace part order/extent changed.")
      }
      let bytes = try store.read(objectID: reference.objectID, documentID: Vault.workspaceID,
        role: .workspace, maximumBytes: expected, part: part)
      guard bytes.count == expected else { throw BoomError.invalid("Prepared SQL workspace chunk extent changed after preparation.") }
      digest.update(data: bytes); observedBytes += bytes.count
    }
    let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard observedBytes == reference.plaintextBytes, actual == reference.digest else {
      throw BoomError.invalid("Prepared SQL workspace digest changed after preparation.")
    }
  }
  private func requireTransaction() throws {
    try store.requireQueue(); guard store.hasTransaction else { throw BoomError.denied("Publication requires the actual page-write transaction.") }
  }
  private func nextHead(_ before: PagedWorkspaceHead, workspace: PagedWorkspaceObjectReference) throws -> PagedWorkspaceHead {
    let next = before.generation.addingReportingOverflow(1)
    guard !next.overflow else { throw BoomError.budget("SQLite head generation exhausted.") }
    return PagedWorkspaceHead(ownerID: ownerID, storeID: store.storeID, generation: next.partialValue, workspace: workspace)
  }
  private func match(_ documents: [PagedDocumentRootRecord], workspace: PagedWorkspaceObjectReference) throws {
    for record in documents { try record.validate(); guard record.document.revision.ownerID == ownerID else { throw BoomError.denied("SQL inventory has another owner.") } }
    guard try PagedWorkspaceProjection.digest(documents.map { DocumentIndex(id: $0.document.id, title: $0.document.title) })
      == workspace.documentProjectionDigest else { throw BoomError.invalid("SQL workspace and document projection disagree.") }
  }
  private func monotonic(_ after: PagedDocumentRootRecord, before: PagedDocumentRootRecord?) throws {
    try after.validate()
    if let before, after.historyPage != before.historyPage || after.document.revision != before.document.revision {
      guard after.historyGeneration > before.historyGeneration else { throw BoomError.stale("SQL source/history change needs a newer generation.") }
    } else if let before, after.historyGeneration != before.historyGeneration { throw BoomError.invalid("SQL history epoch changed without an authenticated history object.") }
  }
}

/// Pure immutable preparation by this exact Publisher; no database write
/// has happened. This is never head/receiving/durability authority.
struct PreparedWorkspaceMetadata: Sendable {
  let inputID: UUID
  let settings: PagedWorkspaceObjectReference
  let entities: [WorkspaceEntityReference]
  let ownerID: UUID
  fileprivate let headers: [WorkspaceEntityHeader]
  fileprivate let settingsBytes: Data?
  fileprivate let vault: Vault
  fileprivate let storeID: UUID
}

extension PagedWorkspacePublisher {
  private func stageEntityBody(_ bytes: Data, entityID: UUID, objectID: UUID, part: Int) throws {
    try requireTransaction()
    guard bytes.count <= 65_536, part >= 0, part < 64 else { throw BoomError.budget("Metadata body staging exceeds its admitted chunk.") }
    try store.insert(bytes, objectID: objectID, documentID: entityID, role: .entityBody, part: part)
    guard try store.read(objectID: objectID, documentID: entityID, role: .entityBody,
      maximumBytes: 65_536, part: part) == bytes else { throw BoomError.invalid("Metadata body authenticated readback changed.") }
  }
  /// Pure bounded preparation on the existing utility worker. Nothing has
  /// been written or admitted as durable. All source buffers remain on Root.
  func prepareMetadata(_ input: WorkspaceMetadataInput,
    expectedHead: PagedWorkspaceHead?) throws -> PreparedWorkspaceMetadata {
    guard !Thread.isMainThread else { throw BoomError.invalid("Metadata preparation belongs off Main.") }
    if let expectedHead {
      try expectedHead.validate(ownerID: ownerID)
      guard expectedHead.storeID == store.storeID, expectedHead.workspace.layout == .settings,
        input.initialDocuments == nil else { throw BoomError.denied("Ordinary metadata cannot consume whole-workspace compatibility input.") }
    } else {
      guard input.settings != nil, input.initialDocuments != nil, input.documentChanges.isEmpty else { throw BoomError.invalid("Initial metadata requires its real settings and document records.") }
    }
    // Only owner-local scalar records can be removed by this first slice.
    // Other deletion callers must port their actual incoming-reference custody;
    // refusal preserves every original record instead of stranding references.
    guard input.removals.allSatisfy({ [.draft, .recordingDraft].contains($0.expected.kind) }) else {
      throw BoomError.unavailable("Entity removal awaits its real referring-owner port; original input retained.")
    }
    let settings: PagedWorkspaceObjectReference
    let settingsBytes: Data?
    if let value = input.settings {
      try value.admitScalars()
      let id = UUID(), bytes = try JSONEncoder().encode(PagedWorkspaceSettingsObject(ownerID: ownerID, objectID: id, settings: value))
      guard bytes.count <= WorkspaceSettings.maximumEncodedBytes else { throw BoomError.budget("Settings wrapper exceeds its actual16 KiB SQL row.") }
      let projection = try expectedHead?.workspace.documentProjectionDigest
        ?? PagedWorkspaceProjection.digest((input.initialDocuments ?? []).map { DocumentIndex(id: $0.document.id, title: $0.document.title) })
      settings = PagedWorkspaceObjectReference(layout: .settings, objectID: id, plaintextBytes: bytes.count,
        digest: Digest.sha256(bytes), documentProjectionDigest: projection)
      settingsBytes = bytes
    } else {
      guard let expectedHead else { throw BoomError.invalid("Initial metadata requires actual settings.") }
      settings = expectedHead.workspace; settingsBytes = nil
    }
    try settings.validate(ownerID: ownerID)
    var references: [WorkspaceEntityReference] = [], headers: [WorkspaceEntityHeader] = []
    for entity in input.entities {
      var bodies: [String: WorkspaceEntityBodyReference] = [:]
      for field in entity.bodies.keys.sorted() {
        guard let inputBody = entity.bodies[field] else { preconditionFailure("Immutable input field changed.") }
        var cursor = WorkspaceEntityBodyCursor(inputBody)
        while cursor.next() != nil {} // <=64 KiB scratch; never a whole body Data
        bodies[field] = try cursor.finish(objectID: UUID())
      }
      let header = try entity.header(bodies: bodies)
      references.append(WorkspaceEntityReference(id: entity.id, objectID: UUID(), logicalID: entity.logicalID,
        parentID: entity.parentID, kind: entity.kind, ordinal: entity.ordinal)); headers.append(header)
    }
    return PreparedWorkspaceMetadata(inputID: input.inputID, settings: settings, entities: references,
      ownerID: ownerID, headers: headers, settingsBytes: settingsBytes, vault: vault, storeID: store.storeID)
  }
  func publishMetadata(_ input: WorkspaceMetadataInput, prepared: PreparedWorkspaceMetadata,
    expectedHead: PagedWorkspaceHead?, validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> WorkspaceMetadataPublication {
    try requireTransaction()
    guard prepared.vault === vault, prepared.storeID == store.storeID, prepared.ownerID == ownerID,
      prepared.inputID == input.inputID, prepared.entities.count == input.entities.count,
      prepared.headers.count == input.entities.count,
      try store.authenticatedCurrentHead() == expectedHead, prepared.settings.layout == .settings else {
      throw BoomError.stale("Metadata publication has another actual input/store/full-head CAS.")
    }
    if expectedHead == nil {
      guard try store.documentIDs().isEmpty, try !store.hasEntityInventory() else { throw BoomError.stale("Initial metadata is not genuinely fresh.") }
    }
    if let bytes = prepared.settingsBytes {
      try store.insert(bytes, objectID: prepared.settings.objectID, documentID: Vault.workspaceID, role: .workspace)
      guard try store.read(objectID: prepared.settings.objectID, documentID: Vault.workspaceID, role: .workspace,
        maximumBytes: WorkspaceSettings.maximumEncodedBytes) == bytes else { throw BoomError.invalid("Settings authenticated readback changed.") }
    }
    var changes: [WorkspaceMetadataChange] = []
    for (index, entity) in input.entities.enumerated() {
      let reference = prepared.entities[index], header = prepared.headers[index]
      for field in entity.bodies.keys.sorted() {
        guard let inputBody = entity.bodies[field], let body = header.bodies[field] else { throw BoomError.stale("Prepared body field changed.") }
        var cursor = WorkspaceEntityBodyCursor(inputBody), part = 0
        while let bytes = cursor.next() {
          try stageEntityBody(bytes, entityID: reference.id, objectID: body.objectID, part: part); part += 1
        }
        guard try cursor.finish(objectID: body.objectID) == body else { throw BoomError.invalid("Source body differs from its immutable preparation.") }
      }
      let headerBytes = try JSONEncoder().encode(header)
      guard headerBytes.count <= WorkspaceEntityHeader.maximumBytes else { throw BoomError.budget("Entity header exceeds16 KiB.") }
      try store.insert(headerBytes, objectID: reference.objectID, documentID: reference.id, role: .entity)
      guard reference.id == entity.id, try store.entityReference(reference.id) == entity.expected else { throw BoomError.stale("Entity changed during metadata preparation.") }
      if let expected = entity.expected { _ = try store.authenticatedEntity(expected) }
      guard try store.authenticatedEntity(reference).header == header else { throw BoomError.invalid("Entity header authenticated readback changed.") }
      try authenticateEntityBodies(reference, header: header)
      try store.replaceEntity(reference, expected: entity.expected)
      changes.append(WorkspaceMetadataChange(before: entity.expected, after: reference))
    }
    for removal in input.removals {
      _ = try store.authenticatedEntity(removal.expected)
      try store.removeEntity(removal.expected)
      changes.append(WorkspaceMetadataChange(before: removal.expected, after: nil))
    }
    var documentChanges: [WorkspaceDocumentChange] = []
    if expectedHead == nil {
      guard let records = input.initialDocuments else { throw BoomError.invalid("Initial metadata lost its actual input records.") }
      try match(records, workspace: prepared.settings)
      var pointers: [(UUID, UUID)] = []
      for record in records {
        try validateRecord(record); pointers.append((record.document.id, try writeRecord(record)))
        documentChanges.append(WorkspaceDocumentChange(kind: .initial, before: nil, after: record,
          archiveBefore: nil, archiveAfter: nil, original: nil))
      }
      try store.replaceInventory(pointers)
    } else if input.initialDocuments != nil { throw BoomError.denied("An update cannot replace the whole inventory as initialization.") }
    else if !input.documentChanges.isEmpty { documentChanges = try publishDocumentChanges(input.documentChanges, validateRecord: validateRecord) }
    // Validate actual post-transaction links, including unchanged chat headers
    // whose message count is affected by this bounded update. No body decode.
    var chats = Set<UUID>()
    for reference in changes.compactMap({ $0.after }) {
      let header = try store.authenticatedEntity(reference).header
      try validateEntityLinks(header)
      if [.chat, .message, .messageVersion].contains(reference.kind) {
        chats.insert(reference.kind == .chat ? reference.logicalID : reference.parentID)
      }
    }
    for before in changes.compactMap({ $0.before }) {
      if [.message, .messageVersion].contains(before.kind) { chats.insert(before.parentID) }
      if before.kind == .chat, try store.entityByLogicalID(kind: .chat, logicalID: before.logicalID) == nil {
        guard try store.entityCount(kind: .message, parentID: before.logicalID) == 0,
          try store.entityCount(kind: .messageVersion, parentID: before.logicalID) == 0 else { throw BoomError.invalid("Chat removal cannot strand retained message records.") }
      }
    }
    for id in chats {
      if let reference = try store.entityByLogicalID(kind: .chat, logicalID: id) { try validateEntityLinks(store.authenticatedEntity(reference).header) }
    }
    var settings = prepared.settings
    if !input.documentChanges.isEmpty {
      let pointers = try store.documentIDs() // <=1,024 UUID pairs, library changes only
      let projection = try PagedWorkspaceProjection.digest(count: pointers.count) { index in
        let value = try self.store.authenticatedRecord(pointers[index].0, objectID: pointers[index].1).record
        return DocumentIndex(id: value.document.id, title: value.document.title)
      }
      settings = PagedWorkspaceObjectReference(layout: .settings, objectID: settings.objectID,
        plaintextBytes: settings.plaintextBytes, digest: settings.digest, documentProjectionDigest: projection)
    }
    let head = try expectedHead.map { try nextHead($0, workspace: settings) }
      ?? PagedWorkspaceHead(ownerID: ownerID, storeID: store.storeID, generation: 0, workspace: settings)
    _ = try readSettings(head)
    try writeHead(head); try store.replaceHead(objectID: head.headID, expected: expectedHead?.headID)
    _ = try store.recordPublication(before: expectedHead, after: head, beforeRecord: nil,
      afterRecord: nil, metadataChanges: changes, documentChanges: documentChanges)
    return WorkspaceMetadataPublication(head: head, changes: changes, documents: documentChanges)
  }
  func settingsRead() throws -> WorkspaceSettingsRead {
    try store.withReadSnapshot {
      let head = try readHead(); return WorkspaceSettingsRead(head: head, settings: try readSettings(head))
    }
  }
  func entityPage(kind: WorkspaceEntityKind, parentID: UUID, afterOrdinal: Int,
    expectedHead: PagedWorkspaceHead?) throws -> WorkspaceEntityPage {
    guard afterOrdinal == -1 || expectedHead != nil else { throw BoomError.stale("Continued entity page requires its actual captured head.") }
    return try store.withReadSnapshot {
      let head = try readHead()
      guard head.workspace.layout == .settings, expectedHead == nil || head == expectedHead else { throw BoomError.stale("Entity page has another full settings head.") }
      let pointers = try store.entityReferences(kind: kind, parentID: parentID, afterOrdinal: afterOrdinal,
        maximumRecords: WorkspaceMetadataInput.maximumEntities + 1)
      var values: [WorkspaceEntityRead] = []
      for reference in pointers.prefix(WorkspaceMetadataInput.maximumEntities) {
        let header = try store.authenticatedEntity(reference).header
        values.append(WorkspaceEntityRead(head: head, reference: reference, header: header))
      }
      return WorkspaceEntityPage(head: head, entities: values,
        nextOrdinal: pointers.count > WorkspaceMetadataInput.maximumEntities ? values.last?.reference.ordinal : nil)
    }
  }
  func entityRead(_ expected: WorkspaceEntityReference) throws -> WorkspaceEntityRead {
    try store.withReadSnapshot {
      let head = try readHead()
      guard head.workspace.layout == .settings, try store.entityReference(expected.id) == expected else { throw BoomError.stale("Selected entity changed while its caller awaited.") }
      return WorkspaceEntityRead(head: head, reference: expected, header: try store.authenticatedEntity(expected).header)
    }
  }
  func documentRead(_ documentID: UUID, expectedHead: PagedWorkspaceHead) throws -> WorkspaceDocumentRead {
    try store.withReadSnapshot {
      let head = try readHead()
      guard head == expectedHead, head.workspace.layout == .settings,
        let value = try readRecord(documentID) else { throw BoomError.stale("Selected document is absent or belongs to another full head.") }
      return WorkspaceDocumentRead(head: head, record: value.record)
    }
  }
  func draftRead(_ owner: ComposerOwner) throws -> WorkspaceEntityRead? {
    try store.withReadSnapshot {
      let head = try readHead()
      guard head.workspace.layout == .settings else { throw BoomError.denied("Draft opening requires row-scoped metadata.") }
      let ordinal = owner.kind == .document ? 0 : 1
      let pointers = try store.entityReferences(kind: .draft, parentID: owner.id, afterOrdinal: ordinal - 1, maximumRecords: 1)
      guard let reference = pointers.first, reference.ordinal == ordinal else { return nil } // actual SQL absence only
      let header = try store.authenticatedEntity(reference).header
      guard header.draftOwner == owner else { throw BoomError.denied("Draft belongs to another actual composer owner.") }
      try validateEntityLinks(header)
      return WorkspaceEntityRead(head: head, reference: reference, header: header)
    }
  }
  func entityBodyPart(_ expected: WorkspaceEntityReference, field: String, part: Int) throws -> Data {
    guard field.utf8.prefix(33).count <= 32 else { throw BoomError.invalid("Body field exceeds its fixed name bound.") }
    return try store.withReadSnapshot {
      let value = try entityRead(expected)
      guard let body = value.header.bodies[field], part >= 0, part < body.partCount else { throw BoomError.invalid("Entity body field/part is absent.") }
      let bytes = try store.read(objectID: body.objectID, documentID: expected.id, role: .entityBody, maximumBytes: 65_536, part: part)
      guard bytes.count == min(65_536, body.bytes - part * 65_536) else { throw BoomError.invalid("Entity body extent changed.") }
      // A part is an authenticated byte window, never a whole-text model grant.
      return bytes
    }
  }
  func admitMetadataPublication(_ output: WorkspaceMetadataPublication,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> PagedWorkspaceHead {
    try store.withReadSnapshot {
      let current = try readHead()
      guard current.ownerID == output.head.ownerID, current.storeID == output.head.storeID,
        current.generation >= output.head.generation, current.workspace == output.head.workspace else { throw BoomError.stale("Metadata receiving has another current settings authority.") }
      _ = try readSettings(current)
      try admitMetadataChanges(output.changes, after: true)
      try admitDocumentChanges(output.documents, after: true, validateRecord: validateRecord)
      // Unrelated native text seals may have advanced the actual head. This
      // returns that observation; it never rewrites the original normal output.
      return current
    }
  }
  private func archive(_ id: UUID) throws -> (WorkspaceEntityReference, WorkspaceDocumentArchive)? {
    guard let reference = try store.entityByLogicalID(kind: .documentArchive, logicalID: id) else { return nil }
    let header = try store.authenticatedEntity(reference).header
    let recordBytes = try header.bodies["record"].map {
      try self.store.read(objectID: $0.objectID, documentID: reference.id, role: .entityBody, maximumBytes: 8_192)
    }
    let value = try header.archivedDocument(recordBytes: recordBytes)
    try value.validate(documentID: id); return (reference, value)
  }
  func documentArchiveRead(_ id: UUID) throws -> WorkspaceDocumentArchiveRead? {
    try store.withReadSnapshot {
      let head = try readHead()
      guard let archived = try archive(id) else { return nil }
      return WorkspaceDocumentArchiveRead(head: head, reference: archived.0, archive: archived.1)
    }
  }
  private func retainedDocumentExists(_ id: UUID) throws -> Bool {
    if let object = try store.recordID(documentID: id) { _ = try store.authenticatedRecord(id, objectID: object); return true }
    return try archive(id)?.1.retainedRecord != nil
  }
  private func writeArchive(_ value: WorkspaceDocumentArchive, documentID: UUID,
    expected: WorkspaceEntityReference?) throws -> WorkspaceEntityReference {
    let input = try WorkspaceEntityInput.documentArchive(value, documentID: documentID, expected: expected)
    var bodies: [String: WorkspaceEntityBodyReference] = [:]
    for (field, body) in input.bodies {
      var cursor = WorkspaceEntityBodyCursor(body)
      let object = UUID(); var part = 0
      while let bytes = cursor.next() { try stageEntityBody(bytes, entityID: input.id, objectID: object, part: part); part += 1 }
      bodies[field] = try cursor.finish(objectID: object)
    }
    let header = try input.header(bodies: bodies)
    let reference = WorkspaceEntityReference(id: input.id, objectID: UUID(), logicalID: documentID,
      parentID: documentID, kind: .documentArchive, ordinal: 0)
    let bytes = try JSONEncoder().encode(header)
    guard bytes.count <= WorkspaceEntityHeader.maximumBytes else { throw BoomError.budget("Document archive exceeds its existing header envelope.") }
    try store.insert(bytes, objectID: reference.objectID, documentID: reference.id, role: .entity)
    guard try store.authenticatedEntity(reference).header == header else { throw BoomError.denied("Archive authenticated readback changed.") }
    try authenticateEntityBodies(reference, header: header)
    try store.replaceEntity(reference, expected: expected); try validateEntityLinks(header); return reference
  }
  private func publishDocumentChanges(_ input: [WorkspaceDocumentMutation],
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws -> [WorkspaceDocumentChange] {
    var pointers = try store.documentIDs(), output: [WorkspaceDocumentChange] = []
    for mutation in input {
      let id = mutation.documentID, position = pointers.firstIndex { $0.0 == id }
      let before = try position.map { try self.store.authenticatedRecord(id, objectID: pointers[$0].1).record }
      guard before == mutation.before else { throw BoomError.stale("Document mutation full-record CAS changed.") }
      if let before { try validateRecord(before) }
      let previous = try archive(id)
      guard previous?.1.retainedRecord == nil else { throw BoomError.stale("A trashed identity cannot be replaced or revived by insert/rename.") }
      let change: WorkspaceDocumentChange
      switch mutation.kind {
      case .insert:
        guard position == nil, previous == nil, let after = mutation.after, let original = mutation.original else { throw BoomError.stale("Insert requires absent active and archived identity.") }
        try validateRecord(after)
        let reference = try writeArchive(WorkspaceDocumentArchive(original: original, retainedRecord: nil), documentID: id, expected: nil)
        pointers.append((id, try writeRecord(after)))
        change = WorkspaceDocumentChange(kind: .insert, before: nil, after: after,
          archiveBefore: nil, archiveAfter: reference, original: original)
      case .rename:
        guard let position, let after = mutation.after else { throw BoomError.stale("Rename lost its real current pointer.") }
        try validateRecord(after); pointers[position].1 = try writeRecord(after)
        change = WorkspaceDocumentChange(kind: .rename, before: before, after: after,
          archiveBefore: previous?.0, archiveAfter: previous?.0, original: previous?.1.original)
      case .trash:
        guard let position, let before else { throw BoomError.stale("Trash lost its real current pointer.") }
        let reference = try writeArchive(WorkspaceDocumentArchive(original: previous?.1.original, retainedRecord: before),
          documentID: id, expected: previous?.0)
        pointers.remove(at: position)
        change = WorkspaceDocumentChange(kind: .trash, before: before, after: nil,
          archiveBefore: previous?.0, archiveAfter: reference, original: previous?.1.original)
      case .initial: throw BoomError.denied("Initialization is not an existing-workspace mutation.")
      }
      try change.validate(); output.append(change)
    }
    // Existing bounded pointer rewrite, one transaction; no full text/records
    // array and no second catalog publisher. Native character seals bypass it.
    try store.replaceInventory(pointers); return output
  }
  private func admitDocumentChanges(_ changes: [WorkspaceDocumentChange], after: Bool,
    validateRecord: (PagedDocumentRootRecord) throws -> Void) throws {
    guard changes.count <= WorkspaceMetadataInput.maximumEntities else { throw BoomError.budget("Document witness exceeds seven records.") }
    for change in changes {
      try change.validate()
      let selected = after ? change.after : change.before, id = change.documentID
      let actual = try readRecord(id)?.record
      guard actual == selected else { throw BoomError.stale("Document outcome has another exact active full record.") }
      if let selected { try validateRecord(selected) }
      let expected = after ? change.archiveAfter : change.archiveBefore, archived = try archive(id)
      guard archived?.0 == expected else { throw BoomError.stale("Document outcome archive pointer changed.") }
      if let archived {
        guard archived.1.original == change.original else { throw BoomError.denied("Imported original changed during receiving.") }
        let retained = after && change.kind == .trash ? change.before : nil
        guard archived.1.retainedRecord == retained else { throw BoomError.denied("Trash retained another source/history record.") }
        if let retained { try validateRecord(retained) }
      }
    }
  }
  private func admitMetadataChanges(_ changes: [WorkspaceMetadataChange], after: Bool) throws {
    guard changes.count <= 2 * WorkspaceMetadataInput.maximumEntities else { throw BoomError.budget("Metadata outcome witness exceeds its bound.") }
    for change in changes {
      guard let id = (change.before ?? change.after)?.id else { throw BoomError.invalid("Empty metadata change witness.") }
      let selected = after ? change.after : change.before
      guard try store.entityReference(id) == selected else { throw BoomError.stale("Metadata outcome has another exact entity pointer.") }
      if let selected {
        let header = try store.authenticatedEntity(selected).header
        if after { try authenticateEntityBodies(selected, header: header) }
      }
    }
  }
  private func authenticateWorkspaceAuthority(_ head: PagedWorkspaceHead) throws {
    if head.workspace.layout == .settings { _ = try readSettings(head) }
    else { _ = try readPayload(head.workspace) } // archived fixture route only; never ordinary metadata
  }
  private func readSettings(_ head: PagedWorkspaceHead) throws -> WorkspaceSettings {
    try head.validate(ownerID: ownerID)
    guard head.storeID == store.storeID, head.workspace.layout == .settings,
      head.workspace.plaintextBytes <= WorkspaceSettings.maximumEncodedBytes else { throw BoomError.denied("A bounded settings reader cannot decode a compatibility WorkspaceState.") }
    let bytes = try store.read(objectID: head.workspace.objectID, documentID: Vault.workspaceID, role: .workspace,
      maximumBytes: WorkspaceSettings.maximumEncodedBytes)
    guard bytes.count == head.workspace.plaintextBytes, Digest.sha256(bytes) == head.workspace.digest else { throw BoomError.denied("Settings immutable object/digest changed.") }
    let object = try JSONDecoder().decode(PagedWorkspaceSettingsObject.self, from: bytes)
    guard object.schema == 1, object.purpose == "bloom/paged-workspace/settings/v1", object.ownerID == ownerID,
      object.objectID == head.workspace.objectID else { throw BoomError.denied("Settings owner/object binding changed.") }
    try object.settings.validate(documentExists: { try self.store.recordID(documentID: $0) != nil },
      chatExists: { id in
        guard let reference = try self.store.entityByLogicalID(kind: .chat, logicalID: id) else { return false }
        _ = try self.store.authenticatedEntity(reference); return true
      })
    return object.settings
  }
  private func authenticateEntityBodies(_ reference: WorkspaceEntityReference, header: WorkspaceEntityHeader) throws {
    for body in header.bodies.values {
      var digest = SHA256(), observed = 0
      for part in 0..<body.partCount {
        let bytes = try store.read(objectID: body.objectID, documentID: reference.id, role: .entityBody, maximumBytes: 65_536, part: part)
        guard bytes.count == min(65_536, body.bytes - observed) else { throw BoomError.invalid("Metadata body part order/extent changed.") }
        digest.update(data: bytes); observed += bytes.count
      }
      guard observed == body.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == body.digest else {
        throw BoomError.denied("Metadata body authentication/digest changed after preparation.")
      }
    }
  }
  private func validateEntityLinks(_ header: WorkspaceEntityHeader) throws {
    try header.validateLinks(documentExists: { try self.retainedDocumentExists($0) },
      entityExists: { kind, id in
        guard let reference = try self.store.entityByLogicalID(kind: kind, logicalID: id) else { return false }
        _ = try self.store.authenticatedEntity(reference); return true
      }, entityCount: { try self.store.entityCount(kind: $0, parentID: $1) })
  }
}
