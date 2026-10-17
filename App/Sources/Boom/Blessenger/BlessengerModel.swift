import AppKit
import AVFoundation
import BoomCore
import Foundation

/// Presentation and operation ownership, not another transcript or database.
/// Every admitted mutation goes through the existing WorkspaceStore actor.
@MainActor final class BlessengerModel: ObservableObject {
  let store: WorkspaceStore
  let catalog: BlessengerCatalog
  let namespace: UUID
  @Published private(set) var state: WorkspaceState
  @Published private(set) var draft: BlessengerDraft
  @Published private(set) var active: Set<UUID> = []
  @Published private(set) var preparing = false
  @Published private(set) var navigating = false
  @Published private(set) var loading = false
  @Published private(set) var failure: String?
  @Published private(set) var liveText: [UUID: String] = [:]
  @Published var settingsOpen = false
  @Published var filter = "all"
  @Published var search = "" { didSet { updateSearch() } }
  @Published var composerFocus = 0
  @Published var recipientFocus = 0
  let audio = BlessengerAudioOutput()
  lazy var inputCompletion = BlessengerCompletion(model: self)
  enum CallPhase { case idle, preparing, active, ending }
  @Published private(set) var callPhase = CallPhase.idle
  var isCalling: Bool { callPhase == .active }
  var callStarting: Bool { callPhase == .preparing }
  var callEnding: Bool { callPhase == .ending }
  var callInProgress: Bool { callPhase != .idle }
  private var callLifetime: CancellationFlag?
  private var callTask: Task<Void, Never>?
  private let requestMicrophone: @MainActor () async -> Bool
  private var call: BlessengerCall?
  private var callID: UUID?
  private var callOperation: CancellationFlag?
  private struct AudioPreparation {
    let captureID: UUID
    let callID: UUID
    let history: ChatRecord?
    let profile: BlessengerProfile
    let contacts: [BlessengerContact]
    let historical: BlessengerMedia.History
    let fittedHistory: [ChatMessage]
    let plans: [ConsultationPlan]
    let trace: BlessengerTrace
    var observation: CausalAudioPrefix.Observation
    var lastPrepared: Double
  }
  private var audioPreparation: AudioPreparation?
  enum NoteState { case idle, preparing, recording, stopping }
  @Published private(set) var noteState = NoteState.idle
  private let voiceNote = VoiceInput()
  private var unstoredVoiceNote: (draftID: UUID, bytes: Data)?
  @Published private(set) var hasUnstoredVoiceNote = false
  @Published var mediaReview: BlessengerMediaReview?
  @Published private(set) var callIssue: String?
  private var speechActionFlag: CancellationFlag?
  @Published var exampleRole = Role.user
  private var runner: MLXGemmaRunner?
  private var runnerPath: String?
  private var draftTask: Task<Void, Never>?
  private var draftFailure: Error?
  private var storedDraftVersion: UUID
  private var operations: [UUID: Task<Void, Never>] = [:]
  private var flags: [UUID: CancellationFlag] = [:]
  private var childFlags: [UUID: CancellationFlag] = [:]
  private var closed = false
  private var closing = false
  private var actionCount = 0
  private var actions: [UUID: Task<Void, Never>] = [:]
  private var setupFlags: [UUID: CancellationFlag] = [:]
  @Published private(set) var setupProgress: String?
  @Published private(set) var callMuted = false
  @Published private(set) var callReady = false
  private var actionWaiters: [CheckedContinuation<Void, Never>] = []
  @Published private(set) var searchIDs: Set<UUID>?
  private var searchTask: Task<Void, Never>?
  private var searchEpoch = UUID()
  func beginAction() throws {
    guard !closed, !closing else { throw CancellationError() }
    actionCount += 1
  }
  func endAction() {
    actionCount -= 1
    if actionCount == 0 {
      let waiters = actionWaiters; actionWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }
  @discardableResult func launch(_ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
    do { try beginAction() } catch { return nil }
    let id = UUID()
    actions[id] = Task {
      defer { actions.removeValue(forKey: id); endAction() }
      do { try Task.checkCancellation(); try await action() } catch { report(error) }
    }
    return actions[id]
  }
  func change(restoreDraft: Bool = false,
    _ mutation: @escaping @Sendable (inout WorkspaceState, inout BlessengerState) throws -> Void) async {
    guard !navigating else { return }
    do { try beginAction() } catch { return }
    navigating = true
    defer { navigating = false; endAction() }
    do {
      try await flushDraft()
      let next = try await store.blessengerTransaction(mutation).0
      accept(next)
      if restoreDraft {
        draft = next.blessenger!.draft(for: next.selectedChat); storedDraftVersion = draft.version
      }
    } catch { report(error) }
  }
  func updateSearch() {
    searchTask?.cancel(); let epoch = UUID(); searchEpoch = epoch
    guard !search.isEmpty else { searchIDs = nil; return }
    guard search.unicodeScalars.count <= 256 else { searchIDs = []; return }
    let query = search, chats = state.chats
    searchTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(100))
        let ids = try await detachedWork { () throws -> Set<UUID> in
          var ids = Set<UUID>()
          for chat in chats {
            try Task.checkCancellation()
            if chat.title.localizedCaseInsensitiveContains(query)
              || chat.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) { ids.insert(chat.id) }
          }
          return ids
        }
        if self.searchEpoch == epoch { self.searchIDs = ids }
      } catch { /* Superseded searches never replace the current query. */ }
    }
  }

  private var admitting: UUID?

  var product: BlessengerState { state.blessenger! }
  var selected: ChatRecord? { state.chats.first { $0.id == state.selectedChat } }
  var templateSelected: Bool { product.selectedTemplate == state.selectedChat && state.selectedChat != nil }
  var recipients: [BlessengerContact] { product.addresses[draft.id]?.recipients ?? draft.recipients }
  var canSend: Bool {
    mediaReview == nil && !closed && !closing && !navigating && !preparing && !loading && !callInProgress && noteState == .idle && !hasUnstoredVoiceNote && !templateSelected
      && !(selected.map { active.contains($0.id) } ?? false)
      && ((try? BlessengerPolicy.validate(draft).sendable) == true)
  }
  var title: String {
    if let selected { return selected.title }
    return draft.groupName ?? (draft.recipients.count == 1 ? draft.recipients[0].name : "New Message")
  }
  var hasReadyModel: Bool { runner.map { effectiveProfile.modelIdentity == $0.identity } ?? false }

  init(store: WorkspaceStore, catalog: BlessengerCatalog, state: WorkspaceState, namespace: UUID,
    requestMicrophone: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
    self.requestMicrophone = requestMicrophone
    self.store = store; self.catalog = catalog; self.state = state; self.namespace = namespace
    let initialDraft = state.blessenger!.draft(for: state.selectedChat)
    draft = initialDraft; storedDraftVersion = initialDraft.version
  }
  static func open(root: URL? = nil, keySession: BlessengerKeySession = .shared) async throws -> BlessengerModel {
    let directory = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Blessenger", isDirectory: true)
    let store = try await detachedWork { try WorkspaceStore(rootOverride: directory, privateSession: keySession) }
    let catalog = try BlessengerCatalog.load()
    let state = try await store.openBlessenger(catalog: catalog)
    let namespace = try await store.storageIdentity().storeID
    return BlessengerModel(store: store, catalog: catalog, state: state, namespace: namespace)
  }
  func report(_ error: Error) {
    if error is CancellationError { return }
    failure = error.localizedDescription
  }
  func saveSpeechVoice(contactID: UUID?, expected: BlessengerSpeechVoice?,
    replacement: BlessengerSpeechVoice?) async throws {
    try beginAction(); defer { endAction() }
    try Task.checkCancellation()
    let next = try await store.blessengerSetSpeechVoice(contactID: contactID,
      expected: expected, replacement: replacement)
    accept(next)
  }
  func dismissFailure() { failure = nil; audio.dismissError() }
  private func accept(_ next: WorkspaceState) {
    guard !closed, (next.blessenger?.generation ?? 0) >= product.generation else { return }
    state = next
    if let view = inputCompletion.view { inputCompletion.observe(view) }
  }
  func editText(_ text: String) {
    guard !closed, !navigating, text.utf8.count <= 2_097_152,
      !draft.text.utf8.elementsEqual(text.utf8) else { return }
    draft.text = text; draft.version = UUID(); scheduleDraftSave()
  }
  func editGroupName(_ name: String) {
    guard !navigating, state.selectedChat == nil else { return }
    var next = draft; next.groupName = name.isEmpty ? nil : name; next.version = UUID()
    do { _ = try BlessengerPolicy.validate(next); draft = next; scheduleDraftSave() }
    catch { report(error) }
  }
  func editRecipientQuery(_ query: String) {
    guard !closed, !navigating, state.selectedChat == nil, query != draft.recipientQuery else { return }
    var next = draft; next.recipientQuery = query; next.version = UUID()
    do { _ = try BlessengerPolicy.validate(next); draft = next; scheduleDraftSave() }
    catch { report(error) }
  }
  private func scheduleDraftSave() {
    // One debouncer and one coalesced current value, not a task per keystroke.
    guard draftTask == nil, draftFailure == nil else { return }
    draftTask = Task { [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: .milliseconds(180)); try await self.saveDraftLoop() }
      catch { self.draftFailure = error; self.report(error) }
      self.draftTask = nil
    }
  }
  private func saveDraftLoop() async throws {
    while draft.version != storedDraftVersion {
      let saved = draft, expected = storedDraftVersion
      let next = try await store.blessengerSaveDraft(saved, expectedVersion: expected)
      storedDraftVersion = saved.version; accept(next)
    }
  }
  func flushDraft() async throws {
    if let draftTask { await draftTask.value }
    if let draftFailure { throw draftFailure }
    try await saveDraftLoop()
  }
  func select(_ id: UUID?, template: Bool = false) async {
    guard !navigating, !closed, noteState == .idle else { return }
    do { try beginAction() } catch { return }
    navigating = true; defer { navigating = false; endAction() }
    do {
      try await flushDraft()
      let next = try await store.blessengerSelect(id, template: template)
      accept(next); draft = next.blessenger!.draft(for: id); storedDraftVersion = draft.version
      failure = nil
      if id == nil { recipientFocus += 1 } else { composerFocus += 1 }
    } catch { report(error) }
  }
  func addContact(_ contact: BlessengerContact) async {
    guard !navigating, !closed else { return }
    let origin = draft.id
    if state.selectedChat != nil { await select(nil) }
    guard origin == BlessengerDraft.unsentID || state.selectedChat == nil else { return }
    guard state.selectedChat == nil, !navigating else { return }
    do {
      var next = draft
      if !next.recipients.contains(where: { $0.id == contact.id }) { next.recipients.append(contact) }
      next.recipientQuery = ""; next.version = UUID(); _ = try BlessengerPolicy.validate(next)
      draft = next; scheduleDraftSave()
    } catch { report(error) }
  }
  func removeContact(_ id: UUID) {
    guard state.selectedChat == nil, !navigating else { return }
    draft.recipients.removeAll { $0.id == id }; draft.version = UUID(); scheduleDraftSave()
  }
  func removeAttachment(_ id: UUID) {
    guard !navigating, !templateSelected else { return }
    draft.attachments.removeAll { $0 == id }; draft.version = UUID(); scheduleDraftSave()
  }
  @discardableResult func importInputs(_ inputs: [AttachmentInput]) async -> Bool {
    guard !navigating, !closed, !templateSelected else { return false }
    do { try beginAction() } catch { return false }
    navigating = true; defer { navigating = false; endAction() }
    do {
      try await flushDraft()
      guard inputs.count + draft.attachments.count <= 8 else { throw BoomError.budget("At most eight attachments may be sent together.") }
      for input in inputs {
        try Task.checkCancellation()
        let imported = try await detachedWork { () throws -> AttachmentImport in
          switch input {
          case .file(let url):
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            return try AttachmentProcessor.inspect(name: url.lastPathComponent, data: AttachmentProcessor.readGranted(url))
          case .bytes(let name, let data): return try AttachmentProcessor.inspect(name: name, data: data)
          }
        }
        try Task.checkCancellation()
        let next = try await store.blessengerImport(imported, draftID: draft.id, expectedVersion: storedDraftVersion)
        accept(next); draft = next.blessenger!.draft(for: state.selectedChat); storedDraftVersion = draft.version
      }
      return true
    } catch { report(error); return false }
  }
  func openMediaReview(_ captured: AttachmentRecord) {
    guard mediaReview == nil, !closed, !closing, !navigating, !callInProgress else { return }
    if [.audio, .video].contains(captured.kind), preparing || !active.isEmpty || audio.responseID != nil {
      report(BoomError.unavailable("Finish or stop the current response before opening another audio player.")); return
    }
    let target = templateSelected ? nil : draft
    let insertion = target.flatMap { BlessengerTranscriptInsertion(view: inputCompletion.view, draft: $0) }
    inputCompletion.invalidateGhost()
    let review = BlessengerMediaReview(original: captured, destination: target, insertion: insertion)
    mediaReview = review
    launch {
      await self.inputCompletion.join()
      guard self.mediaReview === review else { return }
      review.load(store: self.store)
    }
  }
  func closeMediaReview(_ review: BlessengerMediaReview, discard: Bool) {
    guard mediaReview === review, !review.hasOwnedEdit else { return }
    guard discard || !review.dirty else { return }
    launch {
      await review.close()
      if self.mediaReview === review { self.mediaReview = nil }
    }
  }
  func saveMediaTranscript(_ review: BlessengerMediaReview) {
    guard mediaReview === review else { return }
    launch {
      do { let (state, _) = try await review.save(store: self.store); self.accept(state) }
      catch { review.report(error) }
    }
  }
  func attachMediaTranscript(_ review: BlessengerMediaReview) {
    guard mediaReview === review, let destination = review.destination, !navigating else { return }
    launch {
      guard self.mediaReview === review, !self.navigating, review.canSave else { return }
      self.navigating = true; defer { self.navigating = false }
      do {
        try review.beginApplying(); defer { review.endApplying() }
        guard self.draft.id == destination.id, self.draft.version == destination.version else {
          throw BoomError.stale("The target message changed. The transcript remains available.")
        }
        try await self.flushDraft()
        let (saved, version) = try await review.save(store: self.store); self.accept(saved)
        let next = try await self.store.blessengerAttachTranscript(version, draftID: destination.id, expectedVersion: destination.version)
        self.accept(next); self.draft = next.blessenger!.draft(for: destination.id == BlessengerDraft.unsentID ? nil : destination.id)
        self.storedDraftVersion = self.draft.version
        await review.close(); if self.mediaReview === review { self.mediaReview = nil }
      } catch { review.report(error) }
    }
  }
  func insertMediaTranscript(_ review: BlessengerMediaReview) {
    guard mediaReview === review, let insertion = review.insertion else { return }
    launch {
      do {
        try review.beginApplying(); defer { review.endApplying() }
        let (saved, version) = try await review.save(store: self.store); self.accept(saved)
        guard let record = saved.attachments.first(where: { $0.id == version.id }) else { throw BoomError.stale("The saved transcript disappeared.") }
        try insertion.insert(record.text, current: self.draft)
        await review.close(); if self.mediaReview === review { self.mediaReview = nil }
      } catch { review.report(error) }
    }
  }
  func chooseModel(_ path: URL) async {
    guard !loading, !preparing, active.isEmpty, !closed, !callInProgress else { return }
    do { try beginAction() } catch { return }
    loading = true; defer { loading = false; endAction() }
    do {
      try await flushDraft()
      let chatID = state.selectedChat
      let priorProfile = chatID.flatMap { product.addresses[$0]?.profile } ?? product.defaultProfile
      var chosen = priorProfile; chosen.modelPath = path.path; chosen.modelIdentity = nil
      let loaded = try await model(for: chosen)
      let bound = try chosen.resolvingModel(path: loaded.source.path, identity: loaded.identity)
      let next = try await store.blessengerTransaction { state, product in
        guard state.selectedChat == chatID,
          (chatID.flatMap { product.addresses[$0]?.profile } ?? product.defaultProfile) == priorProfile else {
          throw BoomError.stale("The model destination changed during preparation.")
        }
        if let chatID, var address = product.addresses[chatID] {
          address.profile = bound; address.profile.id = UUID(); product.addresses[chatID] = address
        } else { product.defaultProfile = bound; product.defaultProfile.id = UUID() }
      }.0
      accept(next)
    } catch { report(error) }
  }
  private func model(for profile: BlessengerProfile) async throws -> MLXGemmaRunner {
    try BlessengerState.validate(profile)
    let directory = profile.modelPath.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? ModelPacks.cached(.consultation)
    guard let directory else { throw BoomError.unavailable("Choose or install a local consultation model in Settings.") }
    if let runner, runnerPath == directory.path {
      _ = try profile.resolvingModel(path: directory.path, identity: runner.identity); return runner
    }
    guard active.isEmpty else { throw BoomError.unavailable("Finish the current response before changing models.") }
    if let old = runner { await old.cancelAndJoin(); runner = nil; runnerPath = nil }
    let admission = try await detachedWork { try ModelPacks.admission(directory, purpose: .consultation) }
    _ = try profile.resolvingModel(path: directory.path, identity: admission.identity)
    let loaded = try await MLXGemmaRunner.load(admission: admission, cacheProtection: .ephemeral())
    runner = loaded; runnerPath = directory.path
    return loaded
  }
  func send() {
    guard canSend else { return }
    inputCompletion.invalidateGhost()
    let flag = CancellationFlag(); admitting = flag.operationID; flags[flag.operationID] = flag
    preparing = true
    operations[flag.operationID] = Task { [weak self] in
      guard let self else { return }
      defer {
        self.flags.removeValue(forKey: flag.operationID); self.operations.removeValue(forKey: flag.operationID)
        if self.admitting == flag.operationID { self.admitting = nil; self.preparing = false }
      }
      do { try await self.performSend(flag: flag) } catch { self.report(error) }
    }
  }
  func answerAgain(_ questionID: UUID) {
    guard !preparing, !navigating, !callInProgress, let captured = selected,
      !active.contains(captured.id), let question = captured.messages.first(where: { $0.id == questionID && $0.role == .user && $0.state == .complete }) else { return }
    launch {
      await self.branch(at: question.id, in: captured)
      guard let branch = self.selected, self.product.branches[branch.id] == captured.id,
        branch.messages.last?.id == question.id else { throw BoomError.stale("The alternate-answer branch was not created.") }
      self.startReplay(BlessengerReplay(chat: branch, question: question))
    }
  }
  func regenerate(_ responseID: UUID) {
    guard let chat = selected, let i = chat.messages.firstIndex(where: { $0.id == responseID && $0.role == .assistant }),
      let question = chat.messages[..<i].last(where: { $0.role == .user }) else { return }
    answerAgain(question.id)
  }
  private func startReplay(_ replay: BlessengerReplay) {
    guard !preparing, !closing, !active.contains(replay.chat.id) else { return }
    inputCompletion.invalidateGhost()
    let flag = CancellationFlag(); admitting = flag.operationID; flags[flag.operationID] = flag; preparing = true
    operations[flag.operationID] = Task {
      defer {
        flags.removeValue(forKey: flag.operationID); operations.removeValue(forKey: flag.operationID)
        if admitting == flag.operationID { admitting = nil; preparing = false }
      }
      do { try await performSend(flag: flag, replay: replay) } catch { report(error) }
    }
  }
  var synthesizableReplies: [ChatMessage] {
    selected.map(BlessengerSynthesis.eligible(in:)) ?? []
  }
  var canSynthesize: Bool {
    mediaReview == nil && !closed && !closing && !preparing && !navigating && !loading && !callInProgress
      && !templateSelected && active.isEmpty && noteState == .idle
      && synthesizableReplies.count >= 2
  }
  func synthesizeReplies() {
    guard canSynthesize, let chat = selected else { return }
    do {
      let synthesis = try BlessengerSynthesis(chat: chat, responseIDs: synthesizableReplies.map(\.id))
      inputCompletion.invalidateGhost()
      let flag = CancellationFlag(); admitting = flag.operationID
      flags[flag.operationID] = flag; preparing = true
      operations[flag.operationID] = Task {
        defer {
          flags.removeValue(forKey: flag.operationID); operations.removeValue(forKey: flag.operationID)
          if admitting == flag.operationID { admitting = nil; preparing = false }
        }
        do { try await performSynthesis(synthesis, flag: flag) } catch { report(error) }
      }
    } catch { report(error) }
  }
  private func performSynthesis(_ synthesis: BlessengerSynthesis, flag: CancellationFlag) async throws {
    await inputCompletion.join(); try await flushDraft(); try flag.check()
    let snapshot = try await store.blessengerSnapshot()
    try synthesis.revalidate(in: snapshot)
    guard let profile = snapshot.blessenger?.addresses[synthesis.chat.id]?.profile else {
      throw BoomError.unavailable("Select this conversation's local model before synthesizing replies.")
    }
    try profile.requireBinding(for: synthesis.chat)
    let runner = try await model(for: profile); try flag.check()
    let resolved = try profile.resolvingModel(path: runner.source.path, identity: runner.identity)
    let useMTP = profile.useMTP == true
    if useMTP { _ = try await runner.prepareMTP(); try flag.check() }
    let context = try synthesis.context()
    let plan = try synthesis.plan()
    // Synthesis never truncates the selected answers or silently substitutes a
    // shorter subset. Ordinary model admission rejects an over-budget request.
    _ = try await runner.preflight(plan, images: [], maxTokens: profile.maximumTokens, flag: flag)
    try flag.check()
    let id = UUID(), attempt = UUID()
    let receipt = ConsultationReceipt(operationID: flag.operationID, seed: UInt64.random(in: .min ... .max),
      state: .pending, model: runner.identity, voice: nil, plan: plan, sources: synthesis.sources,
      promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [], stopReason: "pending", elapsedSeconds: 0,
      generationPolicy: runner.generationPolicy, attemptID: attempt, responseID: id)
    var action = BlessengerDraft(id: synthesis.chat.id); action.text = "Synthesize selected replies"
    let turn = BlessengerPreparedTurn(chatID: synthesis.chat.id, draft: action, history: synthesis.chat,
      contacts: [], profile: profile, sourceDigests: synthesis.sources, context: context,
      responseIDs: [id], receipts: [receipt], voices: [nil], outputLimit: profile.maximumTokens,
      resolvedProfile: resolved, synthesis: synthesis)
    accept(try await store.blessengerAdmit(turn, flag: flag))
    active.insert(synthesis.chat.id); preparing = false; admitting = nil
    childFlags[id] = flag
    defer { active.remove(synthesis.chat.id) }
    await runResponse(receipt, id: id, chatID: synthesis.chat.id, media: [], runner: runner,
      profile: profile, flag: flag, voice: nil, useMTP: useMTP)
  }
  private func performSend(flag: CancellationFlag, caller: BlessengerCallerTurn? = nil, replay: BlessengerReplay? = nil, prefix: AudioPreparation? = nil) async throws {
    await inputCompletion.join()
    if caller == nil { try await flushDraft() }
    try flag.check()
    var captured = caller?.draft ?? draft
    if let replay {
      captured = BlessengerDraft(id: replay.chat.id); captured.text = replay.question.text
      captured.attachments = replay.question.directAttachments ?? []
    }
    let capturedSelection = caller.map { $0.conversationID } ?? replay?.chat.id ?? state.selectedChat
    let snapshot: WorkspaceState
    if let caller { snapshot = caller.snapshot } else { snapshot = try await store.blessengerSnapshot() }
    let history = snapshot.chats.first { $0.id == capturedSelection }
    if let replay {
      guard let history, try BlessengerPolicy.exactDigest(history) == BlessengerPolicy.exactDigest(replay.chat) else { throw BoomError.stale("The alternate-answer branch changed.") }
    }
    let previousQuestionID = caller?.inputMessageID ?? replay?.question.id
    let contextHistory: [ChatMessage]
    if let previousQuestionID {
      guard let last = history?.messages.last, last.id == previousQuestionID, last.role == .user else { throw BoomError.stale("The committed question is no longer last in the branch.") }
      contextHistory = Array(history!.messages.dropLast())
    } else { contextHistory = history?.messages ?? [] }
    let profile = caller?.profile ?? snapshot.blessenger!.addresses[captured.id]?.profile ?? snapshot.blessenger!.defaultProfile
    var routed = captured
    if let address = snapshot.blessenger!.addresses[captured.id] { routed.recipients = address.recipients }
    let contacts = try BlessengerPolicy.resolve(host: history?.id, draft: routed, state: snapshot, frozen: history != nil)
    let voices: [Voice?] = contacts.isEmpty ? [nil] : try contacts.map { try BlessengerPolicy.capturedVoice($0, state: snapshot) }
    if let prefix {
      guard let caller, prefix.callID == caller.callID, captured.attachments == [prefix.captureID],
        prefix.profile == profile, prefix.contacts == contacts,
        (prefix.history?.messages ?? []) == contextHistory,
        (prefix.history?.instructions ?? "") == (history?.instructions ?? ""),
        prefix.history == nil || prefix.history?.id == history?.id else {
        throw BoomError.stale("The case changed while its caller audio was being prepared. The admitted audio is retained.")
      }
    }
    try profile.requireBinding(for: history, caller: caller != nil)
    let runner = try await model(for: profile); try flag.check()
    let resolvedProfile = try profile.resolvingModel(path: runner.source.path, identity: runner.identity)
    let useMTP = profile.useMTP ?? (caller != nil)
    if useMTP { _ = try await runner.prepareMTP(); try flag.check() }
    let shouldSpeak = (caller != nil || snapshot.blessenger!.readReplies) && voices.count == 1
    var speechVoice: BlessengerSpeechVoice?
    if shouldSpeak {
      audio.stop(); try await audio.join()
      let selectedVoice = caller?.speech ?? contacts.first.flatMap { snapshot.blessenger!.speechVoices[$0.id] } ?? snapshot.blessenger!.defaultSpeech
      speechVoice = try await audio.prepare(selectedVoice); try flag.check()
    }
    let projectedHistory = BlessengerMedia.deliveredHistory(contextHistory, product: snapshot.blessenger!)
    let chatID = history?.id ?? UUID()
    let fitted: (plans: [ConsultationPlan], history: [ChatMessage], context: String)
    let payloads: [WritingMediaData], sourceRefs: [SourceReference]
    let contextWindow: BlessengerHistoryWindow?
    if let prefix {
      // The prefix owner's selected history and already prepared native state
      // remain authoritative. Decode only the new final original, never replay
      // the completed historical prefill or reselect against mutable UI state.
      let current = try await BlessengerMedia.prepare(captured.attachments, state: snapshot, store: store, supportsRawAudio: runner.supportsRawAudio, flag: flag)
      guard current.context.isEmpty else { throw BoomError.stale("The final caller representation changed its prompt text.") }
      fitted = (prefix.plans, prefix.fittedHistory, "")
      payloads = prefix.historical.prepared.payloads + current.payloads
      sourceRefs = prefix.historical.prepared.sources + current.sources
      contextWindow = prefix.historical.window
    } else {
      let admitted = try await BlessengerContext.prepare(history: projectedHistory,
        current: captured.attachments, text: captured.text, state: snapshot, store: store, supportsRawAudio: runner.supportsRawAudio, flag: flag)
      let round = try await BlessengerContext.fit(admitted, voices: voices, instructions: history?.instructions ?? "",
        request: captured.text, routing: contacts.map(\.handle), reserves: voices.map { _ in profile.maximumTokens },
        runner: runner, owner: PromptCacheOwner(namespace: namespace, entity: chatID, route: .consultation), flag: flag)
      fitted = (round.plans, round.capture.history, round.capture.current.context)
      payloads = round.capture.payloads
      sourceRefs = round.capture.prior.prepared.sources + round.capture.current.sources
      contextWindow = round.capture.window
    }
    try flag.check()
    let admittedIDs = Set(fitted.plans.flatMap { $0.placedMediaIDs })
    let admittedPayloads = payloads.filter { admittedIDs.contains($0.reference.id) }
    let admittedSources = sourceRefs.reduce(into: [SourceReference]()) { result, source in
      if !result.contains(source) { result.append(source) }
    }
    let ids = voices.map { _ in UUID() }
    let receipts = fitted.plans.enumerated().map { index, plan in
      ConsultationReceipt(operationID: flag.operationID, seed: UInt64.random(in: .min ... .max), state: .pending,
        model: runner.identity, voice: voices[index], plan: plan, sources: admittedSources,
        promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [], stopReason: "pending", elapsedSeconds: 0,
        generationPolicy: runner.generationPolicy, attemptID: UUID(), responseID: ids[index], media: admittedPayloads.map(\.reference), contextWindow: contextWindow)
    }
    let turn = BlessengerPreparedTurn(chatID: chatID, draft: captured, history: history, contacts: contacts,
      profile: profile, sourceDigests: admittedSources, context: fitted.context, responseIDs: ids,
      receipts: receipts, voices: voices, outputLimit: profile.maximumTokens, caller: caller, speech: speechVoice, previousQuestionID: previousQuestionID, resolvedProfile: resolvedProfile)
    try flag.check(); caller?.trace?.once("turn.admissionStarted")
    let next = try await store.blessengerAdmit(turn, flag: flag); accept(next)
    caller?.trace?.once("turn.admitted")
    if caller == nil, replay == nil, state.selectedChat == chatID, capturedSelection == history?.id,
      draft.id == captured.id, draft.version == captured.version {
      draft = next.blessenger!.draft(for: chatID); storedDraftVersion = draft.version; composerFocus += 1
    }
    if caller != nil, state.selectedChat == chatID, draft.id != chatID {
      // First audio admission opens the real conversation, without consuming or
      // altering the durable New Message draft which remains in its own slot.
      draft = next.blessenger!.draft(for: chatID); storedDraftVersion = draft.version
    }
    active.insert(chatID); preparing = false; admitting = nil
    defer { active.remove(chatID) }
    // Separate answers have the same captured history, not earlier peers' output.
    // Native admission may cohort compatible text rows; each keeps its own flag.
    await withTaskGroup(of: Void.self) { group in
      for index in ids.indices {
        let child = CancellationFlag(); childFlags[ids[index]] = child
        let registration = flag.onCancel { child.cancel() }
        group.addTask { [weak self] in
          await self?.runResponse(receipts[index], id: ids[index], chatID: chatID, media: admittedPayloads,
            runner: runner, profile: profile, flag: child, voice: speechVoice, useMTP: useMTP, callerTrace: caller?.trace, audioPrefixID: prefix?.captureID)
          flag.removeCancellationHandler(registration)
        }
      }
      await group.waitForAll()
    }
  }
  private func runResponse(_ input: ConsultationReceipt, id: UUID, chatID: UUID, media: [WritingMediaData],
    runner: MLXGemmaRunner, profile: BlessengerProfile, flag: CancellationFlag, voice: BlessengerSpeechVoice?, useMTP: Bool, callerTrace: BlessengerTrace? = nil, audioPrefixID: UUID? = nil) async {
    var receipt = input
    let identity = GenerationIdentity(kind: .consultation, operationID: input.operationID, recordID: id,
      attemptID: input.attemptID!, model: input.model, seed: input.seed,
      requestDigest: Digest.sha256(input.plan.rawPrompt), maxTokens: profile.maximumTokens, generationPolicy: input.generationPolicy)
    let (updates, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var audioFailure: String?
    let trace = BlessengerTrace(operation: input.attemptID!)
    if let callerTrace { for event in callerTrace.snapshot().events { trace.record(event.name, at: event.uptime) } }
    trace.once("generation.admission")
    if let voice {
      do { try audio.begin(id, voice: voice, attempt: input.attemptID!, seed: input.seed, cancellation: flag, trace: trace) }
      catch { audioFailure = error.localizedDescription; flag.cancel() }
    }
    let output = Task { [weak self] in
      for await text in updates {
        guard let self, !flag.isCancelled else { continue }
        if !text.isEmpty { trace.once("text.firstVisible") }
        self.liveText[id] = text
        if let voice {
          do { try self.audio.append(text, responseID: id, voice: voice) }
          catch { audioFailure = error.localizedDescription; flag.cancel(); self.report(error) }
        }
      }
    }
    var text = ""
    do {
      let store = store
      let checkpoint: @Sendable (GenerationProgress, String?, Int?) async throws -> Void = { progress, stop, token in
        try await store.checkpoint(progress, identity: identity, stopReason: stop, stopTokenID: token)
      }
      let result: MLXGemmaRunner.Output
      if let audioPrefixID {
        trace.once("audio.prefix.finalization")
        result = try await runner.runPreparedAudio(id: audioPrefixID, plan: input.plan, media: media,
          maxTokens: profile.maximumTokens, seed: input.seed, settings: ProductCore.sampling(profile.sampling),
          useMTP: useMTP, flag: flag, onCheckpoint: checkpoint, onText: { continuation.yield($0) })
      } else if useMTP {
        result = try await runner.runMTP(plan: input.plan, media: media, maxTokens: profile.maximumTokens,
          seed: input.seed, settings: ProductCore.sampling(profile.sampling), flag: flag,
          onCheckpoint: checkpoint, onText: { continuation.yield($0) })
      } else {
        result = try await runner.run(plan: input.plan, images: [], media: media,
          maxTokens: profile.maximumTokens, seed: input.seed, settings: ProductCore.sampling(profile.sampling), flag: flag,
          cacheOwner: PromptCacheOwner(namespace: namespace, entity: chatID, route: .consultation),
          onCheckpoint: checkpoint, onText: { continuation.yield($0) })
      }
      trace.once("generation.completed")
      receipt.mtp = result.mtp
      text = result.text; receipt.promptDigest = result.promptDigest; receipt.tokenIDs = result.tokenIDs
      receipt.stopReason = result.stopReason; receipt.stopTokenID = result.stopTokenID
      receipt.firstTokenSeconds = result.firstTokenSeconds; receipt.elapsedSeconds = result.elapsedSeconds
      receipt.executionOrigin = result.executionOrigin
      receipt.state = flag.isCancelled ? .cancelled : (text.isEmpty ? .failed : .complete)
      if text.isEmpty { receipt.failure = "The model returned no visible response." }
    } catch {
      if let journal = try? await store.generationCheckpoint(identity: identity) { receipt.retain(journal); text = journal.progress.text }
      receipt.state = error is CancellationError || flag.isCancelled ? .cancelled : .failed
      receipt.stopReason = receipt.state == .cancelled ? "cancelled" : "failed"; receipt.failure = error.localizedDescription
    }
    continuation.finish(); await output.value
    var delivery: BlessengerSpeechResult?
    if let voice {
      if receipt.state == .complete {
        do { try audio.append(text, responseID: id, voice: voice, finished: true) }
        catch { audioFailure = error.localizedDescription; audio.stop(responseID: id) }
      } else { audio.stop(responseID: id) }
      do { delivery = try await audio.result(for: id, attempt: input.attemptID!) }
      catch { if audioFailure == nil { audioFailure = error.localizedDescription } }
      if let failure = delivery?.failure ?? audioFailure {
        receipt.state = .failed; receipt.failure = failure; receipt.stopReason = "speech_failed"
      } else if delivery?.interrupted == true || flag.isCancelled {
        receipt.state = .cancelled; receipt.failure = "Speech was interrupted."; receipt.stopReason = "interrupted"
      } else if delivery?.samples.isEmpty != false {
        receipt.state = .failed; receipt.failure = "No playable speech was produced."; receipt.stopReason = "speech_empty"
      }
    }
    do { accept(try await store.blessengerFinish(receipt, messageID: id, text: text, speech: delivery)) }
    catch {
      // A source revocation prohibits success; it must not leave a pending row.
      // Persistence uncertainty still fails closed in the store transaction.
      receipt.state = .failed; receipt.failure = error.localizedDescription; receipt.stopReason = "publication_failed"
      do { accept(try await store.blessengerFinish(receipt, messageID: id, text: text)) }
      catch { report(error) }
    }
    liveText.removeValue(forKey: id); childFlags.removeValue(forKey: id)
  }
  func stop(_ messageID: UUID? = nil) {
    if messageID == nil { speechActionFlag?.cancel(); audio.stop(); for flag in setupFlags.values { flag.cancel() } }
    if let messageID { childFlags[messageID]?.cancel(); audio.stop(responseID: messageID); return }
    if let admitting { flags[admitting]?.cancel(); operations[admitting]?.cancel() }
    if let chatID = state.selectedChat {
      for (id, attempt) in product.attempts where attempt.conversationID == chatID { childFlags[id]?.cancel(); audio.stop(responseID: id) }
    }
  }
  func readAloud(_ message: ChatMessage) {
    guard mediaReview == nil else { return }
    guard message.state != .pending, !message.text.isEmpty, !callInProgress, !preparing, active.isEmpty else { return }
    let flag = CancellationFlag(); speechActionFlag?.cancel(); speechActionFlag = flag
    let sourceDigest = Digest.sha256(message.text), id = message.id
    let voice = message.speaker?.voiceID.flatMap { product.speechVoices[$0] } ?? product.defaultSpeech
    launch {
      defer { if self.speechActionFlag === flag { self.speechActionFlag = nil } }
      self.audio.stop(); try await self.audio.join(); try flag.check()
      let selected = try await self.audio.prepare(voice)
      try Task.checkCancellation(); try flag.check()
      guard !self.closing, self.state.chats.contains(where: { $0.messages.contains(where: { $0.id == id && Digest.sha256($0.text) == sourceDigest }) }) else {
        throw BoomError.stale("The selected message changed before playback.")
      }
      let attempt = UUID()
      try self.audio.begin(id, voice: selected, attempt: attempt, seed: UInt64.random(in: .min ... .max), cancellation: flag)
      do { try self.audio.append(message.text, responseID: id, voice: selected, finished: true) }
      catch { self.audio.stop(responseID: id); try await self.audio.join(); _ = try? await self.audio.result(for: id, attempt: attempt); throw error }
      let result = try await withTaskCancellationHandler {
        try await self.audio.result(for: id, attempt: attempt)
      } onCancel: { flag.cancel() }
      if let failure = result.failure { throw BoomError.unavailable(failure) }
    }
  }
  var canCall: Bool {
    mediaReview == nil && !closed && !closing && !navigating && !preparing && !loading && !callInProgress
      && active.isEmpty && !templateSelected && recipients.count <= 1 && draft.recipientQuery.isEmpty && noteState == .idle && !hasUnstoredVoiceNote
  }
  /// Hang-up invalidates the lifetime synchronously. The same action owns
  /// startup, capture, response workers and teardown until all have joined.
  /// In particular there is no gap before a call object or store route exists.
  func stopCall() {
    guard callInProgress else { return }
    callPhase = .ending; callReady = false; callMuted = false
    callLifetime?.cancel(); callOperation?.cancel(); call?.stop()
  }
  func endCall() async {
    let lifetime = callLifetime, task = callTask
    stopCall()
    if let task { await task.value }
    // A parent may cancel the tracked action before its body ever begins.
    // The generic action owner still joins; there is no call route to release.
    if callLifetime === lifetime {
      call = nil; callID = nil; callLifetime = nil; callTask = nil
      callPhase = .idle; callReady = false; callMuted = false
    }
  }
  private func prepareCallerPrefix(_ chunk: BlessengerAudioSlice, callID: UUID,
    lifetime: CancellationFlag, flag: CancellationFlag) async throws {
    try lifetime.check(); try flag.check()
    guard self.callID == callID, let runner else { throw CancellationError() }
    do {
      if audioPreparation?.captureID != chunk.captureID {
        guard chunk.offset == 0 else { throw BoomError.stale("A new caller prefix did not begin at its first sample.") }
        audioPreparation = nil
        await runner.discardAudioPrefix(); try flag.check()
        let (snapshot, route) = try await store.blessengerCallSnapshot(callID)
        let history = snapshot.chats.first { $0.id == route.conversationID }
        let profile = route.profile
        try profile.requireBinding(for: history, caller: true)
        guard profile.modelIdentity == runner.identity else { throw BoomError.stale("The call's model binding changed.") }
        let voices: [Voice?] = route.recipients.isEmpty ? [nil]
          : try route.recipients.map { try BlessengerPolicy.capturedVoice($0, state: snapshot) }
        let projected = BlessengerMedia.deliveredHistory(history?.messages ?? [], product: snapshot.blessenger!)
        // Only the placement of this provisional row is compiled. It is neither
        // persisted nor evaluated. Final admitted PCM supplies its real digest.
        let stub = try BlessengerWave.encode([Float](repeating: 0, count: 640), rate: 16_000)
        let provisional = WritingMediaData(reference: WritingMediaReference(id: chunk.captureID,
          name: "Caller audio.wav", rootDigest: Digest.sha256(stub), kind: "audio"), bytes: stub,
          samples: [Float](repeating: 0, count: 640))
        let trace = BlessengerTrace(); trace.once("audio.prefix.planning")
        let admitted = try await BlessengerContext.prepare(history: projected, current: [chunk.captureID], text: "",
          state: snapshot, store: store, supportsRawAudio: runner.supportsRawAudio, flag: flag, provisional: provisional)
        let round = try await BlessengerContext.fit(admitted, voices: voices, instructions: history?.instructions ?? "",
          request: "", routing: route.recipients.map(\.handle),
          reserves: [profile.maximumTokens + CausalAudioPrefix.maximumSamples / 640 - 1], runner: runner,
          owner: PromptCacheOwner(namespace: namespace, entity: history?.id ?? callID, route: .consultation), flag: flag)
        let historical = round.capture.prior
        let payloads = round.capture.payloads
        let fitted = (plans: round.plans, history: round.capture.history)
        guard fitted.plans.count == 1 else { throw BoomError.invalid("A live call requires exactly one prepared response.") }
        let selected = Set(fitted.plans[0].placedMediaIDs)
        try lifetime.check(); try flag.check()
        trace.once("audio.prefix.started")
        let observation = try await runner.beginAudioPrefix(id: chunk.captureID, plan: fitted.plans[0],
          media: payloads.filter { selected.contains($0.reference.id) }, maxTokens: profile.maximumTokens, flag: flag)
        try lifetime.check(); try flag.check(); trace.once("audio.prefix.firstPrepared")
        audioPreparation = AudioPreparation(captureID: chunk.captureID, callID: callID, history: history,
          profile: profile, contacts: route.recipients, historical: historical, fittedHistory: fitted.history,
          plans: fitted.plans, trace: trace, observation: observation, lastPrepared: ProcessInfo.processInfo.systemUptime)
      }
      guard var prepared = audioPreparation, prepared.captureID == chunk.captureID, prepared.callID == callID,
        prepared.observation.preparedSamples == chunk.offset else { throw BoomError.stale("A caller prefix was superseded.") }
      let observed = try await runner.appendAudioPrefix(chunk, maxTokens: prepared.profile.maximumTokens, flag: flag)
      try lifetime.check(); try flag.check()
      guard audioPreparation?.captureID == chunk.captureID else { throw CancellationError() }
      prepared.observation = observed; prepared.lastPrepared = ProcessInfo.processInfo.systemUptime
      audioPreparation = prepared
    } catch {
      await runner.discardAudioPrefix(); audioPreparation = nil; throw error
    }
  }
  func toggleCall() {
    if callInProgress { stopCall(); return }
    guard canCall else { return }
    let selection = state.selectedChat, capturedDraft = draft
    let lifetime = CancellationFlag(); callLifetime = lifetime
    inputCompletion.invalidateGhost(); callPhase = .preparing
    callTask = launch {
      defer {
        if self.callLifetime === lifetime {
          self.call = nil; self.callID = nil; self.callLifetime = nil; self.callTask = nil
          self.callPhase = .idle; self.callReady = false; self.callMuted = false
        }
      }
      try lifetime.check()
      await self.inputCompletion.join(); try lifetime.check()
      try await self.flushDraft(); try lifetime.check()
      guard self.state.selectedChat == selection, self.draft.id == capturedDraft.id,
        self.draft.version == capturedDraft.version else {
        throw BoomError.stale("The call destination changed during preparation. Nothing was called.")
      }
      let route = try await self.store.blessengerBeginCall(selection: selection,
        expectedDraftVersion: capturedDraft.version)
      self.callID = route.id
      let call = BlessengerCall(output: self.audio, requestMicrophone: self.requestMicrophone)
      self.call = call
      call.onReady = { [weak self] in
        if self?.callID == route.id, !lifetime.isCancelled { self?.callReady = true }
      }
      call.onIssue = { [weak self] issue in
        if self?.callID == route.id, !lifetime.isCancelled { self?.callIssue = issue }
      }
      call.onEnded = { [weak self] failure in
        guard let self, self.callID == route.id else { return }
        self.callPhase = .ending; self.callReady = false; self.callMuted = false
        if let failure, !lifetime.isCancelled { self.failure = failure }
      }
      call.onStart = { [weak self] in
        guard let self, self.callID == route.id, !lifetime.isCancelled else { throw CancellationError() }
        try route.profile.requireBinding(for: self.state.chats.first { $0.id == route.conversationID })
        let runner = try await self.model(for: route.profile)
        let bound = try route.profile.resolvingModel(path: runner.source.path, identity: runner.identity)
        try lifetime.check(); try await self.store.blessengerBindCall(route.id, resolved: bound)
        try lifetime.check()
        guard runner.supportsRawAudio else { throw BoomError.unavailable("This model cannot receive caller audio.") }
        if route.profile.useMTP != false { _ = try await runner.prepareMTP() }
        try Task.checkCancellation(); try lifetime.check()
        _ = try await self.audio.prepare(route.speech)
        try Task.checkCancellation(); try lifetime.check()
      }
      call.onInterrupt = { [weak self] in self?.callOperation?.cancel() }
      call.onPrefix = { [weak self] chunk, flag in
        guard let self else { throw CancellationError() }
        try await self.prepareCallerPrefix(chunk, callID: route.id, lifetime: lifetime, flag: flag)
      }
      call.onUtterance = { [weak self] clip, _, epoch, flag in
        guard let self, self.callID == route.id else { throw BoomError.stale("An admitted caller clip lost its still-owned route.") }
        let prepared = self.audioPreparation?.captureID == clip.captureID ? self.audioPreparation : nil
        let trace = prepared?.trace ?? BlessengerTrace()
        if let prepared { trace.record("audio.prefix.lastPrepared", at: prepared.lastPrepared) }
        trace.record(clip.nativeInputClock ? "caller.voicedPacketEnd.native" : "caller.voicedPacketEnd.deliveryEstimate", at: clip.speechEndedUptime)
        if let time = clip.deliveredUptime { trace.record("capture.finalVoicedPacketDelivered", at: time) }
        trace.record("caller.turnAdmitted." + clip.decision, at: clip.admittedUptime)
        self.callOperation = flag
        defer { if self.callOperation === flag { self.callOperation = nil } }
        let imported = try await detachedWork {
          try AttachmentProcessor.inspect(name: "Caller audio.wav", data: clip.wav(), id: clip.captureID)
        }
        // Captured authored audio is durable before cancellation can suppress
        // its model response. The joining call still owns this exact route.
        var turn = try await self.store.blessengerCallerTurn(imported, callID: route.id, epoch: epoch, flag: CancellationFlag())
        turn.trace = trace
        self.accept(turn.snapshot)
        if self.state.selectedChat == turn.conversationID, self.draft.id != turn.conversationID {
          self.draft = turn.snapshot.blessenger!.draft(for: turn.conversationID); self.storedDraftVersion = self.draft.version
        }
        do {
          try lifetime.check(); try flag.check(); try await self.performSend(flag: flag, caller: turn, prefix: prepared)
        } catch {
          await self.runner?.discardAudioPrefix(); self.audioPreparation = nil; throw error
        }
        await self.runner?.discardAudioPrefix(); self.audioPreparation = nil
      }
      do {
        try lifetime.check()
        try await withTaskCancellationHandler {
          try await call.start(cancellation: lifetime)
          try lifetime.check()
          guard self.call === call, !self.closing else { throw CancellationError() }
          self.callPhase = call.active ? .active : .ending
          await call.waitUntilEnded()
        } onCancel: { lifetime.cancel() }
      } catch {
        call.stop(); await call.join(); await self.runner?.discardAudioPrefix(); self.audioPreparation = nil
        await self.store.blessengerEndCall(route.id)
        throw error
      }
      call.stop(); await call.join(); await self.runner?.discardAudioPrefix(); self.audioPreparation = nil
        await self.store.blessengerEndCall(route.id)
    }
  }
  var completionContext: BlessengerCompletion.Context {
    BlessengerCompletion.Context(draftID: draft.id, chatVersion: selected?.contentVersion,
      profile: product.addresses[draft.id]?.profile ?? product.defaultProfile, recipients: recipients,
      attachments: draft.attachments.compactMap { id in state.attachments.first { $0.id == id }?.reference })
  }
  var completionAvailable: Bool {
    mediaReview == nil && state.autocomplete && !closed && !closing && !navigating && !loading && !preparing && active.isEmpty
      && !callInProgress && noteState == .idle && !hasUnstoredVoiceNote && !templateSelected && runner != nil
      && runnerPath == ((product.addresses[draft.id]?.profile ?? product.defaultProfile).modelPath ?? ModelPacks.cached(.consultation)?.path)
      && runner?.identity == (product.addresses[draft.id]?.profile ?? product.defaultProfile).modelIdentity
  }
  func inputSuggestions(document: DocumentSnapshot, caret: Int, context: BlessengerCompletion.Context,
    count: Int, flag: CancellationFlag, publish: @escaping @Sendable (String) -> Void) async throws -> [String] {
    guard completionAvailable, completionContext == context, let runner, (1...3).contains(count) else { throw CancellationError() }
    let snapshot = state, chat = selected, profile = context.profile
    let projected = BlessengerMedia.deliveredHistory(chat?.messages ?? [], product: snapshot.blessenger!)
    let selected = try await BlessengerContext.prepare(history: projected, current: draft.attachments,
      text: document.text, state: snapshot, store: store, supportsRawAudio: runner.supportsRawAudio, flag: flag)
    let current = selected.current, prior = selected.prior, history = selected.history, payloads = selected.payloads
    let compiled = try await detachedWork {
      func links(_ ids: [UUID]) -> String { ids.map { "[Attachment: media](boom-attachment:\($0.uuidString))" }.joined(separator: "\n") }
      let turns = history.map { message in
        PromptTurn(role: message.role.rawValue,
          text: [message.context, links(prior.occurrences[message.id] ?? []), message.text].filter { !$0.isEmpty }.joined(separator: "\n"),
          speaker: message.speaker ?? Speaker(name: message.role == .user ? "You" : "Blessenger"))
      }
      let raw = try ProductCore.inputContext(instructions: [chat?.instructions ?? "", current.context, links(current.payloads.map { $0.reference.id })].joined(separator: "\n"),
        history: turns, speaker: "You", text: document.text, caret: caret)
      return try RawWritingInput.compiled(raw, media: payloads.map(\.reference))
    }
    let ordered = try compiled.media.map { reference in
      guard let item = payloads.first(where: { $0.reference == reference }) else { throw BoomError.stale("Completion media changed.") }
      return item
    }
    try flag.check()
    var values: [String] = []
    for _ in 0..<count {
      guard completionAvailable, completionContext == context else { throw CancellationError() }
      let result = try await runner.run(rawPrompt: compiled.prompt, media: ordered, maxTokens: 64,
        settings: ProductCore.sampling(profile.sampling), seed: UInt64.random(in: .min ... .max), flag: flag, background: true,
        cacheOwner: PromptCacheOwner(namespace: namespace, entity: context.draftID, route: .inputCompletion), onText: publish)
      try flag.check(); values.append(result.text)
    }
    return values
  }
  func toggleVoiceNote() {
    guard !navigating, !callInProgress, !closing, !hasUnstoredVoiceNote else { return }
    switch noteState {
    case .idle:
      guard !preparing, active.isEmpty, !templateSelected else { return }
      noteState = .preparing
      launch {
        do { try await self.voiceNote.start(.recording); try Task.checkCancellation(); self.noteState = .recording }
        catch { self.voiceNote.cancel(); self.noteState = .idle; throw error }
      }
    case .recording:
      let destination = draft.id
      noteState = .stopping
      launch {
        defer { self.noteState = .idle }
        let capture = try await self.voiceNote.stop(); try Task.checkCancellation()
        guard self.draft.id == destination else { throw BoomError.stale("The voice note's destination changed.") }
        guard case .audio(let data) = capture else { throw BoomError.invalid("Recording returned a transcript instead of original audio.") }
        // Retention is an attachment operation, not a Send. The ordinary draft
        // provides review, removal, persistence, and failed-send recovery.
        self.unstoredVoiceNote = (destination, data); self.hasUnstoredVoiceNote = true
        if await self.importInputs([.bytes(name: "Voice note.wav", data: data)]) {
          self.unstoredVoiceNote = nil; self.hasUnstoredVoiceNote = false
          if let id = self.draft.attachments.last { self.preview(id) }
        }
      }
    case .preparing, .stopping: break
    }
  }
  func cancelVoiceNote() { voiceNote.cancel(); noteState = .idle }
  func retryVoiceNote() {
    guard let note = unstoredVoiceNote else { return }
    launch {
      guard self.draft.id == note.draftID else { throw BoomError.stale("Return to the recording's original draft before saving it.") }
      if await self.importInputs([.bytes(name: "Voice note.wav", data: note.bytes)]) {
        self.unstoredVoiceNote = nil; self.hasUnstoredVoiceNote = false
      }
    }
  }
  func discardUnstoredVoiceNote() { unstoredVoiceNote = nil; hasUnstoredVoiceNote = false }
  func replayAudio(_ id: UUID) {
    guard mediaReview == nil else { return }
    guard !callInProgress, active.isEmpty, let record = product.audio[id],
      let original = state.attachments.first(where: { $0.id == record.attachmentID }) else { return }
    launch {
      let bytes = try await detachedWork { try self.store.vault.get(.attachment, id: record.attachmentID, limit: 67_108_864) }
      guard Digest.sha256(bytes) == original.rootDigest, self.product.audio[id] == record else { throw BoomError.stale("The retained audio changed.") }
      let pcm = try await detachedWork { try BlessengerWave.decode(bytes) }
      guard pcm.rate == record.sampleRate, pcm.samples.count == record.frames else { throw BoomError.invalid("The retained audio geometry changed.") }
      let flag = CancellationFlag()
      try await withTaskCancellationHandler {
        try await self.audio.replay(pcm.samples, rate: pcm.rate, messageID: id, voice: record.voice, flag: flag)
      } onCancel: { flag.cancel() }
    }
  }
  func clearModel() async {
    guard active.isEmpty, !preparing, !callInProgress, !loading else { return }
    guard let cached = ModelPacks.cached(.consultation) else {
      report(BoomError.unavailable("No local cached model is available. The current binding was retained.")); return
    }
    // This Settings command deliberately rebinds; nil is not a request to keep
    // consulting through whichever model happened to be loaded previously.
    await chooseModel(cached)
  }
  func setProfile(sampling: SamplingProfile? = nil, mtp: Bool?? = nil) async {
    guard !callInProgress else { return }
    let id = state.selectedChat
    await change { _, product in
      var profile = id.flatMap { product.addresses[$0]?.profile } ?? product.defaultProfile
      if let sampling { profile.sampling = sampling }
      if let mtp { profile.useMTP = mtp }
      profile.id = UUID(); try BlessengerState.validate(profile)
      if let id, var address = product.addresses[id] { address.profile = profile; product.addresses[id] = address }
      else { product.defaultProfile = profile }
    }
  }
  var effectiveProfile: BlessengerProfile { product.addresses[draft.id]?.profile ?? product.defaultProfile }
  var hasDraftFailure: Bool { draftFailure != nil }
  func setTheme(_ value: String) {
    guard ["system", "light", "dark"].contains(value) else { return }
    launch { await self.change { state, _ in state.theme = value }
      NSApp.appearance = self.state.theme == "system" ? nil : NSAppearance(named: self.state.theme == "dark" ? .darkAqua : .aqua)
    }
  }
  func setAutocomplete(_ value: Bool) {
    if !value { inputCompletion.invalidateGhost() }
    launch { await self.change { state, _ in state.autocomplete = value } }
  }
  func recoverDraft() {
    guard !navigating, active.isEmpty, !preparing, !callInProgress else { return }
    let authored = draft, previous = storedDraftVersion
    launch {
      self.navigating = true; defer { self.navigating = false }
      // A failed physical replacement can already be on disk. Reload the actual
      // current record, then compare identities before writing any authored bytes.
      var recovered = try await self.store.openBlessenger(catalog: self.catalog)
      let current = recovered.blessenger!.draft(for: authored.id == BlessengerDraft.unsentID ? nil : authored.id)
      if current != authored {
        guard current.version == previous else { throw BoomError.stale("The stored draft changed. Your unsaved text remains in the composer; it was not overwritten.") }
        recovered = try await self.store.blessengerSaveDraft(authored, expectedVersion: current.version)
      }
      self.storedDraftVersion = authored.version; self.draftFailure = nil
      self.accept(recovered); self.failure = nil
    }
  }
  func setCallMuted(_ value: Bool) { call?.setMuted(value); callMuted = value }
  func submitCallTurn() { call?.submitPausedTurn() }
  func runSetup(_ work: @escaping @Sendable (CancellationFlag, @escaping @Sendable (String) -> Void) async throws -> Void) {
    guard !loading, active.isEmpty, !callInProgress, !closing else { return }
    loading = true
    launch {
      let flag = CancellationFlag(); self.setupFlags[flag.operationID] = flag
      defer { self.setupFlags.removeValue(forKey: flag.operationID); self.loading = false; self.setupProgress = nil }
      try await withTaskCancellationHandler {
        try await work(flag) { [weak self] message in
          Task { @MainActor in if self?.setupFlags[flag.operationID] != nil { self?.setupProgress = message } }
        }
      } onCancel: { flag.cancel() }
    }
  }
  func shutdown() async throws {
    guard !closed else { return }
    guard noteState == .idle, !hasUnstoredVoiceNote else {
      throw BoomError.unavailable("Finish and save, or explicitly discard, the recording before quitting.")
    }
    guard mediaReview?.dirty != true, mediaReview?.hasOwnedEdit != true else {
      throw BoomError.unavailable("Save or explicitly discard the transcript edits before quitting.")
    }
    closing = true; navigating = true
    defer { if !closed { closing = false; navigating = false } }
    // Revoke publication and unblock audio consumers BEFORE waiting for UI actions.
    // In particular Read Aloud itself is an owned action waiting for its producer.
    for action in actions.values { action.cancel() }
    for flag in setupFlags.values { flag.cancel() }
    for flag in flags.values { flag.cancel() }
    for operation in operations.values { operation.cancel() }
    for flag in childFlags.values { flag.cancel() }
    speechActionFlag?.cancel(); audio.stop(); voiceNote.cancel(); noteState = .idle
    if let review = mediaReview { await review.close(); mediaReview = nil }
    await endCall()
    searchTask?.cancel(); await inputCompletion.join()
    if actionCount > 0 { await withCheckedContinuation { actionWaiters.append($0) } }
    if let searchTask { await searchTask.value }
    for flag in flags.values { flag.cancel() }
    for operation in operations.values { operation.cancel() }
    for flag in childFlags.values { flag.cancel() }
    audio.stop()
    let pending = Array(operations.values)
    for task in pending { await task.value }
    try await flushDraft()
    try await audio.shutdown()
    if let runner { await runner.cancelAndJoin() }
    runner = nil
    try await store.releaseExclusiveWorkspace()
    closed = true
  }
}
