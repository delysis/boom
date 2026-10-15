import BoomCore
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import Boom

final class NativePrefixParityProbeTests: XCTestCase {
  private func tensor(_ positions: Range<Int>, rows: [Int] = [0], values: Bool = false) -> MLXArray {
    let data = rows.flatMap { row in positions.map { position -> Float in
      let value = Float(row * 100 + position)
      return values ? -value - 1 : value
    } }
    return MLXArray(data, [rows.count, 1, positions.count, 1])
  }
  private func append(_ cache: any KVCache, _ positions: Range<Int>, rows: [Int] = [0]) {
    _ = cache.update(keys: tensor(positions, rows: rows), values: tensor(positions, rows: rows, values: true))
  }
  private func owner() -> PromptCacheOwner {
    PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
  }
  private func caches(_ store: PromptPrefixCache, ids: [Int], scope: PromptCacheOwner,
    create: () throws -> [any KVCache]) throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: scope, input: LMInput(tokens: MLXArray(ids.map(Int32.init))),
      promptTokenIDs: ids, prefill: PrefillParameters(stepSize: 4, chunking: .remainder), useActiveNative: true, makeCache: create)
  }

  func testOverfullPrefillInteriorCropUsesKnownNativeChronology() throws {
    try Device.withDefaultDevice(.cpu) {
      let full = KVCacheSimple(); full.step = 2
      let local = RotatingKVCache(maxSize: 4, step: 2)
      for range in [0..<4, 4..<7] { append(full, range); append(local, range) }
      let snapshot = try NativePrefixParityProbe.captureNative([full, local], evaluatedPrefix: 7, selectedRow: 0)
      let cropped = try snapshot.oracle(prefix: 5)
      XCTAssertEqual(cropped[0].state[0].asArray(Float.self), [0, 1, 2, 3, 4])
      XCTAssertEqual(cropped[1].state[0].asArray(Float.self), [1, 2, 3, 4])
      XCTAssertEqual(cropped[1].state[1].asArray(Float.self), [-2, -3, -4, -5])
      XCTAssertEqual(cropped.map(\.offset), [5, 5])
      XCTAssertEqual(cropped[1].metaState, ["0", "4", "2", "5", "4", "modelNative", "false"])
      // Advance the original ring only after capture. The independently copied
      // native source must keep the old actual values, not newly overwritten rows.
      for position in 7..<12 { append(local, position..<(position + 1)) }
      append(full, 7..<10)
      let unchanged = try snapshot.oracle(prefix: 5)
      XCTAssertEqual(unchanged[1].state[0].asArray(Float.self), [1, 2, 3, 4])
      XCTAssertEqual(unchanged[1].state[1].asArray(Float.self), [-2, -3, -4, -5])
      XCTAssertEqual(unchanged[0].state[0].view(dtype: .uint32).asArray(UInt32.self),
        [Float(0), 1, 2, 3, 4].map(\.bitPattern))
      XCTAssertEqual(unchanged[1].state[1].view(dtype: .uint32).asArray(UInt32.self),
        [Float(-2), -3, -4, -5].map(\.bitPattern))
    }
  }

  func testWrappedKeepChronologyAndTooOldPrefixRefusal() throws {
    try Device.withDefaultDevice(.cpu) {
      let native = RotatingKVCache(maxSize: 4, keep: 1, step: 2)
      append(native, 0..<4)
      for position in 4..<8 { append(native, position..<(position + 1)) }
      let source = try NativePrefixParityProbe.captureNative([native], evaluatedPrefix: 8, selectedRow: 0)
      let current = try source.oracle(prefix: 8)
      XCTAssertEqual(current[0].state[0].asArray(Float.self), [0, 5, 6, 7])
      XCTAssertEqual(current[0].state[1].asArray(Float.self), [-1, -6, -7, -8])
      XCTAssertThrowsError(try source.oracle(prefix: 7)) { error in
        guard case NativePrefixParityProbe.Failure.oracleUnavailable = error else {
          return XCTFail("A missing oldest native window row was silently reconstructed: \(error)")
        }
      }
    }
  }

  func testIndependentNativeBaselineMatchesActualNormalManagerHydration() async throws {
    try await Device.withDefaultDevice(.cpu) {
      let manager = PromptPrefixCache(byteLimit: 16_384), scope = owner(), ids = Array(10..<18)
      let full = KVCacheSimple(); full.step = 2
      let local = RotatingKVCache(maxSize: 4, step: 2)
      let session = try caches(manager, ids: ids, scope: scope) { [full, local] }
      for range in [0..<4, 4..<8] {
        session.cache.forEach { append($0, range) }
        asyncEval(session.cache.flatMap { $0.innerState() }); eval(session.cache)
        session.markCacheSubmitted(); session.observeReadySpill()
        await session.joinPendingSpill(cancelled: false)
      }
      session.prefill.progress?(8, 8)
      let native = try NativePrefixParityProbe.captureNative([full, local], evaluatedPrefix: 8, selectedRow: 0)
      XCTAssertTrue(manager.publish(session))
      let reuse = try caches(manager, ids: ids + [99], scope: scope) {
        XCTFail("Expected the actual manager's prefix hit.")
        return [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)]
      }
      XCTAssertEqual(reuse.cachedTokenCount, 8)
      let oracle = try native.originalBoundary()
      let actual = NeuralPrefixParitySmoke.nativeBases(reuse.cache)
      XCTAssertEqual(ObjectIdentifier(actual[0] as AnyObject), ObjectIdentifier(full))
      XCTAssertEqual(ObjectIdentifier(actual[1] as AnyObject), ObjectIdentifier(local))
      for layer in oracle.indices {
        let reference = NativePrefixParityProbe.CacheDescriptor(oracle[layer])
        let candidate = NativePrefixParityProbe.CacheDescriptor(actual[layer])
        let source = native.source[layer]
        XCTAssertEqual(reference.metadata, source.metadata)
        XCTAssertEqual(candidate.metadata, source.metadata)
        XCTAssertEqual(reference.raw.map(\.shape), [source.rawKeys.shape, source.rawValues.shape])
        XCTAssertEqual(candidate.raw.map(\.shape), reference.raw.map(\.shape))
        XCTAssertEqual(reference.raw.map(\.dtype), [source.rawKeys.dtype, source.rawValues.dtype])
        XCTAssertEqual(candidate.raw.map(\.dtype), reference.raw.map(\.dtype))
      }
      let restored = try NativePrefixParityProbe.compareState(oracle: oracle,
        hydrated: actual, suffixLength: 2, maskWindows: [nil, 4])
      let failureDetail = restored.allKVBitsEqual && restored.allMasksEqual ? ""
        : String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
      XCTAssertTrue(restored.allKVBitsEqual, failureDetail)
      XCTAssertTrue(restored.allMasksEqual, failureDetail)
      XCTAssertEqual(oracle[1].state[0].asArray(Float.self), [1, 2, 3, 4, 5, 6, 7])
      XCTAssertEqual(oracle[1].metaState, ["0", "4", "2", "8", "7", "modelNative", "false"])
      XCTAssertEqual(restored.layers.map { $0.keys.differingElementCount }, [0, 0])
      // Keep the distinct canonical contract and its original exact expectation.
      let canonical = try native.oracle(prefix: 8)
      XCTAssertEqual(canonical[1].state[0].asArray(Float.self), [4, 5, 6, 7])
      let differentLayout = try NativePrefixParityProbe.compareState(oracle: canonical,
        hydrated: actual, suffixLength: 2, maskWindows: [nil, 4])
      XCTAssertFalse(differentLayout.structurallyEqual)
      XCTAssertFalse(differentLayout.allKVBitsEqual)
      XCTAssertTrue(differentLayout.allMasksEqual)
      // Even an older overfull row that the next update will discard must be
      // caught by the strict original-boundary comparison, not normalized away.
      let corrupted = try native.originalBoundary()
      var raw = corrupted[1].innerState(); raw[0][0, 0, 0, 0] = MLXArray(Float(999))
      var target = corrupted[1]; target.state = raw
      let wrong = try NativePrefixParityProbe.compareState(oracle: oracle,
        hydrated: corrupted, suffixLength: 2, maskWindows: [nil, 4])
      XCTAssertTrue(wrong.structurallyEqual); XCTAssertFalse(wrong.allKVBitsEqual)
      XCTAssertEqual(wrong.layers[1].keys.differingElementCount, 1)
      XCTAssertEqual(wrong.layers[1].keys.firstDifferingAxis2Index, 0)
      XCTAssertEqual(wrong.layers[1].values.differingElementCount, 0)
      let stillActual = try NativePrefixParityProbe.compareState(oracle: oracle,
        hydrated: actual, suffixLength: 2, maskWindows: [nil, 4])
      XCTAssertTrue(stillActual.allKVBitsEqual); XCTAssertTrue(stillActual.allMasksEqual)
    }
  }

  func testOriginalBoundaryAndCanonicalCropHaveExactNextUpdatesForOneAndTwoTokenSuffixes() throws {
    try Device.withDefaultDevice(.cpu) {
      for keep in [0, 1] {
        for firstSuffix in [1, 2] {
          let full = KVCacheSimple(); full.step = 2
          let local = RotatingKVCache(maxSize: 4, keep: keep, step: 2)
          for range in [0..<4, 4..<8] { append(full, range); append(local, range) }
          let snapshot = try NativePrefixParityProbe.captureNative([full, local], evaluatedPrefix: 8, selectedRow: 0)
          let original = try snapshot.originalBoundary(), canonical = try snapshot.oracle(prefix: 8)
          XCTAssertEqual(original[1].innerState()[0].dim(2), 7)
          XCTAssertEqual(canonical[1].innerState()[0].dim(2), 4)
          var at = 8
          // Exercise both entry points, then repeated wrap/concat transitions.
          for count in [firstSuffix, 1, 2, firstSuffix] {
            for layer in original.indices {
              let window: Int? = layer == 0 ? nil : 4
              for materialized in [false, true] {
                let mask = try NativePrefixParityProbe.compareMask(original[layer], canonical[layer],
                  n: count, window: window, returnArray: materialized)
                XCTAssertTrue(mask.bitwiseEqual, "pre-update mask: keep=\(keep), suffix=\(count), layer=\(layer)")
              }
              let keys = tensor(at..<(at + count)), values = tensor(at..<(at + count), values: true)
              let a = original[layer].update(keys: keys, values: values)
              let b = canonical[layer].update(keys: keys, values: values)
              eval([a.0, a.1, b.0, b.1] + original[layer].innerState() + canonical[layer].innerState())
              XCTAssertTrue(try NativePrefixParityProbe.compareTensor(a.0, b.0).bitwiseEqual == true,
                "next-update keys: keep=\(keep), suffix=\(count), layer=\(layer)")
              XCTAssertTrue(try NativePrefixParityProbe.compareTensor(a.1, b.1).bitwiseEqual == true,
                "next-update values: keep=\(keep), suffix=\(count), layer=\(layer)")
            }
            at += count
            for next in [1, 2] {
              let same = try NativePrefixParityProbe.compareState(oracle: original, hydrated: canonical,
                suffixLength: next, maskWindows: [nil, 4])
              XCTAssertTrue(same.structurallyEqual); XCTAssertTrue(same.allKVBitsEqual); XCTAssertTrue(same.allMasksEqual)
              XCTAssertEqual(original.map(\.offset), [at, at])
            }
          }
        }
      }
    }
  }

  func testOriginalBoundaryPreservesUnusedPhysicalCapacityAndFrozenRawDescriptors() throws {
    try Device.withDefaultDevice(.cpu) {
      let full = KVCacheSimple(); full.step = 4
      let local = RotatingKVCache(maxSize: 4, step: 4)
      for position in 0..<3 { append(full, position..<(position + 1)); append(local, position..<(position + 1)) }
      let snapshot = try NativePrefixParityProbe.captureNative([full, local], evaluatedPrefix: 3, selectedRow: 0)
      let before = try snapshot.originalBoundary()
      XCTAssertEqual(before.map(\.offset), [3, 3])
      for layer in before.indices {
        XCTAssertEqual(before[layer].innerState().map { $0.dim(2) }, [4, 4])
        XCTAssertEqual(before[layer].state[0].asArray(Float.self), [0, 1, 2])
        XCTAssertEqual(before[layer].innerState()[0].asArray(Float.self), [0, 1, 2, 0])
        XCTAssertEqual(before[layer].innerState()[1].asArray(Float.self), [-1, -2, -3, 0])
      }
      append(full, 3..<4); append(local, 3..<4)
      eval(full.innerState() + local.innerState())
      let frozen = try snapshot.originalBoundary()
      for layer in before.indices {
        XCTAssertEqual(frozen[layer].innerState()[0].view(dtype: .uint32).asArray(UInt32.self),
          [Float(0), 1, 2, 0].map(\.bitPattern))
        XCTAssertEqual(frozen[layer].innerState()[1].view(dtype: .uint32).asArray(UInt32.self),
          [Float(-1), -2, -3, 0].map(\.bitPattern))
        XCTAssertEqual(frozen[layer].metaState, before[layer].metaState)
      }
      let exact = try NativePrefixParityProbe.compareState(oracle: before, hydrated: frozen,
        suffixLength: 2, maskWindows: [nil, 4])
      XCTAssertTrue(exact.allKVBitsEqual); XCTAssertTrue(exact.allMasksEqual)
      XCTAssertEqual(full.offset, 4); XCTAssertEqual(local.offset, 4)
    }
  }

  func testDistinctRowAndChangedKeyCellAreDetected() throws {
    try Device.withDefaultDevice(.cpu) {
      let native = KVCacheSimple(); native.step = 2
      append(native, 0..<6, rows: [0, 1, 2])
      let rowOne = try NativePrefixParityProbe.captureNative([native], evaluatedPrefix: 6, selectedRow: 1)
      let rowZero = try NativePrefixParityProbe.captureNative([native], evaluatedPrefix: 6, selectedRow: 0)
      let correct = try rowOne.oracle(prefix: 6), sibling = try rowZero.oracle(prefix: 6)
      XCTAssertEqual(correct[0].state[0].asArray(Float.self), [100, 101, 102, 103, 104, 105])
      let wrong = try NativePrefixParityProbe.compareState(oracle: correct, hydrated: sibling,
        suffixLength: 1, maskWindows: [nil])
      XCTAssertTrue(wrong.structurallyEqual); XCTAssertFalse(wrong.allKVBitsEqual)
      XCTAssertEqual(wrong.layers[0].keys.differingElementCount, 6)
      XCTAssertEqual(wrong.layers[0].keys.firstDifferingAxis2Index, 0)
      let changed = try rowOne.oracle(prefix: 6)
      var state = changed[0].state
      state[0][0, 0, 2, 0] = MLXArray(Float(999))
      var changedCache = changed[0]; changedCache.state = state
      let corrupted = try NativePrefixParityProbe.compareState(oracle: correct, hydrated: changed,
        suffixLength: 1, maskWindows: [nil])
      XCTAssertEqual(corrupted.layers[0].keys.differingElementCount, 1)
      XCTAssertEqual(corrupted.layers[0].keys.firstDifferingAxis2Index, 2)
      XCTAssertEqual(corrupted.layers[0].values.differingElementCount, 0)
      XCTAssertThrowsError(try NativePrefixParityProbe.captureNative([native], evaluatedPrefix: 6, selectedRow: 3))
    }
  }

  func testValidWrongOffsetWindowAndMaskAreDetected() throws {
    try Device.withDefaultDevice(.cpu) {
      let source = RotatingKVCache(maxSize: 4, step: 2); append(source, 0..<8)
      let saved = try NativePrefixParityProbe.captureNative([source], evaluatedPrefix: 8, selectedRow: 0)
      let oracle = try saved.oracle(prefix: 8)
      let wrongOffset = try saved.oracle(prefix: 8)
      var offsetMetadata = wrongOffset[0].metaState; offsetMetadata[3] = "9"
      var offsetCache = wrongOffset[0]
      offsetCache.metaState = offsetMetadata // Valid native metadata; deliberately wrong identity.
      let offset = try NativePrefixParityProbe.compareState(oracle: oracle, hydrated: wrongOffset,
        suffixLength: 2, maskWindows: [4])
      XCTAssertTrue(offset.layers[0].structuralDifferences.contains("offset"))
      XCTAssertTrue(offset.layers[0].structuralDifferences.contains("scalar_rope_offset"))
      let wrongWindow = RotatingKVCache(maxSize: 5, step: 2)
      wrongWindow.state = oracle[0].state.map { $0[.ellipsis] }
      wrongWindow.metaState = ["0", "5", "2", "8", "4", "modelNative", "false"]
      let window = try NativePrefixParityProbe.compareState(oracle: oracle, hydrated: [wrongWindow],
        suffixLength: 2, maskWindows: [4])
      XCTAssertTrue(window.layers[0].structuralDifferences.contains("max_size"))
      XCTAssertTrue(window.layers[0].structuralDifferences.contains("metadata"))
      XCTAssertFalse(window.allMasksEqual)
    }
  }

  func testCLIRequiresItsBoundedModeAndRejectsTrialMixing() throws {
    let valid = ["--mlx-smoke", "--neural-prefix-parity-smoke", "--pack", "/public/writing",
      "--consultation-pack", "/public/chat", "--parity-fixture", "/public/parity.json",
      "--evidence", "/public/new-evidence", "--seed", "42"]
    XCTAssertNoThrow(try MLXNativeSmoke.validateParityArguments(valid))
    XCTAssertThrowsError(try MLXNativeSmoke.validateParityArguments(valid + ["--prompt-cache-smoke"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateParityArguments(valid + ["--batch"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateParityArguments(valid + ["--pack", "/public/other"]))
    XCTAssertThrowsError(try MLXNativeSmoke.validateParityArguments(["--parity-fixture", "/public/parity.json"]))
    var wrongSeed = valid; wrongSeed[wrongSeed.count - 1] = "43"
    XCTAssertThrowsError(try MLXNativeSmoke.validateParityArguments(wrongSeed))
  }

  private func updateValueBoundary(_ caches: [any KVCache],
    trace: NeuralPrefixParitySmoke.Layer0ValueBoundary, positions: Range<Int>) throws {
    // An actual compact immutable projected operand, not a cache slice.
    let values = take(tensor(positions, values: true),
      MLXArray(Int32(0)..<Int32(positions.count)), axis: 2)
    _ = caches[0].update(keys: tensor(positions), values: values)
    eval(caches.flatMap { $0.innerState() })
    try trace.completedNativeForward(caches, fence: {})
  }

  func testLayer0ValueBoundaryMatchesUncroppedWrappedAndOverfullNativeThenSurvivesLaterWrites() throws {
    // This proof requires a physical Metal allocator backing. MLXReadyBuffer
    // intentionally refuses CPU storage because exposing its raw pointer may
    // perform a synchronous transfer and violate the ready-only contract.
    try Device.withDefaultDevice(.gpu) {
      typealias Boundary = NeuralPrefixParitySmoke.Layer0ValueBoundary
      let source = RotatingKVCache(maxSize: 512), sourceTrace = Boundary()
      let sourceCalls = try sourceTrace.observing([source])
      for start in stride(from: 0, to: 3584, by: 512) {
        try updateValueBoundary(sourceCalls, trace: sourceTrace, positions: start..<(start + 512))
      }
      try updateValueBoundary(sourceCalls, trace: sourceTrace, positions: 3584..<4095)
      for position in Boundary.target {
        try updateValueBoundary(sourceCalls, trace: sourceTrace, positions: position..<(position + 1))
      }
      let sourceSnapshot = try NativePrefixParityProbe.captureNative([source], evaluatedPrefix: 4112, selectedRow: 0)
      let capturedSource = try sourceTrace.freeze(at: sourceSnapshot, fence: {})
      XCTAssertEqual(capturedSource.proof.originalRawSlots, Array(0..<17))
      XCTAssertEqual(capturedSource.proof.inputs.count, 17)
      XCTAssertEqual(capturedSource.proof.incomingVsOriginalRaw.bitwiseEqual, true)

      let cold = RotatingKVCache(maxSize: 512), coldTrace = Boundary()
      let coldCalls = try coldTrace.observing([cold])
      for start in stride(from: 0, to: 4096, by: 512) {
        try updateValueBoundary(coldCalls, trace: coldTrace, positions: start..<(start + 512))
      }
      try updateValueBoundary(coldCalls, trace: coldTrace, positions: 4096..<4128)
      let coldSnapshot = try NativePrefixParityProbe.captureNative([cold], evaluatedPrefix: 4128, selectedRow: 0)
      let capturedCold = try coldTrace.freeze(at: coldSnapshot, fence: {})
      XCTAssertEqual(capturedCold.proof.originalRawSlots, Array(510..<527))
      XCTAssertEqual(capturedCold.proof.inputs.count, 2)
      XCTAssertEqual(capturedCold.proof.incomingVsOriginalRaw.bitwiseEqual, true)
      for proof in [capturedSource.proof, capturedCold.proof] {
        XCTAssertTrue(proof.inputs.allSatisfy { !$0.aliasesNativeAllocation && $0.incomingAllocationBytes > 0 })
        XCTAssertLessThanOrEqual(proof.peakRetainedValueBackingByteUpperBound, Boundary.byteLimit)
        XCTAssertGreaterThan(proof.frozenAllocationBytes, 0)
      }
      // Equality is a valid observation too: no diagnostic gate requires the
      // two incoming histories to differ or guesses a kernel's numerical result.
      XCTAssertEqual(try NativePrefixParityProbe.compareTensor(capturedSource.values, capturedCold.values).bitwiseEqual, true)
      for position in 4112..<4624 { append(source, position..<(position + 1)) }
      eval(source)
      withExtendedLifetime((capturedSource, capturedCold)) {
        XCTAssertEqual(capturedSource.values.asArray(Float.self), Boundary.target.map { -Float($0) - 1 })
        XCTAssertEqual(capturedCold.values.asArray(Float.self), Boundary.target.map { -Float($0) - 1 })
      }
    }
  }

  func testLayer0ValueBoundaryRefusesMissingIncomingCoverageAndDifferentOriginalRawValues() throws {
    try Device.withDefaultDevice(.gpu) {
      typealias Boundary = NeuralPrefixParitySmoke.Layer0ValueBoundary
      let incomplete = RotatingKVCache(maxSize: 512), incompleteTrace = Boundary()
      let incompleteCalls = try incompleteTrace.observing([incomplete])
      append(incomplete, 0..<4095)
      for position in 4095..<4111 {
        try updateValueBoundary(incompleteCalls, trace: incompleteTrace, positions: position..<(position + 1))
      }
      append(incomplete, 4111..<4112) // genuine native value, deliberately unobserved
      let completeNative = try NativePrefixParityProbe.captureNative([incomplete], evaluatedPrefix: 4112, selectedRow: 0)
      XCTAssertThrowsError(try incompleteTrace.freeze(at: completeNative, fence: {}),
        "A complete native cache cannot invent the missing pre-update observation.")

      let source = RotatingKVCache(maxSize: 512), trace = Boundary()
      let calls = try trace.observing([source])
      append(source, 0..<4095)
      for position in Boundary.target {
        try updateValueBoundary(calls, trace: trace, positions: position..<(position + 1))
      }
      let different = RotatingKVCache(maxSize: 512)
      append(different, 0..<4095)
      for position in Boundary.target {
        _ = different.update(keys: tensor(position..<(position + 1)), values: tensor(position..<(position + 1)))
      }
      let wrongRaw = try NativePrefixParityProbe.captureNative([different], evaluatedPrefix: 4112, selectedRow: 0)
      var proof: Boundary.Proof?
      XCTAssertThrowsError(try trace.freeze(at: wrongRaw, fence: {}, record: { proof = $0 }))
      XCTAssertEqual(try XCTUnwrap(proof).incomingVsOriginalRaw.bitwiseEqual, false,
        "Exact metadata and shapes do not excuse different original native V bits.")
    }
  }

  // Supplied DTO admission only; these checks do not execute a model or qualify numerical parity.
  private func parityDeclaration(processed: Int = 8, delivered: Int = 9, row: Int = 2,
    stage: NeuralPrefixParitySmoke.SourceStage = .anchorPrefill) -> NeuralPrefixParitySmoke.Declaration {
    let reference = NeuralPrefixParitySmoke.Reference(path: "/public/receipt.json", sha256: String(repeating: "a", count: 64))
    var declaration = NeuralPrefixParitySmoke.Declaration(kind: .writingLateDivergence, namespace: UUID(), sharedSource: reference,
      anchorSource: reference, currentQuery: reference, modelManifest: reference, sourceStage: stage,
      sharedSourceRow: row, sharedProcessedDecodeTokens: processed, sharedDeliveredLedgerTokens: delivered,
      sharedWidth: 3, anchorCachedPrefix: 4096 + processed,
      sourceNativeBoundary: stage == .sharedDecode ? 4349 : 4352, cachedPrefix: 4349,
      coldNativeBoundary: 4352, warmSuffixPartitions: [3, 1], decodeControlTokens: 16, seed: 42)
    declaration.interveningSources = [reference, reference]
    return declaration
  }

  private func parityInputs(processed: Int = 8, corruptMatrix: Bool = false) throws
    -> (NeuralPrefixParitySmoke.CapturedInput, NeuralPrefixParitySmoke.CapturedInput,
      NeuralPrefixParitySmoke.CapturedInput) {
    let ids = Array(1...4096), lengths = processed == 8 ? [43, 256, 256] : [256, 256, 256]
    let emitted = lengths.enumerated().map { row, count in Array((5_000 + row * 1_000)..<(5_000 + row * 1_000 + count)) }
    let policy = ModelGenerationPolicy(schema: 1, vocabularySize: 32_768, eosTokenIDs: [0],
      suppressedTokenIDs: [], controlTokenIDs: [0], textDecoding: nil,
      prefill: .init(chunking: "fixed_v1", tokenCeiling: 512))
    let settings = SamplingSettings(temperature: 1, topP: 0.95, topK: 40, minP: 0)
    let ranges = stride(from: 0, to: 3584, by: 512).map { $0..<($0 + 512) } + [3584..<4095, 4095..<4096]
    let prefill: [NeuralPrefixParitySmoke.CapturedForward] = ranges.map {
      .init(start: $0.lowerBound, end: $0.upperBound, evaluatedEnd: $0.upperBound,
        origin: "prefill", width: 1, row: nil, originalInput: nil)
    }
    let preparedDigest = try XCTUnwrap(ForwardOperandBinding.tokenDigest([ids]))
    let members = (0..<3).map { row in
      ForwardOperandBinding.Member(logicalRequests: [String(repeating: "a", count: 63) + String(row)],
        preparedTokenDigest: preparedDigest, preparedTokenCount: ids.count,
        cachedTokenCount: 4095, cachedTokenDigest: String(repeating: "b", count: 64),
        cachedSourceDigest: String(repeating: "c", count: 64), cachePaddingDigest: String(repeating: "d", count: 64))
    }
    let decode: [NeuralPrefixParitySmoke.CapturedForward] = try (0..<processed).map { position in
      var matrix = emitted.map { [$0[position]] }
      if corruptMatrix && position == 0 { matrix[0][0] += 1 }
      let candidate = try XCTUnwrap(ForwardOperandBinding.candidate(phase: .decode,
        modelBinding: String(repeating: "e", count: 64), members: members, inputRangeStart: 0,
        tokenRows: matrix, logicalStarts: Array(repeating: 4096 + position, count: 3),
        validLengths: [1, 1, 1], generationActive: [true, true, true]))
      let witness = try XCTUnwrap(candidate.committed(allOwningLayersComplete: true, actuallySubmitted: true))
      return .init(start: 4096 + position, end: 4097 + position, evaluatedEnd: 4097 + position,
        origin: "batchDecode", width: 3, row: 2, originalInput: witness)
    }
    var anchorIDs = ids + Array(emitted[2].prefix(processed))
    anchorIDs += Array(repeating: 12_000, count: 4353 - anchorIDs.count)
    var queryIDs = anchorIDs; queryIDs[4349] = 12_001
    func input(_ name: String, _ prompt: [Int], _ rows: [[Int]], cached: Int,
      forwards: [NeuralPrefixParitySmoke.CapturedForward]) throws -> NeuralPrefixParitySmoke.CapturedInput {
      let digest = Digest.sha256(try JSONEncoder().encode(prompt))
      return .init(name: name, model: "public-checkpoint@revision", prompt: "public", plan: nil,
        prepared_token_ids: prompt, generation_policy: policy, settings: settings,
        outputs: rows.map { .init(token_ids: $0, stop_reason: "output_limit", stop_token_id: nil,
          prompt_digest: digest, prompt_tokens: prompt.count) }, status: "passed",
        expected_cached_tokens_at_snapshot: cached, seeds: rows.indices.map { UInt64(42 + $0) },
        output_history_evidence: rows.indices.map { .init(promptTokens: prompt.count,
          decodeRow: $0, decodeWidth: rows.count, blockers: [], forwards: forwards) })
    }
    var source = try input("writing-three-repeat", ids, emitted, cached: 4095, forwards: prefill)
    source.max_tokens_per_row = 256
    source.batch_metrics = .init(width: 3, sharedPromptPrefills: 1, decodeForwardPasses: 255)
    if lengths[0] < 256 {
      let value = source.outputs[0]
      source = .init(name: source.name, model: source.model, prompt: source.prompt, plan: source.plan,
        prepared_token_ids: source.prepared_token_ids, generation_policy: source.generation_policy,
        settings: source.settings, outputs: [.init(token_ids: value.token_ids, stop_reason: "eos", stop_token_id: 0,
          prompt_digest: value.prompt_digest, prompt_tokens: value.prompt_tokens)] + Array(source.outputs.dropFirst()),
        status: source.status, expected_cached_tokens_at_snapshot: source.expected_cached_tokens_at_snapshot,
        seeds: source.seeds, output_history_evidence: source.output_history_evidence,
        max_tokens_per_row: 256, batch_metrics: .init(width: 3, sharedPromptPrefills: 1, decodeForwardPasses: 255))
    }
    let tail: [NeuralPrefixParitySmoke.CapturedForward] = [
      .init(start: 4096 + processed, end: 4352, evaluatedEnd: 4352, origin: "prefill", width: 1, row: nil, originalInput: nil),
      .init(start: 4352, end: 4353, evaluatedEnd: 4353, origin: "prefill", width: 1, row: nil, originalInput: nil)]
    let anchor = try input("writing-late-anchor", anchorIDs, [Array(20_000..<20_016)],
      cached: 4096 + processed, forwards: prefill + decode + tail)
    let queryProcessed = min(processed, 253)
    let queryTail: [NeuralPrefixParitySmoke.CapturedForward] = [
      .init(start: 4096 + queryProcessed, end: 4352, evaluatedEnd: 4352, origin: "prefill", width: 1, row: nil, originalInput: nil),
      .init(start: 4352, end: 4353, evaluatedEnd: 4353, origin: "prefill", width: 1, row: nil, originalInput: nil)]
    let query = try input("writing-late-divergence", queryIDs, [Array(21_000..<21_016)],
      cached: 4349, forwards: prefill + Array(decode.prefix(queryProcessed)) + queryTail)
    return (source, anchor, query)
  }

  private func parityIntervening(_ source: NeuralPrefixParitySmoke.CapturedInput) throws
    -> [NeuralPrefixParitySmoke.CapturedInput] {
    var forwards = try XCTUnwrap(source.output_history_evidence?.first?.forwards)
    var prompt = source.prepared_token_ids, result: [NeuralPrefixParitySmoke.CapturedInput] = []
    for count in 4097...4098 {
      prompt.append(12_000)
      forwards.append(.init(start: count - 1, end: count, evaluatedEnd: count,
        origin: "prefill", width: 1, row: nil, originalInput: nil))
      let digest = Digest.sha256(try JSONEncoder().encode(prompt))
      result.append(.init(name: "writing-append-\(count)", model: source.model, prompt: "public", plan: nil,
        prepared_token_ids: prompt, generation_policy: source.generation_policy, settings: source.settings,
        outputs: [.init(token_ids: Array(20_000..<20_016), stop_reason: "output_limit", stop_token_id: nil,
          prompt_digest: digest, prompt_tokens: count)], status: "passed", expected_cached_tokens_at_snapshot: count - 1,
        seeds: [42], output_history_evidence: [.init(promptTokens: count, decodeRow: 0, decodeWidth: 1,
          blockers: [], forwards: forwards)], max_tokens_per_row: 16))
    }
    return result
  }

  func testCurrentParityAdmissionUsesActualShortRowsAndCompletedOriginalMatrix() throws {
    let (source, anchor, query) = try parityInputs()
    let declaration = parityDeclaration()
    XCTAssertNoThrow(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
      shared: source, anchor: anchor, query: query, intervening: parityIntervening(source)))
    XCTAssertEqual(source.outputs.map { $0.token_ids.count }, [43, 256, 256])
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateRequest(parityDeclaration(processed: 85, delivered: 86),
      schema: 2, shared: source, anchor: anchor, query: query, intervening: parityIntervening(source)))
    let (sameIDs, wrongMatrix, sameQuery) = try parityInputs(corruptMatrix: true)
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
      shared: sameIDs, anchor: wrongMatrix, query: sameQuery, intervening: parityIntervening(sameIDs)))
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateRequest(parityDeclaration(row: 1), schema: 2,
      shared: source, anchor: anchor, query: query, intervening: parityIntervening(source)))
  }

  func testCurrentParityAdmissionUsesRecordedEarlierRowBeforeNativeRingLosesOldestPositions() throws {
    let (source, anchor, query) = try parityInputs(processed: 255)
    let declaration = parityDeclaration(processed: 255, delivered: 256, stage: .sharedDecode)
    XCTAssertNoThrow(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
      shared: source, anchor: anchor, query: query, intervening: parityIntervening(source)))
    XCTAssertEqual(declaration.sourceNativeBoundary, 4349)
    XCTAssertEqual(declaration.sharedSourceRow, 2)
    XCTAssertEqual(query.output_history_evidence?.first?.forwards.last?.end, 4353)
  }

  func testCurrentWritingReplayRetainsEarlyEOSPhysicalInputsAndFullSharedBoundary() throws {
    let (source, _, _) = try parityInputs()
    let replay = try NeuralPrefixParitySmoke.receiptBatchReplay(source)
    XCTAssertEqual(replay.processed, 255)
    XCTAssertEqual(replay.ledgers.map(\.count), [43, 256, 256])
    XCTAssertEqual(replay.terminalIterations, [43, 255, 255])
    XCTAssertEqual(try replay.column(at: 42)[0], source.outputs[0].token_ids[42])
    XCTAssertEqual(try replay.column(at: 43)[0], source.outputs[0].stop_token_id)
    XCTAssertEqual(try replay.column(at: 44)[0], source.generation_policy.eosTokenIDs[0])
    XCTAssertEqual(try replay.column(at: 254)[1], source.outputs[1].token_ids[254])
    XCTAssertEqual(replay.ledgers[1].last, source.outputs[1].token_ids[255],
      "The final delivered token is retained but is not an invented 256th batch forward.")
    XCTAssertThrowsError(try replay.column(at: -1)); XCTAssertThrowsError(try replay.column(at: 255))
    let (long, _, _) = try parityInputs(processed: 255)
    let longReplay = try NeuralPrefixParitySmoke.receiptBatchReplay(long)
    XCTAssertEqual(longReplay.terminalIterations, [255, 255, 255])
    XCTAssertEqual(try longReplay.column(at: 252), long.outputs.map { $0.token_ids[252] },
      "The earlier E2 snapshot4349 is captured after253actual forwards; two more remain before joined4351.")
    XCTAssertEqual(4096 + longReplay.processed, 4351)
  }

  func testCurrentWritingReplayRequiresOriginalOrderedAppendHistoryAndBoundedTerminalMetadata() throws {
    let (source, anchor, query) = try parityInputs(), declaration = parityDeclaration()
    let steps = try parityIntervening(source)
    XCTAssertNoThrow(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
      shared: source, anchor: anchor, query: query, intervening: steps))
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
      shared: source, anchor: anchor, query: query))
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
      shared: source, anchor: anchor, query: query, intervening: Array(steps.reversed())))
    for extreme in [Int.min, Int.max] {
      var changed = source
      changed.batch_metrics = .init(width: 3, sharedPromptPrefills: 1, decodeForwardPasses: extreme)
      XCTAssertThrowsError(try NeuralPrefixParitySmoke.receiptBatchReplay(changed))
      var changedSteps = steps; changedSteps[1].max_tokens_per_row = extreme
      XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateRequest(declaration, schema: 2,
        shared: source, anchor: anchor, query: query, intervening: changedSteps))
    }
  }

  func testParityVersionTwoRejectsExtremeCountersBeforeArithmeticAndPreservesVersionOneScope() throws {
    let good = parityDeclaration()
    let encoded = try JSONEncoder().encode(good)
    for key in ["sharedProcessedDecodeTokens", "sharedDeliveredLedgerTokens", "anchorCachedPrefix",
      "sourceNativeBoundary", "cachedPrefix", "coldNativeBoundary", "sharedSourceRow", "sharedWidth"] {
      for extreme in [Int.min, Int.max] {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = extreme
        let changed = try JSONDecoder().decode(NeuralPrefixParitySmoke.Declaration.self,
          from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateDeclaration(changed, schema: 2), key)
      }
    }
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["warmSuffixPartitions"] = [Int.max, Int.max]
    let changed = try JSONDecoder().decode(NeuralPrefixParitySmoke.Declaration.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateDeclaration(changed, schema: 2))
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateDeclaration(good, schema: 1))
    object["modelManifest"] = NSNull(); object["sourceStage"] = NSNull(); object["sharedSourceRow"] = NSNull()
    object["interveningSources"] = NSNull()
    object["sharedProcessedDecodeTokens"] = 85; object["sharedDeliveredLedgerTokens"] = 86
    object["anchorCachedPrefix"] = 4181; object["warmSuffixPartitions"] = [3, 1]
    let legacy = try JSONDecoder().decode(NeuralPrefixParitySmoke.Declaration.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNoThrow(try NeuralPrefixParitySmoke.validateDeclaration(legacy, schema: 1))
    object["anchorCachedPrefix"] = 4104
    let changedLegacy = try JSONDecoder().decode(NeuralPrefixParitySmoke.Declaration.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertThrowsError(try NeuralPrefixParitySmoke.validateDeclaration(changedLegacy, schema: 1))
  }
}
