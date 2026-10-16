import AVFoundation
import BoomCore
import Foundation
import Darwin

struct BlessengerCallerClip: Sendable {
  let samples: [Float]
  let firstFrame: UInt64
  let endFrame: UInt64
  let speechEndedUptime: Double
  let admittedUptime: Double
  let decision: String
  var nativeInputClock = false
  var deliveredUptime: Double? = nil
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
  // Two minutes of input, bounded independently of the indefinite call lifetime.
  private var ring = [Float](repeating: 0, count: 1_920_000)
  private var frame: UInt64 = 0
  private var start: UInt64?
  private var speech = false
  private var high = 0, low = 0
  private var publishedPause: UInt64?
  private var lastVoiced: UInt64 = 0
  private var lastVoicedUptime = 0.0
  private var lastDeliveredUptime = 0.0
  private var nativeInputClock = false
  private let hostToUptime = ProcessInfo.processInfo.systemUptime - AVAudioTime.seconds(forHostTime: mach_absolute_time())
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
      high += 1; low = 0; lastVoiced = frame
      // Keep the input packet's clock separate from its delivery to this callback.
      // The detector identifies a voiced packet, not a sample-perfect acoustic edge.
      nativeInputClock = time.isHostTimeValid
      lastVoicedUptime = time.isHostTimeValid
        ? AVAudioTime.seconds(forHostTime: time.hostTime) + hostToUptime + Double(input.frameLength) / input.format.sampleRate : now
      lastDeliveredUptime = now
      if !speech && high >= 3 {
        speech = true
        if start == nil { start = frame > 2560 ? frame - 2560 : 0 }
        emit(.speech(frame: frame))
      }
    } else if rms < 0.006 {
      low += 1; high = 0
      if low >= 6, start != nil, publishedPause != lastVoiced {
        speech = false; publishedPause = lastVoiced
        emit(.pause(frame: lastVoiced, uptime: lastVoicedUptime))
      }
    } else { high = 0; low = 0 }
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
    publishedPause = nil; events.removeAll(keepingCapacity: true)
  }
  func semanticWindow(through end: UInt64) throws -> [Float] {
    lock.lock(); defer { lock.unlock() }
    guard !stopped, !speech, high == 0, let start, end == lastVoiced, end > start, end <= frame,
      frame - start < UInt64(ring.count) else { throw BoomError.stale("The caller resumed before turn classification.") }
    let lower = max(start, end > UInt64(BlessengerTurnClassifier.samples) ? end - UInt64(BlessengerTurnClassifier.samples) : 0)
    return (lower..<end).map { ring[Int($0 % UInt64(ring.count))] }
  }
  func isPaused(through end: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return !stopped && !speech && high == 0 && start != nil && end == lastVoiced && end <= frame
  }
  func clip(through end: UInt64, ended: Double, decision: String) throws -> BlessengerCallerClip {
    lock.lock(); defer { lock.unlock() }
    guard !stopped, !speech, high == 0, let start, end == lastVoiced, end > start, end <= frame,
      frame - start < UInt64(ring.count), end - start > 1024,
      end - start < UInt64(ring.count) else { throw BoomError.stale("The caller resumed or the exact audio span is no longer available.") }
    let samples = (start..<end).map { ring[Int($0 % UInt64(ring.count))] }
    self.start = nil
    return BlessengerCallerClip(samples: samples, firstFrame: start, endFrame: end,
      speechEndedUptime: ended, admittedUptime: ProcessInfo.processInfo.systemUptime, decision: decision,
      nativeInputClock: nativeInputClock, deliveredUptime: lastDeliveredUptime)
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

/// One continuous duplex capture. Acoustic pause and semantic completion are
/// independent witnesses; either may arrive before model readiness. The Rust
/// admission reducer releases the current turn exactly once when both agree.
@MainActor final class BlessengerCall: ObservableObject {
  @Published private(set) var active = false
  @Published private(set) var muted = false
  @Published private(set) var listening = false
  @Published private(set) var error: String?
  private let output: BlessengerAudioOutput
  var onStart: @MainActor () async throws -> Void
  var onUtterance: @MainActor (BlessengerCallerClip, UUID, UInt64) async throws -> Void
  var onInterrupt: @MainActor () -> Void
  var onReady: (@MainActor () -> Void)?
  var onClassify: @Sendable ([Float]) async throws -> Float
  private let classifier: BlessengerTurnClassifier
  private var classification: Task<Void, Never>?
  private var classifiedPause: UInt64?
  private var gate = BlessengerCallGate(call: UUID())
  private var capture: BlessengerCaptureBuffer?
  private var poll: Task<Void, Never>?
  private var preparation: Task<Void, Never>?
  private var response: Task<Void, Never>?
  private var pausedUptime: Double?
  private var modelReady = false
  private var lifecycle = UUID()
  private var endingWaiters: [CheckedContinuation<Void, Never>] = []
  private let requestMicrophone: @MainActor () async -> Bool
  var onEnded: (@MainActor (String?) -> Void)?
  var onIssue: (@MainActor (String?) -> Void)?
  init(output: BlessengerAudioOutput, onStart: @escaping @MainActor () async throws -> Void = {},
    onUtterance: @escaping @MainActor (BlessengerCallerClip, UUID, UInt64) async throws -> Void = { _, _, _ in },
    onInterrupt: @escaping @MainActor () -> Void = {},
    onClassify: (@Sendable ([Float]) async throws -> Float)? = nil,
    requestMicrophone: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
    self.requestMicrophone = requestMicrophone
    self.output = output; self.onStart = onStart; self.onUtterance = onUtterance; self.onInterrupt = onInterrupt
    let classifier = BlessengerTurnClassifier(); self.classifier = classifier
    self.onClassify = onClassify ?? { samples in
      try Task.checkCancellation(); let result = try await classifier.probability(samples)
      try Task.checkCancellation(); return result
    }
  }
  func start(cancellation: CancellationFlag = CancellationFlag()) async throws {
    guard !active, preparation == nil, response == nil else { throw BoomError.unavailable("The preceding call is still closing.") }
    let attempt = UUID(); lifecycle = attempt
    try cancellation.check()
    output.stop(); try await output.join()
    try cancellation.check()
    guard lifecycle == attempt, !Task.isCancelled else { throw CancellationError() }
    let permitted = await requestMicrophone()
    try cancellation.check()
    guard lifecycle == attempt, !Task.isCancelled else { throw CancellationError() }
    guard permitted else { throw BoomError.denied("Microphone access was not granted.") }
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
        try await classifier.prepare()
        try Task.checkCancellation(); try await onStart()
        guard active, gate.call == call else { return }
        modelReady = true; onReady?()
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
              self.pausedUptime = nil; self.listening = true; self.classification?.cancel(); self.classifiedPause = nil; self.error = nil; self.onIssue?(nil)
              try self.advance(["kind": "speech", "frame": frame])
              if self.modelReady { try self.advance(["kind": "ready", "epoch": self.gate.epoch]) }
            case .pause(let frame, let uptime):
              self.pausedUptime = uptime
              try self.advance(["kind": "pause", "epoch": self.gate.epoch, "frame": frame])
            case .overflow: throw BoomError.budget("This input route admits at most two minutes per caller turn. No truncated turn was sent.")
            case .failure(let message): throw BoomError.unavailable(message)
            }
          }
          if let paused = self.pausedUptime, let frame = self.gate.pausedAt,
            !self.gate.admitted, !self.gate.speaking, !self.gate.muted {
            let elapsed = ProcessInfo.processInfo.systemUptime - paused
            if self.modelReady, self.classification == nil, self.classifiedPause != frame, elapsed >= 0.25 {
              self.classify(capture, through: frame, call: call, epoch: self.gate.epoch)
            }
            // A negative semantic result is not permission to force a response.
            // Surface the unsettled turn; explicit Send Turn remains available.
            if elapsed >= 10, self.classifiedPause == frame, self.gate.decision == nil {
              self.error = "The turn sounds unfinished. Continue speaking, or choose Send Turn."; self.onIssue?(self.error)
            }
          }
          if !self.output.engine.isRunning { throw BoomError.unavailable("The audio device stopped. The call has ended.") }
          try await Task.sleep(for: .milliseconds(20))
        } catch is CancellationError { break }
        catch { self.error = error.localizedDescription; self.stop(); break }
      }
    }
  }
  private func classify(_ capture: BlessengerCaptureBuffer, through frame: UInt64, call: UUID, epoch: UInt64) {
    let prior = classification
    classification = Task { [weak self] in
      if let prior { await prior.value }
      guard let self else { return }
      defer { self.classification = nil }
      do {
        try Task.checkCancellation()
        let samples = try capture.semanticWindow(through: frame)
        let probability = try await self.onClassify(samples)
        try Task.checkCancellation()
        guard self.active, self.gate.call == call, self.gate.epoch == epoch,
          self.gate.pausedAt == frame, capture.isPaused(through: frame) else { return }
        self.classifiedPause = frame
        guard probability.isFinite, (0...1).contains(probability) else { throw BoomError.invalid("Invalid semantic turn probability.") }
        if probability >= 0.7 {
          self.error = nil; self.onIssue?(nil)
          try self.advance(["kind": "end_of_utterance", "epoch": epoch, "frame": frame, "decision": "semantic"])
        }
      } catch is CancellationError {}
      catch let issue as BoomError {
        if case .stale = issue { return }
        if self.active, self.gate.call == call, self.gate.epoch == epoch { self.error = issue.localizedDescription; self.stop() }
      } catch { if self.active, self.gate.call == call { self.error = error.localizedDescription; self.stop() } }
    }
  }
  func submitPausedTurn() {
    guard active, !gate.muted, !gate.speaking, let frame = gate.pausedAt, capture?.isPaused(through: frame) == true else { return }
    classification?.cancel()
    do { try advance(["kind": "end_of_utterance", "epoch": gate.epoch, "frame": frame, "decision": "explicit"]) }
    catch { self.error = error.localizedDescription }
  }
  private func advance(_ event: [String: Any]) throws {
    let next: BlessengerCallTransition = try ProductCore.call(["op": "blessenger", "request": [
      "op": "call", "gate": ProductCore.object(gate), "event": event]])
    let clip: BlessengerCallerClip?
    if next.admit {
      guard let end = next.gate.pausedAt, let paused = pausedUptime, let capture else {
        throw BoomError.invalid("A call turn lost its captured pause.")
      }
      do { clip = try capture.clip(through: end, ended: paused, decision: next.gate.decision ?? "unknown") }
      catch let error as BoomError {
        // The realtime producer may resume between its semantic result and this
        // transaction. Leave the gate unconsumed; its next speech/pause event
        // replaces the old decision. Never force a second pause or end the call.
        if case .stale = error { return }; throw error
      }
    } else { clip = nil }
    gate = next.gate
    if next.interrupt { onInterrupt(); output.stop(); response?.cancel() }
    if let clip {
      let call = gate.call, epoch = gate.epoch, prior = response
      response = Task {
        if let prior { await prior.value }
        guard active, gate.call == call, gate.epoch == epoch else { return }
        do { try await onUtterance(clip, call, epoch) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription; self.onIssue?(self.error) }
        // The microphone remains running; a stale completion cannot change
        // readiness or the current caller's captured turn.
      }
    }
  }
  func setMuted(_ value: Bool) {
    guard active else { return }
    muted = value; capture?.mute(value); classification?.cancel(); classifiedPause = nil; pausedUptime = nil
    do { try advance(["kind": "mute", "muted": value]) } catch { self.error = error.localizedDescription; stop() }
  }
  func stop() {
    lifecycle = UUID()
    preparation?.cancel(); poll?.cancel(); response?.cancel(); classification?.cancel()
    guard active else { return }
    active = false; listening = false
    capture?.stop(); capture = nil
    output.engine.inputNode.removeTap(onBus: 0)
    onInterrupt(); output.stop(); response?.cancel(); preparation?.cancel(); poll?.cancel()
    gate.ended = true; onEnded?(error)
    let waiters = endingWaiters; endingWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
  func waitUntilEnded() async {
    if active { await withCheckedContinuation { endingWaiters.append($0) } }
  }
  func join() async {
    if let poll { await poll.value }; if let preparation { await preparation.value }; if let response { await response.value }
    if let classification { await classification.value }; classification = nil
    poll = nil; preparation = nil; response = nil
    output.engine.stop()
  }
}
