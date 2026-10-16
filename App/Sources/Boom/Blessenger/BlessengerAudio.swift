import AppKit
import AVFoundation
import BoomCore
import Foundation

/// Immutable, finite, mono PCM. The callback copies only this bounded packet;
/// AVFoundation's borrowed buffer cannot outlive its producer callback.
struct BlessengerPCM: Sendable {
  let samples: [Float]
  let rate: Int
  init(samples: [Float], rate: Int) throws {
    guard (8000...96000).contains(rate), !samples.isEmpty, samples.count <= 96_000,
      samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else {
      throw BoomError.invalid("Speech supplied invalid or oversized PCM.")
    }
    self.samples = samples; self.rate = rate
  }
  init(_ buffer: AVAudioPCMBuffer) throws {
    guard buffer.frameLength > 0, buffer.frameLength <= 96_000,
      buffer.frameLength <= buffer.frameCapacity,
      buffer.format.channelCount == 1, buffer.format.commonFormat == .pcmFormatFloat32,
      let data = buffer.floatChannelData?[0], buffer.format.sampleRate.rounded() == buffer.format.sampleRate else {
      throw BoomError.invalid("Speech did not supply bounded mono Float32 PCM.")
    }
    try self.init(samples: Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))), rate: Int(buffer.format.sampleRate))
  }
  func buffer() throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let output = buffer.floatChannelData?[0] else { throw BoomError.unavailable("Audio buffer allocation failed.") }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { source in output.update(from: source.baseAddress!, count: source.count) }
    return buffer
  }
}

/// The native synthesizer is kept alive until its terminal delegate callback.
/// Cancelling the consumer suppresses audio immediately but does not invent a
/// producer join. Overflow is a failure, not a dropped middle of a sentence.
@MainActor final class BlessengerAppleSpeech: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var utterance: AVSpeechUtterance?
  private var terminal: CheckedContinuation<Void, Never>?
  private var ended = false
  private var stream: AsyncThrowingStream<BlessengerPCM, Error>.Continuation?
  override init() { super.init(); synthesizer.delegate = self }
  static func voices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().filter {
      $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice)
    }.sorted { ($0.language == "en-US" ? 0 : 1, $0.name) < ($1.language == "en-US" ? 0 : 1, $1.name) }
  }
  func synthesize(_ text: String, voice: BlessengerSpeechVoice, flag: CancellationFlag,
    receive: @MainActor (BlessengerPCM) async throws -> Void) async throws {
    guard utterance == nil else { throw BoomError.unavailable("Speech is still settling its previous utterance.") }
    guard voice.provider == .apple else {
      throw BoomError.unavailable("This build has not qualified a Qwen streaming voice. No replacement voice was selected.")
    }
    let installed = Self.voices()
    let selected = voice.identifier.flatMap { id in installed.first { $0.identifier == id } }
      ?? (voice.identifier == nil ? installed.first : nil)
    guard let selected else { throw BoomError.unavailable("The selected local speech voice is not installed.") }
    try flag.check()
    let value = AVSpeechUtterance(string: text); value.voice = selected
    utterance = value; ended = false
    let (packets, continuation) = AsyncThrowingStream<BlessengerPCM, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
    stream = continuation
    let registration = flag.onCancel { [weak self] in
      Task { @MainActor in if self?.utterance === value { self?.cancel() } }
    }
    defer { flag.removeCancellationHandler(registration); utterance = nil; stream = nil }
    synthesizer.write(value) { buffer in
      guard !flag.isCancelled else { return }
      guard let pcm = buffer as? AVAudioPCMBuffer else {
        continuation.finish(throwing: BoomError.invalid("The speech provider returned a non-PCM buffer.")); flag.cancel(); return
      }
      // A zero-frame callback is end-of-audio, not the native producer's join.
      if pcm.frameLength == 0 { continuation.finish(); return }
      do {
        let packet = try BlessengerPCM(pcm)
        switch continuation.yield(packet) {
        case .dropped:
          continuation.finish(throwing: BoomError.budget("Speech exceeded its bounded PCM queue.")); flag.cancel()
        case .terminated: break
        case .enqueued: break
        @unknown default: continuation.finish(throwing: BoomError.invalid("Unknown PCM queue state.")); flag.cancel()
        }
      } catch { continuation.finish(throwing: error); flag.cancel() }
    }
    do {
      for try await packet in packets { try flag.check(); try await receive(packet) }
      await awaitTerminal(); try flag.check()
    } catch {
      cancel(); await awaitTerminal(); throw error
    }
  }
  private func awaitTerminal() async {
    if ended { return }
    await withCheckedContinuation { terminal = $0 }
  }
  func cancel() {
    stream?.finish(throwing: CancellationError())
    _ = synthesizer.stopSpeaking(at: .immediate)
  }
  private func finish(_ value: AVSpeechUtterance) {
    guard utterance === value else { return }
    ended = true; stream?.finish(); let saved = terminal; terminal = nil; saved?.resume()
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish(utterance) }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(utterance) }
}

/// A single native output graph. Playback completion and synthesis completion
/// are independent. Interruption retires its epoch before unscheduling buffers.
@MainActor final class BlessengerAudioOutput: ObservableObject {
  @Published private(set) var responseID: UUID?
  @Published private(set) var ready = false
  @Published private(set) var speaking = false
  @Published private(set) var error: String?
  @Published private(set) var heardFrames = 0
  let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let synthesizer = BlessengerAppleSpeech()
  private var epoch = UUID()
  private var cursor = BlessengerSpeechCursor()
  private var fragments: [BlessengerFragment] = []
  private var voice: BlessengerSpeechVoice?
  private var worker: Task<Void, Never>?
  private var flag = CancellationFlag()
  private var stopped = false
  private var rate: Int?
  private var pendingFrames = 0
  private var scheduledFrames = 0
  private var totalFrames = 0
  private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
  private var sourceFinished = false
  private var lastText = ""
  private(set) var firstPCMUptime: Double?
  private(set) var firstScheduleUptime: Double?
  var onPacket: ((UUID, BlessengerPCM) -> Void)?
  var onEnd: ((UUID, Int, Bool) -> Void)?
  init() { engine.attach(player) }

  func append(_ text: String, responseID id: UUID, voice: BlessengerSpeechVoice, finished: Bool = false) throws {
    if responseID == nil { begin(id, voice: voice) }
    guard responseID == id, self.voice == voice, !stopped else {
      throw BoomError.stale("Another response owns speech output.")
    }
    let next = try BlessengerPolicy.speech(text, cursor: cursor, finished: finished)
    guard fragments.count + next.fragments.count <= 32 else {
      stop(responseID: id); throw BoomError.budget("The response exceeded its bounded speakable-text queue.")
    }
    cursor = next.cursor; fragments.append(contentsOf: next.fragments); lastText = text
    sourceFinished = finished
    pump()
  }
  private func begin(_ id: UUID, voice: BlessengerSpeechVoice) {
    responseID = id; self.voice = voice; cursor = BlessengerSpeechCursor()
    epoch = UUID(); flag = CancellationFlag(); stopped = false; sourceFinished = false
    fragments = []; ready = false; speaking = false; error = nil
    heardFrames = 0; scheduledFrames = 0; totalFrames = 0; lastText = ""
    firstPCMUptime = nil; firstScheduleUptime = nil
  }
  private func pump() {
    guard worker == nil, responseID != nil, !stopped else { return }
    let operation = epoch
    worker = Task { [weak self] in
      guard let self else { return }
      defer {
        self.worker = nil
        if self.epoch == operation { self.settleIfDrained() }
        else if !self.stopped { self.pump() }
      }
      do {
        while self.epoch == operation, !self.stopped, !self.fragments.isEmpty {
          let fragment = self.fragments.removeFirst()
          let flag = self.flag, voice = self.voice!
          try await self.synthesizer.synthesize(fragment.text, voice: voice, flag: flag) { packet in
            try await self.enqueue(packet, epoch: operation, flag: flag)
          }
        }
      } catch {
        if !(error is CancellationError) { self.error = error.localizedDescription }
        if self.epoch == operation { self.stop() }
      }
    }
  }
  private func enqueue(_ packet: BlessengerPCM, epoch expected: UUID, flag: CancellationFlag) async throws {
    try flag.check()
    guard epoch == expected, !stopped, let id = responseID else { throw CancellationError() }
    if let rate, rate != packet.rate { throw BoomError.invalid("Speech changed sample rate inside a response.") }
    guard totalFrames <= packet.rate * 600 - packet.samples.count else { throw BoomError.budget("One spoken response exceeds ten minutes.") }
    // Four seconds of native playback plus the bounded provider bridge. The
    // consumer suspends rather than growing an unbounded device schedule.
    guard packet.samples.count <= packet.rate * 4 else { throw BoomError.budget("One PCM packet exceeds the playback window.") }
    while pendingFrames + packet.samples.count > packet.rate * 4 {
      await withCheckedContinuation { capacityWaiters.append($0) }
      try flag.check(); guard epoch == expected else { throw CancellationError() }
    }
    if rate == nil {
      rate = packet.rate
      let buffer = try packet.buffer()
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      if !engine.isRunning { try engine.start() }
    }
    let buffer = try packet.buffer(), count = packet.samples.count
    totalFrames += count; pendingFrames += count; scheduledFrames += count
    if firstPCMUptime == nil { firstPCMUptime = ProcessInfo.processInfo.systemUptime }
    ready = true; onPacket?(id, packet)
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.epoch == expected, !self.stopped else { return }
        self.pendingFrames -= count; self.heardFrames += count
        self.wakeCapacity(); self.settleIfDrained()
      }
    }
    if !player.isPlaying {
      firstScheduleUptime = firstScheduleUptime ?? ProcessInfo.processInfo.systemUptime
      player.play(); speaking = true
    }
  }
  private func wakeCapacity() {
    let saved = capacityWaiters; capacityWaiters.removeAll()
    for waiter in saved { waiter.resume() }
  }
  private func settleIfDrained() {
    guard sourceFinished, worker == nil, fragments.isEmpty, pendingFrames == 0, let id = responseID else { return }
    onEnd?(id, heardFrames, false); speaking = false; responseID = nil
    // Never stop from the audio render callback. This runs on the main actor.
    player.stop(); rate = nil
  }
  func stop(responseID id: UUID? = nil) {
    guard id == nil || responseID == id else { return }
    let prior = responseID
    stopped = true; epoch = UUID(); flag.cancel(); synthesizer.cancel()
    player.stop(); fragments.removeAll(); pendingFrames = 0; wakeCapacity()
    speaking = false; ready = false
    if let prior { onEnd?(prior, heardFrames, true) }
    responseID = nil; rate = nil
  }
  func join() async throws {
    if let worker { await worker.value }
    guard pendingFrames == 0, !speaking else { throw BoomError.unavailable("Audio output has not drained.") }
  }
}
