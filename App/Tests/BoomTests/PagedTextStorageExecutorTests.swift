import BoomCore
import Foundation
import Synchronization
import XCTest
@testable import Boom

final class PagedTextStorageExecutorTests: XCTestCase {
  private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
    while !condition() {
      guard clock.now < deadline else { throw BoomError.unavailable("Public scheduler control did not reach its boundary.") }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  func testForegroundOvertakesQueuedBackgroundStep() async throws {
    let executor = PagedTextStorageExecutor(), entered = expectation(description: "first bounded background step")
    let release = DispatchSemaphore(value: 0), order = Mutex<[String]>([])
    let first = Task {
      try await executor.run(priority: .background) {
        XCTAssertFalse(Thread.isMainThread)
        entered.fulfill()
        guard release.wait(timeout: .now() + 3) == .success else {
          throw BoomError.unavailable("Public held storage step timed out.")
        }
        order.withLock { $0.append("first") }
      }
    }
    defer { release.signal() }
    await fulfillment(of: [entered], timeout: 2)
    let background = Task { try await executor.run(priority: .background) { order.withLock { $0.append("background") } } }
    let foreground = Task { try await executor.run { order.withLock { $0.append("edit") } } }
    try await waitUntil { executor.snapshot.backgroundRequests == 2 && executor.snapshot.foregroundRequests == 1 }
    release.signal()
    try await first.value; try await foreground.value; try await background.value
    XCTAssertEqual(order.withLock { $0 }, ["first", "edit", "background"])
    XCTAssertEqual(executor.snapshot.backgroundRequests, 0)
    XCTAssertEqual(executor.snapshot.foregroundRequests, 0)
  }

  func testCloseCancelsAndJoinsWholeBulkLifetimeBeforeCallbackRelease() async throws {
    let executor = PagedTextStorageExecutor(), cancellation = PagedTextCancellation()
    let lease = try executor.reserveBulk(cancellation)
    let closing = Task { try await executor.beginClose() }
    try await waitUntil { executor.snapshot.closing }
    XCTAssertTrue(cancellation.isCancelled)
    XCTAssertEqual(executor.snapshot.bulkOperations, 1)
    do { let _: Bool = try await executor.run { true }; XCTFail("New foreground work entered a closing executor") }
    catch {}
    // Abort has a reserved cleanup slot while ordinary admission is closed.
    let joined = try await executor.run(priority: .cleanup) { true }
    XCTAssertTrue(joined)
    executor.releaseBulk(lease)
    try await closing.value
    let released = try await executor.run(priority: .lifecycle) {
      XCTAssertEqual(executor.snapshot.bulkOperations, 0)
      XCTAssertFalse(Thread.isMainThread)
      return true
    }
    XCTAssertTrue(released)
    executor.endCloseAttempt()
  }
}
