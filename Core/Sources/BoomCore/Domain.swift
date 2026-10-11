import Foundation
import Synchronization

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
/// Owned by one exact snapshot text value. Copies may share only until a text
/// assignment replaces the memo. It retains the digest, never the source text.
private final class SnapshotRevisionMemo: Sendable {
  private let cached = Mutex<String?>(nil)
  func revision(for text: String) -> String {
    cached.withLock { value in
      if let value { return value }
      let digest = Digest.sha256(text)
      value = digest
      return digest
    }
  }
}
public struct DocumentSnapshot: Codable, Equatable, Identifiable, Sendable {
  private enum CodingKeys: String, CodingKey { case id, title, text }
  private var revisionMemo = SnapshotRevisionMemo()
  public let id: UUID
  public var title: String
  public var text: String {
    didSet { textVersion = UUID(); revisionMemo = SnapshotRevisionMemo() }
  }
  /// Local change identity for native synchronization. Never encoded or used
  /// in place of the content digest for authorization, evidence or replay.
  public private(set) var textVersion = UUID()
  public var revision: String { revisionMemo.revision(for: text) }
  public init(id: UUID = UUID(), title: String, text: String) {
    self.id = id
    self.title = title
    self.text = text
  }
  public static func == (left: Self, right: Self) -> Bool {
    left.id == right.id && left.title == right.title
      && (left.textVersion == right.textVersion || left.text.utf8.elementsEqual(right.text.utf8))
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
public enum ConsultationPromptContract: String, Codable, Equatable, Sendable {
  case textHistoryV1 = "text_history_v1"
  case referenceHistoryV2 = "reference_history_v2"
  case referenceBindingsV3 = "reference_bindings_v3"
}
public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
  private enum CodingKeys: String, CodingKey {
    case id, role, timestamp, text, context, sources, directAttachments, state
    case provider, feedback, speaker, failure, authoredByUser, editedFrom
    case consultationRouting, consultationPromptContract
  }
  /// Local ownership for the derived reading text, not persistence or authority.
  /// Copies retain it; text/state/failure assignment and decoding create a new one.
  public private(set) var readingVersion = UUID()
  public let id: UUID
  public let role: Role
  public let timestamp: Date?
  public var text: String { didSet { readingVersion = UUID() } }
  public var context: String
  public var sources: [SourceReference]
  public let directAttachments: [UUID]?
  public var state: MessageState { didSet { readingVersion = UUID() } }
  public var provider: String?
  public var feedback: MessageFeedback?
  public var speaker: Speaker?
  public var failure: String? { didSet { readingVersion = UUID() } }
  public var authoredByUser: Bool?
  public var editedFrom: UUID?
  /// Captured only when this user turn actually enters a consultation plan.
  /// Missing metadata remains legacy; never infer it from today's routing.
  public let consultationRouting: [String]?
  public let consultationPromptContract: ConsultationPromptContract?
  public init(
    id: UUID = UUID(), role: Role, text: String, context: String = "",
    sources: [SourceReference] = [], state: MessageState = .complete,
    provider: String? = nil, feedback: MessageFeedback? = nil, speaker: Speaker? = nil, failure: String? = nil,
    authoredByUser: Bool? = nil, editedFrom: UUID? = nil, timestamp: Date? = Date(),
    directAttachments: [UUID]? = nil, consultationRouting: [String]? = nil,
    consultationPromptContract: ConsultationPromptContract? = nil
  ) {
    self.id = id
    self.role = role
    self.timestamp = timestamp
    self.text = text
    self.context = context
    self.sources = sources
    self.directAttachments = directAttachments
    self.state = state
    self.provider = provider
    self.feedback = feedback
    self.speaker = speaker
    self.failure = failure
    self.authoredByUser = authoredByUser
    self.editedFrom = editedFrom
    self.consultationRouting = consultationRouting
    self.consultationPromptContract = consultationPromptContract
  }
  public var promptText: String { context.isEmpty ? text : context + "\n\nUSER REQUEST\n" + text }
  public static func == (left: Self, right: Self) -> Bool {
    // A local reading version never changes ordinary canonical value equality.
    left.id == right.id && left.role == right.role && left.timestamp == right.timestamp
      && left.text == right.text && left.context == right.context && left.sources == right.sources
      && left.directAttachments == right.directAttachments && left.state == right.state
      && left.provider == right.provider && left.feedback == right.feedback && left.speaker == right.speaker
      && left.failure == right.failure && left.authoredByUser == right.authoredByUser
      && left.editedFrom == right.editedFrom && left.consultationRouting == right.consultationRouting
      && left.consultationPromptContract == right.consultationPromptContract
  }
}
public struct ChatRecord: Codable, Equatable, Sendable, Identifiable {
  private enum CodingKeys: String, CodingKey {
    case id, title, messages, attachedDocumentID, instructions, messageVersions
  }
  public let id: UUID
  public var title: String { didSet { contentVersion = UUID() } }
  public var messages: [ChatMessage] { didSet { contentVersion = UUID() } }
  public var attachedDocumentID: UUID? { didSet { contentVersion = UUID() } }
  public var instructions: String? { didSet { contentVersion = UUID() } }
  public var messageVersions: [ChatMessage]? { didSet { contentVersion = UUID() } }
  /// Local ownership for cached context. Copies retain it; encoded-field edits
  /// and decoding create a fresh identity. Never substitute it for a digest.
  public private(set) var contentVersion = UUID()
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
  public static func == (left: Self, right: Self) -> Bool {
    guard left.id == right.id else { return false }
    if left.contentVersion == right.contentVersion { return true }
    // Keep value equality after decoding, including Swift String's canonical
    // semantics. Exact context ownership uses contentVersion and encoded SHA,
    // never this independently constructed value fallback.
    return left.title == right.title && left.messages == right.messages
      && left.attachedDocumentID == right.attachedDocumentID
      && left.instructions == right.instructions && left.messageVersions == right.messageVersions
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
