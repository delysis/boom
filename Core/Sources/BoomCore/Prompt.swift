import Foundation

/// Matches the inspected Gemma-4 CoreML bundle turn tokens. No user content may
/// manufacture turn/media delimiters; escape visible spellings before tokenization.
public enum GemmaPrompt {
  public static let version = 3
  public static func safe(_ text: String) -> String {
    // Escape only protocol-token spellings. Ordinary Markdown, comparisons,
    // and embedded HTML must remain byte-for-byte available for exact edits.
    text.replacingOccurrences(
      of: #"<(\|[^<>\r\n]*|[^<>\r\n]*\||bos|eos|pad|unk|start_of_turn|end_of_turn)>"#,
      with: "‹$1›", options: .regularExpression)
  }
  private struct Turn {
    var role: Role
    var text: String
  }
  private static func closedTurns(_ messages: [ChatMessage]) -> String {
    var turns: [Turn] = []
    for message in messages {
      let text = safe(message.promptText)
      if turns.last?.role == message.role {
        turns[turns.count - 1].text += "\n\n" + text
      } else {
        turns.append(Turn(role: message.role, text: text))
      }
    }
    return turns.map {
      "<|turn>" + ($0.role == .user ? "user" : "model") + "\n" + $0.text + "<turn|>"
    }.joined(separator: "\n")
  }
  public static func prefix(_ messages: [ChatMessage]) throws -> String {
    guard messages.first?.role == .user, messages.last?.role == .assistant,
      messages.allSatisfy({ $0.state == .complete })
    else {
      throw BoomError.invalid(
        "A persona requires completed user/assistant history ending in an assistant turn. Interrupted turns are not silently dropped."
      )
    }
    return "<bos>" + closedTurns(messages)
  }
  public static func conversation(prefix: String? = nil, history: [ChatMessage], request: String)
    -> String
  {
    let turns = history.filter { $0.state == .complete } + [ChatMessage(role: .user, text: request)]
    let beginning = prefix.map { $0 + "\n" } ?? "<bos>"
    return beginning + closedTurns(turns) + "\n<|turn>model\n"
  }
  /// A checkpoint within the first user turn, not a synthetic assistant answer.
  /// It excludes the current draft, so editing that draft does not rewrite the
  /// followed-document cache. Token-prefix equality is checked by the runtime.
  public static func followedPrefix(_ context: ContextPlan, bodyCharacters: Int? = nil) -> String? {
    guard !context.documents.isEmpty else { return nil }
    return "<bos>" + safe(bodyCharacters.map { context.excerpt(keeping: $0) } ?? context.text)
      + "\n\n"
  }
  public static func completion(
    document: DocumentSnapshot, caretUTF16: Int, context: ContextPlan, prefixCharacters: Int = 2048,
    suffixCharacters: Int = 512, sourceBodyCharacters: Int? = nil
  ) throws -> String {
    let window = try CompletionWindow(
      document: document, caretUTF16: caretUTF16, prefixCharacters: prefixCharacters,
      suffixCharacters: suffixCharacters)
    guard !window.before.isEmpty else {
      throw BoomError.unavailable("Write some text before requesting a continuation.")
    }
    // Only the model's beginning-of-sequence marker and authored source text
    // are supplied. No chat turn, role, or instruction surrounds the draft.
    if let prefix = followedPrefix(context, bodyCharacters: sourceBodyCharacters) {
      return prefix + safe(window.before)
    }
    return "<bos>" + safe(window.before)
  }
  public static func admissibleCompletion(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\u{FFFD}"), !text.contains("\0")
    else { return false }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !["<think", "<|", "<turn|", "<bos>", "here is", "here's", "```"].contains(
      where: t.hasPrefix)
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

public struct CacheDescriptor: Codable, Equatable, Sendable {
  public let schema: Int
  public let model: ModelIdentity
  public let prefixDigest: String
  public let payloadDigest: String
  public let tokenCount: Int
  public init(model: ModelIdentity, prefixDigest: String, payload: Data, tokenCount: Int) {
    schema = 1
    self.model = model
    self.prefixDigest = prefixDigest
    payloadDigest = Digest.sha256(payload)
    self.tokenCount = tokenCount
  }
  public func validate(model: ModelIdentity, prefix: String, payload: Data) throws {
    guard schema == 1 else {
      throw BoomError.invalid("Unknown persona-cache schema; file retained.")
    }
    guard self.model == model, prefixDigest == Digest.sha256(prefix) else {
      throw BoomError.stale("Persona cache model or prompt changed; rebuild required.")
    }
    guard tokenCount > 0, tokenCount < model.contextLength, payloadDigest == Digest.sha256(payload)
    else { throw BoomError.invalid("Persona cache is corrupt or out of bounds; file retained.") }
  }
}

/// Used by synchronous native prediction loops as well as their async owners.
/// Cancellation does not release ownership. The caller must await completion.
public final class CancellationFlag: @unchecked Sendable {
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
  public static let repositories = ["mlboydaisuke/gemma-4-E2B-coreml"]
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

/// Autocomplete is intentionally a caret-local operation. Omitted text is labelled
/// in the prompt and UI; chat/edit source capture still uses full document snapshots.
public struct CompletionWindow: Equatable, Sendable {
  public let before: String
  public let after: String
  public let startUTF16: Int
  public let endUTF16: Int
  public let totalUTF16: Int
  public var isExcerpt: Bool { startUTF16 != 0 || endUTF16 != totalUTF16 }
  public var scopeDescription: String {
    isExcerpt
      ? "excerpt UTF-16 \(startUTF16)..<\(endUTF16) of \(totalUTF16); text outside this range was not supplied"
      : "entire document"
  }
  public init(
    document: DocumentSnapshot, caretUTF16: Int, prefixCharacters: Int = 2048,
    suffixCharacters: Int = 512
  ) throws {
    guard prefixCharacters >= 0, suffixCharacters >= 0 else {
      throw BoomError.invalid("Negative autocomplete context limit.")
    }
    let split = try TextBoundary.split(document.text, atUTF16: caretUTF16)
    before = String(split.0.suffix(prefixCharacters))
    after = String(split.1.prefix(suffixCharacters))
    startUTF16 = caretUTF16 - before.utf16.count
    endUTF16 = caretUTF16 + after.utf16.count
    totalUTF16 = document.text.utf16.count
  }
}
