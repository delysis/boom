import AppKit
import SwiftUI

struct PagedManuscriptView: NSViewRepresentable {
  let viewport: PagedDocumentViewport
  func makeNSView(context: Context) -> PagedDocumentViewport { viewport }
  func updateNSView(_ view: PagedDocumentViewport, context: Context) {
    precondition(view === viewport, "A SwiftUI surface cannot silently retarget another native document owner.")
  }
  static func dismantleNSView(_ view: PagedDocumentViewport, coordinator: ()) {
    // The existing Model joins presentation, input and backend before releasing
    // this graph. Disappearing/hiding a pane is not a storage/root/task join.
  }
}
