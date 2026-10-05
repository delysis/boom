import Foundation
import XCTest
@testable import BoomCore

final class CancellationTests: XCTestCase {
  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  }
  func testCallbackRunsOnceAndCanReenterFlag() {
    let flag = CancellationFlag(), counter = Counter()
    let registration = flag.onCancel {
      if flag.isCancelled { counter.increment() }
      flag.cancel()
    }
    flag.cancel(); flag.cancel(); flag.removeCancellationHandler(registration)
    XCTAssertEqual(counter.value, 1)
  }
  func testCancelledFlagInvokesLateRegistrationImmediately() {
    let flag = CancellationFlag(), counter = Counter()
    flag.cancel()
    XCTAssertNil(flag.onCancel { counter.increment() })
    XCTAssertEqual(counter.value, 1)
  }
  func testRemovedRegistrationIsNotCalled() {
    let flag = CancellationFlag(), counter = Counter()
    let registration = flag.onCancel { counter.increment() }
    flag.removeCancellationHandler(registration); flag.cancel()
    XCTAssertEqual(counter.value, 0)
  }
  func testConcurrentRegistrationAndCancellationNeverMissOrDuplicateCallback() {
    for _ in 0..<200 {
      let flag = CancellationFlag(), counter = Counter()
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 { _ = flag.onCancel { counter.increment() } }
        else { flag.cancel() }
      }
      XCTAssertEqual(counter.value, 1)
    }
  }
}
