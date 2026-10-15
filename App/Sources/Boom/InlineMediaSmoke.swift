import AppKit
import AVFoundation
import AVKit
import BoomCore
import Foundation
import SwiftUI

/// Public fixture only. Captures the production media/editor surface and the
/// actual raw vision/audio tensors in a cached base checkpoint, offline.
@MainActor enum InlineMediaSmoke {
  static func run(arguments: [String]) async throws {
    guard let index = arguments.firstIndex(of: "--evidence"), index + 1 < arguments.count,
      let fixturesIndex = arguments.firstIndex(of: "--fixtures"), fixturesIndex + 1 < arguments.count,
      arguments[index + 1].hasPrefix("/"), arguments[fixturesIndex + 1].hasPrefix("/"),
      let pack = ModelPacks.cached(.writing) else { throw BoomError.invalid("Use a fresh --evidence directory, --fixtures directory and cached writing pack.") }
    let evidence = URL(fileURLWithPath: arguments[index + 1]), fixtures = URL(fileURLWithPath: arguments[fixturesIndex + 1])
    guard !FileManager.default.fileExists(atPath: evidence.path) else { throw BoomError.invalid("Evidence already exists.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + .seconds(600)); watchdog.setEventHandler { exit(2) }; watchdog.resume(); defer { watchdog.cancel() }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    func save<T: Encodable>(_ value: T, _ name: String) throws { try encoder.encode(value).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic) }
    var receipt = ["status": "running", "source": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unavailable"]
    try save(receipt, "receipt")
    let model = try await WorkspaceModel(storeOverride: WorkspaceStore(rootOverride: evidence.appendingPathComponent("public-workspace")), loadModels: false)
    model.state.autocomplete = false
    func finish() async throws {
      for _ in 0..<1200 where model.isBusy { try await Task.sleep(for: .milliseconds(100)) }
      guard !model.isBusy, model.errorMessage == nil else { throw BoomError.invalid(model.errorMessage ?? "Media operation timed out.") }
      try await model.flush()
    }
    func image(_ color: NSColor) throws -> Data {
      let value = NSImage(size: NSSize(width: 720, height: 420)); value.lockFocus()
      color.setFill(); NSRect(x: 0, y: 0, width: 720, height: 420).fill()
      NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 70, width: 280, height: 280)).fill(); value.unlockFocus()
      guard let tiff = value.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Public image unavailable.") }
      return data
    }
    let red = try image(.systemRed), blue = try image(.systemBlue)
    let audio = try Data(contentsOf: fixtures.appendingPathComponent("local-audio.m4a"))
    let video = try Data(contentsOf: fixtures.appendingPathComponent("local-video.mp4"))
    if let document = model.selectedDocument {
      try await NativeCheckEvidence.replacePublicDocument(model, text: "Before the picture.\n\nAfter the picture.\n", id: document.id, caret: 0)
      guard let destination = model.documentAttachmentDestination(id: document.id,
        range: NSRange(location: "Before the picture.\n\n".utf16.count, length: 0)) else { throw BoomError.invalid("No document target.") }
      model.attach([.bytes(name: "Public image.png", data: red)], to: destination); try await finish()
    } else { model.attachToCurrentChat([.bytes(name: "Public image.png", data: red)]); try await finish() }
    let picture = model.state.attachments[0]
    model.attachToCurrentChat([.bytes(name: "Public tone.m4a", data: audio), .bytes(name: "Public video.mp4", data: video)]); try await finish()
    guard let audioRecord = model.state.attachments.first(where: { $0.name == "Public tone.m4a" }),
      let videoRecord = model.state.attachments.first(where: { $0.name == "Public video.mp4" }),
      audioRecord.kind == .audio, videoRecord.kind == .video else {
      throw BoomError.invalid("The actual stored audio/video attachments are unavailable.")
    }
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 1000))
    window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
    func settle() async throws { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    for dark in [true, false] {
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      for width in [1440.0, 820.0, 1100.0, 1440.0] {
        window.setContentSize(NSSize(width: width, height: 1000)); model.fitPanes(to: width)
        try await settle()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw BoomError.invalid("Native media bitmap unavailable.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Native PNG unavailable.") }
        try png.write(to: evidence.appendingPathComponent("\(dark ? "dark" : "light")-\(Int(width)).png"), options: .atomic)
      }
    }
    // Exercise the actual stored-record/native-owner route at each available
    // width. Its production card cap remains real even in a wider viewport.
    @MainActor func attachmentReader(in view: NSView) -> NativeReadingTextView? {
      if let reader = view as? NativeReadingTextView { return reader }
      for child in view.subviews { if let reader = attachmentReader(in: child) { return reader } }
      return nil
    }
    for (record, kind) in [(audioRecord, "audio"), (videoRecord, "video")] {
      let controller = NSHostingController(rootView: InlineAttachmentView(model: model, record: record))
      let playerHost = controller.view
      let playerWindow = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 680, height: 400))
      playerWindow.isReleasedWhenClosed = false; playerWindow.contentView = playerHost

      @MainActor func closePlayer() async throws {
        defer { playerWindow.contentView = nil; playerWindow.close() }
        if let reader = attachmentReader(in: playerHost) {
          reader.inlineMedia.stop()
          if let cleanup = await reader.inlineMedia.joinPendingLoads() { throw cleanup }
        }
      }
      @MainActor func readyPlayer(at width: CGFloat) async throws {
        let clock = ContinuousClock(), started = clock.now
        while started.duration(to: clock.now) < .seconds(5) {
          try Task.checkCancellation()
          let fitting = controller.sizeThatFits(in: NSSize(width: width, height: 1000))
          guard fitting.width.isFinite, fitting.width > 0, fitting.width <= width + 0.5,
            fitting.height.isFinite, fitting.height > 0, fitting.height <= 1000 else {
            throw BoomError.invalid("The actual attachment card has invalid fitting geometry.")
          }
          playerWindow.setContentSize(NSSize(width: width, height: ceil(fitting.height)))
          playerHost.layoutSubtreeIfNeeded()
          if let reader = attachmentReader(in: playerHost) {
            reader.inlineMedia.positionViews()
            await reader.inlineMedia.joinPendingLoads()
            if let failure = reader.inlineMedia.lastFailure { throw failure }
            try Task.checkCancellation()
            guard started.duration(to: clock.now) < .seconds(5) else { break }
            playerHost.layoutSubtreeIfNeeded(); reader.inlineMedia.positionViews()
            if let media = reader.subviews.compactMap({ $0 as? InlineMediaHost }).first,
              let native = media.subviews.compactMap({ $0 as? AVPlayerView }).first,
              let player = native.player, let current = player.currentItem {
              if let failure = player.error { throw failure }
              if let failure = current.error { throw failure }
              guard player.status != .failed, current.status != .failed else {
                throw BoomError.unavailable("The actual native attachment player failed.")
              }
              if player.status == .readyToPlay, current.status == .readyToPlay {
                guard reader.window === playerWindow, media.superview === reader,
                  media.item.record == record, model.state.attachments.contains(record),
                  let range = media.sourceRange, reader.inlineMedia.currentRanges.contains(range),
                  let file = media.item.file, let asset = media.item.asset,
                  let currentAsset = current.asset as? AVURLAsset,
                  currentAsset.url == file.url, asset.url == file.url,
                  media.bounds.width > 0, media.bounds.height > 0,
                  playerHost.bounds.insetBy(dx: -0.5, dy: -0.5).contains(media.convert(media.bounds, to: playerHost)),
                  media.bounds.insetBy(dx: -0.5, dy: -0.5).contains(native.frame) else {
                  throw BoomError.stale("The actual ready player lost its stored source or was clipped by its fitted card.")
                }
                playerHost.displayIfNeeded()
                return
              }
            }
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        throw BoomError.unavailable("The actual native attachment player did not become ready within five seconds.")
      }
      do {
        for dark in [true, false] {
          playerWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
          for width in [144.0, 300.0, 680.0] {
            try await readyPlayer(at: width)
            guard let bitmap = playerHost.bitmapImageRepForCachingDisplay(in: playerHost.bounds) else { throw BoomError.invalid("Player bitmap unavailable.") }
            playerHost.cacheDisplay(in: playerHost.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Player PNG unavailable.") }
            try png.write(to: evidence.appendingPathComponent("\(kind)-\(dark ? "dark" : "light")-\(Int(width)).png"), options: .atomic)
          }
        }
      } catch {
        let original = error
        do { try await closePlayer() }
        catch { throw NativeInlineMediaCleanupFailure(original: original, cleanup: error) }
        throw original
      }
      try await closePlayer()
    }
    model.loadPack(pack, purpose: .writing); try await finish()
    guard let runner = model.completionRunner else { throw BoomError.invalid("Writing runner unavailable.") }
    let redReference = WritingMediaReference(id: picture.id, name: picture.name, rootDigest: picture.rootDigest, kind: "image")
    let blueReference = WritingMediaReference(id: UUID(), name: "Public blue.png", rootDigest: Digest.sha256(blue), kind: "image")
    let redInput = WritingMediaData(reference: redReference, bytes: red), blueInput = WritingMediaData(reference: blueReference, bytes: blue)
    let audioInput = try await model.writingMedia(in: "[Attachment: sound](boom-attachment:\(audioRecord.id))", flag: CancellationFlag())
    struct Trial: Encodable { let name: String; let media: [WritingMediaReference]; let prompt: String; let seeds: [UInt64]; let outputs: [MLXGemmaRunner.Output] }
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioInput[0].samples.count)),
      let samples = buffer.floatChannelData?[0] else { throw BoomError.invalid("Silence fixture unavailable.") }
    buffer.frameLength = buffer.frameCapacity
    samples.initialize(repeating: 0, count: Int(buffer.frameLength))
    let silentBytes = try RecordedClip.wav(buffer)
    let silence = [WritingMediaData(reference: WritingMediaReference(id: UUID(), name: "Public silence.wav",
      rootDigest: Digest.sha256(silentBytes), kind: "audio"), bytes: silentBytes,
      samples: Array(repeating: 0, count: Int(buffer.frameLength)))]
    var trials: [Trial] = []
    for (name, media, raw) in [
      ("red-image-batch", [redInput], "<bos><|image|>\nThe picture shows"),
      ("blue-image-counterfactual", [blueInput], "<bos><|image|>\nThe picture shows"),
      ("audio-waveform", audioInput, "<bos><|audio|>\nThe sound is"),
      ("audio-silence-counterfactual", silence, "<bos><|audio|>\nThe sound is"),
      ("image-and-audio", [redInput] + audioInput, "<bos><|image|>\n<|audio|>\nThe image and the sound")
    ] {
      let seeds: [UInt64] = name == "red-image-batch" ? [41, 42, 43] : [41]
      let outputs = try await runner.runBatch(rawPrompt: raw, media: media, maxTokens: 64,
        settings: ProductCore.sampling(.standard), seeds: seeds, flag: CancellationFlag())
      trials.append(Trial(name: name, media: media.map(\.reference), prompt: raw, seeds: seeds, outputs: outputs))
      try save(trials, "real-model-trials")
      guard outputs.allSatisfy({ $0.promptTokens > 20 && !$0.tokenIDs.isEmpty }) else { throw BoomError.invalid("Multimodal generation failed; every attempt retained.") }
    }
    let replay = try await runner.runBatch(rawPrompt: "<bos><|image|>\nThe picture shows", media: [redInput], maxTokens: 64,
      settings: ProductCore.sampling(.standard), seeds: [41, 42, 43], flag: CancellationFlag())
    try save(replay, "image-batch-replay")
    guard replay.map(\.tokenIDs) == trials[0].outputs.map(\.tokenIDs),
      trials[0].outputs[0].tokenIDs != trials[1].outputs[0].tokenIDs,
      trials[2].outputs[0].tokenIDs != trials[3].outputs[0].tokenIDs else {
      throw BoomError.invalid("Media sensitivity or batch replay failed; all outputs retained.")
    }
    // The manuscript path must generate automatically after the same image,
    // retain media identities in the recipe, and leave authored bytes intact.
    if let editor = model.pagedInput?.activeView, let document = model.selectedDocument {
      let text = document.text + "\nThe picture shows"
      try await NativeCheckEvidence.replacePublicDocument(model, text: text, id: document.id, caret: text.utf16.count); try await settle()
      window.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
      model.state.autocomplete = true; model.scheduleCompletion()
      for _ in 0..<1200 {
        if model.candidates?.candidates.first?.state != .pending, model.candidates != nil { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let candidate = model.candidates, candidate.recipe.media?.contains(redReference) == true,
        !model.ghostText.isEmpty, model.selectedDocument?.text == text else { throw BoomError.invalid("Automatic media continuation did not reach the manuscript; evidence retained.") }
      try save(candidate, "automatic-image-candidate")
      model.state.autocomplete = false; model.invalidateGhost()
    }
    try await model.shutdown()
    receipt["status"] = "passed"; receipt["window"] = "unshown"; receipt["workspaceStorage"] = "files"
    receipt["model"] = runner.identity; try save(receipt, "receipt")
  }
}
