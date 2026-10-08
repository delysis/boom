import AppKit
import BoomCore
import CryptoKit
import SwiftUI

/// Production inputs and real local weights in this process's own public,
/// encrypted fixture. No user windows, Keychain, or network access is needed.
@MainActor enum InputCompletionSmoke {
  static func run(arguments: [String]) async throws {
    guard let index = arguments.firstIndex(of: "--evidence"), index + 1 < arguments.count,
      arguments[index + 1].hasPrefix("/"), let pack = ModelPacks.cached(.consultation) else {
      throw BoomError.invalid("Use a fresh absolute evidence directory and cached consultation weights.")
    }
    let evidence = URL(fileURLWithPath: arguments[index + 1])
    guard !FileManager.default.fileExists(atPath: evidence.path) else { throw BoomError.invalid("Evidence already exists.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + .seconds(300)); watchdog.setEventHandler { exit(2) }
    watchdog.resume(); defer { watchdog.cancel() }
    func write<T: Encodable>(_ value: T, _ name: String) throws {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(value).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
    }
    var receipt = ["status": "running", "source": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unavailable"]
    try write(receipt, "receipt")
    let store = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("public-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 0x71, count: 32)))
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    model.authorChatMessage(.user); model.draft = "Suggest a title for a story set in a harbor. Answer in twelve words or fewer."; model.send()
    model.authorChatMessage(.assistant); model.draft = "The Lantern at Low Tide"; model.send()
    let parent = model.selectedChat!
    let host = NSHostingView(rootView: ChatPane(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 620, height: 900))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    func settle() async throws {
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    }
    func inputs(_ view: NSView) -> [ChatInputView] {
      if let view = view as? ChatInputView { return [view] }
      return view.subviews.flatMap(inputs)
    }
    func key(_ code: UInt16, _ text: ChatTextView) throws {
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else {
        throw BoomError.invalid("Native key event unavailable.")
      }
      text.keyDown(with: event)
    }
    func finishSuggestion(_ completion: TextInputCompletion, count: Int) async throws -> CandidateBundle {
      let started = ContinuousClock().now
      while true {
        if let bundle = completion.bundle, bundle.candidates.count == count,
          bundle.candidates.allSatisfy({ $0.state != .pending }) {
          guard bundle.candidates.allSatisfy({ $0.state == .complete && !$0.tokenIDs.isEmpty && !$0.text.isEmpty }) else {
            throw BoomError.invalid("A real input continuation failed; attempts retained.")
          }
          return bundle
        }
        guard started.duration(to: ContinuousClock().now) < .seconds(90) else {
          throw BoomError.unavailable("Input continuation timed out.")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    do {
      let admission = try await detachedWork { try ModelPacks.admission(pack, purpose: .consultation) }
      try await detachedWork { try ModelPacks.evidenceManifest(admission, purpose: .consultation) }
        .write(to: evidence.appendingPathComponent("model-manifest.json"))
      _ = try await model.openModel(pack, purpose: .consultation, flag: CancellationFlag())
      model.state.autocomplete = true
      for (name, message) in [("composer", Optional<ChatMessage>.none), ("user-edit", Optional(parent.messages[0])),
        ("assistant-edit", Optional(parent.messages[1]))] {
        model.editingChatMessage = message?.id
        try await settle()
        guard let input = inputs(host).first(where: { ($0.saveButton != nil) == (message != nil) }),
          let text = input.scroll.documentView as? ChatTextView,
          let completion = text.completionClient as? TextInputCompletion else {
          throw BoomError.invalid("The shared native input is missing during " + name)
        }
        window.makeFirstResponder(text)
        let authored = message == nil ? "The harbor at dusk was" : message!.text
        text.setAccessibilityValue(authored)
        text.setSelectedRange(NSRange(location: authored.utf16.count, length: 0))
        completion.schedule(delay: .zero)
        let single = try await finishSuggestion(completion, count: 1)
        try write(single, name + "-single")
        guard text.string == authored, completion.ghostStamp != nil else { throw BoomError.invalid("Ghost text changed canonical input.") }
        var expected = authored, remainder = single.candidates[0].text
        var steps: [(String, String)] = []
        for _ in 0..<3 where !remainder.isEmpty {
          let chunk = CompletionNavigation.nextChunk(remainder)
          steps.append((expected, remainder)); expected += chunk.accepted; remainder = chunk.remaining
          try key(124, text)
          guard text.string == expected, completion.ghostText == remainder else { throw BoomError.invalid("A real word acceptance lost its remainder.") }
        }
        for step in steps.reversed() {
          try key(123, text)
          guard text.string == step.0, completion.ghostText == step.1 else { throw BoomError.invalid("A real word reversal changed input bytes.") }
        }
        try key(125, text)
        let alternatives = try await finishSuggestion(completion, count: 3)
        try write(alternatives, name + "-alternatives")
        guard alternatives.recipe.promptDigest == single.recipe.promptDigest,
          alternatives.candidates[1].batch?.seeds.count == 2,
          alternatives.candidates[2].batch?.lane == 1 else { throw BoomError.invalid("Input alternatives lost their captured batch.") }
        try key(126, text)
        guard text.string == authored else { throw BoomError.invalid("Alternative navigation modified the input.") }
        completion.invalidateGhost()
        if message == nil {
          let typedPrefix = authored + " a lantern beyond the warehouse"
          text.setAccessibilityValue(typedPrefix)
          text.setSelectedRange(NSRange(location: typedPrefix.utf16.count, length: 0))
          completion.schedule(delay: .zero)
          let started = ContinuousClock().now
          while completion.bundle?.candidates.first?.outputTokens ?? 0 < 8 {
            guard started.duration(to: ContinuousClock().now) < .seconds(90) else { throw BoomError.unavailable("Interruption fixture timed out.") }
            try await Task.sleep(for: .milliseconds(50))
          }
          guard let interruptedID = completion.bundle?.id else { throw BoomError.invalid("Missing interruption identity.") }
          text.insertText(". Typed by me.", replacementRange: text.selectedRange())
          let explicit = text.string
          await completion.join()
          let interrupted = try await store.readCandidate(interruptedID)
          try write(interrupted, "composer-interrupted")
          guard text.string == explicit, completion.ghostStamp == nil,
            interrupted.candidates[0].outputTokens >= 8,
            [.cancelled, .complete].contains(interrupted.candidates[0].state) else {
            throw BoomError.invalid("Typing lost input bytes or the interrupted output.")
          }
        }
        if let button = input.cancelButton { button.performClick(nil) }
        model.editingChatMessage = nil
        guard model.state.chats.first(where: { $0.id == parent.id }) == parent else { throw BoomError.invalid("Inline completion implicitly saved the transcript.") }
      }
      model.state.autocomplete = false
      model.draft = ""; model.editingChatMessage = nil
      ChatMessageCommands(model: model, chatID: parent.id, message: parent.messages[0]).branch()
      let began = ContinuousClock().now
      while model.isBusy {
        guard began.duration(to: ContinuousClock().now) < .seconds(90) else { throw BoomError.unavailable("Reroll timed out.") }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let branch = model.selectedChat, branch.id != parent.id, branch.messages.count == 2,
        branch.messages[0].text == parent.messages[0].text, branch.messages[1].state == .complete,
        branch.messages[1].provider != nil, !branch.messages[1].text.isEmpty,
        model.state.chats.first(where: { $0.id == parent.id }) == parent else { throw BoomError.invalid("User reroll failed to create an independent real reply.") }
      try write(branch, "rerolled-chat")
      let reply = branch.messages[1], before = model.state.chats.count
      ChatMessageCommands(model: model, chatID: branch.id, message: reply).branch()
      guard !model.isBusy, model.state.chats.count == before + 1,
        model.selectedChat?.messages.last == reply else { throw BoomError.invalid("Assistant branching regenerated the preserved reply.") }
      try write(model.selectedChat, "preserved-reply-branch")
      try await model.shutdown()
      let saved = try await store.load().get().0
      for id in saved.candidateIDs { _ = try await store.readCandidate(id) }
      model.refreshModelChoices()
      for _ in 0..<100 where model.modelChoices.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
      guard !model.modelChoices.isEmpty else { throw BoomError.invalid("Model picker did not discover eligible weights.") }
      try write(model.modelChoices.map(\.candidate), "picker-choices")
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let pickerWindow = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 390, height: 540))
        pickerWindow.isReleasedWhenClosed = false
        pickerWindow.appearance = NSAppearance(named: appearance)
        // A sheet's hosting content is transparent; include the native sheet
        // background in the artifact instead of exporting black glyphs on alpha.
        let picker = NSHostingView(rootView: ModelPickerView(model: model)
          .environment(\.colorScheme, name == "light" ? .light : .dark)
          .background(Color(nsColor: .windowBackgroundColor)))
        pickerWindow.contentView = picker
        defer { pickerWindow.close() }
        picker.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); picker.layoutSubtreeIfNeeded()
        picker.displayIfNeeded()
        guard let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) else { throw BoomError.invalid("Picker bitmap unavailable.") }
        picker.cacheDisplay(in: picker.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Picker PNG unavailable.") }
        try png.write(to: evidence.appendingPathComponent("picker-" + name + ".png"))
      }
      receipt["status"] = "passed"; receipt["window"] = "unshown"; receipt["keychain"] = "unused"
      try write(receipt, "receipt")
    } catch {
      model.cancel(); try? await model.shutdown()
      receipt["status"] = "failed"; receipt["failure"] = error.localizedDescription
      try write(receipt, "receipt"); throw error
    }
  }
}
