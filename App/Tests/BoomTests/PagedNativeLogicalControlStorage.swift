import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

/// Actual SDK application bootstrap for the existing staged/managed fixtures.
/// It never overrides key-window state or substitutes physical key acceptance.
@MainActor enum PagedNativeFixtureApplication {
  private static var finishedLaunching = false
  private static var nativeKeyWindowAvailable: Bool?
  static func bootstrap() throws {
    let application = NSApplication.shared
    if application.activationPolicy() != .regular {
      _ = application.setActivationPolicy(.regular)
    }
    guard application.activationPolicy() == .regular else {
      throw BoomError.unavailable("The public SDK fixture could not acquire regular application policy.")
    }
    if !finishedLaunching {
      application.finishLaunching()
      finishedLaunching = true
    }
  }
  static func requireNativeKeyWindow() async throws {
    try bootstrap()
    if nativeKeyWindowAvailable == false {
      throw XCTSkip("The XCTest runner cannot activate a native key window; signed-app acceptance covers this route.")
    }
    guard nativeKeyWindowAvailable != true else { return }

    let application = NSApplication.shared
    let originalPolicy = application.activationPolicy()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let becameKey = XCTNSNotificationExpectation(name: NSWindow.didBecomeKeyNotification, object: window)
    defer {
      window.orderOut(nil); window.close()
      if application.activationPolicy() != originalPolicy {
        _ = application.setActivationPolicy(originalPolicy)
      }
    }
    window.showAsInvisibleNativeTestWindow()
    application.activate(ignoringOtherApps: true)
    let notification = await XCTWaiter.fulfillment(of: [becameKey], timeout: 2) == .completed
    let available = notification && application.isActive && window.isKeyWindow
    nativeKeyWindowAvailable = available
    guard available else {
      throw XCTSkip("The XCTest runner cannot activate a native key window; signed-app acceptance covers this route.")
    }
  }
  static func scratchRoot(prefix: String) throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["TMPDIR"], !path.isEmpty, path.hasPrefix("/") else {
      throw BoomError.invalid("The public SDK fixture requires its caller's absolute TMPDIR.")
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
      throw BoomError.invalid("The public SDK fixture TMPDIR is not an existing directory.")
    }
    return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(prefix + UUID().uuidString)
  }
  static func focus(_ view: PagedNativeTextView, in window: NSWindow) async throws {
    try bootstrap(); try Task.checkCancellation()
    let becameKey = window.isKeyWindow ? nil : XCTNSNotificationExpectation(
      name: NSWindow.didBecomeKeyNotification, object: window)
    window.showAsInvisibleNativeTestWindow()
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let becameKey {
      guard await XCTWaiter.fulfillment(of: [becameKey], timeout: 10) == .completed else {
        throw BoomError.unavailable("The actual SDK window did not receive its key-window notification.")
      }
    }
    try Task.checkCancellation()
    guard view.window === window, window.isKeyWindow,
      window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.unavailable("The actual SDK fixture did not retain its mounted key-window responder.")
    }
  }
}

/// Scheduling only over the real logical backend. The gates retain actual
/// returned windows or pause an actual save before entry; they mint no source,
/// history action, root output or acknowledgement. All real tasks join.
actor PagedNativeLogicalControlStorage: PagedNativeLogicalSessionStorage {
  nonisolated let engineIncarnation: UUID
  enum Point: Hashable, Sendable { case windowAfter, replacementAfter, commitBefore }
  struct Ticket: Sendable { let id: UUID }
  struct Snapshot: Sendable {
    let activeCalls: Int
    let startedCalls: Int
    let finishedCalls: Int
    let windowCalls: Int
    let publicationCalls: Int
  }
  private struct Hold {
    let point: Point
    var arrived = false
    var released = false
    var failure: Error?
    var observers: [CheckedContinuation<Void, Error>] = []
    var producer: CheckedContinuation<Void, Never>?
  }
  private let backend: PagedNativeStorageBackend
  private var pending: [Point: UUID] = [:]
  private var holds: [UUID: Hold] = [:]
  private var timers: [Task<Void, Never>] = []
  private var realJoins: [Task<Void, Never>] = []
  private var active = 0
  private var started = 0
  private var finished = 0
  private var windowCalls = 0
  private var publicationCalls = 0
  private var closing = false
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  init(_ backend: PagedNativeStorageBackend) {
    self.backend = backend; engineIncarnation = backend.engineIncarnation
  }
  func holdNext(_ point: Point) throws -> Ticket {
    guard !closing, pending[point] == nil, holds.count < 16 else {
      throw BoomError.budget("The public control has another hold or exceeds its fixed hold budget.")
    }
    let id = UUID()
    pending[point] = id; holds[id] = Hold(point: point)
    timers.append(Task { [weak self] in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      await self?.expire(id)
    })
    return Ticket(id: id)
  }
  func awaitHeld(_ ticket: Ticket) async throws {
    guard let hold = holds[ticket.id] else { throw BoomError.invalid("Unknown public scheduling hold.") }
    if let failure = hold.failure { throw failure }
    if hold.arrived { return }
    try await withCheckedThrowingContinuation { holds[ticket.id]?.observers.append($0) }
  }
  func release(_ ticket: Ticket) throws {
    guard var hold = holds[ticket.id] else { throw BoomError.invalid("Unknown public scheduling release.") }
    hold.released = true
    let producer = hold.producer; hold.producer = nil
    holds[ticket.id] = hold; producer?.resume()
  }
  private func expire(_ id: UUID) {
    guard var hold = holds[id], !hold.released else { return }
    hold.failure = BoomError.unavailable("The public scheduling control missed its ten-second deadline.")
    hold.released = true
    let observers = hold.observers, producer = hold.producer
    hold.observers.removeAll(); hold.producer = nil; holds[id] = hold
    for observer in observers { observer.resume(throwing: hold.failure!) }
    producer?.resume()
  }
  private func pass(_ point: Point?) async throws {
    guard let point, let id = pending.removeValue(forKey: point), var hold = holds[id] else { return }
    hold.arrived = true
    let observers = hold.observers; hold.observers.removeAll(); holds[id] = hold
    for observer in observers { observer.resume() }
    if !hold.released { await withCheckedContinuation { holds[id]?.producer = $0 } }
    if let failure = holds[id]?.failure { throw failure }
  }
  private func finishCall() {
    active -= 1; finished += 1
    if active == 0 {
      let waiters = idleWaiters; idleWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }
  private func failHolds(_ points: [Point?], error: Error) {
    for point in points.compactMap({ $0 }) {
      guard let id = pending.removeValue(forKey: point), var hold = holds[id] else { continue }
      hold.failure = error; hold.released = true
      let observers = hold.observers; hold.observers.removeAll(); holds[id] = hold
      for observer in observers { observer.resume(throwing: error) }
    }
  }
  private func forward<T: Sendable>(before: Point? = nil, after: Point? = nil,
    _ call: @escaping @Sendable () async throws -> T) async throws -> T {
    guard !closing, active < 8, started < 128 else {
      throw BoomError.unavailable("The public control route is closing or exceeds its call budget.")
    }
    active += 1; started += 1
    defer { finishCall() }
    do {
      try await pass(before)
      try Task.checkCancellation()
      let realCall = Task { try await call() }
      realJoins.append(Task { _ = await realCall.result })
      let result = try await withTaskCancellationHandler { try await realCall.value }
        onCancel: { realCall.cancel() }
      try await pass(after)
      try Task.checkCancellation()
      return result
    } catch {
      failHolds([before, after], error: error)
      throw error
    }
  }
  func logicalWindow(_ snapshot: PagedNativeLogicalSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int, cancellation: CancellationFlag) async throws -> PagedNativeLogicalWindow {
    windowCalls += 1
    let backend = backend
    return try await forward(after: .windowAfter) {
      try await backend.logicalWindow(snapshot, utf16Anchor: utf16Anchor,
        maximumBytes: maximumBytes, cancellation: cancellation)
    }
  }
  func logicalPosition(_ snapshot: PagedNativeLogicalSnapshot, utf16Offset: UInt64,
    rounding: UInt8, cancellation: CancellationFlag) async throws -> PagedTextSummary {
    let backend = backend
    return try await forward {
      try await backend.logicalPosition(snapshot, utf16Offset: utf16Offset,
        rounding: rounding, cancellation: cancellation)
    }
  }
  func logicalReplacement(_ snapshot: PagedNativeLogicalSnapshot, selection: PagedNativeNavigationSelection,
    replacement: Data, cancellation: CancellationFlag) async throws -> PagedNativeLogicalEdit {
    let backend = backend
    return try await forward(after: .replacementAfter) {
      try await backend.logicalReplacement(snapshot, selection: selection,
        replacement: replacement, cancellation: cancellation)
    }
  }
  func logicalCommand(_ snapshot: PagedNativeLogicalSnapshot, command: PagedNativeLogicalCommand,
    cancellation: CancellationFlag) async throws -> PagedNativeLogicalCommandResult {
    let backend = backend
    return try await forward {
      try await backend.logicalCommand(snapshot, command: command, cancellation: cancellation)
    }
  }
  nonisolated func prepareImportedSourceTransfer(_ imported: PagedTextCustodiedValue<PagedTextImportedRevision>,
    sessionID: UUID) throws -> () -> Void {
    try backend.prepareImportedSourceTransfer(imported, sessionID: sessionID)
  }
  func publishLogical(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    publicationCalls += 1
    let backend = backend
    return try await forward(before: .commitBefore) { try await backend.publishLogical(publication) }
  }
  func finishLogicalPublication(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    let backend = backend
    try await forward { try await backend.finishLogicalPublication(acknowledgement) }
  }
  func resumeLogicalPublication(_ publication: PagedNativeLogicalPublication) async throws -> PagedNativeCommitAcknowledgement {
    let backend = backend
    return try await forward { try await backend.resumeLogicalPublication(publication) }
  }
  var snapshot: Snapshot {
    Snapshot(activeCalls: active, startedCalls: started, finishedCalls: finished,
      windowCalls: windowCalls, publicationCalls: publicationCalls)
  }
  func closeAndJoin() async {
    closing = true
    for id in Array(holds.keys) {
      guard var hold = holds[id] else { continue }
      hold.released = true
      let producer = hold.producer, observers = hold.observers
      hold.producer = nil; hold.observers.removeAll(); holds[id] = hold
      producer?.resume()
      for observer in observers { observer.resume(throwing: BoomError.unavailable("The public fixture is joining.")) }
    }
    for timer in timers { timer.cancel() }
    if active != 0 { await withCheckedContinuation { idleWaiters.append($0) } }
    for join in realJoins { await join.value }
    for timer in timers { await timer.value }
  }
}
