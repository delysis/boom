import BoomCore
import Foundation
import MLX
import MLXLMCommon

/// Diagnostic callbacks run only within the existing exclusive inference lease.
/// This narrow sendability bridge does not permit tensor access by the caller.
/// With nil hooks, normal generation performs no copies, evals or observations.
final class ActiveNativeKVProbeHooks: @unchecked Sendable {
  struct MatrixEvent: Codable, Sendable, Equatable {
    let input_token_ids: [Int]
    let finished_before_sample: [Bool]
    let finished_after_sample: [Bool]
    let submitted_as_next_input: Bool
    let native_offset_before_next_input: Int
  }
  let firstDelivered: (@Sendable (Int, Int) -> Void)?
  let matrix: (@Sendable (MatrixEvent) -> Void)?
  let native: ActiveNativeKVNumericalObserver?
  init(firstDelivered: (@Sendable (Int, Int) -> Void)? = nil,
    matrix: (@Sendable (MatrixEvent) -> Void)? = nil,
    native: ActiveNativeKVNumericalObserver? = nil) {
    self.firstDelivered = firstDelivered; self.matrix = matrix; self.native = native
  }
}

/// Only metadata/errors cross tasks. Tensor state below is used on the currently
/// owned inference constructor/producer, sequentially, and destroyed after join.
final class ActiveNativeKVOracleStore: @unchecked Sendable {
  fileprivate var snapshots: [Int: NativePrefixParityProbe.Snapshot] = [:]
  fileprivate var finished: NativePrefixParityProbe.Snapshot?
  fileprivate var sourceRecords: [[NativePrefixParityProbe.SourceLayer]] = []
  func release() { snapshots.removeAll(); finished = nil }
}

final class ActiveNativeKVNumericalObserver: @unchecked Sendable {
  enum Mode {
    case source(selectedFinishedRow: Int?, selectedPrefix: Int?)
    case query(name: String, expectedPrefix: Int, sourceBoundary: Int?)
  }
  struct Forward: Codable, Sendable {
    let input_token_matrix: [[Int]]
    let start_offset: Int
    let end_offset: Int
    let width: Int
    let reference_teacher_forced_after_sampler_difference: Bool
    let sampleable_logits: NativePrefixParityProbe.TensorComparison?
    let masks: [NativePrefixParityProbe.MaskComparison]
  }
  struct Sample: Codable, Sendable {
    let row: Int
    let seed: UInt64
    let sample_index: Int
    let reference_token_id: Int
    let actual_candidate_token_id: Int
  }
  struct Result: Encodable, Sendable {
    let name: String
    let source_native_layers: [[NativePrefixParityProbe.SourceLayer]]
    let actual_session: PromptPrefixCache.Observation?
    let initial_state: NativePrefixParityProbe.StateComparison?
    let prefill_checkpoint_states: [NativePrefixParityProbe.StateComparison]
    let final_state: NativePrefixParityProbe.StateComparison?
    let forwards: [Forward]
    let samples: [Sample]
    let exact: Bool
    let differences: [String]
    let failure: String?
    let diagnostic_admission_checks: Int
    let largest_additional_allocation_bound_bytes: UInt64
    let unobserved = "per-position discarded prefill logits; historical timing-run tensors; UI and encrypted journal durability"
    let source_scope = "original actual native state captured in this declared untimed replay, before overwrite; timed source token/matrix/history binding independently checked"
  }
  private let lock = NSLock()
  private var failure: String?
  private let mode: Mode
  private let store: ActiveNativeKVOracleStore
  private let prompt: [Int]
  private let policy: ModelGenerationPolicy
  private let settings: SamplingSettings
  private let seeds: [UInt64]
  private let flag: CancellationFlag
  private let admit: @Sendable (UInt64) throws -> Void
  private var model: (any LanguageModel)?
  private var oracle: [any KVCache] = []
  private var cache: [any KVCache] = []
  private var windows: [Int?] = []
  private var samplers: [any LogitSampler] = []
  private var referenceLogits: MLXArray?
  private var expectedSamples: [Int] = []
  private var actualSingleSamples: [Int] = []
  private var pendingBatch: [Int]?
  private var sessionObservation: PromptPrefixCache.Observation?
  private var initial: NativePrefixParityProbe.StateComparison?
  private var checkpoints: [NativePrefixParityProbe.StateComparison] = []
  private var final: NativePrefixParityProbe.StateComparison?
  private var forwards: [Forward] = []
  private var samples: [Sample] = []
  private var differences: [String] = []
  private var sampleIndex = 0
  private var samplerDiffered = false
  private var admissionChecks = 0
  private var largestAdmission: UInt64 = 0

  init(mode: Mode, store: ActiveNativeKVOracleStore, prompt: [Int],
    policy: ModelGenerationPolicy, settings: SamplingSettings, seeds: [UInt64],
    flag: CancellationFlag, admit: @escaping @Sendable (UInt64) throws -> Void) {
    self.mode = mode; self.store = store; self.prompt = prompt; self.policy = policy
    self.settings = settings; self.seeds = seeds; self.flag = flag; self.admit = admit
  }
  private func perform(_ body: () throws -> Void) {
    lock.lock(); let failed = failure != nil; lock.unlock()
    guard !failed else { return }
    do { try flag.check(); try ModelResidency.check(); try body(); try ModelResidency.check() }
    catch {
      lock.lock(); if failure == nil { failure = String(describing: error) }; lock.unlock()
      flag.cancel()
    }
  }
  func requireSuccessful() throws {
    lock.lock(); let value = failure; lock.unlock()
    if let value { throw BoomError.invalid("Active native diagnostic refused: " + value) }
  }
  private func requestAdmission(_ bytes: UInt64) throws {
    admissionChecks += 1; largestAdmission = max(largestAdmission, bytes)
    try admit(bytes)
  }
  static func validateMatrix(_ rows: [[Int]], width: Int, vocabulary: Int) throws -> [Int] {
    guard (1...3).contains(width), rows.count == width, let count = rows.first?.count, count > 0,
      rows.allSatisfy({ $0.count == count && $0.allSatisfy { $0 >= 0 && $0 < vocabulary && $0 <= Int(Int32.max) } }) else {
      throw BoomError.invalid("The actual numerical input matrix is ragged, unbound or outside vocabulary.")
    }
    return rows.flatMap { $0 }
  }
  private func tensorBytes(_ arrays: [MLXArray]) throws -> UInt64 {
    try arrays.reduce(UInt64(0)) { current, a in
      guard a.nbytes >= 0 else { throw BoomError.invalid("Negative diagnostic tensor bytes.") }
      let (next, overflow) = current.addingReportingOverflow(UInt64(a.nbytes))
      guard !overflow else { throw BoomError.budget("Diagnostic tensor bytes overflowed.") }; return next
    }
  }
  static func checkedScale(_ bytes: UInt64, by factor: UInt64) throws -> UInt64 {
    let (value, overflow) = bytes.multipliedReportingOverflow(by: factor)
    guard !overflow else { throw BoomError.budget("Diagnostic allocation bound overflowed.") }
    return value
  }
  private func reserveSnapshot(_ native: [any KVCache]) throws {
    try requestAdmission(Self.checkedScale(try tensorBytes(native.flatMap { $0.innerState() }), by: 2))
  }
  private func comparisonAllowance(_ a: any KVCache, _ b: any KVCache, n: Int) throws -> UInt64 {
    let arrays = a.innerState() + b.innerState()
    let largest: UInt64 = try arrays.map { a -> UInt64 in
      guard a.ndim == 4, a.dim(0) > 0 else { throw BoomError.invalid("Unsupported native diagnostic rank.") }
      // Reduce rows individually; full physical parents stay charged in U.
      return try Self.checkedScale(UInt64(a.size / a.dim(0)), by: 4)
    }.max() ?? 0
    let offset = max(a.offset, b.offset)
    let (positions, overflow) = offset.addingReportingOverflow(n)
    guard !overflow, n > 0, positions > 0 else { throw BoomError.budget("Diagnostic mask bound overflowed.") }
    let mask = try Self.checkedScale(try Self.checkedScale(UInt64(positions), by: UInt64(n)), by: 4)
    // Native compareTensor's casts/masks/arithmetic/int64 reductions use fewer
    // than128 bytes per compared element;32 promoted Float32 spans cover them. One layer's temporaries are drained before
    // the next comparison; this is diagnostic scratch, not released-byte credit.
    let chronology = try tensorBytes(arrays)
    let scratch = try Self.checkedScale(max(largest, mask), by: 32)
    let (total, sumOverflow) = scratch.addingReportingOverflow(chronology)
    guard !sumOverflow else { throw BoomError.budget("Diagnostic chronology/scratch bound overflowed.") }
    try requestAdmission(total)
    return chronology
  }
  private func compareState(n: Int) throws -> NativePrefixParityProbe.StateComparison {
    guard oracle.count == cache.count, oracle.count == windows.count, !oracle.isEmpty else {
      throw BoomError.invalid("Diagnostic state layers disagree.")
    }
    var layers: [NativePrefixParityProbe.LayerComparison] = []
    for layer in oracle.indices {
      let chronology = try comparisonAllowance(oracle[layer], cache[layer], n: n)
      let result = try autoreleasepool {
        try NativePrefixParityProbe.compareState(oracle: [oracle[layer]], hydrated: [cache[layer]],
          suffixLength: n, maskWindows: [windows[layer]], compareValues: { try self.compareRows($0, $1, chronology: chronology) })
      }
      let row = result.layers[0]
      layers.append(.init(layer: layer, reference: row.reference, candidate: row.candidate,
        structuralDifferences: row.structuralDifferences, keys: row.keys, values: row.values,
        normalMask: row.normalMask, materializedMask: row.materializedMask))
    }
    return .init(suffixLength: n, maskWindows: windows, layers: layers)
  }
  private func compareLogits(_ reference: MLXArray, _ actual: MLXArray) throws -> NativePrefixParityProbe.TensorComparison {
    let largest = try Self.checkedScale(UInt64(max(reference.size, actual.size)), by: 4)
    try requestAdmission(Self.checkedScale(largest, by: 32))
    return try autoreleasepool { try NativePrefixParityProbe.compareTensor(reference, actual) }
  }
  static func mergeRows(_ rows: [NativePrefixParityProbe.TensorComparison],
    reference: MLXArray, candidate: MLXArray) -> NativePrefixParityProbe.TensorComparison {
    var result = NativePrefixParityProbe.TensorComparison(reference: .init(reference), candidate: .init(candidate),
      shapeEqual: reference.shape == candidate.shape, dtypeEqual: reference.dtype == candidate.dtype)
    result.numericEqual = rows.allSatisfy { $0.numericEqual == true }
    result.bitwiseEqual = rows.allSatisfy { $0.bitwiseEqual == true }
    result.differingElementCount = rows.allSatisfy { $0.differingElementCount != nil }
      ? rows.reduce(0) { $0 + ($1.differingElementCount ?? 0) } : nil
    result.firstDifferingAxis2Index = rows.compactMap(\.firstDifferingAxis2Index).min()
    // Axis-position unions and relative/max-error aggregates are deliberately
    // unobserved here; bitwise equality and element counts cover every row.
    return result
  }
  private func compareRows(_ reference: MLXArray, _ candidate: MLXArray, chronology: UInt64) throws -> NativePrefixParityProbe.TensorComparison {
    guard reference.ndim == 4, candidate.ndim == 4, reference.dim(0) == candidate.dim(0),
      (1...3).contains(reference.dim(0)) else {
      throw BoomError.invalid("Numerical KV comparison requires the actual declared matrix width.")
    }
    var rows: [NativePrefixParityProbe.TensorComparison] = []
    for row in 0..<reference.dim(0) {
      let a = reference[row..<row + 1, 0..., 0..., 0...]
      let b = candidate[row..<row + 1, 0..., 0..., 0...]
      let largest = try Self.checkedScale(UInt64(max(a.size, b.size)), by: 4)
      let scratch = try Self.checkedScale(largest, by: 32)
      let (total, overflow) = scratch.addingReportingOverflow(chronology)
      guard !overflow else { throw BoomError.budget("Diagnostic row/chronology bound overflowed.") }
      try requestAdmission(total)
      rows.append(try autoreleasepool { try NativePrefixParityProbe.compareTensor(a, b) })
    }
    return Self.mergeRows(rows, reference: reference, candidate: candidate)
  }
  private func reserveOracle(_ native: [any KVCache], pendingCandidate: Bool, width: Int) throws {
    // This uses the actual owning cache shapes, dtypes, capacities and steps.
    // Aliased source parents remain in measured U. No release/donation credit.
    let owners = native.map { PrefixKVNativeOwnership(native: $0) }
    let layouts = try native.map { entry -> PrefixKVStorage.Layout in
      guard let layout = PrefixKVStorage.layout(of: entry) else { throw BoomError.invalid("Unsupported diagnostic native layout.") }
      return layout
    }
    let plan = try ActiveNativeKVStorage.plan(owners: owners, layouts: layouts,
      prefix: min(native[0].offset, prompt.count - 1), prompt: prompt.count,
      output: 256, width: width, row: 0, prefill: PrefillParameters(stepSize: 512, chunking: .remainder))
    let limit = try ModelResidency.limits()
    let allocations = try plan.transitionAllocations(width: width,
      forwards: pendingCandidate ? 2 : 1, hydration: false)
    let bound = try ProductCore.incrementalKVAdmission(application: limit.applicationBytes, used: 0,
      reserve: limit.workingReserveBytes, layers: allocations).additionalBytesUpperBound
    try requestAdmission(bound)
    withExtendedLifetime(owners) {}
  }
  func session(model: any LanguageModel, value: PromptPrefixCache.Session) {
    perform {
      self.model = model; cache = value.cache.map { PrefixKVStorage.unwrap($0) }
      windows = try cache.map { entry in
        switch PrefixKVStorage.layout(of: entry) {
        case .simple: return nil
        case .rotating(let window, _, _, _): return window
        case nil: throw BoomError.invalid("Diagnostic cache is not an owning native simple/rotating layer.")
        }
      }
      guard value.usesActiveNativeState, value.observation.algorithm == PromptPrefixCache.activeAlgorithm else {
        throw BoomError.invalid("The numeric operation must use the normal active-native path.")
      }
      sessionObservation = value.observation
      switch mode {
      case .source:
        guard value.cachedTokenCount == 0 else { throw BoomError.invalid("Source replay unexpectedly reused KV.") }
      case .query(_, let expected, let boundary):
        guard value.cachedTokenCount == expected, expected > 0 else {
          throw BoomError.invalid("Actual query lookup changed its timing-bound prefix.")
        }
        let snapshot: NativePrefixParityProbe.Snapshot
        if let boundary, let captured = store.snapshots[boundary] { snapshot = captured }
        else if boundary == nil, let captured = store.finished { snapshot = captured }
        else { throw BoomError.unavailable("The original actual native source boundary was not captured.") }
        // Crop may concatenate chronology; reserve its full possible output and
        // the next normal update before constructing/evaluating that graph.
        let rawBytes = try tensorBytes(snapshot.layers.flatMap { [$0.keys, $0.values] })
        let (copyBound, overflow) = rawBytes.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw BoomError.budget("Oracle hydration bound overflowed.") }
        try requestAdmission(copyBound)
        oracle = try snapshot.oracle(prefix: expected)
        let next = min(512, max(1, prompt.count - expected - 1))
        initial = try compareState(n: next)
        if initial?.allKVBitsEqual != true || initial?.allMasksEqual != true { differences.append("initial_native_KV_metadata_or_masks") }
        samplers = seeds.map { GenerateParameters(temperature: settings.temperature, topP: settings.topP,
          topK: settings.topK, minP: settings.minP, repetitionPenalty: nil, seed: $0).sampler() }
      }
    }
  }
  static func submittedBoundary(processed: Int, total: Int, cached: Int) -> Int? {
    guard processed > 0, processed < total, cached >= 0 else { return nil }
    let (end, overflow) = cached.addingReportingOverflow(processed)
    return overflow ? nil : end
  }
  func submittedPrefill(processed: Int, total: Int, cached: Int) {
    guard let end = Self.submittedBoundary(processed: processed, total: total, cached: cached) else { return }
    perform {
      switch mode {
      case .source:
        if end == 15_872 || end == 16_127 {
          guard cache.allSatisfy({ $0.offset == end }) else { throw BoomError.invalid("Source boundary is not a complete owning-layer cohort.") }
          try reserveSnapshot(cache)
          let captured = try NativePrefixParityProbe.captureNative(cache, evaluatedPrefix: end, selectedRow: 0)
          store.snapshots[end] = captured; store.sourceRecords.append(captured.source)
        }
      case .query:
        try advanceReference(to: end, width: 1, pendingCandidate: false, sampleable: false, actual: nil)
        let state = try compareState(n: min(512, max(1, prompt.count - end)))
        checkpoints.append(state)
        if !state.allKVBitsEqual || !state.allMasksEqual { differences.append("submitted_prefill_KV_metadata_or_masks") }
      }
    }
  }
  private func advanceReference(to end: Int, width: Int, pendingCandidate: Bool,
    sampleable: Bool, actual: MLXArray?) throws {
    guard let model, !oracle.isEmpty, oracle.allSatisfy({ $0.offset == oracle[0].offset }) else {
      throw BoomError.invalid("Independent oracle lost its actual owning-layer cursor.")
    }
    let start = oracle[0].offset
    let matrix: [[Int]]
    if start < end {
      if end <= prompt.count {
        guard width == 1 else { throw BoomError.invalid("Shared prompt prefill changed width.") }
        matrix = [Array(prompt[start..<end])]
      } else {
        guard end == start + 1 else { throw BoomError.invalid("Decode skipped an unrecorded native forward.") }
        if width == 1 {
          guard let token = actualSingleSamples.last else { throw BoomError.invalid("Missing actual single sampled input.") }
          matrix = [[token]]
        } else {
          guard let pendingBatch, pendingBatch.count == width else { throw BoomError.invalid("Missing actual sibling/inert token matrix.") }
          matrix = pendingBatch.map { [$0] }; self.pendingBatch = nil
        }
      }
      try reserveOracle(oracle, pendingCandidate: pendingCandidate, width: width)
      let count = matrix[0].count
      let flat = try Self.validateMatrix(matrix, width: width, vocabulary: policy.vocabularySize)
      let output = model(LMInput.Text(tokens: MLXArray(flat.map(Int32.init)).reshaped([width, count])),
        cache: oracle, state: nil)
      guard output.state == nil, output.logits.ndim == 3, output.logits.dim(0) == width,
        output.logits.dim(1) == count, output.logits.dim(2) == policy.vocabularySize,
        oracle.allSatisfy({ $0.offset == end }) else { throw BoomError.invalid("Oracle changed native state, offsets or matrix/logit shape.") }
      referenceLogits = sampleable ? output.logits[0..., -1, 0...] : nil
      // Intermediate head logits are discarded in both normal prefill and the
      // reference. No extra model forward is added to observe them.
      if sampleable, let referenceLogits { eval(referenceLogits); eval(oracle) }
      else { eval(oracle) }
    } else { matrix = [] }
    guard start <= end else { throw BoomError.invalid("Oracle cursor advanced beyond the actual candidate.") }
    let masks = try oracle.indices.map { layer in
      _ = try comparisonAllowance(oracle[layer], cache[layer], n: 1)
      return try autoreleasepool { try NativePrefixParityProbe.compareMask(oracle[layer], cache[layer],
        n: 1, window: windows[layer], returnArray: true) }
    }
    if !masks.allSatisfy(\.bitwiseEqual) { differences.append("native_masks") }
    var logits: NativePrefixParityProbe.TensorComparison?
    if sampleable {
      guard let actual, let referenceLogits else { throw BoomError.invalid("Missing actual sampleable logits.") }
      logits = try compareLogits(referenceLogits, actual)
      if logits?.bitwiseEqual != true { differences.append("sampleable_logit_bits") }
    }
    forwards.append(Forward(input_token_matrix: matrix, start_offset: start, end_offset: end,
      width: width, reference_teacher_forced_after_sampler_difference: samplerDiffered,
      sampleable_logits: logits, masks: masks))
  }
  func logits(_ value: MLXArray, width: Int, active: [Bool]?, initialBatch: Bool = false) {
    guard case .query = mode else { return }
    perform {
      guard cache.allSatisfy({ $0.offset == cache[0].offset }), value.ndim == 2,
        value.dim(0) == width, value.dim(1) == policy.vocabularySize else { throw BoomError.invalid("Actual sampleable logit matrix changed.") }
      try advanceReference(to: cache[0].offset, width: width, pendingCandidate: width == 1,
        sampleable: true, actual: value)
      if sampleIndex == 0, !initialBatch {
        let state = try compareState(n: 1)
        checkpoints.append(state)
        if !state.allKVBitsEqual || !state.allMasksEqual { differences.append("final_prefill_KV_metadata_or_masks") }
      }
      if !initialBatch {
        guard let referenceLogits, samplers.count == width,
          active == nil || active?.count == width else { throw BoomError.invalid("Independent sample row widths changed.") }
        let mask = CheckpointTokenMask(policy.suppressedTokenIDs)
        let filtered = mask.process(logits: referenceLogits)
        expectedSamples = samplers.indices.map { row in
          if active?[row] == false { return policy.eosTokenIDs[0] }
          let token = samplers[row].sample(logits: filtered[row].expandedDimensions(axis: 0))
          eval(token); return token.item(Int.self)
        }
      }
    }
  }
  func expanded(width: Int) {
    guard case .query = mode else { return }
    perform {
      let bytes = try tensorBytes(oracle.flatMap { $0.innerState() })
      try requestAdmission(Self.checkedScale(bytes, by: UInt64(width)))
      for var entry in oracle {
        let state = entry.innerState(), offset = entry.offset, meta = entry.metaState
        guard state.count == 2, state.allSatisfy({ $0.dim(0) == 1 }) else { throw BoomError.invalid("Oracle shared prefill was not width one.") }
        entry.state = state.map { broadcast($0, to: [width] + Array($0.shape.dropFirst())) }
        if case .simple = PrefixKVStorage.layout(of: entry) { _ = entry.trim(entry.offset - offset) }
        else { entry.metaState = meta }
      }
      guard let referenceLogits else { throw BoomError.invalid("Missing shared reference last logits.") }
      self.referenceLogits = broadcast(referenceLogits, to: [width, referenceLogits.dim(1)])
      eval(oracle)
    }
  }
  func sampledSingle(_ token: MLXArray) {
    guard case .query = mode else { return }
    perform { eval(token); let id = token.item(Int.self); try recordSamples([id], active: [true]); actualSingleSamples.append(id) }
  }
  func sampledBatch(_ event: ActiveNativeKVProbeHooks.MatrixEvent) {
    perform {
      switch mode {
      case .source(let selected, let prefix):
        if let selected, let prefix, event.native_offset_before_next_input == prefix, store.finished == nil {
          guard event.finished_before_sample.count == seeds.count, event.finished_after_sample.count == seeds.count,
            (0..<seeds.count).contains(selected), !event.finished_before_sample[selected] else {
            throw BoomError.invalid("Selected native checkpoint lacks the actual active row/matrix ledger.")
          }
          let end = event.native_offset_before_next_input
          try reserveSnapshot(cache)
          let captured = try NativePrefixParityProbe.captureNative(cache, evaluatedPrefix: end, selectedRow: selected)
          store.finished = captured; store.sourceRecords.append(captured.source)
        }
      case .query:
        try recordSamples(event.input_token_ids, active: event.finished_before_sample.map { !$0 })
        if event.submitted_as_next_input { pendingBatch = event.input_token_ids }
      }
    }
  }
  private func recordSamples(_ actual: [Int], active: [Bool]) throws {
    guard actual.count == expectedSamples.count, actual.count == seeds.count, active.count == actual.count else {
      throw BoomError.invalid("Missing independent sample or actual row ledger.") }
    for row in actual.indices where active[row] {
      samples.append(Sample(row: row, seed: seeds[row], sample_index: sampleIndex,
        reference_token_id: expectedSamples[row], actual_candidate_token_id: actual[row]))
      if actual[row] != expectedSamples[row] { samplerDiffered = true; differences.append("independent_sampler_token_bits") }
    }
    expectedSamples.removeAll(); sampleIndex += 1
  }
  func joined() {
    guard case .query = mode else { cache.removeAll(); model = nil; return }
    perform {
      final = try compareState(n: 1)
      if final?.allKVBitsEqual != true || final?.allMasksEqual != true { differences.append("joined_KV_metadata_or_masks") }
    }
    releaseWorkingArraysAfterJoin()
  }
  func releaseWorkingArraysAfterJoin() {
    oracle.removeAll(); cache.removeAll(); referenceLogits = nil; model = nil; samplers.removeAll()
  }
  func result() -> Result {
    lock.lock(); let failure = self.failure; lock.unlock()
    let name: String
    switch mode { case .source: name = "source_replay"; case .query(let n, _, _): name = n }
    return Result(name: name, source_native_layers: store.sourceRecords,
      actual_session: sessionObservation, initial_state: initial, prefill_checkpoint_states: checkpoints,
      final_state: final, forwards: forwards, samples: samples,
      exact: failure == nil && differences.isEmpty && (name == "source_replay" || !samples.isEmpty),
      differences: differences, failure: failure, diagnostic_admission_checks: admissionChecks,
      largest_additional_allocation_bound_bytes: largestAdmission)
  }
}
