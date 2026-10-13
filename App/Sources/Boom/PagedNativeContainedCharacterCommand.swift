import AppKit
import Foundation

/// A complete Cocoa cluster in an actual bounded projection. A known control
/// break resets Unicode lookbehind; an arbitrary overlap or nearby base does not.
enum PagedContainedCharacterBoundary {
  static func cluster(in text: NSString, caretUTF16: Int, forward: Bool,
    atDocumentStart: Bool, atDocumentEnd: Bool) -> NSRange? {
    guard caretUTF16 >= 0, caretUTF16 <= text.length,
      (forward ? caretUTF16 < text.length : caretUTF16 > 0) else { return nil }
    let probe = forward ? caretUTF16 : caretUTF16 - 1
    let cluster = text.rangeOfComposedCharacterSequence(at: probe)
    guard cluster.location != NSNotFound, cluster.location >= 0, cluster.length > 0,
      cluster.location <= text.length, cluster.length <= text.length - cluster.location else { return nil }
    let end = NSMaxRange(cluster)
    guard (forward ? cluster.location == caretUTF16 : end == caretUTF16),
      end < text.length || atDocumentEnd else { return nil }
    // Do not split an observed CRLF even if a platform's composed-range
    // primitive treats it differently from an ordinary editing command.
    if cluster.location > 0, text.character(at: cluster.location) == 10,
      text.character(at: cluster.location - 1) == 13 { return nil }
    if end < text.length, text.character(at: end - 1) == 13,
      text.character(at: end) == 10 { return nil }
    if atDocumentStart { return cluster }
    // Scan the retained prefix, not an invented fixed lookbehind. Without a
    // real reset, preceding RI/ZWJ/Indic/Prepend context may be outside it.
    var index = cluster.location
    while index > 0 {
      index -= 1
      let unit = text.character(at: index)
      if unit <= 0x1f || (0x7f...0x9f).contains(unit) || unit == 0x2028 || unit == 0x2029 {
        // A CR reset is after its following LF, never between the two.
        let reset = unit == 13 && index + 1 < text.length && text.character(at: index + 1) == 10
          ? index + 2 : index + 1
        return reset <= cluster.location ? cluster : nil
      }
    }
    return nil
  }
}

@MainActor extension PagedNativeTextView {
  /// Only adds logical Unicode commands. Existing ASCII/contained-selection
  /// behavior stays intact; visual bidi arrows gain no new admission here.
  func hasContainedCharacterCommand(_ selector: Selector) -> Bool {
    do { try boundedStorage.admitsCurrentArena() } catch { return false }
    // Preserve existing native ASCII/contained-selection admission before the
    // additional Unicode-only focus, scalar and marked-text proofs below.
    if hasContainedASCIICharacterCommand(selector) { return true }
    guard !hasMarkedText(), selectedRanges.count == 1 else { return false }
    let range = selectedRange(), text = boundedStorage.string as NSString
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
      range.location <= text.length, range.length <= text.length - range.location,
      (try? session.nativeSelection(range)) != nil,
      let coordinates = try? session.documentCoordinates(), coordinates.localUTF16 == text.length else { return false }
    let globalStart = coordinates.utf16Start.addingReportingOverflow(UInt64(range.location))
    let globalEnd = coordinates.utf16Start.addingReportingOverflow(UInt64(text.length))
    guard !globalStart.overflow, !globalEnd.overflow else { return false }
    var focusAtEnd = false
    if let owner = inputBinding?.owner {
      guard owner.activeView === self, let owned = try? owner.currentDocumentSelection(),
        owned.utf16Offset == globalStart.partialValue, owned.utf16Length == UInt64(range.length) else { return false }
      focusAtEnd = owned.focusAtEnd
    } else if range.length > 0 { return false } // no invented normalized-range anchor
    let command = NSStringFromSelector(selector)
    let forward: Bool
    switch command {
    case "moveForward:", "moveForwardAndModifySelection:", "deleteForward:": forward = true
    case "moveBackward:", "moveBackwardAndModifySelection:", "deleteBackward:": forward = false
    default: return false
    }
    // Exact selected deletion/collapse has its separate existing owner route.
    if range.length > 0, !command.hasSuffix("AndModifySelection:") { return false }
    let caret = range.length > 0 && focusAtEnd ? NSMaxRange(range) : range.location
    let documentStart = coordinates.utf16Start == 0
    let documentEnd = globalEnd.partialValue == coordinates.projectedUTF16
    if forward && caret == text.length { return documentEnd }
    if !forward && caret == 0 { return documentStart }
    return PagedContainedCharacterBoundary.cluster(in: text, caretUTF16: caret, forward: forward,
      atDocumentStart: documentStart, atDocumentEnd: documentEnd) != nil
  }
}
