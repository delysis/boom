import Foundation

/// Host evidence for the pinned stateless Gemma text path. This describes the
/// actual token operands and their row mapping, never embedding features, KV
/// values, kernel choices or independent numerical equivalence.
public struct ForwardOperandBinding: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable { case prefill, decode }
  public struct Member: Codable, Equatable, Sendable {
    public let logicalRequests: [String]
    public let preparedTokenDigest: String
    public let preparedTokenCount: Int
    public let cachedTokenCount: Int
    public let cachedTokenDigest: String
    public let cachedSourceDigest: String
    public let cachePaddingDigest: String
    public init(logicalRequests: [String], preparedTokenDigest: String,
      preparedTokenCount: Int, cachedTokenCount: Int, cachedTokenDigest: String,
      cachedSourceDigest: String, cachePaddingDigest: String) {
      self.logicalRequests = logicalRequests; self.preparedTokenDigest = preparedTokenDigest
      self.preparedTokenCount = preparedTokenCount; self.cachedTokenCount = cachedTokenCount
      self.cachedTokenDigest = cachedTokenDigest; self.cachedSourceDigest = cachedSourceDigest
      self.cachePaddingDigest = cachePaddingDigest
    }
  }
  public static let scope = "pinned_gemma4_text_host_operands_v1"
  public static let metadataBytesUpperBound: UInt64 = 4_096
  public static let maximumPreparedTokens = 16_384
  // A generated continuation may extend the prepared prompt. This is a host
  // descriptor bound, not an admission of model context capacity.
  public static let maximumLogicalEnd = 32_768
  public let schema: Int
  public let evidenceScope: String
  public let phase: Phase
  public let modelBinding: String
  public let members: [Member]
  public let inputRangeStart: Int
  public let evaluatedLength: Int
  public let logicalStarts: [Int]
  public let validLengths: [Int]
  public let generationActive: [Bool]
  public let tokenMatrixDigest: String
  public let submittedAndCompleted: Bool
  public var physicalWidth: Int { members.count }

  private init(phase: Phase, modelBinding: String, members: [Member], inputRangeStart: Int,
    evaluatedLength: Int, logicalStarts: [Int], validLengths: [Int], generationActive: [Bool],
    tokenMatrixDigest: String, submittedAndCompleted: Bool) {
    schema = 1; evidenceScope = Self.scope; self.phase = phase; self.modelBinding = modelBinding
    self.members = members; self.inputRangeStart = inputRangeStart; self.evaluatedLength = evaluatedLength
    self.logicalStarts = logicalStarts; self.validLengths = validLengths
    self.generationActive = generationActive; self.tokenMatrixDigest = tokenMatrixDigest
    self.submittedAndCompleted = submittedAndCompleted
  }
  public static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  /// One bounded pass over supplied host IDs, with explicit dimensions. The
  /// original arrays are not retained or copied into each history descriptor.
  public static func tokenDigest(_ rows: [[Int]]) -> String? {
    guard (1...4).contains(rows.count), let length = rows.first?.count,
      (1...16_384).contains(length), rows.allSatisfy({ $0.count == length }) else { return nil }
    var data = Data("Boom.forward-token-matrix.v1\0".utf8)
    data.reserveCapacity(data.count + 8 + rows.count * length * 4)
    func append(_ value: Int) {
      let n = UInt32(value)
      data.append(UInt8(truncatingIfNeeded: n)); data.append(UInt8(truncatingIfNeeded: n >> 8))
      data.append(UInt8(truncatingIfNeeded: n >> 16)); data.append(UInt8(truncatingIfNeeded: n >> 24))
    }
    append(rows.count); append(length)
    for row in rows {
      for token in row {
        guard (0...Int(Int32.max)).contains(token) else { return nil }
        append(token)
      }
    }
    return Digest.sha256(data)
  }
  public static func candidate(phase: Phase, modelBinding: String, members: [Member],
    inputRangeStart: Int, tokenRows: [[Int]], logicalStarts: [Int], validLengths: [Int],
    generationActive: [Bool]) -> Self? {
    guard tokenRows.count == members.count, let digest = tokenDigest(tokenRows) else { return nil }
    let value = Self(phase: phase, modelBinding: modelBinding, members: members,
      inputRangeStart: inputRangeStart, evaluatedLength: tokenRows[0].count,
      logicalStarts: logicalStarts, validLengths: validLengths, generationActive: generationActive,
      tokenMatrixDigest: digest, submittedAndCompleted: false)
    return value.wellFormed ? value : nil
  }
  public var wellFormed: Bool {
    guard schema == 1, evidenceScope == Self.scope, Self.isDigest(modelBinding),
      Self.isDigest(tokenMatrixDigest), (1...4).contains(physicalWidth),
      (0...16_384).contains(inputRangeStart), (1...16_384).contains(evaluatedLength),
      logicalStarts.count == physicalWidth, validLengths.count == physicalWidth,
      generationActive.count == physicalWidth,
      logicalStarts.allSatisfy({ (0...16_384).contains($0)
        && !$0.addingReportingOverflow(evaluatedLength).overflow
        && $0 + evaluatedLength <= Self.maximumLogicalEnd }),
      validLengths.allSatisfy({ (0...evaluatedLength).contains($0) }) else { return false }
    let identities = members.flatMap(\.logicalRequests)
    guard (1...4).contains(identities.count), Set(identities).count == identities.count else { return false }
    return members.allSatisfy { m in
      !m.logicalRequests.isEmpty && m.logicalRequests.allSatisfy(Self.isDigest)
        && Self.isDigest(m.preparedTokenDigest) && Self.isDigest(m.cachedTokenDigest)
        && Self.isDigest(m.cachedSourceDigest) && Self.isDigest(m.cachePaddingDigest)
        && (1...16_384).contains(m.preparedTokenCount)
        && (0...m.preparedTokenCount).contains(m.cachedTokenCount)
    }
  }
  /// A candidate alone is not a forward: failed/cancelled construction must
  /// never turn predicted submission into completed original-input evidence.
  public func committed(allOwningLayersComplete: Bool, actuallySubmitted: Bool) -> Self? {
    guard wellFormed, allOwningLayersComplete, actuallySubmitted else { return nil }
    return Self(phase: phase, modelBinding: modelBinding, members: members,
      inputRangeStart: inputRangeStart, evaluatedLength: evaluatedLength,
      logicalStarts: logicalStarts, validLengths: validLengths, generationActive: generationActive,
      tokenMatrixDigest: tokenMatrixDigest, submittedAndCompleted: true)
  }
  /// History may clip a row's semantic prefix, but the complete original
  /// physical operands and evaluated boundary remain immutable.
  public func describes(start: Int, end: Int, evaluatedEnd: Int, width: Int, row: Int?) -> Bool {
    let selected = row ?? 0
    guard wellFormed, physicalWidth == width,
      (0..<physicalWidth).contains(selected), width == 1 || row != nil,
      start == logicalStarts[selected], end > start, end <= start + validLengths[selected],
      evaluatedEnd == start + evaluatedLength else { return false }
    return true
  }
  public func covers(start: Int, end: Int, evaluatedEnd: Int, width: Int, row: Int?) -> Bool {
    submittedAndCompleted && describes(start: start, end: end, evaluatedEnd: evaluatedEnd, width: width, row: row)
  }
}
