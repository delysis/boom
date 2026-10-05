import BoomCore
import XCTest
@testable import Boom

final class GenerationCoordinatorTests: XCTestCase {
  private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if open { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      open = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }
  private actor Trace {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
  }
  private func waitForQueue(_ count: Int, coordinator: GenerationCoordinator) async throws {
    let deadline = Date().addingTimeInterval(2)
    while await coordinator.queuedOperations != count {
      if Date() >= deadline { throw BoomError.unavailable("Coordinator did not queue the requested operations.") }
      await Task.yield()
    }
  }
  func testForegroundPreemptsAndJoinsProducerBeforeQueuedAutocomplete() async throws {
    let coordinator = GenerationCoordinator(), gate = Gate(), trace = Trace()
    let active = CancellationFlag()
    await coordinator.enter(flag: active, background: true)
    let producer = Task { await gate.wait(); await trace.append("producer joined") }
    await coordinator.own(producer)
    let background = Task {
      await coordinator.enter(flag: CancellationFlag(), background: true)
      await trace.append("queued autocomplete")
      await coordinator.leave()
    }
    try await waitForQueue(1, coordinator: coordinator)
    let foreground = Task {
      await coordinator.enter(flag: CancellationFlag())
      await trace.append("foreground preparation")
      await coordinator.leave()
    }
    try await waitForQueue(2, coordinator: coordinator)
    XCTAssertTrue(active.isCancelled)
    XCTAssertTrue(producer.isCancelled)
    let leaving = Task { await coordinator.leave() }
    await Task.yield()
    let beforeRelease = await trace.entries
    XCTAssertTrue(beforeRelease.isEmpty, "Neither queued operation may use the GPU before producer joining.")
    await gate.release()
    await leaving.value; await foreground.value; await background.value
    let completed = await trace.entries
    XCTAssertEqual(completed, ["producer joined", "foreground preparation", "queued autocomplete"])
  }
  func testPreemptionBeforeRegistrationCancelsAndJoinsThrowingOwner() async throws {
    let coordinator = GenerationCoordinator(), gate = Gate(), trace = Trace()
    let flag = CancellationFlag()
    await coordinator.enter(flag: flag, background: true)
    let foreground = Task {
      await coordinator.enter(flag: CancellationFlag())
      await trace.append("foreground preparation")
      await coordinator.leave()
    }
    try await waitForQueue(1, coordinator: coordinator)
    let owner = Task<Int, Error> {
      await gate.wait()
      await trace.append("prefill joined")
      try Task.checkCancellation()
      return 1
    }
    await coordinator.own(owner)
    XCTAssertTrue(flag.isCancelled)
    XCTAssertTrue(owner.isCancelled)
    let leaving = Task { await coordinator.leave() }
    await Task.yield()
    let beforeRelease = await trace.entries
    XCTAssertTrue(beforeRelease.isEmpty)
    await gate.release()
    await leaving.value; await foreground.value
    do { _ = try await owner.value; XCTFail("Preempted owner completed normally") }
    catch is CancellationError {}
    let entries = await trace.entries
    XCTAssertEqual(entries, ["prefill joined", "foreground preparation"])
  }
}
