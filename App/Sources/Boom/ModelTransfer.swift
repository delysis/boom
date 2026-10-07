import BoomCore
import Foundation

/// The delegate owns at most one Rust-planned range. Reject an ignored Range
/// before receiving its body; no unbounded URLSession download file is created.
final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let fileBytes: UInt64
  private let range: CheckpointRange
  private var continuation: CheckedContinuation<Data, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var cancelled = false
  // Only the serial URLSession delegate queue touches body and response state.
  private var body = Data()
  private var accepted = false
  private var failure: Error?
  private var outcome: Result<Data, Error>?

  private init(fileBytes: UInt64, range: CheckpointRange) {
    self.fileBytes = fileBytes; self.range = range
  }
  static func fetch(_ url: URL, fileBytes: UInt64, offset: UInt64,
    configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
    let range = try ProductCore.checkpointRange(fileBytes: fileBytes, offset: offset)
    let transfer = ModelTransfer(fileBytes: fileBytes, range: range)
    var request = URLRequest(url: url)
    request.setValue("bytes=\(range.first)-\(range.last)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 120
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { transfer.start($0, request: request, configuration: configuration) }
    } onCancel: { transfer.cancel() }
  }
  private func start(_ value: CheckedContinuation<Data, Error>, request: URLRequest,
    configuration: URLSessionConfiguration) {
    lock.lock()
    if cancelled { lock.unlock(); value.resume(throwing: CancellationError()); return }
    continuation = value
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    self.session = session
    let task = session.dataTask(with: request); self.task = task
    lock.unlock(); task.resume()
  }
  private func cancel() {
    lock.lock(); cancelled = true; let task = task; lock.unlock()
    task?.cancel()
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    do {
      guard let response = response as? HTTPURLResponse,
        response.url.map(DownloadPolicy.permits) == true else { throw BoomError.invalid("Unsafe model response.") }
      try ProductCore.checkpointResponse(fileBytes: fileBytes, offset: range.first, response: response)
      accepted = true; completionHandler(.allow)
    } catch { failure = error; completionHandler(.cancel) }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard accepted, UInt64(data.count) <= range.bytes - UInt64(body.count) else {
      failure = BoomError.invalid("The server exceeded its model range."); dataTask.cancel(); return
    }
    body.append(data)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let cancelled = cancelled
    self.task = nil
    lock.unlock()
    if cancelled { outcome = .failure(CancellationError()) }
    else if let failure = failure ?? error { outcome = .failure(failure) }
    else if !accepted || UInt64(body.count) != range.bytes {
      outcome = .failure(BoomError.invalid("The model range ended before its expected bytes."))
    } else { outcome = .success(body) }
    session.finishTasksAndInvalidate()
  }
  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    lock.lock()
    let value = continuation; continuation = nil
    let cancelled = cancelled
    self.session = nil
    lock.unlock()
    guard let value else { return }
    if cancelled { value.resume(throwing: CancellationError()) }
    else { value.resume(with: outcome ?? .failure(error ?? BoomError.unavailable("The model transfer session ended unexpectedly."))) }
  }
}
