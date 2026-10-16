import BoomCore
import Foundation
import XCTest
@testable import Boom

extension BlessengerTests {
  @MainActor func testSpeechPreparationIsOwnedUntilNativeLoaderReturns() async throws {
    let entered = expectation(description: "Native preparation entered")
    var release: CheckedContinuation<BlessengerSpeechVoice, Never>?
    let output = BlessengerAudioOutput(resolveVoice: { _ in
      await withCheckedContinuation { release = $0; entered.fulfill() }
    })
    let requested = BlessengerSpeechVoice()
    let task = Task { try await output.prepare(requested) }
    await fulfillment(of: [entered], timeout: 5)
    XCTAssertTrue(output.isPreparing)
    do { _ = try await output.prepare(requested); XCTFail("A second native load was admitted.") } catch {}
    output.stop()
    XCTAssertTrue(output.isPreparing, "Cancellation has not joined the loader.")
    XCTAssertThrowsError(try output.begin(UUID(), voice: requested, attempt: UUID(), seed: 0, cancellation: CancellationFlag()))
    let joined = Task { try await output.join() }
    release?.resume(returning: requested); release = nil
    do { _ = try await task.value; XCTFail("Cancelled preparation published its voice.") }
    catch is CancellationError {} catch { XCTFail("Unexpected preparation failure: \(error)") }
    try await joined.value
    XCTAssertFalse(output.isPreparing)
    XCTAssertNil(output.responseID)
    XCTAssertFalse(output.engine.isRunning)
    try await output.shutdown()
  }

  @MainActor func testNoPCMDeadlineSettlesWithoutInventingPlaybackAndCancelsLanguageProducer() async throws {
    let output = BlessengerAudioOutput(firstAudioTimeout: .milliseconds(1))
    let id = UUID(), attempt = UUID(), owner = CancellationFlag()
    try output.begin(id, voice: BlessengerSpeechVoice(), attempt: attempt, seed: 0, cancellation: owner)
    XCTAssertFalse(output.hasPlayableAudio(id))
    let result = try await output.result(for: id, attempt: attempt)
    XCTAssertTrue(owner.isCancelled)
    XCTAssertTrue(result.interrupted)
    XCTAssertNotNil(result.failure)
    XCTAssertTrue(result.samples.isEmpty)
    XCTAssertEqual(result.heardFrames, 0)
    XCTAssertFalse(output.hasPlayableAudio(id))
    XCTAssertFalse(output.ready); XCTAssertFalse(output.speaking)
    XCTAssertTrue(result.trace.snapshot().events.contains { $0.name == "speech.firstAudioDeadline" })
    XCTAssertFalse(output.engine.isRunning)
    try await output.shutdown()
  }

  func testActualAudioSourceIdentitySurvivesMediaCompilation() throws {
    let id = UUID(), root = String(repeating: "a", count: 64), representation = String(repeating: "b", count: 64)
    let reference = WritingMediaReference(id: id, name: "Caller.wav", rootDigest: root, kind: "audio", sourceDigest: representation)
    let link = "[Caller](boom-attachment:\(id.uuidString))"
    let result = try RawWritingInput.compiled(link, media: [reference])
    XCTAssertEqual(result.prompt, "<|audio|>")
    XCTAssertEqual(result.media, [reference], "The inspected representation must not be stripped to make admission pass.")
    var invalid = reference; invalid.sourceDigest = "not-an-admitted-digest"
    XCTAssertThrowsError(try RawWritingInput.compiled(link, media: [invalid]))
  }
}
