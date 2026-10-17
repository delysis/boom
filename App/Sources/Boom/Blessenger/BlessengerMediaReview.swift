import AppKit
import AVFoundation
import BoomCore
import Combine
import Foundation
import PDFKit

/// One in-memory review owns its decoder/player and transcription task through
/// cancellation AND join. Its original is immutable; playback never autostarts
/// and cannot write a plaintext temporary file or fetch a remote URL.
@MainActor final class BlessengerMediaReview: ObservableObject, Identifiable {
  let id = UUID()
  let original: AttachmentRecord
  let destination: BlessengerDraft?
  let insertion: BlessengerTranscriptInsertion?
  @Published private(set) var player: AVPlayer?
  @Published private(set) var image: NSImage?
  @Published private(set) var pdf: PDFDocument?
  @Published private(set) var loading = true
  @Published private(set) var transcribing = false
  @Published private(set) var saving = false
  @Published private(set) var applying = false
  @Published private(set) var transcript = ""
  @Published private(set) var coverage = "Manual transcript; wording and coverage have not been verified."
  @Published private(set) var progress = ""
  @Published private(set) var issue: String?
  @Published private(set) var saved: BlessengerTranscript?
  private var expectedLatest: UUID?
  private var savedText = ""
  private var savedCoverage = "Manual transcript; wording and coverage have not been verified."
  private var savedOrigin = BlessengerTranscript.Origin.manual
  private var origin = BlessengerTranscript.Origin.manual
  private var memory: MemoryMedia?
  private var originalBytes: Data?
  private var task: Task<Void, Never>?
  private var flag = CancellationFlag()
  private var closed = false
  private let transcriber = VoiceInput()
  var dirty: Bool { !transcript.utf8.elementsEqual(savedText.utf8) || coverage != savedCoverage || origin != savedOrigin }
  var busy: Bool { loading || transcribing || saving || applying }
  var hasOwnedEdit: Bool { saving || applying }
  var canTranscribe: Bool { [.audio, .video].contains(original.kind) && originalBytes != nil && !busy && !closed }
  var hasTranscriptEditor: Bool { [.audio, .video].contains(original.kind) }
  var canSave: Bool { !busy && !closed && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  init(original: AttachmentRecord, destination: BlessengerDraft?, insertion: BlessengerTranscriptInsertion?) {
    self.original = original; self.destination = destination; self.insertion = insertion
  }
  func load(store: WorkspaceStore) {
    guard task == nil, !closed else { return }
    let flag = self.flag, original = self.original
    task = Task { [weak self] in
      guard let self else { return }
      defer { self.loading = false; self.task = nil }
      do {
        try flag.check()
        let bytes = try await detachedWork { try store.vault.get(.attachment, id: original.id, limit: 67_108_864) }
        try flag.check()
        guard Digest.sha256(bytes) == original.rootDigest else { throw BoomError.stale("The original failed its identity check.") }
        self.originalBytes = bytes
        let snapshot = try await store.blessengerSnapshot()
        try self.validate(in: snapshot)
        if let latest = snapshot.blessenger?.transcripts?[original.id]?.last {
          let text = try await detachedWork { () throws -> String in
            let data = try store.vault.get(.attachment, id: latest.id, limit: 262_144)
            guard Digest.sha256(data) == latest.textDigest, let text = String(data: data, encoding: .utf8) else {
              throw BoomError.invalid("The saved transcript is missing or corrupt; the original is retained.")
            }
            return text
          }
          try flag.check()
          self.saved = latest; self.expectedLatest = latest.id
          self.transcript = text; self.savedText = text; self.coverage = latest.coverage; self.origin = latest.origin; self.savedOrigin = latest.origin; self.savedCoverage = latest.coverage
        }
        switch original.kind {
        case .audio, .video:
          let memory = try MemoryMedia(bytes: bytes)
          self.memory = memory
          let player = try await memory.readyPlayer(flag: flag)
          try flag.check()
          guard !self.closed else { player.pause(); player.replaceCurrentItem(with: nil); throw CancellationError() }
          self.player = player // real negotiated playback capability, never autoplay
        case .image:
          _ = try LocalImage.decode(bytes)
          guard let image = NSImage(data: bytes) else { throw BoomError.invalid("The image cannot be displayed locally.") }
          self.image = image
        case .pdf:
          guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0,
            document.pageCount <= 4096 else { throw BoomError.unavailable("The PDF is locked, empty, or exceeds the review page bound. Its complete original is retained.") }
          // Review uses all admitted pages, not the model's smaller raster projection.
          self.pdf = document
        default: break
        }
        try self.validate(in: await store.blessengerSnapshot()); try flag.check()
      } catch {
        if !(error is CancellationError) { self.issue = error.localizedDescription }
        self.player?.pause(); self.player?.replaceCurrentItem(with: nil); self.player = nil; self.memory = nil
      }
    }
  }
  func edit(_ text: String) {
    guard !closed, !busy else { return }
    guard text.utf8.count <= 262_144, !text.contains("\0") else { issue = "The transcript exceeds its text limit. Nothing was truncated."; return }
    if !transcript.utf8.elementsEqual(text.utf8) {
      transcript = text
      if origin != .manual { origin = .edited }
    }
  }
  func transcribe() {
    guard canTranscribe, task == nil, let bytes = originalBytes else { return }
    player?.pause()
    transcribing = true; issue = nil; flag = CancellationFlag()
    let flag = self.flag
    task = Task { [weak self] in
      guard let self else { return }
      defer { self.transcribing = false; self.task = nil }
      do {
        let result = try await withTaskCancellationHandler {
          try await self.transcriber.transcribeAttachment(data: bytes, flag: flag) { current, total in
            if !flag.isCancelled { self.progress = "Transcribing segment \(current) of \(total)" }
          }
        } onCancel: { flag.cancel() }
        try flag.check()
        guard !self.closed else { throw CancellationError() }
        self.transcript = result.text; self.coverage = result.coverage; self.origin = .onDevice
      } catch {
        if !(error is CancellationError) { self.issue = error.localizedDescription }
      }
    }
  }
  func cancelTranscription() { flag.cancel(); task?.cancel() }
  func validate(in state: WorkspaceState) throws {
    guard let current = state.attachments.first(where: { $0.id == original.id }),
      try BlessengerPolicy.exactDigest(current) == BlessengerPolicy.exactDigest(original) else {
      throw BoomError.stale("The reviewed source changed. No result was retargeted.")
    }
  }
  /// Returns the stored snapshot as well as its immutable version. Saving is
  /// not insertion, attachment, or Send, and does not change any old message.
  func save(store: WorkspaceStore) async throws -> (WorkspaceState, BlessengerTranscript) {
    guard !closed, !loading, !transcribing, !saving, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BoomError.unavailable("Finish transcription and enter text before saving.") }
    saving = true; defer { saving = false }
    if !dirty, let saved {
      let snapshot = try await store.blessengerSnapshot(); try validate(in: snapshot)
      guard snapshot.blessenger?.transcripts?[original.id]?.contains(saved) == true else { throw BoomError.stale("The saved transcript changed.") }
      return (snapshot, saved)
    }
    flag = CancellationFlag()
    let text = transcript
    let note = origin == .edited && !coverage.hasPrefix("Human-edited transcript.") ? "Human-edited transcript. Prior coverage: " + coverage : coverage
    let next = try await store.blessengerSaveTranscript(original: original, expectedLatest: expectedLatest,
      text: text, coverage: note, origin: origin, flag: flag)
    guard !closed else { throw CancellationError() }
    saved = next.1; expectedLatest = next.1.id; savedText = text; coverage = next.1.coverage; savedCoverage = coverage; savedOrigin = origin
    return next
  }
  func beginApplying() throws {
    guard canSave else { throw BoomError.unavailable("Another review action is still finishing.") }
    applying = true
  }
  func endApplying() { applying = false }
  func report(_ error: Error) { issue = error.localizedDescription }
  func close() async {
    closed = true; flag.cancel(); task?.cancel()
    player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    if let task { await task.value }
    task = nil; memory = nil; pdf = nil; image = nil; originalBytes = nil
  }
}

/// An explicit transcript insertion is an ordinary native edit with ordinary
/// Undo. A replacement view, changed selection, IME or newer draft refuses it.
@MainActor final class BlessengerTranscriptInsertion {
  private weak var view: ChatTextView?
  let draft: BlessengerDraft
  private let range: NSRange
  init?(view: ChatTextView?, draft: BlessengerDraft) {
    guard let view, view.isEditable, !view.hasMarkedText(), view.string.utf8.elementsEqual(draft.text.utf8) else { return nil }
    self.view = view; self.draft = draft; range = view.selectedRange()
  }
  func insert(_ text: String, current: BlessengerDraft) throws {
    guard let view, view.window != nil, view.isEditable, !view.hasMarkedText(),
      current.id == draft.id, current.version == draft.version,
      view.string.utf8.elementsEqual(draft.text.utf8), view.selectedRange() == range,
      let target = Range(range, in: view.string) else {
      throw BoomError.stale("The target message or caret changed. The transcript remains available; nothing was inserted or sent.")
    }
    // This validation is pure. shouldChangeText is an editing boundary, not a
    // predicate: insertText already invokes it and registers the native undo.
    // Calling both registered two deletions for one insertion and damaged the
    // untouched suffix when Undo replayed them.
    try TextInputLimit.validateReplacement(in: view.string, range: range,
      replacement: text, maximumUTF8Bytes: view.maximumUTF8Bytes ?? 2_097_152)
    var expected = view.string; expected.replaceSubrange(target, with: text)
    view.breakUndoCoalescing()
    view.insertText(text, replacementRange: range)
    view.breakUndoCoalescing()
    guard view.string.utf8.elementsEqual(expected.utf8) else { throw BoomError.unavailable("The native editor refused transcript insertion.") }
    view.undoManager?.setActionName("Insert Transcript")
  }
}
