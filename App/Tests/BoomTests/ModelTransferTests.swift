import BoomCore
import XCTest
@testable import Boom

private final class RangeProtocol: URLProtocol, @unchecked Sendable {
  private final class Observations: @unchecked Sendable {
    let lock = NSLock()
    var starts: Set<String> = [], stops: Set<String> = []
    func record(_ path: String, stopped: Bool = false) { lock.lock(); defer { lock.unlock() }; if stopped { stops.insert(path) } else { starts.insert(path) } }
    func contains(_ path: String, stopped: Bool = false) -> Bool { lock.lock(); defer { lock.unlock() }; return (stopped ? stops : starts).contains(path) }
  }
  private static let observations = Observations()
  static func started(_ path: String) -> Bool { observations.contains(path) }
  static func stopped(_ path: String) -> Bool { observations.contains(path, stopped: true) }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    let mode = url.pathComponents[1]
    Self.observations.record(url.path)
    let headers: [String: String]
    let status: Int
    let bytes: Data?
    switch mode {
    case "success", "wait":
      guard request.value(forHTTPHeaderField: "Range") == "bytes=40-99",
        request.value(forHTTPHeaderField: "Authorization") == nil,
        request.value(forHTTPHeaderField: "Cookie") == nil else {
        client?.urlProtocol(self, didFailWithError: BoomError.invalid("Wrong or credentialed range request.")); return
      }
      headers = ["Content-Range": "bytes 40-99/100", "Content-Length": "60"]; status = 206
      bytes = mode == "wait" ? nil : Data(repeating: 0x61, count: 60)
    case "ignored": headers = ["Content-Length": "67108864"]; status = 200; bytes = Data([0x61])
    case "overflow": headers = ["Content-Range": "bytes 0-9/10"]; status = 206; bytes = Data(repeating: 0x61, count: 11)
    default: headers = ["Content-Range": "bytes 40-99/100", "Content-Length": "60"]; status = 206; bytes = Data(repeating: 0x61, count: 59)
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let bytes { client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self) }
  }
  override func stopLoading() { if let path = request.url?.path { Self.observations.record(path, stopped: true) } }
}

final class ModelTransferTests: XCTestCase {
  private func url(_ mode: String) -> URL { URL(string: "https://huggingface.co/" + mode + "/" + UUID().uuidString)! }
  private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RangeProtocol.self]; return configuration
  }
  func testResumedRangeReturnsOnlyTheRequestedBytesAnonymously() async throws {
    let data = try await ModelTransfer.fetch(url("success"), fileBytes: 100, offset: 40, configuration: configuration())
    XCTAssertEqual(data, Data(repeating: 0x61, count: 60))
  }
  func testIgnoredRangeOverflowAndTruncatedBodiesNeverBecomeAcceptedData() async throws {
    for mode in ["ignored", "overflow", "short"] {
      do {
        _ = try await ModelTransfer.fetch(url(mode), fileBytes: mode == "ignored" ? 67_108_864 : mode == "overflow" ? 10 : 100,
          offset: mode == "short" ? 40 : 0, configuration: configuration())
        XCTFail("Accepted " + mode)
      } catch { XCTAssertFalse(error is CancellationError) }
    }
  }
  func testCancellationJoinsAnAlreadyStartedTransfer() async throws {
    let url = url("wait")
    let operation = Task { try await ModelTransfer.fetch(url, fileBytes: 100, offset: 40, configuration: configuration()) }
    let deadline = Date().addingTimeInterval(2)
    while !RangeProtocol.started(url.path) {
      if Date() >= deadline { operation.cancel(); _ = await operation.result; XCTFail("Transfer never started"); return }
      await Task.yield()
    }
    operation.cancel()
    do { _ = try await operation.value; XCTFail("Cancelled transfer completed") } catch is CancellationError {}
    XCTAssertTrue(RangeProtocol.stopped(url.path))
  }
}
