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
}
struct GenerationProgress: Codable, Sendable {
  let text: String
  let tokenIDs: [Int]
  let promptDigest: String
  let promptTokens: Int
  let firstTokenSeconds: Double?
  let elapsedSeconds: Double
}
struct GenerationCheckpoint: Codable, Sendable {
  let schema: Int
  let identity: GenerationIdentity
  let progress: GenerationProgress
  let stopReason: String?
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
    stopReason: String?) throws {
    let previous = try generationCheckpoint(identity: identity)
    let next = try ProductCore.generationCheckpoint(
      GenerationCheckpoint(schema: 1, identity: identity, progress: progress, stopReason: stopReason),
      expected: identity, previous: previous)
    try vault.encode(next, kind: .generationJournal, id: identity.attemptID)
  }
  func generationCheckpoint(identity: GenerationIdentity) throws -> GenerationCheckpoint? {
    guard vault.exists(.generationJournal, identity.attemptID) else { return nil }
    return try ProductCore.generationCheckpoint(
      vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: identity.attemptID),
      expected: identity)
  }
  func consultationCheckpoint(id: UUID, receipt: ConsultationReceipt) throws -> GenerationCheckpoint? {
    guard vault.exists(.generationJournal, id) else { return nil }
    let journal = try vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: id)
    let expected = GenerationIdentity(kind: journal.identity.kind == .documentResponse ? .documentResponse : .consultation,
      operationID: receipt.operationID, recordID: id, attemptID: id, model: receipt.model,
      seed: receipt.seed, requestDigest: Digest.sha256(receipt.plan.rawPrompt), maxTokens: journal.identity.maxTokens)
    return try ProductCore.generationCheckpoint(journal, expected: expected)
  }
  func writingCheckpoint(bundle: CandidateBundle, candidate: WritingCandidate) throws -> GenerationCheckpoint? {
    guard vault.exists(.generationJournal, candidate.id) else { return nil }
    let journal = try vault.decode(GenerationCheckpoint.self, kind: .generationJournal, id: candidate.id)
    let expected = GenerationIdentity(kind: .writing, operationID: journal.identity.operationID,
      recordID: bundle.id, attemptID: candidate.id, model: bundle.recipe.model,
      seed: candidate.seed, requestDigest: bundle.recipe.promptDigest, maxTokens: bundle.recipe.maxTokens)
    return try ProductCore.generationCheckpoint(journal, expected: expected)
  }
}

extension ConsultationReceipt {
  mutating func retain(_ progress: GenerationProgress) {
    promptDigest = progress.promptDigest; tokenIDs = progress.tokenIDs
    firstTokenSeconds = progress.firstTokenSeconds; elapsedSeconds = progress.elapsedSeconds
  }
}
extension WritingCandidate {
  mutating func retain(_ progress: GenerationProgress) {
    text = progress.text; promptTokens = progress.promptTokens
    tokenIDs = progress.tokenIDs; outputTokens = progress.tokenIDs.count
  }
}
