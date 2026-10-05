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
    let coordinator = context.coordinator
    guard coordinator.panes.map(\.id) != panes.map(\.id) else { return }
    coordinator.panes = panes
    // Keep existing native editors and their first responder/Undo state.
    for child in view.subviews { child.removeFromSuperview() }
    for pane in panes {
      let host = coordinator.hosts[pane.id] ?? NSHostingView(rootView: AnyView(pane.content.environment(\.openURL, OpenURLAction { _ in .discarded })))
      coordinator.hosts[pane.id] = host
      host.frame.size.width = pane.preferred
      view.addSubview(host)
    }
    view.adjustSubviews()
  }
  @MainActor final class ShadeSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
  }
  @MainActor final class Coordinator: NSObject, NSSplitViewDelegate {
    var panes: [Pane] = []
    var hosts: [String: NSHostingView<AnyView>] = [:]
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
      guard !panes.isEmpty else { return }
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
