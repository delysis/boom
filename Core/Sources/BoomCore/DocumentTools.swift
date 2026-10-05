import Foundation

public struct Replacement: Codable, Equatable, Sendable {
  public let old: String
  public let new: String
  public init(old: String, new: String) {
    self.old = old
    self.new = new
  }
}
public struct DocumentPatch: Codable, Equatable, Sendable, Identifiable {
  public var id: String { documentID.uuidString + ":" + revision }
  public let documentID: UUID
  public let revision: String
  public let replacements: [Replacement]
  public init(documentID: UUID, revision: String, replacements: [Replacement]) {
    self.documentID = documentID
    self.revision = revision
    self.replacements = replacements
  }
}
public struct AssistantEnvelope: Codable, Equatable, Sendable {
  public let reply: String
  public let edits: [DocumentPatch]
  public init(reply: String, edits: [DocumentPatch]) {
    self.reply = reply
    self.edits = edits
  }
}
public struct DocumentGrant: Sendable {
  public let requestID: UUID
  public let mode: InteractionMode
  public let snapshot: DocumentSnapshot
  public init(requestID: UUID = UUID(), mode: InteractionMode, snapshot: DocumentSnapshot) {
    self.requestID = requestID
    self.mode = mode
    self.snapshot = snapshot
  }
}
public struct ValidatedEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacement: String
  public init(range: NSRange, replacement: String) {
    self.range = range
    self.replacement = replacement
  }
}
