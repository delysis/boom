import BoomCore
import Foundation
import Synchronization

/// One bounded queue. Bulk streams yield after every 64 KiB step; foreground
/// source requests and cleanup can run between them. No maintenance scheduler.
final class PagedTextStorageExecutor: @unchecked Sendable {
  enum Priority: Sendable, Equatable { case foreground, background, cleanup, lifecycle }
  struct Snapshot: Sendable {
    let foregroundRequests: Int; let backgroundRequests: Int; let cleanupRequests: Int
    let bulkOperations: Int; let closing: Bool
  }
  private struct Job: Sendable { let priority: Priority; let run: @Sendable () -> Void }
  private struct State {
    var jobs: [Job] = []
    var foreground = 0; var background = 0; var cleanup = 0; var lifecycle = 0
    var foregroundBurst = 0; var draining = false; var closing = false; var closeInProgress = false
    var bulk: [UUID: PagedTextCancellation] = [:]
    var backgroundBulk: UUID?
    var closeWaiter: CheckedContinuation<Void, Error>?
  }
  let queue = DispatchQueue(label: "com.delysis.Bloom.paged-storage", qos: .userInitiated)
  private let state = Mutex(State())
  var snapshot: Snapshot { state.withLock { Snapshot(foregroundRequests: $0.foreground,
    backgroundRequests: $0.background, cleanupRequests: $0.cleanup,
    bulkOperations: $0.bulk.count, closing: $0.closing) } }
  func reserveBulk(_ cancellation: PagedTextCancellation, priority: Priority = .background) throws -> UUID {
    try state.withLock { s in
      guard priority == .foreground || priority == .background else {
        throw BoomError.invalid("Source continuations require a foreground or background admission.")
      }
      // One of the existing two slots remains available to user movement and
      // editing. Hash/export/import work cannot consume both source slots.
      guard !s.closing, s.bulk.count < 2, priority == .foreground || s.backgroundBulk == nil else {
        throw BoomError.unavailable("Source streams are busy or closing.")
      }
      let id = UUID(); s.bulk[id] = cancellation
      if priority == .background { s.backgroundBulk = id }
      return id
    }
  }
  func releaseBulk(_ id: UUID) {
    let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
      guard s.bulk.removeValue(forKey: id) != nil else { return nil }
      if s.backgroundBulk == id { s.backgroundBulk = nil }
      guard s.bulk.isEmpty else { return nil }
      let waiter = s.closeWaiter; s.closeWaiter = nil; return waiter
    }
    waiter?.resume()
  }
  func beginClose() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let result = state.withLock { s -> Result<Bool, Error> in
        guard !s.closeInProgress else { return .failure(BoomError.unavailable("Source close is already joining.")) }
        s.closing = true; s.closeInProgress = true
        for cancellation in s.bulk.values { cancellation.cancel() }
        if s.bulk.isEmpty { return .success(true) }
        s.closeWaiter = continuation; return .success(false)
      }
      switch result { case .success(true): continuation.resume(); case .success(false): break
        case .failure(let error): continuation.resume(throwing: error) }
    }
  }
  func endCloseAttempt() { state.withLock { $0.closeInProgress = false } }
  func run<T: Sendable>(priority: Priority = .foreground, cancellation: PagedTextCancellation? = nil,
    _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let job = Job(priority: priority) {
        let result: Result<T, Error>
        do {
          if cancellation?.isCancelled == true { throw CancellationError() }
          result = .success(try autoreleasepool(invoking: work))
        } catch { result = .failure(error) }
        // A resumed producer may immediately submit its next quantum on
        // another thread. Its completed job must already have released the
        // admission slot, including when work failed or was cancelled.
        self.finished(priority)
        continuation.resume(with: result)
      }
      let result = state.withLock { s -> (Bool, Bool) in
        guard (!s.closing || priority == .cleanup || priority == .lifecycle), s.jobs.count < 64 else { return (false, false) }
        switch priority {
        case .foreground: guard s.foreground < 32 else { return (false, false) }; s.foreground += 1
        case .background: guard s.background < 2 else { return (false, false) }; s.background += 1
        case .cleanup: guard s.cleanup < 16 else { return (false, false) }; s.cleanup += 1
        case .lifecycle: guard s.lifecycle < 1 else { return (false, false) }; s.lifecycle += 1
        }
        s.jobs.append(job)
        if s.draining { return (true, false) }
        s.draining = true; return (true, true)
      }
      if !result.0 { continuation.resume(throwing: BoomError.unavailable("Source queue is full or closing.")) }
      else if result.1 { queue.async { self.drain() } }
    }
  }
  private func finished(_ priority: Priority) {
    state.withLock { s in switch priority {
      case .foreground: s.foreground -= 1; case .background: s.background -= 1
      case .cleanup: s.cleanup -= 1; case .lifecycle: s.lifecycle -= 1
    } }
  }
  private func drain() {
    while let job = state.withLock({ s -> Job? in
      guard !s.jobs.isEmpty else { s.draining = false; return nil }
      let cleanup = s.jobs.firstIndex { $0.priority == .cleanup }
      let foreground = s.jobs.firstIndex { $0.priority == .foreground }
      let background = s.jobs.firstIndex { $0.priority == .background }
      let index: Int
      if let cleanup { index = cleanup }
      else if let background, s.foregroundBurst >= 8 { index = background }
      else { index = foreground ?? background ?? 0 }
      let job = s.jobs.remove(at: index)
      if job.priority == .foreground { s.foregroundBurst += 1 }
      else if job.priority == .background { s.foregroundBurst = 0 }
      return job
    }) { job.run() }
  }
}
