import Foundation

/// Per-request permission for transient historical KV, separate from UI and
/// encrypted checkpoint acceptance. The caller binds the exact loaded runner,
/// processor, policy, workspace lifetime and operation before makeSession.
struct JoinedKVRetentionBinding: Codable, Equatable, Sendable {
  let owner: PromptCacheOwner
  let workspaceEpoch: UUID
  let runnerEpoch: UUID
  let modelIdentity: String
  let processorIdentity: String
  let policyDigest: String
  let operationID: UUID
}

/// These facts come from the common owned-operation finalizer, after every
/// producer is joined and its existing GPU fence completes. Progress callbacks
/// alone are not a fence proof. No object here performs MLX work.
struct JoinedKVRetentionProof: Sendable {
  enum Termination: String, Codable, Sendable { case constructorCancelled, decodeCancelled }
  let termination: Termination
  let producerJoined: Bool
  let existingFenceCompleted: Bool
  let checkpointUncertain: Bool
  let memoryLimitExceeded: Bool
  let statelessTextKVVerified: Bool
  var permitsRetention: Bool {
    producerJoined && existingFenceCompleted && !checkpointUncertain
      && !memoryLimitExceeded && statelessTextKVVerified
  }
}

/// Retention origin metadata is not an exact replay history. The actual
/// ForwardSegments retain their native width/row/evaluated endpoint; original
/// inputs and batch operand matrices still need independent source receipts.
struct JoinedKVRetentionProvenance: Codable, Sendable {
  let binding: JoinedKVRetentionBinding
  let termination: JoinedKVRetentionProof.Termination
  let promptTokenCount: Int
  let representedTokenCount: Int
  let lastCompleteCohortTokenCount: Int
  let lastSubmittedCohortTokenCount: Int
  let acknowledgedGeneratedTokenCount: Int
  let representedGeneratedTokenCount: Int
}

/// The namespace/model owner explicitly approves after joined finalization.
/// Revocation is monotonic. Approval cannot undo shutdown, invalidation, memory
/// failure or a failed checkpoint. This bridge synchronizes metadata only.
final class JoinedKVRetentionAuthorization: @unchecked Sendable {
  let id = UUID()
  let binding: JoinedKVRetentionBinding
  private let lock = NSLock()
  private var approved = false
  private var revoked = false
  init(binding: JoinedKVRetentionBinding) { self.binding = binding }
  @discardableResult func approve(binding expected: JoinedKVRetentionBinding) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard binding == expected, !revoked else { return false }
    approved = true; return true
  }
  func revoke() { lock.lock(); revoked = true; lock.unlock() }
  /// Only PromptPrefixCache's final metadata insertion uses this critical
  /// section. Its body must never call an authority, await, or evaluate MLX.
  /// revoke() itself never calls a manager while holding this lock.
  func withAuthorization<R>(binding expected: JoinedKVRetentionBinding,
    _ body: () -> R) -> R? {
    lock.lock(); defer { lock.unlock() }
    guard approved, !revoked, binding == expected else { return nil }
    return body()
  }
}

/// Explicit production opt-in. Diagnostics keep their existing nil default.
/// A successful trusted durable callback is the only generated-token ack.
struct JoinedKVRetentionRequest: Sendable {
  let authorization: JoinedKVRetentionAuthorization
  let checkpointIsDurable: Bool
  let authorizeAfterJoin: @Sendable () async -> Bool
  var binding: JoinedKVRetentionBinding { authorization.binding }
}
