import BoomCore
import Foundation

struct BlessengerContact: Codable, Equatable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable { case contact, chat }
  let id: UUID
  let revision: String
  let handle: String
  let name: String
  let kind: Kind
  init(id: UUID, revision: String, handle: String, name: String, kind: Kind) {
    self.id = id; self.revision = revision; self.handle = handle; self.name = name; self.kind = kind
  }
  init(_ voice: Voice, kind: Kind = .contact) {
    id = voice.id; revision = voice.revision; handle = voice.slug; name = voice.name; self.kind = kind
  }
}
struct BlessengerGroup: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var handle: String
  var name: String
  var members: [BlessengerContact]
}
struct BlessengerDraft: Codable, Equatable, Identifiable, Sendable {
  static let unsentID = UUID(uuidString: "D826975E-4876-480E-AF1C-BD077956F388")!
  let id: UUID
  var version = UUID()
  var text = ""
  var attachments: [UUID] = []
  var recipients: [BlessengerContact] = []
  var groupName: String?
  private var recipientQueryValue: String?
  var recipientQuery: String { get { recipientQueryValue ?? "" } set { recipientQueryValue = newValue } }
  enum CodingKeys: String, CodingKey { case id, version, text, attachments, recipients, groupName = "group_name", recipientQueryValue = "recipient_query" }
  init(id: UUID) { self.id = id }
}
struct BlessengerProfile: Codable, Equatable, Sendable {
  var id = UUID()
  var modelPath: String?
  /// Identity of the verified weights/processor actually admitted, not a path alias.
  var modelIdentity: String? = nil
  var sampling = SamplingProfile.standard
  var maximumTokens = 1024
  /// Nil preserves the ordinary text route; calls explicitly require MTP unless
  /// the user selects the disclosed non-MTP comparison in Settings.
  var useMTP: Bool? = nil
}
struct BlessengerAddress: Codable, Equatable, Sendable {
  let recipients: [BlessengerContact]
  var profile: BlessengerProfile
}
struct BlessengerSpeechVoice: Codable, Equatable, Sendable {
  enum Provider: String, Codable, Sendable { case apple, qwen }
  var provider = Provider.qwen
  var identifier: String?
  var description = "A warm, articulate, reassuring mature American colleague with a natural conversational rhythm."
  var locale = "en-US"
}
struct BlessengerAudio: Codable, Equatable, Sendable {
  let attachmentID: UUID
  let textDigest: String
  let frames: Int
  let sampleRate: Int
  let voice: BlessengerSpeechVoice
  let interrupted: Bool
  var heardFrames: Int
  var deliveredText: String? = nil
  var attemptID: UUID? = nil
  var failure: String? = nil
}
struct BlessengerAttempt: Codable, Equatable, Sendable {
  let conversationID: UUID
  let messageID: UUID
  let identity: GenerationIdentity
  let sourceDigests: [SourceReference]
}
struct BlessengerState: Codable, Sendable {
  var schema = 1
  var generation: UInt64 = 0
  var drafts = [BlessengerDraft(id: BlessengerDraft.unsentID)]
  var addresses: [UUID: BlessengerAddress] = [:]
  var groups: [BlessengerGroup] = []
  var managedCatalog: [UUID: String] = [:]
  var removedCatalog: Set<UUID> = []
  var defaultProfile = BlessengerProfile()
  var defaultSpeech = BlessengerSpeechVoice()
  var speechVoices: [UUID: BlessengerSpeechVoice] = [:]
  var audio: [UUID: BlessengerAudio] = [:]
  var spokenResponses: [UUID: BlessengerSpeechVoice]? = nil
  var callResponses: Set<UUID>? = nil
  var traces: [UUID: BlessengerTrace.Record]? = nil
  var attempts: [UUID: BlessengerAttempt] = [:]
  var branches: [UUID: UUID] = [:]
  /// Explicitly removed ancestry may remain referenced by surviving branches.
  var removedConversations: Set<UUID>? = nil
  var transcripts: [UUID: [BlessengerTranscript]]? = nil
  var readReplies = false
  var selectedTemplate: UUID?

  func draft(for id: UUID?) -> BlessengerDraft {
    let key = id ?? BlessengerDraft.unsentID
    return drafts.first(where: { $0.id == key }) ?? BlessengerDraft(id: key)
  }
  func validate(in state: WorkspaceState) throws {
    try validateRelationships(in: state)
    try validateTranscripts(in: state)
    guard schema == 1, state.composerDrafts?.isEmpty ?? true,
      drafts.count <= state.chats.count + 1, Set(drafts.map(\.id)).count == drafts.count,
      drafts.contains(where: { $0.id == BlessengerDraft.unsentID }),
      groups.count <= 1024, Set(groups.map(\.id)).count == groups.count,
      attempts.count <= 4096, audio.count <= 16384 else {
      throw BoomError.invalid("Private conversation metadata is inconsistent. Records were retained.")
    }
    let chats = Set(state.chats.map(\.id)), attachments = Set(state.attachments.map(\.id))
    for draft in drafts {
      _ = try BlessengerPolicy.validate(draft)
      guard (draft.id == BlessengerDraft.unsentID || chats.contains(draft.id)),
        draft.attachments.allSatisfy(attachments.contains) else {
        throw BoomError.invalid("The draft refers to missing private data.")
      }
    }
    for (id, address) in addresses {
      guard chats.contains(id), address.recipients.count <= 4 else { throw BoomError.invalid("Conversation addressing has lost its owner.") }
      try Self.validate(address.profile)
    }
    try Self.validate(defaultProfile)
    _ = try BlessengerPolicy.validate(defaultSpeech)
    guard speechVoices.count <= 4096, speechVoices.keys.allSatisfy(chats.contains) else {
      throw BoomError.invalid("A speech voice has lost its Contact conversation.")
    }
    for voice in speechVoices.values { _ = try BlessengerPolicy.validate(voice) }
    for voice in (spokenResponses ?? [:]).values { _ = try BlessengerPolicy.validate(voice) }
    for (id, attempt) in attempts {
      guard id == attempt.messageID, attempt.identity.recordID == id,
        let chat = state.chats.first(where: { $0.id == attempt.conversationID }),
        chat.messages.contains(where: { $0.id == id && $0.role == .assistant }) else {
        throw BoomError.invalid("A response attempt has lost its conversation.")
      }
    }
    for audio in audio.values {
      _ = try BlessengerPolicy.validate(audio.voice)
      guard attachments.contains(audio.attachmentID), audio.frames > 0,
        (8000...96000).contains(audio.sampleRate), (0...audio.frames).contains(audio.heardFrames),
        audio.textDigest.utf8.count == 64 else { throw BoomError.invalid("Recorded speech metadata is inconsistent.") }
    }
  }
  static func validate(_ profile: BlessengerProfile) throws {
    guard (1...4096).contains(profile.maximumTokens),
      profile.modelPath.map({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true,
      profile.modelIdentity.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && profile.modelPath != nil }) ?? true else {
      throw BoomError.invalid("The conversation model profile is invalid.")
    }
    _ = try ProductCore.sampling(profile.sampling)
  }
}

struct BlessengerDraftAdmission: Decodable, Sendable { let digest: String; let sendable: Bool }
struct BlessengerSpeechCursor: Codable, Sendable {
  var bytes = 0, digest = "", next = 0
  var finished = false
}
struct BlessengerFragment: Codable, Equatable, Sendable {
  let ordinal: Int
  let text: String
  let start: Int
  let end: Int
}
struct BlessengerSpeechEmission: Decodable, Sendable {
  let cursor: BlessengerSpeechCursor
  let fragments: [BlessengerFragment]
}

enum BlessengerPolicy {
  static func exactDigest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return Digest.sha256(try encoder.encode(value))
  }
  static func call<T: Decodable>(_ request: [String: Any]) throws -> T {
    try ProductCore.call(["op": "blessenger", "request": request])
  }
  static func validate(_ voice: BlessengerSpeechVoice) throws -> Bool {
    try call(["op": "validate_speech_voice", "voice": ProductCore.object(voice)])
  }
  static func validate(_ draft: BlessengerDraft) throws -> BlessengerDraftAdmission {
    try call(["op": "validate_draft", "draft": ProductCore.object(draft)])
  }
  static func resolve(host: UUID?, draft: BlessengerDraft, state: WorkspaceState,
    frozen: Bool) throws -> [BlessengerContact] {
    guard let product = state.blessenger else { throw BoomError.invalid("Missing Blessenger state.") }
    let contacts = state.voices.map { BlessengerContact($0) }
    let chats = try state.chats.filter { chat in !state.voices.contains(where: { $0.id == chat.id }) }.map(liveContact)
    let history = state.voiceVersions.map { BlessengerContact($0) }
    return try call(["op": "resolve", "host": host.map { $0.uuidString as Any } ?? NSNull(),
      "recipients": ProductCore.object(draft.recipients), "mentions": ReferenceParser.voices(draft.text),
      "library": ProductCore.object(contacts + chats), "historical": ProductCore.object(history),
      "groups": ProductCore.object(product.groups), "frozen": frozen])
  }
  static func speech(_ text: String, cursor: BlessengerSpeechCursor, finished: Bool,
    maximumFragments: Int = 512) throws -> BlessengerSpeechEmission {
    try call(["op": "speech", "text": text, "cursor": ProductCore.object(cursor), "finished": finished,
      "maximum_fragments": maximumFragments])
  }
  static func liveContact(_ chat: ChatRecord) throws -> BlessengerContact {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return BlessengerContact(id: chat.id, revision: Digest.sha256(try encoder.encode(chat)),
      handle: "chat-" + chat.id.uuidString.lowercased(), name: chat.title, kind: .chat)
  }
  static func capturedVoice(_ contact: BlessengerContact, state: WorkspaceState) throws -> Voice {
    if let value = (state.voices + state.voiceVersions).first(where: { $0.id == contact.id && $0.revision == contact.revision }) { return value }
    if contact.kind == .chat, let chat = state.chats.first(where: { $0.id == contact.id }) {
      guard try liveContact(chat) == contact else { throw BoomError.stale(contact.name) }
      return try ProductCore.pinnedVoice(chat, slug: contact.handle, occupied: [])
    }
    throw BoomError.stale("The captured Contact revision is not available.")
  }
}

/// Process-local call authority. The transcript and originals remain ordinary
/// workspace records. Relaunch never reactivates microphone access or a call.
struct BlessengerCallContext: Sendable {
  let id: UUID
  var conversationID: UUID?
  let recipients: [BlessengerContact]
  var profile: BlessengerProfile
  let speech: BlessengerSpeechVoice
  var lastEpoch: UInt64 = 0
  var pendingDraftDigest: String?
}
struct BlessengerCallerTurn: Sendable {
  let callID: UUID
  let epoch: UInt64
  let draft: BlessengerDraft
  let snapshot: WorkspaceState
  let conversationID: UUID?
  let profile: BlessengerProfile
  let inputMessageID: UUID
  var speech: BlessengerSpeechVoice? = nil
  var trace: BlessengerTrace? = nil
}

/// An explicit alternate answer to an already committed question. Its authored
/// input is not resubmitted and the unrelated unsent draft is never consumed.
struct BlessengerReplay: Sendable {
  let chat: ChatRecord
  let question: ChatMessage
}
