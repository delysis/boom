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
  @Published private(set) var isCalling = false
  @Published private(set) var callStarting = false
  private var call: BlessengerCall?
  private var callID: UUID?
  private var callOperation: CancellationFlag?
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
  func launch(_ action: @escaping @MainActor () async throws -> Void) {
    do { try beginAction() } catch { return }
    Task { defer { endAction() }; do { try await action() } catch { report(error) } }
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
    !closed && !closing && !navigating && !preparing && !loading && !isCalling && !callStarting && !templateSelected
      && !(selected.map { active.contains($0.id) } ?? false)
      && ((try? BlessengerPolicy.validate(draft).sendable) == true)
  }
  var title: String {
    if let selected { return selected.title }
    return draft.groupName ?? (draft.recipients.count == 1 ? draft.recipients[0].name : "New Message")
  }
  var hasReadyModel: Bool { runner != nil }

  init(store: WorkspaceStore, catalog: BlessengerCatalog, state: WorkspaceState, namespace: UUID) {
    self.store = store; self.catalog = catalog; self.state = state; self.namespace = namespace
    draft = state.blessenger!.draft(for: state.selectedChat)
    storedDraftVersion = draft.version
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
  func dismissFailure() { failure = nil }
  private func accept(_ next: WorkspaceState) {
    guard !closed, (next.blessenger?.generation ?? 0) >= product.generation else { return }
    state = next
  }
  func editText(_ text: String) {
    guard !closed, !navigating, !templateSelected, text.utf8.count <= 2_097_152,
      !draft.text.utf8.elementsEqual(text.utf8) else { return }
    draft.text = text; draft.version = UUID(); scheduleDraftSave()
  }
  func editGroupName(_ name: String) {
    guard !navigating, state.selectedChat == nil else { return }
    draft.groupName = name.isEmpty ? nil : name; draft.version = UUID(); scheduleDraftSave()
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
    guard !navigating, !closed else { return }
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
    if state.selectedChat != nil { await select(nil) }
    guard state.selectedChat == nil, !navigating else { return }
    do {
      var next = draft
      if !next.recipients.contains(where: { $0.id == contact.id }) { next.recipients.append(contact) }
      next.version = UUID(); _ = try BlessengerPolicy.validate(next)
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
  func importInputs(_ inputs: [AttachmentInput]) async {
    guard !navigating, !closed, !templateSelected else { return }
    do { try beginAction() } catch { return }
    navigating = true; defer { navigating = false; endAction() }
    do {
      try await flushDraft()
      guard inputs.count + draft.attachments.count <= 8 else { throw BoomError.budget("At most eight attachments may be sent together.") }
      for input in inputs {
        let imported = try await detachedWork { () throws -> AttachmentImport in
          switch input {
          case .file(let url):
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            return try AttachmentProcessor.inspect(name: url.lastPathComponent, data: AttachmentProcessor.readGranted(url))
          case .bytes(let name, let data): return try AttachmentProcessor.inspect(name: name, data: data)
          }
        }
        let next = try await store.blessengerImport(imported, draftID: draft.id, expectedVersion: storedDraftVersion)
        accept(next); draft = next.blessenger!.draft(for: state.selectedChat); storedDraftVersion = draft.version
      }
    } catch { report(error) }
  }
  func chooseModel(_ path: URL) async {
    guard !loading, !preparing, active.isEmpty, !closed else { return }
    do { try beginAction() } catch { return }
    loading = true; defer { loading = false; endAction() }
    do {
      try await flushDraft()
      _ = try await model(for: path.path)
      let chatID = state.selectedChat
      let next = try await store.blessengerTransaction { _, product in
        if let chatID, var address = product.addresses[chatID] {
          address.profile.modelPath = path.path; address.profile.id = UUID(); product.addresses[chatID] = address
        } else { product.defaultProfile.modelPath = path.path; product.defaultProfile.id = UUID() }
      }.0
      accept(next)
    } catch { report(error) }
  }
  private func model(for path: String?) async throws -> MLXGemmaRunner {
    let directory = path.map { URL(fileURLWithPath: $0) } ?? ModelPacks.cached(.consultation)
    guard let directory else { throw BoomError.unavailable("Choose or install a local consultation model in Settings.") }
    if let runner, runnerPath == directory.path { return runner }
    guard active.isEmpty else { throw BoomError.unavailable("Finish the current response before changing models.") }
    if let old = runner { await old.cancelAndJoin(); runner = nil; runnerPath = nil }
    let admission = try await detachedWork { try ModelPacks.admission(directory, purpose: .consultation) }
    let loaded = try await MLXGemmaRunner.load(admission: admission, cacheProtection: .ephemeral())
    runner = loaded; runnerPath = directory.path
    return loaded
  }
  func send() {
    guard canSend else { return }
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
  private func performSend(flag: CancellationFlag, caller: BlessengerCallerTurn? = nil) async throws {
    if caller == nil { try await flushDraft() }
    try flag.check()
    let captured = caller?.draft ?? draft
    let capturedSelection = caller.map { $0.conversationID } ?? state.selectedChat
    let snapshot: WorkspaceState
    if let caller { snapshot = caller.snapshot } else { snapshot = try await store.blessengerSnapshot() }
    let history = snapshot.chats.first { $0.id == capturedSelection }
    let profile = caller?.profile ?? snapshot.blessenger!.addresses[captured.id]?.profile ?? snapshot.blessenger!.defaultProfile
    var routed = captured
    if let address = snapshot.blessenger!.addresses[captured.id] { routed.recipients = address.recipients }
    let contacts = try BlessengerPolicy.resolve(host: history?.id, draft: routed, state: snapshot, frozen: history != nil)
    let voices: [Voice?] = contacts.isEmpty ? [nil] : try contacts.map { try BlessengerPolicy.capturedVoice($0, state: snapshot) }
    let runner = try await model(for: profile.modelPath); try flag.check()
    let media = try await BlessengerMedia.prepare(captured.attachments, state: snapshot, store: store, runner: runner, flag: flag)
    let chatID = history?.id ?? UUID()
    let fitted = try await runner.fittedRound(voices: voices, history: history?.messages ?? [],
      instructions: history?.instructions ?? "", context: media.context, request: captured.text,
      routing: contacts.map(\.handle), images: [], media: media.payloads,
      reserves: voices.map { _ in profile.maximumTokens }, flag: flag,
      cacheOwner: PromptCacheOwner(namespace: namespace, entity: chatID, route: .consultation),
      promptContract: .referenceHistoryV2, capturedSources: media.sources)
    try flag.check()
    let ids = voices.map { _ in UUID() }
    let receipts = fitted.plans.enumerated().map { index, plan in
      ConsultationReceipt(operationID: flag.operationID, seed: UInt64.random(in: .min ... .max), state: .pending,
        model: runner.identity, voice: voices[index], plan: plan, sources: media.sources,
        promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [], stopReason: "pending", elapsedSeconds: 0,
        generationPolicy: runner.generationPolicy, attemptID: UUID(), responseID: ids[index], media: media.payloads.map(\.reference))
    }
    let turn = BlessengerPreparedTurn(chatID: chatID, draft: captured, history: history, contacts: contacts,
      profile: profile, sourceDigests: media.sources, context: media.context, responseIDs: ids,
      receipts: receipts, voices: voices, outputLimit: profile.maximumTokens, caller: caller)
    let next = try await store.blessengerAdmit(turn); accept(next)
    if caller == nil, state.selectedChat == chatID, capturedSelection == history?.id,
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
    let shouldSpeak = (caller != nil || product.readReplies) && voices.count == 1
    if shouldSpeak { audio.stop(); try await audio.join() }
    // Separate answers have the same captured history, not earlier peers' output.
    // Native admission may cohort compatible text rows; each keeps its own flag.
    await withTaskGroup(of: Void.self) { group in
      for index in ids.indices {
        let child = CancellationFlag(); childFlags[ids[index]] = child
        let registration = flag.onCancel { child.cancel() }
        group.addTask { [weak self] in
          await self?.runResponse(receipts[index], id: ids[index], chatID: chatID, media: media.payloads,
            runner: runner, profile: profile, flag: child, speak: shouldSpeak)
          flag.removeCancellationHandler(registration)
        }
      }
      await group.waitForAll()
    }
  }
  private func runResponse(_ input: ConsultationReceipt, id: UUID, chatID: UUID, media: [WritingMediaData],
    runner: MLXGemmaRunner, profile: BlessengerProfile, flag: CancellationFlag, speak: Bool) async {
    var receipt = input
    let identity = GenerationIdentity(kind: .consultation, operationID: input.operationID, recordID: id,
      attemptID: input.attemptID!, model: input.model, seed: input.seed,
      requestDigest: Digest.sha256(input.plan.rawPrompt), maxTokens: profile.maximumTokens, generationPolicy: input.generationPolicy)
    let (updates, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let voice = input.voice.flatMap { product.speechVoices[$0.id] } ?? product.defaultSpeech
    let output = Task { [weak self] in
      for await text in updates {
        guard let self, !flag.isCancelled else { continue }
        self.liveText[id] = text
        if speak { do { try self.audio.append(text, responseID: id, voice: voice) } catch { self.report(error) } }
      }
    }
    var text = ""
    do {
      let store = store
      let result = try await runner.run(plan: input.plan, images: [], media: media,
        maxTokens: profile.maximumTokens, seed: input.seed, settings: ProductCore.sampling(profile.sampling), flag: flag,
        cacheOwner: PromptCacheOwner(namespace: namespace, entity: chatID, route: .consultation),
        onCheckpoint: { progress, stop, token in
          try await store.checkpoint(progress, identity: identity, stopReason: stop, stopTokenID: token)
        }, onText: { continuation.yield($0) })
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
    if receipt.state == .complete, speak {
      do { try audio.append(text, responseID: id, voice: voice, finished: true) } catch { report(error) }
    } else if speak { audio.stop(responseID: id) }
    do { accept(try await store.blessengerFinish(receipt, messageID: id, text: text)) } catch { report(error) }
    liveText.removeValue(forKey: id); childFlags.removeValue(forKey: id)
  }
  func stop(_ messageID: UUID? = nil) {
    if let messageID { childFlags[messageID]?.cancel(); audio.stop(responseID: messageID); return }
    if let admitting { flags[admitting]?.cancel(); operations[admitting]?.cancel() }
    if let chatID = state.selectedChat {
      for (id, attempt) in product.attempts where attempt.conversationID == chatID { childFlags[id]?.cancel(); audio.stop(responseID: id) }
    }
  }
  func readAloud(_ message: ChatMessage) {
    guard message.state != .pending, !message.text.isEmpty else { return }
    do {
      audio.stop()
      let voice = message.speaker?.voiceID.flatMap { product.speechVoices[$0] } ?? product.defaultSpeech
      try audio.append(message.text, responseID: message.id, voice: voice, finished: true)
    } catch { report(error) }
  }
  var canCall: Bool {
    !closed && !closing && !navigating && !preparing && !loading && !callStarting && !isCalling
      && active.isEmpty && !templateSelected && recipients.count <= 1
  }
  func toggleCall() {
    if isCalling || callStarting {
      call?.stop(); callOperation?.cancel(); isCalling = false
      let old = call, id = callID
      launch {
        if let id { await self.store.blessengerEndCall(id) }
        if let old { await old.join() }
        if self.call === old { self.call = nil; self.callID = nil; self.callStarting = false }
      }
      return
    }
    guard canCall else { return }
    callStarting = true
    launch {
      defer { self.callStarting = false }
      try await self.flushDraft()
      if let previous = self.call {
        previous.stop(); await previous.join()
        if let id = self.callID { await self.store.blessengerEndCall(id) }
        self.call = nil; self.callID = nil
      }
      let route = try await self.store.blessengerBeginCall(selection: self.state.selectedChat,
        expectedDraftVersion: self.storedDraftVersion)
      self.callID = route.id
      let call = BlessengerCall(output: self.audio)
      self.call = call
      call.onEnded = { [weak self] failure in
        guard let self, self.callID == route.id else { return }
        self.isCalling = false
        if let failure { self.failure = failure }
        Task { await self.store.blessengerEndCall(route.id) }
      }
      call.onStart = { [weak self] in
        guard let self, self.callID == route.id else { throw CancellationError() }
        let runner = try await self.model(for: route.profile.modelPath)
        guard runner.supportsRawAudio else { throw BoomError.unavailable("This model cannot receive caller audio.") }
      }
      call.onInterrupt = { [weak self] in self?.callOperation?.cancel() }
      call.onUtterance = { [weak self] clip, _, epoch in
        guard let self, self.callID == route.id else { throw CancellationError() }
        let flag = CancellationFlag(); self.callOperation = flag
        defer { if self.callOperation === flag { self.callOperation = nil } }
        let imported = try await detachedWork {
          try AttachmentProcessor.inspect(name: "Caller audio.wav", data: clip.wav())
        }
        try flag.check()
        let turn = try await self.store.blessengerCallerTurn(imported, callID: route.id, epoch: epoch, flag: flag)
        try flag.check(); try await self.performSend(flag: flag, caller: turn)
      }
      do {
        try await call.start()
        guard self.call === call, !self.closing else { throw CancellationError() }
        self.isCalling = call.active
      } catch {
        call.stop(); await call.join(); await self.store.blessengerEndCall(route.id)
        self.call = nil; self.callID = nil; throw error
      }
    }
  }
  func shutdown() async throws {
    guard !closed else { return }
    closing = true; navigating = true
    call?.stop(); callOperation?.cancel()
    if let callID { await store.blessengerEndCall(callID) }
    if let call { await call.join() }
    isCalling = false
    searchTask?.cancel()
    if actionCount > 0 { await withCheckedContinuation { actionWaiters.append($0) } }
    if let searchTask { await searchTask.value }
    for flag in flags.values { flag.cancel() }
    for operation in operations.values { operation.cancel() }
    for flag in childFlags.values { flag.cancel() }
    audio.stop()
    let pending = Array(operations.values)
    for task in pending { await task.value }
    try await flushDraft()
    try await audio.join()
    if let runner { await runner.cancelAndJoin() }
    runner = nil
    try await store.releaseExclusiveWorkspace()
    closed = true
  }
}
