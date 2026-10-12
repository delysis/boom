import AppKit
import BoomCore
import Foundation

protocol PagedNativeDocumentNavigationStorage: PagedNativeSessionStorage {
  func documentPosition(expected: PagedTextRevision, utf16Offset: UInt64,
    forward: Bool) async throws -> PagedTextSummary
}

/// Presentation coordinates for the actual working arena. Projected extent
/// includes local unsealed input; the immutable record remains the sealed
/// authority. No summary/root or source digest is rewritten to describe it.
struct PagedNativeDocumentCoordinates: Sendable {
  let record: PagedDocumentRootRecord
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
  let windowID: UUID
  let utf16Start: UInt64
  let localUTF16: Int
  let projectedUTF16: UInt64
  let localBytes: Int
}
