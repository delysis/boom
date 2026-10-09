import Foundation

/// Short in-caret display; generation stops on tokenizer control IDs.
public enum GemmaPrompt {
  public static func admissibleCompletion(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\u{FFFD}"), !text.contains("\0")
    else { return false }
    return true
  }
  public static func visibleCompletion(_ text: String) -> String? {
    guard let content = text.firstIndex(where: { !$0.isWhitespace }) else {
      return admissibleCompletion(text) ? text : nil
    }
    let paragraph = text[content...].components(separatedBy: "\n\n").first ?? ""
    let visible = String(text[..<content])
      + paragraph.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
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
  private var handlers: [UUID: @Sendable () -> Void] = [:]
  public init() {}
  public func cancel() {
    let callbacks = lock.withLock {
      value = true
      let callbacks = Array(handlers.values)
      handlers.removeAll()
      return callbacks
    }
    for callback in callbacks { callback() }
  }
  /// Registration races safely with cancellation. Callbacks run outside the
  /// lock and may already be executing when their registration is removed.
  public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID? {
    let id: UUID? = lock.withLock {
      guard !value else { return nil }
      let id = UUID()
      handlers[id] = handler
      return id
    }
    if id == nil { handler() }
    return id
  }
  public func removeCancellationHandler(_ id: UUID?) {
    guard let id else { return }
    let removed = lock.withLock { handlers.removeValue(forKey: id) }
    // Captured objects may reenter this flag from deinit. Keep their last
    // release outside the critical section, just like callback execution.
    withExtendedLifetime(removed) {}
  }
  public var isCancelled: Bool { lock.withLock { value } }
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
