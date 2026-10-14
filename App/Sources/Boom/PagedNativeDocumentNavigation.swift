import AppKit
import BoomCore
import Foundation

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
/// describes the actual logical source; the separate record is its last saved
/// checkpoint. No file revision is rewritten to describe unsaved text.
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
