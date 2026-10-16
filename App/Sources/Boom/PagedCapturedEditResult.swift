/// Fixed bounds for explicit captured agent edits. Native global selection,
/// imported replacement and prefix commands use their own stepped source APIs.
enum PagedCapturedEditInput {
  static let maximumEdits = 32
  static let maximumInputBytes = PagedTextWindow.maximumBytes
}
