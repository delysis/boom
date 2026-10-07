import AppKit
import BoomCore
import Foundation

/// Explicit qualification mode only. Observe this process's own window without
/// exporting document text, chat contents, key material or other windows.
@MainActor final class NativeCheckEvidence {
  private struct Snapshot: Codable, Sendable {
    let pid: Int32
    let window: Int
    let source: String
    let time: Double
    let keychainLookups: Int
    let productionKeychainLookups: Int
    let documentRevision: String?
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
  private let session: VaultSession
  private var timer: Timer?
  private var writer: Task<Void, Never>?
  init(directory: URL, session: VaultSession) async throws {
    self.directory = directory; self.session = session
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
        let editor = model.editor, selection = editor?.selectedRange()
        let snapshot = Snapshot(pid: ProcessInfo.processInfo.processIdentifier,
          window: window.windowNumber, source: Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unavailable",
          time: Date().timeIntervalSince1970, keychainLookups: self.session.lookupCount,
          productionKeychainLookups: VaultSession.shared.lookupCount,
          documentRevision: model.selectedDocument?.revision,
          editorDigest: editor.map { Digest.sha256($0.string) }, editorUTF16: editor?.string.utf16.count,
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
