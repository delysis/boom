import Foundation
import Synchronization

/// One latest pending value and one scheduled native publication. The model
/// producer never waits for UI; final publication closes and joins this task.
final class MainActorTextDelivery: @unchecked Sendable {
  private struct State {
    var latest: String?
    var task: Task<Void, Never>?
    var closed = false
  }
  private let state = Mutex(State())
  private let receive: @MainActor @Sendable (String) -> Void

  init(_ receive: @escaping @MainActor @Sendable (String) -> Void) {
    self.receive = receive
  }

  func submit(_ text: String) {
    state.withLock { value in
      guard !value.closed else { return }
      value.latest = text
      if value.task == nil {
        value.task = Task { @MainActor [self] in publish() }
      }
    }
  }

  @MainActor private func publish() {
    let text = state.withLock { value -> String? in
      let text = value.closed ? nil : value.latest
      value.latest = nil
      return text
    }
    if let text { receive(text) }
    state.withLock { value in
      value.task = nil
      if !value.closed, value.latest != nil {
        // Yield the actor between publications, rather than draining a fast
        // producer in a loop that could postpone keyboard and pointer events.
        value.task = Task { @MainActor [self] in publish() }
      }
    }
  }

  @MainActor func closeAndJoin() async {
    let task = state.withLock { value in
      value.closed = true
      value.latest = nil
      return value.task
    }
    if let task { await task.value }
  }
}
