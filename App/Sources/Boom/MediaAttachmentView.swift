import AppKit
import AVFoundation
import AVKit
import BoomCore
import Combine
import Foundation
import PDFKit
import SwiftUI

enum AttachmentKind: Equatable {
  case image, audio, video, pdf, document

  init(name: String) {
    switch (name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp": self = .image
    case "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg": self = .audio
    case "mov", "mp4", "m4v": self = .video
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
    }
  }
}

/// The document owns its attachment controls. The Markdown link remains the
/// portable source reference; playback and extracted text live beside it in
/// the editor, with no modal preview or second navigation context.
struct AttachmentInlineCard: View {
  @ObservedObject var model: WorkspaceModel
  let record: AttachmentRecord
  @State private var bytes: Data?
  @State private var failure: String?
  @State private var showsText = false
  private var kind: AttachmentKind { AttachmentKind(name: record.name) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: kind.symbol).foregroundStyle(.secondary)
        Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
        Spacer(minLength: 8)
        if record.text.isEmpty {
          Button(kind == .audio ? "Transcribe" : "Extract text") {
            model.prepareAttachment(record.id)
          }.font(.caption).disabled(model.isBusy)
        }
        Menu {
          Button("Export original…") { exportOriginal() }.disabled(bytes == nil)
        } label: {
          Image(systemName: "ellipsis").frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Attachment options")
      }
      if let bytes, kind != .document {
        AttachmentMediaView(name: record.name, bytes: bytes)
          .frame(height: mediaHeight)
          .clipped()
      }
      if !record.text.isEmpty {
        Button {
          showsText.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: showsText ? "chevron.down" : "chevron.right")
              .font(.system(size: 9, weight: .semibold))
            Text("Extracted text")
          }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityValue(showsText ? "Expanded" : "Collapsed")
        if showsText {
          Text(record.text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
      }
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    .task(id: record.rootDigest) {
      do { bytes = try model.store.vault.get(.attachment, id: record.id, limit: 67_108_864) }
      catch { failure = error.localizedDescription }
    }
  }

  private var mediaHeight: CGFloat {
    switch kind {
    case .audio: 70
    case .image: 240
    case .video: 260
    case .pdf: 300
    case .document: 0
    }
  }

  private func exportOriginal() {
    guard let bytes else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = record.name
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try bytes.write(to: url, options: .atomic) }
    catch { failure = error.localizedDescription }
  }
}

struct AttachmentMediaView: View {
  let name: String
  let bytes: Data
  private var kind: AttachmentKind { AttachmentKind(name: name) }

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
          PDFAttachmentView(document: pdf)
        } else { unavailable }
      case .document:
        EmptyView()
      }
    }
  }

  private var unavailable: some View {
    ContentUnavailableView("Preview unavailable", systemImage: kind.symbol,
      description: Text("The original file can still be exported."))
  }
}

private struct PDFAttachmentView: NSViewRepresentable {
  let document: PDFDocument
  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.document = document
    return view
  }
  func updateNSView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
  }
}

private struct AudioAttachmentPlayer: View {
  let bytes: Data
  @State private var player: AVAudioPlayer?
  @State private var playing = false
  @State private var seconds = 0.0
  @State private var failure: String?
  private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 14) {
      Button {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        playing = player.isPlaying
      } label: {
        Image(systemName: playing ? "pause.fill" : "play.fill")
          .font(.system(size: 18)).frame(width: 36, height: 36)
      }.buttonStyle(.borderedProminent).disabled(player == nil)
      Slider(value: $seconds, in: 0...max(player?.duration ?? 0, 0.1), onEditingChanged: { editing in
        if !editing { player?.currentTime = seconds }
      }).disabled(player == nil)
      Text("\(clock(seconds)) / \(clock(player?.duration ?? 0))")
        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        .fixedSize()
    }
    .padding(16)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    .onAppear {
      do { player = try AVAudioPlayer(data: bytes); player?.prepareToPlay() }
      catch { failure = error.localizedDescription }
    }
    .onDisappear { player?.stop(); player = nil }
    .onReceive(ticker) { _ in
      seconds = player?.currentTime ?? 0
      playing = player?.isPlaying == true
    }
    .overlay(alignment: .bottomLeading) {
      if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
    }
  }

  private func clock(_ time: Double) -> String {
    let value = max(0, Int(time.isFinite ? time : 0))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
  }
}

private struct VideoAttachmentPlayer: View {
  let name: String
  let bytes: Data
  @State private var player: AVPlayer?
  @State private var temporaryDirectory: URL?
  @State private var failure: String?
  @State private var playing = false
  @State private var seconds = 0.0
  @State private var duration = 0.0
  @State private var scrubbing = false
  private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      if let player {
        NativeVideoPlayer(player: player)
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
              .disabled(duration <= 0)
              Text("\(clock(seconds)) / \(clock(duration))")
                .font(.system(.caption, design: .monospaced))
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(.black.opacity(0.75))
          }
      } else if let failure {
        ContentUnavailableView("Video unavailable", systemImage: "play.rectangle",
          description: Text(failure))
      } else {
        ProgressView()
      }
    }
    .onAppear(perform: prepare)
    .onDisappear {
      player?.pause()
      player = nil
      if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
      temporaryDirectory = nil
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

  private func clock(_ time: Double) -> String {
    let value = max(0, Int(time.isFinite ? time : 0))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
  }

  private func prepare() {
    guard player == nil, temporaryDirectory == nil else { return }
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "BoomVideoPreview-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      temporaryDirectory = directory
      let ext = (name as NSString).pathExtension.lowercased()
      let file = directory.appendingPathComponent("preview.\(ext)")
      try bytes.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      player = AVPlayer(url: file)
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
