import AppKit
import Foundation
import ObjectiveC

/// One input context's permanent physical source. A retained old context owns
/// this small client; the client never owns a view, session, text storage,
/// command owner, source payload, continuation, or another context.
@MainActor final class PagedNativeTextInputClient: NSObject, @MainActor NSTextInputClient {
  let identity: PagedNativeInputIdentity
  private enum State: Equatable { case unbound, bound, retired }
  private var state = State.unbound
  private weak var sourceView: PagedNativeTextView?
  private var contextWasConstructed = false

  // One genuinely stable process-lifetime association key. Never replace it,
  // reuse its address, or remove the association while its context survives.
  // No per-context table and no destructor/class-cluster assumptions.
  private static let contextClientKey: UnsafeRawPointer = {
    UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
  }()

  init(identity: PagedNativeInputIdentity) { self.identity = identity; super.init() }

  var isRetired: Bool { state == .retired }

  func bindOnce(to view: PagedNativeTextView) {
    precondition(state == .unbound && view.inputBinding?.identity == identity)
    sourceView = view
    state = .bound
  }

  func makeContext() -> NSTextInputContext {
    precondition(state == .bound && sourceView != nil && !contextWasConstructed)
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
    sourceView = nil
  }

  private func activeSource() -> PagedNativeTextView? {
    guard state == .bound, let view = sourceView,
      let binding = view.inputBinding, binding.identity == identity,
      binding.state == .active, let owner = binding.owner,
      owner.activeIdentity == identity else { return nil }
    // Do not suppress an active source's refusal here. The real view performs
    // the current transaction/arena/command admission with the original input
    // arguments, including during a source-publication refusal.
    return view
  }

  private static let absentRange = NSRange(location: NSNotFound, length: 0)

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard let view = activeSource() else { return }
    withExtendedLifetime(view) { view.insertText(string, replacementRange: replacementRange) }
  }

  func doCommand(by selector: Selector) {
    guard let view = activeSource() else { return }
    withExtendedLifetime(view) { view.doCommand(by: selector) }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard let view = activeSource() else { return }
    withExtendedLifetime(view) {
      view.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
  }

  func unmarkText() {
    guard let view = activeSource() else { return }
    withExtendedLifetime(view) { view.unmarkText() }
  }

  func selectedRange() -> NSRange { activeSource()?.selectedRange() ?? Self.absentRange }
  func markedRange() -> NSRange { activeSource()?.markedRange() ?? Self.absentRange }
  func hasMarkedText() -> Bool { activeSource()?.hasMarkedText() ?? false }

  func attributedSubstring(forProposedRange range: NSRange,
    actualRange: NSRangePointer?) -> NSAttributedString? {
    guard let view = activeSource() else {
      actualRange?.pointee = Self.absentRange
      return nil
    }
    return view.attributedSubstring(forProposedRange: range, actualRange: actualRange)
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    // Context initialization queries this declarative capability before a
    // stage is active. Preserve the same native view's capability list without
    // admitting staged text/range/command access or a new source destination.
    guard state == .bound, let view = sourceView,
      view.inputBinding?.identity == identity, view.inputBinding?.state != .retired else { return [] }
    return view.validAttributesForMarkedText()
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let view = activeSource() else {
      actualRange?.pointee = Self.absentRange
      return .zero
    }
    return view.firstRect(forCharacterRange: range, actualRange: actualRange)
  }

  func characterIndex(for point: NSPoint) -> Int {
    activeSource()?.characterIndex(for: point) ?? NSNotFound
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
    let client: any NSTextInputClient = view
    return client.baselineDeltaForCharacter?(at: index) ?? 0
  }

  func windowLevel() -> Int {
    guard let view = activeSource() else { return NSWindow.Level.normal.rawValue }
    let client: any NSTextInputClient = view
    return client.windowLevel?() ?? view.window?.level.rawValue ?? NSWindow.Level.normal.rawValue
  }

  func drawsVerticallyForCharacter(at index: Int) -> Bool {
    guard let view = activeSource() else { return false }
    let client: any NSTextInputClient = view
    return client.drawsVerticallyForCharacter?(at: index) ?? false
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
