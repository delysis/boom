import BoomCore
import SwiftUI

/// The same inline text editor serves chat instructions and authored exchanges.
struct ChatTextEditor: View {
  let label: String
  let save: (String) throws -> Void
  let cancel: () -> Void
  @State private var text: String
  @State private var failure: String?
  @State private var contentHeight: CGFloat = 22
  init(label: String, text: String, save: @escaping (String) throws -> Void, cancel: @escaping () -> Void) {
    self.label = label; self.save = save; self.cancel = cancel; _text = State(initialValue: text)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ChatComposer(text: $text, focusRequest: 1, onSend: commit, onCancel: cancel,
        placeholder: "", accessibilityLabel: label, lineSpacing: 3,
        onContentHeight: { contentHeight = $0 }, showsEditingActions: true)
        .frame(height: min(240, max(22, contentHeight)) + 32)
      if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
    }.padding(8)
      .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
  }
  private func commit() {
    nativeEditEvent("save requested")
    do { try save(text); nativeEditEvent("save completed") }
    catch { failure = error.localizedDescription; nativeEditEvent("save failed") }
  }
}
struct ChatInstructions: View {
  @ObservedObject var model: WorkspaceModel
  let chat: ChatRecord
  @State private var mention: String
  init(model: WorkspaceModel, chat: ChatRecord) {
    self.model = model; self.chat = chat
    _mention = State(initialValue: model.chatVoice(chat.id)?.slug ?? "")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Instructions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
      if model.chatVoice(chat.id) != nil {
        HStack(spacing: 4) {
          Text("@")
          TextField("Mention", text: $mention).frame(width: 160).accessibilityLabel("Chat mention")
          Spacer()
        }
      }
      ChatTextEditor(label: "Chat instructions", text: chat.instructions ?? "",
        save: { try model.setChatInstructions($0, mention: mention, chatID: chat.id) },
        cancel: { model.showingChatInstructions = nil })
    }
  }
}

struct WritingAlternatives: View {
  @ObservedObject var model: WorkspaceModel
  @State private var showingContext = false
  var body: some View {
    if let bundle = model.candidates {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Continuations").font(.headline)
          ForEach(Array(bundle.candidates.enumerated()), id: \.element.id) { index, candidate in
            Button { model.selectCandidate(index) } label: {
              HStack(spacing: 4) {
                Text("\(index + 1)")
                if candidate.state == .pending { ProgressView().controlSize(.mini) }
              }
            }.buttonStyle(.bordered)
              .tint(bundle.selected == index ? .accentColor : .secondary)
              .help("Continuation \(index + 1) · \(candidate.state.rawValue)")
              .accessibilityLabel("Continuation \(index + 1)")
          }
          Spacer(minLength: 0)
          Button { model.dismissCandidates() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).help("Dismiss continuations")
            .accessibilityLabel("Dismiss continuations")
        }
        if bundle.candidates.indices.contains(bundle.selected) {
          let candidate = bundle.candidates[bundle.selected]
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if !model.candidateIsCurrent {
                Text("The manuscript or cursor has changed. You can still branch from this captured continuation.")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Text(candidate.text.isEmpty ? emptyMessage(candidate) : candidate.text).accessibilityIdentifier("continuation-output")
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              if candidate.state == .cancelled || candidate.state == .failed {
                Text(candidate.state == .cancelled ? "Generation stopped. This partial continuation has been retained." : "This attempt has been retained. Try another set.")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { useButton(bundle, candidate); wordButton(bundle, candidate); Spacer(minLength: 0); moreMenu(bundle, candidate) }
            HStack(spacing: 8) { useButton(bundle, candidate); Spacer(minLength: 0); moreMenu(bundle, candidate) }
          }
        }
      }.padding(16)
        .background(Color.primary.opacity(0.025))
        .popover(isPresented: $showingContext) {
          VStack(alignment: .leading, spacing: 10) {
            Text(bundle.recipe.omittedPrefixCharacters == 0 ? "Complete preceding manuscript" : "\(bundle.recipe.omittedPrefixCharacters) earlier characters omitted")
              .font(.headline)
            Text("Text after the captured cursor was not supplied.").font(.caption)
            Text("Seed \(bundle.candidates[bundle.selected].seed) · \(bundle.recipe.profile.title)").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(bundle.recipe.prompt).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          }.padding(18).frame(width: 520, height: 420)
        }
    }
  }
  private func emptyMessage(_ candidate: WritingCandidate) -> String {
    switch candidate.state {
    case .pending: "Writing a continuation…"
    case .cancelled: "Stopped before any prose was produced."
    default: "The model ended this continuation before producing prose."
    }
  }
  private func useButton(_ bundle: CandidateBundle, _ candidate: WritingCandidate) -> some View {
    Button("Use continuation") { model.acceptCandidate(bundle.selected) }
      .disabled(model.isBusy || !model.candidateIsCurrent || candidate.state != .complete)
  }
  private func wordButton(_ bundle: CandidateBundle, _ candidate: WritingCandidate) -> some View {
    Button("Insert next word") { model.acceptCandidateWord(bundle.selected) }
      .disabled(model.isBusy || !model.candidateIsCurrent || candidate.state != .complete)
      .help("Option-Right accepts a word; Undo restores your manuscript")
  }
  private func moreMenu(_ bundle: CandidateBundle, _ candidate: WritingCandidate) -> some View {
    Menu("More") {
      Button("Insert next word") { model.acceptCandidateWord(bundle.selected) }
        .disabled(model.isBusy || !model.candidateIsCurrent || candidate.state != .complete)
      Button("Branch from this continuation") { model.branchCandidate(bundle.selected) }
        .disabled(model.isBusy || candidate.state != .complete)
      Button(candidate.batch == nil ? "Replay seed" : "Replay this set") { model.replayCandidate(bundle.selected) }
        .disabled(!model.canReplayCandidate(bundle.selected))
        .help("Replay is available when the original model settings are loaded")
      Divider()
      Button("Try three more") { model.exploreWriting() }.disabled(!model.canExploreWriting)
      Button("Supplied context…") { showingContext = true }
    }.fixedSize()
  }
}

struct WritingExamplesRequest: Identifiable {
  let id = UUID()
  let manuscriptID: UUID
}
struct WritingExamplesView: View {
  @ObservedObject var model: WorkspaceModel
  let request: WritingExamplesRequest
  @State private var adding = false
  @State private var title = ""
  @State private var prose = ""
  @State private var failure: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Writing examples").font(.title2)
      Text("Choose prose that suggests a voice or rhythm. Bloom reads these passages, in order, before your manuscript.")
        .foregroundStyle(.secondary)
      if !model.writingExampleIDs.isEmpty {
        Text("Included, in this order").font(.headline)
        ForEach(model.writingExampleIDs, id: \.self) { id in
          if let document = model.documents.first(where: { $0.id == id }) {
            HStack {
              Text(document.title); Spacer()
              Button { model.moveWritingExample(id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Read earlier")
                .disabled(model.writingExampleIDs.first == id)
              Button { model.moveWritingExample(id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Read later")
                .disabled(model.writingExampleIDs.last == id)
              Button("Remove") { model.toggleWritingExample(id) }
            }
          }
        }
      }
      if adding {
        TextField("Example title", text: $title).accessibilityLabel("Example title")
        TextEditor(text: $prose).frame(minHeight: 180).border(.secondary.opacity(0.2))
          .accessibilityLabel("Example prose")
        HStack {
          Text("Paste the passage itself; its title is only for your library.").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Add example") {
            do {
              try model.addWritingExample(title: title, prose: prose, manuscriptID: request.manuscriptID)
              title = ""; prose = ""; adding = false; failure = nil
            } catch { failure = error.localizedDescription }
          }.disabled(prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } else {
        let available = model.documents.filter { $0.id != request.manuscriptID && !model.writingExampleIDs.contains($0.id) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if available.isEmpty && model.writingExampleIDs.isEmpty {
          Text("No passages added yet.").foregroundStyle(.secondary)
        }
        if !available.isEmpty {
          Text("From your documents").font(.headline)
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(available) { document in
                Button { model.toggleWritingExample(document.id) } label: {
                  HStack(alignment: .top) {
                    Image(systemName: "plus.circle")
                    VStack(alignment: .leading, spacing: 4) {
                      Text(document.title).font(.headline)
                      Text(String(document.text.prefix(140))).lineLimit(2).foregroundStyle(.secondary)
                    }
                    Spacer()
                  }.contentShape(Rectangle())
                }.buttonStyle(.plain)
              }
            }
          }.frame(maxHeight: 180)
        }
        HStack {
          Button("Paste a passage…") { adding = true }
          Button("Import prose…") { model.importWritingExamples(manuscriptID: request.manuscriptID) }
        }
      }
      if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if adding { Button("Back") { adding = false; failure = nil } }
        Spacer()
        Button("Done") { model.editingWritingExamples = nil }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 580)
  }
}

struct BackupRequest: Identifiable {
  let id = UUID()
  let url: URL
  let restoring: Bool
}
struct BackupPassphraseView: View {
  @ObservedObject var model: WorkspaceModel
  let request: BackupRequest
  @State private var passphrase = ""
  @State private var confirmation = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(request.restoring ? "Restore complete backup" : "Encrypt complete backup").font(.title2)
      Text("Documents, chats, voices, branches, continuations, originals and receipts are included. Model weights are kept separately.")
        .font(.callout).foregroundStyle(.secondary)
      SecureField("Backup passphrase", text: $passphrase)
      if !request.restoring { SecureField("Repeat passphrase", text: $confirmation) }
      Text(request.restoring ? "Restore requires a fresh workspace. Existing authored data is retained." : "Keep this passphrase safe. It is independent of this Mac's Keychain key.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { model.backupRequest = nil }.keyboardShortcut(.cancelAction)
        Button(request.restoring ? "Restore" : "Export backup") {
          model.performBackup(request, passphrase: passphrase)
          passphrase = ""; confirmation = ""
        }.disabled(passphrase.utf8.count < 8 || (!request.restoring && passphrase != confirmation))
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 470)
  }
}
