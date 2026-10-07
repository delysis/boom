import BoomCore
import XCTest
@testable import Boom

final class ModelLoadTests: XCTestCase {
  func testCancelledQueuedLoadStopsBeforeReadingTheModel() async throws {
    let coordinator = GenerationCoordinator.shared
    await coordinator.enter()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-cancelled-load-" + UUID().uuidString)
    let admission = ModelPacks.Admission(directory: source, purpose: .consultation, identity: "cancelled-public-fixture", weightBytes: 1, kind: .convertedPack)
    let queued = Task { try await MLXGemmaRunner.load(admission: admission) }
    let deadline = Date().addingTimeInterval(2)
    while await coordinator.queuedOperations != 1 {
      if Date() >= deadline {
        queued.cancel(); await coordinator.leave(); _ = await queued.result
        throw BoomError.unavailable("The model load did not queue behind GPU ownership.")
      }
      await Task.yield()
    }
    queued.cancel()
    await coordinator.leave()
    do { _ = try await queued.value; XCTFail("The cancelled load completed") }
    catch is CancellationError {}
    // A missing-file error would prove the cancelled request reached model I/O.
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    await coordinator.enter(); await coordinator.leave()
  }
}
