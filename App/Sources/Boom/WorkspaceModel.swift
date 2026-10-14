import AppKit
import AVFoundation
import Combine
import BoomCore
import MLX
import Metal
import SwiftUI

struct StoredProposal: Codable, Identifiable, Sendable {
  let id: UUID
  let chatID: UUID
  let messageID: UUID
  let patch: DocumentPatch
  let document: DocumentSnapshot
  var capture: BoundedDocumentCapture? = nil
  let documents: [SourceReference]
  let attachments: [SourceReference]
  var status: String
  var appliedRevision: String? = nil
}

enum DocumentMergeConflict: Error { case changed }

struct ConsultationReplay {
  let request: String
  let voice: Voice?
  let attachmentIDs: [UUID]
  let previousAttemptID: UUID?
  let generationPolicy: ModelGenerationPolicy?
  let promptContract: ConsultationPromptContract
}

enum AttachmentDestination {
  case chat(id: UUID)
  case document(id: UUID, sessionID: UUID, arenaID: UUID, generation: UInt64, selectionEpoch: UInt64,
    range: NSRange, selection: PagedNativeNavigationSelection)
}
struct CompletionSegment {
  let accepted: String
  let remaining: String
  let whole: String
  let sources: [SourceReference]
}

private struct BoundedConsultationContext: Sendable {
  let captures: [BoundedDocumentCapture]
  let documents: [DocumentSnapshot]
  init(captures: [BoundedDocumentCapture]) {
    self.captures = captures
    documents = captures.map(\.modelSnapshot)
  }
  var sources: [SourceReference] { captures.map(\.source) }
  var promptSources: [SourceReference] {
    documents.map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }
  }
}

@MainActor final class WorkspaceModel: ObservableObject {
  enum InputPane: Equatable { case document, chat }
  @Published var state: WorkspaceState
  @Published private(set) var documentIndices: [DocumentIndex] = []
  @Published private(set) var pagedViewport: PagedDocumentViewport?
  @Published private(set) var pagedSelectedRecord: PagedDocumentRootRecord?
  private(set) var pagedEngine: PagedTextEngineAdapter?
  private(set) var pagedPublisher: PagedWorkspacePublisher?
  private var pagedBackend: PagedNativeStorageBackend?
  private(set) var pagedSession: PagedNativeSession?
  private(set) var pagedInput: PagedNativeInputOwner?
  private(set) var pagedCommands: PagedNativeUndoOwner?
  private var pagedImported: PagedTextCustodiedValue<PagedTextImportedRevision>?
  private var pagedInitialized: PagedTextCustodiedValue<PagedDocumentRootRecord>?
  private var pagedFirstFailure: Error?
  private var pagedTransition = false
  private var pagedShutdownRequested = false
  private var saveEntered = false
  private var explicitSaveRequested = false
  private var saveRequestID = UUID()
  private var saveTaskID: UUID?
  private var saveTaskWasEntered = false
  private var captureCache: [UUID: BoundedDocumentCapture] = [:]
  private var writingCapture: BoundedDocumentCapture?
  var completionSourceIdentity: String? {
    guard let session = pagedSession, pagedInput?.activeView?.inputBinding?.state == .active else { return nil }
    return session.sessionID.uuidString + "/" + session.arenaID.uuidString + "/" + String(session.generation)
  }
  private var consultationCaptures: [UUID: BoundedDocumentCapture] = [:]
  var usesPagedStorage: Bool { true }
  var selectedDocumentID: UUID? { state.selectedDocument }
  var selectedChatID: UUID? { state.selectedChat }
  var themeName: String { state.theme }
  var autocompleteEnabled: Bool { state.autocomplete }
  var hasSelectedDocument: Bool { pagedSelectedRecord != nil }
  private func preferredModel(_ purpose: String) -> String? { state.preferredModels?[purpose] }
  /// Complete small request captures only. The library uses documentIndices;
  /// a partial range is never returned as a whole DocumentSnapshot.
  var documents: [DocumentSnapshot] { captureCache.values.compactMap { $0.completeSnapshot } }
  @Published var selectedDocumentIDs: Set<UUID> = []
  @Published var selectedChatIDs: Set<UUID> = []
  @Published var composerFocusEpoch = 0
  @Published var draft = "" {
    didSet {
      draftVersion = UUID()
      retainComposerDraft()
    }
  }
  private(set) var draftVersion = UUID()
  @Published var mode: InteractionMode = .ask
  @Published var pendingAttachments: [UUID] = [] { didSet { if pendingAttachments != oldValue { retainComposerDraft() } } }
  @Published var isBusy = false
  @Published var status = "Install a consultation model to begin"
  @Published var errorMessage: String?
  @Published var composerIssue: String?
  @Published var streamingText = ""
  @Published var streamingChat: UUID?
  @Published var showingModels = false
  @Published var ghostText = ""
  @Published var ghostStamp: GhostStamp?
  @Published var modelReady = false
  @Published var consultationStyle: ConsultationStyle = .separate
  @Published var showingChatInstructions: UUID?
  @Published var editingChatMessage: UUID?
  @Published var authoredChatRole: Role? { didSet { if authoredChatRole != oldValue { retainComposerDraft() } } }
  @Published var samplingProfile: SamplingProfile = .standard
  @Published var candidates: CandidateBundle?
  @Published var showingCandidates = false
  @Published var writingIssue: String?
  @Published private(set) var savedExplorations: [SavedExploration] = []
  private var latestSavedCandidate: UUID?
  private var historyRequest: UUID?
  private var historyTask: Task<Void, Never>?
  private var speechSetupTask: Task<Void, Never>?
  private let speechOutput = VoiceInput()
  func speak(_ message: ChatMessage) {
    if message.state == .complete { speechOutput.speak(message.text) }
  }
  @Published var editingWritingExamples: WritingExamplesRequest?
  var openRestoredWorkspace: ((URL) -> Void)?
  @Published var writingExampleIDs: [UUID] = [] {
    didSet {
      if writingExampleIDs != oldValue {
        state.writingExampleIDs = writingExampleIDs
        scheduleSave()
      }
    }
  }
  private var composerOwner: ComposerOwner?
  var hasComposerOwner: Bool {
    guard let composerOwner else { return false }
    return composerOwner == selectedComposerOwner
  }
  private var restoringComposer = false
  let layout: ProductLayout
  @Published var librarySearch = "" { didSet { if oldValue != librarySearch { refreshSearch() } } }
  @Published private(set) var documentSearch: [UUID: DocumentSearchMatches] = [:]
  @Published private(set) var matchingDocumentIDs: Set<UUID> = []
  @Published private(set) var matchingChatIDs: Set<UUID> = []
  @Published private(set) var matchingVoiceIDs: Set<UUID> = []
  @Published private(set) var searchIssue: String?
  private var searchedQuery = ""
  private var searchEpoch: UInt64 = 0
  private var searchTask: Task<Void, Never>?
  private var visibleSearchTask: Task<Void, Never>?
  let store: WorkspaceStore
  let inferenceCacheNamespace = UUID()
  private var joinedRetentionEpoch = UUID()
  private var joinedRetentionClosed = false
  private var joinedRetentionGrants: [UUID: JoinedKVRetentionAuthorization] = [:]
  private(set) var mlxRunner: MLXGemmaRunner?
  private(set) var baseRunner: MLXGemmaRunner?
  private var modelDirectories: [ModelPurpose: URL] = [:]
  private var residentModelWeights: [ModelPurpose: UInt64] = [:]
  @Published private(set) var settingUpModels = false
  @Published private(set) var modelSetupIssue: String?
  @Published private(set) var modelChoices: [ModelSetupChoice] = []
  @Published private(set) var modelPickerIssue: String?
  private var modelPickerTask: Task<Void, Never>?
  @Published private(set) var writingUsesConsultation = false
  private var writingModelIdentity: String?
  private var writingGenerationPolicy: ModelGenerationPolicy?
  var selectedMLXRunner: MLXGemmaRunner? { mlxRunner }
  var completionRunner: MLXGemmaRunner? { baseRunner }
  func documentAttachmentDestination(id: UUID, range: NSRange) -> AttachmentDestination? {
    guard selectedDocumentID == id, let session = pagedSession, let input = pagedInput,
      let observation = try? input.observeSelection(), observation.range == range,
      let selection = try? input.currentDocumentSelection() else { return nil }
    return .document(id: id, sessionID: session.sessionID, arenaID: session.arenaID,
      generation: session.generation, selectionEpoch: observation.selectionEpoch, range: range, selection: selection)
  }
  private func chatAttachmentDestination() throws -> AttachmentDestination {
    guard !isBusy else { throw BoomError.unavailable("Finish the current action before attaching a file.") }
    if let id = state.selectedChat, state.chats.contains(where: { $0.id == id }) {
      return .chat(id: id)
    }
    retainComposerDraft()
    var next = state
    let chat = ChatRecord(attachedDocumentID: layout.isAuthor ? state.selectedDocument : nil)
    next.chats.append(chat)
    next.selectedChat = chat.id
    next.showChat = true
    scheduleSave()
    state = next
    transferDocumentDraftToChat()
    selectedChatIDs = [chat.id]
    compactPane = "chat"
    return .chat(id: chat.id)
  }
  func attachToCurrentChat(_ inputs: [AttachmentInput]) {
    composerIssue = nil
    do { attach(inputs, to: try chatAttachmentDestination()) }
    catch { report(error) }
  }
  func pasteImageIntoCurrentChat() {
    guard let input = AttachmentInput.readImage(.general) else {
      report(BoomError.unavailable("The clipboard has no image to attach."))
      return
    }
    attachToCurrentChat([input])
  }
  func chooseChatAttachmentFiles() {
    do { chooseAttachmentFiles(to: try chatAttachmentDestination()) }
    catch { report(error) }
  }
  func chooseDocumentAttachmentFiles() {
    guard let id = selectedDocumentID, let view = pagedInput?.activeView,
      let destination = documentAttachmentDestination(id: id, range: view.selectedRange()) else {
      report(BoomError.unavailable("Open a document before attaching a file to it.")); return
    }
    chooseAttachmentFiles(to: destination)
  }
  var canInfer: Bool { mlxRunner != nil || modelDirectories[.consultation] != nil }
  var inferenceName: String { canInfer ? "Gemma 4" : "No model" }
  var baseReady: Bool { baseRunner != nil || modelDirectories[.writing] != nil || (writingUsesConsultation && canInfer) }
  private var foreground: Task<Void, Never>?
  private var recordingAttachmentTask: Task<Void, Error>?
  private var activeFlag: CancellationFlag?
  private var activeID: UUID?
  private var ghostTask: Task<Void, Never>?
  private final class InputCompletionReference {
    weak var value: TextInputCompletion?
    init(_ value: TextInputCompletion) { self.value = value }
  }
  private var inputCompletions: [InputCompletionReference] = []
  var inputContextCache: (id: UUID, version: UUID, digest: String)?
  func registerInputCompletion(_ input: TextInputCompletion) {
    inputCompletions.removeAll { $0.value == nil }
    inputCompletions.append(InputCompletionReference(input))
  }
  private func cancelInputCompletions() {
    for input in inputCompletions { input.value?.invalidateGhost() }
  }
  func makeJoinedRetentionRequest(owner: PromptCacheOwner?, runner: MLXGemmaRunner,
    policy: ModelGenerationPolicy, operationID: UUID) throws -> JoinedKVRetentionRequest? {
    guard let owner, !joinedRetentionClosed, owner.namespace == inferenceCacheNamespace,
      joinedRetentionOwnerIsLive(owner),
      let binding = try runner.joinedRetentionBinding(owner: owner, workspaceEpoch: joinedRetentionEpoch,
        operationID: operationID, policy: policy) else { return nil }
    let auth = JoinedKVRetentionAuthorization(binding: binding)
    joinedRetentionGrants[auth.id] = auth
    return JoinedKVRetentionRequest(authorization: auth, checkpointIsDurable: true,
      authorizeAfterJoin: { [weak self] in
        guard let owner = self else { return false }
        return await owner.authorizeJoinedRetention(auth, runner: runner)
      })
  }
  func finishJoinedRetentionRequest(_ request: JoinedKVRetentionRequest?) {
    guard let auth = request?.authorization else { return }
    auth.revoke()
    if joinedRetentionGrants[auth.id] === auth { joinedRetentionGrants.removeValue(forKey: auth.id) }
  }
  private func joinedRetentionOwnerIsLive(_ owner: PromptCacheOwner) -> Bool {
    switch owner.route {
    case .consultation: return state.chats.contains { $0.id == owner.entity }
    case .writing: return documentIndices.contains { $0.id == owner.entity }
    case .inputCompletion:
      return inputCompletions.contains { $0.value?.id == owner.entity && $0.value?.joinedRetentionOwnerIsLive == true }
    }
  }
  private func authorizeJoinedRetention(_ auth: JoinedKVRetentionAuthorization,
    runner: MLXGemmaRunner) -> Bool {
    let b = auth.binding
    let current: MLXGemmaRunner?
    switch b.owner.route {
    case .consultation: current = mlxRunner
    case .writing: current = baseRunner
    case .inputCompletion: current = inputCompletionRunner
    }
    guard !joinedRetentionClosed, b.workspaceEpoch == joinedRetentionEpoch,
      b.owner.namespace == inferenceCacheNamespace, joinedRetentionOwnerIsLive(b.owner),
      joinedRetentionGrants[auth.id] === auth, current === runner,
      b.runnerEpoch == runner.cacheRunnerEpoch, b.modelIdentity == runner.identity,
      b.processorIdentity == runner.processorIdentity else { auth.revoke(); return false }
    // This grants historical exact-token KV only. The old UI/source/checkpoint
    // hooks still require the captured source, current flags, caret and UI epoch.
    return auth.approve(binding: b)
  }
  private func revokeJoinedRetentions(runnerEpoch: UUID? = nil) {
    let ids = joinedRetentionGrants.compactMap { id, grant in
      runnerEpoch == nil || grant.binding.runnerEpoch == runnerEpoch ? id : nil
    }
    for id in ids { joinedRetentionGrants.removeValue(forKey: id)?.revoke() }
    for runner in [mlxRunner, baseRunner, inputCompletionRunner].compactMap({ $0 })
      where runnerEpoch == nil || runner.cacheRunnerEpoch == runnerEpoch {
      runner.invalidatePromptCacheRetention(reason: "owner_or_model_revoked")
    }
  }
  func revokeInputJoinedRetentions(_ id: UUID) {
    let ids = joinedRetentionGrants.compactMap { key, grant in
      grant.binding.owner.route == .inputCompletion && grant.binding.owner.entity == id ? key : nil
    }
    for key in ids { joinedRetentionGrants.removeValue(forKey: key)?.revoke() }
    // Revoke this input's in-flight salvage grant, without discarding already
    // valid historical KV owned by another input/document in this workspace.
    // Full workspace, model, privacy and memory revocation still clear runners.
  }
  private var writingFlag: CancellationFlag?
  private var ghostFlag: CancellationFlag?
  private var pressureWatch: MemoryPressureWatch?
  private var saveTask: Task<Void, Error>?
  private var exportTasks: [URL: (id: UUID, task: Task<Void, Never>, pagedResult: Task<URL, Error>?,
    clipboardResult: Task<Void, Error>?)] = [:]
  private var pagedExportTaskCount = 0
  private static let maximumPagedExportTasks = 8
  private var ghostSources: [SourceReference] = []
  private var epoch: UInt64 = 0
  private(set) var caret = 0
  weak var editor: MarkdownTextView?
  private var lastInputPane: InputPane?
  private var paneTransition: UInt64 = 0
  private enum PaneFit: Equatable {
    case compact, medium, wide

    init(width: CGFloat) {
      self = width < 600 ? .compact : width < 900 ? .medium : .wide
    }
  }
  @Published private var paneFit: PaneFit = .wide
  @Published private var compactPane = "document"
  @Published private var mediumHiddenPane = "library"
  var showsLibrary: Bool {
    if paneFit == .compact { return compactPane == "library" }
    return state.showLibrary && !(layout.isAuthor && paneFit == .medium && allPanesRequested
      && mediumHiddenPane == "library")
  }
  var showsDocument: Bool {
    guard layout.isAuthor else { return false }
    if paneFit == .compact { return compactPane == "document" }
    return true
  }
  var showsChat: Bool {
    if !layout.isAuthor { return paneFit != .compact || compactPane == "chat" }
    if paneFit == .compact { return compactPane == "chat" }
    return state.showChat && !(paneFit == .medium && allPanesRequested
      && mediumHiddenPane == "chat")
  }
  private var allPanesRequested: Bool {
    layout.isAuthor && state.showLibrary && state.showChat
  }

  init(storeOverride: WorkspaceStore? = nil, loadModels: Bool = true) async throws {
    layout = try ProductCore.layout()
    if let storeOverride { store = storeOverride }
    else { store = try await detachedWork { try WorkspaceStore() } }
    state = WorkspaceState()
    compactPane = layout.primaryPane
    do {
      try await store.acquireExclusiveWorkspace()
      state = try await store.loadState()
      documentIndices = state.documents
      try await openPagedWorkspace(reclaimCold: true)
      selectedDocumentIDs = Set(state.selectedDocument.map { [$0] } ?? [])
      selectedChatIDs = Set(state.selectedChat.map { [$0] } ?? [])
      writingExampleIDs = state.writingExampleIDs ?? []
      restoreComposerDraft()
      if layout.isAuthor && documentIndices.isEmpty { try await createPagedDocument(flag: CancellationFlag()) }
      if !layout.isAuthor && state.chats.isEmpty { try newChat() }
      refreshContinuationHistory()
      try await flush()
    } catch {
      throw WorkspacePagedStartupFailure(original: error, model: self)
    }
    pressureWatch = MemoryPressureWatch { [weak self] critical in
      Task { @MainActor in self?.handleMemoryPressure(critical: critical) }
    }
    if loadModels {
      prepareModels()
      if #available(macOS 26.0, *) {
        speechSetupTask = Task { try? await VoiceInput.prepareOnDeviceSpeech() }
      }
    }
  }
  private func handleMemoryPressure(critical: Bool) {
    revokeJoinedRetentions()
    if critical { cancel() }
    let inactive: ModelPurpose = writingFlag != nil ? .consultation : .writing
    Task {
      if critical || !writingUsesConsultation { await releaseRunner(inactive) }
      await joinAndClearPromptCaches()
      await reclaimModelCache()
      await VideoPreparationCache.shared.release()
    }
    status = "Memory pressure released the inactive model. It will reload when needed."
  }
  /// Stable published library value. Text callbacks never rebuild this array.
  var selectedDocumentIndex: DocumentIndex? { documentIndices.first { $0.id == selectedDocumentID } }
  func appendDocument(_ document: DocumentSnapshot) {
    work("Creating document…") { [weak self] flag in
      try await self?.importAuthoredDocument(document, selecting: false, flag: flag)
    }
  }
  private func updateDocumentIndexTitle(_ id: UUID, title: String) {
    guard let index = documentIndices.firstIndex(where: { $0.id == id }), documentIndices[index].title != title else { return }
    documentIndices[index].title = title
  }
  func documentMatchesSearch(_ document: DocumentIndex) -> Bool { documentMatchesSearch(id: document.id) }
  func documentMatchesSearch(_ document: DocumentSnapshot) -> Bool { documentMatchesSearch(id: document.id) }
  private func documentMatchesSearch(id: UUID) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || searchedQuery != librarySearch || matchingDocumentIDs.contains(id)
  }
  func chatMatchesSearch(_ chat: ChatRecord) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || matchingChatIDs.contains(chat.id)
  }
  func voiceMatchesSearch(_ voice: Voice) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || matchingVoiceIDs.contains(voice.id)
  }
  private func refreshSearch() {
    let previous = searchTask
    searchEpoch &+= 1; previous?.cancel()
    let query = librarySearch, identity = searchEpoch
    refreshVisibleSearch()
    searchIssue = nil
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      searchedQuery = query; matchingDocumentIDs = []; documentSearch = [:]
      matchingChatIDs = []; matchingVoiceIDs = []
      return
    }
    guard !pagedTransition, !pagedShutdownRequested else { return }
    let headers = documentIndices, chats = state.chats, voices = state.voices
    let imported = state.importedFiles ?? [:]
    let folderNames = Dictionary(uniqueKeysWithValues: (state.importedFolders ?? []).map { ($0.id, $0.name) })
    searchTask = Task { [weak self] in
      if let previous { await previous.value }
      do {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(120))
        let metadata = try await detachedWork(priority: .utility) {
          var documentIDs = Set<UUID>(), chatIDs = Set<UUID>(), voiceIDs = Set<UUID>()
          for document in headers {
            try Task.checkCancellation()
            let path = imported[document.id].map { file in
              file.folderID.flatMap { folderNames[$0] }.map { $0 + "/" + file.path } ?? file.path
            } ?? ""
            if try ProductCore.search(document.title + "\n" + path, query: query).hasMatches { documentIDs.insert(document.id) }
          }
          for chat in chats {
            try Task.checkCancellation()
            var found = try ProductCore.search(chat.title + "\n" + (chat.instructions ?? ""), query: query).hasMatches
            for message in chat.messages where !found {
              try Task.checkCancellation()
              found = try ProductCore.search(message.text, query: query).hasMatches
            }
            if found { chatIDs.insert(chat.id) }
          }
          for voice in voices {
            try Task.checkCancellation()
            if try chatIDs.contains(voice.id) || ProductCore.search(voice.name + "\n" + voice.slug + "\n" + voice.instructions, query: query).hasMatches {
              voiceIDs.insert(voice.id)
            }
          }
          return (documentIDs, chatIDs, voiceIDs)
        }
        guard let self, self.searchEpoch == identity else { return }
        self.matchingDocumentIDs = metadata.0; self.matchingChatIDs = metadata.1; self.matchingVoiceIDs = metadata.2
        self.searchedQuery = query
        let (engine, publisher) = try self.pagedOwners()
        for header in headers where !metadata.0.contains(header.id) {
          try Task.checkCancellation()
          let read = try await engine.currentDocumentRecordRetaining(publisher, documentID: header.id)
          let revision = read.value.document.revision
          try await engine.abandonJoinedRootOutput(read.lease)
          if try await self.sourceContains(query, revision: revision, engine: engine) {
            guard self.searchEpoch == identity else { return }
            self.matchingDocumentIDs.insert(header.id)
          }
        }
      } catch is CancellationError {} catch {
        guard let self, self.searchEpoch == identity else { return }
        self.searchIssue = error.localizedDescription
      }
    }
  }
  /// Match only the real bounded projection, after input has returned. Neither
  /// this task nor its highlights grant source or replacement authority.
  private func refreshVisibleSearch() {
    let previous = visibleSearchTask
    previous?.cancel()
    let query = librarySearch, identity = searchEpoch
    visibleSearchTask = Task { [weak self] in
      if let previous { await previous.value }
      do {
        try Task.checkCancellation()
        guard let self, !self.pagedTransition, !self.pagedShutdownRequested else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.pagedInput?.activeView?.highlightSearch([], identity: nil)
          return
        }
        try await Task.sleep(for: .milliseconds(100))
        guard let session = self.pagedSession, let view = self.pagedInput?.activeView,
          !view.hasMarkedText(), self.searchEpoch == identity else { return }
        let arena = session.arenaID, generation = session.generation
        let documentID = self.selectedDocumentID, text = view.string
        let matches = try await detachedWork(priority: .utility) {
          try Task.checkCancellation()
          return try ProductCore.search(text, query: query)
        }
        try Task.checkCancellation()
        guard self.pagedSession === session, self.pagedInput?.activeView === view,
          session.arenaID == arena, session.generation == generation,
          self.selectedDocumentID == documentID, self.searchEpoch == identity,
          !view.hasMarkedText() else { return }
        view.highlightSearch(matches.ranges.map(\.native),
          identity: documentID.map { $0.uuidString + "\n" + query })
      } catch is CancellationError {} catch {
        guard let self, self.searchEpoch == identity else { return }
        self.searchIssue = error.localizedDescription
      }
    }
  }
  private func sourceContains(_ query: String, revision: PagedTextRevision,
    engine: PagedTextEngineAdapter) async throws -> Bool {
    var byte: UInt64 = 0, overlap = ""
    while byte < revision.summary.bytes {
      try Task.checkCancellation()
      let read = try await engine.windowRetaining(revision, byteStart: byte,
        maximumBytes: PagedTextWindow.maximumBytes, priority: .background)
      let window = read.value
      try await engine.abandonJoinedRootOutput(read.lease)
      try Task.checkCancellation()
      let end = window.byteStart + UInt64(window.text.utf8.count)
      guard end > byte, end <= revision.summary.bytes else { throw BoomError.invalid("Search source did not advance its bounded window.") }
      let previous = overlap
      let result = try await detachedWork(priority: .utility) {
        let found = try ProductCore.search(previous + window.text, query: query).hasMatches
        // Literal query admission is <=512 UTF-8 bytes. Keeping 2048 bytes
        // spans its possible Unicode case variants across a chunk boundary.
        let tail = Array(window.text.utf8.suffix(2048))
        let first = tail.firstIndex { $0 & 0xC0 != 0x80 } ?? tail.endIndex
        return (found, String(decoding: tail[first...], as: UTF8.self))
      }
      if result.0 { return true }
      overlap = result.1; byte = end
      await Task.yield()
    }
    return false
  }
  var selectedDocument: DocumentSnapshot? { selectedDocumentID.flatMap { captureCache[$0]?.completeSnapshot } }
  var selectedChat: ChatRecord? { state.chats.first { $0.id == state.selectedChat } }
  var proposedForChat: [StoredProposal] {
    return state.proposals.filter { $0.chatID == state.selectedChat }
  }
  var voiceMatches: [Voice] {
    guard let range = draft.range(of: #"(?:^|\s)@([a-z0-9_-]*)$"#, options: .regularExpression)
    else { return [] }
    let query = draft[range].trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
    return state.voices.filter { $0.slug.hasPrefix(query) }.prefix(6).map { $0 }
  }
  func report(_ error: Error) {
    errorMessage = error.localizedDescription
    status = error.localizedDescription
  }
  func dismissError() { errorMessage = nil }
  func finishComposition() {
    // Invoke the actual active input client; source/close admission still waits
    // for its real unmark and any resulting edit before moving the root.
    guard let view = pagedInput?.activeView, view.hasMarkedText() else { return }
    view.unmarkText()
  }
  private var selectedComposerOwner: ComposerOwner? {
    if let chat = state.selectedChat, state.chats.contains(where: { $0.id == chat }) {
      return ComposerOwner(kind: .chat, id: chat)
    }
    if let document = state.selectedDocument, documentIndices.contains(where: { $0.id == document }) {
      return ComposerOwner(kind: .document, id: document)
    }
    return nil
  }
  private func retainComposerDraft(schedule: Bool = true) {
    guard !restoringComposer, let owner = composerOwner,
      owner.kind == .chat ? state.chats.contains(where: { $0.id == owner.id })
        : documentIndices.contains(where: { $0.id == owner.id }) else { return }
    var drafts = (state.composerDrafts ?? []).filter { $0.owner != owner }
    if !draft.isEmpty || !pendingAttachments.isEmpty {
      drafts.append(ComposerDraft(owner: owner, text: draft, attachments: pendingAttachments,
        authoredRole: authoredChatRole))
    }
    if !drafts.isEmpty || state.composerDrafts != nil { state.composerDrafts = drafts }
    if schedule { scheduleSave() }
  }
  private func restoreComposerDraft() {
    restoringComposer = true
    defer { restoringComposer = false }
    composerOwner = selectedComposerOwner
    let retained = state.composerDrafts?.first { $0.owner == composerOwner }
    draft = retained?.text ?? ""
    pendingAttachments = retained?.attachments ?? (state.selectedChat.flatMap { state.recordingDrafts?[$0] } ?? [])
    mode = .ask
    authoredChatRole = retained?.authoredRole
  }
  private func transferDocumentDraftToChat() {
    if let owner = composerOwner, owner.kind == .document {
      state.composerDrafts?.removeAll { $0.owner == owner }
    }
    composerOwner = selectedComposerOwner
    retainComposerDraft()
  }
  func flush() async throws {
    if let failure = await joinWorkspaceSaveTasks() { throw failure }
    let request = UUID(); saveRequestID = request
    let task = startWorkspaceSave(request: request, expedited: true)
    let outcome = await task.result
    let followingFailure = await joinWorkspaceSaveTasks()
    try outcome.get()
    if let followingFailure { throw followingFailure }
  }
  func save() {
    guard !pagedShutdownRequested, !pagedTransition else { return }
    explicitSaveRequested = true
    scheduleSave()
  }
  private func performWorkspaceFlush(retryFailedSave: Bool = false) async throws {
    let trace = PerformanceTrace.begin("Workspace.Flush")
    defer { PerformanceTrace.end("Workspace.Flush", trace) }
    if let commands = pagedCommands { try await commands.joinPendingCommand() }
    if let session = pagedSession {
      if retryFailedSave {
        try requirePagedOperation()
        await session.joinPendingSave()
        guard pagedSession === session else { throw BoomError.stale("The selected saver changed during Save.") }
        if let identity = session.failedSaveIdentity {
          _ = try await session.retryFailedSave(expectedIdentity: identity)
        }
      }
      _ = try await session.flush(through: session.generation)
    }
    try await saveWorkspaceMetadata()
  }
  private func saveWorkspaceMetadata() async throws {
    retainComposerDraft(schedule: false)
    state.documents = documentIndices
    let snapshot = state
    try await store.saveState(snapshot)
  }
  func scheduleSave() {
    guard !pagedShutdownRequested, !pagedTransition else { return }
    let request = UUID(); saveRequestID = request
    if saveEntered { return }
    _ = startWorkspaceSave(request: request, expedited: explicitSaveRequested)
  }
  /// The existing saver owns every workspace write. Its token prevents an
  /// older join from clearing a replacement; neither token nor saveEntered
  /// is consulted by native input, selection or presentation.
  private func startWorkspaceSave(request: UUID, expedited: Bool,
    cancelSleepingPredecessor: Bool = true) -> Task<Void, Error> {
    precondition(!saveEntered)
    let previous = saveTask
    let cancelledPrevious = cancelSleepingPredecessor && !saveTaskWasEntered
    if cancelledPrevious { previous?.cancel() }
    let id = UUID(); saveTaskID = id
    // Immediate callers reserve the actual saver before their first yield.
    saveEntered = expedited; saveTaskWasEntered = expedited
    let task = Task<Void, Error> { [weak self] in
      let preceding: Result<Void, Error>?
      if let previous { preceding = await previous.result }
      else { preceding = nil }
      guard let self else { return }
      var entered = expedited
      defer {
        if self.saveTaskID == id {
          self.saveEntered = false
          if !self.pagedShutdownRequested, !self.pagedTransition,
            self.saveRequestID != request {
            // The replacement retains this still-returning Task and joins
            // its real result before entering the next save.
            _ = self.startWorkspaceSave(request: self.saveRequestID,
              expedited: self.explicitSaveRequested, cancelSleepingPredecessor: false)
          }
        }
      }
      do {
        if let preceding, case .failure(let error) = preceding,
          !(cancelledPrevious && error is CancellationError) {
          // The old actual task retains its error. A new metadata request
          // does not retry native publication; Session's fence remains until
          // an explicit Save supplies its exact failed identity below.
          self.status = error.localizedDescription
        }
        if !expedited && !self.explicitSaveRequested {
          try await Task.sleep(for: .milliseconds(350))
        }
        try Task.checkCancellation()
        guard self.saveTaskID == id else { throw CancellationError() }
        let explicit = self.explicitSaveRequested
        self.explicitSaveRequested = false
        self.saveEntered = true; self.saveTaskWasEntered = true; entered = true
        try await self.performWorkspaceFlush(retryFailedSave: explicit)
      } catch {
        if entered || !(error is CancellationError) { self.status = error.localizedDescription }
        throw error
      }
    }
    saveTask = task
    return task
  }
  /// Drain the actual current and replacement handles. Only a known canceled
  /// pre-entry sleeper is neutral; entered save errors are returned unchanged.
  private func joinWorkspaceSaveTasks() async -> Error? {
    var original: Error?
    while let pending = saveTask, let id = saveTaskID {
      let cancelledBeforeEntry = !saveTaskWasEntered
      if cancelledBeforeEntry { pending.cancel() }
      if case .failure(let error) = await pending.result,
        !(cancelledBeforeEntry && error is CancellationError), original == nil {
        original = error
      }
      if saveTaskID == id {
        saveTask = nil; saveTaskID = nil; saveTaskWasEntered = false
      }
    }
    return original
  }
  func newDocument() throws {
    try requirePagedOperation()
    work("Creating document…") { [weak self] flag in try await self?.createPagedDocument(flag: flag) }
  }
  func newChat(about documentID: UUID? = nil) throws {
    finishComposition()
    cancel()
    retainComposerDraft()
    if let documentID, !documentIndices.contains(where: { $0.id == documentID }) {
      throw BoomError.invalid("The document for this chat no longer exists.")
    }
    let chat = ChatRecord(attachedDocumentID: documentID)
    state.chats.append(chat)
    state.selectedChat = chat.id
    selectedChatIDs = [chat.id]
    composerFocusEpoch &+= 1
    state.showChat = true
    compactPane = "chat"
    restoreComposerDraft()
    showingChatInstructions = nil; editingChatMessage = nil
    scheduleSave()
  }
  private func ensureChatForSend() {
    guard !isBusy, !draft.isEmpty, selectedChat == nil else { return }
    do { _ = try chatAttachmentDestination() }
    catch { report(error) }
  }
  func attachDocument(_ documentID: UUID?, to chatID: UUID) {
    guard !isBusy else { return }
    do {
      if let documentID, !documentIndices.contains(where: { $0.id == documentID }) {
        throw BoomError.invalid("The selected document no longer exists.")
      }
      guard let index = state.chats.firstIndex(where: { $0.id == chatID }) else {
        throw BoomError.stale("Chat was removed.")
      }
      var next = state
      next.chats[index].attachedDocumentID = documentID
      scheduleSave()
      state = next
    } catch { report(error) }
  }
  func branch(_ messageID: UUID, from chatID: UUID, editing: Bool = false) {
    guard !isBusy else { return }
    do {
      scheduleSave()
      guard let original = state.chats.first(where: { $0.id == chatID }),
        let message = original.messages.first(where: { $0.id == messageID }) else {
        throw BoomError.stale("The selected message is no longer in this chat.")
      }
      if editing && message.role != .user {
        throw BoomError.invalid("Only your messages can be edited and continued.")
      }
      let nextChat = try original.branch(at: messageID, includeMessage: !editing)
      retainComposerDraft()
      var next = state
      next.chats.append(nextChat)
      next.selectedChat = nextChat.id
      scheduleSave()
      state = next
      restoreComposerDraft()
      selectedChatIDs = [nextChat.id]
      pendingAttachments = editing
        ? message.sources.filter { $0.kind == "attachment" }.map(\.id) : []
      draft = editing ? message.text : ""
      mode = .ask
      composerFocusEpoch &+= 1
    } catch { report(error) }
  }
  func regenerate(_ messageID: UUID, from chatID: UUID) {
    guard !isBusy else { return }
    guard let chat = state.chats.first(where: { $0.id == chatID }),
      let index = chat.messages.firstIndex(where: { $0.id == messageID }),
      chat.messages[index].role == .assistant,
      let user = chat.messages[..<index].last(where: { $0.role == .user })
    else { return }
    let previousSelection = state.selectedChat
    branch(user.id, from: chatID, editing: true)
    guard selectedChat?.id != previousSelection else { return }
    if state.proposals.contains(where: { $0.messageID == messageID }) {
      // Regeneration must never repeat an already applied edit automatically.
      mode = .propose
    }
    status = "Regenerating in a branch with current references"
    send()
  }
  func reroll(_ messageID: UUID, from chatID: UUID) {
    guard !isBusy, editingChatMessage == nil,
      let message = state.chats.first(where: { $0.id == chatID })?.messages.first(where: { $0.id == messageID }),
      message.role == .user, message.state == .complete else { return }
    let priorSelection = state.selectedChat
    branch(messageID, from: chatID, editing: true)
    guard state.selectedChat != priorSelection, state.selectedChat != chatID else { return }
    // A reroll always asks for a new answer. It cannot repeat a document edit
    // performed by the parent conversation.
    authoredChatRole = nil
    send()
  }
  func rate(_ messageID: UUID, in chatID: UUID, as feedback: MessageFeedback) {
    guard !isBusy else { return }
      guard let chat = state.chats.firstIndex(where: { $0.id == chatID }),
        let message = state.chats[chat].messages.firstIndex(where: { $0.id == messageID }),
        state.chats[chat].messages[message].role == .assistant else { return }
      var next = state
      let current = next.chats[chat].messages[message].feedback
      next.chats[chat].messages[message].feedback = current == feedback ? nil : feedback
      scheduleSave()
      state = next
  }

  func selectDocument(_ id: UUID, preservingSelection: Bool = false) {
    guard !isBusy else { return }
    cancel()
    work("Opening document…") { [weak self] flag in
      try await self?.selectPagedDocument(id, preservingSelection: preservingSelection, flag: flag)
    }
  }
  func selectChat(_ id: UUID, preservingSelection: Bool = false) {
    guard state.chats.contains(where: { $0.id == id }) else { return }
    cancel()
    retainComposerDraft()
    state.selectedChat = id
    if !preservingSelection { selectedChatIDs = [id] }
    composerFocusEpoch &+= 1
    state.showChat = true
    compactPane = "chat"
    restoreComposerDraft()
    showingChatInstructions = nil; editingChatMessage = nil
    scheduleSave()
  }
  func focusEditor(_ id: UUID) {
    guard selectedDocumentID == id, let input = pagedInput, let view = input.activeView,
      view.inputBinding?.state == .active else { return }
    let identity = view.inputBinding?.identity, focusEpoch = composerFocusEpoch
    // Target only this physical client after the normal representable mounts
    // it; a later arena or composer focus request makes the callback inert.
    DispatchQueue.main.async { [weak self, weak view] in
      guard let self, let view, self.selectedDocumentID == id,
        self.pagedInput === input, input.activeView === view,
        view.inputBinding?.identity == identity, view.inputBinding?.state == .active,
        self.composerFocusEpoch == focusEpoch else { return }
      view.window?.makeFirstResponder(view)
    }
  }
  func deleteDocuments(_ ids: Set<UUID>) {
    guard !isBusy, !ids.isEmpty,
      confirm("Delete documents?", message: "The documents leave the library. Their retained source files and captured history stay in the workspace.") else { return }
    work("Deleting documents…") { [weak self] flag in try await self?.trashPagedDocuments(ids, flag: flag) }
  }
  func deleteChats(_ ids: Set<UUID>) {
    guard !isBusy, !ids.isEmpty else { return }
    let targets = state.chats.filter { ids.contains($0.id) }
    let removesCurrent = state.selectedChat.map { ids.contains($0) } ?? false
    let discardsDrafts = (state.composerDrafts ?? []).contains { $0.owner.kind == .chat && ids.contains($0.owner.id) }
      || (state.recordingDrafts ?? [:]).contains { ids.contains($0.key) && !$0.value.isEmpty }
    guard !targets.isEmpty,
      confirm(
        targets.count == 1 ? "Delete \(targets[0].title)?" : "Delete \(targets.count) chats?",
        message: "Their messages and pinned voices will be removed from the library. Captured voice revisions and edit receipts stay."
          + (discardsDrafts ? " Their unsent text and pending attachment selection will be discarded." : "")
      ) else { return }
      revokeJoinedRetentions()
      retainComposerDraft()
      var next = state
      next.chats.removeAll { ids.contains($0.id) }
      next.voices.removeAll { ids.contains($0.id) }
      next.composerDrafts?.removeAll { $0.owner.kind == .chat && ids.contains($0.owner.id) }
      next.recordingDrafts = next.recordingDrafts?.filter { !ids.contains($0.key) }
      if let selected = next.selectedChat, ids.contains(selected) {
        next.selectedChat = next.chats.first?.id
      }
      scheduleSave()
      state = next
      selectedChatIDs.subtract(ids)
      if selectedChatIDs.isEmpty, let id = next.selectedChat { selectedChatIDs = [id] }
      if removesCurrent {
        restoreComposerDraft()
        composerFocusEpoch &+= 1
      }
  }
  func renameDocument(_ id: UUID, to proposedTitle: String) {
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isBusy, !title.isEmpty else { return }
    work("Renaming document…") { [weak self] flag in try await self?.renamePagedDocument(id, to: title, flag: flag) }
  }
  func renameChat(_ id: UUID, to proposedTitle: String) {
    guard let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    var chat = state.chats[index]; chat.title = title
    do { try applyChat(chat) } catch { composerIssue = error.localizedDescription }
  }
  func updateDocument(_ text: String, id: UUID, caret: Int) {
    report(BoomError.denied("Document edits belong to the native bounded editor."))
  }
  func movedCaret(_ caret: Int, hasMarkedText: Bool) {
    guard self.caret != caret || hasMarkedText else { return }
    self.caret = caret
    invalidateGhost()
    if !hasMarkedText { scheduleCompletion() }
  }
  func invalidateGhost() {
    epoch &+= 1
    writingFlag?.cancel()
    ghostFlag?.cancel()
    ghostTask?.cancel()
    ghostText = ""
    ghostStamp = nil
    ghostSources = []
    pagedInput?.activeView?.clearGhost()
  }
  func toggle(_ pane: String) {
    guard layout.paneControls.contains(pane) else { return }
    if paneFit == .compact {
      compactPane = compactPane == pane ? layout.primaryPane : pane
      if compactPane != "document" { finishComposition(); invalidateGhost() }
      return
    }
    if paneFit == .medium, allPanesRequested,
      !((pane == "library" && showsLibrary) || (pane == "document" && showsDocument)
        || (pane == "chat" && showsChat)) {
      mediumHiddenPane = pane == "library" ? "chat" : "library"
      return
    }
    switch pane {
    case "library": state.showLibrary.toggle()
    case "document":
      finishComposition()
      state.showDocument.toggle()
      invalidateGhost()
    default: state.showChat.toggle()
    }
    if !state.showLibrary && !state.showDocument && !state.showChat { state.showDocument = true }
    scheduleSave()
  }
  func fitPanes(to width: CGFloat) {
    let fit = PaneFit(width: width)
    // The window relays out native views for each pixel on its own. Publish
    // only when pane visibility can change, not for every drag event.
    guard paneFit != fit else { return }
    let previous = NSApp?.keyWindow?.firstResponder
    let focused: InputPane?
    switch previous {
    case is ChatTextView: focused = .chat
    case is MarkdownTextView, is PagedNativeTextView: focused = .document
    case is NSTextField: focused = nil
    default: focused = lastInputPane
    }
    paneTransition &+= 1
    let transition = paneTransition
    if fit == .compact, paneFit != .compact, let focused {
      compactPane = focused == .chat ? "chat" : "document"
    }
    paneFit = fit
    guard let focused else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.paneTransition == transition else { return }
      let target: InputPane? = switch focused {
      case .chat where self.showsChat: .chat
      case .document where self.showsDocument: .document
      default: self.showsDocument ? .document : self.showsChat ? .chat : nil
      }
      switch target {
      case .document:
        if let id = self.selectedDocumentID { self.focusEditor(id) }
      case .chat: self.composerFocusEpoch &+= 1
      case nil: break
      }
    }
  }
  func noteInputFocus(_ pane: InputPane) { lastInputPane = pane }
  func setTheme(_ theme: String) {
    state.theme = theme
    NSApp.appearance =
      theme == "dark"
      ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
    scheduleSave()
  }
  func insertReference(to id: UUID) {
    guard let document = documentIndices.first(where: { $0.id == id }),
      let view = pagedInput?.activeView else { return }
    view.window?.makeFirstResponder(view)
    view.insertText("[[\(document.title)|\(id.uuidString)]]", replacementRange: view.selectedRange())
  }
  func insertVoice(_ persona: Voice) {
    if let range = draft.range(of: #"(?:^|\s)@[a-z0-9_-]*$"#, options: .regularExpression) {
      let prefix = draft[range].first?.isWhitespace == true ? " " : ""
      draft.replaceSubrange(range, with: prefix + "@" + persona.slug + " ")
    } else {
      draft += (draft.isEmpty ? "" : " ") + "@" + persona.slug + " "
    }
  }
  func work(_ label: String, after: (@MainActor () -> Void)? = nil,
    body: @escaping @MainActor (CancellationFlag) async throws -> Void) {
    guard !isBusy else { return }
    let trace = PerformanceTrace.begin("Request.Work")
    cancelInputCompletions()
    invalidateGhost()
    let previousGhost = ghostTask
    let flag = CancellationFlag()
    let id = UUID()
    activeFlag = flag
    activeID = id
    isBusy = true
    status = label
    foreground = Task { [weak self] in
      defer { PerformanceTrace.end("Request.Work", trace) }
      if let previousGhost {
        let joinTrace = PerformanceTrace.begin("Request.PreviousProducerJoin")
        await previousGhost.value
        PerformanceTrace.end("Request.PreviousProducerJoin", joinTrace)
      }
      guard let self else { return }
      var completed = false
      defer {
        if self.activeID == id {
          self.isBusy = false
          self.activeFlag = nil
          self.activeID = nil
          self.streamingText = ""
          self.streamingChat = nil
          self.scheduleCompletion()
          if completed { after?() }
        }
      }
      do {
        try flag.check()
        try await body(flag)
        try await self.flush()
        completed = true
      } catch is CancellationError {
        self.status = "Stopped"
        do { try await self.flush() } catch { self.report(error) }
      } catch {
        self.report(error)
        do { try await self.flush() } catch { self.report(error) }
      }
    }
  }
  func cancel() {
    PerformanceTrace.event("Request.CancelRequested")
    cancelInputCompletions()
    activeFlag?.cancel()
    foreground?.cancel()
    invalidateGhost()
  }
  func shutdown() async throws {
    pagedShutdownRequested = true
    for operation in Array(exportTasks.values) {
      operation.pagedResult?.cancel(); operation.clipboardResult?.cancel()
    }
    joinedRetentionClosed = true
    revokeJoinedRetentions()
    speechOutput.stopSpeaking()
    speechSetupTask?.cancel()
    modelPickerTask?.cancel()
    finishComposition()
    cancel()
    await VoiceInput.cancelSpeechPreparationAndJoin()
    if let speechSetupTask { await speechSetupTask.value }
    speechSetupTask = nil
    for input in inputCompletions { await input.value?.join() }
    let priorSaveFailure = await joinWorkspaceSaveTasks()
    searchEpoch &+= 1; searchTask?.cancel()
    if let searchTask { await searchTask.value }
    if let recordingAttachmentTask {
      recordingAttachmentTask.cancel()
      do { try await recordingAttachmentTask.value } catch is CancellationError {}
    }
    historyRequest = nil; historyTask?.cancel()
    if let historyTask { await historyTask.value }
    if let foreground { await foreground.value }
    if let ghostTask { await ghostTask.value }
    await joinAndClearPromptCaches()
    for operation in Array(exportTasks.values) { await operation.task.value }
    await VideoPreparationCache.shared.release()
    let followingSaveFailure = await joinWorkspaceSaveTasks()
    if let priorSaveFailure { throw priorSaveFailure }
    if let followingSaveFailure { throw followingSaveFailure }
    try await flush()
    try await closePagedSelection()
    guard pagedImported == nil, pagedInitialized == nil else {
      throw BoomError.stale("A document import has not joined shutdown.")
    }
    if let engine = pagedEngine { try await engine.close() }
    pagedPublisher = nil; pagedEngine = nil
    try await store.releaseExclusiveWorkspace()
  }

  private func revalidate(_ sources: [SourceReference], attachments: [SourceReference]) throws {
    for source in sources {
      let attachment = state.attachments.first(where: { $0.id == source.id })
      let digest: String?
      if source.kind == "media" { digest = attachment?.rootDigest }
      else if source.kind == "attachment" { digest = attachment?.digest }
      else if let record = pagedSelectedRecord, record.document.id == source.id { digest = try BoundedDocumentCapture.digest(record.document.revision) }
      else { digest = (consultationCaptures[source.id] ?? captureCache[source.id])?.revisionDigest }
      guard digest == source.digest else { throw BoomError.stale(source.title) }
    }
    for source in attachments {
      guard state.attachments.first(where: { $0.id == source.id })?.digest == source.digest else { throw BoomError.stale(source.title) }
    }
  }
  func send(replay: ConsultationReplay? = nil) {
    let captureTrace = PerformanceTrace.begin("Request.ConsultationCapture")
    defer { PerformanceTrace.end("Request.ConsultationCapture", captureTrace) }
    if replay == nil { ensureChatForSend() }
    if replay == nil && authoredChatRole != nil { appendAuthoredChatMessage(); return }
    guard !isBusy, let chat = selectedChat, canInfer,
      replay != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    else { if !canInfer && !isBusy { prepareModels() }; return }
    let request = replay?.request ?? draft, interaction: InteractionMode = replay == nil ? mode : .propose
    let promptContract = replay?.promptContract ?? .referenceBindingsV3
    let selectedIDs = replay?.attachmentIDs ?? pendingAttachments, style = consultationStyle
    work("Checking consultation context…") { [weak self] flag in
      guard let self else { return }
      finishComposition()
      let graph = try await captureChatContext(request: request, attachedDocumentID: chat.attachedDocumentID,
        editingDocumentID: interaction == .ask ? nil : state.selectedDocument, flag: flag)
      let document = interaction == .ask ? nil : graph.captures.first { $0.documentID == self.state.selectedDocument }?.modelSnapshot
      consultationCaptures = Dictionary(uniqueKeysWithValues: graph.captures.map { ($0.documentID, $0) })
      let slugs = try ReferenceParser.voices(request)
      guard slugs.count <= 3 else { throw BoomError.budget("Consult at most three voices per turn.") }
      guard interaction != .edit || slugs.count <= 1 else {
        throw BoomError.denied("Edit grants one voice at a time. Use Propose to compare voices.")
      }
      let voices: [Voice]
      if let replay { voices = replay.voice.map { [$0] } ?? [] }
      else { voices = try slugs.map { slug -> Voice in
        guard let voice = self.state.voices.first(where: { $0.slug == slug }) else { throw BoomError.invalid("Unknown voice @\(slug).") }
        return voice
      } }
      guard interaction == .ask || document != nil else { throw BoomError.denied("Choose a document before requesting edits.") }
      let inherited = graph.documents.flatMap { AttachmentLink.ids(in: $0.text) }
      let attachmentIDs = (selectedIDs + inherited).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
      guard attachmentIDs.count <= 8 else { throw BoomError.budget("At most eight attachments per turn.") }
      var attachments = try attachmentIDs.map { id -> AttachmentRecord in
        guard let record = self.state.attachments.first(where: { $0.id == id }) else { throw BoomError.stale("An attachment was removed.") }
        return record
      }
      if attachments.contains(where: { $0.kind == .unavailable }) {
        composerIssue = "An attachment can't be read locally. Its original has been kept."
        return
      }
      for index in attachments.indices where attachments[index].needsPreparation {
        let captured = attachments[index]
        let data = try await store.attachment(captured.id)
        let prepared = try await preparedRecord(captured, data: data, automaticAudio: true, flag: flag)
        guard let current = state.attachments.firstIndex(where: { $0.id == captured.id }),
          state.attachments[current].digest == captured.digest else { throw BoomError.stale("The attachment changed.") }
        state.attachments[current] = prepared; attachments[index] = prepared
      }
      let attachmentSources = attachments.map(\.reference), sources = graph.sources + attachmentSources
      let attachmentText = promptContract == .referenceBindingsV3 ? "" : attachments.filter { !$0.text.isEmpty }.map {
        "ATTACHMENT \($0.name)\nID \($0.id)\nDIGEST \($0.digest)\nCOVERAGE \($0.coverage)\n\($0.text)"
      }.joined(separator: "\n\n")
      let authority = CapturedDocumentAuthority(mode: interaction, target: document,
        capture: interaction == .ask ? nil : graph.captures.first { $0.documentID == document?.id })
      let context: String, renderedContext: RenderedReferenceContext?, capturedContextSources: [SourceReference]
      let capturedAttachments = attachments
      if promptContract == .referenceBindingsV3 {
        let rendered = try await detachedWork {
          try DocumentTools.renderedContext(graph.documents, attachments: capturedAttachments, authority: authority)
        }
        renderedContext = rendered; context = rendered.prompt
        capturedContextSources = graph.promptSources + attachments.filter { !$0.text.isEmpty }.map(\.reference)
      } else {
        let documentContext = try await detachedWork { try DocumentTools.context(graph.documents, authority: authority) }
        context = [documentContext, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        renderedContext = nil; capturedContextSources = []
      }
      guard context.utf8.count <= 524_288 else { throw BoomError.budget("Combined reference context exceeds 512 KiB.") }
      let instructions = chat.instructions ?? ""
      let targets: [Voice?] = voices.isEmpty ? [nil] : voices.map(Optional.some)
      let outputLimit = interaction == .ask ? 512 : 4096
        let runner = try await self.runnerForGeneration(.consultation, flag: flag)
        let executionPolicy = try ProductCore.resolvedGenerationPolicy(
          replay?.generationPolicy ?? runner.generationPolicy, loaded: runner.generationPolicy)
        // Exact replay starts cold; live turns may reuse only this chat's prefix.
        let cacheOwner: PromptCacheOwner? = replay == nil
          ? PromptCacheOwner(namespace: self.inferenceCacheNamespace, entity: chat.id, route: .consultation)
          : nil
        let provider = runner.identity
        try await self.flush()
        try await self.revalidateResponseSources(graph.sources, attachments: attachmentSources, targetID: authority.target?.id)
        let media = try await self.consultationMedia(attachments, rawAudio: runner.supportsRawAudio, flag: flag)
        let images = media.images
        let reserves = targets.indices.map { index in
          style == .discuss ? outputLimit * (index + 1) + 256 * index : outputLimit
        }
        let fitPairedAdmission = self.makePairedContextAdmission(runner: runner, purpose: .consultation,
          owner: cacheOwner, flag: flag) { [weak self] in
          guard let workspace = self else { throw CancellationError() }
          try await workspace.validateConsultationAdmissionSource(chat: chat, sources: graph.sources,
            attachments: attachmentSources, targetID: authority.target?.id,
            requiredDocumentID: interaction == .ask ? nil : document?.id, flag: flag)
        }
        let fitted = try await runner.fittedRound(voices: targets, history: chat.messages,
          instructions: instructions, context: context, request: request, routing: slugs,
          images: images, media: media.media, reserves: reserves, flag: flag, authority: authority, cacheOwner: cacheOwner,
          pairedAdmission: fitPairedAdmission, promptContract: promptContract,
          renderedContext: renderedContext, capturedSources: capturedContextSources)
        let plans = fitted.plans
        try flag.check()
        try await self.revalidateResponseSources(graph.sources, attachments: attachmentSources, targetID: authority.target?.id)
        guard let index = self.state.chats.firstIndex(where: { $0.id == chat.id }) else { throw BoomError.stale("Chat was removed.") }
        let replyIDs = targets.map { _ in UUID() }
        if replay == nil {
          self.state.chats[index].messages.append(ChatMessage(role: .user, text: request,
            context: context, sources: sources, speaker: Speaker(name: "Human"), directAttachments: selectedIDs,
            consultationRouting: slugs, consultationPromptContract: promptContract))
        }
        for (offset, voice) in targets.enumerated() {
          self.state.chats[index].messages.append(ChatMessage(id: replyIDs[offset], role: .assistant,
            text: "", sources: sources, state: .pending, provider: provider,
            speaker: voice?.speaker ?? Speaker(name: "Bloom")))
        }
        if self.state.chats[index].title == "New chat" { self.state.chats[index].title = try ProductCore.chatTitle(request, routing: slugs) }
        if replay == nil && self.draft == request { self.draft = "" }
        if replay == nil && self.pendingAttachments == selectedIDs {
          self.pendingAttachments = []
          self.state.recordingDrafts?[chat.id] = (self.state.recordingDrafts?[chat.id] ?? []).filter { !selectedIDs.contains($0) }
        }
        self.streamingChat = chat.id
        var round: [ChatMessage] = []
        do {
          try await self.flush()
          for (offset, voice) in targets.enumerated() {
            try flag.check()
            self.status = voice.map { "Consulting @\($0.slug)…" } ?? "Generating locally…"
            self.streamingText = ""
            var plan: ConsultationPlan
            if style == .discuss, !round.isEmpty {
              plan = try ProductCore.prompt(voice: voice, history: fitted.history + round,
                instructions: instructions, context: context, request: request, routing: slugs,
                authority: authority, promptContract: promptContract,
                renderedContext: renderedContext, capturedSources: capturedContextSources)
            } else { plan = plans[offset] }
            var responseAuthority = authority
            var sourceDocuments = graph.documents
            var previousAttemptID = replay?.previousAttemptID
            while true {
              try flag.check()
              try await self.revalidateResponseSources(try self.sourceReferences(for: sourceDocuments), attachments: attachmentSources, targetID: responseAuthority.target?.id)
              guard interaction == .ask || self.state.selectedDocument == document?.id else { throw BoomError.stale("Active document changed.") }
              let attemptSources = try self.sourceReferences(for: sourceDocuments) + attachmentSources
              let seed = UInt64.random(in: .min ... .max), vault = self.store.vault
              let attemptID = UUID()
              var receipt = ConsultationReceipt(operationID: flag.operationID, seed: seed, state: .pending,
                failure: nil, model: provider, voice: voice, plan: plan, sources: attemptSources,
                promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [], stopReason: "pending",
                firstTokenSeconds: nil, elapsedSeconds: 0, generationPolicy: executionPolicy)
              let replyID = replyIDs[offset]
              receipt.media = media.media.isEmpty ? nil : media.media.map(\.reference)
              receipt.attemptID = attemptID; receipt.previousAttemptID = previousAttemptID; receipt.responseID = replyID
              let pendingReceipt = receipt
              try await detachedWork {
                try vault.encode(pendingReceipt, kind: .receipt, id: attemptID)
                try vault.encode(pendingReceipt, kind: .receipt, id: replyID)
              }
              let checkpointStore = self.store
              let generation = GenerationIdentity(kind: interaction == .ask ? .consultation : .documentResponse,
                operationID: flag.operationID, recordID: replyID, attemptID: attemptID,
                model: provider, seed: seed, requestDigest: Digest.sha256(plan.rawPrompt), maxTokens: outputLimit,
                generationPolicy: executionPolicy)
              let deliveryTrace = PerformanceTrace.firstDelivery()
              let cacheSources = try self.sourceReferences(for: sourceDocuments)
              let cacheTargetID = responseAuthority.target?.id
              guard let admissionChat = self.state.chats.first(where: { $0.id == chat.id }) else {
                throw BoomError.stale("The captured chat was removed.")
              }
              let generationPairedAdmission = self.makePairedContextAdmission(runner: runner, purpose: .consultation,
                owner: cacheOwner, flag: flag, sharingAttempt: fitPairedAdmission) { [weak self] in
                guard let workspace = self else { throw CancellationError() }
                try await workspace.validateConsultationAdmissionSource(chat: admissionChat, sources: cacheSources,
                  attachments: attachmentSources, targetID: cacheTargetID,
                  requiredDocumentID: interaction == .ask ? nil : document?.id, flag: flag)
              }
              let joinedRetention = try self.makeJoinedRetentionRequest(owner: cacheOwner,
                runner: runner, policy: executionPolicy, operationID: flag.operationID)
              defer { self.finishJoinedRetentionRequest(joinedRetention) }
              let result = try await runner.run(plan: plan, images: images, media: media.media, maxTokens: outputLimit,
                seed: seed, flag: flag, cacheOwner: cacheOwner, executionPolicy: executionPolicy,
                joinedRetention: joinedRetention,
                beforeCachePublication: { [weak self] in
                  guard let self else { throw CancellationError() }
                  try await self.revalidateResponseSources(cacheSources,
                    attachments: attachmentSources, targetID: cacheTargetID)
                  try await MainActor.run {
                    try flag.check()
                    guard self.activeFlag === flag,
                      self.state.chats.contains(where: { $0.id == chat.id }),
                      interaction == .ask || self.state.selectedDocument == document?.id else {
                      throw BoomError.stale("The request owner changed before prompt-cache publication.")
                    }
                  }
                },
                pairedAdmission: generationPairedAdmission,
                onCheckpoint: { progress, stop, token in
                  try await checkpointStore.checkpoint(progress, identity: generation, stopReason: stop, stopTokenID: token)
                }) { [weak self] text in
                  Task { @MainActor in
                    guard let self, self.activeFlag === flag, !flag.isCancelled else { return }
                    if interaction == .ask {
                      self.streamingText = text
                      if let c = self.state.chats.firstIndex(where: { $0.id == chat.id }),
                        let m = self.state.chats[c].messages.firstIndex(where: { $0.id == replyIDs[offset] }),
                        self.state.chats[c].messages[m].state == .pending {
                        self.state.chats[c].messages[m].text = text
                      }
                      deliveryTrace?.published()
                    }
                  }
                }
              receipt.promptDigest = result.promptDigest; receipt.tokenIDs = result.tokenIDs
              receipt.stopReason = result.stopReason; receipt.firstTokenSeconds = result.firstTokenSeconds
              receipt.stopTokenID = result.stopTokenID
              receipt.elapsedSeconds = result.elapsedSeconds
              receipt.executionOrigin = result.executionOrigin
              if result.stopReason == "cancelled" { receipt.state = .cancelled }
              let emittedReceipt = receipt
              try await detachedWork {
                try vault.encode(emittedReceipt, kind: .receipt, id: attemptID)
                try vault.encode(emittedReceipt, kind: .receipt, id: replyID)
              }
              if interaction == .ask,
                let c = self.state.chats.firstIndex(where: { $0.id == chat.id }),
                let m = self.state.chats[c].messages.firstIndex(where: { $0.id == replyID }) {
                self.state.chats[c].messages[m].text = result.text
              }
              try flag.check()
              try await self.revalidateResponseSources(try self.sourceReferences(for: sourceDocuments), attachments: attachmentSources, targetID: responseAuthority.target?.id)
              guard interaction == .ask || self.state.selectedDocument == document?.id else { throw BoomError.stale("Active document changed.") }
              var issue: String?
              var refreshContext = false
              if interaction != .ask {
                let capturedAuthority = responseAuthority
                let parsed = try await detachedWork { try DocumentTools.response(result.text, authority: capturedAuthority) }
                issue = parsed.issue
                if issue == nil, let patch = parsed.edits.first, let base = responseAuthority.target,
                  let current = responseAuthority.capture?.modelSnapshot {
                  do { _ = try await detachedWork { try DocumentTools.validate(patch,
                    grant: DocumentGrant(mode: interaction, snapshot: base), current: current) } }
                  catch { issue = error.localizedDescription; refreshContext = current.revision != base.revision }
                }
              }
              var message: ChatMessage?
              if issue == nil {
                guard !result.text.isEmpty else { throw BoomError.unavailable("The model ended before producing an answer.") }
                let pending = ChatMessage(id: replyID, role: .assistant, text: "", sources: attemptSources,
                  state: .pending, provider: provider, speaker: voice?.speaker ?? Speaker(name: "Bloom"))
                do {
                  let completed = try await self.finishConsultationResponse(result.text, pending: pending,
                    chatID: chat.id, authority: responseAuthority,
                    documentSources: try self.sourceReferences(for: sourceDocuments),
                    attachments: attachmentSources, recovering: true)
                  if completed.state == .failed {
                    issue = completed.failure
                    refreshContext = self.pagedSession?.generation != responseAuthority.capture?.generation
                  } else { message = completed }
                } catch is DocumentMergeConflict {
                  issue = "Intervening manuscript changes conflict with this attempt."
                  refreshContext = true
                }
              }
              if let issue {
                // Fail the joined producer privately. Never add malformed output
                // to history, or let a retry overwrite an earlier attempt journal.
                receipt.state = .failed; receipt.failure = issue
                let failedReceipt = receipt
                try await detachedWork {
                  try vault.encode(failedReceipt, kind: .receipt, id: attemptID)
                  try vault.encode(failedReceipt, kind: .receipt, id: replyID)
                }
                previousAttemptID = attemptID
                self.status = "Preparing document changes…"
                if refreshContext {
                  guard let targetID = authority.target?.id, self.state.selectedDocument == targetID else {
                    throw BoomError.stale("Choose the original document before requesting a fresh proposal.")
                  }
                  let refreshedGraph = try await self.captureChatContext(request: request,
                    attachedDocumentID: chat.attachedDocumentID, editingDocumentID: targetID, flag: flag)
                  self.consultationCaptures = Dictionary(uniqueKeysWithValues: refreshedGraph.captures.map { ($0.documentID, $0) })
                  guard let freshTarget = refreshedGraph.captures.first(where: { $0.documentID == targetID }) else { throw BoomError.stale("The refreshed target was removed.") }
                  responseAuthority = CapturedDocumentAuthority(mode: interaction, target: freshTarget.modelSnapshot, capture: freshTarget)
                  sourceDocuments = refreshedGraph.documents
                  let fullContext: String, refreshedContext: RenderedReferenceContext?, refreshedSources: [SourceReference]
                  let refreshedDocuments = sourceDocuments, refreshedAuthority = responseAuthority
                  if promptContract == .referenceBindingsV3 {
                    let rendered = try await detachedWork {
                      try DocumentTools.renderedContext(refreshedDocuments, attachments: capturedAttachments, authority: refreshedAuthority)
                    }
                    refreshedContext = rendered; fullContext = rendered.prompt
                    refreshedSources = refreshedGraph.promptSources
                      + attachments.filter { !$0.text.isEmpty }.map(\.reference)
                  } else {
                    let recapturedContext = try await detachedWork { try DocumentTools.context(refreshedDocuments, authority: refreshedAuthority) }
                    fullContext = [recapturedContext, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    refreshedContext = nil; refreshedSources = []
                  }
                  guard let refitChat = self.state.chats.first(where: { $0.id == chat.id }) else {
                    throw BoomError.stale("The captured chat was removed.")
                  }
                  let refitSources = try self.sourceReferences(for: sourceDocuments)
                  let refitTargetID = responseAuthority.target?.id
                  let refitPairedAdmission = self.makePairedContextAdmission(runner: runner, purpose: .consultation,
                    owner: cacheOwner, flag: flag, sharingAttempt: fitPairedAdmission) { [weak self] in
                    guard let workspace = self else { throw CancellationError() }
                    try await workspace.validateConsultationAdmissionSource(chat: refitChat, sources: refitSources,
                      attachments: attachmentSources, targetID: refitTargetID,
                      requiredDocumentID: document?.id, flag: flag)
                  }
                  let refreshed = try await runner.fittedRound(voices: [voice], history: fitted.history + round,
                    instructions: instructions, context: fullContext, request: request, routing: slugs,
                    images: images, media: media.media, reserves: [outputLimit], flag: flag,
                    authority: responseAuthority, cacheOwner: cacheOwner,
                    pairedAdmission: refitPairedAdmission, promptContract: promptContract,
                    renderedContext: refreshedContext, capturedSources: refreshedSources)
                  guard let refreshedPlan = refreshed.plans.first else { throw BoomError.invalid("Missing captured response plan.") }
                  plan = refreshedPlan
                }
                continue
              }
              guard let message else { throw BoomError.invalid("Missing completed answer.") }
              round.append(message)
              receipt.state = message.state
              receipt.failure = message.failure
              let completedReceipt = receipt
              try await detachedWork {
                try vault.encode(completedReceipt, kind: .receipt, id: attemptID)
                try vault.encode(completedReceipt, kind: .receipt, id: replyID)
              }
              self.streamingText = ""
              if interaction == .ask { self.status = "Local answer · \(result.promptTokens) prompt tokens" }
              try await self.flush()
              break
            }
          }
        } catch {
          if let chatIndex = self.state.chats.firstIndex(where: { $0.id == chat.id }) {
            for message in self.state.chats[chatIndex].messages.indices where replyIDs.contains(self.state.chats[chatIndex].messages[message].id)
              && self.state.chats[chatIndex].messages[message].state == .pending {
              self.state.chats[chatIndex].messages[message].state = flag.isCancelled ? .cancelled : .failed
              self.state.chats[chatIndex].messages[message].failure = flag.isCancelled ? nil : "Bloom couldn't finish this answer. You can try again."
            }
          }
          let vault = self.store.vault, failedIDs = replyIDs, reason = error.localizedDescription
          let checkpointStore = self.store
          let ending: MessageState = flag.isCancelled ? .cancelled : .failed
          do {
            let restored: [(UUID, GenerationCheckpoint)] = try await detachedWork {
              var restored: [(UUID, GenerationCheckpoint)] = []
              for id in failedIDs where vault.exists(.receipt, id) {
                var receipt = try vault.decode(ConsultationReceipt.self, kind: .receipt, id: id)
                if receipt.state == .pending {
                  if let journal = try await checkpointStore.consultationCheckpoint(id: id, receipt: receipt) {
                    receipt.retain(journal); restored.append((id, journal))
                  }
                  receipt.state = ending; receipt.failure = reason; receipt.stopReason = ending.rawValue
                  if let attemptID = receipt.attemptID { try vault.encode(receipt, kind: .receipt, id: attemptID) }
                  try vault.encode(receipt, kind: .receipt, id: id)
                }
              }
              return restored
            }
            for (id, journal) in restored where journal.identity.kind == .consultation {
              if let c = self.state.chats.firstIndex(where: { $0.id == chat.id }),
                let m = self.state.chats[c].messages.firstIndex(where: { $0.id == id }),
                self.state.chats[c].messages[m].state == ending {
                self.state.chats[c].messages[m].text = journal.progress.text
              }
            }
          } catch { self.report(error) }
          self.scheduleSave()
          self.composerIssue = flag.isCancelled ? nil : "Bloom couldn't finish this answer. You can try again."
          self.status = flag.isCancelled ? "Cancelled" : "Answer interrupted"
        }
    }
  }
  func finishConsultationResponse(_ text: String, pending: ChatMessage, chatID: UUID,
    authority: CapturedDocumentAuthority, documentSources: [SourceReference], attachments: [SourceReference], recovering: Bool = false
  ) async throws -> ChatMessage {
    guard state.chats.first(where: { $0.id == chatID })?.messages.contains(where: { $0.id == pending.id && $0.state == .pending }) == true else {
      throw BoomError.stale("The pending response disappeared.")
    }
    var answer = text
    var documentStatus: String?
    var responseIssue: String?
    if authority.mode != .ask {
      let envelope = try await detachedWork { try DocumentTools.response(text, authority: authority) }
      answer = envelope.reply
      responseIssue = envelope.issue
      if responseIssue == nil, let patch = envelope.edits.first {
        guard let document = authority.target, let capture = authority.capture, state.selectedDocument == capture.documentID else {
          throw BoomError.stale("The captured document is no longer open.")
        }
        do { _ = try await detachedWork { try DocumentTools.validate(patch, grant: DocumentGrant(mode: authority.mode, snapshot: document), current: capture.modelSnapshot) } }
        catch { responseIssue = "No document changes: \(error.localizedDescription)"; answer = text }
        if responseIssue == nil {
          let proposal = StoredProposal(id: UUID(), chatID: chatID, messageID: pending.id,
            patch: patch, document: document, capture: capture, documents: documentSources, attachments: attachments, status: "pending")
          state.proposals.append(proposal)
          try await flush()
          if authority.mode == .edit {
            do { try await commit(proposal) }
            catch is DocumentMergeConflict {
              if let index = state.proposals.firstIndex(where: { $0.id == proposal.id }) { state.proposals[index].status = "superseded" }
              throw DocumentMergeConflict.changed
            }
          }
        }
      }
      documentStatus = responseIssue ?? (envelope.edits.isEmpty ? "No document changes"
        : authority.mode == .edit ? "Document edited" : "Proposal ready for review"
      )
    }
    guard let chatIndex = state.chats.firstIndex(where: { $0.id == chatID }),
      let messageIndex = state.chats[chatIndex].messages.firstIndex(where: { $0.id == pending.id }),
      state.chats[chatIndex].messages[messageIndex].state == .pending
    else { throw BoomError.stale("The pending response disappeared.") }
    let message = ChatMessage(id: pending.id, role: .assistant, text: answer, sources: pending.sources,
      state: responseIssue == nil ? .complete : .failed,
      provider: pending.provider, speaker: pending.speaker, failure: responseIssue,
      timestamp: state.chats[chatIndex].messages[messageIndex].timestamp)
    if recovering && responseIssue != nil { return message }
    state.chats[chatIndex].messages[messageIndex] = message
    if let documentStatus { status = documentStatus }
    return message
  }
  private func revalidateOnDisk(_ sources: [SourceReference], attachments: [SourceReference]) async throws {
    let (engine, publisher) = try pagedOwners()
    for source in sources where source.kind == "document" || source.kind == "writing-example" {
      let read = try await engine.currentDocumentRecordRetaining(publisher, documentID: source.id)
      let digest = try BoundedDocumentCapture.digest(read.value.document.revision)
      try await engine.abandonJoinedRootOutput(read.lease)
      guard digest == source.digest else { throw BoomError.stale(source.title) }
    }
    try revalidate(sources.filter { $0.kind == "media" || $0.kind == "attachment" }, attachments: attachments)
  }
  private func revalidateResponseSources(_ sources: [SourceReference], attachments: [SourceReference], targetID: UUID?) async throws {
    let trace = PerformanceTrace.begin("Request.SourceValidation")
    defer { PerformanceTrace.end("Request.SourceValidation", trace) }
    try await revalidateOnDisk(sources, attachments: attachments)
    if let targetID, !documentIndices.contains(where: { $0.id == targetID }) { throw BoomError.stale("The granted document was removed.") }
  }
  private func commit(_ proposal: StoredProposal) async throws {
    guard state.selectedDocument == proposal.document.id, let capture = proposal.capture,
      let commands = pagedCommands, let session = pagedSession else {
      throw BoomError.stale("Choose the captured document before accepting its proposal.")
    }
    try await revalidateResponseSources(proposal.documents, attachments: proposal.attachments, targetID: capture.documentID)
    let current = try await selectedPagedRecord(capture.documentID)
    guard current == capture.record, capture.generation == nil || session.generation == capture.generation else {
      throw DocumentMergeConflict.changed
    }
    let document = capture.modelSnapshot
    let planned = try await detachedWork {
      try DocumentTools.plan(proposal.patch, grant: DocumentGrant(mode: .propose, snapshot: document), current: document)
    }
    if planned.1.isEmpty {
      if let index = state.proposals.firstIndex(where: { $0.id == proposal.id }) { state.proposals[index].status = "already present" }
      return
    }
    let edits = try planned.1.map(capture.absoluteEdit)
    let installed = try await commands.applyCapturedEdits(expected: current, edits: edits, actionName: "Apply proposed edit")
    pagedSelectedRecord = installed
    captureCache.removeValue(forKey: capture.documentID)
    invalidateGhost()
    if let index = state.proposals.firstIndex(where: { $0.id == proposal.id }) {
      state.proposals[index].status = "applied"
      state.proposals[index].appliedRevision = try BoundedDocumentCapture.digest(installed.document.revision)
    }
    try await flush(); status = "Document edited"
  }
  func accept(_ id: UUID) {
    guard !isBusy, let proposal = state.proposals.first(where: { $0.id == id }), proposal.status == "pending" else { return }
    work("Applying the proposed edit…") { [weak self] flag in
      guard let self else { return }
      do { try await self.commit(proposal) }
      catch is DocumentMergeConflict {
        guard let chat = self.state.chats.first(where: { $0.id == proposal.chatID }),
          let answerIndex = chat.messages.firstIndex(where: { $0.id == proposal.messageID }),
          let question = chat.messages[..<answerIndex].last(where: { $0.role == .user }) else {
          self.status = "Your current text is preserved"; return
        }
        if let index = self.state.proposals.firstIndex(where: { $0.id == proposal.id }) { self.state.proposals[index].status = "superseded" }
        let vault = self.store.vault
        let receipt = try await detachedWork { () throws -> ConsultationReceipt? in
          vault.exists(.receipt, proposal.messageID) ? try vault.decode(ConsultationReceipt.self, kind: .receipt, id: proposal.messageID) : nil
        }
        let replay = ConsultationReplay(request: question.text, voice: receipt?.voice,
          attachmentIDs: proposal.attachments.map(\.id), previousAttemptID: receipt?.attemptID,
          generationPolicy: receipt?.generationPolicy,
          promptContract: receipt?.plan.promptContract ?? .textHistoryV1)
        self.status = "Preparing a fresh proposal…"
        let operation = self.foreground
        Task { @MainActor [weak self] in
          await operation?.value
          guard let self, !flag.isCancelled, self.canInfer, !self.isBusy,
            self.state.selectedChat == proposal.chatID, self.state.selectedDocument == proposal.document.id else { return }
          self.send(replay: replay)
        }
      }
      try await self.flush()
    }
  }
  func reject(_ id: UUID) {
    guard let index = state.proposals.firstIndex(where: { $0.id == id }) else { return }
    state.proposals[index].status = "rejected"
    scheduleSave()
  }
  func canUndo(_ proposal: StoredProposal) -> Bool {
    guard !isBusy, proposal.status == "applied", state.selectedDocument == proposal.document.id,
      let current = pagedSelectedRecord, pagedCommands?.manager.canUndo == true else { return false }
    return proposal.appliedRevision == (try? BoundedDocumentCapture.digest(current.document.revision))
  }
  func undoProposal(_ proposal: StoredProposal) {
    guard canUndo(proposal), let commands = pagedCommands else { return }
    commands.request(.undo)
    work("Undoing document edit…") { [weak self] _ in
      guard let self else { return }
      try await commands.joinPendingCommand()
      if let index = self.state.proposals.firstIndex(where: { $0.id == proposal.id }) {
        self.state.proposals[index].status = "undone"
      }
    }
  }
  func chatVoice(_ id: UUID) -> Voice? { state.voices.first { $0.id == id } }
  private func retainVoice(_ voice: Voice) {
    if let index = state.voices.firstIndex(where: { $0.id == voice.id }) { state.voices[index] = voice }
    else { state.voices.append(voice) }
    if !state.voiceVersions.contains(where: { $0.revision == voice.revision }) { state.voiceVersions.append(voice) }
  }
  private func applyChat(_ chat: ChatRecord) throws {
    guard let index = state.chats.firstIndex(where: { $0.id == chat.id }) else { throw BoomError.stale("The chat was removed.") }
    let voice = try chatVoice(chat.id).map { existing in
      try ProductCore.pinnedVoice(chat, slug: existing.slug, occupied: state.voices.filter { $0.id != chat.id }.map(\.slug))
    }
    state.chats[index] = chat
    if let voice { retainVoice(voice) }
    scheduleSave()
  }
  func openChatInstructions(_ id: UUID) {
    guard !isBusy else { return }
    if state.selectedChat != id { selectChat(id) }
    showingChatInstructions = id
  }
  func setChatInstructions(_ text: String, mention: String?, chatID: UUID) throws {
    guard !isBusy, var chat = state.chats.first(where: { $0.id == chatID }) else { throw BoomError.stale("The chat is unavailable.") }
    chat.instructions = try ProductCore.chatText(text, instructions: true)
    if let existing = chatVoice(chatID) {
      let voice = try ProductCore.pinnedVoice(chat, slug: mention ?? existing.slug,
        occupied: state.voices.filter { $0.id != chatID }.map(\.slug))
      guard let index = state.chats.firstIndex(where: { $0.id == chatID }) else { return }
      state.chats[index] = chat; retainVoice(voice); scheduleSave()
    } else { try applyChat(chat) }
    showingChatInstructions = nil
  }
  func pinChat(_ id: UUID) {
    guard !isBusy, let chat = state.chats.first(where: { $0.id == id }) else { return }
    do {
      let voice = try ProductCore.pinnedVoice(chat, slug: chatVoice(id)?.slug,
        occupied: state.voices.filter { $0.id != id }.map(\.slug))
      retainVoice(voice); scheduleSave(); status = "Pinned as @\(voice.slug)"
    } catch { composerIssue = error.localizedDescription; selectChat(id) }
  }
  func unpinChat(_ id: UUID) { guard !isBusy else { return }; state.voices.removeAll { $0.id == id }; scheduleSave() }
  private func sourceChat(for voice: Voice) -> ChatRecord {
    if let chat = state.chats.first(where: { $0.id == voice.id }) { return chat }
    let messages = voice.examples.flatMap { [ChatMessage(role: .user, text: $0.user),
      ChatMessage(role: .assistant, text: $0.assistant)] }
    return ChatRecord(id: voice.id, title: voice.name, messages: messages, instructions: voice.instructions)
  }
  func editVoice(_ voice: Voice) {
    guard !isBusy else { return }
    if !state.chats.contains(where: { $0.id == voice.id }) { state.chats.append(sourceChat(for: voice)) }
    selectChat(voice.id); scheduleSave()
  }
  func duplicateVoice(_ voice: Voice) {
    guard !isBusy else { return }
    let source = sourceChat(for: voice)
    let copy = ChatRecord(title: source.title + " copy", messages: source.messages, instructions: source.instructions)
    state.chats.append(copy); selectChat(copy.id); pinChat(copy.id)
  }
  func consultVoice(_ voice: Voice) {
    if state.selectedChat == voice.id { do { try newChat() } catch { report(error); return } }
    state.showChat = true; compactPane = "chat"; insertVoice(voice); scheduleSave()
  }
  func authorChatMessage(_ role: Role) {
    guard !isBusy else { return }
    authoredChatRole = role; composerFocusEpoch &+= 1
  }
  func appendAuthoredChatMessage() {
    guard let role = authoredChatRole, var chat = selectedChat else { return }
    do {
      let text = try ProductCore.chatText(draft)
      let attachments = pendingAttachments.compactMap { id in state.attachments.first(where: { $0.id == id }) }
      chat.messages.append(ChatMessage(role: role, text: text, sources: attachments.map(\.reference),
        authoredByUser: true, directAttachments: attachments.map(\.id)))
      try applyChat(chat); pendingAttachments = []; draft = ""; authoredChatRole = nil; composerIssue = nil
    } catch { composerIssue = error.localizedDescription }
  }
  func replaceChatMessage(_ text: String, id: UUID, chatID: UUID) throws {
    guard !isBusy, var chat = state.chats.first(where: { $0.id == chatID }),
      let index = chat.messages.firstIndex(where: { $0.id == id }), chat.messages[index].state == .complete else {
      throw BoomError.stale("The completed message is unavailable.")
    }
    let validated = try ProductCore.chatText(text)
    let original = chat.messages[index]
    chat.messageVersions = (chat.messageVersions ?? []) + [original]
    chat.messages[index] = ChatMessage(role: original.role, text: validated,
      context: original.context, sources: original.sources, provider: original.provider,
      speaker: original.speaker, authoredByUser: true, editedFrom: original.id, timestamp: original.timestamp, directAttachments: original.directAttachments)
    try applyChat(chat); editingChatMessage = nil
  }
  func exportChat(_ chatID: UUID) {
    guard let chat = state.chats.first(where: { $0.id == chatID }) else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = chat.title + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    exportFile(to: url) {
      let instructions = (chat.instructions ?? "").isEmpty ? "" : "## Instructions\n\n" + (chat.instructions ?? "") + "\n\n"
      let text = "# " + chat.title + "\n\n" + instructions + chat.messages.map { message in
        "## " + (message.speaker?.name ?? (message.role == .user ? "Human" : "Bloom"))
          + " · " + message.state.rawValue + "\n\n" + message.text
          + (message.failure.map { "\n\nStatus: " + $0 } ?? "")
          + (message.context.isEmpty ? "" : "\n\nCaptured context:\n\n" + message.context)
          + (message.speaker?.voiceRevision.map { "\n\nVoice revision: " + $0 } ?? "")
          + (message.editedFrom.map { "\n\nEdited by you; original message: " + $0.uuidString } ??
            (message.authoredByUser == true && message.role == .assistant ? "\n\nWritten by you." : ""))
      }.joined(separator: "\n\n") + "\n"
      return Data(text.utf8)
    }
  }
  func exportVoice(_ voice: Voice) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = voice.slug + ".json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    exportFile(to: url) {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return try encoder.encode(voice)
    }
  }
  /// Export owns a captured value and a user-selected URL. It neither consumes
  /// a generation slot nor reads mutable workspace state from its worker.
  func exportFile(to url: URL, contents: @escaping @Sendable () throws -> Data) {
    let id = UUID(), target = url.standardizedFileURL
    let previous = exportTasks[target]?.task
    let task = Task { [weak self] in
      if let previous { await previous.value }
      do { try await ExplicitFileExport.write(to: target, contents: contents) }
      catch { self?.report(error) }
      if self?.exportTasks[target]?.id == id { self?.exportTasks[target] = nil }
    }
    exportTasks[target] = (id, task, nil, nil)
  }
  func importVoice() {
    guard !isBusy else { return }
    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    work("Importing voice…") { [weak self] _ in
      guard let self else { return }
      let imported = try await detachedWork {
        let data = try AttachmentProcessor.readGranted(url)
        guard data.count <= 2_097_152 else { throw BoomError.budget("Voice exceeds 2 MiB.") }
        let voice = try JSONDecoder().decode(Voice.self, from: data)
        guard try ProductCore.voice(voice.draft).revision == voice.revision else { throw BoomError.invalid("Voice revision changed.") }
        return voice
      }
      guard !self.state.chats.contains(where: { $0.id == imported.id }),
        !self.state.voices.contains(where: { $0.id == imported.id || $0.slug == imported.slug }) else {
        throw BoomError.invalid("This voice identity or @name already exists. Duplicate the existing chat to make another voice.")
      }
      self.state.chats.append(self.sourceChat(for: imported)); self.retainVoice(imported)
      self.selectChat(imported.id); try await self.flush()
    }
  }
  func scheduleCompletion() {
    guard !showingCandidates, librarySearch.isEmpty, state.autocomplete, showsDocument, !isBusy, baseReady,
      let id = selectedDocumentID, let view = pagedInput?.activeView,
      (try? pagedInput?.currentDocumentSelection().utf16Length) == 0,
      view.selectedRange().length == 0, view.window?.firstResponder === view,
      !view.hasMarkedText(), caret > 0, !candidateIsCurrent || ghostText.isEmpty else { return }
    let previous = ghostTask
    ghostFlag?.cancel(); previous?.cancel()
    let capturedEpoch = epoch, absoluteCaret = UInt64(caret), profile = samplingProfile
    let flag = CancellationFlag(); ghostFlag = flag
    ghostTask = Task { [weak self] in
      if let previous { await previous.value }
      do {
        try await Task.sleep(for: .milliseconds(650))
        guard let self, self.epoch == capturedEpoch, !self.isBusy, !self.showingCandidates else { return }
        let capture = try await self.captureDocument(id, prefixAt: absoluteCaret)
        guard self.epoch == capturedEpoch else { return }
        self.writingCapture = capture
        try await self.generateCandidates(document: capture.modelSnapshot,
          offset: capture.localCaret(absoluteCaret), profile: profile, count: 1, maxTokens: 64, flag: flag, capture: capture)
      } catch is CancellationError {} catch {
        if let self, self.epoch == capturedEpoch { self.status = "Autocomplete: " + error.localizedDescription }
      }
    }
  }
  var canExploreWriting: Bool {
    let trace = PerformanceTrace.begin("Editor.WritingAvailability")
    defer { PerformanceTrace.end("Editor.WritingAvailability", trace) }
    guard baseReady, !isBusy, hasSelectedDocument, caret > 0, let view = pagedInput?.activeView,
      (try? pagedInput?.currentDocumentSelection().utf16Length) == 0,
      view.selectedRange().length == 0, !view.hasMarkedText() else { return false }
    return true
  }
  func setAutocomplete(_ enabled: Bool) {
    state.autocomplete = enabled
    invalidateGhost(); scheduleSave()
    if enabled { scheduleCompletion() }
  }
  func exploreWriting() {
    guard canExploreWriting, let id = selectedDocumentID else { return }
    let absoluteCaret = UInt64(caret), profile = samplingProfile
    writingIssue = nil; showingCandidates = true
    work("Exploring continuations…") { [weak self] flag in
      guard let self else { return }
      do {
        let capture = try await self.captureDocument(id, prefixAt: absoluteCaret)
        self.writingCapture = capture
        try await self.generateCandidates(document: capture.modelSnapshot,
          offset: capture.localCaret(absoluteCaret), profile: profile, count: 3, maxTokens: 256, flag: flag, capture: capture)
      } catch is CancellationError { throw CancellationError() }
      catch { self.writingIssue = error.localizedDescription }
    }
  }
  func openWritingExamples() {
    guard !isBusy, let id = selectedDocumentID else { return }
    editingWritingExamples = WritingExamplesRequest(manuscriptID: id)
  }
  func moveWritingExample(_ id: UUID, by delta: Int) {
    guard let index = writingExampleIDs.firstIndex(of: id), writingExampleIDs.indices.contains(index + delta) else { return }
    writingExampleIDs.swapAt(index, index + delta); invalidateGhost()
  }
  func addWritingExample(title: String, prose: String, manuscriptID: UUID) async throws {
    guard state.selectedDocument == manuscriptID, writingExampleIDs.count < 32 else { throw BoomError.stale("Choose the original manuscript and at most 32 examples.") }
    let validated = try ProductCore.writingExample(title: title, text: prose)
    let document = DocumentSnapshot(title: validated.title, text: validated.text)
    try await importAuthoredDocument(document, selecting: false, flag: CancellationFlag())
    guard state.selectedDocument == manuscriptID else { throw BoomError.stale("The manuscript changed while importing the example.") }
    writingExampleIDs.append(document.id)
    invalidateGhost(); try await flush()
  }
  func importWritingExamples(manuscriptID: UUID) {
    guard !isBusy, state.selectedDocument == manuscriptID else { return }
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    work("Importing writing examples…") { [weak self] flag in
      guard let self else { return }
      do {
        let imported = try await detachedWork {
          try urls.map { url -> ProductCore.WritingExample in
            try flag.check()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try AttachmentProcessor.readGranted(url)
            guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else { throw BoomError.invalid("Choose UTF-8 prose of at most 2 MiB.") }
            return try ProductCore.writingExample(title: url.deletingPathExtension().lastPathComponent, text: text)
          }
        }
        guard self.state.selectedDocument == manuscriptID, self.writingExampleIDs.count + imported.count <= 32 else { throw BoomError.stale("The manuscript changed, or the selection exceeds 32 examples.") }
        for example in imported { try await self.addWritingExample(title: example.title, prose: example.text, manuscriptID: manuscriptID) }
      } catch { self.writingIssue = error.localizedDescription }
    }
  }
  private func generateCandidates(document: DocumentSnapshot, offset: Int, profile: SamplingProfile,
    count: Int, maxTokens: Int, flag: CancellationFlag, previous: CandidateBundle? = nil,
    replay: WritingCandidate? = nil, capture: BoundedDocumentCapture? = nil) async throws {
    let capturedEpoch = epoch
    let runner = try await runnerForGeneration(.writing, flag: flag)
    if let execution = replay?.batch, let seed = replay?.seed {
      try ProductCore.validateWritingBatch(execution, seed: seed)
    }
    let seeds = replay.map { $0.batch?.seeds ?? [$0.seed] }
      ?? (0..<count).map { _ in UInt64.random(in: .min ... .max) }
    try ProductCore.admitWritingBatch(width: seeds.count, prompt: 1, output: maxTokens, capacity: 16_384)
    try await flush()
    let authored = try await detachedWork { try ProductCore.authoredPrefix(document, caret: offset) }
    let capturedExamples = writingExampleIDs
    var exampleCaptures: [BoundedDocumentCapture] = []
    if previous == nil {
      for id in capturedExamples { try flag.check(); exampleCaptures.append(try await captureDocument(id, maximumBytes: 16_384)) }
    }
    let examples = exampleCaptures.map(\.modelSnapshot)
    let mediaText = previous?.recipe.sourcePrompt ?? ([authored] + examples.map(\.text)).joined(separator: "\n\n")
    let media = try await writingMedia(in: mediaText, flag: flag)
    let fitOwner: PromptCacheOwner? = replay == nil
      ? PromptCacheOwner(namespace: inferenceCacheNamespace, entity: document.id, route: .writing) : nil
    let retainedCapture = capture ?? previous?.recipe.capture
    let admissionSources = previous?.recipe.sources ?? ([retainedCapture?.source].compactMap { $0 }
      + exampleCaptures.map(\.source) + media.map { $0.reference.source })
    let pairedAdmission = makePairedContextAdmission(runner: runner, purpose: .writing,
      owner: fitOwner, flag: flag) { [weak self] in
      guard let workspace = self else { throw CancellationError() }
      if replay == nil {
        try await workspace.validateWritingAdmissionSource(document: document, offset: offset,
          examples: capturedExamples, sources: admissionSources, capturedEpoch: capturedEpoch, flag: flag, capture: retainedCapture)
      } else {
        try await MainActor.run {
          try flag.check()
          guard workspace.epoch == capturedEpoch, workspace.selectedDocumentID == document.id else {
            throw BoomError.stale("The replay owner changed.")
          }
        }
      }
    }
    var recipe: CompletionRecipe
    if let previous { recipe = previous.recipe }
    else {
      let sources = admissionSources
      try await revalidateOnDisk(sources, attachments: [])
      recipe = try await runner.completionRecipe(document: document, caret: offset,
        sources: sources, examples: examples.map(\.text), profile: profile,
        maxTokens: maxTokens, flag: flag, batchWidth: seeds.count, media: media,
        cacheOwner: fitOwner, pairedAdmission: pairedAdmission)
    }
    recipe.capture = retainedCapture
    let capturedRecipe = recipe
    try await detachedWork { try ProductCore.validateWritingRecipe(capturedRecipe) }
    guard recipe.model == runner.identity else { throw BoomError.stale("Replay requires the original writing model.") }
    let executionPolicy: ModelGenerationPolicy
    if let replay {
      executionPolicy = try replay.coldReplayPolicy(recipe: recipe,
        loadedModel: runner.identity, loadedPolicy: runner.generationPolicy)
    } else {
      executionPolicy = try ProductCore.resolvedGenerationPolicy(recipe.generationPolicy, loaded: runner.generationPolicy)
    }
    // Only recorded cold attempts may replay until exact warm ancestry exists.
    let cacheOwner: PromptCacheOwner? = replay == nil
      ? PromptCacheOwner(namespace: inferenceCacheNamespace, entity: recipe.document.id, route: .writing)
      : nil
    var bundle = CandidateBundle(id: replay == nil ? previous?.id ?? UUID() : UUID(), recipe: recipe,
      origin: previous?.origin ?? state.manuscriptOrigins[document.id],
      candidates: replay == nil ? previous?.candidates ?? [] : [],
      selected: replay == nil ? previous?.selected ?? 0 : replay?.batch?.lane ?? 0)
    writingFlag = flag
    defer { if writingFlag === flag { writingFlag = nil } }
    do {
      try flag.check()
      let startIndex = bundle.candidates.count
      for (lane, seed) in seeds.enumerated() {
        bundle.candidates.append(WritingCandidate(id: UUID(), seed: seed, text: "", state: .pending,
          promptTokens: 0, outputTokens: 0, tokenIDs: [], stopReason: nil,
          batch: seeds.count > 1 ? WritingBatchExecution(seeds: seeds, lane: lane) : nil))
      }
      if state.selectedDocument == recipe.document.id, !flag.isCancelled { candidates = bundle }
      // Every row's identity, seed and captured batch exist before shared prefill.
      let pendingVault = store.vault, pendingBundle = bundle
      try await detachedWork { try pendingVault.encode(pendingBundle, kind: .candidate, id: pendingBundle.id) }
      if !state.candidateIDs.contains(bundle.id) { state.candidateIDs.append(bundle.id) }
      try await flush()
      refreshContinuationHistory()
      let bundleID = bundle.id, checkpointStore = store
      let generations = seeds.enumerated().map { lane, seed in
        GenerationIdentity(kind: .writing, operationID: flag.operationID,
          recordID: bundleID, attemptID: bundle.candidates[startIndex + lane].id, model: recipe.model,
          seed: seed, requestDigest: recipe.promptDigest, maxTokens: recipe.maxTokens,
          generationPolicy: recipe.generationPolicy, batch: bundle.candidates[startIndex + lane].batch)
      }
      let orderedMedia = try (recipe.media ?? []).map { reference -> WritingMediaData in
        guard let payload = media.first(where: { $0.reference == reference }) else { throw BoomError.stale(reference.name) }; return payload
      }
      let deliveryTrace = PerformanceTrace.firstDelivery()
      let joinedRetention = try makeJoinedRetentionRequest(owner: cacheOwner,
        runner: runner, policy: executionPolicy, operationID: flag.operationID)
      defer { finishJoinedRetentionRequest(joinedRetention) }
      let results = try await runner.runBatch(rawPrompt: recipe.prompt, media: orderedMedia, maxTokens: recipe.maxTokens,
          settings: recipe.settings, seeds: seeds, flag: flag, background: maxTokens == 64 && !showingCandidates,
          cacheOwner: cacheOwner, executionPolicy: executionPolicy, joinedRetention: joinedRetention,
          beforeCachePublication: { [weak self, recipe = capturedRecipe] in
            guard let self else { throw CancellationError() }
            if replay == nil { try await self.revalidateOnDisk(recipe.sources, attachments: []) }
            try await MainActor.run {
              try flag.check()
              guard self.writingFlag === flag, self.epoch == capturedEpoch,
                self.state.selectedDocument == recipe.document.id else {
                throw BoomError.stale("The writing source changed before prompt-cache publication.")
              }
            }
          },
          pairedAdmission: pairedAdmission,
          onCheckpoint: { [weak self, recipe = capturedRecipe] updates in
            for update in updates {
              try await checkpointStore.checkpoint(update.progress, identity: generations[update.lane],
                stopReason: update.stopReason, stopTokenID: update.stopTokenID)
            }
            guard let owner = self else { return }
            // One tensor step publishes one complete UI snapshot. Disk journals
            // remain per attempt; rendering never observes a half-published step.
            await MainActor.run {
              guard owner.writingFlag === flag, !flag.isCancelled,
                owner.state.selectedDocument == recipe.document.id,
                owner.candidates?.id == bundleID, var snapshot = owner.candidates else { return }
              for update in updates {
                let index = startIndex + update.lane, generation = generations[update.lane]
                guard snapshot.candidates.indices.contains(index),
                  snapshot.candidates[index].id == generation.attemptID,
                  snapshot.candidates[index].state == .pending else { continue }
                snapshot.candidates[index].retain(update.progress)
                if let stop = update.stopReason {
                  snapshot.candidates[index].state = stop == "cancelled" ? .cancelled : (update.progress.text.isEmpty ? .failed : .complete)
                  snapshot.candidates[index].stopReason = stop
                  snapshot.candidates[index].stopTokenID = update.stopTokenID
                }
              }
              owner.candidates = snapshot
              if updates.contains(where: { !$0.progress.text.isEmpty }) { deliveryTrace?.published() }
              if owner.epoch == capturedEpoch, let selected = updates.first(where: { startIndex + $0.lane == snapshot.selected }) {
                owner.showCandidateGhost(selected.progress.text, recipe: recipe, epoch: capturedEpoch)
              }
            }

          })
      for (lane, result) in results.enumerated() {
        let index = startIndex + lane
        bundle.candidates[index].text = result.text
        bundle.candidates[index].state = result.stopReason == "cancelled" ? .cancelled : (result.text.isEmpty ? .failed : .complete)
        bundle.candidates[index].promptTokens = result.promptTokens
        bundle.candidates[index].outputTokens = result.outputTokens
        bundle.candidates[index].tokenIDs = result.tokenIDs
        bundle.candidates[index].stopReason = result.stopReason
        bundle.candidates[index].stopTokenID = result.stopTokenID
        bundle.candidates[index].executionOrigin = result.executionOrigin
      }
      if let current = candidates, current.id == bundle.id, bundle.candidates.indices.contains(current.selected) {
        bundle.selected = current.selected
      }
      if state.selectedDocument == recipe.document.id, candidates?.id == bundle.id, writingFlag === flag {
        candidates = bundle
        if epoch == capturedEpoch { showCandidateGhost(bundle.candidates[bundle.selected].text, recipe: recipe, epoch: capturedEpoch) }
      }
      let vault = store.vault, saved = bundle
      try await detachedWork { try vault.encode(saved, kind: .candidate, id: saved.id) }
      try await flush()
      refreshContinuationHistory()
      try flag.check()
      status = "\(bundle.candidates.count) continuation\(bundle.candidates.count == 1 ? "" : "s") · "
        + (recipe.capture?.isWholeSource == true && recipe.omittedPrefixCharacters == 0 ? "full preceding manuscript" : "captured source range")
    } catch {
      if let current = candidates, current.id == bundle.id { bundle = current }
      for index in bundle.candidates.indices where bundle.candidates[index].state == .pending {
        let journal = try await store.writingCheckpoint(bundle: bundle, candidate: bundle.candidates[index])
        bundle.candidates[index].finishInterrupted(journal, failed: !flag.isCancelled,
          reason: flag.isCancelled ? "cancelled" : "failed")
      }
      if state.selectedDocument == recipe.document.id, candidates?.id == bundle.id, writingFlag === flag {
        candidates = bundle
      }
      let vault = store.vault, saved = bundle
      try await detachedWork { try vault.encode(saved, kind: .candidate, id: saved.id) }
      if !state.candidateIDs.contains(bundle.id) { state.candidateIDs.append(bundle.id) }
      try await flush()
      refreshContinuationHistory()
      throw error
    }
  }
  func toggleWritingExample(_ id: UUID) {
    if writingExampleIDs.contains(id) { writingExampleIDs.removeAll { $0 == id } }
    else { guard id != state.selectedDocument, writingExampleIDs.count < 32 else { return }; writingExampleIDs.append(id) }
    invalidateGhost()
  }
  private func resetContinuationView() {
    candidates = nil; showingCandidates = false; writingIssue = nil
    savedExplorations = []; latestSavedCandidate = nil
    refreshContinuationHistory()
  }
  private func refreshContinuationHistory() {
    historyTask?.cancel()
    let request = UUID(); historyRequest = request
    guard let documentID = state.selectedDocument else { return }
    let ids = state.candidateIDs, capturedStore = store
    historyTask = Task { [weak self] in
      do {
        let history = try await capturedStore.candidateHistory(for: documentID, ids: ids)
        guard let self, !Task.isCancelled, self.historyRequest == request,
          self.state.selectedDocument == documentID else { return }
        self.savedExplorations = history.explorations
        self.latestSavedCandidate = history.latest
      } catch {
        guard let self, !Task.isCancelled, self.historyRequest == request,
          self.state.selectedDocument == documentID else { return }
        self.writingIssue = error.localizedDescription
      }
    }
  }
  var canShowContinuations: Bool {
    guard let documentID = state.selectedDocument else { return false }
    return showingCandidates || (!isBusy && (candidates?.recipe.document.id == documentID || latestSavedCandidate != nil))
  }
  func showContinuations() {
    if showingCandidates { showingCandidates = false; return }
    guard !isBusy else { return }
    if candidates?.recipe.document.id == state.selectedDocument { showingCandidates = true }
    else if let id = latestSavedCandidate { reviewContinuation(id) }
  }
  func reviewContinuation(_ id: UUID) {
    guard !isBusy, let documentID = selectedDocumentID, state.candidateIDs.contains(id) else { return }
    let generation = pagedSession?.generation, capturedCaret = caret
    work("Opening continuations…") { [weak self] flag in
      guard let self else { return }
      let capturedEpoch = self.epoch, bundle = try await self.store.readCandidate(id)
      try flag.check()
      guard self.activeFlag === flag, self.selectedDocumentID == documentID,
        self.pagedSession?.generation == generation, self.caret == capturedCaret, self.epoch == capturedEpoch,
        bundle.recipe.document.id == documentID else { throw BoomError.stale("The continuation source changed.") }
      self.candidates = bundle; self.showingCandidates = true; self.writingIssue = nil
      self.refreshContinuationHistory()
    }
  }
  func dismissCandidates() { invalidateGhost(); showingCandidates = false; candidates = nil }
  private func showCandidateGhost(_ text: String, recipe: CompletionRecipe, epoch: UInt64) {
    guard let capture = recipe.capture, let session = pagedSession, let view = pagedInput?.activeView,
      selectedDocumentID == capture.documentID, session.generation == capture.generation,
      (try? pagedInput?.currentDocumentSelection().utf16Length) == 0,
      session.sealedRevision == capture.record.document.revision, self.epoch == epoch,
      view.completionCaretUTF16 >= 0, view.completionCaretUTF16 != NSNotFound, recipe.caretUTF16 >= 0,
      UInt64(view.completionCaretUTF16) == capture.window.utf16Start + UInt64(recipe.caretUTF16),
      let identity = completionSourceIdentity, !view.hasMarkedText(),
      let visible = GemmaPrompt.visibleCompletion(text) else { return }
    guard let stamp = try? GhostStamp(documentID: capture.documentID, revision: identity,
      caretUTF16: view.completionCaretUTF16, epoch: epoch) else { return }
    ghostSources = recipe.sources; ghostStamp = stamp; ghostText = visible
    view.showGhost(visible, stamp: stamp)
  }
  var candidateIsCurrent: Bool {
    guard let recipe = candidates?.recipe, let capture = recipe.capture, let session = pagedSession,
      (try? pagedInput?.currentDocumentSelection().utf16Length) == 0,
      selectedDocumentID == capture.documentID, session.generation == capture.generation,
      session.sealedRevision == capture.record.document.revision,
      let view = pagedInput?.activeView, !view.hasMarkedText(), view.selectedRange().length == 0,
      view.completionCaretUTF16 >= 0, view.completionCaretUTF16 != NSNotFound, recipe.caretUTF16 >= 0,
      UInt64(view.completionCaretUTF16) == capture.window.utf16Start + UInt64(recipe.caretUTF16) else { return false }
    return (try? revalidate(recipe.sources, attachments: [])) != nil
  }
  func selectCandidate(_ index: Int) {
    guard let bundle = candidates, bundle.candidates.indices.contains(index) else { return }
    candidates?.selected = index
    ghostText = ""; ghostStamp = nil; ghostSources = []; pagedInput?.activeView?.clearGhost()
    if candidateIsCurrent { showCandidateGhost(bundle.candidates[index].text, recipe: bundle.recipe, epoch: epoch) }
  }
  func replayCandidate(_ index: Int) {
    guard canReplayCandidate(index), let bundle = candidates, bundle.recipe.document.id == state.selectedDocument,
      bundle.candidates.indices.contains(index) else { return }
    showingCandidates = true
    work("Replaying this seed…") { [weak self] flag in
      guard let self else { return }
      try await self.generateCandidates(document: bundle.recipe.document, offset: bundle.recipe.caretUTF16,
        profile: bundle.recipe.profile, count: 1, maxTokens: bundle.recipe.maxTokens, flag: flag,
        previous: bundle, replay: bundle.candidates[index])
    }
  }
  func canReplayCandidate(_ index: Int) -> Bool {
    guard !isBusy, let bundle = candidates, bundle.candidates.indices.contains(index),
      bundle.candidates[index].state == .complete,
      bundle.recipe.model == (baseRunner?.identity ?? writingModelIdentity),
      let policy = baseRunner?.generationPolicy ?? writingGenerationPolicy else { return false }
    do {
      _ = try bundle.candidates[index].coldReplayPolicy(recipe: bundle.recipe,
        loadedModel: baseRunner?.identity ?? writingModelIdentity ?? "", loadedPolicy: policy)
      return true
    } catch { return false }
  }
  func acceptCandidateWord(_ index: Int) {
    guard !isBusy, candidateIsCurrent, let bundle = candidates, bundle.candidates.indices.contains(index),
      bundle.candidates[index].state == .complete, let view = pagedInput?.activeView else { return }
    view.window?.makeFirstResponder(view); selectCandidate(index)
    _ = view.acceptNextGhostWord()
  }
  func acceptCandidate(_ index: Int) {
    guard candidateIsCurrent, let bundle = candidates, bundle.candidates.indices.contains(index),
      bundle.candidates[index].state == .complete, let view = pagedInput?.activeView else { return }
    let text = bundle.candidates[index].text
    cancel(); showingCandidates = false
    view.window?.makeFirstResponder(view)
    view.insertText(text, replacementRange: view.selectedRange())
  }
  func branchCandidate(_ index: Int) {
    guard !isBusy, let bundle = candidates, bundle.candidates.indices.contains(index),
      bundle.candidates[index].state == .complete, let capture = bundle.recipe.capture else { return }
    let continuation = bundle.candidates[index].text
    work("Branching document…") { [weak self] flag in
      guard let self else { return }
      let (engine, _) = try self.pagedOwners()
      let id = UUID()
      let url = try await detachedWork {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-branch-\(UUID().uuidString).md")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BoomError.unavailable("Could not create a branch stream.") }
        return url
      }
      let file = try await detachedWork { try FileHandle(forWritingTo: url) }
      var closeAttempted = false
      do {
        try await engine.export(capture.record.document.revision, to: file)
        closeAttempted = true
        try await detachedWork { try file.close() }
      } catch {
        let original = error
        if !closeAttempted {
          do { try await detachedWork { try file.close() } }
          catch { throw WorkspacePagedImportFailure(original: original, cleanup: error, url: url) }
        }
        throw original
      }
      try await self.importPagedDocument(url, title: capture.title + " · branch", documentID: id, flag: flag)
      let position = capture.window.utf16Start + UInt64(bundle.recipe.caretUTF16)
      guard let commands = self.pagedCommands else { throw BoomError.stale("The branch lost its native command owner.") }
      await Task.yield()
      guard let mounted = self.pagedInput?.activeView, let window = mounted.window,
        window.isKeyWindow, window.makeFirstResponder(mounted), window.firstResponder === mounted else {
        throw BoomError.stale("The branch has not received its native editor focus.")
      }
      try await commands.navigate(toUTF16: position, selectingUTF16: PagedNativeNavigationSelection(utf16Offset: position, utf16Length: 0))
      guard let view = self.pagedInput?.activeView else { throw BoomError.stale("The branch lost its editor.") }
      view.insertText(continuation, replacementRange: view.selectedRange())
      if let error = view.boundedStorage.mutationFailure { throw error }
      self.state.manuscriptOrigins[id] = ManuscriptOrigin(documentID: capture.documentID, revision: capture.revisionDigest,
        bundleID: bundle.id, candidateID: bundle.candidates[index].id)
      try await self.flush()
      try await detachedWork { try FileManager.default.removeItem(at: url) }
      self.showingCandidates = false
    }
  }
  func takeGhost(documentID: UUID, caret: Int) -> String? {
    guard selectedDocumentID == documentID, let stamp = ghostStamp, let identity = completionSourceIdentity,
      (try? pagedInput?.currentDocumentSelection().utf16Length) == 0,
      let view = pagedInput?.activeView,
      stamp.accepts(documentID: documentID, revision: identity, caretUTF16: caret, epoch: epoch, hasMarkedText: view.hasMarkedText()),
      view.completionCaretUTF16 == caret, !ghostText.isEmpty,
      ghostSourcesRemainCurrent(ghostSources, manuscriptID: documentID) else {
      invalidateGhost(); return nil
    }
    let value = ghostText; invalidateGhost(); return value
  }
  func takeGhostChunk(documentID: UUID, caret: Int) -> CompletionSegment? {
    let sources = ghostSources
    guard let whole = takeGhost(documentID: documentID, caret: caret) else { return nil }
    let chunk = CompletionNavigation.nextChunk(whole)
    return CompletionSegment(
      accepted: chunk.accepted, remaining: chunk.remaining, whole: whole, sources: sources)
  }
  func ghostSourcesRemainCurrent(_ sources: [SourceReference], manuscriptID: UUID) -> Bool {
    (try? revalidate(sources.filter { $0.id != manuscriptID }, attachments: [])) != nil
  }
  func resumeGhost(_ text: String, documentID: UUID, caret: Int, sources: [SourceReference]) {
    guard !text.isEmpty, selectedDocumentID == documentID, let view = pagedInput?.activeView,
      (try? pagedInput?.currentDocumentSelection().utf16Length) == 0,
      view.completionCaretUTF16 == caret, view.selectedRange().length == 0, !view.hasMarkedText(),
      ghostSourcesRemainCurrent(sources, manuscriptID: documentID), let identity = completionSourceIdentity else { return }
    self.caret = caret
    guard let stamp = try? GhostStamp(documentID: documentID, revision: identity, caretUTF16: caret, epoch: epoch) else { return }
    ghostSources = sources; ghostStamp = stamp; ghostText = text
    view.showGhost(text, stamp: stamp)
  }
  func navigateGhost(_ direction: Int) {
    guard let bundle = candidates, candidateIsCurrent else { exploreWriting(); return }
    if bundle.candidates.count == 1 {
      guard !isBusy else { return }
      work("Generating alternatives…") { [weak self] flag in
        guard let self else { return }
        try await self.generateCandidates(document: bundle.recipe.document, offset: bundle.recipe.caretUTF16,
          profile: bundle.recipe.profile, count: 2, maxTokens: bundle.recipe.maxTokens, flag: flag, previous: bundle)
        self.selectCandidate(direction > 0 ? 1 : 2)
      }
    } else {
      selectCandidate((bundle.selected + direction + bundle.candidates.count) % bundle.candidates.count)
    }
  }
  func importFolder() {
    guard !isBusy, layout.isAuthor else { return }
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Import"
    guard panel.runModal() == .OK, let root = panel.url else { return }
    work("Importing folder…") { [weak self] flag in
      guard let self else { return }
      let scoped = root.startAccessingSecurityScopedResource()
      defer { if scoped { root.stopAccessingSecurityScopedResource() } }
      let files = try await detachedWork {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
          throw BoomError.unavailable("The chosen folder cannot be read.")
        }
        var files: [(URL, String)] = [], entries = 0
        while let object = iterator.nextObject() {
          guard let url = object as? URL else { continue }
          try flag.check(); entries += 1
          guard entries <= 4_096 else { throw BoomError.budget("Import at most 4,096 folder entries at a time.") }
          let values = try url.resourceValues(forKeys: Set(keys))
          if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
          let relative = String(url.path.dropFirst(root.path.count + 1))
          guard relative.split(separator: "/").count <= 16 else { throw BoomError.budget("The folder exceeds 16 levels.") }
          guard values.isRegularFile == true, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else { continue }
          guard files.count < 512 else { throw BoomError.budget("Import at most 512 text files at a time.") }
          files.append((url, relative))
        }
        if let failure { throw failure }
        return files.sorted { $0.1 < $1.1 }
      }
      let folder = ImportedFolder(id: UUID(), name: root.lastPathComponent)
      self.state.importedFolders = (self.state.importedFolders ?? []) + [folder]
      for (url, path) in files {
        try flag.check()
        let id = UUID()
        try await self.importPagedDocument(url, title: url.deletingPathExtension().lastPathComponent,
          documentID: id, selecting: false, flag: flag)
        if let imported = self.state.importedFiles?[id] {
          self.state.importedFiles?[id] = ImportedFile(folderID: folder.id, path: path,
            originalDigest: imported.originalDigest, originalRevision: imported.originalRevision)
        }
      }
      try await self.flush()
      self.status = "Imported \(files.count) documents"
    }
  }
  func importDocument() {
    guard !isBusy else { return }
    finishComposition()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText, .utf8PlainText, .text]
    panel.allowsMultipleSelection = true; panel.prompt = "Import"
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    work("Importing documents…") { [weak self] flag in
      guard let self else { return }
      try await self.importDocuments(urls, flag: flag)
    }
  }
  func importDocuments(_ urls: [URL], flag: CancellationFlag) async throws {
    for url in urls {
      try flag.check()
      try await importPagedDocument(url, title: url.deletingPathExtension().lastPathComponent, flag: flag)
    }
  }
  func exportDocument(_ id: UUID? = nil) {
    guard let documentID = id ?? selectedDocumentID,
      let index = documentIndices.first(where: { $0.id == documentID }) else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = index.title + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { _ = try exportPagedDocument(to: url, documentID: documentID) } catch { report(error) }
  }
  /// The existing export task registry owns the real producer before any
  /// await. Same-destination operations join in order, and shutdown joins the
  /// observer only after its actual producer completes. Failed results remain
  /// reachable here, including any unreleased source/file-publication custody.
  @discardableResult
  func exportPagedDocument(to url: URL, documentID: UUID? = nil,
    cancellation: PagedTextCancellation = PagedTextCancellation()) throws -> Task<URL, Error> {
    try requirePagedOperation()
    guard let documentID = documentID ?? selectedDocumentID else { throw BoomError.stale("No source is selected for export.") }
    let target = url.standardizedFileURL, id = UUID()
    guard pagedExportTaskCount < Self.maximumPagedExportTasks,
      exportTasks[target] != nil || exportTasks.count < Self.maximumPagedExportTasks else {
      throw BoomError.budget("The existing export registry has eight pending or retained destinations.")
    }
    let (engine, publisher) = try pagedOwners()
    let selected = pagedSelectedRecord?.document.id == documentID
    let session = selected ? pagedSession : nil
    guard !selected || session != nil else { throw BoomError.stale("The selected source has no actual native session.") }
    let generation = session?.generation, previous = exportTasks[target]
    pagedExportTaskCount += 1
    let producer = Task<URL, Error> { [weak self] in
      try await withTaskCancellationHandler {
        if let previous {
          await previous.task.value
          if let result = previous.pagedResult { _ = try await result.value }
          if let result = previous.clipboardResult { try await result.value }
        }
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
        guard let self, self.pagedEngine === engine, self.pagedPublisher === publisher else {
          throw BoomError.stale("The captured export lost its actual ordinary workspace owners.")
        }
        if let failure = self.pagedFirstFailure { throw failure }
        guard !self.pagedTransition else { throw BoomError.stale("A source transition preceded this export capture.") }
        var captured: PagedDocumentRootRecord?
        if let session, let generation {
          guard self.pagedSession === session, session.generation == generation else {
            throw BoomError.stale("Later source input preceded this export capture.")
          }
          let revision = try await session.flush(through: generation)
          let record = session.sealedRootRecord
          guard self.pagedSession === session, session.generation == generation,
            session.sealedGeneration == generation, record.document.revision == revision else {
            throw BoomError.stale("The exported native prefix changed before its actual full-record capture.")
          }
          captured = record
        }
        if captured == nil {
          let read = try await engine.currentDocumentRecordRetaining(publisher, documentID: documentID)
          captured = read.value
          try await engine.abandonJoinedRootOutput(read.lease)
        }
        guard let captured, captured.document.id == documentID else { throw BoomError.stale("Actual export admission returned another source.") }
        return try await self.store.exportPagedDocument(captured,
          engine: engine, publisher: publisher, to: target, cancellation: cancellation)
      } onCancel: {
        cancellation.cancel()
        previous?.pagedResult?.cancel()
        previous?.clipboardResult?.cancel()
      }
    }
    let observer = Task { [weak self] in
      defer { self?.pagedExportTaskCount -= 1 }
      do {
        _ = try await producer.value
        if self?.exportTasks[target]?.id == id { self?.exportTasks[target] = nil }
      } catch {
        self?.report(error)
        // The same registry result retains the original failure/lease/path;
        // a new same-destination request joins and propagates it without replay.
      }
    }
    exportTasks[target] = (id, observer, producer, nil)
    return producer
  }
  func cancelExport(to url: URL) {
    // Cancel the actual source/coordination task. Its scoped handler also
    // cancels this same destination's entered predecessor and explicit token.
    exportTasks[url.standardizedFileURL]?.pagedResult?.cancel()
    exportTasks[url.standardizedFileURL]?.clipboardResult?.cancel()
  }
  /// The actual native client supplies the complete logical selection. The
  /// immutable capture includes accepted dirty text; the existing export task
  /// retains it without waiting for or borrowing a saved document record.
  func copyDocumentSelection(from view: PagedNativeTextView, cutting: Bool) {
    do {
      try requirePagedOperation()
      guard let input = pagedInput, input.activeView === view, let commands = pagedCommands,
        let session = pagedSession, view.session === session, !view.hasMarkedText(),
        !cutting || view.isEditable else { throw BoomError.stale("Clipboard selection has another native input client.") }
      let selection = try input.currentDocumentSelection()
      guard selection.utf16Length > 0 else { return }
      let observed = try input.observeSelection()
      let (engine, publisher) = try pagedOwners()
      let clipboardChange = NSPasteboard.general.changeCount
      _ = try commands.requestDocumentClipboard(selection, cutting: cutting) { [weak self] captured in
        guard let self, self.pagedInput === input, input.activeView === view,
          self.pagedSession === session, try input.observeSelection() == observed,
          try input.currentDocumentSelection() == selection,
          captured.source.sourceRevision.documentID == self.selectedDocumentID else {
          throw BoomError.stale("The clipboard selection changed before its immutable source capture.")
        }
        try session.admitLogicalRead(captured)
        let snapshot = captured.source
        guard selection.utf16Offset <= snapshot.summary.utf16,
          selection.utf16Length <= snapshot.summary.utf16 - selection.utf16Offset else {
          throw BoomError.stale("Clipboard selection exceeds its captured logical source.")
        }
        let cancellation = CancellationFlag()
        let start = try await engine.logicalPosition(snapshot, utf16Offset: selection.utf16Offset,
          cancellation: cancellation).bytes
        let end = try await engine.logicalPosition(snapshot,
          utf16Offset: selection.utf16Offset + selection.utf16Length, cancellation: cancellation).bytes
        guard start < end, end <= snapshot.summary.bytes else {
          throw BoomError.invalid("Clipboard endpoints did not name the selected logical bytes.")
        }
        guard end - start <= 1_073_741_824 else {
          throw BoomError.budget("Copy up to 1 GiB at a time; larger selections can be exported as a document.")
        }
        try Task.checkCancellation()
        let result = try self.publishClipboardSelection(snapshot: snapshot, engine: engine,
          publisher: publisher, start: start, end: end, expectedChange: clipboardChange)
        if cutting {
          try await withTaskCancellationHandler { try await result.value } onCancel: { result.cancel() }
          try Task.checkCancellation()
        }
      }
    } catch {
      status = error.localizedDescription
      PerformanceTrace.event("Editor.ManagedAdmission")
    }
  }

  /// File paste enters the same physical command fence as selected-source
  /// replacement. Its imported tree stays live until the real mounted result
  /// joins; no manuscript-sized String or clipboard buffer is constructed.
  @discardableResult
  func pasteDocumentTextFile(_ clipboard: PagedClipboardTextFile, from view: PagedNativeTextView)
    throws -> Task<PagedNativeLogicalSnapshot, Error> {
    try requirePagedOperation(); try clipboard.admitCurrent()
    guard let input = pagedInput, input.activeView === view, let commands = pagedCommands,
      let session = pagedSession, view.session === session, view.isEditable, !view.hasMarkedText() else {
      throw BoomError.stale("Text paste has another physical document input client.")
    }
    let selected = try input.currentDocumentSelection(), observed = try input.observeSelection()
    let (engine, _) = try pagedOwners()
    return try commands.requestDocumentImportedReplacement(selected, importing: { [weak self] captured in
      guard let self, self.pagedInput === input, input.activeView === view,
        self.pagedSession === session, captured.source.sourceRevision.documentID == self.selectedDocumentID,
        try input.observeSelection() == observed, try input.currentDocumentSelection() == selected else {
        throw BoomError.stale("Text paste changed before capturing its original source and selection.")
      }
      try session.admitLogicalRead(captured)
      try clipboard.admitCurrent(); try Task.checkCancellation()
      let scoped = clipboard.url.startAccessingSecurityScopedResource()
      defer { if scoped { clipboard.url.stopAccessingSecurityScopedResource() } }
      let opened = try await detachedWork { try clipboard.open() }
      let cancellation = PagedTextCancellation()
      var imported: PagedTextCustodiedValue<PagedTextImportedRevision>?
      var closeAttempted = false
      do {
        let output = try await withTaskCancellationHandler {
          try await engine.importUTF8Retaining(documentID: captured.source.sourceRevision.documentID, from: opened.file,
            expectedBytes: opened.expectedBytes, cancellation: cancellation, priority: .foreground)
        } onCancel: { cancellation.cancel() }
        imported = output
        try await detachedWork { try opened.admit() }
        closeAttempted = true
        try await detachedWork { try opened.close() }
        try Task.checkCancellation()
        guard self.pagedInput === input, self.pagedSession === session, input.activeView === view,
          try input.observeSelection() == observed, try input.currentDocumentSelection() == selected else {
          throw BoomError.stale("Text paste changed while its immutable file tree was imported.")
        }
        return output
      } catch {
        var original: Error = error
        if !closeAttempted {
          closeAttempted = true
          do { try await detachedWork { try opened.close() } }
          catch { original = WorkspacePagedImportFailure(original: original, cleanup: error, url: clipboard.url) }
        }
        if let imported {
          do { try await engine.abandonJoinedRootOutput(imported.lease) }
          catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: imported.lease) }
        }
        throw original
      }
    }, discard: { lease in try await engine.abandonJoinedRootOutput(lease) })
  }

  private func publishClipboardSelection(snapshot: PagedNativeLogicalSnapshot,
    engine: PagedTextEngineAdapter, publisher: PagedWorkspacePublisher,
    start: UInt64, end: UInt64, expectedChange: Int) throws -> Task<Void, Error> {
    guard pagedExportTaskCount < Self.maximumPagedExportTasks else {
      throw BoomError.budget("Eight file publications are already owned.")
    }
    let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false)
    let directory = cache.appendingPathComponent("Bloom/Clipboard", isDirectory: true)
      .appendingPathComponent(publisher.storeID.uuidString.lowercased(), isDirectory: true)
    guard exportTasks[directory] != nil || exportTasks.count < Self.maximumPagedExportTasks else {
      throw BoomError.budget("Eight file publication destinations are already owned.")
    }
    let target = directory.appendingPathComponent("Selection-" + UUID().uuidString.lowercased() + ".txt")
    let previous = exportTasks[directory], id = UUID()
    pagedExportTaskCount += 1
    let producer = Task<Void, Error> { [self] in
      var preparedFile: URL?
      do {
        if let previous {
          await previous.task.value
          if let result = previous.clipboardResult { try await result.value }
        }
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChange else {
          throw BoomError.stale("A newer clipboard item is already present.")
        }
        let retained = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let cancellation = CancellationFlag()
        if end - start <= UInt64(PagedTextWindow.maximumBytes) {
          let bytes = try await engine.logicalBytes(snapshot, byteRange: start..<end, cancellation: cancellation)
          guard UInt64(bytes.count) == end - start, let text = String(data: bytes, encoding: .utf8) else {
            throw BoomError.invalid("Clipboard text did not contain the complete selected logical range.")
          }
          try Task.checkCancellation()
          guard pasteboard.changeCount == expectedChange else { throw BoomError.stale("The clipboard changed while selected text was read.") }
          pasteboard.clearContents()
          guard pasteboard.writeObjects([text as NSString]) else { throw BoomError.unavailable("The selected text was not written to the clipboard.") }
          status = "Copied"
        } else {
          try await detachedWork { try Self.prepareClipboardDirectory(directory, retaining: retained) }
          let file = try await ExplicitFileExport.write(to: target, stream: { handle in
            try await engine.exportLogical(snapshot, to: handle, byteRange: start..<end, cancellation: cancellation)
          })
          preparedFile = file
          try Task.checkCancellation()
          guard pasteboard.changeCount == expectedChange else { throw BoomError.stale("The clipboard changed while the selected file was prepared.") }
          try PagedClipboardTextFile.write(file, to: pasteboard)
          status = "Copied file"
        }
      } catch {
        let original = error
        if let preparedFile {
          throw ExplicitStreamExportFailure(original: original, cleanup: nil,
            retainedDirectory: nil, publishedURL: preparedFile)
        }
        throw original
      }
    }
    let observer = Task { [weak self] in
      defer { self?.pagedExportTaskCount -= 1 }
      do {
        try await producer.value
        if self?.exportTasks[directory]?.id == id { self?.exportTasks[directory] = nil }
      } catch {
        self?.status = error.localizedDescription
        PerformanceTrace.event("Editor.ManagedAdmission")
      }
    }
    exportTasks[directory] = (id, observer, nil, producer)
    return producer
  }

  nonisolated private static func prepareClipboardDirectory(_ directory: URL, retaining: [URL]) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw BoomError.invalid("Clipboard cache is not an ordinary directory.") }
    let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard files.count <= 8 else { throw BoomError.budget("Clipboard cache contains unexpected retained files.") }
    for file in files {
      let name = file.deletingPathExtension().lastPathComponent
      guard file.pathExtension == "txt", name.hasPrefix("Selection-"),
        UUID(uuidString: String(name.dropFirst("Selection-".count))) != nil else {
        throw BoomError.invalid("Clipboard cache contains an unknown file.")
      }
      let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw BoomError.invalid("Clipboard cache contains a link or non-file.") }
      if !retaining.contains(file) { try manager.removeItem(at: file) }
    }
    guard files.filter({ retaining.contains($0) }).count <= 1 else {
      throw BoomError.budget("Clipboard cache retains more than one published selection.")
    }
    // At most the still-published previous file and this action's staging
    // output survive. The next large copy removes inactive owned files; the
    // current clipboard file remains usable after the application exits.
  }

  func revealDocument(_ id: UUID) {
    NSWorkspace.shared.activateFileViewerSelecting([store.root.appendingPathComponent("documents/" + id.uuidString.lowercased(), isDirectory: true)])
  }
  private func insertAttachmentLinks(_ attachments: [AttachmentRecord], into destination: AttachmentDestination) throws {
    guard case .document(let id, let sessionID, let arenaID, let generation, let selectionEpoch, let range, let selection) = destination,
      state.selectedDocument == id, let session = pagedSession, let input = pagedInput,
      session.sessionID == sessionID, session.arenaID == arenaID, session.generation == generation,
      let view = input.activeView, !view.hasMarkedText(),
      let observation = try? input.observeSelection(), observation.selectionEpoch == selectionEpoch,
      observation.range == range, try input.currentDocumentSelection() == selection else {
      throw BoomError.stale("The attachment insertion target changed. Its original files were retained.")
    }
    guard !attachments.isEmpty else { return }
    let links = attachments.map { attachment in
      let name = attachment.name.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
      return "[Attachment: \(name)](boom-attachment:\(attachment.id.uuidString))"
    }.joined(separator: "\n") + "\n"
    let source = view.string as NSString
    let origin = try session.documentCoordinates().utf16Start
    let startsParagraph = selection.utf16Offset == 0
      || selection.utf16Offset == origin + UInt64(range.location) && range.location > 0
        && source.substring(with: NSRange(location: range.location - 1, length: 1)) == "\n"
    view.insertText((startsParagraph ? "" : "\n") + links, replacementRange: range)
    if let error = view.boundedStorage.mutationFailure { throw error }
  }
  func chooseAttachmentFiles(to destination: AttachmentDestination) {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return }
    attach(panel.urls.map(AttachmentInput.file), to: destination)
  }
  func attach(_ inputs: [AttachmentInput], to destination: AttachmentDestination) {
    guard !isBusy, !inputs.isEmpty else { return }
    let alreadyPending: Int
    switch destination {
    case .chat(let id):
      guard state.selectedChat == id else { report(BoomError.stale("Chat changed.")); return }
      alreadyPending = pendingAttachments.count
    case .document(let id, _, _, _, _, _, _):
      guard documentIndices.contains(where: { $0.id == id }) else {
        report(BoomError.stale("Document was removed.")); return
      }
      alreadyPending = 0
    }
    guard inputs.count + alreadyPending <= 8 else {
      report(BoomError.budget("At most eight attachments per turn."))
      return
    }
    work("Inspecting attachments locally…") { [weak self] flag in
      guard let self else { return }
      var importedRecords: [AttachmentRecord] = []
      for input in inputs {
        try flag.check()
        let sourceURL: URL?
        if case .file(let url) = input { sourceURL = url } else { sourceURL = nil }
        let scope = sourceURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scope { sourceURL?.stopAccessingSecurityScopedResource() } }
        let imported: AttachmentImport
        switch input {
        case .file(let url):
          imported = try await detachedWork(priority: .utility) {
            let bytes = try AttachmentProcessor.readGranted(url)
            return try AttachmentProcessor.inspect(name: url.lastPathComponent, data: bytes)
          }
        case .bytes(let name, let data):
          imported = try await detachedWork(priority: .utility) {
            try AttachmentProcessor.inspect(name: name, data: data)
          }
        }
        try flag.check()
        let vault = self.store.vault
        try await detachedWork {
          try vault.put(imported.original, kind: .attachment, id: imported.record.id)
          try vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
        }
        var record = imported.record
        record.isImage = LocalImage.canDecode(imported.original)
        if record.isImage == true {
          record.presentation = .image
          record.coverage = "Original image available locally"
        } else if record.kind == .image {
          record.presentation = .unavailable
          record.coverage = "Image cannot be decoded locally; original retained"
        } else if record.kind == .pdf {
          record.text = ""
          do { record = try await self.preparedRecord(record, data: imported.original, automaticAudio: false, flag: flag) }
          catch is CancellationError { throw CancellationError() }
          catch { record.coverage = "Original PDF available locally; " + error.localizedDescription }
        } else if [.audio, .video].contains(record.kind), record.text.isEmpty {
          do {
            _ = try ProductCore.admitMedia(imported.original)
            if record.kind == .audio {
              try await detachedWork {
                let reader = try await MemoryMedia(bytes: imported.original).audioReader()
                guard try reader.next(flag: flag, seconds: 1) != nil else { throw BoomError.invalid("Audio contains no decodable samples.") }
              }
            } else {
              _ = try await detachedWork { [name = record.name] in try await NativeMedia.prepare(data: imported.original, name: name, audioSeconds: 0, flag: flag) }
            }
            record.awaitingPreparation = true
            record.coverage = "Original media available locally"
          } catch { record.presentation = .unavailable; record.coverage = "Unreadable locally: " + error.localizedDescription }
        } else if record.text.isEmpty {
          do {
            record = try await self.preparedRecord(
              record, data: imported.original, automaticAudio: sourceURL != nil, flag: flag)
          } catch is CancellationError { throw CancellationError() }
          catch { record.coverage = "Unreadable locally: " + error.localizedDescription }
        }
        try flag.check()
        self.state.attachments.append(record)
        importedRecords.append(record)
      }
      switch destination {
      case .chat(let id):
        guard self.state.selectedChat == id else { throw BoomError.stale("Chat changed.") }
        self.pendingAttachments.append(contentsOf: importedRecords.map(\.id))
      case .document:
        try self.insertAttachmentLinks(importedRecords, into: destination)
      }
      self.status = importedRecords.allSatisfy { !$0.text.isEmpty || $0.isImage == true }
        ? "Attachments ready" : "Some attachments need a readable local conversion"
    }
  }
  func removePending(_ id: UUID) {
    guard !isBusy else { return }
    pendingAttachments.removeAll { $0 == id }
    if let chat = state.selectedChat { state.recordingDrafts?[chat] = (state.recordingDrafts?[chat] ?? []).filter { $0 != id } }
    scheduleSave()
    composerIssue = nil
  }
  /// A captured recording is an original attachment, not a transcription action.
  /// File admission can finish while model preparation runs.
  func attachRecordedAudio(_ data: Data, chatID: UUID?, documentID: UUID?) async throws {
    guard !pagedTransition, !pagedShutdownRequested, recordingAttachmentTask == nil,
      !isBusy || settingUpModels, state.selectedChat == chatID,
      state.selectedDocument == documentID, pendingAttachments.count < 8 else {
      throw BoomError.stale("The recording's conversation changed.")
    }
    let task = Task { @MainActor in try await self.persistRecordedAudio(data, chatID: chatID, documentID: documentID) }
    recordingAttachmentTask = task
    defer { recordingAttachmentTask = nil }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
  }
  private func persistRecordedAudio(_ data: Data, chatID: UUID?, documentID: UUID?) async throws {
    let imported = try await detachedWork {
      guard try ProductCore.admitMedia(data).rawValue == "wav" else {
        throw BoomError.invalid("The recording is not local PCM audio.")
      }
      return try AttachmentProcessor.inspect(name: "Recording.wav", data: data)
    }
    try Task.checkCancellation()
    guard !pagedTransition, !pagedShutdownRequested else { throw CancellationError() }
    let vault = store.vault
    try await detachedWork {
      try vault.put(imported.original, kind: .attachment, id: imported.record.id)
      try vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
    }
    guard state.selectedChat == chatID, state.selectedDocument == documentID,
      pendingAttachments.count < 8 else {
      throw BoomError.stale("The recording's conversation changed.")
    }
    if state.selectedChat == nil {
      retainComposerDraft()
      let chat = ChatRecord(attachedDocumentID: layout.isAuthor ? documentID : nil)
      state.chats.append(chat); state.selectedChat = chat.id; selectedChatIDs = [chat.id]
      transferDocumentDraftToChat()
    }
    var record = imported.record
    record.text = ""; record.coverage = "Audio"; record.awaitingTranscription = true
    state.attachments.append(record); pendingAttachments.append(record.id)
    if state.recordingDrafts == nil { state.recordingDrafts = [:] }
    if let chat = state.selectedChat { state.recordingDrafts?[chat] = pendingAttachments.filter { candidate in
      state.attachments.first(where: { $0.id == candidate })?.awaitingTranscription == true
    } }
    composerIssue = nil; status = "Recorded"; scheduleSave()
    try await flush()
  }
  private func prepareMediaForSend(_ records: [AttachmentRecord], chat: UUID, request: String,
    interaction: InteractionMode, selectedIDs: [UUID], documentID: UUID?) {
    let unchanged = { [weak self] in
      guard let self else { return false }
      return self.state.selectedChat == chat && self.state.selectedDocument == documentID
        && self.draft == request && self.mode == interaction && self.pendingAttachments == selectedIDs
    }
    work("Reading media on this Mac…", after: { [weak self] in
      guard let self, unchanged(), records.allSatisfy({ original in
        self.state.attachments.first(where: { $0.id == original.id }).map { !$0.needsPreparation } ?? false
      }) else { return }
      self.send()
    }) { [weak self] flag in
      guard let self else { return }
      let runner = try await self.runnerForGeneration(.consultation, flag: flag)
      for original in records where original.needsPreparation {
        let vault = self.store.vault
        let bytes = try await detachedWork { try vault.get(.attachment, id: original.id, limit: 67_108_864) }
        guard Digest.sha256(bytes) == original.rootDigest else { throw BoomError.invalid("The recorded audio changed.") }
        var prepared: AttachmentRecord
        if original.kind == .video || original.kind == .audio && runner.supportsRawAudio {
          prepared = original
          if original.kind == .audio {
            _ = try await MemoryMedia(bytes: bytes).audioReader()
            prepared.coverage = "Original audio waveform available locally"
          } else {
            let storyboard = try await VideoPreparationCache.shared.prepare(bytes, digest: original.rootDigest, flag: flag)
            prepared.coverage = storyboard.coverage
          }
        } else { prepared = try await self.preparedRecord(original, data: bytes, automaticAudio: false, flag: flag) }
        prepared.awaitingTranscription = false; prepared.awaitingPreparation = false
        try flag.check()
        guard let index = self.state.attachments.firstIndex(where: { $0.id == original.id }),
          self.state.attachments[index].digest == original.digest else { throw BoomError.stale("The recording changed.") }
        self.state.attachments[index] = prepared
      }
      self.status = "Audio ready"; self.scheduleSave()
    }
  }
  func consultationMedia(_ records: [AttachmentRecord], rawAudio: Bool, flag: CancellationFlag) async throws -> (images: [Data], media: [WritingMediaData]) {
    let trace = PerformanceTrace.begin("Request.MediaInput")
    defer { PerformanceTrace.end("Request.MediaInput", trace) }
    let readable = records.filter { !($0.kind == .audio && !rawAudio) }
    let links = readable.map { "[Attachment: media](boom-attachment:\($0.id))" }.joined(separator: "\n")
    let payloads = try await writingMedia(in: links, flag: flag)
    let media = payloads.filter { $0.reference.kind != "text" }.map { payload in
      var supplied = payload
      if !rawAudio && !supplied.audioSegments.isEmpty {
        supplied.reference.video?.audio = []; supplied.reference.video?.soundtrackOmitted = true
        supplied.audioSegments = []
      }
      return supplied
    }
    for record in records {
      try flag.check()
      if record.text.isEmpty && ![.image, .audio, .pdf, .video].contains(record.kind) {
        throw BoomError.unavailable("This attachment has no readable local content.")
      }
    }
    return ([], media)
  }
  private func preparedRecord(
    _ attachment: AttachmentRecord, data: Data, automaticAudio: Bool, flag: CancellationFlag
  ) async throws -> AttachmentRecord {
    var updated = attachment
    if attachment.kind == .audio {
      let result = try await VoiceInput().transcribeAttachment(
        data: data, automaticAudio: automaticAudio, flag: flag
      ) { [weak self] current, total in
        self?.status = "Transcribing \(attachment.name) · \(current) of \(total)"
      }
      updated.text = result.text
      updated.transform = result.coverage
      updated.coverage = result.coverage.hasPrefix("Partial")
        ? "Partial local transcript" : "Local speech transcript"
      return updated
    }
    let audioSeconds = 0
    let media = try await detachedWork(priority: .utility) {
      try await NativeMedia.prepare(
        data: data, name: attachment.name, audioSeconds: Double(audioSeconds), flag: flag)
    }
    var text = ""
    var note = ""
    switch media {
    case .text(let extracted, let coverage):
      text = extracted
      note = coverage
    case .image, .video:
      throw BoomError.invalid("Media must use its original input adapter.")
    }
    try flag.check()
    guard !text.isEmpty, text.utf8.count <= 262_144 else {
      throw BoomError.invalid("Native transform returned no bounded text.")
    }
    updated.text = text
    if updated.kind != .pdf { updated.presentation = .document }
    updated.transform = note
    updated.coverage = "Partial native transform"
    return updated
  }
  @discardableResult
  private func releaseRunner(_ purpose: ModelPurpose, expectedEpoch: UUID? = nil) async -> Bool {
    let current = purpose == .consultation ? mlxRunner : baseRunner
    guard let old = current else {
      if expectedEpoch == nil {
        if purpose == .consultation { mlxRunner = nil; modelReady = false } else { baseRunner = nil }
        residentModelWeights.removeValue(forKey: purpose)
      }
      return false
    }
    guard expectedEpoch == nil || old.cacheRunnerEpoch == expectedEpoch else { return false }
    revokeJoinedRetentions(runnerEpoch: old.cacheRunnerEpoch)
    if expectedEpoch != nil { await old.cancelAndJoin() } else { await old.join() }
    guard (purpose == .consultation ? mlxRunner : baseRunner) === old else { return false }
    await old.clearPromptCache()
    guard (purpose == .consultation ? mlxRunner : baseRunner) === old else { return false }
    if purpose == .consultation { mlxRunner = nil; modelReady = false }
    else { baseRunner = nil }
    residentModelWeights.removeValue(forKey: purpose)
    return true
  }
  private func joinAndClearPromptCaches() async {
    let consultation = mlxRunner, writing = baseRunner
    if let consultation { await consultation.join(); await consultation.clearPromptCache() }
    if let writing, writing !== consultation { await writing.join(); await writing.clearPromptCache() }
  }
  private func reclaimModelCache(background: Bool = false) async {
    await GenerationCoordinator.shared.enter(background: background)
    // Releasing native Metal allocations may block. Retain the GPU lease,
    // but let the main actor continue handling manuscript input.
    await InferenceExecutor.shared.perform { _ in MLX.Memory.clearCache() }
    await GenerationCoordinator.shared.leave()
  }
  @discardableResult
  private func releaseInactiveModel(for purpose: ModelPurpose, expectedEpoch: UUID? = nil) async -> Bool {
    // releaseRunner's last strong local must leave before allocator reclamation.
    let released = await releaseRunner(purpose == .consultation ? .writing : .consultation,
      expectedEpoch: expectedEpoch)
    if released || expectedEpoch == nil { await reclaimModelCache(background: expectedEpoch != nil) }
    return released
  }
  /// Only captured production callers opt in. A nil controller retains normal
  /// admission, and a nil cache owner still uses actual cold admission.
  func makePairedContextAdmission(runner: MLXGemmaRunner, purpose: ModelPurpose,
    owner: PromptCacheOwner?, flag: CancellationFlag, sharingAttempt: PairedContextAdmission? = nil,
    validateSource: @escaping @Sendable () async throws -> Void) -> PairedContextAdmission {
    let workspaceEpoch = joinedRetentionEpoch
    return PairedContextAdmission(sharingAttempt: sharingAttempt) { [weak self] request in
      guard let workspace = self else { throw CancellationError() }
      return try await workspace.reclaimPreparedPeer(request, runner: runner, purpose: purpose,
        owner: owner, flag: flag, workspaceEpoch: workspaceEpoch, validateSource: validateSource)
    }
  }
  private func reclaimPreparedPeer(_ request: PreparedPairedAdmissionRequest,
    runner: MLXGemmaRunner, purpose: ModelPurpose, owner: PromptCacheOwner?, flag: CancellationFlag,
    workspaceEpoch: UUID, validateSource: @escaping @Sendable () async throws -> Void) async throws -> Bool {
    func validateOwner() throws {
      try flag.check()
      do { try ModelResidency.check() }
      catch { flag.cancel(); throw error }
      guard !joinedRetentionClosed, joinedRetentionEpoch == workspaceEpoch,
        (purpose == .consultation ? mlxRunner : baseRunner) === runner,
        request.operationID == flag.operationID, request.runnerEpoch == runner.cacheRunnerEpoch,
        request.modelIdentity == runner.identity, request.processorIdentity == runner.processorIdentity,
        request.owner == owner, owner == nil || owner?.namespace == inferenceCacheNamespace,
        owner == nil || joinedRetentionOwnerIsLive(owner!) else {
        throw BoomError.stale("The captured request or loaded model changed before paired-model reclamation.")
      }
      _ = try ProductCore.resolvedGenerationPolicy(request.policy, loaded: runner.generationPolicy)
    }
    try validateOwner(); try await validateSource(); try validateOwner()
    // Keep only scalar peer identity across release. Retaining its actor here
    // would pin weights while its release function clears the allocator pool.
    func inactiveEpoch() -> UUID? {
      guard let inactive = purpose == .consultation ? baseRunner : mlxRunner,
        inactive !== runner else { return nil }
      return inactive.cacheRunnerEpoch
    }
    guard let peerEpoch = inactiveEpoch() else { return false }
    // This callback is invoked only after the failing prepared operation has
    // exited its executor/container/coordinator lease. cancelAndJoin never runs
    // beneath the target lease, nor beneath a cache/admission lock.
    let released = await releaseInactiveModel(for: purpose, expectedEpoch: peerEpoch)
    try validateOwner(); try await validateSource(); try validateOwner()
    if released { status = "The inactive model was released to preserve context. It will reload when needed." }
    return released
  }
  private func validateConsultationAdmissionSource(chat: ChatRecord, sources: [SourceReference],
    attachments: [SourceReference], targetID: UUID?, requiredDocumentID: UUID?, flag: CancellationFlag) async throws {
    func check() throws {
      try flag.check()
      guard activeFlag === flag, state.selectedChat == chat.id,
        state.chats.first(where: { $0.id == chat.id })?.contentVersion == chat.contentVersion,
        requiredDocumentID == nil || state.selectedDocument == requiredDocumentID else {
        throw BoomError.stale("The captured consultation changed before paired-model reclamation.")
      }
    }
    try check(); try await revalidateResponseSources(sources, attachments: attachments, targetID: targetID); try check()
  }
  private func validateWritingAdmissionSource(document: DocumentSnapshot, offset: Int,
    examples: [UUID], sources: [SourceReference], capturedEpoch: UInt64, flag: CancellationFlag,
    capture: BoundedDocumentCapture?) async throws {
    func check() throws {
      try flag.check()
      guard let capture, caret >= 0, caret != NSNotFound, offset >= 0,
        epoch == capturedEpoch, state.selectedDocument == document.id,
        pagedSession?.generation == capture.generation,
        UInt64(caret) == capture.window.utf16Start + UInt64(offset), writingExampleIDs == examples else {
        throw BoomError.stale("The captured writing source changed.")
      }
    }
    try check(); try await revalidateOnDisk(sources, attachments: []); try check()
  }
  func runnerForGeneration(_ purpose: ModelPurpose, flag: CancellationFlag) async throws -> MLXGemmaRunner {
    let trace = PerformanceTrace.begin("Request.ModelReady")
    defer { PerformanceTrace.end("Request.ModelReady", trace) }
    try flag.check()
    if let runner = purpose == .consultation ? mlxRunner : baseRunner { return runner }
    if writingUsesConsultation {
      if purpose == .writing {
        let runner = try await runnerForGeneration(.consultation, flag: flag)
        useConsultationForWriting(runner)
        return runner
      } else if let runner = baseRunner {
        mlxRunner = runner; modelReady = true
        residentModelWeights[.consultation] = residentModelWeights[.writing]
        return runner
      }
    }
    guard let directory = modelDirectories[purpose] else {
      throw BoomError.unavailable("Install the \(purpose.title.lowercased()) model first.")
    }
    status = "Reloading \(purpose.title.lowercased()) model to preserve context…"
    return try await openModel(directory, purpose: purpose, flag: flag)
  }
  private func useConsultationForWriting(_ runner: MLXGemmaRunner) {
    baseRunner = runner
    residentModelWeights[.writing] = residentModelWeights[.consultation]
    writingModelIdentity = runner.identity; writingGenerationPolicy = runner.generationPolicy
  }
  func prepareModels() {
    guard !isBusy else { return }
    modelSetupIssue = nil
    if canInfer && (!layout.isAuthor || baseReady) { return }
    work("Preparing Bloom on this Mac…") { [weak self] flag in
      guard let self else { return }
      self.settingUpModels = true
      defer { self.settingUpModels = false }
      do {
        // A retry joins and releases a partially loaded setup before planning;
        // it never admits a replacement on top of unaccounted resident weights.
        await self.releaseRunner(.writing)
        await self.releaseRunner(.consultation)
        await self.reclaimModelCache()
        try flag.check()
        guard let device = MTLCreateSystemDefaultDevice() else { throw BoomError.unavailable("Metal is unavailable.") }
        let writing = self.layout.isAuthor
        let choices = try await detachedWork { try ModelPacks.setupChoices(writing: writing) }
        let disk = try await detachedWork { try ModelPacks.availableDiskBytes() }
        let candidates = choices.map { choice in
          let candidate = choice.candidate
          return ModelSetupCandidate(identity: candidate.identity, purpose: candidate.purpose,
            weightBytes: candidate.weightBytes, diskBytes: candidate.diskBytes, cached: candidate.cached,
            rank: self.preferredModel(candidate.purpose.rawValue) == candidate.identity ? 0 : candidate.rank + 1)
        }
        let plan = try ProductCore.modelSetup(physical: ProcessInfo.processInfo.physicalMemory,
          metal: device.recommendedMaxWorkingSetSize, resident: ModelResidency.footprint(), disk: disk,
          writing: writing, candidates: candidates)
        self.writingUsesConsultation = plan.reuseConsultation
        for identity in [plan.consultation, plan.writing].compactMap({ $0 }) {
          try flag.check()
          guard let choice = choices.first(where: { $0.candidate.identity == identity }) else {
            throw BoomError.invalid("The model setup decision is absent from its catalog.")
          }
          let directory: URL
          if let cached = choice.directory {
            directory = cached
            self.status = "Opening \(choice.candidate.purpose.rawValue) model…"
          } else if let checkpoint = choice.checkpoint {
            self.status = "Downloading a local model…"
            directory = try await ModelPacks.installPublished(checkpoint, flag: flag) { progress in
              Task { @MainActor in
                guard self.activeFlag === flag, !flag.isCancelled else { return }
                self.status = progress
              }
            }
          } else { throw BoomError.invalid("The selected model has no local files or download.") }
          _ = try await self.openModel(directory, purpose: choice.candidate.purpose, flag: flag)
        }
        if plan.reuseConsultation, let runner = self.mlxRunner { self.useConsultationForWriting(runner) }
        self.status = "Ready · models stay on this Mac"
      } catch is CancellationError { throw CancellationError() }
      catch {
        try flag.check()
        self.modelSetupIssue = error.localizedDescription
        self.status = "Model setup needs attention"
      }
    }
  }
  func openModels() {
    showingModels = true
    refreshModelChoices()
  }
  func refreshModelChoices() {
    modelPickerTask?.cancel(); modelPickerIssue = nil
    let writing = layout.isAuthor
    modelPickerTask = Task { [weak self] in
      do {
        let available = try await detachedWork { () throws -> [ModelSetupChoice] in
          guard let device = MTLCreateSystemDefaultDevice() else { throw BoomError.unavailable("Metal is unavailable.") }
          let choices = try ModelPacks.setupChoices(writing: writing)
          // List models that fit as replacements. Actual loading subsequently
          // accounts for every resident allocation and releases inactive weights.
          let identities = try ProductCore.modelChoices(physical: ProcessInfo.processInfo.physicalMemory,
            metal: device.recommendedMaxWorkingSetSize, resident: 0, disk: ModelPacks.availableDiskBytes(),
            candidates: choices.map(\.candidate))
          return identities.compactMap { identity in choices.first { $0.id == identity } }
        }
        guard !Task.isCancelled, let self else { return }
        self.modelChoices = available
      } catch {
        guard !Task.isCancelled else { return }
        self?.modelPickerIssue = "Models couldn't be checked."
      }
    }
  }
  func modelIsSelected(_ choice: ModelSetupChoice) -> Bool {
    modelDirectories[choice.candidate.purpose] == choice.directory && choice.directory != nil
  }
  func chooseModel(_ choice: ModelSetupChoice) {
    guard !isBusy else { return }
    work("Opening model…", after: { [weak self] in self?.refreshModelChoices() }) { [weak self] flag in
      guard let self else { return }
      let directory: URL
      if let local = choice.directory { directory = local }
      else if let checkpoint = choice.checkpoint {
        directory = try await ModelPacks.installPublished(checkpoint, flag: flag) { progress in
          Task { @MainActor in
            guard self.activeFlag === flag else { return }
            self.status = progress
          }
        }
      } else { throw BoomError.invalid("The model has no available weights.") }
      _ = try await self.openModel(directory, purpose: choice.candidate.purpose, flag: flag)
      if self.state.preferredModels == nil { self.state.preferredModels = [:] }
      self.state.preferredModels?[choice.candidate.purpose.rawValue] = choice.id
      self.showingModels = false; self.status = "Ready"; self.scheduleSave()
    }
  }
  private var residentWeightBytes: UInt64 {
    if let consultation = mlxRunner, let writing = baseRunner, consultation === writing {
      return residentModelWeights.values.max() ?? 0
    }
    return residentModelWeights.values.reduce(0, +)
  }
  private func admitModel(_ admission: ModelPacks.Admission, purpose: ModelPurpose) async throws {
    do { try ModelResidency.admit(weightBytes: admission.weightBytes, residentWeights: residentWeightBytes) }
    catch BoomError.budget {
      await releaseInactiveModel(for: purpose)
      try ModelResidency.admit(weightBytes: admission.weightBytes, residentWeights: residentWeightBytes)
      status = "The inactive model was released to make room. Reopening it will take a moment."
    }
  }
  func openModel(_ url: URL, purpose: ModelPurpose, flag: CancellationFlag,
    prefillTokens: UInt32? = nil) async throws -> MLXGemmaRunner {
    let admission = try await detachedWork { try ModelPacks.admission(url, purpose: purpose) }
    try flag.check()
    await releaseRunner(purpose)
    await reclaimModelCache()
    try await admitModel(admission, purpose: purpose)
    let loaded = try await MLXGemmaRunner.load(admission: admission, prefillTokens: prefillTokens)
    try flag.check()
    modelDirectories[purpose] = url
    if purpose == .consultation { mlxRunner = loaded; modelReady = true }
    else {
      baseRunner = loaded; writingModelIdentity = loaded.identity
      writingGenerationPolicy = loaded.generationPolicy
    }
    residentModelWeights[purpose] = admission.weightBytes
    if purpose == .consultation && writingUsesConsultation { useConsultationForWriting(loaded) }
    return loaded
  }
  func loadPack(_ url: URL, purpose: ModelPurpose) {
    work("Opening \(purpose.title.lowercased()) model…") { [weak self] flag in
      guard let self else { return }
      _ = try await self.openModel(url, purpose: purpose, flag: flag)
      self.showingModels = false
      self.status = "\(purpose.title) ready · on this Mac"
    }
  }
  func installModel(_ purpose: ModelPurpose) {
    work("Installing \(purpose.title.lowercased()) model…") { [weak self] flag in
      guard let self else { return }
      let directory = try await ModelPacks.install(purpose, flag: flag) { progress in
        Task { @MainActor in
          guard self.activeFlag === flag, !flag.isCancelled else { return }
          self.status = progress
        }
      }
      try flag.check()
      _ = try await self.openModel(directory, purpose: purpose, flag: flag)
      self.status = "\(purpose.title) ready · on this Mac"
    }
  }
  var canBackupWorkspace: Bool {
    !isBusy && !pagedTransition && !pagedShutdownRequested && recordingAttachmentTask == nil
  }
  func backupWorkspace(restoring: Bool) {
    guard canBackupWorkspace else { return }
    if restoring {
      let sourcePanel = NSOpenPanel()
      sourcePanel.canChooseFiles = false; sourcePanel.canChooseDirectories = true
      guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
      let destinationPanel = NSSavePanel()
      destinationPanel.nameFieldStringValue = "Bloom-restored"
      destinationPanel.canCreateDirectories = true
      guard destinationPanel.runModal() == .OK, let target = destinationPanel.url else { return }
      work("Restoring workspace…", after: { [weak self] in self?.openRestoredWorkspace?(target) }) { [weak self] flag in
        guard let self else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try flag.check()
        try await detachedWork { try WorkspaceBackup.restore(from: source, into: target) }
        self.status = "Workspace restored"
      }
    } else {
      let panel = NSSavePanel(); panel.nameFieldStringValue = "Bloom-backup"
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let target = panel.url else { return }
      do { _ = try exportWorkspaceBackup(to: target) }
      catch { status = error.localizedDescription }
    }
  }
  @discardableResult
  func exportWorkspaceBackup(to url: URL, progress: WorkspaceBackup.CopyProgress? = nil, temporaryParent: URL? = nil) throws -> Task<URL, Error> {
    try requirePagedOperation()
    guard canBackupWorkspace, recordingAttachmentTask == nil else {
      throw BoomError.unavailable("Another workspace capture or recording is still being saved.")
    }
    let target = url.standardizedFileURL, id = UUID(), flag = CancellationFlag()
    guard pagedExportTaskCount < Self.maximumPagedExportTasks,
      exportTasks[target] != nil || exportTasks.count < Self.maximumPagedExportTasks else {
      throw BoomError.budget("The existing export registry has eight pending or retained destinations.")
    }
    let (engine, _) = try pagedOwners(), vault = store.vault
    // Retain the pre-existing handles before installing this export's entry;
    // joining the new entry itself would wait on its own producer.
    let priorExports = Array(exportTasks.values), previousExport = exportTasks[target], previousGhost = ghostTask
    cancelInputCompletions(); invalidateGhost()
    isBusy = true; activeID = id; activeFlag = flag
    status = "Backing up workspace…"
    pagedExportTaskCount += 1
    let producer = Task<URL, Error> { [weak self] in
      try await withTaskCancellationHandler {
        guard let self else { throw CancellationError() }
        var captured = false
        defer { if !captured { self.finishWorkspaceBackupCapture(id) } }
        if let previousGhost { await previousGhost.value }
        for input in self.inputCompletions { await input.value?.join() }
        for operation in priorExports {
          await operation.task.value
          // Terminal export failures remain in their existing entries; they
          // do not poison a new backup of the live workspace.
          if let result = operation.pagedResult { _ = await result.result }
          if let result = operation.clipboardResult { _ = await result.result }
        }
        try flag.check()
        if let failure = await self.joinWorkspaceSaveTasks() { throw failure }
        guard self.pagedEngine === engine, self.pagedImported == nil, self.pagedInitialized == nil else {
          throw BoomError.stale("The backup capture lost its existing workspace source.")
        }
        // A marked composition stays live. Its last completed file checkpoint
        // is backed up; no forced unmark or synthetic native receiving occurs.
        if self.pagedSession?.isPinned == true { try await self.saveWorkspaceMetadata() }
        else { try await self.flush() }
        try flag.check()
        let snapshot = try await engine.captureWorkspaceBackup(vault: vault, cancellation: flag, temporaryParent: temporaryParent)
        captured = true
        self.finishWorkspaceBackupCapture(id)
        // This Task/registry owns the clone until export AND disposal join.
        // No live writer lock, editor retirement or busy UI spans this copy.
        try await detachedWork { try WorkspaceBackup.export(snapshot, to: target, cancellation: flag, progress: progress) }
        return target
      } onCancel: {
        flag.cancel()
        previousExport?.pagedResult?.cancel(); previousExport?.clipboardResult?.cancel()
      }
    }
    let observer = Task { [weak self] in
      defer { self?.pagedExportTaskCount -= 1 }
      do {
        _ = try await producer.value
        if self?.exportTasks[target]?.id == id { self?.exportTasks[target] = nil }
        if self?.isBusy == false { self?.status = "Backup exported" }
      } catch {
        // The result and any refused cleanup path remain in the existing
        // registry. Backup failure never retires or poisons the live editor.
        self?.status = error is CancellationError ? "Stopped" : error.localizedDescription
        PerformanceTrace.event("Workspace.BackupFailure")
      }
    }
    exportTasks[target] = (id, observer, producer, nil)
    return producer
  }
  private func finishWorkspaceBackupCapture(_ id: UUID) {
    guard activeID == id else { return }
    isBusy = false; activeID = nil; activeFlag = nil
    scheduleSave(); refreshVisibleSearch(); scheduleCompletion()
  }
  func importModel() {
    guard !isBusy else { return }
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.message = "Choose a Bloom model pack or a supported public Gemma snapshot."
    guard panel.runModal() == .OK, let source = panel.url else { return }
    work("Importing a model pack…") { [weak self] flag in
      guard let self else { return }
      let result = try await detachedWork { try ModelPacks.importPack(source, flag: flag) }
      try flag.check()
      self.status = "\(result.purpose.title) installed"
      let directory = result.directory
      do {
        _ = try await self.openModel(directory, purpose: result.purpose, flag: flag)
      }
    }
  }

}

@MainActor func askForText(title: String, message: String = "", initial: String) -> String? {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = message
  let field = NSTextField(string: initial)
  field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
  alert.accessoryView = field
  alert.addButton(withTitle: "Save")
  alert.addButton(withTitle: "Cancel")
  guard alert.runModal() == .alertFirstButtonReturn else { return nil }
  let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  return value.isEmpty ? nil : value
}
@MainActor func confirm(_ title: String, message: String) -> Bool {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = message
  alert.alertStyle = .warning
  alert.addButton(withTitle: "Delete")
  alert.addButton(withTitle: "Cancel")
  return alert.runModal() == .alertFirstButtonReturn
}

/// The existing Model is the ordinary receiving owner. A startup failure names
/// that same reachable Model/Engine and its actual retained outputs; this Error
/// is not a replacement root owner or a claim that resource close joined.
struct WorkspacePagedStartupFailure: Error, LocalizedError {
  let original: Error
  let model: WorkspaceModel
  var errorDescription: String? { original.localizedDescription }
}

extension WorkspaceModel {
  func joinWorkspaceOperation() async throws {
    if let foreground { await foreground.value }
    if let pagedFirstFailure { throw pagedFirstFailure }
  }
  private func requirePagedOperation() throws {
    guard !pagedTransition, !pagedShutdownRequested, pagedImported == nil, pagedInitialized == nil else {
      throw BoomError.stale("The workspace is still joining a document operation.")
    }
    if let pagedFirstFailure { throw pagedFirstFailure }
  }
  private func pagedOwners() throws -> (PagedTextEngineAdapter, PagedWorkspacePublisher) {
    guard let engine = pagedEngine, let publisher = pagedPublisher,
      engine.ownerID == publisher.ownerID else {
      throw BoomError.unavailable("The document store is not open.")
    }
    return (engine, publisher)
  }
  private func failPagedSource(_ error: Error) {
    if pagedFirstFailure == nil { pagedFirstFailure = error }
    // Background durability errors retain their source evidence and unsaved
    // bytes. Reporting them cannot take focus away from continued typing.
    status = error.localizedDescription
    PerformanceTrace.event("Editor.ManagedHistoryReconcile")
  }
  private func openPagedWorkspace(reclaimCold: Bool = false) async throws {
    let identity = try await store.storageIdentity()
    let engine = try await PagedTextEngineAdapter.create(root: store.root,
      ownerID: identity.ownerID, storeID: identity.storeID)
    pagedEngine = engine
    let publisher = try await engine.makeWorkspacePublisher()
    pagedPublisher = publisher
    if reclaimCold { _ = try await engine.reclaimColdWorkspace(state: state) }
    if let id = state.selectedDocument {
      guard documentIndices.contains(where: { $0.id == id }) else { throw BoomError.invalid("The selected document is absent from the catalog.") }
      try await openPagedSelection(try await selectedPagedRecord(id))
    }
  }
  private func openPagedSelection(_ record: PagedDocumentRootRecord) async throws {
    let (engine, publisher) = try pagedOwners()
    guard pagedBackend == nil, pagedSession == nil, pagedInput == nil,
      pagedCommands == nil, pagedViewport == nil else {
      throw BoomError.stale("The previous native graph has not actually retired/detached.")
    }
    let backend = try await engine.makeNativeStorage(publisher, expected: record)
    pagedBackend = backend // keep partial opening failure on THIS Model
    let opening = try await backend.opening(sessionID: UUID())
    let session = try PagedNativeSession(opening: opening, storage: backend)
    pagedSession = session; pagedSelectedRecord = record
    let input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: 640, height: 480), session: session)
    pagedInput = input
    input.installCompletionClient(self)
    input.activeView?.setMedia(model: self)
    input.onNativeEdit = { [weak self] observation in self?.nativeInputChanged(observation, edited: true) }
    input.onNativeSelection = { [weak self] observation in self?.nativeInputChanged(observation, edited: false) }
    let commands = try PagedNativeUndoOwner(input: input)
    pagedCommands = commands
    let viewport = try PagedDocumentViewport(frame: NSRect(x: 0, y: 0, width: 640, height: 480), input: input)
    pagedViewport = viewport
    commands.mountView = { [weak viewport, weak self] old, new in
      guard let viewport else { throw BoomError.stale("The ordinary selected viewport lost its real receiving host.") }
      try viewport.mountManagedView(from: old, to: new)
      new.setMedia(model: self)
      self?.refreshVisibleSearch()
    }
    commands.didFail = { [weak self, weak commands] error in
      if commands?.firstFailure != nil { self?.failPagedSource(error) }
      else {
        self?.status = error.localizedDescription
        PerformanceTrace.event("Editor.ManagedAdmission")
      }
    }
    session.didFail = { [weak self] error in
      // Durability failure belongs to the retained saver; live source and
      // ordinary input remain usable. Explicit durable operations receive it.
      self?.status = error.localizedDescription
      PerformanceTrace.event("Editor.ManagedSaveFailure")
    }
    session.didSeal = { [weak self, weak session] _ in
      guard let self, let session, self.pagedSession === session else { return }
      let record = session.sealedRootRecord
      guard record.document.id == self.pagedSelectedRecord?.document.id else { return }
      // The actual worker projection is already received. No title-array
      // rebuild, document hash, metadata encode, IO or whole source copy here.
      self.pagedSelectedRecord = record
      self.captureCache.removeValue(forKey: record.document.id)
      if !self.librarySearch.isEmpty { self.refreshSearch() }
    }
    viewport.didRejectPresentation = { [weak self] error in
      // A read-only display failure cannot take over the editable responder.
      // The existing status remains inspectable without a modal input fence.
      guard let self else { return }
      self.status = error.localizedDescription
      PerformanceTrace.event("Editor.ManagedScrollRead")
    }
    try viewport.enableDocumentNavigation(engine: engine, publisher: publisher)
    refreshVisibleSearch()
  }
  private func nativeInputChanged(_ observation: PagedNativeStateObservation, edited: Bool) {
    guard let session = pagedSession, observation.sessionID == session.sessionID,
      observation.arenaID == session.arenaID, observation.generation == session.generation,
      let caret = Int(exactly: observation.caretUTF16) else { return }
    let changed = self.caret != caret
    self.caret = caret; lastInputPane = .document
    if edited {
      captureCache.removeValue(forKey: selectedDocumentID ?? UUID())
      if !librarySearch.isEmpty { refreshVisibleSearch() }
    }
    // A word accepted synchronously may already have resumed its remainder
    // under this exact new generation before the outer input callback.
    let resumed = ghostStamp?.revision == completionSourceIdentity && ghostStamp?.caretUTF16 == caret
    if !resumed && (edited || changed || observation.hasMarkedText || observation.selectionLength != 0) { invalidateGhost() }
    if !observation.hasMarkedText, observation.selectionLength == 0, ghostText.isEmpty { scheduleCompletion() }
  }
  private func closePagedSelection() async throws {
    guard let backend = pagedBackend else {
      guard pagedSession == nil, pagedInput == nil, pagedCommands == nil, pagedViewport == nil else {
        throw BoomError.stale("The ordinary native graph lost its actual storage owner.")
      }
      return
    }
    guard let session = pagedSession, let input = pagedInput,
      let commands = pagedCommands, let viewport = pagedViewport else {
      throw BoomError.stale("A partially opened native graph remains retained; shutdown cannot invent its installation.")
    }
    visibleSearchTask?.cancel()
    if let visibleSearchTask { await visibleSearchTask.value }
    visibleSearchTask = nil
    try await commands.joinPendingCommand()
    let generation = session.generation
    _ = try await session.flush(through: generation)
    try await viewport.closePresentation()
    try await commands.joinPendingCommand()
    guard session.generation == generation, session.sealedGeneration == generation,
      session.sealedRootRecord == pagedSelectedRecord else {
      throw BoomError.stale("Later admitted input keeps its existing source; selection did not discard it.")
    }
    let record = session.sealedRootRecord
    try session.requireJoinedNativeClose()
    try commands.closeInput()
    try commands.requireJoinedClose(); try input.requireJoinedClose()
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: generation, record: record)
    // Clearing requires the actual Input/Foundation retirement AND the exact
    // same Engine/head transfer. Retained old contexts contain inert proxies.
    session.didSeal = nil; session.didFail = nil
    pagedViewport = nil; pagedCommands = nil; pagedInput = nil
    pagedSession = nil; pagedBackend = nil; pagedSelectedRecord = nil
  }

  @discardableResult func beginPagedWorkspaceSave() throws -> Task<Void, Error> {
    try requirePagedOperation()
    let request = UUID(); saveRequestID = request
    if saveEntered, let current = saveTask { return current }
    return startWorkspaceSave(request: request, expedited: true)
  }
  private func selectedPagedRecord(_ id: UUID) async throws -> PagedDocumentRootRecord {
    if let session = pagedSession, pagedSelectedRecord?.document.id == id {
      let generation = session.generation
      if let commands = pagedCommands { try await commands.joinPendingCommand() }
      _ = try await session.flush(through: generation)
      guard pagedSession === session, session.generation == generation,
        session.sealedGeneration == generation else { throw BoomError.stale("Later input changed the captured document.") }
      let record = session.sealedRootRecord
      pagedSelectedRecord = record
      return record
    }
    let (engine, publisher) = try pagedOwners()
    let read = try await engine.currentDocumentRecordRetaining(publisher, documentID: id)
    let record = read.value
    try await engine.abandonJoinedRootOutput(read.lease)
    return record
  }
  func selectPagedDocument(_ id: UUID, preservingSelection: Bool = false,
    flag: CancellationFlag = CancellationFlag()) async throws {
    try requirePagedOperation(); try flag.check()
    guard documentIndices.contains(where: { $0.id == id }) else { throw BoomError.stale("The document was removed.") }
    if state.selectedDocument == id, pagedSession != nil { focusEditor(id); return }
    pagedTransition = true
    defer { pagedTransition = false }
    retainComposerDraft(schedule: false)
    try await flush()
    let record = try await selectedPagedRecord(id)
    try await closePagedSelection(); try flag.check()
    try await openPagedSelection(record)
    state.selectedDocument = id; state.showDocument = true
    if layout.isAuthor, selectedChat?.attachedDocumentID != id {
      state.selectedChat = state.chats.last(where: { $0.attachedDocumentID == id })?.id
    }
    restoreComposerDraft(); resetContinuationView()
    if !preservingSelection { selectedDocumentIDs = [id] }
    compactPane = "document"; composerFocusEpoch &+= 1
    invalidateGhost(); try await flush(); focusEditor(id)
  }
  private func createPagedDocument(flag: CancellationFlag) async throws {
    try await importAuthoredDocument(DocumentSnapshot(title: "Untitled", text: ""), selecting: true, flag: flag)
  }
  func importAuthoredDocument(_ document: DocumentSnapshot, selecting: Bool,
    flag: CancellationFlag) async throws {
    guard document.text.utf8.count <= 2_097_152 else { throw BoomError.budget("Authored input exceeds the bounded import size.") }
    let url = try await detachedWork {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-authored-\(UUID().uuidString).md")
      try Data(document.text.utf8).write(to: url, options: .withoutOverwriting)
      return url
    }
    try await importPagedDocument(url, title: document.title, documentID: document.id, selecting: selecting, flag: flag)
    try await detachedWork { try FileManager.default.removeItem(at: url) }
  }
  private func importPagedDocument(_ url: URL, title: String, documentID: UUID = UUID(),
    selecting: Bool = true, flag: CancellationFlag) async throws {
    try requirePagedOperation(); try flag.check()
    pagedTransition = true
    defer { pagedTransition = false }
    try await flush()
    let (engine, publisher) = try pagedOwners()
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let file = try await detachedWork { try FileHandle(forReadingFrom: url) }
    let cancellation = PagedTextCancellation()
    var closeAttempted = false
    do {
      let imported = try await withTaskCancellationHandler {
        try await engine.importUTF8Retaining(documentID: documentID, from: file, cancellation: cancellation)
      } onCancel: { cancellation.cancel() }
      pagedImported = imported
      closeAttempted = true
      try await detachedWork { try file.close() }
      let descriptor = PagedDocumentDescriptor(id: documentID, title: title, revision: imported.value.revision)
      let initialized = try await engine.initialNativeRecordRetaining(descriptor)
      pagedInitialized = initialized
      let record = try await engine.publishInitialDocumentRetaining(publisher, imported: imported, initialized: initialized)
      pagedImported = nil; pagedInitialized = nil
      documentIndices.append(DocumentIndex(id: documentID, title: title)); state.documents = documentIndices
      if state.importedFiles == nil { state.importedFiles = [:] }
      state.importedFiles?[documentID] = ImportedFile(folderID: nil, path: url.path, originalDigest: imported.value.wholeTextSha256, originalRevision: imported.value.revision)
      if selecting {
        retainComposerDraft(schedule: false)
        try await closePagedSelection(); try flag.check()
        try await openPagedSelection(record)
        state.selectedDocument = documentID; state.showDocument = true
        selectedDocumentIDs = [documentID]; compactPane = "document"
        restoreComposerDraft(); resetContinuationView(); composerFocusEpoch &+= 1
      }
      try await flush()
      if selecting { focusEditor(documentID) }
    } catch {
      let original = error
      if !closeAttempted {
        do { try await detachedWork { try file.close() } }
        catch { throw WorkspacePagedImportFailure(original: original, cleanup: error, url: url) }
      }
      throw original
    }
  }
  private func renamePagedDocument(_ id: UUID, to title: String, flag: CancellationFlag) async throws {
    try requirePagedOperation(); try flag.check()
    guard title.utf8.count <= 1_024 else { throw BoomError.budget("A document title is limited to 1 KiB.") }
    guard let index = documentIndices.firstIndex(where: { $0.id == id }) else { throw BoomError.stale("The document was removed.") }
    // Display titles are metadata, not source edits or native Undo groups.
    documentIndices[index].title = title; state.documents = documentIndices
    captureCache.removeValue(forKey: id)
    try await flush()
  }
  func trashPagedDocuments(_ ids: Set<UUID>, flag: CancellationFlag = CancellationFlag()) async throws {
    try requirePagedOperation(); try flag.check()
    pagedTransition = true
    defer { pagedTransition = false }
    retainComposerDraft(schedule: false); try await flush()
    if selectedDocumentID.map(ids.contains) == true { try await closePagedSelection() }
    try flag.check()
    state.archivedDocuments = (state.archivedDocuments ?? []) + documentIndices.filter { ids.contains($0.id) }
    documentIndices.removeAll { ids.contains($0.id) }; state.documents = documentIndices
    for id in ids { captureCache.removeValue(forKey: id) }
    writingExampleIDs.removeAll { ids.contains($0) }
    selectedDocumentIDs.subtract(ids)
    if state.selectedDocument.map(ids.contains) == true {
      state.selectedDocument = documentIndices.first?.id
      if let id = state.selectedDocument { try await openPagedSelection(try await selectedPagedRecord(id)) }
    }
    restoreComposerDraft(); invalidateGhost(); try await flush()
  }
  func previewDocument(_ id: UUID) async throws -> BoundedDocumentCapture {
    try await captureDocument(id, maximumBytes: 16_384)
  }
  private func sourceReferences(for documents: [DocumentSnapshot]) throws -> [SourceReference] {
    try documents.map { document in
      guard let source = consultationCaptures[document.id]?.source ?? captureCache[document.id]?.source else {
        throw BoomError.stale("The captured document source was replaced.")
      }
      return source
    }
  }
  private func captureChatContext(request: String, attachedDocumentID: UUID?,
    editingDocumentID: UUID?, flag: CancellationFlag) async throws -> BoundedConsultationContext {
    var ordered: [BoundedDocumentCapture] = [], active = Set<UUID>(), complete = Set<UUID>(), charged = 0
    func resolve(_ title: String, id: UUID?) throws -> UUID {
      if let id { return id }
      let matches = documentIndices.filter { $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
      guard matches.count == 1, let match = matches.first else {
        throw BoomError.invalid("Missing or ambiguous document: \(title). Insert its stable reference from the library.")
      }
      return match.id
    }
    func visit(_ id: UUID, depth: Int) async throws {
      try flag.check()
      guard !active.contains(id) else { throw BoomError.invalid("Document-follow cycle.") }
      if complete.contains(id) { return }
      guard depth <= 8, complete.count + active.count < 24, charged < 262_144 else {
        throw BoomError.budget("Linked context exceeds 24 sources / 256 KiB.")
      }
      active.insert(id)
      let start = id == editingDocumentID ? try pagedSession?.documentCoordinates().utf16Start : nil
      let capture = try await captureDocument(id, startingAtUTF16: start,
        maximumBytes: min(PagedTextWindow.maximumBytes, 262_144 - charged))
      charged += capture.window.text.utf8.count
      for link in try ReferenceParser.wiki(capture.window.text) {
        try await visit(resolve(link.title, id: link.documentID), depth: depth + 1)
      }
      active.remove(id); complete.insert(id); ordered.append(capture)
    }
    for id in [attachedDocumentID, editingDocumentID].compactMap({ $0 }) { try await visit(id, depth: 0) }
    for link in try ReferenceParser.wiki(request) { try await visit(resolve(link.title, id: link.documentID), depth: 0) }
    return BoundedConsultationContext(captures: ordered)
  }
  func captureDocument(_ id: UUID, prefixAt caret: UInt64? = nil,
    startingAtUTF16 start: UInt64? = nil,
    maximumBytes: Int = PagedTextWindow.maximumBytes) async throws -> BoundedDocumentCapture {
    guard documentIndices.contains(where: { $0.id == id }) || state.archivedDocuments?.contains(where: { $0.id == id }) == true else { throw BoomError.stale("The requested source was removed.") }
    let record = try await selectedPagedRecord(id), generation = id == selectedDocumentID ? pagedSession?.generation : nil
    let (engine, _) = try pagedOwners()
    let read: PagedTextCustodiedValue<PagedTextWindow>
    if let caret { read = try await engine.prefixWindowRetaining(record.document.revision, utf16Caret: caret, maximumBytes: maximumBytes) }
    else {
      var byte: UInt64 = 0
      if let start { byte = try await engine.byteAtUTF16(record.document.revision, offset: start) }
      read = try await engine.windowRetaining(record.document.revision, byteStart: byte, maximumBytes: maximumBytes)
    }
    let captured: BoundedDocumentCapture
    let title = documentIndices.first(where: { $0.id == id })?.title ?? record.document.title
    do {
      captured = try await detachedWork {
        try BoundedDocumentCapture(record: record, window: read.value, generation: generation, title: title)
      }
    } catch {
      let original = error
      do { try await engine.abandonJoinedRootOutput(read.lease) }
      catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: read.lease) }
      throw original
    }
    try await engine.abandonJoinedRootOutput(read.lease)
    if let generation, pagedSession?.generation != generation { throw BoomError.stale("Later input changed the captured model range.") }
    if captureCache.count >= 24, captureCache[id] == nil { captureCache.removeAll(keepingCapacity: true) }
    captureCache[id] = captured
    return captured
  }
}

private struct WorkspacePagedImportFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  let url: URL
  var errorDescription: String? { "\(original.localizedDescription) Import handle cleanup: \(cleanup.localizedDescription). Original source retained at \(url.path)." }
}
