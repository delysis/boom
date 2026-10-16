import BoomCore
import Foundation

/// Tensor-free handoff from a failed prepared admission. No lease, native
/// descriptor, memory-release estimate or model state escapes with this value.
struct PreparedPairedAdmissionRequest: Error, Equatable, Sendable {
  let operationID: UUID
  let runnerEpoch: UUID
  let modelIdentity: String
  let processorIdentity: String
  let owner: PromptCacheOwner?
  let tokenIDs: [Int]
  let outputTokens: Int
  let batchWidth: Int
  let policy: ModelGenerationPolicy
}

struct PairedAdmissionAttempt: Sendable {
  let deferReclamation: Bool
  let expected: PreparedPairedAdmissionRequest?
  static let normal = Self(deferReclamation: false, expected: nil)
  func validate(_ current: PreparedPairedAdmissionRequest) throws {
    guard expected == nil || expected == current else {
      throw BoomError.stale("The captured prepared request changed during paired-model reclamation.")
    }
  }
}

/// One reclamation opportunity per captured operation, shared by context fit
/// and generation. The lock covers only the bit; callbacks and lease work never
/// execute under it. A rebound source validator shares this same opportunity.
final class PairedContextAdmission: @unchecked Sendable {
  private final class Opportunity: @unchecked Sendable {
    private let lock = NSLock()
    private var spent = false
    func available() -> Bool { lock.lock(); defer { lock.unlock() }; return !spent }
    func claim() -> Bool {
      lock.lock(); defer { lock.unlock() }
      guard !spent else { return false }; spent = true; return true
    }
  }
  private let opportunity: Opportunity
  private let reclaim: @Sendable (PreparedPairedAdmissionRequest) async throws -> Bool
  init(sharingAttempt: PairedContextAdmission? = nil,
    reclaim: @escaping @Sendable (PreparedPairedAdmissionRequest) async throws -> Bool) {
    opportunity = sharingAttempt?.opportunity ?? Opportunity()
    self.reclaim = reclaim
  }
  static func perform<R: Sendable>(using admission: PairedContextAdmission?, flag: CancellationFlag,
    operation: @escaping @Sendable (PairedAdmissionAttempt) async throws -> R) async throws -> R {
    guard let admission else { return try await operation(.normal) }
    let first = PairedAdmissionAttempt(deferReclamation: admission.opportunity.available(), expected: nil)
    do { return try await operation(first) }
    catch let request as PreparedPairedAdmissionRequest {
      try flag.check()
      guard request.operationID == flag.operationID else {
        throw BoomError.stale("The admission handoff belongs to a different operation.")
      }
      if admission.opportunity.claim() {
        // operation() has returned/thrown and must have relinquished its owning
        // coordinator/executor lease before this callback can join the peer.
        do { _ = try await admission.reclaim(request) }
        catch {
          if flag.isCancelled || Task.isCancelled { throw CancellationError() }
          // A source/disk/ownership callback's budget error is not a context-fit
          // result. Do not let fittedRound treat it as permission to trim history.
          throw BoomError.stale("Paired-model reclamation authority failed: " + String(describing: error))
        }
        try flag.check()
      }
      // Even no peer/release uses real measured admission again. Never deduct
      // expected reclaimed weights, native KV or allocator-cache bytes.
      return try await operation(PairedAdmissionAttempt(deferReclamation: false, expected: request))
    }
  }
}
