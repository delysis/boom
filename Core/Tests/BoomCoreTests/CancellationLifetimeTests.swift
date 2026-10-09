import Foundation
import XCTest
@testable import BoomCore

final class CancellationLifetimeTests: XCTestCase {
  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  private final class ReenterOnDeinit: @unchecked Sendable {
    let flag: CancellationFlag
    let counter: Counter
    init(flag: CancellationFlag, counter: Counter) {
      self.flag = flag
      self.counter = counter
    }
    func captured() {}
    deinit {
      _ = flag.isCancelled
      counter.increment()
    }
  }

  private func registerProbe(_ flag: CancellationFlag, _ counter: Counter) -> UUID? {
    let probe = ReenterOnDeinit(flag: flag, counter: counter)
    return flag.onCancel { probe.captured() }
  }

  func testRemovingLastCaptureMayReenterFlagFromDeinit() {
    let flag = CancellationFlag(), counter = Counter()
    let registration = registerProbe(flag, counter)
    XCTAssertNotNil(registration)
    XCTAssertEqual(counter.value, 0)
    flag.removeCancellationHandler(registration)
    XCTAssertEqual(counter.value, 1)
    XCTAssertFalse(flag.isCancelled)
    flag.removeCancellationHandler(registration)
    flag.removeCancellationHandler(nil)
    flag.cancel()
    XCTAssertEqual(counter.value, 1)
  }

  func testCancellationReleasesLastCaptureOutsideLock() {
    let flag = CancellationFlag(), counter = Counter()
    _ = registerProbe(flag, counter)
    flag.cancel()
    XCTAssertEqual(counter.value, 1)
    XCTAssertTrue(flag.isCancelled)
  }

  func testLateRegistrationMayReenterCancellationAndRegisterAgain() {
    let flag = CancellationFlag(), counter = Counter()
    flag.cancel()
    XCTAssertNil(flag.onCancel {
      flag.cancel()
      _ = flag.onCancel { counter.increment() }
    })
    XCTAssertEqual(counter.value, 1)
  }
}
