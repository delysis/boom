import AppKit
import BoomCore
import Combine
import SwiftUI

enum BoomChrome {
  private static func color(dark: (Double, Double, Double), light: (Double, Double, Double)) -> NSColor {
    NSColor(name: nil) { appearance in
      let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
  }
  static let sidebarBackground = color(dark: (0.16, 0.16, 0.16), light: (0.96, 0.945, 0.92))
  static let documentBackground = color(dark: (0.15, 0.15, 0.15), light: (1, 1, 1))
  static let inputBackground = color(dark: (0.125, 0.125, 0.125), light: (1, 1, 1))
}

/// Shared pane edges and control geometry. Keep native text insets separate:
/// they belong to TextKit, rather than an overlay or a toolbar offset.
enum WorkspaceGeometry {
  static let paneInset: CGFloat = 12
  static let inputInset: CGFloat = 12
  static let controlSize: CGFloat = 24
  static let headerHeight: CGFloat = 24
  static let proseMaximumWidth: CGFloat = 760
}

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  private var panes: [PaneLayout.Pane] {
    var result: [PaneLayout.Pane] = []
    if model.showsLibrary {
      result.append(.init(id: "library", content: AnyView(LibraryView(model: model)),
        minimum: 170, preferred: 210, maximum: 300))
    }
    if model.showsDocument {
      result.append(.init(id: "document", content: AnyView(ManuscriptPane(model: model)),
        minimum: 280, preferred: 580, maximum: .infinity))
    }
    if model.showsChat {
      result.append(.init(id: "chat", content: AnyView(ChatPane(model: model)),
        minimum: 300, preferred: model.layout.isAuthor ? 370 : 800,
        maximum: model.layout.isAuthor ? 620 : .infinity))
    }
    return result
  }
  var body: some View {
    GeometryReader { geometry in
      PaneLayout(panes: panes)
        .onChange(of: geometry.size.width, initial: true) { _, width in model.fitPanes(to: width) }
    }
    .background(Color(nsColor: BoomChrome.sidebarBackground))
    .environment(\.openURL, OpenURLAction { _ in .discarded })
    .sheet(isPresented: $model.showingModels) { ModelPickerView(model: model) }
    .sheet(item: $model.backupRequest) { BackupPassphraseView(model: model, request: $0) }
    .sheet(item: $model.editingWritingExamples) { WritingExamplesView(model: model, request: $0) }
    .alert("Bloom", isPresented: Binding(
      get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    ) { Button("OK", role: .cancel) { model.dismissError() } }
    message: { Text(model.errorMessage ?? "") }
  }
}

struct ManuscriptPane: View {
  @ObservedObject var model: WorkspaceModel
  var body: some View {
    GeometryReader { pane in
      VStack(spacing: 0) {
        if let document = model.selectedDocument {
          GeometryReader { viewport in
            ScrollView(.vertical) {
              let width = min(WorkspaceGeometry.proseMaximumWidth, max(1, viewport.size.width))
              MarkdownEditor(model: model, document: document,
                minimumHeight: max(1, viewport.size.height))
              .frame(width: width)
              .frame(maxWidth: .infinity)
            }
          }
        } else {
          Color.clear.accessibilityLabel("No document selected")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let issue = model.writingIssue {
          Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(14)
        }
        if model.showingCandidates, model.candidates != nil {
          WritingAlternatives(model: model).frame(height: min(300, max(220, pane.size.height * 0.4)))
            .background(Color(nsColor: BoomChrome.sidebarBackground))
        }
      }
    }.background(Color(nsColor: BoomChrome.documentBackground))
  }
}

struct LibraryView: View {
  private enum RenameTarget: Equatable {
    case document(UUID), chat(UUID)
  }
  @ObservedObject var model: WorkspaceModel
  @State private var documentAnchor: UUID?
  @State private var chatAnchor: UUID?
  @State private var renameTarget: RenameTarget?
  @State private var renameDraft = ""
  @FocusState private var renameFocused: Bool
  private func includes(_ title: String) -> Bool {
    model.librarySearch.isEmpty || title.localizedCaseInsensitiveContains(model.librarySearch)
  }
  private func heading(_ title: String, add: (() -> Void)? = nil) -> some View {
    HStack {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(.tertiary)
      Spacer()
      if let add {
        Button(action: add) {
          Image(systemName: "plus")
            .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
            .contentShape(Rectangle())
        }
          .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary).accessibilityLabel("New \(title.dropLast())")
      }
    }.frame(height: WorkspaceGeometry.headerHeight)
      .padding(.horizontal, WorkspaceGeometry.paneInset)
      .padding(.top, WorkspaceGeometry.paneInset).padding(.bottom, 8)
  }
  private func row(_ title: String, symbol: String, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13, weight: .regular))
        .foregroundStyle(selected ? .primary : .secondary).frame(width: 17)
      Text(title).font(.system(size: 13)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? Color.primary.opacity(0.075) : .clear,
      in: RoundedRectangle(cornerRadius: 7))
    .contentShape(Rectangle())
  }
  private func editableRow(symbol: String, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13))
        .foregroundStyle(selected ? .primary : .secondary).frame(width: 17)
      TextField("Name", text: $renameDraft)
        .textFieldStyle(.plain)
        .focused($renameFocused)
        .onSubmit(commitRename)
        .onExitCommand(perform: cancelRename)
        .onChange(of: renameFocused) { _, focused in
          if !focused && renameTarget != nil { commitRename() }
        }
      Spacer(minLength: 0)
    }
    .font(.system(size: 13))
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
    .padding(.horizontal, 4)
  }
  private func beginRename(_ target: RenameTarget, title: String) {
    if renameTarget != nil { commitRename() }
    renameTarget = target
    renameDraft = title
    renameFocused = true
  }
  private func commitRename() {
    guard let target = renameTarget else { return }
    let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty {
      switch target {
      case .document(let id): model.renameDocument(id, to: title)
      case .chat(let id): model.renameChat(id, to: title)
      }
    }
    renameTarget = nil
    renameFocused = false
  }
  private func cancelRename() {
    renameTarget = nil
    renameFocused = false
  }
  private func chooseDocument(_ id: UUID) {
    if renameTarget != nil { commitRename() }
    let visible = model.documents.filter { model.documentMatchesSearch($0) }.map(\.id)
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    var selection = LibrarySelection(ids: model.selectedDocumentIDs, anchor: documentAnchor)
    let result = selection.click(
      id, visible: visible, primary: model.state.selectedDocument, gesture: clickGesture(modifiers))
    documentAnchor = selection.anchor
    model.selectedDocumentIDs = selection.ids
    switch result {
    case .none: break
    case .open: model.selectDocument(id, preservingSelection: true)
    case .rename:
      if let document = model.documents.first(where: { $0.id == id }) {
        beginRename(.document(id), title: document.title)
      }
    }
  }
  private func chooseChat(_ id: UUID) {
    if renameTarget != nil { commitRename() }
    let visible = model.state.chats.filter { model.chatMatchesSearch($0) }.map(\.id)
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    var selection = LibrarySelection(ids: model.selectedChatIDs, anchor: chatAnchor)
    let result = selection.click(
      id, visible: visible, primary: model.state.selectedChat, gesture: clickGesture(modifiers))
    chatAnchor = selection.anchor
    model.selectedChatIDs = selection.ids
    switch result {
    case .none: break
    case .open: model.selectChat(id, preservingSelection: true)
    case .rename:
      if let chat = model.state.chats.first(where: { $0.id == id }) {
        beginRename(.chat(id), title: chat.title)
      }
    }
  }
  private func clickGesture(_ modifiers: NSEvent.ModifierFlags) -> LibrarySelection.Click {
    if modifiers.contains(.shift) {
      return modifiers.contains(.command) ? .additiveRange : .range
    }
    return modifiers.contains(.command) ? .toggle : .plain
  }
  private func documentDeletion(_ id: UUID) -> Set<UUID> {
    model.selectedDocumentIDs.contains(id) ? model.selectedDocumentIDs : [id]
  }
  private func chatDeletion(_ id: UUID) -> Set<UUID> {
    model.selectedChatIDs.contains(id) ? model.selectedChatIDs : [id]
  }
  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          if model.layout.isAuthor {
          heading("Documents") {
            do { try model.newDocument() } catch { model.report(error) }
          }
          ForEach(model.documents.filter { model.state.importedFiles?[$0.id]?.folderID == nil && model.documentMatchesSearch($0) }) { document in
            Group {
              if renameTarget == .document(document.id) {
                editableRow(symbol: "doc.text", selected: true)
              } else {
                Button { chooseDocument(document.id) } label: {
                  row(document.title, symbol: "doc.text",
                    selected: model.showsDocument && model.selectedDocumentIDs.contains(document.id))
                }.buttonStyle(.plain).padding(.horizontal, 4)
              }
            }
              .contextMenu {
                Button("Rename") { beginRename(.document(document.id), title: document.title) }
                Button("New chat about this document") {
                  do { try model.newChat(about: document.id) } catch { model.report(error) }
                }
                Button("Follow in current document") { model.insertReference(to: document.id) }
                  .disabled(document.id == model.state.selectedDocument)
                Button("Copy stable reference") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(
                    "[[\(document.title)|\(document.id.uuidString)]]", forType: .string)
                }
                Divider()
                Button("Export Markdown…") { model.exportDocument(document.id) }
                Divider()
                Button(
                  documentDeletion(document.id).count == 1 ? "Delete Document…"
                    : "Delete \(documentDeletion(document.id).count) Documents…",
                  role: .destructive
                ) { model.deleteDocuments(documentDeletion(document.id)) }.disabled(model.isBusy)
              }
          }
          ForEach(model.state.importedFolders ?? []) { folder in
            ImportedFolderRows(model: model, folder: folder)
          }
          Button { model.importFolder() } label: {
            row("Import folder…", symbol: "folder.badge.plus", selected: false)
          }.buttonStyle(.plain).padding(.horizontal, 4).disabled(model.isBusy)
          } else {
          heading("Chats") {
            do { try model.newChat() } catch { model.report(error) }
          }
          ForEach(model.state.chats.filter { model.chatMatchesSearch($0) && model.chatVoice($0.id) == nil }) { chat in
            Group {
              if renameTarget == .chat(chat.id) {
                editableRow(symbol: "bubble.left", selected: true)
              } else {
                Button { chooseChat(chat.id) } label: {
                  row(chat.title, symbol: "bubble.left",
                    selected: model.showsChat && model.selectedChatIDs.contains(chat.id))
                }.buttonStyle(.plain).padding(.horizontal, 4)
              }
            }
              .contextMenu {
                Button("Rename") { beginRename(.chat(chat.id), title: chat.title) }
                Button("Export conversation…") { model.exportChat(chat.id) }
                Button("Instructions…") { model.openChatInstructions(chat.id) }.disabled(model.isBusy)
                Button("Pin as voice") { model.pinChat(chat.id) }.disabled(model.isBusy)
                Divider()
                Button(
                  chatDeletion(chat.id).count == 1 ? "Delete Chat…"
                    : "Delete \(chatDeletion(chat.id).count) Chats…",
                  role: .destructive
                ) { model.deleteChats(chatDeletion(chat.id)) }.disabled(model.isBusy)
              }
          }
          }
          if !model.state.voices.isEmpty { heading("Voices") }
          ForEach(model.state.voices.filter { model.voiceMatchesSearch($0) }) { voice in
            Group {
              if renameTarget == .chat(voice.id) { editableRow(symbol: "pin", selected: true) }
              else {
                Button { model.editVoice(voice) } label: {
                  row(voice.name + " · @" + voice.slug, symbol: "pin",
                    selected: model.showsChat && model.state.selectedChat == voice.id)
                }.buttonStyle(.plain).padding(.horizontal, 4)
              }
            }.contextMenu {
              Button("Consult @" + voice.slug) { model.consultVoice(voice) }
              Button("Rename") { model.editVoice(voice); beginRename(.chat(voice.id), title: voice.name) }
              Button("Instructions…") { model.editVoice(voice); model.openChatInstructions(voice.id) }
              Button("Duplicate") { model.duplicateVoice(voice) }
              Button("Export voice…") { model.exportVoice(voice) }
              Button("Unpin") { model.unpinChat(voice.id) }
            }.disabled(model.isBusy)
          }
          if let issue = model.searchIssue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(12) }
          Spacer(minLength: 12)
        }
      }
    }
    .background(Color(nsColor: BoomChrome.sidebarBackground))
  }
}

struct ChatPane: View {
  @ObservedObject var model: WorkspaceModel
  @StateObject private var voice = VoiceInput()
  @State private var composerFocusRequest = 0
  @State private var composerHeight: CGFloat = 36
  @State private var voiceChatID: UUID?
  @State private var voiceDocumentID: UUID?
  @State private var voiceDraft = ""
  @State private var recoveredVoiceText = ""
  @State private var recoveredRecording: Data?
  @State private var acceptingCapture = false
  @State private var restoreComposerAfterAlert = false
  private func authorityMenu(compact: Bool) -> some View {
    Menu {
      Button("Ask · read only") { model.mode = .ask }
      Button("Propose · review edits") { model.mode = .propose }
      Button("Edit · apply edits") { model.mode = .edit }
      Divider()
      Picker("Multiple voices", selection: $model.consultationStyle) {
        ForEach(ConsultationStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: model.mode == .ask ? "bubble.left" :
          model.mode == .propose ? "text.badge.plus" : "pencil.line")
        Text(model.mode.rawValue)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
      }.font(.system(size: 11, weight: .medium))
        .foregroundStyle(model.mode == .ask ? .secondary : .primary)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isBusy)
      .accessibilityLabel("Document authority: " + model.mode.rawValue)
      .help("Ask reads; Propose offers edits for review; Edit applies validated edits to the attached document")
  }
  private var attachmentMenu: some View {
    Menu {
      if let chat = model.selectedChat {
        Menu("Chat document") {
          if chat.attachedDocumentID != nil {
            Button("Detach document") { model.attachDocument(nil, to: chat.id) }
            Divider()
          }
          ForEach(model.documents) { document in
            Button(document.title) { model.attachDocument(document.id, to: chat.id) }
          }
        }
        Divider()
      }
      Button("Choose files…") { model.chooseChatAttachmentFiles() }
      Button("Paste image") { model.pasteImageIntoCurrentChat() }
    } label: {
      Image(systemName: "paperclip")
        .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
    }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
      .accessibilityLabel("Attach files or paste an image")
  }
  private func modelMenu(compact: Bool) -> some View {
    Button { model.openModels() } label: {
      HStack(spacing: 4) {
        Image(systemName: "cpu")
        if !compact {
          Text(model.canInfer ? "Gemma" : "No model")
        }
      }.font(.system(size: 11, weight: .medium)).lineLimit(1)
    }.buttonStyle(.plain).fixedSize().disabled(model.isBusy)
      .accessibilityLabel("Current model: \(model.inferenceName)")
      .help("Current local model: \(model.inferenceName). Select a model")
  }
  private var recordingButton: some View {
    Button { toggleVoice(.recording) } label: {
      Image(systemName: voice.purpose == .recording ? "stop.circle.fill" : "waveform")
        .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
    }.buttonStyle(.plain).disabled((model.isBusy && !model.settingUpModels && !voice.isRecording) ||
      voice.starting || voice.transcribing || acceptingCapture ||
      (voice.isRecording && voice.purpose != .recording))
      .accessibilityLabel(voice.purpose == .recording ? "Stop audio recording" : "Record audio")
  }
  private var transcriptionButton: some View {
    Button { toggleVoice(.transcription) } label: {
      Image(systemName: voice.purpose == .transcription ? "stop.circle.fill" : "mic")
        .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
    }.buttonStyle(.plain).disabled((model.isBusy && !model.settingUpModels && !voice.isRecording) ||
      voice.starting || voice.transcribing || acceptingCapture ||
      (voice.isRecording && voice.purpose != .transcription))
      .accessibilityLabel(voice.purpose == .transcription ? "Stop transcription" : "Transcribe speech")
  }
  private var sendButton: some View {
    Group {
      if model.isBusy {
        Button { model.cancel() } label: {
          Image(systemName: "stop.fill").frame(width: 24, height: 24)
        }.buttonStyle(.plain).accessibilityLabel("Stop local operation")
      } else {
        Button { model.send() } label: {
          Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
        }.buttonStyle(.plain).disabled(
          model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty
        ).keyboardShortcut(.return, modifiers: .command).accessibilityLabel(model.authoredChatRole == nil ? "Send message" : "Add message")
      }
    }
  }
  private enum ComposerControl: Hashable {
    case newChat, authority, attachment, model, recording, transcription
  }
  private var newChatMenu: some View {
    Menu {
      Button("New chat") {
        do { try model.newChat() } catch { model.report(error) }
      }
      if let document = model.selectedDocument {
        Button("New chat about \(document.title)") {
          do { try model.newChat(about: document.id) } catch { model.report(error) }
        }
      }
      if let chat = model.selectedChat {
        Divider()
        Button("Instructions…") { model.openChatInstructions(chat.id) }
        Button(model.chatVoice(chat.id) == nil ? "Pin as voice" : "Unpin voice") {
          if model.chatVoice(chat.id) == nil { model.pinChat(chat.id) } else { model.unpinChat(chat.id) }
        }
        Divider()
        Button("Write a question") { model.authorChatMessage(.user) }
        Button("Write an answer") { model.authorChatMessage(.assistant) }
      }
    } label: {
      Image(systemName: "square.and.pencil")
        .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
    }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
      .accessibilityLabel("New chat").help("Start a chat, optionally about the current document")
  }
  private func overflowMenu(_ hidden: Set<ComposerControl>) -> some View {
    Menu {
      if hidden.contains(.newChat) {
        Button("New chat") {
          do { try model.newChat() } catch { model.report(error) }
        }
        if let document = model.selectedDocument {
          Button("New chat about \(document.title)") {
            do { try model.newChat(about: document.id) } catch { model.report(error) }
          }
        }
      }
      if hidden.contains(.authority) {
        Menu("Message authority") {
          Button("Ask") { model.mode = .ask }
          Button("Propose · review edits") { model.mode = .propose }
          Button("Edit · apply edits") { model.mode = .edit }
      Divider()
      Picker("Multiple voices", selection: $model.consultationStyle) {
        ForEach(ConsultationStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
        }
      }
      if hidden.contains(.attachment) {
        Button("Choose files…") { model.chooseChatAttachmentFiles() }
        Button("Paste image") { model.pasteImageIntoCurrentChat() }
      }
      if hidden.contains(.model) {
        Menu("Model · \(model.inferenceName)") {
          Button("Manage models…") { model.openModels() }
        }.disabled(model.isBusy)
      }
      if hidden.contains(.recording) {
        Button(voice.purpose == .recording ? "Stop audio recording" : "Record audio") {
          toggleVoice(.recording)
        }.disabled((model.isBusy && !model.settingUpModels && !voice.isRecording) || voice.starting || voice.transcribing || acceptingCapture ||
          (voice.isRecording && voice.purpose != .recording))
      }
      if hidden.contains(.transcription) {
        Button(voice.purpose == .transcription ? "Stop transcription" : "Transcribe speech") {
          toggleVoice(.transcription)
        }.disabled((model.isBusy && !model.settingUpModels && !voice.isRecording) || voice.starting || voice.transcribing || acceptingCapture ||
          (voice.isRecording && voice.purpose != .transcription))
      }
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
    }.menuStyle(.borderlessButton).fixedSize()
      .accessibilityLabel("More message controls")
  }
  private func controlRow(
    hidden: Set<ComposerControl> = [], compactLabels: Bool = false
  ) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        if !model.layout.isAuthor && !hidden.contains(.newChat) { newChatMenu }
        if !hidden.contains(.authority) { authorityMenu(compact: compactLabels) }
        if !hidden.contains(.attachment) { attachmentMenu }
      }.fixedSize()
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        if !hidden.contains(.model) { modelMenu(compact: compactLabels) }
        if !hidden.contains(.recording) { recordingButton }
        if !hidden.contains(.transcription) { transcriptionButton }
        if !hidden.isEmpty { overflowMenu(hidden) }
        sendButton
      }.fixedSize()
    }
  }
  private var composerControls: some View {
    ViewThatFits(in: .horizontal) {
      controlRow()
      controlRow(compactLabels: true)
      controlRow(hidden: [.newChat], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .recording], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .recording, .transcription], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .recording, .transcription], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .recording, .transcription, .model], compactLabels: true)
    }.frame(height: 28)
  }
  private func assistantName(_ message: ChatMessage) -> String {
    message.speaker?.name ?? "Bloom"
  }
  private func needsSpeakerName(_ message: ChatMessage) -> Bool {
    message.speaker?.voiceID != nil || (model.selectedChat?.messages.contains { $0.speaker?.voiceID != nil } ?? false)
  }
  private func visibleMessageText(_ message: ChatMessage) -> String {
    if message.state == .pending { return message.text.isEmpty ? "…" : message.text }
    if message.text.isEmpty, let failure = message.failure { return failure }
    return message.text
  }
  @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
    if model.editingChatMessage == message.id, let chat = model.selectedChat {
      VStack(alignment: .leading, spacing: 6) {
        if message.role == .assistant, needsSpeakerName(message) {
          Text(assistantName(message)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        ChatTextEditor(label: "Edit message", text: message.text,
          completionModel: model, completionTarget: TextInputTarget(chatID: chat.id,
            documentID: nil, messageID: message.id),
          save: { try model.replaceChatMessage($0, id: message.id, chatID: chat.id) },
          cancel: { model.editingChatMessage = nil })
      }
    } else if message.role == .user {
      HStack(alignment: .bottom, spacing: 4) {
        Spacer(minLength: 36)
        VStack(alignment: .trailing, spacing: 8) {
          ForEach(message.directAttachments ?? [], id: \.self) { id in
            if let record = model.state.attachments.first(where: { $0.id == id }) {
              InlineAttachmentView(model: model, record: record)
            }
          }
          NativeText(text: visibleMessageText(message), mediaModel: model)
        }
          .padding(.horizontal, 12).padding(.vertical, 9)
          .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
      }.frame(maxWidth: .infinity, alignment: .trailing)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        if needsSpeakerName(message) || message.state != .complete {
          HStack(spacing: 5) {
            if needsSpeakerName(message) {
              Text(assistantName(message))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if message.state != .complete {
              Text(message.state.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
          }
        }
        NativeText(text: visibleMessageText(message), mediaModel: model)
        ForEach(model.state.proposals.filter { $0.messageID == message.id }) { proposal in
          ProposalCard(model: model, proposal: proposal)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func toggleVoice(_ purpose: VoiceInput.Purpose) {
    guard !acceptingCapture else { return }
    if voice.isRecording {
      guard voice.purpose == purpose else { return }
      let chatID = voiceChatID, documentID = voiceDocumentID, draft = voiceDraft
      acceptingCapture = true
      Task {
        defer { acceptingCapture = false }
        do {
          switch try await voice.stop() {
          case .audio(let bytes):
            do { try await model.attachRecordedAudio(bytes, chatID: chatID, documentID: documentID) }
            catch { recoveredRecording = bytes }
          case .transcript(let text):
            guard model.state.selectedChat == chatID, model.draft == draft,
              model.state.selectedDocument == documentID else {
              recoveredVoiceText += (recoveredVoiceText.isEmpty ? "" : " ") + text
              return
            }
            model.draft += (model.draft.isEmpty ? "" : " ") + text
            composerFocusRequest += 1
          }
        } catch is CancellationError {} catch {
          restoreComposerAfterAlert = true
          model.report(error)
        }
      }
    } else {
      voiceChatID = model.state.selectedChat
      voiceDocumentID = model.state.selectedDocument
      voiceDraft = model.draft
      Task {
        do {
          try await voice.start(purpose)
          model.status = purpose == .transcription ? "Transcribing" : "Recording"
        } catch is CancellationError {} catch { model.report(error) }
      }
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if model.layout.isAuthor { DocumentChatHistory(model: model) }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if let chat = model.selectedChat {
              if model.showingChatInstructions == chat.id || !(chat.instructions ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                  if model.showingChatInstructions == chat.id {
                    ChatInstructions(model: model, chat: chat)
                  } else {
                    Button("Instructions") { model.openChatInstructions(chat.id) }
                      .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                      .disabled(model.isBusy)
                  }
                }.id("chat-instructions")
              }
              ForEach(chat.messages) { message in
                ChatMessageRow(commands: ChatMessageCommands(model: model, chatID: chat.id, message: message)) {
                  messageView(message)
                }
              }

            }
            Color.clear.frame(height: 1).id("bottom")
          }.padding(.horizontal, WorkspaceGeometry.paneInset + WorkspaceGeometry.inputInset)
            .padding(.vertical, WorkspaceGeometry.paneInset)
        }
          .onAppear {
            DispatchQueue.main.async {
              let instructions = model.showingChatInstructions == model.state.selectedChat
              proxy.scrollTo(instructions ? "chat-instructions" : "bottom", anchor: instructions ? .top : .bottom)
            }
          }
          .onChange(of: model.selectedChat?.messages.count) { _, _ in
            proxy.scrollTo("bottom", anchor: .bottom)
          }
          .onChange(of: model.showingChatInstructions) { _, id in
            if id != nil {
              DispatchQueue.main.async { proxy.scrollTo("chat-instructions", anchor: .top) }
            }
          }
          .onChange(of: model.streamingText) { _, _ in
            if model.isBusy { proxy.scrollTo("bottom", anchor: .bottom) }
          }
      }.id(model.state.selectedChat)
      VStack(alignment: .leading, spacing: 8) {
        if let chat = model.selectedChat, let documentID = chat.attachedDocumentID {
          HStack(spacing: 5) {
            Image(systemName: "doc.text")
            Text("About " + (model.documents.first { $0.id == documentID }?.title ?? "missing document"))
              .lineLimit(1)
            Button {
              model.attachDocument(nil, to: chat.id)
            } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("Detach document from chat")
          }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let recording = recoveredRecording {
          HStack {
            Image(systemName: "waveform")
            Button {
              Task {
                do {
                  try await model.attachRecordedAudio(recording, chatID: model.state.selectedChat,
                    documentID: model.state.selectedDocument)
                  recoveredRecording = nil
                } catch { model.composerIssue = "The recording couldn't be attached yet." }
              }
            } label: { Image(systemName: "plus") }
              .buttonStyle(.plain).accessibilityLabel("Attach retained recording")
            Button { recoveredRecording = nil } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("Discard retained recording")
          }
        }
        if !recoveredVoiceText.isEmpty {
          HStack {
            Image(systemName: "mic").foregroundStyle(.secondary)
            Spacer()
            Button {
              model.draft += (model.draft.isEmpty ? "" : " ") + recoveredVoiceText
              recoveredVoiceText = ""
            } label: { Image(systemName: "plus") }
              .buttonStyle(.plain).accessibilityLabel("Insert retained transcript")
            Button { recoveredVoiceText = "" } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("Discard retained transcript")
          }
        }
        if !model.pendingAttachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(model.pendingAttachments, id: \.self) { id in
                if let attachment = model.state.attachments.first(where: { $0.id == id }) {
                  InlineAttachmentView(model: model, record: attachment,
                    remove: { model.removePending(id) }).frame(maxWidth: 320)
                }
              }
            }
          }.frame(height: model.pendingAttachments.compactMap { id in
            model.state.attachments.first(where: { $0.id == id }).map { record -> CGFloat in
              switch record.kind {
              case .audio: 44
              case .image: 180
              case .video, .pdf: 220
              case .document: NativeScrollableText.height(of: record.text, width: 300)
              case .unavailable: 24
              }
            }
          }.max() ?? 44)
        }
        if let role = model.authoredChatRole {
          HStack {
            Text(role == .user ? "Writing a question" : "Writing an answer").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Return to chat") { model.authoredChatRole = nil }.buttonStyle(.plain).font(.caption)
          }
        }
        if let issue = model.composerIssue {
          Text(issue).font(.caption).foregroundStyle(.orange)
        }
        if model.settingUpModels {
          HStack(spacing: 8) { ProgressView().controlSize(.small).help(model.status); Spacer() }
            .foregroundStyle(.secondary)
        } else if let issue = model.modelSetupIssue {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(issue)
            Spacer()
            Button { model.prepareModels() } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.plain).disabled(model.isBusy).accessibilityLabel("Retry model preparation")
          }
        }
        if !model.voiceMatches.isEmpty {
          HStack(spacing: 10) {
            ForEach(model.voiceMatches) { persona in
              Button("@" + persona.slug) { model.insertVoice(persona) }.buttonStyle(.plain).font(
                .caption)
            }
          }
        }
        ChatComposer(
          text: $model.draft, focusRequest: composerFocusRequest,
          onSend: { model.send() }, onCancel: { model.cancel() },
          onAttachments: { model.attachToCurrentChat($0) },
          onFocus: { model.noteInputFocus(.chat) },
          onContentHeight: { composerHeight = min(140, max(36, $0)) },
          completionModel: model, completionTarget: TextInputTarget(chatID: model.state.selectedChat,
            documentID: model.state.selectedDocument)
        ).frame(height: composerHeight)
        composerControls
      }.padding(WorkspaceGeometry.inputInset)
        .background(Color(nsColor: BoomChrome.inputBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, WorkspaceGeometry.paneInset)
        .padding(.bottom, WorkspaceGeometry.paneInset).padding(.top, 8)
    }
    .background(Color(nsColor: BoomChrome.sidebarBackground))
    .onChange(of: model.state.selectedChat) { _, _ in voice.stopSpeaking() }
    .onChange(of: model.composerFocusEpoch) { _, _ in
      composerFocusRequest += 1
    }
    .onChange(of: model.errorMessage) { old, new in
      if old != nil, new == nil, restoreComposerAfterAlert {
        restoreComposerAfterAlert = false
        composerFocusRequest += 1
      }
    }
    .onDisappear { voice.cancel() }
  }
}
struct ProposalCard: View {
  @ObservedObject var model: WorkspaceModel
  let proposal: StoredProposal
  @State private var expanded = true
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(proposal.document.title).font(.caption.weight(.medium))
        Spacer()
        Text(proposal.status.capitalized).font(.caption).foregroundStyle(.secondary)
      }
      if proposal.status == "pending" {
        DisclosureGroup("\(proposal.patch.replacements.count) replacements", isExpanded: $expanded)
        {
          ForEach(Array(proposal.patch.replacements.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading, spacing: 4) {
              NativeText(text: "− " + r.old, presentation: .removed, pointSize: 12)
              NativeText(text: "+ " + r.new, presentation: .added, pointSize: 12)
            }.padding(
              .vertical, 4)
          }
        }.font(.caption)
        HStack {
          Button("Accept") { model.accept(proposal.id) }.disabled(model.isBusy)
          Button("Reject") { model.reject(proposal.id) }.buttonStyle(.plain)
        }
      } else if proposal.status == "applied" {
        Button("Undo document edit") { model.undoProposal(proposal) }.font(.caption).buttonStyle(
          .plain
        ).disabled(!model.canUndo(proposal))
      }
    }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
  }
}

struct ModelPickerView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var search = ""
  private var choices: [ModelSetupChoice] {
    model.modelChoices.filter { search.isEmpty || ($0.title + " " + $0.purposeLabel + " " + ($0.checkpoint?.repository ?? "Bloom")).localizedCaseInsensitiveContains(search) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Models").font(.headline)
        Spacer()
        Menu {
          Button("Import…") { model.importModel() }.disabled(model.isBusy)
          Button("Refresh") { model.refreshModelChoices() }
        } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Model actions")
        Button { model.showingModels = false } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close model picker")
      }
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search", text: $search).textFieldStyle(.plain)
          .accessibilityLabel("Search curated models")
      }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach([true, false], id: \.self) { local in
            let group = choices.filter { $0.candidate.cached == local }
            if !group.isEmpty {
              Text(local ? "Local" : "Hugging Face").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 8)
              ForEach(group) { choice in
                Button { model.chooseModel(choice) } label: {
                  HStack(spacing: 8) {
                    Image(systemName: choice.candidate.purpose == .consultation ? "bubble.left" : "pencil")
                      .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(choice.title)
                      Text(choice.purposeLabel + " · " + ByteCountFormatter.string(fromByteCount: Int64(choice.candidate.weightBytes), countStyle: .memory))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: model.modelIsSelected(choice) ? "checkmark" : local ? "arrow.right" : "arrow.down.circle")
                      .foregroundStyle(.secondary)
                  }.padding(.vertical, 7).padding(.horizontal, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                  .help((choice.checkpoint?.repository ?? "Bloom") + " · " + choice.purposeLabel + (local ? " · Local" : " · Download"))
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 360)
      if model.settingUpModels {
        HStack { ProgressView().controlSize(.small); Text("Preparing").font(.caption) }
          .help(model.status)
      }
      if let issue = model.modelSetupIssue ?? model.modelPickerIssue {
        HStack {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(issue)
          Spacer()
          Button { model.prepareModels() } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).disabled(model.isBusy).accessibilityLabel("Retry model preparation")
        }
      }
    }.padding(16).frame(width: 350)
      .onAppear { model.refreshModelChoices() }
  }
}
