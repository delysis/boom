import BoomCore
import Foundation
import Darwin
import Metal
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers

actor GenerationCoordinator {
  static let shared = GenerationCoordinator()
  private var occupied = false
  private var activeFlag: CancellationFlag?
  private var background = false
  private var runnerEpoch: UUID?
  private var producer: Task<Void, Never>?
  private var cancelProducer: (@Sendable () -> Void)?
  private var activity: NSObjectProtocol?
  private struct TextWaiting {
    let request: MLXGemmaRunner.IndependentTextRequest
    let epoch: UUID
    let compatibility: String
    let perform: @Sendable ([MLXGemmaRunner.IndependentTextRequest], CancellationFlag) async -> [Result<MLXGemmaRunner.Output, Error>]
    let continuation: CheckedContinuation<Result<MLXGemmaRunner.Output, Error>, Never>
  }
  private enum Waiting {
    case operation(CancellationFlag?, Bool, UUID?, CheckedContinuation<Void, Never>)
    case text(TextWaiting)
    var isBackground: Bool { if case .operation(_, let value, _, _) = self { return value }; return false }
    var epoch: UUID? {
      switch self { case .operation(_, _, let value, _): value; case .text(let value): value.epoch }
    }
    func cancel() {
      switch self { case .operation(let flag, _, _, _): flag?.cancel(); case .text(let value): value.request.flag.cancel() }
    }
  }
  private var speech: (id: UUID, flag: CancellationFlag)?
  /// Speech generation may overlap a foreground language producer, not a load
  /// or unload. Both retain their actual producer joins and process budget.
  func beginSpeech(flag: CancellationFlag) throws -> UUID {
    try flag.check()
    guard speech == nil, !occupied || activeFlag != nil else {
      throw BoomError.unavailable("Model preparation still owns the device.")
    }
    if background { activeFlag?.cancel(); cancelProducer?() }
    let id = UUID(); speech = (id, flag); return id
  }
  func endSpeech(_ id: UUID) {
    guard speech?.id == id else { return }
    speech = nil
    if !occupied { startNext() }
  }
  private var waiting: [Waiting] = []
  var queuedOperations: Int { waiting.count }
  private func admitOwner(flag: CancellationFlag?, background: Bool, runnerEpoch: UUID?) {
    occupied = true; activeFlag = flag; self.background = background; self.runnerEpoch = runnerEpoch
    activity = ProcessInfo.processInfo.beginActivity(
      options: background ? .background : .userInitiatedAllowingIdleSystemSleep,
      reason: "On-device model operation")
  }
  func enter(flag: CancellationFlag? = nil, background: Bool = false, runnerEpoch: UUID? = nil) async {
    if background, speech != nil { flag?.cancel() }
    if !occupied, flag != nil || speech == nil { admitOwner(flag: flag, background: background, runnerEpoch: runnerEpoch); return }
    if !background, self.background { activeFlag?.cancel(); cancelProducer?() }
    await withCheckedContinuation { waiting.append(.operation(flag, background, runnerEpoch, $0)) }
  }
  /// Rows are payloads in the existing wait queue, not separate GPU tasks. Only
  /// already-ready requests for this exact runner and policy share a fixed batch.
  func submitIndependentText(_ request: MLXGemmaRunner.IndependentTextRequest,
    runnerEpoch: UUID, compatibility: String,
    perform: @escaping @Sendable ([MLXGemmaRunner.IndependentTextRequest], CancellationFlag) async -> [Result<MLXGemmaRunner.Output, Error>]
  ) async throws -> MLXGemmaRunner.Output {
    let result = await withCheckedContinuation { continuation in
      waiting.append(.text(TextWaiting(request: request, epoch: runnerEpoch,
        compatibility: compatibility, perform: perform, continuation: continuation)))
      if occupied {
        if background { activeFlag?.cancel(); cancelProducer?() }
      } else { startNext() }
    }
    return try result.get()
  }
  func own<R: Sendable, E: Error>(_ task: Task<R, E>) {
    cancelProducer = { task.cancel() }
    producer = Task { _ = try? await task.value }
    if activeFlag?.isCancelled == true { task.cancel() }
  }
  func cancel(runnerEpoch: UUID) {
    if self.runnerEpoch == runnerEpoch { activeFlag?.cancel(); cancelProducer?() }
    for queued in waiting where queued.epoch == runnerEpoch { queued.cancel() }
  }
  private func startNext() {
    guard !waiting.isEmpty else { occupied = false; background = false; return }
    func eligible(_ item: Waiting) -> Bool {
      if case .operation(nil, _, _, _) = item { return speech == nil }
      return true
    }
    guard let index = waiting.firstIndex(where: { !$0.isBackground && eligible($0) })
      ?? waiting.firstIndex(where: eligible) else { occupied = false; background = false; return }
    switch waiting.remove(at: index) {
    case .operation(let flag, let background, let epoch, let continuation):
      admitOwner(flag: flag, background: background, runnerEpoch: epoch); continuation.resume()
    case .text(let first):
      let flag = CancellationFlag()
      admitOwner(flag: flag, background: false, runnerEpoch: first.epoch)
      // Reserve the existing owner before yielding once to other ready callers.
      // There is no batching timer and no new request may join after this step.
      Task { await Task.yield(); self.beginTextCohort(first: first, flag: flag) }
    }
  }
  private func beginTextCohort(first: TextWaiting, flag: CancellationFlag) {
    var selected = [first]
    var index = 0
    while selected.count < 4, index < waiting.count {
      if case .text(let next) = waiting[index], next.epoch == first.epoch,
        next.compatibility == first.compatibility {
        selected.append(next); waiting.remove(at: index)
      } else { index += 1 }
    }
    let cohortWaiting = selected
    let requests = cohortWaiting.map(\.request)
    let work = Task(priority: .userInitiated) {
      let cancellations = requests.map { request in
        request.flag.onCancel {
          if requests.allSatisfy({ $0.flag.isCancelled }) { flag.cancel() }
        }
      }
      defer {
        for (request, registration) in zip(requests, cancellations) {
          request.flag.removeCancellationHandler(registration)
        }
      }
      if requests.allSatisfy({ $0.flag.isCancelled }) {
        return requests.map { _ in Result<MLXGemmaRunner.Output, Error>.failure(CancellationError()) }
      }
      return await first.perform(requests, flag)
    }
    let cancellation = flag.onCancel { work.cancel() }
    own(work)
    Task {
      let results = await work.value // actual body/fence, not a row cancellation
      flag.removeCancellationHandler(cancellation)
      await self.completeText(cohortWaiting, results: results)
    }
  }
  private func completeText(_ selected: [TextWaiting], results: [Result<MLXGemmaRunner.Output, Error>]) async {
    await leave()
    for (index, request) in selected.enumerated() {
      request.continuation.resume(returning: results.indices.contains(index) ? results[index]
        : .failure(BoomError.invalid("The real cohort returned another row count.")))
    }
  }
  func leave() async {
    if let producer { await producer.value }
    producer = nil; cancelProducer = nil; activeFlag = nil; runnerEpoch = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil; startNext()
  }
}

/// Mutable model state is confined to this actor and ModelContainer.
actor MLXGemmaRunner {
  /// Time the existing fence without introducing another GPU wait.
  private nonisolated static func synchronizeGPU() {
    let trace = PerformanceTrace.begin("Model.FinalFence")
    defer { PerformanceTrace.end("Model.FinalFence", trace) }
    Stream.defaultStream.synchronize()
  }
  struct PrefillProgress: Sendable {
    let operationID: UUID
    let processedPositions: Int
    let totalPositions: Int
  }
  struct Output: Codable, Sendable {
    let text: String
    let tokenIDs: [Int]
    let promptDigest: String
    let promptTokens: Int
    let outputTokens: Int
    let endedByEOS: Bool
    let stopReason: String
    let stopTokenID: Int?
    let firstTokenSeconds: Double?
    let elapsedSeconds: Double
    var executionPriority: UInt8? = nil
    var setupMetrics: SetupMetrics? = nil
    var prefillCacheMetrics: PrefillCacheMetrics? = nil
    var executionOrigin: GenerationExecutionOrigin? = nil
    var mtp: BlessengerMTPExecution? = nil
  }
  struct PrefillCacheMetrics: Codable, Sendable {
    let algorithm: String
    let cachedPromptTokens: Int
    let prefilledPromptTokens: Int
    let fullPromptTokens: Int
    let preservesChunkBoundaries: Bool
    let originalGeometry: PromptCacheGeometry
    let suffixGeometry: PromptCacheGeometry
    let missReason: String?
    let contextReclamation: ContextReclamationMetrics?
    let cachedOrigin: PromptPrefixCache.Origin?
    let cachedBatchWidth: Int?
    let cachedRow: Int?
    let cachedForwardHistory: [PromptPrefixCache.ForwardSegment]
    var cachedJoinedRetentionProvenance: JoinedKVRetentionProvenance? = nil
    var residentTensorBytes: UInt64? = nil
    var residentTensorByteLimit: UInt64? = nil
    var residentTensorBytesAfter: UInt64? = nil
    // Staging fields above retain the 1 GiB contract. Native working ownership
    // and true parent aliases are separately charged by the application budget.
    var nativeTensorBytes: UInt64? = nil
    var nativeTensorBytesAfter: UInt64? = nil
    var cachedNativePhysicalWidth: Int? = nil
    var nativeAdmission: IncrementalKVAdmission? = nil
    var nativeReadmission: ActiveNativeKVReadmissionObservation? = nil
    // CPU lookup and hydration graph construction; submitted GPU copies finish
    // inside later preparation/evaluation and the end-to-end first-token timer.
    var lookupReturnedSeconds: Double? = nil
  }
  struct ContextReclamationMetrics: Codable, Sendable {
    let reason: String
    let requestedContext: Int
    let batchWidth: Int
    let capacityBefore: Int
    let capacityAfter: Int
    let retainedAnchorTokenCounts: [Int]
    let retainedBytesUpperBound: UInt64
    let processFootprintBefore: UInt64
    let processFootprintAfter: UInt64
    let allocatorActiveBefore: Int
    let allocatorActiveAfter: Int
    let allocatorCacheBefore: Int
    let allocatorCacheAfter: Int
  }
  /// Native execution observations, separate from replay and sampling policy.
  /// A returned setup call may still have queued GPU work; it is not a GPU timer.
  struct SetupMetrics: Codable, Sendable {
    let path: String
    let returnedSeconds: Double
    let threadQoSBefore: UInt32
    let threadQoSAfter: UInt32
    let firstDeliveryThreadQoS: UInt32?
    let tokenShape: [Int]
    let maskShape: [Int]?
  }
  struct BatchMetrics: Codable, Sendable {
    let width: Int
    let sharedPromptPrefills: Int
    let decodeForwardPasses: Int
    let cacheBatchDimensions: [Int]
    var prefillCacheMetrics: PrefillCacheMetrics? = nil
  }
  struct BatchCheckpoint: Sendable {
    let lane: Int
    let progress: GenerationProgress
    let stopReason: String?
    let stopTokenID: Int?
  }
  private var assistant: MTPDrafterContainer?
  private var assistantWeights: ModelWeightLease?
  private var assistantIdentity: String?
  private let weightLease: ModelWeightLease
  nonisolated let source: URL
  nonisolated let identity: String
  nonisolated let generationPolicy: ModelGenerationPolicy
  nonisolated let supportsRawAudio: Bool
  nonisolated let cacheRunnerEpoch = UUID()
  nonisolated let processorIdentity: String
  private nonisolated let verifiedStatelessTextKV: Bool
  private let container: ModelContainer
  // Stored anchors are immutable; the manager synchronizes eviction and epochs.
  // Working caches remain confined to the exclusive inference executor.
  private nonisolated let promptCache: PromptPrefixCache
  private let cacheConfiguration: Data
  private nonisolated let verifiedContextCeiling: Int
  private let tokenizerDescription: Data
  private var contextVocabulary: ContextVocabulary?
  private struct Configuration: Decodable {
    let model_type: String
    let text_config: Text
    struct Text: Decodable {
      let vocab_size: Int
      let max_position_embeddings: Int
      let num_hidden_layers: Int
      let num_key_value_heads: Int
      let head_dim: Int
    }
  }
  private struct TokenizerFile: Decodable {
    let added_tokens: [Added]
    struct Added: Decodable { let id: Int; let special: Bool }
  }
  static func load(admission: ModelPacks.Admission, prefillTokens: UInt32? = nil, cacheProtection: RecordCipher? = nil) async throws -> MLXGemmaRunner {
    let trace = PerformanceTrace.begin("Model.Load")
    defer { PerformanceTrace.end("Model.Load", trace) }
    let directory = admission.directory
    await GenerationCoordinator.shared.enter()
    do {
      try Task.checkCancellation()
      try ModelResidency.configure()
      let weightLease = try ModelWeightLease(bytes: admission.weightBytes)
      let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
      let config = try JSONDecoder().decode(Configuration.self,
        from: configuration)
      let text = config.text_config
      guard ["gemma4_unified", "gemma4"].contains(config.model_type), text.max_position_embeddings > 0,
        text.num_hidden_layers > 0, text.num_key_value_heads > 0, text.head_dim > 0
      else { throw BoomError.invalid("This is not a supported Gemma 4 model.") }
      let tokenizerDescription = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
      let tokenizer = try JSONDecoder().decode(TokenizerFile.self, from: tokenizerDescription)
      let generationURL = directory.appendingPathComponent("generation_config.json")
      let generationDescription = try Data(contentsOf: generationURL)
      let tokenizerConfigurationURL = directory.appendingPathComponent("tokenizer_config.json")
      let tokenizerConfiguration = try Data(contentsOf: tokenizerConfigurationURL)
      let processorDescriptions = try processorMetadata(directory)
      let model = try await VLMModelFactory.shared.loadContainer(
        from: directory, using: CheckpointTokenizerLoader())
      guard configuration == (try Data(contentsOf: directory.appendingPathComponent("config.json"))),
        processorDescriptions == (try processorMetadata(directory)),
        tokenizerDescription == (try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))),
        tokenizerConfiguration == (try Data(contentsOf: tokenizerConfigurationURL)),
        generationDescription == (try Data(contentsOf: generationURL)) else {
        throw BoomError.stale("The model, processor or tokenizer configuration changed while the model was loading.")
      }
      if admission.purpose == .consultation {
        // Admit the actual chat action before advertising consultation as ready.
        // This catches a missing or incompatible checkpoint template at load,
        // without a generated response or any network access.
        _ = try await model.perform { context in
          let input = try await context.processor.prepare(input: UserInput(chat: [.user("Ready.")],
            additionalContext: ["enable_thinking": false]))
          return input.text.tokens.size
        }
      }
      let tokenizerEnds = await model.perform { ($0.tokenizer.eosTokenId, $0.tokenizer.unknownTokenId) }
      let controls = tokenizer.added_tokens.filter(\.special).map(\.id) + (tokenizerEnds.1.map { [$0] } ?? [])
      let policy = try ProductCore.generationPolicy(vocabularySize: text.vocab_size,
        configuration: generationDescription, controls: controls, tokenizerEOS: tokenizerEnds.0,
        prefillTokens: prefillTokens)
      guard let object = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        let cacheConfiguration = object["text_config"] as? [String: Any] else {
        throw BoomError.invalid("Missing model cache configuration.")
      }
      let loadedTypes = await model.perform { context in
        (String(reflecting: type(of: context.model)), String(reflecting: type(of: context.processor)),
          String(reflecting: type(of: context.tokenizer)),
          context.model is Gemma4 || context.model is Gemma4Unified)
      }
      let processorBinding = LoadedProcessorBinding(modelType: loadedTypes.0,
        processorType: loadedTypes.1, tokenizerType: loadedTypes.2,
        modelConfiguration: Digest.sha256(configuration), tokenizer: Digest.sha256(tokenizerDescription),
        tokenizerConfiguration: Digest.sha256(tokenizerConfiguration),
        processorConfigurations: processorDescriptions.mapValues { Digest.sha256($0) },
        tokenizerAdapter: "checkpoint-no-cleanup-v1")
      let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
      let runner = MLXGemmaRunner(source: directory, container: model, weightLease: weightLease,
        identity: admission.identity,
        cacheConfiguration: try JSONSerialization.data(withJSONObject: cacheConfiguration),
        generationPolicy: policy, tokenizerDescription: tokenizerDescription,
        processorIdentity: Digest.sha256(try encoder.encode(processorBinding)),
        verifiedStatelessTextKV: loadedTypes.3, verifiedContextCeiling: min(16_384, text.max_position_embeddings),
        supportsRawAudio: config.model_type == "gemma4_unified" && object["audio_config"] != nil, cacheProtection: cacheProtection)
      try ModelResidency.check()
      guard try runner.availableContext() >= 1024 else {
        throw BoomError.budget("The model leaves too little memory for a useful context.")
      }
      await GenerationCoordinator.shared.leave()
      return runner
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  private init(source: URL, container: ModelContainer, weightLease: ModelWeightLease, identity: String,
    cacheConfiguration: Data, generationPolicy: ModelGenerationPolicy, tokenizerDescription: Data,
    processorIdentity: String, verifiedStatelessTextKV: Bool, verifiedContextCeiling: Int, supportsRawAudio: Bool, cacheProtection: RecordCipher?) {
    self.source = source; self.identity = identity; self.weightLease = weightLease
    promptCache = PromptPrefixCache(protection: cacheProtection)
    self.container = container; self.cacheConfiguration = cacheConfiguration
    self.verifiedContextCeiling = verifiedContextCeiling
    self.generationPolicy = generationPolicy
    self.tokenizerDescription = tokenizerDescription
    self.supportsRawAudio = supportsRawAudio
    self.processorIdentity = processorIdentity; self.verifiedStatelessTextKV = verifiedStatelessTextKV
  }
  private struct LoadedProcessorBinding: Codable {
    let modelType: String
    let processorType: String
    let tokenizerType: String
    let modelConfiguration: String
    let tokenizer: String
    let tokenizerConfiguration: String
    let processorConfigurations: [String: String]
    let tokenizerAdapter: String
  }
  private static func processorMetadata(_ directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in ["preprocessor_config.json", "processor_config.json"] {
      let url = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { result[name] = try Data(contentsOf: url) }
    }
    return result
  }
  private nonisolated static func policyDigest(_ policy: ModelGenerationPolicy) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return Digest.sha256(try encoder.encode(policy))
  }
  private nonisolated func forwardOperandModelBinding(_ policy: ModelGenerationPolicy) throws -> String {
    struct Binding: Encodable {
      let scope: String; let model: String; let processor: String; let configuration: String
      let policy: String; let cacheAlgorithm: String
    }
    return try Digest.identity(Binding(scope: ForwardOperandBinding.scope, model: identity,
      processor: processorIdentity, configuration: Digest.sha256(cacheConfiguration),
      policy: Self.policyDigest(policy), cacheAlgorithm: PromptPrefixCache.activeAlgorithm))
  }
  private nonisolated static func forwardOperandRequest(owner: PromptCacheOwner?, prepared: [Int],
    seed: UInt64?, output: Int, settings: SamplingSettings, row: Int, request: String? = nil) throws -> String {
    struct Request: Encodable {
      let owner: PromptCacheOwner?; let tokens: String; let seed: UInt64?
      let output: Int; let sampling: String; let row: Int; let request: String?
    }
    guard let tokens = ForwardOperandBinding.tokenDigest([prepared]) else {
      throw BoomError.invalid("Invalid original text operands.")
    }
    return try Digest.identity(Request(owner: owner, tokens: tokens, seed: seed, output: output,
      sampling: Digest.identity(settings), row: row, request: request))
  }
  nonisolated func joinedRetentionBinding(owner: PromptCacheOwner, workspaceEpoch: UUID,
    operationID: UUID, policy: ModelGenerationPolicy) throws -> JoinedKVRetentionBinding? {
    guard verifiedStatelessTextKV else { return nil }
    let resolved = try ProductCore.resolvedGenerationPolicy(policy, loaded: generationPolicy)
    return JoinedKVRetentionBinding(owner: owner, workspaceEpoch: workspaceEpoch,
      runnerEpoch: cacheRunnerEpoch, modelIdentity: identity, processorIdentity: processorIdentity,
      policyDigest: try Self.policyDigest(resolved), operationID: operationID)
  }
  private nonisolated func admittedJoinedBinding(_ request: JoinedKVRetentionRequest?,
    owner: PromptCacheOwner?, operationID: UUID, policy: ModelGenerationPolicy,
    input: LMInput, parameters: GenerateParameters) throws -> JoinedKVRetentionBinding? {
    guard let request else { return nil }
    let b = request.binding
    guard verifiedStatelessTextKV, b.owner == owner, b.operationID == operationID,
      b.runnerEpoch == cacheRunnerEpoch, b.modelIdentity == identity,
      b.processorIdentity == processorIdentity, b.policyDigest == (try Self.policyDigest(policy)),
      input.text.mask == nil, input.image == nil, input.video == nil, input.audio == nil,
      parameters.kvCache == nil, parameters.kvBits == nil, parameters.kvScheme == nil,
      parameters.maxKVSize == nil else { request.authorization.revoke(); return nil }
    return b
  }
  private nonisolated func availableContext(batchWidth: Int = 1) throws -> Int {
    guard let prefill = generationPolicy.prefill else { throw BoomError.invalid("The loaded model has no prefill geometry.") }
    return try ProductCore.contextCapacity(configuration: cacheConfiguration,
      available: ModelResidency.availableBytes(), width: batchWidth, prefill: prefill)
  }
  private nonisolated func nativeContextCeiling() throws -> Int { verifiedContextCeiling }
  private nonisolated func admitNativeAllowance(_ additional: UInt64, limits: ResidencyLimits) throws -> IncrementalKVAdmission {
    let process = ModelResidency.footprint()
    guard process > 0 else { throw BoomError.unavailable("Process memory accounting is unavailable.") }
    let active = UInt64(max(0, Memory.activeMemory)), pooled = UInt64(max(0, Memory.cacheMemory))
    let (allocator, overflow) = active.addingReportingOverflow(pooled)
    guard !overflow else { throw BoomError.budget("Allocator accounting overflowed.") }
    let result = try ProductCore.incrementalKVReadmission(application: limits.applicationBytes,
      used: max(process, allocator), reserve: limits.workingReserveBytes, allocation: additional)
    guard result.admitted else { throw BoomError.budget("The native cache continuation does not fit the measured application budget.") }
    return result
  }
  private nonisolated func nativeAllocationBound(_ plan: ActiveNativeKVAdmissionPlan,
    limits: ResidencyLimits, width: Int, forwards: Int, hydration: Bool) throws -> UInt64 {
    try ProductCore.incrementalKVAdmission(application: limits.applicationBytes, used: 0,
      reserve: limits.workingReserveBytes,
      layers: plan.transitionAllocations(width: width, forwards: forwards, hydration: hydration)).additionalBytesUpperBound
  }
  private nonisolated func admitNativePlan(_ plan: ActiveNativeKVAdmissionPlan) throws -> IncrementalKVAdmission {
    let (required, overflow) = plan.promptTokenCount.addingReportingOverflow(plan.reservedOutputTokenCount)
    guard !overflow, required <= verifiedContextCeiling else { throw BoomError.budget("The request exceeds the native context ceiling.") }
    let limits = try ModelResidency.limits()
    // Width-one constructor can reach its final tail without another cancellation
    // check. Actual hydration plus two such forwards are admitted before transfer.
    let bound = try nativeAllocationBound(plan, limits: limits, width: 1, forwards: 2, hydration: true)
    return try admitNativeAllowance(bound, limits: limits)
  }
  private nonisolated func makeNativeReadmission(_ plan: ActiveNativeKVAdmissionPlan,
    flag: CancellationFlag, authorization: JoinedKVRetentionAuthorization?) throws -> ActiveNativeKVReadmission {
    let limits = try ModelResidency.limits()
    // Native shapes/dtypes and Rust allocation algebra are resolved once. The
    // per-forward path reads actual U and passes only three scalar bounds to Rust.
    let one = try nativeAllocationBound(plan, limits: limits, width: 1, forwards: 1, hydration: false)
    let two = try nativeAllocationBound(plan, limits: limits, width: 1, forwards: 2, hydration: false)
    let batch = plan.consumerWidth == 1 ? one : try nativeAllocationBound(plan, limits: limits,
      width: plan.consumerWidth, forwards: 1, hydration: false)
    return ActiveNativeKVReadmission(flag: flag, authorization: authorization) { width, forwards in
      let bound: UInt64
      if width == 1, forwards == 1 { bound = one }
      else if width == 1, forwards == 2 { bound = two }
      else if width == plan.consumerWidth, forwards == 1 { bound = batch }
      else { throw BoomError.invalid("The active native KV forward changed its admitted shape.") }
      _ = try self.admitNativeAllowance(bound, limits: limits)
    }
  }
  private nonisolated func canUseNative(_ input: LMInput, owner: PromptCacheOwner?) -> Bool {
    let sequence = input.text.tokens.ndim == 1 || input.text.tokens.ndim == 2 && input.text.tokens.dim(0) == 1
    return verifiedStatelessTextKV && owner != nil && sequence && input.text.mask == nil
      && input.image == nil && input.video == nil && input.audio == nil
  }
  private nonisolated func pairedAdmissionRequest(ids: [Int], owner: PromptCacheOwner?, output: Int,
    width: Int, policy: ModelGenerationPolicy, flag: CancellationFlag,
    attempt: PairedAdmissionAttempt) throws -> PreparedPairedAdmissionRequest? {
    guard attempt.deferReclamation || attempt.expected != nil else { return nil }
    try flag.check()
    let request = PreparedPairedAdmissionRequest(operationID: flag.operationID,
      runnerEpoch: cacheRunnerEpoch, modelIdentity: identity, processorIdentity: processorIdentity,
      owner: owner, tokenIDs: ids, outputTokens: output, batchWidth: width, policy: policy)
    try attempt.validate(request)
    return request
  }
  /// Read-only native selection/real admission comes first. An opt-in handoff
  /// exits the lease before the caller joins a peer; it clears no requested KV.
  private nonisolated func preparedCapacityOwned(input: LMInput, ids: [Int], owner: PromptCacheOwner?,
    output: Int, width: Int, prefill: PrefillParameters, policy: ModelGenerationPolicy,
    flag: CancellationFlag, attempt: PairedAdmissionAttempt = .normal) throws -> Int {
    let request = try pairedAdmissionRequest(ids: ids, owner: owner, output: output,
      width: width, policy: policy, flag: flag, attempt: attempt)
    let (required, overflow) = ids.count.addingReportingOverflow(output)
    guard !overflow else { throw BoomError.budget("The prepared context reservation overflowed.") }
    let canDefer = attempt.deferReclamation && required <= verifiedContextCeiling
    if canUseNative(input, owner: owner),
      let plan = try promptCache.nativeAdmissionPlan(owner: owner, tokens: ids,
        prefill: prefill, outputTokens: output, batchWidth: width) {
      do { _ = try admitNativePlan(plan); return try nativeContextCeiling() }
      catch BoomError.budget {
        if canDefer, let request { throw request }
        // After the one real peer opportunity, existing measured fallback applies.
      }
    }
    if canDefer, try availableContext(batchWidth: width) < required, let request { throw request }
    return try requestCapacityOwned(required: required, batchWidth: width,
      forceCold: owner == nil).capacity
  }
  /// Only under the generation coordinator and on the inference executor.
  /// Reclaim once before a real fit failure; ordinary capacity reads keep KV.
  private nonisolated func requestCapacityOwned(required: Int, batchWidth: Int = 1,
    forceCold: Bool = false, reclaimBeforeTrimming: Bool = false
  ) throws -> (capacity: Int, reclamation: ContextReclamationMetrics?) {
    let before = try availableContext(batchWidth: batchWidth)
    let hasAnchors = promptCache.hasAnchors
    let needsReclamation = (required <= 16_384 && before < required)
      || reclaimBeforeTrimming && before < 16_384 && hasAnchors
    guard needsReclamation || forceCold && hasAnchors else {
      if forceCold { promptCache.clear(reason: "forced_cold") }
      return (before, nil)
    }
    let trace = PerformanceTrace.begin("Model.ContextReclamation")
    defer { PerformanceTrace.end("Model.ContextReclamation", trace) }
    let reason = forceCold ? "forced_cold" : "residency_evicted"
    let counts = promptCache.retainedAnchorTokenCounts, retained = promptCache.retainedBytesUpperBound
    let processBefore = ModelResidency.memoryAccounting().current
    let activeBefore = Memory.activeMemory, cacheBefore = Memory.cacheMemory
    promptCache.clear(reason: reason)
    Memory.clearCache()
    let after = try availableContext(batchWidth: batchWidth)
    return (after, ContextReclamationMetrics(reason: reason, requestedContext: required,
      batchWidth: batchWidth, capacityBefore: before, capacityAfter: after,
      retainedAnchorTokenCounts: counts, retainedBytesUpperBound: retained,
      processFootprintBefore: processBefore, processFootprintAfter: ModelResidency.memoryAccounting().current,
      allocatorActiveBefore: activeBefore, allocatorActiveAfter: Memory.activeMemory,
      allocatorCacheBefore: cacheBefore, allocatorCacheAfter: Memory.cacheMemory))
  }
  private nonisolated func prefillParameters(_ callback: (@Sendable (PrefillProgress) -> Void)?,
    operationID: UUID, policy: ModelGenerationPolicy) throws -> PrefillParameters {
    guard let geometry = policy.prefill else { throw BoomError.invalid("The loaded model has no prefill geometry.") }
    let chunking: PrefillParameters.Chunking
    switch geometry.chunking {
    case "balanced_v1": chunking = .balanced
    case "fixed_v1": chunking = .remainder
    default: throw BoomError.invalid("Unsupported captured prefill geometry.")
    }
    return PrefillParameters(stepSize: geometry.tokenCeiling, chunking: chunking,
      progress: { processed, total in
        PerformanceTrace.prefill(processed: processed, total: total)
        callback?(PrefillProgress(operationID: operationID, processedPositions: processed, totalPositions: total))
      })
  }
  /// Explicit public diagnostic only; ordinary generation never enters this path.
  func diagnosticPrefixParity(_ request: NeuralPrefixParitySmoke.Request,
    evidence: URL) async throws -> NeuralPrefixParitySmoke.CaseSummary {
    guard request.query.model == identity else { throw BoomError.invalid("The public parity model identity changed.") }
    let policy = try ProductCore.resolvedGenerationPolicy(request.query.generation_policy, loaded: generationPolicy)
    guard policy.prefill == PrefillGeometry(chunking: "fixed_v1", tokenCeiling: 512) else {
      throw BoomError.invalid("The bounded parity control requires its recorded fixed policy.")
    }
    for input in request.inputs {
      guard try ProductCore.resolvedGenerationPolicy(input.generation_policy, loaded: generationPolicy) == policy else {
        throw BoomError.invalid("The original/current public execution policies differ.")
      }
    }
    guard let config = try JSONSerialization.jsonObject(with: cacheConfiguration) as? [String: Any],
      let window = config["sliding_window"] as? Int, window > 0,
      let layers = config["layer_types"] as? [String], !layers.isEmpty,
      let count = config["num_hidden_layers"] as? Int, layers.count == count,
      layers.allSatisfy({ ["full_attention", "sliding_attention"].contains($0) }) else {
      throw BoomError.invalid("The actual model has no complete native attention-mask geometry.")
    }
    // Pinned Gemma4.newCache creates the owning prefix of layer_types; the engine
    // selects its actual cache count dynamically, including no shared-KV slots.
    let windows: [Int?] = layers.map { $0 == "full_attention" ? nil : window }
    let flag = CancellationFlag()
    let prefill = try prefillParameters(nil, operationID: flag.operationID, policy: policy)
    let allowSnapshot = try Self.cacheRetentionGuard()
    return try await ownedOperation(flag: flag, background: false) {
      try await self.container.perform { (context: ModelContext) async throws -> NeuralPrefixParitySmoke.CaseSummary in
        try await InferenceExecutor.shared.perform { _ in
          defer { Self.synchronizeGPU() }
          try flag.check(); try ModelResidency.check()
          for captured in request.inputs {
            let input: LMInput
            if let plan = captured.plan {
              input = try await Self.chatInput(plan, images: [], context: context)
            } else if let raw = captured.prompt {
              input = try RawWritingInput.prepare(raw, media: [], context: context)
            } else { throw BoomError.invalid("The public parity input has no compiled source.") }
            guard input.image == nil, input.video == nil, input.audio == nil, input.text.mask == nil,
              input.text.tokens.asArray(Int.self) == captured.prepared_token_ids else {
              throw BoomError.stale("The actual loaded processor changed a public prepared token ledger.")
            }
          }
          let required = (request.inputs.map { $0.prepared_token_ids.count }.max() ?? 0) + 16
          let capacity = try self.requestCapacityOwned(required: required,
            batchWidth: request.declaration.sharedWidth, forceCold: false)
          guard capacity.capacity >= required else { throw BoomError.budget("Insufficient context for the bounded public parity control.") }
          return try await NeuralPrefixParitySmoke.execute(request, model: context.model, manager: self.promptCache,
            prefill: prefill, policy: policy, layerWindows: windows, flag: flag,
            allowSnapshot: allowSnapshot, fence: { Self.synchronizeGPU() }, evidence: evidence)
        }
      }
    }
  }

  nonisolated func invalidatePromptCacheRetention(reason: String) { promptCache.clear(reason: reason) }
  func clearPromptCache() async {
    await InferenceExecutor.shared.perform { _ in self.promptCache.clear() }
    await promptCache.joinPendingDiskCleanup()
  }
  func diagnosticCacheSnapshots() -> [PromptPrefixCache.SnapshotObservation] {
    promptCache.retainedLookupSnapshotObservations
  }
  /// Preserve the active-owner observation contract for constructor controls
  /// that require one physically retained native row after joined cancellation.
  func diagnosticActiveCacheSnapshots() -> [PromptPrefixCache.SnapshotObservation] {
    promptCache.retainedSnapshotObservations
  }
  /// Resolve the policy once; the update tap reads only measured accounting.
  private nonisolated static func cacheRetentionGuard() throws -> @Sendable (UInt64) -> Bool {
    let limits = try ModelResidency.limits()
    return { incoming in
      let process = ModelResidency.footprint()
      guard process > 0 else { return false }
      let active = UInt64(max(0, Memory.activeMemory)), pool = UInt64(max(0, Memory.cacheMemory))
      let (allocator, allocatorOverflow) = active.addingReportingOverflow(pool)
      let (reserved, reserveOverflow) = incoming.addingReportingOverflow(limits.workingReserveBytes)
      guard !allocatorOverflow, !reserveOverflow else { return false }
      let used = max(process, allocator)
      return used <= limits.applicationBytes && reserved <= limits.applicationBytes - used
    }
  }
  private nonisolated static func cacheMetrics(_ session: PromptPrefixCache.Session,
    owner: PromptCacheOwner?, reclamation: ContextReclamationMetrics? = nil) -> PrefillCacheMetrics? {
    guard owner != nil else { return nil }
    return PrefillCacheMetrics(algorithm: session.observation.algorithm,
      cachedPromptTokens: session.cachedTokenCount,
      prefilledPromptTokens: session.fullPromptTokenCount - session.cachedTokenCount,
      fullPromptTokens: session.fullPromptTokenCount,
      preservesChunkBoundaries: session.preservesChunkBoundaries,
      originalGeometry: session.observation.originalGeometry,
      suffixGeometry: session.observation.suffixGeometry,
      missReason: session.observation.missReason, contextReclamation: reclamation,
      cachedOrigin: session.observation.cachedOrigin,
      cachedBatchWidth: session.observation.cachedBatchWidth,
      cachedRow: session.observation.cachedRow,
      cachedForwardHistory: session.observation.cachedForwardHistory,
      cachedJoinedRetentionProvenance: session.observation.cachedJoinedRetentionProvenance,
      residentTensorBytes: session.observation.retainedBytes,
      residentTensorByteLimit: session.observation.byteLimit)
  }
  var contextLength: Int { (try? availableContext()) ?? 0 }
  func contextLength(batchWidth: Int) throws -> Int { try availableContext(batchWidth: batchWidth) }
  func tokenCount(_ text: String) async -> Int {
    await container.perform { $0.tokenizer.encode(text: text, addSpecialTokens: false).count }
  }
  func diagnosticTokenIDs(_ text: String) async -> [Int] {
    await container.perform { $0.tokenizer.encode(text: text, addSpecialTokens: false) }
  }
  /// Public diagnostic fixture construction using this exact loaded tokenizer.
  func diagnosticPrefix(tokens: Int) async throws -> String {
    guard (1...16_384).contains(tokens) else { throw BoomError.invalid("Invalid public fixture token bound.") }
    return try await container.perform { context in
      let authored = "<bos>" + String(repeating:
        "The harbor was quiet. A light moved across the water, and the keeper watched from the window.\n", count: 1024)
      let ids = context.tokenizer.encode(text: authored, addSpecialTokens: false)
      let text = context.tokenizer.decode(tokenIds: Array(ids.prefix(tokens)))
      guard context.tokenizer.encode(text: text, addSpecialTokens: false).count == tokens else {
        throw BoomError.invalid("Public fixture did not round-trip to the requested exact token count.")
      }
      return text
    }
  }
  func tokenCount(_ plan: ConsultationPlan) async throws -> Int {
    await GenerationCoordinator.shared.enter()
    do {
      let count = try await container.perform { context in
        try await Self.chatInput(plan, images: [], context: context).text.tokens.size
      }
      await GenerationCoordinator.shared.leave(); return count
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  func diagnosticTokenIDs(_ plan: ConsultationPlan) async throws -> [Int] {
    await GenerationCoordinator.shared.enter()
    do {
      let ids = try await container.perform { context in
        try await Self.chatInput(plan, images: [], context: context).text.tokens.asArray(Int.self)
      }
      await GenerationCoordinator.shared.leave(); return ids
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  private func writingVocabulary(tokenizer: any MLXLMCommon.Tokenizer, flag: CancellationFlag) throws -> ContextVocabulary {
    if let contextVocabulary { return contextVocabulary }
    guard let description = try JSONSerialization.jsonObject(with: tokenizerDescription) as? [String: Any],
      var model = description["model"] as? [String: Any], let vocabulary = model["vocab"] as? NSDictionary,
      let added = description["added_tokens"] as? [[String: Any]],
      let normalizer = description["normalizer"], let preTokenizer = description["pre_tokenizer"] else {
      throw BoomError.invalid("Invalid writing tokenizer description.")
    }
    // Use the loaded tokenizer's exact strings. A Swift dictionary keyed by
    // String would collapse canonically equivalent vocabulary entries.
    let ids = vocabulary.allValues.compactMap { ($0 as? NSNumber)?.intValue }
      + added.compactMap { ($0["id"] as? NSNumber)?.intValue }
    var words: [String] = []; words.reserveCapacity(ids.count)
    for id in Set(ids) {
      try flag.check()
      guard let word = tokenizer.convertIdToToken(id) else { throw BoomError.invalid("The loaded tokenizer has an incomplete vocabulary.") }
      words.append(word)
    }
    model.removeValue(forKey: "vocab"); model.removeValue(forKey: "merges")
    let dictionary = try ProductCore.contextVocabulary(["vocabulary": words, "normalizer": normalizer,
      "preTokenizer": preTokenizer, "model": model, "addedTokens": added])
    contextVocabulary = dictionary
    return dictionary
  }
  func writingContext(document: DocumentSnapshot, caret: Int, examples: [String], capacity: Int,
    flag: CancellationFlag, media: [WritingMediaData] = []) async throws -> (WritingPrompt, Int) {
    try flag.check()
    let tokenizer = await container.perform { $0.tokenizer }
    let dictionary = try writingVocabulary(tokenizer: tokenizer, flag: flag)
    var step = try ProductCore.writingContext(document, caret: caret, examples: examples,
      capacity: capacity, dictionary: dictionary, media: media.map(\.reference))
    defer { ProductCore.releaseContext(step.id) }
    while step.status == "candidate", let prompt = step.candidate {
      try flag.check()
      let count: Int
      if media.isEmpty { count = tokenizer.encode(text: prompt.prompt, addSpecialTokens: false).count }
      else {
        let compiled = try RawWritingInput.compiled(prompt.prompt, media: media.map(\.reference))
        let ordered = try compiled.media.map { reference -> WritingMediaData in
          guard let payload = media.first(where: { $0.reference == reference }) else { throw BoomError.stale(reference.name) }; return payload
        }
        count = try await ownedOperation(flag: flag, background: true) {
          try await self.container.perform { context in
            try await InferenceExecutor.shared.perform { _ in
              defer { Stream.defaultStream.synchronize() }
              return try RawWritingInput.prepare(compiled.prompt, media: ordered, context: context).text.tokens.size
            }
          }
        }
      }
      try flag.check()
      step = try ProductCore.countedContext(step, prompt: prompt, count: count)
      await Task.yield()
    }
    try flag.check()
    guard step.status == "selected", let prompt = step.candidate else {
      throw BoomError.budget("The examples leave no room for text at the caret.")
    }
    return (prompt, step.testedCandidates)
  }
  private static func chatInput(_ plan: ConsultationPlan, images: [Data], media: [WritingMediaData] = [], context: ModelContext) async throws -> LMInput {
    if plan.hasPlacedMedia {
      guard images.isEmpty else { throw BoomError.invalid("Unplaced images cannot accompany captured media history.") }
      return try await placedChatInput(plan, media: media, context: context)
    }
    let pictures = images.map { bytes in WritingMediaData(reference: WritingMediaReference(id: UUID(), name: "Image",
      rootDigest: Digest.sha256(bytes), kind: "image"), bytes: bytes) }
    let payloads = pictures + media
    let links = payloads.map { "[Attachment: media](boom-attachment:\($0.reference.id))" }.joined(separator: "\n")
    let compiled = try RawWritingInput.compiled(links, media: payloads.map(\.reference))
    let ordered = try compiled.media.map { reference -> WritingMediaData in
      guard let payload = payloads.first(where: { $0.reference == reference }) else { throw BoomError.invalid("Captured media changed.") }
      return payload
    }
    let messages = plan.messages.enumerated().map { index, m -> Chat.Message in
      switch m.role {
      case "system": return .system(m.content)
      case "assistant": return .assistant(m.content)
      default:
        guard index == plan.messages.count - 1, !compiled.prompt.isEmpty else { return .user(m.content) }
        if let sound = compiled.prompt.range(of: "<|audio|>") {
          // Images precede the question; the first continuous sound window
          // follows it. Later storyboard windows keep their chronological order.
          return .user(String(compiled.prompt[..<sound.lowerBound]) + m.content + "\n" + compiled.prompt[sound.lowerBound...])
        }
        return .user(compiled.prompt + "\n" + m.content)
      }
    }
    guard !messages.isEmpty else { throw BoomError.invalid("Conversation plan is empty.") }
    // The template handles roles; the shared raw adapter expands media in the
    // captured chronological order without decoding/re-encoding token IDs.
    if !payloads.isEmpty, !(context.model is Gemma4Unified) {
      guard !payloads.contains(where: { $0.reference.kind == "audio" || !$0.audioSegments.isEmpty }) else { throw BoomError.unavailable("This checkpoint cannot read a video soundtrack.") }
      let native = try payloads.flatMap { $0.reference.kind == "image" ? [$0.bytes] : $0.images }.map { UserInput.Image.ciImage(try LocalImage.decode($0)) }
      let plain = plan.messages.enumerated().map { index, m -> Chat.Message in
        if m.role == "system" { return .system(m.content) }
        if m.role == "assistant" { return .assistant(m.content) }
        return .user((index == plan.messages.count - 1 ? compiled.prompt.replacingOccurrences(of: "<|image|>", with: "").replacingOccurrences(of: "<|video|>", with: "") + "\n" : "") + m.content, images: index == plan.messages.count - 1 ? native : [])
      }
      return try await context.processor.prepare(input: UserInput(chat: plain, additionalContext: ["enable_thinking": false]))
    }
    let input = try await context.processor.prepare(input: UserInput(chat: messages,
      additionalContext: ["enable_thinking": false]))
    return try RawWritingInput.prepare(tokens: input.text.tokens.asArray(Int.self), media: ordered, context: context)
  }
  private static func placedChatInput(_ plan: ConsultationPlan, media: [WritingMediaData], context: ModelContext) async throws -> LMInput {
    let expansion = try RawWritingInput.expandChatMedia(plan, media: media)
    let ordered = expansion.media
    let messages = expansion.messages.map { message -> Chat.Message in
      switch message.role {
      case "system": return .system(message.content)
      case "assistant": return .assistant(message.content)
      default: return .user(message.content)
      }
    }
    guard ordered.isEmpty || context.model is Gemma4Unified else {
      throw BoomError.unavailable("This checkpoint cannot preserve the selected chronological raw-media context.")
    }
    let input = try await context.processor.prepare(input: UserInput(chat: messages, additionalContext: ["enable_thinking": false]))
    return try RawWritingInput.prepare(tokens: input.text.tokens.asArray(Int.self), media: ordered, context: context)
  }
  func preflight(_ plan: ConsultationPlan, images: [Data], media: [WritingMediaData] = [], maxTokens: Int,
    flag: CancellationFlag, cacheOwner: PromptCacheOwner? = nil,
    pairedAdmission: PairedContextAdmission? = nil) async throws -> Int {
    try await PairedContextAdmission.perform(using: pairedAdmission, flag: flag) { attempt in
      // Media preparation shares this lease too; no input tensor escapes it.
      await GenerationCoordinator.shared.enter(flag: flag, runnerEpoch: self.cacheRunnerEpoch)
      do {
        try flag.check()
        let (count, capacity) = try await self.container.perform { context in
          try await InferenceExecutor.shared.perform { _ in
            let input = try await Self.chatInput(plan, images: images, media: media, context: context)
            let ids = input.text.tokens.asArray(Int.self)
            let prefill = try self.prefillParameters(nil, operationID: flag.operationID, policy: self.generationPolicy)
            return (ids.count, try self.preparedCapacityOwned(input: input, ids: ids,
              owner: cacheOwner, output: maxTokens, width: 1, prefill: prefill,
              policy: self.generationPolicy, flag: flag, attempt: attempt))
          }
        }
        guard count + maxTokens <= capacity else {
          throw BoomError.budget("The voice, question and sources do not fit. Nothing was sent.")
        }
        try flag.check()
        await GenerationCoordinator.shared.leave()
        return count
      } catch { await GenerationCoordinator.shared.leave(); throw error }
    }
  }
  func fittedRound(voices: [Voice?], history: [ChatMessage], instructions: String, context: String,
    request: String, routing: [String], images: [Data], media: [WritingMediaData] = [], reserves: [Int], flag: CancellationFlag,
    authority: CapturedDocumentAuthority = .readOnly, cacheOwner: PromptCacheOwner? = nil,
    pairedAdmission: PairedContextAdmission? = nil,
    promptContract: ConsultationPromptContract = .referenceHistoryV2,
    renderedContext: RenderedReferenceContext? = nil, capturedSources: [SourceReference] = [],
    historyMedia: [UUID: [UUID]] = [:], currentMedia: [UUID]? = nil
  ) async throws -> (plans: [ConsultationPlan], history: [ChatMessage], omittedHistory: Int,
    context: String, renderedContext: RenderedReferenceContext?, capturedSources: [SourceReference], workingTextBytes: Int?, workingRequestBytes: Int?) {
    let trace = PerformanceTrace.begin("Request.ContextFit")
    defer { PerformanceTrace.end("Request.ContextFit", trace) }
    guard voices.count == reserves.count else { throw BoomError.invalid("Every participant needs an output reservation.") }
    let complete = history.filter { $0.state == .complete }
    var recent: [ChatMessage] = [], historyBytes = 0
    for turn in complete.suffix(4096).reversed() {
      let bytes = turn.text.utf8.count.addingReportingOverflow(turn.context.utf8.count)
      guard !bytes.overflow, bytes.partialValue <= 4_194_304 - historyBytes else { break }
      historyBytes += bytes.partialValue; recent.append(turn)
    }
    recent.reverse()
    var workingContext = context, workingRendered = renderedContext, workingSources = capturedSources
    var workingBytes: Int?, requestBytes: Int?, maximumSources = 32
    func compile(_ turns: [ChatMessage]) async throws -> [ConsultationPlan] {
      try flag.check()
      let plans = try ProductCore.consultationRound(voices: voices, history: turns,
        instructions: instructions, context: workingContext, request: request, routing: routing,
        authority: authority, promptContract: promptContract,
        renderedContext: workingRendered, capturedSources: workingSources, workingTextBytes: workingBytes,
        workingRequestBytes: requestBytes, historyMedia: historyMedia, currentMedia: currentMedia)
      for (plan, reserve) in zip(plans, reserves) {
        _ = try await preflight(plan, images: images, media: media, maxTokens: reserve,
          flag: flag, cacheOwner: cacheOwner, pairedAdmission: pairedAdmission)
      }
      return plans
    }
    do {
      let plans = try await compile(recent)
      return (plans, recent, complete.count - recent.count, workingContext, workingRendered, workingSources, workingBytes, requestBytes)
    } catch BoomError.budget { /* Slide whole older turns before reducing current text. */ }

    var best: [ConsultationPlan]
    while true {
      do { best = try await compile([]); break }
      catch BoomError.budget(let reason) {
        if let bytes = workingBytes {
          if bytes > 0 { workingBytes = bytes / 2 }
          else if maximumSources > 0 { maximumSources /= 2 }
          else {
            // Keep the complete current question ahead of optional prose and
            // source headers. Only now slide its recent Unicode-safe suffix.
            if let bytes = requestBytes {
              guard bytes > 0 else {
                throw BoomError.unavailable("The model cannot reserve this output and media on this Mac. \(reason)")
              }
              requestBytes = bytes / 2
            } else { requestBytes = 32_768 }
            continue // Reference selection is unchanged; do not reread/revalidate it.
          }
        } else { workingBytes = 32_768 }
        if let original = renderedContext {
          let value = try DocumentTools.windowedContext(original, authority: authority,
            capturedSources: capturedSources, bodyBytes: workingBytes ?? 0, maximumSources: maximumSources)
          workingRendered = value; workingContext = value.prompt; workingSources = value.bindings.map(\.source)
        } else {
          // Legacy reference strings have no typed interior ranges. Omit their
          // whole block rather than cutting structured data into false claims.
          workingContext = context.isEmpty ? "" : "[Captured reference data outside the working window]"
        }
      }
    }
    // Every candidate is a whole recent suffix. Binary search avoids repeatedly
    // tokenizing all but one of thousands of old turns.
    var lower = 0, upper = recent.count
    while lower < upper {
      let count = lower + (upper - lower + 1) / 2
      do {
        best = try await compile(Array(recent.suffix(count))); lower = count
      } catch BoomError.budget { upper = count - 1 }
    }
    let retained = Array(recent.suffix(lower))
    return (best, retained, complete.count - retained.count, workingContext, workingRendered, workingSources, workingBytes, requestBytes)
  }
  func completionRecipe(document: DocumentSnapshot, caret: Int, sources: [SourceReference],
    examples: [String], profile: SamplingProfile, maxTokens: Int, flag: CancellationFlag,
    batchWidth: Int = 1, media: [WritingMediaData] = [], cacheOwner: PromptCacheOwner? = nil,
    pairedAdmission: PairedContextAdmission? = nil
  ) async throws -> CompletionRecipe {
    let trace = PerformanceTrace.begin("Request.ContextFit")
    defer { PerformanceTrace.end("Request.ContextFit", trace) }
    let ceiling = try nativeContextCeiling()
    var selected = try await writingContext(document: document, caret: caret, examples: examples,
      capacity: ceiling - maxTokens, flag: flag, media: media).0
    func admittedCapacity(_ prompt: WritingPrompt) async throws -> (Int, Int) {
      try await PairedContextAdmission.perform(using: pairedAdmission, flag: flag) { attempt in
        try await self.ownedOperation(flag: flag, background: true) {
          try await self.container.perform { context in
            try await InferenceExecutor.shared.perform { _ in
              let compiled = try RawWritingInput.compiled(prompt.prompt, media: media.map(\.reference))
              let ordered = try compiled.media.map { reference -> WritingMediaData in
                guard let value = media.first(where: { $0.reference == reference }) else { throw BoomError.stale(reference.name) }; return value
              }
              let input = try RawWritingInput.prepare(compiled.prompt, media: ordered, context: context)
              let ids = input.text.tokens.asArray(Int.self)
              let prefill = try self.prefillParameters(nil, operationID: flag.operationID, policy: self.generationPolicy)
              return (ids.count, try self.preparedCapacityOwned(input: input, ids: ids, owner: cacheOwner,
                output: maxTokens, width: batchWidth, prefill: prefill,
                policy: self.generationPolicy, flag: flag, attempt: attempt))
            }
          }
        }
      }
    }
    let initial = try await admittedCapacity(selected)
    if initial.0 + maxTokens > initial.1 {
      selected = try await writingContext(document: document, caret: caret, examples: examples,
        capacity: initial.1 - maxTokens, flag: flag, media: media).0
      let fitted = try await admittedCapacity(selected)
      guard fitted.0 + maxTokens <= fitted.1 else { throw BoomError.budget("The examples leave no room for text at the caret.") }
    }
    let compiled = try RawWritingInput.compiled(selected.prompt, media: media.map(\.reference))
    return CompletionRecipe(document: document, caretUTF16: caret, sources: sources,
      prompt: compiled.prompt, promptDigest: Digest.sha256(compiled.prompt), omittedPrefixCharacters: selected.omittedCharacters,
      model: identity, profile: profile, settings: try ProductCore.sampling(profile), maxTokens: maxTokens,
      generationPolicy: generationPolicy, sourcePrompt: compiled.media.isEmpty ? nil : selected.prompt,
      media: compiled.media.isEmpty ? nil : compiled.media)
  }
  /// Load the actual four-layer assistant. Merely discovering its files is not
  /// enabling MTP. A mismatched target is refused before loading any weights.
  func prepareMTP() async throws -> String {
    let specification = try BlessengerModelPackage.package(.mtp)
    guard identity == "mlx-community/gemma-4-12B-it-qat-4bit@e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6",
      supportsRawAudio else { throw BoomError.unavailable("This assistant is paired only with the pinned Gemma 4 12B QAT target.") }
    if assistant != nil, assistantIdentity == specification.identity { return specification.identity }
    let directory = try await detachedWork { try specification.local() }
    let requirements = try specification.requirements()
    await GenerationCoordinator.shared.enter()
    do {
      try Task.checkCancellation()
      let weights = try ModelWeightLease(bytes: requirements.weightBytes)
      await Gemma4AssistantRegistration.register()
      let loaded = try await MTPDrafterModelFactory.shared.loadContainer(from: directory, using: CheckpointTokenizerLoader())
      try await detachedWork { try specification.verify(directory) }
      try ModelResidency.check(); assistant = loaded; assistantWeights = weights; assistantIdentity = specification.identity
      await GenerationCoordinator.shared.leave(); return specification.identity
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }

  /// This route deliberately does not claim ordinary native-prefix retention:
  /// the MTP iterator owns staged speculative rows, not acknowledged chat rows.
  /// The normal Bloom cache route is unchanged for non-MTP requests.
  func runMTP(plan: ConsultationPlan, media: [WritingMediaData], maxTokens: Int, seed: UInt64,
    settings: SamplingSettings, flag: CancellationFlag,
    onCheckpoint: @escaping @Sendable (GenerationProgress, String?, Int?) async throws -> Void,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    guard let assistant, let assistantIdentity else { throw BoomError.unavailable("The MTP assistant has not been loaded.") }
    let policy = generationPolicy, prefill = try prefillParameters(nil, operationID: flag.operationID, policy: generationPolicy)
    return try await ownedOperation(flag: flag, background: false) {
      try await assistant.perform { drafter in
        try await self.container.perform { context in
          try await InferenceExecutor.shared.perform { _ in
            try flag.check()
            let input = try await Self.chatInput(plan, images: [], media: media, context: context)
            let ids = input.text.tokens.asArray(Int.self)
            guard ids.count + maxTokens <= (try self.availableContext()) else { throw BoomError.budget("The actual MTP input and output do not fit this Mac.") }
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: settings.temperature,
              topP: settings.topP, topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, prefill: prefill, seed: seed)
            let started = ProcessInfo.processInfo.systemUptime
            let components = GenerationComponents(logitProcessorFactory: { CheckpointTokenMask(policy.suppressedTokenIDs) })
            let iterator = try MTPSpeculativeTokenIterator(input: input, mainModel: context.model,
              drafter: drafter.model, parameters: parameters, blockSize: 4, components: components)
            let (events, producer) = generateTokenTask(promptTokenCount: ids.count,
              modelConfiguration: context.configuration, tokenizer: context.tokenizer,
              iterator: iterator, includeStopToken: true)
            return try await Self.consumeVoiceTokens(events, producer: producer, ids: ids, started: started,
              context: context, policy: policy, flag: flag, assistantIdentity: assistantIdentity,
              onCheckpoint: onCheckpoint, onText: onText)
          }
        }
      }
    }
  }
  private nonisolated static func consumeVoiceTokens(_ events: AsyncStream<TokenGeneration>, producer: Task<Void, Never>,
    ids: [Int], started: Double, context: ModelContext, policy: ModelGenerationPolicy, flag: CancellationFlag,
    assistantIdentity: String?, onCheckpoint: @escaping @Sendable (GenerationProgress, String?, Int?) async throws -> Void,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    let cancellation = flag.onCancel { producer.cancel() }
    defer { flag.removeCancellationHandler(cancellation) }
    let digest = Digest.sha256(try JSONEncoder().encode(ids))
    let origin = GenerationExecutionOrigin(schema: 1, cacheAlgorithm: assistantIdentity == nil ? "causal-audio-prefix-v1" : "mtp-owned-v1",
      cachedPromptTokens: 0, cacheMissReason: "no-persistent-mtp-state")
    var tokens: [Int] = [], text = "", first: Double?, stop: Int?, reason = "output_limit"
    var information: GenerateCompletionInfo?
    func progress(_ text: String) -> GenerationProgress {
      GenerationProgress(text: text, tokenIDs: tokens, promptDigest: digest, promptTokens: ids.count,
        firstTokenSeconds: first, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, executionOrigin: origin)
    }
    do {
      for await event in events {
        try flag.check(); try ModelResidency.check()
        switch event {
        case .token(let token):
          if policy.controlTokenIDs.contains(token) || policy.eosTokenIDs.contains(token) { stop = token; continue }
          guard !policy.suppressedTokenIDs.contains(token) else { throw BoomError.invalid("MTP emitted a suppressed control token.") }
          if first == nil { first = ProcessInfo.processInfo.systemUptime - started }
          tokens.append(token)
          let decoded = context.tokenizer.decode(tokenIds: tokens)
          if !decoded.hasSuffix("\u{FFFD}"), decoded != text {
            try await onCheckpoint(progress(decoded), nil, nil); text = decoded; onText(decoded)
          }
        case .info(let value):
          information = value
          switch value.stopReason { case .stop: reason = "eos"; case .length: reason = "output_limit"; case .cancelled: reason = "cancelled" }
        }
      }
      await producer.value; Self.synchronizeGPU()
      try flag.check()
      guard information != nil else { throw BoomError.invalid("The owned voice iterator returned no terminal observation.") }
      let final = context.tokenizer.decode(tokenIds: tokens)
      try await onCheckpoint(progress(final), reason, stop)
      if final != text { onText(final) }
      return Output(text: final, tokenIDs: tokens, promptDigest: digest, promptTokens: ids.count,
        outputTokens: tokens.count, endedByEOS: reason == "eos", stopReason: reason, stopTokenID: stop,
        firstTokenSeconds: first, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
        executionOrigin: origin, mtp: assistantIdentity.map { BlessengerMTPExecution(assistant: $0,
          blockSize: 4, proposed: information?.proposedDraftTokens, accepted: information?.acceptedDraftTokens,
          passthrough: information?.passthroughReason) })
    } catch {
      producer.cancel(); await producer.value; Self.synchronizeGPU(); throw error
    }
  }

  func run(plan: ConsultationPlan, images: [Data], media: [WritingMediaData] = [], maxTokens: Int, seed: UInt64? = nil, settings: SamplingSettings? = nil,
    flag: CancellationFlag, independentIdentity: GenerationIdentity? = nil,
    cacheOwner: PromptCacheOwner? = nil, executionPolicy: ModelGenerationPolicy? = nil,
    joinedRetention: JoinedKVRetentionRequest? = nil,
    beforeCachePublication: (@Sendable () async throws -> Void)? = nil,
    pairedAdmission: PairedContextAdmission? = nil,
    diagnostic: ActiveNativeKVProbeHooks? = nil,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    if let independentIdentity, let cacheOwner, images.isEmpty, media.isEmpty,
      verifiedStatelessTextKV, diagnostic == nil {
      let policy = try ProductCore.resolvedGenerationPolicy(executionPolicy ?? generationPolicy, loaded: generationPolicy)
      guard independentIdentity.seed == seed, independentIdentity.maxTokens == maxTokens,
        independentIdentity.requestDigest == Digest.sha256(plan.rawPrompt) else {
        throw BoomError.stale("The independent consultation lost its captured seed or prompt.")
      }
      return try await submitIndependentText(.init(identity: independentIdentity, owner: cacheOwner,
        input: .consultation(plan), settings: try settings ?? ProductCore.sampling(.standard), flag: flag, policy: policy,
        joinedRetention: joinedRetention, pairedAdmission: pairedAdmission,
        beforeCachePublication: beforeCachePublication,
        onPrefill: onPrefill, onCheckpoint: onCheckpoint, onText: onText))
    }
    return try await generate(plan: plan, raw: nil, images: images, media: media, maxTokens: maxTokens,
      settings: settings ?? ProductCore.sampling(.standard), seed: seed, flag: flag,
      cacheOwner: cacheOwner, executionPolicy: executionPolicy, joinedRetention: joinedRetention,
      beforeCachePublication: beforeCachePublication, pairedAdmission: pairedAdmission, diagnostic: diagnostic, onPrefill: onPrefill,
      onCheckpoint: onCheckpoint, onText: onText)
  }
  func run(rawPrompt: String, media: [WritingMediaData] = [], maxTokens: Int, settings: SamplingSettings? = nil, seed: UInt64? = nil,
    flag: CancellationFlag, background: Bool = false,
    cacheOwner: PromptCacheOwner? = nil, executionPolicy: ModelGenerationPolicy? = nil,
    joinedRetention: JoinedKVRetentionRequest? = nil,
    beforeCachePublication: (@Sendable () async throws -> Void)? = nil,
    pairedAdmission: PairedContextAdmission? = nil,
    diagnostic: ActiveNativeKVProbeHooks? = nil,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await generate(plan: nil, raw: rawPrompt, images: [], media: media, maxTokens: maxTokens,
      settings: settings ?? ProductCore.sampling(.standard), seed: seed, flag: flag, background: background,
      cacheOwner: cacheOwner, executionPolicy: executionPolicy, joinedRetention: joinedRetention,
      beforeCachePublication: beforeCachePublication, pairedAdmission: pairedAdmission, diagnostic: diagnostic, onPrefill: onPrefill,
      onCheckpoint: onCheckpoint, onText: onText)
  }
  private func generate(plan: ConsultationPlan?, raw: String?, images: [Data], media: [WritingMediaData] = [], maxTokens: Int,
    settings: SamplingSettings, seed: UInt64?, flag: CancellationFlag,
    background: Bool = false,
    cacheOwner: PromptCacheOwner?, executionPolicy: ModelGenerationPolicy?,
    joinedRetention: JoinedKVRetentionRequest?,
    beforeCachePublication: (@Sendable () async throws -> Void)?,
    pairedAdmission: PairedContextAdmission? = nil,
    diagnostic: ActiveNativeKVProbeHooks? = nil,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)? = nil,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try await PairedContextAdmission.perform(using: pairedAdmission, flag: flag) { attempt in
      try await self.ownedOperationWithBudget(flag: flag, background: background,
        joinedRetention: joinedRetention) { watch in
        let budgetWasExceeded: @Sendable () -> Bool = { watch.exceeded }
        return try await self.generateOwned(plan: plan, raw: raw, images: images, media: media, maxTokens: maxTokens,
          settings: settings, seed: seed, flag: flag,
          cacheOwner: cacheOwner, executionPolicy: executionPolicy,
          joinedRetention: joinedRetention, budgetWasExceeded: budgetWasExceeded,
          beforeCachePublication: beforeCachePublication, pairedAttempt: attempt, diagnostic: diagnostic, onPrefill: onPrefill,
          onCheckpoint: onCheckpoint, onText: onText)
      }
    }
  }
  private func ownedOperation<R: Sendable>(flag: CancellationFlag, background: Bool,
    operation: @escaping @Sendable () async throws -> R) async throws -> R {
    try await ownedOperationWithBudget(flag: flag, background: background, joinedRetention: nil) { _ in
      try await operation()
    }
  }
  private func ownedOperationWithBudget<R: Sendable>(flag: CancellationFlag, background: Bool,
    joinedRetention: JoinedKVRetentionRequest?,
    operation: @escaping @Sendable (OperationMemoryWatch) async throws -> R) async throws -> R {
    let queueTrace = PerformanceTrace.begin("Model.Queue")
    await GenerationCoordinator.shared.enter(flag: flag, background: background, runnerEpoch: cacheRunnerEpoch)
    PerformanceTrace.end("Model.Queue", queueTrace)
    let trace = PerformanceTrace.begin("Model.Operation")
    defer { PerformanceTrace.end("Model.Operation", trace) }
    let watch: OperationMemoryWatch
    do {
      watch = try OperationMemoryWatch(flag: flag, onExceeded: {
        joinedRetention?.authorization.revoke()
      })
    }
    catch { await GenerationCoordinator.shared.leave(); throw error }
    defer { watch.stop() }
    // Own the whole task before preparing input or constructing the iterator.
    // MLX checks Task cancellation between prefill chunks, before a stream
    // producer exists. Every exit fences submitted GPU work before handoff.
    let work = Task(priority: background ? .background : .userInitiated) {
      try await operation(watch)
    }
    let registration = flag.onCancel { work.cancel() }
    defer { flag.removeCancellationHandler(registration) }
    await GenerationCoordinator.shared.own(work)
    do {
      let result = try await withTaskCancellationHandler {
        try await work.value
      } onCancel: { flag.cancel(); work.cancel() }
      watch.stop()
      try ModelResidency.check()
      if watch.exceeded { throw BoomError.budget("The operation reached Bloom's application memory budget.") }
      await GenerationCoordinator.shared.leave()
      return result
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  /// Fixed independent attempts enter the existing coordinator concurrently;
  /// its one ready queue chooses compatible rows, never one GPU owner per row.
  func runIndependentText(_ requests: [IndependentTextRequest]) async -> [Result<Output, Error>] {
    guard (1...4).contains(requests.count) else {
      return requests.map { _ in .failure(BoomError.invalid("At most four independent attempts form a cohort.")) }
    }
    return await withTaskGroup(of: (Int, Result<Output, Error>).self) { group in
      for (index, request) in requests.enumerated() {
        group.addTask {
          do { return (index, .success(try await self.submitIndependentText(request))) }
          catch { return (index, .failure(error)) }
        }
      }
      var values = Array<Result<Output, Error>>(repeating: .failure(CancellationError()), count: requests.count)
      for await (index, value) in group { values[index] = value }
      return values
    }
  }
  private func submitIndependentText(_ request: IndependentTextRequest) async throws -> Output {
    guard verifiedStatelessTextKV, request.identity.batch == nil,
      request.identity.model == identity, request.identity.operationID == request.flag.operationID,
      request.identity.generationPolicy == request.policy else {
      throw BoomError.invalid("An independent request lost its actual runner or captured attempt.")
    }
    let policy = try ProductCore.resolvedGenerationPolicy(request.policy, loaded: generationPolicy)
    let compatibility = processorIdentity + ":" + (try Self.policyDigest(policy))
    return try await withTaskCancellationHandler {
      try await PairedContextAdmission.perform(using: request.pairedAdmission, flag: request.flag) { attempt in
        var prepared = request; prepared.pairedAttempt = attempt
        return try await GenerationCoordinator.shared.submitIndependentText(prepared,
          runnerEpoch: self.cacheRunnerEpoch, compatibility: compatibility) { requests, flag in
            await self.generateIndependentOwned(requests, flag: flag)
          }
      }
    } onCancel: { request.flag.cancel() } // never cancels a peer's shared producer
  }
  private struct IndependentCohortDoesNotFit: Error { let message: String }
  private struct IndependentPreparationRefusals: Error {
    let rows: [(Int, Error)]
  }
  private func generateIndependentSingle(_ row: IndependentTextRequest,
    watch: OperationMemoryWatch) async -> Result<Output, Error> {
    do {
      try row.flag.check()
      let plan: ConsultationPlan?, raw: String?
      switch row.input { case .consultation(let value): plan = value; raw = nil; case .raw(let value): plan = nil; raw = value }
      return .success(try await generateOwned(plan: plan, raw: raw, images: [], media: [],
        maxTokens: row.identity.maxTokens, settings: row.settings, seed: row.identity.seed,
        flag: row.flag, cacheOwner: row.owner, executionPolicy: row.policy,
        joinedRetention: row.joinedRetention, budgetWasExceeded: { watch.exceeded },
        beforeCachePublication: row.beforeCachePublication, pairedAttempt: row.pairedAttempt,
        onPrefill: row.onPrefill, onCheckpoint: row.onCheckpoint, onText: row.onText))
    } catch { return .failure(error) }
  }
  private func generateIndependentOwned(_ original: [IndependentTextRequest],
    flag: CancellationFlag) async -> [Result<Output, Error>] {
    let participating = original.indices.filter { !original[$0].flag.isCancelled }
    guard !participating.isEmpty else { return original.map { _ in .failure(CancellationError()) } }
    var values = Array<Result<Output, Error>>(repeating: .failure(CancellationError()), count: original.count)
    let watch: OperationMemoryWatch
    do {
      watch = try OperationMemoryWatch(flag: flag, onExceeded: {
        for index in participating { original[index].joinedRetention?.authorization.revoke() }
      })
    } catch { return original.map { _ in .failure(error) } }
    defer { watch.stop() }
    do {
      // At most four captured rows. A refused preparation or padded allocation
      // may regroup ONLY before any forward/ticket transfer; completed rows
      // are never replayed. All groups retain this same exclusive GPU owner.
      var groups = [participating]
      while !groups.isEmpty {
        let indexes = groups.removeFirst()
        if indexes.count == 1 {
          values[indexes[0]] = await generateIndependentSingle(original[indexes[0]], watch: watch)
          continue
        }
        let requests = indexes.map { original[$0] }
        do {
          let results = try await container.perform { context in
            try await InferenceExecutor.shared.perform { _ in
              try await self.generateIndependentPrepared(requests, context: context, flag: flag, watch: watch)
            }
          }
          guard results.count == indexes.count else {
            throw BoomError.invalid("The real independent cohort lost a result row.")
          }
          for (index, result) in zip(indexes, results) { values[index] = result }
        } catch let refusal as IndependentPreparationRefusals {
          guard !refusal.rows.isEmpty,
            refusal.rows.allSatisfy({ indexes.indices.contains($0.0) }),
            Set(refusal.rows.map { $0.0 }).count == refusal.rows.count else {
            throw BoomError.invalid("Independent preparation returned another row's refusal.")
          }
          for (row, error) in refusal.rows { values[indexes[row]] = .failure(error) }
          let ready = indexes.enumerated().compactMap { row, index in
            refusal.rows.contains(where: { $0.0 == row }) ? nil : index
          }
          if !ready.isEmpty { groups.insert(ready, at: 0) }
        } catch is IndependentCohortDoesNotFit {
          // Keep useful two/three-row batches when a wider padded shape cannot
          // fit. Its declined admission has not entered a forward or a ticket.
          let split = indexes.count == 3 ? 2 : indexes.count / 2
          groups.insert(Array(indexes[split...]), at: 0)
          groups.insert(Array(indexes[..<split]), at: 0)
        }
      }
      try ModelResidency.check()
      if watch.exceeded { throw BoomError.budget("The actual independent cohort reached the application memory budget.") }
      return values
    } catch {
      for index in participating { values[index] = .failure(error) }
      return values
    }
  }
  private nonisolated func generateIndependentPrepared(_ requests: [IndependentTextRequest],
    context: ModelContext, flag: CancellationFlag, watch: OperationMemoryWatch
  ) async throws -> [Result<Output, Error>] {
    var didFence = false
    defer { if !didFence { Self.synchronizeGPU() } }
    let policy = try ProductCore.resolvedGenerationPolicy(requests[0].policy, loaded: generationPolicy)
    guard requests.allSatisfy({ $0.policy == policy && $0.identity.model == identity }) else {
      throw BoomError.invalid("Independent rows require the same actual weights, processor and execution policy.")
    }
    var preparedIDs: [[Int]] = [], bindings: [JoinedKVRetentionBinding?] = []
    let prefill = try prefillParameters(nil, operationID: flag.operationID, policy: policy)
    var refused: [(Int, Error)] = []
    for (row, request) in requests.enumerated() {
      try flag.check() // only cancellation of the actual whole producer
      do {
        try request.flag.check()
        let input: LMInput
        switch request.input {
        case .consultation(let plan): input = try await Self.chatInput(plan, images: [], media: [], context: context)
        case .raw(let prompt): input = try RawWritingInput.prepare(prompt, media: [], context: context)
        }
        guard canUseNative(input, owner: request.owner) else {
          throw BoomError.invalid("This captured attempt is not independent stateless text.")
        }
        let ids = input.text.tokens.asArray(Int.self)
        guard !ids.isEmpty, ids.count + request.identity.maxTokens <= verifiedContextCeiling else {
          throw BoomError.budget("An independent row exceeds the actual context ceiling.")
        }
        // This is the original independent request's width-one prepared input.
        // A reclamation retry validates this exact row before regrouping peers;
        // runtime allocation separately admits the actual padded cohort width.
        _ = try pairedAdmissionRequest(ids: ids, owner: request.owner,
          output: request.identity.maxTokens, width: 1, policy: policy, flag: request.flag,
          attempt: request.pairedAttempt)
        preparedIDs.append(ids)
        let parameters = GenerateParameters(maxTokens: request.identity.maxTokens, prefill: prefill)
        bindings.append(try admittedJoinedBinding(request.joinedRetention, owner: request.owner,
          operationID: request.flag.operationID, policy: policy, input: input, parameters: parameters))
      } catch {
        refused.append((row, error))
      }
    }
    // No cache selection, producer forward or publication has entered yet.
    // Return only original errors; the owner can regroup surviving requests.
    if !refused.isEmpty { throw IndependentPreparationRefusals(rows: refused) }
    let inputs = requests.indices.map { PromptPrefixCache.TextCohortInput(owner: requests[$0].owner,
      tokens: preparedIDs[$0], joinedBinding: bindings[$0]) }
    guard let geometry = policy.prefill else { throw BoomError.invalid("Missing independent prefill geometry.") }
    let limits = try ModelResidency.limits()
    let prompts = preparedIDs.map(\.count), outputLimits = requests.map { $0.identity.maxTokens }
    func admission(_ cached: [Int], initial: Bool, valueBytes: Int = 4) throws {
      let allocation = try ProductCore.independentKVAllocation(configuration: self.cacheConfiguration,
        prompts: prompts, cached: cached, outputs: outputLimits, prefill: geometry,
        initial: initial, valueBytes: valueBytes)
      _ = try self.admitNativeAllowance(allocation, limits: limits)
    }
    let cohort = try promptCache.makeTextCohort(inputs, prefill: prefill,
      allowSnapshot: try Self.cacheRetentionGuard(), admit: { cached in
        do { try admission(cached, initial: true) }
        catch BoomError.budget(let message) { throw IndependentCohortDoesNotFit(message: message) }
      }, outputLimits: outputLimits,
      makeCache: { try context.model.newCache(parameters: GenerateParameters(prefill: prefill)) })
    cohort.bindForwardOperands(model: try forwardOperandModelBinding(policy), requests: try requests.indices.map { row in
      try Self.forwardOperandRequest(owner: requests[row].owner, prepared: preparedIDs[row],
        seed: requests[row].identity.seed, output: requests[row].identity.maxTokens,
        settings: requests[row].settings, row: row, request: requests[row].identity.requestDigest)
    })
    defer { cohort.discard() }
    let origins = try Self.independentOrigins(requests: requests, preparedIDs: preparedIDs,
      cohort: cohort, policy: policy)
    let decoded: IndependentTextDecoded
    do {
      decoded = try await Self.decodeIndependentText(requests: requests, model: context.model,
        tokenizer: context.tokenizer, cohort: cohort, origins: origins, policy: policy, flag: flag,
        admitNext: {
          try flag.check()
          let arrays = cohort.cache.flatMap { $0.innerState() }.filter { $0.ndim == 4 }
          guard arrays.allSatisfy({ $0.dtype == .float16 || $0.dtype == .bfloat16 || $0.dtype == .float32 }) else {
            throw BoomError.invalid("Independent Gemma KV has an unsupported actual dtype.")
          }
          // No eval/readback: cold caches reserve float32, then every actual
          // forward uses the submitted parents' real scalar byte size.
          try admission(cohort.rows.map(\.cachedTokenCount), initial: false,
            valueBytes: arrays.map { $0.dtype.size }.max() ?? 4)
        })
    } catch {
      Self.synchronizeGPU(); didFence = true
      await promptCache.joinTextCohortSpill(cohort, cancelled: true)
      if error is CancellationError, !watch.exceeded {
        var retained = Array<PromptPrefixCache.TextCohortRetention?>(repeating: nil, count: requests.count)
        for row in requests.indices {
          guard let request = requests[row].joinedRetention,
            await request.authorizeAfterJoin(), !watch.exceeded else { continue }
          retained[row] = .init(completion: .init(row: row, emittedTokenIDs: []), acknowledged: nil,
            proof: JoinedKVRetentionProof(termination: .constructorCancelled, producerJoined: true,
              existingFenceCompleted: true, checkpointUncertain: false, memoryLimitExceeded: false,
              statelessTextKVVerified: true), authorization: request.authorization)
        }
        // Cancellation remains the original result. Only completed disk bytes
        // or an exactly submitted joined hot prefix can consume this ticket.
        promptCache.publishTextCohort(cohort, retention: retained)
      }
      throw error
    }
    Self.synchronizeGPU(); didFence = true
    await promptCache.joinTextCohortSpill(cohort, cancelled: false)
    var results = decoded.outputs
    var retention = Array<PromptPrefixCache.TextCohortRetention?>(repeating: nil, count: requests.count)
    for row in requests.indices {
      guard !decoded.checkpointUncertain[row], !watch.exceeded else { continue }
      do {
        if !decoded.cancelled[row] { try await requests[row].beforeCachePublication?() }
        if decoded.cancelled[row] {
          guard let request = requests[row].joinedRetention, await request.authorizeAfterJoin() else { continue }
          retention[row] = .init(completion: decoded.completions[row], acknowledged: decoded.acknowledged[row],
            proof: JoinedKVRetentionProof(termination: .decodeCancelled, producerJoined: true,
              existingFenceCompleted: true, checkpointUncertain: false, memoryLimitExceeded: false,
              statelessTextKVVerified: true), authorization: request.authorization)
        } else {
          retention[row] = .init(completion: decoded.completions[row], acknowledged: decoded.acknowledged[row],
            proof: nil, authorization: nil)
        }
      } catch { results[row] = .failure(error) }
    }
    try ModelResidency.check()
    promptCache.publishTextCohort(cohort, retention: retention)
    return results
  }

  /// One producer, one prompt prefill, and one weight-reading forward pass per
  /// decoding step. Rows never compact: their shape is part of seeded replay.
  func runBatch(rawPrompt: String, media: [WritingMediaData] = [], maxTokens: Int, settings: SamplingSettings, seeds: [UInt64],
    flag: CancellationFlag, background: Bool = false,
    cacheOwner: PromptCacheOwner? = nil, executionPolicy: ModelGenerationPolicy? = nil,
    joinedRetention: JoinedKVRetentionRequest? = nil,
    beforeCachePublication: (@Sendable () async throws -> Void)? = nil,
    pairedAdmission: PairedContextAdmission? = nil,
    diagnostic: ActiveNativeKVProbeHooks? = nil,
    onPrefill: (@Sendable (PrefillProgress) -> Void)? = nil,
    onCheckpoint: (@Sendable ([BatchCheckpoint]) async throws -> Void)? = nil,
    onMetrics: (@Sendable (BatchMetrics) async -> Void)? = nil
  ) async throws -> [Output] {
    try ProductCore.admitWritingBatch(width: seeds.count, prompt: 1, output: maxTokens, capacity: 16_384)
    if seeds.count == 1 {
      let singleCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)?
      if let onCheckpoint {
        singleCheckpoint = { progress, stop, token in
          try await onCheckpoint([BatchCheckpoint(lane: 0, progress: progress, stopReason: stop, stopTokenID: token)])
        }
      } else { singleCheckpoint = nil }
      return [try await run(rawPrompt: rawPrompt, media: media, maxTokens: maxTokens, settings: settings,
        seed: seeds[0], flag: flag, background: background,
        cacheOwner: cacheOwner, executionPolicy: executionPolicy, joinedRetention: joinedRetention,
        beforeCachePublication: beforeCachePublication, pairedAdmission: pairedAdmission, diagnostic: diagnostic, onPrefill: onPrefill,
        onCheckpoint: singleCheckpoint,
        onText: { _ in })]
    }
    return try await PairedContextAdmission.perform(using: pairedAdmission, flag: flag) { attempt in
      try await self.ownedOperationWithBudget(flag: flag, background: background,
        joinedRetention: joinedRetention) { watch in
        let budgetWasExceeded: @Sendable () -> Bool = { watch.exceeded }
        return try await self.generateBatchOwned(raw: rawPrompt, media: media, maxTokens: maxTokens, settings: settings,
          seeds: seeds, flag: flag, cacheOwner: cacheOwner, executionPolicy: executionPolicy,
          joinedRetention: joinedRetention, budgetWasExceeded: budgetWasExceeded,
          beforeCachePublication: beforeCachePublication, pairedAttempt: attempt, diagnostic: diagnostic,
          onPrefill: onPrefill, onCheckpoint: onCheckpoint, onMetrics: onMetrics)
      }
    }
  }
  private func generateBatchOwned(raw: String, media: [WritingMediaData], maxTokens: Int, settings: SamplingSettings,
    seeds: [UInt64], flag: CancellationFlag,
    cacheOwner: PromptCacheOwner?, executionPolicy: ModelGenerationPolicy?,
    joinedRetention: JoinedKVRetentionRequest?, budgetWasExceeded: @escaping @Sendable () -> Bool,
    beforeCachePublication: (@Sendable () async throws -> Void)?,
    pairedAttempt: PairedAdmissionAttempt = .normal,
    diagnostic: ActiveNativeKVProbeHooks? = nil,
    onPrefill: (@Sendable (PrefillProgress) -> Void)?,
    onCheckpoint: (@Sendable ([BatchCheckpoint]) async throws -> Void)?,
    onMetrics: (@Sendable (BatchMetrics) async -> Void)?
  ) async throws -> [Output] {
    try flag.check()
    let policy = try ProductCore.resolvedGenerationPolicy(executionPolicy ?? generationPolicy, loaded: generationPolicy)
    let prefill = try prefillParameters(onPrefill, operationID: flag.operationID, policy: policy)
    let controls = Set(policy.controlTokenIDs), ends = Set(policy.eosTokenIDs)
    let containerTrace = PerformanceTrace.begin("Model.ContainerWait")
    return try await container.perform { (context: ModelContext) async throws -> [Output] in
      PerformanceTrace.end("Model.ContainerWait", containerTrace)
      let executorTrace = PerformanceTrace.begin("Model.ExecutorWait")
      return try await InferenceExecutor.shared.perform { _ in
        PerformanceTrace.end("Model.ExecutorWait", executorTrace)
        var didFence = false
        defer { if !didFence { Self.synchronizeGPU() } }
        let input = try {
          let trace = PerformanceTrace.begin("Model.InputPrepare")
          defer { PerformanceTrace.end("Model.InputPrepare", trace) }
          return try RawWritingInput.prepare(raw, media: media, context: context)
        }()
        let (promptIDs, digest) = try {
          let trace = PerformanceTrace.begin("Model.PromptReceipt")
          defer { PerformanceTrace.end("Model.PromptReceipt", trace) }
          let ids = input.text.tokens.asArray(Int.self)
          return (ids, Digest.sha256(try JSONEncoder().encode(ids)))
        }()
        let pairedRequest = try self.pairedAdmissionRequest(ids: promptIDs, owner: cacheOwner,
          output: maxTokens, width: seeds.count, policy: policy, flag: flag, attempt: pairedAttempt)
        if pairedRequest != nil {
          _ = try self.preparedCapacityOwned(input: input, ids: promptIDs, owner: cacheOwner,
            output: maxTokens, width: seeds.count, prefill: prefill, policy: policy,
            flag: flag, attempt: pairedAttempt)
        }
        let clock = ContinuousClock(), started = clock.now
        var parameters = GenerateParameters(maxTokens: maxTokens, temperature: settings.temperature,
          topP: settings.topP, topK: settings.topK, minP: settings.minP, repetitionPenalty: nil,
          prefill: prefill)
        let joinedBinding = try self.admittedJoinedBinding(joinedRetention, owner: cacheOwner,
          operationID: flag.operationID, policy: policy, input: input, parameters: parameters)
        var reclamation: ContextReclamationMetrics?
        var nativeAdmission: IncrementalKVAdmission?
        var selectedNativePlan: ActiveNativeKVAdmissionPlan?
        let nativeReuse = self.canUseNative(input, owner: cacheOwner)
        let lookupStarted = clock.now
        let cacheSession = try {
          let trace = PerformanceTrace.begin("Model.PrefixCacheLookup")
          defer { PerformanceTrace.end("Model.PrefixCacheLookup", trace) }
          func admit(_ plan: ActiveNativeKVAdmissionPlan?) throws {
            if let plan {
              do { nativeAdmission = try self.admitNativePlan(plan) }
              catch let error as BoomError {
                if case .budget = error, pairedAttempt.deferReclamation,
                  promptIDs.count + maxTokens <= self.verifiedContextCeiling, let pairedRequest { throw pairedRequest }
                throw error
              }
              selectedNativePlan = plan; return
            }
            selectedNativePlan = nil
            let result = try self.requestCapacityOwned(required: promptIDs.count + maxTokens,
              batchWidth: seeds.count, forceCold: cacheOwner == nil || !nativeReuse)
            reclamation = result.reclamation
            try ProductCore.admitWritingBatch(width: seeds.count, prompt: promptIDs.count,
              output: maxTokens, capacity: result.capacity)
          }
          if !nativeReuse { try admit(nil) }
          return try self.promptCache.makeSession(owner: cacheOwner, input: input,
            promptTokenIDs: promptIDs, prefill: parameters.prefill,
            allowSnapshot: try Self.cacheRetentionGuard(), joinedRetentionBinding: joinedBinding,
            useActiveNative: nativeReuse, outputTokens: maxTokens, batchWidth: seeds.count,
            admitNative: admit, makeCache: { try context.model.newCache(parameters: parameters) })
        }()
        // The admitted session is authoritative even when diagnostics are absent.
        let executionOrigin = GenerationExecutionOrigin(schema: 1,
          cacheAlgorithm: cacheSession.observation.algorithm,
          cachedPromptTokens: cacheSession.cachedTokenCount,
          cacheMissReason: cacheSession.observation.missReason)
        parameters.prefill = cacheSession.prefill
        if nativeReuse {
          parameters.prefill.observeTextForward = cacheSession.bindForwardOperands(
            model: try self.forwardOperandModelBinding(policy), requests: try seeds.indices.map { row in
              try Self.forwardOperandRequest(owner: cacheOwner, prepared: promptIDs, seed: seeds[row],
                output: maxTokens, settings: settings, row: row)
            })
        }
        let nativeReadmission = try selectedNativePlan.map { plan in
          try self.makeNativeReadmission(plan, flag: flag, authorization: joinedRetention?.authorization)
        }
        if let nativeReadmission {
          let submittedProgress = parameters.prefill.progress
          parameters.prefill.progress = { processed, total in
            submittedProgress?(processed, total)
            nativeReadmission.afterSubmittedPrefill(processed: processed, total: total)
          }
        }
        let operationMemoryDenied: @Sendable () -> Bool = {
          budgetWasExceeded() || nativeReadmission?.denied == true
        }
        let cache = cacheSession.cache
        var cacheMetrics = Self.cacheMetrics(cacheSession, owner: cacheOwner, reclamation: reclamation)
        cacheMetrics?.lookupReturnedSeconds = lookupStarted.duration(to: clock.now).timeInterval
        cacheMetrics?.nativeTensorBytes = self.promptCache.retainedNativeBytesUpperBound
        cacheMetrics?.cachedNativePhysicalWidth = cacheSession.observation.cachedNativePhysicalWidth
        cacheMetrics?.nativeAdmission = nativeAdmission
        if let observer = diagnostic?.native {
          observer.session(model: context.model, value: cacheSession)
          try observer.requireSuccessful()
          let submittedProgress = parameters.prefill.progress
          let cachedDiagnosticTokens = cacheSession.cachedTokenCount
          parameters.prefill.progress = { processed, total in
            submittedProgress?(processed, total)
            observer.submittedPrefill(processed: processed, total: total, cached: cachedDiagnosticTokens)
          }
        }
        var checkpointUncertain = false
        var acknowledged: [Int: PromptPrefixCache.Completion] = [:]
        var constructedAndSubmitted = false
        func retainJoinedPrefix(_ termination: JoinedKVRetentionProof.Termination) async {
          guard let request = joinedRetention, joinedBinding != nil,
            !checkpointUncertain, !operationMemoryDenied() else { return }
          do { try ModelResidency.check() }
          catch { request.authorization.revoke(); return }
          guard await request.authorizeAfterJoin(), !operationMemoryDenied() else { return }
          do { try ModelResidency.check() }
          catch { request.authorization.revoke(); return }
          // Approval remains revocable through the helper's final insertion.
          // This call cannot display a result or reopen an encrypted journal.
          self.promptCache.publishJoinedValidPrefix(cacheSession,
            proof: JoinedKVRetentionProof(termination: termination, producerJoined: true,
              existingFenceCompleted: didFence, checkpointUncertain: checkpointUncertain,
              memoryLimitExceeded: operationMemoryDenied(), statelessTextKVVerified: true),
            authorization: request.authorization, acknowledged: termination == .constructorCancelled
              ? [] : acknowledged.values.sorted { $0.row < $1.row })
        }
        // Batch construction/decode run synchronously on this owned executor;
        // there is no separate token producer to join.
        func joinAndFence() async {
          if !didFence { Self.synchronizeGPU(); didFence = true }
          await cacheSession.joinPendingSpill(cancelled: flag.isCancelled || Task.isCancelled)
        }
        do {
          let setupStarted = clock.now
          let setupQoSBefore = qos_class_self().rawValue
          let prepared = try {
            let trace = PerformanceTrace.begin("Model.BatchPrepare")
            defer { PerformanceTrace.end("Model.BatchPrepare", trace) }
            return try context.model.prepare(cacheSession.input, cache: cache, state: nil, prefill: parameters.prefill)
          }()
          let setupReturnedSeconds = setupStarted.duration(to: clock.now).timeInterval
          let setupQoSAfter = qos_class_self().rawValue
          let initial: LMOutput
          switch prepared {
          case .logits(let output): initial = output
          case .tokens(let tail):
            initial = context.model(LMInput.Text(tokens: tail.tokens.expandedDimensions(axis: 0)), cache: cache, state: nil)
          }
          guard initial.state == nil else { throw BoomError.invalid("This checkpoint needs unsupported per-row inference state.") }
          var logits = initial.logits[0..., -1, 0...]
          let initialTrace = PerformanceTrace.begin("Model.BatchInitialEvaluation")
          asyncEval([logits] + cache.flatMap { $0.innerState() })
          eval(logits)
          cacheSession.observeReadySpill()
          if joinedBinding != nil || cacheSession.usesActiveNativeState { cacheSession.markCacheSubmitted() }; constructedAndSubmitted = true
          PerformanceTrace.end("Model.BatchInitialEvaluation", initialTrace)
          diagnostic?.native?.logits(logits, width: 1, active: nil, initialBatch: true)
          try diagnostic?.native?.requireSuccessful()
          try flag.check()
          try nativeReadmission?.beforeBatchForward(width: seeds.count)
          // Preserve each existing cache object's offsets and rotating-window
          // metadata. Only its leading tensor dimension changes.
          for var entry in cache {
            let state = entry.innerState(), offset = entry.offset, metadata = entry.metaState
            if state.isEmpty { continue } // Gemma's shared-KV layers have no own tensors.
            guard PrefixKVStorage.layout(of: entry) != nil, state.count == 2,
              state.allSatisfy({ $0.ndim == 4 && $0.dim(0) == 1 }) else {
              throw BoomError.invalid("Unsupported cache layout for batched writing.")
            }
            entry.state = state.map { broadcast($0, to: [seeds.count] + Array($0.shape.dropFirst())) }
            if case .simple = PrefixKVStorage.layout(of: entry) {
              _ = entry.trim(entry.offset - offset)
            } else { entry.metaState = metadata }
            guard entry.offset == offset else { throw BoomError.invalid("Batch expansion changed the native logical offset.") }
          }
          let expandedRoots = cache.flatMap { $0.innerState() }
          asyncEval(expandedRoots); eval(expandedRoots)
          cacheSession.observeReadySpill()
          logits = broadcast(logits, to: [seeds.count, logits.dim(1)])
          diagnostic?.native?.expanded(width: seeds.count)
          try diagnostic?.native?.requireSuccessful()
          let mask = CheckpointTokenMask(policy.suppressedTokenIDs)
          let samplers = seeds.map { seed in
            GenerateParameters(temperature: settings.temperature, topP: settings.topP,
              topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, seed: seed).sampler()
          }
          var tokens = Array(repeating: [Int](), count: seeds.count)
          var texts = Array(repeating: "", count: seeds.count)
          var first = Array<Double?>(repeating: nil, count: seeds.count)
          var firstDeliveryQoS: UInt32?
          var reasons = Array<String?>(repeating: nil, count: seeds.count)
          var stops = Array<Int?>(repeating: nil, count: seeds.count)
          var elapsed = Array(repeating: 0.0, count: seeds.count)
          var decodePasses = 0
          var firstTokenMarked = false
          var firstTextMarked = false
          // Finished rows remain inert occupants of the original shape. They never
          // sample again or emit another checkpoint, and cannot affect other rows.
          let inertToken = policy.eosTokenIDs[0]
          while reasons.contains(nil), !flag.isCancelled, !Task.isCancelled {
            let diagnosticFinishedBefore = diagnostic == nil ? nil : reasons.map { $0 != nil }
            diagnostic?.native?.logits(logits, width: seeds.count, active: reasons.map { $0 == nil })
            try diagnostic?.native?.requireSuccessful()
            let sampled: [Int] = autoreleasepool {
              let filtered = mask.process(logits: logits)
              let next = samplers.indices.map { lane in
                reasons[lane] == nil
                  ? samplers[lane].sample(logits: filtered[lane].expandedDimensions(axis: 0)).reshaped([1])
                  : MLXArray([inertToken])
              }
              let joined = concatenated(next, axis: 0)
              eval(joined)
              return joined.asArray(Int.self)
            }
            if firstDeliveryQoS == nil { firstDeliveryQoS = qos_class_self().rawValue }
            var updates: [BatchCheckpoint] = []
            for lane in seeds.indices where reasons[lane] == nil {
              let token = sampled[lane]
              guard !policy.suppressedTokenIDs.contains(token) else {
                throw BoomError.invalid("A batch row emitted an excluded checkpoint token.")
              }
              if controls.contains(token) {
                reasons[lane] = ends.contains(token) ? "eos" : "model_control"; stops[lane] = token
              } else {
                if first[lane] == nil {
                  first[lane] = started.duration(to: clock.now).timeInterval
                  diagnostic?.firstDelivered?(lane, token)
                  if !firstTokenMarked {
                    firstTokenMarked = true
                    PerformanceTrace.event("Model.FirstToken")
                  }
                }
                tokens[lane].append(token)
                if tokens[lane].count == maxTokens { reasons[lane] = "output_limit" }
              }
              let decoded = context.tokenizer.decode(tokenIds: tokens[lane])
              // Record the processed boundary before a completed row receives
              // inert padding. Incoming KV pages are shared; no full-cache clone.
              autoreleasepool {
                _ = cacheSession.captureDecodeLane(row: lane, width: seeds.count,
                  emittedTokenIDs: tokens[lane], stopTokenID: stops[lane],
                  finished: reasons[lane] != nil)
              }
              elapsed[lane] = started.duration(to: clock.now).timeInterval
              if reasons[lane] != nil || (!decoded.hasSuffix("\u{FFFD}") && decoded != texts[lane]) {
                updates.append(BatchCheckpoint(lane: lane, progress: GenerationProgress(text: decoded, tokenIDs: tokens[lane],
                  promptDigest: digest, promptTokens: promptIDs.count, firstTokenSeconds: first[lane],
                  elapsedSeconds: elapsed[lane], executionOrigin: executionOrigin), stopReason: reasons[lane], stopTokenID: stops[lane]))
                texts[lane] = decoded
              }
            }
            let diagnosticEvent: ActiveNativeKVProbeHooks.MatrixEvent?
            if let diagnostic, let before = diagnosticFinishedBefore {
              let event = ActiveNativeKVProbeHooks.MatrixEvent(input_token_ids: sampled,
                finished_before_sample: before, finished_after_sample: reasons.map { $0 != nil },
                submitted_as_next_input: reasons.contains(nil) && !flag.isCancelled && !Task.isCancelled,
                native_offset_before_next_input: cache[0].offset)
              diagnosticEvent = event; diagnostic.native?.sampledBatch(event)
              try diagnostic.native?.requireSuccessful()
              if !event.submitted_as_next_input { diagnostic.matrix?(event) }
            } else { diagnosticEvent = nil }
            if !updates.isEmpty {
              let firstText = !firstTextMarked && updates.contains { !$0.progress.text.isEmpty }
              if firstText {
                firstTextMarked = true
                PerformanceTrace.event("Model.FirstDecodedText")
              }
              if let onCheckpoint {
                let trace = firstText ? PerformanceTrace.begin("Model.FirstCheckpoint") : nil
                defer { PerformanceTrace.end("Model.FirstCheckpoint", trace) }
                do { try await onCheckpoint(updates) }
                catch { checkpointUncertain = true; throw error }
                if joinedBinding != nil, joinedRetention?.checkpointIsDurable == true {
                  // Promote rows only AFTER the complete multi-row callback succeeds.
                  // A partially written failing callback authorizes no salvage.
                  for update in updates {
                    acknowledged[update.lane] = PromptPrefixCache.Completion(row: update.lane,
                      emittedTokenIDs: update.progress.tokenIDs, stopTokenID: update.stopTokenID)
                  }
                }
              }
            }
            if reasons.contains(nil), !flag.isCancelled, !Task.isCancelled {
              try nativeReadmission?.beforeBatchForward(width: seeds.count)
              logits = try autoreleasepool {
                cacheSession.observeDecodeOperands(sampled, active: reasons.map { $0 == nil })
                let output = context.model(LMInput.Text(tokens: MLXArray(sampled).reshaped([seeds.count, 1])),
                  cache: cache, state: nil)
                guard output.state == nil else { throw BoomError.invalid("Unexpected batch inference state.") }
                let next = output.logits[0..., -1, 0...]
                guard next.ndim == 2, next.dim(0) == seeds.count else { throw BoomError.invalid("The model lost its batch rows.") }
                asyncEval([next] + cache.flatMap { $0.innerState() })
                eval(next)
                cacheSession.observeReadySpill()
                if joinedBinding != nil || cacheSession.usesActiveNativeState { cacheSession.markCacheSubmitted() }
                if let event = diagnosticEvent { diagnostic?.matrix?(event) }
                return next
              }
              decodePasses += 1
            }
          }
          var cancelled: [BatchCheckpoint] = []
          for lane in seeds.indices where reasons[lane] == nil {
            reasons[lane] = "cancelled"
            elapsed[lane] = started.duration(to: clock.now).timeInterval
            texts[lane] = context.tokenizer.decode(tokenIds: tokens[lane])
            cancelled.append(BatchCheckpoint(lane: lane, progress: GenerationProgress(text: texts[lane], tokenIDs: tokens[lane],
              promptDigest: digest, promptTokens: promptIDs.count, firstTokenSeconds: first[lane],
              elapsedSeconds: elapsed[lane], executionOrigin: executionOrigin), stopReason: reasons[lane], stopTokenID: nil))
          }
          if !cancelled.isEmpty, let onCheckpoint {
            do { try await onCheckpoint(cancelled) }
            catch { checkpointUncertain = true; throw error }
            if joinedBinding != nil, joinedRetention?.checkpointIsDurable == true {
              for update in cancelled {
                acknowledged[update.lane] = PromptPrefixCache.Completion(row: update.lane,
                  emittedTokenIDs: update.progress.tokenIDs, stopTokenID: update.stopTokenID)
              }
            }
          }
          // The original operation fence runs once, before immutable anchors can
          // become eligible for the next owner-bound request.
          await joinAndFence()
          diagnostic?.native?.joined(); try diagnostic?.native?.requireSuccessful()
          if cacheOwner != nil, !cacheSession.stagedAnchorTokenCounts.isEmpty,
            !flag.isCancelled, !Task.isCancelled {
            try await beforeCachePublication?()
            if !flag.isCancelled, !Task.isCancelled {
              try ModelResidency.check()
              self.promptCache.publish(cacheSession, completions: seeds.indices.map {
                PromptPrefixCache.Completion(row: $0, emittedTokenIDs: tokens[$0], stopTokenID: stops[$0])
              }, acknowledged: acknowledged.values.sorted { $0.row < $1.row })
            }
          }
          if flag.isCancelled || Task.isCancelled || reasons.contains("cancelled") {
            await retainJoinedPrefix(.decodeCancelled)
          }
          try nativeReadmission?.requireAdmitted()
          cacheMetrics?.nativeReadmission = nativeReadmission?.observation
          cacheMetrics?.residentTensorBytesAfter = self.promptCache.retainedBytesUpperBound
          cacheMetrics?.nativeTensorBytesAfter = self.promptCache.retainedNativeBytesUpperBound
          await onMetrics?(BatchMetrics(width: seeds.count, sharedPromptPrefills: 1,
            decodeForwardPasses: decodePasses,
            cacheBatchDimensions: cache.flatMap { $0.state.map { $0.dim(0) } },
            prefillCacheMetrics: cacheMetrics))
          return seeds.indices.map { lane in
            Output(text: texts[lane], tokenIDs: tokens[lane], promptDigest: digest, promptTokens: promptIDs.count,
              outputTokens: tokens[lane].count, endedByEOS: stops[lane] != nil, stopReason: reasons[lane] ?? "cancelled",
              stopTokenID: stops[lane], firstTokenSeconds: first[lane], elapsedSeconds: elapsed[lane],
              executionPriority: Task.currentPriority.rawValue,
              setupMetrics: SetupMetrics(path: "shared-prefill-model-prepare",
                returnedSeconds: setupReturnedSeconds, threadQoSBefore: setupQoSBefore,
                threadQoSAfter: setupQoSAfter, firstDeliveryThreadQoS: firstDeliveryQoS,
              tokenShape: [promptIDs.count], maskShape: nil), prefillCacheMetrics: cacheMetrics,
              executionOrigin: executionOrigin)
          }
        } catch {
          await joinAndFence()
          if error is CancellationError, !checkpointUncertain {
            await retainJoinedPrefix(constructedAndSubmitted ? .decodeCancelled : .constructorCancelled)
          }
          try nativeReadmission?.requireAdmitted()
          throw error
        }
      }
    }
  }
  private func generateOwned(plan: ConsultationPlan?, raw: String?, images: [Data], media: [WritingMediaData], maxTokens: Int,
    settings: SamplingSettings, seed: UInt64?, flag: CancellationFlag,
    cacheOwner: PromptCacheOwner?, executionPolicy: ModelGenerationPolicy?,
    joinedRetention: JoinedKVRetentionRequest?, budgetWasExceeded: @escaping @Sendable () -> Bool,
    beforeCachePublication: (@Sendable () async throws -> Void)?,
    pairedAttempt: PairedAdmissionAttempt = .normal,
    diagnostic: ActiveNativeKVProbeHooks? = nil,
    onPrefill: (@Sendable (PrefillProgress) -> Void)?,
    onCheckpoint: (@Sendable (GenerationProgress, String?, Int?) async throws -> Void)?,
    onText: @escaping @Sendable (String) -> Void) async throws -> Output {
    try flag.check()
    let policy = try ProductCore.resolvedGenerationPolicy(executionPolicy ?? generationPolicy, loaded: generationPolicy)
    let prefill = try prefillParameters(onPrefill, operationID: flag.operationID, policy: policy)
    let controls = Set(policy.controlTokenIDs), ends = Set(policy.eosTokenIDs)
    let containerTrace = PerformanceTrace.begin("Model.ContainerWait")
    return try await container.perform { (context: ModelContext) async throws -> Output in
      PerformanceTrace.end("Model.ContainerWait", containerTrace)
      let executorTrace = PerformanceTrace.begin("Model.ExecutorWait")
      return try await InferenceExecutor.shared.perform { _ in
        PerformanceTrace.end("Model.ExecutorWait", executorTrace)
        var didFence = false
        defer { if !didFence { Self.synchronizeGPU() } }
        let input: LMInput = try await {
          let trace = PerformanceTrace.begin("Model.InputPrepare")
          defer { PerformanceTrace.end("Model.InputPrepare", trace) }
          if let plan { return try await Self.chatInput(plan, images: images, media: media, context: context) }
          if let raw { return try RawWritingInput.prepare(raw, media: media, context: context) }
          throw BoomError.invalid("No compiled model input.")
        }()
        let (promptIDs, preparedDigest) = try {
          let trace = PerformanceTrace.begin("Model.PromptReceipt")
          defer { PerformanceTrace.end("Model.PromptReceipt", trace) }
          let ids = input.text.tokens.asArray(Int.self)
          return (ids, Digest.sha256(try JSONEncoder().encode(ids)))
        }()
        let pairedRequest = try self.pairedAdmissionRequest(ids: promptIDs, owner: cacheOwner,
          output: maxTokens, width: 1, policy: policy, flag: flag, attempt: pairedAttempt)
        if pairedRequest != nil {
          _ = try self.preparedCapacityOwned(input: input, ids: promptIDs, owner: cacheOwner,
            output: maxTokens, width: 1, prefill: prefill, policy: policy,
            flag: flag, attempt: pairedAttempt)
        }
        let clock = ContinuousClock(), started = clock.now
        var parameters = GenerateParameters(maxTokens: maxTokens, temperature: settings.temperature,
          topP: settings.topP, topK: settings.topK, minP: settings.minP, repetitionPenalty: nil,
          prefill: prefill, seed: seed)
        let joinedBinding = try self.admittedJoinedBinding(joinedRetention, owner: cacheOwner,
          operationID: flag.operationID, policy: policy, input: input, parameters: parameters)
        var reclamation: ContextReclamationMetrics?
        var nativeAdmission: IncrementalKVAdmission?
        var selectedNativePlan: ActiveNativeKVAdmissionPlan?
        let nativeReuse = self.canUseNative(input, owner: cacheOwner)
        let lookupStarted = clock.now
        let cacheSession = try {
          let trace = PerformanceTrace.begin("Model.PrefixCacheLookup")
          defer { PerformanceTrace.end("Model.PrefixCacheLookup", trace) }
          func admit(_ plan: ActiveNativeKVAdmissionPlan?) throws {
            if let plan {
              do { nativeAdmission = try self.admitNativePlan(plan) }
              catch let error as BoomError {
                if case .budget = error, pairedAttempt.deferReclamation,
                  promptIDs.count + maxTokens <= self.verifiedContextCeiling, let pairedRequest { throw pairedRequest }
                throw error
              }
              selectedNativePlan = plan; return
            }
            selectedNativePlan = nil
            let result = try self.requestCapacityOwned(required: promptIDs.count + maxTokens,
              batchWidth: 1, forceCold: cacheOwner == nil || !nativeReuse)
            reclamation = result.reclamation
            try ProductCore.admitWritingBatch(width: 1, prompt: promptIDs.count,
              output: maxTokens, capacity: result.capacity)
          }
          if !nativeReuse { try admit(nil) }
          return try self.promptCache.makeSession(owner: cacheOwner, input: input,
            promptTokenIDs: promptIDs, prefill: parameters.prefill,
            allowSnapshot: try Self.cacheRetentionGuard(), joinedRetentionBinding: joinedBinding,
            useActiveNative: nativeReuse, outputTokens: maxTokens, batchWidth: 1,
            admitNative: admit, makeCache: { try context.model.newCache(parameters: parameters) })
        }()
        // The admitted session is authoritative even when diagnostics are absent.
        let executionOrigin = GenerationExecutionOrigin(schema: 1,
          cacheAlgorithm: cacheSession.observation.algorithm,
          cachedPromptTokens: cacheSession.cachedTokenCount,
          cacheMissReason: cacheSession.observation.missReason)
        parameters.prefill = cacheSession.prefill
        if nativeReuse {
          let operandModel: String = try self.forwardOperandModelBinding(policy)
          let operandRequest: String = try Self.forwardOperandRequest(owner: cacheOwner,
            prepared: promptIDs, seed: seed, output: maxTokens, settings: settings, row: 0)
          let operandObserver: (@Sendable (Range<Int>, Int, [Int]) -> Void)? =
            cacheSession.bindForwardOperands(model: operandModel, requests: [operandRequest])
          parameters.prefill.observeTextForward = operandObserver
        }
        let nativeReadmission = try selectedNativePlan.map { plan in
          try self.makeNativeReadmission(plan, flag: flag, authorization: joinedRetention?.authorization)
        }
        if let nativeReadmission {
          let submittedProgress = parameters.prefill.progress
          parameters.prefill.progress = { processed, total in
            submittedProgress?(processed, total)
            nativeReadmission.afterSubmittedPrefill(processed: processed, total: total)
          }
        }
        let operationMemoryDenied: @Sendable () -> Bool = {
          budgetWasExceeded() || nativeReadmission?.denied == true
        }
        var cacheMetrics = Self.cacheMetrics(cacheSession, owner: cacheOwner, reclamation: reclamation)
        cacheMetrics?.lookupReturnedSeconds = lookupStarted.duration(to: clock.now).timeInterval
        cacheMetrics?.nativeTensorBytes = self.promptCache.retainedNativeBytesUpperBound
        cacheMetrics?.cachedNativePhysicalWidth = cacheSession.observation.cachedNativePhysicalWidth
        cacheMetrics?.nativeAdmission = nativeAdmission
        if let observer = diagnostic?.native {
          observer.session(model: context.model, value: cacheSession)
          try observer.requireSuccessful()
          let submittedProgress = parameters.prefill.progress
          let cachedDiagnosticTokens = cacheSession.cachedTokenCount
          parameters.prefill.progress = { processed, total in
            submittedProgress?(processed, total)
            observer.submittedPrefill(processed: processed, total: total, cached: cachedDiagnosticTokens)
          }
        }
        var checkpointUncertain = false
        var acknowledged: [Int: PromptPrefixCache.Completion] = [:]
        var constructedAndSubmitted = false
        var stateIsReusable = false
        var producer: Task<Void, Never>?
        var producerCancellation: UUID?
        defer { flag.removeCancellationHandler(producerCancellation) }
        func retainJoinedPrefix(_ termination: JoinedKVRetentionProof.Termination) async {
          guard let request = joinedRetention, joinedBinding != nil, (!constructedAndSubmitted || stateIsReusable),
            !checkpointUncertain, !operationMemoryDenied() else { return }
          do { try ModelResidency.check() }
          catch { request.authorization.revoke(); return }
          guard await request.authorizeAfterJoin(), !operationMemoryDenied() else { return }
          do { try ModelResidency.check() }
          catch { request.authorization.revoke(); return }
          // Approval remains revocable through the helper's final insertion.
          // This call cannot display a result or reopen an encrypted journal.
          self.promptCache.publishJoinedValidPrefix(cacheSession,
            proof: JoinedKVRetentionProof(termination: termination, producerJoined: true,
              existingFenceCompleted: didFence, checkpointUncertain: checkpointUncertain,
              memoryLimitExceeded: operationMemoryDenied(), statelessTextKVVerified: true),
            authorization: request.authorization, acknowledged: termination == .constructorCancelled
              ? [] : acknowledged.values.sorted { $0.row < $1.row })
        }
        func joinAndFence(cancelProducer: Bool, completeFence: Bool = true) async {
          if let task = producer {
            if cancelProducer { task.cancel() }
            let trace = PerformanceTrace.begin("Model.ProducerJoin")
            await task.value
            PerformanceTrace.end("Model.ProducerJoin", trace)
            // Pinned TokenIterator.next submits token+cache before returning;
            // joining the actual producer also joins its final stream fence.
            if joinedBinding != nil || cacheSession.usesActiveNativeState { cacheSession.markCacheSubmitted() }
            producer = nil
          }
          if completeFence {
            if !didFence { Self.synchronizeGPU(); didFence = true }
            await cacheSession.joinPendingSpill(cancelled: flag.isCancelled || Task.isCancelled)
          }
        }
        do {
          // TokenIterator performs prompt prefill during task construction.
          // Start before it so first-token and elapsed time include that work.
          let setupQoSBefore = qos_class_self().rawValue
          let setupStarted = clock.now
          let captureSample = cacheSession.didSample
          let didSample: @Sendable (MLXArray) -> Void = { token in
            captureSample?(token)
            diagnostic?.native?.sampledSingle(token)
            nativeReadmission?.afterSingleSampleBeforeSubmission()
          }
          let observedLogits: (@Sendable (MLXArray) -> Void)?
          if let observer = diagnostic?.native {
            observedLogits = { logits in observer.logits(logits, width: 1, active: nil) }
          } else { observedLogits = nil }
          let components = GenerationComponents(logitProcessorFactory: {
            CheckpointTokenMask(policy.suppressedTokenIDs, didSample: didSample, observeLogits: observedLogits)
          })
          let (stream, task, reusableState) = try {
            let trace = PerformanceTrace.begin("Model.StreamConstruction")
            defer { PerformanceTrace.end("Model.StreamConstruction", trace) }
            let iterator = try TokenIterator(input: cacheSession.input, model: context.model,
              cache: cacheSession.cache, parameters: parameters, components: components)
            // Returning from the pinned constructor proves its asyncEval(token)
            // happened. Its terminal progress callback alone would not prove it.
            if joinedBinding != nil || cacheSession.usesActiveNativeState { cacheSession.markCacheSubmitted() }; constructedAndSubmitted = true
            let reusableState = iterator.state == nil
            stateIsReusable = reusableState
            guard reusableState || cacheSession.cachedTokenCount == 0 else {
              throw BoomError.invalid("The checkpoint needs unsupported state for prompt-cache reuse.")
            }
            try nativeReadmission?.startSingleDecodeAfterConstructorSubmission()
            try flag.check()
            let (stream, task) = generateTokenTask(promptTokenCount: cacheSession.fullPromptTokenCount,
              modelConfiguration: context.configuration, tokenizer: context.tokenizer,
              iterator: iterator, includeStopToken: true)
            producer = task
            producerCancellation = flag.onCancel { task.cancel() }
            return (stream, task, reusableState)
          }()
          let setupReturnedSeconds = setupStarted.duration(to: clock.now).timeInterval
          let setupQoSAfter = qos_class_self().rawValue
          var tokens: [Int] = [], text = "", ended = false, reason = "output_limit"
          var first: Double?; var stopToken: Int?
          var firstDeliveryQoS: UInt32?
          var firstTextMarked = false
          do {
            for await event in stream {
              if flag.isCancelled || Task.isCancelled { task.cancel(); break }
              switch event {
              case .token(let token):
                if firstDeliveryQoS == nil { firstDeliveryQoS = qos_class_self().rawValue }
                guard !policy.suppressedTokenIDs.contains(token) else {
                  throw BoomError.invalid("The model emitted a token excluded by its checkpoint policy.")
                }
                if controls.contains(token) {
                  stopToken = token; reason = ends.contains(token) ? "eos" : "model_control"
                  ended = true; task.cancel(); break
                }
                if first == nil {
                  first = started.duration(to: clock.now).timeInterval
                  PerformanceTrace.event("Model.FirstToken")
                  diagnostic?.firstDelivered?(0, token)
                }
                tokens.append(token)
                let decoded = context.tokenizer.decode(tokenIds: tokens)
                if !decoded.hasSuffix("\u{FFFD}"), decoded != text {
                  let firstText = !firstTextMarked && !decoded.isEmpty
                  if firstText {
                    firstTextMarked = true
                    PerformanceTrace.event("Model.FirstDecodedText")
                  }
                  // Every displayed update is durable before it reaches a view.
                  // Awaiting the store also bounds the checkpoint producer.
                  if let onCheckpoint {
                    let trace = firstText ? PerformanceTrace.begin("Model.FirstCheckpoint") : nil
                    defer { PerformanceTrace.end("Model.FirstCheckpoint", trace) }
                    do {
                      try await onCheckpoint(GenerationProgress(text: decoded,
                        tokenIDs: tokens, promptDigest: preparedDigest, promptTokens: promptIDs.count,
                        firstTokenSeconds: first, elapsedSeconds: started.duration(to: clock.now).timeInterval,
                        executionOrigin: executionOrigin), nil, nil)
                    } catch { checkpointUncertain = true; throw error }
                    if joinedBinding != nil, joinedRetention?.checkpointIsDurable == true {
                      acknowledged[0] = PromptPrefixCache.Completion(emittedTokenIDs: tokens)
                    }
                  }
                  text = decoded; onText(text)
                }
              case .info(let info):
                switch info.stopReason {
                case .stop: ended = true; reason = "eos"
                case .length: reason = "output_limit"
                case .cancelled: reason = "cancelled"
                }
              }
              if ended { break }
            }
          } catch { throw error }
          await joinAndFence(cancelProducer: flag.isCancelled || Task.isCancelled, completeFence: false)
          // Joining must retain the producer's emitted tokens even on cancellation.
          // Callers persist this receipt before propagating their cancelled operation.
          if flag.isCancelled || Task.isCancelled { reason = "cancelled" }
          let final = context.tokenizer.decode(tokenIds: tokens)
          let elapsed = started.duration(to: clock.now).timeInterval
          if let onCheckpoint {
            do {
              try await onCheckpoint(GenerationProgress(text: final, tokenIDs: tokens,
                promptDigest: preparedDigest, promptTokens: promptIDs.count, firstTokenSeconds: first,
                elapsedSeconds: elapsed, executionOrigin: executionOrigin), reason, stopToken)
            } catch { checkpointUncertain = true; throw error }
            if joinedBinding != nil, joinedRetention?.checkpointIsDurable == true {
              acknowledged[0] = PromptPrefixCache.Completion(emittedTokenIDs: tokens, stopTokenID: stopToken)
            }
          }
          if final != text, reason != "cancelled" { onText(final) }
          await joinAndFence(cancelProducer: false)
          diagnostic?.native?.joined(); try diagnostic?.native?.requireSuccessful()
          if reusableState, reason != "cancelled", cacheOwner != nil, !cacheSession.stagedAnchorTokenCounts.isEmpty,
            !flag.isCancelled, !Task.isCancelled {
            try await beforeCachePublication?()
            if !flag.isCancelled, !Task.isCancelled {
              try ModelResidency.check()
              self.promptCache.publish(cacheSession, completions: [
                PromptPrefixCache.Completion(emittedTokenIDs: tokens, stopTokenID: stopToken)
              ], acknowledged: acknowledged.values.sorted { $0.row < $1.row })
            }
          }
          if reason == "cancelled" { await retainJoinedPrefix(.decodeCancelled) }
          try nativeReadmission?.requireAdmitted()
          cacheMetrics?.nativeReadmission = nativeReadmission?.observation
          cacheMetrics?.residentTensorBytesAfter = self.promptCache.retainedBytesUpperBound
          cacheMetrics?.nativeTensorBytesAfter = self.promptCache.retainedNativeBytesUpperBound
          return Output(text: final, tokenIDs: tokens, promptDigest: preparedDigest,
            promptTokens: promptIDs.count, outputTokens: tokens.count, endedByEOS: ended, stopReason: reason, stopTokenID: stopToken,
            firstTokenSeconds: first, elapsedSeconds: elapsed,
            executionPriority: Task.currentPriority.rawValue,
            setupMetrics: SetupMetrics(path: "token-iterator-constructor",
              returnedSeconds: setupReturnedSeconds, threadQoSBefore: setupQoSBefore,
              threadQoSAfter: setupQoSAfter, firstDeliveryThreadQoS: firstDeliveryQoS,
              tokenShape: input.text.tokens.shape, maskShape: input.text.mask?.shape),
            prefillCacheMetrics: cacheMetrics, executionOrigin: executionOrigin)
        } catch {
          await joinAndFence(cancelProducer: true)
          if error is CancellationError, !checkpointUncertain {
            await retainJoinedPrefix(constructedAndSubmitted ? .decodeCancelled : .constructorCancelled)
          }
          try nativeReadmission?.requireAdmitted()
          throw error
        }
      }
    }
  }
  func diagnosticActiveNativeKVParity(_ request: ActiveNativeKVSmoke.NumericRequest,
    evidence: URL) async throws -> ActiveNativeKVSmoke.NumericResult {
    let flag = CancellationFlag()
    return try await ownedOperationWithBudget(flag: flag, background: false, joinedRetention: nil) { watch in
      let store = ActiveNativeKVOracleStore()
      do {
      let policy = try ProductCore.resolvedGenerationPolicy(request.policy, loaded: self.generationPolicy)
      let settings = try ProductCore.sampling(.standard), limits = try ModelResidency.limits()
      let admit: @Sendable (UInt64) throws -> Void = { bytes in
        _ = try self.admitNativeAllowance(bytes, limits: limits)
      }
      var records: [ActiveNativeKVSmoke.NumericSubcall] = []
      for (index, trial) in request.trials.enumerated() {
        let mode: ActiveNativeKVNumericalObserver.Mode = index == 0
          ? .source(selectedFinishedRow: request.selectedRow,
              selectedPrefix: request.selectedRow == nil ? nil : request.trials.last?.independent_maximum_prefix)
          : .query(name: trial.operation_name, expectedPrefix: trial.independent_maximum_prefix,
              sourceBoundary: request.selectedRow == nil ? (index == 1 ? 16_127 : 15_872) : nil)
        let observer = ActiveNativeKVNumericalObserver(mode: mode, store: store,
          prompt: trial.prepared_token_ids, policy: policy, settings: settings,
          seeds: trial.seeds, flag: flag, admit: admit)
        let matrices = ActiveNativeKVSmoke.MatrixCollector()
        let hooks = ActiveNativeKVProbeHooks(matrix: { matrices.append($0) }, native: observer)
        let budgetExceeded: @Sendable () -> Bool = { watch.exceeded }
        let output: [Output]
        do {
        if let prompt = trial.input.prompt {
          if trial.seeds.count == 1 {
            output = [try await self.generateOwned(plan: nil, raw: prompt, images: [], media: [],
              maxTokens: trial.output_limit, settings: settings, seed: trial.seeds[0], flag: flag,
              cacheOwner: trial.owner, executionPolicy: policy, joinedRetention: nil,
              budgetWasExceeded: budgetExceeded, beforeCachePublication: nil, diagnostic: hooks,
              onPrefill: nil, onCheckpoint: nil, onText: { _ in })]
          } else {
            output = try await self.generateBatchOwned(raw: prompt, media: [], maxTokens: trial.output_limit,
              settings: settings, seeds: trial.seeds, flag: flag, cacheOwner: trial.owner,
              executionPolicy: policy, joinedRetention: nil, budgetWasExceeded: budgetExceeded,
              beforeCachePublication: nil, diagnostic: hooks, onPrefill: nil, onCheckpoint: nil, onMetrics: nil)
          }
        } else if let plan = trial.input.plan, trial.seeds.count == 1 {
          output = [try await self.generateOwned(plan: plan, raw: nil, images: [], media: [],
            maxTokens: trial.output_limit, settings: settings, seed: trial.seeds[0], flag: flag,
            cacheOwner: trial.owner, executionPolicy: policy, joinedRetention: nil,
            budgetWasExceeded: budgetExceeded, beforeCachePublication: nil, diagnostic: hooks,
            onPrefill: nil, onCheckpoint: nil, onText: { _ in })]
        } else { throw BoomError.invalid("Missing declared numerical source input.") }
        } catch {
          try ActiveNativeKVSmoke.write(observer.result(), evidence.appendingPathComponent("subcall-\(index)-failed.json"))
          await InferenceExecutor.shared.perform { _ in observer.releaseWorkingArraysAfterJoin() }
          throw error
        }
        try observer.requireSuccessful()
        let matrix = matrices.snapshot()
        let same = zip(output, trial.outputs).allSatisfy {
          $0.tokenIDs == $1.tokenIDs && $0.stopTokenID == $1.stopTokenID && $0.stopReason == $1.stopReason
        } && output.count == trial.outputs.count && matrix == trial.matrix_events
          && zip(output, trial.outputs).allSatisfy { actual, previous in
            let a = actual.prefillCacheMetrics, b = previous.prefillCacheMetrics
            return a?.algorithm == b?.algorithm && a?.cachedPromptTokens == b?.cachedPromptTokens
              && a?.originalGeometry == b?.originalGeometry && a?.suffixGeometry == b?.suffixGeometry
              && a?.cachedForwardHistory == b?.cachedForwardHistory && a?.cachedRow == b?.cachedRow
              && a?.cachedBatchWidth == b?.cachedBatchWidth && a?.cachedOrigin == b?.cachedOrigin
          }
        let result = observer.result()
        let record = ActiveNativeKVSmoke.NumericSubcall(name: trial.operation_name,
          source_history_matches_timing: same, outputs: output, matrix_events: matrix, comparison: result)
        try ActiveNativeKVSmoke.write(record, evidence.appendingPathComponent("subcall-\(index).json"))
        records.append(record)
        guard same else { throw BoomError.stale("The actual numerical source/query token matrix or completion ledger changed from timing.") }
        if index == 0 { try flag.check() }
      }
      let result = ActiveNativeKVSmoke.NumericResult(owned_subcalls: records,
        exact: records.count == request.trials.count && records.allSatisfy { $0.source_history_matches_timing && $0.comparison.exact })
      await InferenceExecutor.shared.perform { _ in store.release() }
      return result
      } catch {
        await InferenceExecutor.shared.perform { _ in store.release() }
        throw error
      }
    }
  }
  func cancelAndJoin() async {
    await GenerationCoordinator.shared.cancel(runnerEpoch: cacheRunnerEpoch)
    // A reclamation barrier must wait, not preempt an unrelated target producer.
    await GenerationCoordinator.shared.enter(background: true)
    await GenerationCoordinator.shared.leave()
  }
  func join() async { await GenerationCoordinator.shared.enter(); await GenerationCoordinator.shared.leave() }
}

extension Duration {
  var timeInterval: Double {
    let value = components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
  }
}
