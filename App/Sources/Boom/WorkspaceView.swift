import AppKit
import BoomCore
import Combine
import SwiftUI

enum BoomChrome {
  static var sidebarBackground: NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    }
  }
}

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  var body: some View {
    GeometryReader { geometry in
      HSplitView {
        if model.showsLibrary {
          LibraryView(model: model).frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
        }
        if model.showsDocument {
          if let document = model.selectedDocument {
            VStack(spacing: 0) {
              let attachments = model.documentAttachments(document)
              if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                      Button {
                        model.previewReceipt = false
                        model.previewAttachment = attachment.id
                      } label: {
                        Label(attachment.name, systemImage: attachment.text.isEmpty
                          ? "exclamationmark.circle" : "paperclip")
                          .lineLimit(1)
                      }.buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(attachment.text.isEmpty ? .secondary : .primary)
                        .help(attachment.coverage)
                    }
                  }.padding(.horizontal, 20).padding(.vertical, 8)
                }
                Divider()
              }
              MarkdownEditor(model: model, document: document)
            }.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
          } else {
            Text("Choose a document").foregroundStyle(.secondary).frame(
              minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        if model.showsChat {
          ChatPane(model: model).frame(
            minWidth: 280, idealWidth: 370, maxWidth: model.showsDocument ? 620 : .infinity)
        }
      }
      .onChange(of: geometry.size.width, initial: true) { _, width in
        model.fitPanes(to: width)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
      model.refreshAppleAvailability()
    }
    .environment(\.openURL, OpenURLAction { _ in .discarded })
    .sheet(isPresented: $model.showingModels) { ModelSetupView(model: model) }
    .sheet(
      isPresented: Binding(
        get: { model.previewAttachment != nil }, set: { if !$0 { model.previewAttachment = nil } })
    ) {
      if let id = model.previewAttachment { AttachmentPreview(model: model, id: id) }
    }
    .alert(
      "Boom",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    ) {
      Button("OK", role: .cancel) { model.dismissError() }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

struct LibraryView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var filter = ""
  @State private var documentAnchor: UUID?
  @State private var chatAnchor: UUID?
  private func includes(_ title: String) -> Bool {
    filter.isEmpty || title.localizedCaseInsensitiveContains(filter)
  }
  private func heading(_ title: String, add: (() -> Void)? = nil) -> some View {
    HStack {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(.tertiary)
      Spacer()
      if let add {
        Button(action: add) { Image(systemName: "plus") }
          .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary).accessibilityLabel("New \(title.dropLast())")
      }
    }.padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 7)
  }
  private func row(_ title: String, symbol: String, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13, weight: .regular))
        .foregroundStyle(selected ? .primary : .secondary).frame(width: 17)
      Text(title).font(.system(size: 13)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? Color.primary.opacity(0.075) : .clear,
      in: RoundedRectangle(cornerRadius: 7))
    .contentShape(Rectangle())
  }
  private func chooseDocument(_ id: UUID) {
    let visible = model.documents.filter { includes($0.title) }.map(\.id)
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    var selection = LibrarySelection(ids: model.selectedDocumentIDs, anchor: documentAnchor)
    let result = selection.click(
      id, visible: visible, primary: model.state.selectedDocument, gesture: clickGesture(modifiers))
    documentAnchor = selection.anchor
    model.selectedDocumentIDs = selection.ids
    if result.rename { model.renameDocument(id) }
    if result.open { model.selectDocument(id, preservingSelection: true) }
  }
  private func chooseChat(_ id: UUID) {
    let visible = model.state.chats.filter { includes($0.title) }.map(\.id)
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    var selection = LibrarySelection(ids: model.selectedChatIDs, anchor: chatAnchor)
    let result = selection.click(
      id, visible: visible, primary: model.state.selectedChat, gesture: clickGesture(modifiers))
    chatAnchor = selection.anchor
    model.selectedChatIDs = selection.ids
    if result.rename { model.renameChat(id) }
    if result.open { model.selectChat(id, preservingSelection: true) }
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
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
        TextField("Search", text: $filter).textFieldStyle(.plain)
          .accessibilityLabel("Filter documents, chats and personas")
      }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 12)
      Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          heading("Documents") {
            do { try model.newDocument() } catch { model.report(error) }
          }
          ForEach(model.documents.filter { includes($0.title) }) { document in
            Button { chooseDocument(document.id) } label: {
              row(document.title, symbol: "doc.text",
                selected: model.selectedDocumentIDs.contains(document.id))
            }.buttonStyle(.plain).padding(.horizontal, 7)
              .contextMenu {
                Button("Rename…") { model.renameDocument(document.id) }
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
                Button("Reveal UTF-8 file") { model.revealDocument(document.id) }
                Divider()
                Button(
                  documentDeletion(document.id).count == 1 ? "Delete Document…"
                    : "Delete \(documentDeletion(document.id).count) Documents…",
                  role: .destructive
                ) { model.deleteDocuments(documentDeletion(document.id)) }.disabled(model.isBusy)
              }
          }
          heading("Chats") {
            do { try model.newChat() } catch { model.report(error) }
          }
          ForEach(model.state.chats.filter { includes($0.title) }) { chat in
            Button { chooseChat(chat.id) } label: {
              row(chat.title, symbol: "bubble.left",
                selected: model.selectedChatIDs.contains(chat.id))
            }.buttonStyle(.plain).padding(.horizontal, 7)
              .contextMenu {
                Button("Rename…") { model.renameChat(chat.id) }
                Button("Save as persona…") { model.savePersona(from: chat.id) }.disabled(
                  model.isBusy || !model.modelReady || chat.messages.last?.role != .assistant)
                Divider()
                Button(
                  chatDeletion(chat.id).count == 1 ? "Delete Chat…"
                    : "Delete \(chatDeletion(chat.id).count) Chats…",
                  role: .destructive
                ) { model.deleteChats(chatDeletion(chat.id)) }.disabled(model.isBusy)
              }
          }
          if !model.state.personas.isEmpty {
            heading("Personas")
            ForEach(model.state.personas.filter { includes($0.title) || includes($0.slug) }) {
              persona in
              Button {
                model.insertPersona(persona)
                model.state.showChat = true
              } label: {
                row("@" + persona.slug, symbol: "person.crop.circle", selected: false)
              }.buttonStyle(.plain).padding(.horizontal, 7).help(
                persona.model == model.runner?.identity
                  ? "Native KV snapshot saved; authenticated again on use"
                  : "Rebuild this persona for the selected model"
              )
              .contextMenu {
                Button("Consult @\(persona.slug)") { model.insertPersona(persona) }
                Button("Rebuild native cache") { model.rebuildPersona(persona.id) }.disabled(
                  model.isBusy || !model.modelReady)
                Button("Delete persona…", role: .destructive) { model.deletePersona(persona.id) }
                  .disabled(model.isBusy)
              }
            }
          }
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
  @State private var voiceChatID: UUID?
  @State private var voiceDraft = ""
  @State private var awaitingVoiceReply: UUID?
  @State private var recoveredVoiceText = ""
  @State private var restoreComposerAfterAlert = false
  private func authorityMenu(compact: Bool) -> some View {
    Menu {
      Button("Ask · read only") { model.mode = .ask }
      Button("Propose · review edits") { model.mode = .propose }
      Button("Edit · apply edits") { model.mode = .edit }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: model.mode == .ask ? "bubble.left" :
          model.mode == .propose ? "text.badge.plus" : "pencil.line")
        if !compact { Text(model.mode.rawValue) }
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
      }.font(.system(size: 11, weight: .medium))
        .foregroundStyle(model.mode == .ask ? .secondary : .primary)
    }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
      .help("Choose this message's document authority")
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
      Image(systemName: "paperclip").frame(width: 22, height: 22)
    }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
      .accessibilityLabel("Attach files or paste an image")
  }
  private func modelMenu(compact: Bool) -> some View {
    Menu {
      Button("Automatic") { model.chooseModel(.automatic) }
      Button("Apple Foundation Model") { model.chooseModel(.apple) }
        .disabled(!AppleModel.isAvailable)
      Button("Gemma 4 E2B") { model.chooseModel(.gemma) }
        .disabled(model.runner == nil)
      Divider()
      Button("Manage models…") { model.showingModels = true }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "cpu")
        if !compact {
          Text(model.inferenceName == "Apple Foundation Model" ? "Apple" :
            model.inferenceName == "Gemma 4 E2B" ? "Gemma" : "No model")
        }
      }.font(.system(size: 11, weight: .medium)).lineLimit(1)
    }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
      .accessibilityLabel("Current model: \(model.inferenceName)")
      .help("Current local model: \(model.inferenceName). Select a model")
  }
  private var dictationButton: some View {
    Button { toggleVoice(.dictation) } label: {
      Image(systemName: voice.purpose == .dictation ? "stop.circle.fill" : "waveform")
        .frame(width: 22, height: 22)
    }.buttonStyle(.plain).disabled((model.isBusy && !voice.isRecording) ||
      voice.starting || voice.transcribing ||
      (voice.isRecording && voice.purpose != .dictation))
      .accessibilityLabel(voice.purpose == .dictation ? "Stop dictation" : "Dictate into message")
  }
  private var conversationButton: some View {
    Button { toggleVoice(.conversation) } label: {
      Image(systemName: voice.purpose == .conversation ? "stop.circle.fill" : "mic")
        .frame(width: 22, height: 22)
    }.buttonStyle(.plain).disabled((model.isBusy && !voice.isRecording) ||
      voice.starting || voice.transcribing ||
      (voice.isRecording && voice.purpose != .conversation))
      .accessibilityLabel(voice.purpose == .conversation ? "Stop voice recording" : "Start voice conversation")
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
          model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ).keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send message")
      }
    }
  }
  private enum ComposerControl: Hashable {
    case newChat, authority, attachment, model, dictation, conversation
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
    } label: {
      Image(systemName: "square.and.pencil").frame(width: 22, height: 22)
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
        }
      }
      if hidden.contains(.attachment) {
        Button("Choose files…") { model.chooseChatAttachmentFiles() }
        Button("Paste image") { model.pasteImageIntoCurrentChat() }
      }
      if hidden.contains(.model) {
        Menu("Model · \(model.inferenceName)") {
          Button("Automatic") { model.chooseModel(.automatic) }
          Button("Apple Foundation Model") { model.chooseModel(.apple) }
            .disabled(!AppleModel.isAvailable)
          Button("Gemma 4 E2B") { model.chooseModel(.gemma) }
            .disabled(model.runner == nil)
          Divider()
          Button("Manage models…") { model.showingModels = true }
        }
      }
      if hidden.contains(.dictation) {
        Button(voice.purpose == .dictation ? "Stop dictation" : "Dictate into message") {
          toggleVoice(.dictation)
        }.disabled((model.isBusy && !voice.isRecording) || voice.starting || voice.transcribing ||
          (voice.isRecording && voice.purpose != .dictation))
      }
      if hidden.contains(.conversation) {
        Button(voice.purpose == .conversation ? "Stop voice recording" : "Start voice conversation") {
          toggleVoice(.conversation)
        }.disabled((model.isBusy && !voice.isRecording) || voice.starting || voice.transcribing ||
          (voice.isRecording && voice.purpose != .conversation))
      }
    } label: {
      Image(systemName: "ellipsis").frame(width: 22, height: 22)
    }.menuStyle(.borderlessButton).fixedSize()
      .accessibilityLabel("More message controls")
  }
  private func controlRow(
    hidden: Set<ComposerControl> = [], compactLabels: Bool = false
  ) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        if !hidden.contains(.newChat) { newChatMenu }
        if !hidden.contains(.authority) { authorityMenu(compact: compactLabels) }
        if !hidden.contains(.attachment) { attachmentMenu }
      }.fixedSize()
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        if !hidden.contains(.model) { modelMenu(compact: compactLabels) }
        if !hidden.contains(.dictation) { dictationButton }
        if !hidden.contains(.conversation) { conversationButton }
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
      controlRow(hidden: [.newChat, .attachment, .dictation], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .dictation, .conversation], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .dictation, .conversation, .authority], compactLabels: true)
      controlRow(hidden: [.newChat, .attachment, .dictation, .conversation, .authority, .model], compactLabels: true)
    }.frame(height: 28)
  }
  private func assistantName(_ message: ChatMessage) -> String {
    message.personaID.flatMap { id in
      model.state.personas.first { $0.id == id }.map { "@" + $0.slug }
    } ?? (message.provider ?? "Local assistant")
  }
  @ViewBuilder private func messageMenu(_ message: ChatMessage) -> some View {
    if let chatID = model.state.selectedChat {
      if message.role == .user {
        Button("Edit & Continue") { model.branch(message.id, from: chatID, editing: true) }
        Button("Branch from here") { model.branch(message.id, from: chatID) }
      } else {
        Button("Regenerate in new branch") { model.regenerate(message.id, from: chatID) }
          .disabled(message.state != .complete)
        Button("Branch from here") { model.branch(message.id, from: chatID) }
        Divider()
        Button(message.feedback == .helpful ? "Remove thumbs up" : "Thumbs up") {
          model.rate(message.id, in: chatID, as: .helpful)
        }
        Button(message.feedback == .unhelpful ? "Remove thumbs down" : "Thumbs down") {
          model.rate(message.id, in: chatID, as: .unhelpful)
        }
      }
      Divider()
      Button("Copy message") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
      }
    }
  }
  @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
    if message.role == .user {
      HStack(alignment: .bottom, spacing: 4) {
        Spacer(minLength: 36)
        ChatMarkdown(text: message.text)
          .padding(.horizontal, 12).padding(.vertical, 9)
          .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
      }.frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle()).contextMenu { messageMenu(message) }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          Text(assistantName(message))
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
          if message.state != .complete {
            Text(message.state.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary)
          }
          if let feedback = message.feedback {
            Image(systemName: feedback == .helpful ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
              .font(.system(size: 10)).foregroundStyle(.tertiary)
          }
        }
        ChatMarkdown(text: message.text)
        ForEach(model.state.proposals.filter { $0.messageID == message.id }) { proposal in
          ProposalCard(model: model, proposal: proposal)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).contextMenu { messageMenu(message) }
    }
  }
  private func toggleVoice(_ purpose: VoiceInput.Purpose) {
    if voice.isRecording {
      guard voice.purpose == purpose else { return }
      Task {
        do {
          let text = try await voice.stop()
          guard model.state.selectedChat == voiceChatID, model.draft == voiceDraft,
            !model.isBusy else {
            recoveredVoiceText += (recoveredVoiceText.isEmpty ? "" : " ") + text
            model.status = "Voice transcript ready to insert"
            return
          }
          model.draft += (model.draft.isEmpty ? "" : " ") + text
          if purpose == .conversation {
            guard model.canInfer else {
              model.status = "Voice transcript ready · choose a local model to send"
              model.showingModels = true
              return
            }
            model.mode = .ask
            awaitingVoiceReply = voiceChatID
            model.send()
            if !model.isBusy { awaitingVoiceReply = nil }
          } else {
            model.status = "Dictated on device"
            composerFocusRequest += 1
          }
        } catch is CancellationError {} catch {
          restoreComposerAfterAlert = true
          model.report(error)
        }
      }
    } else {
      voiceChatID = model.state.selectedChat
      voiceDraft = model.draft
      Task {
        do {
          try await voice.start(purpose)
          model.status = purpose == .conversation ? "Voice conversation · recording" : "Dictation · recording"
        } catch is CancellationError {} catch { model.report(error) }
      }
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if let chat = model.selectedChat {
              ForEach(chat.messages) { message in
                messageView(message).id(message.id)
              }
              if model.isBusy && model.streamingChat == chat.id {
                VStack(alignment: .leading, spacing: 6) {
                  Text(model.inferenceName)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                  ChatMarkdown(text: model.streamingText.isEmpty ? "…" : model.streamingText)
                }.frame(maxWidth: .infinity, alignment: .leading).id("stream")
              }
            }
            Color.clear.frame(height: 1).id("bottom")
          }.padding(.horizontal, 16).padding(.vertical, 18)
        }
          .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
          .onChange(of: model.selectedChat?.messages.count) { _, _ in
            proxy.scrollTo("bottom", anchor: .bottom)
          }
          .onChange(of: model.state.selectedChat) { _, _ in
            proxy.scrollTo("bottom", anchor: .bottom)
          }
          .onChange(of: model.streamingText) { _, _ in
            if model.isBusy { proxy.scrollTo("bottom", anchor: .bottom) }
          }
      }
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
        if !recoveredVoiceText.isEmpty {
          HStack {
            Text("Voice transcript saved").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Insert") {
              model.draft += (model.draft.isEmpty ? "" : " ") + recoveredVoiceText
              recoveredVoiceText = ""
            }.font(.caption)
            Button("Discard") { recoveredVoiceText = "" }.font(.caption).buttonStyle(.plain)
          }
        }
        if !model.pendingAttachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(model.pendingAttachments, id: \.self) { id in
                if let attachment = model.state.attachments.first(where: { $0.id == id }) {
                  HStack(spacing: 5) {
                    Button {
                      model.previewReceipt = false
                      model.previewAttachment = id
                    } label: {
                      Label(
                        attachment.name,
                        systemImage: attachment.text.isEmpty
                          ? "exclamationmark.circle" : "paperclip"
                      ).lineLimit(1)
                    }.buttonStyle(.plain)
                    Button {
                      model.removePending(id)
                    } label: {
                      Image(systemName: "xmark").font(.system(size: 9))
                    }.buttonStyle(.plain).disabled(model.isBusy).accessibilityLabel(
                      "Remove \(attachment.name) from this message")
                  }.font(.caption).padding(.horizontal, 7).padding(.vertical, 5).background(
                    Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                }
              }
            }
          }
        }
        if !model.personaMatches.isEmpty {
          HStack(spacing: 10) {
            ForEach(model.personaMatches) { persona in
              Button("@" + persona.slug) { model.insertPersona(persona) }.buttonStyle(.plain).font(
                .caption)
            }
          }
        }
        ChatComposer(
          text: $model.draft, focusRequest: composerFocusRequest,
          onSend: { model.send() }, onCancel: { model.cancel() },
          onAttachments: { model.attachToCurrentChat($0) }
        ).frame(height: CGFloat(50 + 18 * min(3, model.draft.filter { $0 == "\n" }.count)))
        composerControls
      }.padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 8)
    }
    .onChange(of: model.selectedChat?.messages.count) { _, _ in
      guard let chat = model.selectedChat, chat.id == awaitingVoiceReply,
        let message = chat.messages.last, message.role == .assistant else { return }
      awaitingVoiceReply = nil
      if message.state == .complete { voice.speak(message.text) }
    }
    .onChange(of: model.state.selectedChat) { _, _ in
      awaitingVoiceReply = nil
      voice.stopSpeaking()
    }
    .onChange(of: model.draft) { _, text in
      if !text.isEmpty { model.ensureChatForDraft() }
    }
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
struct ChatMarkdown: View {
  let text: String
  var body: some View {
    Text(
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    )
    .font(.system(size: 14)).lineSpacing(3)
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
              Text("− " + r.old).strikethrough().foregroundStyle(.secondary)
              Text("+ " + r.new)
            }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(
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

struct ModelSetupView: View {
  @ObservedObject var model: WorkspaceModel
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Text("Models").font(.title2.weight(.semibold))
      HStack(spacing: 9) {
        Image(systemName: "sparkles")
          .foregroundStyle(AppleModel.isAvailable ? .primary : .secondary)
        Text(model.appleAvailability).font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
      if !AppleModel.isAvailable {
        Button("Open Siri Settings") {
          guard let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
            NSWorkspace.shared.open(url) else {
            model.report(BoomError.unavailable("Could not open Siri Settings. Open it from System Settings."))
            return
          }
        }.font(.caption)
      }
      Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
      Text("Gemma 4 E2B · CoreML")
        .font(.system(size: 13, weight: .medium))
      HStack {
        Button("Download Gemma 4 E2B") { model.downloadModel() }
        Button("Import model folder…") { model.importModel() }
      }.disabled(model.isBusy)
      Text(
        "Verified files are reused from the Hugging Face cache; new downloads go there too. Native persona caches require Gemma."
      ).font(.caption).foregroundStyle(.tertiary)
      HStack {
        if model.isBusy {
          ProgressView().controlSize(.small)
          Button("Stop") { model.cancel() }
        }
        Spacer()
        Button("Done") { model.showingModels = false }.keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: 490)
  }
}

struct AttachmentPreview: View {
  @ObservedObject var model: WorkspaceModel
  let id: UUID
  @State private var bytes: Data?
  @State private var receipt = ""
  @State private var failure: String?
  private var record: AttachmentRecord? { model.state.attachments.first { $0.id == id } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(record?.name ?? "Attachment").font(.headline)
      if let record {
        Text(record.coverage).font(.caption).foregroundStyle(.secondary)
        if let transform = record.transform {
          Text(transform).font(.caption).foregroundStyle(.secondary)
        }
        Picker("Preview", selection: $model.previewReceipt) {
          Text("Content").tag(false)
          Text("Processing receipt").tag(true)
        }.pickerStyle(.segmented).frame(width: 270)
        if model.previewReceipt {
          ScrollView {
            Text(receipt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              if let bytes, let image = NativeMedia.thumbnail(bytes) {
                Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().scaledToFit()
                  .frame(maxHeight: 280)
              }
              Text(
                record.text.isEmpty
                  ? "No text has been admitted for this attachment. Its original bytes are preserved; unsupported content has not been silently included in the prompt."
                  : record.text
              ).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
        HStack {
          if record.text.isEmpty {
            Button(record.coverage.contains("Long recording")
              ? "Transcribe full recording" : "Retry local conversion") {
                model.prepareAttachment(id)
              }.disabled(model.isBusy)
          }
          Button("Export original…") { exportOriginal() }.disabled(bytes == nil)
          if model.isBusy {
            ProgressView().controlSize(.small)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Button("Stop") { model.cancel() }
          }
          Spacer()
          Button("Done") { model.previewAttachment = nil }.keyboardShortcut(.cancelAction)
        }
      }
    }.padding(20).frame(width: 680, height: 600)
      .task {
        do {
          bytes = try model.store.vault.get(.attachment, id: id, limit: 67_108_864)
          let data = try model.store.vault.get(.receipt, id: id, limit: 8_388_608)
          let object = try JSONSerialization.jsonObject(with: data)
          let pretty = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
          receipt = String(decoding: pretty.prefix(131_072), as: UTF8.self)
          if pretty.count > 131_072 {
            receipt += "\n[Display limited to 128 KiB; full receipt remains encrypted on disk.]"
          }
        } catch { failure = error.localizedDescription }
      }
  }
  private func exportOriginal() {
    guard let bytes else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = record?.name ?? "attachment"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try bytes.write(to: url, options: .atomic) } catch { failure = error.localizedDescription }
  }
}
