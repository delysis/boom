import BoomCore
import Foundation
import MLX

/// Observe the whole owned operation, including prefill, without UI work.
/// The OS does not offer a process physical-footprint hard limit. This watch
/// requests cancellation; joined-operation checks report any overshoot.
final class OperationMemoryWatch: @unchecked Sendable {
  private let lock = NSLock()
  private let source: DispatchSourceTimer
  private var crossed = false
  var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return crossed }
  init(flag: CancellationFlag) throws {
    let limit = try ModelResidency.budget()
    try ModelResidency.check()
    source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    source.schedule(deadline: .now(), repeating: .milliseconds(20))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let used = max(ModelResidency.footprint(), UInt64(max(0, Memory.activeMemory + Memory.cacheMemory)))
      if used > limit {
        lock.lock(); crossed = true; lock.unlock()
        flag.cancel()
      }
    }
    source.resume()
  }
  func stop() { source.cancel() }
  deinit { source.cancel() }
}
