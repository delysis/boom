import Foundation

public enum CompletionNavigation {
  /// Advance one whitespace-delimited word, retaining surrounding whitespace
  /// exactly. String indices keep emoji and composed characters intact.
  public static func nextChunk(_ completion: String) -> (accepted: String, remaining: String) {
    guard !completion.isEmpty else { return ("", "") }
    var cursor = completion.startIndex
    while cursor < completion.endIndex, completion[cursor].isWhitespace {
      completion.formIndex(after: &cursor)
    }
    while cursor < completion.endIndex, !completion[cursor].isWhitespace {
      completion.formIndex(after: &cursor)
    }
    while cursor < completion.endIndex, completion[cursor].isWhitespace {
      completion.formIndex(after: &cursor)
    }
    return (String(completion[..<cursor]), String(completion[cursor...]))
  }
}
