import AppKit
import BoomCore
import Foundation

protocol PagedNativeDocumentNavigationStorage: PagedNativeSessionStorage {
  func graphemeBoundary(expected: PagedTextRevision, utf16Offset: UInt64, forward: Bool) async throws -> PagedTextSummary
  func paragraphBounds(expected: PagedTextRevision, utf16Offset: UInt64,
    includeLineEndings: Bool) async throws -> PagedTextParagraphBounds
  func documentPosition(expected: PagedTextRevision, utf16Offset: UInt64,
    forward: Bool) async throws -> PagedTextSummary
}

extension PagedNativeDocumentNavigationStorage {
  func paragraphBounds(expected: PagedTextRevision, utf16Offset: UInt64,
    includeLineEndings: Bool) async throws -> PagedTextParagraphBounds {
    throw BoomError.unavailable("This storage route has no document paragraph continuation.")
  }
  func graphemeBoundary(expected: PagedTextRevision, utf16Offset: UInt64, forward: Bool) async throws -> PagedTextSummary {
    throw BoomError.unavailable("This storage route has no document grapheme continuation.")
  }
}

/// Logical source commands only. Visual line and Left/Right commands keep
/// their actual Cocoa geometry; a fragment is never treated as a paragraph.
enum PagedNativeParagraphCommand {
  case beginning, end, beginningSelecting, endSelecting
  case forwardSelecting, backwardSelecting, deleteBeginning, deleteEnd

  init?(_ selector: Selector) {
    switch NSStringFromSelector(selector) {
    case "moveToBeginningOfParagraph:": self = .beginning
    case "moveToEndOfParagraph:": self = .end
    case "moveToBeginningOfParagraphAndModifySelection:": self = .beginningSelecting
    case "moveToEndOfParagraphAndModifySelection:": self = .endSelecting
    case "moveParagraphForwardAndModifySelection:": self = .forwardSelecting
    case "moveParagraphBackwardAndModifySelection:": self = .backwardSelecting
    case "deleteToBeginningOfParagraph:": self = .deleteBeginning
    case "deleteToEndOfParagraph:": self = .deleteEnd
    default: return nil
    }
  }
  var deletes: Bool {
    switch self { case .deleteBeginning, .deleteEnd: return true; default: return false }
  }
  var extends: Bool {
    switch self {
    case .beginningSelecting, .endSelecting, .forwardSelecting, .backwardSelecting: return true
    default: return false
    }
  }
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
