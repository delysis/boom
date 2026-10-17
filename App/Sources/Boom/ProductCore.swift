import BoomCore
import CAttachment
import Foundation

/// Swift projections of Rust-owned policy. No duplicate validation rules.
enum ProductCore {
  static func inputContext(instructions: String, history: [PromptTurn], speaker: String,
    text: String, caret: Int) throws -> String {
    try call(["op": "input_context", "instructions": instructions, "history": object(history),
      "speaker": speaker, "text": text, "caretUtf16": caret])
  }
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
  static func markdownSpans<T: Decodable>(_ text: String, as: T.Type = T.self) throws -> T {
    try parseText(text, using: bloom_markdown_spans)
  }
  static func markdownMediaSpans(_ text: String) throws -> [InlineMediaSpan] {
    try parseText(text, using: bloom_markdown_media_spans)
  }
  struct MarkupProjection {
    let markdown: [MarkdownSpan]
    let media: [InlineMediaSpan]
    let hasWikiMarker: Bool
    let hasAttachmentMarker: Bool
  }
  private static let attachmentMarker: [UInt8] = Array("[Attachment: ".utf8)
  /// Exact ASCII eligibility shares the parser's already contiguous input.
  /// General NSString literal searches would revisit foreign storage twice.
  private static func markupMarkers(_ bytes: UnsafeBufferPointer<UInt8>) -> (wiki: Bool, attachment: Bool) {
    var wiki = false, attachment = false, index = 0
    while index < bytes.count {
      if bytes[index] == 91 {
        if index + 1 < bytes.count, bytes[index + 1] == 91 { wiki = true }
        if !attachment, bytes.count - index >= attachmentMarker.count {
          var matches = true
          for offset in attachmentMarker.indices where bytes[index + offset] != attachmentMarker[offset] {
            matches = false; break
          }
          attachment = matches
        }
        if wiki && attachment { break }
      }
      index += 1
    }
    return (wiki, attachment)
  }
  /// Both parsers borrow one UTF-8 representation. Their independent parser
  /// options and failure behavior stay unchanged; the result retains no text.
  static func markupProjection(_ text: String) -> MarkupProjection {
    let projectionTrace = PerformanceTrace.begin("Editor.Projection")
    defer { PerformanceTrace.end("Editor.Projection", projectionTrace) }
    var source = text
    let inputTrace = PerformanceTrace.begin("Bridge.InputUTF8")
    return source.withUTF8 { bytes in
      PerformanceTrace.end("Bridge.InputUTF8", inputTrace)
      let markers = markupMarkers(bytes)
      let markdown: [MarkdownSpan] = {
        let trace = PerformanceTrace.begin("Editor.MarkdownParse")
        defer { PerformanceTrace.end("Editor.MarkdownParse", trace) }
        return (try? parseBorrowedText(bytes, using: bloom_markdown_spans)) ?? []
      }()
      let media: [InlineMediaSpan] = {
        let trace = PerformanceTrace.begin("Editor.MediaParse")
        defer { PerformanceTrace.end("Editor.MediaParse", trace) }
        return (try? parseBorrowedText(bytes, using: bloom_markdown_media_spans)) ?? []
      }()
      return MarkupProjection(markdown: markdown, media: media,
        hasWikiMarker: markers.wiki, hasAttachmentMarker: markers.attachment)
    }
  }
  private static func parseText<T: Decodable>(_ text: String,
    using parser: (UnsafePointer<UInt8>?, Int) -> BoomAttachmentBuffer) throws -> T {
    // String owns the contiguous UTF-8 only for this synchronous call. The
    // parser borrows it; no whole-document JSON escaping or request copy.
    var source = text
    let inputTrace = PerformanceTrace.begin("Bridge.InputUTF8")
    return try source.withUTF8 { bytes in
      PerformanceTrace.end("Bridge.InputUTF8", inputTrace)
      return try parseBorrowedText(bytes, using: parser)
    }
  }
  private static func parseBorrowedText<T: Decodable>(_ bytes: UnsafeBufferPointer<UInt8>,
    using parser: (UnsafePointer<UInt8>?, Int) -> BoomAttachmentBuffer) throws -> T {
    let buffer = {
      let trace = PerformanceTrace.begin("Bridge.Execute")
      defer { PerformanceTrace.end("Bridge.Execute", trace) }
      return parser(bytes.baseAddress, bytes.count)
    }()
    return try response(buffer)
  }
  static func layout() throws -> ProductLayout { try call(["op": "layout"]) }
  static func importedTexts(_ files: [ImportedText]) throws -> [ImportedText] {
    try call(["op": "validate_import", "files": object(files)])
  }
  static func importedDocuments(_ files: [ImportedText]) throws -> [ImportedText] {
    try call(["op": "validate_document_import", "files": object(files)])
  }
  static func admitImportedTexts(_ files: [ImportedText], documents: Bool = false) throws {
    var bytes = 0
    for file in files {
      let total = bytes.addingReportingOverflow(file.text.utf8.count)
      guard !total.overflow else { throw BoomError.budget("Import size cannot be represented.") }
      bytes = total.partialValue
    }
    try importBudget(files: files.count, bytes: bytes)
    let operation = documents ? "admit_document_import" : "admit_import"
    // Validate the complete path set together, then acknowledge bounded texts.
    // Worst-case JSON escaping of eight MiB need not fit a sixteen-MiB request.
    let paths = files.map { ImportedText(path: $0.path, text: "") }
    let _: Bool = try call(["op": operation, "files": object(paths)])
    for file in files {
      let _: Bool = try call(["op": operation, "files": object([file])])
    }
  }
  static func importBudget(files: Int, bytes: Int) throws {
    let _: Bool = try call(["op": "validate_import_budget", "files": files, "bytes": bytes])
  }
  static func chatTitle(_ request: String, routing: [String]) throws -> String {
    try call(["op": "chat_title", "request": request, "routing": routing])
  }
  private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let value: T?
    let error: Failure?
    struct Failure: Decodable { let code: String; let message: String }
  }
  static func call<T: Decodable>(_ request: [String: Any], as: T.Type = T.self) throws -> T {
    let data = try {
      let trace = PerformanceTrace.begin("Bridge.Encode")
      defer { PerformanceTrace.end("Bridge.Encode", trace) }
      return try JSONSerialization.data(withJSONObject: request)
    }()
    // A fitting request still carries immutable original prose for validation.
    // Only this explicit windowed operation may use the bridge's bounded 64 MiB input.
    let windowed = ["compile_consultation", "compile_consultation_compact"].contains(request["op"] as? String ?? "")
      && (request["workingTextBytes"] is Int || request["workingRequestBytes"] is Int)
    let limit = windowed ? 67_108_864 : 16_777_216
    guard data.count <= limit else { throw BoomError.budget("Product request exceeds its bounded wire capacity.") }
    let buffer = {
      let trace = PerformanceTrace.begin("Bridge.Execute")
      defer { PerformanceTrace.end("Bridge.Execute", trace) }
      return data.withUnsafeBytes {
        bloom_core_request($0.bindMemory(to: UInt8.self).baseAddress, data.count)
      }
    }()
    return try response(buffer)
  }
  private static func response<T: Decodable>(_ buffer: BoomAttachmentBuffer) throws -> T {
    let trace = PerformanceTrace.begin("Bridge.Decode")
    defer { PerformanceTrace.end("Bridge.Decode", trace) }
    defer { boom_attachment_free(buffer) }
    guard let pointer = buffer.data, buffer.length > 0, buffer.length <= 8_388_608 else {
      throw BoomError.invalid("Invalid product-core response.")
    }
    let response = try JSONDecoder().decode(
      Envelope<T>.self, from: Data(bytes: pointer, count: buffer.length))
    guard response.ok, let value = response.value else {
      if let failure = response.error,
        ["input_limit", "output_limit", "consultation_budget"].contains(failure.code) {
        throw BoomError.budget(failure.message)
      }
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
    voice: Voice?, history: [ChatMessage], instructions: String, context: String, request: String, routing: [String], authority: CapturedDocumentAuthority = .readOnly,
    promptContract: ConsultationPromptContract = .referenceHistoryV2,
    renderedContext: RenderedReferenceContext? = nil, capturedSources: [SourceReference] = [],
    workingTextBytes: Int? = nil, workingRequestBytes: Int? = nil
  ) throws -> ConsultationPlan {
    guard let plan = try consultationRound(voices: [voice], history: history, instructions: instructions,
      context: context, request: request, routing: routing, authority: authority,
      promptContract: promptContract, renderedContext: renderedContext,
      capturedSources: capturedSources, workingTextBytes: workingTextBytes,
      workingRequestBytes: workingRequestBytes).first else { throw BoomError.invalid("Empty consultation round.") }
    return plan
  }
  static func consultationRound(
    voices: [Voice?], history: [ChatMessage], instructions: String, context: String, request: String, routing: [String], authority: CapturedDocumentAuthority = .readOnly,
    promptContract: ConsultationPromptContract = .referenceHistoryV2,
    renderedContext: RenderedReferenceContext? = nil, capturedSources: [SourceReference] = [],
    workingTextBytes: Int? = nil, workingRequestBytes: Int? = nil,
    historyMedia: [UUID: [UUID]] = [:], currentMedia: [UUID]? = nil
  ) throws -> [ConsultationPlan] {
    let retainedHistory = history.filter { $0.state == .complete }
    let turns = retainedHistory.map { message in
      PromptTurn(role: message.role.rawValue, text: message.text,
        speaker: message.speaker ?? Speaker(name: message.role == .user ? "Human" : "Bloom"),
        context: message.consultationPromptContract == .referenceHistoryV2
          || message.consultationPromptContract == .referenceBindingsV3 ? message.context : nil,
        routing: message.consultationRouting, promptContract: message.consultationPromptContract)
    }
    let compiled: CompactConsultation = try call(["op": "compile_consultation_compact", "authority": object(authority),
      "voices": try voices.map { try $0.map { try object($0) } ?? NSNull() },
      "history": object(turns), "instructions": instructions, "context": context, "request": request,
      "routing": routing, "promptContract": promptContract.rawValue,
      "renderedContext": try renderedContext.map { try object($0) } ?? NSNull(),
      "capturedSources": try object(capturedSources), "workingTextBytes": workingTextBytes.map { $0 as Any } ?? NSNull(),
      "workingRequestBytes": workingRequestBytes.map { $0 as Any } ?? NSNull()])
    let expectedContract: ConsultationPromptContract? = promptContract == .textHistoryV1 ? nil : promptContract
    guard compiled.schema == 1, compiled.plans.count == voices.count,
      compiled.promptContract == expectedContract else {
      throw BoomError.invalid("Inconsistent consultation reply.")
    }
    return try compiled.plans.map { plan in
      ConsultationPlan(messages: try plan.messages.map { message in
        guard ["system", "user", "assistant"].contains(message.role) else {
          throw BoomError.invalid("Invalid consultation role.")
        }
        let text = try compiled.text(message.content)
        var placed: [ConsultationPlan.MediaPlacement]? = nil
        if let currentMedia {
          placed = []
          var last = 0
          for span in message.sourceSpans ?? [] {
            guard span.end >= last, span.end <= text.utf8.count else { throw BoomError.invalid("Invalid captured history boundary.") }
            let ids: [UUID]
            if let turn = span.turn {
              guard retainedHistory.indices.contains(turn) else { throw BoomError.invalid("A media boundary lost its captured history turn.") }
              ids = historyMedia[retainedHistory[turn].id] ?? []
            } else { ids = currentMedia }
            guard ids.isEmpty || message.role == "user" else { throw BoomError.denied("Caller audio cannot become an assistant example.") }
            placed?.append(contentsOf: ids.map { ConsultationPlan.MediaPlacement(id: $0, end: span.end) })
            last = span.end
          }
        }
        return ConsultationPlan.Message(role: message.role, content: text, media: placed)
      }, rawPrompt: try compiled.text(plan.rawPrompt), promptContract: compiled.promptContract,
        workingWindow: compiled.workingWindow)
    }
  }
  private struct CompactConsultation: Decodable {
    struct Plan: Decodable {
      struct Message: Decodable {
        struct SourceSpan: Decodable { let turn: Int?; let end: Int }
        let role: String; let content: [Int]; let sourceSpans: [SourceSpan]?
      }
      let messages: [Message]
      let rawPrompt: [Int]
    }
    let schema: Int
    let promptContract: ConsultationPromptContract?
    let workingWindow: ConsultationWorkingWindow?
    let texts: [String]
    let plans: [Plan]
    func text(_ references: [Int]) throws -> String {
      var bytes = 0
      for index in references {
        guard texts.indices.contains(index) else { throw BoomError.invalid("Invalid consultation text reference.") }
        let total = bytes.addingReportingOverflow(texts[index].utf8.count)
        guard !total.overflow, total.partialValue <= 16_777_216 else {
          throw BoomError.budget("Consultation prompt exceeds 16 MiB.")
        }
        bytes = total.partialValue
      }
      return references.map { texts[$0] }.joined()
    }
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
    capacity: Int, dictionary: ContextVocabulary, media: [WritingMediaReference] = []) throws -> WritingContextStep {
    try call(["op": "begin_writing_context", "dictionary": dictionary.id.uuidString,
      "text": document.text, "caretUtf16": caret, "examples": examples, "capacity": capacity, "media": object(media)])
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
  static func resolvedGenerationPolicy(_ captured: ModelGenerationPolicy?,
    loaded: ModelGenerationPolicy) throws -> ModelGenerationPolicy {
    try call(["op": "resolve_execution_policy",
      "captured": try captured.map { try object($0) } ?? NSNull(), "loaded": object(loaded)])
  }
  /// This checks compatibility. Execution must use resolvedGenerationPolicy's
  /// returned policy rather than the runner's current default.
  static func admitGenerationPolicy(_ captured: ModelGenerationPolicy?, loaded: ModelGenerationPolicy) throws {
    let effective = try resolvedGenerationPolicy(captured, loaded: loaded)
    let _: Bool = try call(["op": "admit_generation_policy",
      "captured": try captured.map { try object($0) } ?? NSNull(), "loaded": object(effective)])
  }
  static func validateWritingRecipe(_ recipe: CompletionRecipe) throws {
    try recipe.capture?.admit()
    let _: Bool = try call(["op": "validate_writing_recipe", "recipe": recipeModelObject(recipe)])
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
    guard recipe.capture?.isWholeSource != false else {
      throw BoomError.denied("A range capture cannot be branched as a whole manuscript.")
    }
    return try call(["op": "branch_writing", "recipe": recipeModelObject(recipe), "continuation": continuation])
  }
  private static func recipeModelObject(_ recipe: CompletionRecipe) throws -> [String: Any] {
    guard var value = try object(recipe) as? [String: Any] else { throw BoomError.invalid("Invalid writing recipe.") }
    // The Rust planner validates the bounded text/prompt. File revision/range
    // authority stays with the native owner and is rechecked before insertion.
    value.removeValue(forKey: "capture")
    return value
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
  static func retainResidentPair(writing: Int, consultation: Int) throws -> Bool {
    try call(["op": "residency_pair", "writing": writing, "consultation": consultation])
  }
  static func admitCacheProbe(physical: UInt64, metal: UInt64, cache: UInt64) throws {
    let _: Bool = try call(["op": "residency_cache_probe", "physicalBytes": physical,
      "metalBytes": metal, "cacheBytes": cache])
  }
  static func admitModelLoad(physical: UInt64, metal: UInt64, resident: UInt64, weights: UInt64) throws -> Bool {
    try call(["op": "residency_load", "physicalBytes": physical, "metalBytes": metal,
      "residentBytes": resident, "weightBytes": weights])
  }
  static func modelSetup(physical: UInt64, metal: UInt64, resident: UInt64, disk: UInt64,
    writing: Bool, candidates: [ModelSetupCandidate]) throws -> ModelSetupPlan {
    try call(["op": "model_setup", "physicalBytes": physical, "metalBytes": metal,
      "residentBytes": resident, "diskBytes": disk, "writing": writing, "candidates": object(candidates)])
  }
  static func modelChoices(physical: UInt64, metal: UInt64, resident: UInt64, disk: UInt64,
    candidates: [ModelSetupCandidate]) throws -> [String] {
    try call(["op": "model_choices", "physicalBytes": physical, "metalBytes": metal,
      "residentBytes": resident, "diskBytes": disk, "candidates": object(candidates)])
  }
  static func admitModelWeights(physical: UInt64, resident: UInt64, weights: UInt64) throws -> Bool {
    try call(["op": "model_weights", "physicalBytes": physical, "residentBytes": resident, "weightBytes": weights])
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
  static func incrementalKVAdmission(application: UInt64, used: UInt64, reserve: UInt64,
    layers: [ActiveNativeKVAllocation]) throws -> IncrementalKVAdmission {
    try call(["op": "incremental_kv_admission", "applicationBytes": application,
      "usedBytes": used, "workingReserveBytes": reserve, "layers": try object(layers)])
  }
  static func incrementalKVReadmission(application: UInt64, used: UInt64, reserve: UInt64,
    allocation: UInt64) throws -> IncrementalKVAdmission {
    try call(["op": "incremental_kv_readmission", "applicationBytes": application,
      "usedBytes": used, "workingReserveBytes": reserve, "allocationBytesUpperBound": allocation])
  }
  static func independentKVAllocation(configuration: Data, prompts: [Int], cached: [Int],
    outputs: [Int], prefill: PrefillGeometry, initial: Bool, valueBytes: Int) throws -> UInt64 {
    try call(["op": "independent_kv_allocation", "configuration": JSONSerialization.jsonObject(with: configuration),
      "prompts": prompts, "cached": cached, "outputs": outputs, "prefill": try object(prefill),
      "initial": initial, "valueBytes": valueBytes])
  }
  static func contextCapacity(configuration: Data, available: UInt64, width: Int,
    prefill: PrefillGeometry? = nil) throws -> Int {
    try call(["op": "context_capacity", "configuration": JSONSerialization.jsonObject(with: configuration),
      "availableBytes": available, "width": width, "prefill": try prefill.map { try object($0) } ?? NSNull()])
  }
}
struct IncrementalKVAdmission: Codable, Sendable {
  let admitted: Bool
  let additionalBytesUpperBound: UInt64
  let requiredBytes: UInt64
  let scope: String
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
  case mp4, wav, aiff, flac, mp3, aac, ogg, caf
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
  let textVersion: UUID
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
struct PromptTurn: Codable, Sendable {
  let role: String
  let text: String
  let speaker: Speaker
  var context: String? = nil
  var routing: [String]? = nil
  var promptContract: ConsultationPromptContract? = nil
}
private struct PinnableTurn: Codable {
  let role: String
  let text: String
  let state: String
  let speaker: Speaker?
}
enum ConsultationStyle: String, Codable, CaseIterable, Sendable {
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
  var sourcePrompt: String? = nil
  var media: [WritingMediaReference]? = nil
  var capture: BoundedDocumentCapture? = nil
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
  private enum CodingKeys: String, CodingKey {
    case id, seed, text, state, promptTokens, outputTokens, tokenIDs, stopReason
    case stopTokenID, batch, executionOrigin
  }
  /// The candidate owns this local display identity, including its empty-state text.
  /// It is never encoded or used as generation, source or replay authority.
  private(set) var readingVersion = UUID()
  let id: UUID
  let seed: UInt64
  var text: String { didSet { readingVersion = UUID() } }
  var state: MessageState { didSet { readingVersion = UUID() } }
  var promptTokens: Int
  var outputTokens: Int
  var tokenIDs: [Int]
  var stopReason: String?
  var stopTokenID: Int? = nil
  var batch: WritingBatchExecution? = nil
  var executionOrigin: GenerationExecutionOrigin? = nil

  init(id: UUID, seed: UInt64, text: String, state: MessageState,
    promptTokens: Int, outputTokens: Int, tokenIDs: [Int], stopReason: String?,
    stopTokenID: Int? = nil, batch: WritingBatchExecution? = nil,
    executionOrigin: GenerationExecutionOrigin? = nil) {
    self.id = id; self.seed = seed; self.text = text; self.state = state
    self.promptTokens = promptTokens; self.outputTokens = outputTokens; self.tokenIDs = tokenIDs
    self.stopReason = stopReason; self.stopTokenID = stopTokenID
    self.batch = batch; self.executionOrigin = executionOrigin
  }
}
struct CandidateBundle: Codable, Identifiable, Sendable {
  let id: UUID
  let recipe: CompletionRecipe
  let origin: ManuscriptOrigin?
  var candidates: [WritingCandidate]
  var selected: Int
  var input: TextInputCapture? = nil
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
  struct MediaPlacement: Codable, Equatable, Sendable { let id: UUID; let end: Int }
  struct Message: Codable, Sendable { let role: String; let content: String; var media: [MediaPlacement]? = nil }
  var hasPlacedMedia: Bool { messages.contains { $0.media != nil } }
  var placedMediaIDs: Set<UUID> { Set(messages.flatMap { ($0.media ?? []).map(\.id) }) }
  let messages: [Message]
  let rawPrompt: String
  var promptContract: ConsultationPromptContract? = nil
  var workingWindow: ConsultationWorkingWindow? = nil
}
struct BlessengerMTPExecution: Codable, Equatable, Sendable {
  let assistant: String
  let blockSize: Int
  let proposed: Int?
  let accepted: Int?
  let passthrough: String?
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
  var attemptID: UUID? = nil
  var previousAttemptID: UUID? = nil
  var responseID: UUID? = nil
  var media: [WritingMediaReference]? = nil
  var executionOrigin: GenerationExecutionOrigin? = nil
  var mtp: BlessengerMTPExecution? = nil
  var contextWindow: BlessengerHistoryWindow? = nil
}

struct WritingPrompt: Codable { let prompt: String; let digest: String; let totalCharacters: Int; let omittedCharacters: Int }
