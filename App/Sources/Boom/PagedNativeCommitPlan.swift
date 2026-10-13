import BoomCore
import Foundation

/// Worker-only admission of one bounded accepted-character batch. This is a
/// private candidate plan, never a current-root grant or a decoded model edit.
/// The storage owner must still compare the complete authenticated root record
/// and publish the final document/history/workspace head atomically.
struct PagedNativeCommitPlan: Sendable {
  struct Step: Sendable {
    enum Kind: Sendable, Equatable { case expiredGroupBaseline, nativeGroup, epochOnly }
    let kind: Kind
    /// Meaningful groups keep their actual native UUID. An epoch-only tail
    /// does not rename discarded no-op groups into an invented Undo group.
    let groupID: UUID?
    let lastSequence: UInt64
    let afterBytes: Data
    let beforeCursor: PagedNativeLocalCursor?
    let localCursorByte: Int
    let localCursorUTF16: Int
    let localSelectionLengthUTF16: Int
    let localFocusAtEnd: Bool
    let localAffinity: PagedSelectionAffinity
  }
  let initialBytes: Data
  /// At most one expired meaningful baseline, 100 meaningful group states,
  /// and one source-neutral epoch tail: <=102 steps / <=101 possible splices.
  /// A compacted net delta alone cannot reconstruct the retained Undo points.
  let steps: [Step]

  init(_ batch: PagedNativeCommitBatch) throws {
    guard !Thread.isMainThread else {
      throw BoomError.invalid("Native candidate admission belongs to storage execution.")
    }
    try batch.expected.validate(); try batch.expectedRootRecord.validate()
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard batch.sessionID != zero, batch.batchID != zero,
      batch.expectedRootRecord.document.revision == batch.expected.revision,
      batch.firstSequence > 0, batch.firstSequence <= batch.lastSequence,
      !batch.deltas.isEmpty, batch.deltas.count <= PagedWorkingWindow.maximumQueuedDeltas,
      batch.groupCheckpoints.count <= PagedRootHistory.maximumEntries,
      batch.afterBytes.count <= PagedWorkingWindow.hardBytes else {
      throw BoomError.invalid("Native candidate has an inconsistent captured root or sequence bound.")
    }
    initialBytes = Data(batch.expected.text.utf8)
    guard initialBytes.count <= PagedWorkingWindow.hardBytes else {
      throw BoomError.budget("Native candidate exceeds its fixed resident island.")
    }

    var admitted: [Step] = []
    admitted.reserveCapacity(PagedRootHistory.maximumEntries + 2)
    var previousGroupSequence = batch.firstSequence - 1
    var previousGroupBytes = initialBytes
    if let baseline = batch.historyBaseline {
      guard batch.groupCheckpoints.count == PagedRootHistory.maximumEntries,
        baseline.firstSequence >= batch.firstSequence,
        baseline.firstSequence <= baseline.lastSequence,
        baseline.lastSequence < batch.lastSequence else {
        throw BoomError.invalid("Expired native groups have no bounded retained baseline.")
      }
      admitted.append(try Self.step(baseline, kind: .expiredGroupBaseline))
      previousGroupSequence = baseline.lastSequence
      previousGroupBytes = baseline.afterBytes
    }
    var groupIDs = Set<UUID>()
    for checkpoint in batch.groupCheckpoints {
      // Source-neutral groups may occupy gaps. Their original deltas still
      // cover those sequences; no other group adopts their IDs or ranges.
      guard checkpoint.firstSequence > previousGroupSequence,
        checkpoint.firstSequence <= checkpoint.lastSequence,
        checkpoint.lastSequence <= batch.lastSequence,
        groupIDs.insert(checkpoint.groupID).inserted else {
        throw BoomError.invalid("Meaningful native checkpoints have an invalid sequence, identity or net state.")
      }
      let beforeCursor = try Self.localCursor(in: previousGroupBytes,
        caretUTF16: checkpoint.beforeCursor.utf16Offset,
        selectionLengthUTF16: checkpoint.beforeCursor.selectionLengthUTF16,
        focusAtEnd: checkpoint.beforeCursor.focusAtEnd, affinity: checkpoint.beforeCursor.affinity)
      guard beforeCursor == checkpoint.beforeCursor else {
        throw BoomError.invalid("Native group start cursor differs from its exact before source.")
      }
      // Adjacent chunks of one typing transaction may return to its original
      // bytes. Preserve their real sequence resolution, but mint no Undo root.
      admitted.append(try Self.step(checkpoint, kind: .nativeGroup))
      previousGroupSequence = checkpoint.lastSequence
      previousGroupBytes = checkpoint.afterBytes
    }
    guard previousGroupBytes == batch.afterBytes else {
      throw BoomError.invalid("The retained native groups do not end at the accepted batch.")
    }
    let final = try Self.makeStep(kind: .epochOnly, groupID: nil,
      lastSequence: batch.lastSequence, afterBytes: batch.afterBytes, caretUTF16: batch.finalCaretUTF16,
      selectionLengthUTF16: batch.finalSelectionLengthUTF16,
      focusAtEnd: batch.finalFocusAtEnd, affinity: batch.finalAffinity)
    if admitted.last?.lastSequence == batch.lastSequence {
      guard admitted.last?.localCursorByte == final.localCursorByte,
        admitted.last?.localCursorUTF16 == final.localCursorUTF16,
        admitted.last?.localSelectionLengthUTF16 == final.localSelectionLengthUTF16,
        admitted.last?.localFocusAtEnd == final.localFocusAtEnd,
        admitted.last?.localAffinity == final.localAffinity else {
        throw BoomError.invalid("The final native cursor differs from its retained group endpoint.")
      }
    } else { admitted.append(final) }

    // Exact byte admission of the original deltas is independent of the
    // checkpoints. Bounded queue compaction may span intermediate groups;
    // every endpoint it does retain must agree with the corresponding state.
    var oracle = initialBytes, expectedSequence = batch.firstSequence
    var chargedBytes = 0, checkpointIndex = 0
    for (index, delta) in batch.deltas.enumerated() {
      guard delta.firstSequence == expectedSequence,
        delta.firstSequence <= delta.lastSequence, delta.lastSequence <= batch.lastSequence,
        delta.localByteStart >= 0, delta.localByteStart <= oracle.count,
        delta.oldBytes.count <= oracle.count - delta.localByteStart,
        delta.oldBytes.count <= PagedWorkingWindow.hardBytes,
        delta.newBytes.count <= PagedWorkingWindow.hardBytes,
        String(data: delta.oldBytes, encoding: .utf8) != nil,
        String(data: delta.newBytes, encoding: .utf8) != nil else {
        throw BoomError.invalid("Native deltas have an invalid scalar range or ordered sequence.")
      }
      chargedBytes += delta.chargedBytes
      guard chargedBytes <= PagedWorkingWindow.maximumQueuedBytes else {
        throw BoomError.budget("Native deltas exceed their fixed queue charge.")
      }
      let range = delta.localByteStart..<(delta.localByteStart + delta.oldBytes.count)
      guard Self.isScalarBoundary(range.lowerBound, in: oracle),
        Self.isScalarBoundary(range.upperBound, in: oracle),
        oracle.subdata(in: range) == delta.oldBytes,
        delta.newBytes.count <= PagedWorkingWindow.hardBytes - (oracle.count - range.count) else {
        throw BoomError.stale("Native deltas differ from the exact captured bytes.")
      }
      oracle.replaceSubrange(range, with: delta.newBytes)
      while checkpointIndex < admitted.count,
        admitted[checkpointIndex].lastSequence <= delta.lastSequence {
        let checkpoint = admitted[checkpointIndex]
        guard checkpoint.lastSequence >= delta.firstSequence else {
          throw BoomError.invalid("Native delta coverage skipped a retained group.")
        }
        if checkpoint.lastSequence == delta.lastSequence, checkpoint.afterBytes != oracle {
          throw BoomError.invalid("A native delta endpoint differs from its retained group.")
        }
        checkpointIndex += 1
      }
      if index + 1 < batch.deltas.count {
        let next = delta.lastSequence.addingReportingOverflow(1)
        guard !next.overflow else { throw BoomError.budget("Native delta sequence is exhausted.") }
        expectedSequence = next.partialValue
      }
    }
    guard batch.deltas.last?.lastSequence == batch.lastSequence,
      checkpointIndex == admitted.count, oracle == batch.afterBytes,
      String(data: oracle, encoding: .utf8) != nil else {
      throw BoomError.invalid("Native deltas do not produce the accepted bounded island.")
    }
    steps = admitted
  }

  private static func isScalarBoundary(_ offset: Int, in bytes: Data) -> Bool {
    offset == bytes.count || bytes[bytes.startIndex + offset] & 0xc0 != 0x80
  }

  private static func step(_ checkpoint: PagedNativeGroupCheckpoint, kind: Step.Kind) throws -> Step {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard checkpoint.groupID != zero else { throw BoomError.invalid("Native checkpoint identity is empty.") }
    return try makeStep(kind: kind, groupID: checkpoint.groupID, lastSequence: checkpoint.lastSequence,
      afterBytes: checkpoint.afterBytes, caretUTF16: checkpoint.caretUTF16,
      beforeCursor: kind == .nativeGroup ? checkpoint.beforeCursor : nil,
      selectionLengthUTF16: checkpoint.afterSelectionLengthUTF16,
      focusAtEnd: checkpoint.afterFocusAtEnd, affinity: checkpoint.afterAffinity)
  }

  private static func makeStep(kind: Step.Kind, groupID: UUID?, lastSequence: UInt64,
    afterBytes: Data, caretUTF16: Int, beforeCursor: PagedNativeLocalCursor? = nil,
    selectionLengthUTF16: Int = 0, focusAtEnd: Bool = false,
    affinity: PagedSelectionAffinity = .downstream) throws -> Step {
    let cursor = try localCursor(in: afterBytes, caretUTF16: caretUTF16,
      selectionLengthUTF16: selectionLengthUTF16, focusAtEnd: focusAtEnd, affinity: affinity)
    return Step(kind: kind, groupID: groupID, lastSequence: lastSequence,
      afterBytes: afterBytes, beforeCursor: beforeCursor,
      localCursorByte: cursor.byteOffset, localCursorUTF16: cursor.utf16Offset,
      localSelectionLengthUTF16: cursor.selectionLengthUTF16,
      localFocusAtEnd: cursor.focusAtEnd, localAffinity: cursor.affinity)
  }

  private static func localCursor(in bytes: Data, caretUTF16: Int,
    selectionLengthUTF16: Int = 0, focusAtEnd: Bool = false,
    affinity: PagedSelectionAffinity = .downstream) throws -> PagedNativeLocalCursor {
    let end = caretUTF16.addingReportingOverflow(selectionLengthUTF16)
    guard bytes.count <= PagedWorkingWindow.hardBytes, caretUTF16 >= 0,
      selectionLengthUTF16 >= 0, !end.overflow,
      let text = String(data: bytes, encoding: .utf8) else {
      throw BoomError.invalid("Native group checkpoint exceeds its scalar island.")
    }
    var byte = 0, units = 0, startByte: Int?
    for scalar in text.unicodeScalars {
      if units == caretUTF16 { startByte = byte }
      if units == end.partialValue { break }
      let value = scalar.value
      units += value < 0x10000 ? 1 : 2
      byte += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
    }
    if units == caretUTF16 { startByte = byte }
    guard units == end.partialValue, let startByte else {
      throw BoomError.invalid("Native group cursor splits a scalar or exceeds its island.")
    }
    return PagedNativeLocalCursor(byteOffset: startByte, utf16Offset: caretUTF16,
      selectionLengthUTF16: selectionLengthUTF16, focusAtEnd: focusAtEnd, affinity: affinity)
  }
}
