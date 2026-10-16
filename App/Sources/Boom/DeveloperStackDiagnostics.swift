import BoomCore
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Fixed recipe values are shared with the explicit normal-memory fixture.
/// Capture transport and bootstrap exist only in the guarded build. Application
/// invokes that bootstrap only from its owned public branch; no workspace opens here.
enum DeveloperStackDiagnostics {
  struct PublicEditorPlan: Sendable {
    let kind: UInt32
    let operations: UInt32
    let utf8Bytes: UInt64
    init(kind: UInt32, operations: UInt32, utf8Bytes: UInt64) throws {
      guard operations == (kind == 4 || kind == 5 ? 200 : 1_000),
        (kind == 1 && utf8Bytes == 72_196) || (kind == 2 && utf8Bytes == 72_196)
          || (kind == 3 && utf8Bytes == (1 << 30))
          || (kind == 4 && utf8Bytes == 72_196) || (kind == 5 && utf8Bytes == (1 << 30)) else {
        #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
        throw DeveloperStackWire.Failure.admission
        #else
        throw BoomError.invalid("Public editor recipe is outside its fixed kind/operation/byte bounds.")
        #endif
      }
      self.kind = kind; self.operations = operations; self.utf8Bytes = utf8Bytes
    }
    var isMixed: Bool { kind == 4 || kind == 5 }
    var diskLimit: UInt64 { kind == 1 ? 4 << 20 : kind == 2 || kind == 4 ? 64 << 20 : 8 << 30 }
    var lifetimeSeconds: UInt64 { kind == 1 ? 120 : kind == 2 || kind == 4 ? 220 : 740 }
  }
  #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
  typealias Wire = DeveloperStackWire
  struct Token: Sendable {
    let sequence: UInt64
    let tid: UInt64
    let stage: UInt32
    let event: UInt64
  }
  private struct Stage {
    let id: UInt32
    let name: StaticString
  }
  private static let stages: [Stage] = [
    Stage(id: 1, name: "Bridge.Decode"),
    Stage(id: 2, name: "Bridge.Encode"),
    Stage(id: 3, name: "Bridge.Execute"),
    Stage(id: 4, name: "Bridge.InputUTF8"),
    Stage(id: 5, name: "Editor.DeferredLayout"),
    Stage(id: 6, name: "Editor.DeferredLayoutWait"),
    Stage(id: 7, name: "Editor.Draw"),
    Stage(id: 8, name: "Editor.GhostDraw"),
    Stage(id: 9, name: "Editor.GhostGraph"),
    Stage(id: 10, name: "Editor.GhostSnapshot"),
    Stage(id: 11, name: "Editor.GhostUpdate"),
    Stage(id: 12, name: "Editor.HostLayout"),
    Stage(id: 13, name: "Editor.InsertText"),
    Stage(id: 14, name: "Editor.MarkdownParse"),
    Stage(id: 15, name: "Editor.MediaLayout"),
    Stage(id: 16, name: "Editor.MediaParse"),
    Stage(id: 17, name: "Editor.MediaProject"),
    Stage(id: 18, name: "Editor.MediaRefresh"),
    Stage(id: 19, name: "Editor.NativePublication"),
    Stage(id: 20, name: "Editor.Projection"),
    Stage(id: 21, name: "Editor.Publish"),
    Stage(id: 22, name: "Editor.SearchUpdate"),
    Stage(id: 23, name: "Editor.SourceRead"),
    Stage(id: 24, name: "Editor.Style"),
    Stage(id: 25, name: "Editor.StyleSynchronize"),
    Stage(id: 26, name: "Editor.Update"),
    Stage(id: 27, name: "Model.ActiveKVAdmission"),
    Stage(id: 28, name: "Model.ActiveLocalKVHydration"),
    Stage(id: 29, name: "Model.ActiveNativeKVTransfer"),
    Stage(id: 30, name: "Model.BatchInitialEvaluation"),
    Stage(id: 31, name: "Model.BatchPrepare"),
    Stage(id: 32, name: "Model.ContainerWait"),
    Stage(id: 33, name: "Model.ContextReclamation"),
    Stage(id: 34, name: "Model.ExecutorWait"),
    Stage(id: 35, name: "Model.FinalFence"),
    Stage(id: 36, name: "Model.FirstCheckpoint"),
    Stage(id: 37, name: "Model.FirstDecodedText"),
    Stage(id: 38, name: "Model.FirstToken"),
    Stage(id: 39, name: "Model.InputPrepare"),
    Stage(id: 40, name: "Model.KVRetentionPublish"),
    Stage(id: 41, name: "Model.KVRetentionReserve"),
    Stage(id: 42, name: "Model.KVRetentionUpdate"),
    Stage(id: 43, name: "Model.Load"),
    Stage(id: 44, name: "Model.Operation"),
    Stage(id: 45, name: "Model.PrefillSubmission"),
    Stage(id: 46, name: "Model.PrefixCacheHydration"),
    Stage(id: 47, name: "Model.PrefixCacheLookup"),
    Stage(id: 48, name: "Model.ProducerJoin"),
    Stage(id: 49, name: "Model.PromptReceipt"),
    Stage(id: 50, name: "Model.Queue"),
    Stage(id: 51, name: "Model.StreamConstruction"),
    Stage(id: 52, name: "Request.CancelRequested"),
    Stage(id: 53, name: "Request.ConsultationCapture"),
    Stage(id: 54, name: "Request.ContextFit"),
    Stage(id: 55, name: "Request.FirstUIPublication"),
    Stage(id: 56, name: "Request.MediaInput"),
    Stage(id: 57, name: "Request.ModelReady"),
    Stage(id: 58, name: "Request.PreviousProducerJoin"),
    Stage(id: 59, name: "Request.SourceValidation"),
    Stage(id: 60, name: "Request.Work"),
    Stage(id: 61, name: "Request.WritingCapture"),
    Stage(id: 62, name: "Storage.AtomicWrite"),
    Stage(id: 63, name: "Storage.Checkpoint"),
    Stage(id: 64, name: "Storage.CheckpointRead"),
    Stage(id: 65, name: "Storage.Encode"),
    Stage(id: 66, name: "Storage.Encrypt"),
    Stage(id: 67, name: "Storage.LockWait"),
    Stage(id: 68, name: "Storage.Put"),
    Stage(id: 69, name: "Storage.Save"),
    Stage(id: 70, name: "Text.Measurement"),
    Stage(id: 71, name: "Workspace.Flush"),
    Stage(id: 72, name: "Editor.PublicTypingCycle"),
    Stage(id: 73, name: "Editor.ManagedInput"),
    Stage(id: 74, name: "Editor.ManagedAdmission"),
    Stage(id: 75, name: "Editor.ManagedSourceMutation"),
    Stage(id: 76, name: "Editor.ManagedBackingMutation"),
    Stage(id: 77, name: "Editor.ManagedTextKitNotification"),
    Stage(id: 78, name: "Editor.ManagedLayout"),
    Stage(id: 79, name: "Editor.ManagedDraw"),
    Stage(id: 80, name: "Editor.ManagedHistoryReconcile"),
    Stage(id: 81, name: "Editor.PublicMixedOperation"),
    Stage(id: 82, name: "Editor.PublicInputDispatch"),
    Stage(id: 83, name: "Editor.PublicReadyWait"),
    Stage(id: 84, name: "Editor.PublicRaster"),
    Stage(id: 85, name: "Storage.CheckpointAdmission"),
    Stage(id: 86, name: "Editor.ComposerHeight"),
  ]
  private static let runtime = AtomicLazyReference<Session>()
  private static let bootstrapping = Atomic<Bool>(false)
  private final class EntryLifetime: Sendable {
    let own: Wire.Identity
    let parent: Wire.Identity
    // Until the exact source/image/parent plan is admitted, retain the old
    // 120-second startup ceiling. Only one fixed recipe may extend this bound.
    let maximumNanoseconds = Atomic<UInt64>(120_000_000_000)
    init(own: Wire.Identity, parent: Wire.Identity) { self.own = own; self.parent = parent }
  }
  private static let entryLifetime = AtomicLazyReference<EntryLifetime>()

  private struct Fixture: Codable {
    let kind: UInt32 // 1 = legacy72K; 2/3 = paired file72K/1GiB; 4/5 = mixed file72K/1GiB.
    let operations: UInt32
    let utf8Bytes: UInt64
  }
  private struct Plan: Codable {
    let schema: UInt32
    let nonce: [UInt8]
    let owner: Wire.Identity
    let ownerExecutable: String
    let ownerExecutableSHA256: String
    let executable: String
    let executableSHA256: String
    let sourceInventory: String
    let sourceInventorySHA256: String
    let arguments: [String]
    let fixture: Fixture
  }
  private struct Admission { let plan: Plan; let own: Wire.Identity; let parent: Wire.Identity }

  /// Guard the exact developer entry before NSApplication or public fixture IO.
  /// Kernel identities only: no file reads, workspace, key or Mach donation.
  /// This admits a self-only lifetime bound, not permission to sample anything.
  @MainActor static func startOwnedEntryLifetime() throws {
    guard CommandLine.arguments.count == 4,
      CommandLine.arguments[1] == "--developer-stack-public-fixture",
      CommandLine.arguments[2] == "--developer-stack-recipe",
      CommandLine.arguments[3].hasPrefix("/"), pthread_main_np() == 1 else {
      throw Wire.Failure.admission
    }
    let own = try Wire.Identity.current(getpid())
    let parent = try Wire.Identity.current(getppid())
    guard own.uid == getuid(), getuid() == geteuid(), own.ppid == parent.pid, own.pgid == own.pid,
      parent.uid == own.uid else { throw Wire.Failure.identity }
    let candidate = EntryLifetime(own: own, parent: parent)
    let registered = entryLifetime.storeIfNil(candidate)
    guard registered.own == own, registered.parent == parent else { throw Wire.Failure.identity }
    if registered === candidate { startLifetimeGuardian(candidate) }
  }

  /// Startup/explicit registration only; not called from PerformanceTrace.
  /// The self-only guardian starts before the first potentially blocking IO
  /// and remains live through errors, final stderr writes and process exit.
  /// Prepare/warm only the reviewed public native fixture after image/source
  /// admission, before module donation. This avoids inventing trusted modules
  /// after lazy AppKit/TextKit loads. No measured phase exists during prepare.
  @MainActor static func bootstrapForOwnedPublicFixture(recipe: URL,
    prepare: @MainActor (PublicEditorPlan) async throws -> Void) async throws -> PublicEditorPlan {
    let admission = try admitOwnedFixture(recipe)
    let plan = try PublicEditorPlan(kind: admission.plan.fixture.kind, operations: admission.plan.fixture.operations,
      utf8Bytes: admission.plan.fixture.utf8Bytes)
    try await prepare(plan)
    return try startAdmittedFixture(admission)
  }
  @MainActor private static func admitOwnedFixture(_ recipe: URL) throws -> Admission {
    guard CommandLine.arguments.count == 4,
      CommandLine.arguments[1] == "--developer-stack-public-fixture",
      CommandLine.arguments[2] == "--developer-stack-recipe",
      CommandLine.arguments[3] == recipe.path,
      recipe.isFileURL, recipe.path.hasPrefix("/"), pthread_main_np() == 1,
      bootstrapping.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
      throw Wire.Failure.admission
    }
    let own = try Wire.Identity.current(getpid())
    let parent = try Wire.Identity.current(getppid())
    guard own.uid == getuid(), own.ppid == parent.pid, own.pgid == own.pid,
      parent.uid == own.uid else { throw Wire.Failure.identity }
    try startOwnedEntryLifetime()
    let bytes = try boundedFile(recipe.path, maximum: 64 * 1024, owner: own.uid)
    let plan = try JSONDecoder().decode(Plan.self, from: bytes)
    guard plan.schema == Wire.version, plan.owner == parent, plan.nonce.count == 16,
      plan.nonce.contains(where: { $0 != 0 }), plan.arguments == CommandLine.arguments,
      plan.executable == processImage(own.pid),
      plan.ownerExecutable == processImage(parent.pid) else { throw Wire.Failure.admission }
    let fixture = try PublicEditorPlan(kind: plan.fixture.kind,
      operations: plan.fixture.operations, utf8Bytes: plan.fixture.utf8Bytes)
    try verifyFile(plan.executable, sha256: plan.executableSHA256, maximum: 128 << 20, owner: nil)
    try verifyFile(plan.ownerExecutable, sha256: plan.ownerExecutableSHA256, maximum: 32 << 20, owner: nil)
    try verifyFile(plan.sourceInventory, sha256: plan.sourceInventorySHA256, maximum: 64 << 10, owner: own.uid)
    guard try Wire.Identity.current(getpid()) == own,
      try Wire.Identity.current(getppid()) == parent, let lifetime = entryLifetime.load(),
      lifetime.own == own, lifetime.parent == parent else { throw Wire.Failure.identity }
    lifetime.maximumNanoseconds.store(fixture.lifetimeSeconds * 1_000_000_000, ordering: .releasing)
    return Admission(plan: plan, own: own, parent: parent)
  }
  @MainActor private static func startAdmittedFixture(_ admission: Admission) throws -> PublicEditorPlan {
    let (plan, own, parent) = (admission.plan, admission.own, admission.parent)
    guard try Wire.Identity.current(getpid()) == own,
      try Wire.Identity.current(getppid()) == parent else { throw Wire.Failure.identity }
    try verifyFile(plan.executable, sha256: plan.executableSHA256, maximum: 128 << 20, owner: nil)
    try verifyFile(plan.ownerExecutable, sha256: plan.ownerExecutableSHA256, maximum: 32 << 20, owner: nil)
    try verifyFile(plan.sourceInventory, sha256: plan.sourceInventorySHA256, maximum: 64 << 10, owner: own.uid)
    let session = try Session(own: own, parent: parent, nonce: plan.nonce)
    try session.register(role: .main)
    try session.waitForStart()
    guard runtime.storeIfNil(session) === session else { throw Wire.Failure.admission }
    session.startDrain()
    return try PublicEditorPlan(kind: plan.fixture.kind, operations: plan.fixture.operations,
      utf8Bytes: plan.fixture.utf8Bytes)
  }

  /// Only after the public main-thread fixture has ended all measured phases.
  /// Multiple registered producers require their own actual join protocol.
  @MainActor static func finishOutsideMeasuredPhases() throws {
    guard let session = runtime.load() else { throw Wire.Failure.admission }
    try session.finishSingleProducer()
  }

  /// Call only outside measured operations on the thread donating its own
  /// right. No foreign thread lookup/enumeration and no implicit registration.
  static func registerCurrentThread(role: Wire.Role) throws {
    guard let session = runtime.load() else { throw Wire.Failure.admission }
    try session.register(role: role)
  }
  static var isReady: Bool { runtime.load()?.running.load(ordering: .acquiring) == true }

  static func begin(_ name: StaticString, event: UInt64 = 0) -> Token? {
    guard let session = runtime.load(), session.running.load(ordering: .acquiring),
      let ring = session.currentRing() else { return nil }
    let stage = session.stageID(name)
    let sequence = ring.nextSequence()
    guard sequence != 0 else { return nil }
    let token = Token(sequence: sequence, tid: ring.tid, stage: stage, event: event)
    ring.append(sequence: sequence, correlation: token, kind: stage == 0 ? .unknownStage : .begin, value: 0)
    return token
  }
  static func end(_ token: Token?) {
    guard let token, let session = runtime.load(), session.running.load(ordering: .acquiring),
      let ring = session.currentRing() else { return }
    let sequence = ring.nextSequence()
    guard sequence != 0 else { return }
    ring.append(sequence: sequence, correlation: token, kind: token.stage == 0 ? .unknownStage : .end, value: 0)
  }
  static func event(_ name: StaticString) {
    guard let session = runtime.load(), session.running.load(ordering: .acquiring),
      let ring = session.currentRing() else { return }
    let stage = session.stageID(name), sequence = ring.nextSequence()
    guard sequence != 0 else { return }
    let token = Token(sequence: sequence, tid: ring.tid, stage: stage, event: 0)
    ring.append(sequence: sequence, correlation: token, kind: stage == 0 ? .unknownStage : .event, value: 0)
  }
  static func prefill(processed: Int, total: Int) {
    guard let session = runtime.load(), session.running.load(ordering: .acquiring),
      let ring = session.currentRing() else { return }
    guard processed >= 0, total >= processed, total <= Int(UInt32.max) else {
      ring.invalidValues.wrappingAdd(1, ordering: .relaxed); return
    }
    let sequence = ring.nextSequence()
    guard sequence != 0 else { return }
    let token = Token(sequence: sequence, tid: ring.tid,
      stage: session.stageID("Model.PrefillSubmission"), event: 0)
    ring.append(sequence: sequence, correlation: token, kind: .progress,
      value: UInt64(processed) | UInt64(total) << 32)
  }

  /// One producer, the explicitly registered thread; one utility consumer.
  /// Queue allocation/initialization occurs before TLS publication. Release
  /// publication protects scalar storage, acquire tail prevents slot reuse.
  final class Ring: @unchecked Sendable {
    let tid: UInt64
    let role: Wire.Role
    private let storage: UnsafeMutablePointer<Wire.Phase>
    private let published = Atomic<UInt64>(0)
    private let consumed = Atomic<UInt64>(0)
    private var position: UInt64 = 0 // producer only
    private var attempt: UInt64 = 0 // producer only, including queue refusals
    let ringFull = Atomic<UInt64>(0)
    let exhausted = Atomic<UInt64>(0)
    let invalidValues = Atomic<UInt64>(0)
    var transportLost: UInt64 = 0 // utility consumer only
    init(tid: UInt64, role: Wire.Role) {
      self.tid = tid; self.role = role
      storage = .allocate(capacity: Wire.ringRecords)
      storage.initialize(repeating: Wire.Phase(), count: Wire.ringRecords)
    }
    deinit { storage.deinitialize(count: Wire.ringRecords); storage.deallocate() }
    func nextSequence() -> UInt64 {
      guard attempt < UInt64.max else { exhausted.store(1, ordering: .relaxed); return 0 }
      attempt += 1; return attempt
    }
    func lastSequenceOutsidePhases() -> UInt64 { attempt }
    func append(sequence: UInt64, correlation: Token, kind: Wire.PhaseKind, value: UInt64) {
      let tail = consumed.load(ordering: .acquiring)
      guard position < UInt64.max, tail <= position,
        position - tail < UInt64(Wire.ringRecords) else {
        ringFull.wrappingAdd(1, ordering: .relaxed); return
      }
      let at = Int(position & UInt64(Wire.ringRecords - 1))
      storage[at] = Wire.Phase(sequence: sequence,
        correlationSequence: correlation.sequence, correlationTID: correlation.tid,
        timestampTicks: mach_absolute_time(), event: correlation.event,
        emitterTID: tid, stage: correlation.stage, kind: kind.rawValue,
        reserved: 0, value: value)
      position += 1; published.store(position, ordering: .releasing)
    }
    func peek(into buffer: UnsafeMutableBufferPointer<Wire.Phase>) -> Int {
      let head = published.load(ordering: .acquiring)
      var tail = consumed.load(ordering: .relaxed)
      guard tail <= head else { return 0 }
      let count = min(buffer.count, Int(min(head - tail, UInt64(Wire.ringRecords))))
      for index in 0..<count {
        buffer[index] = storage[Int(tail & UInt64(Wire.ringRecords - 1))]
        tail += 1
      }
      return count
    }
    /// The sole consumer releases slots only after their actual send succeeds.
    func commit(_ count: Int) {
      let tail = consumed.load(ordering: .relaxed), head = published.load(ordering: .acquiring)
      precondition(count >= 0 && tail <= head && UInt64(count) <= head - tail)
      consumed.store(tail + UInt64(count), ordering: .releasing)
    }
    /// Final shutdown only, after the producer stopped. Count a permanent
    /// transport discard once, rather than counting each refused send.
    func discardPending() -> UInt64 {
      let tail = consumed.load(ordering: .relaxed), head = published.load(ordering: .acquiring)
      precondition(tail <= head && head - tail <= UInt64(Wire.ringRecords))
      consumed.store(head, ordering: .releasing)
      return head - tail
    }
  }

  private final class Session: @unchecked Sendable {
    let running = Atomic<Bool>(true)
    private let unregistered = Atomic<UInt64>(0)
    private let state: Mutex<State>
    private let key: pthread_key_t
    private let stagesByHash: [UInt64: Stage]
    private let queue = DispatchQueue(label: "com.delysis.Bloom.developer-phase-drain", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var drainTicks: UInt64 = 0 // utility consumer only
    private var lostSnapshots: UInt64 = 0 // utility consumer only
    private var phaseBuffer = [Wire.Phase](repeating: Wire.Phase(), count: Wire.phasesPerMessage)
    private struct State { let client: Wire.Client; var rings: [Ring] = [] }
    init(own: Wire.Identity, parent: Wire.Identity, nonce: [UInt8]) throws {
      var key = pthread_key_t()
      guard pthread_key_create(&key, nil) == 0 else { throw Wire.Failure.exhausted }
      var initialized = false
      defer { if !initialized { pthread_key_delete(key) } }
      self.key = key
      var mapping = [UInt64: Stage]()
      for stage in DeveloperStackDiagnostics.stages {
        let value = Self.hash(stage.name)
        guard stage.id > 0, value != 0, mapping[value] == nil else { throw Wire.Failure.admission }
        mapping[value] = stage
      }
      stagesByHash = mapping
      // Lookup/challenge precede all task/thread donation. The parent source,
      // actual executable and kernel lifetime were checked by bootstrap.
      state = Mutex(State(client: try Wire.Client(nonce: nonce, own: own, parent: parent)))
      initialized = true
    }
    // This Session is retained until process exit by AtomicLazyReference; TLS
    // pointers never outlive a ring, including after drain/transport failure.
    deinit { timer?.cancel(); pthread_key_delete(key) }
    func register(role: Wire.Role) throws {
      guard running.load(ordering: .acquiring), pthread_getspecific(key) == nil else {
        throw Wire.Failure.admission
      }
      try state.withLock { state in
        guard running.load(ordering: .acquiring), state.rings.count < Wire.maximumThreads else {
          throw Wire.Failure.exhausted
        }
        let tid = try state.client.donateCurrentThread(role: role)
        guard !state.rings.contains(where: { $0.tid == tid }) else { throw Wire.Failure.identity }
        let ring = Ring(tid: tid, role: role)
        state.rings.append(ring)
        guard pthread_setspecific(key, Unmanaged.passUnretained(ring).toOpaque()) == 0 else {
          running.store(false, ordering: .releasing); throw Wire.Failure.exhausted
        }
      }
    }
    func currentRing() -> Ring? {
      // The TLS lookup is user-space only. Unregistered stages never invoke a
      // thread-info RPC, allocate a ring, acquire state or send a Mach message.
      guard let pointer = pthread_getspecific(key) else {
        unregistered.wrappingAdd(1, ordering: .relaxed); return nil
      }
      return Unmanaged<Ring>.fromOpaque(pointer).takeUnretainedValue()
    }
    private static func hash(_ name: StaticString) -> UInt64 {
      name.withUTF8Buffer { bytes in
        guard bytes.count > 0, bytes.count <= 64 else { return 0 }
        return bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
      }
    }
    func stageID(_ name: StaticString) -> UInt32 {
      guard let stage = stagesByHash[Self.hash(name)] else { return 0 }
      let same = stage.name.withUTF8Buffer { expected in name.withUTF8Buffer { expected.elementsEqual($0) } }
      return same ? stage.id : 0 // collision/unknown is an explicit numeric marker.
    }
    func startDrain() {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      self.timer = timer
      timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
      timer.setEventHandler { [weak self] in self?.drain() }; timer.resume()
    }
    func waitForStart() throws {
      try state.withLock { try $0.client.waitForStart() }
    }
    func finishSingleProducer() throws {
      guard pthread_main_np() == 1, let current = currentRing() else { throw Wire.Failure.identity }
      running.store(false, ordering: .releasing)
      timer?.cancel()
      try queue.sync {
        try state.withLock { state in
          guard state.rings.count == 1, state.rings[0] === current, current.role == .main else {
            throw Wire.Failure.admission
          }
          for _ in 0..<(Wire.ringRecords / Wire.phasesPerMessage) {
            do {
              if try sendReadyPhases(current, state: state, timeout: 100) == 0 { break }
            } catch {
              let discarded = current.discardPending()
              let lost = current.transportLost.addingReportingOverflow(discarded)
              current.transportLost = lost.overflow ? UInt64.max : lost.partialValue
              break
            }
          }
          // A terminal loss report is required before DONE. Failure remains
          // explicit instead of claiming a fully reconciled capture.
          try sendLossSnapshot(current, state: state, timeout: 100)
          try state.client.done(tid: current.tid, lastSequence: current.lastSequenceOutsidePhases())
        }
      }
    }
    private func sendReadyPhases(_ ring: Ring, state: State, timeout: UInt32 = 0) throws -> Int {
      try phaseBuffer.withUnsafeMutableBufferPointer { buffer in
        let count = ring.peek(into: buffer)
        if count > 0 {
          try state.client.phases(UnsafeBufferPointer(start: buffer.baseAddress, count: count),
            tid: ring.tid, role: ring.role, timeout: timeout)
          ring.commit(count)
        }
        return count
      }
    }
    private func drain() {
      guard running.load(ordering: .acquiring) else { return }
      state.withLock { state in
        // Fixed512-slot rings, at most16 batches/ring per tick. Backpressure
        // retains the uncommitted prefix and stops this tick without a wait.
        draining: for _ in 0..<16 {
          var progressed = false
          for ring in state.rings {
            do {
              if try sendReadyPhases(ring, state: state) > 0 { progressed = true }
            } catch { break draining }
          }
          if !progressed { break }
        }
        drainTicks = drainTicks == UInt64.max ? 0 : drainTicks + 1
        if drainTicks.isMultiple(of: 10) { publishLossSnapshot(state) }
      }
    }
    private func sendLossSnapshot(_ ring: Ring, state: State, timeout: UInt32 = 0) throws {
      try state.client.loss(tid: ring.tid, role: ring.role,
        ringFull: ring.ringFull.load(ordering: .acquiring), transport: ring.transportLost,
        unregistered: unregistered.load(ordering: .acquiring),
        invalid: ring.invalidValues.load(ordering: .acquiring),
        exhausted: ring.exhausted.load(ordering: .acquiring), lostSnapshots: lostSnapshots,
        timeout: timeout)
    }
    /// Outside phases. Missing terminal loss counters after a crash are unknown.
    private func publishLossSnapshot(_ state: State) {
      for ring in state.rings {
        do { try sendLossSnapshot(ring, state: state) }
        catch { lostSnapshots = lostSnapshots == UInt64.max ? UInt64.max : lostSnapshots + 1 }
      }
    }
  }

  private static func startLifetimeGuardian(_ lifetime: EntryLifetime) {
    let deadline = mach_absolute_time()
    Thread.detachNewThread {
      var timebase = mach_timebase_info_data_t()
      guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { _exit(71) }
      while true {
        guard let actual = try? Wire.Identity.current(pid_t(lifetime.parent.pid)),
          actual.sameLifetime(as: lifetime.parent) else { _exit(71) }
        let elapsed = mach_absolute_time() - deadline
        let scaled = elapsed.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !scaled.overflow, scaled.partialValue / UInt64(timebase.denom)
          < lifetime.maximumNanoseconds.load(ordering: .acquiring) else { _exit(71) }
        usleep(50_000)
      }
    }
  }
  private static func processImage(_ pid: UInt32) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    let count = bytes.withUnsafeMutableBytes { proc_pidpath(Int32(pid), $0.baseAddress, UInt32($0.count)) }
    guard count > 0, count < Int32(bytes.count), bytes.contains(0) else { return nil }
    return String(cString: bytes)
  }
  private static func boundedFile(_ path: String, maximum: Int, owner: UInt32?) throws -> Data {
    guard path.hasPrefix("/"), path.utf8.count <= 4096 else { throw Wire.Failure.admission }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Wire.Failure.admission }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      before.st_size >= 0, before.st_size <= off_t(maximum),
      owner.map({ before.st_uid == $0 }) ?? true else { throw Wire.Failure.admission }
    var data = Data(count: Int(before.st_size)), total = 0
    try data.withUnsafeMutableBytes { buffer in
      while total < buffer.count {
        let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Wire.Failure.admission }
        total += count
      }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, sameFile(before, after) else { throw Wire.Failure.admission }
    return data
  }
  private static func verifyFile(_ path: String, sha256: String, maximum: Int, owner: UInt32?) throws {
    guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw Wire.Failure.admission
    }
    guard path.hasPrefix("/"), path.utf8.count <= 4096 else { throw Wire.Failure.admission }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Wire.Failure.admission }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      before.st_size > 0, before.st_size <= off_t(maximum),
      owner.map({ before.st_uid == $0 }) ?? true else { throw Wire.Failure.admission }
    // Stream the image rather than materializing its complete bytes or raising
    // the app's kernel peak by the binary size. This precedes task donation.
    var chunk = Data(count: 64 * 1024), digest = SHA256(), total: off_t = 0
    while total < before.st_size {
      let requested = min(chunk.count, Int(before.st_size - total))
      let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, requested) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw Wire.Failure.admission }
      digest.update(data: chunk.prefix(count)); total += off_t(count)
    }
    var after = stat()
    guard fstat(fd, &after) == 0, sameFile(before, after) else { throw Wire.Failure.admission }
    let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard actual == sha256 else { throw Wire.Failure.identity }
  }
  private static func sameFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_size == right.st_size
      && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
      && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
      && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
      && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
  }
  #endif
}
