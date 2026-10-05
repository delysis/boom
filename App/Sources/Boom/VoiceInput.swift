import AppKit
import AVFoundation
import BoomCore
import Speech

@MainActor final class VoiceInput: ObservableObject {
  enum Purpose { case conversation, dictation }
  @Published private(set) var purpose: Purpose?
  @Published private(set) var starting = false
  @Published private(set) var transcribing = false
  private var engine: AVAudioEngine?
  private var recording: RecordedAudio?
  private var deadline: Task<Void, Never>?
  private var transcriptionFlag: CancellationFlag?
  private var generation = 0
  private let speaker = AVSpeechSynthesizer()

  var isRecording: Bool { engine != nil }

  func start(_ purpose: Purpose) async throws {
    guard engine == nil, !starting, !transcribing else { return }
    starting = true
    let capturedGeneration = generation
    defer { starting = false }
    if #available(macOS 26.0, *) {
      _ = try await readyDictationModule()
    } else {
      try await authorizeLegacySpeech()
    }
    guard generation == capturedGeneration else { throw CancellationError() }
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      throw BoomError.denied("Microphone access was not granted.")
    }
    guard generation == capturedGeneration else { throw CancellationError() }
    let engine = AVAudioEngine(), recording = RecordedAudio()
    let input = engine.inputNode, format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in recording.append(buffer) }
    do { try engine.start() }
    catch { input.removeTap(onBus: 0); throw error }
    self.engine = engine; self.recording = recording; self.purpose = purpose
    deadline = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
      guard self?.engine === engine else { return }
      engine.stop()
    }
  }

  func stop() async throws -> String {
    guard let engine, let recording else { return "" }
    let capturedGeneration = generation
    engine.stop(); engine.inputNode.removeTap(onBus: 0)
    deadline?.cancel(); deadline = nil
    self.engine = nil; self.recording = nil; purpose = nil
    let flag = CancellationFlag(); transcriptionFlag = flag
    transcribing = true
    defer { transcribing = false; if transcriptionFlag === flag { transcriptionFlag = nil } }
    let buffer = try recording.snapshot()
    let text = try await recognize(buffer, flag: flag)
    guard generation == capturedGeneration else { throw CancellationError() }
    return text
  }

  func cancel() {
    generation += 1
    transcriptionFlag?.cancel()
    if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
    deadline?.cancel(); engine = nil; recording = nil; deadline = nil; purpose = nil
    speaker.stopSpeaking(at: .immediate)
  }

  func speak(_ text: String) {
    speaker.stopSpeaking(at: .immediate)
    if !text.isEmpty { speaker.speak(AVSpeechUtterance(string: text)) }
  }
  func stopSpeaking() { speaker.stopSpeaking(at: .immediate) }

  @available(macOS 26.0, *)
  private func dictationModule() async throws -> DictationTranscriber {
    let locales = await DictationTranscriber.supportedLocales
    guard let locale = locales.first(where: { $0.identifier == Locale.current.identifier })
      ?? locales.first(where: { $0.language.languageCode == Locale.current.language.languageCode })
    else {
      throw BoomError.unavailable("On-device dictation does not support this Mac's current language.")
    }
    return DictationTranscriber(locale: locale, preset: .shortDictation)
  }

  @available(macOS 26.0, *)
  private func readyDictationModule() async throws -> DictationTranscriber {
    let module = try await dictationModule()
    let status = await AssetInventory.status(forModules: [module])
    switch status {
    case .installed:
      return module
    case .supported, .downloading:
      throw BoomError.unavailable("Install the on-device speech asset from model setup before using speech.")
    case .unsupported:
      throw BoomError.unavailable("On-device dictation does not support this language on this Mac.")
    @unknown default:
      throw BoomError.unavailable("The on-device dictation model is not ready.")
    }
  }

  func installSpeechAsset() async throws {
    if #available(macOS 26.0, *) {
      let module = try await dictationModule()
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
      }
      _ = try await readyDictationModule()
    } else { try await authorizeLegacySpeech() }
  }
  func transcribeAttachment(_ url: URL, flag: CancellationFlag, progress: (Int, Int) -> Void) async throws -> (text: String, coverage: String) {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 67_108_864 else { throw BoomError.budget("Audio attachment exceeds 64 MiB.") }
    let data = try await detachedWork { try Data(contentsOf: url) }
    return try await transcribeAttachment(data: data, extension: url.pathExtension, flag: flag, progress: progress)
  }
  func transcribeAttachment(data: Data, extension ext: String, flag: CancellationFlag,
    progress: (Int, Int) -> Void) async throws -> (text: String, coverage: String) {
    if ["m4a", "mp4", "mov"].contains(ext.lowercased()),
      try !MediaContainerPolicy.selfContainedMP4(data) {
      throw BoomError.invalid("Audio must be self-contained. External media references are not opened.")
    }
    if #available(macOS 26.0, *) { _ = try await readyDictationModule() }
    else { try await authorizeLegacySpeech() }
    let media = MemoryMedia(bytes: data, extension: ext)
    let reader = try await media.audioReader()
    let count = max(1, Int(ceil(reader.duration / 50)))
    var parts: [String] = [], failures: [Int] = [], index = 0
    while let buffer = try await detachedWork(operation: { try reader.next(flag: flag) }) {
      try flag.check(); index += 1; progress(index, count)
      do { parts.append(try await recognize(buffer, flag: flag)) }
      catch is CancellationError { throw CancellationError() }
      catch let error as BoomError {
        if case .denied = error { throw error }; failures.append(index)
      } catch { failures.append(index) }
    }
    guard !parts.isEmpty else { throw BoomError.unavailable("On-device speech recognized no words. The original is retained.") }
    let text = parts.joined(separator: "\n\n")
    guard text.utf8.count <= 262_144 else { throw BoomError.budget("Transcript exceeds 256 KiB; original retained.") }
    return (text, failures.isEmpty ? "On-device transcription of all \(index) segments; check wording against the original."
      : "Partial on-device transcription: \(index - failures.count) of \(index) segments; failed segments \(failures.map(String.init).joined(separator: ", ")).")
  }
  private func recognize(_ buffer: AVAudioPCMBuffer, flag: CancellationFlag) async throws -> String {
    if #available(macOS 26.0, *) { return try await transcribeModern(buffer, with: readyDictationModule(), flag: flag) }
    return try await transcribeLegacy(buffer, flag: flag)
  }
  @available(macOS 26.0, *)
  private func transcribeModern(
    _ buffer: AVAudioPCMBuffer, with transcriber: DictationTranscriber, flag: CancellationFlag? = nil
  ) async throws -> String {
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: buffer.format)
    let watchdog = flag.map { flag in
      Task {
        while !Task.isCancelled {
          if flag.isCancelled {
            await analyzer.cancelAndFinishNow()
            return
          }
          try? await Task.sleep(nanoseconds: 200_000_000)
        }
      }
    }
    defer { watchdog?.cancel() }
    let results = Task { () throws -> String in
      var words = ""
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { words += (words.isEmpty ? "" : " ") + text }
      }
      return words
    }
    do {
      let inputs = AsyncStream<AnalyzerInput> { continuation in
        continuation.yield(AnalyzerInput(buffer: buffer)); continuation.finish()
      }
      _ = try await analyzer.analyzeSequence(inputs)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      try flag?.check()
      let text = try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw BoomError.unavailable("No words were recognized.") }
      return text
    } catch {
      results.cancel()
      throw error
    }
  }

  private func authorizeLegacySpeech() async throws {
    guard let recognizer = SFSpeechRecognizer(locale: .current),
      recognizer.supportsOnDeviceRecognition else {
      throw BoomError.unavailable("On-device speech is unavailable for this language. Check macOS Dictation language settings.")
    }
    let status: SFSpeechRecognizerAuthorizationStatus
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      status = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
      }
    } else {
      status = SFSpeechRecognizer.authorizationStatus()
    }
    guard status == .authorized else {
      throw BoomError.denied("Speech recognition access was not granted.")
    }
  }

  private func transcribeLegacy(_ buffer: AVAudioPCMBuffer, flag: CancellationFlag? = nil) async throws -> String {
    try await authorizeLegacySpeech()
    guard let recognizer = SFSpeechRecognizer(locale: .current),
      recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
      throw BoomError.unavailable("An on-device speech recognizer is not available for this language.")
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.append(buffer); request.endAudio()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    return try await withCheckedThrowingContinuation { continuation in
      let completion = SpeechOnce(continuation)
      let task = recognizer.recognitionTask(with: request) { result, error in
        if let error { completion.finish(.failure(error)); return }
        if let result, result.isFinal {
          let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
          completion.finish(text.isEmpty
            ? .failure(BoomError.unavailable("No words were recognized.")) : .success(text))
        }
      }
      if let flag {
        Task {
          while !completion.isFinished {
            if flag.isCancelled {
              task.cancel()
              completion.finish(.failure(CancellationError()))
              break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
          }
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: 90_000_000_000)
        task.cancel()
        completion.finish(.failure(BoomError.unavailable("On-device transcription timed out.")))
      }
    }
  }
}

private final class SpeechOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return continuation == nil
  }
  func finish(_ result: Result<String, Error>) {
    lock.lock()
    let saved = continuation
    continuation = nil
    lock.unlock()
    saved?.resume(with: result)
  }
}

/// The microphone callback owns no file and cannot exceed one minute of PCM.
private final class RecordedAudio: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Float] = []
  private var failure: Error?
  func append(_ input: AVAudioPCMBuffer) {
    lock.lock(); defer { lock.unlock() }
    guard samples.count < 960_000, failure == nil else { return }
    do {
      guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: input.format, to: format),
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32)) else {
        throw BoomError.invalid("Microphone audio could not be converted.")
      }
      let source = OneShotAudioInput(input); var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, state in source.take(state) }
      if let error { throw error }
      guard status != .error, let channel = output.floatChannelData?[0] else { throw BoomError.invalid("Microphone conversion failed.") }
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: min(Int(output.frameLength), 960_000 - samples.count)))
    } catch { failure = error }
  }
  func snapshot() throws -> AVAudioPCMBuffer {
    lock.lock(); defer { lock.unlock() }
    if let failure { throw failure }
    guard samples.count > 1_024, samples.allSatisfy(\.isFinite),
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = output.floatChannelData?[0] else { throw BoomError.unavailable("No speech was recorded.") }
    output.frameLength = AVAudioFrameCount(samples.count)
    for index in samples.indices { channel[index] = samples[index] }
    return output
  }
}
