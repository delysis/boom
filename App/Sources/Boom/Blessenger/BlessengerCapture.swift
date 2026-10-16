import AVFoundation
import BoomCore
import Foundation

struct BlessengerCallerClip: Sendable {
  let samples: [Float]
  let firstFrame: UInt64
  let endFrame: UInt64
  let speechEndedUptime: Double
  let admittedUptime: Double
  let decision: String
  func wav() throws -> Data {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let output = buffer.floatChannelData?[0] else { throw BoomError.unavailable("Caller audio could not be packaged.") }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
    return try RecordedClip.wav(buffer)
  }
}

/// The real-time edge owns fixed ring and conversion buffers. It neither writes
/// files nor creates Tasks. The main-actor call owner drains a bounded event lane.
final class BlessengerCaptureBuffer: @unchecked Sendable {
  enum Event: Sendable { case speech(frame: UInt64), pause(frame: UInt64, uptime: Double), overflow, failure(String) }
  private let lock = NSLock()
  private let converter: AVAudioConverter
  private let converted: AVAudioPCMBuffer
  private var ring = [Float](repeating: 0, count: 480_000)
  private var frame: UInt64 = 0
  private var start: UInt64?
  private var speech = false
  private var high = 0, low = 0
  private var lastVoiced: UInt64 = 0
  private var lastVoicedUptime = 0.0
  private var events: [Event] = []
  private var enabled = true
  private var stopped = false
  init(source: AVAudioFormat) throws {
    guard source.channelCount > 0, source.channelCount <= 8, (8000...192000).contains(source.sampleRate),
      let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: source, to: target),
      let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768) else {
      throw BoomError.unavailable("The microphone format cannot be converted on this Mac.")
    }
    self.converter = converter; self.converted = converted
    events.reserveCapacity(32)
  }
  func append(_ input: AVAudioPCMBuffer, at time: AVAudioTime) {
    lock.lock(); defer { lock.unlock() }
    guard !stopped else { return }
    // The tap is serial; one converter preserves filter state across packets.
    guard input.frameLength > 0, input.frameLength <= 4096, input.format == converter.inputFormat else { fail("Invalid microphone packet."); return }
    var supplied = false, error: NSError?
    converted.frameLength = 0
    let status = converter.convert(to: converted, error: &error) { _, result in
      if supplied { result.pointee = .noDataNow; return nil }
      supplied = true; result.pointee = .haveData; return input
    }
    guard status != .error, error == nil, let samples = converted.floatChannelData?[0] else {
      fail("Microphone conversion failed."); return
    }
    let count = Int(converted.frameLength)
    guard count <= 32_768 else { fail("Microphone conversion exceeded its buffer."); return }
    guard frame <= UInt64.max - UInt64(count) else { fail("Capture frame counter exhausted."); return }
    var energy = 0.0
    for index in 0..<count {
      let value = samples[index]
      guard value.isFinite else { fail("Microphone supplied nonfinite samples."); return }
      ring[Int((frame + UInt64(index)) % UInt64(ring.count))] = enabled ? value : 0
      energy += Double(value) * Double(value)
    }
    guard frame <= UInt64.max - UInt64(count) else { fail("Capture frame counter exhausted."); return }
    frame += UInt64(count)
    guard enabled, count > 0 else { return }
    if let start, frame - start >= UInt64(ring.count - 4096) {
      stopped = true; emit(.overflow); return
    }
    let rms = sqrt(energy / Double(count)), now = ProcessInfo.processInfo.systemUptime
    // Acoustic hypotheses, not semantic completion. Their corpus qualification
    // remains separate from the monotonic capture/ownership contract.
    if rms >= 0.012 {
      high += 1; low = 0; lastVoiced = frame; lastVoicedUptime = now
      if !speech && high >= 3 {
        speech = true
        if start == nil { start = frame > 2560 ? frame - 2560 : 0 }
        emit(.speech(frame: frame))
      }
    } else if rms < 0.006 {
      low += 1; high = 0
      if speech && low >= 6 { speech = false; emit(.pause(frame: lastVoiced, uptime: lastVoicedUptime)) }
    } else { high = 0; low = 0 }
    _ = time // Native host timestamp is retained by qualification taps, not invented here.
  }
  private func emit(_ event: Event) {
    guard events.count < 32 else { stopped = true; events[31] = .failure("The bounded capture event lane overflowed."); return }
    events.append(event)
  }
  private func fail(_ message: String) { stopped = true; emit(.failure(message)) }
  func drain() -> [Event] {
    lock.lock(); defer { lock.unlock() }
    let saved = events; events.removeAll(keepingCapacity: true); return saved
  }
  func mute(_ muted: Bool) {
    lock.lock(); defer { lock.unlock() }
    enabled = !muted; start = nil; speech = false; high = 0; low = 0
  }
  func clip(through end: UInt64, ended: Double, decision: String) throws -> BlessengerCallerClip {
    lock.lock(); defer { lock.unlock() }
    guard !stopped, !speech, let start, end > start, end <= frame,
      frame - start < UInt64(ring.count), end - start > 1024,
      end - start < 480_000 else { throw BoomError.stale("The caller resumed or the exact audio span is no longer available.") }
    let samples = (start..<end).map { ring[Int($0 % UInt64(ring.count))] }
    self.start = nil
    return BlessengerCallerClip(samples: samples, firstFrame: start, endFrame: end,
      speechEndedUptime: ended, admittedUptime: ProcessInfo.processInfo.systemUptime, decision: decision)
  }
  func stop() { lock.lock(); stopped = true; start = nil; events.removeAll(); lock.unlock() }
}

struct BlessengerCallGate: Codable, Sendable {
  let call: UUID
  var epoch: UInt64 = 0
  var speaking = false, ready = false, muted = false, ended = false, admitted = false
  var pausedAt: UInt64?, decision: String?, lastFrame: UInt64?
  enum CodingKeys: String, CodingKey {
    case call, epoch, speaking, ready, muted, ended, decision, admitted
    case pausedAt = "paused_at", lastFrame = "last_frame"
  }
}
struct BlessengerCallTransition: Decodable, Sendable {
  let gate: BlessengerCallGate
  let interrupt: Bool, admit: Bool, ignored: Bool
}

/// One continuous duplex capture. The explicit timeout fallback is NEVER
/// described as a semantic detector, incremental audio prefill, or MTP decoding.
/// Model integration receives original audio, not a transcript surrogate.
@MainActor final class BlessengerCall: ObservableObject {
  @Published private(set) var active = false
  @Published private(set) var muted = false
  @Published private(set) var listening = false
  @Published private(set) var error: String?
  private let output: BlessengerAudioOutput
  var onStart: @MainActor () async throws -> Void
  var onUtterance: @MainActor (BlessengerCallerClip, UUID, UInt64) async throws -> Void
  var onInterrupt: @MainActor () -> Void
  private var gate = BlessengerCallGate(call: UUID())
  private var capture: BlessengerCaptureBuffer?
  private var poll: Task<Void, Never>?
  private var preparation: Task<Void, Never>?
  private var response: Task<Void, Never>?
  private var pausedUptime: Double?
  private var modelReady = false
  private var lifecycle = UUID()
  var onEnded: (@MainActor (String?) -> Void)?
  init(output: BlessengerAudioOutput, onStart: @escaping @MainActor () async throws -> Void = {},
    onUtterance: @escaping @MainActor (BlessengerCallerClip, UUID, UInt64) async throws -> Void = { _, _, _ in },
    onInterrupt: @escaping @MainActor () -> Void = {}) {
    self.output = output; self.onStart = onStart; self.onUtterance = onUtterance; self.onInterrupt = onInterrupt
  }
  func start() async throws {
    guard !active, preparation == nil, response == nil else { throw BoomError.unavailable("The preceding call is still closing.") }
    let attempt = UUID(); lifecycle = attempt
    output.stop(); try await output.join()
    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw BoomError.denied("Microphone access was not granted.") }
    guard lifecycle == attempt, !Task.isCancelled else { throw CancellationError() }
    let engine = output.engine
    engine.stop()
    try engine.inputNode.setVoiceProcessingEnabled(true)
    let format = engine.inputNode.outputFormat(forBus: 0)
    let capture = try BlessengerCaptureBuffer(source: format)
    engine.inputNode.installTap(onBus: 0, bufferSize: 480, format: format) { [capture] buffer, time in capture.append(buffer, at: time) }
    do { try engine.start() } catch { engine.inputNode.removeTap(onBus: 0); throw error }
    self.capture = capture; gate = BlessengerCallGate(call: UUID())
    active = true; listening = true; modelReady = false; error = nil
    let call = gate.call
    preparation = Task {
      defer { preparation = nil }
      do {
        try await onStart()
        guard active, gate.call == call else { return }
        modelReady = true
        try advance(["kind": "ready", "epoch": gate.epoch])
      } catch { self.error = error.localizedDescription; stop() }
    }
    poll = Task { [weak self] in
      guard let self else { return }
      while self.active, self.gate.call == call, !Task.isCancelled {
        do {
          for event in capture.drain() {
            switch event {
            case .speech(let frame):
              self.pausedUptime = nil; self.listening = true
              try self.advance(["kind": "speech", "frame": frame])
              if self.modelReady { try self.advance(["kind": "ready", "epoch": self.gate.epoch]) }
            case .pause(let frame, let uptime):
              self.pausedUptime = uptime
              try self.advance(["kind": "pause", "epoch": self.gate.epoch, "frame": frame])
            case .overflow: throw BoomError.budget("This input route cannot admit a caller turn of 30 seconds or more. No truncated turn was sent.")
            case .failure(let message): throw BoomError.unavailable(message)
            }
          }
          if let paused = self.pausedUptime, let frame = self.gate.pausedAt,
            !self.gate.admitted, !self.gate.speaking,
            ProcessInfo.processInfo.systemUptime - paused >= 1.5 {
            try self.advance(["kind": "end_of_utterance", "epoch": self.gate.epoch,
              "frame": frame, "decision": "forced_timeout"])
          }
          try await Task.sleep(for: .milliseconds(20))
        } catch is CancellationError { break }
        catch { self.error = error.localizedDescription; self.stop(); break }
      }
    }
  }
  private func advance(_ event: [String: Any]) throws {
    let next: BlessengerCallTransition = try ProductCore.call(["op": "blessenger", "request": [
      "op": "call", "gate": ProductCore.object(gate), "event": event]])
    gate = next.gate
    if next.interrupt { onInterrupt(); output.stop(); response?.cancel() }
    if next.admit, let end = gate.pausedAt, let paused = pausedUptime, let capture {
      let clip = try capture.clip(through: end, ended: paused, decision: gate.decision ?? "unknown")
      let call = gate.call, epoch = gate.epoch, prior = response
      response = Task {
        if let prior { await prior.value }
        guard active, gate.call == call, gate.epoch == epoch else { return }
        do { try await onUtterance(clip, call, epoch) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
        // The microphone remains running; a stale completion cannot change
        // readiness or the current caller's captured turn.
      }
    }
  }
  func setMuted(_ value: Bool) {
    guard active else { return }
    muted = value; capture?.mute(value)
    do { try advance(["kind": "mute", "muted": value]) } catch { self.error = error.localizedDescription; stop() }
  }
  func stop() {
    lifecycle = UUID()
    preparation?.cancel(); poll?.cancel(); response?.cancel()
    guard active else { return }
    active = false; listening = false
    capture?.stop(); capture = nil
    output.engine.inputNode.removeTap(onBus: 0)
    onInterrupt(); output.stop(); response?.cancel(); preparation?.cancel(); poll?.cancel()
    gate.ended = true; onEnded?(error)
  }
  func join() async {
    if let poll { await poll.value }; if let preparation { await preparation.value }; if let response { await response.value }
    poll = nil; preparation = nil; response = nil
    output.engine.stop()
  }
}
