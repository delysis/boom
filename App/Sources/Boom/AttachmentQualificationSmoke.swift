import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// One exact-bundle journey for the checked-in, public attachment corpus.
/// The diagnostic never opens a human workspace, shared clipboard or window.
@MainActor enum AttachmentQualificationSmoke {
  struct Fixture: Decodable { let name: String; let kind: AttachmentKind; let needle: String? }
  struct Observation: Codable {
    let name: String
    let originalSHA256: String
    let kind: String
    let coverage: String
    let documentID: UUID?
    let documentAttachment: UUID?
    let chatID: UUID
    let chatAttachment: UUID
    var rawRecipe: CompletionRecipe?
    var writing: MLXGemmaRunner.Output?
    var consultation: MLXGemmaRunner.Output?
    var issue: String?
  }
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> URL {
      guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count,
        arguments[index + 1].hasPrefix("/") else { throw BoomError.invalid("Supply absolute fixture and fresh evidence directories.") }
      return URL(fileURLWithPath: arguments[index + 1])
    }
    let evidence = try argument("--evidence"), fixtures = try argument("--fixtures")
    guard !FileManager.default.fileExists(atPath: evidence.path) else { throw BoomError.invalid("Evidence already exists.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    var rows: [Observation] = []
    func save() throws { try encoder.encode(rows).write(to: evidence.appendingPathComponent("matrix.json"), options: .atomic) }
    var receipt = ["status":"running", "source": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unsealed", "keychain":"unused", "window":"unshown"]
    func saveReceipt() throws { try encoder.encode(receipt).write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic) }
    try saveReceipt()
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + .seconds(1800)); watchdog.setEventHandler { exit(2) }; watchdog.resume(); defer { watchdog.cancel() }
    let corpus = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: evidence.appendingPathComponent("public-workspace"), testKey: SymmetricKey(data: Data(repeating: 0x71, count: 32))), loadModels: false)
    model.state.autocomplete = false
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 1000))
    window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
    let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.clearContents() }
    func settle(_ ms: Int = 100) async throws { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(ms)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    func finish() async throws {
      for _ in 0..<6000 where model.isBusy { try await Task.sleep(for: .milliseconds(50)) }
      guard !model.isBusy, model.errorMessage == nil else { throw BoomError.invalid(model.errorMessage ?? "Import timed out.") }
      try await model.flush(); try await settle()
    }
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    func snapshot(_ stem: String) async throws {
      for dark in [true,false] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for width in [1440.0, 820.0] {
          window.setContentSize(NSSize(width: width, height: 1000)); model.fitPanes(to: width); try await settle()
          guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw BoomError.invalid("Bitmap unavailable.") }
          host.cacheDisplay(in: host.bounds, to: bitmap)
          guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("PNG unavailable.") }
          try png.write(to: evidence.appendingPathComponent("\(stem)-\(dark ? "dark" : "light")-\(Int(width)).png"), options: .atomic)
          let forbidden = all(host).compactMap { $0 as? NSButton }.filter { ["Extract text", "Prepare", "More", "…"].contains($0.title) && !$0.isHidden }
          guard forbidden.isEmpty else { throw BoomError.invalid("Unexpected permanent attachment chrome.") }
        }
      }
    }
    for (offset, fixture) in corpus.enumerated() {
      guard fixture.name == URL(fileURLWithPath: fixture.name).lastPathComponent else { throw BoomError.invalid("Fixture name is not a basename.") }
      let file = fixtures.appendingPathComponent(fixture.name), bytes = try Data(contentsOf: file)
      var documentAttachment: UUID?
      if model.layout.isAuthor {
        try model.newDocument()
        let document = model.selectedDocument!
        model.updateDocument("Before 🪶\n\nAfter", id: document.id, caret: 0)
        window.setContentSize(NSSize(width: 1440, height: 1000)); model.fitPanes(to: 1440); try await settle()
        guard let editor = model.editor, let layout = editor.layoutManager, let container = editor.textContainer else { throw BoomError.invalid("Native manuscript unavailable.") }
        let caret = "Before 🪶\n\n".utf16.count
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: caret), line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), position = layout.location(forGlyphAt: glyph)
        let point = editor.convert(NSPoint(x: editor.textContainerOrigin.x + line.minX + position.x + 0.1, y: editor.textContainerOrigin.y + line.midY), to: nil)
        board.clearContents(); board.writeObjects([file as NSURL])
        let drag = AttachmentDropFixture(board: board, point: point, window: window)
        guard editor.draggingEntered(drag) == .copy, editor.performDragOperation(drag) else { throw BoomError.invalid("Document rejected its native drop.") }
        try await finish()
        guard let current = model.selectedDocument, current.text.hasPrefix("Before 🪶\n\n[Attachment:"), current.text.hasSuffix("\nAfter"),
          let id = AttachmentLink.ids(in: current.text).first, model.pendingAttachments.isEmpty else { throw BoomError.invalid("Document drop lost its position or leaked into chat.") }
        documentAttachment = id
        try await snapshot(String(format: "%02d", offset) + "-document-" + fixture.name)
      }
      try model.newChat(); try await settle()
      guard let composer = all(host).compactMap({ $0 as? ChatTextView }).first(where: { $0.onAttachments != nil }) else { throw BoomError.invalid("Native composer unavailable.") }
      board.clearContents(); board.writeObjects([file as NSURL])
      let drag = AttachmentDropFixture(board: board, point: .zero, window: window)
      guard composer.draggingEntered(drag) == .copy, composer.performDragOperation(drag) else { throw BoomError.invalid("Chat rejected its native drop.") }
      try await finish()
      guard let record = model.state.attachments.last, model.pendingAttachments == [record.id],
        try model.store.vault.get(.attachment, id: record.id) == bytes else { throw BoomError.invalid("Chat drop lost its original or owner.") }
      let unsupported = ["video.mkv", "video.webm", "video.avi"].contains(fixture.name)
      guard record.kind == (unsupported ? .unavailable : fixture.kind) else { throw BoomError.invalid("Unexpected native capability: \(fixture.name).") }
      if let needle = fixture.needle, !record.text.contains(needle) { throw BoomError.invalid("Canonical text is missing: \(fixture.name).") }
      try await snapshot(String(format: "%02d", offset) + "-pending-" + fixture.name)
      model.draft = "Describe the attachment briefly."; model.authorChatMessage(.user); model.send(); try await finish()
      guard let chat = model.selectedChat, chat.messages.last?.directAttachments == [record.id], model.pendingAttachments.isEmpty else { throw BoomError.invalid("Attachment did not reach its chat bubble.") }
      try await snapshot(String(format: "%02d", offset) + "-bubble-" + fixture.name)
      rows.append(Observation(name: fixture.name, originalSHA256: record.rootDigest, kind: record.kind.rawValue, coverage: record.coverage,
        documentID: model.selectedDocument?.id, documentAttachment: documentAttachment, chatID: chat.id, chatAttachment: record.id))
      try save()
    }
    // Model qualification consumes each actual admitted original, not a mock or
    // an unrelated successful prompt. Preserve each output and every failure.
    guard let writingPack = ModelPacks.cached(.writing), let consultationPack = ModelPacks.cached(.consultation) else { throw BoomError.unavailable("Cached model packs unavailable.") }
    model.loadPack(writingPack,purpose:.writing); try await finish()
    model.loadPack(consultationPack,purpose:.consultation); try await finish()
    guard let writer = model.completionRunner, let assistant = model.selectedMLXRunner, assistant.supportsRawAudio else { throw BoomError.unavailable("Qualified native media models unavailable.") }
    for index in rows.indices where rows[index].kind != "unavailable" {
      do {
        let record = model.state.attachments.first { $0.id == rows[index].chatAttachment }!
        if [.audio, .video].contains(record.kind) {
          let owner = try MemoryMedia(bytes: try model.store.vault.get(.attachment, id: record.id))
          let player = try await owner.readyPlayer(flag: CancellationFlag())
          player.volume = 0; player.play(); try await Task.sleep(for: .milliseconds(200))
          let elapsed = player.currentTime().seconds
          player.pause()
          guard elapsed.isFinite, elapsed > 0 else { throw BoomError.invalid("Native playback did not advance.") }
          withExtendedLifetime(owner) {}
        }
        let source = "[Attachment: file](boom-attachment:\(record.id))\nThe attachment contains"
        let payloads = try await model.writingMedia(in: source, flag: CancellationFlag())
        let document = DocumentSnapshot(title:"Public attachment input",text:source)
        let recipe = try await writer.completionRecipe(document:document,caret:source.utf16.count,sources:payloads.map { $0.reference.source },
          examples:[],profile:.standard,maxTokens:8,flag:CancellationFlag(),media:payloads)
        try ProductCore.validateWritingRecipe(recipe); rows[index].rawRecipe = recipe
        rows[index].writing = try await writer.run(rawPrompt:recipe.prompt,media:payloads,maxTokens:8,seed:73,flag:CancellationFlag(),onText:{ _ in })
        let native = try await model.consultationMedia([record],rawAudio:true,flag:CancellationFlag())
        let context = record.text.isEmpty ? record.coverage : record.text
        let plan = try ProductCore.prompt(voice:nil,history:[],instructions:"",context:context,request:"Describe the attachment briefly.",routing:[])
        _ = try await assistant.preflight(plan,images:native.images,audio:native.audio,maxTokens:8,flag:CancellationFlag())
        rows[index].consultation = try await assistant.run(plan:plan,images:native.images,audio:native.audio,maxTokens:8,seed:73,flag:CancellationFlag(),onText:{ _ in })
      } catch { rows[index].issue = error.localizedDescription }
      try save()
    }
    // Exercise ordinary Send and pending-media consumption with actual audio,
    // rather than only the inference adapter used by the matrix above.
    let audio = model.state.attachments.first { $0.name == "tone.wav" }!
    try model.newChat(); model.pendingAttachments = [audio.id]; model.draft = "Describe the sound in one sentence."
    model.send(); try await finish()
    guard let chat = model.selectedChat, chat.messages.last?.state == .complete,
      chat.messages.first?.directAttachments == [audio.id], model.pendingAttachments.isEmpty else { throw BoomError.invalid("Native audio Send did not complete.") }
    try encoder.encode(chat).write(to:evidence.appendingPathComponent("real-audio-chat.json"),options:.atomic)
    try await snapshot("real-audio-chat")
    let state = model.state
    try await model.shutdown()
    let reopened = try await model.store.load().get()
    guard reopened.0.attachments == state.attachments, reopened.0.chats == state.chats else { throw BoomError.invalid("Encrypted attachment/chat recovery changed records.") }
    guard rows.allSatisfy({ $0.issue == nil }) else { receipt["status"]="failed"; try saveReceipt(); throw BoomError.invalid("One or more model input cells failed; all attempts retained.") }
    receipt["status"]="passed"; receipt["fixtures"]=String(rows.count); receipt["modelInputFixtures"]=String(rows.filter { $0.kind != "unavailable" }.count)
    receipt["writingModel"]=writer.identity; receipt["consultationModel"]=assistant.identity; try saveReceipt()
  }
}
