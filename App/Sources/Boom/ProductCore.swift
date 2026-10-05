import BoomCore
import CAttachment
import Foundation

/// Swift projections of Rust-owned policy. No duplicate validation rules.
enum ProductCore {
  static func search(_ text: String, query: String) throws -> SearchMatches {
    try call(["op": "search", "text": text, "query": query])
  }
  static func layout() throws -> ProductLayout { try call(["op": "layout"]) }
  static func importedTexts(_ files: [ImportedText]) throws -> [ImportedText] {
    try call(["op": "validate_import", "files": object(files)])
  }
  static func importedDocuments(_ files: [ImportedText]) throws -> [ImportedText] {
    try call(["op": "validate_document_import", "files": object(files)])
  }
  static func importBudget(files: Int, bytes: Int) throws {
    let _: Bool = try call(["op": "validate_import_budget", "files": files, "bytes": bytes])
  }
  static func validateOriginals(_ state: WorkspaceState) throws {
    let files = (state.importedFiles ?? [:]).map { id, file in
      ["id": id.uuidString, "folderID": file.folderID.map { $0.uuidString as Any } ?? NSNull(),
        "path": file.path, "originalDigest": file.originalDigest] as [String: Any]
    }
    let _: Bool = try call(["op": "validate_imported_originals", "documents": state.documents.map { $0.id.uuidString },
      "folders": (state.importedFolders ?? []).map { $0.id.uuidString }, "files": files])
  }
  static func admitRestore(_ state: WorkspaceState, documents: [DocumentSnapshot], entries: [String], hasIndex: Bool) throws {
    let _: Bool = try call(["op": "admit_restore", "state": object(state), "documents": object(documents),
      "entries": entries, "hasIndex": hasIndex])
  }
  static func chatTitle(_ request: String, routing: [String]) throws -> String {
    try call(["op": "chat_title", "request": request, "routing": routing])
  }
  private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let value: T?
    let error: Failure?
    struct Failure: Decodable { let message: String }
  }
  static func call<T: Decodable>(_ request: [String: Any], as: T.Type = T.self) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: request)
    let buffer = data.withUnsafeBytes {
      bloom_core_request($0.bindMemory(to: UInt8.self).baseAddress, data.count)
    }
    defer { boom_attachment_free(buffer) }
    guard let pointer = buffer.data, buffer.length > 0, buffer.length <= 16_777_216 else {
      throw BoomError.invalid("Invalid product-core response.")
    }
    let response = try JSONDecoder().decode(
      Envelope<T>.self, from: Data(bytes: pointer, count: buffer.length))
    guard response.ok, let value = response.value else {
      throw BoomError.invalid(response.error?.message ?? "Product request failed.")
    }
    return value
  }
  static func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
  static func suggestedSlug(_ name: String, occupied: [String]) throws -> String {
    try call(["op": "suggest_voice_slug", "name": name, "occupied": occupied])
  }
  static func voice(_ draft: VoiceDraft, occupied: [String] = []) throws -> Voice {
    try call(["op": "validate_voice", "draft": object(draft), "occupied": occupied])
  }
  static func pinnedVoice(_ chat: ChatRecord, slug: String?, occupied: [String]) throws -> Voice {
    let turns = chat.messages.map { PinnableTurn(role: $0.role.rawValue, text: $0.text, state: $0.state.rawValue, speaker: $0.speaker) }
    return try call(["op": "pin_chat", "id": chat.id.uuidString, "title": chat.title,
      "slug": slug.map { $0 as Any } ?? NSNull(), "instructions": chat.instructions ?? "",
      "turns": object(turns), "occupied": occupied])
  }
  static func chatText(_ text: String, instructions: Bool = false) throws -> String {
    try call(["op": "validate_chat_text", "text": text, "instructions": instructions])
  }
  static func prompt(
    voice: Voice?, history: [ChatMessage], instructions: String, context: String, request: String, routing: [String], authority: CapturedDocumentAuthority = .readOnly
  ) throws -> ConsultationPlan {
    guard let plan = try consultationRound(voices: [voice], history: history, instructions: instructions,
      context: context, request: request, routing: routing, authority: authority).first else { throw BoomError.invalid("Empty consultation round.") }
    return plan
  }
  static func consultationRound(
    voices: [Voice?], history: [ChatMessage], instructions: String, context: String, request: String, routing: [String], authority: CapturedDocumentAuthority = .readOnly
  ) throws -> [ConsultationPlan] {
    let turns = history.filter { $0.state == .complete }.map { message in
      PromptTurn(role: message.role.rawValue, text: message.text,
        speaker: message.speaker ?? Speaker(name: message.role == .user ? "Human" : "Bloom"))
    }
    return try call(["op": "compile_consultation", "authority": object(authority),
      "voices": try voices.map { try $0.map { try object($0) } ?? NSNull() },
      "history": object(turns), "instructions": instructions, "context": context, "request": request, "routing": routing])
  }
  static func authoredPrefix(_ document: DocumentSnapshot, caret: Int) throws -> String {
    try call(["op": "authored_prefix", "text": document.text, "caretUtf16": caret])
  }
  static func writingPrompt(_ document: DocumentSnapshot, caret: Int, examples: [String], retaining: Int) throws -> WritingPrompt {
    try call(["op": "writing_prompt", "text": document.text, "caretUtf16": caret,
      "examples": examples, "retainedCharacters": retaining])
  }
  struct WritingExample: Decodable { let title: String; let text: String }
  static func writingExample(title: String, text: String) throws -> WritingExample {
    try call(["op": "validate_writing_example", "title": title, "text": text])
  }
  static func sampling(_ profile: SamplingProfile) throws -> SamplingSettings {
    try call(["op": "sampling", "profile": profile.rawValue])
  }
  static func validateWritingRecipe(_ recipe: CompletionRecipe) throws {
    let _: Bool = try call(["op": "validate_writing_recipe", "recipe": object(recipe)])
  }
  static func branchWriting(_ recipe: CompletionRecipe, continuation: String) throws -> String {
    try call(["op": "branch_writing", "recipe": object(recipe), "continuation": continuation])
  }
  static func residencyBudget(physical: UInt64, metal: UInt64) throws -> UInt64 {
    try call(["op": "residency_budget", "physicalBytes": physical, "metalBytes": metal])
  }
}
struct ProductLayout: Codable, Sendable {
  let edition: String
  let primaryPane: String
  let panes: [String]
  let paneControls: [String]
  var isAuthor: Bool { primaryPane == "document" }
}
struct ImportedText: Codable, Sendable {
  let path: String
  let text: String
}
struct SearchMatches: Codable, Sendable {
  struct Range: Codable, Sendable {
    let location: Int
    let length: Int
    var native: NSRange { NSRange(location: location, length: length) }
  }
  let ranges: [Range]
  let omitted: Int
  var hasMatches: Bool { !ranges.isEmpty }
}
struct DocumentSearchMatches: Sendable {
  let query: String
  let revision: String
  let matches: SearchMatches
}
struct VoiceExchange: Codable, Equatable, Sendable {
  var user: String
  var assistant: String
}
struct VoiceDraft: Codable, Identifiable, Sendable {
  var id = UUID()
  var slug = ""
  var name = ""
  var instructions = ""
  var examples: [VoiceExchange] = []
}
struct Voice: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let slug: String
  let name: String
  let instructions: String
  let examples: [VoiceExchange]
  let revision: String
  var draft: VoiceDraft {
    VoiceDraft(id: id, slug: slug, name: name, instructions: instructions, examples: examples)
  }
  var speaker: Speaker { Speaker(name: name, voiceID: id, voiceRevision: revision) }
}
private struct PromptTurn: Codable {
  let role: String
  let text: String
  let speaker: Speaker
}
private struct PinnableTurn: Codable {
  let role: String
  let text: String
  let state: String
  let speaker: Speaker?
}
enum ConsultationStyle: String, Codable, CaseIterable {
  case separate = "Separate answers"
  case discuss = "Discuss together"
}
enum SamplingProfile: String, Codable, CaseIterable, Sendable {
  case steady, standard, open
  var title: String { self == .open ? "Open · experimental" : rawValue.capitalized }
}
struct SamplingSettings: Codable, Equatable, Sendable {
  let temperature: Float
  let topP: Float
  let topK: Int
  let minP: Float
}
struct CompletionRecipe: Codable, Sendable {
  let document: DocumentSnapshot
  let caretUTF16: Int
  let sources: [SourceReference]
  let prompt: String
  let promptDigest: String
  let omittedPrefixCharacters: Int
  let model: String
  let profile: SamplingProfile
  let settings: SamplingSettings
  let maxTokens: Int
}
struct WritingCandidate: Codable, Identifiable, Sendable {
  let id: UUID
  let seed: UInt64
  var text: String
  var state: MessageState
  var promptTokens: Int
  var outputTokens: Int
  var tokenIDs: [Int]
  var stopReason: String?
}
struct CandidateBundle: Codable, Identifiable, Sendable {
  let id: UUID
  let recipe: CompletionRecipe
  let origin: ManuscriptOrigin?
  var candidates: [WritingCandidate]
  var selected: Int
}
struct ManuscriptOrigin: Codable, Sendable {
  let documentID: UUID
  let revision: String
  let bundleID: UUID
  let candidateID: UUID
}


struct ConsultationPlan: Codable, Sendable {
  struct Message: Codable, Sendable { let role: String; let content: String }
  let messages: [Message]
  let rawPrompt: String
}
struct ConsultationReceipt: Codable, Sendable {
  let operationID: UUID
  let seed: UInt64
  var state: MessageState
  var failure: String?
  let model: String
  let voice: Voice?
  let plan: ConsultationPlan
  let sources: [SourceReference]
  var promptDigest: String
  var tokenIDs: [Int]
  var stopReason: String
  var firstTokenSeconds: Double?
  var elapsedSeconds: Double
}

struct WritingPrompt: Decodable { let prompt: String; let digest: String; let totalCharacters: Int; let omittedCharacters: Int }
