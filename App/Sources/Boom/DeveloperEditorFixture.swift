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
/// Fixed ordinary file recipes; no physical input/IME or
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
    private static let cycles: UInt32 = 1_000
    private static let observationSeconds: Int64 = 110
    private let plan: DeveloperStackDiagnostics.PublicEditorPlan
    private let root: URL
    private let temporaryRoot: URL
    private var workspace: WorkspaceModel?
    private var host: NSHostingView<WorkspaceView>?
    private var window: NSWindow?
    private var managedEditor: PagedNativeTextView?
    private var sourceFile: FileHandle?
    private var sourceCloseAttempted = false
    private var bitmap: NSBitmapImageRep?
    private var bitmapSize: NSSize?
    private var expectedDigest: Data?
    private var documentID: UUID?
    private var completed: UInt32 = 0
    private var lastWarmSlot: UInt32?
    private var completedWarmSlots: UInt32 = 0
    private var sourceVerified = false, shutdownJoined = false
    private var importJoined = false, selectionJoined = false, preparationExportJoined = false, finalExportJoined = false
    private var generatedBytes: UInt64 = 0
    private var footprintBefore: UInt64 = 0, footprintAfter: UInt64 = 0, peakFootprint: UInt64 = 0
    private var startupBefore: [String: Any]?, startupAfter: [String: Any]?
    private var startupUndoAttempted = false, startupUndoJoined = false
    private var primingBefore: [String: Any]?, primingAfterInsert: [String: Any]?, primingAfterDelete: [String: Any]?
    private var vmBefore: [String: Any]?, vmAfter: [String: Any]?

    init(recipe: URL, plan: DeveloperStackDiagnostics.PublicEditorPlan) throws {
      guard plan.operations == (plan.isMixed ? 200 : Self.cycles) else {
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

    func prepare() async throws { try await prepareOrdinary() }

    func observe(_ plan: DeveloperStackDiagnostics.PublicEditorPlan) async throws {
      if plan.isMixed { try await observeMixed(plan) }
      else { try await observeOrdinary(plan) }
    }

    private func prepareOrdinary() async throws {
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
      let store = try WorkspaceStore(rootOverride: root.appendingPathComponent("workspace", isDirectory: true))
      let model: WorkspaceModel
      do { model = try await WorkspaceModel(storeOverride: store, loadModels: false) }
      catch let failure as WorkspacePagedStartupFailure {
        workspace = failure.model // preserve actual partial Engine/native custody
        throw failure.original
      }
      workspace = model
      guard model.layout.isAuthor else {
        throw BoomError.invalid("Public ordinary fixture requires the actual file Author route.")
      }
      model.setAutocomplete(false)
      if model.state.showChat == true { model.toggle("chat") }
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
      guard let importedRevision = model.pagedSelectedRecord?.document.revision,
        importedRevision.summary.bytes == extent, importedRevision.summary.utf16 == extent else {
        throw BoomError.invalid("Ordinary public import differs from its generated ASCII source.")
      }
      let host = NSHostingView(rootView: WorkspaceView(model: model)); self.host = host
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      self.window = window; window.isReleasedWhenClosed = false; window.contentView = host
      if plan.isMixed {
        guard NSApp.setActivationPolicy(.regular) else {
          throw BoomError.unavailable("Mixed diagnostics cannot acquire their actual native action route.")
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      }
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      guard let view = model.pagedViewport?.textView as? PagedNativeTextView,
        model.pagedInput?.activeView === view, window.makeFirstResponder(view), view.isEditable else {
        throw BoomError.invalid("Ordinary managed public editor focus was unavailable.")
      }
      managedEditor = view
      var primingView = view
      if plan.isMixed {
        startupBefore = try nativePreparationState(view)
        if view.session.generation != 0 {
          // An incidental key in this explicitly public window is real input.
          // Exercise its actual responder Undo once before the fixed recipe;
          // never guess a deletion or accept a shifted source baseline.
          try await joinMixedInput(0, measured: false)
          let current = try currentMixedView()
          guard let history = current.session.canonicalHistory,
            current.session.generation == 1, history.record.historyGeneration == 1,
            history.undo.count == 1, history.redo.isEmpty,
            history.undo[0].revision == importedRevision,
            history.record.document.revision != importedRevision else {
            throw BoomError.invalid("Public startup input is not exactly one admitted edit of the imported source.")
          }
          startupUndoAttempted = true
          try await mixedResponder(false, event: 0, measured: false)
          startupUndoJoined = true
          primingView = try currentMixedView()
          guard primingView.session.canonicalHistory?.record.document.revision == importedRevision,
            model.pagedSelectedRecord?.document.revision == importedRevision,
            try primingView.session.documentCoordinates().projectedUTF16 == extent else {
            throw BoomError.invalid("The actual startup Undo did not restore the original public source.")
          }
        }
        startupAfter = try nativePreparationState(primingView)
      }
      primingView.setSelectedRange(NSRange(location: 0, length: 0))
      if plan.isMixed { primingBefore = try nativePreparationState(primingView) }
      primingView.insertText("x", replacementRange: primingView.selectedRange())
      if plan.isMixed { primingAfterInsert = try nativePreparationState(primingView) }
      primingView.insertText("", replacementRange: NSRange(location: 0, length: 1))
      if plan.isMixed { primingAfterDelete = try nativePreparationState(primingView) }
      host.layoutSubtreeIfNeeded()
      if plan.isMixed {
        guard window.isKeyWindow else { throw BoomError.unavailable("Mixed diagnostics have no actual key window.") }
        try prepareBitmap(for: primingView, window: window, target: model.pagedViewport)
        // Exercise lazy TextKit/IME/action/navigation loads BEFORE module donation.
        for index in 0..<20 {
          lastWarmSlot = UInt32(index)
          try await performMixedOperation(UInt32(index), measured: false)
          completedWarmSlots += 1
        }
        _ = try currentMixedView()
      }
      if plan.isMixed { host.layoutSubtreeIfNeeded() }
      let preparedView = managedEditor ?? view
      if !plan.isMixed { try prepareBitmap(for: preparedView, window: window) }
      try rasterize(preparedView, target: plan.isMixed ? model.pagedViewport : nil)
      try await model.flush() // actual canonical/worker join, not a delay or flag
      try requireManagedSource()
      try await verifyOrdinaryExport(named: "prepared-export.txt"); preparationExportJoined = true
      _ = try diskExtent(reservingReceipt: true)
      vmBefore = currentVMCategories()
    }

    // Fixed scalar provenance only, outside timed operations; no source bytes.
    private func nativePreparationState(_ view: PagedNativeTextView) throws -> [String: Any] {
      let source = try view.session.documentCoordinates(), selected = view.selectedRange()
      return ["session": source.sessionID.uuidString, "arena": source.arenaID.uuidString,
        "generation": source.generation, "projected_utf16": source.projectedUTF16,
        "local_utf16": source.localUTF16, "local_bytes": source.localBytes,
        "selection_location": selected.location, "selection_length": selected.length,
        "actual_active_view": workspace?.pagedInput?.activeView === view,
        "actual_viewport_view": workspace?.pagedViewport?.textView === view,
        "actual_first_responder": window?.firstResponder === view,
        "command_closed": view.inputCommandIsClosed]
    }

    // The same fixed current-task API as ModelResidency, sampled once before
    // donation and once after capture. Ledgers are categories, not allocation
    // owners; resident bytes and compressed/footprint accounting differ.
    private func currentVMCategories() -> [String: Any] {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let capacity = Int(count)
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      guard status == KERN_SUCCESS, Int(count) == capacity else {
        return ["available": false, "kernel_result": status, "returned_count": count]
      }
      return ["available": true, "kernel_result": status, "returned_count": count,
        "resident_bytes": info.resident_size, "internal_bytes": info.internal,
        "external_bytes": info.external, "reusable_bytes": info.reusable,
        "compressed_bytes": info.compressed, "physical_footprint_bytes": info.phys_footprint,
        "kernel_lifetime_peak_footprint_bytes": info.ledger_phys_footprint_peak,
        "purgeable_nonvolatile_bytes": info.ledger_purgeable_nonvolatile,
        "purgeable_nonvolatile_compressed_bytes": info.ledger_purgeable_novolatile_compressed,
        "media_footprint_bytes": info.ledger_tag_media_footprint,
        "media_compressed_bytes": info.ledger_tag_media_footprint_compressed,
        "graphics_footprint_bytes": info.ledger_tag_graphics_footprint,
        "graphics_compressed_bytes": info.ledger_tag_graphics_footprint_compressed,
        "neural_footprint_bytes": info.ledger_tag_neural_footprint,
        "neural_compressed_bytes": info.ledger_tag_neural_footprint_compressed]
    }

    private func observeOrdinary(_ requested: DeveloperStackDiagnostics.PublicEditorPlan) async throws {
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

    // Ten repetitions of the same twenty real product operations. Slot and
    // location derive from the numeric event; no per-operation text/log array.
    private static let mixedSlots = [
      "head-type", "middle-type", "tail-type", "head-replace", "middle-replace", "tail-replace",
      "grapheme-backspace", "marked-commit", "forward-delete", "backward-delete",
      "cross-window-delete", "select-all-replace", "scroll-head", "scroll-middle", "scroll-tail",
      "scroll-edge", "scroll-click", "recenter-head", "scroll-with-typing", "scroll-with-typing-tail",
    ]

    private func currentMixedView() throws -> PagedNativeTextView {
      guard let model = workspace, let view = model.pagedInput?.activeView,
        model.pagedViewport?.textView === view, let window,
        window.firstResponder === view, window.isKeyWindow else {
        throw BoomError.stale("Mixed observation lost its actual mounted key-window client.")
      }
      managedEditor = view
      try requireManagedSource()
      return view
    }

    private func mixedCPU(_ event: UInt64, measured: Bool, _ operation: () throws -> Void) rethrows {
      let trace = measured ? PerformanceTrace.begin("Editor.PublicInputDispatch", event: event) : nil
      defer { PerformanceTrace.end("Editor.PublicInputDispatch", trace) }
      try operation()
    }

    private func mixedReady(_ event: UInt64, measured: Bool,
      _ operation: () async throws -> Void) async rethrows {
      let trace = measured ? PerformanceTrace.begin("Editor.PublicReadyWait", event: event) : nil
      defer { PerformanceTrace.end("Editor.PublicReadyWait", trace) }
      try await operation()
    }

    private func joinMixedInput(_ event: UInt64, measured: Bool) async throws {
      guard let model = workspace, let commands = model.pagedCommands else {
        throw BoomError.stale("Mixed input lost its existing command owner.")
      }
      try await mixedReady(event, measured: measured) {
        try await commands.joinPendingCommand()
        try await model.flush()
      }
      _ = try currentMixedView()
    }

    private func mixedCaret(_ position: UInt64, event: UInt64, measured: Bool) async throws {
      guard let model = workspace, let commands = model.pagedCommands,
        let session = model.pagedSession else { throw BoomError.stale("Mixed caret has no native session.") }
      let before = try session.documentCoordinates()
      let end = before.utf16Start + UInt64(before.localUTF16)
      if position >= before.utf16Start, position <= end {
        try mixedCPU(event, measured: measured) {
          try currentMixedView().setSelectedRange(NSRange(location: Int(position - before.utf16Start), length: 0))
        }
      } else {
        try await mixedReady(event, measured: measured) {
          _ = try await commands.navigate(toUTF16: position > 4096 ? position - 4096 : 0,
            selectingUTF16: PagedNativeNavigationSelection(utf16Offset: position, utf16Length: 0))
        }
      }
      _ = try currentMixedView()
      guard try model.pagedInput?.currentDocumentSelection().utf16Offset == position,
        try model.pagedInput?.currentDocumentSelection().utf16Length == 0 else {
        throw BoomError.invalid("Mixed caret was not received at its actual global scalar.")
      }
    }

    private func mixedResponder(_ redo: Bool, event: UInt64, measured: Bool) async throws {
      let view = try currentMixedView()
      let action = NSSelectorFromString(redo ? "redo:" : "undo:")
      let item = NSMenuItem(title: redo ? "Redo" : "Undo", action: action, keyEquivalent: "z")
      if redo { item.keyEquivalentModifierMask = [.command, .shift] }
      try mixedCPU(event, measured: measured) {
        guard item.target == nil, view.validateUserInterfaceItem(item),
          let responder = window?.firstResponder, responder === view,
          responder.tryToPerform(action, with: item) else {
          throw BoomError.unavailable("The actual window responder refused its canonical history action.")
        }
      }
      try await joinMixedInput(event, measured: measured)
    }

    private func mixedRestoreEdit(event: UInt64, measured: Bool) async throws {
      try await mixedResponder(false, event: event, measured: measured)
      try await mixedResponder(true, event: event, measured: measured)
      try await mixedResponder(false, event: event, measured: measured)
    }

    private func performMixedOperation(_ index: UInt32, measured: Bool) async throws {
      guard let model = workspace, let input = model.pagedInput,
        let commands = model.pagedCommands, let viewport = model.pagedViewport else {
        throw BoomError.stale("Mixed observation lost its ordinary graph.")
      }
      let event = UInt64(index) + 1, slot = Int(index % 20), extent = plan.utf8Bytes
      let positions: [UInt64] = [32, extent / 2, extent - 4096]
      if slot < 12 || slot >= 18 {
        try await mixedCaret(positions[slot % 3], event: event, measured: measured)
      }
      let generation = input.session.generation
      switch slot {
      case 0...2:
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView(), start = view.selectedRange().location
          view.insertText("x", replacementRange: view.selectedRange())
          view.insertText("", replacementRange: NSRange(location: start, length: 1))
        }
        try await joinMixedInput(event, measured: measured)
      case 3...5:
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView()
          view.insertText("A changed bounded span.", replacementRange: NSRange(location: view.selectedRange().location, length: 64))
        }
        try await joinMixedInput(event, measured: measured)
        try await mixedRestoreEdit(event: event, measured: measured)
      case 6:
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView()
          view.insertText("e\u{301}👩🏽‍💻", replacementRange: view.selectedRange())
        }
        try await joinMixedInput(event, measured: measured)
        try renderMixedSurface(event: event, measured: measured)
        for _ in 0..<2 {
          try mixedCPU(event, measured: measured) {
            try currentMixedView().doCommand(by: NSSelectorFromString("deleteBackward:"))
          }
          try await joinMixedInput(event, measured: measured)
        }
      case 7:
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView(), unspecified = NSRange(location: NSNotFound, length: 0)
          view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
          guard view.hasMarkedText() else { throw BoomError.invalid("The native marked-text input was not pinned.") }
          view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
          view.unmarkText()
          guard !view.hasMarkedText() else { throw BoomError.invalid("The native marked-text input did not commit.") }
        }
        try await joinMixedInput(event, measured: measured)
        try renderMixedSurface(event: event, measured: measured)
        try await mixedRestoreEdit(event: event, measured: measured)
      case 8, 9:
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView(), start = view.selectedRange().location
          view.setSelectedRange(NSRange(location: start, length: 256))
          view.doCommand(by: NSSelectorFromString(slot == 8 ? "deleteForward:" : "deleteBackward:"))
        }
        try await joinMixedInput(event, measured: measured)
        try await mixedRestoreEdit(event: event, measured: measured)
      case 10, 11:
        if slot == 11 {
          // Exercise the same actual action as the nil-target menu. Its
          // existing ordered command must join before interpreting insertion.
          try mixedCPU(event, measured: measured) { try currentMixedView().selectAll(nil) }
          try await mixedReady(event, measured: measured) { try await commands.joinPendingCommand() }
          let selected = try input.currentDocumentSelection()
          guard selected.utf16Offset == 0, selected.utf16Length == extent,
            selected.utf16Length == (try input.session.documentCoordinates()).projectedUTF16 else {
            throw BoomError.invalid("Mixed Select All did not select the actual complete source.")
          }
        }
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView()
          if slot == 10 {
            let caret = try input.currentDocumentSelection().utf16Offset
            let lower = min(caret, extent - 32_768)
            try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: lower,
              utf16Length: 32_768, focusAtEnd: true))
          }
          view.insertText(slot == 11 ? "Small." : "", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try await joinMixedInput(event, measured: measured)
        try await mixedRestoreEdit(event: event, measured: measured)
      case 12...15:
        let anchors: [UInt64] = [0, extent / 2, extent - 4096, extent / 2 + 16_383]
        try mixedCPU(event, measured: measured) { try viewport.requestScroll(toUTF16: anchors[slot - 12]) }
        try await mixedReady(event, measured: measured) { try await viewport.joinPresentation() }
        guard let displayed = viewport.visibleScrollWindow, displayed.text.utf8.count <= 16_384 else {
          throw BoomError.invalid("The actual bounded scroll projection was absent.")
        }
      case 16:
        guard let displayed = viewport.visibleScrollWindow else { throw BoomError.stale("Mixed click has no actual displayed source.") }
        let local = min(3, displayed.text.utf16.count)
        try mixedCPU(event, measured: measured) { try viewport.selectVisibleUTF16(local) }
        try await mixedReady(event, measured: measured) { try await commands.joinPendingCommand() }
        guard try input.currentDocumentSelection().utf16Offset == displayed.utf16Start + UInt64(local) else {
          throw BoomError.invalid("The displayed source click did not mount its exact native scalar.")
        }
      case 17:
        try await mixedCaret(32, event: event, measured: measured)
      default:
        let view = try currentMixedView(), start = view.selectedRange().location
        try mixedCPU(event, measured: measured) {
          view.insertText("x", replacementRange: view.selectedRange())
          try viewport.requestScroll(toUTF16: slot == 18 ? extent / 2 : extent - 4096)
          // Contained input is accepted while the actual read remains owned.
          view.insertText("y", replacementRange: view.selectedRange())
        }
        try await mixedReady(event, measured: measured) { try await viewport.joinPresentation() }
        try mixedCPU(event, measured: measured) {
          try currentMixedView().insertText("", replacementRange: NSRange(location: start, length: 2))
        }
        try await joinMixedInput(event, measured: measured)
        // Superseded projections need not have been shown. Join a fresh real
        // source read before counting this end-to-ready operation complete.
        try mixedCPU(event, measured: measured) { try viewport.requestScroll(toUTF16: extent / 2) }
        try await mixedReady(event, measured: measured) { try await viewport.joinPresentation() }
      }
      _ = try currentMixedView()
      if slot < 12 || slot >= 18 {
        guard input.session.generation > generation else { throw BoomError.invalid("Mixed edit did not advance the native source.") }
      }
      guard model.pagedInput === input, model.pagedCommands === commands, model.pagedViewport === viewport,
        model.pagedSelectedRecord?.document.revision.summary.bytes == extent else {
        throw BoomError.invalid("Mixed operation did not retain its graph or restored source extent.")
      }
    }

    private func renderMixedSurface(event: UInt64, measured: Bool) throws {
      guard let model = workspace, let host else { throw BoomError.stale("Mixed display has no actual host.") }
      let layout = measured ? PerformanceTrace.begin("Editor.HostLayout", event: event) : nil
      host.layoutSubtreeIfNeeded()
      PerformanceTrace.end("Editor.HostLayout", layout)
      let view = try currentMixedView()
      let draw = measured ? PerformanceTrace.begin("Editor.PublicRaster", event: event) : nil
      defer { PerformanceTrace.end("Editor.PublicRaster", draw) }
      try rasterize(view, target: model.pagedViewport)
    }

    private func observeMixed(_ requested: DeveloperStackDiagnostics.PublicEditorPlan) async throws {
      guard requested.kind == plan.kind, requested.operations == plan.operations,
        requested.utf8Bytes == plan.utf8Bytes, plan.isMixed, host != nil,
        let window, workspace != nil else { throw BoomError.invalid("Mixed public preparation is incomplete.") }
      _ = try currentMixedView()
      footprintBefore = ModelResidency.memoryAccounting().current
      guard footprintBefore > 0 else { throw BoomError.unavailable("Public process footprint is unavailable.") }
      let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(Self.observationSeconds))
      for index in 0..<requested.operations {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw BoomError.unavailable("Mixed observation exceeded its fixed bound.") }
        try await Task.sleep(until: clock.now.advanced(by: .milliseconds(250)), clock: clock)
        guard clock.now < deadline else { throw BoomError.unavailable("Mixed observation expired before its next operation.") }
        let operation = PerformanceTrace.begin("Editor.PublicMixedOperation", event: UInt64(index) + 1)
        do {
          defer { PerformanceTrace.end("Editor.PublicMixedOperation", operation) }
          try await performMixedOperation(index, measured: true)
          try renderMixedSurface(event: UInt64(index) + 1, measured: true)
          guard window.firstResponder === managedEditor else { throw BoomError.stale("Mixed raster lost its actual responder.") }
        }
        try Task.checkCancellation()
        guard clock.now < deadline else { throw BoomError.unavailable("Mixed operation exceeded the observation deadline; prefix retained.") }
        completed += 1
      }
      let after = ModelResidency.memoryAccounting()
      footprintAfter = after.current; peakFootprint = after.peak
      guard footprintAfter > 0, peakFootprint >= footprintAfter else { throw BoomError.unavailable("Mixed process footprint is incomplete.") }
    }

    private func requireManagedSource() throws {
      guard let model = workspace, let view = managedEditor, let id = documentID,
        model.selectedDocumentID == id,
        model.pagedSelectedRecord?.document.id == id,
        model.pagedViewport?.textView === view, model.pagedInput?.activeView === view,
        model.pagedSession === view.session, view.inputBinding?.owner === model.pagedInput,
        view.inputBinding?.state == .active, view.inputBinding?.identity == model.pagedInput?.activeIdentity,
        view.inputBinding?.identity.arenaID == view.session.arenaID, view.inputCommandIsClosed,
        view.boundedStorage.mutationFailure == nil, view.inputBinding?.firstRefusal == nil,
        view.boundedStorage.length <= PagedWorkingWindow.hardBytes, view.isEditable, !view.hasMarkedText(),
        model.errorMessage == nil, model.writingIssue == nil,
        model.completionRunner == nil, model.selectedMLXRunner == nil,
        !model.autocompleteEnabled else {
        let model = workspace, view = managedEditor
        let failed = [
          ("missing", model == nil || view == nil || documentID == nil),
          ("document", model?.selectedDocumentID != documentID || model?.pagedSelectedRecord?.document.id != documentID),
          ("viewport", model?.pagedViewport?.textView !== view),
          ("input", model?.pagedInput?.activeView !== view),
          ("session", model?.pagedSession !== view?.session),
          ("owner", view?.inputBinding?.owner !== model?.pagedInput),
          ("binding", view?.inputBinding?.state != .active || view?.inputBinding?.identity != model?.pagedInput?.activeIdentity),
          ("arena", view?.inputBinding?.identity.arenaID != view?.session.arenaID),
          ("transaction", view?.inputCommandIsClosed != true),
          ("mutation", view?.boundedStorage.mutationFailure != nil),
          ("refusal", view?.inputBinding?.firstRefusal != nil),
          ("extent", (view?.boundedStorage.length ?? Int.max) > PagedWorkingWindow.hardBytes),
          ("editable", view?.isEditable != true),
          ("marked", view?.hasMarkedText() != false),
          ("error", model?.errorMessage != nil),
          ("writing", model?.writingIssue != nil),
          ("model", model?.completionRunner != nil || model?.selectedMLXRunner != nil || model?.autocompleteEnabled != false),
        ].filter { $0.1 }.map { $0.0 }.joined(separator: ",")
        let originals: [(String, Error?)] = [
          ("mutation", view?.boundedStorage.mutationFailure),
          ("bindingRefusal", view?.inputBinding?.firstRefusal),
          ("inputRefusal", model?.pagedInput?.firstRefusal),
          ("commandFailure", model?.pagedCommands?.firstFailure),
        ]
        let underlying = originals.compactMap { label, error -> String? in
          guard let error else { return nil }
          let kind = String(String(reflecting: type(of: error)).prefix(128))
          let reason = String(decoding: error.localizedDescription.utf8.prefix(512), as: UTF8.self)
          return "\(label)=\(kind):\(reason)"
        }.joined(separator: ";")
        throw BoomError.invalid("Ordinary public source/native/model binding changed: \(failed); warmSlot=\(lastWarmSlot.map(String.init) ?? "none"); warmCompleted=\(completedWarmSlots); original=\(underlying).")
      }
    }

    private func prepareBitmap(for view: PagedNativeTextView, window: NSWindow, target: NSView? = nil) throws {
      let surface = target ?? view
      guard surface === view || surface === workspace?.pagedViewport else {
        throw BoomError.denied("Public raster has another native surface.")
      }
      let visible = surface.visibleRect, scale = window.backingScaleFactor
      guard visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0,
        visible.width <= 1190, visible.height <= 846, scale.isFinite, scale >= 1, scale <= 2,
        ceil(visible.width * scale) * ceil(visible.height * scale) * 8 <= 32 * 1048576,
        let backing = surface.bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero, size: visible.size)) else {
        throw BoomError.budget("Ordinary public raster backing is outside its fixed viewport bound.")
      }
      let cost = backing.bytesPerRow.multipliedReportingOverflow(by: backing.pixelsHigh)
      guard backing.bytesPerRow > 0, backing.pixelsHigh > 0, !cost.overflow, cost.partialValue <= 32 * 1048576 else {
        throw BoomError.budget("Ordinary public raster backing exceeds32MiB.")
      }
      bitmap = backing; bitmapSize = visible.size
    }

    private func rasterize(_ view: PagedNativeTextView, target: NSView? = nil) throws {
      let surface = target ?? view
      guard surface === view || surface === workspace?.pagedViewport else {
        throw BoomError.denied("Public raster has another native surface.")
      }
      let visible = surface.visibleRect
      guard let window, workspace?.pagedViewport?.window === window, view.window === window, window.firstResponder === view else {
        throw BoomError.stale("Ordinary public raster lost its actual attached viewport/native window/focus.")
      }
      guard let bitmap, let bitmapSize, visible.origin.x.isFinite, visible.origin.y.isFinite,
        visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0,
        visible.width <= bitmapSize.width, visible.height <= bitmapSize.height else {
        throw BoomError.budget("Ordinary public raster no longer fits its prepared backing.")
      }
      surface.cacheDisplay(in: visible, to: bitmap)
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
      vmAfter = currentVMCategories()
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

    /// Ordinary recipes admit32files,16directories/depth6 and their fixed
    /// byte ceilings, including
    /// the owner's public TMPDIR. Never inspect a directory during typing.
    private func diskExtent(reservingReceipt: Bool) throws -> UInt64 {
      var pending: [(URL, Int)] = [(root, 0), (temporaryRoot, 0)]
      var files = 0, directories = 0, bytes: UInt64 = 0
      while let (directory, depth) = pending.popLast() {
        guard depth < 6, directories < 16 else {
          throw BoomError.budget("Public fixture directory bound exceeded.")
        }
        directories += 1
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 32 else { throw BoomError.budget("Public fixture entry bound exceeded.") }
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
          guard files <= (reservingReceipt ? 31 : 32),
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
          && completed == plan.operations ? "complete" : "incomplete",
        "requested_cycles": plan.operations, "completed_cycles": completed,
        "operation_program": plan.isMixed ? "mixed-v1" : "head-paired-v1",
        "mixed_slots": plan.isMixed ? Self.mixedSlots : [],
        "mixed_warmed_before_donation": plan.isMixed && completedWarmSlots == 20,
        "mixed_warm_completed": completedWarmSlots,
        "mixed_warm_last_slot": lastWarmSlot.map { $0 as Any } ?? NSNull(),
        "startup_input_before": startupBefore ?? ["available": false],
        "startup_input_after": startupAfter ?? ["available": false],
        "startup_incidental_undo_attempted": startupUndoAttempted,
        "startup_incidental_undo_joined": startupUndoJoined,
        "priming_before": primingBefore ?? ["available": false],
        "priming_after_insert": primingAfterInsert ?? ["available": false],
        "priming_after_delete": primingAfterDelete ?? ["available": false],
        "vm_categories_before_capture": vmBefore ?? ["available": false],
        "vm_categories_after_capture": vmAfter ?? ["available": false],
        "synchronous_cpu_stage": "Editor.PublicInputDispatch",
        "ready_wait_stage": "Editor.PublicReadyWait",
        "end_to_ready_stage": "Editor.PublicMixedOperation",
        "offscreen_sdk_diagnostic": true,
        "slow_dispatch_threshold_ns": 8_000_000,
        "fixture_kind": plan.kind, "storage_route": "files",
        "primitive_replacements_per_cycle": plan.isMixed ? (NSNull() as Any) : (2 as Any), "public_utf8_bytes": plan.utf8Bytes,
        "physically_generated_bytes": generatedBytes, "generation_stream_chunk_limit": 64 << 10,
        "whole_source_sha256": expectedDigest?.map { String(format: "%02x", $0) }.joined() ?? "absent",
        "ordinary_import_joined": importJoined, "ordinary_selection_joined": selectionJoined,
        "preparation_export_joined": preparationExportJoined, "final_export_joined": finalExportJoined,
        "observation_deadline_seconds": Self.observationSeconds,
        "source_verified": sourceVerified, "capture_finish_acknowledged": captureFinished,
        "workspace_shutdown_joined": shutdownJoined,
        "process_footprint_before_bytes": footprintBefore, "process_footprint_after_bytes": footprintAfter,
        "process_peak_footprint_bytes": peakFootprint, "workspace_disk_bytes_before_receipt": extent,
        "workspace_disk_limit_bytes": plan.diskLimit, "target_lifetime_seconds": plan.lifetimeSeconds, "failures": failures,
        "scope": plan.isMixed ? "Warmed actual ordinary graph with bounded head/middle/tail edits, NFD/ZWJ deletion, direct marked-text primitives, actual window-responder Undo/Redo, bounded and whole-source root edits, read-only scroll/click/recenter and interleaved contained input. Offscreen SDK raster; no hardware keyboard/input-method service/compositor, model or GPU-overlap acceptance. CPU dispatch spans contain no await; command/read/source joins have separate wait spans inside end-to-ready. All raw observations and failures retained." : "Warmed actual ordinary file WorkspaceModel/WorkspaceView/managed viewport; physical public ASCII imported/export-verified in <=64KiB chunks. Direct paired native edits, synchronous host layout and completed SDK cached-bitmap raster, closed-loop100ms pacing. No inference, IME, hardware input dispatch, deferred draw/compositor acceptance, or per-cycle whole-source copies/hash/files/Mach samples."
      ]
      let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      guard bytes.count <= 16_384 else { throw BoomError.budget("Public fixture receipt exceeds its bound.") }
      try bytes.write(to: root.appendingPathComponent("fixture-receipt.json"), options: .withoutOverwriting)
      _ = try diskExtent(reservingReceipt: false)
    }
  }
}
#endif
