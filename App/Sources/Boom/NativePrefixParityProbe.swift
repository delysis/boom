// Explicit public native-value diagnostic; ordinary inference never calls it.
// Pinned MLXSwiftLM: 9afc3b55f75a0d41a3d0c11330b9df6a036d24e4.
// Call only under the model's exclusive owner, on its inference executor.
// Evaluations, comparisons and copies below are diagnostic work, never hot-path hooks.
import Foundation
import MLX
import MLXLMCommon

enum NativePrefixParityProbe {
  enum Failure: Error {
    case invalid(String)
    case oracleUnavailable(layer: Int, required: [TokenRange], present: [TokenRange])
  }

  struct TokenRange: Codable, Sendable, Equatable {
    let start: Int
    let end: Int
    init(_ range: Range<Int>) { start = range.lowerBound; end = range.upperBound }
  }

  struct TensorDescriptor: Codable, Sendable {
    let shape: [Int]
    let dtype: String
    init(_ array: MLXArray) {
      shape = array.shape
      dtype = String(describing: array.dtype)
    }
  }

  // JSON never silently discards an infinite or NaN diagnostic reduction.
  struct Scalar: Codable, Sendable {
    let value: Double?
    let exceptional: String?
    init(_ value: Float) {
      self.value = value.isFinite ? Double(value) : nil
      exceptional = value.isNaN ? "nan" : (value == .infinity ? "positive_infinity"
        : (value == -.infinity ? "negative_infinity" : nil))
    }
  }

  struct TensorComparison: Codable, Sendable {
    let reference: TensorDescriptor
    let candidate: TensorDescriptor
    let shapeEqual: Bool
    let dtypeEqual: Bool
    var numericEqual: Bool? = nil
    var bitwiseEqual: Bool? = nil
    var differingElementCount: Int? = nil
    var firstDifferingAxis2Index: Int? = nil
    var differingAxis2Count: Int? = nil
    var referenceNonFiniteCount: Int? = nil
    var candidateNonFiniteCount: Int? = nil
    var finitePairCount: Int? = nil
    var maxAbsoluteErrorOnFinitePairs: Scalar? = nil
    var nonzeroReferenceFinitePairCount: Int? = nil
    var maxRelativeErrorOnNonzeroReferenceFinitePairs: Scalar? = nil
    var zeroReferenceNonzeroCandidateFinitePairCount: Int? = nil
  }

  struct SourceLayer: Codable, Sendable {
    let layer: Int
    let nativeClass: String
    let offset: Int
    let scalarRoPEOffset: Int
    let metadata: [String]
    let rawKeys: TensorDescriptor
    let rawValues: TensorDescriptor
    let sourceBatchWidth: Int
    let selectedRow: Int
    let presentRanges: [TokenRange]
  }

  // Tensor-bearing types intentionally do not conform to Sendable. Keep them on
  // the inference executor. No array is serialized or copied to host memory.
  struct Snapshot {
    let evaluatedPrefix: Int
    let selectedRow: Int
    let layers: [Layer]
    var source: [SourceLayer] { layers.map(\.source) }

    func oracle(prefix: Int) throws -> [any KVCache] {
      guard prefix > 0, prefix <= evaluatedPrefix else {
        throw Failure.invalid("Oracle prefix is outside the evaluated native source.")
      }
      return try layers.map { try $0.oracle(prefix: prefix, row: selectedRow) }
    }
  }

  struct RingMetadata {
    let keep: Int
    let window: Int
    let step: Int
    let offset: Int
    let index: Int
    let origin: String
    let wrapped: Bool

    init(_ metadata: [String], capacity: Int) throws {
      guard metadata.count == 7,
        let keep = Int(metadata[0]), let window = Int(metadata[1]),
        let step = Int(metadata[2]), let offset = Int(metadata[3]),
        let index = Int(metadata[4]), let wrapped = Bool(metadata[6]),
        keep >= 0, window > keep, step > 0, offset >= 0,
        index >= 0, index <= capacity,
        metadata[5] == "modelNative" || metadata[5] == "requested"
      else { throw Failure.invalid("Unsupported or malformed native rotating metadata.") }
      if wrapped, index < keep {
        throw Failure.invalid("Native ring write index lies inside its preserved prefix.")
      }
      self.keep = keep; self.window = window; self.step = step
      self.offset = offset; self.index = index; origin = metadata[5]
      self.wrapped = wrapped
    }
  }

  enum Kind { case full(step: Int); case rotating(RingMetadata) }

  struct Segment {
    let absolute: Range<Int>
    let chronological: Range<Int>
  }

  struct Layer {
    let source: SourceLayer
    let kind: Kind
    let keys: MLXArray
    let values: MLXArray
    let segments: [Segment]

    // Read chronology from the pinned *native* storage and metadata. This is
    // independent of PrefixKVStorage and the resident manager's spans/index.
    func chronologicalRow(_ array: MLXArray, row: Int) -> MLXArray {
      let selected = array[row ..< row + 1, 0..., 0..., 0...]
      switch kind {
      case .full:
        return selected[0..., 0..., 0 ..< source.offset, 0...]
      case .rotating(let ring):
        if ring.index == array.dim(2) { return selected }
        if !ring.wrapped { return selected[0..., 0..., 0 ..< ring.index, 0...] }
        var parts: [MLXArray] = []
        if ring.keep > 0 {
          parts.append(selected[0..., 0..., 0 ..< ring.keep, 0...])
        }
        if ring.index < array.dim(2) {
          parts.append(selected[0..., 0..., ring.index ..< array.dim(2), 0...])
        }
        if ring.index > ring.keep {
          parts.append(selected[0..., 0..., ring.keep ..< ring.index, 0...])
        }
        return parts.count == 1 ? parts[0] : concatenated(parts, axis: 2)
      }
    }

    func cropped(_ array: MLXArray, ranges: [Range<Int>], row: Int) throws -> MLXArray {
      let chronological = chronologicalRow(array, row: row)
      var parts: [MLXArray] = []
      for required in ranges {
        var cursor = required.lowerBound
        for segment in segments {
          let lower = max(cursor, segment.absolute.lowerBound)
          let upper = min(required.upperBound, segment.absolute.upperBound)
          guard lower < upper else { continue }
          guard lower == cursor else {
            throw Failure.oracleUnavailable(layer: source.layer,
              required: ranges.map(TokenRange.init), present: source.presentRanges)
          }
          let begin = segment.chronological.lowerBound + lower - segment.absolute.lowerBound
          parts.append(chronological[0..., 0..., begin ..< begin + upper - lower, 0...])
          cursor = upper
          if cursor == required.upperBound { break }
        }
        guard cursor == required.upperBound else {
          throw Failure.oracleUnavailable(layer: source.layer,
            required: ranges.map(TokenRange.init), present: source.presentRanges)
        }
      }
      guard !parts.isEmpty else { throw Failure.invalid("Empty native oracle crop.") }
      return parts.count == 1 ? parts[0] : concatenated(parts, axis: 2)
    }

    func oracle(prefix: Int, row: Int) throws -> any KVCache {
      let required: [Range<Int>]
      switch kind {
      case .full:
        required = [0 ..< prefix]
      case .rotating(let ring):
        if prefix <= ring.window { required = [0 ..< prefix] }
        else {
          required = (ring.keep > 0 ? [0 ..< ring.keep] : [])
            + [prefix - (ring.window - ring.keep) ..< prefix]
        }
      }
      // Never lower a requested window, rewind an offset alone, or regenerate
      // unavailable K/V. Each required absolute position must already be here.
      let k = try cropped(keys, ranges: required, row: row)
      let v = try cropped(values, ranges: required, row: row)
      switch kind {
      case .full(let step):
        let restored = KVCacheSimple()
        restored.step = step
        restored.state = [k, v] // Native setter establishes offset from dim(2).
        guard restored.offset == prefix else { throw Failure.invalid("Full-cache crop offset changed.") }
        return restored
      case .rotating(let ring):
        let restored = RotatingKVCache(maxSize: ring.window, keep: ring.keep, step: ring.step)
        restored.state = [k, v]
        restored.metaState = [String(ring.keep), String(ring.window), String(ring.step),
          String(prefix), String(k.dim(2)), ring.origin, "false"]
        return restored
      }
    }
  }

  static func captureNative(_ native: [any KVCache], evaluatedPrefix: Int,
    selectedRow: Int) throws -> Snapshot {
    guard !native.isEmpty, evaluatedPrefix > 0, selectedRow >= 0 else {
      throw Failure.invalid("Empty or invalid evaluated native boundary.")
    }
    // This is the explicit diagnostic fence. Normal inference does not call it.
    eval(native.flatMap { $0.innerState() })
    let layers = try native.enumerated().map { index, original -> Layer in
      guard original.offset == evaluatedPrefix,
        case .scalar(let rope) = original.ropeOffset, rope == evaluatedPrefix
      else { throw Failure.invalid("Native layer offset or RoPE differs from the evaluated boundary.") }
      let originalRaw = original.innerState()
      try validateKV(originalRaw, row: selectedRow)
      let kind: Kind
      if ObjectIdentifier(type(of: original)) == ObjectIdentifier(KVCacheSimple.self),
        let full = original as? KVCacheSimple {
        kind = .full(step: full.step)
      } else if ObjectIdentifier(type(of: original)) == ObjectIdentifier(RotatingKVCache.self) {
        kind = .rotating(try RingMetadata(original.metaState, capacity: originalRaw[0].dim(2)))
      } else {
        throw Failure.invalid("Oracle only supports exact full-precision native simple/rotating cache classes.")
      }
      // Once per diagnostic boundary, use native copy()'s independent-cache
      // contract. The pinned implementations freeze array descriptors and metadata.
      let frozen = original.copy()
      let raw = frozen.innerState()
      try validateKV(raw, row: selectedRow)
      guard frozen.offset == evaluatedPrefix, frozen.metaState == original.metaState else {
        throw Failure.invalid("Native snapshot metadata changed while being captured.")
      }
      let frozenKind: Kind
      let segments: [Segment]
      switch kind {
      case .full(let step):
        guard raw[0].dim(2) >= evaluatedPrefix else {
          throw Failure.invalid("Native full-cache source is shorter than its offset.")
        }
        frozenKind = .full(step: step)
        segments = [Segment(absolute: 0 ..< evaluatedPrefix, chronological: 0 ..< evaluatedPrefix)]
      case .rotating:
        let ring = try RingMetadata(frozen.metaState, capacity: raw[0].dim(2))
        let held = ring.wrapped ? raw[0].dim(2) : ring.index
        let pinned = min(ring.keep, held)
        let tailCount = held - pinned
        let tailStart = evaluatedPrefix - tailCount
        guard held > 0, held <= evaluatedPrefix, tailStart >= pinned else {
          throw Failure.invalid("Native rotating source coverage overlaps or exceeds its offset.")
        }
        frozenKind = .rotating(ring)
        segments = (pinned > 0
          ? [Segment(absolute: 0 ..< pinned, chronological: 0 ..< pinned)] : [])
          + (tailCount > 0 ? [Segment(absolute: tailStart ..< evaluatedPrefix,
            chronological: pinned ..< held)] : [])
      }
      let source = SourceLayer(layer: index, nativeClass: String(describing: type(of: original)),
        offset: evaluatedPrefix, scalarRoPEOffset: rope, metadata: original.metaState,
        rawKeys: TensorDescriptor(originalRaw[0]), rawValues: TensorDescriptor(originalRaw[1]),
        sourceBatchWidth: originalRaw[0].dim(0), selectedRow: selectedRow,
        presentRanges: segments.map { TokenRange($0.absolute) })
      return Layer(source: source, kind: frozenKind, keys: raw[0], values: raw[1], segments: segments)
    }
    return Snapshot(evaluatedPrefix: evaluatedPrefix, selectedRow: selectedRow, layers: layers)
  }

  static func validateKV(_ arrays: [MLXArray], row: Int) throws {
    guard arrays.count == 2, arrays.allSatisfy({ $0.ndim == 4 && $0.shape.allSatisfy { $0 > 0 } }),
      row >= 0, row < arrays[0].dim(0), arrays[0].dim(0) == arrays[1].dim(0),
      arrays[0].dim(1) == arrays[1].dim(1), arrays[0].dim(2) == arrays[1].dim(2),
      arrays.allSatisfy({ [.float16, .bfloat16, .float32].contains($0.dtype) })
    else { throw Failure.invalid("Native K/V rank, batch row, dimensions or dtype is unsupported.") }
  }

  static func compareTensor(_ reference: MLXArray, _ candidate: MLXArray) throws -> TensorComparison {
    var receipt = TensorComparison(reference: TensorDescriptor(reference), candidate: TensorDescriptor(candidate),
      shapeEqual: reference.shape == candidate.shape, dtypeEqual: reference.dtype == candidate.dtype)
    guard receipt.shapeEqual, receipt.dtypeEqual else { return receipt }
    guard reference.size > 0, [.float16, .bfloat16, .float32, .bool, .int32].contains(reference.dtype) else {
      throw Failure.invalid("Diagnostic reduction dtype or empty tensor is unsupported.")
    }
    let bits: MLXArray
    switch reference.dtype {
    case .float16, .bfloat16: bits = reference.view(dtype: .uint16) .== candidate.view(dtype: .uint16)
    case .float32: bits = reference.view(dtype: .uint32) .== candidate.view(dtype: .uint32)
    default: bits = reference .== candidate
    }
    let a = reference.asType(.float32), b = candidate.asType(.float32)
    let finiteA = isFinite(a), finiteB = isFinite(b)
    let finitePair = finiteA & finiteB
    let nonzero = finitePair & (a .!= Float(0))
    let difference = (a - b).abs()
    let absolute = MLX.where(finitePair, difference, Float(0)).max()
    // No epsilon or tolerance. Zero-reference cases are counted separately;
    // relative error is |test-ref|/|ref| only for finite pairs with ref != 0.
    let denominator = MLX.where(nonzero, a.abs(), Float(1))
    let relative = MLX.where(nonzero, difference / denominator, Float(0)).max()
    let numeric = (reference .== candidate).all(), binary = bits.all()
    let differingElements = (bits .== false).asType(.int64).sum()
    // For [B,H,T,D] K/V this identifies the earliest stored sequence position
    // without transferring tensor values. The driver maps local T through the
    // recorded keep/tail ranges to its absolute token position.
    let equalByAxis2 = reference.ndim == 4 ? bits.all(axes: [0, 1, 3]) : nil
    let badA = (finiteA .== false).asType(.int64).sum()
    let badB = (finiteB .== false).asType(.int64).sum()
    let finiteCount = finitePair.asType(.int64).sum()
    let nonzeroCount = nonzero.asType(.int64).sum()
    let zeroRefMismatch = (finitePair & (a .== Float(0)) & (b .!= Float(0))).asType(.int64).sum()
    eval([numeric, binary, differingElements, badA, badB, finiteCount, absolute,
      nonzeroCount, relative, zeroRefMismatch] + (equalByAxis2.map { [$0] } ?? []))
    receipt.numericEqual = numeric.item(Bool.self); receipt.bitwiseEqual = binary.item(Bool.self)
    receipt.differingElementCount = differingElements.item(Int.self)
    if let equalByAxis2 {
      let positions = equalByAxis2.asArray(Bool.self)
      receipt.firstDifferingAxis2Index = positions.firstIndex(of: false)
      receipt.differingAxis2Count = positions.filter { !$0 }.count
    }
    receipt.referenceNonFiniteCount = badA.item(Int.self); receipt.candidateNonFiniteCount = badB.item(Int.self)
    receipt.finitePairCount = finiteCount.item(Int.self)
    receipt.maxAbsoluteErrorOnFinitePairs = Scalar(absolute.item(Float.self))
    receipt.nonzeroReferenceFinitePairCount = nonzeroCount.item(Int.self)
    receipt.maxRelativeErrorOnNonzeroReferenceFinitePairs = Scalar(relative.item(Float.self))
    receipt.zeroReferenceNonzeroCandidateFinitePairCount = zeroRefMismatch.item(Int.self)
    return receipt
  }

  struct MaskComparison: Codable, Sendable {
    let referenceMode: String
    let candidateMode: String
    let modeEqual: Bool
    let array: TensorComparison?
    var bitwiseEqual: Bool { modeEqual && (array == nil || array?.bitwiseEqual == true) }
  }

  static func compareMask(_ a: any KVCache, _ b: any KVCache, n: Int,
    window: Int?, returnArray: Bool) throws -> MaskComparison {
    let reference = a.makeMask(n: n, windowSize: window, returnArray: returnArray)
    let candidate = b.makeMask(n: n, windowSize: window, returnArray: returnArray)
    let ra = reference.mask, ca = candidate.mask
    let rm = ra == nil ? (reference.mode == "causal" ? "causal" : "none") : "array"
    let cm = ca == nil ? (candidate.mode == "causal" ? "causal" : "none") : "array"
    return MaskComparison(referenceMode: rm, candidateMode: cm, modeEqual: rm == cm,
      array: try ra.flatMap { r in try ca.map { c in try compareTensor(r, c) } })
  }

  struct CacheDescriptor: Codable, Sendable {
    let nativeClass: String
    let offset: Int
    let scalarRoPEOffset: Int?
    let maxSize: Int?
    let step: Int?
    let metadata: [String]
    let raw: [TensorDescriptor]
    init(_ cache: any KVCache) {
      nativeClass = String(describing: type(of: cache)); offset = cache.offset
      if case .scalar(let value) = cache.ropeOffset { scalarRoPEOffset = value }
      else { scalarRoPEOffset = nil }
      maxSize = cache.maxSize; step = (cache as? KVCacheSimple)?.step
      metadata = cache.metaState; raw = cache.innerState().map(TensorDescriptor.init)
    }
  }

  struct LayerComparison: Codable, Sendable {
    let layer: Int
    let reference: CacheDescriptor
    let candidate: CacheDescriptor
    let structuralDifferences: [String]
    let keys: TensorComparison
    let values: TensorComparison
    let normalMask: MaskComparison
    let materializedMask: MaskComparison
  }

  struct StateComparison: Codable, Sendable {
    let suffixLength: Int
    let maskWindows: [Int?]
    let layers: [LayerComparison]
    var structurallyEqual: Bool { layers.allSatisfy { $0.structuralDifferences.isEmpty
      && $0.keys.shapeEqual && $0.keys.dtypeEqual && $0.values.shapeEqual && $0.values.dtypeEqual } }
    var allKVBitsEqual: Bool { structurallyEqual && layers.allSatisfy {
      $0.keys.bitwiseEqual == true && $0.values.bitwiseEqual == true } }
    var allMasksEqual: Bool { layers.allSatisfy { $0.normalMask.bitwiseEqual && $0.materializedMask.bitwiseEqual } }
  }

  static func compareState(oracle: [any KVCache], hydrated: [any KVCache],
    suffixLength: Int, maskWindows: [Int?],
    compareValues: ((MLXArray, MLXArray) throws -> TensorComparison)? = nil) throws -> StateComparison {
    guard !oracle.isEmpty, oracle.count == hydrated.count, oracle.count == maskWindows.count,
      suffixLength > 0 else { throw Failure.invalid("Cache layers, mask windows or suffix length disagree.") }
    let layers = try oracle.indices.map { layer -> LayerComparison in
      let a = oracle[layer], b = hydrated[layer]
      let ad = CacheDescriptor(a), bd = CacheDescriptor(b)
      let av = a.state, bv = b.state
      guard av.count == 2, bv.count == 2 else { throw Failure.invalid("Missing native comparison state.") }
      var differences: [String] = []
      if ObjectIdentifier(type(of: a)) != ObjectIdentifier(type(of: b)) { differences.append("native_class") }
      if ad.offset != bd.offset { differences.append("offset") }
      if ad.scalarRoPEOffset == nil || ad.scalarRoPEOffset != bd.scalarRoPEOffset { differences.append("scalar_rope_offset") }
      if ad.maxSize != bd.maxSize { differences.append("max_size") }
      if ad.step != bd.step { differences.append("step") }
      if ad.metadata != bd.metadata { differences.append("metadata") }
      return LayerComparison(layer: layer, reference: ad, candidate: bd, structuralDifferences: differences,
        keys: try (compareValues ?? compareTensor)(av[0], bv[0]),
        values: try (compareValues ?? compareTensor)(av[1], bv[1]),
        normalMask: try compareMask(a, b, n: suffixLength, window: maskWindows[layer], returnArray: false),
        materializedMask: try compareMask(a, b, n: suffixLength, window: maskWindows[layer], returnArray: true))
    }
    return StateComparison(suffixLength: suffixLength, maskWindows: maskWindows, layers: layers)
  }

  struct SampleComparison: Codable, Sendable {
    let seed: UInt64
    let referenceTokenID: Int
    let candidateTokenID: Int
  }

  struct ForwardComparison: Codable, Sendable {
    let block: Int
    let inputTokenIDs: [Int]
    let startOffset: Int
    let endOffset: Int
    let stateBefore: StateComparison
    let logits: TensorComparison
    let perPositionLogits: [TensorComparison]
    let referenceArgmaxTokenIDs: [Int]
    let candidateArgmaxTokenIDs: [Int]
    let samples: [SampleComparison]
  }

  // The caller supplies *actual normal-manager hydration*, not oracle-derived
  // spans. Both branches consume exactly the same explicit token blocks.
  // `sample` may be nil for teacher-forced prefill blocks. For decode blocks it
  // uses separate normal processors/samplers and RNG state for each branch/seed.
  // If candidate sampling diverges, subsequent shared inputs are labelled
  // teacher-forced; they must never be presented as autonomous candidate output.
  static func forwardSameInputs(model: any LanguageModel, oracle: [any KVCache],
    hydrated: [any KVCache], tokenBlocks: [[Int]], maskWindows: [Int?], vocabularySize: Int,
    sample: ((MLXArray, MLXArray, Int) throws -> [SampleComparison])? = nil,
    didRecordBlock: ((ForwardComparison) throws -> Void)? = nil
  ) throws -> [ForwardComparison] {
    guard !tokenBlocks.isEmpty, tokenBlocks.allSatisfy({ !$0.isEmpty }), vocabularySize > 0,
      tokenBlocks.flatMap({ $0 }).allSatisfy({ $0 >= 0 && $0 < vocabularySize && $0 <= Int(Int32.max) })
    else { throw Failure.invalid("Invalid diagnostic suffix tokens or vocabulary.") }
    var receipt: [ForwardComparison] = []
    for (block, ids) in tokenBlocks.enumerated() {
      let before = try compareState(oracle: oracle, hydrated: hydrated,
        suffixLength: ids.count, maskWindows: maskWindows)
      guard before.structurallyEqual, before.allMasksEqual else {
        // Driver saves the independent state receipt before asking to forward.
        throw Failure.invalid("Unsafe structural/mask discrepancy; diagnostic forward refused.")
      }
      let begin = oracle[0].offset
      let input = LMInput.Text(tokens: MLXArray(ids.map(Int32.init)).expandedDimensions(axis: 0))
      let reference = model(input, cache: oracle, state: nil)
      let candidate = model(input, cache: hydrated, state: nil)
      guard reference.state == nil, candidate.state == nil,
        reference.logits.ndim == 3, candidate.logits.shape == reference.logits.shape,
        reference.logits.dim(0) == 1, reference.logits.dim(1) == ids.count,
        reference.logits.dim(2) == vocabularySize,
        oracle.allSatisfy({ $0.offset == begin + ids.count }),
        hydrated.allSatisfy({ $0.offset == begin + ids.count })
      else { throw Failure.invalid("Non-text state, logit shape or consumed extent is unsupported.") }
      eval([reference.logits, candidate.logits] + oracle.flatMap { $0.innerState() }
        + hydrated.flatMap { $0.innerState() })
      let logits = try compareTensor(reference.logits, candidate.logits)
      let positions = try ids.indices.map { position in
        try compareTensor(reference.logits[0..., position, 0...], candidate.logits[0..., position, 0...])
      }
      let samples = try sample?(reference.logits[0..., -1, 0...], candidate.logits[0..., -1, 0...], block) ?? []
      let result = ForwardComparison(block: block, inputTokenIDs: ids, startOffset: begin,
        endOffset: begin + ids.count, stateBefore: before, logits: logits, perPositionLogits: positions,
        referenceArgmaxTokenIDs: reference.logits.argMax(axis: -1).asArray(Int.self),
        candidateArgmaxTokenIDs: candidate.logits.argMax(axis: -1).asArray(Int.self), samples: samples)
      // Persist each completed block before the next one; a later failure must
      // not erase earlier reductions or differences from the owned receipt.
      try didRecordBlock?(result)
      receipt.append(result)
    }
    return receipt
  }
}
