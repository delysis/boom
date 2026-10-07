import BoomCore
import CAttachment
import Foundation

/// Swift projections of Rust-owned policy. No duplicate validation rules.
enum ProductCore {
  static func mediaDuration(_ seconds: Double, automaticAudio: Bool = false) throws {
    let _: Bool = try call(["op": "validate_media_duration", "seconds": seconds, "automaticAudio": automaticAudio])
  }
  static func admitMedia(_ data: Data) throws -> MediaContainer {
    try response(data.withUnsafeBytes {
      bloom_media_admit($0.bindMemory(to: UInt8.self).baseAddress, data.count)
    })
  }
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
  static func validateInventory(_ state: WorkspaceState, entries: [VaultInventoryEntry], hasIndex: Bool) throws {
    let originals = state.attachments.map { ["id": $0.id.uuidString, "digest": $0.rootDigest] }
    let imported = (state.importedFiles ?? [:]).map { ["id": $0.key.uuidString, "digest": $0.value.originalDigest] }
    let replies = state.chats.flatMap { $0.messages + ($0.messageVersions ?? []) }.map { message in
      ["id": message.id.uuidString, "role": message.role.rawValue, "state": message.state.rawValue,
        "hasModel": message.provider != nil, "authored": message.authoredByUser == true,
        "hasText": !message.text.isEmpty] as [String: Any]
    }
    let _: Bool = try call(["op": "validate_vault_inventory", "manifest": ["hasIndex": hasIndex,
      "documents": state.documents.map { $0.id.uuidString }, "attachments": originals, "importedOriginals": imported,
      "candidates": state.candidateIDs.map(\.uuidString), "replies": replies], "entries": object(entries)])
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
    return try response(buffer)
  }
  private static func response<T: Decodable>(_ buffer: BoomAttachmentBuffer) throws -> T {
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
  static func contextVocabulary(_ descriptor: [String: Any]) throws -> ContextVocabulary {
    ContextVocabulary(id: try call(["op": "context_vocabulary", "descriptor": descriptor]))
  }
  static func writingContext(_ document: DocumentSnapshot, caret: Int, examples: [String],
    capacity: Int, dictionary: ContextVocabulary) throws -> WritingContextStep {
    try call(["op": "begin_writing_context", "dictionary": dictionary.id.uuidString,
      "text": document.text, "caretUtf16": caret, "examples": examples, "capacity": capacity])
  }
  static func countedContext(_ step: WritingContextStep, prompt: WritingPrompt, count: Int) throws -> WritingContextStep {
    try call(["op": "count_writing_context", "id": step.id.uuidString,
      "promptDigest": prompt.digest, "count": count])
  }
  static func releaseContext(_ id: UUID) {
    let _: Bool? = try? call(["op": "release_writing_context", "id": id.uuidString])
  }
  struct WritingExample: Decodable { let title: String; let text: String }
  static func writingExample(title: String, text: String) throws -> WritingExample {
    try call(["op": "validate_writing_example", "title": title, "text": text])
  }
  static func sampling(_ profile: SamplingProfile) throws -> SamplingSettings {
    try call(["op": "sampling", "profile": profile.rawValue])
  }
  static func generationPolicy(vocabularySize: Int, configuration: Data,
    controls: [Int], tokenizerEOS: Int?, prefillTokens: UInt32? = nil) throws -> ModelGenerationPolicy {
    try call(["op": "model_generation_policy", "vocabularySize": vocabularySize,
      "configuration": JSONSerialization.jsonObject(with: configuration),
      "controlTokenIds": controls, "tokenizerEos": tokenizerEOS.map { $0 as Any } ?? NSNull(),
      "prefillTokens": prefillTokens.map { $0 as Any } ?? NSNull()])
  }
  static func admitGenerationPolicy(_ captured: ModelGenerationPolicy?, loaded: ModelGenerationPolicy) throws {
    let _: Bool = try call(["op": "admit_generation_policy",
      "captured": try captured.map { try object($0) } ?? NSNull(), "loaded": object(loaded)])
  }
  static func validateWritingRecipe(_ recipe: CompletionRecipe) throws {
    let _: Bool = try call(["op": "validate_writing_recipe", "recipe": object(recipe)])
  }
  static func writingHistory(documentID: UUID, entries: [WritingHistoryEntry]) throws -> WritingHistoryPlan {
    try call(["op": "writing_history", "documentId": documentID.uuidString, "entries": object(entries)])
  }
  static func validateWritingBatch(_ execution: WritingBatchExecution, seed: UInt64) throws {
    let _: Bool = try call(["op": "validate_writing_batch", "execution": object(execution), "seed": seed])
  }
  static func admitWritingBatch(width: Int, prompt: Int, output: Int, capacity: Int) throws {
    let _: Bool = try call(["op": "admit_writing_batch", "width": width,
      "prompt": prompt, "output": output, "capacity": capacity])
  }
  static func writingEvaluationPlan(fixtures: Int, seeds: [UInt64]) throws -> [WritingEvaluationGroup] {
    try call(["op": "writing_evaluation_plan", "fixtures": fixtures, "seeds": seeds])
  }
  static func branchWriting(_ recipe: CompletionRecipe, continuation: String) throws -> String {
    try call(["op": "branch_writing", "recipe": object(recipe), "continuation": continuation])
  }
  static func residencyBudget(physical: UInt64, metal: UInt64) throws -> UInt64 {
    try call(["op": "residency_budget", "physicalBytes": physical, "metalBytes": metal])
  }
  static func residencyLimits(physical: UInt64, metal: UInt64) throws -> ResidencyLimits {
    try call(["op": "residency_limits", "physicalBytes": physical, "metalBytes": metal])
  }
  static func qualificationContext(writing: Int, consultation: Int) throws -> FullContextInputs {
    try call(["op": "qualification_context", "writing": writing, "consultation": consultation])
  }
  static func admitCacheProbe(physical: UInt64, metal: UInt64, cache: UInt64) throws {
    let _: Bool = try call(["op": "residency_cache_probe", "physicalBytes": physical,
      "metalBytes": metal, "cacheBytes": cache])
  }
  static func admitModelLoad(physical: UInt64, metal: UInt64, resident: UInt64, weights: UInt64) throws -> Bool {
    try call(["op": "residency_load", "physicalBytes": physical, "metalBytes": metal,
      "residentBytes": resident, "weightBytes": weights])
  }
  static func checkpointRequirements(_ checkpoint: PublishedCheckpoint) throws -> CheckpointRequirements {
    try call(["op": "checkpoint_requirements", "checkpoint": object(checkpoint)])
  }
  static func checkpointRange(fileBytes: UInt64, offset: UInt64) throws -> CheckpointRange {
    try call(["op": "checkpoint_range", "fileBytes": fileBytes, "offset": offset])
  }
  static func checkpointResponse(fileBytes: UInt64, offset: UInt64, response: HTTPURLResponse) throws {
    let length = response.value(forHTTPHeaderField: "Content-Length")
    if let length, UInt64(length) == nil { throw BoomError.invalid("Invalid model response length.") }
    let _: Bool = try call(["op": "checkpoint_response", "fileBytes": fileBytes, "offset": offset,
      "status": response.statusCode, "contentRange": response.value(forHTTPHeaderField: "Content-Range") as Any? ?? NSNull(),
      "contentLength": length.flatMap(UInt64.init) as Any? ?? NSNull()])
  }
  static func contextCapacity(configuration: Data, available: UInt64, width: Int,
    prefill: PrefillGeometry? = nil) throws -> Int {
    try call(["op": "context_capacity", "configuration": JSONSerialization.jsonObject(with: configuration),
      "availableBytes": available, "width": width, "prefill": try prefill.map { try object($0) } ?? NSNull()])
  }
}
struct FullContextInputs: Codable, Sendable {
  let contextTokens: Int
  let inputTokens: [Int]
  let outputTokens: Int
}
struct ResidencyLimits: Codable, Sendable {
  let applicationBytes: UInt64
  let allocatorBytes: UInt64
  let cacheBytes: UInt64
  let workingReserveBytes: UInt64
}
enum MediaContainer: String, Decodable {
  case mp4, wav, aiff, flac, mp3, aac, ogg
}
final class ContextVocabulary: Sendable {
  let id: UUID
  init(id: UUID) { self.id = id }
  deinit { let _: Bool? = try? ProductCore.call(["op": "release_context_vocabulary", "id": id.uuidString]) }
}
struct WritingContextStep: Decodable {
  let id: UUID
  let status: String
  let candidate: WritingPrompt?
  let testedCandidates: Int
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
struct ModelGenerationPolicy: Codable, Equatable, Sendable {
  let schema: Int
  let vocabularySize: Int
  let eosTokenIDs: [Int]
  let suppressedTokenIDs: [Int]
  let controlTokenIDs: [Int]
  let textDecoding: String?
  var prefill: PrefillGeometry? = nil
}
struct PrefillGeometry: Codable, Equatable, Sendable {
  let chunking: String
  let tokenCeiling: Int
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
  let generationPolicy: ModelGenerationPolicy?
}
struct WritingBatchExecution: Codable, Equatable, Sendable {
  var algorithm = "shared-prefill-fixed-batch-v1"
  let seeds: [UInt64]
  let lane: Int
}
struct WritingEvaluationGroup: Codable, Sendable {
  let id: String
  let fixture: Int
  let profile: SamplingProfile
  let seeds: [UInt64]
  let names: [String]
  let replayOf: String?
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
  var stopTokenID: Int? = nil
  var batch: WritingBatchExecution? = nil
}
struct CandidateBundle: Codable, Identifiable, Sendable {
  let id: UUID
  let recipe: CompletionRecipe
  let origin: ManuscriptOrigin?
  var candidates: [WritingCandidate]
  var selected: Int
}
struct WritingHistoryEntry: Codable, Sendable {
  let id: UUID
  let documentId: UUID
  let maxTokens: Int
  let candidates: Int
}
struct WritingHistoryPlan: Codable, Sendable {
  let explorations: [UUID]
  let latest: UUID?
}
struct SavedExploration: Identifiable, Sendable {
  let id: UUID
  let preview: String
}
struct SavedWritingHistory: Sendable {
  let explorations: [SavedExploration]
  let latest: UUID?
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
  let generationPolicy: ModelGenerationPolicy?
  var stopTokenID: Int? = nil
}

struct WritingPrompt: Codable { let prompt: String; let digest: String; let totalCharacters: Int; let omittedCharacters: Int }
