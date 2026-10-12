#if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
#if BOOM_UI_TEST
#error("Owned public editor diagnostics cannot use the UI test workspace override.")
#endif
import AppKit
import BoomCore
import CryptoKit
import Darwin
import Foundation
import SwiftUI

/// One explicit public, warmed, model-free observation of the ordinary editor.
/// It does not qualify the paged editor, physical input, IME or presentation.
@MainActor enum DeveloperEditorFixture {
  static func run(recipe: URL) async throws {
    var fixture: Prepared?
    var connected = false, finished = false
    var failures: [String] = []
    do {
      let plan = try await DeveloperStackDiagnostics.bootstrapForOwnedPublicFixture(recipe: recipe) { plan in
        let prepared = try Prepared(recipe: recipe, plan: plan)
        fixture = prepared
        try await prepared.prepare()
      }
      connected = true
      guard let fixture else { throw BoomError.invalid("Public editor preparation was absent.") }
      try await fixture.observe(plan)
    } catch { failures.append(error.localizedDescription) }
    // Finish the single main producer before shutdown can lazily load modules
    // or invoke other subsystem cleanup. The lifetime guardian remains active.
    if connected {
      do { try DeveloperStackDiagnostics.finishOutsideMeasuredPhases(); finished = true }
      catch { failures.append("Capture finish: " + error.localizedDescription) }
    }
    if let fixture {
      do { try await fixture.shutdown() }
      catch { failures.append("Workspace shutdown: " + error.localizedDescription) }
      do { try fixture.writeReceipt(captureFinished: finished, failures: failures) }
      catch { failures.append("Public fixture receipt: " + error.localizedDescription) }
    }
    guard failures.isEmpty else { throw BoomError.unavailable(failures.joined(separator: "; ")) }
  }

  @MainActor private final class Prepared {
    private static let byteCount = 72_196
    private static let cycles: UInt32 = 1_000
    private static let observationSeconds: Int64 = 110
    private static let diskLimit: UInt64 = 4 << 20
    private let root: URL
    private let keySession = VaultSession(loader: { _ in
      throw BoomError.invalid("Public fixture cannot look up a Keychain key.")
    })
    private var workspace: WorkspaceModel?
    private var host: NSHostingView<WorkspaceView>?
    private var window: NSWindow?
    private var editor: MarkdownTextView?
    private var expectedDigest: Data?
    private var documentID: UUID?
    private var completed: UInt32 = 0
    private var sourceVerified = false, shutdownJoined = false
    private var footprintBefore: UInt64 = 0, footprintAfter: UInt64 = 0, peakFootprint: UInt64 = 0

    init(recipe: URL, plan: DeveloperStackDiagnostics.PublicEditorPlan) throws {
      guard plan.operations == Self.cycles, plan.utf8Bytes == UInt64(Self.byteCount) else {
        throw BoomError.invalid("Public editor plan differs from its fixed source recipe.")
      }
      root = recipe.deletingLastPathComponent().appendingPathComponent("public-editor-workspace", isDirectory: true)
      // Atomic fresh-directory admission; no reuse or cleanup of an existing path.
      guard mkdir(root.path, 0o700) == 0 else {
        throw BoomError.invalid("Public fixture directory already exists or cannot be created.")
      }
    }

    func prepare() async throws {
      let paragraph = "At the harbor, the keeper watches the morning light cross the water. A visitor leaves a letter on the table, and the quiet room begins to change.\n\n"
      let text = String(repeating: paragraph, count: Self.byteCount / paragraph.utf8.count)
        + String(paragraph.prefix(Self.byteCount % paragraph.utf8.count))
      guard text.utf8.count == Self.byteCount else { throw BoomError.invalid("Public fixture byte extent changed.") }
      expectedDigest = Data(SHA256.hash(data: Data(text.utf8)))
      let document = DocumentSnapshot(title: "Public editor fixture", text: text)
      documentID = document.id
      let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted-workspace", isDirectory: true),
        testKey: SymmetricKey(data: Data(repeating: 0x74, count: 32)), session: keySession)
      var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
      state.documents = [.init(id: document.id, title: document.title)]; state.selectedDocument = document.id
      try await store.save(state, documents: [document])
      let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
      workspace = model
      guard model.layout.isAuthor else { throw BoomError.invalid("Public editor observation requires Author.") }
      let host = NSHostingView(rootView: WorkspaceView(model: model)); self.host = host
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      self.window = window; window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      guard let editor = model.editor, window.makeFirstResponder(editor), editor.isEditable else {
        throw BoomError.invalid("Ordinary public editor focus was unavailable.")
      }
      self.editor = editor; model.isBusy = true
      // Deliberate warmup outside recording permits immutable module admission
      // after edit-specific AppKit/TextKit images have actually loaded.
      editor.setSelectedRange(NSRange(location: 0, length: 0))
      editor.insertText("x", replacementRange: editor.selectedRange())
      editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)); host.layoutSubtreeIfNeeded()
      try verifySource()
      _ = try diskExtent(reservingReceipt: true)
    }

    func observe(_ plan: DeveloperStackDiagnostics.PublicEditorPlan) async throws {
      guard plan.operations == Self.cycles, plan.utf8Bytes == UInt64(Self.byteCount),
        let model = workspace, let editor, let host, let window else {
        throw BoomError.invalid("Public editor preparation is incomplete.")
      }
      let before = ModelResidency.memoryAccounting(); footprintBefore = before.current
      guard footprintBefore > 0 else { throw BoomError.unavailable("Public process footprint is unavailable.") }
      let clock = ContinuousClock(), started = ContinuousClock().now
      let deadline = started.advanced(by: .seconds(Self.observationSeconds))
      for index in 0..<plan.operations {
        try Task.checkCancellation()
        guard clock.now < deadline else {
          throw BoomError.unavailable("Public editor observation exceeded its bound.")
        }
        // Existing closed-loop 100ms pacing; elapsed stages, not acceptance timing.
        try await Task.sleep(until: clock.now.advanced(by: .milliseconds(100)), clock: clock)
        guard clock.now < deadline else {
          throw BoomError.unavailable("Public editor observation expired before its next cycle.")
        }
        guard let priorVersion = model.selectedDocument?.textVersion else {
          throw BoomError.invalid("Public editor document was removed.")
        }
        let cycle = PerformanceTrace.begin("Editor.PublicTypingCycle", event: UInt64(index) + 1)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("x", replacementRange: editor.selectedRange())
        editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
        let layout = PerformanceTrace.begin("Editor.HostLayout")
        host.layoutSubtreeIfNeeded()
        PerformanceTrace.end("Editor.HostLayout", layout)
        PerformanceTrace.end("Editor.PublicTypingCycle", cycle)
        // Constant-size admission checks only; no whole-source comparison/hash,
        // timing arrays, file IO, Mach calls or recorder joins in a cycle.
        guard let current = model.selectedDocument, current.id == documentID,
          current.textVersion != priorVersion, editor.displays(current),
          editor.textStorage?.length == Self.byteCount, editor.isEditable,
          window.firstResponder === editor, !editor.hasMarkedText(),
          model.errorMessage == nil, model.writingIssue == nil else {
          throw BoomError.invalid("Public native edit was refused or lost its source/focus binding.")
        }
        completed += 1
      }
      try verifySource(); sourceVerified = true
      let after = ModelResidency.memoryAccounting()
      footprintAfter = after.current; peakFootprint = after.peak
      guard footprintAfter > 0, peakFootprint >= footprintAfter else {
        throw BoomError.unavailable("Public process footprint accounting was incomplete.")
      }
    }

    private func verifySource() throws {
      guard let model = workspace, let editor, let expectedDigest,
        let current = model.selectedDocument, current.id == documentID,
        current.text.utf8.count == Self.byteCount,
        Data(SHA256.hash(data: Data(current.text.utf8))) == expectedDigest,
        Data(SHA256.hash(data: Data(editor.string.utf8))) == expectedDigest,
        model.completionRunner == nil, model.selectedMLXRunner == nil,
        !model.state.autocomplete, keySession.lookupCount == 0 else {
        throw BoomError.invalid("Public source/model/Keychain isolation changed.")
      }
    }

    func shutdown() async throws {
      window?.close()
      if let workspace { try await workspace.shutdown() }
      shutdownJoined = true
    }

    /// The public workspace has an independent 4MiB/16-file/depth4 ceiling.
    /// Inspect only after preparation or joined shutdown, never during typing.
    private func diskExtent(reservingReceipt: Bool) throws -> UInt64 {
      var pending: [(URL, Int)] = [(root, 0)]
      var files = 0, directories = 0, bytes: UInt64 = 0
      while let (directory, depth) = pending.popLast() {
        guard depth < 4, directories < 4 else { throw BoomError.budget("Public fixture directory bound exceeded.") }
        directories += 1
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 20 else { throw BoomError.budget("Public fixture entry bound exceeded.") }
        for child in children {
          var info = stat()
          guard lstat(child.path, &info) == 0, info.st_uid == getuid() else {
            throw BoomError.invalid("Public fixture ownership changed.")
          }
          switch info.st_mode & S_IFMT {
          case S_IFDIR: pending.append((child, depth + 1))
          case S_IFREG:
            guard info.st_size >= 0, info.st_nlink == 1 else { throw BoomError.invalid("Public fixture file extent changed.") }
            files += 1; bytes += UInt64(info.st_size)
          default: throw BoomError.invalid("Public fixture contains a nonregular entry.")
          }
          guard files <= (reservingReceipt ? 15 : 16),
            bytes <= Self.diskLimit - (reservingReceipt ? 16_384 : 0) else {
            throw BoomError.budget("Public fixture disk bound exceeded.")
          }
        }
      }
      return bytes
    }

    func writeReceipt(captureFinished: Bool, failures: [String]) throws {
      let extent = try diskExtent(reservingReceipt: true)
      let receipt: [String: Any] = [
        "schema": 1, "status": failures.isEmpty && captureFinished && shutdownJoined && sourceVerified
          && completed == Self.cycles ? "complete" : "incomplete",
        "requested_cycles": Self.cycles, "completed_cycles": completed,
        "primitive_replacements_per_cycle": 2, "public_utf8_bytes": Self.byteCount,
        "observation_deadline_seconds": Self.observationSeconds,
        "source_verified": sourceVerified, "capture_finish_acknowledged": captureFinished,
        "workspace_shutdown_joined": shutdownJoined, "keychain_lookups": keySession.lookupCount,
        "process_footprint_before_bytes": footprintBefore, "process_footprint_after_bytes": footprintAfter,
        "process_peak_footprint_bytes": peakFootprint, "workspace_disk_bytes_before_receipt": extent,
        "workspace_disk_limit_bytes": Self.diskLimit, "failures": failures,
        "scope": "Warmed offscreen ordinary Author editor; fixed public ASCII, direct paired edits and synchronous host layout, closed-loop100ms pacing. No inference, IME, physical event dispatch, deferred draw completion or compositor acceptance. No per-cycle source hashing, files or timing arrays."
      ]
      let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      guard bytes.count <= 16_384 else { throw BoomError.budget("Public fixture receipt exceeds its bound.") }
      try bytes.write(to: root.appendingPathComponent("fixture-receipt.json"), options: .withoutOverwriting)
      _ = try diskExtent(reservingReceipt: false)
    }
  }
}
#endif
