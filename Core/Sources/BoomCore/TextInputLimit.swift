import Foundation

/// AppKit may hand us an NSString-backed String. Range(_:in:) alone can accept
/// half of a surrogate pair on that representation. Validate its UTF-16 code
/// units before bridging any selected substring. Combining marks remain native
/// editable scalars; this gate does not break IME replacement inside a grapheme.
public enum TextInputLimit {
  public static func validateReplacement(in text: String, range: NSRange,
    replacement: String, maximumUTF8Bytes: Int) throws {
    let source = text as NSString
    guard maximumUTF8Bytes >= 0, range.location >= 0, range.length >= 0,
      range.location <= source.length, range.length <= source.length - range.location else {
      throw BoomError.invalid("The text replacement is outside the input.")
    }
    func scalarBoundary(_ offset: Int) -> Bool {
      guard offset > 0, offset < source.length else { return true }
      return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
        || !(0xDC00...0xDFFF).contains(source.character(at: offset))
    }
    guard scalarBoundary(range.location), scalarBoundary(range.location + range.length) else {
      throw BoomError.invalid("The text replacement splits a Unicode scalar.")
    }
    let removed = source.substring(with: range).utf8.count
    let existing = text.utf8.count
    guard removed <= existing else { throw BoomError.invalid("The input encoding changed.") }
    let retained = existing - removed
    guard retained <= maximumUTF8Bytes, replacement.utf8.count <= maximumUTF8Bytes - retained else {
      throw BoomError.budget("The message exceeds its input limit. Nothing was pasted or truncated.")
    }
  }
}
