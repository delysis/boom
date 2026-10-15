import AppKit
import QuartzCore

/// Keep native text drawing synchronous without replacing AppKit's backing
/// layers, glyph renderer, pixel format, or embedded media views. The measured
/// deferred text-content drawing activates a Metal path
/// with a roughly 240 MiB graphics footprint even for a small plain document.
@MainActor final class NativeTextDrawing {
  private var backingObservation: NSKeyValueObservation?
  private var contentObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

  init(backing: CALayer) {
    // AppKit creates content layers after viewWillDraw and can enable deferred
    // drawing after attaching them. Observe both events before the first draw.
    backingObservation = backing.observe(\.sublayers, options: [.initial, .new]) { [weak self] layer, _ in
      // AppKit mutates a view's layer tree synchronously on the main thread.
      MainActor.assumeIsolated { self?.observeContent(in: layer) }
    }
  }

  private func observeContent(in backing: CALayer) {
    // A child view's backing layer has its own delegate. Leave that layer and
    // its entire subtree alone, including image/video renderers and the caret.
    let content = (backing.sublayers ?? []).filter { $0.delegate == nil }
    let retained = Set(content.map(ObjectIdentifier.init))
    contentObservations = contentObservations.filter { retained.contains($0.key) }
    for layer in content where contentObservations[ObjectIdentifier(layer)] == nil {
      contentObservations[ObjectIdentifier(layer)] = layer.observe(\.drawsAsynchronously,
        options: [.initial, .new]) { layer, _ in
        MainActor.assumeIsolated {
          if layer.delegate == nil && layer.drawsAsynchronously {
            layer.drawsAsynchronously = false
          }
        }
      }
    }
  }
}
