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
struct ModelSetupChoice: Sendable {
  let candidate: ModelSetupCandidate
  let directory: URL?
  let checkpoint: PublishedCheckpoint?
}
