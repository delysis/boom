import AppKit
import AVFoundation
import AVKit
import BoomCore
import Combine
import Foundation
import PDFKit
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

struct AttachmentMediaView: View {
  let name: String
  let bytes: Data
  var presentation: AttachmentKind? = nil
  var text: String = ""
  var maximumTextHeight: CGFloat = 220
  private var kind: AttachmentKind { presentation ?? AttachmentKind(name: name) }

  var body: some View {
    Group {
      switch kind {
      case .image:
        if let image = NativeMedia.thumbnail(bytes, maximum: 3200) {
          Image(nsImage: NSImage(cgImage: image, size: .zero))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { unavailable }
      case .audio:
        AudioAttachmentPlayer(bytes: bytes)
      case .video:
        VideoAttachmentPlayer(name: name, bytes: bytes)
      case .pdf:
        if let pdf = PDFDocument(data: bytes) {
          PDFAttachmentView(bytes: bytes, pageCount: pdf.pageCount)
        } else { unavailable }
      case .document:
        NativeScrollableText(text: text, maximumHeight: maximumTextHeight)
      case .unavailable: unavailable
      }
    }
  }

  private var unavailable: some View {
    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
      .help("Preview unavailable").accessibilityLabel("Preview unavailable")
  }
}

private struct PDFAttachmentView: View {
  let bytes: Data
  let pageCount: Int
  var body: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        ForEach(0..<pageCount, id: \.self) { index in
          PDFPagePreview(bytes: bytes, index: index)
        }
      }
    }
  }
}

private struct PDFPagePreview: View {
  let bytes: Data
  let index: Int
  @State private var image: NSImage?
  @State private var failed = false
  var body: some View {
    Group {
      if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
      else if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
      else { ProgressView().controlSize(.small) }
    }
    .task {
      do {
        let png = try await detachedWork {
          guard let page = PDFDocument(data: bytes)?.page(at: index),
            let tiff = page.thumbnail(of: NSSize(width: 1200, height: 1200), for: .mediaBox).tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw BoomError.invalid("PDF preview unavailable.")
          }
          return png
        }
        try Task.checkCancellation(); image = NSImage(data: png)
      } catch is CancellationError {} catch { failed = true }
    }
  }
}

private struct MediaPlaybackTime: View {
  let seconds: Double
  let duration: Double
  var body: some View {
    ViewThatFits(in: .horizontal) {
      Text("\(clock(seconds)) / \(clock(duration))").fixedSize()
      Text(clock(seconds)).fixedSize()
    }
    .font(.system(.caption, design: .monospaced))
    .accessibilityLabel("\(clock(seconds)) of \(clock(duration))")
  }
  private func clock(_ time: Double) -> String {
    let value = max(0, Int(time.isFinite ? time : 0))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
  }
}

private struct AudioAttachmentPlayer: View {
  let bytes: Data
  @State private var player: AVPlayer?
  @State private var media: MemoryMedia?
  @State private var preparation: Task<Void, Never>?
  @State private var playing = false
  @State private var seconds = 0.0
  @State private var duration = 0.0
  @State private var scrubbing = false
  @State private var failure: String?
  private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 8) {
      Button {
        guard let player else { return }
        if player.rate > 0 { player.pause() }
        else { if seconds >= duration { player.seek(to: .zero) }; player.play() }
        playing = player.rate > 0
      } label: {
        Image(systemName: playing ? "pause.fill" : "play.fill")
          .font(.system(size: 18)).frame(width: 28, height: 36)
      }.buttonStyle(.plain).disabled(player == nil)
      .accessibilityLabel(playing ? "Pause audio" : "Play audio")
      Slider(value: $seconds, in: 0...max(duration, 0.1), onEditingChanged: { editing in
        scrubbing = editing
        if !editing { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
      }).frame(minWidth: 32).disabled(player == nil)
      MediaPlaybackTime(seconds: seconds, duration: duration)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 4)
    .onAppear {
      guard preparation == nil else { return }
      preparation = Task {
        do {
          let source = try MemoryMedia(bytes: bytes)
          let ready = try await source.readyPlayer(flag: CancellationFlag())
          let length = try await source.asset.load(.duration).seconds
          try Task.checkCancellation()
          media = source; player = ready; duration = length.isFinite ? max(0, length) : 0
        } catch is CancellationError {} catch { failure = error.localizedDescription }
      }
    }
    .onDisappear { preparation?.cancel(); preparation = nil; player?.pause(); player = nil; media = nil }
    .onReceive(ticker) { _ in
      let time = player?.currentTime().seconds ?? 0
      if !scrubbing, time.isFinite { seconds = time }
      playing = (player?.rate ?? 0) > 0
    }
    .overlay(alignment: .bottomLeading) {
      if let failure {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
          .help(failure).accessibilityLabel("Audio unavailable")
      }
    }
  }

}

private struct VideoAttachmentPlayer: View {
  let name: String
  let bytes: Data
  @State private var player: AVPlayer?
  @State private var media: MemoryMedia?
  @State private var failure: String?
  @State private var playing = false
  @State private var seconds = 0.0
  @State private var duration = 0.0
  @State private var scrubbing = false
  @State private var poster: NSImage?
  @State private var posterTask: Task<Void, Never>?
  private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

  var body: some View {
    ZStack {
      if let player {
        NativeVideoPlayer(player: player)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay {
            if !playing, seconds < 0.05, let poster { Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit).allowsHitTesting(false) }
          }
          .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
              Button {
                if player.rate > 0 { player.pause() } else { player.play() }
                playing = player.rate > 0
              } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                  .frame(width: 18, height: 20)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(playing ? "Pause video" : "Play video")
              Slider(value: $seconds, in: 0...max(duration, 0.1), onEditingChanged: { editing in
                scrubbing = editing
                if !editing {
                  player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                }
              })
              .frame(minWidth: 32).disabled(duration <= 0)
              MediaPlaybackTime(seconds: seconds, duration: duration)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(.black.opacity(0.75))
          }
      } else if let failure {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
          .help(failure).accessibilityLabel("Video unavailable")
      } else {
        ProgressView()
      }
    }
    .onAppear(perform: prepare)
    .onDisappear {
      posterTask?.cancel(); posterTask = nil; poster = nil
      player?.pause()
      player = nil
      media = nil
    }
    .onReceive(ticker) { _ in
      guard let player else { return }
      let current = player.currentTime().seconds
      if current.isFinite && !scrubbing { seconds = current }
      let itemDuration = player.currentItem?.duration.seconds ?? 0
      if itemDuration.isFinite { duration = max(0, itemDuration) }
      playing = player.rate > 0
    }
  }

  private func prepare() {
    guard player == nil else { return }
    do {
      let source = try MemoryMedia(bytes: bytes)
      guard source.container == .mp4 else { throw BoomError.invalid("This attachment is not self-contained MP4 video.") }
      posterTask = Task {
        do {
          let ready = try await source.readyPlayer(flag: CancellationFlag())
          try Task.checkCancellation(); media = source; player = ready
          let generator = AVAssetImageGenerator(asset: source.asset)
          generator.appliesPreferredTrackTransform = true; generator.maximumSize = NSSize(width: 1600, height: 1600)
          let frame = try await generator.image(at: .zero)
          try Task.checkCancellation(); poster = NSImage(cgImage: frame.image, size: .zero)
        } catch is CancellationError {} catch { failure = error.localizedDescription }
      }
    } catch { failure = error.localizedDescription }
  }
}

private struct NativeVideoPlayer: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .none
    view.videoGravity = .resizeAspect
    view.player = player
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }
}

/// The media itself is the presentation. Intentional export/removal lives in
/// the ordinary context menu, never a permanent filename/options card.
struct InlineAttachmentView: View {
  @ObservedObject var model: WorkspaceModel
  let record: AttachmentRecord
  var remove: (() -> Void)? = nil
  @State private var bytes: Data?
  @State private var failure: String?
  private var kind: AttachmentKind { record.kind }
  var body: some View {
    Group {
      if let bytes {
        AttachmentMediaView(name: record.name, bytes: bytes, presentation: kind, text: record.text)
          .frame(minWidth: 0, idealWidth: kind == .unavailable ? 24 : kind == .audio ? 260 : kind == .image ? 240 : 300,
            maxWidth: kind == .unavailable ? 24 : kind == .audio ? 260 : kind == .image ? 240 : 300)
          .frame(height: kind == .document ? nil : kind == .unavailable ? 24 : kind == .audio ? 44 : kind == .image ? 180 : 220)
      } else if let failure {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).help(failure)
      } else { ProgressView().controlSize(.small) }
    }
    .accessibilityLabel(record.name)
    .help(kind == .unavailable ? record.coverage : record.name)
    .contextMenu {
      if let remove { Button("Remove", action: remove) }
      Button("Export original…") {
        guard let bytes else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = record.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportFile(to: url) { bytes }
      }.disabled(bytes == nil)
    }
    .task(id: record.rootDigest) {
      do {
        let vault = model.store.vault, id = record.id, digest = record.rootDigest
        let data = try await detachedWork { try vault.get(.attachment, id: id, limit: 67_108_864) }
        guard Digest.sha256(data) == digest else { throw BoomError.invalid("Attachment original changed.") }
        try Task.checkCancellation(); bytes = data
      } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
  }
}
