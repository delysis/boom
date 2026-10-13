import BoomCore
import Foundation

/// Exact source boundaries. Logical lines additionally include NEL/LS;
/// paragraphs use CR, LF/CRLF and PS. LF counts retain their byte meaning.
struct PagedTextParagraphBounds: Decodable, Sendable, Equatable {
  let start: PagedTextSummary
  let contentEnd: PagedTextSummary
  let end: PagedTextSummary
  let terminated: Bool
  let lfTerminated: Bool

  func validate(in revision: PagedTextRevision, originUTF16: UInt64) throws {
    try start.validate(); try contentEnd.validate(); try end.validate()
    guard start.bytes <= contentEnd.bytes, contentEnd.bytes <= end.bytes,
      start.utf16 <= contentEnd.utf16, contentEnd.utf16 <= end.utf16,
      start.lfCount <= contentEnd.lfCount, contentEnd.lfCount <= end.lfCount,
      end.bytes <= revision.summary.bytes, end.utf16 <= revision.summary.utf16,
      end.lfCount <= revision.summary.lfCount,
      start.utf16 <= originUTF16, originUTF16 <= end.utf16,
      terminated == (contentEnd.bytes < end.bytes),
      !lfTerminated || (terminated && contentEnd.lfCount < UInt64.max && end.lfCount == contentEnd.lfCount + 1),
      lfTerminated || contentEnd.lfCount == end.lfCount else {
      throw BoomError.invalid("Source line boundaries lost their exact extent or LF semantics.")
    }
  }
}
