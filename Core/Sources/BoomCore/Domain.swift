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
public enum MessageState: String, Codable, Sendable { case pending, complete, cancelled, failed }
public struct Speaker: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey { case name, voiceID = "voiceId", voiceRevision }
  public let name: String
  public let voiceID: UUID?
  public let voiceRevision: String?
  public init(name: String, voiceID: UUID? = nil, voiceRevision: String? = nil) {
    self.name = name; self.voiceID = voiceID; self.voiceRevision = voiceRevision
  }
}
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
  public let timestamp: Date?
  public var text: String
  public var context: String
  public var sources: [SourceReference]
  public var state: MessageState
  public var provider: String?
  public var feedback: MessageFeedback?
  public var speaker: Speaker?
  public var failure: String?
  public var authoredByUser: Bool?
  public var editedFrom: UUID?
  public init(
    id: UUID = UUID(), role: Role, text: String, context: String = "",
    sources: [SourceReference] = [], state: MessageState = .complete,
    provider: String? = nil, feedback: MessageFeedback? = nil, speaker: Speaker? = nil, failure: String? = nil,
    authoredByUser: Bool? = nil, editedFrom: UUID? = nil, timestamp: Date? = Date()
  ) {
    self.id = id
    self.role = role
    self.timestamp = timestamp
    self.text = text
    self.context = context
    self.sources = sources
    self.state = state
    self.provider = provider
    self.feedback = feedback
    self.speaker = speaker
    self.failure = failure
    self.authoredByUser = authoredByUser
    self.editedFrom = editedFrom
  }
  public var promptText: String { context.isEmpty ? text : context + "\n\nUSER REQUEST\n" + text }
}
public struct ChatRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var title: String
  public var messages: [ChatMessage]
  public var attachedDocumentID: UUID?
  public var instructions: String?
  public var messageVersions: [ChatMessage]?
  public init(
    id: UUID = UUID(), title: String = "New chat", messages: [ChatMessage] = [],
    attachedDocumentID: UUID? = nil, instructions: String? = nil
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.attachedDocumentID = attachedDocumentID
    self.instructions = instructions
  }
  public func branch(at messageID: UUID, includeMessage: Bool) throws -> ChatRecord {
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
      throw BoomError.invalid("The selected message is no longer in this chat.")
    }
    let count = index + (includeMessage ? 1 : 0)
    return ChatRecord(
      title: title == "New chat" ? "New chat · branch" : title + " · branch",
      messages: Array(messages.prefix(count)), attachedDocumentID: attachedDocumentID, instructions: instructions)
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
