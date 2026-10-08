import Foundation

struct ModelSetupCandidate: Codable, Sendable {
  let identity: String
  let purpose: ModelPurpose
  let weightBytes: UInt64
  let diskBytes: UInt64
  let cached: Bool
  let rank: Int
}
struct ModelSetupPlan: Decodable, Sendable {
  let consultation: String
  let writing: String?
  let reuseConsultation: Bool
  let weightLimitBytes: UInt64
  let totalWeightBytes: UInt64
  let requiredDiskBytes: UInt64
}
struct ModelSetupChoice: Sendable, Identifiable {
  let candidate: ModelSetupCandidate
  let directory: URL?
  let checkpoint: PublishedCheckpoint?
  var id: String { candidate.identity }
  var title: String {
    let repository = checkpoint?.repository ?? "gemma-4-12B"
    if repository.lowercased().contains("e2b") { return "Gemma 4 E2B" }
    if repository.lowercased().contains("e4b") { return "Gemma 4 E4B" }
    return "Gemma 4 12B"
  }
  var purposeLabel: String { candidate.purpose == .consultation ? "Chat" : "Write" }
}
