import AppKit
import BoomCore
import AVKit
import PDFKit
import SwiftUI

struct BlessengerMediaReviewView: View {
  @ObservedObject var model: BlessengerModel
  @ObservedObject var review: BlessengerMediaReview
  @State private var discard = false
  @State private var replace = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(review.original.name).font(.headline).lineLimit(2)
        Spacer()
        Button("Close") { requestClose() }.keyboardShortcut(.cancelAction).disabled(review.hasOwnedEdit)
      }
      if review.loading { ProgressView("Opening private original…") }
      if let player = review.player {
        BlessengerReviewPlayer(player: player).frame(minHeight: review.original.kind == .video ? 210 : 80)
          .accessibilityLabel("Original media playback; playback is not automatic")
      } else if let image = review.image {
        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340)
      } else if let document = review.pdf {
        BlessengerReviewPDF(document: document).frame(minHeight: 260, maxHeight: .infinity)
        Text("\(document.pageCount) pages · Private preview; external actions are disabled").font(.caption).foregroundStyle(.secondary)
      } else if !review.loading, !review.hasTranscriptEditor {
        NativeScrollableText(text: review.original.text.isEmpty ? review.original.coverage : review.original.text,
          maximumHeight: 340).frame(maxHeight: .infinity)
      }
      Text("Model representation: " + review.original.coverage).font(.caption).foregroundStyle(.secondary)
      if let issue = review.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
      if review.hasTranscriptEditor { transcriptEditor }
    }
    .padding(20).frame(minWidth: 560, idealWidth: 690, maxWidth: 880, minHeight: 360, idealHeight: 650)
    .interactiveDismissDisabled()
    .confirmationDialog("Discard the unsaved transcript edits?", isPresented: $discard) {
      Button("Discard Edits and Close", role: .destructive) { model.closeMediaReview(review, discard: true) }
      Button("Keep Editing", role: .cancel) {}
    } message: { Text("The original recording and earlier saved transcript versions remain unchanged.") }
    .confirmationDialog("Replace the transcript editor with new on-device recognition?", isPresented: $replace) {
      Button("Transcribe Again") { review.transcribe() }
      Button("Cancel", role: .cancel) {}
    } message: { Text("Review the result before saving or using it. Earlier saved versions remain unchanged.") }
  }
  private var transcriptEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Transcript").font(.headline)
        if review.dirty { Text("Unsaved edits").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        if review.transcribing {
          ProgressView().controlSize(.small)
          Button("Cancel Transcription") { review.cancelTranscription() }
        } else {
          Button("Transcribe On Device") {
            if !review.transcript.isEmpty { replace = true } else { review.transcribe() }
          }.disabled(!review.canTranscribe)
        }
      }
      if review.transcribing { Text(review.progress).font(.caption).accessibilityLabel(review.progress) }
      ChatComposer(text: Binding(get: { review.transcript }, set: review.edit), focusRequest: 0,
        onSend: {}, onCancel: {}, placeholder: "Edit or enter the words spoken",
        accessibilityLabel: "Transcript editor; never sends a message", onIssue: { review.report(BoomCore.BoomError.invalid($0)) },
        maximumUTF8Bytes: 262_144)
        .frame(minHeight: 100, idealHeight: 175, maxHeight: 260).disabled(review.busy)
        .padding(8).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
      Text(review.coverage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Text("Recognition stays on this Mac. macOS may install public speech assets. A transcript is a separate representation; the original is never replaced.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save Transcript Version") { model.saveMediaTranscript(review) }.disabled(!review.canSave || !review.dirty)
        Spacer()
        if review.destination != nil {
          Button("Attach Transcript to Message") { model.attachMediaTranscript(review) }.disabled(!review.canSave)
        }
        if review.insertion != nil {
          Button("Insert into Message") { model.insertMediaTranscript(review) }.disabled(!review.canSave)
        }
      }
    }
  }
  private func requestClose() {
    if review.dirty { discard = true } else { model.closeMediaReview(review, discard: false) }
  }
}

private struct BlessengerReviewPlayer: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView(); view.controlsStyle = .inline; view.showsFullScreenToggleButton = false
    view.player = player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

/// PDF action dispatch has no authority beyond navigating the same document.
/// The public delegate hooks also suppress annotation/outline URL and remote
/// GoTo paths that PDFKit may dispatch without perform(_:).
@MainActor final class BlessengerReadOnlyPDFView: PDFView, PDFViewDelegate {
  override init(frame: NSRect) { super.init(frame: frame); delegate = self }
  required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }
  override func perform(_ action: PDFAction) {
    if let local = action as? PDFActionGoTo, let document,
      let page = local.destination.page, page.document === document { go(to: local.destination) }
  }
  func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
  func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
  func pdfViewPerformPrint(_ sender: PDFView) {}
  override func menu(for event: NSEvent) -> NSMenu? { nil }
}
private struct BlessengerReviewPDF: NSViewRepresentable {
  let document: PDFDocument
  func makeNSView(context: Context) -> BlessengerReadOnlyPDFView {
    let view = BlessengerReadOnlyPDFView(frame: .zero)
    view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = document
    return view
  }
  func updateNSView(_ view: BlessengerReadOnlyPDFView, context: Context) { if view.document !== document { view.document = document } }
  static func dismantleNSView(_ view: BlessengerReadOnlyPDFView, coordinator: ()) { view.document = nil; view.delegate = nil }
}
