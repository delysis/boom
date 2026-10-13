import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

/// Actual Session/TextKit/client lifetime controls with public synthetic page
/// identities. The acknowledgements use the real bounded validators, but this
/// fixture has no encrypted provider, durable publisher or installed app claim.
/// All holds are explicit continuations. Cancellation/time passage never
/// substitutes for joining the actual tasks, and failed custody is preserved.
@MainActor final class PagedNativeSessionRetirementTests: XCTestCase {
  private func withFixture(_ body: (PagedRetirementFixture) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fixture = try PagedRetirementFixture()
    do {
      try await body(fixture)
      await fixture.closeControlAndJoin()
    } catch {
      await fixture.closeControlAndJoin()
      throw error
    }
    XCTAssertEqual(fixture.session.activeNavigationOperationCount, 0)
    let active = await fixture.route.activeCallCount
    XCTAssertEqual(active, 0)
  }

  private func edit(_ session: PagedNativeSession, _ text: String) throws {
    try session.nativeCharacterTransactionWillBegin()
    do {
      XCTAssertTrue(try session.replace(NSRange(location: 0, length: 1), with: text, groupID: UUID()))
    } catch {
      _ = session.nativeCharacterTransactionDidClose()
      throw error
    }
    XCTAssertTrue(session.nativeCharacterTransactionDidClose())
  }

  func testOwnedSubscriptionRequiresExactSessionObjectOwnerAndLiveToken() async throws {
    try await withFixture { fixture in
      let session = fixture.session, owner = UUID()
      var firstCalls = 0, replacementCalls = 0
      let first = try session.registerNativeGroupSubscription(ownerID: owner) { token, receipt in
        XCTAssertEqual(token.ownerID, owner); XCTAssertEqual(token.sessionID, session.sessionID)
        XCTAssertEqual(receipt.sessionID, token.sessionID)
        firstCalls += 1
      }
      XCTAssertThrowsError(try session.registerNativeGroupSubscription(ownerID: owner) { _, _ in })
      XCTAssertThrowsError(try session.requireNativeGroupSubscription(first, ownerID: UUID()))
      XCTAssertThrowsError(try session.detachNativeGroupSubscription(first, ownerID: UUID()))
      let foreign = try PagedNativeSession(window: fixture.initial, rootRecord: fixture.record, storage: fixture.route)
      let foreignToken = try foreign.registerNativeGroupSubscription(ownerID: owner) { _, _ in }
      XCTAssertThrowsError(try session.requireNativeGroupSubscription(foreignToken, ownerID: owner))
      XCTAssertThrowsError(try session.detachNativeGroupSubscription(foreignToken, ownerID: owner))
      XCTAssertThrowsError(try foreign.requireNativeGroupSubscription(first, ownerID: owner))
      try edit(session, "X")
      _ = try await session.flush(through: 1)
      XCTAssertEqual(firstCalls, 1)
      try session.requireNativeGroupSubscription(first, ownerID: owner)
      try session.detachNativeGroupSubscription(first, ownerID: owner)
      let replacement = try session.registerNativeGroupSubscription(ownerID: owner) { _, _ in replacementCalls += 1 }
      // The stale token has the same owner and session IDs. Object identity and
      // real detached state must still refuse it without removing replacement.
      XCTAssertThrowsError(try session.requireNativeGroupSubscription(first, ownerID: owner))
      XCTAssertThrowsError(try session.detachNativeGroupSubscription(first, ownerID: owner))
      try edit(session, "Y")
      _ = try await session.flush(through: 2)
      XCTAssertEqual(firstCalls, 1); XCTAssertEqual(replacementCalls, 1)
      try session.detachNativeGroupSubscription(replacement, ownerID: owner)
      try foreign.detachNativeGroupSubscription(foreignToken, ownerID: owner)
    }
  }

  func testPrototypeCallbackCannotReplaceOrMasqueradeAsOwnedSubscription() async throws {
    try await withFixture { fixture in
      let session = fixture.session, owner = UUID()
      var prototypeCalls = 0, ownedCalls = 0
      session.didCloseNativeGroup = { _ in prototypeCalls += 1 }
      XCTAssertThrowsError(try session.registerNativeGroupSubscription(ownerID: owner) { _, _ in })
      try edit(session, "X")
      _ = try await session.flush(through: 1)
      XCTAssertEqual(prototypeCalls, 1)
      session.didCloseNativeGroup = nil
      let subscription = try session.registerNativeGroupSubscription(ownerID: owner) { _, _ in ownedCalls += 1 }
      session.didCloseNativeGroup = { _ in prototypeCalls += 1 }
      try edit(session, "Y")
      _ = try await session.flush(through: 2)
      XCTAssertEqual(ownedCalls, 1); XCTAssertEqual(prototypeCalls, 1)
      session.didCloseNativeGroup = nil
      try session.requireNativeGroupSubscription(subscription, ownerID: owner)
      session.didCloseNativeGroup = { _ in prototypeCalls += 1 }
      try session.detachNativeGroupSubscription(subscription, ownerID: owner)
      XCTAssertNotNil(session.didCloseNativeGroup, "Owned detach must not clear an unrelated prototype callback.")
      try edit(session, "Z")
      _ = try await session.flush(through: 3)
      XCTAssertEqual(ownedCalls, 1); XCTAssertEqual(prototypeCalls, 2)
      session.didCloseNativeGroup = nil
    }
  }

  func testNativeGroupCallbackRefusesReentrantHookTransferAndPhysicalClose() async throws {
    try await withFixture { fixture in
      let input = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let view = try XCTUnwrap(input.activeView), native = try XCTUnwrap(view.textStorage)
      var supplied: PagedNativeGroupSubscription?, calls = 0
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: input.ownerID) { token, _ in
        do {
          supplied = token; calls += 1
          try XCTAssertThrowsError(try fixture.session.requireNativeGroupSubscription(token, ownerID: input.ownerID))
          try XCTAssertThrowsError(try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID))
          try XCTAssertThrowsError(try fixture.session.registerNativeGroupSubscription(ownerID: UUID()) { _, _ in })
          try XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
          try XCTAssertThrowsError(try input.retireInputForClose())
          XCTAssertNotNil(input.activeView)
        } catch {
          XCTFail("Unexpected XCTest assertion-framework error in nonthrowing group-subscription callback: \(error)")
        }
      }
      native.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
      XCTAssertTrue(supplied === token); XCTAssertEqual(calls, 1)
      _ = try await fixture.session.flush(through: 1)
      try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID)
      try input.retireInputForClose()
      try input.requireJoinedClose()
      XCTAssertEqual(input.retainedClientCount, 0)
    }
  }

  func testReceiverDisposalFencesRealDeinitReentrancyAndReleasesCapturedGraph() async throws {
    try await withFixture { fixture in
      let session = fixture.session, owner = UUID()
      var disposalCalls = 0
      var probe: PagedRetirementReleaseProbe? = PagedRetirementReleaseProbe {
        do {
          disposalCalls += 1
          try XCTAssertThrowsError(try session.windowForNativeInstallation())
          try XCTAssertThrowsError(try session.registerNativeGroupSubscription(ownerID: UUID()) { _, _ in })
          try XCTAssertThrowsError(try session.nativeCharacterTransactionWillBegin())
        } catch {
          XCTFail("Unexpected XCTest assertion-framework error in nonthrowing receiver-disposal callback: \(error)")
        }
      }
      weak var weakProbe = probe
      let token = try session.registerNativeGroupSubscription(ownerID: owner) { [held = probe!] _, _ in
        withExtendedLifetime(held) {}
      }
      probe = nil
      XCTAssertNotNil(weakProbe)
      try session.detachNativeGroupSubscription(token, ownerID: owner)
      XCTAssertNil(weakProbe); XCTAssertEqual(disposalCalls, 1)
      XCTAssertNoThrow(try session.windowForNativeInstallation())
      let next = try session.registerNativeGroupSubscription(ownerID: owner) { _, _ in }
      try session.detachNativeGroupSubscription(next, ownerID: owner)
      withExtendedLifetime(token) {} // Holding old token does not retain callback.
    }
  }

  func testRetiringClientPrecedesReceiverDisposalAndLaterCallbacksStayInert() async throws {
    try await withFixture { fixture in
      let input = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let view = try XCTUnwrap(input.activeView), context = try XCTUnwrap(view.inputContext)
      let client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      let ticket = try input.prepareInputRetirement(commandOwner: nil)
      let generation = fixture.session.generation, arena = fixture.session.arenaID
      var order: [String] = []
      var probe: PagedRetirementReleaseProbe? = PagedRetirementReleaseProbe {
        do {
          order.append("dispose")
          XCTAssertTrue(client.isRetired)
          XCTAssertNil(input.activeView)
          try XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
          client.insertText("stale disposal", replacementRange: NSRange(location: 0, length: 0))
          client.doCommand(by: #selector(UndoManager.undo))
          XCTAssertNil(input.firstRefusal)
          XCTAssertEqual(fixture.session.generation, generation)
        } catch {
          XCTFail("Unexpected XCTest assertion-framework error in nonthrowing retired-client-disposal callback: \(error)")
        }
      }
      weak var weakProbe = probe
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: input.ownerID) { [held = probe!] _, _ in
        withExtendedLifetime(held) {}
      }
      probe = nil
      var forbiddenBodyCalls = 0
      XCTAssertThrowsError(try fixture.session.detachNativeGroupSubscription(token, ownerID: UUID(),
        retiringClient: { forbiddenBodyCalls += 1 }))
      XCTAssertEqual(forbiddenBodyCalls, 0)
      XCTAssertNotNil(input.activeView); XCTAssertFalse(client.isRetired)
      try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID) {
        do {
          order.append("retire")
          input.consumeInputRetirement(ticket, commandOwner: nil)
          XCTAssertTrue(client.isRetired)
          try XCTAssertThrowsError(try fixture.session.registerNativeGroupSubscription(ownerID: UUID()) { _, _ in })
        } catch {
          XCTFail("Unexpected XCTest assertion-framework error in nonthrowing physical-retirement callback: \(error)")
        }
      }
      XCTAssertEqual(order, ["retire", "dispose"]); XCTAssertNil(weakProbe)
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertEqual(fixture.session.arenaID, arena)
      XCTAssertNil(input.firstRefusal)
      try input.requireJoinedClose()
      client.insertText("stale later", replacementRange: NSRange(location: 0, length: 0))
      XCTAssertNil(input.firstRefusal); XCTAssertEqual(fixture.session.generation, generation)
      withExtendedLifetime((context, view, token, ticket)) {}
    }
  }

  func testActiveNavigationPinsPhysicalClientAndOwnedHookUntilActualReturn() async throws {
    try await withFixture { fixture in
      let input = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: input.ownerID) { _, _ in }
      let navigation = fixture.own { try await fixture.session.navigate(toUTF16: 1) }
      try await fixture.route.waitForWindow(at: 1)
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 1)
      XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
      XCTAssertThrowsError(try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID))
      XCTAssertThrowsError(try input.retireInputForClose())
      await fixture.route.releaseWindow(at: 1)
      _ = try await navigation.value
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 0)
      try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID)
      try input.retireInputForClose()
      try input.requireJoinedClose()
    }
  }

  func testInvalidatingNavigationNonceDoesNotJoinAwaitingStorageProducer() async throws {
    try await withFixture { fixture in
      let input = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: input.ownerID) { _, _ in }
      let original = fixture.session.arenaID
      let navigation = fixture.own { try await fixture.session.navigate(toUTF16: 0) }
      try await fixture.route.waitForWindow(at: 0)
      let prefix = try fixture.session.reservePrefix() // Deliberately invalidates navigationID.
      _ = try await fixture.session.flush(prefix)
      try fixture.session.releasePrefix(prefix)        // Leaves no retained prefix/intent.
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 1)
      XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
      XCTAssertThrowsError(try PagedNativeTextStorage(session: fixture.session))
      XCTAssertThrowsError(try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID))
      XCTAssertThrowsError(try input.retireInputForClose())
      await fixture.route.releaseWindow(at: 0)
      do {
        _ = try await navigation.value
        XCTFail("Invalidated navigation assigned a new arena.")
      } catch BoomError.stale { /* The producer actually returned; no arena assignment. */ }
      XCTAssertEqual(fixture.session.arenaID, original)
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 0)
      try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID)
      try input.retireInputForClose(); try input.requireJoinedClose()
    }
  }

  func testCancelledNavigationStaysOwnedUntilAwaitedStorageReturns() async throws {
    try await withFixture { fixture in
      let navigation = fixture.own { try await fixture.session.navigate(toUTF16: 0) }
      try await fixture.route.waitForWindow(at: 0)
      navigation.cancel()
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 1)
      XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
      await fixture.route.releaseWindow(at: 0)
      do {
        _ = try await navigation.value
        XCTFail("Cancelled navigation acquired a physical source window.")
      } catch is CancellationError { /* Cancellation followed the actual storage return. */ }
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 0)
      XCTAssertNoThrow(try fixture.session.windowForNativeInstallation())
    }
  }

  func testBoundedNavigationAdmissionPreservesWinnerAndAllEarlierLifetimes() async throws {
    try await withFixture { fixture in
      var operations: [Task<PagedTextWindow, Error>] = []
      for index in 0..<PagedNativeSession.maximumNavigationOperations {
        let anchor = UInt64(index)
        operations.append(fixture.own { try await fixture.session.navigate(toUTF16: anchor) })
        try await fixture.route.waitForWindow(at: anchor)
      }
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, PagedNativeSession.maximumNavigationOperations)
      do {
        _ = try await fixture.session.navigate(toUTF16: 8)
        XCTFail("The ninth navigation exceeded the explicit producer bound.")
      } catch BoomError.budget { /* Existing newest nonce must stay intact. */ }
      let winningAnchor = UInt64(PagedNativeSession.maximumNavigationOperations - 1)
      await fixture.route.releaseWindow(at: winningAnchor)
      let winner = try await operations.last!.value
      XCTAssertEqual(winner.utf16Start, winningAnchor)
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, PagedNativeSession.maximumNavigationOperations - 1)
      XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
      for index in 0..<(operations.count - 1) {
        await fixture.route.releaseWindow(at: UInt64(index))
        do {
          _ = try await operations[index].value
          XCTFail("A superseded navigation replaced the winning arena.")
        } catch BoomError.stale { /* Exact older operation joined. */ }
      }
      XCTAssertEqual(fixture.session.activeNavigationOperationCount, 0)
      XCTAssertEqual(try fixture.session.windowForNativeInstallation().windowID, winner.windowID)
    }
  }

  func testRetainedTicketConstructionWaitsForInvalidatedNavigationThenRemainsAdmissible() async throws {
    try await withFixture { fixture in
      let navigation = fixture.own { try await fixture.session.navigate(toUTF16: 0) }
      try await fixture.route.waitForWindow(at: 0)
      let prefix = try fixture.session.reservePrefix()
      let prepared = try await fixture.session.prepareHistoryMove(fixture.handle, prefix: prefix)
      XCTAssertThrowsError(try fixture.session.stageHistoryInstallation(prepared))
      XCTAssertTrue(fixture.session.hasPendingHistoryCommand)
      await fixture.route.releaseWindow(at: 0)
      _ = await navigation.result
      let ticket = try fixture.session.stageHistoryInstallation(prepared)
      XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
      let native = try PagedNativeTextStorage(session: fixture.session, stagedTicket: ticket)
      XCTAssertEqual(Data(native.string.utf8), Data(prepared.window.text.utf8))
      XCTAssertEqual(try fixture.session.windowForStagedNativeInstallation(ticket).windowID, prepared.window.windowID)
      try fixture.session.cancelStagedHistoryInstallation(ticket)
      _ = try await fixture.session.resolveUnadmittedHistory(.explicitlyAbandoned)
      XCTAssertNoThrow(try fixture.session.windowForNativeInstallation())
    }
  }

  func testHistoryTaskAndSealNotificationBothExcludeReentrantPhysicalRetirement() async throws {
    try await withFixture { fixture in
      let prefix = try fixture.session.reservePrefix()
      let prepared = try await fixture.session.prepareHistoryMove(fixture.handle, prefix: prefix)
      var sealCalls = 0
      fixture.session.didSeal = { _ in
        do {
          sealCalls += 1
          XCTAssertFalse(fixture.session.hasPendingHistoryCommand)
          XCTAssertFalse(fixture.session.isProvisionalHistory)
          try XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
          try XCTAssertThrowsError(try fixture.session.registerNativeGroupSubscription(ownerID: UUID()) { _, _ in })
        } catch {
          XCTFail("Unexpected XCTest assertion-framework error in nonthrowing history-seal-notification callback: \(error)")
        }
      }
      let admission = try fixture.session.installPreparedHistory(prepared) { _, _, _ in }
      _ = try await fixture.session.joinHistoryPublication(commandID: admission.commandID)
      XCTAssertEqual(sealCalls, 1)
      XCTAssertNoThrow(try fixture.session.windowForNativeInstallation())
      fixture.session.didSeal = nil
    }
  }

  func testOrdinarySealNotificationCannotDetachItsJoinedOwnedHookReentrantly() async throws {
    try await withFixture { fixture in
      let owner = UUID()
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: owner) { _, _ in }
      var sealCalls = 0
      fixture.session.didSeal = { _ in
        do {
          sealCalls += 1
          XCTAssertNil(fixture.session.pendingCommitInstallation)
          try XCTAssertThrowsError(try fixture.session.windowForNativeInstallation())
          try XCTAssertThrowsError(try fixture.session.requireNativeGroupSubscription(token, ownerID: owner))
          try XCTAssertThrowsError(try fixture.session.detachNativeGroupSubscription(token, ownerID: owner))
        } catch {
          XCTFail("Unexpected XCTest assertion-framework error in nonthrowing ordinary-seal-notification callback: \(error)")
        }
      }
      try edit(fixture.session, "X")
      _ = try await fixture.session.flush(through: 1)
      XCTAssertEqual(sealCalls, 1)
      try fixture.session.detachNativeGroupSubscription(token, ownerID: owner)
      fixture.session.didSeal = nil
    }
  }

  func testFailedAcceptedNativeCommitPreservesInputHookAndUncertainBatch() async throws {
    try await withFixture { fixture in
      let input = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let native = try XCTUnwrap(input.activeView.textStorage)
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: input.ownerID) { _, _ in }
      await fixture.route.refuseNextCommit()
      native.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
      do {
        _ = try await fixture.session.flush(through: 1)
        XCTFail("A refused accepted native batch acquired a fake sealed source.")
      } catch BoomError.unavailable { /* The real task joined with its retained source refusal. */ }
      XCTAssertEqual(native.string, "Xublic0123456789")
      XCTAssertEqual(fixture.session.generation, 1)
      XCTAssertEqual(fixture.session.sealedRevision, fixture.initial.revision)
      XCTAssertNotNil(fixture.session.persistenceFailure)
      let observedRejected = await fixture.route.rejectedBatch
      let rejected = try XCTUnwrap(observedRejected)
      XCTAssertEqual(rejected.expectedRootRecord, fixture.record)
      XCTAssertEqual(rejected.firstSequence, 1); XCTAssertEqual(rejected.lastSequence, 1)
      XCTAssertEqual(rejected.afterBytes, Data(native.string.utf8))
      var retirementCalls = 0
      XCTAssertThrowsError(try input.prepareInputRetirement(commandOwner: nil))
      XCTAssertThrowsError(try fixture.session.detachNativeGroupSubscription(token, ownerID: input.ownerID,
        retiringClient: { retirementCalls += 1 }))
      XCTAssertEqual(retirementCalls, 0)
      XCTAssertNotNil(input.activeView)
      // Deliberately no abandonment, failure reset or fake hook detach. The
      // fixture has no durable files; a real backend requires explicit custody
      // resolution and preserved failed diagnostics in its own qualification.
    }
  }

  func testLaterRetiredClientCallbacksCannotInvokeDetachedOrReplacementOwnedHook() async throws {
    try await withFixture { fixture in
      let input = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let oldView = try XCTUnwrap(input.activeView)
      let context = try XCTUnwrap(oldView.inputContext)
      let client = try XCTUnwrap(context.client as? PagedNativeTextInputClient)
      var oldCalls = 0, newCalls = 0
      let old = try fixture.session.registerNativeGroupSubscription(ownerID: input.ownerID) { _, _ in oldCalls += 1 }
      try fixture.session.detachNativeGroupSubscription(old, ownerID: input.ownerID)
      try input.retireInputForClose(); try input.requireJoinedClose()
      XCTAssertTrue(client.isRetired)
      let replacement = try PagedNativeInputOwner(frame: .zero, session: fixture.session)
      let token = try fixture.session.registerNativeGroupSubscription(ownerID: replacement.ownerID) { _, _ in newCalls += 1 }
      let generation = fixture.session.generation, arena = fixture.session.arenaID
      client.insertText("stale", replacementRange: NSRange(location: 0, length: 0))
      client.setMarkedText("stale", selectedRange: NSRange(location: 5, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
      client.unmarkText(); client.doCommand(by: #selector(UndoManager.undo))
      oldView.insertText("stale", replacementRange: NSRange(location: 0, length: 0))
      XCTAssertEqual(fixture.session.generation, generation); XCTAssertEqual(fixture.session.arenaID, arena)
      XCTAssertEqual(oldCalls, 0); XCTAssertEqual(newCalls, 0)
      XCTAssertNil(replacement.firstRefusal); XCTAssertFalse(fixture.session.isPinned)
      let native = try XCTUnwrap(replacement.activeView.textStorage)
      native.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
      _ = try await fixture.session.flush(through: 1)
      XCTAssertEqual(oldCalls, 0); XCTAssertEqual(newCalls, 1)
      try fixture.session.detachNativeGroupSubscription(token, ownerID: replacement.ownerID)
      try replacement.retireInputForClose(); try replacement.requireJoinedClose()
      withExtendedLifetime((context, client, old, oldView)) {}
    }
  }
}

/// Direct synchronous destruction exposes hook-disposal reentrancy without
/// retaining a native view/context pair or posting a fabricated later callback.
private final class PagedRetirementReleaseProbe {
  private let release: @MainActor () -> Void
  init(release: @escaping @MainActor () -> Void) { self.release = release }
  deinit { MainActor.assumeIsolated { release() } }
}

@MainActor private final class PagedRetirementFixture {
  let initial: PagedTextWindow
  let record: PagedDocumentRootRecord
  let route: PagedRetirementHeldStorage
  let session: PagedNativeSession
  let handle: PagedNativeHistoryHandle
  private var joins: [Task<Void, Never>] = []

  init() throws {
    let owner = UUID(), document = UUID()
    initial = PagedRetirementHeldStorage.capture("public0123456789", owner: owner, document: document)
    record = PagedRetirementHeldStorage.record(initial, generation: 0)
    route = PagedRetirementHeldStorage(initial: initial, record: record)
    session = try PagedNativeSession(window: initial, rootRecord: record, storage: route)
    handle = PagedNativeHistoryHandle(documentID: document, groupID: UUID(), direction: .undo)
  }
  func own<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
    precondition(joins.count < 16)
    let task = Task { try await body() }
    joins.append(Task { _ = await task.result })
    return task
  }
  func closeControlAndJoin() async {
    await route.closeControl()
    for join in joins { await join.value }
  }
}

private actor PagedRetirementHeldStorage: PagedNativeCommitInstallationStorage, PagedNativeHistorySessionStorage {
  private struct WindowCall {
    let expected: PagedTextRevision
    let maximumBytes: Int
    let continuation: CheckedContinuation<PagedTextWindow, Error>
  }
  private let initial: PagedTextWindow
  private var current: PagedDocumentRootRecord
  private var windows: [UInt64: WindowCall] = [:]
  private var observers: [UInt64: CheckedContinuation<Void, Error>] = [:]
  private var closing = false
  private var refuseCommit = false
  private(set) var rejectedBatch: PagedNativeCommitBatch?
  private(set) var activeCallCount = 0

  init(initial: PagedTextWindow, record: PagedDocumentRootRecord) { self.initial = initial; current = record }
  nonisolated static func page(_ hex: String = "a") -> PagedTextPageRef {
    PagedTextPageRef(locator: PagedTextPageLocator(storeID: UUID(), offset: 0,
      bytes: 128), digest: String(repeating: hex, count: 64))
  }
  nonisolated static func capture(_ text: String, owner: UUID, document: UUID) -> PagedTextWindow {
    let revision = PagedTextRevision(schema: 1, ownerID: owner, documentID: document,
      root: text.isEmpty ? nil : PagedTextTreeRef(page: page(),
        summary: PagedTextSummary(bytes: UInt64(text.utf8.count), utf16: UInt64(text.utf16.count), lfCount: 0), height: 0))
    return PagedTextWindow(revision: revision, windowID: UUID(), byteStart: 0, utf16Start: 0, lfStart: 0, text: text)
  }
  nonisolated static func record(_ window: PagedTextWindow, generation: UInt64) -> PagedDocumentRootRecord {
    PagedDocumentRootRecord(document: PagedDocumentDescriptor(id: window.revision.documentID,
      title: "Public retirement mechanics", revision: window.revision), historyPage: page("b"), historyGeneration: generation)
  }
  func commit(_ batch: PagedNativeCommitBatch) async throws -> PagedNativeCommitAcknowledgement {
    guard !closing else { throw BoomError.unavailable("Public retirement control is joining.") }
    activeCallCount += 1; defer { activeCallCount -= 1 }
    if refuseCommit {
      refuseCommit = false; rejectedBatch = batch
      throw BoomError.unavailable("Public control preserves its deliberately refused accepted batch.")
    }
    guard current == batch.expectedRootRecord,
      let text = String(data: batch.afterBytes, encoding: .utf8) else { throw BoomError.stale("Another public source owns the fixture.") }
    let window = Self.capture(text, owner: current.document.revision.ownerID, document: current.document.id)
    let record = Self.record(window, generation: current.historyGeneration + 1)
    let ack = try await Task.detached {
      try PagedNativeCommitAcknowledgement(validating: batch, sealedWindow: window, sealedRootRecord: record)
    }.value
    current = record
    return ack
  }
  func refuseNextCommit() { refuseCommit = true }
  func finishCommitInstallation(_ acknowledgement: PagedNativeCommitAcknowledgement) async throws {
    guard current == acknowledgement.sealedRootRecord else { throw BoomError.stale("Another public ACK owns the fixture.") }
  }
  func window(expected: PagedTextRevision, utf16Anchor: UInt64, maximumBytes: Int) async throws -> PagedTextWindow {
    guard !closing, windows.count < 8, windows[utf16Anchor] == nil else { throw BoomError.budget("Public held navigation bound is full.") }
    activeCallCount += 1; defer { activeCallCount -= 1 }
    return try await withCheckedThrowingContinuation { continuation in
      windows[utf16Anchor] = WindowCall(expected: expected, maximumBytes: maximumBytes, continuation: continuation)
      observers.removeValue(forKey: utf16Anchor)?.resume()
    }
  }
  func waitForWindow(at anchor: UInt64) async throws {
    if windows[anchor] != nil { return }
    guard !closing, observers.count < 8, observers[anchor] == nil else { throw BoomError.budget("Public navigation observer bound is full.") }
    try await withCheckedThrowingContinuation { observers[anchor] = $0 }
  }
  func releaseWindow(at anchor: UInt64) {
    guard let call = windows.removeValue(forKey: anchor) else { return }
    // ASCII public fixture only; no whole production document is materialized.
    guard call.expected == initial.revision, anchor <= UInt64(initial.text.utf16.count), call.maximumBytes > 0 else {
      call.continuation.resume(throwing: BoomError.stale("Public held navigation lost its exact source.")); return
    }
    let text = String(initial.text.dropFirst(Int(anchor)).prefix(call.maximumBytes))
    let window = PagedTextWindow(revision: initial.revision, windowID: UUID(), byteStart: anchor,
      utf16Start: anchor, lfStart: 0, text: text)
    call.continuation.resume(returning: window)
  }
  func prepareHistoryMove(_ command: PagedNativeHistoryMoveCommand) async throws -> PagedNativePreparedHistoryMove {
    guard !closing, current == command.expectedRootRecord else { throw BoomError.stale("Public history fixture source changed.") }
    activeCallCount += 1; defer { activeCallCount -= 1 }
    let window = Self.capture("older", owner: current.document.revision.ownerID, document: current.document.id)
    let record = Self.record(window, generation: current.historyGeneration + 1)
    return try await Task.detached {
      try PagedNativePreparedHistoryMove(validating: command, routeID: UUID(), candidateRecord: record,
        window: window, cursor: PagedSealedCursor(byteOffset: 0, utf16Offset: 0), localCaretUTF16: 0)
    }.value
  }
  func commitPreparedHistory(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws -> PagedNativeHistoryAcknowledgement {
    guard current == prepared.command.expectedRootRecord else { throw BoomError.stale("Public history fixture head changed.") }
    activeCallCount += 1; defer { activeCallCount -= 1 }
    let ack = try await Task.detached {
      try PagedNativeHistoryAcknowledgement(validating: prepared, admission: admission,
        publishedRecord: prepared.candidateRecord, readWindow: prepared.window)
    }.value
    current = prepared.candidateRecord
    return ack
  }
  func finishHistoryInstallation(_ prepared: PagedNativePreparedHistoryMove,
    admission: PagedNativeHistoryAdmission) async throws {
    try admission.validate(for: prepared)
    guard current == prepared.candidateRecord else { throw BoomError.stale("Public retained history installation changed.") }
  }
  func noteHistoryInputConflict(_ prepared: PagedNativePreparedHistoryMove,
    observation: PagedNativeHistoryInputObservation) async throws -> PagedNativeHistoryInputConflictReceipt {
    try observation.validate(for: prepared)
    return PagedNativeHistoryInputConflictReceipt(prepared: prepared, observation: observation)
  }
  func resolveUnadmittedHistory(_ prepared: PagedNativePreparedHistoryMove,
    disposition: PagedNativeHistoryIntentDisposition) async throws -> PagedNativeHistoryIntentDispositionReceipt {
    PagedNativeHistoryIntentDispositionReceipt(prepared: prepared, disposition: disposition)
  }
  func inspectHistoryRecovery(_ prepared: PagedNativePreparedHistoryMove) async throws -> PagedNativeHistoryRecovery {
    throw BoomError.unavailable("This public mechanics fixture has no durable recovery permit.")
  }
  func completeVerifiedHistory(_ prepared: PagedNativePreparedHistoryMove,
    verificationID: UUID) async throws -> PagedNativeHistoryAcknowledgement {
    throw BoomError.unavailable("This public mechanics fixture never fabricates a recovery permit.")
  }
  func closeControl() {
    closing = true
    let held = Array(windows.values), waiting = Array(observers.values)
    windows.removeAll(); observers.removeAll()
    for call in held { call.continuation.resume(throwing: BoomError.unavailable("Public fixture joins its existing producer.")) }
    for observer in waiting { observer.resume(throwing: BoomError.unavailable("Public fixture joins its existing observer.")) }
  }
}
