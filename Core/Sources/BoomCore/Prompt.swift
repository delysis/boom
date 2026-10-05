import Foundation

/// Short in-caret display; generation stops on tokenizer control IDs.
public enum GemmaPrompt {
  public static func admissibleCompletion(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\u{FFFD}"), !text.contains("\0")
    else { return false }
    return true
  }
  public static func visibleCompletion(_ text: String) -> String? {
    let paragraph = text.components(separatedBy: "\n\n").first ?? ""
    let visible = paragraph.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
    return admissibleCompletion(visible) ? visible : nil
  }
}

public enum ContextExcerpt {
  /// Keep the beginning and end of a source in authored order. The marker is
  /// part of the actual captured prompt, so omission cannot masquerade as a
  /// complete document or an exact quotation.
  public static func middle(_ text: String, keeping characters: Int) -> String {
    guard characters >= 0, characters < text.count else { return text }
    let first = (characters + 1) / 2
    let last = characters / 2
    return String(text.prefix(first))
      + "\n[\(text.count - characters) source characters omitted from the middle]\n"
      + String(text.suffix(last))
  }
}

/// Used by synchronous native prediction loops as well as their async owners.
/// Cancellation does not release ownership. The caller must await completion.
public final class CancellationFlag: @unchecked Sendable {
  public let operationID = UUID()
  private let lock = NSLock()
  private var value = false
  public init() {}
  public func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  public func check() throws { if isCancelled { throw CancellationError() } }
}

public enum DownloadPolicy {
  public static func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"),
      !path.contains(":"), !path.contains("%"), !path.contains("\0"),
      !path.unicodeScalars.contains(where: { $0.value < 32 })
    else { throw BoomError.invalid("Unsafe model asset path.") }
    guard
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".."
      })
    else { throw BoomError.invalid("Unsafe model asset path components.") }
  }
  public static func permits(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, let host = url.host?.lowercased()
    else { return false }
    return host == "huggingface.co" || host == "cdn-lfs.huggingface.co"
      || host == "cdn-lfs-us-1.huggingface.co" || host == "cdn-lfs-eu-1.huggingface.co"
      || host == "cas-bridge.xethub.hf.co" || host == "us.aws.cdn.hf.co"
  }
}
