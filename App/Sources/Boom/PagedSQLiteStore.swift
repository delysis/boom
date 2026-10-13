import BoomCore
import CSQLite
import Darwin
import Foundation

/// Exact live connection binding; identities alone grant no receiving proof.
struct PagedSQLiteNativeReceivingIdentity: Sendable, Equatable {
  let ownerID: UUID
  let engineIncarnation: UUID
  let storeID: UUID
  let connectionIncarnation: UUID
  func admit(ownerID: UUID, engineIncarnation: UUID) throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard self.ownerID == ownerID, self.engineIncarnation == engineIncarnation,
      storeID != zero, connectionIncarnation != zero else {
      throw BoomError.denied("SQL receiving has another actual engine/store incarnation.")
    }
  }
}

/// Store-minted result of ONE actual call on this exact connection. It is held
/// only by the existing Root entry. No operation row, durable ACK ledger or
/// second copy of a failure lives in the Store.
struct PagedSQLiteOperationIdentity: Sendable, Equatable {
  let store: PagedSQLiteNativeReceivingIdentity
  let operationID: UUID
}
struct PagedSQLitePublication: Sendable, Equatable {
  let beforeHead: PagedWorkspaceHead?
  let afterHead: PagedWorkspaceHead
  let beforeRecord: PagedDocumentRootRecord?
  let afterRecord: PagedDocumentRootRecord?
  let metadataChanges: [WorkspaceMetadataChange]?
  let documentChanges: [WorkspaceDocumentChange]?
}
final class PagedSQLiteExecution: @unchecked Sendable {
  enum Kind: Sendable, Equatable { case write, format, checkpoint }
  enum Selection: Sendable, Equatable { case before, after, candidates, format, checkpoint }
  enum Outcome: Sendable, Equatable { case committed, rolledBack, unknown, resolved(Selection) }
  let identity: PagedSQLiteOperationIdentity
  let kind: Kind
  let beforeAdmitted: Bool
  let beforeHead: PagedWorkspaceHead?
  let beforeRecord: PagedDocumentRootRecord?
  let publication: PagedSQLitePublication?
  let commitEntered: Bool
  let outcome: Outcome
  let original: Error?
  let rollbackCode: Int32?
  let checkpoint: PagedSQLiteCheckpointResult?
  fileprivate init(identity: PagedSQLiteOperationIdentity, kind: Kind,
    beforeAdmitted: Bool, beforeHead: PagedWorkspaceHead?, beforeRecord: PagedDocumentRootRecord?,
    publication: PagedSQLitePublication?, commitEntered: Bool, outcome: Outcome,
    original: Error? = nil, rollbackCode: Int32? = nil, checkpoint: PagedSQLiteCheckpointResult? = nil) {
    self.identity = identity; self.kind = kind; self.beforeAdmitted = beforeAdmitted
    self.beforeHead = beforeHead; self.beforeRecord = beforeRecord; self.publication = publication
    self.commitEntered = commitEntered; self.outcome = outcome; self.original = original
    self.rollbackCode = rollbackCode; self.checkpoint = checkpoint
  }
  var selectedBefore: Bool { outcome == .rolledBack || outcome == .resolved(.before) }
  var selectedAfter: Bool { outcome == .committed || outcome == .resolved(.after) }
}
struct PagedSQLiteExecuted<Value> {
  let value: Value
  let execution: PagedSQLiteExecution
}
struct PagedSQLiteExecutionFailure: Error, LocalizedError {
  let execution: PagedSQLiteExecution
  var original: Error { execution.original ?? BoomError.unavailable("The SQL outcome remains unresolved.") }
  var errorDescription: String? { original.localizedDescription }
}
struct PagedSQLiteResolutionFailure: Error, LocalizedError {
  let execution: PagedSQLiteExecution
  let refusal: Error
  var errorDescription: String? {
    "\(execution.original?.localizedDescription ?? "The SQL outcome remains unresolved.") Resolution also refused: \(refusal.localizedDescription)"
  }
}
struct PagedSQLiteCheckpointResult: Sendable {
  let operationID: UUID
  let code: Int32
  let logFrames: Int32
  let copiedFrames: Int32
  let beforeWALBytes: Int64
  let afterWALBytes: Int64?
}
struct PagedSQLiteMaintenanceSnapshot: Sendable {
  let identity: PagedSQLiteNativeReceivingIdentity
  let observedWALBytes: Int64
  let checkpointRequested: Bool
  let lastCheckpoint: PagedSQLiteCheckpointResult?
  let failedOperationID: UUID?
}
private struct PagedSQLiteCheckpointFailure: Error, LocalizedError {
  let result: PagedSQLiteCheckpointResult
  var errorDescription: String? {
    "SQLite main TRUNCATE refused: code \(result.code), log \(result.logFrames), copied \(result.copiedFrames), WAL \(result.beforeWALBytes) -> \(result.afterWALBytes.map(String.init) ?? "unadmitted")."
  }
}

private struct PagedSQLiteCode: Error, LocalizedError {
  let code: Int32
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  // Supplementary observation only; code remains the original API result.
  var publicObservation: [String: String]? = nil
#endif
  var errorDescription: String? {
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
    if let publicObservation { return "SQLite storage returned code \(code). Public observation: \(publicObservation)" }
#endif
    return "SQLite storage returned code \(code)."
  }
}

private struct PagedSQLiteRollbackAdmissionFailure: Error, LocalizedError {
  let original: Error
  let admission: Error
  var errorDescription: String? {
    "\(original.localizedDescription) Post-rollback namespace admission also failed: \(admission.localizedDescription)."
  }
}

private struct PagedSQLiteCleanupFailure: Error, LocalizedError {
  enum Phase: String { case statementFinalize, readSnapshotRollback, rawPreflightClose, commitRepairRollback }
  let original: Error
  let phase: Phase
  let code: Int32
  var errorDescription: String? { "SQLite operation failed: \(original.localizedDescription). \(phase.rawValue) returned code \(code)." }
}

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
/// Real SQLite/OS faults, public nominated scratch only. No forged SQLite code,
/// fake ACK, VFS, replacement DB owner or success-returning test backend.
enum PagedSQLitePublicCommitFault: Sendable { case veto, moveDatabaseName }

struct PagedSQLPublicImmutableKeyRefusal: Error, Sendable {
  let operationID: UUID
  let objectID: UUID
  let part: Int
  let extendedCode: Int32
  let original: Error
  fileprivate init(operationID: UUID, objectID: UUID, part: Int, extendedCode: Int32, original: Error) {
    self.operationID = operationID; self.objectID = objectID; self.part = part
    self.extendedCode = extendedCode; self.original = original
  }
}

#endif

/// One connection, exclusively borrowed on the already-owned engine executor.
/// No actor, queue, ORM, VFS, key or external lock service is added. SQLite's
/// actual EXCLUSIVE WAL connection excludes other cooperating connections.
/// This is an explicit new-format prototype; opening existing data never creates.
final class PagedSQLiteStore: @unchecked Sendable {
  enum Opening: Sendable { case fresh(storeID: UUID), existing(storeID: UUID) }
  static let maximumTransactionRows = 4_096
  static let maximumTransactionBytes = 32 * 1_024 * 1_024
  static let maximumDocuments = PagedWorkspaceProjection.maximumDocuments
  static let walAdmissionBytes: Int64 = 64 * 1_024 * 1_024
  static let walMaintenanceBytes: Int64 = 32 * 1_024 * 1_024
  let ownerID: UUID
  let storeID: UUID
  private let vault: Vault
  private let engineIncarnation: UUID
  private let connectionIncarnation = UUID()
  var nativeReceivingIdentity: PagedSQLiteNativeReceivingIdentity {
    PagedSQLiteNativeReceivingIdentity(ownerID: ownerID, engineIncarnation: engineIncarnation,
      storeID: storeID, connectionIncarnation: connectionIncarnation)
  }
  private let queue: DispatchQueue
  private var rootFD: Int32
  private var directoryFD: Int32
  private var identity: (UInt64, UInt64) = (0, 0)
  private var path: String
  private let freshOpening: Bool
  private var openingStarted = false
  private var preflightFD: Int32 = -1
  private var preflightCloseFailure: Error?
  private var db: OpaquePointer?
  private var statements = 0
  // Set only after the actual authenticated format-row access acquired the
  // configured EXCLUSIVE WAL connection. A pragma result alone is not a lock.
  private var connectionPolicyAdmitted = false
  private var observedWALBytes: Int64 = 0
  private var checkpointRequested = false
  private var lastCheckpoint: PagedSQLiteCheckpointResult?
  private var inspectionDepth = 0
  private enum ReadSnapshotOwner: Equatable { case active(UUID), unresolved(UUID) }
  private var readSnapshotOwner: ReadSnapshotOwner?
  private struct Transaction {
    let operationID: UUID
    var beforeAdmitted = false
    var beforeHead: PagedWorkspaceHead?
    var beforeRecord: PagedDocumentRootRecord?
    var rows = 0
    var bytes = 0
    var publication: PagedSQLitePublication?
  }
  private var transactionState: Transaction?
  // Only the actual physical connection's fence. The original error, before /
  // after witnesses and output belong to ONE existing Root entry.
  private var refusedOperationID: UUID?
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  private var publicCommitFault: (fault: PagedSQLitePublicCommitFault, publicationsOnly: Bool)?
  private var publicDatabaseNameMoved = false
  private var publicDiagnosticOpenFlags: Int32?
  private var publicDiagnosticDuringConfigure = false
#endif
  private let freshOperationID = UUID()
  var openingOperationID: UUID? { freshOpening ? freshOperationID : nil }
  var hasTransaction: Bool { transactionState != nil }
  var transactionOperationID: UUID? { transactionState?.operationID }
  var failedOperationID: UUID? { refusedOperationID }

  /// Metadata-only construction. Engine installs this exact owner into its
  /// already-retained router BEFORE any file/connection opening can fail.
  init(vault: Vault, ownerID: UUID, engineIncarnation: UUID, queue: DispatchQueue, opening: Opening) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !Thread.isMainThread else { throw BoomError.invalid("SQLite opening must run off Main.") }
    let version = sqlite3_libversion_number()
    // Preserve the predecessor's explicit vendor/version admission.
    if version < 3_051_003 {
      if (version >= 3_044_006 && version < 3_045_000) || (version >= 3_050_007 && version < 3_051_000) {
        throw BoomError.unavailable("Known fixed SQLite backport requires a separately reviewed runtime admission.")
      }
      throw BoomError.unavailable("SQLite runtime/Apple vendor fix admission is unqualified; this does not classify older builds as unsafe.")
    }
    let id: UUID, fresh: Bool
    switch opening { case .fresh(let value): id = value; fresh = true; case .existing(let value): id = value; fresh = false }
    _ = try PagedSQLiteBinding(ownerID: ownerID, storeID: id, documentID: Vault.workspaceID,
      objectID: id, role: .format, part: 0, plaintextBytes: 1)
    self.vault = vault; self.ownerID = ownerID; self.engineIncarnation = engineIncarnation
    storeID = id; self.queue = queue; freshOpening = fresh
    rootFD = -1; directoryFD = -1
    path = vault.root.appendingPathComponent("paged-sqlite-v3/store.sqlite").path
  }
  var isSourceAdmitted: Bool {
    dispatchPrecondition(condition: .onQueue(queue)); return connectionPolicyAdmitted
  }
  /// One actual unexposed opening on the existing Engine queue/root job.
  /// Every real descriptor and SQLite out-pointer belongs to self immediately,
  /// including a non-OK sqlite3_open_v2 result with a nonnull connection.
  func openAndAdmit(report: (PagedSQLiteExecution) -> Void) throws {
    var formatExecution: PagedSQLiteExecution?
    dispatchPrecondition(condition: .onQueue(queue))
    guard !Thread.isMainThread, !openingStarted, !connectionPolicyAdmitted,
      rootFD == -1, directoryFD == -1, preflightFD == -1, db == nil else {
      throw BoomError.unavailable("The actual SQLite setup owner has already entered opening.")
    }
    openingStarted = true
    rootFD = Darwin.open(vault.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootFD >= 0 else { throw BoomError.invalid("Private SQLite root is unavailable.") }
    try Self.admitDirectory(rootFD)
    // Existing opening admits only an existing directory; no mkdir fallback.
    if freshOpening {
      let created = mkdirat(rootFD, "paged-sqlite-v3", mode_t(0o700)) == 0
      guard created || errno == EEXIST else { throw BoomError.unavailable("Could not create private SQLite storage.") }
      directoryFD = openat(rootFD, "paged-sqlite-v3", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard directoryFD >= 0 else { throw BoomError.invalid("Private SQLite storage contains an unsafe directory.") }
      // The descriptor is already in this actual owner before sync may fail;
      // no helper closes/forgets a local descriptor on its throwing path.
      if created, fsync(rootFD) != 0 { throw BoomError.unavailable("Could not synchronize private SQLite directory creation.") }
    } else { directoryFD = openat(rootFD, "paged-sqlite-v3", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    guard directoryFD >= 0 else { throw BoomError.invalid("Existing SQLite directory is unavailable; records retained.") }
    try Self.admitDirectory(directoryFD)
    let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (freshOpening ? O_CREAT | O_EXCL : 0)
    preflightFD = openat(directoryFD, "store.sqlite", flags, mode_t(0o600))
    guard preflightFD >= 0 else { throw BoomError.invalid("SQLite opening mode or file identity was refused.") }
    var before = stat()
    let statCode = fstat(preflightFD, &before), statErrno = errno
    let admissionFailure: Error? = statCode == 0 && Self.privateFile(before) ? nil
      : BoomError.invalid("Unsafe SQLite preflight file: stat \(statCode), errno \(statCode == 0 ? 0 : statErrno).")
    // Never close a bypass FD after SQLite opens. One actual close attempt is
    // recorded; failure cannot be retried by guessing whether its FD survived.
    let rawClose = Darwin.close(preflightFD)
    if rawClose != 0 {
      let savedErrno = errno
      let failure: Error
      if let admissionFailure {
        failure = PagedSQLiteCleanupFailure(original: admissionFailure, phase: .rawPreflightClose, code: savedErrno)
      } else {
        failure = BoomError.unavailable("Raw SQLite preflight close did not join: fd \(preflightFD), errno \(savedErrno).")
      }
      preflightCloseFailure = failure; throw failure
    }
    preflightFD = -1
    if let admissionFailure { throw admissionFailure }
    identity = (UInt64(truncatingIfNeeded: before.st_dev), UInt64(before.st_ino))
    // NOFOLLOW also rejects ancestor aliases. Resolve the admitted, existing
    // database with the OS and keep its literal path: Foundation can shorten
    // /private/var back to /var, reintroducing that symlink.
    guard let physical = Darwin.realpath(path, nil) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(physical) }
    guard let canonical = String(validatingCString: physical) else {
      throw BoomError.invalid("SQLite physical filename is not UTF-8.")
    }
    path = canonical
    // The actual pointer is stored BEFORE interpreting the return code. There
    // is no local `opened` pointer, ignored defer or close_v2 ownership gap.
    let sqliteOpenFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
    publicDiagnosticOpenFlags = sqliteOpenFlags
#endif
    let code = sqlite3_open_v2(path, &db, sqliteOpenFlags, nil)
    guard code == SQLITE_OK else { throw sqliteFailure(code, stage: "open") }
    guard db != nil else { throw BoomError.invalid("SQLite open returned success without its actual connection.") }
    var after = stat()
    guard fstatat(directoryFD, "store.sqlite", &after, AT_SYMLINK_NOFOLLOW) == 0,
      Self.privateFile(after), before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
      throw BoomError.stale("SQLite path changed while opening.")
    }
    try configure()
    if freshOpening {
      let result = try withTransaction(operationID: freshOperationID, creatingFormat: true) {
        try self.insert(Data("bloom/paged-sqlite/v3/document-archive-v1".utf8), objectID: storeID,
          documentID: Vault.workspaceID, role: .format)
      }
      formatExecution = result.execution; report(result.execution)
    } else {
      guard try integer("PRAGMA user_version") == 3 else { throw BoomError.invalid("Unsupported SQLite schema; records retained.") }
    }
    do {
      if freshOpening, fsync(directoryFD) != 0 { throw BoomError.unavailable("Initial database names did not synchronize.") }
      guard try read(objectID: storeID, documentID: Vault.workspaceID, role: .format, maximumBytes: 64)
        == Data("bloom/paged-sqlite/v3/document-archive-v1".utf8) else { throw BoomError.denied("SQLite incarnation or Vault key changed.") }
      try admit(); connectionPolicyAdmitted = true
    } catch {
      if let prior = formatExecution {
        let execution = PagedSQLiteExecution(identity: prior.identity, kind: .format,
          beforeAdmitted: prior.beforeAdmitted, beforeHead: prior.beforeHead, beforeRecord: nil,
          publication: nil, commitEntered: true, outcome: .unknown, original: error)
        refusedOperationID = prior.identity.operationID; report(execution)
        throw PagedSQLiteExecutionFailure(execution: execution)
      }
      throw error
    }

  }
  /// Physical cleanup of an UNEXPOSED partial opening, not source/receiving
  /// admission or durability repair. The installed Engine/router/root job owns
  /// self throughout; actual close refusal leaves connection and FDs intact.
  func closeUnexposedSetup() throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !Thread.isMainThread, !connectionPolicyAdmitted,
      statements == 0, inspectionDepth == 0 else {
      throw BoomError.unavailable("Unexposed SQL cleanup has an admitted or active source owner.")
    }
    if let preflightCloseFailure { throw preflightCloseFailure }
    guard preflightFD == -1 else { throw BoomError.unavailable("An actual raw preflight descriptor still owns setup.") }
    if let connection = db {
      let code = sqlite3_close(connection)
      guard code == SQLITE_OK else { throw PagedSQLiteCode(code: code) }
      db = nil // ONLY the actual checked close may clear a real connection.
    }
    // Nil here means no connection was allocated by the completed opening;
    // it is never an inferred native join or failed-COMMIT durability outcome.
  }
  deinit {
    // Only the joined Engine setup/normal close may release this owner. Its
    // retained callback context plus RootCustody keep every refused resource.
    // Do not turn an ignored deferred close_v2 into a claimed SQL join.
    assert(db == nil && preflightFD == -1, "Actual SQL/setup resources were dropped before their owner joined.")
    if directoryFD >= 0 { Darwin.close(directoryFD) }; if rootFD >= 0 { Darwin.close(rootFD) }
  }
  func belongs(to vault: Vault) -> Bool { self.vault === vault }
  func requireQueue() throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !Thread.isMainThread, db != nil else { throw BoomError.unavailable("SQLite owner is closed or on Main.") }
  }
  func close() throws {
    try requireCloseAdmission()
    guard let db else { throw BoomError.unavailable("SQLite is closed.") }
    let code = sqlite3_close(db)
    guard code == SQLITE_OK else { throw PagedSQLiteCode(code: code) }
    self.db = nil
  }
  func requireSourceAdmission() throws {
    try requireQueue()
    guard connectionPolicyAdmitted else { throw BoomError.unavailable("The actual EXCLUSIVE source opening has not joined.") }
    try admit()
  }
  func requireMaintenanceAdmission() throws {
    try requireSourceAdmission()
    guard refusedOperationID == nil, transactionState == nil, statements == 0,
      inspectionDepth == 0, readSnapshotOwner == nil, let db, sqlite3_get_autocommit(db) == 1 else {
      throw BoomError.unavailable("SQLite has an actual unjoined operation or snapshot.")
    }
  }
  func requireCloseAdmission() throws { try requireMaintenanceAdmission() }
  var needsWALMaintenance: Bool {
    dispatchPrecondition(condition: .onQueue(queue)); return checkpointRequested
  }
  var needsClosingMaintenance: Bool {
    dispatchPrecondition(condition: .onQueue(queue)); return observedWALBytes > 0 || checkpointRequested
  }
  func maintenanceSnapshot() throws -> PagedSQLiteMaintenanceSnapshot {
    try requireQueue()
    return PagedSQLiteMaintenanceSnapshot(identity: nativeReceivingIdentity,
      observedWALBytes: observedWALBytes, checkpointRequested: checkpointRequested,
      lastCheckpoint: lastCheckpoint, failedOperationID: refusedOperationID)
  }
  func requireObjectAccess() throws {
    try requireQueue()
    guard refusedOperationID == nil || inspectionDepth > 0 else { throw BoomError.unavailable("The exact failed SQL call remains fenced.") }
    if case .some(.unresolved(_)) = readSnapshotOwner { throw BoomError.unavailable("A read snapshot remains unresolved.") }
  }
  private func admit() throws {
    try requireObjectAccess()
    // The outer transaction admitted its connection/path before BEGIN and
    // rechecks after COMMIT. Do not issue filesystem metadata IO per tree page.
    if transactionState != nil { return }
    if case .some(.active(_)) = readSnapshotOwner { return }
    try Self.admitDirectory(rootFD); try Self.admitDirectory(directoryFD)
    var file = stat()
    guard fstatat(directoryFD, "store.sqlite", &file, AT_SYMLINK_NOFOLLOW) == 0, Self.privateFile(file),
      (UInt64(truncatingIfNeeded: file.st_dev), UInt64(file.st_ino)) == identity else {
      throw BoomError.stale("Owned SQLite path changed; records retained.")
    }
    for name in ["store.sqlite-wal", "store.sqlite-shm"] {
      var info = stat()
      if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        guard Self.privateFile(info) else { throw BoomError.denied("Unsafe SQLite companion file.") }
        if name == "store.sqlite-wal" {
          guard info.st_size >= 0 else { throw BoomError.invalid("Negative WAL extent.") }
          observedWALBytes = Int64(info.st_size)
          if observedWALBytes >= Self.walMaintenanceBytes { checkpointRequested = true }
        }
      } else if errno != ENOENT { throw BoomError.unavailable("SQLite companion identity is unresolved.") }
      else if name == "store.sqlite-wal" { observedWALBytes = 0 }
    }
  }

  func withTransaction<T>(operationID: UUID, expectedRecord: PagedDocumentRootRecord? = nil,
    creatingFormat: Bool = false, _ body: () throws -> T) throws -> PagedSQLiteExecuted<T> {
    try requireQueue()
    guard let db else { throw BoomError.unavailable("The actual SQL resource is closed.") }
    let operation = PagedSQLiteOperationIdentity(store: nativeReceivingIdentity, operationID: operationID)
    let kind: PagedSQLiteExecution.Kind = creatingFormat ? .format : .write
    var began = false, commitEntered = false
    var captured: Transaction?
    do {
      try admit()
      guard refusedOperationID == nil, inspectionDepth == 0, readSnapshotOwner == nil,
        transactionState == nil, sqlite3_get_autocommit(db) == 1 else {
        throw BoomError.invalid("SQL transactions cannot nest or cross an await.")
      }
      try admitWAL()
      transactionState = Transaction(operationID: operationID)
      try exec("BEGIN IMMEDIATE"); began = true
      if creatingFormat {
        guard freshOpening, operationID == freshOperationID, !connectionPolicyAdmitted,
          try integer("PRAGMA user_version") == 0,
          try integer("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0 else {
          throw BoomError.stale("Fresh format has another actual setup boundary.")
        }
        try exec(Self.schema); try exec("PRAGMA user_version=3")
      }
      let beforeHead = try authenticatedCurrentHead()
      let actualRecord = try expectedRecord.flatMap { try authenticatedCurrentRecord($0.document.id) }
      transactionState?.beforeHead = beforeHead; transactionState?.beforeRecord = actualRecord
      transactionState?.beforeAdmitted = true
      if let expectedRecord, actualRecord != expectedRecord {
        throw BoomError.stale("SQL transaction has another full source/history record.")
      }
      let value = try body()
      guard let state = transactionState else { throw BoomError.invalid("Actual transaction ownership disappeared.") }
      captured = state
      commitEntered = true
      try performCommit()
      guard sqlite3_get_autocommit(db) == 1 else { throw BoomError.unavailable("COMMIT returned with an owned transaction.") }
      transactionState = nil
      try admit()
      return PagedSQLiteExecuted(value: value, execution: PagedSQLiteExecution(identity: operation,
        kind: kind, beforeAdmitted: state.beforeAdmitted, beforeHead: state.beforeHead,
        beforeRecord: state.beforeRecord, publication: state.publication, commitEntered: true, outcome: .committed))
    } catch {
      if !began {
        // This call never entered its BEGIN/body/COMMIT. No foreign fence or
        // transaction is changed. Actual absence of entry proves this input
        // unpublished, but grants no source/namespace or durable output ACK.
        if transactionState?.operationID == operationID { transactionState = nil }
        throw PagedSQLiteExecutionFailure(execution: PagedSQLiteExecution(identity: operation,
          kind: kind, beforeAdmitted: false, beforeHead: nil, beforeRecord: nil,
          publication: nil, commitEntered: false, outcome: .rolledBack, original: error))
      }
      var original = error
      let state = transactionState ?? captured
      let rollback: Int32? = sqlite3_get_autocommit(db) == 0 ? sqlite3_exec(db, "ROLLBACK", nil, nil, nil) : nil
      transactionState = nil
      var knownBefore = !commitEntered && rollback == SQLITE_OK && sqlite3_get_autocommit(db) == 1
      if knownBefore {
        do { try admit() } catch { knownBefore = false; original = PagedSQLiteRollbackAdmissionFailure(original: original, admission: error) }
      }
      let execution = PagedSQLiteExecution(identity: operation, kind: kind,
        beforeAdmitted: state?.beforeAdmitted ?? false, beforeHead: state?.beforeHead,
        beforeRecord: state?.beforeRecord, publication: state?.publication, commitEntered: commitEntered,
        outcome: knownBefore ? .rolledBack : .unknown, original: original, rollbackCode: rollback)
      if !knownBefore { refusedOperationID = operationID }
      throw PagedSQLiteExecutionFailure(execution: execution)
    }
  }
  /// Pure in-transaction witness, held by the actual Root owner after COMMIT.
  /// This adds no operation record, index insertion, receipt encoding or sync.
  func recordPublication(before: PagedWorkspaceHead?, after: PagedWorkspaceHead,
    beforeRecord: PagedDocumentRootRecord?, afterRecord: PagedDocumentRootRecord?,
    metadataChanges: [WorkspaceMetadataChange]? = nil,
    documentChanges: [WorkspaceDocumentChange]? = nil) throws -> PagedSQLitePublication {
    try requireWrite()
    guard var state = transactionState, state.publication == nil,
      state.beforeAdmitted, state.beforeHead == before, state.beforeRecord == beforeRecord else {
      throw BoomError.stale("Publication changed the transaction's exact captured authority.")
    }
    try before?.validate(ownerID: ownerID); try after.validate(ownerID: ownerID)
    try beforeRecord?.validate(); try afterRecord?.validate()
    guard after.storeID == storeID, before?.storeID == nil || before?.storeID == storeID,
      (beforeRecord == nil && afterRecord == nil) || (beforeRecord?.document.id == afterRecord?.document.id),
      afterRecord == nil || afterRecord?.document.revision.ownerID == ownerID else {
      throw BoomError.denied("Publication has another exact owner/document.")
    }
    if let before {
      let next = before.generation.addingReportingOverflow(1)
      guard !next.overflow, after.generation == next.partialValue else { throw BoomError.stale("Publication head epoch changed.") }
    } else if after.generation != 0 { throw BoomError.invalid("Initial head epoch changed.") }
    if let metadataChanges {
      guard beforeRecord == nil, afterRecord == nil, metadataChanges.count <= 2 * WorkspaceMetadataInput.maximumEntities else {
        throw BoomError.invalid("Metadata publication exceeds its admitted change witness.")
      }
      for change in metadataChanges { try change.before?.validate(); try change.after?.validate() }
    }
    if let documentChanges {
      guard metadataChanges != nil, documentChanges.count <= WorkspaceMetadataInput.maximumEntities else { throw BoomError.budget("Document outcome exceeds seven exact changes.") }
      for change in documentChanges { try change.validate() }
      guard Set(documentChanges.map(\.documentID)).count == documentChanges.count else { throw BoomError.invalid("Duplicate document outcome witness.") }
    }
    let publication = PagedSQLitePublication(beforeHead: before, afterHead: after,
      beforeRecord: beforeRecord, afterRecord: afterRecord, metadataChanges: metadataChanges, documentChanges: documentChanges)
    state.publication = publication; transactionState = state; return publication
  }
  /// Resolve the retained actual result. Unknown COMMIT needs a checked main
  /// FULL-policy checkpoint plus identical authenticated authority on both
  /// sides. Known ROLLBACK and successful COMMIT never require this extra sync.
  /// The caller retains the returned result on the SAME Root entry before any
  /// continuation returns. This method never clears the physical fence.
  func resolve(_ prior: PagedSQLiteExecution,
    validate: () throws -> PagedSQLiteExecution.Selection) throws -> PagedSQLiteExecution {
    try requireQueue()
    guard prior.identity.store == nativeReceivingIdentity, transactionState == nil,
      statements == 0, readSnapshotOwner == nil, inspectionDepth == 0, let db,
      refusedOperationID == nil || refusedOperationID == prior.identity.operationID else {
      throw BoomError.stale("Resolution has another actual connection or unjoined operation.")
    }
    do {
      var cleanupRollback: Int32?
      if sqlite3_get_autocommit(db) == 0 {
        let code = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        cleanupRollback = code
        guard code == SQLITE_OK, sqlite3_get_autocommit(db) == 1 else {
          throw PagedSQLiteCleanupFailure(original: prior.original ?? BoomError.unavailable("SQL cleanup remains unjoined."), phase: .commitRepairRollback, code: code)
        }
      }
      let selected = try withOutcomeReads(prior) { try validate() }
      var checkpoint: PagedSQLiteCheckpointResult? = prior.checkpoint
      if prior.outcome == .unknown {
        if !prior.commitEntered, prior.kind == .write, selected == .before,
          prior.rollbackCode == SQLITE_OK || cleanupRollback == SQLITE_OK {
          // The actual checked rollback above (or the original one) plus the
          // selected BEFORE authority proves no entered COMMIT. No sync ritual.
          // This exact checked rollback, not autocommit alone, joined.
        } else {
          checkpoint = try withOutcomeCheckpoint(prior)
        }
        let after = try withOutcomeReads(prior) { try validate() }
        guard after == selected else { throw BoomError.stale("The exact selected SQL authority changed across sync.") }
      } else if prior.selectedBefore, selected != .before {
        throw BoomError.stale("The retained actual ROLLBACK differs from current authority.")
      } else if prior.selectedAfter, prior.publication != nil, selected != .after {
        throw BoomError.stale("The retained successful COMMIT differs from current authority.")
      }
      return PagedSQLiteExecution(identity: prior.identity, kind: prior.kind,
        beforeAdmitted: prior.beforeAdmitted, beforeHead: prior.beforeHead,
        beforeRecord: prior.beforeRecord, publication: prior.publication,
        commitEntered: prior.commitEntered, outcome: .resolved(selected), original: prior.original,
        rollbackCode: prior.rollbackCode, checkpoint: checkpoint)
    } catch { throw PagedSQLiteResolutionFailure(execution: prior, refusal: error) }
  }
  private func withOutcomeCheckpoint(_ execution: PagedSQLiteExecution) throws -> PagedSQLiteCheckpointResult {
    guard execution.identity.store == nativeReceivingIdentity, inspectionDepth == 0,
      transactionState == nil, readSnapshotOwner == nil else { throw BoomError.stale("Checkpoint has another actual entered owner.") }
    inspectionDepth += 1; defer { inspectionDepth -= 1 }
    return try truncateWAL(operationID: execution.identity.operationID)
  }
  func withOutcomeReads<T>(_ execution: PagedSQLiteExecution, _ body: () throws -> T) throws -> T {
    try requireQueue()
    guard execution.identity.store == nativeReceivingIdentity,
      refusedOperationID == nil || refusedOperationID == execution.identity.operationID,
      inspectionDepth == 0, transactionState == nil, readSnapshotOwner == nil else {
      throw BoomError.stale("Outcome reads have another exact connection/producer.")
    }
    inspectionDepth += 1; defer { inspectionDepth -= 1 }
    return try withReadSnapshot(body)
  }
  /// Only called after the real same-entry producer/consumer disposition has
  /// joined. This is one physical fence release, never an installation ACK.
  func releaseRefusal(_ execution: PagedSQLiteExecution) throws {
    try requireQueue()
    guard execution.identity.store == nativeReceivingIdentity,
      execution.outcome != .unknown, transactionState == nil, readSnapshotOwner == nil,
      inspectionDepth == 0, statements == 0 else { throw BoomError.stale("Actual SQL outcome has not joined.") }
    if let refusedOperationID {
      guard refusedOperationID == execution.identity.operationID else { throw BoomError.stale("Another actual SQL call owns the fence.") }
      self.refusedOperationID = nil
    }
  }
  func inspectFormat(_ execution: PagedSQLiteExecution) throws -> PagedSQLiteExecution.Selection {
    guard freshOpening, execution.kind == .format, execution.identity.operationID == freshOperationID else {
      throw BoomError.stale("Format inspection has another actual unexposed opening.")
    }
    let version = try integer("PRAGMA user_version")
    if version == 0 {
      guard try integer("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0 else { throw BoomError.stale("Unpublished format has partial schema.") }
      return .before
    }
    guard version == 3, try headID() == nil, try documentIDs().isEmpty, try !hasEntityInventory(),
      try read(objectID: storeID, documentID: Vault.workspaceID, role: .format, maximumBytes: 64)
        == Data("bloom/paged-sqlite/v3/document-archive-v1".utf8) else { throw BoomError.denied("Format differs from the exact actual opening.") }
    guard fsync(directoryFD) == 0 else { throw BoomError.unavailable("Actual fresh-format namespace did not synchronize.") }
    return .format
  }
  func acceptFormat(_ execution: PagedSQLiteExecution) throws {
    guard !connectionPolicyAdmitted, execution.outcome == .resolved(.format) else { throw BoomError.stale("Actual format receiving has another outcome.") }
    try releaseRefusal(execution); connectionPolicyAdmitted = true
  }

  /// Coherent short SQL read authority, released before any await. Reuses
  /// an existing outer write/read transaction on this same connection. Cold
  /// metadata decoding occurs outside the short head/catalog snapshot.
  func withReadSnapshot<T>(_ body: () throws -> T) throws -> T {
    try admit()
    if transactionState != nil { return try body() }
    if case .some(.active(_)) = readSnapshotOwner { return try body() }
    if case .some(.unresolved(_)) = readSnapshotOwner { throw BoomError.unavailable("An exact read snapshot remains unresolved.") }
    guard let db, sqlite3_get_autocommit(db) == 1 else { throw BoomError.unavailable("A prior read transaction remains unresolved.") }
    let identity = UUID(); readSnapshotOwner = .active(identity)
    do {
      try exec("BEGIN")
      let value = try body()
      try exec("ROLLBACK") // Read-only snapshot: no durable publication occurs.
      guard sqlite3_get_autocommit(db) == 1 else { throw BoomError.unavailable("SQL read snapshot did not join.") }
      readSnapshotOwner = nil; try admit(); return value
    } catch {
      let original = error
      let cleanup: Int32? = sqlite3_get_autocommit(db) == 0 ? sqlite3_exec(db, "ROLLBACK", nil, nil, nil) : nil
      if sqlite3_get_autocommit(db) == 1 { readSnapshotOwner = nil } else { readSnapshotOwner = .unresolved(identity) }
      // If release failed, retain the actual owner identity and refuse writes /
      // close. Never replace an earlier failed publication's identity/error.
      if let cleanup, cleanup != SQLITE_OK { throw PagedSQLiteCleanupFailure(original: original, phase: .readSnapshotRollback, code: cleanup) }
      throw original
    }
  }
  func insert(_ bytes: Data, objectID: UUID, documentID: UUID, role: PagedSQLiteRole, part: Int = 0) throws {
    try requireWrite(); guard var state = transactionState else { throw BoomError.denied("Immutable SQL writes require the actual outer transaction.") }
    let binding = try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: documentID,
      objectID: objectID, role: role, part: part, plaintextBytes: bytes.count)
    let charge = bytes.count + 28
    guard state.rows < Self.maximumTransactionRows, state.bytes <= Self.maximumTransactionBytes - charge else {
      throw BoomError.budget("Bounded SQLite transaction exceeds its admitted rows or encrypted bytes.")
    }
    let sealed = try vault.sealPagedSQLiteObject(bytes, binding: binding)
    try statement("INSERT INTO objects(object_id,part,document_id,role,plain_bytes,ciphertext) VALUES(?,?,?,?,?,?)") { sql in
      try bind(objectID, sql, 1); try bind(part, sql, 2); try bind(documentID, sql, 3)
      try bind(Int(role.rawValue), sql, 4); try bind(bytes.count, sql, 5); try bind(sealed, sql, 6); try done(sql)
    }
    state.rows += 1; state.bytes += charge; transactionState = state
  }
  func read(objectID: UUID, documentID: UUID, role: PagedSQLiteRole, maximumBytes: Int, part: Int = 0) throws -> Data {
    try requireObjectAccess(); guard maximumBytes >= 0, maximumBytes <= role.maximumBytes else { throw BoomError.budget("SQL read exceeds its row bound.") }
    return try statement("SELECT plain_bytes,ciphertext FROM objects WHERE object_id=? AND part=? AND document_id=? AND role=?") { sql in
      try bind(objectID, sql, 1); try bind(part, sql, 2); try bind(documentID, sql, 3); try bind(Int(role.rawValue), sql, 4)
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_INTEGER else { throw BoomError.invalid("Immutable SQL object is absent or malformed.") }
      let count = sqlite3_column_int64(sql, 0)
      guard count >= 0, count <= maximumBytes else { throw BoomError.budget("SQL plaintext exceeds the admitted read before allocation.") }
      let encrypted = try blob(sql, 1, maximumBytes: maximumBytes + 28)
      guard encrypted.count == Int(count) + 28 else { throw BoomError.invalid("SQL ciphertext extent changed.") }
      try end(sql)
      let binding = try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: documentID,
        objectID: objectID, role: role, part: part, plaintextBytes: Int(count))
      return try vault.openPagedSQLiteObject(encrypted, binding: binding)
    }
  }
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
  func _publicArmCommitFault(identity: PagedSQLPublicControlIdentity,
    fault: PagedSQLitePublicCommitFault) throws {
    try identity.admitConnection(self)
    guard vault.root.lastPathComponent.hasPrefix("public-sql-durability-"), publicCommitFault == nil,
      !publicDatabaseNameMoved, refusedOperationID == nil else { throw BoomError.denied("Actual public scratch fault admission refused.") }
    try withReadSnapshot { try self.publicControlReadAdmission() }
    publicCommitFault = (fault, true) // only the actual publication transaction; no SQL mutation
  }
  func _publicArmSetupFault(_ fault: PagedSQLitePublicCommitFault) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard freshOpening, !openingStarted, publicCommitFault == nil,
      vault.root.lastPathComponent.hasPrefix("public-sql-durability-") else { throw BoomError.denied("Fresh public setup fault requires exact unexposed scratch.") }
    publicCommitFault = (fault, false)
  }
  func _publicRestoreDatabaseName(identity: PagedSQLPublicControlIdentity) throws {
    try identity.admitConnection(self); try restorePublicDatabaseName()
  }
  func _publicRestoreFailedSetupName() throws {
    guard freshOpening, !connectionPolicyAdmitted else { throw BoomError.denied("Setup name restoration cannot target exposed source.") }
    try restorePublicDatabaseName()
  }
  private func restorePublicDatabaseName() throws {
    try requireQueue()
    guard publicDatabaseNameMoved, refusedOperationID != nil,
      statements == 0, transactionState == nil, inspectionDepth == 0, readSnapshotOwner == nil else {
      throw BoomError.stale("Public name restoration has another original failed SQL operation.")
    }
    try Self.admitDirectory(rootFD); try Self.admitDirectory(directoryFD)
    var original = stat(), missing = stat()
    guard fstatat(directoryFD, "public-moved.sqlite", &original, AT_SYMLINK_NOFOLLOW) == 0,
      Self.privateFile(original), (UInt64(truncatingIfNeeded: original.st_dev), UInt64(original.st_ino)) == identity,
      fstatat(directoryFD, "store.sqlite", &missing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
      throw BoomError.stale("Only the actual moved scratch inode can restore its prior name.")
    }
    guard renameat(directoryFD, "public-moved.sqlite", directoryFD, "store.sqlite") == 0 else {
      throw BoomError.unavailable("Actual scratch name restoration refused, errno \(errno).")
    }
    publicDatabaseNameMoved = false
    // Fence remains; successful filesystem restoration is NOT durability or ACK.
  }
  // Test-build helpers borrow this exact admitted connection. They do not
  // open descriptors/connections, authenticate another key or release fences.
  func _publicControlCurrentRecord(identity: PagedSQLPublicControlIdentity, documentID: UUID) throws -> PagedDocumentRootRecord? {
    try identity.admitConnection(self)
    try publicControlReadAdmission()
    return try authenticatedCurrentRecord(documentID)
  }
  func _publicControlCiphertext(identity: PagedSQLPublicControlIdentity, page: PagedTextPageRef, documentID: UUID) throws -> Data {
    try identity.admitConnection(self)
    try publicControlReadAdmission()
    try page.validate(maximumPlaintextBytes: PagedRootHistoryStore.segmentBytes); try page.locator.admit(storeID: storeID)
    let encrypted: Data = try statement("SELECT plain_bytes,ciphertext FROM objects WHERE object_id=? AND part=0 AND document_id=? AND role=2") { sql in
      try bind(page.locator.recordID, sql, 1); try bind(documentID, sql, 2)
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_INTEGER else { throw BoomError.invalid("Public index row is unavailable.") }
      let count = sqlite3_column_int64(sql, 0)
      guard count >= 0, count <= PagedRootHistoryStore.segmentBytes,
        count + 28 == Int64(page.locator.ciphertextBytes) else { throw BoomError.budget("Public index ciphertext extent changed before allocation.") }
      let bytes = try blob(sql, 1, maximumBytes: PagedRootHistoryStore.segmentBytes + 28)
      guard bytes.count == Int(count) + 28 else { throw BoomError.invalid("Public index row has another exact extent.") }
      try end(sql); return bytes
    }
    let binding = try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: documentID,
      objectID: page.locator.recordID, role: .index, part: 0, plaintextBytes: encrypted.count - 28)
    let plaintext = try vault.openPagedSQLiteObject(encrypted, binding: binding)
    guard Digest.sha256(plaintext) == page.digest else { throw BoomError.denied("Public ciphertext is not the authenticated PageRef.") }
    return encrypted
  }
  func _publicControlRequireCurrentRecord(identity: PagedSQLPublicControlIdentity, expected: PagedDocumentRootRecord?, documentID: UUID) throws {
    try identity.admitConnection(self)
    try requireWrite()
    guard refusedOperationID == nil, try authenticatedCurrentRecord(documentID) == expected else { throw BoomError.stale("Public mutation lost its exact authenticated current-record anchor.") }
  }
  func _publicControlReplaceCiphertext(identity: PagedSQLPublicControlIdentity, page: PagedTextPageRef, documentID: UUID, original: Data, replacement: Data) throws {
    try identity.admitConnection(self)
    try requireWrite()
    try page.validate(maximumPlaintextBytes: PagedRootHistoryStore.segmentBytes); try page.locator.admit(storeID: storeID)
    guard refusedOperationID == nil, original.count == Int(page.locator.ciphertextBytes), replacement.count == original.count,
      replacement.count >= 28, replacement.count <= PagedRootHistoryStore.segmentBytes + 28,
      var state = transactionState, state.rows < Self.maximumTransactionRows,
      replacement.count <= Self.maximumTransactionBytes - state.bytes else { throw BoomError.budget("Public row mutation exceeds its exact ciphertext/transaction bounds.") }
    state.rows += 1; state.bytes += replacement.count; transactionState = state
    // Exact row + original ciphertext CAS. No source/head/history pointer or
    // receiving/root-custody state is modified by this controlled tag flip.
    try statement("UPDATE objects SET ciphertext=? WHERE object_id=? AND part=0 AND document_id=? AND role=2 AND plain_bytes=? AND ciphertext=?") { sql in
      try bind(replacement, sql, 1); try bind(page.locator.recordID, sql, 2); try bind(documentID, sql, 3)
      try bind(original.count - 28, sql, 4); try bind(original, sql, 5); try done(sql)
    }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("Public ciphertext row CAS was refused.") }
  }
  /// Fixed Publisher targets from an actually authenticated current head. No
  /// arbitrary row/role/key is exposed; extents follow the real writer caps.
  func _publicControlWorkspaceCiphertext(identity: PagedSQLPublicControlIdentity,
    head: PagedWorkspaceHead, record: PagedDocumentRootRecord?, target: PagedSQLPublicWorkspaceCiphertextTarget)
    throws -> (objectID: UUID, documentID: UUID, role: PagedSQLiteRole, part: Int, ciphertext: Data) {
    try identity.admitConnection(self); try publicControlReadAdmission()
    try head.validate(ownerID: ownerID)
    guard head.storeID == storeID, try authenticatedCurrentHead() == head else {
      throw BoomError.stale("Public Publisher witness has another exact authenticated head.")
    }
    if let record {
      try record.validate()
      guard try authenticatedCurrentRecord(record.document.id) == record else {
        throw BoomError.stale("Public Publisher witness has another full document record.")
      }
    }
    let objectID: UUID, documentID: UUID, role: PagedSQLiteRole, part: Int, maximum: Int
    switch target {
    case .workspacePart(let selected):
      guard selected >= 0, selected < head.workspace.partCount else { throw BoomError.invalid("Public workspace part is outside its authenticated reference.") }
      objectID = head.workspace.objectID; documentID = Vault.workspaceID; role = .workspace; part = selected
      maximum = min(65_536, head.workspace.plaintextBytes - selected * 65_536)
    case .documentRecord:
      guard let record, let pointer = try recordID(documentID: record.document.id) else {
        throw BoomError.denied("Public document row needs its actual full record/pointer.")
      }
      objectID = pointer; documentID = record.document.id; role = .documentRecord; part = 0; maximum = 16_384
    case .head:
      objectID = head.headID; documentID = Vault.workspaceID; role = .head; part = 0; maximum = 4_096
    }
    let encrypted: Data = try statement("SELECT plain_bytes,ciphertext FROM objects WHERE object_id=? AND part=? AND document_id=? AND role=?") { sql in
      try bind(objectID, sql, 1); try bind(part, sql, 2); try bind(documentID, sql, 3); try bind(Int(role.rawValue), sql, 4)
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_INTEGER else { throw BoomError.invalid("Public Publisher row is absent.") }
      let count = sqlite3_column_int64(sql, 0)
      guard count > 0, count <= maximum, role != .workspace || count == maximum else {
        throw BoomError.budget("Public Publisher row exceeds its exact writer/reference extent before allocation.")
      }
      let bytes = try blob(sql, 1, maximumBytes: maximum + 28)
      guard bytes.count == Int(count) + 28 else { throw BoomError.invalid("Public Publisher ciphertext has another extent.") }
      try end(sql); return bytes
    }
    let binding = try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: documentID,
      objectID: objectID, role: role, part: part, plaintextBytes: encrypted.count - 28)
    let bytes = try vault.openPagedSQLiteObject(encrypted, binding: binding)
    if role == .head {
      guard try JSONDecoder().decode(PagedWorkspaceHead.self, from: bytes) == head else { throw BoomError.denied("Public head ciphertext differs from its authenticated anchor.") }
    } else if role == .documentRecord {
      guard let record, try JSONDecoder().decode(PagedDocumentRootRecord.self, from: bytes) == record else { throw BoomError.denied("Public document ciphertext differs from its full-record anchor.") }
    }
    return (objectID, documentID, role, part, encrypted)
  }
  /// The caller separately admits the exact live known-successful corruption
  /// producer. Later real character publication may reuse this payload; this
  /// ciphertext CAS neither grants a native ACK nor settles a failed operation.
  /// Known ciphertext CAS only. Current head and fixed pointer must still name
  /// the original row; the original live witness authenticates its full record
  /// even while the deliberately changed tag is unreadable. Head mutation is
  /// refused, because ordinary BEGIN admission must authenticate that head.
  func _publicControlReplaceWorkspaceCiphertext(identity: PagedSQLPublicControlIdentity,
    expectedHead: PagedWorkspaceHead, originalHead: PagedWorkspaceHead, record: PagedDocumentRootRecord?,
    target: PagedSQLPublicWorkspaceCiphertextTarget, objectID: UUID, documentID: UUID, role: PagedSQLiteRole, part: Int,
    original: Data, replacement: Data) throws {
    try identity.admitConnection(self); try requireWrite()
    guard failedOperationID == nil, try authenticatedCurrentHead() == expectedHead,
      expectedHead.workspace == originalHead.workspace, expectedHead.storeID == originalHead.storeID,
      replacement.count == original.count,
      replacement.count >= 28, replacement.count <= PagedSQLPublicWorkspaceCiphertextWitness.maximumCiphertextBytes,
      var state = transactionState, state.rows < Self.maximumTransactionRows,
      replacement.count <= Self.maximumTransactionBytes - state.bytes else {
      throw BoomError.stale("Public Publisher row mutation lost its actual head/extent/transaction admission.")
    }
    switch target {
    case .workspacePart(let selected):
      guard role == .workspace, documentID == Vault.workspaceID,
        objectID == expectedHead.workspace.objectID, part == selected,
        selected >= 0, selected < expectedHead.workspace.partCount,
        replacement.count == min(65_536, expectedHead.workspace.plaintextBytes - selected * 65_536) + 28 else {
        throw BoomError.denied("Public payload mutation has another authenticated fixed part.")
      }
    case .documentRecord:
      guard let record, role == .documentRecord, part == 0,
        documentID == record.document.id, replacement.count <= 16_384 + 28,
        try recordID(documentID: record.document.id) == objectID else {
        throw BoomError.denied("Public document mutation lost its original full-record pointer.")
      }
    case .head: throw BoomError.denied("Public head mutation cannot bypass normal authenticated transaction admission.")
    }
    state.rows += 1; state.bytes += replacement.count; transactionState = state
    try statement("UPDATE objects SET ciphertext=? WHERE object_id=? AND part=? AND document_id=? AND role=? AND plain_bytes=? AND ciphertext=?") { sql in
      try bind(replacement, sql, 1); try bind(objectID, sql, 2); try bind(part, sql, 3)
      try bind(documentID, sql, 4); try bind(Int(role.rawValue), sql, 5)
      try bind(original.count - 28, sql, 6); try bind(original, sql, 7); try done(sql)
    }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("Public Publisher ciphertext CAS was refused.") }
  }

  func _publicControlRestagePreparedPart(identity: PagedSQLPublicControlIdentity,
    reference: PagedWorkspaceObjectReference, part: Int) throws -> String {
    try identity.admitConnection(self); try requireWrite(); try reference.validate(ownerID: ownerID)
    guard part >= 0, part < reference.partCount,
      reference.plaintextBytes <= PagedSQLPublicPreparedWorkspace.maximumEncodedBytes,
      let state = transactionState else { throw BoomError.denied("Immutable-key control lost its actual prepared part/transaction.") }
    let maximum = min(65_536, reference.plaintextBytes - part * 65_536)
    let bytes = try read(objectID: reference.objectID, documentID: Vault.workspaceID,
      role: .workspace, maximumBytes: maximum, part: part)
    guard bytes.count == maximum else { throw BoomError.invalid("Actual duplicate-key input has another extent.") }
    do {
      try insert(bytes, objectID: reference.objectID, documentID: Vault.workspaceID, role: .workspace, part: part)
    } catch {
      let original = error
      let code: Int32?
      if let observed = original as? PagedSQLiteCode { code = observed.code }
      else if let cleanup = original as? PagedSQLiteCleanupFailure,
        let observed = cleanup.original as? PagedSQLiteCode { code = observed.code }
      else { code = nil }
      guard let code, code & 0xff == SQLITE_CONSTRAINT else { throw original }
      throw PagedSQLPublicImmutableKeyRefusal(operationID: state.operationID, objectID: reference.objectID,
        part: part, extendedCode: code, original: original)
    }
    return Digest.sha256(bytes) // only if SQLite admitted duplicate immutable key
  }

  func _publicControlPreparedPartCiphertext(identity: PagedSQLPublicControlIdentity,
    reference: PagedWorkspaceObjectReference, part: Int) throws -> Data {
    try identity.admitConnection(self); try publicControlReadAdmission(); try reference.validate(ownerID: ownerID)
    guard reference.plaintextBytes <= PagedSQLPublicPreparedWorkspace.maximumEncodedBytes,
      part >= 0, part < reference.partCount, try headID() == nil, try documentIDs().isEmpty else {
      throw BoomError.denied("Public prepared ciphertext has another actual unpublished reference/head.")
    }
    let count = min(65_536, reference.plaintextBytes - part * 65_536)
    let encrypted: Data = try statement("SELECT plain_bytes,ciphertext FROM objects WHERE object_id=? AND part=? AND document_id=? AND role=3") { sql in
      try bind(reference.objectID, sql, 1); try bind(part, sql, 2); try bind(Vault.workspaceID, sql, 3)
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_INTEGER,
        sqlite3_column_int64(sql, 0) == Int64(count) else { throw BoomError.invalid("Actual prepared ciphertext part extent changed.") }
      let bytes = try blob(sql, 1, maximumBytes: count + 28)
      guard bytes.count == count + 28 else { throw BoomError.invalid("Actual prepared ciphertext has another exact extent.") }
      try end(sql); return bytes
    }
    let binding = try PagedSQLiteBinding(ownerID: ownerID, storeID: storeID, documentID: Vault.workspaceID,
      objectID: reference.objectID, role: .workspace, part: part, plaintextBytes: count)
    _ = try vault.openPagedSQLiteObject(encrypted, binding: binding)
    return encrypted
  }
  func _publicControlReplacePreparedPartCiphertext(identity: PagedSQLPublicControlIdentity,
    reference: PagedWorkspaceObjectReference, part: Int, original: Data, replacement: Data) throws {
    try identity.admitConnection(self); try requireWrite(); try reference.validate(ownerID: ownerID)
    guard failedOperationID == nil, reference.plaintextBytes <= PagedSQLPublicPreparedWorkspace.maximumEncodedBytes,
      part >= 0, part < reference.partCount, try headID() == nil, try documentIDs().isEmpty else {
      throw BoomError.denied("Prepared mutation lost its actual unpublished reference/head/connection.")
    }
    let count = min(65_536, reference.plaintextBytes - part * 65_536)
    guard original.count == count + 28, replacement.count == original.count,
      var state = transactionState, state.rows < Self.maximumTransactionRows,
      replacement.count <= Self.maximumTransactionBytes - state.bytes else {
      throw BoomError.budget("Prepared ciphertext CAS exceeds its exact part/transaction bound.")
    }
    state.rows += 1; state.bytes += replacement.count; transactionState = state
    try statement("UPDATE objects SET ciphertext=? WHERE object_id=? AND part=? AND document_id=? AND role=3 AND plain_bytes=? AND ciphertext=?") { sql in
      try bind(replacement, sql, 1); try bind(reference.objectID, sql, 2); try bind(part, sql, 3)
      try bind(Vault.workspaceID, sql, 4); try bind(count, sql, 5); try bind(original, sql, 6); try done(sql)
    }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("Prepared ciphertext CAS was refused.") }
  }

  private func publicControlReadAdmission() throws {
    try admit()
    guard refusedOperationID == nil, inspectionDepth == 0 else { throw BoomError.unavailable("Public control cannot bypass an exact failed SQL operation.") }
    if transactionState == nil {
      guard case .some(.active(_)) = readSnapshotOwner else { throw BoomError.denied("Public control requires the real coherent read snapshot.") }
    }
  }
#endif

  func authenticatedCurrentHead() throws -> PagedWorkspaceHead? {
    guard let id = try headID() else { return nil }
    let bytes = try read(objectID: id, documentID: Vault.workspaceID, role: .head, maximumBytes: 4_096)
    let head = try JSONDecoder().decode(PagedWorkspaceHead.self, from: bytes); try head.validate(ownerID: ownerID)
    guard head.storeID == storeID, head.headID == id else { throw BoomError.denied("SQL before-head identity changed.") }
    return head
  }
  private func authenticatedCurrentRecord(_ document: UUID) throws -> PagedDocumentRootRecord? {
    guard let id = try recordID(documentID: document) else { return nil }
    return try authenticatedRecord(document, objectID: id).record
  }
  /// The single bounded full-record row decoder used by transaction admission
  /// and publisher catalog reads. encodedBytes remains the real catalog charge.
  func authenticatedRecord(_ document: UUID, objectID: UUID) throws -> (objectID: UUID, record: PagedDocumentRootRecord, encodedBytes: Int) {
    let bytes = try read(objectID: objectID, documentID: document, role: .documentRecord, maximumBytes: 16_384)
    let record = try JSONDecoder().decode(PagedDocumentRootRecord.self, from: bytes); try record.validate()
    guard record.document.id == document, record.document.revision.ownerID == ownerID else { throw BoomError.denied("SQL full-record identity changed.") }
    return (objectID, record, bytes.count)
  }
  func headID() throws -> UUID? { try admit(); return try pointer("SELECT object_id FROM current_head WHERE singleton=1") }
  func recordID(documentID: UUID) throws -> UUID? {
    try admit(); return try statement("SELECT object_id FROM documents WHERE document_id=?") { sql in
      try bind(documentID, sql, 1); guard try row(sql) else { return nil }; let id = try uuid(sql, 0); try end(sql); return id
    }
  }
  func documentIDs() throws -> [(UUID, UUID)] {
    try admit(); return try statement("SELECT document_id,object_id FROM documents ORDER BY ordinal") { sql in
      var result: [(UUID, UUID)] = []; result.reserveCapacity(Self.maximumDocuments)
      while try row(sql) {
        guard result.count < Self.maximumDocuments else { throw BoomError.budget("SQLite inventory exceeds its explicit catalog bound.") }
        result.append((try uuid(sql, 0), try uuid(sql, 1)))
      }
      return result
    }
  }
  /// One actual SQL cursor page. No complete catalog or workspace payload is
  /// allocated; the caller still authenticates each immutable record object.
  func documentIDs(afterOrdinal: Int, maximumRecords: Int)
    throws -> [(ordinal: Int, documentID: UUID, objectID: UUID)] {
    guard afterOrdinal >= -1, afterOrdinal < Self.maximumDocuments,
      maximumRecords > 0, maximumRecords <= PagedDocumentIndexPage.maximumRecords + 1 else {
      throw BoomError.budget("Invalid bounded document-index cursor.")
    }
    try admit()
    return try statement("SELECT ordinal,document_id,object_id FROM documents WHERE ordinal>? ORDER BY ordinal LIMIT ?") { sql in
      try bind(afterOrdinal, sql, 1); try bind(maximumRecords, sql, 2)
      var result: [(ordinal: Int, documentID: UUID, objectID: UUID)] = []
      result.reserveCapacity(maximumRecords)
      var prior = afterOrdinal
      while try row(sql) {
        guard sqlite3_column_type(sql, 0) == SQLITE_INTEGER,
          let ordinal = Int(exactly: sqlite3_column_int64(sql, 0)),
          ordinal > prior, ordinal < Self.maximumDocuments, result.count < maximumRecords else {
          throw BoomError.invalid("Document-index row order or extent changed.")
        }
        result.append((ordinal, try uuid(sql, 1), try uuid(sql, 2)))
        prior = ordinal
      }
      return result
    }
  }
  /// SQL columns are cursor locators only. Every caller authenticates the
  /// exact immutable header against all of these columns before using them.
  func hasEntityInventory() throws -> Bool {
    try admit(); return try integer("SELECT EXISTS(SELECT 1 FROM entities LIMIT 1)") == 1
  }
  func entityReference(_ id: UUID) throws -> WorkspaceEntityReference? {
    try admit()
    return try statement("SELECT entity_id,object_id,logical_id,parent_id,kind,ordinal FROM entities WHERE entity_id=?") { sql in
      try bind(id, sql, 1); guard try row(sql) else { return nil }
      let value = try entityPointer(sql); try end(sql); return value
    }
  }
  func entityReferences(kind: WorkspaceEntityKind, parentID: UUID, afterOrdinal: Int,
    maximumRecords: Int = WorkspaceMetadataInput.maximumEntities) throws -> [WorkspaceEntityReference] {
    guard afterOrdinal >= -1, afterOrdinal < Int(Int32.max), maximumRecords > 0,
      maximumRecords <= WorkspaceMetadataInput.maximumEntities + 1 else { throw BoomError.budget("Invalid entity cursor page.") }
    try admit()
    return try statement("SELECT entity_id,object_id,logical_id,parent_id,kind,ordinal FROM entities WHERE kind=? AND parent_id=? AND ordinal>? ORDER BY ordinal LIMIT ?") { sql in
      try bind(kind.rawValue, sql, 1); try bind(parentID, sql, 2); try bind(afterOrdinal, sql, 3); try bind(maximumRecords, sql, 4)
      var values: [WorkspaceEntityReference] = []; values.reserveCapacity(maximumRecords)
      var prior = afterOrdinal
      while try row(sql) {
        let value = try entityPointer(sql)
        guard values.count < maximumRecords, value.kind == kind, value.parentID == parentID, value.ordinal > prior else { throw BoomError.invalid("Entity cursor order/identity changed.") }
        values.append(value); prior = value.ordinal
      }
      return values
    }
  }
  func entityCount(kind: WorkspaceEntityKind, parentID: UUID) throws -> Int {
    try admit()
    return try statement("SELECT count(*) FROM entities WHERE kind=? AND parent_id=?") { sql in
      try bind(kind.rawValue, sql, 1); try bind(parentID, sql, 2)
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_INTEGER,
        let count = Int(exactly: sqlite3_column_int64(sql, 0)), count >= 0, count < Int(Int32.max) else { throw BoomError.invalid("Entity count changed.") }
      try end(sql); return count
    }
  }
  func entityByLogicalID(kind: WorkspaceEntityKind, logicalID: UUID) throws -> WorkspaceEntityReference? {
    try admit()
    return try statement("SELECT entity_id,object_id,logical_id,parent_id,kind,ordinal FROM entities WHERE kind=? AND logical_id=? LIMIT 2") { sql in
      try bind(kind.rawValue, sql, 1); try bind(logicalID, sql, 2)
      guard try row(sql) else { return nil }; let value = try entityPointer(sql)
      guard try row(sql) == false else { throw BoomError.invalid("Non-versioned entity logical identity is ambiguous.") }; return value
    }
  }
  private func entityPointer(_ sql: OpaquePointer) throws -> WorkspaceEntityReference {
    guard sqlite3_column_type(sql, 4) == SQLITE_INTEGER, sqlite3_column_type(sql, 5) == SQLITE_INTEGER,
      let kindNumber = Int(exactly: sqlite3_column_int64(sql, 4)), let kind = WorkspaceEntityKind(rawValue: kindNumber),
      let ordinal = Int(exactly: sqlite3_column_int64(sql, 5)) else { throw BoomError.invalid("Entity pointer scalar type changed.") }
    let value = WorkspaceEntityReference(id: try uuid(sql, 0), objectID: try uuid(sql, 1), logicalID: try uuid(sql, 2),
      parentID: try uuid(sql, 3), kind: kind, ordinal: ordinal)
    try value.validate(); return value
  }
  func authenticatedEntity(_ reference: WorkspaceEntityReference) throws -> (header: WorkspaceEntityHeader, bytes: Int) {
    try reference.validate()
    let bytes = try read(objectID: reference.objectID, documentID: reference.id, role: .entity, maximumBytes: WorkspaceEntityHeader.maximumBytes)
    let header = try JSONDecoder().decode(WorkspaceEntityHeader.self, from: bytes); try header.validate()
    guard header.id == reference.id, header.logicalID == reference.logicalID, header.parentID == reference.parentID,
      header.kind == reference.kind, header.ordinal == reference.ordinal else { throw BoomError.denied("Entity index columns disagree with their authenticated header.") }
    return (header, bytes.count)
  }
  func replaceEntity(_ after: WorkspaceEntityReference, expected: WorkspaceEntityReference?) throws {
    try requireWrite(); try after.validate()
    guard try entityReference(after.id) == expected else { throw BoomError.stale("Metadata entity full pointer CAS changed.") }
    try chargeMutation(rows: 1)
    if let expected {
      guard after.id == expected.id, after.kind == expected.kind, after.logicalID == expected.logicalID,
        after.parentID == expected.parentID, after.ordinal == expected.ordinal else { throw BoomError.denied("Entity replacement cannot silently rebase order/identity.") }
      try statement("UPDATE entities SET object_id=? WHERE entity_id=? AND object_id=?") { sql in
        try bind(after.objectID, sql, 1); try bind(after.id, sql, 2); try bind(expected.objectID, sql, 3); try done(sql)
      }
    } else {
      // Versions deliberately retain their original logical ID at distinct
      // ordinals. Every other logical identity is unique on its real route.
      if ![WorkspaceEntityKind.messageVersion, .voiceVersion, .draft].contains(after.kind),
        try entityByLogicalID(kind: after.kind, logicalID: after.logicalID) != nil { throw BoomError.stale("Entity logical identity already exists.") }
      try statement("INSERT INTO entities(entity_id,kind,logical_id,parent_id,ordinal,object_id) VALUES(?,?,?,?,?,?)") { sql in
        try bind(after.id, sql, 1); try bind(after.kind.rawValue, sql, 2); try bind(after.logicalID, sql, 3)
        try bind(after.parentID, sql, 4); try bind(after.ordinal, sql, 5); try bind(after.objectID, sql, 6); try done(sql)
      }
    }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("Entity pointer mutation did not join.") }
  }
  func removeEntity(_ expected: WorkspaceEntityReference) throws {
    try requireWrite(); try expected.validate()
    guard try entityReference(expected.id) == expected else { throw BoomError.stale("Entity removal has another current full pointer.") }
    try chargeMutation(rows: 1)
    try statement("DELETE FROM entities WHERE entity_id=? AND object_id=?") { sql in
      try bind(expected.id, sql, 1); try bind(expected.objectID, sql, 2); try done(sql)
    }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("Entity removal did not join.") }
    // No immutable ciphertext/source row deletion or backup/GC authority.
  }
  func replaceHead(objectID: UUID, expected: UUID?) throws {
    try requireWrite(); try chargeMutation(rows: 1)
    if let expected {
      try statement("UPDATE current_head SET object_id=? WHERE singleton=1 AND object_id=?") {
        try bind(objectID, $0, 1); try bind(expected, $0, 2); try done($0)
      }
    } else { try statement("INSERT INTO current_head(singleton,object_id) VALUES(1,?)") { try bind(objectID, $0, 1); try done($0) } }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("SQLite head pointer CAS changed.") }
  }
  func replaceRecord(documentID: UUID, objectID: UUID, expected: UUID) throws {
    try requireWrite(); try chargeMutation(rows: 1)
    try statement("UPDATE documents SET object_id=? WHERE document_id=? AND object_id=?") {
      try bind(objectID, $0, 1); try bind(documentID, $0, 2); try bind(expected, $0, 3); try done($0)
    }
    guard sqlite3_changes(db) == 1 else { throw BoomError.stale("SQLite document pointer CAS changed.") }
  }
  func replaceInventory(_ documents: [(UUID, UUID)]) throws {
    try requireWrite(); guard documents.count <= Self.maximumDocuments, Set(documents.map { $0.0 }).count == documents.count else {
      throw BoomError.budget("SQLite workspace inventory is not bounded and unique.")
    }
    let oldCount = try integer("SELECT count(*) FROM documents")
    guard oldCount >= 0, oldCount <= Self.maximumDocuments else { throw BoomError.budget("Existing SQL inventory is oversized.") }
    try chargeMutation(rows: oldCount + documents.count)
    try exec("DELETE FROM documents")
    for (ordinal, entry) in documents.enumerated() {
      try statement("INSERT INTO documents(document_id,object_id,ordinal) VALUES(?,?,?)") {
        try bind(entry.0, $0, 1); try bind(entry.1, $0, 2); try bind(ordinal, $0, 3); try done($0)
      }
    }
  }
  private func chargeMutation(rows: Int) throws {
    guard var state = transactionState, rows >= 0, rows <= Self.maximumTransactionRows - state.rows else {
      throw BoomError.budget("SQL pointer mutations exceed the actual transaction row budget.")
    }
    state.rows += rows; transactionState = state
  }
  private func requireWrite() throws {
    try admit(); guard transactionState != nil, inspectionDepth == 0, readSnapshotOwner == nil else { throw BoomError.denied("SQL mutation has no exclusive transaction.") }
  }
  /// Same existing executor/job. One finite checkpoint, no receipt drain,
  /// polling loop or background disk COMMIT per edit.
  func checkpoint(operationID: UUID) throws -> PagedSQLiteExecution {
    try requireMaintenanceAdmission()
    let operation = PagedSQLiteOperationIdentity(store: nativeReceivingIdentity, operationID: operationID)
    do {
      let result = try truncateWAL(operationID: operationID)
      return PagedSQLiteExecution(identity: operation, kind: .checkpoint, beforeAdmitted: true,
        beforeHead: nil, beforeRecord: nil, publication: nil, commitEntered: false,
        outcome: .resolved(.checkpoint), checkpoint: result)
    } catch {
      refusedOperationID = operationID
      throw PagedSQLiteExecutionFailure(execution: PagedSQLiteExecution(identity: operation,
        kind: .checkpoint, beforeAdmitted: true, beforeHead: nil, beforeRecord: nil,
        publication: nil, commitEntered: false, outcome: .unknown, original: error, checkpoint: lastCheckpoint))
    }
  }
  private func truncateWAL(operationID: UUID) throws -> PagedSQLiteCheckpointResult {
    try admit()
    guard statements == 0, transactionState == nil, readSnapshotOwner == nil, let db,
      sqlite3_get_autocommit(db) == 1, try integer("PRAGMA synchronous") == 2,
      try integer("PRAGMA fullfsync") == 1, try integer("PRAGMA checkpoint_fullfsync") == 1 else {
      throw BoomError.unavailable("Actual checkpoint connection lost its full-sync or join policy.")
    }
    let before = observedWALBytes
    var frames: Int32 = -1, copied: Int32 = -1
    let code = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, &frames, &copied)
    let returned = PagedSQLiteCheckpointResult(operationID: operationID, code: code,
      logFrames: frames, copiedFrames: copied, beforeWALBytes: before, afterWALBytes: nil)
    lastCheckpoint = returned
    guard code == SQLITE_OK, frames == 0, copied == 0 else { throw PagedSQLiteCheckpointFailure(result: returned) }
    try admit()
    let joined = PagedSQLiteCheckpointResult(operationID: operationID, code: code,
      logFrames: frames, copiedFrames: copied, beforeWALBytes: before, afterWALBytes: observedWALBytes)
    lastCheckpoint = joined
    guard observedWALBytes == 0 else { throw PagedSQLiteCheckpointFailure(result: joined) }
    checkpointRequested = false; return joined
  }
  private func admitWAL() throws {
    // admit() just measured this exact namespace before BEGIN. The unchanged
    // 64 MiB guard is pre-write admission, not a promise that one accepted
    // transaction cannot cross it. Post-COMMIT observation schedules maintenance
    // before the next write turn, including a threshold-crossing transaction.
    guard observedWALBytes < Self.walAdmissionBytes else {
      throw BoomError.budget("WAL admission requires exact owned maintenance; source records retained.")
    }
  }
  /// Only augments an already failing API result. No statement text, body,
  /// database open/close, storage mutation, input/root disposition or retry.
  private func sqliteFailure(_ code: Int32, stage: StaticString) -> PagedSQLiteCode {
    var failure = PagedSQLiteCode(code: code)
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
    // This diagnostic is deliberately narrower than the public SQL controls:
    // exactly the first metadata case and its actual UUID scratch namespace.
    let fixtureName = vault.root.deletingLastPathComponent().lastPathComponent
    let prefix = "bloom-metadata-public-"
    guard !Thread.isMainThread,
      ProcessInfo.processInfo.environment["BLOOM_METADATA_SQL_PUBLIC_CASE"] == "testPublicConversionLazyDraftNativeReuseAndEncryptedReopen",
      vault.root.lastPathComponent == "Private", fixtureName.hasPrefix(prefix),
      UUID(uuidString: String(fixtureName.dropFirst(prefix.count))) != nil else { return failure }
    // Read the connection's error immediately, before filesystem observation
    // or statement finalization can obscure the original extended result.
    let extended = db.map { sqlite3_extended_errcode($0) }
    var observation: [String: String] = [
      "stage": String(describing: stage),
      "context": publicDiagnosticDuringConfigure ? "configure" : "outside_configure",
      "primaryCode": String(code), "extendedCode": extended.map(String.init) ?? "unresolved_no_connection",
      "runtimeVersion": String(sqlite3_libversion_number()),
      "openFlags": publicDiagnosticOpenFlags.map(String.init) ?? "unobserved",
      "storeID": storeID.uuidString, "engineIncarnation": engineIncarnation.uuidString,
      "connectionIncarnation": connectionIncarnation.uuidString,
      "preflightDevice": String(identity.0), "preflightInode": String(identity.1)
    ]
    if let sourceID = sqlite3_sourceid() {
      let length = strnlen(sourceID, 256)
      if length < 256 {
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(sourceID).assumingMemoryBound(to: UInt8.self), count: length)
        observation["runtimeSourceID"] = String(decoding: bytes, as: UTF8.self)
      } else { observation["runtimeSourceID"] = "unresolved_source_id_bound" }
    }
    if path.utf8.count <= Int(MAXPATHLEN) {
      observation["passedFilename"] = path // the exact String passed to open_v2; no Foundation re-resolution
      let physical: (String?, Int32) = path.withCString { input in
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN)) { buffer in
          guard let destination = buffer.baseAddress else { return (nil, 0) }
          let result = Darwin.realpath(input, destination)
          let savedErrno = errno
          guard result != nil else { return (nil, savedErrno) }
          return (String(validatingCString: destination), 0)
        }
      }
      observation["physicalFilename"] = physical.0 ?? "unresolved"
      observation["realpathErrno"] = String(physical.1)
      var named = stat()
      let result = path.withCString { lstat($0, &named) }
      let savedErrno = errno
      observation["namedStatCode"] = String(result)
      observation["namedStatErrno"] = String(result == 0 ? 0 : savedErrno)
      if result == 0 {
        observation["namedDevice"] = String(UInt64(truncatingIfNeeded: named.st_dev))
        observation["namedInode"] = String(UInt64(named.st_ino))
        observation["namedMode"] = String(UInt32(named.st_mode))
        observation["namedUID"] = String(named.st_uid)
        observation["namedLinks"] = String(named.st_nlink)
        observation["namedBytes"] = String(named.st_size)
      }
    } else { observation["passedFilename"] = "unresolved_filename_bound" }
    if directoryFD >= 0 {
      var directory = stat()
      let result = fstat(directoryFD, &directory), savedErrno = errno
      observation["ownedDirectoryStatCode"] = String(result)
      observation["ownedDirectoryStatErrno"] = String(result == 0 ? 0 : savedErrno)
      if result == 0 {
        observation["ownedDirectoryDevice"] = String(UInt64(truncatingIfNeeded: directory.st_dev))
        observation["ownedDirectoryInode"] = String(UInt64(directory.st_ino))
      }
    } else { observation["ownedDirectoryStatCode"] = "unobserved_no_descriptor" }
    // All keys are fixed and strings have explicit bounds. Capacity refusal
    // preserves the original primary result instead of returning false success.
    if observation.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 4_096 {
      failure.publicObservation = observation
    } else {
      failure.publicObservation = ["stage": String(describing: stage), "primaryCode": String(code),
        "extendedCode": extended.map(String.init) ?? "unresolved_no_connection", "observation": "refused_4096_byte_bound"]
    }
#endif
    return failure
  }

  private func configure() throws {
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
    publicDiagnosticDuringConfigure = true
    defer { publicDiagnosticDuringConfigure = false }
#endif
    guard let db else { throw BoomError.unavailable("SQLite is closed.") }
    let extended = sqlite3_extended_result_codes(db, 1), busy = sqlite3_busy_timeout(db, 0)
    guard extended == SQLITE_OK, busy == SQLITE_OK else { throw sqliteFailure(extended != SQLITE_OK ? extended : busy, stage: "configure") }
    sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 65_664)
    sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 16_384)
    sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 16)
    sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 8)
    sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
    guard sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 65_664,
      sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, -1) == 16_384,
      sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1) == 16,
      sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1) == 8,
      sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, -1) == 0 else { throw BoomError.unavailable("SQLite connection limits were refused.") }
    // Must precede the first schema/journal/WAL access. Never switch this
    // connection back to NORMAL; source pins are process-local and require
    // exclusion of other cooperating SQLite connections for this prototype.
    try exec("PRAGMA main.locking_mode=EXCLUSIVE")
    let exclusive = try statement("PRAGMA main.locking_mode") { sql -> Data in
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_TEXT else { throw BoomError.invalid("SQLite locking mode unavailable.") }
      let n = sqlite3_column_bytes(sql, 0)
      guard n == 9, let bytes = sqlite3_column_text(sql, 0) else { throw BoomError.invalid("SQLite locking mode changed.") }
      let result = Data(bytes: bytes, count: Int(n)); try end(sql); return result
    }
    guard exclusive == Data("exclusive".utf8) else { throw BoomError.unavailable("SQLite EXCLUSIVE connection policy was refused.") }
    for sql in ["PRAGMA trusted_schema=OFF", "PRAGMA foreign_keys=ON", "PRAGMA journal_mode=WAL",
      "PRAGMA synchronous=FULL", "PRAGMA fullfsync=ON", "PRAGMA checkpoint_fullfsync=ON",
      "PRAGMA wal_autocheckpoint=0", "PRAGMA mmap_size=0", "PRAGMA temp_store=MEMORY", "PRAGMA cache_size=-2048"] { try exec(sql) }
    let wal = try statement("PRAGMA journal_mode") { sql -> Data in
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_TEXT else { throw BoomError.invalid("SQLite journal mode unavailable.") }
      let n = sqlite3_column_bytes(sql, 0); guard n == 3, let bytes = sqlite3_column_text(sql, 0) else { throw BoomError.invalid("SQLite journal mode changed.") }
      let result = Data(bytes: bytes, count: Int(n)); try end(sql); return result
    }
    guard wal == Data("wal".utf8), try integer("PRAGMA synchronous") == 2,
      try integer("PRAGMA fullfsync") == 1, try integer("PRAGMA checkpoint_fullfsync") == 1,
      try integer("PRAGMA wal_autocheckpoint") == 0, try integer("PRAGMA mmap_size") == 0,
      try integer("PRAGMA temp_store") == 2, try integer("PRAGMA foreign_keys") == 1 else {
      throw BoomError.unavailable("SQLite durability or temporary-storage policy was refused.")
    }
  }
  private func performCommit() throws {
#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
    let fault: PagedSQLitePublicCommitFault?
    if let armed = publicCommitFault, !armed.publicationsOnly || transactionState?.publication != nil {
      fault = armed.fault; publicCommitFault = nil
    } else { fault = nil }
    if case .veto? = fault {
      // Documented commit-hook nonzero return forces actual SQLite ROLLBACK.
      // This still enters COMMIT; visibility alone cannot release our fence.
      _ = sqlite3_commit_hook(db, { _ in 1 }, nil)
      defer { _ = sqlite3_commit_hook(db, nil, nil) }
      try exec("COMMIT")
      throw BoomError.invalid("Actual SQLite unexpectedly accepted a vetoed COMMIT.")
    }
    try exec("COMMIT")
    if case .moveDatabaseName? = fault {
      var original = stat(), destination = stat()
      guard fstatat(directoryFD, "store.sqlite", &original, AT_SYMLINK_NOFOLLOW) == 0,
        Self.privateFile(original), (UInt64(truncatingIfNeeded: original.st_dev), UInt64(original.st_ino)) == identity,
        fstatat(directoryFD, "public-moved.sqlite", &destination, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
        throw BoomError.stale("Public post-COMMIT name fault has another exact scratch inode.")
      }
      guard renameat(directoryFD, "store.sqlite", directoryFD, "public-moved.sqlite") == 0 else {
        throw BoomError.unavailable("Actual public post-COMMIT rename refused, errno \(errno).")
      }
      publicDatabaseNameMoved = true // only after real rename success
      // The existing mandatory post-COMMIT admit() actually refuses the now
      // absent name. Keep the live connection; no raw open/close cancels locks.
    }
#else
    try exec("COMMIT")
#endif
  }

  private func exec(_ sql: String) throws {
    let code = sqlite3_exec(db, sql, nil, nil, nil); guard code == SQLITE_OK else { throw sqliteFailure(code, stage: "exec") }
  }
  private func statement<T>(_ text: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    guard statements < 8, let db else { throw BoomError.budget("SQLite statement ownership is bounded.") }
    var sql: OpaquePointer?
    let code = sqlite3_prepare_v3(db, text, -1, 0, &sql, nil)
    guard code == SQLITE_OK, let sql else {
      let original = sqliteFailure(code, stage: "prepare") // capture before the existing finalize changes connection error state
      if let sql { sqlite3_finalize(sql) }
      throw original
    }
    statements += 1; defer { statements -= 1 }
    let result: T
    do { result = try body(sql) }
    catch {
      let finalize = sqlite3_finalize(sql)
      if finalize != SQLITE_OK { throw PagedSQLiteCleanupFailure(original: error, phase: .statementFinalize, code: finalize) }
      throw error
    }
    let close = sqlite3_finalize(sql)
    guard close == SQLITE_OK else { throw PagedSQLiteCode(code: close) }
    return result
  }
  private func bind(_ value: Data, _ sql: OpaquePointer, _ index: Int32) throws {
    guard value.count <= 65_564 else { throw BoomError.budget("SQL parameter exceeds its bound.") }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let code = value.withUnsafeBytes { sqlite3_bind_blob(sql, index, $0.baseAddress, Int32($0.count), transient) }
    guard code == SQLITE_OK else { throw PagedSQLiteCode(code: code) }
  }
  private func bind(_ value: UUID, _ sql: OpaquePointer, _ index: Int32) throws {
    var id = value.uuid; try withUnsafeBytes(of: &id) { try bind(Data($0), sql, index) }
  }
  private func bind(_ value: Int, _ sql: OpaquePointer, _ index: Int32) throws {
    let code = sqlite3_bind_int64(sql, index, Int64(value)); guard code == SQLITE_OK else { throw PagedSQLiteCode(code: code) }
  }
  private func blob(_ sql: OpaquePointer, _ column: Int32, maximumBytes: Int) throws -> Data {
    let n = sqlite3_column_bytes(sql, column)
    guard sqlite3_column_type(sql, column) == SQLITE_BLOB, n >= 0, Int(n) <= maximumBytes else {
      throw BoomError.budget("SQL result type or extent refused before allocation.")
    }
    if n == 0 { return Data() }
    guard let bytes = sqlite3_column_blob(sql, column) else { throw BoomError.invalid("SQL result buffer unavailable.") }
    return Data(bytes: bytes, count: Int(n))
  }
  private func uuid(_ sql: OpaquePointer, _ column: Int32) throws -> UUID {
    let data = try blob(sql, column, maximumBytes: 16)
    guard data.count == 16 else { throw BoomError.invalid("SQL object UUID has another extent.") }
    return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
  }
  private func row(_ sql: OpaquePointer) throws -> Bool {
    let code = sqlite3_step(sql)
    if code == SQLITE_ROW { return true }; if code == SQLITE_DONE { return false }; throw sqliteFailure(code, stage: "step")
  }
  private func done(_ sql: OpaquePointer) throws { guard try row(sql) == false else { throw BoomError.invalid("SQL mutation returned unexpected rows.") } }
  private func end(_ sql: OpaquePointer) throws { try done(sql) }
  private func integer(_ text: String) throws -> Int {
    try statement(text) { sql in
      guard try row(sql), sqlite3_column_type(sql, 0) == SQLITE_INTEGER, let value = Int(exactly: sqlite3_column_int64(sql, 0)) else {
        throw BoomError.invalid("SQL scalar unavailable.")
      }
      try end(sql); return value
    }
  }
  private func pointer(_ text: String) throws -> UUID? {
    try statement(text) { sql in guard try row(sql) else { return nil }; let value = try uuid(sql, 0); try end(sql); return value }
  }
  private static func admitDirectory(_ fd: Int32) throws {
    var value = stat(); guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { throw BoomError.denied("SQLite directory ownership refused.") }
  }
  private static func privateFile(_ value: stat) -> Bool {
    value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_mode & 0o077 == 0 && value.st_nlink == 1
  }
  private static let schema = """
    CREATE TABLE objects(object_id BLOB NOT NULL CHECK(length(object_id)=16),part INTEGER NOT NULL CHECK(part>=0 AND part<2048),document_id BLOB NOT NULL CHECK(length(document_id)=16),role INTEGER NOT NULL CHECK(role IN(1,2,3,4,5,7,8,9)),plain_bytes INTEGER NOT NULL CHECK(plain_bytes>=0 AND plain_bytes<=65536),ciphertext BLOB NOT NULL CHECK(length(ciphertext)=plain_bytes+28),PRIMARY KEY(object_id,part)) WITHOUT ROWID;
    CREATE TABLE entities(entity_id BLOB PRIMARY KEY CHECK(length(entity_id)=16),kind INTEGER NOT NULL CHECK(kind>=1 AND kind<=14),logical_id BLOB NOT NULL CHECK(length(logical_id)=16),parent_id BLOB NOT NULL CHECK(length(parent_id)=16),ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<2147483647),object_id BLOB NOT NULL CHECK(length(object_id)=16),UNIQUE(kind,parent_id,ordinal)) WITHOUT ROWID;
    CREATE INDEX entity_identity ON entities(kind,logical_id);
    CREATE TABLE current_head(singleton INTEGER PRIMARY KEY CHECK(singleton=1),object_id BLOB NOT NULL CHECK(length(object_id)=16));
    CREATE TABLE documents(document_id BLOB PRIMARY KEY CHECK(length(document_id)=16),object_id BLOB NOT NULL CHECK(length(object_id)=16),ordinal INTEGER NOT NULL UNIQUE CHECK(ordinal>=0 AND ordinal<1024)) WITHOUT ROWID;
    """
}
