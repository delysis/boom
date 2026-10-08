import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// Public controls: retain all outputs, including mistakes. Structural admission
/// and model understanding have separate receipts; nonempty text proves neither.
@MainActor enum VideoStoryboardSmoke {
  private actor BatchObservation {
    var value: MLXGemmaRunner.BatchMetrics?
    func record(_ metrics: MLXGemmaRunner.BatchMetrics) { value = metrics }
  }
  struct Observation: Codable {
    let variant: String
    let input: [WritingMediaReference]
    let writingRecipe: CompletionRecipe
    let consultationRequest: String
    var writing: MLXGemmaRunner.Output?
    var consultation: MLXGemmaRunner.Output?
    var issue: String?
  }
  static func run(arguments: [String]) async throws {
    func path(_ name: String) throws -> URL {
      guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else { throw BoomError.invalid("Supply absolute public fixture and fresh evidence paths.") }
      return URL(fileURLWithPath: arguments[i + 1])
    }
    let evidence = try path("--evidence"), fixture = try path("--fixture")
    guard !FileManager.default.fileExists(atPath: evidence.path) else { throw BoomError.invalid("Evidence exists.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    var receipt = ["status": "running", "source": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unsealed", "semanticReview": "pending"]
    func saveReceipt() throws { try encoder.encode(receipt).write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic) }
    try saveReceipt()
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: evidence.appendingPathComponent("public-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 0x71, count: 32))), loadModels: false)
    model.state.autocomplete = false
    func finish() async throws {
      for _ in 0..<6000 where model.isBusy { try await Task.sleep(for: .milliseconds(50)) }
      guard !model.isBusy, model.errorMessage == nil else { throw BoomError.invalid(model.errorMessage ?? "Public operation timed out.") }
      try await model.flush()
    }
    if model.selectedChat == nil { try model.newChat() }
    model.attachToCurrentChat([.bytes(name: fixture.lastPathComponent, data: try Data(contentsOf: fixture))]); try await finish()
    guard let record = model.state.attachments.last, let writingPack = ModelPacks.cached(.writing),
      let consultationPack = ModelPacks.cached(.consultation) else { throw BoomError.unavailable("Local fixtures or packs unavailable.") }
    let link = "[Attachment: video](boom-attachment:\(record.id))"
    let cold = ProcessInfo.processInfo.systemUptime
    let full = try await model.writingMedia(in: link, flag: CancellationFlag())
    receipt["coldPreparationSeconds"] = String(ProcessInfo.processInfo.systemUptime - cold)
    let warm = ProcessInfo.processInfo.systemUptime
    let repeatInput = try await model.writingMedia(in: link, flag: CancellationFlag())
    receipt["warmPreparationSeconds"] = String(ProcessInfo.processInfo.systemUptime - warm)
    guard full.map(\.reference) == repeatInput.map(\.reference), full.count == 1, full[0].audioSegments.count > 0 else { throw BoomError.invalid("Storyboard cache or sound control changed.") }
    model.loadPack(writingPack, purpose: .writing); try await finish()
    model.loadPack(consultationPack, purpose: .consultation); try await finish()
    guard let writer = model.completionRunner, let assistant = model.selectedMLXRunner else { throw BoomError.unavailable("Local models unavailable.") }
    receipt["writingModel"] = writer.identity; receipt["consultationModel"] = assistant.identity
    var silent = full[0]; silent.reference.video?.audio = []; silent.reference.video?.soundtrackOmitted = true; silent.audioSegments = []
    let sound = WritingMediaData(reference: WritingMediaReference(id: record.id, name: "Public soundtrack", rootDigest: record.rootDigest, kind: "audio"),
      bytes: Data(), samples: full[0].audioSegments.flatMap { $0 })
    var observations: [Observation] = []
    func save() throws { try encoder.encode(observations).write(to: evidence.appendingPathComponent("outputs.json"), options: .atomic) }
    for (variant, payloads) in [("full", full), ("frames-only", [silent]), ("sound-only", [sound])] {
      let source = link + "\nThe sequence of colors and the spoken words were:"
      let document = DocumentSnapshot(title: "Public storyboard control", text: source)
      let recipe = try await writer.completionRecipe(document: document, caret: source.utf16.count, sources: payloads.map { $0.reference.source },
        examples: [], profile: .standard, maxTokens: 128, flag: CancellationFlag(), media: payloads)
      let request = variant == "sound-only" ? "Transcribe the following speech segment in English into English text. Only output the transcription, with no newlines."
        : "State the colors in order, then transcribe the speech in English exactly, using the speaker's words."
      observations.append(Observation(variant: variant, input: payloads.map(\.reference), writingRecipe: recipe, consultationRequest: request))
      try save()
      do {
        observations[observations.count - 1].writing = try await writer.run(rawPrompt: recipe.prompt, media: payloads, maxTokens: 128,
          seed: 73, flag: CancellationFlag(), onText: { _ in })
        try save()
        let plan = try ProductCore.prompt(voice: nil, history: [], instructions: "", context: "",
          request: request, routing: [])
        observations[observations.count - 1].consultation = try await assistant.run(plan: plan, images: [], media: payloads, maxTokens: 128,
          seed: 73, flag: CancellationFlag(), onText: { _ in })
      } catch { observations[observations.count - 1].issue = error.localizedDescription }
      try save()
    }
    let captured = observations[0].writingRecipe
    let metrics = BatchObservation()
    let candidates = try await writer.runBatch(rawPrompt: captured.prompt, media: full, maxTokens: 32,
      settings: captured.settings, seeds: [73, 74, 75], flag: CancellationFlag(), onMetrics: { await metrics.record($0) })
    try encoder.encode(candidates).write(to: evidence.appendingPathComponent("batch.json"), options: .atomic)
    let replay = try await writer.runBatch(rawPrompt: captured.prompt, media: full, maxTokens: 32,
      settings: captured.settings, seeds: [73, 74, 75], flag: CancellationFlag())
    try encoder.encode(replay).write(to: evidence.appendingPathComponent("batch-replay.json"), options: .atomic)
    guard candidates.count == 3, candidates.map(\.tokenIDs) == replay.map(\.tokenIDs),
      let observed = await metrics.value, observed.width == 3 else { throw BoomError.invalid("Multimodal batch or seeded replay changed.") }
    try encoder.encode(observed).write(to: evidence.appendingPathComponent("batch-metrics.json"), options: .atomic)
    if model.layout.isAuthor {
      try model.newDocument()
      guard let document = model.selectedDocument else { throw BoomError.invalid("Public manuscript unavailable.") }
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 1000))
      window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
      let text = link + "\nMara watched the recording and said, \""
      model.updateDocument(text, id: document.id, caret: text.utf16.count)
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
      guard let editor = model.editor else { throw BoomError.invalid("Native manuscript surface unavailable.") }
      window.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
      model.state.autocomplete = true; model.scheduleCompletion()
      for _ in 0..<1200 {
        if model.candidates?.candidates.first?.state != .pending, model.candidates != nil { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let candidate = model.candidates, candidate.recipe.media == full.map(\.reference),
        !model.ghostText.isEmpty, model.selectedDocument?.text == text else { throw BoomError.invalid("Video ghost did not reach the unchanged native manuscript.") }
      try encoder.encode(candidate).write(to: evidence.appendingPathComponent("automatic-video-candidate.json"), options: .atomic)
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw BoomError.invalid("Native ghost bitmap unavailable.") }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: evidence.appendingPathComponent("automatic-video.png"), options: .atomic)
      model.state.autocomplete = false; model.invalidateGhost()
      receipt["automaticVideoGhost"] = "passed; manuscript unchanged; window unshown"
    }
    receipt["status"] = observations.allSatisfy { $0.issue == nil } ? "structurally-passed" : "failed"
    try saveReceipt(); try await model.shutdown()
    guard observations.allSatisfy({ $0.issue == nil }) else { throw BoomError.invalid("Public model controls failed; all outputs retained.") }
  }
}
