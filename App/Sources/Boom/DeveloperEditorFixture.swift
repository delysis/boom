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
/// Fixed legacy and ordinary bounded-SQL recipes; no physical input/IME or
/// compositor acceptance. Only explicit owned developer admission can enter.
@MainActor enum DeveloperEditorFixture {
  // Preserve the actual partial Model/window/source on any failed cleanup.
  // This is the existing fixture receiver, not another lifetime or root owner.
  private static var failedFixture: Prepared?
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
      if finished && failures.isEmpty {
        do { try await fixture.verifyAfterCapture() }
        catch { failures.append("Public source verification: " + error.localizedDescription) }
      }
      do { try await fixture.shutdown() }
      catch { failures.append("Workspace shutdown: " + error.localizedDescription) }
      do { try fixture.writeReceipt(captureFinished: finished, failures: failures) }
      catch { failures.append("Public fixture receipt: " + error.localizedDescription) }
    }
    if !failures.isEmpty { failedFixture = fixture }
    guard failures.isEmpty else { throw BoomError.unavailable(failures.joined(separator: "; ")) }
  }

  @MainActor private final class Prepared {
    private static let byteCount = 72_196
    private static let cycles: UInt32 = 1_000
    private static let observationSeconds: Int64 = 110
    private let plan: DeveloperStackDiagnostics.PublicEditorPlan
    private let root: URL
    private let temporaryRoot: URL
    private let keySession = VaultSession(loader: { _ in
      throw BoomError.invalid("Public fixture cannot look up a Keychain key.")
    })
    private var workspace: WorkspaceModel?
    private var host: NSHostingView<WorkspaceView>?
    private var window: NSWindow?
    private var editor: MarkdownTextView?
    private var managedEditor: PagedNativeTextView?
    private var sourceFile: FileHandle?
    private var sourceCloseAttempted = false
    private var bitmap: NSBitmapImageRep?
    private var bitmapSize: NSSize?
    private var expectedDigest: Data?
    private var documentID: UUID?
    private var completed: UInt32 = 0
    private var sourceVerified = false, shutdownJoined = false
    private var importJoined = false, selectionJoined = false, preparationExportJoined = false, finalExportJoined = false
    private var generatedBytes: UInt64 = 0
    private var footprintBefore: UInt64 = 0, footprintAfter: UInt64 = 0, peakFootprint: UInt64 = 0

    init(recipe: URL, plan: DeveloperStackDiagnostics.PublicEditorPlan) throws {
      guard plan.operations == Self.cycles else {
        throw BoomError.invalid("Public editor plan differs from its fixed source recipe.")
      }
      self.plan = plan
      root = recipe.deletingLastPathComponent().appendingPathComponent("public-editor-workspace", isDirectory: true)
      temporaryRoot = recipe.deletingLastPathComponent().appendingPathComponent("public-editor-tmp", isDirectory: true)
      // Atomic fresh-directory admission; no reuse or cleanup of an existing path.
      guard mkdir(root.path, 0o700) == 0 else {
        throw BoomError.invalid("Public fixture directory already exists or cannot be created.")
      }
    }

    func prepare() async throws {
      if plan.boundedSQL { try await prepareBoundedSQL(); return }
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
      if plan.boundedSQL { try await observeBoundedSQL(plan); return }
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

    private func prepareBoundedSQL() async throws {
      guard ProcessInfo.processInfo.environment["TMPDIR"] == temporaryRoot.path,
        temporaryRoot.resolvingSymlinksInPath() == temporaryRoot else {
        throw BoomError.invalid("Public ordinary fixture requires its exact owner-provided physical TMPDIR.")
      }
      var temporary = stat()
      guard lstat(temporaryRoot.path, &temporary) == 0, temporary.st_mode & S_IFMT == S_IFDIR,
        temporary.st_uid == getuid(), temporary.st_mode & 0o777 == 0o700 else {
        throw BoomError.invalid("Public ordinary temporary directory admission changed.")
      }
      let input = root.appendingPathComponent("public-source.txt")
      let fd = open(input.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw BoomError.invalid("Public source cannot be created exclusively.") }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      sourceFile = file; sourceCloseAttempted = false // own the actual descriptor before utility work can fail
      let extent = plan.utf8Bytes
      let digest = try await detachedWork {
        let paragraph = "At the harbor, the keeper watches the morning light cross the water. A visitor leaves a letter on the table, and the quiet room begins to change.\n\n"
        let period = paragraph.utf8.count
        // One <=66KiB repeated pattern plus one <=64KiB transfer block. Preserve
        // the original72K paragraph bytes without a per-byte GB-sized loop.
        let pattern = Data(String(repeating: paragraph, count: (64 << 10) / period + 2).utf8)
        var written: UInt64 = 0, hash = SHA256()
        while written < extent {
          try Task.checkCancellation()
          let count = Int(min(UInt64(64 << 10), extent - written))
          let phase = Int(written % UInt64(period))
          let block = pattern.subdata(in: phase..<(phase + count))
          try file.write(contentsOf: block); hash.update(data: block); written += UInt64(count)
        }
        try file.synchronize()
        return Data(hash.finalize())
      }
      sourceCloseAttempted = true
      try await detachedWork { try file.close() }
      sourceFile = nil; generatedBytes = extent; expectedDigest = digest
      _ = try diskExtent(reservingReceipt: true)
      let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("encrypted-workspace", isDirectory: true),
        testKey: SymmetricKey(data: Data(repeating: 0x74, count: 32)), session: keySession)
      let model: WorkspaceModel
      do { model = try await WorkspaceModel(storeOverride: store, loadModels: false, storageRoute: .boundedSQL) }
      catch let failure as WorkspacePagedStartupFailure {
        workspace = failure.model // preserve actual partial Engine/native custody
        throw failure.original
      }
      workspace = model
      guard model.layout.isAuthor, model.usesPagedStorage else {
        throw BoomError.invalid("Public ordinary fixture requires the actual SQL Author route.")
      }
      model.setAutocomplete(false)
      if model.pagedSettings?.showChat == true { model.toggle("chat") }
      try await model.flush()
      guard let initialDocument = model.selectedDocumentID else {
        throw BoomError.invalid("Fresh ordinary Author did not receive its initial document.")
      }
      // These are the same bodies used by the ordinary panels. Their returns
      // join the actual import, metadata receiver, opening and selection work.
      try await model.importDocuments([input], flag: CancellationFlag()); importJoined = true
      guard let id = model.selectedDocumentID, id != initialDocument else {
        throw BoomError.invalid("Ordinary import did not select its new source.")
      }
      documentID = id
      try await model.selectPagedDocument(initialDocument)
      try await model.selectPagedDocument(id); selectionJoined = true
      let host = NSHostingView(rootView: WorkspaceView(model: model)); self.host = host
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      self.window = window; window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      guard let view = model.pagedViewport?.textView as? PagedNativeTextView,
        model.pagedInput?.activeView === view, window.makeFirstResponder(view), view.isEditable else {
        throw BoomError.invalid("Ordinary managed public editor focus was unavailable.")
      }
      managedEditor = view
      view.setSelectedRange(NSRange(location: 0, length: 0))
      view.insertText("x", replacementRange: view.selectedRange())
      view.insertText("", replacementRange: NSRange(location: 0, length: 1))
      host.layoutSubtreeIfNeeded()
      try prepareBitmap(for: view, window: window)
      try rasterize(view)
      try await model.flush() // actual canonical/worker join, not a delay or flag
      try requireManagedSource()
      try await verifyOrdinaryExport(named: "prepared-export.txt"); preparationExportJoined = true
      _ = try diskExtent(reservingReceipt: true)
    }

    private func observeBoundedSQL(_ requested: DeveloperStackDiagnostics.PublicEditorPlan) async throws {
      guard requested.kind == plan.kind, requested.operations == plan.operations, requested.utf8Bytes == plan.utf8Bytes,
        workspace != nil, let view = managedEditor, let host, let window else {
        throw BoomError.invalid("Ordinary public preparation is incomplete.")
      }
      try requireManagedSource()
      footprintBefore = ModelResidency.memoryAccounting().current
      guard footprintBefore > 0 else { throw BoomError.unavailable("Public process footprint is unavailable.") }
      let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(Self.observationSeconds))
      for index in 0..<requested.operations {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw BoomError.unavailable("Public editor observation exceeded its bound.") }
        try await Task.sleep(until: clock.now.advanced(by: .milliseconds(100)), clock: clock)
        guard clock.now < deadline else { throw BoomError.unavailable("Public editor observation expired before its next cycle.") }
        let priorGeneration = view.session.generation
        do {
          let cycle = PerformanceTrace.begin("Editor.PublicTypingCycle", event: UInt64(index) + 1)
          defer { PerformanceTrace.end("Editor.PublicTypingCycle", cycle) }
          view.setSelectedRange(NSRange(location: 0, length: 0))
          view.insertText("x", replacementRange: view.selectedRange())
          view.insertText("", replacementRange: NSRange(location: 0, length: 1))
          let layout = PerformanceTrace.begin("Editor.HostLayout")
          host.layoutSubtreeIfNeeded()
          PerformanceTrace.end("Editor.HostLayout", layout)
          try rasterize(view) // actual SDK cached-bitmap draw completes inside this cycle
        }
        guard view.session.generation > priorGeneration, window.firstResponder === view else {
          throw BoomError.invalid("Ordinary native input did not advance its exact source/focus.")
        }
        try requireManagedSource() // bounded scalar identities, never source IO/hash
        completed += 1
      }
      let after = ModelResidency.memoryAccounting()
      footprintAfter = after.current; peakFootprint = after.peak
      guard footprintAfter > 0, peakFootprint >= footprintAfter else {
        throw BoomError.unavailable("Public process footprint accounting was incomplete.")
      }
    }

    private func requireManagedSource() throws {
      guard let model = workspace, let view = managedEditor, let id = documentID,
        model.usesPagedStorage, model.selectedDocumentID == id,
        model.pagedSelectedRecord?.document.id == id,
        model.pagedViewport?.textView === view, model.pagedInput?.activeView === view,
        model.pagedSession === view.session, view.inputBinding?.owner === model.pagedInput,
        view.inputBinding?.state == .active, view.inputBinding?.identity == model.pagedInput?.activeIdentity,
        view.inputBinding?.identity.arenaID == view.session.arenaID, view.inputCommandIsClosed,
        view.boundedStorage.mutationFailure == nil, view.inputBinding?.firstRefusal == nil,
        view.boundedStorage.length <= PagedWorkingWindow.hardBytes, view.isEditable, !view.hasMarkedText(),
        model.errorMessage == nil, model.writingIssue == nil,
        model.completionRunner == nil, model.selectedMLXRunner == nil,
        !model.autocompleteEnabled, keySession.lookupCount == 0 else {
        throw BoomError.invalid("Ordinary public source/native/model/Keychain binding changed.")
      }
    }

    private func prepareBitmap(for view: PagedNativeTextView, window: NSWindow) throws {
      let visible = view.visibleRect, scale = window.backingScaleFactor
      guard visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0,
        visible.width <= 1190, visible.height <= 846, scale.isFinite, scale >= 1, scale <= 2,
        ceil(visible.width * scale) * ceil(visible.height * scale) * 8 <= 32 * 1048576,
        let backing = view.bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero, size: visible.size)) else {
        throw BoomError.budget("Ordinary public raster backing is outside its fixed viewport bound.")
      }
      let cost = backing.bytesPerRow.multipliedReportingOverflow(by: backing.pixelsHigh)
      guard backing.bytesPerRow > 0, backing.pixelsHigh > 0, !cost.overflow, cost.partialValue <= 32 * 1048576 else {
        throw BoomError.budget("Ordinary public raster backing exceeds32MiB.")
      }
      bitmap = backing; bitmapSize = visible.size
    }

    private func rasterize(_ view: PagedNativeTextView) throws {
      let visible = view.visibleRect
      guard let window, workspace?.pagedViewport?.window === window, view.window === window, window.firstResponder === view else {
        throw BoomError.stale("Ordinary public raster lost its actual attached viewport/native window/focus.")
      }
      guard let bitmap, let bitmapSize, visible.origin.x.isFinite, visible.origin.y.isFinite,
        visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0,
        visible.width <= bitmapSize.width, visible.height <= bitmapSize.height else {
        throw BoomError.budget("Ordinary public raster no longer fits its prepared backing.")
      }
      view.cacheDisplay(in: visible, to: bitmap)
    }

    private func verifyOrdinaryExport(named name: String) async throws {
      guard let model = workspace, let id = documentID, let expectedDigest else {
        throw BoomError.invalid("Ordinary export lacks its actual source receiver.")
      }
      let destination = root.appendingPathComponent(name)
      guard access(destination.path, F_OK) != 0, errno == ENOENT else {
        throw BoomError.invalid("Public export destination is not fresh.")
      }
      let task = try model.exportPagedDocument(to: destination, documentID: id)
      let actual = try await task.value // join the real registered export producer
      guard actual == destination else { throw BoomError.invalid("Public export returned another destination.") }
      let extent = plan.utf8Bytes
      guard sourceFile == nil else { throw BoomError.invalid("Public export verifier has no fresh descriptor slot.") }
      let fd = open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw BoomError.invalid("Public export verifier cannot be opened.") }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      sourceFile = file; sourceCloseAttempted = false
      var original: Error?, digest: Data?
      do {
        digest = try await detachedWork {
          var before = stat()
          guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
            before.st_nlink == 1, before.st_size >= 0, UInt64(before.st_size) == extent else {
            throw BoomError.invalid("Public export extent/ownership differs from its physical input.")
          }
          var consumed: UInt64 = 0, hash = SHA256()
          while consumed < extent {
            try Task.checkCancellation()
            guard let block = try file.read(upToCount: Int(min(UInt64(64 << 10), extent - consumed))), !block.isEmpty else {
              throw BoomError.invalid("Public export ended before its admitted extent.")
            }
            hash.update(data: block); consumed += UInt64(block.count)
          }
          guard (try file.read(upToCount: 1))?.isEmpty != false else {
            throw BoomError.invalid("Public export exceeds its admitted extent.")
          }
          var after = stat()
          guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw BoomError.invalid("Public export changed during bounded verification.")
          }
          return Data(hash.finalize())
        }
      } catch { original = error }
      sourceCloseAttempted = true
      do { try await detachedWork { try file.close() }; sourceFile = nil }
      catch {
        if let original { throw BoomError.unavailable(original.localizedDescription + "; export verifier close: " + error.localizedDescription) }
        throw error // the real failed descriptor stays on this Prepared receiver
      }
      if let original { throw original }
      guard digest == expectedDigest else { throw BoomError.invalid("Ordinary export changed the actual generated whole source.") }
    }

    func verifyAfterCapture() async throws {
      guard plan.boundedSQL else { return }
      try requireManagedSource()
      if let workspace { try await workspace.flush() }
      try await verifyOrdinaryExport(named: "final-export.txt"); finalExportJoined = true
      try requireManagedSource(); sourceVerified = true
    }

    func shutdown() async throws {
      var failures: [String] = []
      if let file = sourceFile {
        if sourceCloseAttempted { failures.append("A failed public descriptor close remains retained; no close retry.") }
        else {
          sourceCloseAttempted = true
          do { try await detachedWork { try file.close() }; sourceFile = nil }
          catch { failures.append("Public source close: " + error.localizedDescription) }
        }
      }
      if let workspace {
        do { try await workspace.shutdown() }
        catch { failures.append("Actual workspace close: " + error.localizedDescription) }
      }
      guard failures.isEmpty else { throw BoomError.unavailable(failures.joined(separator: "; ")) }
      window?.close() // do not detach a failed actual native/window receiver
      shutdownJoined = true
    }

    /// Recipe1 retains4MiB/16files/depth4. Ordinary recipes admit32files,
    ///16directories/depth6 and their exact64MiB/8GiB byte ceilings, including
    /// the owner's public TMPDIR. Never inspect a directory during typing.
    private func diskExtent(reservingReceipt: Bool) throws -> UInt64 {
      var pending: [(URL, Int)] = plan.boundedSQL ? [(root, 0), (temporaryRoot, 0)] : [(root, 0)]
      var files = 0, directories = 0, bytes: UInt64 = 0
      while let (directory, depth) = pending.popLast() {
        guard depth < (plan.boundedSQL ? 6 : 4), directories < (plan.boundedSQL ? 16 : 4) else {
          throw BoomError.budget("Public fixture directory bound exceeded.")
        }
        directories += 1
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= (plan.boundedSQL ? 32 : 20) else { throw BoomError.budget("Public fixture entry bound exceeded.") }
        for child in children {
          var info = stat()
          guard lstat(child.path, &info) == 0, info.st_uid == getuid() else {
            throw BoomError.invalid("Public fixture ownership changed.")
          }
          switch info.st_mode & S_IFMT {
          case S_IFDIR: pending.append((child, depth + 1))
          case S_IFREG:
            guard info.st_size >= 0, info.st_nlink == 1 else { throw BoomError.invalid("Public fixture file extent changed.") }
            files += 1
            let next = bytes.addingReportingOverflow(UInt64(info.st_size))
            guard !next.overflow else { throw BoomError.budget("Public fixture disk extent overflowed.") }
            bytes = next.partialValue
          default: throw BoomError.invalid("Public fixture contains a nonregular entry.")
          }
          guard files <= (plan.boundedSQL ? (reservingReceipt ? 31 : 32) : (reservingReceipt ? 15 : 16)),
            bytes <= plan.diskLimit - (reservingReceipt ? 16_384 : 0) else {
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
        "fixture_kind": plan.kind, "storage_route": plan.boundedSQL ? "boundedSQL" : "legacy",
        "primitive_replacements_per_cycle": 2, "public_utf8_bytes": plan.utf8Bytes,
        "physically_generated_bytes": generatedBytes, "generation_stream_chunk_limit": 64 << 10,
        "whole_source_sha256": expectedDigest?.map { String(format: "%02x", $0) }.joined() ?? "absent",
        "ordinary_import_joined": importJoined, "ordinary_selection_joined": selectionJoined,
        "preparation_export_joined": preparationExportJoined, "final_export_joined": finalExportJoined,
        "observation_deadline_seconds": Self.observationSeconds,
        "source_verified": sourceVerified, "capture_finish_acknowledged": captureFinished,
        "workspace_shutdown_joined": shutdownJoined, "keychain_lookups": keySession.lookupCount,
        "process_footprint_before_bytes": footprintBefore, "process_footprint_after_bytes": footprintAfter,
        "process_peak_footprint_bytes": peakFootprint, "workspace_disk_bytes_before_receipt": extent,
        "workspace_disk_limit_bytes": plan.diskLimit, "target_lifetime_seconds": plan.lifetimeSeconds, "failures": failures,
        "scope": plan.boundedSQL
          ? "Warmed actual ordinary boundedSQL WorkspaceModel/WorkspaceView/managed viewport; physical public ASCII imported/export-verified in <=64KiB chunks. Direct paired native edits, synchronous host layout and completed SDK cached-bitmap raster, closed-loop100ms pacing. No inference, IME, hardware input dispatch, deferred draw/compositor acceptance, or per-cycle whole-source copies/hash/files/Mach samples."
          : "Warmed offscreen ordinary Author editor; fixed public ASCII, direct paired edits and synchronous host layout, closed-loop100ms pacing. No inference, IME, physical event dispatch, deferred draw completion or compositor acceptance. No per-cycle source hashing, files or timing arrays."
      ]
      let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      guard bytes.count <= 16_384 else { throw BoomError.budget("Public fixture receipt exceeds its bound.") }
      try bytes.write(to: root.appendingPathComponent("fixture-receipt.json"), options: .withoutOverwriting)
      _ = try diskExtent(reservingReceipt: false)
    }
  }
}
#endif
