import XCTest
@testable import Boom

final class SpeechPreparationTests: XCTestCase {
  @MainActor func testConcurrentPreparationIsJoinedOnCancellationAndCanRestart() async throws {
    var starts = 0, joined = false
    let first = Task {
      try await VoiceInput.prepareOnDeviceSpeech {
        starts += 1
        defer { joined = true }
        try await Task.sleep(for: .seconds(60))
      }
    }
    for _ in 0..<1_000 { if starts > 0 { break }; await Task.yield() }
    XCTAssertEqual(starts, 1)
    let second = Task { try await VoiceInput.prepareOnDeviceSpeech { starts += 1 } }
    for _ in 0..<10 { await Task.yield() }
    await VoiceInput.cancelSpeechPreparationAndJoin()
    XCTAssertTrue(joined, "Cancellation must join the owned installation attempt.")
    for task in [first, second] {
      do { try await task.value; XCTFail("Cancelled preparation succeeded") }
      catch { XCTAssertTrue(error is CancellationError) }
    }
    XCTAssertEqual(starts, 1, "Concurrent callers must share one installation attempt.")
    try await VoiceInput.prepareOnDeviceSpeech { starts += 1 }
    XCTAssertEqual(starts, 2)
  }

  @MainActor func testWorkspaceShutdownJoinsAnActivePreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-speech-lifecycle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: root), loadModels: false)
    var started = false, joined = false
    let preparation = Task {
      try await VoiceInput.prepareOnDeviceSpeech {
        started = true
        defer { joined = true }
        try await Task.sleep(for: .seconds(60))
      }
    }
    for _ in 0..<1_000 { if started { break }; await Task.yield() }
    XCTAssertTrue(started)
    try await model.shutdown()
    XCTAssertTrue(joined)
    do { try await preparation.value; XCTFail("Shutdown left preparation running") }
    catch { XCTAssertTrue(error is CancellationError) }
  }
}
