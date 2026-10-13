import BoomCore
import Foundation

/// One actual file-published edit, before its physical native installation.
/// The worker retains both full roots until finishCapturedEditInstallation.
struct PagedCapturedEditResult: Sendable, Equatable {
  let sessionID: UUID
  let commandID: UUID
  let groupID: UUID
  let sequence: UInt64
  let beforeRecord: PagedDocumentRootRecord
  let record: PagedDocumentRootRecord
  let window: PagedTextWindow
  let cursor: PagedSealedCursor
  let localCaretUTF16: Int
  let canonicalHistory: PagedNativeCanonicalHistoryProjection

  func validate() throws {
    guard !Thread.isMainThread else { throw BoomError.invalid("Captured edit validation belongs to storage.") }
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    try beforeRecord.validate(); try record.validate(); try window.validate()
    try PagedNativePreparedHistoryMove.validate(window: window, cursor: cursor, localCaretUTF16: localCaretUTF16)
    guard sessionID != zero, commandID != zero, groupID != zero, sequence > 0,
      beforeRecord.document.id == record.document.id,
      beforeRecord.document.revision.ownerID == record.document.revision.ownerID,
      beforeRecord.document.title.utf8.elementsEqual(record.document.title.utf8),
      beforeRecord.historyGeneration < UInt64.max,
      record.historyGeneration == beforeRecord.historyGeneration + 1,
      record.document.revision != beforeRecord.document.revision,
      window.revision == record.document.revision,
      window.text.utf8.count <= PagedWorkingWindow.targetBytes,
      canonicalHistory.beforeRecord == beforeRecord,
      canonicalHistory.currentCursor == cursor,
      canonicalHistory.activeGroup == groupID else {
      throw BoomError.invalid("Captured edit lost its exact source, group or bounded cursor window.")
    }
    try canonicalHistory.admit(record: record, sessionID: sessionID,
      engineIncarnation: canonicalHistory.producer.engineIncarnation,
      scope: .capturedEdit(sessionID: sessionID, commandID: commandID, sequence: sequence))
  }
}

/// Actual exact neutral source observation; never a failed write or ACK.
struct PagedCapturedEditUnchanged: Error, Sendable {
  let record: PagedDocumentRootRecord
  let commandID: UUID
}

protocol PagedNativeCapturedEditingStorage: PagedNativeSessionStorage {
  func commitCapturedEdits(expected: PagedDocumentRootRecord, edits: [PagedTextLocalEdit],
    sessionID: UUID, commandID: UUID, groupID: UUID, sequence: UInt64,
    beforeCursor: PagedSealedCursor, afterSelection: PagedNativeNavigationSelection?) async throws -> PagedCapturedEditResult
  func commitUserReplacement(expected: PagedDocumentRootRecord, selection: PagedNativeNavigationSelection,
    replacement: Data, sessionID: UUID, commandID: UUID, groupID: UUID, sequence: UInt64,
    beforeCursor: PagedSealedCursor) async throws -> PagedCapturedEditResult
  func commitImportedReplacement(expected: PagedDocumentRootRecord, selection: PagedNativeNavigationSelection,
    imported: PagedTextCustodiedValue<PagedTextImportedRevision>, sessionID: UUID, commandID: UUID,
    groupID: UUID, sequence: UInt64, beforeCursor: PagedSealedCursor) async throws -> PagedCapturedEditResult
  func commitLinePrefix(expected: PagedDocumentRootRecord, selection: PagedNativeNavigationSelection,
    prefix: String, sessionID: UUID, commandID: UUID, groupID: UUID, sequence: UInt64,
    beforeCursor: PagedSealedCursor) async throws -> PagedCapturedEditResult
  func finishCapturedEditInstallation(_ result: PagedCapturedEditResult) async throws
}

/// The same entered source job owns the exact original command on failure.
/// No serialized duplicate or whole selection bytes are kept for a user range.
struct PagedCapturedEditInput: Sendable {
  enum Operation: Sendable {
    case edits([PagedTextLocalEdit])
    case replacement(PagedNativeNavigationSelection, Data)
    case importedReplacement(PagedNativeNavigationSelection, PagedTextCustodiedValue<PagedTextImportedRevision>)
    case linePrefix(PagedNativeNavigationSelection, String)
  }
  static let maximumEdits = 32
  static let maximumInputBytes = PagedTextWindow.maximumBytes
  let expected: PagedDocumentRootRecord
  let operation: Operation
  let sessionID: UUID
  let commandID: UUID
  let groupID: UUID
  let sequence: UInt64
  let beforeCursor: PagedSealedCursor
  let afterSelection: PagedNativeNavigationSelection?
  init(expected: PagedDocumentRootRecord, operation: Operation, sessionID: UUID,
    commandID: UUID, groupID: UUID, sequence: UInt64, beforeCursor: PagedSealedCursor,
    afterSelection: PagedNativeNavigationSelection? = nil) {
    self.expected = expected; self.operation = operation; self.sessionID = sessionID
    self.commandID = commandID; self.groupID = groupID; self.sequence = sequence
    self.beforeCursor = beforeCursor; self.afterSelection = afterSelection
  }

  /// Bounded admission charge only; UTF8/source checks occur on the worker.
  func inputCharge() throws -> Int {
    var bytes = 0
    switch operation {
    case .edits(let edits):
      guard !edits.isEmpty, edits.count <= Self.maximumEdits else { throw BoomError.budget("Captured edit count exceeds its bound.") }
      for edit in edits {
        let next = bytes.addingReportingOverflow(edit.oldBytes.count)
        let end = next.partialValue.addingReportingOverflow(edit.newBytes.count)
        guard !next.overflow, !end.overflow, end.partialValue <= Self.maximumInputBytes else {
          throw BoomError.budget("Captured edit buffers exceed their fixed bound.")
        }
        bytes = end.partialValue
      }
    case .replacement(_, let replacement):
      guard replacement.count <= Self.maximumInputBytes else { throw BoomError.budget("Replacement exceeds its fixed source buffer.") }
      bytes = replacement.count
    case .importedReplacement: break // one bounded tree/lease value, no body buffer
    case .linePrefix(_, let prefix):
      guard !prefix.isEmpty, prefix.utf8.count <= 256,
        !prefix.unicodeScalars.contains(where: { [0x0A, 0x0D, 0x85, 0x2028, 0x2029].contains($0.value) }) else {
        throw BoomError.invalid("Line prefix exceeds its fixed bound or contains a separator.")
      }
      bytes = prefix.utf8.count
    }
    return bytes
  }
}
