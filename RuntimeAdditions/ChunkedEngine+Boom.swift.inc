
// BEGIN BOOM NATIVE ADDITION — original integration code, appended in this file
// so Swift's file-scoped private access remains narrow. Upstream is pinned.
extension ChunkedEngine {
  private var boomBuffers: [(String, MLMultiArray)] {
    [
      ("kSliding1", kSliding1), ("vSliding1", vSliding1),
      ("kFull1", kFull1), ("vFull1", vFull1),
      ("kSliding2", kSliding2), ("vSliding2", vSliding2),
      ("kFull2", kFull2), ("vFull2", vFull2),
    ]
  }

  /// Dense fast path on the supported little-endian Mac architectures. Padded
  /// IOSurface-backed arrays retain their logical strided representation on disk.
  private func boomIsDense(_ array: MLMultiArray) -> Bool {
    guard UInt16(littleEndian: 1) == 1 else { return false }
    var expected = 1
    for axis in array.shape.indices.reversed() {
      let dimension = array.shape[axis].intValue
      if dimension > 1 && array.strides[axis].intValue != expected { return false }
      expected *= dimension
    }
    return true
  }
  private func boomOffset(_ linear: Int, shape: [Int], strides: [Int]) -> Int {
    var remaining = linear
    var offset = 0
    for axis in shape.indices.reversed() {
      offset += (remaining % shape[axis]) * strides[axis]
      remaining /= shape[axis]
    }
    return offset
  }

  /// Compile source packages into CoreML's temporary output, never into the
  /// content-verified model bundle. Only the two pinned load sites call this.
  static func boomLoadCompiledModel(_ url: URL, configuration: MLModelConfiguration) throws
    -> MLModel
  {
    let compiled: URL
    if url.pathExtension == "mlmodelc" {
      compiled = url
    } else if url.pathExtension == "mlpackage" {
      compiled = try MLModel.compileModel(at: url)
    } else {
      throw BoomRuntimeError.invalid("Unsupported local model representation.")
    }
    return try MLModel(contentsOf: compiled, configuration: configuration)
  }

  func boomSnapshot(tokens: [Int], nextToken: Int, identity: String) throws -> BoomKVSnapshot {
    quiesceCopyBacks()
    guard currentPosition == tokens.count, currentPosition > 0,
      currentPosition < config.contextLength
    else {
      throw BoomRuntimeError.invalid("Cannot snapshot an uncommitted or full context.")
    }
    var tensors: [BoomKVTensor] = []
    var total = 0
    for (name, array) in boomBuffers {
      guard array.dataType == .float16, array.count > 0,
        array.count <= 268_435_456
      else {
        throw BoomRuntimeError.invalid("Unsupported KV storage type or size: \(name)")
      }
      total += array.count * 2
      guard total <= 1_073_741_824 else {
        throw BoomRuntimeError.invalid("KV snapshot exceeds 1 GiB.")
      }
      if boomIsDense(array) {
        tensors.append(
          BoomKVTensor(
            name: name, shape: array.shape.map(\.intValue),
            bytes: Data(bytes: array.dataPointer, count: array.count * 2)))
        continue
      }
      let shape = array.shape.map(\.intValue)
      let strides = array.strides.map(\.intValue)
      var bytes = Data(count: array.count * 2)
      let source = array.dataPointer.assumingMemoryBound(to: UInt16.self)
      bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        let destination = raw.bindMemory(to: UInt8.self)
        for index in 0..<array.count {
          let value = source[boomOffset(index, shape: shape, strides: strides)]
          destination[index * 2] = UInt8(truncatingIfNeeded: value)
          destination[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
      }
      tensors.append(BoomKVTensor(name: name, shape: array.shape.map(\.intValue), bytes: bytes))
    }
    return BoomKVSnapshot(
      schema: 1, identity: identity, position: currentPosition,
      nextToken: nextToken, tokens: tokens, tensors: tensors)
  }

  /// Validate ALL tensors before touching any live storage. The caller authenticates
  /// the sealed record first and owns the single prediction queue throughout restore.
  func boomRestore(_ snapshot: BoomKVSnapshot, identity: String) throws {
    guard snapshot.schema == 1, snapshot.identity == identity,
      snapshot.position == snapshot.tokens.count,
      snapshot.position > 0, snapshot.position < config.contextLength,
      (0..<config.vocabSize).contains(snapshot.nextToken),
      snapshot.tokens.allSatisfy({ (0..<config.vocabSize).contains($0) }),
      snapshot.tensors.count == 8
    else { throw BoomRuntimeError.invalid("Incompatible KV snapshot.") }
    let buffers = boomBuffers
    for (index, pair) in buffers.enumerated() {
      let (name, array) = pair
      let tensor = snapshot.tensors[index]
      guard tensor.name == name, tensor.shape == array.shape.map(\.intValue),
        array.dataType == .float16, tensor.bytes.count == array.count * 2
      else {
        throw BoomRuntimeError.invalid("KV tensor contract mismatch: \(name)")
      }
    }
    quiesceCopyBacks()
    reset()
    for (index, pair) in buffers.enumerated() {
      let array = pair.1
      let bytes = snapshot.tensors[index].bytes
      if boomIsDense(array) {
        _ = bytes.withUnsafeBytes { raw in memcpy(array.dataPointer, raw.baseAddress!, bytes.count)
        }
        continue
      }
      let shape = array.shape.map(\.intValue)
      let strides = array.strides.map(\.intValue)
      let destination = array.dataPointer.assumingMemoryBound(to: UInt16.self)
      bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let source = raw.bindMemory(to: UInt8.self)
        for element in 0..<array.count {
          destination[boomOffset(element, shape: shape, strides: strides)] =
            UInt16(source[element * 2]) | (UInt16(source[element * 2 + 1]) << 8)
        }
      }
    }
    currentPosition = snapshot.position
    lastArgmaxAfterDecode = snapshot.nextToken
    // No EAGLE, MTP, cross-vocabulary or speculative state participates in Boom.
    lastHiddenAtL8 = nil
    lastHiddenAtL17 = nil
    lastHiddenAtL34 = nil
  }
}
// END BOOM NATIVE ADDITION
