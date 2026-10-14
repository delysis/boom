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
      let oracle = try native.oracle(prefix: 8)
      let restored = try NativePrefixParityProbe.compareState(oracle: oracle,
        hydrated: NeuralPrefixParitySmoke.nativeBases(reuse.cache), suffixLength: 2, maskWindows: [nil, 4])
      XCTAssertTrue(restored.allKVBitsEqual); XCTAssertTrue(restored.allMasksEqual)
      XCTAssertEqual(oracle[1].state[0].asArray(Float.self), [4, 5, 6, 7])
      XCTAssertEqual(restored.layers.map { $0.keys.differingElementCount }, [0, 0])
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
}
