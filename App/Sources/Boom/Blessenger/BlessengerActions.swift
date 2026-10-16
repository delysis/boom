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
    guard !active.contains(id) else { report(BoomError.unavailable("Stop the active response before removing its conversation.")); return }
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
        state.chats.removeAll { $0.id == id }; product.drafts.removeAll { $0.id == id }
        product.addresses.removeValue(forKey: id)
        product.branches.removeValue(forKey: id)
        if state.selectedChat == id { state.selectedChat = nil; product.selectedTemplate = nil }
      }
    }
  }
  func branch(at messageID: UUID, replacement: String? = nil) async {
    guard let original = selected else { return }
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
    guard message.state != .pending else { return }
    let alert = NSAlert(); alert.messageText = "Edit on a new branch"
    alert.informativeText = "The original message and later replies remain unchanged."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260)), editor = NSTextView(frame: scroll.bounds)
    editor.isRichText = false; editor.string = message.text; editor.font = .systemFont(ofSize: 14); editor.allowsUndo = true
    scroll.documentView = editor; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
    alert.addButton(withTitle: "Save Branch"); alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { let text = editor.string; launch { await self.branch(at: message.id, replacement: text) } }
  }
  func pickAttachments() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { let inputs = panel.urls.map(AttachmentInput.file); launch { await self.importInputs(inputs) } }
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
    launch {
      let flag = CancellationFlag()
      let installed = try await ModelPacks.installPublished(.consultation, flag: flag) { _ in }
      await self.chooseModel(installed)
    }
  }
  func setReadReplies(_ value: Bool) { launch { await self.change { _, product in product.readReplies = value } } }
  func setSpeechVoice(_ id: String) {
    guard id.isEmpty || BlessengerAppleSpeech.voices().contains(where: { $0.identifier == id }) else { return }
    launch { await self.change { _, product in product.defaultSpeech.identifier = id.isEmpty ? nil : id } }
  }
  func exportConversation() {
    guard let chat = selected else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = chat.title + ".md"; panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    launch {
      try await ExplicitFileExport.write(to: destination) {
        let content = chat.messages.map { "## " + ($0.speaker?.name ?? ($0.role == .user ? "You" : "Blessenger")) + "\n\n" + $0.text }.joined(separator: "\n\n")
        return Data(("# " + chat.title + "\n\n" + content).utf8)
      }
    }
  }
  func preview(_ id: UUID) {
    guard let captured = state.attachments.first(where: { $0.id == id }) else { return }
    launch {
      let bytes = try await detachedWork { try self.store.vault.get(.attachment, id: id, limit: 67_108_864) }
      guard Digest.sha256(bytes) == captured.rootDigest,
        self.state.attachments.first(where: { $0.id == id })?.digest == captured.digest else { throw BoomError.stale("The attachment changed.") }
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = captured.name; window.isRestorable = false; window.disableSnapshotRestoration()
      if captured.kind == .image, let image = NSImage(data: bytes) {
        window.contentView = NSHostingView(rootView: Image(nsImage: image).resizable().scaledToFit().padding())
      } else {
        window.contentView = NSHostingView(rootView: NativeScrollableText(text: captured.text.isEmpty ? captured.coverage : captured.text, maximumHeight: 460).padding())
      }
      window.center(); window.makeKeyAndOrderFront(nil)
    }
  }
}
