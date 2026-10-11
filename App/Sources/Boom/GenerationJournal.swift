import BoomCore
import Foundation

struct GenerationIdentity: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case consultation, documentResponse = "document_response", writing }
  let kind: Kind
  let operationID: UUID
  let recordID: UUID
  let attemptID: UUID
  let model: String
  let seed: UInt64
  let requestDigest: String
  let maxTokens: Int
  let generationPolicy: ModelGenerationPolicy?
  var batch: WritingBatchExecution? = nil
}
/// A durable observation of the admitted lookup, not a warm replay transcript.
/// Absent metadata is unknown; a historical policy never implies a cold run.
struct GenerationExecutionOrigin: Codable, Equatable, Sendable {
  let schema: Int
  let cacheAlgorithm: String
  let cachedPromptTokens: Int
  let cacheMissReason: String?

  func isValid(promptTokens: Int) -> Bool {
    guard schema == 1, promptTokens > 0, promptTokens <= 16_384,
      cachedPromptTokens >= 0, cachedPromptTokens < promptTokens,
      Self.identifier(cacheAlgorithm) else { return false }
    if cachedPromptTokens > 0 { return cacheMissReason == nil }
    return cacheMissReason.map(Self.identifier) == true
  }
  func isConfirmedCold(promptTokens: Int) -> Bool {
    isValid(promptTokens: promptTokens) && cachedPromptTokens == 0
  }
  private static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || $0 == 45 || $0 == 46 || $0 == 95
    }
  }
}

struct GenerationProgress: Codable, Sendable {
  let text: String
  let tokenIDs: [Int]
  let promptDigest: String
  let promptTokens: Int
  let firstTokenSeconds: Double?
  let elapsedSeconds: Double
  var executionOrigin: GenerationExecutionOrigin? = nil
}
struct GenerationCheckpoint: Codable, Sendable {
  let schema: Int
  let identity: GenerationIdentity
  let progress: GenerationProgress
  let stopReason: String?
  var stopTokenID: Int? = nil
}

extension ProductCore {
  static func generationCheckpoint(_ next: GenerationCheckpoint, expected: GenerationIdentity,
    previous: GenerationCheckpoint? = nil) throws -> GenerationCheckpoint {
    try call(["op": "generation_checkpoint", "expected": object(expected),
      "previous": try previous.map { try object($0) } ?? NSNull(), "next": object(next)])
  }
}

extension WorkspaceStore {
  // The store actor serializes checkpoints with workspace saves. The model
  // consumer awaits admission, so there is no detached backlog to overwrite a
  // final result after cancellation or the next attempt.
  func checkpoint(_ progress: GenerationProgress, identity: GenerationIdentity,
    stopReason: String?, stopTokenID: Int? = nil) throws {
    let trace = PerformanceTrace.begin("Storage.Checkpoint")
    defer { PerformanceTrace.end("Storage.Checkpoint", trace) }
    let previous = try generationCheckpoint(identity: identity)
    let next = try ProductCore.generationCheckpoint(
      GenerationCheckpoint(schema: 1, identity: identity, progress: progress, stopReason: stopReason, stopTokenID: stopTokenID),
      expected: identity, previous: previous)
    try vault.encode(next, kind: .generationJournal, id: identity.attemptID)
  }
  func generationCheckpoint(identity: GenerationIdentity) throws -> GenerationCheckpoint? {
    let trace = PerformanceTrace.begin("Storage.CheckpointRead")
    defer { PerformanceTrace.end("Storage.CheckpointRead", trace) }
    guard vault.exists(.generationJournal, identity.attemptID) else { return nil }
    return try ProductCore.generationCheckpoint(
      vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: identity.attemptID),
      expected: identity)
  }
  func consultationCheckpoint(id: UUID, receipt: ConsultationReceipt) throws -> GenerationCheckpoint? {
    let attemptID = receipt.attemptID ?? id
    guard vault.exists(.generationJournal, attemptID) else { return nil }
    let journal = try vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: attemptID)
    let expected = GenerationIdentity(kind: journal.identity.kind == .documentResponse ? .documentResponse : .consultation,
      operationID: receipt.operationID, recordID: receipt.responseID ?? id, attemptID: attemptID, model: receipt.model,
      seed: receipt.seed, requestDigest: Digest.sha256(receipt.plan.rawPrompt), maxTokens: journal.identity.maxTokens,
      generationPolicy: receipt.generationPolicy)
    let admitted = try ProductCore.generationCheckpoint(journal, expected: expected)
    try validateExecutionOrigin(receipt.executionOrigin, journal: admitted)
    return admitted
  }
  func writingCheckpoint(bundle: CandidateBundle, candidate: WritingCandidate) throws -> GenerationCheckpoint? {
    guard vault.exists(.generationJournal, candidate.id) else { return nil }
    let journal = try vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: candidate.id)
    let expected = GenerationIdentity(kind: .writing, operationID: journal.identity.operationID,
      recordID: bundle.id, attemptID: candidate.id, model: bundle.recipe.model,
      seed: candidate.seed, requestDigest: bundle.recipe.promptDigest, maxTokens: bundle.recipe.maxTokens,
      generationPolicy: bundle.recipe.generationPolicy, batch: candidate.batch)
    let admitted = try ProductCore.generationCheckpoint(journal, expected: expected)
    try validateExecutionOrigin(candidate.executionOrigin, journal: admitted)
    return admitted
  }
  private func validateExecutionOrigin(_ captured: GenerationExecutionOrigin?, journal: GenerationCheckpoint) throws {
    guard captured == nil || captured == journal.progress.executionOrigin else {
      throw BoomError.invalid("The recorded execution origin differs from its checkpoint; records retained.")
    }
  }
}

extension ConsultationReceipt {
  mutating func retain(_ journal: GenerationCheckpoint) {
    retain(journal.progress); stopTokenID = journal.stopTokenID
  }
  mutating func retain(_ progress: GenerationProgress) {
    promptDigest = progress.promptDigest; tokenIDs = progress.tokenIDs
    firstTokenSeconds = progress.firstTokenSeconds; elapsedSeconds = progress.elapsedSeconds
    executionOrigin = progress.executionOrigin
  }
}
extension WritingCandidate {
  /// Live interruption and relaunch use the same durable terminal state.
  /// A cancelled sibling cannot rewrite a row that already completed.
  mutating func finishInterrupted(_ journal: GenerationCheckpoint?, failed: Bool = false,
    reason: String = "interrupted") {
    guard state == .pending else { return }
    if let journal {
      retain(journal)
      if let stop = journal.stopReason, stop != "cancelled" {
        state = journal.progress.text.isEmpty ? .failed : .complete
        stopReason = stop
        return
      }
    }
    state = failed ? .failed : .cancelled
    stopReason = reason
  }
  mutating func retain(_ journal: GenerationCheckpoint) {
    retain(journal.progress); stopTokenID = journal.stopTokenID
  }
  mutating func retain(_ progress: GenerationProgress) {
    text = progress.text; promptTokens = progress.promptTokens
    tokenIDs = progress.tokenIDs; outputTokens = progress.tokenIDs.count
    executionOrigin = progress.executionOrigin
  }
  func coldReplayPolicy(recipe: CompletionRecipe, loadedModel: String,
    loadedPolicy: ModelGenerationPolicy) throws -> ModelGenerationPolicy {
    guard state == .complete, recipe.model == loadedModel,
      executionOrigin?.isConfirmedCold(promptTokens: promptTokens) == true else {
      throw BoomError.unavailable("Seed replay requires a confirmed cold execution; saved output is retained.")
    }
    if let batch { try ProductCore.validateWritingBatch(batch, seed: seed) }
    return try ProductCore.resolvedGenerationPolicy(recipe.generationPolicy, loaded: loadedPolicy)
  }
}
