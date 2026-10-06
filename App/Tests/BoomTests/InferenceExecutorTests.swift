import AppKit
import XCTest
@testable import Boom

final class InferenceExecutorTests: XCTestCase {
  private func blockUntilReleased(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now() + .seconds(2)) == .success
  }
  @MainActor func testBlockingInferenceAllowsMainActorTimerToResume() async throws {
    let started = expectation(description: "Blocking native work started")
    let release = DispatchSemaphore(value: 0)
    let worker = InferenceExecutor()
    let operation = Task {
      await worker.perform { _ in
        XCTAssertFalse(Thread.isMainThread)
        started.fulfill()
        XCTAssertTrue(self.blockUntilReleased(release), "The test must release the dedicated worker before its timeout.")
      }
    }
    defer { release.signal() }
    await fulfillment(of: [started], timeout: 2)
    let clock = ContinuousClock(), before = clock.now
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertLessThan(before.duration(to: clock.now), .seconds(1), "A blocked model thread must not prevent the main-actor timer from resuming.")
    release.signal(); await operation.value
  }
}
