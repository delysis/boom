import AppKit
import AVFoundation
import SwiftUI

/// The same model-owned settings, divided at visible sections rather than one
/// enormous generic expression. No shadow copy of the execution profile.
struct BlessengerSettings: View {
  @ObservedObject var model: BlessengerModel
  var body: some View {
    Form {
      modelSection
      speechSection
      appearanceSection
      librarySection
      HStack { Spacer(); Button("Done") { model.settingsOpen = false } }
    }.formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var mtpSelection: Binding<String> {
    Binding(get: { model.effectiveProfile.useMTP.map { $0 ? "on" : "off" } ?? "calls" }, set: { value in
      let enabled: Bool? = value == "calls" ? nil : value == "on"
      Task { await model.setProfile(mtp: .some(enabled)) }
    })
  }
  private var modelSection: some View {
  Section("Local model") {
    Text(model.effectiveProfile.modelPath ?? "Verified local model cache")
      .font(.caption).textSelection(.enabled)
    HStack {
      Button("Choose…") { model.pickModel() }
      Button("Use Cache") { Task { await model.clearModel() } }
      Button("Install…") { model.installModel() }
    }
    Picker("Sampling", selection: Binding(get: { model.effectiveProfile.sampling }, set: { value in Task { await model.setProfile(sampling: value) } })) {
      ForEach(SamplingProfile.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    Picker("MTP assistant", selection: mtpSelection) {
      Text("Calls only").tag("calls"); Text("On").tag("on"); Text("Off · comparison").tag("off")
    }
    Button("Install MTP Assistant…") { model.installVoicePackage(.mtp) }
  }.disabled(model.loading || model.isCalling || model.callStarting || !model.active.isEmpty)
  }
  private var speechSection: some View {
  Section("Speech") {
    Toggle("Read text replies aloud", isOn: Binding(get: { model.product.readReplies }, set: model.setReadReplies))
    Picker("Provider", selection: Binding(get: { model.product.defaultSpeech.provider }, set: model.setSpeechProvider)) {
      Text("Qwen · local designed voice").tag(BlessengerSpeechVoice.Provider.qwen)
      Text("Apple · local system voice").tag(BlessengerSpeechVoice.Provider.apple)
    }
    if model.product.defaultSpeech.provider == .apple {
      Picker("Voice", selection: Binding(get: { model.product.defaultSpeech.identifier ?? "" }, set: model.setSpeechVoice)) {
        Text("Local English voice").tag("")
        ForEach(BlessengerAppleSpeech.voices(), id: \.identifier) { Text($0.name).tag($0.identifier) }
      }
    }
    HStack {
      Button("Install Qwen…") { model.installVoicePackage(.qwen) }
      Button("Install Turn Detector…") { model.installVoicePackage(.turn) }
    }
    if model.loading {
      HStack { ProgressView().controlSize(.small); Text(model.setupProgress ?? "Preparing").font(.caption); Button("Cancel") { model.stop() } }
    }
  }
  }
  private var appearanceSection: some View {
  Section("Appearance and input") {
    Picker("Appearance", selection: Binding(get: { model.state.theme }, set: model.setTheme)) {
      Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
    }
    Toggle("Inline suggestions", isOn: Binding(get: { model.state.autocomplete }, set: model.setAutocomplete))
    Text("Suggestions use the already loaded local model. Right Arrow accepts a word; Escape dismisses. Nothing is sent automatically.").font(.caption).foregroundStyle(.secondary)
  }
  }
  private var librarySection: some View {
  Section("Library") {
    Button("New Contact") { Task { await model.newContact() } }
    Button("Export Readable Transcript…") { model.exportConversation() }.disabled(model.selected == nil)
    Button("Back Up Private Workspace…") { model.backupWorkspace(restoring: false) }
    Button("Restore Backup to New Folder…") { model.backupWorkspace(restoring: true) }
    Button("Recover Unstored Draft") { model.recoverDraft() }.disabled(!model.hasDraftFailure)
  }
  }
}
