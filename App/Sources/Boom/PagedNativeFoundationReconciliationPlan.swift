import BoomCore
import Foundation

/// A copy of metadata attached to an ACTUAL Foundation action target. It is
/// not an independently advanced source stack. The command owner holds <=100 such targets
/// and changes this mirror only with actual SDK registration/removal/inverse.
struct PagedNativeFoundationNode: Sendable, Equatable {
  let id: UUID
  let nativeOwnerID: UUID
  let direction: PagedNativeHistoryHandle.Direction
  let canonical: PagedRootHistoryEntry?
  let canonicalRecord: PagedDocumentRootRecord?
  let canonicalIndex: Int?
  let nativeReceipt: PagedNativeGroupClosureReceipt?
}

/// Compute the entire bounded plan before any Foundation mutation. Actual
/// application stays in the command owner's Main lexical scope; normal public
/// history requests queue throughout that scope. No source/root changes occur.
struct PagedNativeFoundationReconciliationPlan: Sendable {
  struct Desired: Sendable {
    let existingID: UUID?
    let canonical: PagedRootHistoryEntry?
    let canonicalIndex: Int?
    let canonicalRecord: PagedDocumentRootRecord?
    let nativeReceipt: PagedNativeGroupClosureReceipt?
    let direction: PagedNativeHistoryHandle.Direction
  }
  struct SelectionDisposition: Sendable {
    let originalNodeID: UUID
    /// The complete canonical entry may survive under another actual target
    /// after adjacent chunks coalesce. Nil is explicit expiry, not retry.
    let canonical: PagedRootHistoryEntry?
    let canonicalIndex: Int?
    let existingSurvivorID: UUID?
  }
  enum Mutation: Sendable { case pruneOnly, rebuildUndoOnly }
  let undo: [Desired]
  let redo: [Desired]
  let retiredIDs: [UUID]
  let dispositions: [SelectionDisposition]
  let mutation: Mutation
  let afterRecord: PagedDocumentRootRecord
  let coveredSequence: UInt64

  init(previous: PagedNativeCanonicalHistoryProjection,
    incoming: PagedNativeCanonicalHistoryProjection,
    actualUndo: [PagedNativeFoundationNode], actualRedo: [PagedNativeFoundationNode],
    nativeOwnerID: UUID) throws {
    guard previous.record == incoming.beforeRecord,
      previous.scope.sessionID == incoming.scope.sessionID,
      previous.producer.engineIncarnation == incoming.producer.engineIncarnation,
      previous.producer.ownerID == incoming.producer.ownerID,
      actualUndo.count + actualRedo.count <= PagedRootHistory.maximumEntries,
      incoming.scope.coveredSequence > previous.scope.coveredSequence else {
      throw BoomError.stale("Foundation reconciliation is not this exact joined source prefix.")
    }
    switch incoming.scope {
    case .nativeBatch, .historyPublished, .capturedEdit: break
    default: throw BoomError.invalid("Unpublished/opening history cannot reconcile an active Foundation manager.")
    }
    let nodes = actualUndo + actualRedo
    guard Set(nodes.map(\.id)).count == nodes.count,
      actualUndo.allSatisfy({ $0.nativeOwnerID == nativeOwnerID && $0.direction == .undo }),
      actualRedo.allSatisfy({ $0.nativeOwnerID == nativeOwnerID && $0.direction == .redo }) else {
      throw BoomError.denied("Foundation actions have another exact native target owner.")
    }
    for node in nodes {
      guard (node.canonical == nil) == (node.canonicalRecord == nil),
        (node.canonical == nil) == (node.canonicalIndex == nil) else {
        throw BoomError.invalid("Foundation canonical metadata lost its exact record/slot tuple.")
      }
      if let canonical = node.canonical {
        guard canonical.revision.ownerID == incoming.record.document.revision.ownerID,
          canonical.revision.documentID == incoming.record.document.id else {
          throw BoomError.denied("Foundation action metadata crosses source ownership.")
        }
      }
      if let receipt = node.nativeReceipt {
        guard receipt.sessionID == incoming.scope.sessionID,
          receipt.firstSequence > 0, receipt.firstSequence <= receipt.lastSequence,
          receipt.hasEffectiveSourceChange, node.direction == .undo else {
          throw BoomError.invalid("A Foundation native target lost its actual meaningful closure.")
        }
      } else if node.canonical == nil {
        throw BoomError.invalid("A Foundation target lacks actual closure or canonical metadata.")
      }
    }

    let through = incoming.scope.coveredSequence
    // A chunk crossing the seal is protected in its entirety. Coalescence of
    // the sealed part never substitutes a different object for accepted G+1.
    let protected = actualUndo.filter { ($0.nativeReceipt?.lastSequence ?? 0) > through }
    if let firstProtected = actualUndo.firstIndex(where: { ($0.nativeReceipt?.lastSequence ?? 0) > through }) {
      guard actualUndo[firstProtected...].allSatisfy({ ($0.nativeReceipt?.lastSequence ?? 0) > through }) else {
        throw BoomError.stale("Later accepted native targets are not an ordered Foundation suffix.")
      }
    }

    func admittedIndex(_ node: PagedNativeFoundationNode) throws -> Int? {
      if let receipt = node.nativeReceipt, receipt.lastSequence > through { return nil }
      let entries = node.direction == .undo ? incoming.undo : incoming.redo
      let priorEntries = node.direction == .undo ? previous.undo : previous.redo
      let lineage = node.direction == .undo ? incoming.undoFromBefore : incoming.redoFromBefore
      if let canonical = node.canonical, let index = node.canonicalIndex,
        let record = node.canonicalRecord {
        if record == incoming.record {
          guard entries.indices.contains(index), entries[index] == canonical else {
            throw BoomError.stale("Prepared Foundation inverse differs from its exact candidate slot.")
          }
          return index
        }
        guard record == previous.record, priorEntries.indices.contains(index), priorEntries[index] == canonical else {
          throw BoomError.stale("Foundation action lost its exact prior-record slot identity.")
        }
        if let retained = lineage.firstIndex(where: { $0 == index }) {
          guard entries[retained] == canonical else { throw BoomError.invalid("Worker slot lineage lost the exact retained entry.") }
          return retained
        }
      }
      guard let receipt = node.nativeReceipt else { return nil }
      guard case .nativeBatch(_, _, let first, let last) = incoming.scope else {
        throw BoomError.stale("An unmapped old native target is absent from its real history seal.")
      }
      guard receipt.firstSequence >= first, receipt.lastSequence <= last else {
        guard node.canonical != nil else {
          throw BoomError.stale("Unsealed native target has no exact checkpoint resolution in this batch.")
        }
        return nil
      }
      let matches = incoming.resolutions.filter {
        $0.groupID == receipt.effectiveGroupID && $0.firstSequence <= receipt.firstSequence
          && $0.lastSequence >= receipt.lastSequence
      }
      guard matches.count == 1 else {
        throw BoomError.stale("Native target has no unique actual checkpoint-to-root resolution.")
      }
      return matches[0].undoIndex
    }

    var mappedUndo: [(PagedNativeFoundationNode, Int?)] = []
    for node in actualUndo where (node.nativeReceipt?.lastSequence ?? 0) <= through {
      mappedUndo.append((node, try admittedIndex(node)))
    }
    var used = Set<UUID>()
    var desiredUndo: [Desired] = []
    for (index, canonical) in incoming.undo.enumerated() {
      let match = mappedUndo.first { $0.1 == index && !used.contains($0.0.id) }
      if let match { used.insert(match.0.id) }
      desiredUndo.append(Desired(existingID: match?.0.id, canonical: canonical, canonicalIndex: index,
        canonicalRecord: incoming.record, nativeReceipt: nil, direction: .undo))
    }
    for node in protected {
      used.insert(node.id)
      desiredUndo.append(Desired(existingID: node.id, canonical: node.canonical, canonicalIndex: node.canonicalIndex,
        canonicalRecord: node.canonicalRecord, nativeReceipt: node.nativeReceipt, direction: .undo))
    }
    if desiredUndo.count > PagedRootHistory.maximumEntries {
      desiredUndo.removeFirst(desiredUndo.count - PagedRootHistory.maximumEntries)
    }
    var desiredRedo: [Desired] = []
    // Actual normal registration has already cleared SDK Redo. Protecting
    // source-newer input never restores Redo over those accepted registrations.
    if protected.isEmpty {
      var mappedRedo: [(PagedNativeFoundationNode, Int?)] = []
      for node in actualRedo { mappedRedo.append((node, try admittedIndex(node))) }
      for (index, canonical) in incoming.redo.enumerated() {
        let match = mappedRedo.first { $0.1 == index && !used.contains($0.0.id) }
        if let match { used.insert(match.0.id) }
        desiredRedo.append(Desired(existingID: match?.0.id, canonical: canonical, canonicalIndex: index,
          canonicalRecord: incoming.record, nativeReceipt: nil, direction: .redo))
      }
    }
    guard desiredUndo.count + desiredRedo.count <= PagedRootHistory.maximumEntries else {
      throw BoomError.budget("Canonical Foundation projection exceeds its retained-entry bound.")
    }
    let desiredIDs = Set((desiredUndo + desiredRedo).compactMap(\.existingID))
    let retired = nodes.filter { !desiredIDs.contains($0.id) }.map(\.id)
    let pruningUndo = actualUndo.filter { desiredIDs.contains($0.id) }.map(\.id)
    let pruningRedo = actualRedo.filter { desiredIDs.contains($0.id) }.map(\.id)
    let isPrune = desiredUndo.allSatisfy({ $0.existingID != nil })
      && desiredRedo.allSatisfy({ $0.existingID != nil })
      && pruningUndo == desiredUndo.compactMap(\.existingID)
      && pruningRedo == desiredRedo.compactMap(\.existingID)
    if !isPrune, !desiredRedo.isEmpty {
      // Never emit synthetic Will/DidUndo to repair a live manager. Retain
      // real ACK/prefix/output custody and report a receiving-side discrepancy.
      throw BoomError.stale("Live Foundation Redo cannot be rebuilt by an opening-only metadata Undo pass.")
    }
    var selected: [SelectionDisposition] = []
    for (node, index) in mappedUndo {
      let survivor = desiredUndo.first { index != nil && $0.canonicalIndex == index && $0.nativeReceipt == nil }
      selected.append(SelectionDisposition(originalNodeID: node.id,
        canonical: survivor?.canonical, canonicalIndex: survivor?.canonicalIndex,
        existingSurvivorID: survivor?.existingID))
    }
    undo = desiredUndo; redo = desiredRedo; retiredIDs = retired; dispositions = selected
    mutation = isPrune ? .pruneOnly : .rebuildUndoOnly
    afterRecord = incoming.record; coveredSequence = through
  }
}
