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

  func testBackgroundExportCannotConsumeTheForegroundContinuationSlot() throws {
    let executor = PagedTextStorageExecutor()
    let background = try executor.reserveBulk(PagedTextCancellation())
    defer { executor.releaseBulk(background) }
    XCTAssertThrowsError(try executor.reserveBulk(PagedTextCancellation()))
    let edit = try executor.reserveBulk(PagedTextCancellation(), priority: .foreground)
    XCTAssertEqual(executor.snapshot.bulkOperations, 2)
    XCTAssertThrowsError(try executor.reserveBulk(PagedTextCancellation(), priority: .foreground))
    executor.releaseBulk(edit)
    let nextEdit = try executor.reserveBulk(PagedTextCancellation(), priority: .foreground)
    executor.releaseBulk(nextEdit)
    XCTAssertEqual(executor.snapshot.bulkOperations, 1)
  }

  func testCompletedJobsReleaseAdmissionBeforeTheirProducersContinue() async throws {
    let executor = PagedTextStorageExecutor()
    // Lifecycle has one actual slot. A sequential caller must never compete
    // with its own completed predecessor, on either success or failure.
    for value in 0..<256 {
      let actual = try await executor.run(priority: .lifecycle) { value }
      XCTAssertEqual(actual, value)
    }
    do {
      let _: Int = try await executor.run(priority: .lifecycle) {
        throw BoomError.invalid("Public failed source job")
      }
      XCTFail("The actual failed work unexpectedly returned")
    } catch {
      XCTAssertEqual(error.localizedDescription, BoomError.invalid("Public failed source job").localizedDescription)
    }
    let following = try await executor.run(priority: .lifecycle) { true }
    XCTAssertTrue(following)
    // This is the real two-mode producer shape: each producer submits its
    // next bounded step only after its own previous step has returned.
    let total = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<2 {
        group.addTask {
          var sum = 0
          for value in 0..<2_000 {
            sum += try await executor.run(priority: .background) { value }
          }
          return sum
        }
      }
      var sum = 0
      for try await value in group { sum += value }
      return sum
    }
    XCTAssertEqual(total, 2 * (1_999 * 2_000 / 2))
    XCTAssertEqual(executor.snapshot.backgroundRequests, 0)
    XCTAssertFalse(executor.snapshot.closing)
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
