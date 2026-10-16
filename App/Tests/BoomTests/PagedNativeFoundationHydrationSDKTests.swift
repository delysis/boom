import Foundation
import XCTest

/// SOURCE-ONLY, UNRUN. These two controls investigate actual public Foundation
/// stack construction/reentry. They do not substitute for encrypted engine,
/// command-owner, native input, ACK custody or ordinary application controls.
@MainActor private final class CanonicalSDKManager: UndoManager {
  var request: ((Bool) -> Void)?
  override func undo() { request?(false) }
  override func redo() { request?(true) }
  override func undoNestedGroup() { request?(false) }
  func admittedUndo() { super.undoNestedGroup() }
  func admittedRedo() { super.redo() }
}

@MainActor private final class CanonicalSDKAction: NSObject {
  let group: String
  let cursor: Int
  let redo: Bool
  init(_ group: String, cursor: Int, redo: Bool) {
    self.group = group; self.cursor = cursor; self.redo = redo
  }
}

@MainActor private final class CanonicalSDKOwner {
  static let key = UndoManager.UserInfoKey(rawValue: "public.canonical-sdk-control")
  let manager = CanonicalSDKManager()
  // Foundation does not retain handler targets. The harness owns all of its
  // fixed <=6 metadata targets, including synchronous inverse registrations.
  var targets: [CanonicalSDKAction] = []
  var hydrating = false
  var queued: [Bool] = []
  var userHandlers: [(String, Int, Bool)] = []
  var expected: CanonicalSDKAction?

  init() {
    manager.groupsByEvent = false; manager.levelsOfUndo = 100
    manager.request = { [weak self] redo in
      guard let self else { return }
      precondition(self.queued.count < 4)
      self.queued.append(redo)
    }
  }
  func register(_ action: CanonicalSDKAction) {
    precondition(targets.count < 16)
    targets.append(action)
    manager.registerUndo(withTarget: action) { [weak self] target in self?.consume(target) }
    manager.setActionName("Edit")
    manager.setActionUserInfoValue(action, forKey: Self.key)
  }
  private func consume(_ action: CanonicalSDKAction) {
    if hydrating {
      precondition(!action.redo && manager.isUndoing)
      register(CanonicalSDKAction(action.group, cursor: action.cursor, redo: true))
      return
    }
    precondition(expected === action)
    precondition(action.redo ? manager.isRedoing : manager.isUndoing)
    userHandlers.append((action.group, action.cursor, action.redo))
    // This is an SDK metadata harness, not a source adoption or durable ACK.
    register(CanonicalSDKAction(action.group, cursor: action.cursor, redo: !action.redo))
  }
  func hydrate(undo: [(String, Int)], redo: [(String, Int)]) {
    precondition(undo.count + redo.count <= 100 && manager.undoCount == 0 && manager.redoCount == 0)
    hydrating = true
    defer { hydrating = false }
    // Register ALL ordinary Undo actions before producing Redo. A later normal
    // registration would clear the Redo stack just created by these real calls.
    for item in undo + redo.reversed() {
      manager.beginUndoGrouping()
      register(CanonicalSDKAction(item.0, cursor: item.1, redo: false))
      manager.endUndoGrouping()
    }
    for _ in redo { manager.admittedUndo() }
  }
  func top(redo: Bool) throws -> CanonicalSDKAction {
    let value = redo ? manager.redoActionUserInfoValue(forKey: Self.key)
      : manager.undoActionUserInfoValue(forKey: Self.key)
    return try XCTUnwrap(value as? CanonicalSDKAction)
  }
  func admitUser(redo: Bool) throws {
    precondition(!hydrating && manager.groupingLevel == 0)
    expected = try top(redo: redo)
    defer { expected = nil }
    if redo { manager.admittedRedo() } else { manager.admittedUndo() }
  }
  func dispose() {
    manager.request = nil
    manager.removeAllActions()
    targets.removeAll()
  }
}

@MainActor final class PagedNativeFoundationHydrationSDKTests: XCTestCase {
  func testActualSDKHydratesUndoAndRedoInCorrectOrderBeforeAnyUserHandler() throws {
    let owner = CanonicalSDKOwner()
    defer { owner.dispose() }
    // Bottom-first canonical stacks: Undo g1; Redo g3, g2 (g2 is next).
    owner.hydrate(undo: [("g1", 11)], redo: [("g3", 33), ("g2", 22)])
    XCTAssertEqual(owner.manager.undoCount, 1); XCTAssertEqual(owner.manager.redoCount, 2)
    XCTAssertEqual(owner.manager.groupingLevel, 0); XCTAssertTrue(owner.userHandlers.isEmpty)
    XCTAssertEqual(try owner.top(redo: false).group, "g1")
    XCTAssertEqual(try owner.top(redo: true).group, "g2")
    XCTAssertEqual(try owner.top(redo: true).cursor, 22)
    try owner.admitUser(redo: true)
    try owner.admitUser(redo: true)
    XCTAssertEqual(owner.manager.undoCount, 3); XCTAssertEqual(owner.manager.redoCount, 0)
    try owner.admitUser(redo: false)
    try owner.admitUser(redo: false)
    try owner.admitUser(redo: false)
    XCTAssertEqual(owner.userHandlers.map { $0.0 }, ["g2", "g3", "g3", "g2", "g1"])
    XCTAssertEqual(owner.userHandlers.map { $0.1 }, [22, 33, 33, 22, 11])
    XCTAssertEqual(owner.userHandlers.map { $0.2 }, [true, true, false, false, false])
    XCTAssertEqual(owner.manager.undoCount, 0); XCTAssertEqual(owner.manager.redoCount, 3)
  }

  func testWillUndoNestedPublicRequestQueuesWithoutAnAdditionalHydrationPop() throws {
    let owner = CanonicalSDKOwner()
    var will = 0, did = 0
    let center = NotificationCenter.default
    let first = center.addObserver(forName: .NSUndoManagerWillUndoChange,
      object: owner.manager, queue: .main) { _ in MainActor.assumeIsolated {
        will += 1
        if will == 1 { owner.manager.undoNestedGroup() }
      } }
    let second = center.addObserver(forName: .NSUndoManagerDidUndoChange,
      object: owner.manager, queue: .main) { _ in MainActor.assumeIsolated { did += 1 } }
    defer { center.removeObserver(first); center.removeObserver(second); owner.dispose() }
    owner.hydrate(undo: [("g1", 11)], redo: [("g3", 33), ("g2", 22)])
    XCTAssertEqual(will, 2); XCTAssertEqual(did, 2)
    XCTAssertEqual(owner.queued, [false]); XCTAssertTrue(owner.userHandlers.isEmpty)
    XCTAssertEqual(owner.manager.undoCount, 1); XCTAssertEqual(owner.manager.redoCount, 2)
    XCTAssertEqual(try owner.top(redo: false).group, "g1")
    XCTAssertEqual(try owner.top(redo: true).group, "g2")
    XCTAssertEqual(owner.manager.groupingLevel, 0)
  }
}
