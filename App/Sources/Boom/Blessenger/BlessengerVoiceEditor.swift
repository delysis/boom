import AVFoundation
import BoomCore
import SwiftUI

/// One explicit edit draft bound to the selected Contact. Settings navigation
/// cannot retarget its eventual save, and Cancel never writes a preference.
struct BlessengerVoiceEdit: Identifiable {
  let id = UUID()
  let contactID: UUID?
  let title: String
  let expected: BlessengerSpeechVoice?
  let initial: BlessengerSpeechVoice
  init(contact: Voice?, product: BlessengerState) {
    contactID = contact?.id; title = contact?.name ?? "Default voice"
    if let contact { expected = product.speechVoices[contact.id] }
    else { expected = product.defaultSpeech }
    initial = expected ?? product.defaultSpeech
  }
}

struct BlessengerVoiceEditor: View {
  @ObservedObject var model: BlessengerModel
  let edit: BlessengerVoiceEdit
  let close: () -> Void
  @State private var voice: BlessengerSpeechVoice
  @State private var saving = false
  @State private var issue: String?
  init(model: BlessengerModel, edit: BlessengerVoiceEdit, close: @escaping () -> Void) {
    self.model = model; self.edit = edit; self.close = close
    _voice = State(initialValue: edit.initial)
  }
  private var provider: Binding<BlessengerSpeechVoice.Provider> {
    Binding(get: { voice.provider }, set: { value in
      if voice.provider != value { voice.provider = value; voice.identifier = nil }
    })
  }
  private var appleVoice: Binding<String> {
    Binding(get: { voice.identifier ?? "" }, set: { voice.identifier = $0.isEmpty ? nil : $0 })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Speech · " + edit.title).font(.headline)
      Text("Applies to future responses. Previously recorded audio keeps its original voice.")
        .font(.caption).foregroundStyle(.secondary)
      Picker("Provider", selection: provider) {
        Text("Qwen · local designed voice").tag(BlessengerSpeechVoice.Provider.qwen)
        Text("Apple · local English voice").tag(BlessengerSpeechVoice.Provider.apple)
      }.disabled(saving)
      if voice.provider == .qwen {
        Text("Designed voice description").font(.callout)
        ChatComposer(text: $voice.description, focusRequest: 0,
          onSend: { save(voice) }, onCancel: { if !saving { close() } },
          placeholder: "Describe the voice",
          accessibilityLabel: "Designed voice description; Command Return saves",
          onIssue: { issue = $0 }, maximumUTF8Bytes: 4096)
          .frame(height: 120).disabled(saving)
        Text("Describe delivery and timbre; this does not clone or claim the real person's voice. English is the supported profile.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Picker("Voice", selection: appleVoice) {
          Text("Local English default").tag("")
          ForEach(BlessengerAppleSpeech.voices(), id: \.identifier) { Text($0.name).tag($0.identifier) }
          if let selected = voice.identifier, !BlessengerAppleSpeech.voices().contains(where: { $0.identifier == selected }) {
            Text("Previously selected voice · unavailable").tag(selected)
          }
        }.disabled(saving)
      }
      if let issue { Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(saving)
        if edit.contactID != nil { Button("Use Default Voice") { save(nil) }.disabled(saving) }
        Spacer()
        if saving { ProgressView().controlSize(.small) }
        Button("Save") { save(voice) }.keyboardShortcut(.defaultAction)
          .disabled(saving || (try? BlessengerPolicy.validate(voice)) != true)
      }
    }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
  }
  private func save(_ replacement: BlessengerSpeechVoice?) {
    guard !saving else { return }
    saving = true; issue = nil
    Task { @MainActor in
      defer { saving = false }
      do {
        try await model.saveSpeechVoice(contactID: edit.contactID, expected: edit.expected, replacement: replacement)
        close()
      } catch { issue = error.localizedDescription }
    }
  }
}
