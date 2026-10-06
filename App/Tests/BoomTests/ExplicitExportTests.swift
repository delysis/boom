import AppKit
import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class ExplicitExportTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-explicit-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  @MainActor func testExportRunsOffMainWithoutTakingForegroundAndShutdownJoinsCapturedBytes() async throws {
    let root = try fixture(), url = root.appendingPathComponent("chosen.md")
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted"), testKey: SymmetricKey(size: .bits256))
    let initial = DocumentSnapshot(title: "Public export fixture", text: "")
    var state = WorkspaceState(); state.autocomplete = false; state.selectedDocument = initial.id
    state.documents = [DocumentIndex(id: initial.id, title: initial.title)]
    try await store.save(state, documents: [initial])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let document = try XCTUnwrap(model.selectedDocument)
    let text = "\u{feff}Export canary Café 👩🏽‍💻\r\nCaptured bytes.\n"
    model.updateDocument(text, id: document.id, caret: text.utf16.count)
    let captured = try XCTUnwrap(model.selectedDocument)
    let started = expectation(description: "Export serializer started"), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    model.work("Unrelated public foreground operation") { flag in
      while true { try flag.check(); try await Task.sleep(for: .milliseconds(10)) }
    }
    model.exportFile(to: url) {
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill()
      guard release.wait(timeout: .now() + .seconds(3)) == .success else { throw CancellationError() }
      return Data(captured.text.utf8)
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(model.isBusy, "An explicit export must not consume or cancel the foreground operation.")
    model.updateDocument("A later human edit.", id: document.id, caret: 0)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    release.signal()
    try await model.shutdown()
    XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
    let reopened = try await store.load().get().1
    XCTAssertEqual(reopened.first { $0.id == document.id }?.text, "A later human edit.")
    XCTAssertNil(model.errorMessage)
  }
  @MainActor func testCancellationAfterSerializationStartsCannotReplaceChosenFile() async throws {
    let root = try fixture(), url = root.appendingPathComponent("chosen.bin")
    let original = Data([0, 1, 0xff, 0xfe]); try original.write(to: url)
    let started = expectation(description: "Serializer paused"), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let operation = Task {
      try await ExplicitFileExport.write(to: url) {
        started.fulfill()
        guard release.wait(timeout: .now() + .seconds(3)) == .success else { throw CancellationError() }
        return Data("Replacement must not escape.".utf8)
      }
    }
    await fulfillment(of: [started], timeout: 2)
    operation.cancel(); release.signal()
    do { try await operation.value; XCTFail("Cancelled export published") } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["chosen.bin"])
  }
  func testSerializationFailureLeavesExistingFileAndBinaryOriginalIsExact() async throws {
    let root = try fixture(), url = root.appendingPathComponent("chosen.bin")
    let original = Data([0, 1, 0xff, 0xfe, 0, 0x80]); try original.write(to: url)
    do {
      try await ExplicitFileExport.write(to: url) { throw BoomError.invalid("Public fixture serialization failure.") }
      XCTFail("Failed serialization published")
    } catch { XCTAssertEqual(try Data(contentsOf: url), original) }
    let captured = Data((0..<256).map(UInt8.init))
    try await ExplicitFileExport.write(to: url) { captured }
    XCTAssertEqual(try Data(contentsOf: url), captured)
  }
  @MainActor func testDestinationFailureIsReportedAndWorkspaceRemainsEncrypted() async throws {
    let root = try fixture()
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted"), testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    model.exportFile(to: root.appendingPathComponent("absent/chosen.md")) { Data("Public denied export canary.".utf8) }
    try await model.shutdown()
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), ["Private"])
  }
  @MainActor func testLaterExportToSameDestinationPublishesAfterTheEarlierRequest() async throws {
    let root = try fixture(), url = root.appendingPathComponent("chosen.md")
    let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted"), testKey: SymmetricKey(size: .bits256))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let first = expectation(description: "First export paused"), later = expectation(description: "Later export started")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    model.exportFile(to: url) {
      first.fulfill()
      guard release.wait(timeout: .now() + .seconds(3)) == .success else { throw CancellationError() }
      return Data("Earlier captured value.".utf8)
    }
    await fulfillment(of: [first], timeout: 2)
    model.exportFile(to: url) { later.fulfill(); return Data("Later captured value.".utf8) }
    try await Task.sleep(for: .milliseconds(50))
    // Let a concurrent buggy writer publish before releasing the older one.
    release.signal()
    try await model.shutdown()
    await fulfillment(of: [later], timeout: 2)
    XCTAssertEqual(try Data(contentsOf: url), Data("Later captured value.".utf8))
    XCTAssertNil(model.errorMessage)
  }
}
