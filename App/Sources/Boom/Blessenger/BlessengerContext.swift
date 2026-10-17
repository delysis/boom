import BoomCore
import Foundation

/// A receipt for context selection, separate from the original conversation.
/// Omitting a whole older unit never deletes it or changes the user's question.
struct BlessengerHistoryWindow: Codable, Equatable, Sendable {
  let units: [UUID]
  let messages: [UUID]
  let sourceIds: [UUID]
  let rawSourceIds: [UUID]
  let mediaOccurrences: Int
  /// Metadata reservation; a live input reserves its full bounded capture.
  let originalBytes: UInt64
  let textBytes: UInt64
  let omittedUnits: Int
  let omittedMessages: Int
  var reason: String?
}

enum BlessengerContext {
  struct Source: Codable, Sendable {
    let id: UUID
    let media: Bool
    let originalBytes: UInt64
    let available: Bool
  }
  struct Unit: Codable, Sendable {
    let id: UUID
    var messages: [UUID]
    var textBytes: UInt64
    var sources: [UUID]
  }
  struct Input: Codable, Sendable {
    let units: [Unit]
    let sources: [Source]
    let current: [UUID]
    let currentTextBytes: UInt64
    var maximumUnits = 4096
    func selected() throws -> BlessengerHistoryWindow {
      try BlessengerPolicy.call(["op": "history_window", "input": ProductCore.object(self)])
    }
  }
  struct Capture: Sendable {
    let input: Input
    let history: [ChatMessage]
    let window: BlessengerHistoryWindow
    let current: BlessengerMedia.Prepared
    let prior: BlessengerMedia.History
    var payloads: [WritingMediaData] {
      (prior.prepared.payloads + current.payloads).reduce(into: []) { values, value in
        if !values.contains(where: { $0.reference.id == value.reference.id }) { values.append(value) }
      }
    }
    func selecting(maximumUnits: Int, tokenLimited: Bool = false) throws -> Capture {
      var narrowed = input; narrowed.maximumUnits = maximumUnits
      var selected = try narrowed.selected()
      if tokenLimited { selected.reason = "model_context_budget" }
      let messageIDs = Set(selected.messages), sourceIDs = Set(selected.sourceIds)
      return Capture(input: narrowed, history: history.filter { messageIDs.contains($0.id) }, window: selected,
        current: current, prior: BlessengerMedia.History(prepared: .init(context: "",
          sources: prior.prepared.sources.filter { sourceIDs.contains($0.id) },
          payloads: prior.prepared.payloads.filter { sourceIDs.contains($0.reference.id) }),
          occurrences: prior.occurrences.filter { messageIDs.contains($0.key) }, window: selected))
    }
  }
  struct Round: Sendable {
    let capture: Capture
    let plans: [ConsultationPlan]
  }
  /// Unit construction is chronological. Replies cannot survive removal of
  /// their preceding question, including a multi-consultant response round.
  static func units(_ history: [ChatMessage]) throws -> [Unit] {
    guard history.count <= 131_072, Set(history.map(\.id)).count == history.count else {
      throw BoomError.invalid("The selected history contains duplicate identities or unbounded metadata.")
    }
    var result: [Unit] = []
    for message in history {
      let bytes = UInt64(message.text.utf8.count) + UInt64(message.context.utf8.count)
      if message.role == .user || result.isEmpty {
        result.append(Unit(id: message.id, messages: [message.id], textBytes: bytes,
          sources: BlessengerMedia.directSources(message)))
      } else {
        result[result.count - 1].messages.append(message.id)
        result[result.count - 1].textBytes += bytes
      }
    }
    return result
  }
  /// Metadata admission precedes every get/decrypt/decode below. Provisional
  /// current media is used only by the causal input owner; it is never a store
  /// record and cannot be mistaken for a persisted waveform.
  static func prepare(history: [ChatMessage], current: [UUID], text: String,
    state: WorkspaceState, store: WorkspaceStore, supportsRawAudio: Bool,
    flag: CancellationFlag, provisional: WritingMediaData? = nil) async throws -> Capture {
    let grouped = try units(history)
    guard Set(state.attachments.map(\.id)).count == state.attachments.count else {
      throw BoomError.invalid("The context index contains duplicate original identities.")
    }
    if let provisional {
      guard !state.attachments.contains(where: { $0.id == provisional.reference.id }),
        !grouped.contains(where: { $0.sources.contains(provisional.reference.id) }) else {
        throw BoomError.stale("A new caller capture collides with a retained original.")
      }
    }
    let input = try await detachedWork { () throws -> Input in
      var seen = Set<UUID>()
      let ids = (grouped.flatMap(\.sources) + current).filter { seen.insert($0).inserted }
      let indexed = Dictionary(uniqueKeysWithValues: state.attachments.map { ($0.id, $0) })
      let metadata = try ids.map { id -> Source in
        try flag.check()
        if let provisional, provisional.reference.id == id {
          return Source(id: id, media: true, originalBytes: UInt64(CausalAudioPrefix.maximumSamples * 4 + 44), available: true)
        }
        guard let item = indexed[id] else { return Source(id: id, media: false, originalBytes: 0, available: false) }
        let raw = BlessengerMedia.isRaw(item)
        let size = try? store.vault.originalByteCount(id)
        return Source(id: id, media: raw, originalBytes: UInt64(size ?? 0),
          available: size != nil && item.kind != .unavailable && (raw || !item.text.isEmpty))
      }
      let currentText = current.compactMap { indexed[$0] }.reduce(UInt64(text.utf8.count)) {
        $0 + UInt64($1.text.utf8.count) + UInt64($1.coverage.utf8.count) + UInt64($1.name.utf8.count)
      }
      return Input(units: grouped, sources: metadata, current: current, currentTextBytes: currentText)
    }
    let window = try input.selected()
    let selectedMessages = Set(window.messages)
    let retained = history.filter { selectedMessages.contains($0.id) }
    let currentMedia: BlessengerMedia.Prepared
    if let provisional {
      guard current == [provisional.reference.id] else { throw BoomError.invalid("A provisional call has exactly one current waveform.") }
      currentMedia = .init(context: "", sources: [], payloads: [provisional])
    } else {
      currentMedia = try await BlessengerMedia.prepare(current, state: state, store: store, supportsRawAudio: supportsRawAudio, flag: flag)
    }
    let priorIDs = window.sourceIds.filter { !current.contains($0) }
    let decoded = try await BlessengerMedia.prepare(priorIDs, state: state, store: store, supportsRawAudio: supportsRawAudio, flag: flag,
      maximumDecodedBytes: 67_108_864 - BlessengerMedia.decodedBytes(currentMedia))
    let priorSourceIDs = Set(retained.flatMap(BlessengerMedia.directSources))
    let allSources = decoded.sources + currentMedia.sources
    let allPayloads = decoded.payloads + currentMedia.payloads
    let raw = Set(window.rawSourceIds)
    var occurrences: [UUID: [UUID]] = [:]
    for message in retained where message.role == .user {
      occurrences[message.id] = BlessengerMedia.directSources(message).filter { raw.contains($0) }
    }
    let prior = BlessengerMedia.History(prepared: .init(context: "",
      sources: allSources.filter { priorSourceIDs.contains($0.id) },
      payloads: allPayloads.filter { priorSourceIDs.contains($0.reference.id) }), occurrences: occurrences, window: window)
    return Capture(input: input, history: retained, window: window, current: currentMedia, prior: prior)
  }
  /// Ask the real tokenizer/media route to fit. Only whole older units slide;
  /// explicit current input, Contact instructions and output reserves never do.
  /// No one-shot raw decoder is called again during this search.
  static func fit(_ initial: Capture, voices: [Voice?], instructions: String,
    request: String, routing: [String], reserves: [Int], runner: MLXGemmaRunner,
    owner: PromptCacheOwner, flag: CancellationFlag) async throws -> Round {
    guard voices.count == reserves.count, !voices.isEmpty else { throw BoomError.invalid("Every response requires a context reservation.") }
    func compile(_ capture: Capture) async throws -> [ConsultationPlan] {
      try flag.check()
      let plans = try ProductCore.consultationRound(voices: voices, history: capture.history,
        instructions: instructions, context: capture.current.context, request: request, routing: routing,
        promptContract: .referenceHistoryV2, historyMedia: capture.prior.occurrences,
        currentMedia: capture.current.payloads.map { $0.reference.id })
      for (plan, reserve) in zip(plans, reserves) {
        let payloads = capture.payloads.filter { plan.placedMediaIDs.contains($0.reference.id) }
        _ = try await runner.preflight(plan, images: [], media: payloads, maxTokens: reserve, flag: flag, cacheOwner: owner)
      }
      return plans
    }
    return try await selectFitting(initial, flag: flag, compile: compile)
  }
  static func selectFitting(_ initial: Capture, flag: CancellationFlag,
    compile: (Capture) async throws -> [ConsultationPlan]) async throws -> Round {
    do { return Round(capture: initial, plans: try await compile(initial)) }
    catch BoomError.budget { /* whole-unit search below */ }
    var best = try initial.selecting(maximumUnits: 0, tokenLimited: true)
    var plans = try await compile(best) // mandatory current content must actually fit
    var low = 0, high = initial.window.units.count
    while low + 1 < high {
      let middle = low + (high - low) / 2
      let candidate = try initial.selecting(maximumUnits: middle, tokenLimited: true)
      do { let value = try await compile(candidate); low = middle; best = candidate; plans = value }
      catch BoomError.budget { high = middle }
    }
    try flag.check()
    return Round(capture: best, plans: plans)
  }
}
