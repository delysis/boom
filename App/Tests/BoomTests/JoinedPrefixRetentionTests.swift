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
      joinedRetentionBinding: binding, makeCache: { [KVCacheSimple(), RotatingKVCache(maxSize: 4)] })
  }
  private func append(_ session: PromptPrefixCache.Session, _ values: [Float], width: Int = 1) {
    let a = MLXArray(values, [width, 1, values.count / width, 1])
    for cache in session.cache { _ = cache.update(keys: a, values: a + 100) }
  }
  private func prefill(_ session: PromptPrefixCache.Session) throws {
    let ids = session.input.text.tokens.asArray(Int.self)
    let count = try session.prefill.forEachChunk(total: ids.count) { range in
      append(session, ids[range].map(Float.init)); asyncEval(session.cache)
    }
    append(session, ids[count...].map(Float.init)); session.prefill.progress?(ids.count, ids.count)
    eval(session.cache); session.markCacheSubmitted()
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
  func testConstructorKeepsCompletedCohortAndExcludesHalfUpdatedNextCohort() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(byteLimit: 4096), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      append(session, [0, 1, 2, 3]); asyncEval(session.cache)
      session.prefill.progress?(4, 9)
      let next = MLXArray([Float(4), 5, 6, 7], [1, 1, 4, 1])
      _ = session.cache[0].update(keys: next, values: next + 100)
      eval(session.cache) // CPU completion, standing in for the owned finalizer.
      XCTAssertTrue(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      let snapshots = store.retainedSnapshotObservations
      XCTAssertEqual(snapshots.map { $0.tokenIDs }, [Array(0..<4)])
      XCTAssertEqual(snapshots[0].forwardHistory.last?.evaluatedEndTokenCount, 4)
      XCTAssertEqual(snapshots[0].joinedRetentionProvenance?.termination, .constructorCancelled)
      let query = try request(store, [0, 1, 2, 3, 40, 50], scope)
      XCTAssertEqual(query.cachedTokenCount, 4)
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), [0, 1, 2, 3])
      XCTAssertEqual(query.cache[1].state[0].asArray(Float.self), [0, 1, 2, 3])
      XCTAssertLessThanOrEqual(store.retainedBytesUpperBound, 4096)
    }
  }
  func testNoOptInStillCannotPublishPartialConstructor() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner()
      let session = try request(store, Array(0..<9), scope)
      append(session, [0, 1, 2, 3]); session.prefill.progress?(4, 9)
      XCTAssertFalse(store.publish(session)); XCTAssertFalse(store.hasAnchors)
    }
  }
  func testDecodeKeepsOnlyAcknowledgedSingleIDsNotLookaheadOrUnacknowledgedOutput() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), ids = Array(0..<9)
      let session = try request(store, ids, scope, binding: b); try prefill(session)
      session.didSample?(MLXArray([901])); append(session, [901])
      session.didSample?(MLXArray([902])); append(session, [902])
      session.didSample?(MLXArray([903])); append(session, [903])
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
  func testBatchFinishedRowExcludesLaterInertPaddingAndUnacknowledgedPrediction() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), ids = Array(0..<9)
      let session = try request(store, ids, scope, binding: b); try prefill(session)
      for var cache in session.cache {
        cache.state = cache.state.map { broadcast($0, to: [3] + Array($0.shape.dropFirst())) }
      }
      for row in 0..<3 {
        XCTAssertTrue(session.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10], finished: false))
      }
      append(session, [901, 911, 921], width: 3)
      for row in 0..<3 {
        XCTAssertTrue(session.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10], finished: false))
      }
      append(session, [902, 912, 922], width: 3)
      XCTAssertTrue(session.captureFinishedLane(row: 0, width: 3, emittedTokenIDs: [901, 902, 903]))
      for row in 1..<3 {
        XCTAssertTrue(session.captureDecodeLane(row: row, width: 3,
          emittedTokenIDs: [901 + row * 10, 902 + row * 10, 903 + row * 10], finished: false))
      }
      append(session, [-1, 913, 923], width: 3); eval(session.cache); session.markCacheSubmitted()
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
  func testConstructorWitnessCannotAuthorizeGeneratedAcknowledgments() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b); try prefill(session)
      session.didSample?(MLXArray([901])); append(session, [901]); eval(session.cache)
      XCTAssertFalse(store.publishJoinedValidPrefix(session, proof: proof(.constructorCancelled),
        authorization: approved(b), acknowledged: [.init(emittedTokenIDs: [901])]))
      XCTAssertFalse(store.hasAnchors); session.discardStagedAnchors()
    }
  }
  func testCheckpointUncertaintyMemoryFailureAndMissingFenceAreDenied() throws {
    try Device.withDefaultDevice(.cpu) {
      for evidence in [proof(.constructorCancelled, joined: false),
        proof(.constructorCancelled, fenced: false), proof(.decodeCancelled, uncertain: true),
        proof(.decodeCancelled, memoryFailed: true), proof(.constructorCancelled, stateless: false)] {
        let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
        let session = try request(store, Array(0..<9), scope, binding: b)
        append(session, [0, 1, 2, 3]); eval(session.cache); session.markCacheSubmitted()
        XCTAssertFalse(store.publishJoinedValidPrefix(session, proof: evidence, authorization: approved(b)))
        XCTAssertFalse(store.hasAnchors); session.discardStagedAnchors()
      }
    }
  }
  func testRevocationClearAndSupersedingEpochCannotPublish() throws {
    try Device.withDefaultDevice(.cpu) {
      for mode in 0..<3 {
        let store = PromptPrefixCache(), scope = owner(), b = binding(scope), auth = approved(b)
        let session = try request(store, Array(0..<9), scope, binding: b)
        append(session, [0, 1, 2, 3]); eval(session.cache); session.markCacheSubmitted()
        if mode == 0 { auth.revoke(); XCTAssertFalse(auth.approve(binding: b)) }
        if mode == 1 { store.clear(reason: "workspace_closed") }
        if mode == 2 { _ = try request(store, [0, 1, 2, 3, 90], scope) }
        XCTAssertFalse(store.publishJoinedValidPrefix(session,
          proof: proof(.constructorCancelled), authorization: auth))
        XCTAssertFalse(store.hasAnchors)
      }
    }
  }
  func testWrongRequestBindingAndUnknownApprovalAreDenied() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      append(session, [0, 1, 2, 3]); eval(session.cache); session.markCacheSubmitted()
      let unapproved = JoinedKVRetentionAuthorization(binding: b)
      XCTAssertFalse(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: unapproved))
      XCTAssertFalse(store.hasAnchors)
      let other = try request(store, Array(0..<9), scope, binding: b)
      append(other, [0, 1, 2, 3]); eval(other.cache); other.markCacheSubmitted()
      let different = binding(scope)
      XCTAssertFalse(store.publishJoinedValidPrefix(other,
        proof: proof(.constructorCancelled), authorization: approved(different)))
      XCTAssertFalse(store.hasAnchors)
    }
  }
  func testAllLayerDescriptorWithoutSubmissionCannotAuthorizeConstructorRetention() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      append(session, [0, 1, 2, 3]) // Every owning layer, deliberately no submission witness.
      XCTAssertEqual(session.retentionObservation?.lastCompleteTokenCount, 4)
      XCTAssertEqual(session.submittedTokenCount, 0)
      XCTAssertFalse(store.publishJoinedValidPrefix(session,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      XCTAssertFalse(store.hasAnchors)
    }
  }
  func testTerminalProgressDoesNotAuthorizeUnsubmittedFinalGraph() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let session = try request(store, Array(0..<9), scope, binding: b)
      append(session, [0, 1, 2, 3]); asyncEval(session.cache); session.prefill.progress?(4, 9)
      append(session, [4, 5, 6, 7]); asyncEval(session.cache); session.prefill.progress?(8, 9)
      eval(session.cache)
      append(session, [8]) // Same ordering as pinned prepare before final asyncEval.
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
      XCTAssertEqual(query.cache[0].state[0].asArray(Float.self), Array(0..<8).map(Float.init))
    }
  }
  func testSuffixSubmittedProgressMapsToFullPromptPosition() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope)
      let first = try request(store, Array(0..<9), scope, binding: b)
      append(first, [0, 1, 2, 3]); asyncEval(first.cache); first.prefill.progress?(4, 9)
      eval(first.cache)
      XCTAssertTrue(store.publishJoinedValidPrefix(first,
        proof: proof(.constructorCancelled), authorization: approved(b)))
      let nextBinding = binding(scope)
      let next = try request(store, Array(0..<12), scope, binding: nextBinding)
      XCTAssertEqual(next.cachedTokenCount, 4)
      append(next, [4, 5, 6, 7]); asyncEval(next.cache); next.prefill.progress?(4, 8)
      eval(next.cache)
      XCTAssertEqual(next.submittedTokenCount, 8)
      XCTAssertTrue(store.publishJoinedValidPrefix(next,
        proof: proof(.constructorCancelled), authorization: approved(nextBinding)))
      XCTAssertEqual(store.retainedSnapshotObservations.first?.tokenIDs, Array(0..<8))
      let query = try request(store, Array(0..<8) + [900], scope)
      XCTAssertEqual(query.cachedTokenCount, 8)
    }
  }
  func testPromptOnlyBatchSalvageRecordsItsActualWidthOneForward() throws {
    try Device.withDefaultDevice(.cpu) {
      let store = PromptPrefixCache(), scope = owner(), b = binding(scope), ids = Array(0..<9)
      let session = try request(store, ids, scope, binding: b); try prefill(session)
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

}
