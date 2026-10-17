import AppKit
import AVFoundation
import BoomCore
import SwiftUI
import UniformTypeIdentifiers

extension BlessengerModel {
  var visibleChats: [ChatRecord] {
    state.chats.reversed().filter { chat in
      !state.voices.contains(where: { $0.id == chat.id }) && (searchIDs?.contains(chat.id) ?? true)
    }
  }
  var visibleContacts: [Voice] { state.voices.filter { searchIDs?.contains($0.id) ?? true } }
  func rename(_ id: UUID, name: String) async {
    guard let original = state.chats.first(where: { $0.id == id }) else { return }
    await change { state, product in
      let value = try ProductCore.chatText(name)
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= 120,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        let index = state.chats.firstIndex(where: { $0.id == id }),
        state.chats[index].title.utf8.elementsEqual(original.title.utf8) else { throw BoomError.stale("The item name changed.") }
      state.chats[index].title = value
      if let old = state.voices.first(where: { $0.id == id }) {
        let voice = try ProductCore.pinnedVoice(state.chats[index], slug: old.slug, occupied: state.voices.filter { $0.id != id }.map(\.slug))
        state.voiceVersions.append(old); state.voices.removeAll { $0.id == id }; state.voices.append(voice)
      }
    }
  }
  func pin(_ id: UUID) async {
    await change { state, _ in
      guard let chat = state.chats.first(where: { $0.id == id }) else { throw BoomError.stale("The conversation was removed.") }
      let prior = state.voices.first { $0.id == id }
      let voice = try ProductCore.pinnedVoice(chat, slug: prior?.slug, occupied: state.voices.filter { $0.id != id }.map(\.slug))
      if let prior, prior.revision != voice.revision { state.voiceVersions.append(prior) }
      state.voices.removeAll { $0.id == id }; state.voices.append(voice)
    }
  }
  func newContact() async {
    let id = UUID()
    await change(restoreDraft: true) { state, product in
      let name = "New Contact", slug = try ProductCore.suggestedSlug(name, occupied: state.voices.map(\.slug))
      let chat = ChatRecord(id: id, title: name, instructions: "")
      let voice = try ProductCore.pinnedVoice(chat, slug: slug, occupied: state.voices.map(\.slug))
      state.chats.append(chat); state.voices.append(voice); state.selectedChat = id
      product.selectedTemplate = id; product.drafts.append(BlessengerDraft(id: id))
    }
  }
  func updateInstructions(_ text: String) async {
    guard let original = selected else { return }
    await change { state, _ in
      let admitted = try ProductCore.chatText(text, instructions: true)
      guard let index = state.chats.firstIndex(where: { $0.id == original.id }),
        (state.chats[index].instructions ?? "").utf8.elementsEqual((original.instructions ?? "").utf8) else {
        throw BoomError.stale("The conversation instructions changed.")
      }
      state.chats[index].instructions = admitted
      if let prior = state.voices.first(where: { $0.id == original.id }) {
        let voice = try ProductCore.pinnedVoice(state.chats[index], slug: prior.slug,
          occupied: state.voices.filter { $0.id != prior.id }.map(\.slug))
        if voice.revision != prior.revision { state.voiceVersions.append(prior) }
        state.voices.removeAll { $0.id == prior.id }; state.voices.append(voice)
      }
    }
  }
  func remove(_ id: UUID) async {
    guard !callInProgress, !active.contains(id) else { report(BoomError.unavailable("Stop the active response before removing its conversation.")); return }
    await change(restoreDraft: true) { state, product in
      guard !product.attempts.values.contains(where: { $0.conversationID == id }) else { throw BoomError.unavailable("The conversation is still settling a response.") }
      if let contact = state.voices.first(where: { $0.id == id }) {
        state.voiceVersions.append(contact); state.voices.removeAll { $0.id == id }
        product.removedCatalog.insert(id)
        for index in product.drafts.indices where product.drafts[index].recipients.contains(where: { $0.id == id }) {
          product.drafts[index].recipients.removeAll { $0.id == id }; product.drafts[index].version = UUID()
        }
        // Unpinning preserves the source conversation and historic membership.
        if product.selectedTemplate == id { product.selectedTemplate = nil }
      } else {
        product.removeConversation(id, from: &state)
      }
    }
  }
  func branch(at messageID: UUID, replacement: String? = nil, in capturedChat: ChatRecord? = nil) async {
    guard let original = capturedChat ?? selected else { return }
    await change(restoreDraft: true) { state, product in
      guard let source = state.chats.first(where: { $0.id == original.id }),
        try BlessengerPolicy.exactDigest(source) == BlessengerPolicy.exactDigest(original),
        let index = source.messages.firstIndex(where: { $0.id == messageID }),
        source.messages.prefix(index + 1).allSatisfy({ $0.state != .pending }) else {
        throw BoomError.stale("Finish or stop pending responses before branching this history.")
      }
      var branch = try source.branch(at: messageID, includeMessage: true)
      if let replacement {
        let previous = branch.messages[index]
        let admitted = try ProductCore.chatText(replacement)
        branch.messages[index] = ChatMessage(role: previous.role, text: admitted, context: previous.context,
          sources: previous.sources, provider: previous.provider, speaker: previous.speaker,
          authoredByUser: true, editedFrom: previous.id, directAttachments: previous.directAttachments,
          consultationRouting: previous.consultationRouting, consultationPromptContract: previous.consultationPromptContract)
        branch.messageVersions = [previous]
      }
      state.chats.append(branch); state.selectedChat = branch.id; product.selectedTemplate = nil
      product.drafts.append(BlessengerDraft(id: branch.id)); product.branches[branch.id] = source.id
      product.addresses[branch.id] = product.addresses[source.id]
    }
  }
  func editMessage(_ message: ChatMessage) {
    guard message.state != .pending, let chat = selected, chat.messages.contains(where: { $0.id == message.id }) else { return }
    let alert = NSAlert(); alert.messageText = "Edit on a new branch"
    alert.informativeText = "The original message and later replies remain unchanged."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260)), editor = NSTextView(frame: scroll.bounds)
    editor.isRichText = false; editor.string = message.text; editor.font = .systemFont(ofSize: 14); editor.allowsUndo = true
    scroll.documentView = editor; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
    alert.addButton(withTitle: "Save Branch"); alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { let text = editor.string; launch { await self.branch(at: message.id, replacement: text, in: chat) } }
  }
  func pickAttachments() {
    let destination = draft.id, version = draft.version
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { let inputs = panel.urls.map(AttachmentInput.file); launch {
      guard self.draft.id == destination, self.draft.version == version else { throw BoomError.stale("The attachment picker destination changed. Nothing was attached.") }
      await self.importInputs(inputs)
    } }
  }
  func pickModel() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url { launch { await self.chooseModel(url) } }
  }
  func installModel() {
    let alert = NSAlert(); alert.messageText = "Install the local consultation model?"
    alert.informativeText = "This explicitly downloads the pinned public model into the shared Hugging Face cache. Your conversations and microphone audio are not uploaded."
    alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    runSetup { flag, progress in _ = try await ModelPacks.installPublished(.consultation, flag: flag, progress: progress) }
  }
  func installVoicePackage(_ kind: BlessengerModelPackage.Kind) {
    let alert = NSAlert(); alert.messageText = "Install the local \(kind.rawValue) model?"
    alert.informativeText = "This downloads only the pinned public model into the shared cache. No case text or audio is uploaded."
    alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    runSetup { flag, progress in _ = try await BlessengerModelPackage.package(kind).install(flag: flag, progress: progress) }
  }
  func setReadReplies(_ value: Bool) { launch { await self.change { _, product in product.readReplies = value } } }
  func setSpeechProvider(_ provider: BlessengerSpeechVoice.Provider) {
    launch { await self.change { _, product in product.defaultSpeech.provider = provider; product.defaultSpeech.identifier = nil } }
  }
  func setSpeechVoice(_ id: String) {
    guard id.isEmpty || BlessengerAppleSpeech.voices().contains(where: { $0.identifier == id }) else { return }
    launch { await self.change { _, product in
      product.defaultSpeech.provider = .apple; product.defaultSpeech.identifier = id.isEmpty ? nil : id
    } }
  }
  func appendExample() {
    guard templateSelected, let captured = selected, !draft.text.isEmpty else { return }
    let submitted = draft, role = exampleRole
    launch {
      await self.change(restoreDraft: true) { state, product in
        guard let c = state.chats.firstIndex(where: { $0.id == captured.id }),
          let d = product.drafts.firstIndex(where: { $0.id == submitted.id }), product.drafts[d] == submitted,
          let previous = state.voices.first(where: { $0.id == captured.id }) else { throw BoomError.stale("The Contact source changed.") }
        let text = try ProductCore.chatText(submitted.text)
        state.chats[c].messages.append(ChatMessage(role: role, text: text,
          speaker: role == .assistant ? previous.speaker : Speaker(name: "You"), authoredByUser: true))
        let voice = try ProductCore.pinnedVoice(state.chats[c], slug: previous.slug, occupied: state.voices.filter { $0.id != previous.id }.map(\.slug))
        if voice.revision != previous.revision { state.voiceVersions.append(previous) }
        state.voices.removeAll { $0.id == previous.id }; state.voices.append(voice)
        product.drafts[d] = BlessengerDraft(id: submitted.id)
      }
    }
  }
  func exportConversation() {
    guard let chat = selected else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = chat.title + ".md"; panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    launch {
      try await ExplicitFileExport.write(to: destination) {
        let content = chat.messages.map { "## " + ($0.speaker?.name ?? ($0.role == .user ? "You" : "Blessenger")) + "\n\n" + $0.text + ($0.state == .complete ? "" : "\n\n[" + $0.state.rawValue + "]") }.joined(separator: "\n\n")
        return Data(("# " + chat.title + "\n\nReadable transcript only. This is not a restorable backup.\n\n" + content).utf8)
      }
    }
  }
  func openSource(_ source: SourceReference, from messageID: UUID) {
    guard let chat = selected, let owner = chat.messages.first(where: { $0.id == messageID }),
      owner.sources.contains(source) else { report(BoomError.stale("The source occurrence changed.")); return }
    do {
      try BlessengerSources.validate([source], in: state, conversationID: chat.id)
      if source.kind == "attachment" { preview(source.id); return }
      guard source.kind == BlessengerSources.consultation,
        let reply = chat.messages.first(where: { $0.id == source.id }) else { return }
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = source.title; window.isRestorable = false; window.disableSnapshotRestoration()
      window.contentView = NSHostingView(rootView: NativeScrollableText(text: reply.text, maximumHeight: 460).padding())
      window.center(); window.makeKeyAndOrderFront(nil)
    } catch { report(error) }
  }
  func showResponseContext(_ message: ChatMessage) {
    guard message.role == .assistant, message.provider != nil, message.state != .pending else { return }
    launch {
      let receipt = try await detachedWork {
        try self.store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: message.id)
      }
      guard receipt.responseID == message.id, receipt.model == message.provider else {
        throw BoomError.stale("The response's captured context is not available.")
      }
      let summary: String
      if let window = receipt.contextWindow {
        summary = "Context selection\n\(window.units.count) whole earlier input/reply units included; \(window.omittedUnits) omitted (\(window.omittedMessages) messages).\n"
          + "\(window.sourceIds.count) original sources, \(window.mediaOccurrences) chronological media occurrences.\n"
          + "Omission reason: \(window.reason ?? "none"). Original conversation records are unchanged.\n\n"
      } else { summary = "This earlier response has no recorded context-window summary.\n\n" }
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = "Response Context"; window.isRestorable = false; window.disableSnapshotRestoration()
      window.contentView = NSHostingView(rootView: NativeScrollableText(text: summary + receipt.plan.rawPrompt, maximumHeight: 460).padding())
      window.center(); window.makeKeyAndOrderFront(nil)
    }
  }
  func preview(_ id: UUID) {
    guard let captured = state.attachments.first(where: { $0.id == id }) else { return }
    openMediaReview(captured)
  }
}
