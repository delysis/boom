import Foundation
import XCTest
#if canImport(Boom)
@testable import Boom
#else
@testable import BlessengerPortable
#endif

final class BlessengerPlaybackProgressTests: XCTestCase {
  func testSourceCompletionCannotCreditQueuedAudio() throws {
    var progress = SpeechPlaybackProgress()
    let a = try progress.schedule(frames: 100), b = try progress.schedule(frames: 200)
    XCTAssertEqual(progress.scheduledFrames, 300)
    XCTAssertEqual(progress.deliveredFrames, 0)
    XCTAssertFalse(progress.isDrained)
    XCTAssertTrue(progress.played(a))
    XCTAssertEqual(progress.deliveredFrames, 100)
    XCTAssertFalse(progress.isDrained, "The last scheduled buffer still owns 200 frames.")
    XCTAssertTrue(progress.played(b))
    XCTAssertEqual(progress.deliveredFrames, 300)
    XCTAssertTrue(progress.isDrained)
  }

  func testEveryAcknowledgementOrderAdvancesOnlyTheContiguousPrefix() throws {
    func permutations(_ values: [Int]) -> [[Int]] {
      if values.isEmpty { return [[]] }
      return values.flatMap { head in permutations(values.filter { $0 != head }).map { [head] + $0 } }
    }
    for order in permutations(Array(0..<5)) {
      var progress = SpeechPlaybackProgress(), played = Set<Int>()
      let tickets = try (0..<5).map { _ in try progress.schedule(frames: 17) }
      for index in order {
        XCTAssertTrue(progress.played(tickets[index])); played.insert(index)
        let contiguous = (0..<5).prefix(while: played.contains).count
        XCTAssertEqual(progress.deliveredFrames, contiguous * 17, "order: \(order)")
        XCTAssertEqual(progress.pendingFrames, (5 - played.count) * 17)
        XCTAssertEqual(progress.isDrained, played.count == 5)
        XCTAssertFalse(progress.played(tickets[index]), "A duplicate must not release queue capacity twice.")
      }
    }
  }

  func testStopFreezesDeliveryBeforeLateAndForeignCallbacks() throws {
    var old = SpeechPlaybackProgress()
    let heard = try old.schedule(frames: 5), unplayed = try old.schedule(frames: 50)
    old.played(heard); old.retire()
    XCTAssertFalse(old.played(unplayed))
    XCTAssertEqual(old.deliveredFrames, 5)
    XCTAssertThrowsError(try old.schedule(frames: 1))
    var next = SpeechPlaybackProgress()
    let current = try next.schedule(frames: 10)
    XCTAssertFalse(next.played(unplayed))
    XCTAssertEqual(next.pendingFrames, 10); XCTAssertEqual(next.deliveredFrames, 0)
    XCTAssertTrue(next.played(current)); XCTAssertEqual(next.deliveredFrames, 10)
  }

  func testAdmissionBoundsDoNotChangeAnyCursorOnFailure() throws {
    var progress = SpeechPlaybackProgress(maximumFrames: 5, maximumPackets: 2)
    XCTAssertThrowsError(try progress.schedule(frames: 0))
    XCTAssertThrowsError(try progress.schedule(frames: -1))
    XCTAssertThrowsError(try progress.schedule(frames: Int.max))
    let a = try progress.schedule(frames: 2), b = try progress.schedule(frames: 2)
    XCTAssertThrowsError(try progress.schedule(frames: 1))
    XCTAssertEqual(progress.scheduledFrames, 4); XCTAssertEqual(progress.pendingFrames, 4)
    progress.played(a)
    let c = try progress.schedule(frames: 1)
    XCTAssertEqual(progress.scheduledFrames, 5)
    XCTAssertThrowsError(try progress.schedule(frames: 1))
    progress.played(c)
    XCTAssertEqual(progress.deliveredFrames, 2)
    progress.played(b)
    XCTAssertEqual(progress.deliveredFrames, 5); XCTAssertTrue(progress.isDrained)
  }

  func testRetiredPlayerNeverGrantsDeliveryEvenAfterAllCallbacks() throws {
    var progress = SpeechPlaybackProgress()
    let tickets = try (0..<32).map { _ in try progress.schedule(frames: 80) }
    progress.retire()
    for ticket in tickets { XCTAssertFalse(progress.played(ticket)) }
    XCTAssertEqual(progress.deliveredFrames, 0)
    XCTAssertEqual(progress.scheduledFrames, 2560)
  }
}
