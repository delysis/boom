import AppKit
import BoomCore
import SwiftUI

struct BlessengerView: View {
  @ObservedObject var model: BlessengerModel
  @ObservedObject private var audio: BlessengerAudioOutput
  @State private var instructions = ""
  @State private var renameID: UUID?
  @State private var renameText = ""
  @State private var removeID: UUID?
  @State private var details = false
  @State private var composerHeight: CGFloat = 28
  init(model: BlessengerModel) { self.model = model; audio = model.audio }
  var body: some View {
    HSplitView {
      sidebar.frame(minWidth: 180, idealWidth: 255, maxWidth: 390)
      VStack(spacing: 0) {
        header
        Divider()
        if model.settingsOpen { settings }
        else {
          if model.state.selectedChat == nil { addressing }
          if model.templateSelected { template }
          else { transcript; composer }
        }
      }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }
    .font(.system(size: 14))
    .frame(minWidth: 640, minHeight: 480)
    .background(Color(nsColor: .textBackgroundColor))
    .overlay(alignment: .bottom) {
      if model.failure != nil || audio.error != nil {
        HStack(spacing: 10) {
          Button { details.toggle() } label: { Image(systemName: "exclamationmark.triangle") }
            .help("Open error details").accessibilityLabel("Open error details")
          Text("Attention").font(.callout)
          Spacer()
          Button { model.dismissFailure() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
        }.padding(10).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
          .padding(12)
      }
    }
    .sheet(isPresented: $details) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Details").font(.headline)
        NativeScrollableText(text: model.failure ?? audio.error ?? "", maximumHeight: 300).frame(minWidth: 360)
        Button("Close") { details = false }.keyboardShortcut(.cancelAction)
      }.padding(24)
    }
    .sheet(item: Binding(get: { renameID.map { IdentifiedID(id: $0) } }, set: { renameID = $0?.id })) { item in
      VStack(alignment: .leading, spacing: 16) {
        Text("Rename").font(.headline)
        TextField("Name", text: $renameText).onSubmit { rename(item.id) }
        HStack { Button("Cancel") { renameID = nil }; Spacer(); Button("Save") { rename(item.id) }.keyboardShortcut(.defaultAction) }
      }.padding(24).frame(width: 360)
    }
    .confirmationDialog("Remove this item from the library?", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) {
      Button("Remove", role: .destructive) {
        if let id = removeID { Task { await model.remove(id) } }; removeID = nil
      }
    } message: { Text("Other conversations and their historical attribution remain unchanged.") }
  }
  private var sidebar: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search", text: Binding(get: { model.search }, set: { model.search = $0 })).textFieldStyle(.plain)
          .accessibilityLabel("Search conversations and Contacts")
        Menu {
          Picker("Show", selection: $model.filter) {
            Text("All").tag("all"); Text("Messages").tag("messages"); Text("Contacts").tag("contacts")
          }
        } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize()
      }.padding(10).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 9)).padding([.horizontal, .top], 10)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          if model.filter != "contacts" {
            ForEach(model.visibleChats) { chat in sidebarRow(chat, contact: nil) }
          }
          if model.filter != "messages" {
            if model.filter == "all" { Text("Contacts").font(.caption).foregroundStyle(.secondary).padding(.top, 14).padding(.leading, 12) }
            ForEach(model.visibleContacts) { contact in
              if let chat = model.state.chats.first(where: { $0.id == contact.id }) { sidebarRow(chat, contact: contact) }
            }
          }
        }.padding(.horizontal, 6)
      }
    }.background(Color(nsColor: .windowBackgroundColor))
  }
  private func sidebarRow(_ chat: ChatRecord, contact: Voice?) -> some View {
    Button {
      if let contact { Task { await model.addContact(BlessengerContact(contact)) } }
      else { Task { await model.select(chat.id) } }
    } label: {
      HStack(spacing: 9) {
        BlessengerPortrait(id: contact?.id ?? chat.messages.last?.speaker?.voiceID, catalog: model.catalog).frame(width: 34, height: 34)
        VStack(alignment: .leading, spacing: 3) {
          Text(chat.title).lineLimit(1)
          if contact == nil, let last = chat.messages.last {
            Text(last.state == .pending ? "…" : String(last.text.prefix(90))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(model.state.selectedChat == chat.id ? Color.accentColor.opacity(0.22) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }.buttonStyle(.plain)
      .contextMenu {
        if contact != nil { Button("Edit") { Task { await model.select(chat.id, template: true); instructions = chat.instructions ?? "" } } }
        else { Button("Save as Contact") { Task { await model.pin(chat.id) } } }
        Button("Rename") { renameText = chat.title; renameID = chat.id }
        Button("Remove", role: .destructive) { removeID = chat.id }
      }
  }
  private var header: some View {
    HStack {
      Button { Task { await model.select(nil) } } label: { Image(systemName: "square.and.pencil") }
        .buttonStyle(GlassControl()).help("New Message").accessibilityLabel("New Message")
      Spacer()
      HStack(spacing: 9) {
        BlessengerPortrait(id: model.recipients.count == 1 ? model.recipients.first?.id : nil, catalog: model.catalog).frame(width: 32, height: 32)
        Text(model.title).lineLimit(1)
      }
      Spacer()
      Button { model.toggleCall() } label: { Image(systemName: model.isCalling ? "phone.down.fill" : "phone") }
        .buttonStyle(GlassControl()).help(model.isCalling ? "End Call" : "Call")
        .accessibilityLabel(model.isCalling ? "End Call" : "Call")
        .disabled(!model.canCall && !model.isCalling)
    }.padding(.horizontal, 16).frame(height: 64)
      .background(.thinMaterial)
  }
  private var addressing: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .center, spacing: 7) {
        Text("To:").foregroundStyle(.secondary)
        ForEach(model.draft.recipients) { contact in
          HStack(spacing: 4) {
            Text(contact.name).lineLimit(1)
            Button { model.removeContact(contact.id) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
              .buttonStyle(.plain).accessibilityLabel("Remove \(contact.name)")
          }.padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary).clipShape(Capsule())
        }
        BlessengerToField(query: Binding(get: { model.draft.recipientQuery }, set: model.editRecipientQuery), contacts: model.state.voices.map { BlessengerContact($0) },
          focus: model.recipientFocus) { contact in
          Task { await model.addContact(contact) }
        }.frame(minWidth: 70).frame(height: 26)
      }
      if model.draft.recipients.count > 1 {
        TextField("Group name", text: Binding(get: { model.draft.groupName ?? "" }, set: model.editGroupName)).textFieldStyle(.plain)
      }
    }.padding(.horizontal, 18).padding(.vertical, 10)
  }
  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if let chat = model.selected {
            ForEach(chat.messages) { message in
              messageRow(message).id(message.id)
            }
          }
          Color.clear.frame(height: 1).id("bottom")
        }.padding(18).frame(maxWidth: 820).frame(maxWidth: .infinity)
      }
      .onChange(of: model.state.selectedChat) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
    }
  }
  private func messageRow(_ message: ChatMessage) -> some View {
    let outgoing = message.role == .user
    let text = model.liveText[message.id] ?? message.text
    return HStack(alignment: .bottom, spacing: 8) {
      if outgoing { Spacer(minLength: 40) }
      else if message.state != .pending || !text.isEmpty {
        BlessengerPortrait(id: message.speaker?.voiceID, catalog: model.catalog).frame(width: 32, height: 32)
      }
      VStack(alignment: .leading, spacing: 6) {
        if !outgoing, let name = message.speaker?.name { Text(name).font(.caption).foregroundStyle(.secondary) }
        if message.state == .pending && text.isEmpty {
          ProgressView().controlSize(.small).padding(5).accessibilityLabel("Preparing response")
        } else if !text.isEmpty { NativeText(text: text) }
        ForEach(message.directAttachments ?? [], id: \.self) { id in
          if let attachment = model.state.attachments.first(where: { $0.id == id }) {
            Button { model.preview(id) } label: { Label(attachment.name, systemImage: attachment.kind == .audio ? "waveform" : "paperclip") }
              .buttonStyle(.plain).help("Open attachment")
          }
        }
        if message.state == .cancelled { Text("Interrupted").font(.caption).foregroundStyle(.secondary) }
        if message.state == .failed { Label("Incomplete", systemImage: "exclamationmark.circle").font(.caption) }
        if audio.responseID == message.id, audio.ready {
          Button { audio.stop(responseID: message.id) } label: { Image(systemName: "stop.fill") }
            .buttonStyle(.plain).accessibilityLabel("Stop playback")
        }
      }.padding(.horizontal, 13).padding(.vertical, 10)
        .background(outgoing ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contextMenu {
          Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
          if !outgoing, message.state == .pending { Button("Stop") { model.stop(message.id) } }
          if !outgoing, message.state != .pending { Button("Read Aloud") { model.readAloud(message) } }
          Button("Branch Here") { Task { await model.branch(at: message.id) } }
          Button("Edit") { model.editMessage(message) }
        }
      if !outgoing { Spacer(minLength: 40) }
    }
  }
  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      Button { model.pickAttachments() } label: { Image(systemName: "plus") }
        .buttonStyle(GlassControl()).accessibilityLabel("Add attachment")
      ChatComposer(text: Binding(get: { model.draft.text }, set: model.editText), focusRequest: model.composerFocus,
        onSend: { if model.draft.recipientQuery.isEmpty { model.send() } }, onCancel: { model.stop() },
        onAttachments: { inputs in Task { await model.importInputs(inputs) } },
        accessibilityLabel: "Message; Return sends, Shift Return inserts a line break",
        onContentHeight: { composerHeight = min(180, max(28, $0)) },
        onIssue: { model.report(BoomError.invalid($0)) }, sendsOnReturn: true, maximumUTF8Bytes: 2_097_152)
        .disabled(model.navigating).frame(height: composerHeight)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 18))
      Button {
        if model.preparing || model.state.selectedChat.map({ model.active.contains($0) }) == true { model.stop() }
        else if model.draft.recipientQuery.isEmpty { model.send() }
      } label: { Image(systemName: model.preparing || model.state.selectedChat.map({ model.active.contains($0) }) == true ? "stop.fill" : "arrow.up") }
        .buttonStyle(GlassControl())
        .disabled(!model.canSend && !model.preparing && model.state.selectedChat.map({ model.active.contains($0) }) != true)
        .accessibilityLabel(model.preparing ? "Stop" : "Send")
    }.padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 8)
  }
  private var template: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Instructions").font(.headline)
      TextEditor(text: $instructions).font(.system(size: 14))
      HStack {
        Button("Save") { Task { await model.updateInstructions(instructions) } }
        Button("Message") { if let id = model.state.selectedChat, let voice = model.state.voices.first(where: { $0.id == id }) { Task { await model.addContact(BlessengerContact(voice)) } } }
        Spacer()
      }
    }.padding(18).onAppear { instructions = model.selected?.instructions ?? "" }
  }
  private var settings: some View {
    Form {
      Section("Local model") {
        Text(model.product.addresses[model.draft.id]?.profile.modelPath ?? model.product.defaultProfile.modelPath ?? "Use the verified local model cache")
          .font(.caption).textSelection(.enabled)
        Button("Choose Model…") { model.pickModel() }
        Button("Install Model…") { model.installModel() }
      }
      Section("Speech") {
        Toggle("Read replies aloud", isOn: Binding(get: { model.product.readReplies }, set: { model.setReadReplies($0) }))
        Picker("Voice", selection: Binding(get: { model.product.defaultSpeech.identifier ?? "" }, set: { model.setSpeechVoice($0) })) {
          Text("Local English voice").tag("")
          ForEach(BlessengerAppleSpeech.voices(), id: \.identifier) { Text($0.name).tag($0.identifier) }
        }
      }
      Section("Library") {
        Button("New Contact") { Task { await model.newContact() } }
        Button("Export Conversation…") { model.exportConversation() }
      }
      HStack { Spacer(); Button("Done") { model.settingsOpen = false } }
    }.formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func rename(_ id: UUID) { let name = renameText; renameID = nil; Task { await model.rename(id, name: name) } }
  private struct IdentifiedID: Identifiable { let id: UUID }
}

private struct GlassControl: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 16, weight: .regular))
      .frame(width: 34, height: 34).background(.thinMaterial, in: Circle())
      .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 0.5))
      .opacity(configuration.isPressed ? 0.65 : 1)
  }
}
struct BlessengerPortrait: View {
  let id: UUID?
  let catalog: BlessengerCatalog
  var body: some View {
    Group {
      if let id, let cell = catalog.entries.first(where: { $0.id == id })?.portraitCell,
        let image = BlessengerPortraitCache.image(cell) { Image(nsImage: image).resizable().scaledToFill() }
      else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
    }.clipShape(Circle()).accessibilityHidden(true)
  }
}
@MainActor private enum BlessengerPortraitCache {
  static var images: [Int: NSImage] = [:]
  static func image(_ cell: Int) -> NSImage? {
    if let image = images[cell] { return image }
    guard (0..<14).contains(cell), let url = Bundle.module.url(forResource: "BlessengerPortraits", withExtension: "png"),
      let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = CGFloat(cg.width) / 4, height = CGFloat(cg.height) / 4
    guard let crop = cg.cropping(to: CGRect(x: CGFloat(cell % 4) * width, y: CGFloat(cell / 4) * height, width: width, height: height)) else { return nil }
    let result = NSImage(cgImage: crop, size: NSSize(width: width, height: height)); images[cell] = result
    return result
  }
}

struct BlessengerToField: NSViewRepresentable {
  @Binding var query: String
  let contacts: [BlessengerContact]
  let focus: Int
  let choose: (BlessengerContact) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSComboBox {
    let field = NSComboBox(); field.usesDataSource = false; field.isEditable = true
    field.completes = true; field.hasVerticalScroller = true; field.numberOfVisibleItems = 8
    field.font = .systemFont(ofSize: 14); field.isBordered = false
    field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.commit)
    field.setAccessibilityLabel("Add Contact")
    return field
  }
  func updateNSView(_ field: NSComboBox, context: Context) {
    context.coordinator.parent = self
    if context.coordinator.contacts != contacts {
      context.coordinator.contacts = contacts; field.removeAllItems(); field.addItems(withObjectValues: contacts.map(\.name))
    }
    if field.stringValue != query { field.stringValue = query }
    if context.coordinator.focus != focus {
      context.coordinator.focus = focus
      DispatchQueue.main.async { [weak field] in guard let field else { return }; field.window?.makeFirstResponder(field) }
    }
  }
  final class Coordinator: NSObject, NSComboBoxDelegate {
    var parent: BlessengerToField
    var contacts: [BlessengerContact] = []
    var focus = -1
    init(_ parent: BlessengerToField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSComboBox else { return }
      parent.query = field.stringValue
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSComboBox, contacts.indices.contains(field.indexOfSelectedItem) else { return }
      parent.choose(contacts[field.indexOfSelectedItem]); field.stringValue = ""
    }
    @objc func commit(_ field: NSComboBox) {
      guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      let value = field.stringValue
      let matches = contacts.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame || $0.handle.caseInsensitiveCompare(value.trimmingCharacters(in: CharacterSet(charactersIn: "@"))) == .orderedSame }
      if matches.count == 1 { parent.choose(matches[0]); field.stringValue = "" }
      else { parent.query = value }
    }
  }
}
