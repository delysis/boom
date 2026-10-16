import AppKit
import BoomCore
import Foundation

/// Blessenger supplies context to the existing native ghost/Undo surface. This
/// owner has no transcript, editor projection, or model loader of its own.
@MainActor final class BlessengerCompletion: NativeCompletionClient {
  struct Context: Equatable {
    let draftID: UUID
    let chatVersion: UUID?
    let profile: BlessengerProfile
    let recipients: [BlessengerContact]
    let attachments: [SourceReference]
  }
  weak var model: BlessengerModel?
  weak var view: ChatTextView?
  let id = UUID()
  private(set) var completionDocument: DocumentSnapshot?
  private(set) var ghostStamp: GhostStamp?
  private var sourceVersion: UUID?
  private var caret = 0
  private var epoch: UInt64 = 0
  private var context: Context?
  private var suggestions: [String] = []
  private var selected = 0
  private var ghost = ""
  private var task: Task<Void, Never>?
  private var flag: CancellationFlag?
  var hasCompletionChoices: Bool { !suggestions.isEmpty && !ghost.isEmpty }
  init(model: BlessengerModel) { self.model = model }

  func observe(_ view: ChatTextView) {
    if self.view !== view { invalidateGhost(); self.view?.completionClient = nil; self.view = view }
    view.documentID = id; view.completionClient = self
    let next = model?.completionContext
    let changed = sourceVersion != view.sourceVersion || caret != view.selectedRange().location || context != next
    if sourceVersion != view.sourceVersion {
      completionDocument = DocumentSnapshot(id: id, title: "Message input", text: view.string)
      sourceVersion = view.sourceVersion
    }
    caret = view.selectedRange().location
    if changed || view.hasMarkedText() || view.selectedRange().length != 0 {
      invalidateGhost(); context = next
      if !view.movingGhostBoundary { suggestions = []; selected = 0; view.endGhostBoundary() }
    }
    if !view.movingGhostBoundary { schedule() }
  }
  private var eligible: Bool {
    guard let model, model.completionAvailable, let view, view.isEditable,
      view.window?.firstResponder === view, !view.hasMarkedText(), view.selectedRange().length == 0,
      let document = completionDocument, caret > 0, context == model.completionContext else { return false }
    return !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private func schedule(count: Int = 1, immediately: Bool = false) {
    guard eligible, ghostStamp == nil, flag == nil, let model, let document = completionDocument,
      let context else { return }
    let previous = task, expected = epoch, caret = caret
    let operation = CancellationFlag(); flag = operation
    let existing = immediately ? suggestions : []
    task = Task { [weak self, weak model] in
      if let previous { await previous.value }
      defer { if self?.flag === operation { self?.flag = nil } }
      do {
        if !immediately { try await Task.sleep(for: .milliseconds(650)) }
        try operation.check()
        guard let self, let model, self.epoch == expected, self.eligible else { return }
        let values = try await model.inputSuggestions(document: document, caret: caret, context: context,
          count: count, flag: operation) { [weak self] text in
            Task { @MainActor in
              guard let self, self.epoch == expected, !operation.isCancelled, self.eligible,
                self.completionDocument?.revision == document.revision, self.caret == caret else { operation.cancel(); return }
              self.present(text)
            }
          }
        guard self.epoch == expected, !operation.isCancelled, self.eligible else { return }
        self.suggestions = Array((existing + values).prefix(3)); self.selected = 0
        if let first = self.suggestions.first { self.present(first) }
      } catch { /* An optional suggestion never changes or blocks authored text. */ }
    }
  }
  private func present(_ text: String) {
    guard eligible, !text.isEmpty, let document = completionDocument, let view,
      let stamp = try? GhostStamp(document: document, caretUTF16: caret, epoch: epoch) else { return }
    ghost = text; ghostStamp = stamp; view.showGhost(text, stamp: stamp)
  }
  func invalidateGhost() {
    epoch &+= 1; flag?.cancel(); flag = nil; task?.cancel()
    ghost = ""; ghostStamp = nil; view?.clearGhost()
  }
  func join() async { invalidateGhost(); if let task { await task.value } }
  func takeGhost(documentID: UUID, caret: Int) -> String? {
    guard eligible, let document = completionDocument, document.id == documentID,
      ghostStamp?.accepts(document: document, caretUTF16: caret, epoch: epoch, hasMarkedText: view?.hasMarkedText() ?? true) == true,
      !ghost.isEmpty else { invalidateGhost(); return nil }
    let text = ghost; invalidateGhost(); return text
  }
  func takeGhostChunk(documentID: UUID, caret: Int) -> CompletionSegment? {
    guard let whole = takeGhost(documentID: documentID, caret: caret) else { return nil }
    let piece = CompletionNavigation.nextChunk(whole)
    return CompletionSegment(accepted: piece.accepted, remaining: piece.remaining, whole: whole, sources: [])
  }
  func resumeGhost(_ text: String, documentID: UUID, caret: Int, sources: [SourceReference]) {
    guard documentID == id, caret == self.caret, ghostSourcesRemainCurrent(sources, manuscriptID: id) else { return }
    present(text)
  }
  func ghostSourcesRemainCurrent(_ sources: [SourceReference], manuscriptID: UUID) -> Bool {
    manuscriptID == id && context == model?.completionContext && model?.completionAvailable == true
  }
  func navigateGhost(_ direction: Int) {
    guard eligible else { return }
    if suggestions.count > 1 {
      selected = (selected + direction + suggestions.count) % suggestions.count; present(suggestions[selected])
    } else {
      let old = suggestions; invalidateGhost(); suggestions = old
      schedule(count: old.isEmpty ? 3 : 2, immediately: true)
    }
  }
}
