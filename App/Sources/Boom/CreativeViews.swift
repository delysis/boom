import AppKit
import BoomCore
import SwiftUI

/// The same inline text editor serves chat instructions and authored exchanges.
struct ChatTextEditor: View {
  let label: String
  let save: (String) throws -> Void
  let cancel: () -> Void
  var completionModel: WorkspaceModel? = nil
  var completionTarget: TextInputTarget? = nil
  @State private var text: String
  @State private var textVersion = UUID()
  @State private var failure: String?
  @State private var contentHeight: CGFloat = 22
  init(label: String, text: String, completionModel: WorkspaceModel? = nil,
    completionTarget: TextInputTarget? = nil,
    save: @escaping (String) throws -> Void, cancel: @escaping () -> Void) {
    self.label = label; self.save = save; self.cancel = cancel; _text = State(initialValue: text)
    self.completionModel = completionModel; self.completionTarget = completionTarget
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ChatComposer(text: Binding(get: { text }, set: { text = $0; textVersion = UUID() }),
        focusRequest: 1, onSend: commit, onCancel: cancel,
        placeholder: "", accessibilityLabel: label, lineSpacing: 3,
        onContentHeight: { contentHeight = $0 }, showsEditingActions: true,
        completionModel: completionModel, completionTarget: completionTarget, textVersion: textVersion,
        currentTextVersion: { textVersion })
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
        completionModel: model, completionTarget: TextInputTarget(chatID: chat.id,
          documentID: nil, instructions: true),
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
              NativeText(candidate: candidate).accessibilityIdentifier("continuation-output")
                .frame(maxWidth: .infinity, alignment: .leading)
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
            ScrollView { NativeText(text: bundle.recipe.prompt, presentation: .literal, pointSize: 12).frame(maxWidth: .infinity, alignment: .leading) }
          }.padding(18).frame(width: 520, height: 420)
        }
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
      Button("Replay", systemImage: "arrow.counterclockwise") { model.replayCandidate(bundle.selected) }
        .disabled(!model.canReplayCandidate(bundle.selected))
        .accessibilityLabel(candidate.batch == nil ? "Replay continuation" : "Replay alternatives")
        .help(candidate.executionOrigin?.isConfirmedCold(promptTokens: candidate.promptTokens) == true
          ? "Reproduce the saved run with the same model"
          : "The original run cannot yet be reproduced")
      Divider()
      Button("Try three more") { model.exploreWriting() }.disabled(!model.canExploreWriting)
      Button("Supplied context…") { showingContext = true }
      if !model.savedExplorations.isEmpty {
        Menu("Saved explorations") {
          ForEach(model.savedExplorations) { exploration in
            Button(exploration.preview) { model.reviewContinuation(exploration.id) }
          }
        }.disabled(model.isBusy)
      }
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
  @State private var previewID: UUID?
  @State private var previewHasProse = false
  @State private var adding = false
  @State private var importing = false
  @State private var title = ""
  @State private var prose = ""
  @State private var proseVersion = UUID()
  @State private var failure: String?
  @State private var showingFailure = false

  private var included: [DocumentSnapshot] {
    model.writingExampleIDs.compactMap { id in model.documents.first { $0.id == id } }
  }
  private var available: [DocumentSnapshot] {
    model.documents.filter {
      $0.id != request.manuscriptID && !model.writingExampleIDs.contains($0.id) && !$0.text.isEmpty
    }
  }
  private var preview: DocumentSnapshot? {
    model.documents.first { $0.id == previewID }
  }
  private var canChange: Bool {
    !model.isBusy && !model.editingLocked && model.state.selectedDocument == request.manuscriptID
      && model.documents.contains { $0.id == request.manuscriptID }
  }
  private var canAdd: Bool {
    canChange && model.writingExampleIDs.count < 32 && prose.contains { !$0.isWhitespace }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Examples").font(.headline)
          .help("Bloom reads the included passages in order before your manuscript.")
          .accessibilityHint("Bloom reads the included passages in order before your manuscript.")
        Text("\(model.writingExampleIDs.count)/32").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityLabel("\(model.writingExampleIDs.count) of 32 examples")
        Spacer()
        if importing { ProgressView().controlSize(.small).accessibilityLabel("Importing examples") }
        if let failure {
          Button { showingFailure = true } label: { Image(systemName: "exclamationmark.triangle") }
            .help(failure).accessibilityLabel("Example error").accessibilityHint(failure)
        }
        Button { adding = true; failure = nil } label: { Image(systemName: "square.and.pencil") }
          .disabled(!canChange || adding || model.writingExampleIDs.count >= 32)
          .help("New example").accessibilityLabel("New example")
        Button(action: importExamples) { Image(systemName: "square.and.arrow.down") }
          .disabled(!canChange || adding || model.writingExampleIDs.count >= 32)
          .help("Import prose").accessibilityLabel("Import prose")
      }.buttonStyle(.borderless).controlSize(.small).padding(16)
      Divider()
      if adding || !included.isEmpty || !available.isEmpty {
        HStack(spacing: 0) {
          selector.frame(width: 200).disabled(adding)
          Divider()
          Group {
            if adding { draftEditor }
            else { passagePreview }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxHeight: .infinity)
      } else {
        Image(systemName: "doc.text")
          .font(.system(size: 28)).foregroundStyle(.tertiary)
          .accessibilityLabel("No examples")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack {
        if adding {
          Button("Back", action: back).keyboardShortcut(.cancelAction)
            .help("Keep the draft and return to examples").accessibilityLabel("Back to examples")
        }
        Spacer()
        if adding {
          Button("Add", action: addExample).disabled(!canAdd).keyboardShortcut(.defaultAction)
        } else {
          Button("Done") { model.editingWritingExamples = nil }.keyboardShortcut(.defaultAction)
        }
      }.padding(12)
    }
    .frame(width: 640, height: adding || !included.isEmpty || !available.isEmpty ? 400 : 176)
    .onAppear { previewID = model.writingExampleIDs.first ?? available.first?.id }
    .onChange(of: preview?.textVersion, initial: true) { _, _ in
      // A local source identity avoids rescanning every document on status updates.
      previewHasProse = preview?.text.contains { !$0.isWhitespace } ?? false
    }
    .onChange(of: model.writingExampleIDs) { _, ids in
      if previewID == nil { previewID = ids.first ?? available.first?.id }
    }
    .onChange(of: model.isBusy) { _, busy in
      if importing && !busy { importing = false; failure = model.writingIssue }
    }
    .onExitCommand {
      if adding { back() } else { model.editingWritingExamples = nil }
    }
    .alert("Examples", isPresented: $showingFailure) {
      Button("OK", role: .cancel) {}
    } message: { Text(failure ?? "") }
  }

  private var selector: some View {
    List(selection: $previewID) {
      if !included.isEmpty {
        Section("Included") {
          ForEach(Array(included.enumerated()), id: \.element.id) { index, document in
            HStack(spacing: 8) {
              Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
              Text(document.title).lineLimit(1)
            }.tag(document.id).help(document.title)
              .accessibilityLabel("Example \(index + 1), \(document.title)")
          }
        }
      }
      if !available.isEmpty {
        Section("Documents") {
          ForEach(available) { document in
            Text(document.title).lineLimit(1).tag(document.id).help(document.title)
          }
        }
      }
    }.listStyle(.sidebar).accessibilityLabel("Writing examples and documents")
  }

  @ViewBuilder private var passagePreview: some View {
    if let document = preview {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Text(document.title).font(.headline).lineLimit(1).help(document.title)
          Spacer(minLength: 8)
          if model.writingExampleIDs.contains(document.id) {
            Button { move(document.id, by: -1) } label: { Image(systemName: "arrow.up") }
              .disabled(!canChange || model.writingExampleIDs.first == document.id)
              .help("Read earlier").accessibilityLabel("Move example earlier")
            Button { move(document.id, by: 1) } label: { Image(systemName: "arrow.down") }
              .disabled(!canChange || model.writingExampleIDs.last == document.id)
              .help("Read later").accessibilityLabel("Move example later")
            Button { remove(document.id) } label: { Image(systemName: "minus.circle") }
              .disabled(!canChange)
              .help("Remove from examples; keep the document").accessibilityLabel("Remove from examples")
          } else {
            Button { include(document) } label: { Image(systemName: "plus.circle") }
              .disabled(!canChange || !previewHasProse || model.writingExampleIDs.count >= 32)
              .help("Include as the last example").accessibilityLabel("Include example")
          }
        }.buttonStyle(.borderless).controlSize(.small)
        WritingExamplePassage(document: document)
          .accessibilityLabel("Example prose").frame(maxWidth: .infinity, maxHeight: .infinity)
      }.padding(16)
    } else {
      Color.clear.accessibilityLabel("No example selected")
    }
  }
  private var draftEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Title", text: $title).textFieldStyle(.roundedBorder)
        .accessibilityLabel("Example title").help("The title is only for your library.")
      ChatComposer(text: Binding(get: { prose }, set: { prose = $0; proseVersion = UUID() }),
        focusRequest: 1, onSend: addExample, onCancel: back,
        placeholder: "Prose", accessibilityLabel: "Example prose", textVersion: proseVersion,
        currentTextVersion: { proseVersion })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }.padding(16)
  }
  private func back() { adding = false; failure = nil }
  private func move(_ id: UUID, by delta: Int) {
    guard canChange else { return }
    model.moveWritingExample(id, by: delta)
  }
  private func remove(_ id: UUID) {
    guard canChange, model.writingExampleIDs.contains(id) else { return }
    model.toggleWritingExample(id)
  }
  private func include(_ document: DocumentSnapshot) {
    guard canChange, document.id != request.manuscriptID,
      !model.writingExampleIDs.contains(document.id), model.writingExampleIDs.count < 32,
      model.documents.contains(where: { $0.id == document.id && $0.textVersion == document.textVersion }),
      document.text.contains(where: { !$0.isWhitespace }) else { return }
    model.toggleWritingExample(document.id)
  }
  private func addExample() {
    guard canAdd else { return }
    do {
      try model.addWritingExample(title: title, prose: prose, manuscriptID: request.manuscriptID)
      previewID = model.writingExampleIDs.last
      title = ""; prose = ""; proseVersion = UUID(); adding = false; failure = nil
    } catch { failure = error.localizedDescription }
  }
  private func importExamples() {
    guard canChange, model.writingExampleIDs.count < 32 else { return }
    failure = nil; model.writingIssue = nil; importing = true
    model.importWritingExamples(manuscriptID: request.manuscriptID)
    if !model.isBusy { importing = false }
  }
}

/// Reuse the native reader/viewport; only the selected local source identity
/// changes its text. Reorder and operation-status updates preserve the reader.
private struct WritingExamplePassage: NSViewRepresentable {
  let document: DocumentSnapshot
  final class Coordinator {
    var documentID: UUID?
    var textVersion: UUID?
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NativeTextScrollView { NativeTextScrollView() }
  func updateNSView(_ view: NativeTextScrollView, context: Context) {
    let ownerChanged = context.coordinator.documentID != document.id
    guard ownerChanged || context.coordinator.textVersion != document.textVersion else { return }
    view.reader.setSource(document.text)
    context.coordinator.documentID = document.id; context.coordinator.textVersion = document.textVersion
    if ownerChanged { view.contentView.scroll(to: .zero); view.reflectScrolledClipView(view.contentView) }
    view.needsLayout = true
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
      Text(request.restoring ? "Restore" : "Backup").font(.title2)
        .help("Documents, chats, voices, branches, continuations, originals and receipts are included. Model weights are kept separately.")
        .accessibilityHint("Documents, chats, voices, branches, continuations, originals and receipts are included. Model weights are kept separately.")
      SecureField("Passphrase", text: $passphrase)
        .accessibilityLabel("Backup passphrase")
        .help(request.restoring ? "Restore requires a fresh workspace. Existing authored data is retained." : "Keep this passphrase safe. It is independent of this Mac's Keychain key.")
        .accessibilityHint(request.restoring ? "Restore requires a fresh workspace. Existing authored data is retained." : "Keep this passphrase safe. It is independent of this Mac's Keychain key.")
      if !request.restoring {
        SecureField("Repeat", text: $confirmation).accessibilityLabel("Repeat passphrase")
      }
      HStack {
        Spacer()
        Button("Cancel") { model.backupRequest = nil }.keyboardShortcut(.cancelAction)
        Button(request.restoring ? "Restore" : "Export") {
          model.performBackup(request, passphrase: passphrase)
          passphrase = ""; confirmation = ""
        }.accessibilityLabel(request.restoring ? "Restore" : "Export backup")
          .disabled(passphrase.utf8.count < 8 || (!request.restoring && passphrase != confirmation))
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 470)
  }
}
