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
  @Published var state: WorkspaceState
  @Published var documents: [DocumentSnapshot]
  @Published var selectedDocumentIDs: Set<UUID> = []
  @Published var selectedChatIDs: Set<UUID> = []
  @Published var composerFocusEpoch = 0
  @Published var draft = ""
  @Published var mode: InteractionMode = .ask
  @Published var pendingAttachments: [UUID] = []
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
  @Published var authoredChatRole: Role?
  @Published var samplingProfile: SamplingProfile = .standard
  @Published var candidates: CandidateBundle?
  @Published var showingCandidates = false
  @Published var writingIssue: String?
  @Published private(set) var savedExplorations: [SavedExploration] = []
  private var latestSavedCandidate: UUID?
  private var historyRequest: UUID?
  private var historyTask: Task<Void, Never>?
  @Published var editingWritingExamples: WritingExamplesRequest?
  @Published var editingLocked = false
  @Published var backupRequest: BackupRequest?
  @Published var writingExampleIDs: [UUID] = []
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
  private(set) var mlxRunner: MLXGemmaRunner?
  private(set) var baseRunner: MLXGemmaRunner?
  private var modelDirectories: [ModelPurpose: URL] = [:]
  private var residentModelWeights: [ModelPurpose: UInt64] = [:]
  @Published private(set) var settingUpModels = false
  @Published private(set) var modelSetupIssue: String?
  @Published private(set) var writingUsesConsultation = false
  private var writingModelIdentity: String?
  private var writingGenerationPolicy: ModelGenerationPolicy?
  var selectedMLXRunner: MLXGemmaRunner? { mlxRunner }
  var completionRunner: MLXGemmaRunner? { baseRunner }
  func documentAttachments(_ document: DocumentSnapshot) -> [AttachmentRecord] {
    AttachmentLink.ids(in: document.text).compactMap { id in
      state.attachments.first { $0.id == id }
    }
  }
  func documentAttachmentDestination(id: UUID, range: NSRange) -> AttachmentDestination? {
    guard let document = documents.first(where: { $0.id == id }) else { return nil }
    return .document(id: id, revision: document.revision, range: range)
  }
  private func chatAttachmentDestination() throws -> AttachmentDestination {
    guard !isBusy else { throw BoomError.unavailable("Finish the current action before attaching a file.") }
    if let id = state.selectedChat, state.chats.contains(where: { $0.id == id }) {
      return .chat(id: id)
    }
    scheduleSave()
    var next = state
    let chat = ChatRecord(attachedDocumentID: layout.isAuthor ? state.selectedDocument : nil)
    next.chats.append(chat)
    next.selectedChat = chat.id
    next.showChat = true
    scheduleSave()
    state = next
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
  private var writingFlag: CancellationFlag?
  private var ghostFlag: CancellationFlag?
  private var pressureWatch: MemoryPressureWatch?
  private var saveTask: Task<Void, Never>?
  private var exportTasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
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
    let loaded = try await store.load().get()
    self.state = loaded.0
    self.documents = loaded.1
    selectedDocumentIDs = Set(state.selectedDocument.map { [$0] } ?? [])
    selectedChatIDs = Set(state.selectedChat.map { [$0] } ?? [])
    if layout.isAuthor && documents.isEmpty { try newDocument() }
    if state.chats.isEmpty && !layout.isAuthor { try newChat() }
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
    pressureWatch = MemoryPressureWatch { [weak self] critical in
      Task { @MainActor in self?.handleMemoryPressure(critical: critical) }
    }
    if loadModels { prepareModels() }
  }
  private func handleMemoryPressure(critical: Bool) {
    if critical { cancel() }
    let inactive: ModelPurpose = writingFlag != nil ? .consultation : .writing
    Task {
      if critical || !writingUsesConsultation { await releaseRunner(inactive) }
      await reclaimModelCache()
    }
    status = "Memory pressure released the inactive model. It will reload when needed."
  }
  func documentMatchesSearch(_ document: DocumentSnapshot) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || documentSearch[document.id] != nil
  }
  func chatMatchesSearch(_ chat: ChatRecord) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || matchingChatIDs.contains(chat.id)
  }
  func voiceMatchesSearch(_ voice: Voice) -> Bool {
    librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchedQuery != librarySearch || matchingVoiceIDs.contains(voice.id)
  }
  private func refreshSearch() {
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
              documents[document.id] = DocumentSearchMatches(query: query, revision: document.revision, matches: matches)
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
  var selectedDocument: DocumentSnapshot? { documents.first { $0.id == state.selectedDocument } }
  var selectedChat: ChatRecord? { state.chats.first { $0.id == state.selectedChat } }
  var proposedForChat: [StoredProposal] {
    state.proposals.filter { $0.chatID == state.selectedChat }
  }
  var voiceMatches: [Voice] {
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
  func finishComposition() { editor?.finishComposition() }
  func flush() async throws {
    saveTask?.cancel()
    saveTask = nil
    let captured = documents.filter { dirty.contains($0.id) }
    // The editable source is the chat; portable voice records are its immutable snapshots.
    for voice in state.voices {
      if let chat = state.chats.first(where: { $0.id == voice.id }) {
        let revision = try ProductCore.pinnedVoice(chat, slug: voice.slug,
          occupied: state.voices.filter { $0.id != chat.id }.map(\.slug))
        retainVoice(revision)
      }
    }
    state.documents = documents.map { DocumentIndex(id: $0.id, title: $0.title) }
    let snapshot = state
    try await store.save(snapshot, documents: captured)
    if !librarySearch.isEmpty { refreshSearch() }
    for saved in captured where documents.first(where: { $0.id == saved.id })?.revision == saved.revision {
      dirty.remove(saved.id)
    }
  }
  func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 350_000_000)
        try await self?.flush()
      } catch is CancellationError {} catch { self?.report(error) }
    }
  }
  func newDocument() throws {
    finishComposition()
    cancel()
    scheduleSave()
    let document = DocumentSnapshot(title: "Untitled", text: "")
    dirty.insert(document.id)
    documents.append(document)
    state.selectedDocument = document.id
    mode = .ask
    resetContinuationView()
    selectedDocumentIDs = [document.id]
    state.showDocument = true
    compactPane = "document"
    invalidateGhost()
    scheduleSave()
  }
  func newChat(about documentID: UUID? = nil) throws {
    finishComposition()
    cancel()
    scheduleSave()
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
    pendingAttachments = []
    draft = ""
    mode = .ask
    authoredChatRole = nil; showingChatInstructions = nil; editingChatMessage = nil
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
      var next = state
      next.chats.append(nextChat)
      next.selectedChat = nextChat.id
      scheduleSave()
      state = next
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
      guard documents.contains(where: { $0.id == id }) else { return }
      finishComposition()
      scheduleSave()
      cancel()
      state.selectedDocument = id
      resetContinuationView()
      if layout.isAuthor, selectedChat?.attachedDocumentID != id {
        state.selectedChat = state.chats.last(where: { $0.attachedDocumentID == id })?.id
        mode = .ask
        draft = ""; pendingAttachments = []; showingChatInstructions = nil; editingChatMessage = nil
      }
      if !preservingSelection { selectedDocumentIDs = [id] }
      state.showDocument = true
        compactPane = "document"
      caret = 0
      invalidateGhost()
      scheduleSave()
      focusEditor(id)
  }
  func selectChat(_ id: UUID, preservingSelection: Bool = false) {
    guard state.chats.contains(where: { $0.id == id }) else { return }
    cancel()
    state.selectedChat = id
    if !preservingSelection { selectedChatIDs = [id] }
    composerFocusEpoch &+= 1
    state.showChat = true
    compactPane = "chat"
    pendingAttachments = []
    draft = ""
    mode = .ask
    authoredChatRole = nil; showingChatInstructions = nil; editingChatMessage = nil
    scheduleSave()
  }
  func focusEditor(_ id: UUID) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.state.selectedDocument == id, let editor = self.editor,
        editor.documentID == id else { return }
      editor.window?.makeFirstResponder(editor)
    }
  }
  func deleteDocuments(_ ids: Set<UUID>) {
    guard !isBusy, !ids.isEmpty else { return }
    let targets = documents.filter { ids.contains($0.id) }
    guard !targets.isEmpty, confirm(targets.count == 1 ? "Delete \(targets[0].title)?" : "Delete \(targets.count) documents?",
      message: "Encrypted records move to macOS Trash after the library change is saved. Captured chat sources and receipts stay.") else { return }
    finishComposition()
    work("Deleting documents…") { [weak self] _ in
      guard let self else { return }
      try await self.flush()
      self.documents.removeAll { ids.contains($0.id) }
      self.state.importedFiles = self.state.importedFiles?.filter { !ids.contains($0.key) }
      if self.state.selectedDocument.map(ids.contains) == true {
        self.state.selectedDocument = self.documents.first?.id
        self.caret = 0
        self.resetContinuationView()
      }
      self.selectedDocumentIDs.subtract(ids)
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
    guard !targets.isEmpty,
      confirm(
        targets.count == 1 ? "Delete \(targets[0].title)?" : "Delete \(targets.count) chats?",
        message: "Their messages and pinned voices will be removed from the library. Captured voice revisions and edit receipts stay."
          + (removesCurrent && !draft.isEmpty ? " The unsent message will be discarded." : "")
      ) else { return }
      scheduleSave()
      var next = state
      next.chats.removeAll { ids.contains($0.id) }
      next.voices.removeAll { ids.contains($0.id) }
      if let selected = next.selectedChat, ids.contains(selected) {
        next.selectedChat = next.chats.first?.id
      }
      scheduleSave()
      state = next
      selectedChatIDs.subtract(ids)
      if selectedChatIDs.isEmpty, let id = next.selectedChat { selectedChatIDs = [id] }
      if removesCurrent {
        draft = ""
        pendingAttachments = []
        mode = .ask
        composerFocusEpoch &+= 1
      }
  }
  func renameDocument(_ id: UUID, to proposedTitle: String) {
    guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    cancel()
    documents[index].title = title
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
    case is MarkdownTextView: focused = .document
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
        if let id = self.state.selectedDocument { self.focusEditor(id) }
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
  func work(_ label: String, body: @escaping @MainActor (CancellationFlag) async throws -> Void) {
    guard !isBusy else { return }
    invalidateGhost()
    let previousGhost = ghostTask
    let flag = CancellationFlag()
    let id = UUID()
    activeFlag = flag
    activeID = id
    isBusy = true
    status = label
    foreground = Task { [weak self] in
      if let previousGhost { await previousGhost.value }
      guard let self else { return }
      defer {
        if self.activeID == id {
          self.isBusy = false
          self.activeFlag = nil
          self.activeID = nil
          self.streamingText = ""
          self.streamingChat = nil
          self.scheduleCompletion()
        }
      }
      do {
        try flag.check()
        try await body(flag)
        try await self.flush()
      } catch is CancellationError {
        self.status = "Stopped"
        do { try await self.flush() } catch { self.report(error) }
      } catch {
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
    activeFlag?.cancel()
    foreground?.cancel()
    invalidateGhost()
  }
  func shutdown() async throws {
    finishComposition()
    cancel()
    saveTask?.cancel()
    searchEpoch &+= 1; searchTask?.cancel()
    historyRequest = nil; historyTask?.cancel()
    if let historyTask { await historyTask.value }
    if let foreground { await foreground.value }
    if let ghostTask { await ghostTask.value }
    if let mlxRunner { await mlxRunner.join() }
    if let baseRunner { await baseRunner.join() }
    for operation in Array(exportTasks.values) { await operation.task.value }
    try await flush()
  }
  private func revalidate(_ sources: [SourceReference], attachments: [SourceReference]) throws {
    for source in sources {
      guard documents.first(where: { $0.id == source.id })?.revision == source.digest else {
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
    if replay == nil { ensureChatForSend() }
    if replay == nil && authoredChatRole != nil { appendAuthoredChatMessage(); return }
    guard !isBusy, let chat = selectedChat, canInfer,
      replay != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    else { if !canInfer && !isBusy { prepareModels() }; return }
    let request = replay?.request ?? draft, interaction: InteractionMode = replay == nil ? mode : .propose, document = selectedDocument
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
      let attachmentSources = attachments.map(\.reference), sources = graph.sources + attachmentSources
      let attachmentText = attachments.filter { !$0.text.isEmpty }.map {
        "ATTACHMENT \($0.name)\nID \($0.id)\nDIGEST \($0.digest)\nCOVERAGE \($0.coverage)\n\($0.text)"
      }.joined(separator: "\n\n")
      let authority = CapturedDocumentAuthority(mode: interaction, target: interaction == .ask ? nil : document)
      let documentContext = try DocumentTools.context(graph.documents, authority: authority)
      let context = [documentContext, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
      guard context.utf8.count <= 524_288 else { throw BoomError.budget("Combined reference context exceeds 512 KiB.") }
      let instructions = chat.instructions ?? ""
      let targets: [Voice?] = voices.isEmpty ? [nil] : voices.map(Optional.some)
      let outputLimit = interaction == .ask ? 512 : 4096
      work("Checking consultation context…") { [weak self] flag in
        guard let self else { return }
        let runner = try await self.runnerForGeneration(.consultation, flag: flag)
        let provider = runner.identity
        try await self.flush()
        try await self.revalidateResponseSources(graph.sources, attachments: attachmentSources, targetID: authority.target?.id)
        var images: [Data] = []
        for attachment in attachments {
          if let image = try await self.imagePayload(for: attachment) { images.append(image) }
          else if attachment.text.isEmpty { throw BoomError.unavailable("\(attachment.name) has no readable local content. Prepare it locally or remove it.") }
        }
        let reserves = targets.indices.map { index in
          style == .discuss ? outputLimit * (index + 1) + 256 * index : outputLimit
        }
        let fitted = try await runner.fittedRound(voices: targets, history: chat.messages,
          instructions: instructions, context: context, request: request, routing: slugs,
          images: images, reserves: reserves, flag: flag, authority: authority)
        let plans = fitted.plans
        try flag.check()
        try await self.revalidateResponseSources(graph.sources, attachments: attachmentSources, targetID: authority.target?.id)
        guard let index = self.state.chats.firstIndex(where: { $0.id == chat.id }) else { throw BoomError.stale("Chat was removed.") }
        let replyIDs = targets.map { _ in UUID() }
        if replay == nil {
          self.state.chats[index].messages.append(ChatMessage(role: .user, text: request,
            context: context, sources: sources, speaker: Speaker(name: "Human")))
        }
        for (offset, voice) in targets.enumerated() {
          self.state.chats[index].messages.append(ChatMessage(id: replyIDs[offset], role: .assistant,
            text: "", sources: sources, state: .pending, provider: provider,
            speaker: voice?.speaker ?? Speaker(name: "Bloom")))
        }
        if self.state.chats[index].title == "New chat" { self.state.chats[index].title = try ProductCore.chatTitle(request, routing: slugs) }
        if replay == nil && self.draft == request { self.draft = "" }
        if replay == nil && self.pendingAttachments == selectedIDs { self.pendingAttachments = [] }
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
                instructions: instructions, context: context, request: request, routing: slugs, authority: authority)
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
                firstTokenSeconds: nil, elapsedSeconds: 0, generationPolicy: runner.generationPolicy)
              let replyID = replyIDs[offset]
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
                generationPolicy: runner.generationPolicy)
              let result = try await runner.run(plan: plan, images: images, maxTokens: outputLimit,
                seed: seed, flag: flag, onCheckpoint: { progress, stop, token in
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
                    }
                  }
                }
              receipt.promptDigest = result.promptDigest; receipt.tokenIDs = result.tokenIDs
              receipt.stopReason = result.stopReason; receipt.firstTokenSeconds = result.firstTokenSeconds
              receipt.stopTokenID = result.stopTokenID
              receipt.elapsedSeconds = result.elapsedSeconds
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
                  let recapturedContext = try DocumentTools.context(sourceDocuments, authority: responseAuthority)
                  let fullContext = [recapturedContext, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                  let refreshed = try await runner.fittedRound(voices: [voice], history: fitted.history + round,
                    instructions: instructions, context: fullContext, request: request, routing: slugs,
                    images: images, reserves: [outputLimit], flag: flag, authority: responseAuthority)
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
    for source in sources { try await store.checkDisk(source.id) }
    try revalidate(sources, attachments: attachments)
  }
  private func revalidateResponseSources(_ sources: [SourceReference], attachments: [SourceReference],
    targetID: UUID?) async throws {
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
          attachmentIDs: proposal.attachments.map(\.id), previousAttemptID: receipt?.attemptID)
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
    guard !isBusy else { return }
    authoredChatRole = role; composerFocusEpoch &+= 1
  }
  func appendAuthoredChatMessage() {
    guard let role = authoredChatRole, var chat = selectedChat else { return }
    do {
      let text = try ProductCore.chatText(draft)
      chat.messages.append(ChatMessage(role: role, text: text, authoredByUser: true))
      try applyChat(chat); draft = ""; authoredChatRole = nil; composerIssue = nil
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
      speaker: original.speaker, authoredByUser: true, editedFrom: original.id, timestamp: original.timestamp)
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
    exportTasks[target] = (id, task)
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
    // An open tray retains its captured choices for branching after edits.
    // Background suggestions must not replace the visible bundle.
    guard !showingCandidates, librarySearch.isEmpty, state.autocomplete, showsDocument, !isBusy, baseReady, caret > 0,
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
        guard let self, self.epoch == capturedEpoch, !self.isBusy, !self.showingCandidates else { return }
        try await self.generateCandidates(document: document, offset: offset, profile: profile,
          count: 1, maxTokens: 64, flag: flag)
      } catch is CancellationError {} catch {
        if let self, self.epoch == capturedEpoch { self.status = "Autocomplete: " + error.localizedDescription }
      }
    }
  }
  var canExploreWriting: Bool {
    guard baseReady, !isBusy, let document = selectedDocument, caret > 0,
      editor?.selectedRange().length == 0, editor?.hasMarkedText() != true,
      let prefix = try? ProductCore.authoredPrefix(document, caret: caret) else { return false }
    return !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  func setAutocomplete(_ enabled: Bool) {
    state.autocomplete = enabled
    invalidateGhost(); scheduleSave()
    if enabled { scheduleCompletion() }
  }
  func exploreWriting() {
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
    documents.append(document); dirty.insert(document.id)
    writingExampleIDs.append(document.id)
    invalidateGhost(); scheduleSave()
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
    let recipe: CompletionRecipe
    if let previous { recipe = previous.recipe }
    else {
      let examples = try writingExampleIDs.map { id in
        guard let value = documents.first(where: { $0.id == id }) else { throw BoomError.stale("An example was removed.") }
        return value
      }
      let sources = ([document] + examples).map { SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document") }
      try await revalidateOnDisk(sources, attachments: [])
      recipe = try await runner.completionRecipe(document: document, caret: offset,
        sources: sources, examples: examples.map(\.text), profile: profile,
        maxTokens: maxTokens, flag: flag, batchWidth: seeds.count)
    }
    try ProductCore.validateWritingRecipe(recipe)
    guard recipe.model == runner.identity else { throw BoomError.stale("Replay requires the original writing model.") }
    try ProductCore.admitGenerationPolicy(recipe.generationPolicy, loaded: runner.generationPolicy)
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
      let results = try await runner.runBatch(rawPrompt: recipe.prompt, maxTokens: recipe.maxTokens,
          settings: recipe.settings, seeds: seeds, flag: flag, background: maxTokens == 64 && !showingCandidates,
          onCheckpoint: { [weak self] lane, progress, stop, token in
            let generation = generations[lane], index = startIndex + lane
            try await checkpointStore.checkpoint(progress, identity: generation, stopReason: stop, stopTokenID: token)
            guard let owner = self else { return }
            await MainActor.run {
              guard owner.writingFlag === flag, !flag.isCancelled,
                owner.state.selectedDocument == recipe.document.id,
                owner.candidates?.id == bundleID,
                owner.candidates?.candidates.indices.contains(index) == true,
                owner.candidates?.candidates[index].id == generation.attemptID,
                owner.candidates?.candidates[index].state == .pending else { return }
              owner.candidates?.candidates[index].retain(progress)
              if let stop {
                owner.candidates?.candidates[index].state = stop == "cancelled" ? .cancelled : (progress.text.isEmpty ? .failed : .complete)
                owner.candidates?.candidates[index].stopReason = stop
                owner.candidates?.candidates[index].stopTokenID = token
              }
              if index == owner.candidates?.selected, owner.epoch == capturedEpoch {
                owner.showCandidateGhost(progress.text, recipe: recipe, epoch: capturedEpoch)
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
        if let journal = try await store.writingCheckpoint(bundle: bundle, candidate: bundle.candidates[index]) {
          bundle.candidates[index].retain(journal)
        }
        bundle.candidates[index].state = flag.isCancelled ? .cancelled : .failed
        bundle.candidates[index].stopReason = flag.isCancelled ? "cancelled" : "failed"
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
    guard !isBusy, let bundle = candidates, bundle.recipe.document.id == state.selectedDocument,
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
    do { try ProductCore.admitGenerationPolicy(bundle.recipe.generationPolicy, loaded: policy); return true }
    catch { return false }
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
      documents.append(document); dirty.insert(document.id); selectDocument(document.id)
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
    state.selectedDocument = id; selectedDocumentIDs = [id]; state.showDocument = true
    caret = 0; resetContinuationView()
    state.selectedChat = nil; draft = ""; pendingAttachments = []
    showingChatInstructions = nil; editingChatMessage = nil
    compactPane = "document"; invalidateGhost(); focusEditor(id)
  }
  func importFolder() {
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
        self.documents.append(DocumentSnapshot(id: file.id, title: title, text: file.text))
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
    let imported = try await detachedWork { try DocumentImport.read(urls, flag: flag) }
    try flag.check()
    try await store.retainImportedOriginals(imported, flag: flag)
    try flag.check()
    state.importedFiles = state.importedFiles ?? [:]
    for file in imported {
      let document = DocumentSnapshot(id: file.id,
        title: URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent, text: file.text)
      dirty.insert(document.id); documents.append(document)
      state.importedFiles?[file.id] = ImportedFile(folderID: nil, path: file.path, originalDigest: Digest.sha256(file.original))
    }
    if let first = imported.first { selectImportedDocument(first.id) }
    try await flush()
  }
  func exportDocument(_ id: UUID? = nil) {
    finishComposition()
    guard let d = documents.first(where: { $0.id == (id ?? state.selectedDocument) }) else {
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = d.title + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    exportFile(to: url) { Data(d.text.utf8) }
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
    let value = links
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
          record.coverage = "Original image available locally"
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
    composerIssue = nil
  }
  private func imagePayload(for attachment: AttachmentRecord) async throws -> Data? {
    guard attachment.isImage == true || attachment.text.isEmpty else { return nil }
    let vault = store.vault
    let data = try await detachedWork { try vault.get(.attachment, id: attachment.id, limit: 67_108_864) }
    guard Digest.sha256(data) == attachment.rootDigest else {
      throw BoomError.invalid("Stored image bytes changed.")
    }
    if LocalImage.canDecode(data) { return data }
    if attachment.isImage == true {
      throw BoomError.invalid("The stored image cannot be decoded locally.")
    }
    return nil
  }
  private func describeImage(_ image: CGImage, runner: MLXGemmaRunner, flag: CancellationFlag) async throws -> String {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Could not encode image.") }
    let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: "",
      request: "Describe this image carefully. Transcribe legible text and distinguish uncertainty.", routing: [])
    return try await runner.run(plan: plan, images: [bytes], maxTokens: 512, flag: flag, onText: { _ in }).text
  }
  private func preparedRecord(
    _ attachment: AttachmentRecord, data: Data, automaticAudio: Bool, flag: CancellationFlag
  ) async throws -> AttachmentRecord {
    var updated = attachment
    if AttachmentKind(name: attachment.name) == .audio {
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
    case .image(let image):
      let runner = try await runnerForGeneration(.consultation, flag: flag)
      text = try await describeImage(image, runner: runner, flag: flag)
      note = "Local model description of the first image, resized to at most 1600 pixels. Machine-generated, not verified OCR or full image coverage."
    case .video(let frames, let coverage):
      let runner = try await runnerForGeneration(.consultation, flag: flag)
      var descriptions: [String] = []
      for frame in frames {
        try flag.check()
        let result = try await describeImage(frame.image, runner: runner, flag: flag)
        descriptions.append("[Frame at \(String(format: "%.2f", frame.seconds)) seconds]\n" + result)
      }
      text = descriptions.joined(separator: "\n\n")
      note = coverage
    }
    try flag.check()
    guard !text.isEmpty, text.utf8.count <= 262_144 else {
      throw BoomError.invalid("Native transform returned no bounded text.")
    }
    updated.text = text
    updated.transform = note
    updated.coverage = "Partial native transform"
    return updated
  }
  func prepareAttachment(_ id: UUID) {
    guard !isBusy, let attachment = state.attachments.first(where: { $0.id == id }) else { return }
    work("Preparing \(attachment.name) locally…") { [weak self] flag in
      guard let self else { return }
      let vault = self.store.vault
      let data = try await detachedWork { try vault.get(.attachment, id: id, limit: 67_108_864) }
      guard Digest.sha256(data) == attachment.rootDigest else {
        throw BoomError.invalid("Stored attachment digest changed.")
      }
      let updated = try await self.preparedRecord(
        attachment, data: data, automaticAudio: false, flag: flag)
      guard let index = self.state.attachments.firstIndex(where: { $0.id == id }),
        self.state.attachments[index].digest == attachment.digest
      else { throw BoomError.stale(attachment.name) }
      self.state.attachments[index] = updated
      self.status = "Attachment ready"
    }
  }
  private func releaseRunner(_ purpose: ModelPurpose) async {
    if purpose == .consultation {
      if let old = mlxRunner { await old.join() }
      mlxRunner = nil; modelReady = false
    } else {
      if let old = baseRunner { await old.join() }
      baseRunner = nil
    }
    residentModelWeights.removeValue(forKey: purpose)
  }
  private func reclaimModelCache() async {
    await GenerationCoordinator.shared.enter()
    // Releasing native Metal allocations may block. Retain the GPU lease,
    // but let the main actor continue handling manuscript input.
    await InferenceExecutor.shared.perform { _ in MLX.Memory.clearCache() }
    await GenerationCoordinator.shared.leave()
  }
  private func releaseInactiveModel(for purpose: ModelPurpose) async {
    // Return from releaseRunner before clearing the allocator: its local strong
    // reference must be gone so discarded model weights can actually reclaim.
    await releaseRunner(purpose == .consultation ? .writing : .consultation)
    await reclaimModelCache()
  }
  private func pairHasContext() async throws -> Bool {
    guard let writing = baseRunner, let consultation = mlxRunner else { return true }
    if writing === consultation { return true }
    return try ProductCore.retainResidentPair(writing: await writing.contextLength(batchWidth: 3),
      consultation: await consultation.contextLength)
  }
  private func retainPairIfUseful(for purpose: ModelPurpose) async throws {
    guard try await !pairHasContext() else { return }
    await releaseInactiveModel(for: purpose)
    status = "The inactive model was released to preserve context. It will reload when needed."
  }
  func runnerForGeneration(_ purpose: ModelPurpose, flag: CancellationFlag) async throws -> MLXGemmaRunner {
    try flag.check()
    try await retainPairIfUseful(for: purpose)
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
        let disk = try await detachedWork { () throws -> UInt64 in
          var location = HuggingFaceCache.hub
          while !FileManager.default.fileExists(atPath: location.path), location.path != "/" {
            location.deleteLastPathComponent()
          }
          let values = try location.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
          guard let bytes = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init), bytes >= 0 else {
            throw BoomError.unavailable("Bloom could not check free disk space.")
          }
          return UInt64(bytes)
        }
        let plan = try ProductCore.modelSetup(physical: ProcessInfo.processInfo.physicalMemory,
          metal: device.recommendedMaxWorkingSetSize, resident: ModelResidency.footprint(), disk: disk,
          writing: writing, candidates: choices.map(\.candidate))
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
    try await retainPairIfUseful(for: purpose)
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
    work(request.restoring ? "Restoring encrypted backup…" : "Encrypting complete backup…") { [weak self] _ in
      guard let self else { return }
      try await self.flush()
      if request.restoring {
        let restored = try await self.store.restoreBackup(passphrase: passphrase, from: request.url)
        self.state = restored.0; self.documents = restored.1
        self.dirty.removeAll(); self.undoManagers.removeAll()
        self.selectedDocumentIDs = Set(self.state.selectedDocument.map { [$0] } ?? [])
        self.selectedChatIDs = Set(self.state.selectedChat.map { [$0] } ?? [])
        self.draft = ""; self.pendingAttachments = []; self.invalidateGhost()
        self.status = "Backup restored"
      } else {
        try await self.store.exportBackup(passphrase: passphrase, to: request.url)
        self.status = "Complete encrypted backup exported"
      }
    }
  }
  func installSpeechAsset() {
    work("Setting up on-device speech…") { [weak self] flag in
      try await VoiceInput().installSpeechAsset()
      try flag.check()
      self?.status = "On-device speech ready"
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
