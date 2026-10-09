import BoomCore
import XCTest
@testable import Boom

private final class RangeProtocol: URLProtocol, @unchecked Sendable {
  private final class Observations: @unchecked Sendable {
    let lock = NSLock()
    var starts: Set<String> = [], stops: Set<String> = [], returns: Set<String> = []
    var consumed: [String: UInt64] = [:]
    func record(_ path: String, stopped: Bool = false) { lock.lock(); defer { lock.unlock() }; if stopped { stops.insert(path) } else { starts.insert(path) } }
    func contains(_ path: String, stopped: Bool = false) -> Bool { lock.lock(); defer { lock.unlock() }; return (stopped ? stops : starts).contains(path) }
    func receive(_ path: String, count: UInt64) { lock.lock(); defer { lock.unlock() }; consumed[path] = count }
    func bytes(_ path: String) -> UInt64 { lock.lock(); defer { lock.unlock() }; return consumed[path] ?? 0 }
    func returned(_ path: String) { lock.lock(); defer { lock.unlock() }; returns.insert(path) }
    func hasReturned(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return returns.contains(path) }
  }
  private static let observations = Observations()
  static func started(_ path: String) -> Bool { observations.contains(path) }
  static func stopped(_ path: String) -> Bool { observations.contains(path, stopped: true) }
  static func bytes(_ path: String) -> UInt64 { observations.bytes(path) }
  static func received(_ path: String, count: UInt64) { observations.receive(path, count: count) }
  static func returned(_ path: String) { observations.returned(path) }
  static func hasReturned(_ path: String) -> Bool { observations.hasReturned(path) }
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
      let expectedRange = mode == "wait" ? "bytes=65536-262143" : "bytes=40-99"
      guard request.value(forHTTPHeaderField: "Range") == expectedRange,
        request.value(forHTTPHeaderField: "Authorization") == nil,
        request.value(forHTTPHeaderField: "Cookie") == nil else {
        client?.urlProtocol(self, didFailWithError: BoomError.invalid("Wrong or credentialed range request.")); return
      }
      headers = mode == "wait"
        ? ["Content-Range": "bytes 65536-262143/262144", "Content-Length": "196608"]
        : ["Content-Range": "bytes 40-99/100", "Content-Length": "60"]
      status = 206
      bytes = Data(repeating: 0x61, count: mode == "wait" ? 65536 : 60)
    case "ignored": headers = ["Content-Length": "67108864"]; status = 200; bytes = Data([0x61])
    case "overflow": headers = ["Content-Range": "bytes 0-9/10"]; status = 206; bytes = Data(repeating: 0x61, count: 11)
    default: headers = ["Content-Range": "bytes 40-99/100", "Content-Length": "60"]; status = 206; bytes = Data(repeating: 0x61, count: 59)
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let bytes { client?.urlProtocol(self, didLoad: bytes) }
    if mode != "wait" { client?.urlProtocolDidFinishLoading(self) }
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
  func testCancellationJoinsCallbacksAndStopsStartedTransport() async throws {
    for _ in 0..<16 {
      let url = url("wait")
      let consumerGate = DispatchSemaphore(value: 0)
      defer { consumerGate.signal() }
      let operation = Task {
        defer { RangeProtocol.returned(url.path) }
        return try await ModelTransfer.fetch(url, fileBytes: 262144, offset: 65536, configuration: configuration(),
          receivedBytes: { count in
            RangeProtocol.received(url.path, count: count)
            consumerGate.wait()
          })
      }
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      // Headers being submitted does not establish that URLSession has
      // accepted them and started receiving the body. Cancel only after its
      // validated body-byte callback arrives.
      while RangeProtocol.bytes(url.path) == 0 {
        if ContinuousClock().now >= deadline { consumerGate.signal(); operation.cancel(); _ = await operation.result; XCTFail("Transfer never prepared"); return }
        try await Task.sleep(for: .milliseconds(1))
      }
      operation.cancel()
      // Deliberately hold an active consumer callback across cancellation.
      // Returning early would leave app-owned work running after fetch ended.
      try await Task.sleep(for: .milliseconds(25))
      XCTAssertFalse(RangeProtocol.hasReturned(url.path))
      consumerGate.signal()
      do { _ = try await operation.value; XCTFail("Cancelled transfer completed") } catch is CancellationError {}
      XCTAssertTrue(RangeProtocol.started(url.path))
      let bytesAtReturn = RangeProtocol.bytes(url.path)
      // finishTasksAndInvalidate joins session delegates. URLProtocol's
      // separate transport stop callback has no documented ordering relative
      // to session invalidation; require its acknowledgement independently.
      let stopDeadline = ContinuousClock().now.advanced(by: .seconds(2))
      while !RangeProtocol.stopped(url.path), ContinuousClock().now < stopDeadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      XCTAssertTrue(RangeProtocol.stopped(url.path))
      XCTAssertEqual(RangeProtocol.bytes(url.path), bytesAtReturn,
        "The consumer must receive no body callbacks after cancellation returns.")
    }
  }
}
