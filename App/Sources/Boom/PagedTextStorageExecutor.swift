import BoomCore
import Foundation
import Synchronization

/// Foreground storage operations run between bounded background steps. This
/// owner also joins complete bulk lifetimes, including off-queue file sync,
/// before the Rust callback context can be released.
final class PagedTextStorageExecutor: @unchecked Sendable {
  enum Priority: Sendable, Equatable { case foreground, background, cleanup, maintenance, lifecycle }
  struct Snapshot: Sendable {
    let foregroundRequests: Int
    let backgroundRequests: Int
    let cleanupRequests: Int
    let maintenanceRequests: Int
    let bulkOperations: Int
    let closing: Bool
  }
  private struct Job: Sendable {
    let priority: Priority
    let run: @Sendable () -> Void
  }
  private struct State {
    var jobs: [Job] = []
    var foreground = 0
    var background = 0
    var cleanup = 0
    var maintenance = 0
    var maintenanceUrgent = false
    var interactiveBurst = 0
    var lifecycle = 0
    var draining = false
    var closing = false
    var closeInProgress = false
    var bulk: [UUID: PagedTextCancellation] = [:]
    var closeWaiter: CheckedContinuation<Void, Error>?
  }
  let queue = DispatchQueue(label: "com.delysis.Bloom.paged-storage", qos: .userInitiated)
  private let state = Mutex(State())
  var snapshot: Snapshot {
    state.withLock {
      Snapshot(foregroundRequests: $0.foreground, backgroundRequests: $0.background,
        cleanupRequests: $0.cleanup, maintenanceRequests: $0.maintenance,
        bulkOperations: $0.bulk.count, closing: $0.closing)
    }
  }

  func reserveBulk(_ cancellation: PagedTextCancellation) throws -> UUID {
    try state.withLock { state in
      guard !state.closing, state.bulk.count < 2 else {
        throw BoomError.unavailable("Paged bulk storage is busy or closing.")
      }
      let id = UUID(); state.bulk[id] = cancellation; return id
    }
  }
  func releaseBulk(_ id: UUID) {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
      guard state.bulk.removeValue(forKey: id) != nil, state.bulk.isEmpty else { return nil }
      let waiter = state.closeWaiter; state.closeWaiter = nil; return waiter
    }
    waiter?.resume()
  }
  func beginClose() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let result = state.withLock { state -> Result<Bool, Error> in
        guard !state.closeInProgress else {
          return .failure(BoomError.unavailable("Paged close is already joining."))
        }
        state.closing = true; state.closeInProgress = true
        // These are nonblocking atomic flags, with no executor reentry.
        for cancellation in state.bulk.values { cancellation.cancel() }
        if state.bulk.isEmpty { return .success(true) }
        state.closeWaiter = continuation; return .success(false)
      }
      switch result {
      case .success(true): continuation.resume()
      case .success(false): break
      case .failure(let error): continuation.resume(throwing: error)
      }
    }
  }
  func endCloseAttempt() { state.withLock { $0.closeInProgress = false } }

  /// Admission is synchronous, before the owner may return. The one maintenance
  /// slot contains the actual owned work; no detached Task or timer is created.
  /// Rejection leaves its caller responsible for releasing an unmutated lease.
  func enqueueMaintenance(urgent: Bool, afterJoin: @escaping @Sendable () -> Void = {},
    _ work: @escaping @Sendable () -> Void) -> Bool {
    let job = Job(priority: .maintenance) {
      autoreleasepool(invoking: work)
      self.finished(.maintenance)
      // The actual body already joined its Root job before this counter fell.
      // A successor quantum may now synchronously reserve/admit its own SAME
      // owner/slot; no unowned dispatch or overlapped producer is introduced.
      afterJoin()
    }
    let admitted = state.withLock { state -> (Bool, Bool) in
      if state.maintenance != 0 {
        if urgent { state.maintenanceUrgent = true }
        return (false, false)
      }
      guard !state.closing else { return (false, false) }
      state.maintenance = 1; state.maintenanceUrgent = urgent
      state.jobs.append(job)
      if state.draining { return (true, false) }
      state.draining = true; return (true, true)
    }
    if admitted.1 { queue.async { self.drain() } }
    return admitted.0
  }
  /// A post-COMMIT WAL threshold crossing promotes the already admitted job.
  /// It cannot add a second job or turn a mode value into a storage admission.
  func prioritizeMaintenance() {
    state.withLock { state in if state.maintenance != 0 { state.maintenanceUrgent = true } }
  }

  func run<T: Sendable>(priority: Priority = .foreground, cancellation: PagedTextCancellation? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let job = Job(priority: priority) {
          let result: Result<T, Error> = Result {
            if cancellation?.isCancelled == true { throw CancellationError() }
            return try autoreleasepool(invoking: work)
          }
          self.finished(priority)
          continuation.resume(with: result)
        }
        let admitted = state.withLock { state -> (Bool, Bool) in
          if state.closing, priority != .cleanup && priority != .lifecycle { return (false, false) }
          switch priority {
          case .foreground:
            guard state.foreground < 8 else { return (false, false) }; state.foreground += 1
          case .background:
            guard state.background < 2 else { return (false, false) }; state.background += 1
          case .cleanup:
            guard state.cleanup < 2 else { return (false, false) }; state.cleanup += 1
          case .maintenance:
            guard state.maintenance == 0 else { return (false, false) }; state.maintenance = 1
          case .lifecycle:
            guard state.closeInProgress, state.bulk.isEmpty, state.lifecycle == 0 else { return (false, false) }
            state.lifecycle += 1
          }
          state.jobs.append(job)
          if state.draining { return (true, false) }
          state.draining = true; return (true, true)
        }
        if !admitted.0 { continuation.resume(throwing: BoomError.unavailable("Paged storage request queue is full or closing.")) }
        else if admitted.1 { queue.async { self.drain() } }
      }
    } onCancel: { cancellation?.cancel() }
  }
  private func finished(_ priority: Priority) {
    state.withLock { state in
      switch priority {
      case .foreground: state.foreground -= 1
      case .background: state.background -= 1
      case .cleanup: state.cleanup -= 1
      case .maintenance: state.maintenance -= 1; state.maintenanceUrgent = false
      case .lifecycle: state.lifecycle -= 1
      }
    }
  }
  private func drain() {
    dispatchPrecondition(condition: .onQueue(queue))
    let job = state.withLock { state -> Job? in
      guard !state.jobs.isEmpty else { state.draining = false; return nil }
      let maintenance = state.jobs.firstIndex(where: { $0.priority == .maintenance })
      let index: Int
      if let maintenance, state.maintenanceUrgent || state.interactiveBurst >= 8 {
        index = maintenance
      } else {
        index = state.jobs.firstIndex(where: { $0.priority == .foreground })
          ?? state.jobs.firstIndex(where: { $0.priority == .cleanup })
          ?? maintenance ?? state.jobs.firstIndex(where: { $0.priority == .background }) ?? 0
      }
      let job = state.jobs.remove(at: index)
      if job.priority == .maintenance { state.interactiveBurst = 0 }
      else if job.priority == .foreground || job.priority == .cleanup {
        state.interactiveBurst = min(8, state.interactiveBurst + 1)
      }
      return job
    }
    guard let job else { return }
    job.run()
    queue.async { self.drain() }
  }
}
