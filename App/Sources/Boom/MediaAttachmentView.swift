import BoomCore
import Foundation
import SwiftUI

enum AttachmentKind: String, Codable, Sendable {
  case image, audio, video, pdf, document, unavailable

  init(name: String) {
    switch (name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "avif": self = .image
    case "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf": self = .audio
    case "mov", "mp4", "m4v", "webm", "mkv", "avi": self = .video
    case "pdf": self = .pdf
    default: self = .document
    }
  }

  var symbol: String {
    switch self {
    case .image: "photo"
    case .audio: "waveform"
    case .video: "play.rectangle"
    case .pdf: "doc.richtext"
    case .document: "doc.text"
    case .unavailable: "exclamationmark.triangle"
    }
  }
}

/// The media itself is the presentation. Intentional export/removal lives in
/// the ordinary context menu, never a permanent filename/options card.
struct InlineAttachmentView: View {
  @ObservedObject var model: WorkspaceModel
  let record: AttachmentRecord
  var remove: (() -> Void)? = nil

  var body: some View {
    // The controlled marker reuses the actual native media owner and its
    // source-bound worker/menu. It never retains an original Data value or
    // constructs a second extracted-document reader for SwiftUI measurement.
    NativeText(text: "[Attachment](boom-attachment:\(record.id.uuidString))",
      mediaModel: model, attachmentRemoval: remove)
      .frame(minWidth: 24, idealWidth: 300, maxWidth: 320)
      .accessibilityLabel(record.name)
      .help(record.kind == .unavailable ? record.coverage : record.name)
  }
}
