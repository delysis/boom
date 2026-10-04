import AppKit
import AVFoundation
import Combine
import CoreMLLLM
import BoomCore
import SwiftUI

struct StoredProposal: Codable, Identifiable {
  let id: UUID
  let chatID: UUID
  let messageID: UUID
  let patch: DocumentPatch
  let document: DocumentSnapshot
  let documents: [SourceReference]
  let attachments: [SourceReference]
  var status: String
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
  enum ModelChoice: String { case automatic = "Auto", apple = "Apple", gemma = "Gemma" }
  @Published var state: WorkspaceState
  @Published var documents: [DocumentSnapshot]
  @Published var selectedDocumentIDs: Set<UUID> = []
  @Published var selectedChatIDs: Set<UUID> = []
  @Published var composerFocusEpoch = 0
  @Published var draft = ""
  @Published var mode: InteractionMode = .ask
  @Published var pendingAttachments: [UUID] = []
  @Published var isBusy = false
  @Published var status = AppleModel.availabilityMessage
  @Published var appleAvailability = AppleModel.availabilityMessage
  @Published var errorMessage: String?
  @Published var streamingText = ""
  @Published var streamingChat: UUID?
  @Published var showingModels = false
  @Published var ghostText = ""
  @Published var ghostStamp: GhostStamp?
  @Published var modelReady = false
  @Published var modelChoice: ModelChoice = .automatic
  let store: WorkspaceStore
  private(set) var runner: GemmaRunner?
  private(set) var mlxRunner: MLXGemmaRunner?
  private(set) var baseRunner: MLXGemmaRunner?
  var selectedMLXRunner: MLXGemmaRunner? { modelChoice == .apple ? nil : mlxRunner }
  var completionRunner: MLXGemmaRunner? { baseRunner }
  var selectedRunner: GemmaRunner? {
    modelChoice == .apple || mlxRunner != nil ? nil : runner
  }
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
    try flush()
    var next = state
    let chat = ChatRecord()
    next.chats.append(chat)
    next.selectedChat = chat.id
    next.showChat = true
    try store.persist(next)
    state = next
    selectedChatIDs = [chat.id]
    compactPane = "chat"
    return .chat(id: chat.id)
  }
  func attachToCurrentChat(_ inputs: [AttachmentInput]) {
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
  var canInfer: Bool {
    selectedMLXRunner != nil || selectedRunner != nil
      || (modelChoice != .gemma && AppleModel.isAvailable)
  }
  var inferenceName: String {
    if let selectedMLXRunner { return "Gemma 4 \(selectedMLXRunner.size.rawValue)" }
    if selectedRunner != nil { return "Gemma 4 E2B" }
    return modelChoice != .gemma && AppleModel.isAvailable ? "Apple Foundation Model" : "No model"
  }
  var cachedQATSize: GemmaSize? {
    MLXModelStore.bestCachedSource(
      physicalBytes: ProcessInfo.processInfo.physicalMemory)?.size
  }
  var recommendedQATSize: GemmaSize? {
    ModelMemoryPolicy.recommendedSize(physicalBytes: ProcessInfo.processInfo.physicalMemory)
  }
  var recommendedBaseSize: GemmaSize? {
    guard let chat = recommendedQATSize else { return nil }
    let bytes = ProcessInfo.processInfo.physicalMemory
    let combined = UInt64(chat.nominalBillions + GemmaSize.b12.nominalBillions) * 500_000_000
    return combined < bytes / 2 ? .b12 : nil
  }
  var baseReady: Bool { baseRunner != nil }
  var baseCached: Bool {
    recommendedBaseSize.flatMap(MLXModelStore.cachedBaseSource(for:)) != nil
  }
  func chooseModel(_ choice: ModelChoice) {
    modelChoice = choice
    invalidateGhost()
    status = selectedRunner == nil && selectedMLXRunner == nil && AppleModel.isAvailable
      ? "Apple Foundation Model · chat only; raw document completion needs Gemma"
      : inferenceName == "No model" ? appleAvailability : inferenceName + " · on device"
    scheduleCompletion()
  }
  private var foreground: Task<Void, Never>?
  private var activeFlag: CancellationFlag?
  private var activeID: UUID?
  private var ghostTask: Task<Void, Never>?
  private var ghostFlag: CancellationFlag?
  private var saveTask: Task<Void, Never>?
  private var dirty = Set<UUID>()
  private var undoManagers: [UUID: UndoManager] = [:]
  private var ghostSources: [SourceReference] = []
  private var epoch: UInt64 = 0
  private(set) var caret = 0
  weak var editor: MarkdownTextView?
  @Published private(set) var paneWidth: CGFloat = 1190
  @Published private var compactPane = "document"
  @Published private var mediumHiddenPane = "library"
  var showsLibrary: Bool {
    if paneWidth < 820 { return compactPane == "library" }
    return state.showLibrary && !(paneWidth < 1000 && allPanesRequested
      && mediumHiddenPane == "library")
  }
  var showsDocument: Bool {
    if paneWidth < 820 { return compactPane == "document" }
    return state.showDocument && !(paneWidth < 1000 && allPanesRequested
      && mediumHiddenPane == "document")
  }
  var showsChat: Bool {
    if paneWidth < 820 { return compactPane == "chat" }
    return state.showChat && !(paneWidth < 1000 && allPanesRequested
      && mediumHiddenPane == "chat")
  }
  private var allPanesRequested: Bool {
    state.showLibrary && state.showDocument && state.showChat
  }

  init() throws {
    store = try WorkspaceStore()
    let loaded = try store.load().get()
    self.state = loaded.0
    self.documents = loaded.1
    selectedDocumentIDs = Set(state.selectedDocument.map { [$0] } ?? [])
    selectedChatIDs = Set(state.selectedChat.map { [$0] } ?? [])
    if documents.isEmpty { try newDocument() }
    if state.chats.isEmpty { try newChat() }
    compactPane = state.showDocument ? "document" : state.showChat ? "chat" : "library"
    #if BOOM_UI_TEST
    if let index = state.chats.firstIndex(where: { $0.id == state.selectedChat }),
      state.chats[index].messages.isEmpty {
      state.chats[index].messages = [
        ChatMessage(role: .user, text: "A sample request"),
        ChatMessage(role: .assistant, text: "A sample reply."),
      ]
      try flush()
    }
    #endif
    if let source = MLXModelStore.bestCachedSource(
      physicalBytes: ProcessInfo.processInfo.physicalMemory),
      FileManager.default.fileExists(atPath: MLXModelStore.convertedURL(for: source).path),
      let assistant = MLXModelStore.cachedAssistant(for: source.size)
    {
      loadConvertedMLX(source, assistant: assistant)
    } else if let name = state.installedModel {
      guard name.range(of: "^gemma4-e2b-[0-9a-f]{20}$", options: .regularExpression) != nil else {
        throw BoomError.invalid("Invalid installed-model identifier.")
      }
      let appOwned = store.modelsURL.appendingPathComponent(name)
      let cached = HuggingFaceCache.boomModels.appendingPathComponent(name)
      loadModel(FileManager.default.fileExists(atPath: appOwned.path) ? appOwned : cached)
    }
    if recommendedBaseSize == .b12,
      let source = MLXModelStore.cachedBaseSource(for: .b12),
      FileManager.default.fileExists(atPath: MLXModelStore.convertedURL(for: source).path)
    {
      Task { [weak self] in
        guard let self else { return }
        if let foreground = self.foreground { await foreground.value }
        self.loadConvertedBase(source)
      }
    }
  }
  var selectedDocument: DocumentSnapshot? { documents.first { $0.id == state.selectedDocument } }
  var selectedChat: ChatRecord? { state.chats.first { $0.id == state.selectedChat } }
  var proposedForChat: [StoredProposal] {
    state.proposals.filter { $0.chatID == state.selectedChat }
  }
  var personaMatches: [Persona] {
    guard let range = draft.range(of: #"(?:^|\s)@([a-z0-9_-]*)$"#, options: .regularExpression)
    else { return [] }
    let query = draft[range].trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
    return state.personas.filter { $0.slug.hasPrefix(query) }.prefix(6).map { $0 }
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
  func refreshAppleAvailability() {
    let latest = AppleModel.availabilityMessage
    guard latest != appleAvailability else { return }
    if selectedRunner == nil, selectedMLXRunner == nil, !isBusy,
      status == appleAvailability { status = latest }
    appleAvailability = latest
    if AppleModel.isAvailable, selectedRunner == nil, selectedMLXRunner == nil {
      scheduleCompletion()
    }
  }
  func dismissError() { errorMessage = nil }
  func finishComposition() { editor?.finishComposition() }
  func flush() throws {
    saveTask?.cancel()
    saveTask = nil
    for id in dirty.sorted(by: { $0.uuidString < $1.uuidString }) {
      if let document = documents.first(where: { $0.id == id }) { try store.saveDocument(document) }
      dirty.remove(id)
    }
    state.documents = documents.map { DocumentIndex(id: $0.id, title: $0.title) }
    try store.persist(state)
  }
  func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 350_000_000)
        try self?.flush()
      } catch is CancellationError {} catch { self?.report(error) }
    }
  }
  func newDocument() throws {
    finishComposition()
    cancel()
    try flush()
    let document = DocumentSnapshot(title: "Untitled", text: "")
    try store.saveDocument(document)
    documents.append(document)
    state.selectedDocument = document.id
    selectedDocumentIDs = [document.id]
    state.showDocument = true
    compactPane = "document"
    invalidateGhost()
    try flush()
  }
  func newChat(about documentID: UUID? = nil) throws {
    finishComposition()
    cancel()
    try flush()
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
    try flush()
  }
  func ensureChatForDraft() {
    guard !isBusy, !draft.isEmpty, selectedChat == nil else { return }
    do {
      try flush()
      var next = state
      let chat = ChatRecord()
      next.chats.append(chat)
      next.selectedChat = chat.id
      try store.persist(next)
      state = next
      selectedChatIDs = [chat.id]
    } catch { report(error) }
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
      try store.persist(next)
      state = next
    } catch { report(error) }
  }
  func branch(_ messageID: UUID, from chatID: UUID, editing: Bool = false) {
    guard !isBusy else { return }
    do {
      try flush()
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
      try store.persist(next)
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
    do {
      guard let chat = state.chats.firstIndex(where: { $0.id == chatID }),
        let message = state.chats[chat].messages.firstIndex(where: { $0.id == messageID }),
        state.chats[chat].messages[message].role == .assistant else { return }
      var next = state
      let current = next.chats[chat].messages[message].feedback
      next.chats[chat].messages[message].feedback = current == feedback ? nil : feedback
      try store.persist(next)
      state = next
    } catch { report(error) }
  }
  func selectDocument(_ id: UUID, preservingSelection: Bool = false) {
    do {
      guard documents.contains(where: { $0.id == id }) else { return }
      finishComposition()
      try flush()
      cancel()
      state.selectedDocument = id
      if !preservingSelection { selectedDocumentIDs = [id] }
      state.showDocument = true
      compactPane = "document"
      caret = 0
      invalidateGhost()
      scheduleSave()
      focusEditor(id)
    } catch { report(error) }
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
    guard !targets.isEmpty,
      confirm(
        targets.count == 1 ? "Delete \(targets[0].title)?" : "Delete \(targets.count) documents?",
        message: "The Markdown files will move to macOS Trash. Captured chat sources and edit receipts stay."
      ) else { return }
    do {
      finishComposition()
      try flush()
      let before = documents
      let remaining = before.filter { !ids.contains($0.id) }
      var next = state
      next.documents = remaining.map { DocumentIndex(id: $0.id, title: $0.title) }
      if let selected = next.selectedDocument, ids.contains(selected) {
        next.selectedDocument = remaining.first?.id
      }
      try store.persist(next)
      documents = remaining
      state = next
      selectedDocumentIDs.subtract(ids)
      if selectedDocumentIDs.isEmpty, let id = next.selectedDocument { selectedDocumentIDs = [id] }
      invalidateGhost()
      var failed = Set<UUID>()
      for target in targets {
        do {
          try store.trashDocument(target.id)
          undoManagers.removeValue(forKey: target.id)
        } catch { failed.insert(target.id) }
      }
      if !failed.isEmpty {
        documents = before.filter { !ids.contains($0.id) || failed.contains($0.id) }
        state.documents = documents.map { DocumentIndex(id: $0.id, title: $0.title) }
        if state.selectedDocument == nil { state.selectedDocument = documents.first?.id }
        try flush()
        throw BoomError.unavailable("Some documents could not move to Trash; they remain in the library.")
      }
      if documents.isEmpty { try newDocument() }
      scheduleSave()
    } catch { report(error) }
  }
  func deleteChats(_ ids: Set<UUID>) {
    guard !isBusy, !ids.isEmpty else { return }
    let targets = state.chats.filter { ids.contains($0.id) }
    let removesCurrent = state.selectedChat.map { ids.contains($0) } ?? false
    guard !targets.isEmpty,
      confirm(
        targets.count == 1 ? "Delete \(targets[0].title)?" : "Delete \(targets.count) chats?",
        message: "Their messages and captured source snapshots will be removed from the encrypted workspace. Saved personas and edit receipts stay."
          + (removesCurrent && !draft.isEmpty ? " The unsent message will be discarded." : "")
      ) else { return }
    do {
      try flush()
      var next = state
      next.chats.removeAll { ids.contains($0.id) }
      if let selected = next.selectedChat, ids.contains(selected) {
        next.selectedChat = next.chats.first?.id
      }
      try store.persist(next)
      state = next
      selectedChatIDs.subtract(ids)
      if selectedChatIDs.isEmpty, let id = next.selectedChat { selectedChatIDs = [id] }
      if removesCurrent {
        draft = ""
        pendingAttachments = []
        mode = .ask
        composerFocusEpoch &+= 1
      }
    } catch { report(error) }
  }
  func renameDocument(_ id: UUID, to proposedTitle: String) {
    guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    cancel()
    documents[index].title = title
    scheduleSave()
  }
  func renameChat(_ id: UUID, to proposedTitle: String) {
    guard let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    state.chats[index].title = title
    scheduleSave()
  }
  func updateDocument(_ text: String, id: UUID, caret: Int) {
    guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
    invalidateGhost()
    documents[index].text = text
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
    ghostFlag?.cancel()
    ghostTask?.cancel()
    ghostText = ""
    ghostStamp = nil
    ghostSources = []
    editor?.clearGhost()
  }
  func toggle(_ pane: String) {
    if paneWidth < 820 {
      compactPane = compactPane == pane ? (pane == "document" ? "chat" : "document") : pane
      if compactPane != "document" { finishComposition(); invalidateGhost() }
      return
    }
    if paneWidth < 1000, allPanesRequested,
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
    if paneWidth != width { paneWidth = width }
  }
  func setTheme(_ theme: String) {
    state.theme = theme
    NSApp.appearance =
      theme == "dark"
      ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
    scheduleSave()
  }
  func insertReference(to id: UUID) {
    guard let document = documents.first(where: { $0.id == id }), let editor else { return }
    let unique =
      documents.filter {
        $0.title.compare(document.title, options: [.caseInsensitive, .diacriticInsensitive])
          == .orderedSame
      }.count == 1
    let link = unique ? "[[\(document.title)]]" : "[[\(document.title)|\(id.uuidString)]]"
    editor.insertText(link, replacementRange: editor.selectedRange())
    editor.window?.makeFirstResponder(editor)
  }
  func insertPersona(_ persona: Persona) {
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
        try self.flush()
      } catch is CancellationError {
        self.status = "Stopped"
        do { try self.flush() } catch { self.report(error) }
      } catch {
        if flag.isCancelled || Task.isCancelled {
          self.status = "Stopped"
        } else {
          self.report(error)
        }
        do { try self.flush() } catch { self.report(error) }
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
    if let foreground { await foreground.value }
    if let ghostTask { await ghostTask.value }
    if let runner { await runner.join() }
    if let mlxRunner { await mlxRunner.join() }
    if let baseRunner { await baseRunner.join() }
    try flush()
  }
  private func revalidate(_ sources: [SourceReference], attachments: [SourceReference]) throws {
    for source in sources {
      guard documents.first(where: { $0.id == source.id })?.revision == source.digest else {
        throw BoomError.stale(source.title)
      }
      try store.checkDisk(source.id)
    }
    for source in attachments {
      guard state.attachments.first(where: { $0.id == source.id })?.digest == source.digest else {
        throw BoomError.stale(source.title)
      }
    }
  }
  func send() {
    ensureChatForDraft()
    guard !isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let chat = selectedChat, canInfer
    else {
      if !canInfer { showingModels = true }
      return
    }
    do {
      finishComposition()
      try flush()
      let request = draft
      let interaction = mode
      let document = selectedDocument
      let graph = try ContextGraph.resolveChat(
        request: request, attachedDocumentID: chat.attachedDocumentID, all: documents)
      let sourceDocuments = graph.sources
      let selectedAttachments = try pendingAttachments.map { id -> AttachmentRecord in
        guard let attachment = state.attachments.first(where: { $0.id == id }),
          !attachment.text.isEmpty
        else {
          throw BoomError.unavailable(
            "A selected attachment has no admitted text. Prepare it locally, or remove it before sending."
          )
        }
        return attachment
      }
      let inheritedIDs = graph.documents.flatMap { AttachmentLink.ids(in: $0.text) }
      let inheritedAttachments = inheritedIDs.compactMap { id in
        state.attachments.first { $0.id == id }
      }
      let attachments = (selectedAttachments + inheritedAttachments).reduce(
        into: [AttachmentRecord]()) { records, attachment in
          if !records.contains(where: { $0.id == attachment.id }) { records.append(attachment) }
        }
      guard attachments.count <= 8 else {
        throw BoomError.budget("At most eight attachments per turn.")
      }
      let attachmentSources = attachments.map(\.reference)
      let sources = sourceDocuments + attachmentSources
      let attachmentText = attachments.map {
        "ATTACHMENT \($0.name)\nID \($0.id)\nDIGEST \($0.digest)\nCOVERAGE \($0.coverage)\n\($0.transform ?? "")\n"
          + ($0.text.isEmpty ? "No readable text was extracted from this attachment." : $0.text)
      }.joined(separator: "\n\n")
      let contextParts = [graph.text, attachmentText].filter { !$0.isEmpty }
      let context = contextParts.isEmpty ? "" : "REFERENCE DATA:\n" + contextParts.joined(separator: "\n\n")
      guard context.utf8.count <= 524_288 else {
        throw BoomError.budget("Combined reference context exceeds 512 KiB.")
      }
      let slugs = try ReferenceParser.personas(request)
      guard slugs.count <= 3 else {
        throw BoomError.budget(
          "Consult at most three personas in one turn; their caches are never merged.")
      }
      guard interaction != .edit || slugs.count <= 1 else {
        throw BoomError.denied(
          "Edit grants one consultation at a time. Use Propose to compare multiple personas before applying any changes."
        )
      }
      let personas = try slugs.map { slug -> Persona in
        guard let p = state.personas.first(where: { $0.slug == slug }) else {
          throw BoomError.invalid("Unknown persona @\(slug).")
        }
        return p
      }
      if selectedRunner == nil && !personas.isEmpty {
        throw BoomError.unavailable(
          "This persona has a Core ML cache. Select its original model until a matching MLX cache is built."
        )
      }
      if interaction != .ask && document == nil {
        throw BoomError.denied("Choose a document before requesting edits.")
      }
      // Historic source snapshots are receipts. Only the current chat attachment,
      // explicit links and selected files become source material for this turn.
      let oldHistory = chat.messages.map { message -> ChatMessage in
        var copy = message
        copy.context = ""
        return copy
      }
      let chatID = chat.id
      draft = ""
      pendingAttachments = []
      mode = .ask
      work("Generating locally…") { [weak self] flag in
        guard let self else { return }
        try self.revalidate(sourceDocuments, attachments: attachmentSources)
        guard let index = self.state.chats.firstIndex(where: { $0.id == chatID }) else {
          throw BoomError.stale("Chat was removed.")
        }
        self.state.chats[index].messages.append(
          ChatMessage(role: .user, text: request, context: context, sources: sources))
        if self.state.chats[index].title == "New chat" {
          self.state.chats[index].title = String(request.prefix(48))
        }
        try self.flush()
        self.streamingChat = chatID
        let instructions = interaction == .ask ? "" : DocumentTools.instructions
        let fitted: FittedConversation?
        if let runner = self.selectedRunner {
          let prefixes = try personas.map { try GemmaPrompt.prefix($0.messages) }
          fitted = try await runner.fitConversation(
            prefixes: prefixes.map(Optional.some), history: oldHistory,
            instructions: instructions, context: context, request: request,
            maxOutputTokens: 512, flag: flag)
          if let fitted, fitted.context != context {
            guard let current = self.state.chats[index].messages.indices.last else {
              throw BoomError.invalid("The current chat message disappeared.")
            }
            self.state.chats[index].messages[current].context = fitted.context
            try self.flush()
          }
        } else if let runner = self.selectedMLXRunner {
          fitted = try await runner.fitConversation(
            history: oldHistory, instructions: instructions, context: context,
            request: request, maxOutputTokens: 512, flag: flag)
          if let fitted, fitted.context != context {
            guard let current = self.state.chats[index].messages.indices.last else {
              throw BoomError.invalid("The current chat message disappeared.")
            }
            self.state.chats[index].messages[current].context = fitted.context
            try self.flush()
          }
        } else { fitted = nil }
        let consultations: [Persona?] = personas.isEmpty ? [nil] : personas.map { Optional($0) }
        for persona in consultations {
          try flag.check()
          var prefix: String?
          var cache: BoomKVSnapshot?
          if let persona {
            guard let runner = self.selectedRunner else { throw BoomError.unavailable("Gemma is required for native persona caches.") }
            self.status = "Consulting @\(persona.slug)…"
            let vault = self.store.vault
            (prefix, cache) = try await detachedWork {
              try runner.restorePersona(persona, vault: vault)
            }
          }
          self.streamingText = ""
          var responseRecorded = false
          do {
            let generated: String
            let resultStatus: String
            if let runner = self.selectedRunner {
              let prompt = GemmaPrompt.conversation(
                prefix: prefix, history: fitted?.history ?? oldHistory,
                request: [instructions, fitted?.context ?? context, request].filter { !$0.isEmpty }
                  .joined(separator: "\n\n"))
              let result = try await runner.run(
                prompt: prompt, restore: cache, maxTokens: 512, flag: flag
              ) { [weak self] text in
                Task { @MainActor in
                  guard let self, self.activeFlag === flag, !flag.isCancelled else { return }
                  self.streamingText = text
                }
              }
              generated = result.text
              resultStatus = "Local Gemma · \(result.promptTokens) prompt tokens · \(result.cachedTokens) restored"
                + ((fitted?.omittedContextCharacters ?? 0) > 0
                  || (fitted?.omittedHistoryCount ?? 0) > 0 ? " · earlier context shortened" : "")
                + (result.endedByEOS ? "" : " · output limit")
            } else if let runner = self.selectedMLXRunner {
              let prompt = MLXGemmaRunner.chatPrompt(
                history: fitted?.history ?? oldHistory,
                request: [instructions, fitted?.context ?? context, request]
                  .filter { !$0.isEmpty }.joined(separator: "\n\n"))
              let result = try await runner.run(
                rawPrompt: prompt, maxTokens: 512, flag: flag
              ) { [weak self] text in
                Task { @MainActor in
                  guard let self, self.activeFlag === flag, !flag.isCancelled else { return }
                  self.streamingText = text
                }
              }
              generated = result.text
              resultStatus = "Local Gemma · \(result.promptTokens) prompt tokens"
                + (result.endedByEOS ? "" : " · output limit")
            } else {
              let prompt = try AppleModel.conversation(
                history: oldHistory, context: context, request: request)
              generated = try await AppleModel.respond(to: prompt, instructions: instructions)
              resultStatus = "Apple Foundation Model · on device · no native KV cache"
            }
            try flag.check()
            try self.revalidate(sourceDocuments, attachments: attachmentSources)
            guard interaction == .ask || self.state.selectedDocument == document?.id else {
              throw BoomError.stale("Active document selection changed.")
            }
            var answer = generated
            var patch: DocumentPatch?
            if interaction != .ask {
              let envelope = try AssistantEnvelope.decode(generated)
              answer = envelope.reply
              patch = envelope.edits.first
            }
            let message = ChatMessage(
              role: .assistant, text: answer, sources: sources, personaID: persona?.id,
              provider: self.inferenceName)
            guard let chatIndex = self.state.chats.firstIndex(where: { $0.id == chatID }) else {
              throw BoomError.stale("Chat was removed.")
            }
            if let patch, let document {
              _ = try DocumentTools.validate(
                patch, grant: DocumentGrant(mode: interaction, snapshot: document),
                current: self.selectedDocument ?? document)
              let proposal = StoredProposal(
                id: UUID(), chatID: chatID, messageID: message.id, patch: patch, document: document,
                documents: sourceDocuments, attachments: attachmentSources, status: "pending")
              self.state.proposals.append(proposal)
              self.state.chats[chatIndex].messages.append(message)
              responseRecorded = true
              self.streamingText = ""
              // Even Edit records the exact proposal and answer before mutation.
              try self.flush()
              if interaction == .edit {
                try self.commit(proposal)
                if let index = self.state.proposals.firstIndex(where: { $0.id == proposal.id }) {
                  self.state.proposals[index].status = "applied"
                }
              }
            } else {
              self.state.chats[chatIndex].messages.append(message)
              responseRecorded = true
              self.streamingText = ""
            }
            self.status = resultStatus
            self.streamingText = ""
            try self.flush()
          } catch {
            if let chatIndex = self.state.chats.firstIndex(where: { $0.id == chatID }) {
              let retained: String
              if responseRecorded {
                retained =
                  "The response and proposal were retained. Completing the local operation failed: "
                  + error.localizedDescription
              } else if !self.streamingText.isEmpty {
                retained = self.streamingText
              } else {
                retained =
                  flag.isCancelled
                  ? "Generation stopped before an answer was produced."
                  : "Local generation failed before an answer was produced: "
                    + error.localizedDescription
              }
              self.state.chats[chatIndex].messages.append(
                ChatMessage(
                  role: .assistant, text: retained, sources: sources,
                  state: flag.isCancelled ? .cancelled : .failed, personaID: persona?.id,
                  provider: self.inferenceName))
            }
            throw error
          }
        }
      }
    } catch { report(error) }
  }
  private func commit(_ proposal: StoredProposal) throws {
    try revalidate(proposal.documents, attachments: proposal.attachments)
    guard state.selectedDocument == proposal.document.id, let current = selectedDocument else {
      throw BoomError.stale("Choose the original document before accepting this proposal.")
    }
    guard editor?.hasMarkedText() != true else {
      throw BoomError.denied("Finish the current input-method composition before applying an edit.")
    }
    let grant = DocumentGrant(mode: .propose, snapshot: proposal.document)
    let updated = try DocumentTools.apply(proposal.patch, grant: grant, current: current)
    let journal = DocumentEditJournal(
      schema: 1, proposalID: proposal.id, documentID: current.id, beforeRevision: current.revision,
      afterRevision: updated.revision, phase: "prepared")
    try store.vault.encode(journal, kind: .editJournal, id: proposal.id)
    try store.saveDocument(updated)
    if let editor, editor.documentID == updated.id {
      editor.replaceDocument(updated.text, action: "Apply proposed edit")
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
    }
    // Updating the UI precedes this second journal write: a disk-full receipt
    // failure must not leave an old buffer poised to overwrite the applied file.
    // The already-durable prepared journal is sufficient for restart recovery.
    do {
      try store.vault.encode(
        DocumentEditJournal(
          schema: 1, proposalID: proposal.id, documentID: current.id,
          beforeRevision: current.revision, afterRevision: updated.revision, phase: "file_written"),
        kind: .editJournal, id: proposal.id)
    } catch {
      throw BoomError.unavailable(
        "The document edit was applied, but its final journal mark could not be saved. The prepared recovery receipt was retained. "
          + error.localizedDescription)
    }
  }
  private func registerDocumentUndo(_ previous: DocumentSnapshot) {
    let manager = undoManager(previous.id)
    manager.registerUndo(withTarget: self) { owner in
      guard let index = owner.documents.firstIndex(where: { $0.id == previous.id }) else { return }
      let current = owner.documents[index]
      do {
        try owner.store.saveDocument(previous)
        owner.registerDocumentUndo(current)
        owner.documents[index] = previous
        owner.invalidateGhost()
        owner.scheduleSave()
      } catch { owner.report(error) }
    }
    manager.setActionName("Document edit")
  }
  func accept(_ id: UUID) {
    guard !isBusy, let index = state.proposals.firstIndex(where: { $0.id == id }),
      state.proposals[index].status == "pending"
    else { return }
    do {
      try commit(state.proposals[index])
      state.proposals[index].status = "applied"
      try flush()
    } catch { report(error) }
  }
  func reject(_ id: UUID) {
    guard let index = state.proposals.firstIndex(where: { $0.id == id }) else { return }
    state.proposals[index].status = "rejected"
    scheduleSave()
  }
  func canUndo(_ proposal: StoredProposal) -> Bool {
    guard !isBusy, proposal.status == "applied", state.selectedDocument == proposal.document.id,
      let current = selectedDocument, undoManager(current.id).canUndo,
      let applied = try? DocumentTools.apply(
        proposal.patch, grant: DocumentGrant(mode: .propose, snapshot: proposal.document),
        current: proposal.document)
    else { return false }
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
  func clearFollowCache() {
    guard let runner else { return }
    work("Clearing the autocomplete reference cache…") { [weak self] flag in
      guard let self else { return }
      try flag.check()
      try await runner.clearFollowCache(vault: self.store.vault)
      self.status = "Autocomplete reference cache cleared; persona caches unchanged"
    }
  }
  func savePersona(from chatID: UUID) {
    guard !isBusy, let runner, let chat = state.chats.first(where: { $0.id == chatID }),
      let slug = askForText(
        title: "Save chat as persona",
        message:
          "Choose a lowercase @name. The completed conversation will be prefilled and its actual KV tensors encrypted on disk.",
        initial: "persona")
    else { return }
    guard Persona.validSlug(slug), !state.personas.contains(where: { $0.slug == slug }) else {
      report(
        BoomError.invalid(
          "Use a unique lowercase name, starting with a letter; digits, - and _ are allowed."))
      return
    }
    work("Preparing @\(slug) cache…") { [weak self] flag in
      guard let self else { return }
      let persona = try await runner.makePersona(
        slug: slug, title: chat.title, messages: chat.messages, vault: self.store.vault, flag: flag)
      try flag.check()
      var candidate = self.state
      candidate.personas.append(persona)
      try self.store.persist(candidate)
      self.state = candidate
      self.status = "@\(slug) · native cache ready"
    }
  }
  func rebuildPersona(_ id: UUID) {
    guard !isBusy, let runner, let persona = state.personas.first(where: { $0.id == id }) else {
      return
    }
    work("Rebuilding @\(persona.slug)…") { [weak self] flag in
      guard let self else { return }
      let rebuilt = try await runner.makePersona(
        slug: persona.slug, title: persona.title, messages: persona.messages,
        vault: self.store.vault, flag: flag)
      guard let index = self.state.personas.firstIndex(where: { $0.id == id }) else {
        throw BoomError.stale("Persona was removed.")
      }
      // Preserve persona ID so chat references survive an explicit cache rebuild.
      try flag.check()
      var candidate = self.state
      candidate.personas[index] = try Persona(
        id: persona.id, slug: rebuilt.slug, title: rebuilt.title, messages: rebuilt.messages,
        prefixDigest: rebuilt.prefixDigest, model: rebuilt.model, cacheID: rebuilt.cacheID,
        createdAt: persona.createdAt)
      try self.store.persist(candidate)
      self.state = candidate
      // The old encrypted cache is retained; this operation never silently
      // deletes evidence or rewrites an incompatible cache in place.
      self.status = "@\(persona.slug) · native cache ready"
    }
  }
  func deletePersona(_ id: UUID) {
    guard !isBusy, let index = state.personas.firstIndex(where: { $0.id == id }),
      confirm(
        "Delete @\(state.personas[index].slug)?",
        message: "The persona and its encrypted KV cache will be removed. The source chat stays.")
    else { return }
    do {
      let persona = state.personas.remove(at: index)
      try flush()
      try store.vault.remove(.personaCache, id: persona.cacheID)
    } catch { report(error) }
  }
  func scheduleCompletion() {
    guard state.autocomplete, state.showDocument, !isBusy,
      (selectedRunner != nil || completionRunner != nil), caret > 0,
      let document = selectedDocument, let editor, editor.selectedRange().length == 0,
      !editor.hasMarkedText()
    else { return }
    let capturedEpoch = epoch
    let offset = caret
    let flag = CancellationFlag()
    ghostFlag = flag
    ghostTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 650_000_000)
        guard let self, !self.isBusy, self.epoch == capturedEpoch else { return }
        let stamp = try GhostStamp(document: document, caretUTF16: offset, epoch: capturedEpoch)
        let graph = try ContextGraph.resolve(root: document, all: self.documents)
        try self.flush()
        try self.revalidate(graph.sources, attachments: [])
        self.status = "Local autocomplete · bounded caret context"
        let onText: @Sendable (String) -> Void = { [weak self] text in
          Task { @MainActor in
            guard let self, !flag.isCancelled, let current = self.selectedDocument,
              stamp.accepts(
                document: current, caretUTF16: self.caret, epoch: self.epoch,
                hasMarkedText: self.editor?.hasMarkedText() ?? true),
              (try? graph.revalidate(against: self.documents)) != nil,
              let visible = GemmaPrompt.visibleCompletion(text)
            else { return }
            self.ghostSources = graph.sources
            self.ghostStamp = stamp
            self.ghostText = visible
            self.editor?.showGhost(self.ghostText, stamp: stamp)
          }
        }
        if let runner = self.completionRunner {
          let result = try await runner.complete(
            document: document, caret: offset, context: graph, flag: flag,
            useDraft: false, onText: onText)
          if self.epoch == capturedEpoch, !flag.isCancelled {
            self.status = "Local autocomplete"
              + (result.window.isExcerpt ? " · " + result.window.scopeDescription : "")
          }
        } else if let runner = self.selectedRunner {
          let result = try await runner.complete(
            document: document, caret: offset, context: graph, vault: self.store.vault,
            flag: flag, onText: onText)
          if self.epoch == capturedEpoch, !flag.isCancelled {
            self.status = "Local autocomplete · \(result.cachedTokens) reference tokens restored"
              + (result.window.isExcerpt ? " · " + result.window.scopeDescription : "")
          }
        }
      } catch is CancellationError {} catch {
        // An unsupported/oversized autocomplete never inserts text or stops
        // ordinary editing. Its reason is visible without a modal dialog.
        if let self, self.epoch == capturedEpoch {
          self.status = "Autocomplete: " + error.localizedDescription
        }
      }
    }
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
      try store.checkDisk(documentID)
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
      (try? store.checkDisk(documentID)) != nil,
      let stamp = try? GhostStamp(document: document, caretUTF16: caret, epoch: epoch)
    else { return }
    ghostSources = sources
    ghostStamp = stamp
    ghostText = text
    editor?.showGhost(text, stamp: stamp)
  }
  func navigateGhost(_ direction: Int) {
    guard !ghostText.isEmpty else { scheduleCompletion(); return }
    // The admitted CoreML decode graph returns only argmax, so retrying the
    // identical prefix cannot produce an independent candidate.
    status = "This model provides one deterministic completion at this position."
  }
  func importDocument() {
    finishComposition()
    cancel()
    do { try flush() } catch {
      report(error)
      return
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText, .utf8PlainText, .text]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    do {
      for url in panel.urls {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let data = try AttachmentProcessor.readGranted(url)
        guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else {
          throw BoomError.invalid("Markdown import requires UTF-8 text up to 2 MiB.")
        }
        let document = DocumentSnapshot(
          title: url.deletingPathExtension().lastPathComponent, text: text)
        try store.saveDocument(document)
        documents.append(document)
        state.selectedDocument = document.id
      }
      state.showDocument = true
      compactPane = "document"
      invalidateGhost()
      try flush()
    } catch { report(error) }
  }
  func exportDocument(_ id: UUID? = nil) {
    finishComposition()
    guard let d = documents.first(where: { $0.id == (id ?? state.selectedDocument) }) else {
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = d.title + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try Data(d.text.utf8).write(to: url, options: .atomic) } catch { report(error) }
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
    let replacement = insertion ?? current.text.endIndex..<current.text.endIndex
    let prefix = insertion == nil && !current.text.isEmpty ? "\n" : ""
    let value = prefix + links
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
        try self.store.vault.put(imported.original, kind: .attachment, id: imported.record.id)
        try self.store.vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
        var record = imported.record
        if record.text.isEmpty {
          do {
            record = try await self.preparedRecord(
              record, data: imported.original, sourceURL: sourceURL, flag: flag)
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
      self.status = importedRecords.allSatisfy { !$0.text.isEmpty }
        ? "Attachments ready" : "Some attachments need a readable local conversion"
    }
  }
  func removePending(_ id: UUID) {
    guard !isBusy else { return }
    pendingAttachments.removeAll { $0 == id }
  }
  private func preparedRecord(
    _ attachment: AttachmentRecord, data: Data, sourceURL: URL?, flag: CancellationFlag
  ) async throws -> AttachmentRecord {
    var updated = attachment
    let audioExtensions = ["mp3", "wav", "aiff", "aif", "flac"]
    if audioExtensions.contains((attachment.name as NSString).pathExtension.lowercased()) {
      if let sourceURL {
        let audio = try AVAudioFile(forReading: sourceURL)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        if seconds > 120 {
          throw BoomError.unavailable(
            "Long recording (\(Int(seconds / 60)) min). Open this attachment to transcribe the full recording on device.")
        }
      }
      let result: (text: String, coverage: String)
      if let sourceURL {
        result = try await VoiceInput().transcribeAttachment(sourceURL, flag: flag) {
          [weak self] current, total in
          self?.status = "Transcribing \(attachment.name) · \(current) of \(total)"
        }
      } else {
        result = try await VoiceInput().transcribeAttachment(
          data: data, extension: (attachment.name as NSString).pathExtension.lowercased(), flag: flag
        ) { [weak self] current, total in
          self?.status = "Transcribing \(attachment.name) · \(current) of \(total)"
        }
      }
      updated.text = result.text
      updated.transform = result.coverage
      updated.coverage = result.coverage.hasPrefix("Partial")
        ? "Partial local transcript" : "Local speech transcript"
      return updated
    }
    let audioSeconds = runner?.audioSeconds ?? 0
    let media = try await detachedWork(priority: .utility) {
      try await NativeMedia.prepare(
        data: data, name: attachment.name, audioSeconds: audioSeconds, flag: flag)
    }
    var text = ""
    var note = ""
    switch media {
    case .text(let extracted, let coverage):
      text = extracted
      note = coverage
    case .image(let image):
      guard let runner, runner.supportsImages else {
        throw BoomError.unavailable("No local image description model is ready.")
      }
      text = try await runner.describe(image: image, flag: flag, onText: { _ in }).text
      note = "Local model description of the first image, resized to at most 1600 pixels. Machine-generated, not verified OCR or full image coverage."
    case .audio(let samples, let coverage):
      guard let runner, runner.supportsAudio else {
        throw BoomError.unavailable("On-device speech could not read this file and no local audio model is ready.")
      }
      text = try await runner.describe(audio: samples, flag: flag, onText: { _ in }).text
      note = coverage
    case .video(let frames, let coverage):
      guard let runner, runner.supportsImages else {
        throw BoomError.unavailable("No local video-frame description model is ready.")
      }
      var descriptions: [String] = []
      for frame in frames {
        try flag.check()
        let result = try await runner.describe(image: frame.image, flag: flag, onText: { _ in })
        descriptions.append("[Frame at \(String(format: "%.2f", frame.seconds)) seconds]\n" + result.text)
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
      let data = try self.store.vault.get(.attachment, id: id, limit: 67_108_864)
      guard Digest.sha256(data) == attachment.rootDigest else {
        throw BoomError.invalid("Stored attachment digest changed.")
      }
      let updated = try await self.preparedRecord(
        attachment, data: data, sourceURL: nil, flag: flag)
      guard let index = self.state.attachments.firstIndex(where: { $0.id == id }),
        self.state.attachments[index].digest == attachment.digest
      else { throw BoomError.stale(attachment.name) }
      self.state.attachments[index] = updated
      self.status = "Attachment ready"
    }
  }
  private func releaseRunner() async {
    if let old = runner { await old.join() }
    if let old = mlxRunner { await old.join() }
    runner = nil
    mlxRunner = nil
    modelReady = false
  }
  func loadConvertedMLX(_ source: MLXModelStore.Source, assistant: URL) {
    work("Verifying local Gemma files…") { [weak self] flag in
      guard let self else { return }
      let directory = MLXModelStore.convertedURL(for: source)
      try await detachedWork(priority: .utility) {
        try MLXModelStore.verify(directory, expected: source)
      }
      try flag.check()
      let loaded = try await MLXGemmaRunner.load(
        directory: directory, assistantDirectory: assistant, size: source.size)
      try flag.check()
      await self.releaseRunner()
      self.mlxRunner = loaded
      self.modelReady = true
      self.showingModels = false
      self.status = "Gemma 4 \(source.size.rawValue) ready · local Metal"
      self.scheduleCompletion()
    }
  }
  func loadConvertedBase(_ source: MLXModelStore.Source) {
    work("Opening local writing model…") { [weak self] flag in
      guard let self else { return }
      let directory = MLXModelStore.convertedURL(for: source)
      try await detachedWork(priority: .utility) {
        try MLXModelStore.verify(directory, expected: source)
      }
      try flag.check()
      let loaded = try await MLXGemmaRunner.load(directory: directory, size: source.size)
      try flag.check()
      if let old = self.baseRunner { await old.join() }
      self.baseRunner = loaded
      self.status = "Writing suggestions ready"
    }
  }
  func prepareBase() {
    guard !isBusy, let size = recommendedBaseSize else { return }
    work("Preparing writing suggestions…") { [weak self] flag in
      guard let self else { return }
      let source = try await MLXModelStore.ensureBaseSource(for: size)
      try flag.check()
      let directory = try await detachedWork(priority: .userInitiated) {
        try await MLXModelStore.prepare(source)
      }
      try flag.check()
      let loaded = try await MLXGemmaRunner.load(directory: directory, size: size)
      try flag.check()
      if let old = self.baseRunner { await old.join() }
      self.baseRunner = loaded
      self.status = "Writing suggestions ready"
    }
  }
  func prepareCachedMLX() {
    guard !isBusy else { return }
    guard let source = MLXModelStore.bestCachedSource(
      physicalBytes: ProcessInfo.processInfo.physicalMemory)
    else {
      report(BoomError.unavailable("No first-party Gemma 4 QAT safetensors are cached."))
      return
    }
    prepareMLX(size: source.size, downloadIfMissing: false)
  }
  func downloadRecommendedMLX() {
    guard let size = recommendedQATSize else {
      report(BoomError.unavailable("This Mac has too little memory for Gemma 4."))
      return
    }
    prepareMLX(size: size, downloadIfMissing: true)
  }
  private func prepareMLX(size: GemmaSize, downloadIfMissing: Bool) {
    guard !isBusy else { return }
    work("Preparing Gemma 4 \(size.rawValue)…") { [weak self] flag in
      guard let self else { return }
      let source: MLXModelStore.Source
      if let cached = MLXModelStore.cachedSource(for: size) { source = cached }
      else if downloadIfMissing {
        self.status = "Downloading Gemma 4 \(size.rawValue) into the Hugging Face cache…"
        source = try await MLXModelStore.ensureSource(for: size) { [weak self] progress in
          Task { @MainActor in
            guard let self, !flag.isCancelled else { return }
            self.status = "Gemma 4 \(size.rawValue) · \(Int(progress.fractionCompleted * 100))%"
          }
        }
      } else {
        throw BoomError.unavailable("No cached QAT source weights for \(size.rawValue).")
      }
      try flag.check()
      self.status = "Converting first-party QAT weights locally…"
      let directory = try await detachedWork(priority: .userInitiated) {
        try await MLXModelStore.prepare(source)
      }
      try flag.check()
      self.status = "Loading matching Gemma assistant…"
      let assistant = try await MLXModelStore.ensureAssistant(for: source.size)
      try flag.check()
      let loaded = try await MLXGemmaRunner.load(
        directory: directory, assistantDirectory: assistant, size: source.size)
      try flag.check()
      await self.releaseRunner()
      self.mlxRunner = loaded
      self.modelReady = true
      self.showingModels = false
      self.status = "Gemma 4 \(source.size.rawValue) ready · local Metal"
      self.scheduleCompletion()
    }
  }
  func loadModel(_ url: URL) {
    work("Verifying local model files…") { [weak self] flag in
      guard let self else { return }
      await self.releaseRunner()
      let manifest = try await detachedWork(priority: .utility) {
        try ModelManifest.loadAndVerify(url)
      }
      try flag.check()
      self.status = "Loading local Gemma 4 E2B…"
      let loaded = try await detachedWork(priority: .userInitiated) {
        try await GemmaRunner.load(directory: url, manifestDigest: manifest.identity)
      }
      try flag.check()
      self.runner = loaded
      self.modelReady = true
      self.state.installedModel = url.lastPathComponent
      self.status = "Gemma 4 E2B ready"
      self.showingModels = false
    }
  }
  func downloadModel() {
    guard !isBusy else { return }
    let root = HuggingFaceCache.boomModels
    work("Downloading Gemma 4 E2B…") { [weak self] flag in
      guard let self else { return }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let installer = ModelInstaller()
      let url = try await installer.download(to: root) { [weak self] status in
        Task { @MainActor in
          guard let self, !flag.isCancelled else { return }
          self.status = status
        }
      }
      try flag.check()
      let manifest = try await detachedWork(priority: .utility) {
        try ModelManifest.loadAndVerify(url)
      }
      self.status = "Loading the verified local model…"
      await self.releaseRunner()
      let loaded = try await detachedWork(priority: .userInitiated) {
        try await GemmaRunner.load(directory: url, manifestDigest: manifest.identity)
      }
      try flag.check()
      self.runner = loaded
      self.modelReady = true
      self.state.installedModel = url.lastPathComponent
      self.showingModels = false
      self.status = "Gemma 4 E2B ready · local CoreML"
    }
  }
  func importModel() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.message =
      "Choose an unpacked Gemma 4 E2B chunk bundle containing model_config.json, hf_model and chunk1–4. A verified app-owned copy will be made."
    guard panel.runModal() == .OK, let source = panel.url else { return }
    let root = store.modelsURL
    work("Importing a local Gemma bundle…") { [weak self] flag in
      guard let self else { return }
      let scope = source.startAccessingSecurityScopedResource()
      defer { if scope { source.stopAccessingSecurityScopedResource() } }
      let url = try await detachedWork(priority: .utility) {
        try ModelInstaller.importDirectory(source, to: root) { [weak self] text in
          Task { @MainActor in self?.status = text }
        }
      }
      try flag.check()
      let manifest = try await detachedWork(priority: .utility) {
        try ModelManifest.loadAndVerify(url)
      }
      await self.releaseRunner()
      self.status = "Loading the imported local model…"
      let loaded = try await detachedWork(priority: .userInitiated) {
        try await GemmaRunner.load(directory: url, manifestDigest: manifest.identity)
      }
      try flag.check()
      self.runner = loaded
      self.modelReady = true
      self.state.installedModel = url.lastPathComponent
      self.showingModels = false
      self.status = "Gemma 4 E2B ready · local CoreML"
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
