import AppKit

/// Diagnostic drag payload. Calls the native destination protocol without
/// moving the human pointer or reading the shared clipboard.
@MainActor final class AttachmentDropFixture: NSObject, @preconcurrency NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  let draggingLocation: NSPoint
  weak var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(board: NSPasteboard, point: NSPoint, window: NSWindow?) {
    draggingPasteboard = board; draggingLocation = point; draggingDestinationWindow = window
  }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
