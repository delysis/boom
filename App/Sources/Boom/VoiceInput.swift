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
      if let module = try? await dictationModule(),
        await AssetInventory.status(forModules: [module]) == .installed {
        // The installed transcriber can run without Speech authorization.
      } else {
        try await authorizeLegacySpeech()
      }
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

  func transcribe(_ url: URL) async throws -> String {
    if #available(macOS 26.0, *) {
      if let transcriber = try? await dictationModule(),
        await AssetInventory.status(forModules: [transcriber]) == .installed {
        return try await transcribeModern(url, with: transcriber)
      }
    }
    return try await transcribeLegacy(url)
  }

  @available(macOS 26.0, *)
  private func transcribeModern(_ url: URL, with transcriber: DictationTranscriber) async throws -> String {
    let file = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: file.processingFormat)
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

  private func transcribeLegacy(_ url: URL) async throws -> String {
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
  func finish(_ result: Result<String, Error>) {
    lock.lock()
    let saved = continuation
    continuation = nil
    lock.unlock()
    saved?.resume(with: result)
  }
}
