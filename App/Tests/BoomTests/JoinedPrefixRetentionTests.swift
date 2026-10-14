import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

/// CPU behavioral checks for submitted-cohort, ledger and revocable-owner boundaries.
final class JoinedPrefixRetentionTests: XCTestCase {
  private func owner() -> PromptCacheOwner {
    .init(namespace: UUID(), entity: UUID(), route: .writing)
  }
  private func binding(_ owner: PromptCacheOwner) -> JoinedKVRetentionBinding {
    .init(owner: owner, workspaceEpoch: UUID(), runnerEpoch: UUID(),
      modelIdentity: "public-test-model", processorIdentity: "public-test-processor",
      policyDigest: String(repeating: "a", count: 64), operationID: UUID())
  }
  private func request(_ store: PromptPrefixCache, _ ids: [Int], _ owner: PromptCacheOwner,
    binding: JoinedKVRetentionBinding? = nil) throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(ids, [1, ids.count])),
      promptTokenIDs: ids, prefill: .init(stepSize: 4, chunking: .remainder),
      joinedRetentionBinding: binding, useActiveNative: true, makeCache: { let global = KVCacheSimple(); global.step = 4; return [global, RotatingKVCache(maxSize: 4, step: 2)] })
  }
  private func append(_ session: PromptPrefixCache.Session, _ values: [Float], width: Int = 1, submitted: Bool = true) async {
    let a = MLXArray(values, [width, 1, values.count / width, 1])
    for cache in session.cache { _ = cache.update(keys: a, values: a + 100) }
      if submitted {
      asyncEval(session.cache.flatMap { $0.innerState() })
      eval(session.cache); session.markCacheSubmitted()
      session.observeReadySpill(); await session.joinPendingSpill(cancelled: false)
    }
  }
  private func prefill(_ session: PromptPrefixCache.Session) async throws {
    let ids = session.input.text.tokens.asArray(Int.self)
    var partition = session.prefill; partition.progress = nil
    var ranges: [Range<Int>] = []
    let done = try partition.forEachChunk(total: ids.count) { ranges.append($0) }
    if done < ids.count { ranges.append(done..<ids.count) }
    for range in ranges {
      await append(session, ids[range].map(Float.init))
      session.prefill.progress?(range.upperBound, ids.count)
    }
  }
  private func proof(_ termination: JoinedKVRetentionProof.Termination,
    joined: Bool = true, fenced: Bool = true, uncertain: Bool = false,
    memoryFailed: Bool = false, stateless: Bool = true) -> JoinedKVRetentionProof {
    .init(termination: termination, producerJoined: joined, existingFenceCompleted: fenced,
      checkpointUncertain: uncertain, memoryLimitExceeded: memoryFailed,
      statelessTextKVVerified: stateless)
  }
  private func approved(_ b: JoinedKVRetentionBinding) -> JoinedKVRetentionAuthorization {
    let a = JoinedKVRetentionAuthorization(binding: b); XCTAssertTrue(a.approve(binding: b)); return a
  }
  func testConstructorKeepsCompletedCohortAndExcludesHalfUpdatedNextCohort() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 4096), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      await append(session, [0, 1, 2, 3]); asyncEval(session.cache)
      session.prefill.progress?(4, 9)
      let next = MLXArray([Float(4), 5, 6, 7], [1, 1, 4, 1])
      _ = session.cache[0].update(keys: next, values: next + 100)
      eval(session.cache) // CPU completion, standing in for the owned finalizer.
      await session.joinPendingSpill(cancelled: false)
      XCTAssertTrue(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(snapshot.tokenIDs, Array(0..<4))
      XCTAssertEqual(snapshot.forwardHistory.last?.evaluatedEndTokenCount, 4)
      XCTAssertEqual(snapshot.joinedRetentionProvenance?.termination, .constructorCancelled)
      let query = try request(store, [0, 1, 2, 3, 40, 50], scope)
      XCTAssertEqual(query.cachedTokenCount, 4)
      XCTAssertFalse(query.observation.cachedCurrentHotPrefix)
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), [0, 1, 2, 3])
      XCTAssertEqual(query.cache[1].state[0].asArray(Float.self), [0, 1, 2, 3])
      XCTAssertEqual(session.cache[0].offset, 8, "Only disk64-style retention was admitted, not transfer of the later hot future.")
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 4096)
    }
  }
  func testNoOptInStillCannotPublishPartialConstructor() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner()
      let session = try request(store, Array(0..<9), scope)
      await append(session, [0, 1, 2, 3]); session.prefill.progress?(4, 9)
      XCTAssertFalse(store.publish(session)); XCTAssertFalse(store.hasAnchors)
    }
  }
  func testDecodeKeepsOnlyAcknowledgedSingleIDsNotLookaheadOrUnacknowledgedOutput() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), ids = Array(0..<9)
      let session = try request(store, ids, scope, binding: b); try await prefill(session)
      session.didSample?(MLXArray([901])); await append(session, [901])
      session.didSample?(MLXArray([902])); await append(session, [902])
      session.didSample?(MLXArray([903])); await append(session, [903])
      session.didSample?(MLXArray([904])); eval(session.cache); session.markCacheSubmitted()
      XCTAssertTrue(store.publishJoinedValidPrefix(session, proof: proof(.decodeCancelled),
        authorization: approved(b), acknowledged: [.init(emittedTokenIDs: [901])]))
      let s = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(s.tokenIDs, ids + [901])
      XCTAssertEqual(s.origin, .singleDecode)
      XCTAssertEqual(s.joinedRetentionProvenance?.acknowledgedGeneratedTokenCount, 1)
      XCTAssertEqual(s.joinedRetentionProvenance?.representedGeneratedTokenCount, 1)
      XCTAssertEqual(s.joinedRetentionProvenance?.lastCompleteCohortTokenCount, 12)
      XCTAssertFalse(s.tokenIDs.contains(902)); XCTAssertFalse(s.tokenIDs.contains(904))
      let query = try request(store, ids + [901, 999], scope)
      XCTAssertEqual(query.cachedTokenCount, 10)
      XCTAssertEqual(query.observation.cachedOrigin, .singleDecode)
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), (ids + [901]).map(Float.init))
    }
  }
  func testBatchFinishedRowExcludesLaterInertPaddingAndUnacknowledgedPrediction() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), ids = Array(0..<9)
      let session = try request(store, ids, scope, binding: b); try await prefill(session)
      for var cache in session.cache {
        cache.state = cache.state.map { broadcast($0, to: [3] + Array($0.shape.dropFirst())) }
      }
      for row in 0..<3 {
        XCTAssertTrue(session.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10], finished: false))
      }
      await append(session, [901, 911, 921], width: 3)
      for row in 0..<3 {
        XCTAssertTrue(session.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10], finished: false))
      }
      await append(session, [902, 912, 922], width: 3)
      XCTAssertTrue(session.captureFinishedLane(row: 0, width: 3, emittedTokenIDs: [901, 902, 903]))
      for row in 1..<3 {
        XCTAssertTrue(session.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10, 903 + row * 10], finished: false))
      }
      await append(session, [-1, 913, 923], width: 3); eval(session.cache); session.markCacheSubmitted()
      XCTAssertTrue(store.publishJoinedValidPrefix(session, proof: proof(.decodeCancelled),
        authorization: approved(b), acknowledged: [.init(row: 0, emittedTokenIDs: [901, 902])]))
      let s = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(s.tokenIDs, ids + [901, 902]); XCTAssertEqual(s.batchWidth, 3)
      XCTAssertEqual(s.row, 0); XCTAssertEqual(s.origin, .batchDecode)
      XCTAssertFalse(s.tokenIDs.contains(-1)); XCTAssertFalse(s.tokenIDs.contains(903))
      let query = try request(store, ids + [901, 902, 999], scope)
      XCTAssertEqual(query.cachedTokenCount, 11); XCTAssertEqual(query.observation.cachedRow, 0)
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), (ids + [901, 902]).map(Float.init))
    }
  }
  func testConstructorWitnessCannotAuthorizeGeneratedAcknowledgments() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b); try await prefill(session)
      session.didSample?(MLXArray([901])); await append(session, [901]); eval(session.cache)
      XCTAssertFalse(store.publishJoinedValidPrefix(session, proof: proof(.constructorCancelled),
        authorization: approved(b), acknowledged: [.init(emittedTokenIDs: [901])]))
      XCTAssertFalse(store.hasAnchors); session.discardStagedAnchors()
    }
  }
  func testCheckpointUncertaintyMemoryFailureAndMissingFenceAreDenied() async throws {
    try await Device.withDefaultDevice(.cpu) {
      for evidence in [proof(.constructorCancelled, joined: false),
        proof(.constructorCancelled, fenced: false), proof(.decodeCancelled, uncertain: true),
        proof(.decodeCancelled, memoryFailed: true), proof(.constructorCancelled, stateless: false)] {
        let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
        let session = try request(store, Array(0..<9), scope, binding: b)
        await append(session, [0, 1, 2, 3]); eval(session.cache); session.markCacheSubmitted()
        XCTAssertFalse(store.publishJoinedValidPrefix(session, proof: evidence, authorization: approved(b)))
        XCTAssertFalse(store.hasAnchors); session.discardStagedAnchors()
      }
    }
  }
  func testRevocationClearAndSupersedingEpochCannotPublish() async throws {
    try await Device.withDefaultDevice(.cpu) {
      for mode in 0..<3 {
        let store = PromptPrefixCache(), scope = owner(), b = binding(scope), auth = approved(b)
        let session = try request(store, Array(0..<9), scope, binding: b)
        await append(session, [0, 1, 2, 3]); eval(session.cache); session.markCacheSubmitted()
        if mode == 0 { auth.revoke(); XCTAssertFalse(auth.approve(binding: b)) }
        if mode == 1 { store.clear(reason: "workspace_closed") }
        if mode == 2 { _ = try request(store, [0, 1, 2, 3, 90], scope) }
        XCTAssertFalse(store.publishJoinedValidPrefix(session,
          proof: proof(.constructorCancelled), authorization: auth))
        XCTAssertFalse(store.hasAnchors)
      }
    }
  }
  func testWrongRequestBindingAndUnknownApprovalAreDenied() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      await append(session, [0, 1, 2, 3]); eval(session.cache); session.markCacheSubmitted()
      let unapproved = JoinedKVRetentionAuthorization(binding: b)
      XCTAssertFalse(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: unapproved))
      XCTAssertFalse(store.hasAnchors)
      let other = try request(store, Array(0..<9), scope, binding: b)
      await append(other, [0, 1, 2, 3]); eval(other.cache); other.markCacheSubmitted()
      let different = binding(scope)
      XCTAssertFalse(store.publishJoinedValidPrefix(other,
        proof: proof(.constructorCancelled), authorization: approved(different)))
      XCTAssertFalse(store.hasAnchors)
    }
  }
  func testAllLayerDescriptorWithoutSubmissionCannotAuthorizeConstructorRetention() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      await append(session, [0, 1, 2, 3], submitted: false) // Every owning layer, deliberately no submission witness.
      XCTAssertEqual(session.retentionObservation?.lastCompleteTokenCount, 4)
      XCTAssertEqual(session.submittedTokenCount, 0)
      XCTAssertFalse(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      XCTAssertFalse(store.hasAnchors)
    }
  }
  func testTerminalProgressDoesNotAuthorizeUnsubmittedFinalGraph() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      await append(session, [0, 1, 2, 3]); asyncEval(session.cache); session.prefill.progress?(4, 9)
      await append(session, [4, 5, 6, 7]); asyncEval(session.cache); session.prefill.progress?(8, 9)
      eval(session.cache)
      await append(session, [8], submitted: false) // Same ordering as pinned prepare before final asyncEval.
      session.prefill.progress?(9, 9)
      XCTAssertEqual(session.retentionObservation?.lastCompleteTokenCount, 9)
      XCTAssertEqual(session.submittedTokenCount, 8)
      XCTAssertTrue(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(snapshot.tokenIDs, Array(0..<8))
      XCTAssertEqual(snapshot.forwardHistory.last?.evaluatedEndTokenCount, 8)
      XCTAssertEqual(snapshot.joinedRetentionProvenance?.lastCompleteCohortTokenCount, 9)
      XCTAssertEqual(snapshot.joinedRetentionProvenance?.lastSubmittedCohortTokenCount, 8)
      let query = try request(store, Array(0..<8) + [90, 91], scope)
      XCTAssertEqual(query.cachedTokenCount, 8)
      XCTAssertFalse(query.observation.cachedCurrentHotPrefix)
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), Array(0..<8).map(Float.init))
      XCTAssertEqual(session.cache[0].offset, 9, "Unscheduled future was neither evaluated nor trimmed for hot adoption.")
    }
  }
  func testSuffixSubmittedProgressMapsToFullPromptPosition() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let first = try request(store, Array(0..<9), scope, binding: b)
      await append(first, [0, 1, 2, 3]); asyncEval(first.cache); first.prefill.progress?(4, 9)
      eval(first.cache)
      XCTAssertTrue(store.publishJoinedValidPrefix(first,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      let nextBinding = binding(scope)
      let next = try request(store, Array(0..<12), scope, binding: nextBinding)
      XCTAssertEqual(next.cachedTokenCount, 4)
      await append(next, [4, 5, 6, 7]); asyncEval(next.cache); next.prefill.progress?(4, 8)
      eval(next.cache)
      XCTAssertEqual(next.submittedTokenCount, 8)
      XCTAssertTrue(store.publishJoinedValidPrefix(next,
        proof: proof(.constructorCancelled), authorization: approved(nextBinding)))
      XCTAssertEqual(store.retainedSnapshotObservations.first?.tokenIDs, Array(0..<8))
      let query = try request(store, Array(0..<8) + [900], scope)
      XCTAssertEqual(query.cachedTokenCount, 8)
    }
  }
  func testPromptOnlyBatchSalvageRecordsItsActualWidthOneForward() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), ids = Array(0..<9)
      let session = try request(store, ids, scope, binding: b); try await prefill(session)
      for var cache in session.cache {
        cache.state = cache.state.map { broadcast($0, to: [3] + Array($0.shape.dropFirst())) }
      }
      XCTAssertTrue(session.captureDecodeLane(row: 1, width: 3, emittedTokenIDs: [901], finished: false))
      eval(session.cache)
      XCTAssertTrue(store.publishJoinedValidPrefix(session, proof: proof(.decodeCancelled),
        authorization: approved(b), acknowledged: [.init(row: 1, emittedTokenIDs: [901])]))
      let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
      XCTAssertEqual(snapshot.tokenIDs, ids); XCTAssertEqual(snapshot.origin, .prefill)
      XCTAssertEqual(snapshot.batchWidth, 1); XCTAssertNil(snapshot.row)
      XCTAssertEqual(snapshot.forwardHistory.last?.batchWidth, 1)
      XCTAssertEqual(snapshot.joinedRetentionProvenance?.acknowledgedGeneratedTokenCount, 1)
      XCTAssertEqual(snapshot.joinedRetentionProvenance?.representedGeneratedTokenCount, 0)
      let query = try request(store, ids + [999], scope)
      XCTAssertEqual(query.cachedTokenCount, 9); XCTAssertEqual(query.observation.cachedBatchWidth, 1)
      XCTAssertNil(query.observation.cachedRow)
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), ids.map(Float.init))
    }
  }


  func testJoinedCompletedDisk64SurvivesHalfUpdatedOrUnsubmitted65WithoutHotAdoption() async throws {
    try await Device.withDefaultDevice(.cpu) {
      for mode in 0..<3 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-Joined-Disk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        let store = PromptPrefixCache(byteLimit: mode == 2 ? 1 : 4096, temporaryParent: root)
        let scope = owner(), b = binding(scope), session = try request(store, Array(0..<66), scope, binding: b)
        // Actual all-owning-layer execution, parent submission/evaluation and
        // completed immutable disk write precede any later future descriptor.
        await append(session, Array(0..<64))
        session.prefill.progress?(64, 66)
        XCTAssertEqual(session.submittedTokenCount, 64)
        XCTAssertEqual(session.retentionObservation?.lastCompleteTokenCount, 64)
        if mode != 2 { XCTAssertGreaterThan(session.retentionObservation?.diskBytes ?? 0, 0) }
        if mode == 0 {
          let future = MLXArray([Float(64)], [1, 1, 1, 1])
          _ = session.cache[0].update(keys: future, values: future + 100)
          eval(session.cache) // actual joined half-forward, NOT an all-layer submit
          XCTAssertEqual(session.cache.map(\.offset), [65, 64])
        } else {
          await append(session, [64], submitted: false)
          XCTAssertEqual(session.cache.map(\.offset), [65, 65])
          XCTAssertNil(PrefixKVStorage.unwrap(session.cache[0]).innerState()[0].readyBuffer(),
            "This real future graph must remain unscheduled.")
        }
        XCTAssertEqual(session.submittedTokenCount, 64)
        await session.joinPendingSpill(cancelled: true) // actual writer/cleanup joins; no future eval
        let retained = store.publishJoinedValidPrefix(session,
          proof: proof(.constructorCancelled), authorization: approved(b))
        XCTAssertEqual(retained, mode != 2)
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
        if mode == 2 {
          XCTAssertTrue(store.retainedSnapshotObservations.isEmpty)
          XCTAssertFalse(store.hasAnchors, "Missing disk bytes cannot rescue unsupported future owners.")
          continue
        }
        let snapshot = try XCTUnwrap(store.retainedSnapshotObservations.first)
        XCTAssertEqual(snapshot.tokenIDs, Array(0..<64))
        XCTAssertEqual(snapshot.forwardHistory.last?.endTokenCount, 64)
        XCTAssertEqual(snapshot.forwardHistory.last?.evaluatedEndTokenCount, 64)
        XCTAssertEqual(snapshot.joinedRetentionProvenance?.representedTokenCount, 64)
        XCTAssertEqual(snapshot.joinedRetentionProvenance?.lastSubmittedCohortTokenCount, 64)
        XCTAssertEqual(snapshot.joinedRetentionProvenance?.lastCompleteCohortTokenCount, mode == 0 ? 64 : 65)
        XCTAssertNil(snapshot.nativePhysicalWidth, "The unsafe future hot owner supplied no physical-width witness.")
        let query = try request(store, Array(0..<64) + [900], scope)
        XCTAssertEqual(query.cachedTokenCount, 64)
        XCTAssertFalse(query.observation.cachedCurrentHotPrefix)
        XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), Array(0..<64).map(Float.init))
        XCTAssertEqual(query.cache[1].state[0].asArray(Float.self), Array(60..<64).map(Float.init))
        XCTAssertEqual(query.cache[1].state[1].asArray(Float.self), Array(160..<164).map(Float.init))
        XCTAssertEqual(query.input.text.tokens.asArray(Int.self), [900])
        XCTAssertEqual(session.cache[0].offset, 65, "Lookup did not borrow, trim or adopt the unsafe hot cache.")
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
        XCTAssertFalse(store.publishJoinedValidPrefix(session,
          proof: proof(.constructorCancelled), authorization: approved(b)), "The one ticket was already consumed.")
        query.discardStagedAnchors(); store.clear(); await query.joinPendingSpill(cancelled: true)
      }
    }
  }
}
