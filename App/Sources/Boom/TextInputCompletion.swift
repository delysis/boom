import AppKit
import BoomCore
import Foundation

struct TextInputTarget: Equatable, Sendable {
  let chatID: UUID?
  let documentID: UUID?
  var messageID: UUID? = nil
  var instructions = false
}

/// Bare editable bytes and conversation attribution accompany the compiled
/// recipe. Chat drafts are never admitted as library manuscripts.
struct TextInputCapture: Codable, Sendable {
  let chatID: UUID?
  let messageID: UUID?
  let contextDigest: String
  let snapshot: DocumentSnapshot
  let caretUTF16: Int
}

/// Main-thread validity uses local ownership only. The encoded digest remains
/// part of the captured generation; it is never replaced with this stamp.
struct InputContextStamp: Equatable, Sendable {
  struct Attachment: Equatable, Sendable {
    let id: UUID
    let rootDigest: String
  }
  let target: TextInputTarget
  let chatVersion: UUID?
  let attachments: [Attachment]
}

/// Value snapshots share immutable String/Array storage until an author edits.
/// Encoding, history projection and prompt compilation run on the worker.
struct InputContextSnapshot: Sendable {
  let stamp: InputContextStamp
  let chat: ChatRecord?
  let pendingAttachments: [UUID]

  func digests(cachedChatDigest: String? = nil) throws -> (chat: String, context: String) {
    let chatDigest: String
    if let chat {
      if let cachedChatDigest { chatDigest = cachedChatDigest }
      else {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        chatDigest = Digest.sha256(try encoder.encode(chat))
      }
    } else { return ("", Digest.sha256("null")) }
    return (chatDigest, Digest.sha256(chatDigest + stamp.attachments.map {
      $0.id.uuidString + $0.rootDigest
    }.joined()))
  }
  func compile(text: String, caret: Int) throws -> String {
    let target = stamp.target
    var messages = chat?.messages ?? []
    var speaker = "You"
    if let messageID = target.messageID {
      guard let index = messages.firstIndex(where: { $0.id == messageID }) else { throw BoomError.stale("Message changed.") }
      speaker = messages[index].speaker?.name ?? (messages[index].role == .user ? "You" : "Bloom")
      messages = Array(messages[..<index])
    }
    if target.instructions { messages = [] }
    let turns = messages.filter { $0.state == .complete }.map {
      PromptTurn(role: $0.role.rawValue, text: Self.mediaLinks($0.directAttachments ?? []) + $0.text,
        speaker: $0.speaker ?? Speaker(name: $0.role == .user ? "You" : "Bloom"))
    }
    let mediaIDs = target.instructions ? [] : target.messageID.flatMap { id in
      chat?.messages.first(where: { $0.id == id }).map { $0.directAttachments ?? [] }
    } ?? pendingAttachments
    let context = [chat?.instructions ?? "", Self.mediaLinks(mediaIDs)].filter { !$0.isEmpty }.joined(separator: "\n")
    return try ProductCore.inputContext(instructions: target.instructions ? "" : context,
      history: turns, speaker: speaker, text: text, caret: caret)
  }
  private static func mediaLinks(_ ids: [UUID]) -> String {
    ids.map { "[Attachment: media](boom-attachment:\($0.uuidString))\n" }.joined()
  }
}

@MainActor private final class InputCandidateProgress {
  var bundle: CandidateBundle
  let publish: @MainActor (CandidateBundle) -> Void
  init(_ bundle: CandidateBundle, publish: @escaping @MainActor (CandidateBundle) -> Void) {
    self.bundle = bundle; self.publish = publish
  }
  func apply(_ updates: [MLXGemmaRunner.BatchCheckpoint], start: Int, flag: CancellationFlag) {
    guard !flag.isCancelled else { return }
    var snapshot = bundle
    for update in updates {
      snapshot.candidates[start + update.lane].retain(update.progress)
      if let stop = update.stopReason {
        snapshot.candidates[start + update.lane].state = stop == "cancelled" ? .cancelled : (update.progress.text.isEmpty ? .failed : .complete)
        snapshot.candidates[start + update.lane].stopReason = stop
        snapshot.candidates[start + update.lane].stopTokenID = update.stopTokenID
      }
    }
    bundle = snapshot; publish(snapshot)
  }
}

@MainActor final class TextInputCompletion: NativeCompletionClient {
  weak var model: WorkspaceModel?
  weak var view: NativeCompletionTextView?
  let id = UUID()
  private(set) var target: TextInputTarget
  private(set) var completionDocument: DocumentSnapshot?
  private var documentSourceVersion: UUID?
  private var stampedDocumentVersion: UUID?
  private(set) var ghostStamp: GhostStamp?
  private(set) var ghostText = ""
  private var epoch: UInt64 = 0
  private var caret = 0
  private var contextDigest: String?
  private var contextStamp: InputContextStamp?
  private(set) var bundle: CandidateBundle?
  private var task: Task<Void, Never>?
  private var flag: CancellationFlag?
  var hasCompletionChoices: Bool { bundle != nil && !ghostText.isEmpty }

  init(model: WorkspaceModel, target: TextInputTarget) {
    self.model = model; self.target = target
    if !model.isBusy { contextStamp = try? model.inputContextStamp(target) }
    model.registerInputCompletion(self)
  }
  func update(selection: NSRange, marked: Bool, target: TextInputTarget) {
    guard let view else { model?.revokeInputJoinedRetentions(id); invalidateGhost(); return }
    let sourceVersion = view.sourceVersion
    let sourceChanged = completionDocument == nil || documentSourceVersion != sourceVersion
    let changed = self.target != target || sourceChanged || caret != selection.location
    if sourceChanged {
      completionDocument = DocumentSnapshot(id: id, title: "Chat input", text: view.string)
      documentSourceVersion = sourceVersion
    }
    if self.target != target { model?.revokeInputJoinedRetentions(id) }
    self.target = target; caret = selection.location
    if changed || marked || selection.length != 0 {
      invalidateGhost()
      if !view.movingGhostBoundary {
        bundle = nil
        if model?.isBusy == true { contextStamp = nil }
        else { contextStamp = try? model?.inputContextStamp(target) }
        view.endGhostBoundary()
      }
    }
    if !marked, selection.length == 0, !view.movingGhostBoundary { schedule() }
  }
  func refresh() {
    // A local ownership comparison keeps status/streaming refresh independent
    // of the size of the stored chat. Encoding belongs to the captured worker.
    if model?.isBusy == true { invalidateGhost(); return }
    guard let model, let stamp = try? model.inputContextStamp(target) else {
      invalidateGhost(); bundle = nil; contextStamp = nil; contextDigest = nil; view?.endGhostBoundary(); return
    }
    if contextStamp != nil && contextStamp != stamp {
      invalidateGhost(); bundle = nil; view?.endGhostBoundary()
    }
    contextStamp = stamp
    guard !model.isBusy, model.state.autocomplete else { invalidateGhost(); return }
    schedule()
  }
  func invalidateGhost() {
    epoch &+= 1; flag?.cancel(); task?.cancel()
    flag = nil
    ghostStamp = nil; stampedDocumentVersion = nil; ghostText = ""; view?.clearGhost()
  }
  func join() async { invalidateGhost(); if let task { await task.value } }
  var joinedRetentionOwnerIsLive: Bool {
    guard let model, view != nil else { return false }
    if let id = target.chatID {
      guard let chat = model.state.chats.first(where: { $0.id == id }) else { return false }
      if let message = target.messageID, !chat.messages.contains(where: { $0.id == message }) { return false }
    }
    if let id = target.documentID, !model.documentIndices.contains(where: { $0.id == id }) { return false }
    return true
  }
  private var eligible: Bool {
    guard let model, !model.isBusy, model.state.autocomplete, model.inputCompletionRunner != nil,
      let view, view.window?.firstResponder === view, !view.hasMarkedText(),
      view.selectedRange().length == 0, caret > 0, completionDocument != nil,
      view.sourceVersion == documentSourceVersion else { return false }
    return true
  }
  func schedule(delay: Duration = .milliseconds(650)) {
    guard eligible, ghostStamp == nil, flag == nil, view?.hasGhostBoundary != true else { return }
    start(count: 1, previous: nil, delay: delay)
  }
  private func start(count: Int, previous: CandidateBundle?, delay: Duration) {
    guard eligible, let model, let document = completionDocument else { return }
    let capturedEpoch = epoch, target = target, capturedCaret = caret
    let previousTask = task
    flag?.cancel(); previousTask?.cancel()
    let operation = CancellationFlag(); flag = operation
    task = Task { [weak self, weak model] in
      defer { if let self, self.flag === operation { self.flag = nil } }
      if let previousTask { await previousTask.value }
      do {
        try await Task.sleep(for: delay)
        try operation.check()
        guard let self, let model, self.epoch == capturedEpoch, self.eligible else { return }
        // Full-prefix validation belongs to this captured operation, after the
        // debounce, not every status, selection or native layout callback.
        guard let prepared = try await model.prepareInputContext(target, document: document,
          caret: capturedCaret, flag: operation), self.epoch == capturedEpoch, self.eligible,
          self.completionDocument?.textVersion == document.textVersion,
          (try? model.inputContextStamp(target)) == prepared.stamp else { return }
        let digest = prepared.digest, raw = prepared.raw, capturedContext = prepared.stamp
        self.contextDigest = digest; self.contextStamp = capturedContext
        let capture = TextInputCapture(chatID: target.chatID, messageID: target.messageID,
          contextDigest: digest, snapshot: document, caretUTF16: capturedCaret)
        let compiled = DocumentSnapshot(id: document.id, title: document.title, text: raw)
        let result = try await model.generateInputCandidates(document: compiled, capture: capture,
          count: count, previous: previous, flag: operation,
          beforeCachePublication: { [weak self, weak model] in
            guard let sourceOwner = self, let workspaceOwner = model else {
              throw BoomError.stale("The input source changed before prompt-cache publication.")
            }
            try await MainActor.run {
              try operation.check()
              guard sourceOwner.epoch == capturedEpoch,
                sourceOwner.completionDocument?.textVersion == document.textVersion,
                sourceOwner.view?.sourceVersion == sourceOwner.documentSourceVersion,
                sourceOwner.caret == capturedCaret, sourceOwner.target == target,
                (try? workspaceOwner.inputContextStamp(target)) == capturedContext,
                sourceOwner.view?.hasMarkedText() == false else {
                throw BoomError.stale("The input source changed before prompt-cache publication.")
              }
            }
          }) { [weak self] bundle in
            guard let self, self.epoch == capturedEpoch, !operation.isCancelled,
              self.completionDocument?.textVersion == document.textVersion,
              self.view?.sourceVersion == self.documentSourceVersion, self.caret == capturedCaret,
              self.target == target, (try? self.model?.inputContextStamp(target)) == capturedContext,
              self.view?.hasMarkedText() == false else { operation.cancel(); return }
            var displayed = bundle
            if let prior = self.bundle, prior.id == bundle.id { displayed.selected = prior.selected }
            self.bundle = displayed
            self.present(displayed.candidates[displayed.selected].text)
          }
        if self.epoch == capturedEpoch, !operation.isCancelled { self.bundle = result }
      } catch is CancellationError {} catch {
        // A background suggestion can fail without interrupting authored text.
        // The attempt and its failure remain available for diagnosis.
      }
    }
  }
  private func present(_ text: String) {
    guard let document = completionDocument, let view, !text.isEmpty, !view.hasMarkedText(),
      view.sourceVersion == documentSourceVersion,
      view.selectedRange() == NSRange(location: caret, length: 0) else { return }
    let stamp: GhostStamp
    if let current = ghostStamp, stampedDocumentVersion == document.textVersion,
      current.caretUTF16 == caret, current.epoch == epoch {
      stamp = current
    } else {
      guard let captured = try? GhostStamp(document: document, caretUTF16: caret, epoch: epoch) else { return }
      stamp = captured; stampedDocumentVersion = document.textVersion
    }
    ghostText = text; ghostStamp = stamp; view.showGhost(text, stamp: stamp)
  }
  func takeGhost(documentID: UUID, caret: Int) -> String? {
    guard let document = completionDocument, let stamp = ghostStamp,
      stamp.accepts(document: document, caretUTF16: caret, epoch: epoch,
        hasMarkedText: view?.hasMarkedText() ?? true), document.id == documentID,
      ghostSourcesRemainCurrent([], manuscriptID: documentID), !ghostText.isEmpty else {
      invalidateGhost(); return nil
    }
    let text = ghostText; invalidateGhost(); return text
  }
  func takeGhostChunk(documentID: UUID, caret: Int) -> CompletionSegment? {
    guard let whole = takeGhost(documentID: documentID, caret: caret) else { return nil }
    let chunk = CompletionNavigation.nextChunk(whole)
    return CompletionSegment(accepted: chunk.accepted, remaining: chunk.remaining, whole: whole, sources: [])
  }
  func ghostSourcesRemainCurrent(_ sources: [SourceReference], manuscriptID: UUID) -> Bool {
    guard let model, !model.isBusy, let contextStamp else { return false }
    return (try? model.inputContextStamp(target)) == contextStamp
  }
  func resumeGhost(_ text: String, documentID: UUID, caret: Int, sources: [SourceReference]) {
    guard completionDocument?.id == documentID, self.caret == caret,
      ghostSourcesRemainCurrent(sources, manuscriptID: documentID) else { return }
    present(text)
  }
  func navigateGhost(_ direction: Int) {
    guard eligible else { return }
    guard var current = bundle, current.input?.snapshot.revision == completionDocument?.revision,
      current.input?.caretUTF16 == caret, current.input?.contextDigest == contextDigest,
      ghostSourcesRemainCurrent([], manuscriptID: id)
    else { invalidateGhost(); start(count: 3, previous: nil, delay: .zero); return }
    if current.candidates.count == 1 {
      bundle = nil
      invalidateGhost(); start(count: 2, previous: current, delay: .zero)
    } else {
      current.selected = (current.selected + direction + current.candidates.count) % current.candidates.count
      bundle = current; present(current.candidates[current.selected].text)
    }
  }
}

extension WorkspaceModel {
  var inputCompletionRunner: MLXGemmaRunner? { baseRunner ?? mlxRunner }
  func inputContextStamp(_ target: TextInputTarget) throws -> InputContextStamp {
    guard target.chatID == state.selectedChat,
      target.chatID != nil || target.documentID == state.selectedDocument else { throw BoomError.stale("Input changed.") }
    let pending = target.messageID == nil && !target.instructions ? pendingAttachments : []
    return InputContextStamp(target: target, chatVersion: selectedChat?.contentVersion,
      attachments: pending.compactMap { id in state.attachments.first(where: { $0.id == id }).map {
        InputContextStamp.Attachment(id: $0.id, rootDigest: $0.rootDigest)
      } })
  }
  func captureInputContext(_ target: TextInputTarget) throws -> InputContextSnapshot {
    InputContextSnapshot(stamp: try inputContextStamp(target), chat: selectedChat,
      pendingAttachments: pendingAttachments)
  }
  fileprivate func cachedInputChatDigest(_ snapshot: InputContextSnapshot) -> String? {
    guard let chat = snapshot.chat, let cached = inputContextCache,
      cached.id == chat.id, cached.version == chat.contentVersion else { return nil }
    return cached.digest
  }
  fileprivate func retainInputChatDigest(_ digest: String, snapshot: InputContextSnapshot) {
    guard let chat = snapshot.chat,
      (try? inputContextStamp(snapshot.stamp.target)) == snapshot.stamp else { return }
    inputContextCache = (id: chat.id, version: chat.contentVersion, digest: digest)
  }
  func prepareInputContext(_ target: TextInputTarget, document: DocumentSnapshot,
    caret: Int, flag: CancellationFlag
  ) async throws -> (stamp: InputContextStamp, digest: String, raw: String)? {
    let snapshot = try captureInputContext(target)
    let cachedDigest = cachedInputChatDigest(snapshot)
    let prepared = try await detachedWork { () -> (chatDigest: String, digest: String, raw: String)? in
      try flag.check()
      let prefix = try ProductCore.authoredPrefix(document, caret: caret)
      guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let digests = try snapshot.digests(cachedChatDigest: cachedDigest)
      try flag.check()
      let raw = try snapshot.compile(text: document.text, caret: caret)
      try flag.check()
      return (digests.chat, digests.context, raw)
    }
    guard let prepared else { return nil }
    try flag.check()
    guard (try? inputContextStamp(target)) == snapshot.stamp else { throw BoomError.stale("Input changed.") }
    retainInputChatDigest(prepared.chatDigest, snapshot: snapshot)
    return (snapshot.stamp, prepared.digest, prepared.raw)
  }
  // Synchronous projections remain available for explicit fixture inspection.
  // Native input callbacks use only inputContextStamp; generation uses a worker.
  func inputContextDigest(_ target: TextInputTarget) throws -> String {
    let snapshot = try captureInputContext(target)
    let digests = try snapshot.digests(cachedChatDigest: cachedInputChatDigest(snapshot))
    retainInputChatDigest(digests.chat, snapshot: snapshot)
    return digests.context
  }
  func inputContext(_ target: TextInputTarget, text: String, caret: Int) throws -> String {
    try captureInputContext(target).compile(text: text, caret: caret)
  }
  func generateInputCandidates(document: DocumentSnapshot, capture: TextInputCapture, count: Int,
    previous: CandidateBundle?, flag: CancellationFlag,
    beforeCachePublication: @escaping @Sendable () async throws -> Void,
    publish: @escaping @MainActor (CandidateBundle) -> Void) async throws -> CandidateBundle {
    guard let runner = inputCompletionRunner, !isBusy else { throw CancellationError() }
    let seeds = (0..<count).map { _ in UInt64.random(in: .min ... .max) }
    let media = try await writingMedia(in: previous?.recipe.sourcePrompt ?? document.text, flag: flag)
    let cacheOwner = PromptCacheOwner(namespace: inferenceCacheNamespace,
      entity: capture.snapshot.id, route: .inputCompletion)
    let pairedAdmission = makePairedContextAdmission(runner: runner,
      purpose: baseRunner === runner ? .writing : .consultation, owner: cacheOwner, flag: flag) {
      // The same captured target/text/caret/context validator used by successful
      // cache publication also gates a peer release and the exact retry.
      try await beforeCachePublication()
    }
    let recipe: CompletionRecipe
    if let previous { recipe = previous.recipe }
    else {
      recipe = try await runner.completionRecipe(document: document, caret: document.text.utf16.count,
        sources: media.map { $0.reference.source }, examples: [], profile: samplingProfile, maxTokens: 64, flag: flag, batchWidth: seeds.count, media: media,
        cacheOwner: cacheOwner, pairedAdmission: pairedAdmission)
    }
    try flag.check(); try ProductCore.validateWritingRecipe(recipe)
    guard recipe.model == runner.identity else { throw BoomError.stale("Completion model changed.") }
    let executionPolicy = try ProductCore.resolvedGenerationPolicy(recipe.generationPolicy, loaded: runner.generationPolicy)
    var bundle = previous ?? CandidateBundle(id: UUID(), recipe: recipe, origin: nil,
      candidates: [], selected: 0, input: capture)
    let start = bundle.candidates.count
    guard start + seeds.count <= 3 else { throw BoomError.invalid("Too many input alternatives.") }
    for (lane, seed) in seeds.enumerated() {
      bundle.candidates.append(WritingCandidate(id: UUID(), seed: seed, text: "", state: .pending,
        promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: nil,
        batch: seeds.count > 1 ? WritingBatchExecution(seeds: seeds, lane: lane) : nil))
    }
    if start > 0 { bundle.selected = start }
    let generations = seeds.enumerated().map { lane, seed in
      GenerationIdentity(kind: .writing, operationID: flag.operationID, recordID: bundle.id,
        attemptID: bundle.candidates[start + lane].id, model: recipe.model, seed: seed,
        requestDigest: recipe.promptDigest, maxTokens: recipe.maxTokens, generationPolicy: recipe.generationPolicy,
        batch: bundle.candidates[start + lane].batch)
    }
    let checkpointStore = store
    try await saveInputCandidate(bundle)
    publish(bundle)
    let progress = InputCandidateProgress(bundle, publish: publish)
    do {
      let orderedMedia = try (recipe.media ?? []).map { reference -> WritingMediaData in
        guard let payload = media.first(where: { $0.reference == reference }) else { throw BoomError.stale(reference.name) }; return payload
      }
      // The input source ID survives glyph edits; textVersion identifies only a snapshot.
      let joinedRetention = try makeJoinedRetentionRequest(owner: cacheOwner,
        runner: runner, policy: executionPolicy, operationID: flag.operationID)
      defer { finishJoinedRetentionRequest(joinedRetention) }
      let results = try await runner.runBatch(rawPrompt: recipe.prompt, media: orderedMedia, maxTokens: recipe.maxTokens,
        settings: recipe.settings, seeds: seeds, flag: flag, background: true,
        cacheOwner: cacheOwner, executionPolicy: executionPolicy, joinedRetention: joinedRetention,
        beforeCachePublication: beforeCachePublication, pairedAdmission: pairedAdmission,
        onCheckpoint: { updates in
          for update in updates {
            try await checkpointStore.checkpoint(update.progress, identity: generations[update.lane],
              stopReason: update.stopReason, stopTokenID: update.stopTokenID)
          }
          await progress.apply(updates, start: start, flag: flag)
        })
      for (lane, result) in results.enumerated() {
        let index = start + lane
        bundle.candidates[index].text = result.text; bundle.candidates[index].tokenIDs = result.tokenIDs
        bundle.candidates[index].promptTokens = result.promptTokens; bundle.candidates[index].outputTokens = result.outputTokens
        bundle.candidates[index].state = result.stopReason == "cancelled" ? .cancelled : (result.text.isEmpty ? .failed : .complete)
        bundle.candidates[index].stopReason = result.stopReason; bundle.candidates[index].stopTokenID = result.stopTokenID
        bundle.candidates[index].executionOrigin = result.executionOrigin
      }
      try await saveInputCandidate(bundle)
      try flag.check(); publish(bundle)
      return bundle
    } catch {
      for index in start..<bundle.candidates.count {
        let checkpoint = try await store.writingCheckpoint(bundle: bundle, candidate: bundle.candidates[index])
        bundle.candidates[index].finishInterrupted(checkpoint, failed: !flag.isCancelled,
          reason: flag.isCancelled ? "cancelled" : "failed")
      }
      try await saveInputCandidate(bundle)
      throw error
    }
  }
  private func saveInputCandidate(_ bundle: CandidateBundle) async throws {
    let vault = store.vault
    try await detachedWork { try vault.encode(bundle, kind: .candidate, id: bundle.id) }
    if !state.candidateIDs.contains(bundle.id) { state.candidateIDs.append(bundle.id) }
    try await flush()
  }
}
