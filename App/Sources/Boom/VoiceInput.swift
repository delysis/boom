import AppKit
import AVFoundation
import BoomCore
import Speech

@MainActor final class VoiceInput: ObservableObject {
  enum Purpose { case conversation, dictation }
  @Published private(set) var purpose: Purpose?
  @Published private(set) var starting = false
  @Published private(set) var transcribing = false
  private var recorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var deadline: Task<Void, Never>?
  private var generation = 0
  private let speaker = AVSpeechSynthesizer()

  var isRecording: Bool { recorder != nil }

  func start(_ purpose: Purpose) async throws {
    guard recorder == nil, !starting, !transcribing else { return }
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
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("boom-voice-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    guard recorder.record(forDuration: 60) else {
      try? FileManager.default.removeItem(at: url)
      throw BoomError.unavailable("The microphone could not start recording.")
    }
    self.recorder = recorder
    recordingURL = url
    self.purpose = purpose
    deadline = Task { [weak self, capturedRecorder = recorder] in
      do { try await Task.sleep(nanoseconds: 60_000_000_000) }
      catch { return }
      guard self?.recorder === capturedRecorder else { return }
      capturedRecorder.stop()
    }
  }

  func stop() async throws -> String {
    guard let recorder, let url = recordingURL else { return "" }
    let capturedGeneration = generation
    recorder.stop()
    deadline?.cancel()
    deadline = nil
    self.recorder = nil
    recordingURL = nil
    purpose = nil
    transcribing = true
    defer {
      transcribing = false
      try? FileManager.default.removeItem(at: url)
    }
    guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 4_096 else {
      throw BoomError.unavailable("No speech was recorded.")
    }
    let text = try await transcribe(url)
    guard generation == capturedGeneration else { throw CancellationError() }
    return text
  }

  func cancel() {
    generation += 1
    recorder?.stop()
    deadline?.cancel()
    recorder = nil
    deadline = nil
    purpose = nil
    if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
    recordingURL = nil
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
      // This fetches only Apple's speech model asset. Recorded audio is never
      // supplied to a network recognizer.
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
      }
      guard await AssetInventory.status(forModules: [module]) == .installed else {
        throw BoomError.unavailable(
          "The on-device speech model is still downloading. Try again when macOS finishes installing it.")
      }
      return module
    case .unsupported:
      throw BoomError.unavailable("On-device dictation does not support this language on this Mac.")
    @unknown default:
      throw BoomError.unavailable("The on-device dictation model is not ready.")
    }
  }

  func transcribe(_ url: URL) async throws -> String {
    if #available(macOS 26.0, *) {
      return try await transcribeModern(url, with: readyDictationModule())
    }
    return try await transcribeLegacy(url)
  }

  /// File attachments are divided into short, independently recognized local
  /// requests. A single hour-long Speech request is not a valid transcript.
  func transcribeAttachment(
    _ url: URL, flag: CancellationFlag, progress: (Int, Int) -> Void
  ) async throws -> (text: String, coverage: String) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard format.sampleRate >= 8_000, format.sampleRate <= 192_000,
      format.channelCount > 0, format.channelCount <= 8, file.length > 0 else {
      throw BoomError.invalid("Unsupported local audio format.")
    }
    let chunkFrames = AVAudioFramePosition(format.sampleRate * 50)
    let count = Int((file.length + chunkFrames - 1) / chunkFrames)
    guard count > 0, count <= 144 else {
      throw BoomError.budget("Audio transcription accepts at most two hours of local audio.")
    }
    guard let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
      interleaved: false),
      let converter = AVAudioConverter(from: format, to: target) else {
      throw BoomError.invalid("Cannot create the local audio converter.")
    }
    if #available(macOS 26.0, *) {
      _ = try await readyDictationModule()
    } else {
      try await authorizeLegacySpeech()
    }
    var parts: [String] = []
    var failures: [Int] = []
    var firstFailure: String?
    for chunk in 0..<count {
      try flag.check()
      progress(chunk + 1, count)
      let start = AVAudioFramePosition(chunk) * chunkFrames
      let frames = AVAudioFrameCount(min(chunkFrames, file.length - start))
      file.framePosition = start
      guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
        let output = AVAudioPCMBuffer(
          pcmFormat: target,
          frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 16_000 / format.sampleRate) + 1024))
      else { throw BoomError.invalid("Cannot allocate a bounded audio chunk.") }
      try file.read(into: input, frameCount: frames)
      let source = OneShotAudioInput(input)
      var conversionError: NSError?
      let result = converter.convert(to: output, error: &conversionError) { _, status in
        source.take(status)
      }
      if let conversionError { throw conversionError }
      guard result != .error, output.frameLength > 0 else {
        throw BoomError.invalid("Local audio chunk conversion failed.")
      }
      let chunkURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "boom-speech-\(UUID().uuidString).wav")
      defer { try? FileManager.default.removeItem(at: chunkURL) }
      do {
        let writer = try AVAudioFile(
          forWriting: chunkURL, settings: target.settings,
          commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: output)
      }
      do {
        let text: String
        if #available(macOS 26.0, *) {
          text = try await transcribeModern(
            chunkURL, with: readyDictationModule(), flag: flag)
        } else {
          text = try await transcribeLegacy(chunkURL, flag: flag)
        }
        if !text.isEmpty { parts.append(text) }
      } catch is CancellationError { throw CancellationError() }
      catch let error as BoomError {
        if case .denied = error { throw error }
        firstFailure = firstFailure ?? error.localizedDescription
        failures.append(chunk + 1)
      } catch {
        firstFailure = firstFailure ?? error.localizedDescription
        failures.append(chunk + 1)
      }
      try flag.check()
    }
    guard !parts.isEmpty else {
      throw BoomError.unavailable(
        "On-device speech could not transcribe this recording: "
          + (firstFailure ?? "No words were recognized."))
    }
    let text = parts.joined(separator: "\n\n")
    guard text.utf8.count <= 262_144 else {
      throw BoomError.budget("The transcript exceeds the attachment text limit; the original is retained.")
    }
    let coverage = failures.isEmpty
      ? "On-device transcription of all \(count) audio segments; wording should be checked against the original."
      : "Partial on-device transcription: \(count - failures.count) of \(count) segments; failed segments \(failures.map(String.init).joined(separator: ", "))."
    return (text, coverage)
  }

  func transcribeAttachment(
    data: Data, extension ext: String, flag: CancellationFlag,
    progress: (Int, Int) -> Void
  ) async throws -> (text: String, coverage: String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "boom-speech-input-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("source." + ext)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return try await transcribeAttachment(url, flag: flag, progress: progress)
  }

  @available(macOS 26.0, *)
  private func transcribeModern(
    _ url: URL, with transcriber: DictationTranscriber, flag: CancellationFlag? = nil
  ) async throws -> String {
    let file = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: file.processingFormat)
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
      _ = try await analyzer.analyzeSequence(from: file)
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

  private func transcribeLegacy(_ url: URL, flag: CancellationFlag? = nil) async throws -> String {
    try await authorizeLegacySpeech()
    guard let recognizer = SFSpeechRecognizer(locale: .current),
      recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
      throw BoomError.unavailable("An on-device speech recognizer is not available for this language.")
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
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
