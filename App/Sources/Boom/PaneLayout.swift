import AppKit
import SwiftUI

/// Native resize handles without decorative separator rules.
struct PaneLayout: NSViewRepresentable {
  struct Pane {
    let id: String
    let content: AnyView
    let minimum: CGFloat
    let preferred: CGFloat
    let maximum: CGFloat
  }
  let panes: [Pane]
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> ShadeSplitView {
    let view = ShadeSplitView()
    view.isVertical = true
    view.delegate = context.coordinator
    return view
  }
  func updateNSView(_ view: ShadeSplitView, context: Context) {
    context.coordinator.update(panes, in: view)
  }

  @MainActor final class ShadeSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
  }
  @MainActor final class Coordinator: NSObject, NSSplitViewDelegate {
    var panes: [Pane] = []
    var hosts: [String: NSHostingView<AnyView>] = [:]
    private var updatingPanes = false

    func update(_ next: [Pane], in view: ShadeSplitView) {
      guard panes.map(\.id) != next.map(\.id) else { return }
      precondition(Set(next.map(\.id)).count == next.count, "Pane identities must be unique.")
      updatingPanes = true
      panes = next
      let retained = Set(next.map(\.id))
      // Detaching a focused host gives its first responder back to NSWindow.
      // Keep every surviving pane attached, including its native editor/Undo.
      for (id, host) in hosts where !retained.contains(id) && host.superview === view {
        host.removeFromSuperview()
      }
      for pane in next {
        let host = hosts[pane.id] ?? NSHostingView(rootView: AnyView(
          pane.content.environment(\.openURL, OpenURLAction { _ in .discarded })))
        hosts[pane.id] = host
        if host.superview !== view {
          host.frame.size.width = pane.preferred
          view.addSubview(host)
        }
      }
      // Reorder the existing siblings without removing them from the window.
      // AppKit borrows this comparator/context only for the synchronous sort.
      var order = Dictionary(uniqueKeysWithValues: next.enumerated().map {
        (ObjectIdentifier(hosts[$0.element.id]!), $0.offset)
      })
      withUnsafeMutablePointer(to: &order) { pointer in
        view.sortSubviews({ left, right, context in
          guard let context else { return .orderedSame }
          let order = context.assumingMemoryBound(to: [ObjectIdentifier: Int].self).pointee
          guard let a = order[ObjectIdentifier(left)], let b = order[ObjectIdentifier(right)] else {
            return .orderedSame
          }
          return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }, context: pointer)
      }
      updatingPanes = false
      view.adjustSubviews()
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
      guard !updatingPanes, !panes.isEmpty, panes.count == splitView.subviews.count else { return }
      let flexible = panes.firstIndex { $0.maximum == .infinity } ?? panes.count - 1
      var widths = zip(panes, splitView.subviews).map { pane, view in
        min(pane.maximum, max(pane.minimum, view.frame.width))
      }
      let delta = splitView.bounds.width - widths.reduce(0, +)
      widths[flexible] += delta
      if widths[flexible] < panes[flexible].minimum {
        var deficit = panes[flexible].minimum - widths[flexible]
        widths[flexible] = panes[flexible].minimum
        for i in widths.indices where i != flexible {
          let released = min(deficit, max(0, widths[i] - panes[i].minimum))
          widths[i] -= released; deficit -= released
        }
      }
      var x: CGFloat = 0
      for (view, width) in zip(splitView.subviews, widths) {
        view.frame = NSRect(x: x, y: 0, width: max(0, width), height: splitView.bounds.height)
        x += width
      }
    }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
      forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
      drawnRect.insetBy(dx: -4, dy: 0)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
      ofSubviewAt dividerIndex: Int) -> CGFloat {
      splitView.subviews[dividerIndex].frame.minX + panes[dividerIndex].minimum
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
      ofSubviewAt dividerIndex: Int) -> CGFloat {
      splitView.subviews[dividerIndex + 1].frame.maxX - panes[dividerIndex + 1].minimum
    }
  }
}
