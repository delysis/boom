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
  private(set) var ghostStamp: GhostStamp?
  private(set) var ghostText = ""
  private var epoch: UInt64 = 0
  private var caret = 0
  private var contextDigest: String?
  private(set) var bundle: CandidateBundle?
  private var task: Task<Void, Never>?
  private var flag: CancellationFlag?
  var hasCompletionChoices: Bool { bundle != nil && !ghostText.isEmpty }

  init(model: WorkspaceModel, target: TextInputTarget) {
    self.model = model; self.target = target
    contextDigest = try? model.inputContextDigest(target)
    model.registerInputCompletion(self)
  }
  func update(text: String, selection: NSRange, marked: Bool, target: TextInputTarget) {
    let next = DocumentSnapshot(id: id, title: "Chat input", text: text)
    let changed = self.target != target || completionDocument?.revision != next.revision || caret != selection.location
    self.target = target; completionDocument = next; caret = selection.location
    if changed || marked || selection.length != 0 {
      invalidateGhost()
      if view?.movingGhostBoundary != true {
        bundle = nil; contextDigest = try? model?.inputContextDigest(target); view?.endGhostBoundary()
      }
    }
    if !marked, selection.length == 0, view?.movingGhostBoundary != true { schedule() }
  }
  func refresh() {
    guard let model, let digest = try? model.inputContextDigest(target) else {
      invalidateGhost(); bundle = nil; contextDigest = nil; view?.endGhostBoundary(); return
    }
    if contextDigest != nil && contextDigest != digest {
      invalidateGhost(); bundle = nil; view?.endGhostBoundary()
    }
    contextDigest = digest
    guard !model.isBusy, model.state.autocomplete else { invalidateGhost(); return }
    schedule()
  }
  func invalidateGhost() {
    epoch &+= 1; flag?.cancel(); task?.cancel()
    flag = nil
    ghostStamp = nil; ghostText = ""; view?.clearGhost()
  }
  func join() async { invalidateGhost(); if let task { await task.value } }
  private var eligible: Bool {
    guard let model, !model.isBusy, model.state.autocomplete, model.inputCompletionRunner != nil,
      let view, view.window?.firstResponder === view, !view.hasMarkedText(),
      view.selectedRange().length == 0, caret > 0, let document = completionDocument,
      let prefix = try? ProductCore.authoredPrefix(document, caret: caret) else { return false }
    return !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let digest = try model.inputContextDigest(target)
        self.contextDigest = digest
        let capture = TextInputCapture(chatID: target.chatID, messageID: target.messageID,
          contextDigest: digest, snapshot: document, caretUTF16: capturedCaret)
        let raw = try model.inputContext(target, text: document.text, caret: capturedCaret)
        let compiled = DocumentSnapshot(id: document.id, title: document.title, text: raw)
        let result = try await model.generateInputCandidates(document: compiled, capture: capture,
          count: count, previous: previous, flag: operation) { [weak self] bundle in
            guard let self, self.epoch == capturedEpoch, !operation.isCancelled,
              self.completionDocument?.revision == document.revision, self.caret == capturedCaret,
              self.target == target, (try? self.model?.inputContextDigest(target)) == digest,
              self.view?.hasMarkedText() == false else { operation.cancel(); return }
            var displayed = bundle
            if let prior = self.bundle, prior.id == bundle.id { displayed.selected = prior.selected }
            self.bundle = displayed
            self.present(displayed.candidates[displayed.selected].text)
          }
        if self.epoch == capturedEpoch, !operation.isCancelled { self.bundle = result }
      } catch is CancellationError {} catch {
        // A background suggestion can fail without interrupting authored text.
        // The encrypted attempt and its failure remain available for diagnosis.
      }
    }
  }
  private func present(_ text: String) {
    guard let document = completionDocument, let view, !text.isEmpty,
      view.string == document.text, view.selectedRange() == NSRange(location: caret, length: 0),
      let stamp = try? GhostStamp(document: document, caretUTF16: caret, epoch: epoch) else { return }
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
    guard let model, !model.isBusy, let contextDigest else { return false }
    return (try? model.inputContextDigest(target)) == contextDigest
  }
  func resumeGhost(_ text: String, documentID: UUID, caret: Int, sources: [SourceReference]) {
    guard completionDocument?.id == documentID, self.caret == caret,
      ghostSourcesRemainCurrent(sources, manuscriptID: documentID) else { return }
    present(text)
  }
  func navigateGhost(_ direction: Int) {
    guard eligible else { return }
    guard var current = bundle, current.input?.snapshot.revision == completionDocument?.revision,
      current.input?.caretUTF16 == caret, current.input?.contextDigest == (try? model?.inputContextDigest(target))
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
  func inputContextDigest(_ target: TextInputTarget) throws -> String {
    guard target.chatID == state.selectedChat,
      target.chatID != nil || target.documentID == state.selectedDocument else { throw BoomError.stale("Input changed.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    guard let chat = selectedChat else { return Digest.sha256("null") }
    if let cached = inputContextCache, cached.0 == chat { return cached.1 }
    let digest = Digest.sha256(try encoder.encode(chat))
    inputContextCache = (chat, digest)
    return digest
  }
  func inputContext(_ target: TextInputTarget, text: String, caret: Int) throws -> String {
    _ = try inputContextDigest(target)
    let chat = selectedChat
    var messages = chat?.messages ?? []
    var speaker = "You"
    if let messageID = target.messageID {
      guard let index = messages.firstIndex(where: { $0.id == messageID }) else { throw BoomError.stale("Message changed.") }
      speaker = messages[index].speaker?.name ?? (messages[index].role == .user ? "You" : "Bloom")
      messages = Array(messages[..<index])
    }
    if target.instructions { messages = [] }
    let turns = messages.filter { $0.state == .complete }.map {
      PromptTurn(role: $0.role.rawValue, text: $0.text,
        speaker: $0.speaker ?? Speaker(name: $0.role == .user ? "You" : "Bloom"))
    }
    return try ProductCore.inputContext(instructions: target.instructions ? "" : chat?.instructions ?? "",
      history: turns, speaker: speaker, text: text, caret: caret)
  }
  func generateInputCandidates(document: DocumentSnapshot, capture: TextInputCapture, count: Int,
    previous: CandidateBundle?, flag: CancellationFlag,
    publish: @escaping @MainActor (CandidateBundle) -> Void) async throws -> CandidateBundle {
    guard let runner = inputCompletionRunner, !isBusy else { throw CancellationError() }
    let seeds = (0..<count).map { _ in UInt64.random(in: .min ... .max) }
    let recipe: CompletionRecipe
    if let previous { recipe = previous.recipe }
    else {
      recipe = try await runner.completionRecipe(document: document, caret: document.text.utf16.count,
        sources: [], examples: [], profile: samplingProfile, maxTokens: 64, flag: flag, batchWidth: 3)
    }
    try flag.check(); try ProductCore.validateWritingRecipe(recipe)
    guard recipe.model == runner.identity else { throw BoomError.stale("Completion model changed.") }
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
      let results = try await runner.runBatch(rawPrompt: recipe.prompt, maxTokens: recipe.maxTokens,
        settings: recipe.settings, seeds: seeds, flag: flag, background: true,
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
