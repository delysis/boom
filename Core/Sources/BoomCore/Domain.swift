import Foundation

public enum BoomError: Error, LocalizedError, Equatable {
  case invalid(String)
  case stale(String)
  case denied(String)
  case budget(String)
  case unavailable(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let s): return "Invalid data: \(s)"
    case .stale(let s): return "Changed since this request: \(s)"
    case .denied(let s): return "Not permitted: \(s)"
    case .budget(let s): return "Limit reached: \(s)"
    case .unavailable(let s): return s
    }
  }
}
public struct DocumentSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var text: String
  public var revision: String { Digest.sha256(text) }
  public init(id: UUID = UUID(), title: String, text: String) {
    self.id = id
    self.title = title
    self.text = text
  }
}
public enum Role: String, Codable, Sendable { case user, assistant }
public enum MessageState: String, Codable, Sendable { case complete, cancelled, failed }
public enum MessageFeedback: String, Codable, Sendable { case helpful, unhelpful }
public struct SourceReference: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let title: String
  public let digest: String
  public let kind: String
  public init(id: UUID, title: String, digest: String, kind: String) {
    self.id = id
    self.title = title
    self.digest = digest
    self.kind = kind
  }
}
public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let role: Role
  public var text: String
  public var context: String
  public var sources: [SourceReference]
  public var state: MessageState
  public var personaID: UUID?
  public var provider: String?
  public var feedback: MessageFeedback?
  public init(
    id: UUID = UUID(), role: Role, text: String, context: String = "",
    sources: [SourceReference] = [], state: MessageState = .complete, personaID: UUID? = nil,
    provider: String? = nil, feedback: MessageFeedback? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.context = context
    self.sources = sources
    self.state = state
    self.personaID = personaID
    self.provider = provider
    self.feedback = feedback
  }
  public var promptText: String { context.isEmpty ? text : context + "\n\nUSER REQUEST\n" + text }
}
public struct ChatRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var title: String
  public var messages: [ChatMessage]
  public var attachedDocumentID: UUID?
  public init(
    id: UUID = UUID(), title: String = "New chat", messages: [ChatMessage] = [],
    attachedDocumentID: UUID? = nil
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.attachedDocumentID = attachedDocumentID
  }
  public func branch(at messageID: UUID, includeMessage: Bool) throws -> ChatRecord {
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
      throw BoomError.invalid("The selected message is no longer in this chat.")
    }
    let count = index + (includeMessage ? 1 : 0)
    return ChatRecord(
      title: title == "New chat" ? "New chat · branch" : title + " · branch",
      messages: Array(messages.prefix(count)), attachedDocumentID: attachedDocumentID)
  }
}
public struct ModelIdentity: Codable, Equatable, Sendable {
  public let manifestDigest: String
  public let runtimeRevision: String
  public let promptVersion: Int
  public let contextLength: Int
  public init(
    manifestDigest: String, runtimeRevision: String, promptVersion: Int = 2, contextLength: Int
  ) {
    self.manifestDigest = manifestDigest
    self.runtimeRevision = runtimeRevision
    self.promptVersion = promptVersion
    self.contextLength = contextLength
  }
  public var key: String { (try? Digest.identity(self)) ?? "invalid" }
}
public struct Persona: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let slug: String
  public let title: String
  public let messages: [ChatMessage]
  public let prefixDigest: String
  public let model: ModelIdentity
  public let cacheID: UUID
  public let createdAt: Date
  public init(
    id: UUID = UUID(), slug: String, title: String, messages: [ChatMessage], prefixDigest: String,
    model: ModelIdentity, cacheID: UUID, createdAt: Date = Date()
  ) throws {
    guard Self.validSlug(slug), messages.first?.role == .user,
      messages.allSatisfy({ $0.state == .complete }), messages.last?.role == .assistant
    else {
      throw BoomError.invalid(
        "A persona needs a unique lowercase slug and a completed chat ending in an assistant turn.")
    }
    self.id = id
    self.slug = slug
    self.title = title
    self.messages = messages
    self.prefixDigest = prefixDigest
    self.model = model
    self.cacheID = cacheID
    self.createdAt = createdAt
  }
  public static func validSlug(_ s: String) -> Bool {
    s.range(of: "^[a-z][a-z0-9_-]{0,47}$", options: .regularExpression) != nil
  }
}
public enum InteractionMode: String, Codable, CaseIterable, Sendable {
  case ask = "Ask"
  case propose = "Propose"
  case edit = "Edit"
}

/// A callback result belongs to this exact editing state, never just the active window.
public struct GhostStamp: Equatable, Sendable {
  public let documentID: UUID
  public let revision: String
  public let caretUTF16: Int
  public let epoch: UInt64
  public init(document: DocumentSnapshot, caretUTF16: Int, epoch: UInt64) throws {
    _ = try TextBoundary.index(caretUTF16, in: document.text)
    self.documentID = document.id
    self.revision = document.revision
    self.caretUTF16 = caretUTF16
    self.epoch = epoch
  }
  public func accepts(
    document: DocumentSnapshot, caretUTF16: Int, epoch: UInt64, hasMarkedText: Bool
  ) -> Bool {
    !hasMarkedText && document.id == documentID && document.revision == revision
      && caretUTF16 == self.caretUTF16 && epoch == self.epoch
  }
}
public enum TextBoundary {
  /// UTF-16 offsets are the AppKit coordinate system. Reject half-surrogate and half-grapheme cuts.
  public static func index(_ offset: Int, in text: String) throws -> String.Index {
    guard offset >= 0, offset <= text.utf16.count else {
      throw BoomError.invalid("Text offset outside the document.")
    }
    let u = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
    guard let i = String.Index(u, within: text), i == text.endIndex || text.indices.contains(i)
    else { throw BoomError.invalid("Text offset splits a character.") }
    return i
  }
  public static func split(_ text: String, atUTF16 offset: Int) throws -> (String, String) {
    let i = try index(offset, in: text)
    return (String(text[..<i]), String(text[i...]))
  }
}
