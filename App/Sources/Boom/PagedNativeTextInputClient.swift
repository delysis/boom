import AppKit
import BoomCore
import Foundation
import ObjectiveC

/// The document input context survives bounded-window rotations. Its UTF16
/// ranges are logical document coordinates; substring/geometry queries expose
/// only the actually resident window. Context ownership never retargets another
/// document, and a retired owner leaves retained contexts inert.
struct PagedNativeDocumentInputIdentity: Equatable {
  let ownerID: UUID
  let sessionID: UUID
  let documentID: UUID
}
/// An admitted native callback remains in the same chronological input queue
/// until its actual primitive/installation completes. Intermediate marked
/// previews may be superseded only by the same pending native conversion.
@MainActor final class PagedNativeContextContinuation {
  enum Kind { case insert, marked(NSRange), command(Selector), unmark }
  let id = UUID()
  let identity: PagedNativeDocumentInputIdentity
  let pendingID: UUID?
  var rootID: UUID
  var selection: PagedNativeNavigationSelection
  let implicitRange: Bool
  let text: Any
  let kind: Kind
  let chargedBytes: Int
  var failure: Error?
  init(identity: PagedNativeDocumentInputIdentity, pendingID: UUID?, rootID: UUID,
    selection: PagedNativeNavigationSelection, implicitRange: Bool, text: Any,
    kind: Kind, chargedBytes: Int) {
    self.identity = identity; self.pendingID = pendingID; self.rootID = rootID
    self.selection = selection; self.implicitRange = implicitRange; self.text = text
    self.kind = kind; self.chargedBytes = chargedBytes
  }
  var isPreview: Bool { if case .marked = kind { return true }; return false }
  var supersedesPreview: Bool {
    switch kind { case .insert, .marked: return true; case .command, .unmark: return false }
  }
  func map(before: PagedNativeLogicalSnapshot, after: PagedNativeLogicalSnapshot,
    start: UInt64, removed: UInt64, inserted: UInt64, following pending: UUID?) {
    guard failure == nil else { return }
    guard rootID == before.rootID, before.sessionID == identity.sessionID,
      after.sessionID == identity.sessionID, before.sourceRevision.documentID == identity.documentID,
      after.sourceRevision.documentID == identity.documentID, start <= before.summary.utf16,
      removed <= before.summary.utf16 - start, inserted <= UInt64.max - (before.summary.utf16 - removed),
      after.summary.utf16 == before.summary.utf16 - removed + inserted,
      selection.utf16Offset <= before.summary.utf16,
      selection.utf16Length <= before.summary.utf16 - selection.utf16Offset else {
      failure = BoomError.stale("Queued native input has no exact accepted source splice."); return
    }
    let lower = selection.utf16Offset, upper = lower + selection.utf16Length, end = start + removed
    if implicitRange, let pendingID, pendingID == pending,
      lower >= start, upper <= end {
      // A later implicit callback of this SAME conversion follows the actual
      // earlier delivery. This is its accepted splice, never the newest caret.
      selection = PagedNativeNavigationSelection(utf16Offset: start + inserted, utf16Length: 0,
        focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
    } else {
      guard lower == upper || !(start < upper && end > lower || inserted > 0 && start > lower && start < upper) else {
        failure = BoomError.stale("An intervening accepted edit overlaps queued native input."); return
      }
      func map(_ point: UInt64, afterInsertion: Bool) -> UInt64 {
        if point < start { return point }
        if point > end { return point - removed + inserted }
        if removed > 0, point == end { return start + inserted }
        return start + (afterInsertion ? inserted : 0)
      }
      let lo = map(lower, afterInsertion: true), hi = map(upper, afterInsertion: lower == upper)
      selection = PagedNativeNavigationSelection(utf16Offset: min(lo, hi), utf16Length: max(lo, hi) - min(lo, hi),
        focusAtEnd: selection.focusAtEnd, affinity: selection.affinity)
    }
    rootID = after.rootID
  }
}

@MainActor final class PagedNativeTextInputClient: NSObject, @MainActor NSTextInputClient {
  let identity: PagedNativeDocumentInputIdentity
  private enum State: Equatable { case unbound, bound, retired }
  private var state = State.unbound
  private weak var sourceView: PagedNativeTextView?
  private var contextWasConstructed = false
  private var lastReportedRootID: UUID?
  private var lastReportedSelection: PagedNativeNavigationSelection?
  private struct PendingSelection {
    let id: UUID
    let reported: PagedNativeNavigationSelection
    let originalRootID: UUID
    var mapped: PagedNativeNavigationSelection
    var rootID: UUID
    var failure: Error?
    init(id: UUID = UUID(), reported: PagedNativeNavigationSelection, mapped: PagedNativeNavigationSelection, rootID: UUID) {
      self.id = id; self.reported = reported; self.mapped = mapped
      originalRootID = rootID; self.rootID = rootID
    }
  }
  private var pendingSelection: PendingSelection?
  private var nativeEventDepth = 0
  private var receivedInsertion = false
  private var receivedCommand = false
  private var continuationAcceptance: (() -> Void)?
  var needsSpliceObservation: Bool { pendingSelection != nil && nativeEventDepth == 0 }
  var isInterpretingNativeEvent: Bool { nativeEventDepth > 0 }

  /// This encloses ACTUAL Cocoa interpretation, never a speculative attempt
  /// followed by replay. A no-output event keeps its document context/anchor.
  func withNativeEvent(_ operation: () -> Void) {
    guard let view = activeSource(), let owner = view.inputBinding?.owner else { operation(); return }
    let outer = nativeEventDepth == 0
    let olderConversion = pendingSelection?.id
    if outer {
      receivedInsertion = false; receivedCommand = false
      lastReportedRootID = owner.session.logicalWindow.snapshot.rootID
      if pendingSelection == nil, !view.hasMarkedText(), let selected = try? owner.currentDocumentSelection() {
        pendingSelection = PendingSelection(reported: selected, mapped: selected,
          rootID: owner.session.logicalWindow.snapshot.rootID)
      }
    }
    let ephemeral = outer && olderConversion == nil ? pendingSelection?.id : nil
    let storage = view.boundedStorage, previous = view.boundedStorage.didAcceptNativePrimitive
    let originalPending = pendingSelection?.id
    storage.didAcceptNativePrimitive = { [weak self] in
      previous?()
      if let originalPending { self?.acceptedDelivery(originalPending) }
    }
    nativeEventDepth += 1
    defer {
      storage.didAcceptNativePrimitive = previous
      nativeEventDepth -= 1
      if outer, receivedInsertion || view.hasMarkedText() { pendingSelection = nil }
      else if outer, receivedCommand, let ephemeral, pendingSelection?.id == ephemeral {
        // This event actually produced/delivered a selector. Its temporary
        // interpretation range is not an older opaque conversion anchor.
        pendingSelection = nil
      }
    }
    operation()
  }

  /// The existing Session subscription supplies the exact accepted splice.
  /// Normal synchronous text input needs no additional snapshot or edit log.
  func mapPendingSelection(before: PagedNativeLogicalSnapshot, after: PagedNativeLogicalSnapshot,
    start: UInt64, removed: UInt64, inserted: UInt64) {
    guard nativeEventDepth == 0, var pending = pendingSelection else { return }
    defer { pendingSelection = pending }
    guard pending.failure == nil else { return }
    let remaining = before.summary.utf16.subtractingReportingOverflow(removed)
    let extent = remaining.partialValue.addingReportingOverflow(inserted)
    guard pending.rootID == before.rootID, before.sessionID == identity.sessionID,
      after.sessionID == identity.sessionID, before.sourceRevision.documentID == identity.documentID,
      after.sourceRevision.documentID == identity.documentID, start <= before.summary.utf16,
      removed <= before.summary.utf16 - start, !remaining.overflow, !extent.overflow,
      after.summary.utf16 == extent.partialValue else {
      pending.failure = BoomError.stale("Pending native input has no actual source splice."); return
    }
    let lower = pending.mapped.utf16Offset
    let rangeEnd = lower.addingReportingOverflow(pending.mapped.utf16Length)
    guard !rangeEnd.overflow, rangeEnd.partialValue <= before.summary.utf16 else {
      pending.failure = BoomError.stale("Pending native input exceeds its actual source range."); return
    }
    let upper = rangeEnd.partialValue, end = start + removed
    if lower < upper, (start < upper && end > lower || inserted > 0 && start > lower && start < upper) {
      pending.failure = BoomError.stale("An accepted edit overlaps a pending native replacement."); return
    }
    func map(_ point: UInt64, afterInsertion: Bool) -> UInt64 {
      if point < start { return point }
      if point > end { return point - removed + inserted }
      if removed > 0, point == end { return start + inserted }
      return start + (afterInsertion ? inserted : 0)
    }
    // A later insertion at a pending caret stays after the earlier input.
    // Affinity/direction never substitute for this chronological gravity.
    let collapsed = lower == upper
    let mappedLower = map(lower, afterInsertion: !collapsed)
    let mappedUpper = map(upper, afterInsertion: false)
    pending.mapped = PagedNativeNavigationSelection(utf16Offset: min(mappedLower, mappedUpper),
      utf16Length: max(mappedLower, mappedUpper) - min(mappedLower, mappedUpper),
      focusAtEnd: pending.mapped.focusAtEnd, affinity: pending.mapped.affinity)
    pending.rootID = after.rootID
  }

  // One genuinely stable process-lifetime association key. Never replace it,
  // reuse its address, or remove the association while its context survives.
  // No per-context table and no destructor/class-cluster assumptions.
  private static let contextClientKey: UnsafeRawPointer = {
    UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
  }()

  init(identity: PagedNativeDocumentInputIdentity) { self.identity = identity; super.init() }

  var isRetired: Bool { state == .retired }

  func bindOnce(to view: PagedNativeTextView) {
    precondition(state == .unbound && view.inputBinding?.identity.ownerID == identity.ownerID
      && view.session.sessionID == identity.sessionID
      && view.session.logicalWindow.snapshot.sourceRevision.documentID == identity.documentID)
    sourceView = view
    lastReportedRootID = view.session.logicalWindow.snapshot.rootID
    state = .bound
  }

  func makeContext() -> NSTextInputContext {
    precondition(state == .bound && sourceView != nil && !contextWasConstructed)
    return constructContext()
  }

  private func constructContext() -> NSTextInputContext {
    precondition(!contextWasConstructed)
    contextWasConstructed = true
    // NSTextInputContext explicitly does not retain its client. The method's
    // receiver is alive during construction; after construction the context's
    // associated object supplies the required client lifetime.
    let context = NSTextInputContext(client: self)
    objc_setAssociatedObject(context, Self.contextClientKey, self,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return context
  }

  func retire() {
    precondition(sourceView == nil || sourceView?.inputBinding?.state == .retired)
    state = .retired
    pendingSelection = nil; lastReportedRootID = nil; lastReportedSelection = nil
    sourceView = nil
  }

  private func activeSource() -> PagedNativeTextView? {
    guard state == .bound, let view = sourceView,
      let binding = view.inputBinding, binding.state == .active, let owner = binding.owner,
      binding.identity == owner.activeIdentity,
      owner.ownerID == identity.ownerID, owner.session.sessionID == identity.sessionID,
      owner.session.logicalWindow.snapshot.sourceRevision.documentID == identity.documentID,
      !owner.isAdopting, owner.firstRefusal == nil,
      view.boundedStorage.mutationFailure == nil else { return nil }
    return view
  }

  private static let absentRange = NSRange(location: NSNotFound, length: 0)

  private func callbackSource() -> PagedNativeTextView? {
    // This SAME live document context is the authority for asynchronous native
    // continuation. Focus/arena retirement is not a callback completion signal.
    activeSource()
  }

  /// Convert only an actual scalar-admitted resident range. Never relabel the
  /// mounted substring as the complete document or clamp replacement endpoints.
  private func localRange(_ range: NSRange, in view: PagedNativeTextView,
    intersecting: Bool = false) -> NSRange? {
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
      let coordinates = try? view.session.documentCoordinates() else { return nil }
    let end = range.location.addingReportingOverflow(range.length)
    guard !end.overflow, UInt64(end.partialValue) <= coordinates.projectedUTF16,
      let start = Int(exactly: coordinates.utf16Start) else { return nil }
    let windowEnd = start.addingReportingOverflow(coordinates.localUTF16)
    guard !windowEnd.overflow else { return nil }
    let lower = intersecting ? max(start, range.location) : range.location
    let upper = intersecting ? min(windowEnd.partialValue, end.partialValue) : end.partialValue
    guard lower >= start, upper >= lower, upper <= windowEnd.partialValue else { return nil }
    let local = NSRange(location: lower - start, length: upper - lower)
    guard (try? view.session.navigationSelection(local)) != nil else { return nil }
    return local
  }

  private func globalRange(_ local: NSRange, in view: PagedNativeTextView) -> NSRange {
    guard local.location >= 0, local.location != NSNotFound, local.length >= 0,
      let coordinates = try? view.session.documentCoordinates(),
      let start = Int(exactly: coordinates.utf16Start) else { return Self.absentRange }
    let end = local.location.addingReportingOverflow(local.length)
    let origin = start.addingReportingOverflow(local.location)
    guard !end.overflow, end.partialValue <= coordinates.localUTF16, !origin.overflow else { return Self.absentRange }
    return NSRange(location: origin.partialValue, length: local.length)
  }

  private func callbackRange(_ requested: NSRange, in view: PagedNativeTextView) throws -> NSRange {
    if view.hasMarkedText() {
      return requested.location == NSNotFound ? markedRange() : requested
    }
    if let pending = pendingSelection {
      if let failure = pending.failure { throw failure }
      guard pending.rootID == view.session.logicalWindow.snapshot.rootID else {
        throw BoomError.stale("Pending native input needs its actual logical operation transform.")
      }
      guard let reportedStart = Int(exactly: pending.reported.utf16Offset),
        let reportedLength = Int(exactly: pending.reported.utf16Length) else {
        throw BoomError.budget("Reported native input exceeds Cocoa's coordinate range.")
      }
      let reported = NSRange(location: reportedStart, length: reportedLength)
      if requested.location == NSNotFound || requested == reported {
        guard let start = Int(exactly: pending.mapped.utf16Offset), let length = Int(exactly: pending.mapped.utf16Length) else {
          throw BoomError.budget("Pending native input exceeds Cocoa's coordinate range.")
        }
        return NSRange(location: start, length: length)
      }
    }
    return requested.location == NSNotFound ? selectedRange() : requested
  }

  private func retainUnmapped(_ original: Any, range: NSRange,
    kind: PagedNativeContextContinuation.Kind, error: Error, in view: PagedNativeTextView) {
    if continuationAcceptance != nil { view.didRejectInput?(error); return }
    // These callbacks failed before admission. Preserve bounded diagnostics;
    // admitted final callbacks live in the real queue, never this disposition.
    guard let commands = view.inputBinding?.owner?.commandOwner else { view.didRejectInput?(error); return }
    do {
      let continuation = try captureContinuation(original, range: range, kind: kind, in: view)
      try commands.retainRejectedContextContinuation(continuation, refusal: error)
    } catch { view.didRejectInput?(error) }
  }

  private func captureContinuation(_ original: Any, range: NSRange,
    kind: PagedNativeContextContinuation.Kind, in view: PagedNativeTextView) throws -> PagedNativeContextContinuation {
    guard let commands = view.inputBinding?.owner?.commandOwner else {
      throw BoomError.stale("The native callback lost its actual input owner.")
    }
    let payload = try PagedNativeContextPayload(original)
    if case .marked(let selected) = kind { try Self.validateMarkedSelection(selected, text: payload.text) }
    try commands.admitContextContinuation(identity: identity, chargedBytes: payload.chargedBytes)
    let rootID: UUID, selected: PagedNativeNavigationSelection
    if let pending = pendingSelection {
      if let error = pending.failure { throw error }
      rootID = pending.rootID
      if range.location == NSNotFound { selected = pending.mapped }
      else {
        guard range.location >= 0, range.length >= 0 else { throw BoomError.invalid("Native callback has a negative range.") }
        let requested = PagedNativeNavigationSelection(utf16Offset: UInt64(range.location), utf16Length: UInt64(range.length))
        if requested.utf16Offset == pending.reported.utf16Offset && requested.utf16Length == pending.reported.utf16Length {
          selected = pending.mapped
        } else {
          guard pending.originalRootID == pending.rootID else {
            throw BoomError.stale("Surrounding native input needs its original source transform.")
          }
          selected = requested
        }
      }
    } else if view.inputBinding?.owner?.isAdopting == true {
      // A pure window rotation can report an asynchronous callback without
      // an older conversion. Use only the actual range this context saw on
      // the SAME immutable root, never the half-installed UI caret.
      guard lastReportedRootID == view.session.logicalWindow.snapshot.rootID,
        let reported = lastReportedSelection else {
        throw BoomError.stale("An adopting native callback needs its actual previously reported source range.")
      }
      rootID = view.session.logicalWindow.snapshot.rootID
      if range.location == NSNotFound { selected = reported }
      else {
        guard range.location >= 0, range.length >= 0 else { throw BoomError.invalid("Native callback has a negative range.") }
        selected = PagedNativeNavigationSelection(utf16Offset: UInt64(range.location), utf16Length: UInt64(range.length))
      }
      guard selected.utf16Offset <= view.session.logicalWindow.snapshot.summary.utf16,
        selected.utf16Length <= view.session.logicalWindow.snapshot.summary.utf16 - selected.utf16Offset else {
        throw BoomError.invalid("The native callback exceeds its actually reported source.")
      }
      pendingSelection = PendingSelection(reported: selected, mapped: selected, rootID: rootID)
    } else {
      guard let current = activeSource(), current === view else {
        throw BoomError.stale("The native callback lost its actual live document source.")
      }
      rootID = view.session.logicalWindow.snapshot.rootID
      let actual = try callbackRange(range, in: view)
      _ = try prepareDelivery(actual, in: view)
      selected = pendingSelection!.mapped
    }
    let copied = try payload.materialize()
    return PagedNativeContextContinuation(identity: identity, pendingID: pendingSelection?.id, rootID: rootID,
      selection: selected, implicitRange: range.location == NSNotFound, text: copied,
      kind: kind, chargedBytes: payload.chargedBytes)
  }

  private func deferDuringAdoption(_ original: Any, range: NSRange,
    kind: PagedNativeContextContinuation.Kind) -> Bool {
    guard state == .bound, let view = sourceView, let owner = view.inputBinding?.owner,
      owner.ownerID == identity.ownerID, owner.session.sessionID == identity.sessionID,
      let commands = owner.commandOwner,
      owner.isAdopting || commands.requiresOrderedContextDelivery else { return false }
    do {
      let continuation = try captureContinuation(original, range: range, kind: kind, in: view)
      try commands.enqueueContextContinuation(continuation)
    } catch { view.didRejectInput?(error) }
    return true
  }

  /// The same owner calls this only for the admitted queue head after its
  /// preceding real source/window transition joined. No focus is stolen.
  func deliver(_ continuation: PagedNativeContextContinuation, accepted: @escaping () -> Void) throws {
    guard continuation.identity == identity, let view = activeSource(),
      continuation.rootID == view.session.logicalWindow.snapshot.rootID,
      continuationAcceptance == nil else {
      throw BoomError.stale("Ordered native delivery lost its original document/source.")
    }
    if let error = continuation.failure { throw error }
    guard continuation.selection.utf16Offset <= UInt64(Int.max),
      continuation.selection.utf16Length <= UInt64(Int.max) else {
      throw BoomError.budget("Native delivery exceeds AppKit coordinates.")
    }
    let selection = continuation.selection
    let range = NSRange(location: Int(selection.utf16Offset), length: Int(selection.utf16Length))
    let root = view.session.logicalWindow.snapshot
    guard selection.utf16Offset <= root.summary.utf16,
      selection.utf16Length <= root.summary.utf16 - selection.utf16Offset else {
      throw BoomError.stale("Ordered native delivery exceeds its actual source.")
    }
    // The final queue head owns this range. An older conversion's pending
    // range is not rebased to the UI caret, nor used to retarget this head.
    if let old = pendingSelection, old.id != continuation.pendingID {
      throw BoomError.stale("Another native conversion still owns the document input anchor.")
    }
    var pending = pendingSelection ?? PendingSelection(id: continuation.pendingID ?? UUID(),
      reported: selection, mapped: selection, rootID: root.rootID)
    if let failure = pending.failure { throw failure }
    pending.mapped = selection; pending.rootID = root.rootID
    pendingSelection = pending
    let previous = continuationAcceptance
    continuationAcceptance = accepted
    defer { continuationAcceptance = previous }
    switch continuation.kind {
    case .insert: insertText(continuation.text, replacementRange: range)
    case .marked(let selected): setMarkedText(continuation.text, selectedRange: selected, replacementRange: range)
    case .command(let selector):
      guard let owner = view.inputBinding?.owner,
        try owner.currentDocumentSelection() == selection else {
        throw BoomError.stale("Ordered native selector needs its exact preceding selection.")
      }
      doCommand(by: selector)
      acceptedDelivery(pending.id)
    case .unmark:
      unmarkText()
      if !view.hasMarkedText() { pendingSelection = nil; accepted() }
    }
  }

  private func prepareDelivery(_ range: NSRange, in view: PagedNativeTextView) throws -> UUID {
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0 else {
      throw BoomError.invalid("Native input has no actual global replacement range.")
    }
    let end = range.location.addingReportingOverflow(range.length)
    let root = view.session.logicalWindow.snapshot
    guard !end.overflow, UInt64(end.partialValue) <= root.summary.utf16 else {
      throw BoomError.invalid("Native input exceeds its current logical source.")
    }
    let actual = PagedNativeNavigationSelection(utf16Offset: UInt64(range.location), utf16Length: UInt64(range.length))
    let window = view.session.logicalWindow
    let windowEnd = window.start.utf16 + window.summary.utf16
    var endpointsProven = true
    for endpoint in [actual.utf16Offset, UInt64(end.partialValue)] {
      if endpoint >= window.start.utf16, endpoint <= windowEnd {
        _ = try window.position(localUTF16: Int(endpoint - window.start.utf16))
      } else if endpoint != 0 && endpoint != root.summary.utf16 { endpointsProven = false }
    }
    if var pending = pendingSelection {
      if let error = pending.failure { throw error }
      guard pending.rootID == root.rootID else { throw BoomError.stale("Native input still needs its original source transform.") }
      if pending.mapped.utf16Offset != actual.utf16Offset || pending.mapped.utf16Length != actual.utf16Length {
        // Explicit surrounding-text replacement is valid on the originally
        // reported root. No old explicit range is relabeled after a transform.
        guard pending.originalRootID == root.rootID, endpointsProven else {
          throw BoomError.stale("Native surrounding-text input needs its original range transform.")
        }
        pending.mapped = actual; pendingSelection = pending
      }
      return pending.id
    }
    let pending = PendingSelection(reported: actual, mapped: actual, rootID: root.rootID)
    pendingSelection = pending; return pending.id
  }
  private func deliverySelection(_ id: UUID) throws -> PagedNativeNavigationSelection {
    guard let view = activeSource(), let pending = pendingSelection, pending.id == id,
      pending.rootID == view.session.logicalWindow.snapshot.rootID else {
      throw BoomError.stale("The accepted native continuation lost its exact mapped source range.")
    }
    if let failure = pending.failure { throw failure }
    return pending.mapped
  }
  private func acceptedDelivery(_ id: UUID, acknowledging completion: (() -> Void)? = nil) {
    let ownsPending = pendingSelection?.id == id
    if ownsPending { receivedInsertion = true; pendingSelection = nil }
    // A real installed producer may finish after native unmark/completion.
    // Its own retained acknowledgement cannot depend on mutable preview state.
    if let completion { completion() }
    else if ownsPending { continuationAcceptance?() }
  }

  func insertText(_ original: Any, replacementRange: NSRange) {
    if deferDuringAdoption(original, range: replacementRange, kind: .insert) { return }
    guard let view = callbackSource(), let owner = view.inputBinding?.owner else { return }
    do {
      guard let text = (original as? String) ?? (original as? NSAttributedString)?.string else {
        throw BoomError.invalid("Native input is neither text nor attributed text.")
      }
      let replacement = try callbackRange(replacementRange, in: view)
      let local = localRange(replacement, in: view)
      guard local != nil || !view.hasMarkedText() else { throw BoomError.stale("A marked replacement left its actual resident text.") }
      let delivery = try prepareDelivery(replacement, in: view)
      let originalAcknowledgement = continuationAcceptance
      var acknowledgedOnce = false
      let acknowledged: (() -> Void)? = originalAcknowledgement.map { completion in
        { guard !acknowledgedOnce else { return }; acknowledgedOnce = true; completion() }
      }
      view.supersedeDeferredDocumentMarkedText(pendingID: delivery)
      owner.withDocumentContextCallback {
        view.withDocumentContextMutation(selecting: { [weak self] in
          guard let self else { throw BoomError.stale("The original native context retired before its accepted insertion.") }
          return try self.deliverySelection(delivery)
        }, accepted: { [weak self] in
          self?.acceptedDelivery(delivery, acknowledging: acknowledged)
        }) {
          if let local { view.insertText(original, replacementRange: local) }
          else {
            view.insertDocumentText(text, replacing: PagedNativeNavigationSelection(
              utf16Offset: UInt64(replacement.location), utf16Length: UInt64(replacement.length)))
          }
        }
      }
    } catch { retainUnmapped(original, range: replacementRange, kind: .insert, error: error, in: view) }
  }

  func doCommand(by selector: Selector) {
    if deferDuringAdoption("", range: Self.absentRange, kind: .command(selector)) { return }
    guard let view = callbackSource(), let owner = view.inputBinding?.owner else { return }
    if let pending = pendingSelection {
      do {
        let actual = try deliverySelection(pending.id)
        guard actual == (try owner.currentDocumentSelection()) else {
          throw BoomError.stale("A native selector needs its original mapped selection, not the newer UI caret.")
        }
      } catch { retainUnmapped("", range: Self.absentRange, kind: .command(selector), error: error, in: view); return }
    }
    // A selector is not evidence that the native context cancelled its
    // earlier conversion. Actual unmark/accepted insertion ends that anchor.
    owner.withDocumentContextCallback {
      view.doCommand(by: selector)
      receivedCommand = true
    }
  }

  private static func validateMarkedSelection(_ selected: NSRange, text: String) throws {
    guard selected.location >= 0, selected.location != NSNotFound, selected.length >= 0 else {
      throw BoomError.invalid("Marked selection has no actual native range.")
    }
    let end = selected.location.addingReportingOverflow(selected.length)
    guard !end.overflow, end.partialValue <= text.utf16.count,
      String.Index(text.utf16.index(text.utf16.startIndex, offsetBy: selected.location), within: text) != nil,
      String.Index(text.utf16.index(text.utf16.startIndex, offsetBy: end.partialValue), within: text) != nil else {
      throw BoomError.invalid("Marked selection splits or exceeds the native text.")
    }
  }

  func setMarkedText(_ original: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if deferDuringAdoption(original, range: replacementRange, kind: .marked(selectedRange)) { return }
    guard let view = callbackSource(), let owner = view.inputBinding?.owner else { return }
    do {
      guard let text = (original as? String) ?? (original as? NSAttributedString)?.string else {
        throw BoomError.invalid("Marked input is neither text nor attributed text.")
      }
      try Self.validateMarkedSelection(selectedRange, text: text)
      let replacement = try callbackRange(replacementRange, in: view)
      let local = localRange(replacement, in: view)
      guard local != nil || !view.hasMarkedText() && text.utf8.count <= PagedWorkingWindow.hardBytes else {
        throw BoomError.budget("The marked replacement needs its actual bounded resident range.")
      }
      let delivery = try prepareDelivery(replacement, in: view)
      if local == nil, try view.deferDocumentMarkedText(original, pendingID: delivery, selected: selectedRange, replacement: replacement) { return }
      owner.withDocumentContextCallback {
        view.withDocumentContextMutation(selecting: { [weak self] in
          guard let self else { throw BoomError.stale("The original marked context retired before delivery.") }
          return try self.deliverySelection(delivery)
        }, accepted: { [weak self] in self?.acceptedDelivery(delivery) }) {
          if let local { view.setMarkedText(original, selectedRange: selectedRange, replacementRange: local) }
          else {
            do {
              guard let commands = owner.commandOwner,
                try commands.prepareResidentCompositionSelection(self.deliverySelection(delivery)) else {
                throw BoomError.unavailable("Composition needs its exact resident logical range.")
              }
              // The actual structural deletion joined. Its original full
              // selection is held by the same native Undo group; only the
              // actual SDK marked primitive can acknowledge this preview.
              let collapsed = PagedNativeNavigationSelection(utf16Offset: UInt64(replacement.location), utf16Length: 0)
              guard try owner.currentDocumentSelection() == collapsed,
                var pending = self.pendingSelection, pending.id == delivery else {
                throw BoomError.stale("Prepared composition lost its actual installed replacement cursor.")
              }
              pending.mapped = collapsed; pending.rootID = view.session.logicalWindow.snapshot.rootID
              pending.failure = nil; self.pendingSelection = pending
              view.setMarkedText(original, selectedRange: selectedRange,
                replacementRange: NSRange(location: NSNotFound, length: 0))
            } catch { view.didRejectInput?(error) }
          }
        }
      }
      if view.hasMarkedText() { acceptedDelivery(delivery) }
    } catch { retainUnmapped(original, range: replacementRange, kind: .marked(selectedRange), error: error, in: view) }
  }

  func unmarkText() {
    if deferDuringAdoption("", range: Self.absentRange, kind: .unmark) { return }
    guard let view = callbackSource() else { return }
    view.inputBinding?.owner?.withDocumentContextCallback { view.unmarkText() }
    if !view.hasMarkedText() { pendingSelection = nil }
  }

  func selectedRange() -> NSRange {
    guard let view = activeSource(), let owner = view.inputBinding?.owner else { return Self.absentRange }
    let selected: PagedNativeNavigationSelection
    if !view.hasMarkedText(), let pending = pendingSelection {
      guard pending.failure == nil, pending.rootID == view.session.logicalWindow.snapshot.rootID else { return Self.absentRange }
      selected = pending.mapped
    } else {
      guard let current = try? owner.currentDocumentSelection() else { return Self.absentRange }
      selected = current
    }
    guard let location = Int(exactly: selected.utf16Offset), let length = Int(exactly: selected.utf16Length) else { return Self.absentRange }
    lastReportedRootID = view.session.logicalWindow.snapshot.rootID
    lastReportedSelection = selected
    return NSRange(location: location, length: length)
  }
  func markedRange() -> NSRange {
    guard let view = activeSource() else { return Self.absentRange }
    return globalRange(view.markedRange(), in: view)
  }
  func hasMarkedText() -> Bool { activeSource()?.hasMarkedText() ?? false }

  func attributedSubstring(forProposedRange range: NSRange,
    actualRange: NSRangePointer?) -> NSAttributedString? {
    guard let view = activeSource(), let local = localRange(range, in: view, intersecting: true) else {
      actualRange?.pointee = Self.absentRange; return nil
    }
    var actual = Self.absentRange
    let text = view.attributedSubstring(forProposedRange: local, actualRange: &actual)
    actualRange?.pointee = text == nil ? Self.absentRange : globalRange(actual, in: view)
    return text
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    guard state == .bound, let view = sourceView, view.inputBinding?.state != .retired else { return [] }
    return view.validAttributesForMarkedText()
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let view = activeSource(), let local = localRange(range, in: view, intersecting: true) else {
      actualRange?.pointee = Self.absentRange; return .zero
    }
    var actual = Self.absentRange
    let rect = view.firstRect(forCharacterRange: local, actualRange: &actual)
    actualRange?.pointee = globalRange(actual, in: view)
    return rect
  }

  func characterIndex(for point: NSPoint) -> Int {
    guard let view = activeSource() else { return NSNotFound }
    return globalRange(NSRange(location: view.characterIndex(for: point), length: 0), in: view).location
  }

  // Preserve the real NSTextView's optional geometry without advertising the
  // optional whole-document attributedString operation on this paged client.
  func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat {
    guard let view = activeSource() else { return 0 }
    let client: any NSTextInputClient = view
    return client.fractionOfDistanceThroughGlyph?(for: point) ?? 0
  }

  func baselineDeltaForCharacter(at index: Int) -> CGFloat {
    guard let view = activeSource() else { return 0 }
    guard let local = localRange(NSRange(location: index, length: 0), in: view) else { return 0 }
    let client: any NSTextInputClient = view
    return client.baselineDeltaForCharacter?(at: local.location) ?? 0
  }

  func windowLevel() -> Int {
    guard let view = activeSource() else { return NSWindow.Level.normal.rawValue }
    let client: any NSTextInputClient = view
    return client.windowLevel?() ?? view.window?.level.rawValue ?? NSWindow.Level.normal.rawValue
  }

  func drawsVerticallyForCharacter(at index: Int) -> Bool {
    guard let view = activeSource() else { return false }
    guard let local = localRange(NSRange(location: index, length: 0), in: view) else { return false }
    let client: any NSTextInputClient = view
    return client.drawsVerticallyForCharacter?(at: local.location) ?? false
  }

  func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement {
    guard let view = activeSource() else { return .invisible }
    let client: any NSTextInputClient = view
    return client.preferredTextAccessoryPlacement?() ?? .unspecified
  }

  var unionRectInVisibleSelectedRange: NSRect {
    guard let view = activeSource() else { return .zero }
    let client: any NSTextInputClient = view
    return client.unionRectInVisibleSelectedRange
      ?? view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
  }

  var documentVisibleRect: NSRect {
    guard let view = activeSource() else { return .zero }
    let client: any NSTextInputClient = view
    if let rect = client.documentVisibleRect { return rect }
    guard let window = view.window else { return .zero }
    return window.convertToScreen(view.convert(view.visibleRect, to: nil))
  }
}
