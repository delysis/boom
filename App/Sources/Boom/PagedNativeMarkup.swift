import CAttachment
import Foundation

/// Display-only arrays, bound to an exact immutable logical window. This is
/// neither an editable source nor a saved revision. Incomplete context keeps
/// source punctuation visible and cannot grant media/extension projection.
struct PagedNativeMarkupProjection: Sendable {
  struct Mode: Decodable, Sendable {
    let rootID: UUID
    let windowID: UUID
    let start: PagedTextSummary
    let summary: PagedTextSummary
    let complete: Bool
    let markdown: [MarkdownSpan]
    let media: [InlineMediaSpan]
    let hasWikiMarker: Bool
    let hasAttachmentMarker: Bool
    let trackedReferencePeakBytes: Int
    let maxReferenceCount: Int
    let maxReferenceProbes: Int
    static func literal(_ window: PagedNativeLogicalWindow) -> Mode {
      Mode(rootID: window.snapshot.rootID, windowID: window.windowID, start: window.start,
        summary: window.summary, complete: false, markdown: [], media: [],
        hasWikiMarker: false, hasAttachmentMarker: false, trackedReferencePeakBytes: 0,
        maxReferenceCount: 0, maxReferenceProbes: 0)
    }
    func matches(_ window: PagedNativeLogicalWindow) -> Bool {
      rootID == window.snapshot.rootID && windowID == window.windowID
        && start == window.start && summary == window.summary
    }
  }
  let style: Mode
  let media: Mode
  /// Conservative sum of each mode's measured post-turn retained reference
  /// capacities. This excludes parser temporaries, host caches, allocator
  /// overhead and decoded UI arrays; it is not a full 3MiB peak-memory proof.
  var trackedReferenceCapacityUpperBytes: Int { style.trackedReferencePeakBytes + media.trackedReferencePeakBytes }
  func matches(_ window: PagedNativeLogicalWindow) -> Bool { style.matches(window) && media.matches(window) }
  /// Only actual display content participates: telemetry and global proof
  /// progress may advance without changing any local attributes or media.
  func hasSameDisplay(as other: Self) -> Bool {
    let current = value, previous = other.value
    return current.markdown == previous.markdown && current.media == previous.media
      && current.hasWikiMarker == previous.hasWikiMarker
      && current.hasAttachmentMarker == previous.hasAttachmentMarker
  }
  var value: ProductCore.MarkupProjection {
    ProductCore.MarkupProjection(markdown: style.markdown, media: media.media,
      hasWikiMarker: style.complete && style.hasWikiMarker,
      hasAttachmentMarker: style.complete && media.complete && media.hasAttachmentMarker)
  }
}

/// One existing source-operation lifetime. Release runs only after its actual
/// last read/writer callback joins; the viewport never retains this handle.
final class PagedLogicalMarkupHandle: @unchecked Sendable {
  private var retained: OpaquePointer?
  init(_ pointer: OpaquePointer) { retained = pointer }
  var pointer: OpaquePointer { precondition(retained != nil); return retained! }
  func release() { if let retained { bloom_logical_markup_free(retained); self.retained = nil } }
  deinit { precondition(retained == nil, "Derived source operation must join before disposal.") }
}
