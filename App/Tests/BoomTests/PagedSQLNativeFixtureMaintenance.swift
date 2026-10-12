import BoomCore
import Foundation
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
/// Diagnostics only: this does not classify transactions or release failures.
func pagedSQLUnderlyingRefusal(_ error: Error) -> Error {
  var current = error
  for _ in 0..<4 {
    if let custody = current as? PagedTextCustodyFailure { current = custody.original; continue }
    if let handoff = current as? PagedTextCustodyHandoffFailure { current = handoff.original; continue }
    if let operation = current as? PagedSQLiteExecutionFailure { current = operation.original; continue }
    return current
  }
  return current
}

@MainActor final class PagedSQLNativeFixtureMaintenance {
  private let engine: PagedTextEngineAdapter
  private var attempted = false
  private(set) var scheduledJoin: PagedTextSQLMaintenanceSnapshot?
  private(set) var after: PagedTextSQLMaintenanceSnapshot?
  init(engine: PagedTextEngineAdapter) { self.engine = engine }

  /// Native callers and their actual receiving owners have already joined.
  /// This joins the SAME executor's bounded WAL work; no operation receipts,
  /// source replay, COMMIT retry or implicit output disposition is introduced.
  func drainAfterJoinedNativeCalls() async throws {
    guard !attempted else { throw BoomError.stale("Actual fixture WAL maintenance was already attempted; preserve its original failure.") }
    attempted = true
    let joined = try await engine.joinScheduledWALMaintenance()
    scheduledJoin = joined
    if let failure = joined.failure { throw failure }
    guard joined.storage.failedOperationID == nil, engine.custodySnapshot.jobs == 0 else {
      throw BoomError.stale("An actual source or failed transaction remains owned.")
    }
    let final: PagedTextSQLMaintenanceSnapshot
    if joined.storage.checkpointRequested {
      final = try await engine.maintainWAL() // one finite real checkpoint, no disk COMMIT per edit
    } else { final = joined }
    after = final
    if let failure = final.failure { throw failure }
    guard final.storage.failedOperationID == nil,
      final.storage.observedWALBytes <= PagedSQLiteStore.walAdmissionBytes,
      engine.custodySnapshot.jobs == 0 else {
      throw BoomError.stale("Actual WAL/source join is incomplete; retain the fixture.")
    }
  }
}
#endif
