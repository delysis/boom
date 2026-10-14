import BoomCore
import Darwin
import Dispatch
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest
@testable import Boom

/// Tiny real CPU/cache/file controls. No model/GPU throughput or total-process
/// memory qualification is implied. Mutable MLX work stays on its existing owner.
final class PrefixKVDiskTests: XCTestCase {
  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [PrefixKVSpan]?
    func set(_ value: [PrefixKVSpan]?) { lock.lock(); result = value; lock.unlock() }
    func take() -> [PrefixKVSpan]? {
      lock.lock(); defer { lock.unlock() }; let value = result; result = nil; return value
    }
  }
  private final class FinalizerCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
  }
  private static func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-KV-Control-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  private static func files(_ root: URL) throws -> [URL] {
    let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    return try directories.flatMap { directory in
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }.filter { $0.pathExtension == "kv" }
  }
  private static func bits(_ type: DType, count: Int) -> Data {
    if type == .float32 {
      let patterns: [UInt32] = [0x8000_0000, 0x0000_0001, 0x7fc0_1234, 0x3f80_0000]
      return (0..<count).map { patterns[$0 % patterns.count] }.withUnsafeBytes { Data($0) }
    }
    let patterns: [UInt16] = type == .float16 ? [0x8000, 0x0001, 0x7e55, 0x3c00]
      : [0x8000, 0x0001, 0x7fc3, 0x3f80]
    return (0..<count).map { patterns[$0 % patterns.count] }.withUnsafeBytes { Data($0) }
  }

  func testReadyLeaseRefusesUnscheduledGraphAndPinsFunctionalSliceUpdate() async throws {
    try await InferenceExecutor.shared.perform { _ in
      try Device.withDefaultDevice(.cpu) {
        let original = Self.bits(.float32, count: 4)
        let array = MLXArray(original, [1, 1, 4, 1], dtype: .float32)
        let future = array + 1
        XCTAssertNil(future.readyBuffer(), "Readiness must not evaluate/mark this unscheduled graph available.")
        let lease = try XCTUnwrap(array.readyBuffer())
        XCTAssertGreaterThanOrEqual(lease.allocationBytes, original.count)
        array[0..., 0..., 1..<2, 0...] = MLXArray([42.0], [1, 1, 1, 1])
        eval(array) // actual functional SliceUpdate on CPU, not a mocked writer
        XCTAssertEqual(array.asArray(Float.self)[1], 42)
        let retained = lease.withUnsafeBytes { Data($0[lease.byteOffset..<(lease.byteOffset + original.count)]) }
        XCTAssertEqual(retained, original, "Donation must not overwrite the retained original raw bits.")
      }
    }
  }

  func testReadyLeaseRefusesActualExternallyManagedBuffer() async throws {
    try await InferenceExecutor.shared.perform { _ in
      let length = Int(getpagesize()), finalizer = FinalizerCount()
      let pointer = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
      guard let pointer, pointer != MAP_FAILED else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      defer { if finalizer.value == 0 { _ = munmap(pointer, length) } }
      var array: MLXArray? = MLXArray(rawPointer: pointer, [1, 1, length / 4, 1], dtype: .float32) {
        _ = munmap(pointer, length); finalizer.increment()
      }
      XCTAssertEqual(finalizer.value, 0, "Require actual managed shared storage, not an already-copied array.")
      XCTAssertNil(try XCTUnwrap(array).readyBuffer(), "A custom finalizer cannot become a Sendable owned raw pin.")
      array = nil
      XCTAssertEqual(finalizer.value, 1, "The original array alone owns and releases its managed memory.")
    }
  }

  func testRawFloatBitsRowsAndPhysicalStridesRoundTripWithoutNumericCast() async throws {
    try await InferenceExecutor.shared.perform { _ in
      let root = try Self.root()
      let disk = PrefixKVDiskStore(byteLimit: 4096, temporaryParent: root)
      for type in [DType.float16, .bfloat16, .float32] {
        let original = Self.bits(type, count: 12), box = ResultBox()
        let source = MLXArray(original, [2, 1, 3, 2], dtype: type)
        let view = Device.withDefaultDevice(.cpu) { source.transposed(0, 1, 3, 2) }
        // Evaluate then perform the existing completed-array wait. The new
        // ready-only method itself never initiates either operation.
        Device.withDefaultDevice(.cpu) { eval(view); view.eval() }
        let lease = try XCTUnwrap(view.readyBuffer())
        XCTAssertEqual(lease.shape, [2, 1, 2, 3])
        XCTAssertGreaterThanOrEqual(lease.allocationBytes, original.count)
        let ready = try PrefixKVDiskStore.ReadySpan(start: 0, layer: 0, keys: lease, values: lease,
          positions: 0..<2)
        XCTAssertTrue(disk.submit([ready], isLive: { true }, completed: { box.set($0) }))
        await disk.joinPending()
        let spans = try XCTUnwrap(box.take())
        let physicalPath = try XCTUnwrap(disk.observation.directoryPath)
        let physicalParent = try XCTUnwrap(Darwin.realpath(root.path, nil))
        let parentPath = String(cString: physicalParent); free(physicalParent)
        XCTAssertTrue(physicalPath.hasPrefix(parentPath + "/"))
        let restored = try Device.withDefaultDevice(.cpu) {
          try PrefixKVStorage.hydrate(layout: .rotating(window: 2, keep: 0, step: 1, capacityOrigin: "modelNative"),
            spans: spans, prefix: 2, row: 1, batchWidth: 2)
        }
        let expected = Device.withDefaultDevice(.cpu) { view[1..<2, 0..., 0..<2, 0...].asData().data }
        XCTAssertEqual(restored.state[0].asData().data, expected)
        XCTAssertEqual(restored.state[1].asData().data, expected)
        XCTAssertEqual(spans[0].backingBytesUpperBound, 0, "Disk bytes cannot masquerade as resident KV.")
      }
      await disk.joinPending()
      XCTAssertEqual(disk.observation.bytes, 0, "Last span release must join actual background unlink.")
      XCTAssertTrue(try Self.files(root).isEmpty)
    }
  }

  func testOneInFlightCancellationQuotaAndGCUseActualWorker() async throws {
    let entered = expectation(description: "actual spill worker entered")
    let finished = expectation(description: "last actual C ready pin released before aggregate byte charge")
    let gate = DispatchSemaphore(value: 0), cancellation = CancellationFlag()
    let root = try Self.root(), disk = PrefixKVDiskStore(byteLimit: 128, temporaryParent: root), box = ResultBox()
    let value = MLXArray(Self.bits(.float32, count: 8), [1, 1, 4, 2], dtype: .float32)
    let other = MLXArray(Self.bits(.float32, count: 8), [1, 1, 4, 2], dtype: .float32)
    func readyPair() throws -> (MLXReadyBuffer, MLXReadyBuffer) {
      let aggregate = PrefixKVDependencyLease { finished.fulfill() }
      let admit: (Int) -> (@Sendable () -> Void)? = { _ in
        { withExtendedLifetime(aggregate) {} }
      }
      return (try XCTUnwrap(value.readyBuffer(admitting: admit)),
        try XCTUnwrap(other.readyBuffer(admitting: admit)))
    }
    var leases: (MLXReadyBuffer, MLXReadyBuffer)? = try readyPair()
    var span: PrefixKVDiskStore.ReadySpan? = try .init(start: 0, layer: 0,
      keys: XCTUnwrap(leases).0, values: XCTUnwrap(leases).1, positions: 0..<4)
    XCTAssertTrue(disk.submit([try XCTUnwrap(span)], isLive: {
      entered.fulfill()
      guard gate.wait(timeout: .now() + 5) == .success else { return false }
      return !cancellation.isCancelled
    }, completed: { box.set($0) }))
    await fulfillment(of: [entered], timeout: 5)
    XCTAssertFalse(disk.submit([try XCTUnwrap(span)], isLive: { true }, completed: { box.set($0) }))
    let tooSmall = PrefixKVDiskStore(byteLimit: 1, temporaryParent: root)
    XCTAssertFalse(tooSmall.submit([try XCTUnwrap(span)], isLive: { true }, completed: { box.set($0) }))
    span = nil; leases = nil; cancellation.cancel(); gate.signal()
    await disk.joinPending()
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertNil(box.take()); XCTAssertFalse(disk.observation.inFlight)
    XCTAssertEqual(disk.observation.bytes, 0)
    XCTAssertTrue(try Self.files(root).isEmpty)
  }

  func testWarmFourDiskRowsWrappedChronologyAndLostFileColdReadmission() async throws {
    try await InferenceExecutor.shared.perform { _ in
      let ids = Array(0..<6), first = [901, 911, 921, 931], second = [902, 912, 922, 932]
      let last = [903, 913, 923, 933]
      // Four real warm restores, all-file loss, then surviving-prefix fallback.
      for target in 0..<6 {
        let root = try Self.root(), store = PromptPrefixCache(byteLimit: 65_536, temporaryParent: root)
        let owner = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
        func session(_ query: [Int], width: Int) throws -> PromptPrefixCache.Session {
          try Device.withDefaultDevice(.cpu) {
            try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(query, [1, query.count])),
              promptTokenIDs: query, prefill: .init(stepSize: 6, chunking: .remainder),
              useActiveNative: true, outputTokens: 2, batchWidth: width,
              makeCache: { [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)] })
          }
        }
        func settle(_ value: PromptPrefixCache.Session) {
          Device.withDefaultDevice(.cpu) {
            eval(value.cache)
            // Explicit completed-array waits on this CPU producer, mirroring
            // the runner's eval(logits); eval(cache) joined completion boundary.
            for array in value.cache.flatMap({ $0.innerState() }) { array.eval() }
            value.markCacheSubmitted()
          }
        }
        let source = try session(ids, width: 4)
        Device.withDefaultDevice(.cpu) {
          let keys = MLXArray(ids.map(Float.init), [1, 1, 6, 1])
          for cache in source.cache { _ = cache.update(keys: keys, values: keys + 100) }
        }
        settle(source); source.prefill.progress?(6, 6)
        await source.joinPendingSpill(cancelled: false)
        let initialFiles = Set(try Self.files(root))
        Device.withDefaultDevice(.cpu) {
          for var cache in source.cache {
            let state = cache.innerState(), offset = cache.offset, metadata = cache.metaState
            cache.state = state.map { broadcast($0, to: [4] + Array($0.shape.dropFirst())) }
            if case .simple = PrefixKVStorage.layout(of: cache) { _ = cache.trim(cache.offset - offset) }
            else { cache.metaState = metadata }
          }
        }
        settle(source)
        for row in 0..<4 {
          XCTAssertTrue(source.captureDecodeLane(row: row, width: 4, emittedTokenIDs: [first[row]], finished: false))
        }
        Device.withDefaultDevice(.cpu) {
          let keys = MLXArray(first.map(Float.init), [4, 1, 1, 1])
          for cache in source.cache { _ = cache.update(keys: keys, values: keys + 100) }
        }
        settle(source)
        XCTAssertEqual(source.cache[1].metaState[6], "true", "This must exercise a physically wrapped ring.")
        await source.joinPendingSpill(cancelled: false)
        for row in 0..<4 {
          XCTAssertTrue(source.captureDecodeLane(row: row, width: 4,
            emittedTokenIDs: [first[row], second[row]], finished: false))
        }
        Device.withDefaultDevice(.cpu) {
          let keys = MLXArray(second.map(Float.init), [4, 1, 1, 1])
          for cache in source.cache { _ = cache.update(keys: keys, values: keys + 100) }
        }
        settle(source); await source.joinPendingSpill(cancelled: false)
        for row in 0..<4 {
          XCTAssertTrue(source.captureFinishedLane(row: row, width: 4,
            emittedTokenIDs: [first[row], second[row], last[row]]))
        }
        XCTAssertTrue(store.publish(source, completions: (0..<4).map {
          .init(row: $0, emittedTokenIDs: [first[$0], second[$0], last[$0]])
        }))
        XCTAssertEqual(store.retainedBytesUpperBound, 0, "No immutable rotating RAM archive survives the join.")
        // This query diverges one token BEFORE current-hot. It must use the
        // previous actual disk window, not silently borrow today's ring.
        let row = min(target, 3), query = ids + [first[row], 999]
        let plan = try XCTUnwrap(store.nativeAdmissionPlan(owner: owner, tokens: query,
          prefill: .init(stepSize: 6, chunking: .remainder), outputTokens: 2, batchWidth: 4))
        XCTAssertEqual(plan.cachedTokenCount, 7); XCTAssertEqual(plan.sourceWidth, 4)
        XCTAssertEqual(plan.sourceRow, row)
        if target == 4 || target == 5 {
          let files = try Self.files(root)
          let failedFiles = target == 4 ? files : files.filter { !initialFiles.contains($0) }
          XCTAssertFalse(failedFiles.isEmpty)
          for file in failedFiles { try FileManager.default.removeItem(at: file) }
        }
        let restored = try session(query, width: 4)
        if target == 4 {
          XCTAssertEqual(restored.cachedTokenCount, 0)
          XCTAssertEqual(restored.observation.missReason, "disk_span_unavailable")
          XCTAssertEqual(source.cache[0].offset, 8, "A failed local read must not trim/consume the old global parent.")
        } else if target == 5 {
          XCTAssertEqual(restored.cachedTokenCount, 6, "Use the maximal surviving prefix, not an unnecessary cold miss.")
          XCTAssertGreaterThan(restored.observation.unavailableDiskBackings, 0)
          let contents = Device.withDefaultDevice(.cpu) { restored.cache[1].state.map { $0.asArray(Float.self) } }
          XCTAssertEqual(contents[0], [2, 3, 4, 5]); XCTAssertEqual(contents[1], [102, 103, 104, 105])
        } else {
          XCTAssertEqual(restored.cachedTokenCount, 7)
          XCTAssertEqual(restored.observation.cachedRow, row)
          let contents = Device.withDefaultDevice(.cpu) { restored.cache[1].state.map { $0.asArray(Float.self) } }
          XCTAssertEqual(contents[0], [3, 4, 5, Float(first[row])])
          XCTAssertEqual(contents[1], [103, 104, 105, Float(first[row] + 100)])
        }
        restored.discardStagedAnchors(); store.clear()
        await restored.joinPendingSpill(cancelled: true)
      }
    }
  }

  func testAllSpillsRefusedKeepsActualHotPrefixButInventsNoHistoricalCoverage() async throws {
    try await InferenceExecutor.shared.perform { _ in
      let root = try Self.root(), store = PromptPrefixCache(byteLimit: 1, temporaryParent: root)
      let ids = Array(0..<6), owner = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
      func session(_ query: [Int]) throws -> PromptPrefixCache.Session {
        try Device.withDefaultDevice(.cpu) {
          try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(query, [1, query.count])),
            promptTokenIDs: query, prefill: .init(stepSize: 6, chunking: .remainder),
            useActiveNative: true, outputTokens: 2,
            makeCache: { [KVCacheSimple(), RotatingKVCache(maxSize: 4, step: 2)] })
        }
      }
      func prefill(_ value: PromptPrefixCache.Session) async {
        Device.withDefaultDevice(.cpu) {
          let suffix = value.input.text.tokens.asArray(Int.self)
          let keys = MLXArray(suffix.map(Float.init), [1, 1, suffix.count, 1])
          for cache in value.cache { _ = cache.update(keys: keys, values: keys + 100) }
          eval(value.cache)
          for array in value.cache.flatMap({ $0.innerState() }) { array.eval() }
          value.markCacheSubmitted(); value.prefill.progress?(suffix.count, suffix.count)
        }
        await value.joinPendingSpill(cancelled: false)
      }
      let first = try session(ids); await prefill(first)
      let ring = ObjectIdentifier(PrefixKVStorage.unwrap(first.cache[1]) as AnyObject)
      XCTAssertTrue(store.publish(first))
      let warm = try session(ids + [99])
      XCTAssertEqual(warm.cachedTokenCount, 6)
      XCTAssertTrue(warm.observation.cachedCurrentHotPrefix)
      XCTAssertEqual(ObjectIdentifier(PrefixKVStorage.unwrap(warm.cache[1]) as AnyObject), ring)
      XCTAssertEqual(warm.cache[1].state[0].asArray(Float.self), ids.map(Float.init))
      await prefill(warm); XCTAssertTrue(store.publish(warm))
      let old = try session(ids + [88])
      XCTAssertEqual(old.cachedTokenCount, 0, "Neither missing disk history nor overwritten native positions can grant reuse.")
      XCTAssertEqual(old.observation.missReason, "no_active_supported_prefix")
      XCTAssertEqual(store.retainedBytesUpperBound, 0)
      XCTAssertTrue(try Self.files(root).isEmpty)
      old.discardStagedAnchors(); store.clear(); await old.joinPendingSpill(cancelled: true)
    }
  }

  func testMissingDiskSpanRefusesHydrationWithoutReturningPartialRows() async throws {
    try await InferenceExecutor.shared.perform { _ in
      let root = try Self.root(), disk = PrefixKVDiskStore(byteLimit: 4096, temporaryParent: root), box = ResultBox()
      let array = MLXArray(Self.bits(.float32, count: 8), [2, 1, 4, 1], dtype: .float32)
      let lease = try XCTUnwrap(array.readyBuffer())
      let span = try PrefixKVDiskStore.ReadySpan(start: 0, layer: 0, keys: lease, values: lease,
        positions: 0..<4)
      XCTAssertTrue(disk.submit([span], isLive: { true }, completed: { box.set($0) }))
      await disk.joinPending()
      let spans = try XCTUnwrap(box.take()), file = try XCTUnwrap(Self.files(root).first)
      try FileManager.default.removeItem(at: file)
      XCTAssertThrowsError(try PrefixKVStorage.hydrate(layout: .rotating(window: 4, keep: 0, step: 1, capacityOrigin: "modelNative"),
        spans: spans, prefix: 4, row: 1, batchWidth: 2))
    }
  }

  private static func session(_ store: PromptPrefixCache, _ ids: [Int], owner: PromptCacheOwner, window: Int = 4)
    throws -> PromptPrefixCache.Session {
    try store.makeSession(owner: owner, input: LMInput(tokens: MLXArray(ids, [1, ids.count])),
      promptTokenIDs: ids, prefill: .init(stepSize: 6, chunking: .remainder),
      useActiveNative: true, outputTokens: 2, makeCache: {
        let global = KVCacheSimple(); global.step = 4
        return [global, RotatingKVCache(maxSize: window, step: 2)]
      })
  }
  private static func finishPrefill(_ session: PromptPrefixCache.Session) async throws {
    let ids = session.input.text.tokens.asArray(Int.self)
    var partition = session.prefill; partition.progress = nil
    var ranges: [Range<Int>] = []
    let through = try partition.forEachChunk(total: ids.count) { ranges.append($0) }
    if through < ids.count { ranges.append(through..<ids.count) }
    for range in ranges {
      let keys = MLXArray(ids[range].map(Float.init), [1, 1, range.count, 1])
      for cache in session.cache { _ = cache.update(keys: keys, values: keys + 100) }
      // A real completed CPU forward and its parents precede the actual spill
      // join. Geometry/progress still reflect each original chunk, not a fake
      // completion callback preceding native execution.
      asyncEval(session.cache.flatMap { $0.innerState() })
      eval(session.cache); session.markCacheSubmitted()
      session.prefill.progress?(range.upperBound, ids.count)
      session.observeReadySpill(); await session.joinPendingSpill(cancelled: false)
    }
  }

  func testLayerFilesRetireSlidingBytesWithoutDroppingGlobalHistory() async throws {
    try await InferenceExecutor.shared.perform { _ in
      try await Device.withDefaultDevice(.cpu) {
        let root = try Self.root(), disk = PrefixKVDiskStore(byteLimit: 64, temporaryParent: root)
        let box = ResultBox(), array = MLXArray(Self.bits(.float32, count: 4), [1, 1, 4, 1], dtype: .float32)
        let raw = try XCTUnwrap(array.readyBuffer())
        let global = try PrefixKVDiskStore.ReadySpan(start: 0, layer: 0, keys: raw, values: raw, positions: 0..<4)
        let local = try PrefixKVDiskStore.ReadySpan(start: 0, layer: 1, keys: raw, values: raw, positions: 0..<4)
        XCTAssertTrue(disk.submit([global, local], isLive: { true }, completed: { box.set($0) }))
        await disk.joinPending()
        var written = try XCTUnwrap(box.take())
        XCTAssertEqual(written.count, 2)
        XCTAssertNotEqual(written[0].diskFileID, written[1].diskFileID)
        let retainedGlobal = written.removeFirst()
        written.removeAll(); await disk.joinPending()
        XCTAssertEqual(disk.observation.bytes, 32, "Only the actual sliding last-owner unlink releases quota.")
        XCTAssertEqual(try Self.files(root).count, 1)
        XCTAssertTrue(disk.submit([local], isLive: { true }, completed: { box.set($0) }))
        await disk.joinPending()
        let restored = try PrefixKVStorage.hydrate(layout: .simple(step: 4), spans: [retainedGlobal],
          prefix: 4, row: 0, batchWidth: 1)
        XCTAssertEqual(restored.state[0].asData().data, Self.bits(.float32, count: 4))
        XCTAssertEqual(disk.observation.bytes, 64)
        _ = box.take()
      }
    }
  }

  func testSaturatedDiskQuotaReclaimsLeastRecentlyUsedJoinedHistoryBeforeReplacement() async throws {
    try await InferenceExecutor.shared.perform { _ in
      try await Device.withDefaultDevice(.cpu) {
        let root = try Self.root(), store = PromptPrefixCache(byteLimit: 4096, diskByteLimit: 192, temporaryParent: root)
        let a = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
        let b = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
        let c = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
        let aIDs = Array(0..<6), bIDs = Array(100..<106), cIDs = Array(200..<206)
        let first = try Self.session(store, aIDs, owner: a)
        try await Self.finishPrefill(first); XCTAssertTrue(store.publish(first))
        let second = try Self.session(store, bIDs, owner: b)
        try await Self.finishPrefill(second); XCTAssertTrue(store.publish(second))
        // This sizing probe does not refresh LRU. Actual completed warm
        // admission below does, and must protect A ahead of the older B entry.
        XCTAssertNotNil(try store.nativeAdmissionPlan(owner: a, tokens: aIDs + [9],
          prefill: .init(stepSize: 6), outputTokens: 2, batchWidth: 1))
        let used = try Self.session(store, aIDs + [9], owner: a)
        XCTAssertEqual(used.cachedTokenCount, 6)
        XCTAssertFalse(used.observation.cachedCurrentHotPrefix)
        used.discardStagedAnchors(); await used.joinPendingSpill(cancelled: true)
        let replacement = try Self.session(store, cIDs, owner: c)
        try await Self.finishPrefill(replacement); XCTAssertTrue(store.publish(replacement))
        XCTAssertGreaterThan(replacement.retentionObservation?.diskQuotaMisses ?? 0, 0)
        XCTAssertLessThanOrEqual(replacement.retentionObservation?.diskBytes ?? UInt64.max, 192)
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
        XCTAssertNotNil(try store.nativeAdmissionPlan(owner: a, tokens: aIDs + [8],
          prefill: .init(stepSize: 6), outputTokens: 2, batchWidth: 1))
        XCTAssertNil(try store.nativeAdmissionPlan(owner: b, tokens: bIDs + [8],
          prefill: .init(stepSize: 6), outputTokens: 2, batchWidth: 1))
        XCTAssertNotNil(try store.nativeAdmissionPlan(owner: c, tokens: cIDs + [8],
          prefill: .init(stepSize: 6), outputTokens: 2, batchWidth: 1))
        let returning = try Self.session(store, aIDs + [8], owner: a)
        XCTAssertEqual(returning.cachedTokenCount, 6, "A returning chat restores every required disk layer, not just the sliding ring.")
        XCTAssertEqual(returning.cache[0].state[0].asArray(Float.self), aIDs.map(Float.init))
        XCTAssertEqual(returning.cache[1].state[0].asArray(Float.self), [Float(2), 3, 4, 5])
        returning.discardStagedAnchors(); store.clear(); await returning.joinPendingSpill(cancelled: true)
      }
    }
  }

  func testRawParentPressurePreservesDiskOnlyHistoryAndReturningChatReuse() async throws {
    try await InferenceExecutor.shared.perform { _ in
      try await Device.withDefaultDevice(.cpu) {
        let root = try Self.root(), store = PromptPrefixCache(byteLimit: 128, diskByteLimit: 4096, temporaryParent: root)
        let a = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
        let b = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
        let aIDs = Array(0..<6)
        let first = try Self.session(store, aIDs, owner: a)
        try await Self.finishPrefill(first); XCTAssertTrue(store.publish(first))
        let pressure = try Self.session(store, Array(100..<132), owner: b)
        try await Self.finishPrefill(pressure); XCTAssertTrue(store.publish(pressure))
        XCTAssertEqual(pressure.retentionObservation?.refusalReason, "pool_limit")
        XCTAssertGreaterThan(pressure.retentionObservation?.diskReadyMisses ?? 0, 0)
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
        let restored = try Self.session(store, aIDs + [9], owner: a)
        XCTAssertEqual(restored.cachedTokenCount, 6, "Zero-RAM disk entries cannot pay for a rejected raw parent and must survive that pressure.")
        XCTAssertFalse(restored.observation.cachedCurrentHotPrefix)
        XCTAssertEqual(restored.cache[0].state[0].asArray(Float.self), aIDs.map(Float.init))
        restored.discardStagedAnchors(); store.clear(); await restored.joinPendingSpill(cancelled: true)
      }
    }
  }

  func testAdmittedMiddleEditAfterHotChatSwitchRestoresEveryLayerAtLongestPrefix() async throws {
    try await InferenceExecutor.shared.perform { _ in
      try await Device.withDefaultDevice(.cpu) {
        let root = try Self.root(), store = PromptPrefixCache(byteLimit: 16_384, diskByteLimit: 16_384, temporaryParent: root)
        let a = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .writing)
        let b = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
        let ids = Array(0..<384), generated = Array(1_000..<1_128)
        let original = try Self.session(store, ids, owner: a, window: 64)
        try await Self.finishPrefill(original)
        for token in generated {
          original.didSample?(MLXArray(Int32(token)))
          let keys = MLXArray([Float(token)], [1, 1, 1, 1])
          for cache in original.cache { _ = cache.update(keys: keys, values: keys + 100) }
          asyncEval(original.cache.flatMap { $0.innerState() }); eval(original.cache)
          original.markCacheSubmitted(); original.observeReadySpill()
          await original.joinPendingSpill(cancelled: false)
        }
        XCTAssertTrue(store.publish(original, completions: [.init(emittedTokenIDs: generated)]))
        XCTAssertEqual(original.retentionObservation?.diskQuotaMisses, 0)
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
        let other = try Self.session(store, [9_000, 9_001, 9_002, 9_003, 9_004, 9_005], owner: b, window: 64)
        try await Self.finishPrefill(other); XCTAssertTrue(store.publish(other))
        let query = Array(0..<128) + [7_777]
        let restored = try Self.session(store, query, owner: a, window: 64)
        XCTAssertEqual(restored.cachedTokenCount, 128, "Middle local and global intervals must both survive ample disk quota after hot ownership moves.")
        XCTAssertFalse(restored.observation.cachedCurrentHotPrefix)
        XCTAssertEqual(restored.cache[0].state[0].asArray(Float.self), Array(0..<128).map(Float.init))
        XCTAssertEqual(restored.cache[1].state[0].asArray(Float.self), Array(64..<128).map(Float.init))
        XCTAssertEqual(restored.input.text.tokens.asArray(Int.self), [7_777])
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
        restored.discardStagedAnchors(); store.clear(); await restored.joinPendingSpill(cancelled: true)
      }
    }
  }

  func testJoinedManagerClearRetainsEscapedReaderThenJoinsLastFileOwnerCleanup() async throws {
    try await InferenceExecutor.shared.perform { _ in
      try await Device.withDefaultDevice(.cpu) {
        let root = try Self.root()
        let store = PromptPrefixCache(byteLimit: 4096, temporaryParent: root)
        let owner = PromptCacheOwner(namespace: UUID(), entity: UUID(), route: .consultation)
        let ids = Array(0..<6)
        var source: PromptPrefixCache.Session? = try Self.session(store, ids, owner: owner)
        try await Self.finishPrefill(XCTUnwrap(source))
        XCTAssertTrue(store.publish(try XCTUnwrap(source)))
        XCTAssertGreaterThan(source?.retentionObservation?.diskCreatedFiles ?? 0, 0)
        source?.discardStagedAnchors(); source = nil
        var escaped: PromptPrefixCache.Session? = try Self.session(store, ids + [9], owner: owner)
        XCTAssertEqual(escaped?.cachedTokenCount, 6)
        let beforeClear = try Dictionary(uniqueKeysWithValues: Self.files(root).map { file in
          (file, Digest.sha256(try Data(contentsOf: file)))
        })
        XCTAssertFalse(beforeClear.isEmpty, "Require actual completed private-file spills.")

        store.clear()
        await store.joinPendingDiskCleanup()
        XCTAssertFalse(store.hasAnchors)
        let surviving = try Self.files(root)
        XCTAssertFalse(surviving.isEmpty,
          "Joined clear must not unlink spans still owned by a genuine warm reader.")
        for file in surviving {
          XCTAssertEqual(Digest.sha256(try Data(contentsOf: file)), try XCTUnwrap(beforeClear[file]),
            "Actual owned disk bytes remain readable and unchanged after joined clear.")
        }
        if let reader = escaped {
          XCTAssertGreaterThan(reader.retentionObservation?.diskBytes ?? 0, 0)
          XCTAssertEqual(reader.cache[0].state[0].asArray(Float.self), ids.map(Float.init))
          XCTAssertEqual(reader.cache[1].state[0].asArray(Float.self), [Float(5), 2, 3, 4])
          let ordered = try PrefixKVStorage.hydrate(
            layout: XCTUnwrap(PrefixKVStorage.layout(of: reader.cache[1])),
            spans: PrefixKVStorage.residentWindowSpans(of: reader.cache[1], layer: 1, through: 6),
            prefix: 6, row: 0)
          XCTAssertEqual(ordered.state[0].asArray(Float.self), [Float(2), 3, 4, 5])
          reader.discardStagedAnchors()
        }
        escaped = nil // the last cache/capture file owners, not a forced purge
        await store.joinPendingDiskCleanup()
        XCTAssertTrue(try Self.files(root).isEmpty,
          "The explicit join must complete the actual queued last-owner unlinks.")
        XCTAssertEqual(store.activeCaptureLeaseCount, 0)
        XCTAssertEqual(store.retainedBytesUpperBound, 0)
      }
    }
  }
}
