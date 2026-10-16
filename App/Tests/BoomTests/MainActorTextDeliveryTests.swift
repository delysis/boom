import XCTest
@testable import Boom

final class MainActorTextDeliveryTests: XCTestCase {
  @MainActor private final class Display {
    var values: [String] = []
    var text = "initial"
    weak var delivery: MainActorTextDelivery?
  }
  @MainActor func testNativeActionCoalescesProgressAndCloseRejectsLaterUpdates() async {
    let published = expectation(description: "latest progress published")
    let display = Display()
    let delivery = MainActorTextDelivery { text in
      display.values.append(text)
      published.fulfill()
    }
    // The actual MainActor action prevents its queued publication from
    // entering until these producer updates have all been submitted.
    for value in 0..<1000 { delivery.submit(String(value)) }
    guard await XCTWaiter.fulfillment(of: [published], timeout: 5) == .completed else {
      XCTFail("Queued progress did not enter.")
      await delivery.closeAndJoin()
      return
    }
    XCTAssertEqual(display.values, ["999"])
    await delivery.closeAndJoin()
    delivery.submit("obsolete")
    await delivery.closeAndJoin()
    XCTAssertEqual(display.values, ["999"])
  }

  @MainActor func testProgressArrivingDuringPublicationIsDeliveredOnAnotherTurn() async {
    let published = expectation(description: "next progress published")
    let display = Display()
    let delivery = MainActorTextDelivery { text in
      display.values.append(text)
      if text == "first" { display.delivery?.submit("second") }
      else { published.fulfill() }
    }
    display.delivery = delivery
    delivery.submit("first")
    guard await XCTWaiter.fulfillment(of: [published], timeout: 5) == .completed else {
      XCTFail("Progress arriving during native publication was lost.")
      await delivery.closeAndJoin()
      return
    }
    await delivery.closeAndJoin()
    XCTAssertEqual(display.values, ["first", "second"])
  }

  @MainActor func testFinalPublicationJoinsQueuedProgressBeforeItCanOverwriteFinalText() async {
    let display = Display()
    let delivery = MainActorTextDelivery { display.text = $0 }
    delivery.submit("old partial answer")
    await delivery.closeAndJoin()
    display.text = "final answer"
    delivery.submit("late partial answer")
    await delivery.closeAndJoin()
    XCTAssertEqual(display.text, "final answer")
  }
}
