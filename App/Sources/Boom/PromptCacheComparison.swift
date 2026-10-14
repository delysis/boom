import BoomCore
import Foundation

extension PromptCacheReuseSmoke {
  enum OutputHistoryRelation: String, Codable, Sendable {
    case sameObservedPartitions = "same_observed_partitions"
    case differentObservedPartitions = "different_observed_partitions"
    case differentObservedInputs = "different_observed_inputs"
    case unknown
    case incompatibleRequest = "incompatible_request"
  }
  struct ComparisonForward: Codable, Equatable, Sendable {
    let origin: PromptPrefixCache.Origin
    let start: Int
    let end: Int
    let evaluatedEnd: Int?
    let width: Int
    let row: Int?
    var originalInput: PromptPrefixCache.OperandWitness? = nil
    func hasSamePartition(as other: Self) -> Bool {
      origin == other.origin && start == other.start && end == other.end
        && evaluatedEnd == other.evaluatedEnd && width == other.width && row == other.row
    }
  }
  struct OutputHistoryEvidence: Encodable, Equatable, Sendable {
    let requestBinding: String
    let promptTokens: Int
    let decodeWidth: Int
    let decodeRow: Int
    let preparePath: String
    let forwards: [ComparisonForward]
    let blockers: [String]
    let evidenceScope = "retained_native_prefix_descriptors_and_pinned_text_prepare_callbacks; not_independent_KV_or_kernel_parity"
  }
  struct OutputHistoryClassification: Codable, Sendable {
    let relation: OutputHistoryRelation
    let differences: [String]
    var requiresExactOutput: Bool { relation == .sameObservedPartitions }
    var requiredComparisonAdmitted: Bool {
      relation == .sameObservedPartitions || relation == .differentObservedPartitions || relation == .differentObservedInputs
    }
  }

  static func comparisonHistoryProblems(_ evidence: OutputHistoryEvidence) -> [String] {
    var problems = evidence.blockers
    guard evidence.promptTokens > 0, evidence.decodeWidth > 0,
      (0..<evidence.decodeWidth).contains(evidence.decodeRow),
      evidence.requestBinding.utf8.count == 64,
      evidence.requestBinding.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      ["token-iterator-constructor", "shared-prefill-model-prepare"].contains(evidence.preparePath) else {
      return problems + ["request_or_prepare_evidence_missing"]
    }
    var end = 0
    for forward in evidence.forwards {
      guard let evaluated = forward.evaluatedEnd,
        forward.start == end, forward.start >= 0, forward.end > forward.start,
        forward.end <= evidence.promptTokens, evaluated >= forward.end,
        forward.width > 0,
        (forward.width == 1 ? forward.row == nil : forward.row.map({ (0..<forward.width).contains($0) }) == true)
      else { problems.append("forward_history_gap_or_metadata_missing"); return problems }
      let widthMatchesOrigin = forward.origin == .singleDecode ? forward.width == 1
        : (forward.origin == .batchDecode ? forward.width > 1 : (1...4).contains(forward.width))
      if !widthMatchesOrigin {
        problems.append("forward_origin_width_invalid")
      }
      end = forward.end
    }
    if end != evidence.promptTokens { problems.append("forward_history_incomplete") }
    return problems
  }

  static func comparisonBindingsMatch(_ lhs: [OutputHistoryEvidence],
    _ rhs: [OutputHistoryEvidence]) -> Bool {
    !lhs.isEmpty && lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
      a.requestBinding.utf8.count == 64
        && a.requestBinding.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        && a.requestBinding == b.requestBinding && a.promptTokens > 0 && a.promptTokens == b.promptTokens
        && a.decodeWidth > 0 && a.decodeWidth == b.decodeWidth && a.decodeRow == b.decodeRow
        && (0..<a.decodeWidth).contains(a.decodeRow)
    }
  }

  static func classifyOutputHistories(_ lhs: [OutputHistoryEvidence],
    _ rhs: [OutputHistoryEvidence]) -> OutputHistoryClassification {
    guard !lhs.isEmpty, lhs.count == rhs.count else {
      return .init(relation: .unknown, differences: ["lane_history_missing"])
    }
    guard comparisonBindingsMatch(lhs, rhs) else {
      return .init(relation: .incompatibleRequest, differences: ["request_binding"])
    }
    var shapeDifferences: [String] = [], inputDifferences: [String] = []
    var blockers: [String] = [], inputLimitations: [String] = []
    for row in lhs.indices {
      let a = lhs[row], b = rhs[row], label = "lane_\(row)."
      blockers += comparisonHistoryProblems(a).map { label + "first." + $0 }
      blockers += comparisonHistoryProblems(b).map { label + "second." + $0 }
      for (side, value) in [("first", a), ("second", b)] {
        for (index, forward) in value.forwards.enumerated() {
          let key = label + side + ".forward_\(index)."
          let required = forward.width > 1 || (forward.evaluatedEnd ?? forward.end) > forward.end
          if let binding = forward.originalInput?.binding {
            guard let evaluated = forward.evaluatedEnd,
              binding.phase == (forward.origin == .prefill ? .prefill : .decode),
              binding.covers(start: forward.start, end: forward.end, evaluatedEnd: evaluated,
                width: forward.width, row: forward.row) else {
              inputLimitations.append(key + "original_operand_binding_invalid_or_unsupported"); continue
            }
          } else if required {
            inputLimitations.append(key + (forward.width > 1
              ? "original_batch_operand_matrix_unrecorded" : "original_evaluated_input_beyond_prefix_unrecorded"))
          }
        }
      }
      if a.preparePath != b.preparePath { shapeDifferences.append(label + "prepare_path") }
      if a.forwards.count != b.forwards.count { shapeDifferences.append(label + "forward_count") }
      for index in 0..<min(a.forwards.count, b.forwards.count) {
        let x = a.forwards[index], y = b.forwards[index]
        if x.evaluatedEnd != nil, y.evaluatedEnd != nil, !x.hasSamePartition(as: y) {
          shapeDifferences.append(label + "forward_\(index).partition")
        }
        if let first = x.originalInput, let second = y.originalInput, first != second {
          inputDifferences.append(label + "forward_\(index).original_operands_or_membership")
        }
      }
    }
    // A known shape difference never recovers missing original peer operands
    // or input positions beyond a retained prefix.
    if !blockers.isEmpty || !inputLimitations.isEmpty {
      return .init(relation: .unknown, differences: blockers + inputLimitations + shapeDifferences + inputDifferences)
    }
    if !inputDifferences.isEmpty {
      return .init(relation: .differentObservedInputs, differences: inputDifferences + shapeDifferences)
    }
    if !shapeDifferences.isEmpty {
      return .init(relation: .differentObservedPartitions, differences: shapeDifferences)
    }
    return .init(relation: .sameObservedPartitions, differences: [])
  }

  /// This is deliberately scoped to the frozen public text-only prepare paths.
  /// Callback boundaries observe graph construction, not kernel selection or KV
  /// bytes. Independent same-history native parity remains a separate gate.
  static func comparisonHistories(outputs: [MLXGemmaRunner.Output],
    callbackPositions: [Int], batch: MLXGemmaRunner.BatchMetrics?,
    requestBinding: String) -> [OutputHistoryEvidence] {
    outputs.enumerated().map { row, output in
      var blockers: [String] = [], forwards: [ComparisonForward] = []
      let width = outputs.count, path = output.setupMetrics?.path ?? "unavailable"
      var cached = 0
      if let origin = output.executionOrigin, origin.isValid(promptTokens: output.promptTokens) {
        cached = origin.cachedPromptTokens
        if origin.cacheAlgorithm != PromptPrefixCache.activeAlgorithm {
          blockers.append("cache_algorithm_not_current")
        }
        if let metrics = output.prefillCacheMetrics,
          !(metrics.cachedPromptTokens == cached && metrics.fullPromptTokens == output.promptTokens
            && metrics.algorithm == origin.cacheAlgorithm && metrics.missReason == origin.cacheMissReason
            && metrics.prefilledPromptTokens == output.promptTokens - cached
            && (cached > 0 || metrics.cachedForwardHistory.isEmpty)) {
          blockers.append("execution_origin_cache_metrics_disagree")
        }
      } else { blockers.append("execution_origin_missing_or_invalid") }
      if width > 1, !(batch?.width == width && batch?.sharedPromptPrefills == 1) {
        blockers.append("shared_single_row_prefill_unverified")
      }
      if cached > 0 {
        if let metrics = output.prefillCacheMetrics,
          metrics.cachedPromptTokens == cached, metrics.fullPromptTokens == output.promptTokens {
          forwards = metrics.cachedForwardHistory.map {
            ComparisonForward(origin: $0.origin, start: $0.startTokenCount,
              end: $0.endTokenCount, evaluatedEnd: $0.evaluatedEndTokenCount,
              width: $0.batchWidth, row: $0.row, originalInput: $0.originalInput)
          }
          if forwards.last?.end != cached { blockers.append("cached_forward_boundary_missing") }
        } else { blockers.append("cached_forward_history_missing") }
      }
      var processed = cached
      for position in callbackPositions {
        if position == processed && position == output.promptTokens { continue }
        guard position > processed, position <= output.promptTokens else {
          blockers.append("callback_forward_boundary_invalid"); break
        }
        forwards.append(.init(origin: .prefill, start: processed, end: position,
          evaluatedEnd: position, width: 1, row: nil))
        processed = position
      }
      if processed != output.promptTokens { blockers.append("terminal_prefill_boundary_missing") }
      return OutputHistoryEvidence(requestBinding: requestBinding, promptTokens: output.promptTokens,
        decodeWidth: width, decodeRow: row, preparePath: path, forwards: forwards, blockers: blockers)
    }
  }

  struct OutputComparisonOutcome: Sendable {
    let history: OutputHistoryClassification
    let exactObserved: Bool
    var requiredComparisonPassed: Bool {
      history.requiredComparisonAdmitted && (!history.requiresExactOutput || exactObserved)
    }
    var numericalComparisonQualified: Bool { history.requiresExactOutput && exactObserved }
  }
  enum GeneratedControlDisposition: String, Sendable {
    case passed, failed
    case qualificationOpen = "qualification_open"
  }
  static func generatedControlDisposition(semanticPassed: Bool, inputExact: Bool,
    comparisons: [OutputComparisonOutcome?]) -> GeneratedControlDisposition {
    guard semanticPassed, inputExact, comparisons.count == 3,
      comparisons.allSatisfy({ $0?.requiredComparisonPassed == true }) else { return .failed }
    return comparisons.allSatisfy({ $0?.numericalComparisonQualified == true })
      ? .passed : .qualificationOpen
  }
}
