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
  case document(id: UUID, revision: String, range: NSRange)
}
struct CompletionSegment {
  let accepted: String
  let remaining: String
  let whole: String
  let sources: [SourceReference]
}

@MainActor final class WorkspaceModel: ObservableObject {
  enum InputPane: Equatable { case document, chat }
  enum StorageRoute: Equatable { case legacy, boundedSQL }
  /// A paged workspace has no WorkspaceState. This accessor belongs only to
  /// the complete shipped legacy route and its explicitly legacy consumers.
  @Published private var legacyState: WorkspaceState?
  var state: WorkspaceState {
    get {
      guard let legacyState else { preconditionFailure("A bounded SQL workspace has no legacy WorkspaceState.") }
      return legacyState
    }
    set {
      precondition(legacyState != nil, "Cannot create legacy authority inside a SQL workspace.")
      legacyState = newValue
    }
  }
  @Published private(set) var pagedSettings: WorkspaceSettings?
  @Published private(set) var pagedDocumentPage: [PagedDocumentRootRecord] = []
  @Published private(set) var pagedChatPage: [WorkspaceEntityRead] = []
  @Published private(set) var pagedViewport: PagedDocumentViewport?
  @Published private(set) var pagedSelectedRecord: PagedDocumentRootRecord?
  @Published private(set) var pagedNextDocumentOrdinal: Int?
  @Published private(set) var pagedLibraryHasPrevious = false
  private var pagedHead: PagedWorkspaceHead?
  private var pagedDocumentPageStart = -1
  private var pagedPreviousDocumentPages: [Int] = [] // at most1,024 scalar cursors
  private(set) var pagedEngine: PagedTextEngineAdapter?
  private(set) var pagedPublisher: PagedWorkspacePublisher?
  private var pagedBackend: PagedNativeStorageBackend?
  private(set) var pagedSession: PagedNativeSession?
  private(set) var pagedInput: PagedNativeInputOwner?
  private(set) var pagedCommands: PagedNativeUndoOwner?
  private var pagedMetadataOutput: PagedTextCustodiedValue<WorkspaceMetadataPublication>?
  private var pagedReadLease: PagedTextRootLease?
  private var pagedImported: PagedTextCustodiedValue<PagedTextImportedRevision>?
  private var pagedInitialized: PagedTextCustodiedValue<PagedDocumentRootRecord>?
  private var pagedDraftReference: WorkspaceEntityReference?
  private var pagedSettingsDirty = false
  private var pagedDraftDirty = false
  private var pagedSettingsVersion = UUID()
  private var pagedFirstFailure: Error?
  private var pagedTransition = false
  private var pagedShutdownRequested = false
  var usesPagedStorage: Bool { legacyState == nil }
  var selectedDocumentID: UUID? { pagedSettings?.selectedDocument ?? legacyState?.selectedDocument }
  var selectedChatID: UUID? { pagedSettings?.selectedChat ?? legacyState?.selectedChat }
  var themeName: String { pagedSettings?.theme ?? legacyState?.theme ?? "system" }
  var autocompleteEnabled: Bool { pagedSettings?.autocomplete ?? legacyState?.autocomplete ?? false }
  var hasSelectedDocument: Bool { usesPagedStorage ? pagedSelectedRecord != nil : selectedDocument != nil }
  private func preferredModel(_ purpose: String) -> String? {
    usesPagedStorage ? pagedSettings?.preferredModels[purpose] : legacyState?.preferredModels?[purpose]
  }
  @Published private(set) var documents: [DocumentSnapshot]
  @Published private(set) var documentIndices: [DocumentIndex] = []
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
  @Published var editingLocked = false
  @Published var backupRequest: BackupRequest?
  @Published var writingExampleIDs: [UUID] = [] {
    didSet {
      if writingExampleIDs != oldValue {
        if usesPagedStorage {
          pagedSettings?.writingExampleIDs = writingExampleIDs
          pagedSettingsDirty = true; pagedSettingsVersion = UUID()
        } else { state.writingExampleIDs = writingExampleIDs }
        scheduleSave()
      }
    }
  }
  private var composerOwner: ComposerOwner?
  var hasComposerOwner: Bool {
    guard let composerOwner else { return false }
    return composerOwner == (usesPagedStorage ? pagedComposerOwner : selectedComposerOwner)
  }
  private var restoringComposer = false
  let layout: ProductLayout
  @Published var librarySearch = "" { didSet { if oldValue != librarySearch { refreshSearch() } } }
  @Published private(set) var documentSearch: [UUID: DocumentSearchMatches] = [:]
  @Published private(set) var matchingChatIDs: Set<UUID> = []
  @Published private(set) var matchingVoiceIDs: Set<UUID> = []
  @Published private(set) var searchIssue: String?
  private var searchedQuery = ""
  private var searchEpoch: UInt64 = 0
  private var searchTask: Task<Void, Never>?
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
    guard let document = documents.first(where: { $0.id == id }) else { return nil }
    return .document(id: id, revision: document.revision, range: range)
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
    guard legacyConsumerAvailable("Lazy SQL chat attachment receiving") else { return }
    composerIssue = nil
    do { attach(inputs, to: try chatAttachmentDestination()) }
    catch { report(error) }
  }
  func pasteImageIntoCurrentChat() {
    guard legacyConsumerAvailable("Lazy SQL image receiving") else { return }
    guard let input = AttachmentInput.readImage(.general) else {
      report(BoomError.unavailable("The clipboard has no image to attach."))
      return
    }
    attachToCurrentChat([input])
  }
  func chooseChatAttachmentFiles() {
    guard legacyConsumerAvailable("Lazy SQL chat media") else { return }
    do { chooseAttachmentFiles(to: try chatAttachmentDestination()) }
    catch { report(error) }
  }
  func chooseDocumentAttachmentFiles() {
    guard legacyConsumerAvailable("Typed paged media insertion") else { return }
    guard let document = selectedDocument else {
      report(BoomError.unavailable("Open a document before attaching a file to it."))
      return
    }
    let range: NSRange
    if let editor, editor.documentID == document.id { range = editor.selectedRange() }
    else { range = NSRange(location: document.text.utf16.count, length: 0) }
    guard let destination = documentAttachmentDestination(id: document.id, range: range) else { return }
    chooseAttachmentFiles(to: destination)
  }
  var canInfer: Bool { mlxRunner != nil || modelDirectories[.consultation] != nil }
  var inferenceName: String { canInfer ? "Gemma 4" : "No model" }
  var baseReady: Bool { baseRunner != nil || modelDirectories[.writing] != nil || (writingUsesConsultation && canInfer) }
  private var foreground: Task<Void, Never>?
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
    case .writing: return documents.contains { $0.id == owner.entity }
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
  private var saveTask: Task<Void, Never>?
  private enum PagedSavePhase: Equatable { case waiting, reserved, entered, finished }
  private var pagedSaveID: UUID?
  private var pagedSavePhase: PagedSavePhase?
  private var pagedSaveRunningID: UUID?
  private var pagedSaveDeadline: ContinuousClock.Instant?
  private var pagedSaveRequested = false
  private var pagedSaveTaskCount = 0
  private static let maximumPagedSaveTasks = 8
  private var exportTasks: [URL: (id: UUID, task: Task<Void, Never>, pagedResult: Task<URL, Error>?)] = [:]
  private var pagedExportTaskCount = 0
  private static let maximumPagedExportTasks = 8
  private var dirty = Set<UUID>()
  private var undoManagers: [UUID: UndoManager] = [:]
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
    return (pagedSettings?.showLibrary ?? state.showLibrary) && !(layout.isAuthor && paneFit == .medium && allPanesRequested
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
    return (pagedSettings?.showChat ?? state.showChat) && !(paneFit == .medium && allPanesRequested
      && mediumHiddenPane == "chat")
  }
  private var allPanesRequested: Bool {
    layout.isAuthor && (pagedSettings?.showLibrary ?? state.showLibrary) && (pagedSettings?.showChat ?? state.showChat)
  }

  init(storeOverride: WorkspaceStore? = nil, loadModels: Bool = true, storageRoute: StorageRoute = .legacy) async throws {
    layout = try ProductCore.layout()
    if let storeOverride { store = storeOverride }
    else { store = try await detachedWork { try WorkspaceStore() } }
    if storageRoute == .boundedSQL {
      legacyState = nil; documents = []
      compactPane = layout.primaryPane
      do { try await openPagedWorkspace() }
      catch { pagedFirstFailure = error; throw WorkspacePagedStartupFailure(original: error, model: self) }
    } else {
    let loaded = try await store.load().get()
    self.legacyState = loaded.0
    self.documents = loaded.1
    self.documentIndices = loaded.1.map { DocumentIndex(id: $0.id, title: $0.title) }
    selectedDocumentIDs = Set(state.selectedDocument.map { [$0] } ?? [])
    selectedChatIDs = Set(state.selectedChat.map { [$0] } ?? [])
    if layout.isAuthor && documents.isEmpty { try newDocument() }
    if state.chats.isEmpty && !layout.isAuthor { try newChat() }
    writingExampleIDs = state.writingExampleIDs ?? []
    restoreComposerDraft()
    if let id = state.selectedDocument {
      let history = try await store.candidateHistory(for: id, ids: state.candidateIDs)
      savedExplorations = history.explorations
      latestSavedCandidate = history.latest
      if let latest = history.latest { candidates = try await store.readCandidate(latest) }
    }
    compactPane = layout.primaryPane
    #if BOOM_UI_TEST
    if let index = state.chats.firstIndex(where: { $0.id == state.selectedChat }),
      state.chats[index].messages.isEmpty {
      state.chats[index].messages = [
        ChatMessage(role: .user, text: "A sample request"),
        ChatMessage(role: .assistant, text: "A sample reply."),
      ]
      scheduleSave()
    }
    #endif
    try await flush()
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
    documents.append(document)
    documentIndices.append(DocumentIndex(id: document.id, title: document.title))
  }
  private func updateDocumentIndexTitle(_ id: UUID, title: String) {
    guard let index = documentIndices.firstIndex(where: { $0.id == id }), documentIndices[index].title != title else { return }
    documentIndices[index].title = title
  }
  func documentMatchesSearch(_ document: DocumentIndex) -> Bool { documentMatchesSearch(id: document.id) }
  func documentMatchesSearch(_ document: DocumentSnapshot) -> Bool { documentMatchesSearch(id: document.id) }
  private func documentMatchesSearch(id: UUID) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || searchedQuery != librarySearch || documentSearch[id] != nil
  }
  func chatMatchesSearch(_ chat: ChatRecord) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || matchingChatIDs.contains(chat.id)
  }
  func voiceMatchesSearch(_ voice: Voice) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || matchingVoiceIDs.contains(voice.id)
  }
  private func refreshSearch() {
    if usesPagedStorage {
      // These exact titles are one page, not a claim of complete source search.
      searchIssue = librarySearch.isEmpty ? nil : "Full-source SQL search has not been admitted; only this title page is filtered."
      return
    }
    searchEpoch &+= 1; searchTask?.cancel()
    let query = librarySearch, identity = searchEpoch
    searchIssue = nil
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      searchedQuery = query; documentSearch = [:]; matchingChatIDs = []; matchingVoiceIDs = []
      return
    }
    editor?.clearGhost()
    let capturedDocuments = documents, capturedChats = state.chats, capturedVoices = state.voices
    let imported = state.importedFiles ?? [:]
    let folderNames = Dictionary(uniqueKeysWithValues: (state.importedFolders ?? []).map { ($0.id, $0.name) })
    searchTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 120_000_000)
        let results = try await detachedWork(priority: .utility) {
          var documents: [UUID: DocumentSearchMatches] = [:], chats = Set<UUID>(), voices = Set<UUID>()
          for document in capturedDocuments {
            try Task.checkCancellation()
            let matches = try ProductCore.search(document.text, query: query)
            let importedPath = imported[document.id].map { file in
              file.folderID.flatMap { folderNames[$0] }.map { $0 + "/" + file.path } ?? file.path
            } ?? ""
            let title = try ProductCore.search(document.title + "\n" + importedPath, query: query)
            if matches.hasMatches || title.hasMatches {
              documents[document.id] = DocumentSearchMatches(query: query, revision: document.revision,
                textVersion: document.textVersion, matches: matches)
            }
          }
          for chat in capturedChats {
            try Task.checkCancellation()
            var found = try ProductCore.search(chat.title + "\n" + (chat.instructions ?? ""), query: query).hasMatches
            for message in chat.messages where !found {
              try Task.checkCancellation()
              found = try ProductCore.search(message.text, query: query).hasMatches
            }
            if found { chats.insert(chat.id) }
          }
          for voice in capturedVoices {
            try Task.checkCancellation()
            if try chats.contains(voice.id) || ProductCore.search(voice.name + "\n" + voice.slug + "\n" + voice.instructions, query: query).hasMatches {
              voices.insert(voice.id)
            }
          }
          return (documents, chats, voices)
        }
        guard let self, self.searchEpoch == identity else { return }
        self.documentSearch = results.0; self.matchingChatIDs = results.1; self.matchingVoiceIDs = results.2
        self.searchedQuery = query
      } catch is CancellationError {} catch {
        guard let self, self.searchEpoch == identity else { return }
        self.searchIssue = error.localizedDescription
      }
    }
  }
  var selectedDocument: DocumentSnapshot? { guard let legacyState else { return nil }; return documents.first { $0.id == legacyState.selectedDocument } }
  var selectedChat: ChatRecord? { legacyState?.chats.first { $0.id == legacyState?.selectedChat } }
  var proposedForChat: [StoredProposal] {
    guard !usesPagedStorage else { return [] } // no paged proposal was decoded or discarded
    return state.proposals.filter { $0.chatID == state.selectedChat }
  }
  var voiceMatches: [Voice] {
    guard !usesPagedStorage else { return [] } // lazy voice headers/bodies are not hydrated here
    guard let range = draft.range(of: #"(?:^|\s)@([a-z0-9_-]*)$"#, options: .regularExpression)
    else { return [] }
    let query = draft[range].trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
    return state.voices.filter { $0.slug.hasPrefix(query) }.prefix(6).map { $0 }
  }
  func undoManager(_ id: UUID) -> UndoManager {
    if let manager = undoManagers[id] { return manager }
    let manager = UndoManager()
    manager.levelsOfUndo = 100
    undoManagers[id] = manager
    return manager
  }
  func report(_ error: Error) {
    errorMessage = error.localizedDescription
    status = error.localizedDescription
  }
  func dismissError() { errorMessage = nil }
  func finishComposition() {
    if usesPagedStorage {
      // Marked input is owned by its real client. Do not fabricate an unmark
      // callback/join merely to make navigation, save or shutdown succeed.
      return
    }
    editor?.finishComposition()
  }
  private var selectedComposerOwner: ComposerOwner? {
    if let chat = state.selectedChat, state.chats.contains(where: { $0.id == chat }) {
      return ComposerOwner(kind: .chat, id: chat)
    }
    if let document = state.selectedDocument, documents.contains(where: { $0.id == document }) {
      return ComposerOwner(kind: .document, id: document)
    }
    return nil
  }
  private func retainComposerDraft(schedule: Bool = true) {
    if usesPagedStorage {
      guard !restoringComposer, composerOwner != nil else { return }
      pagedDraftDirty = true
      if schedule { scheduleSave() }
      return
    }
    guard !restoringComposer, let owner = composerOwner,
      owner.kind == .chat ? state.chats.contains(where: { $0.id == owner.id })
        : documents.contains(where: { $0.id == owner.id }) else { return }
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
    if usesPagedStorage { try await flushPagedWorkspace(); return }
    let trace = PerformanceTrace.begin("Workspace.Flush")
    defer { PerformanceTrace.end("Workspace.Flush", trace) }
    saveTask?.cancel()
    saveTask = nil
    retainComposerDraft(schedule: false)
    let captured = documents.filter { dirty.contains($0.id) }
    // The editable source is the chat; portable voice records are its immutable snapshots.
    for voice in state.voices {
      if let chat = state.chats.first(where: { $0.id == voice.id }) {
        let revision = try ProductCore.pinnedVoice(chat, slug: voice.slug,
          occupied: state.voices.filter { $0.id != chat.id }.map(\.slug))
        retainVoice(revision)
      }
    }
    state.documents = documentIndices
    let snapshot = state
    try await store.save(snapshot, documents: captured)
    if !librarySearch.isEmpty { refreshSearch() }
    for saved in captured where documents.first(where: { $0.id == saved.id })?.textVersion == saved.textVersion {
      dirty.remove(saved.id)
    }
  }
  func scheduleSave() {
    if usesPagedStorage {
      guard !pagedShutdownRequested, pagedFirstFailure == nil else { return }
      pagedSaveRequested = true
      pagedSaveDeadline = ContinuousClock().now.advanced(by: .milliseconds(350))
      // One waiting timer coalesces edits; an entered producer keeps its real
      // task until receiving finishes. A transition joins that task first.
      guard !pagedTransition else { return }
      if let phase = pagedSavePhase, phase != .finished { return }
      do { _ = try reservePagedSave(waiting: true) }
      catch { failPagedSource(error) }
      return
    }
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 350_000_000)
        try await self?.flush()
      } catch is CancellationError {} catch { self?.report(error) }
    }
  }
  func newDocument() throws {
    if usesPagedStorage { try requirePagedOperation(); work("Creating document…") { [weak self] flag in
      try await self?.createPagedDocument(flag: flag)
    }; return }
    finishComposition()
    cancel()
    retainComposerDraft()
    let document = DocumentSnapshot(title: "Untitled", text: "")
    dirty.insert(document.id)
    appendDocument(document)
    state.selectedDocument = document.id
    restoreComposerDraft()
    resetContinuationView()
    selectedDocumentIDs = [document.id]
    state.showDocument = true
    compactPane = "document"
    invalidateGhost()
    scheduleSave()
  }
  func newChat(about documentID: UUID? = nil) throws {
    guard !usesPagedStorage else { throw BoomError.unavailable("Lazy SQL conversation authoring is a required consumer port; original rows remain retained.") }
    finishComposition()
    cancel()
    retainComposerDraft()
    if let documentID, !documents.contains(where: { $0.id == documentID }) {
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
      if let documentID, !documents.contains(where: { $0.id == documentID }) {
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
      if usesPagedStorage {
        work("Opening document…") { [weak self] flag in
          try await self?.selectPagedDocument(id, preservingSelection: preservingSelection, flag: flag)
        }; return
      }
      guard documents.contains(where: { $0.id == id }) else { return }
      finishComposition()
      retainComposerDraft()
      cancel()
      state.selectedDocument = id
      resetContinuationView()
      if layout.isAuthor, selectedChat?.attachedDocumentID != id {
        state.selectedChat = state.chats.last(where: { $0.attachedDocumentID == id })?.id
        showingChatInstructions = nil; editingChatMessage = nil
      }
      restoreComposerDraft()
      if !preservingSelection { selectedDocumentIDs = [id] }
      state.showDocument = true
        compactPane = "document"
      caret = 0
      invalidateGhost()
      scheduleSave()
      focusEditor(id)
  }
  func selectChat(_ id: UUID, preservingSelection: Bool = false) {
    guard legacyConsumerAvailable("Lazy SQL conversation hydration") else { return }
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
    if usesPagedStorage {
      guard selectedDocumentID == id, let input = pagedInput, let view = input.activeView,
        view.inputBinding?.state == .active else { return }
      let identity = view.inputBinding?.identity, focusEpoch = composerFocusEpoch
      // Reuse the existing deferred Cocoa focus handoff. It targets only this
      // exact physical client after the normal representable mounts it; a new
      // arena, selection or composer focus request makes the callback inert.
      DispatchQueue.main.async { [weak self, weak view] in
        guard let self, let view, self.selectedDocumentID == id,
          self.pagedInput === input, input.activeView === view,
          view.inputBinding?.identity == identity, view.inputBinding?.state == .active,
          self.composerFocusEpoch == focusEpoch else { return }
        view.window?.makeFirstResponder(view)
      }
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.state.selectedDocument == id, let editor = self.editor,
        editor.documentID == id else { return }
      editor.window?.makeFirstResponder(editor)
    }
  }
  func deleteDocuments(_ ids: Set<UUID>) {
    if usesPagedStorage {
      guard !ids.isEmpty, ids.count <= 7, confirm("Delete documents?", message: "Retained encrypted sources and drafts stay in the workspace archive.") else { return }
      work("Deleting documents…") { [weak self] flag in try await self?.trashPagedDocuments(ids, flag: flag) }; return
    }
    guard !isBusy, !ids.isEmpty else { return }
    let targets = documents.filter { ids.contains($0.id) }
    let discardsDrafts = (state.composerDrafts ?? []).contains { $0.owner.kind == .document && ids.contains($0.owner.id) }
    guard !targets.isEmpty, confirm(targets.count == 1 ? "Delete \(targets[0].title)?" : "Delete \(targets.count) documents?",
      message: "Encrypted records move to macOS Trash after the library change is saved. Captured chat sources and receipts stay."
        + (discardsDrafts ? " Their unsent text and pending attachment selection will be discarded." : "")) else { return }
    revokeJoinedRetentions()
    finishComposition()
    work("Deleting documents…") { [weak self] _ in
      guard let self else { return }
      try await self.flush()
      self.documents.removeAll { ids.contains($0.id) }
      self.documentIndices.removeAll { ids.contains($0.id) }
      self.state.composerDrafts?.removeAll { $0.owner.kind == .document && ids.contains($0.owner.id) }
      self.writingExampleIDs.removeAll { ids.contains($0) }
      self.state.importedFiles = self.state.importedFiles?.filter { !ids.contains($0.key) }
      if self.state.selectedDocument.map(ids.contains) == true {
        self.state.selectedDocument = self.documents.first?.id
        self.caret = 0
        self.resetContinuationView()
      }
      self.selectedDocumentIDs.subtract(ids)
      self.restoreComposerDraft()
      self.invalidateGhost()
      try await self.flush()
      for document in targets {
        try await self.store.trashDocument(document.id)
        self.undoManagers.removeValue(forKey: document.id)
      }
      if self.documents.isEmpty { try self.newDocument() }
    }
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
    if usesPagedStorage {
      let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return }
      work("Renaming document…") { [weak self] flag in try await self?.renamePagedDocument(id, to: title, flag: flag) }; return
    }
    guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    cancel()
    documents[index].title = title
    updateDocumentIndexTitle(id, title: title)
    refreshSearch(); scheduleSave()
  }
  func renameChat(_ id: UUID, to proposedTitle: String) {
    guard let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    var chat = state.chats[index]; chat.title = title
    do { try applyChat(chat) } catch { composerIssue = error.localizedDescription }
  }
  func updateDocument(_ text: String, id: UUID, caret: Int) {
    guard !usesPagedStorage else { report(BoomError.denied("Whole-document String callbacks cannot edit a paged source.")); return }
    let trace = PerformanceTrace.begin("Editor.Publish")
    defer { PerformanceTrace.end("Editor.Publish", trace) }
    guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
    invalidateGhost()
    documents[index].text = text
    writingIssue = nil
    refreshSearch()
    dirty.insert(id)
    self.caret = caret
    scheduleSave()
    scheduleCompletion()
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
    editor?.clearGhost()
  }
  func toggle(_ pane: String) {
    if usesPagedStorage {
      guard layout.paneControls.contains(pane) else { return }
      if paneFit == .compact { compactPane = compactPane == pane ? layout.primaryPane : pane; return }
      switch pane {
      case "library": pagedSettings?.showLibrary.toggle()
      case "document": pagedSettings?.showDocument.toggle()
      default: pagedSettings?.showChat.toggle()
      }
      pagedSettingsDirty = true; pagedSettingsVersion = UUID(); scheduleSave(); return
    }
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
    if usesPagedStorage {
      if pagedSettings?.theme != theme {
        pagedSettings?.theme = theme; pagedSettingsDirty = true; pagedSettingsVersion = UUID()
      }
    } else { state.theme = theme }
    NSApp.appearance =
      theme == "dark"
      ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
    scheduleSave()
  }
  func insertReference(to id: UUID) {
    guard legacyConsumerAvailable("Typed paged reference insertion") else { return }
    guard let document = documents.first(where: { $0.id == id }), let editor else { return }
    let link = "[[\(document.title)|\(id.uuidString)]]"
    editor.insertText(link, replacementRange: editor.selectedRange())
    editor.window?.makeFirstResponder(editor)
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
      var bodyEntered = false
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
        bodyEntered = true
        try await body(flag)
        try await self.flush()
        completed = true
      } catch is CancellationError {
        if self.usesPagedStorage {
          // The initial admission check ran before the body could enter any
          // source/metadata producer. This cancellation owns no SQL outcome.
          if !bodyEntered { self.status = "Stopped"; return }
          self.failPagedSource(CancellationError())
          return // actual partial source/output stays owned; no implicit flush/retry
        }
        self.status = "Stopped"
        do { try await self.flush() } catch { self.report(error) }
      } catch {
        if self.usesPagedStorage { self.failPagedSource(error); return }
        if flag.isCancelled || Task.isCancelled {
          self.status = "Stopped"
        } else {
          self.report(error)
        }
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
    if usesPagedStorage {
      pagedShutdownRequested = true
      for operation in Array(exportTasks.values) { operation.pagedResult?.cancel() }
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
    if usesPagedStorage { try await joinPagedSaves() }
    else { saveTask?.cancel() }
    searchEpoch &+= 1; searchTask?.cancel()
    historyRequest = nil; historyTask?.cancel()
    if let historyTask { await historyTask.value }
    if let foreground { await foreground.value }
    if let ghostTask { await ghostTask.value }
    await joinAndClearPromptCaches()
    for operation in Array(exportTasks.values) { await operation.task.value }
    await VideoPreparationCache.shared.release()
    if usesPagedStorage { try await flushPagedWorkspace(closing: true) }
    else { try await flush() }
    if usesPagedStorage {
      try await closePagedSelection()
      guard pagedMetadataOutput == nil, pagedReadLease == nil, pagedImported == nil, pagedInitialized == nil else {
        throw BoomError.stale("An actual workspace output/source consumer has not joined shutdown.")
      }
      if let engine = pagedEngine { try await engine.close() }
      pagedPublisher = nil; pagedEngine = nil
    }
  }
  private func revalidate(_ sources: [SourceReference], attachments: [SourceReference]) throws {
    for source in sources {
      let attachment = state.attachments.first(where: { $0.id == source.id })
      let digest = source.kind == "media" ? attachment?.rootDigest : source.kind == "attachment" ? attachment?.digest
        : documents.first(where: { $0.id == source.id })?.revision
      guard digest == source.digest else {
        throw BoomError.stale(source.title)
      }
    }
    for source in attachments {
      guard state.attachments.first(where: { $0.id == source.id })?.digest == source.digest else {
        throw BoomError.stale(source.title)
      }
    }
  }
  func send(replay: ConsultationReplay? = nil) {
    guard legacyConsumerAvailable("Typed paged consultation capture") else { return }
    let captureTrace = PerformanceTrace.begin("Request.ConsultationCapture")
    defer { PerformanceTrace.end("Request.ConsultationCapture", captureTrace) }
    if replay == nil { ensureChatForSend() }
    if replay == nil && authoredChatRole != nil { appendAuthoredChatMessage(); return }
    guard !isBusy, let chat = selectedChat, canInfer,
      replay != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    else { if !canInfer && !isBusy { prepareModels() }; return }
    let request = replay?.request ?? draft, interaction: InteractionMode = replay == nil ? mode : .propose, document = selectedDocument
    let promptContract = replay?.promptContract ?? .referenceBindingsV3
    let selectedIDs = replay?.attachmentIDs ?? pendingAttachments, style = consultationStyle
    do {
      finishComposition()
      let graph = try ContextGraph.resolveChat(request: request, attachedDocumentID: chat.attachedDocumentID,
        editingDocumentID: interaction == .ask ? nil : document?.id, all: documents)
      let slugs = try ReferenceParser.voices(request)
      guard slugs.count <= 3 else { throw BoomError.budget("Consult at most three voices per turn.") }
      guard interaction != .edit || slugs.count <= 1 else {
        throw BoomError.denied("Edit grants one voice at a time. Use Propose to compare voices.")
      }
      let voices: [Voice]
      if let replay { voices = replay.voice.map { [$0] } ?? [] }
      else { voices = try slugs.map { slug -> Voice in
        guard let voice = state.voices.first(where: { $0.slug == slug }) else { throw BoomError.invalid("Unknown voice @\(slug).") }
        return voice
      } }
      guard interaction == .ask || document != nil else { throw BoomError.denied("Choose a document before requesting edits.") }
      let inherited = graph.documents.flatMap { AttachmentLink.ids(in: $0.text) }
      let attachmentIDs = (selectedIDs + inherited).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
      guard attachmentIDs.count <= 8 else { throw BoomError.budget("At most eight attachments per turn.") }
      let attachments = try attachmentIDs.map { id -> AttachmentRecord in
        guard let record = state.attachments.first(where: { $0.id == id }) else { throw BoomError.stale("An attachment was removed.") }
        return record
      }
      if attachments.contains(where: { $0.kind == .unavailable }) {
        composerIssue = "An attachment can't be read locally. Its original has been kept."
        return
      }
      if attachments.contains(where: { $0.needsPreparation }) {
        prepareMediaForSend(attachments, chat: chat.id, request: request, interaction: interaction,
          selectedIDs: selectedIDs, documentID: state.selectedDocument)
        return
      }
      let attachmentSources = attachments.map(\.reference), sources = graph.sources + attachmentSources
      let attachmentText = promptContract == .referenceBindingsV3 ? "" : attachments.filter { !$0.text.isEmpty }.map {
        "ATTACHMENT \($0.name)\nID \($0.id)\nDIGEST \($0.digest)\nCOVERAGE \($0.coverage)\n\($0.text)"
      }.joined(separator: "\n\n")
      let authority = CapturedDocumentAuthority(mode: interaction, target: interaction == .ask ? nil : document)
      let context: String, renderedContext: RenderedReferenceContext?, capturedContextSources: [SourceReference]
      if promptContract == .referenceBindingsV3 {
        let rendered = try DocumentTools.renderedContext(graph.documents, attachments: attachments, authority: authority)
        renderedContext = rendered; context = rendered.prompt
        capturedContextSources = graph.sources + attachments.filter { !$0.text.isEmpty }.map(\.reference)
      } else {
        let documentContext = try DocumentTools.context(graph.documents, authority: authority)
        context = [documentContext, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        renderedContext = nil; capturedContextSources = []
      }
      guard context.utf8.count <= 524_288 else { throw BoomError.budget("Combined reference context exceeds 512 KiB.") }
      let instructions = chat.instructions ?? ""
      let targets: [Voice?] = voices.isEmpty ? [nil] : voices.map(Optional.some)
      let outputLimit = interaction == .ask ? 512 : 4096
      work("Checking consultation context…") { [weak self] flag in
        guard let self else { return }
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
              try await self.revalidateResponseSources(sourceDocuments.map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }, attachments: attachmentSources, targetID: responseAuthority.target?.id)
              guard interaction == .ask || self.state.selectedDocument == document?.id else { throw BoomError.stale("Active document changed.") }
              let attemptSources = sourceDocuments.map {
                SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document")
              } + attachmentSources
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
              let cacheSources = sourceDocuments.map {
                SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document")
              }
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
              try await self.revalidateResponseSources(sourceDocuments.map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }, attachments: attachmentSources, targetID: responseAuthority.target?.id)
              guard interaction == .ask || self.state.selectedDocument == document?.id else { throw BoomError.stale("Active document changed.") }
              var issue: String?
              var refreshContext = false
              if interaction != .ask {
                let capturedAuthority = responseAuthority
                let parsed = try await detachedWork { try DocumentTools.response(result.text, authority: capturedAuthority) }
                issue = parsed.issue
                if issue == nil, let patch = parsed.edits.first, let base = responseAuthority.target,
                  let current = self.selectedDocument {
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
                    chatID: chat.id, authority: responseAuthority, documentSources: sourceDocuments.map {
                      SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document")
                    }, attachments: attachmentSources, recovering: true)
                  if completed.state == .failed {
                    issue = completed.failure
                    refreshContext = self.selectedDocument?.revision != responseAuthority.target?.revision
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
                  guard let current = self.selectedDocument, current.id == authority.target?.id else {
                    throw BoomError.stale("The granted document is no longer open.")
                  }
                  responseAuthority = CapturedDocumentAuthority(mode: interaction, target: current)
                  sourceDocuments = try ContextGraph.resolveChat(request: request,
                    attachedDocumentID: chat.attachedDocumentID, editingDocumentID: current.id,
                    all: self.documents).documents
                  let fullContext: String, refreshedContext: RenderedReferenceContext?, refreshedSources: [SourceReference]
                  if promptContract == .referenceBindingsV3 {
                    let rendered = try DocumentTools.renderedContext(sourceDocuments, attachments: attachments, authority: responseAuthority)
                    refreshedContext = rendered; fullContext = rendered.prompt
                    refreshedSources = sourceDocuments.map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }
                      + attachments.filter { !$0.text.isEmpty }.map(\.reference)
                  } else {
                    let recapturedContext = try DocumentTools.context(sourceDocuments, authority: responseAuthority)
                    fullContext = [recapturedContext, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    refreshedContext = nil; refreshedSources = []
                  }
                  guard let refitChat = self.state.chats.first(where: { $0.id == chat.id }) else {
                    throw BoomError.stale("The captured chat was removed.")
                  }
                  let refitSources = sourceDocuments.map { SourceReference(id: $0.id, title: $0.title,
                    digest: $0.revision, kind: "document") }
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
    } catch { report(error) }
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
        guard let document = authority.target, let current = selectedDocument else {
          throw BoomError.stale("The captured document is no longer open.")
        }
        do { _ = try await detachedWork { try DocumentTools.validate(patch, grant: DocumentGrant(mode: authority.mode, snapshot: document), current: current) } }
        catch { responseIssue = "No document changes: \(error.localizedDescription)"; answer = text }
        if responseIssue == nil {
          let proposal = StoredProposal(id: UUID(), chatID: chatID, messageID: pending.id,
            patch: patch, document: document, documents: documentSources, attachments: attachments, status: "pending")
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
    try revalidate(sources, attachments: attachments)
    for source in sources where !["media", "attachment"].contains(source.kind) { try await store.checkDisk(source.id) }
    try revalidate(sources, attachments: attachments)
  }
  private func revalidateResponseSources(_ sources: [SourceReference], attachments: [SourceReference],
    targetID: UUID?) async throws {
    let trace = PerformanceTrace.begin("Request.SourceValidation")
    defer { PerformanceTrace.end("Request.SourceValidation", trace) }
    // The target's captured revision is checked by the Rust three-way merge.
    // Other sources, attachments and out-of-process disk writes remain guarded.
    let independent = sources.filter { $0.id != targetID }
    try await revalidateOnDisk(independent, attachments: attachments)
    if let targetID {
      guard documents.contains(where: { $0.id == targetID }) else { throw BoomError.stale("The granted document was removed.") }
      try await store.checkDisk(targetID)
    }
  }
  private func commit(_ proposal: StoredProposal) async throws {
    try await revalidateResponseSources(proposal.documents, attachments: proposal.attachments, targetID: proposal.document.id)
    let grant = DocumentGrant(mode: .propose, snapshot: proposal.document)
    var resolution: (DocumentSnapshot, DocumentSnapshot, [ValidatedEdit])?
    while resolution == nil {
      try Task.checkCancellation()
      guard state.selectedDocument == proposal.document.id, let current = selectedDocument else {
        throw BoomError.stale("Choose the original document before accepting this proposal.")
      }
      if editor?.hasMarkedText() == true {
        try await Task.sleep(for: .milliseconds(50))
        continue
      }
      let planned: (DocumentSnapshot, [ValidatedEdit])
      do { planned = try await detachedWork { try DocumentTools.plan(proposal.patch, grant: grant, current: current) } }
      catch {
        if current.revision != proposal.document.revision { throw DocumentMergeConflict.changed }
        throw error
      }
      guard selectedDocument?.id == current.id, selectedDocument?.revision == current.revision else { continue }
      resolution = (current, planned.0, planned.1)
    }
    guard let (current, updated, nativeEdits) = resolution else { throw BoomError.stale("The document changed.") }
    if updated.text == current.text {
      if let index = state.proposals.firstIndex(where: { $0.id == proposal.id }) { state.proposals[index].status = "already present" }
      status = "The document already contains these changes"
      return
    }
    editingLocked = true
    let capturedEditor = editor
    capturedEditor?.isEditable = false
    defer { editingLocked = false; capturedEditor?.isEditable = true }
    // Persist the actual pre-merge manuscript before its prepared journal, so
    // crash recovery and native Undo refer to the user's latest authored text.
    try await flush()
    let journal = DocumentEditJournal(
      schema: 1, proposalID: proposal.id, documentID: current.id, beforeRevision: current.revision,
      afterRevision: updated.revision, phase: "prepared", capturedRevision: proposal.document.revision)
    let vault = store.vault
    try await detachedWork { try vault.encode(journal, kind: .editJournal, id: proposal.id) }
    try Task.checkCancellation()
    try await store.saveDocument(updated)
    if let editor, editor.documentID == updated.id {
      editor.replaceDocument(updated.text, action: "Apply proposed edit", edits: nativeEdits)
    } else {
      registerDocumentUndo(current)
      if let index = documents.firstIndex(where: { $0.id == updated.id }) {
        documents[index] = updated
        updateDocumentIndexTitle(updated.id, title: updated.title)
        dirty.remove(updated.id)
      }
    }
    invalidateGhost()
    if let index = state.proposals.firstIndex(where: { $0.id == proposal.id }) {
      state.proposals[index].status = "applied"
      state.proposals[index].appliedRevision = updated.revision
    }
    // Updating the UI precedes this second journal write: a disk-full receipt
    // failure must not leave an old buffer poised to overwrite the applied file.
    // The already-durable prepared journal is sufficient for restart recovery.
    do {
      let finalJournal = DocumentEditJournal(
          schema: 1, proposalID: proposal.id, documentID: current.id,
          beforeRevision: current.revision, afterRevision: updated.revision, phase: "file_written", capturedRevision: proposal.document.revision)
      try await detachedWork { try vault.encode(finalJournal, kind: .editJournal, id: proposal.id) }
      status = "Document edited"
    } catch {
      throw BoomError.unavailable(
        "The document edit was applied, but its final journal mark could not be saved. The prepared recovery receipt was retained. "
          + error.localizedDescription)
    }
  }
  private func registerDocumentUndo(_ previous: DocumentSnapshot) {
    let manager = undoManager(previous.id)
    manager.beginUndoGrouping()
    manager.registerUndo(withTarget: self) { owner in
      guard !owner.editingLocked, let index = owner.documents.firstIndex(where: { $0.id == previous.id }) else { return }
      let current = owner.documents[index]
        owner.dirty.insert(previous.id)
        owner.registerDocumentUndo(current)
        owner.documents[index] = previous
        owner.updateDocumentIndexTitle(previous.id, title: previous.title)
        owner.invalidateGhost()
        owner.scheduleSave()
    }
    manager.setActionName("Document edit")
    manager.endUndoGrouping()
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
      let current = selectedDocument, undoManager(current.id).canUndo else { return false }
    if let applied = proposal.appliedRevision { return current.revision == applied }
    guard let applied = try? DocumentTools.apply(proposal.patch,
      grant: DocumentGrant(mode: .propose, snapshot: proposal.document), current: proposal.document) else { return false }
    return current.revision == applied.revision
  }
  func undoProposal(_ proposal: StoredProposal) {
    guard canUndo(proposal) else { return }
    undoManager(proposal.document.id).undo()
    if let index = state.proposals.firstIndex(where: { $0.id == proposal.id }) {
      state.proposals[index].status = "undone"
      scheduleSave()
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
    guard legacyConsumerAvailable("Lazy SQL message authoring") else { return }
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
    exportTasks[target] = (id, task, nil)
  }
  func importVoice() {
    guard legacyConsumerAvailable("Lazy SQL voice import") else { return }
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
    guard !usesPagedStorage else { return } // typed paged capture/recipe remains a required consumer port
    // An open tray retains its captured choices for branching after edits.
    // Background suggestions must not replace the visible bundle.
    guard editor?.hasGhostBoundary != true, !showingCandidates, librarySearch.isEmpty, state.autocomplete, showsDocument, !isBusy, baseReady, caret > 0,
      let document = selectedDocument, let editor, editor.selectedRange().length == 0,
      editor.window?.firstResponder === editor,
      !editor.hasMarkedText(), !candidateIsCurrent || ghostText.isEmpty else { return }
    let previous = ghostTask
    ghostFlag?.cancel(); previous?.cancel()
    let capturedEpoch = epoch, offset = caret, profile = samplingProfile
    let flag = CancellationFlag(); ghostFlag = flag
    ghostTask = Task { [weak self] in
      if let previous { await previous.value }
      do {
        try await Task.sleep(nanoseconds: 650_000_000)
        guard let self, self.epoch == capturedEpoch, !self.isBusy, !self.showingCandidates,
          self.editor?.hasGhostBoundary != true else { return }
        try await self.generateCandidates(document: document, offset: offset, profile: profile,
          count: 1, maxTokens: 64, flag: flag)
      } catch is CancellationError {} catch {
        if let self, self.epoch == capturedEpoch { self.status = "Autocomplete: " + error.localizedDescription }
      }
    }
  }
  var canExploreWriting: Bool {
    let trace = PerformanceTrace.begin("Editor.WritingAvailability")
    defer { PerformanceTrace.end("Editor.WritingAvailability", trace) }
    guard baseReady, !isBusy, let document = selectedDocument, caret > 0,
      editor?.selectedRange().length == 0, editor?.hasMarkedText() != true else { return false }
    return MarkdownTextView.hasAuthoredPrefix(document, caret: caret)
  }
  func setAutocomplete(_ enabled: Bool) {
    if usesPagedStorage {
      pagedSettings?.autocomplete = enabled; pagedSettingsDirty = true; pagedSettingsVersion = UUID()
    } else { state.autocomplete = enabled }
    invalidateGhost(); scheduleSave()
    if enabled { scheduleCompletion() }
  }
  func exploreWriting() {
    let captureTrace = PerformanceTrace.begin("Request.WritingCapture")
    defer { PerformanceTrace.end("Request.WritingCapture", captureTrace) }
    guard canExploreWriting, let document = selectedDocument else { return }
    let offset = caret, profile = samplingProfile
    writingIssue = nil; showingCandidates = true
    work("Exploring continuations…") { [weak self] flag in
      guard let self else { return }
      do {
        try await self.generateCandidates(document: document, offset: offset, profile: profile,
          count: 3, maxTokens: 256, flag: flag)
      } catch is CancellationError { throw CancellationError() }
      catch { self.writingIssue = error.localizedDescription }
    }
  }
  func openWritingExamples() {
    guard legacyConsumerAvailable("Typed paged writing examples") else { return }
    guard !isBusy, let document = selectedDocument else { return }
    editingWritingExamples = WritingExamplesRequest(manuscriptID: document.id)
  }
  func moveWritingExample(_ id: UUID, by delta: Int) {
    guard let index = writingExampleIDs.firstIndex(of: id), writingExampleIDs.indices.contains(index + delta) else { return }
    writingExampleIDs.swapAt(index, index + delta); invalidateGhost()
  }
  func addWritingExample(title: String, prose: String, manuscriptID: UUID) throws {
    guard state.selectedDocument == manuscriptID, writingExampleIDs.count < 32 else { throw BoomError.stale("Choose the original manuscript and at most 32 examples.") }
    let validated = try ProductCore.writingExample(title: title, text: prose)
    let document = DocumentSnapshot(title: validated.title, text: validated.text)
    appendDocument(document); dirty.insert(document.id)
    writingExampleIDs.append(document.id)
    invalidateGhost(); scheduleSave()
  }
  func importWritingExamples(manuscriptID: UUID) {
    guard legacyConsumerAvailable("Typed paged writing examples") else { return }
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
        for example in imported { try self.addWritingExample(title: example.title, prose: example.text, manuscriptID: manuscriptID) }
      } catch { self.writingIssue = error.localizedDescription }
    }
  }
  private func generateCandidates(document: DocumentSnapshot, offset: Int, profile: SamplingProfile,
    count: Int, maxTokens: Int, flag: CancellationFlag, previous: CandidateBundle? = nil,
    replay: WritingCandidate? = nil) async throws {
    let capturedEpoch = epoch
    let runner = try await runnerForGeneration(.writing, flag: flag)
    if let execution = replay?.batch, let seed = replay?.seed {
      try ProductCore.validateWritingBatch(execution, seed: seed)
    }
    let seeds = replay.map { $0.batch?.seeds ?? [$0.seed] }
      ?? (0..<count).map { _ in UInt64.random(in: .min ... .max) }
    try ProductCore.admitWritingBatch(width: seeds.count, prompt: 1, output: maxTokens, capacity: 16_384)
    try await flush()
    let authored = try ProductCore.authoredPrefix(document, caret: offset)
    let mediaText = previous?.recipe.sourcePrompt ?? ([authored] + writingExampleIDs.compactMap { id in documents.first(where: { $0.id == id })?.text }).joined(separator: "\n\n")
    let media = try await writingMedia(in: mediaText, flag: flag)
    let fitOwner: PromptCacheOwner? = replay == nil
      ? PromptCacheOwner(namespace: inferenceCacheNamespace, entity: document.id, route: .writing) : nil
    let capturedExamples = writingExampleIDs
    let examples = try (previous == nil ? capturedExamples : []).map { id in
      guard let value = documents.first(where: { $0.id == id }) else { throw BoomError.stale("An example was removed.") }
      return value
    }
    let admissionSources = previous?.recipe.sources ?? (([document] + examples).map {
      SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document")
    } + media.map { $0.reference.source })
    let pairedAdmission = makePairedContextAdmission(runner: runner, purpose: .writing,
      owner: fitOwner, flag: flag) { [weak self] in
      guard let workspace = self else { throw CancellationError() }
      try await workspace.validateWritingAdmissionSource(document: document, offset: offset,
        examples: capturedExamples, sources: admissionSources, capturedEpoch: capturedEpoch, flag: flag)
    }
    let recipe: CompletionRecipe
    if let previous { recipe = previous.recipe }
    else {
      let sources = admissionSources
      try await revalidateOnDisk(sources, attachments: [])
      recipe = try await runner.completionRecipe(document: document, caret: offset,
        sources: sources, examples: examples.map(\.text), profile: profile,
        maxTokens: maxTokens, flag: flag, batchWidth: seeds.count, media: media,
        cacheOwner: fitOwner, pairedAdmission: pairedAdmission)
    }
    try ProductCore.validateWritingRecipe(recipe)
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
          beforeCachePublication: { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.revalidateOnDisk(recipe.sources, attachments: [])
            try await MainActor.run {
              try flag.check()
              guard self.writingFlag === flag, self.epoch == capturedEpoch,
                self.state.selectedDocument == recipe.document.id else {
                throw BoomError.stale("The writing source changed before prompt-cache publication.")
              }
            }
          },
          pairedAdmission: pairedAdmission,
          onCheckpoint: { [weak self] updates in
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
        + (recipe.omittedPrefixCharacters == 0 ? "full preceding manuscript" : "\(recipe.omittedPrefixCharacters) earlier characters omitted")
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
    guard !usesPagedStorage else { return false }
    guard let documentID = state.selectedDocument else { return false }
    return showingCandidates || (!isBusy && (candidates?.recipe.document.id == documentID || latestSavedCandidate != nil))
  }
  func showContinuations() {
    guard legacyConsumerAvailable("Typed paged candidate history") else { return }
    if showingCandidates { showingCandidates = false; return }
    guard !isBusy else { return }
    if candidates?.recipe.document.id == state.selectedDocument { showingCandidates = true }
    else if let id = latestSavedCandidate { reviewContinuation(id) }
  }
  func reviewContinuation(_ id: UUID) {
    guard !isBusy, let document = selectedDocument, state.candidateIDs.contains(id) else { return }
    let capturedCaret = caret
    work("Opening continuations…") { [weak self] flag in
      guard let self else { return }
      let capturedEpoch = self.epoch
      let bundle = try await self.store.readCandidate(id)
      try flag.check()
      guard self.activeFlag === flag, self.selectedDocument == document,
        self.caret == capturedCaret, self.epoch == capturedEpoch else { throw CancellationError() }
      guard bundle.recipe.document.id == document.id else {
        throw BoomError.invalid("These continuations belong to another manuscript.")
      }
      self.candidates = bundle; self.showingCandidates = true; self.writingIssue = nil
      self.refreshContinuationHistory()
    }
  }
  func dismissCandidates() { invalidateGhost(); showingCandidates = false; candidates = nil }
  private func showCandidateGhost(_ text: String, recipe: CompletionRecipe, epoch: UInt64) {
    guard let document = selectedDocument, document.id == recipe.document.id,
      document.revision == recipe.document.revision, caret == recipe.caretUTF16,
      let stamp = try? GhostStamp(document: document, caretUTF16: caret, epoch: epoch),
      stamp.accepts(document: document, caretUTF16: caret, epoch: self.epoch,
        hasMarkedText: editor?.hasMarkedText() ?? true), let visible = GemmaPrompt.visibleCompletion(text)
    else { return }
    ghostSources = recipe.sources; ghostStamp = stamp; ghostText = visible
    editor?.showGhost(visible, stamp: stamp)
  }
  var candidateIsCurrent: Bool {
    guard let recipe = candidates?.recipe, let document = selectedDocument else { return false }
    return document.id == recipe.document.id && document.revision == recipe.document.revision
      && caret == recipe.caretUTF16 && (try? revalidate(recipe.sources, attachments: [])) != nil
      && editor?.hasMarkedText() != true
  }
  func selectCandidate(_ index: Int) {
    guard let bundle = candidates, bundle.candidates.indices.contains(index) else { return }
    candidates?.selected = index
    ghostText = ""; ghostStamp = nil; ghostSources = []; editor?.clearGhost()
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
      bundle.candidates[index].state == .complete, let editor else { return }
    editor.window?.makeFirstResponder(editor)
    selectCandidate(index)
    _ = editor.acceptNextGhostWord()
  }
  func acceptCandidate(_ index: Int) {
    guard candidateIsCurrent, let bundle = candidates, bundle.candidates.indices.contains(index),
      bundle.candidates[index].state == .complete, let editor else { return }
    let text = bundle.candidates[index].text
    cancel(); showingCandidates = false
    editor.window?.makeFirstResponder(editor)
    editor.insertText(text, replacementRange: NSRange(location: bundle.recipe.caretUTF16, length: 0))
  }
  func branchCandidate(_ index: Int) {
    guard !isBusy, let bundle = candidates, bundle.candidates.indices.contains(index),
      bundle.candidates[index].state == .complete, editor?.hasMarkedText() != true else { return }
    do {
      let snapshot = bundle.recipe.document
      let text = try ProductCore.branchWriting(bundle.recipe, continuation: bundle.candidates[index].text)
      let document = DocumentSnapshot(title: snapshot.title + " · branch", text: text)
      state.manuscriptOrigins[document.id] = ManuscriptOrigin(documentID: snapshot.id, revision: snapshot.revision,
        bundleID: bundle.id, candidateID: bundle.candidates[index].id)
      appendDocument(document); dirty.insert(document.id); selectDocument(document.id)
      showingCandidates = false; scheduleSave()
    } catch { report(error) }
  }
  func takeGhost(documentID: UUID, caret: Int) -> String? {
    guard let d = selectedDocument, d.id == documentID, let stamp = ghostStamp,
      stamp.accepts(
        document: d, caretUTF16: caret, epoch: epoch, hasMarkedText: editor?.hasMarkedText() ?? true
      ), !ghostText.isEmpty
    else {
      invalidateGhost()
      return nil
    }
    do {
      try revalidate(ghostSources, attachments: [])
    } catch {
      status = error.localizedDescription
      invalidateGhost()
      return nil
    }
    let value = ghostText
    invalidateGhost()
    return value
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
  func resumeGhost(_ text: String, documentID: UUID, caret: Int,
    sources: [SourceReference]) {
    guard !text.isEmpty, let document = selectedDocument, document.id == documentID,
      self.caret == caret, editor?.selectedRange().location == caret,
      editor?.selectedRange().length == 0, editor?.string == document.text,
      (try? revalidate(sources, attachments: [])) != nil,
      let stamp = try? GhostStamp(document: document, caretUTF16: caret, epoch: epoch)
    else { return }
    ghostSources = sources
    ghostStamp = stamp
    ghostText = text
    editor?.showGhost(text, stamp: stamp)
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
  private func selectImportedDocument(_ id: UUID) {
    retainComposerDraft()
    state.selectedDocument = id; selectedDocumentIDs = [id]; state.showDocument = true
    caret = 0; resetContinuationView()
    state.selectedChat = nil; restoreComposerDraft()
    showingChatInstructions = nil; editingChatMessage = nil
    compactPane = "document"; invalidateGhost(); focusEditor(id)
  }
  func importFolder() {
    guard legacyConsumerAvailable("Folder provenance enumeration") else { return }
    guard !isBusy, layout.isAuthor else { return }
    finishComposition()
    let panel = NSOpenPanel()
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.prompt = "Import"; panel.message = "Copy Markdown and text files into Bloom's encrypted library."
    guard panel.runModal() == .OK, let root = panel.url else { return }
    work("Importing folder…") { [weak self] flag in
      guard let self else { return }
      let scope = root.startAccessingSecurityScopedResource()
      defer { if scope { root.stopAccessingSecurityScopedResource() } }
      let files = try await detachedWork { try FolderImport.read(root, flag: flag) }
      try flag.check()
      try await self.store.retainImportedOriginals(files, flag: flag)
      try flag.check()
      let folder = ImportedFolder(id: UUID(), name: root.lastPathComponent)
      self.state.importedFolders = (self.state.importedFolders ?? []) + [folder]
      for file in files {
        let title = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        self.appendDocument(DocumentSnapshot(id: file.id, title: title, text: file.text))
        self.dirty.insert(file.id)
        self.state.importedFiles = self.state.importedFiles ?? [:]
        self.state.importedFiles?[file.id] = ImportedFile(folderID: folder.id, path: file.path,
          originalDigest: Digest.sha256(file.original))
      }
      if let first = files.first { self.selectImportedDocument(first.id) }
      try await self.flush()
      self.status = "Imported \(files.count) documents into encrypted storage"
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
    if usesPagedStorage {
      for url in urls { try flag.check(); try await importPagedDocument(url, title: url.deletingPathExtension().lastPathComponent, flag: flag) }
      return
    }
    let imported = try await detachedWork { try DocumentImport.read(urls, flag: flag) }
    try flag.check()
    try await store.retainImportedOriginals(imported, flag: flag)
    try flag.check()
    state.importedFiles = state.importedFiles ?? [:]
    for file in imported {
      let document = DocumentSnapshot(id: file.id,
        title: URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent, text: file.text)
      dirty.insert(document.id); appendDocument(document)
      state.importedFiles?[file.id] = ImportedFile(folderID: nil, path: file.path, originalDigest: Digest.sha256(file.original))
    }
    if let first = imported.first { selectImportedDocument(first.id) }
    try await flush()
  }
  func exportDocument(_ id: UUID? = nil) {
    if usesPagedStorage {
      guard let documentID = id ?? selectedDocumentID,
        let record = pagedSelectedRecord?.document.id == documentID ? pagedSelectedRecord
          : pagedDocumentPage.first(where: { $0.document.id == documentID }) else { return }
      let panel = NSSavePanel(); panel.nameFieldStringValue = record.document.title + ".md"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      do { _ = try exportPagedDocument(to: url, documentID: documentID) }
      catch { report(error) }
      return
    }
    finishComposition()
    guard let d = documents.first(where: { $0.id == (id ?? state.selectedDocument) }) else {
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = d.title + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    exportFile(to: url) { Data(d.text.utf8) }
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
          guard self.pagedSession === session, session.generation == generation,
            let projection = session.canonicalHistory,
            projection.scope.coveredSequence == generation, projection.record.document.revision == revision else {
            throw BoomError.stale("The exported native prefix changed before its actual full-record capture.")
          }
          captured = projection.record
        }
        // These local read outputs belong to this export, not Model's selection
        // read slot. No live workspace settings are overwritten during capture.
        let settings = try await engine.loadWorkspaceSettingsRetaining(publisher)
        let head = settings.value.head
        do { try await engine.abandonJoinedRootOutput(settings.lease) }
        catch { throw PagedTextCustodyFailure(original: error, lease: settings.lease) }
        if captured == nil {
          let read = try await engine.loadWorkspaceDocumentRetaining(publisher, documentID: documentID, expectedHead: head)
          captured = read.value.record
          do { try await engine.abandonJoinedRootOutput(read.lease) }
          catch { throw PagedTextCustodyFailure(original: error, lease: read.lease) }
        }
        guard let captured, captured.document.id == documentID else { throw BoomError.stale("Actual export admission returned another source.") }
        return try await self.store.exportPagedDocument(captured, expectedHead: head,
          engine: engine, publisher: publisher, to: target, cancellation: cancellation)
      } onCancel: {
        cancellation.cancel()
        previous?.pagedResult?.cancel()
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
    exportTasks[target] = (id, observer, producer)
    return producer
  }
  func cancelExport(to url: URL) {
    // Cancel the actual source/coordination task. Its scoped handler also
    // cancels this same destination's entered predecessor and explicit token.
    exportTasks[url.standardizedFileURL]?.pagedResult?.cancel()
  }
  func revealDocument(_ id: UUID) {
    NSWorkspace.shared.activateFileViewerSelecting([store.documentURL(id)])
  }
  private func insertAttachmentLinks(
    _ attachments: [AttachmentRecord], into destination: AttachmentDestination
  ) throws {
    guard case .document(let id, let revision, let range) = destination else {
      throw BoomError.invalid("A document destination is required for Markdown links.")
    }
    guard let index = documents.firstIndex(where: { $0.id == id }) else {
      throw BoomError.stale("The attachment's document was removed.")
    }
    guard !attachments.isEmpty else { return }
    let links = attachments.map { attachment in
      let name = attachment.name.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "]", with: "\\]")
        .replacingOccurrences(of: "\n", with: " ")
      return "[Attachment: \(name)](boom-attachment:\(attachment.id.uuidString))"
    }.joined(separator: "\n") + "\n"
    let current = documents[index]
    let insertion = current.revision == revision
      ? Range(range, in: current.text) : nil
    guard let replacement = insertion else { throw BoomError.stale("The attachment insertion target changed. Its original bytes were retained.") }
    // Media occupy their own paragraph while retaining the exact source on
    // both sides of the captured paste range.
    let prefix = current.text[..<replacement.lowerBound]
    let value = (prefix.isEmpty || prefix.hasSuffix("\n") ? "" : "\n") + links
    if state.selectedDocument == id, let editor, editor.documentID == id,
      editor.string == current.text,
      let native = NSRange(replacement, in: current.text) as NSRange? {
      editor.insertText(value, replacementRange: native)
    } else {
      documents[index].text.replaceSubrange(replacement, with: value)
      dirty.insert(id)
      scheduleSave()
    }
  }
  func chooseAttachmentFiles(to destination: AttachmentDestination) {
    guard legacyConsumerAvailable("Typed paged attachments") else { return }
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
    case .document(let id, _, _):
      guard documents.contains(where: { $0.id == id }) else {
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
  /// Admission and encrypted storage can finish while model preparation runs.
  func attachRecordedAudio(_ data: Data, chatID: UUID?, documentID: UUID?) async throws {
    guard !isBusy || settingUpModels, state.selectedChat == chatID,
      state.selectedDocument == documentID, pendingAttachments.count < 8 else {
      throw BoomError.stale("The recording's conversation changed.")
    }
    let imported = try await detachedWork {
      guard try ProductCore.admitMedia(data).rawValue == "wav" else {
        throw BoomError.invalid("The recording is not local PCM audio.")
      }
      return try AttachmentProcessor.inspect(name: "Recording.wav", data: data)
    }
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
    examples: [UUID], sources: [SourceReference], capturedEpoch: UInt64, flag: CancellationFlag) async throws {
    func check() throws {
      try flag.check()
      guard epoch == capturedEpoch, state.selectedDocument == document.id,
        selectedDocument?.textVersion == document.textVersion, caret == offset,
        writingExampleIDs == examples else {
        throw BoomError.stale("The captured writing source changed before paired-model reclamation.")
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
      if self.usesPagedStorage {
        self.pagedSettings?.preferredModels[choice.candidate.purpose.rawValue] = choice.id
        self.pagedSettingsDirty = true; self.pagedSettingsVersion = UUID()
      } else {
        if self.state.preferredModels == nil { self.state.preferredModels = [:] }
        self.state.preferredModels?[choice.candidate.purpose.rawValue] = choice.id
      }
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
  func backupWorkspace(restoring: Bool) {
    guard legacyConsumerAvailable("Paged backup/inventory") else { return }
    guard !isBusy else { return }
    if restoring {
      let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]
      guard panel.runModal() == .OK, let url = panel.url else { return }
      backupRequest = BackupRequest(url: url, restoring: true)
    } else {
      let panel = NSSavePanel(); panel.nameFieldStringValue = "Bloom.bloombackup"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      backupRequest = BackupRequest(url: url, restoring: false)
    }
  }
  func performBackup(_ request: BackupRequest, passphrase: String) {
    backupRequest = nil
    if request.restoring { revokeJoinedRetentions(); joinedRetentionEpoch = UUID() }
    work(request.restoring ? "Restoring encrypted backup…" : "Encrypting complete backup…") { [weak self] _ in
      guard let self else { return }
      try await self.flush()
      if request.restoring {
        await self.joinAndClearPromptCaches()
        let restored = try await self.store.restoreBackup(passphrase: passphrase, from: request.url)
        self.state = restored.0; self.documents = restored.1
        self.documentIndices = restored.1.map { DocumentIndex(id: $0.id, title: $0.title) }
        self.dirty.removeAll(); self.undoManagers.removeAll()
        self.selectedDocumentIDs = Set(self.state.selectedDocument.map { [$0] } ?? [])
        self.selectedChatIDs = Set(self.state.selectedChat.map { [$0] } ?? [])
        self.writingExampleIDs = self.state.writingExampleIDs ?? []
        self.restoreComposerDraft(); self.invalidateGhost()
        self.status = "Backup restored"
      } else {
        try await self.store.exportBackup(passphrase: passphrase, to: request.url)
        self.status = "Complete encrypted backup exported"
      }
    }
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
  /// Join the actual existing foreground task. This is also useful for normal
  /// close/receiving callers; an elapsed delay is never used as completion.
  func joinWorkspaceOperation() async throws {
    if let foreground { await foreground.value }
    if let pagedFirstFailure { throw pagedFirstFailure }
  }
  private func legacyConsumerAvailable(_ consumer: String) -> Bool {
    guard !usesPagedStorage else {
      report(BoomError.unavailable("\(consumer) has no bounded SQL consumer yet; existing source/metadata records were retained."))
      return false
    }
    return true
  }
  private func requirePagedOperation() throws {
    guard usesPagedStorage, !pagedTransition, !pagedShutdownRequested,
      pagedImported == nil, pagedInitialized == nil else {
      throw BoomError.stale("The ordinary workspace has an entered transition or actual unreceived output.")
    }
    if let pagedFirstFailure { throw pagedFirstFailure }
    // A real save can be inside its read/receiving await. The transition's
    // reserved successor joins that exact task before using either field.
    guard pagedMetadataOutput == nil && pagedReadLease == nil || pagedSaveRunningID != nil else {
      throw BoomError.stale("An ordinary read/publication has no entered save task to join.")
    }
  }
  private func pagedOwners() throws -> (PagedTextEngineAdapter, PagedWorkspacePublisher) {
    guard usesPagedStorage, let engine = pagedEngine, let publisher = pagedPublisher,
      engine.belongs(to: store.vault), publisher.belongs(to: store.vault),
      engine.ownerID == publisher.ownerID else {
      throw BoomError.denied("The ordinary workspace has no actual admitted SQL/Vault owners.")
    }
    return (engine, publisher)
  }
  private func failPagedSource(_ error: Error) {
    if pagedFirstFailure == nil { pagedFirstFailure = error }
    report(error)
  }
  private func releasePagedRead(_ lease: PagedTextRootLease, engine: PagedTextEngineAdapter) async throws {
    guard pagedReadLease == lease else { throw BoomError.denied("Another actual workspace read owns this output.") }
    // Keep the field on refusal. A dropped reply is not an implicit release.
    try await engine.abandonJoinedRootOutput(lease)
    pagedReadLease = nil
  }
  private func openPagedWorkspace() async throws {
    let opening = try await store.preparePagedStorageOpening()
    let engine = try await PagedTextEngineAdapter.create(vault: store.vault,
      ownerID: opening.identity.ownerID, sqliteOpening: opening.sql)
    pagedEngine = engine // own the ACTUAL engine before the next await
    let publisher = try await engine.makeWorkspacePublisher()
    pagedPublisher = publisher
    if case .fresh = opening.sql {
      // A real empty fresh metadata inventory is not an empty source snapshot.
      // It has no documents/chats. Subsequent insertion uses the actual source
      // and history producers through the same normal metadata receiver.
      let input = try await detachedWork {
        try WorkspaceMetadataInput(settings: WorkspaceSettings(), initialDocuments: [])
      }
      let result = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: nil)
      pagedMetadataOutput = result
      pagedHead = try await store.finishPagedMetadataPublication(result, engine: engine, publisher: publisher)
      pagedMetadataOutput = nil
    }
    let loaded = try await store.loadPagedMetadataOpening(engine: engine, publisher: publisher)
    pagedHead = loaded.head; pagedSettings = loaded.settings
    pagedDocumentPage = try loaded.documents.map { value in
      guard case .paged(let record) = value else { throw BoomError.denied("A SQL library page cannot admit a legacy descriptor.") }
      return record
    }
    documentIndices = pagedDocumentPage.map { DocumentIndex(id: $0.document.id, title: $0.document.title) }
    pagedNextDocumentOrdinal = loaded.nextDocumentOrdinal; pagedChatPage = loaded.chats
    writingExampleIDs = loaded.settings.writingExampleIDs
    // The published didSet keeps user-authored changes; this initialization is
    // the actual authenticated stored selection, not a dirty synthetic rewrite.
    pagedSettingsDirty = false
    selectedDocumentIDs = Set(loaded.settings.selectedDocument.map { [$0] } ?? [])
    selectedChatIDs = Set(loaded.settings.selectedChat.map { [$0] } ?? [])
    if let selected = loaded.selectedDocument {
      guard case .paged(let record) = selected else { throw BoomError.denied("Selected SQL source has a legacy descriptor.") }
      try await openPagedSelection(record)
    }
    if let owner = pagedComposerOwner { try await restorePagedDraft(owner) }
    // Fresh creation is a real ordinary insertion, not a missing/corrupt-row
    // fallback. Existing settings with no selected source remain genuinely nil.
    if case .fresh = opening.sql, layout.isAuthor {
      try await createPagedDocument(flag: CancellationFlag())
    }
  }
  private var pagedComposerOwner: ComposerOwner? {
    if let chat = pagedSettings?.selectedChat { return ComposerOwner(kind: .chat, id: chat) }
    if let document = pagedSettings?.selectedDocument { return ComposerOwner(kind: .document, id: document) }
    return nil
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
    let commands = try PagedNativeUndoOwner(input: input)
    pagedCommands = commands
    let viewport = try PagedDocumentViewport(frame: NSRect(x: 0, y: 0, width: 640, height: 480), input: input)
    pagedViewport = viewport
    commands.mountView = { [weak viewport] old, new in
      guard let viewport else { throw BoomError.stale("The ordinary selected viewport lost its real receiving host.") }
      try viewport.mountManagedView(from: old, to: new)
    }
    commands.didFail = { [weak self] error in self?.failPagedSource(error) }
    session.didFail = { [weak self] error in self?.failPagedSource(error) }
    session.didSeal = { [weak self, weak session] _ in
      guard let self, let session, self.pagedSession === session,
        let projection = session.canonicalHistory,
        projection.record.document.id == self.pagedSelectedRecord?.document.id else { return }
      // The actual worker projection is already received. No title-array
      // rebuild, document hash, metadata encode, IO or whole source copy here.
      self.pagedSelectedRecord = projection.record
    }
    viewport.didRejectPresentation = { [weak self] error in self?.report(error) }
    try viewport.enableDocumentNavigation(engine: engine, publisher: publisher)
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
    try await commands.joinPendingCommand()
    let generation = session.generation
    _ = try await session.flush(through: generation)
    try await viewport.closePresentation()
    try await commands.joinPendingCommand()
    guard session.generation == generation, let history = session.canonicalHistory,
      history.record == pagedSelectedRecord else {
      throw BoomError.stale("Later admitted input keeps its existing source; selection did not discard it.")
    }
    _ = try session.windowForNativeInstallation() // real source/producer/IME join admission
    try commands.closeInput()
    try commands.requireJoinedClose(); try input.requireJoinedClose()
    try await backend.detachJoinedController(sessionID: session.sessionID,
      sequence: generation, record: history.record)
    // Clearing requires the actual Input/Foundation retirement AND the exact
    // same Engine/head transfer. Retained old contexts contain inert proxies.
    session.didSeal = nil; session.didFail = nil
    pagedViewport = nil; pagedCommands = nil; pagedInput = nil
    pagedSession = nil; pagedBackend = nil
  }
  private func refreshPagedHead() async throws {
    let (engine, publisher) = try pagedOwners()
    guard pagedReadLease == nil else { throw BoomError.stale("Another ordinary read has not joined.") }
    let read = try await engine.loadWorkspaceSettingsRetaining(publisher)
    pagedReadLease = read.lease
    if let previous = pagedHead, previous.workspace != read.value.head.workspace {
      // Current settings/draft changes belong to this actual receiver. An
      // external metadata writer cannot be silently merged over dirty state.
      try await releasePagedRead(read.lease, engine: engine)
      throw BoomError.stale("Workspace metadata changed outside this ordinary receiver; its current input was retained.")
    }
    pagedHead = read.value.head
    try await releasePagedRead(read.lease, engine: engine)
  }
  private func receivePagedMetadata(_ result: PagedTextCustodiedValue<WorkspaceMetadataPublication>) async throws {
    let (engine, publisher) = try pagedOwners()
    guard pagedMetadataOutput == nil else { throw BoomError.stale("An earlier actual metadata output has not been received.") }
    pagedMetadataOutput = result
    pagedHead = try await store.finishPagedMetadataPublication(result, engine: engine, publisher: publisher)
    pagedMetadataOutput = nil
  }
  /// A real save reservation is installed synchronously before the caller's
  /// first await. The existing tail task joins its predecessor; at most eight
  /// entered/reserved task bodies can be admitted. No second storage lane.
  @discardableResult
  func beginPagedWorkspaceSave() throws -> Task<Void, Never> {
    guard usesPagedStorage, pagedEngine != nil, !pagedTransition, !pagedShutdownRequested else {
      throw BoomError.stale("An ordinary transition owns the current save admission.")
    }
    if let pagedFirstFailure { throw pagedFirstFailure }
    return try reservePagedSave(waiting: false)
  }
  private func reservePagedSave(waiting: Bool) throws -> Task<Void, Never> {
    guard pagedSaveTaskCount < Self.maximumPagedSaveTasks else {
      throw BoomError.budget("The existing workspace save task has eight pending reservations.")
    }
    let previous = saveTask, id = UUID()
    // Only a not-yet-entered timer can be cancelled. Its successor still
    // awaits the actual task, including any predecessor it was joining.
    if pagedSavePhase == .waiting { previous?.cancel() }
    pagedSaveID = id; pagedSavePhase = waiting ? .waiting : .reserved
    pagedSaveTaskCount += 1
    let task = Task { [weak self] in
      if let previous { await previous.value }
      guard let self else { return }
      var entered = false
      defer {
        if self.pagedSaveRunningID == id { self.pagedSaveRunningID = nil }
        self.pagedSaveTaskCount -= 1
        if self.pagedSaveID == id {
          self.pagedSavePhase = .finished; self.pagedSaveDeadline = nil
          if self.pagedSaveRequested, self.pagedSettingsDirty || self.pagedDraftDirty {
            self.scheduleSave()
          }
        }
      }
      do {
        if waiting {
          let clock = ContinuousClock()
          while true {
            try Task.checkCancellation()
            guard self.pagedSaveID == id, !self.pagedTransition, !self.pagedShutdownRequested,
              let deadline = self.pagedSaveDeadline else { return }
            try await clock.sleep(until: deadline)
            try Task.checkCancellation()
            guard self.pagedSaveID == id, !self.pagedTransition, !self.pagedShutdownRequested,
              let currentDeadline = self.pagedSaveDeadline else { return }
            if clock.now < currentDeadline { continue }
            break
          }
          // A timer has not entered source work. Keep the dirty metadata and
          // defer its ordinary save while the real native client owns IME.
          // Explicit capture/transition/close still uses the joined guard.
          if self.pagedInput?.activeView?.hasMarkedText() == true { return }
        }
        if let failure = self.pagedFirstFailure { throw failure }
        guard self.pagedSaveRunningID == nil else {
          throw BoomError.stale("A prior workspace save producer did not join its actual task.")
        }
        self.pagedSaveRunningID = id
        if self.pagedSaveID == id { self.pagedSavePhase = .entered }
        entered = true; self.pagedSaveRequested = false
        try await self.performPagedFlush(saveID: id)
      } catch {
        if !entered, error is CancellationError { return }
        self.failPagedSource(error)
      }
    }
    saveTask = task
    return task
  }
  private func joinPagedSaves() async throws {
    // This handle can be a timer, an entered producer or a reserved successor.
    // The handle itself is the join proof, never its phase or the debounce clock.
    if let task = saveTask {
      let id = pagedSaveID
      if pagedSavePhase == .waiting { task.cancel() }
      await task.value
      if pagedSaveID == id {
        saveTask = nil; pagedSaveID = nil; pagedSavePhase = nil; pagedSaveDeadline = nil
      }
    }
    if let pagedFirstFailure { throw pagedFirstFailure }
  }
  private func flushPagedWorkspace(insideTransition: Bool = false, closing: Bool = false) async throws {
    if let pagedFirstFailure { throw pagedFirstFailure }
    guard let _ = pagedEngine else { return }
    guard pagedTransition == insideTransition, !pagedShutdownRequested || closing else {
      throw BoomError.stale("An actual transition or shutdown owns the current save admission.")
    }
    let task = try (insideTransition || closing ? reservePagedSave(waiting: false) : beginPagedWorkspaceSave())
    let id = pagedSaveID
    await task.value
    if pagedSaveID == id {
      saveTask = nil; pagedSaveID = nil; pagedSavePhase = nil; pagedSaveDeadline = nil
    }
    if let pagedFirstFailure { throw pagedFirstFailure }
  }
  private func performPagedFlush(saveID: UUID) async throws {
    guard pagedSaveRunningID == saveID, pagedMetadataOutput == nil, pagedReadLease == nil else {
      throw BoomError.stale("An actual read/publication remains owned by the workspace save producer.")
    }
    if let commands = pagedCommands, let session = pagedSession {
      try await commands.joinPendingCommand()
      _ = try await session.flush(through: session.generation)
    }
    guard pagedSettingsDirty || pagedDraftDirty else { return }
    let (engine, publisher) = try pagedOwners()
    let settings = pagedSettingsDirty ? pagedSettings : nil
    let settingsVersion = pagedSettingsVersion, capturedDraftVersion = draftVersion
    let owner = composerOwner, reference = pagedDraftReference
    let retainedDraft = pagedDraftDirty ? owner.map {
      ComposerDraft(owner: $0, text: draft, attachments: pendingAttachments, authoredRole: authoredChatRole)
    } : nil
    try await refreshPagedHead()
    guard let head = pagedHead else { throw BoomError.stale("The workspace has no received full metadata head.") }
    // Encode only changed16KiB settings/one owner draft on utility. The input
    // allocation is charged by the existing3MiB/4MiB Root contract, not a new
    // queue or an unbounded WorkspaceState serialization on every text edit.
    let input = try await detachedWork {
      let entities = try retainedDraft.map { [try WorkspaceEntityInput.draft($0, expected: reference)] } ?? []
      return try WorkspaceMetadataInput(settings: settings, entities: entities)
    }
    let result = try await engine.publishWorkspaceMetadataRetaining(publisher, input: input, expectedHead: head)
    try await receivePagedMetadata(result)
    if pagedSettingsVersion == settingsVersion { pagedSettingsDirty = false }
    if composerOwner == owner, draftVersion == capturedDraftVersion {
      pagedDraftDirty = false
    }
    if let owner, let changed = result.value.changes.first(where: { $0.after?.parentID == owner.id && $0.after?.kind == .draft }) {
      pagedDraftReference = changed.after
    }
  }
  private func finishPagedTransition() {
    pagedTransition = false
    if pagedSettingsDirty || pagedDraftDirty { scheduleSave() }
  }
  private func restorePagedDraft(_ owner: ComposerOwner) async throws {
    let (engine, publisher) = try pagedOwners()
    let focus = composerFocusEpoch, version = draftVersion
    guard pagedReadLease == nil, !pagedDraftDirty else {
      throw BoomError.stale("The previous owner draft/input still belongs to this receiver.")
    }
    let captured = try await engine.loadWorkspaceDraftRetaining(publisher, owner: owner)
    pagedReadLease = captured.lease
    // This header remains pinned while its bounded parts are read. Individual
    // part outputs always join before the next; failed part custody is returned
    // by the actual Engine and never replaced with an empty draft.
    var retained: ComposerDraft?
    var headerReleaseAttempted = false
    do {
      if let value = captured.value {
        guard value.header.draftOwner == owner, let body = value.header.bodies["text"],
          body.bytes <= 2_097_152 else { throw BoomError.denied("Selected draft has another owner/body envelope.") }
        var bytes = Data(); bytes.reserveCapacity(body.bytes)
        for part in 0..<body.partCount {
          let window = try await engine.loadWorkspaceEntityBodyPartRetaining(publisher, reference: value.reference, field: "text", part: part)
          bytes.append(window.value)
          do { try await engine.abandonJoinedRootOutput(window.lease) }
          catch { throw PagedTextCustodyFailure(original: error, lease: window.lease) }
        }
        let exactBytes = bytes
        retained = try await detachedWork { try value.header.hydratedDraft(bytes: exactBytes) }
      }
      guard composerFocusEpoch == focus, draftVersion == version, pagedComposerOwner == owner else {
        throw BoomError.stale("Later composer input/focus keeps its original text; the delayed draft was not adopted.")
      }
      headerReleaseAttempted = true
      try await releasePagedRead(captured.lease, engine: engine)
    } catch {
      // Original body/header/input failures remain associated with this same
      // Model, even if its read producer cannot be released. No error retry.
      let original = error
      if !headerReleaseAttempted, pagedReadLease == captured.lease {
        headerReleaseAttempted = true
        do { try await releasePagedRead(captured.lease, engine: engine) }
        catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: captured.lease) }
      }
      throw original
    }
    restoringComposer = true
    defer { restoringComposer = false }
    composerOwner = owner; pagedDraftReference = captured.value?.reference
    draft = retained?.text ?? "" // genuine authenticated absence only
    pendingAttachments = retained?.attachments ?? []
    authoredChatRole = retained?.authoredRole; mode = .ask
    pagedDraftDirty = false
  }
  private func selectedPagedRecord(_ id: UUID) async throws -> PagedDocumentRootRecord {
    if pagedSelectedRecord?.document.id == id, let session = pagedSession {
      _ = try await session.flush(through: session.generation)
      guard let actual = session.canonicalHistory?.record else { throw BoomError.stale("Selected native source lost its real canonical projection.") }
      pagedSelectedRecord = actual; return actual
    }
    try await refreshPagedHead()
    let (engine, publisher) = try pagedOwners()
    guard let head = pagedHead else { throw BoomError.stale("The ordinary workspace has no actual head.") }
    let result = try await engine.loadWorkspaceDocumentRetaining(publisher, documentID: id, expectedHead: head)
    pagedReadLease = result.lease
    let record = result.value.record
    try await releasePagedRead(result.lease, engine: engine)
    return record // descriptor only; actual opening later authenticates source/history
  }
  func selectPagedDocument(_ id: UUID, preservingSelection: Bool = false,
    flag: CancellationFlag = CancellationFlag()) async throws {
    try requirePagedOperation(); try flag.check()
    if pagedSelectedRecord?.document.id == id, pagedViewport != nil { focusEditor(id); return }
    pagedTransition = true // actual Main admission before the first await
    defer { finishPagedTransition() }
    try await flushPagedWorkspace(insideTransition: true)
    let record = try await selectedPagedRecord(id)
    let previousDraftVersion = draftVersion
    try await closePagedSelection()
    try flag.check()
    guard draftVersion == previousDraftVersion, !pagedDraftDirty else { throw BoomError.stale("Later draft input keeps the previous owner/selection.") }
    let (engine, publisher) = try pagedOwners()
    try await refreshPagedHead()
    guard var settings = pagedSettings, let head = pagedHead else { throw BoomError.stale("Selected workspace metadata is absent.") }
    settings.selectedDocument = id; settings.showDocument = true
    let settingsVersion = pagedSettingsVersion
    let result = try await store.savePagedSettingsRetaining(settings, engine: engine, publisher: publisher, expectedHead: head)
    try await receivePagedMetadata(result)
    // This operation changes selection only. Later accepted theme/pane/model
    // settings remain dirty on the SAME Model; never replace them wholesale.
    pagedSettings?.selectedDocument = id; pagedSettings?.showDocument = true
    if pagedSettingsVersion == settingsVersion { pagedSettingsDirty = false }
    try await openPagedSelection(record)
    if !preservingSelection { selectedDocumentIDs = [id] }
    composerFocusEpoch &+= 1; compactPane = "document"
    if let owner = pagedComposerOwner { try await restorePagedDraft(owner) }
    focusEditor(id)
  }
  private func createPagedDocument(flag: CancellationFlag) async throws {
    try requirePagedOperation(); try flag.check()
    // The empty new manuscript is an actual0-byte regular source, never a
    // DocumentSnapshot placeholder. Its file/parent IO is off Main and its
    // original is retained on failure until the actual import/publication joins.
    let url = try await detachedWork {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-new-\(UUID().uuidString).md")
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BoomError.unavailable("Could not create the owned empty source.") }
      return url
    }
    try await importPagedDocument(url, title: "Untitled", flag: flag)
    try await detachedWork { try FileManager.default.removeItem(at: url) }
  }
  private func importPagedDocument(_ url: URL, title: String, flag: CancellationFlag) async throws {
    try requirePagedOperation(); try flag.check()
    pagedTransition = true // retains all source/import/metadata receiver fields through yield
    defer { finishPagedTransition() }
    try await flushPagedWorkspace(insideTransition: true)
    let (engine, publisher) = try pagedOwners()
    let documentID = UUID()
    let file = try await detachedWork { try FileHandle(forReadingFrom: url) }
    let cancellation = PagedTextCancellation()
    var callerFileClosed = false
    do {
      let imported = try await withTaskCancellationHandler {
        try await engine.importUTF8Retaining(documentID: documentID, from: file, cancellation: cancellation)
      } onCancel: { cancellation.cancel() }
      pagedImported = imported
      try await detachedWork { try file.close() }; callerFileClosed = true
      let descriptor = PagedDocumentDescriptor(id: documentID, title: title, revision: imported.value.revision)
      let initialized = try await engine.initialNativeRecordRetaining(descriptor)
      pagedInitialized = initialized
      let change = try await detachedWork { try WorkspaceDocumentMutation.inserting(imported, initialized: initialized, path: url.path) }
      try await refreshPagedHead()
      guard var settings = pagedSettings, let head = pagedHead else { throw BoomError.stale("Import has no actual received settings/head.") }
      // Close the selected graph before changing source selection. The actual
      // old native input remains retained on any refusal; import producers stay.
      let capturedDraftVersion = draftVersion
      try await closePagedSelection()
      try flag.check()
      guard draftVersion == capturedDraftVersion, !pagedDraftDirty else { throw BoomError.stale("Later composer input keeps its actual previous owner; import selection was not published.") }
      settings.selectedDocument = documentID; settings.showDocument = true
      let settingsVersion = pagedSettingsVersion
      let result = try await store.savePagedDocumentChangesRetaining([change], settings: settings,
        engine: engine, publisher: publisher, expectedHead: head)
      try await receivePagedMetadata(result)
      // The real metadata receiver transfers BOTH insert producers. Dropping
      // the consumed carriers is correct; abandonJoined here would be false.
      pagedImported = nil; pagedInitialized = nil
      pagedSettings?.selectedDocument = documentID; pagedSettings?.showDocument = true
      if pagedSettingsVersion == settingsVersion { pagedSettingsDirty = false }
      guard let record = result.value.documents.first(where: { $0.documentID == documentID })?.after else {
        throw BoomError.stale("Actual import metadata output omitted its exact inserted record.")
      }
      try await openPagedSelection(record)
      selectedDocumentIDs = [documentID]; compactPane = "document"
      composerFocusEpoch &+= 1
      if let owner = pagedComposerOwner { try await restorePagedDraft(owner) }
      // Keep one actual page; refresh rather than growing all titles/records.
      try await loadPagedDocumentPage(afterOrdinal: -1)
      focusEditor(documentID)
    } catch {
      let original = error
      // Closing the caller handle is ordinary resource IO, not import/source
      // abandonment. The Engine owns its dup and joins its stream producer.
      if !callerFileClosed {
        do { try await detachedWork { try file.close() }; callerFileClosed = true }
        catch { throw WorkspacePagedImportFailure(original: original, cleanup: error, url: url) }
      }
      throw original
    }
  }
  private func renamePagedDocument(_ id: UUID, to title: String, flag: CancellationFlag) async throws {
    try requirePagedOperation(); try flag.check()
    pagedTransition = true
    defer { finishPagedTransition() }
    try await flushPagedWorkspace(insideTransition: true)
    let expected = try await selectedPagedRecord(id)
    if expected.document.title.utf8.elementsEqual(title.utf8) { return }
    let selected = pagedSelectedRecord?.document.id == id
    if selected { try await closePagedSelection() }
    try flag.check(); try await refreshPagedHead()
    let (engine, publisher) = try pagedOwners()
    guard let head = pagedHead else { throw BoomError.stale("Rename has no actual current head.") }
    let change = try await detachedWork { try WorkspaceDocumentMutation.renaming(expected, title: title) }
    let result = try await store.savePagedDocumentChangesRetaining([change], engine: engine, publisher: publisher, expectedHead: head)
    try await receivePagedMetadata(result)
    if selected {
      guard let record = result.value.documents.first?.after else { throw BoomError.stale("Rename lost its actual returned full record.") }
      try await openPagedSelection(record)
    }
    if let row = documentIndices.firstIndex(where: { $0.id == id }) { documentIndices[row].title = title }
    if let row = pagedDocumentPage.firstIndex(where: { $0.document.id == id }), let record = result.value.documents.first?.after { pagedDocumentPage[row] = record }
  }
  func trashPagedDocuments(_ ids: Set<UUID>, flag: CancellationFlag = CancellationFlag()) async throws {
    try requirePagedOperation(); guard !ids.isEmpty, ids.count <= 7 else { throw BoomError.budget("One document metadata transaction admits one to seven actual records.") }
    pagedTransition = true
    defer { finishPagedTransition() }
    try await flushPagedWorkspace(insideTransition: true)
    var expected: [PagedDocumentRootRecord] = []
    for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) { try flag.check(); expected.append(try await selectedPagedRecord(id)) }
    let capturedDraftVersion = draftVersion
    if pagedSelectedRecord.map({ ids.contains($0.document.id) }) == true { try await closePagedSelection() }
    guard draftVersion == capturedDraftVersion, !pagedDraftDirty else { throw BoomError.stale("Later draft text retains its original document owner; trash did not discard it.") }
    try flag.check(); try await refreshPagedHead()
    let (engine, publisher) = try pagedOwners()
    guard var settings = pagedSettings, let head = pagedHead else { throw BoomError.stale("Trash has no actual received settings/head.") }
    if settings.selectedDocument.map(ids.contains) == true { settings.selectedDocument = nil }
    settings.writingExampleIDs.removeAll { ids.contains($0) }
    let records = expected
    let changes = try await detachedWork { try records.map(WorkspaceDocumentMutation.trashing) }
    let settingsVersion = pagedSettingsVersion
    let result = try await store.savePagedDocumentChangesRetaining(changes, settings: settings,
      engine: engine, publisher: publisher, expectedHead: head)
    try await receivePagedMetadata(result)
    pagedSettings?.selectedDocument = settings.selectedDocument
    if pagedSettingsVersion == settingsVersion {
      writingExampleIDs = settings.writingExampleIDs
      pagedSettingsDirty = false
    } else {
      // A later selection of a just-trashed writing source is a concrete input
      // conflict, not permission to erase that selection. The archived records
      // and actual already-received metadata stay truthful and reachable.
      guard !writingExampleIDs.contains(where: ids.contains) else {
        throw BoomError.stale("Later writing-example input names a now archived source; its original selection remains retained.")
      }
      pagedSettingsDirty = true
    }
    selectedDocumentIDs.subtract(ids)
    if pagedSelectedRecord.map({ ids.contains($0.document.id) }) == true { pagedSelectedRecord = nil }
    // Original source/archive/draft records stay. No implicit draft deletion,
    // source GC or macOS file-trash call is substituted for receiving.
    try await loadPagedDocumentPage(afterOrdinal: -1)
    if settings.selectedDocument == nil { composerOwner = nil } // old text remains in receiver memory; no discard
  }
  func pagePagedDocuments(forward: Bool) {
    guard !isBusy else { return }
    work("Reading library…") { [weak self] _ in
      guard let self else { return }
      try self.requirePagedOperation()
      self.pagedTransition = true
      defer { self.finishPagedTransition() }
      try await self.flushPagedWorkspace(insideTransition: true)
      if forward {
        guard let next = self.pagedNextDocumentOrdinal else { return }
        guard self.pagedPreviousDocumentPages.count < PagedWorkspaceProjection.maximumDocuments else { throw BoomError.budget("Library navigation cursors exceed the actual bounded catalog.") }
        self.pagedPreviousDocumentPages.append(self.pagedDocumentPageStart)
        try await self.loadPagedDocumentPage(afterOrdinal: next)
      } else {
        guard let previous = self.pagedPreviousDocumentPages.last else { return }
        try await self.loadPagedDocumentPage(afterOrdinal: previous)
        self.pagedPreviousDocumentPages.removeLast()
      }
      self.pagedLibraryHasPrevious = !self.pagedPreviousDocumentPages.isEmpty
    }
  }
  private func loadPagedDocumentPage(afterOrdinal: Int) async throws {
    try await refreshPagedHead()
    let (engine, publisher) = try pagedOwners()
    guard let head = pagedHead else { throw BoomError.stale("Library page has no actual current head.") }
    let read = try await engine.loadDocumentIndexPageRetaining(publisher, afterOrdinal: afterOrdinal, expectedHead: head)
    pagedReadLease = read.lease
    let records = read.value.records, next = read.value.nextOrdinal
    try await releasePagedRead(read.lease, engine: engine)
    pagedDocumentPage = records; pagedDocumentPageStart = afterOrdinal
    documentIndices = records.map { DocumentIndex(id: $0.document.id, title: $0.document.title) }
    pagedNextDocumentOrdinal = next
  }
}

private struct WorkspacePagedImportFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  let url: URL
  var errorDescription: String? { "\(original.localizedDescription) Import handle cleanup: \(cleanup.localizedDescription). Original source retained at \(url.path)." }
}
