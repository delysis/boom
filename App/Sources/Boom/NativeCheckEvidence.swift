import AppKit
import BoomCore
import Foundation

/// Explicit qualification mode only. Observe this process's own window without
/// exporting document text, chat contents or other windows.
@MainActor final class NativeCheckEvidence {
  /// Small explicitly authored public fixtures use the ordinary joined import
  /// path. Document bodies never become WorkspaceState/category records.
  static func openPublicWorkspace(store: WorkspaceStore, state: WorkspaceState,
    documents: [DocumentSnapshot]) async throws -> WorkspaceModel {
    guard documents.count <= 33, documents.allSatisfy({ $0.text.utf8.count <= PagedTextWindow.maximumBytes }),
      Set(documents.map(\.id)) == Set(state.documents.map(\.id)),
      state.composerDrafts?.isEmpty != false else {
      throw BoomError.invalid("Public diagnostic source setup exceeds its explicit bounds.")
    }
    var initial = state
    initial.documents = []; initial.selectedDocument = nil; initial.writingExampleIDs = []
    initial.importedFiles = nil
    try await store.saveState(initial)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    do {
      let empty = model.selectedDocumentID
      for document in documents {
        try await model.importAuthoredDocument(document, selecting: document.id == state.selectedDocument,
          flag: CancellationFlag())
      }
      if let empty, !documents.isEmpty { try await model.trashPagedDocuments([empty]) }
      model.writingExampleIDs = state.writingExampleIDs ?? []
      try await model.flush()
      _ = try await readPublicDocuments(model: model)
      return model
    } catch {
      throw WorkspacePagedStartupFailure(original: error, model: model)
    }
  }

  /// Readback is deliberately limited to a complete <=128KiB public fixture.
  /// Larger diagnostics use the real streaming export instead.
  static func readPublicDocuments(store: WorkspaceStore) async throws -> [DocumentSnapshot] {
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    do {
      let documents = try await readPublicDocuments(model: model)
      try await model.shutdown()
      return documents
    } catch {
      throw WorkspacePagedStartupFailure(original: error, model: model)
    }
  }

  static func readPublicDocuments(model: WorkspaceModel) async throws -> [DocumentSnapshot] {
    guard model.documentIndices.count <= 33 else { throw BoomError.budget("Public diagnostic document count exceeds33.") }
    var documents: [DocumentSnapshot] = []
    for index in model.documentIndices {
      let capture = try await model.captureDocument(index.id)
      guard let document = capture.completeSnapshot else {
        throw BoomError.budget("Public diagnostic readback requires a complete bounded source.")
      }
      documents.append(document)
    }
    return documents
  }

  static func readPublicOriginal(model: WorkspaceModel, documentID: UUID) async throws -> Data {
    guard let revision = model.state.importedFiles?[documentID]?.originalRevision,
      let engine = model.pagedEngine, revision.summary.bytes <= UInt64(PagedTextWindow.maximumBytes) else {
      throw BoomError.budget("Public original readback lacks its bounded retained file revision.")
    }
    let opened = try await engine.openRetaining(revision)
    var window: PagedTextCustodiedValue<PagedTextWindow>?
    do {
      let read = try await engine.windowRetaining(opened.value, byteStart: 0, maximumBytes: PagedTextWindow.maximumBytes)
      window = read
      let bytes = Data(read.value.text.utf8)
      guard UInt64(bytes.count) == revision.summary.bytes,
        Digest.sha256(bytes) == model.state.importedFiles?[documentID]?.originalDigest else {
        throw BoomError.invalid("The public imported original changed its exact bytes.")
      }
    } catch {
      let original = error
      do {
        if let window { try await engine.abandonJoinedRootOutput(window.lease) }
        try await engine.abandonJoinedRootOutput(opened.lease)
      } catch {
        throw PagedTextCustodyHandoffFailure(original: original, handoff: error,
          lease: window?.lease ?? opened.lease)
      }
      throw original
    }
    guard let window else { throw BoomError.stale("Public original read lost its actual receiving window.") }
    let bytes = Data(window.value.text.utf8)
    try await engine.abandonJoinedRootOutput(window.lease)
    try await engine.abandonJoinedRootOutput(opened.lease)
    return bytes
  }

  /// Programmed native input for a complete small public editing island.
  /// This never replaces an unseen large-document suffix.
  static func replacePublicDocument(_ model: WorkspaceModel, text: String, id: UUID,
    caret: Int) async throws {
    try await model.selectPagedDocument(id)
    guard let view = model.pagedInput?.activeView, model.pagedViewport?.textView === view,
      text.utf8.count <= PagedCapturedEditInput.maximumInputBytes,
      caret >= 0, caret <= text.utf16.count else {
      throw BoomError.budget("Public native edit is outside its bounded complete island.")
    }
    let coordinates = try view.session.documentCoordinates()
    _ = try TextBoundary.index(caret, in: text)
    if coordinates.utf16Start == 0, UInt64(view.boundedStorage.length) == coordinates.projectedUTF16,
      text.utf8.count <= PagedWorkingWindow.hardBytes {
      view.setSelectedRange(NSRange(location: 0, length: view.boundedStorage.length))
      view.insertText(text, replacementRange: view.selectedRange())
    } else {
      guard let commands = model.pagedCommands else { throw BoomError.stale("Public replacement lost its actual native command owner.") }
      _ = try await commands.replaceDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 0,
        utf16Length: coordinates.projectedUTF16), with: Data(text.utf8), actionName: "Public fixture")
      _ = try await commands.navigate(toUTF16: UInt64(caret),
        selectingUTF16: PagedNativeNavigationSelection(utf16Offset: UInt64(caret), utf16Length: 0))
    }
    guard let current = model.pagedInput?.activeView else { throw BoomError.stale("Public native replacement lost its actual receiving view.") }
    guard current.boundedStorage.mutationFailure == nil, current.inputBinding?.firstRefusal == nil else {
      throw BoomError.stale("The actual public native replacement was refused.")
    }
    let origin = try current.session.documentCoordinates().utf16Start
    guard UInt64(caret) >= origin, UInt64(caret) - origin <= UInt64(current.boundedStorage.length) else {
      throw BoomError.stale("Public native replacement returned another caret island.")
    }
    current.setSelectedRange(NSRange(location: Int(UInt64(caret) - origin), length: 0))
    try await model.flush()
    let capture = try await model.captureDocument(id)
    guard capture.completeSnapshot?.text == text else {
      throw BoomError.invalid("The actual public native replacement changed its expected source.")
    }
  }

  private struct Snapshot: Codable, Sendable {
    let pid: Int32
    let window: Int
    let source: String
    let time: Double
    let documentID: UUID?
    let editorDigest: String?
    let editorUTF16: Int?
    let selectionLocation: Int?
    let selectionLength: Int?
    let markedText: Bool
    let keyWindow: Bool
    let draftDigest: String
    let draftUTF16: Int
  }
  private let directory: URL
  private var timer: Timer?
  private var writer: Task<Void, Never>?
  init(directory: URL) async throws {
    self.directory = directory
    try await detachedWork {
      guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw BoomError.invalid("Native qualification evidence already exists.")
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
  }
  func observe(window: NSWindow, model: WorkspaceModel) {
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak window, weak model] _ in
      Task { @MainActor in
        guard let self, let window, let model, self.writer == nil else { return }
        let editor: NSTextView? = model.pagedViewport?.textView ?? model.editor
        let selection = editor?.selectedRange()
        let snapshot = Snapshot(pid: ProcessInfo.processInfo.processIdentifier,
          window: window.windowNumber, source: Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unavailable",
          time: Date().timeIntervalSince1970, documentID: model.selectedDocumentID,
          editorDigest: editor.map { Digest.sha256($0.string) }, editorUTF16: editor?.textStorage?.length,
          selectionLocation: selection?.location, selectionLength: selection?.length,
          markedText: editor?.hasMarkedText() ?? false, keyWindow: window.isKeyWindow,
          draftDigest: Digest.sha256(model.draft), draftUTF16: model.draft.utf16.count)
        let url = self.directory.appendingPathComponent("live.json")
        self.writer = Task {
          do { try await detachedWork { try JSONEncoder().encode(snapshot).write(to: url, options: .atomic) } }
          catch { fputs("Public native qualification observation failed.\n", stderr) }
          self.writer = nil
        }
      }
    }
  }
}
