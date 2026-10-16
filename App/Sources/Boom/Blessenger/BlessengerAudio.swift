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
      throw BoomError.unavailable("This provider accepts only the captured Apple voice.")
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
  private func finish(_ identity: ObjectIdentifier) {
    guard utterance.map(ObjectIdentifier.init) == identity else { return }
    ended = true; stream?.finish(); let saved = terminal; terminal = nil; saved?.resume()
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance); Task { @MainActor [weak self] in self?.finish(id) }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance); Task { @MainActor [weak self] in self?.finish(id) }
  }
}

struct BlessengerSpeechResult: Sendable {
  struct Boundary: Codable, Equatable, Sendable { let frames: Int; let text: String }
  let responseID: UUID
  let attempt: UUID
  let voice: BlessengerSpeechVoice
  let samples: [Float]
  let sampleRate: Int
  let heardFrames: Int
  let boundaries: [Boundary]
  let interrupted: Bool
  let failure: String?
  let trace: BlessengerTrace
  var deliveredText: String { boundaries.filter { $0.frames <= heardFrames }.map(\.text).joined(separator: " ") }
  func wav() throws -> Data { try BlessengerWave.encode(samples, rate: sampleRate) }
}

/// A single native output graph, with bounded producer and device queues. A
/// response keeps one captured speech route until synthesis AND playback end.
@MainActor final class BlessengerAudioOutput: ObservableObject {
  @Published private(set) var responseID: UUID?
  @Published private(set) var ready = false
  @Published private(set) var speaking = false
  @Published private(set) var error: String?
  @Published private(set) var heardFrames = 0
  let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let synthesizer = BlessengerAppleSpeech()
  private let qwen = BlessengerQwenSpeech()
  private var epoch = UUID()
  private var cursor = BlessengerSpeechCursor()
  private var fragments: [BlessengerFragment] = []
  private var voice: BlessengerSpeechVoice?
  private var worker: Task<Void, Never>?
  private var flag = CancellationFlag()
  private var externalCancellation: (CancellationFlag, UUID?)?
  private var stopped = false
  private var rate: Int?
  private var pendingFrames = 0
  private var scheduledFrames = 0
  private var samples: [Float] = []
  private var boundaries: [BlessengerSpeechResult.Boundary] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var sourceFinished = false
  private var terminal: BlessengerSpeechResult?
  private var completed: [UUID: BlessengerSpeechResult] = [:]
  private var attempt = UUID()
  private var seed: UInt64 = 0
  private var trace = BlessengerTrace()
  private var renderObservation: Task<Void, Never>?
  private(set) var firstPCMUptime: Double?
  private(set) var firstScheduleUptime: Double?
  var onPacket: ((UUID, BlessengerPCM) -> Void)?
  var onEnd: ((UUID, Int, Bool) -> Void)?
  init() { engine.attach(player) }

  func prepare(_ voice: BlessengerSpeechVoice) async throws -> BlessengerSpeechVoice {
    guard responseID == nil, worker == nil else { throw BoomError.unavailable("Stop and join current speech before changing its voice.") }
    var resolved = voice
    switch voice.provider {
    case .qwen: resolved.identifier = try await qwen.prepare()
    case .apple:
      let installed = BlessengerAppleSpeech.voices()
      guard let selected = voice.identifier.flatMap({ id in installed.first { $0.identifier == id } })
        ?? (voice.identifier == nil ? installed.first : nil) else {
        throw BoomError.unavailable("The selected local speech voice is not installed.")
      }
      resolved.identifier = selected.identifier
    }
    return resolved
  }
  func begin(_ id: UUID, voice: BlessengerSpeechVoice, attempt: UUID, seed: UInt64,
    cancellation: CancellationFlag, trace: BlessengerTrace = BlessengerTrace()) throws {
    guard responseID == nil, worker == nil, completed.count < 8 else { throw BoomError.unavailable("The prior speech producer or its retained result has not settled.") }
    try cancellation.check()
    responseID = id; self.voice = voice; self.attempt = attempt; self.seed = seed
    self.trace = trace; terminal = nil; cursor = BlessengerSpeechCursor()
    epoch = UUID(); flag = CancellationFlag(); stopped = false; sourceFinished = false
    fragments = []; ready = false; speaking = false; error = nil
    heardFrames = 0; scheduledFrames = 0; pendingFrames = 0; samples = []; boundaries = []; rate = nil
    firstPCMUptime = nil; firstScheduleUptime = nil
    let current = epoch
    let registration = cancellation.onCancel { [weak self] in
      Task { @MainActor in if self?.epoch == current { self?.stop(responseID: id) } }
    }
    externalCancellation = (cancellation, registration)
  }
  func append(_ text: String, responseID id: UUID, voice: BlessengerSpeechVoice, finished: Bool = false) throws {
    guard responseID == id, self.voice == voice, !stopped else {
      if let terminal, terminal.responseID == id, let failure = terminal.failure { throw BoomError.unavailable(failure) }
      throw BoomError.stale("Another response owns speech output.")
    }
    let next = try BlessengerPolicy.speech(text, cursor: cursor, finished: finished)
    guard fragments.count + next.fragments.count <= 32 else {
      fail("The response exceeded its bounded speakable-text queue."); throw BoomError.budget(error!)
    }
    if !next.fragments.isEmpty { trace.once("text.firstSpeakable") }
    cursor = next.cursor; fragments.append(contentsOf: next.fragments); sourceFinished = finished
    pump(); settleIfDrained()
  }
  private func pump() {
    guard worker == nil, responseID != nil, !stopped, !fragments.isEmpty else { return }
    let operation = epoch
    worker = Task { [weak self] in
      guard let self else { return }
      defer { self.worker = nil; self.wake(); if self.epoch == operation { self.settleIfDrained() } }
      do {
        while self.epoch == operation, !self.stopped, !self.fragments.isEmpty {
          let fragment = self.fragments.removeFirst()
          let flag = self.flag, voice = self.voice!
          self.trace.once("tts.dispatch")
          switch voice.provider {
          case .apple:
            try await self.synthesizer.synthesize(fragment.text, voice: voice, flag: flag) { packet in
              try await self.enqueue(packet, epoch: operation, flag: flag)
            }
          case .qwen:
            let trace = self.trace
            try await self.qwen.synthesize(fragment.text, voice: voice, seed: self.seed,
              flag: flag, observe: { name, time in trace.record(name, at: time) }) { [weak self] packet in
                guard let self else { throw CancellationError() }
                try await self.enqueue(packet, epoch: operation, flag: flag)
              }
          }
          guard self.epoch == operation, !self.stopped else { throw CancellationError() }
          self.boundaries.append(.init(frames: self.samples.count, text: fragment.text))
        }
      } catch {
        if self.epoch == operation {
          if !(error is CancellationError) { self.fail(error.localizedDescription) } else { self.stop() }
        }
      }
    }
  }
  private func enqueue(_ packet: BlessengerPCM, epoch expected: UUID, flag: CancellationFlag) async throws {
    try flag.check()
    guard epoch == expected, !stopped, let id = responseID else { throw CancellationError() }
    if let rate, rate != packet.rate { throw BoomError.invalid("Speech changed sample rate inside a response.") }
    guard samples.count <= min(packet.rate * 600, 16_000_000) - packet.samples.count else {
      throw BoomError.budget("One spoken response exceeds its duration or private-record limit.")
    }
    guard packet.samples.count <= packet.rate * 4 else { throw BoomError.budget("One PCM packet exceeds the playback window.") }
    while pendingFrames + packet.samples.count > packet.rate * 4 {
      await withCheckedContinuation { waiters.append($0) }
      try flag.check(); guard epoch == expected else { throw CancellationError() }
    }
    let buffer = try packet.buffer()
    if rate == nil {
      rate = packet.rate; engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      if !engine.isRunning { try engine.start() }
    }
    let count = packet.samples.count, end = scheduledFrames + packet.samples.count
    samples.append(contentsOf: packet.samples); pendingFrames += count; scheduledFrames = end
    if firstPCMUptime == nil { firstPCMUptime = ProcessInfo.processInfo.systemUptime; trace.once("pcm.firstValidated") }
    ready = true; onPacket?(id, packet)
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.epoch == expected, !self.stopped else { return }
        self.pendingFrames -= count; self.heardFrames = max(self.heardFrames, end)
        self.observeRenderTime(); self.wake(); self.settleIfDrained()
      }
    }
    if !player.isPlaying {
      firstScheduleUptime = firstScheduleUptime ?? ProcessInfo.processInfo.systemUptime
      trace.once("playback.enqueued"); player.play(); speaking = true
      renderObservation = Task { [weak self] in
        guard let self else { return }
        while self.epoch == expected, self.speaking, !Task.isCancelled {
          if self.observeRenderTime() { return }
          do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
      }
    }
  }
  /// Native render progress, not an assertion that sound reached a human ear.
  /// A physical loopback remains necessary for acoustic latency qualification.
  @discardableResult private func observeRenderTime() -> Bool {
    guard let time = player.lastRenderTime, time.isHostTimeValid,
      let position = player.playerTime(forNodeTime: time), position.sampleTime > 0,
      position.sampleRate > 0 else { return false }
    let rendered = min(scheduledFrames, Int(position.sampleTime))
    heardFrames = max(heardFrames, rendered)
    let first = AVAudioTime.seconds(forHostTime: time.hostTime) - Double(position.sampleTime) / position.sampleRate
    trace.once("playback.firstRendered", at: first)
    return true
  }
  private func wake() { let saved = waiters; waiters.removeAll(); for waiter in saved { waiter.resume() } }
  private func settleIfDrained() {
    guard sourceFinished, worker == nil, fragments.isEmpty, pendingFrames == 0, responseID != nil else { return }
    if samples.isEmpty { fail("Speech completed without producing playable audio."); return }
    finish(interrupted: false)
  }
  private func finish(interrupted: Bool) {
    guard let id = responseID, let voice else { return }
    observeRenderTime(); trace.record(interrupted ? "playback.interrupted" : "playback.drained")
    terminal = BlessengerSpeechResult(responseID: id, attempt: attempt, voice: voice, samples: samples,
      sampleRate: rate ?? 24_000, heardFrames: min(samples.count, heardFrames), boundaries: boundaries,
      interrupted: interrupted, failure: error, trace: trace)
    completed[attempt] = terminal
    // Retire publication BEFORE stop: AVFoundation may invoke completions for
    // buffers it unschedules. Those callbacks cannot become delivery receipts.
    epoch = UUID(); responseID = nil; speaking = false; ready = false
    renderObservation?.cancel(); renderObservation = nil
    player.stop(); pendingFrames = 0; rate = nil
    if let (owner, registration) = externalCancellation { owner.removeCancellationHandler(registration) }
    externalCancellation = nil
    onEnd?(id, heardFrames, interrupted); wake()
  }
  private func fail(_ message: String) { error = message; trace.record("speech.failed"); stop() }
  func stop(responseID id: UUID? = nil) {
    guard id == nil || responseID == id else { return }
    stopped = true; flag.cancel(); synthesizer.cancel(); fragments.removeAll()
    finish(interrupted: true); wake()
  }
  func result(for id: UUID, attempt expected: UUID? = nil) async throws -> BlessengerSpeechResult {
    let expected = expected ?? attempt
    while attempt == expected && (responseID == id || worker != nil) {
      if let worker { await worker.value }
      else { await withCheckedContinuation { waiters.append($0) } }
    }
    guard let result = completed.removeValue(forKey: expected), result.responseID == id else {
      throw BoomError.stale("The selected speech result has been replaced or already consumed.")
    }
    result.trace.record("speech.producerJoined"); return result
  }
  func join() async throws {
    let expected = attempt
    if let worker { await worker.value }
    guard responseID == nil || sourceFinished else { throw BoomError.unavailable("Speech input has not reached its terminal boundary.") }
    while attempt == expected && responseID != nil { await withCheckedContinuation { waiters.append($0) } }
  }
  func replay(_ samples: [Float], rate: Int, messageID: UUID, voice: BlessengerSpeechVoice, flag: CancellationFlag) async throws {
    stop(); try await join()
    try begin(messageID, voice: voice, attempt: UUID(), seed: 0, cancellation: flag)
    let captured = epoch
    do {
      for start in stride(from: 0, to: samples.count, by: rate) {
        try await enqueue(BlessengerPCM(samples: Array(samples[start..<min(start + rate, samples.count)]), rate: rate), epoch: captured, flag: self.flag)
      }
      sourceFinished = true; settleIfDrained(); _ = try await result(for: messageID)
    } catch { stop(responseID: messageID); try await join(); throw error }
  }
}
