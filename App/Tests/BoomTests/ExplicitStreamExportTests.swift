import BoomCore
import Foundation
import XCTest
@testable import Boom

final class ExplicitStreamExportTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-stream-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    addTeardownBlock { [weak self] in
      guard self?.testRun?.failureCount == 0 else {
        print("Failed public export fixture retained at \(root.path)")
        return
      }
      try FileManager.default.removeItem(at: root)
    }
    return root
  }

  func testNativeReplacementPublishesExactBoundedChunksOffMain() async throws {
    let root = try fixture(), target = root.appendingPathComponent("chosen.md")
    try Data("Original chosen export".utf8).write(to: target)
    let chunk = Data("\u{feff}Café 👩🏽‍💻\r\n".utf8)
    let destination = try await ExplicitFileExport.write(to: target, stream: { file in
      XCTAssertFalse(Thread.isMainThread)
      for _ in 0..<1_024 { try file.write(contentsOf: chunk) }
    })
    XCTAssertEqual(destination.standardizedFileURL, target.standardizedFileURL)
    var expected = Data()
    for _ in 0..<1_024 { expected.append(chunk) }
    XCTAssertEqual(try Data(contentsOf: target), expected)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber,
      NSNumber(value: 0o600))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["chosen.md"])
  }

  func testActualPartialWriterFailureRetainsChosenFileAndEmptyExportIsSupported() async throws {
    let root = try fixture(), target = root.appendingPathComponent("chosen.bin")
    let original = Data([0, 1, 0xff, 0xfe, 0x80])
    try original.write(to: target)
    do {
      _ = try await ExplicitFileExport.write(to: target, stream: { file in
        try file.write(contentsOf: Data("Partial public export".utf8))
        throw BoomError.invalid("Public actual writer refusal.")
      })
      XCTFail("Failed stream replaced the chosen file")
    } catch {
      XCTAssertEqual(try Data(contentsOf: target), original)
      XCTAssertFalse(error is ExplicitStreamExportFailure, "Known unpublished cleanup must actually join.")
    }
    _ = try await ExplicitFileExport.write(to: target, stream: { _ in })
    XCTAssertEqual(try Data(contentsOf: target), Data())
    let fresh = root.appendingPathComponent("fresh.bin")
    _ = try await ExplicitFileExport.write(to: fresh, stream: { file in try file.write(contentsOf: original) })
    XCTAssertEqual(try Data(contentsOf: fresh), original)
  }

  @MainActor func testCancellationAfterPartialStreamCannotPublishReplacement() async throws {
    let root = try fixture(), target = root.appendingPathComponent("chosen.md")
    let original = Data("Original public chosen file".utf8)
    try original.write(to: target)
    let entered = expectation(description: "Actual partial stream entered")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let task = Task {
      try await ExplicitFileExport.write(to: target, stream: { file in
        try file.write(contentsOf: Data("Partial replacement".utf8))
        entered.fulfill()
        guard release.wait(timeout: .now() + .seconds(3)) == .success else { throw CancellationError() }
      })
    }
    await fulfillment(of: [entered], timeout: 2)
    task.cancel()
    release.signal()
    do { _ = try await task.value; XCTFail("Cancelled stream published") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try Data(contentsOf: target), original)
  }

  func testExplicitTokenCancellationAtStreamCompletionCannotPublishReplacement() async throws {
    let root = try fixture(), target = root.appendingPathComponent("chosen.md")
    let original = Data("Original public chosen file".utf8)
    try original.write(to: target)
    let cancellation = PagedTextCancellation()
    do {
      _ = try await ExplicitFileExport.write(to: target, checkCancellation: {
        if cancellation.isCancelled { throw CancellationError() }
      }, stream: { file in
        try file.write(contentsOf: Data("Complete but cancelled replacement".utf8))
        cancellation.cancel()
      })
      XCTFail("Explicitly cancelled stream replaced the chosen file")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try Data(contentsOf: target), original)
  }

  @MainActor func testCancellationJoinsWhileActualFilePresenterStillHoldsWriter() async throws {
    let root = try fixture(), target = root.appendingPathComponent("chosen.md")
    let original = Data("Original public presented export".utf8)
    try original.write(to: target)
    let entered = expectation(description: "Actual presenter holds writer admission")
    let returned = expectation(description: "Actual presenter callback returned")
    let completed = expectation(description: "Cancelled export task joined while writer held")
    let presenter = HeldStreamExportPresenter(url: target, entered: entered, returned: returned)
    NSFileCoordinator.addFilePresenter(presenter)
    var registered = true
    defer {
      presenter.releaseWriter()
      if registered { NSFileCoordinator.removeFilePresenter(presenter) }
    }
    let task = Task {
      let result: Result<URL, Error>
      do {
        result = .success(try await ExplicitFileExport.write(to: target, stream: { file in
          try file.write(contentsOf: Data("Complete staged public replacement".utf8))
        }))
      } catch { result = .failure(error) }
      let joinedWhileHeld = presenter.isHoldingWriter
      completed.fulfill()
      return (result, joinedWhileHeld)
    }
    await fulfillment(of: [entered], timeout: 2)
    task.cancel()
    // Release happens AFTER this awaited completion. The five-second presenter
    // deadline bounds cleanup even if interruption fails; it is not a pass.
    await fulfillment(of: [completed], timeout: 2)
    presenter.releaseWriter()
    let (result, joinedWhileHeld) = await task.value
    await fulfillment(of: [returned], timeout: 2)
    NSFileCoordinator.removeFilePresenter(presenter)
    registered = false
    try await detachedWork { presenter.presentedItemOperationQueue.waitUntilAllOperationsAreFinished() }
    XCTAssertTrue(joinedWhileHeld, "Cancelling only a flag cannot interrupt the real coordinator wait.")
    XCTAssertFalse(presenter.didTimeOut, "Presenter fallback deadline is a cleanup failure.")
    switch result {
    case .success: XCTFail("Cancelled coordinated export published")
    case .failure(let error):
      let cocoa = error as NSError
      XCTAssertTrue(error is CancellationError ||
        (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError),
        "Original cancellation outcome must be retained: \(error)")
    }
    XCTAssertEqual(try Data(contentsOf: target), original)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["chosen.md"])
  }

  func testSelectedSymlinkAndDirectoryCannotReplaceTheirTargets() async throws {
    let root = try fixture(), original = root.appendingPathComponent("original.md")
    let bytes = Data("Original retained outside the selected symlink".utf8)
    try bytes.write(to: original)
    let link = root.appendingPathComponent("chosen.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    do {
      _ = try await ExplicitFileExport.write(to: link, stream: { file in try file.write(contentsOf: Data("Replacement".utf8)) })
      XCTFail("Export replaced a selected symlink")
    } catch { XCTAssertEqual(try Data(contentsOf: original), bytes) }
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), original.path)
    let directory = root.appendingPathComponent("chosen-directory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
      _ = try await ExplicitFileExport.write(to: directory, stream: { file in try file.write(contentsOf: bytes) })
      XCTFail("Export replaced a directory")
    } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path)) }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }
}

/// This real file presenter delays its mandatory writer callback on its own
/// serial queue. Immutable handles are thread-safe; mutable facts use the lock.
private final class HeldStreamExportPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  private let entered: XCTestExpectation
  private let returned: XCTestExpectation
  private let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var holding = false
  private var timedOut = false

  init(url: URL, entered: XCTestExpectation, returned: XCTestExpectation) {
    presentedItemURL = url; self.entered = entered; self.returned = returned
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "Bloom-public-export-presenter"
    presentedItemOperationQueue = queue
    super.init()
  }
  var isHoldingWriter: Bool {
    lock.lock(); defer { lock.unlock() }; return holding
  }
  var didTimeOut: Bool {
    lock.lock(); defer { lock.unlock() }; return timedOut
  }
  func releaseWriter() { release.signal() }
  func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
    lock.lock(); holding = true; lock.unlock()
    entered.fulfill()
    let expired = release.wait(timeout: .now() + .seconds(5)) != .success
    lock.lock(); timedOut = timedOut || expired; holding = false; lock.unlock()
    // Apple's contract requires this callback even after coordination cancels.
    writer(nil)
    returned.fulfill()
  }
}
