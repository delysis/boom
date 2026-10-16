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
  @State private var instructionsOpen = false
  init(model: BlessengerModel) { self.model = model; audio = model.audio }
  var body: some View {
    HSplitView {
      sidebar.frame(minWidth: 180, idealWidth: 255, maxWidth: 390)
      VStack(spacing: 0) {
        header
        Divider()
        issueBar
        if model.isCalling || model.callStarting { callBar }
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
    .sheet(isPresented: $details) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Details").font(.headline)
        NativeScrollableText(text: model.failure ?? audio.error ?? model.callIssue ?? "", maximumHeight: 300).frame(minWidth: 360)
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
  @ViewBuilder private var issueBar: some View {
    if model.failure != nil || audio.error != nil || model.callIssue != nil {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
        Button("Attention · Show Details") { details = true }.buttonStyle(.plain)
        Spacer()
        Button { model.dismissFailure() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
      }.padding(10).background(Color(nsColor: .controlBackgroundColor))
    }
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
    let isSpoken = model.product.spokenResponses?[message.id] != nil
    let storedAudio = model.product.audio[message.id]
    let playable = storedAudio != nil || audio.hasPlayableAudio(message.id)
    return HStack(alignment: .bottom, spacing: 8) {
      if outgoing { Spacer(minLength: 40) }
      else if !isSpoken || playable {
        BlessengerPortrait(id: message.speaker?.voiceID, catalog: model.catalog).frame(width: 32, height: 32)
      }
      VStack(alignment: .leading, spacing: 6) {
        if !outgoing, (!isSpoken || playable), let name = message.speaker?.name { Text(name).font(.caption).foregroundStyle(.secondary) }
        if message.state == .pending && (text.isEmpty || (isSpoken && !playable)) {
          ProgressView().controlSize(.small).padding(5).accessibilityLabel("Preparing response")
        } else if isSpoken {
          if let storedAudio {
            HStack {
              Button { model.replayAudio(message.id) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain).disabled(model.isCalling || model.preparing || !model.active.isEmpty)
                .accessibilityLabel("Replay recorded response")
              Text(Duration.seconds(Double(storedAudio.frames) / Double(storedAudio.sampleRate)), format: .time(pattern: .minuteSecond))
                .monospacedDigit().font(.callout)
            }
          }
          if !text.isEmpty { DisclosureGroup("Transcript") { NativeText(text: text) } }
        } else if !text.isEmpty { NativeText(text: text) }
        ForEach(message.directAttachments ?? [], id: \.self) { id in
          if let attachment = model.state.attachments.first(where: { $0.id == id }) {
            Button { model.preview(id) } label: { Label(attachment.name, systemImage: attachment.kind == .audio ? "waveform" : "paperclip") }
              .buttonStyle(.plain).help("Open attachment")
          }
        }
        if message.state == .cancelled { Text("Interrupted").font(.caption).foregroundStyle(.secondary) }
        if message.state == .failed {
          Label("Incomplete", systemImage: "exclamationmark.circle").font(.caption)
          if let reason = message.failure { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
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
          if !outgoing { Button("Regenerate on a Branch") { model.regenerate(message.id) } }
          if outgoing { Button("Answer on a Branch") { model.answerAgain(message.id) } }
          Button("Edit") { model.editMessage(message) }
        }
      if !outgoing { Spacer(minLength: 40) }
    }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 7) {
      if !model.draft.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(model.draft.attachments, id: \.self) { id in
              if let item = model.state.attachments.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                  Button { model.preview(id) } label: { Label(item.name, systemImage: item.kind == .audio ? "waveform" : "paperclip") }
                    .buttonStyle(.plain)
                  Button { model.removeAttachment(id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Remove " + item.name)
                }.padding(7).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
              }
            }
          }
        }
      }
      if model.hasUnstoredVoiceNote {
        HStack {
          Text("The recording has not been saved.").font(.callout)
          Button("Retry") { model.retryVoiceNote() }
          Button("Discard", role: .destructive) { model.discardUnstoredVoiceNote() }
        }
      }
      if model.templateSelected {
        Picker("Example speaker", selection: $model.exampleRole) {
          Text("You").tag(Role.user); Text("Contact").tag(Role.assistant)
        }.pickerStyle(.segmented).frame(maxWidth: 230)
      }
      HStack(alignment: .bottom, spacing: 10) {
        if !model.templateSelected {
          Button { model.pickAttachments() } label: { Image(systemName: "plus") }
            .buttonStyle(GlassControl()).accessibilityLabel("Add attachment")
            .disabled(model.navigating || model.noteState != .idle)
        }
        ChatComposer(text: Binding(get: { model.draft.text }, set: model.editText), focusRequest: model.composerFocus,
          onSend: { if model.templateSelected { model.appendExample() } else { model.send() } }, onCancel: { model.stop() },
          onAttachments: model.templateSelected ? nil : { inputs in Task { _ = await model.importInputs(inputs) } },
          accessibilityLabel: "Message; Return sends, Shift Return inserts a line break",
          onContentHeight: { composerHeight = min(180, max(28, $0)) },
          onIssue: { model.report(BoomError.invalid($0)) },
          onNativeInput: { model.inputCompletion.observe($0) },
          onNativeDetach: { model.inputCompletion.invalidateGhost() }, sendsOnReturn: true, maximumUTF8Bytes: 2_097_152)
          .disabled(model.navigating).frame(height: composerHeight)
          .padding(.horizontal, 8).padding(.vertical, 5)
          .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 18))
        if !model.templateSelected && !model.isCalling {
          Button { model.toggleVoiceNote() } label: { Image(systemName: model.noteState == .recording ? "stop.circle" : "mic") }
            .buttonStyle(GlassControl())
            .disabled(model.noteState == .preparing || model.noteState == .stopping || model.navigating || model.callStarting)
            .accessibilityLabel(model.noteState == .recording ? "Stop recording for review" : "Record voice note")
          if model.noteState != .idle {
            Button { model.cancelVoiceNote() } label: { Image(systemName: "xmark") }
              .buttonStyle(GlassControl()).accessibilityLabel("Cancel recording")
          }
        }
        Button {
          if model.templateSelected { model.appendExample() }
          else if selectedBusy { model.stop() }
          else { model.send() }
        } label: { Image(systemName: selectedBusy ? "stop.fill" : "arrow.up") }
          .buttonStyle(GlassControl())
          .disabled(model.templateSelected ? model.draft.text.isEmpty || model.navigating : !model.canSend && !selectedBusy)
          .accessibilityLabel(selectedBusy ? "Stop response" : model.templateSelected ? "Append example" : "Send")
      }
    }.padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 8)
  }
  private var selectedBusy: Bool { model.preparing || model.state.selectedChat.map { model.active.contains($0) } == true }
  private var callBar: some View {
    HStack(spacing: 12) {
      if !model.callReady { ProgressView().controlSize(.small) }
      Text(model.callReady ? (model.callMuted ? "Muted" : "Listening") : "Preparing call").font(.callout)
      Spacer()
      Button { model.setCallMuted(!model.callMuted) } label: { Image(systemName: model.callMuted ? "mic.slash.fill" : "mic.fill") }
        .accessibilityLabel(model.callMuted ? "Unmute microphone" : "Mute microphone")
        .disabled(!model.callReady)
      Button("Send Turn") { model.submitCallTurn() }.disabled(!model.callReady || model.callMuted)
      Button { model.toggleCall() } label: { Image(systemName: "phone.down.fill") }.accessibilityLabel("End call")
    }.padding(.horizontal, 18).padding(.vertical, 8).background(.quaternary)
  }
  private var template: some View {
    VStack(alignment: .leading, spacing: 0) {
      DisclosureGroup("Instructions", isExpanded: $instructionsOpen) {
        ChatComposer(text: $instructions, focusRequest: 0,
          onSend: { Task { await model.updateInstructions(instructions) } }, onCancel: { instructions = model.selected?.instructions ?? "" },
          accessibilityLabel: "Contact instructions; Command Return saves", showsEditingActions: true)
          .frame(minHeight: 90, maxHeight: 230)
      }.padding(14)
      transcript
      composer
    }.onAppear { instructions = model.selected?.instructions ?? "" }
      .onChange(of: model.state.selectedChat) { _, _ in instructions = model.selected?.instructions ?? "" }
  }
  private var settings: some View { BlessengerSettings(model: model) }
  private func rename(_ id: UUID) { let name = renameText; renameID = nil; Task { await model.rename(id, name: name) } }
  private struct IdentifiedID: Identifiable { let id: UUID }
}

private struct GlassControl: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceTransparency) private var opaque
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 16, weight: .regular))
      .frame(width: 34, height: 34)
      .background { if opaque { Circle().fill(Color(nsColor: .controlBackgroundColor)) } else { Circle().fill(.thinMaterial) } }
      .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 0.5))
      .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
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
